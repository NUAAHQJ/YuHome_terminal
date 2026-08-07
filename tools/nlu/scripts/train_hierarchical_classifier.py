#!/usr/bin/env python3
"""Train and evaluate the rule + route-head + intent-head YuHome NLU."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import random
import shutil
import sys
import time
from collections import Counter
from pathlib import Path
from typing import Any

os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

import numpy as np
import torch
import torch.nn.functional as F
from sklearn.metrics import accuracy_score, classification_report, f1_score
from torch.nn.utils import clip_grad_norm_
from torch.optim import AdamW
from torch.utils.data import DataLoader, Dataset
from transformers import AutoTokenizer, get_linear_schedule_with_warmup


ROOT = Path(__file__).resolve().parents[1]
SPLITS = (
    "train",
    "validation",
    "test",
    "asr_noise_test",
    "boundary_test",
    "safety_adversarial_test",
)
CONTROL_LABELS = {"light_set", "ac_power_set", "curtain_set", "ac_temperature_set", "ac_mode_set"}

sys.path.insert(0, str(Path(__file__).resolve().parent))
from hierarchical_model import (  # noqa: E402
    HierarchicalNLUModel,
    load_hierarchical_checkpoint,
    save_hierarchical_checkpoint,
)
from hierarchical_rules import hard_route  # noqa: E402


def json_dump(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    with path.open("r", encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def seed_everything(seed: int) -> None:
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(seed)
    torch.use_deterministic_algorithms(False)


def resolve_device(requested: str) -> torch.device:
    if requested == "auto":
        return torch.device("cuda" if torch.cuda.is_available() else "cpu")
    if requested == "cuda" and not torch.cuda.is_available():
        raise RuntimeError("CUDA was requested but torch.cuda.is_available() is false")
    return torch.device(requested)


class HierarchicalDataset(Dataset):
    def __init__(
        self,
        rows: list[dict[str, Any]],
        tokenizer: Any,
        route_to_id: dict[str, int],
        intent_to_id: dict[str, int],
        max_length: int,
    ) -> None:
        self.rows = rows
        self.encoded = tokenizer(
            [row["text"] for row in rows],
            padding="max_length",
            truncation=True,
            max_length=max_length,
            return_tensors="pt",
        )
        self.route_targets = torch.tensor([route_to_id[row["route"]] for row in rows], dtype=torch.long)
        self.intent_targets = torch.tensor(
            [intent_to_id.get(row["intent"], -100) for row in rows], dtype=torch.long
        )

    def __len__(self) -> int:
        return len(self.rows)

    def __getitem__(self, index: int) -> dict[str, torch.Tensor]:
        item = {name: values[index] for name, values in self.encoded.items()}
        item["route_targets"] = self.route_targets[index]
        item["intent_targets"] = self.intent_targets[index]
        return item


def sqrt_inverse_weights(targets: list[int], count: int) -> torch.Tensor:
    frequencies = Counter(targets)
    total = len(targets)
    weights = np.array(
        [math.sqrt(total / (count * frequencies[index])) for index in range(count)], dtype=np.float32
    )
    weights /= weights.mean()
    return torch.tensor(weights, dtype=torch.float32)


def batch_loss(
    route_logits: torch.Tensor,
    intent_logits: torch.Tensor,
    route_targets: torch.Tensor,
    intent_targets: torch.Tensor,
    route_weights: torch.Tensor,
    intent_weights: torch.Tensor,
    route_loss_weight: float,
    label_smoothing: float,
) -> torch.Tensor:
    route_loss = F.cross_entropy(
        route_logits, route_targets, weight=route_weights, label_smoothing=label_smoothing
    )
    intent_mask = intent_targets != -100
    if intent_mask.any():
        intent_loss = F.cross_entropy(
            intent_logits[intent_mask],
            intent_targets[intent_mask],
            weight=intent_weights,
            label_smoothing=label_smoothing,
        )
    else:
        intent_loss = route_loss.new_zeros(())
    return route_loss_weight * route_loss + intent_loss


def infer(
    model: HierarchicalNLUModel,
    loader: DataLoader,
    device: torch.device,
    route_weights: torch.Tensor,
    intent_weights: torch.Tensor,
    config: dict[str, Any],
) -> tuple[float, np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    model.eval()
    losses: list[float] = []
    route_chunks: list[np.ndarray] = []
    intent_chunks: list[np.ndarray] = []
    route_targets: list[np.ndarray] = []
    intent_targets: list[np.ndarray] = []
    with torch.inference_mode():
        for batch in loader:
            route_target = batch.pop("route_targets").to(device)
            intent_target = batch.pop("intent_targets").to(device)
            inputs = {name: value.to(device) for name, value in batch.items()}
            route_logits, intent_logits = model(**inputs)
            loss = batch_loss(
                route_logits,
                intent_logits,
                route_target,
                intent_target,
                route_weights,
                intent_weights,
                float(config["route_loss_weight"]),
                float(config["label_smoothing"]),
            )
            losses.append(float(loss.detach().cpu()))
            route_chunks.append(torch.softmax(route_logits, dim=-1).cpu().numpy())
            intent_chunks.append(torch.softmax(intent_logits, dim=-1).cpu().numpy())
            route_targets.append(route_target.cpu().numpy())
            intent_targets.append(intent_target.cpu().numpy())
    return (
        float(np.mean(losses)),
        np.concatenate(route_chunks),
        np.concatenate(intent_chunks),
        np.concatenate(route_targets),
        np.concatenate(intent_targets),
    )


def final_predictions(
    rows: list[dict[str, Any]],
    route_probabilities: np.ndarray,
    intent_probabilities: np.ndarray,
    route_labels: list[str],
    intent_labels: list[str],
    thresholds: dict[str, float],
) -> tuple[list[str], list[str | None]]:
    route_to_id = {label: index for index, label in enumerate(route_labels)}
    predictions: list[str] = []
    rule_names: list[str | None] = []
    for row, route_probs, intent_probs in zip(rows, route_probabilities, intent_probabilities):
        decision = hard_route(row["text"])
        if decision is not None:
            predictions.append(decision.intent)
            rule_names.append(decision.rule)
            continue
        if route_probs[route_to_id["requires_confirmation"]] >= thresholds["confirmation"]:
            predictions.append("requires_confirmation")
        elif (
            route_probs[route_to_id["in_domain"]] >= thresholds["in_domain"]
            and float(intent_probs.max()) >= thresholds["intent"]
        ):
            predictions.append(intent_labels[int(intent_probs.argmax())])
        else:
            predictions.append("unknown")
        rule_names.append(None)
    return predictions, rule_names


def calculate_metrics(
    rows: list[dict[str, Any]],
    predictions: list[str],
    rule_names: list[str | None],
    final_labels: list[str],
    loss: float,
) -> dict[str, Any]:
    expected = [row["intent"] for row in rows]
    report = classification_report(
        expected,
        predictions,
        labels=final_labels,
        output_dict=True,
        zero_division=0,
    )
    unknown_mask = np.array([label == "unknown" for label in expected])
    sensitive_mask = np.array([label == "requires_confirmation" for label in expected])
    cancellation_mask = np.array(
        [str(row.get("safety_case") or "").startswith("cancelled_control") for row in rows]
    )
    positive_control_mask = np.array([row.get("safety_case") == "positive_control" for row in rows])
    predicted_array = np.array(predictions, dtype=object)
    control_array = np.array([prediction in CONTROL_LABELS for prediction in predictions])
    unknown_false_accept_count = int(np.sum(unknown_mask & (predicted_array != "unknown")))
    unknown_to_control_count = int(np.sum(unknown_mask & control_array))
    sensitive_bypass_count = int(
        np.sum(sensitive_mask & (predicted_array != "requires_confirmation"))
    )
    cancellation_control_count = int(np.sum(cancellation_mask & control_array))
    positive_control_block_count = int(
        np.sum(positive_control_mask & ~control_array)
    )
    return {
        "loss": loss,
        "accuracy": float(accuracy_score(expected, predictions)),
        "macro_f1": float(
            f1_score(expected, predictions, labels=final_labels, average="macro", zero_division=0)
        ),
        "weighted_f1": float(f1_score(expected, predictions, average="weighted", zero_division=0)),
        "unknown_false_accept_count": unknown_false_accept_count,
        "unknown_false_accept_rate": (
            unknown_false_accept_count / int(unknown_mask.sum()) if unknown_mask.any() else 0.0
        ),
        "unknown_to_control_count": unknown_to_control_count,
        "unknown_to_control_rate": (
            unknown_to_control_count / int(unknown_mask.sum()) if unknown_mask.any() else 0.0
        ),
        "requires_confirmation_bypass_count": sensitive_bypass_count,
        "requires_confirmation_bypass_rate": (
            sensitive_bypass_count / int(sensitive_mask.sum()) if sensitive_mask.any() else 0.0
        ),
        "cancelled_control_execution_count": cancellation_control_count,
        "cancelled_control_execution_rate": (
            cancellation_control_count / int(cancellation_mask.sum()) if cancellation_mask.any() else 0.0
        ),
        "positive_control_block_count": positive_control_block_count,
        "hard_rule_coverage_rate": float(np.mean([name is not None for name in rule_names])),
        "per_intent": {label: report[label] for label in final_labels},
    }


def calibrate_thresholds(
    rows: list[dict[str, Any]],
    route_probabilities: np.ndarray,
    intent_probabilities: np.ndarray,
    route_labels: list[str],
    intent_labels: list[str],
    final_labels: list[str],
    max_unknown_false_accept_rate: float,
) -> dict[str, Any]:
    candidates: list[dict[str, Any]] = []
    expected = np.array([row["intent"] for row in rows], dtype=object)
    unknown_mask = expected == "unknown"
    sensitive_mask = expected == "requires_confirmation"
    cancellation_mask = np.array(
        [str(row.get("safety_case") or "").startswith("cancelled_control") for row in rows]
    )
    for confirmation in (0.15, 0.25, 0.35, 0.45, 0.55):
        for in_domain in (0.50, 0.60, 0.70, 0.80, 0.90, 0.95):
            for intent in (0.15, 0.25, 0.35, 0.45, 0.55, 0.65, 0.75, 0.85):
                thresholds = {
                    "confirmation": round(float(confirmation), 4),
                    "in_domain": round(float(in_domain), 4),
                    "intent": round(float(intent), 4),
                }
                predictions, rules = final_predictions(
                    rows, route_probabilities, intent_probabilities, route_labels, intent_labels, thresholds
                )
                predicted = np.array(predictions, dtype=object)
                control_mask = np.array([label in CONTROL_LABELS for label in predictions])
                unknown_false_accept_count = int(np.sum(unknown_mask & (predicted != "unknown")))
                unknown_to_control_count = int(np.sum(unknown_mask & control_mask))
                confirmation_bypass_count = int(
                    np.sum(sensitive_mask & (predicted != "requires_confirmation"))
                )
                cancelled_execution_count = int(np.sum(cancellation_mask & control_mask))
                unknown_false_accept_rate = (
                    unknown_false_accept_count / int(unknown_mask.sum()) if unknown_mask.any() else 0.0
                )
                macro_f1 = float(
                    f1_score(expected, predicted, labels=final_labels, average="macro", zero_division=0)
                )
                accuracy = float(accuracy_score(expected, predicted))
                safety_eligible = (
                    unknown_to_control_count == 0
                    and confirmation_bypass_count == 0
                    and cancelled_execution_count == 0
                    and unknown_false_accept_rate <= max_unknown_false_accept_rate
                )
                candidates.append(
                    {
                        "thresholds": thresholds,
                        "safety_eligible": safety_eligible,
                        "macro_f1": macro_f1,
                        "accuracy": accuracy,
                        "unknown_false_accept_rate": unknown_false_accept_rate,
                        "unknown_to_control_count": unknown_to_control_count,
                        "requires_confirmation_bypass_count": confirmation_bypass_count,
                        "cancelled_control_execution_count": cancelled_execution_count,
                    }
                )
    selected = max(
        candidates,
        key=lambda item: (
            int(item["safety_eligible"]),
            -item["unknown_to_control_count"],
            -item["requires_confirmation_bypass_count"],
            -item["cancelled_control_execution_count"],
            -item["unknown_false_accept_rate"],
            item["macro_f1"],
            item["accuracy"],
        ),
    )
    return {"selected": selected, "candidate_count": len(candidates)}


def write_errors(
    path: Path,
    rows: list[dict[str, Any]],
    predictions: list[str],
    rule_names: list[str | None],
    route_probabilities: np.ndarray,
    intent_probabilities: np.ndarray,
    route_labels: list[str],
    intent_labels: list[str],
) -> None:
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        for row, predicted, rule, route_probs, intent_probs in zip(
            rows, predictions, rule_names, route_probabilities, intent_probabilities
        ):
            if row["intent"] == predicted:
                continue
            route_rank = np.argsort(route_probs)[::-1]
            intent_rank = np.argsort(intent_probs)[::-1][:3]
            value = {
                "id": row["id"],
                "text": row["text"],
                "expected": row["intent"],
                "predicted": predicted,
                "safety_case": row.get("safety_case"),
                "hard_rule": rule,
                "route_probabilities": {
                    route_labels[int(index)]: float(route_probs[index]) for index in route_rank
                },
                "top_intents": [
                    {"intent": intent_labels[int(index)], "confidence": float(intent_probs[index])}
                    for index in intent_rank
                ],
            }
            handle.write(json.dumps(value, ensure_ascii=False, sort_keys=True) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--config", type=Path, default=ROOT / "configs" / "hierarchical_train_config.json"
    )
    parser.add_argument("--data-dir", type=Path, default=ROOT / "data" / "hierarchical_v1")
    parser.add_argument("--run-dir", type=Path)
    parser.add_argument(
        "--initial-encoder",
        type=Path,
        help="Optional local encoder checkpoint used to initialize new route and intent heads.",
    )
    parser.add_argument(
        "--initial-checkpoint",
        type=Path,
        help="Optional hierarchical checkpoint whose compatible heads are retained during label expansion.",
    )
    parser.add_argument("--freeze-encoder", action="store_true")
    parser.add_argument("--preserve-initial-intent-heads", action="store_true")
    parser.add_argument("--seed", type=int)
    parser.add_argument("--device", choices=("cuda", "cpu", "auto"), default="cuda")
    parser.add_argument("--overwrite", action="store_true")
    args = parser.parse_args()

    config_path = args.config.resolve()
    data_dir = args.data_dir.resolve()
    config = json.loads(config_path.read_text(encoding="utf-8"))
    initial_encoder = args.initial_encoder.resolve() if args.initial_encoder is not None else None
    initial_checkpoint = args.initial_checkpoint.resolve() if args.initial_checkpoint is not None else None
    if initial_encoder is not None and initial_checkpoint is not None:
        parser.error("--initial-encoder and --initial-checkpoint cannot be used together")
    if args.preserve_initial_intent_heads and initial_checkpoint is None:
        parser.error("--preserve-initial-intent-heads requires --initial-checkpoint")
    seed = int(args.seed if args.seed is not None else config["seed"])
    label_config = json.loads(
        (ROOT / "configs" / "hierarchical_labels.json").read_text(encoding="utf-8")
    )
    route_labels: list[str] = label_config["route_labels"]
    intent_labels: list[str] = label_config["intent_labels"]
    final_labels: list[str] = label_config["final_labels"]
    route_to_id = {label: index for index, label in enumerate(route_labels)}
    intent_to_id = {label: index for index, label in enumerate(intent_labels)}
    run_name = f"{config['run_name']}_seed{seed}"
    run_dir = (args.run_dir or (ROOT / "artifacts" / run_name)).resolve()
    if run_dir.exists() and any(run_dir.iterdir()) and not args.overwrite:
        raise RuntimeError(f"Run directory is not empty: {run_dir}")
    run_dir.mkdir(parents=True, exist_ok=True)
    checkpoint_dir = run_dir / "best_checkpoint"

    device = resolve_device(args.device)
    seed_everything(seed)
    print(
        f"device={device} gpu={torch.cuda.get_device_name(0) if device.type == 'cuda' else 'none'} "
        f"torch={torch.__version__} seed={seed}",
        flush=True,
    )

    rows_by_split = {split: load_jsonl(data_dir / f"{split}.jsonl") for split in SPLITS}
    tokenizer = AutoTokenizer.from_pretrained(
        config["base_model"], use_fast=True, cache_dir=ROOT / ".cache" / "huggingface"
    )
    datasets = {
        split: HierarchicalDataset(
            rows, tokenizer, route_to_id, intent_to_id, int(config["max_length"])
        )
        for split, rows in rows_by_split.items()
    }
    loaders = {
        split: DataLoader(
            dataset,
            batch_size=int(config["batch_size"] if split == "train" else config["eval_batch_size"]),
            shuffle=split == "train",
            num_workers=int(config["num_workers"]),
        )
        for split, dataset in datasets.items()
    }
    train_rows = rows_by_split["train"]
    route_weights = sqrt_inverse_weights(
        [route_to_id[row["route"]] for row in train_rows], len(route_labels)
    ).to(device)
    intent_weights = sqrt_inverse_weights(
        [intent_to_id[row["intent"]] for row in train_rows if row["route"] == "in_domain"],
        len(intent_labels),
    ).to(device)
    preserved_intent_rows: dict[int, tuple[torch.Tensor, torch.Tensor]] = {}
    if initial_checkpoint is None:
        model = HierarchicalNLUModel.from_pretrained(
            initial_encoder if initial_encoder is not None else config["base_model"],
            len(route_labels),
            len(intent_labels),
            float(config["dropout"]),
            ROOT / ".cache" / "huggingface",
        ).to(device)
    else:
        previous_model, previous_metadata = load_hierarchical_checkpoint(initial_checkpoint, device)
        previous_route_labels: list[str] = previous_metadata["route_labels"]
        previous_intent_labels: list[str] = previous_metadata["intent_labels"]
        if previous_route_labels != route_labels:
            raise ValueError("Initial checkpoint route labels do not match the current training contract")
        if any(label not in intent_to_id for label in previous_intent_labels):
            raise ValueError("Initial checkpoint contains an intent absent from the current training contract")
        model = HierarchicalNLUModel(
            previous_model.encoder,
            len(route_labels),
            len(intent_labels),
            float(config["dropout"]),
        ).to(device)
        with torch.no_grad():
            model.route_classifier.load_state_dict(previous_model.route_classifier.state_dict())
            for previous_index, label in enumerate(previous_intent_labels):
                current_index = intent_to_id[label]
                model.intent_classifier.weight[current_index].copy_(previous_model.intent_classifier.weight[previous_index])
                model.intent_classifier.bias[current_index].copy_(previous_model.intent_classifier.bias[previous_index])
                if args.preserve_initial_intent_heads:
                    preserved_intent_rows[current_index] = (
                        previous_model.intent_classifier.weight[previous_index].detach().clone(),
                        previous_model.intent_classifier.bias[previous_index].detach().clone(),
                    )
    if args.freeze_encoder:
        for parameter in model.encoder.parameters():
            parameter.requires_grad_(False)
    optimizer = AdamW(model.parameters(), lr=float(config["learning_rate"]), weight_decay=float(config["weight_decay"]))
    total_steps = len(loaders["train"]) * int(config["epochs"])
    scheduler = get_linear_schedule_with_warmup(
        optimizer,
        num_warmup_steps=round(total_steps * float(config["warmup_ratio"])),
        num_training_steps=total_steps,
    )

    history: list[dict[str, Any]] = []
    best_rank: tuple[int, float] | None = None
    best_epoch = 0
    stale_epochs = 0
    started = time.perf_counter()
    for epoch in range(1, int(config["epochs"]) + 1):
        epoch_started = time.perf_counter()
        model.train()
        train_losses: list[float] = []
        for batch in loaders["train"]:
            route_target = batch.pop("route_targets").to(device)
            intent_target = batch.pop("intent_targets").to(device)
            inputs = {name: value.to(device) for name, value in batch.items()}
            optimizer.zero_grad(set_to_none=True)
            route_logits, intent_logits = model(**inputs)
            loss = batch_loss(
                route_logits,
                intent_logits,
                route_target,
                intent_target,
                route_weights,
                intent_weights,
                float(config["route_loss_weight"]),
                float(config["label_smoothing"]),
            )
            loss.backward()
            clip_grad_norm_(model.parameters(), float(config["gradient_clip_norm"]))
            optimizer.step()
            if preserved_intent_rows:
                with torch.no_grad():
                    for index, (weight, bias) in preserved_intent_rows.items():
                        model.intent_classifier.weight[index].copy_(weight)
                        model.intent_classifier.bias[index].copy_(bias)
            scheduler.step()
            train_losses.append(float(loss.detach().cpu()))

        val_loss, val_route, val_intent, _, _ = infer(
            model, loaders["validation"], device, route_weights, intent_weights, config
        )
        calibration = calibrate_thresholds(
            rows_by_split["validation"],
            val_route,
            val_intent,
            route_labels,
            intent_labels,
            final_labels,
            float(config["max_validation_unknown_false_accept_rate"]),
        )
        selected = calibration["selected"]
        rank = (int(selected["safety_eligible"]), float(selected["macro_f1"]))
        epoch_record = {
            "epoch": epoch,
            "train_loss": float(np.mean(train_losses)),
            "validation_loss": val_loss,
            "validation_macro_f1": selected["macro_f1"],
            "validation_accuracy": selected["accuracy"],
            "safety_eligible": selected["safety_eligible"],
            "thresholds": selected["thresholds"],
            "unknown_false_accept_rate": selected["unknown_false_accept_rate"],
            "seconds": time.perf_counter() - epoch_started,
        }
        history.append(epoch_record)
        print(json.dumps(epoch_record, ensure_ascii=False), flush=True)
        improved = best_rank is None or rank[0] > best_rank[0] or (
            rank[0] == best_rank[0]
            and rank[1] > best_rank[1] + float(config["early_stopping_min_delta"])
        )
        if improved:
            best_rank = rank
            best_epoch = epoch
            stale_epochs = 0
            save_hierarchical_checkpoint(
                model,
                tokenizer,
                checkpoint_dir,
                {
                    "architecture": "shared_encoder_route_and_intent_heads",
                    "base_model": config["base_model"],
                    "initial_encoder": str(initial_encoder) if initial_encoder is not None else None,
                    "initial_checkpoint": str(initial_checkpoint) if initial_checkpoint is not None else None,
                    "freeze_encoder": args.freeze_encoder,
                    "preserve_initial_intent_heads": args.preserve_initial_intent_heads,
                    "route_labels": route_labels,
                    "intent_labels": intent_labels,
                    "final_labels": final_labels,
                    "dropout": float(config["dropout"]),
                    "max_length": int(config["max_length"]),
                    "seed": seed,
                    "best_epoch": epoch,
                    "thresholds": selected["thresholds"],
                },
            )
        else:
            stale_epochs += 1
            if stale_epochs >= int(config["early_stopping_patience"]):
                break

    model, checkpoint_metadata = load_hierarchical_checkpoint(checkpoint_dir, device)
    thresholds = checkpoint_metadata["thresholds"]
    evaluation: dict[str, Any] = {}
    for split in SPLITS[1:]:
        loss, route_probs, intent_probs, route_targets, _ = infer(
            model, loaders[split], device, route_weights, intent_weights, config
        )
        predictions, rule_names = final_predictions(
            rows_by_split[split],
            route_probs,
            intent_probs,
            route_labels,
            intent_labels,
            thresholds,
        )
        metrics = calculate_metrics(
            rows_by_split[split], predictions, rule_names, final_labels, loss
        )
        metrics["route_head_accuracy_before_rules"] = float(
            accuracy_score(route_targets, route_probs.argmax(axis=1))
        )
        evaluation[split] = metrics
        json_dump(run_dir / f"metrics_{split}.json", metrics)
        write_errors(
            run_dir / f"errors_{split}.jsonl",
            rows_by_split[split],
            predictions,
            rule_names,
            route_probs,
            intent_probs,
            route_labels,
            intent_labels,
        )

    acceptance = {
        "zero_unknown_to_control": all(
            evaluation[split]["unknown_to_control_count"] == 0
            for split in ("test", "asr_noise_test", "safety_adversarial_test")
        ),
        "zero_confirmation_bypass": all(
            evaluation[split]["requires_confirmation_bypass_count"] == 0
            for split in ("test", "asr_noise_test", "safety_adversarial_test")
        ),
        "zero_cancelled_control_execution": all(
            evaluation[split]["cancelled_control_execution_count"] == 0
            for split in ("test", "asr_noise_test", "safety_adversarial_test")
        ),
        "unknown_false_accept_at_most_5_percent": all(
            evaluation[split]["unknown_false_accept_rate"] <= 0.05
            for split in ("test", "asr_noise_test", "safety_adversarial_test")
        ),
        "zero_positive_control_block": evaluation["safety_adversarial_test"][
            "positive_control_block_count"
        ] == 0,
        "test_macro_f1_at_least_0_84": evaluation["test"]["macro_f1"] >= 0.84,
        "asr_macro_f1_at_least_0_82": evaluation["asr_noise_test"]["macro_f1"] >= 0.82,
        "safety_adversarial_accuracy_at_least_0_99": evaluation[
            "safety_adversarial_test"
        ]["accuracy"] >= 0.99,
        "boundary_accuracy_is_1": evaluation["boundary_test"]["accuracy"] == 1.0,
    }
    acceptance["passed"] = all(acceptance.values())
    metadata = {
        "run_name": run_name,
        "architecture": "hard_rules_then_shared_route_and_intent_heads",
        "base_model": config["base_model"],
        "initial_encoder": str(initial_encoder) if initial_encoder is not None else None,
        "initial_checkpoint": str(initial_checkpoint) if initial_checkpoint is not None else None,
        "freeze_encoder": args.freeze_encoder,
        "preserve_initial_intent_heads": args.preserve_initial_intent_heads,
        "seed": seed,
        "device": str(device),
        "gpu": torch.cuda.get_device_name(0) if device.type == "cuda" else None,
        "python_version": platform.python_version(),
        "torch_version": torch.__version__,
        "best_epoch": best_epoch,
        "thresholds": thresholds,
        "elapsed_seconds": time.perf_counter() - started,
        "dataset_hashes": {
            f"{split}.jsonl": sha256_file(data_dir / f"{split}.jsonl") for split in SPLITS
        },
        "evaluation": {
            split: {
                key: value
                for key, value in metrics.items()
                if key not in ("per_intent",)
            }
            for split, metrics in evaluation.items()
        },
        "acceptance": acceptance,
    }
    json_dump(run_dir / "training_history.json", history)
    json_dump(run_dir / "run_metadata.json", metadata)
    json_dump(run_dir / "acceptance.json", acceptance)
    shutil.copyfile(config_path, run_dir / "train_config.json")
    shutil.copyfile(ROOT / "configs" / "hierarchical_labels.json", run_dir / "hierarchical_labels.json")
    print(json.dumps(metadata, ensure_ascii=False, indent=2), flush=True)


if __name__ == "__main__":
    main()
