#!/usr/bin/env python3
"""Fine-tune hfl/rbt3 for YuHome intent classification and evaluate it."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
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
from sklearn.metrics import accuracy_score, classification_report, confusion_matrix, f1_score
from torch.nn.utils import clip_grad_norm_
from torch.optim import AdamW
from torch.utils.data import DataLoader, Dataset
from transformers import AutoModelForSequenceClassification, AutoTokenizer, get_linear_schedule_with_warmup


ROOT = Path(__file__).resolve().parents[1]
CONTROL_LABELS = {"light_set", "ac_power_set", "curtain_set", "ac_temperature_set", "ac_mode_set"}

sys.path.insert(0, str(Path(__file__).resolve().parent))
from slot_rules import extract_slots, validate_slots  # noqa: E402


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


class EncodedDataset(Dataset):
    def __init__(self, rows: list[dict[str, Any]], tokenizer: Any, label_to_id: dict[str, int], max_length: int) -> None:
        self.rows = rows
        self.encoded = tokenizer(
            [row["text"] for row in rows],
            padding="max_length",
            truncation=True,
            max_length=max_length,
            return_tensors="pt",
        )
        self.labels = torch.tensor([label_to_id[row["intent"]] for row in rows], dtype=torch.long)

    def __len__(self) -> int:
        return len(self.rows)

    def __getitem__(self, index: int) -> dict[str, torch.Tensor]:
        item = {name: values[index] for name, values in self.encoded.items()}
        item["labels"] = self.labels[index]
        return item


def resolve_device(requested: str) -> torch.device:
    if requested == "auto":
        return torch.device("cuda" if torch.cuda.is_available() else "cpu")
    if requested == "cuda" and not torch.cuda.is_available():
        raise RuntimeError("CUDA was requested but torch.cuda.is_available() is false")
    return torch.device(requested)


def infer(
    model: torch.nn.Module,
    loader: DataLoader[dict[str, torch.Tensor]],
    device: torch.device,
) -> tuple[float, np.ndarray, np.ndarray]:
    model.eval()
    losses: list[float] = []
    probability_chunks: list[np.ndarray] = []
    labels: list[np.ndarray] = []
    with torch.inference_mode():
        for batch in loader:
            batch = {name: tensor.to(device) for name, tensor in batch.items()}
            outputs = model(**batch)
            losses.append(float(outputs.loss.detach().cpu()))
            probability_chunks.append(torch.softmax(outputs.logits, dim=-1).cpu().numpy())
            labels.append(batch["labels"].cpu().numpy())
    probabilities = np.concatenate(probability_chunks, axis=0)
    targets = np.concatenate(labels, axis=0)
    return float(np.mean(losses)), probabilities, targets


def threshold_predictions(probabilities: np.ndarray, threshold: float, unknown_id: int) -> np.ndarray:
    predictions = probabilities.argmax(axis=1)
    confidence = probabilities.max(axis=1)
    return np.where(confidence >= threshold, predictions, unknown_id)


def calibrate_threshold(
    probabilities: np.ndarray,
    targets: np.ndarray,
    unknown_id: int,
    threshold_min: float,
    threshold_max: float,
    threshold_step: float,
    labels: list[int],
) -> dict[str, Any]:
    candidates: list[dict[str, float]] = []
    threshold = threshold_min
    while threshold <= threshold_max + 1e-9:
        predictions = threshold_predictions(probabilities, threshold, unknown_id)
        macro_f1 = f1_score(targets, predictions, labels=labels, average="macro", zero_division=0)
        candidates.append({"threshold": round(threshold, 4), "macro_f1": float(macro_f1)})
        threshold += threshold_step
    best = max(candidates, key=lambda item: (item["macro_f1"], item["threshold"]))
    return {"selected_threshold": best["threshold"], "validation_macro_f1": best["macro_f1"], "candidates": candidates}


def calculate_metrics(
    targets: np.ndarray,
    predictions: np.ndarray,
    probabilities: np.ndarray,
    labels: list[str],
    threshold: float,
    loss: float,
) -> dict[str, Any]:
    ids = list(range(len(labels)))
    label_to_id = {label: index for index, label in enumerate(labels)}
    report = classification_report(
        targets,
        predictions,
        labels=ids,
        target_names=labels,
        output_dict=True,
        zero_division=0,
    )
    unknown_id = label_to_id["unknown"]
    sensitive_id = label_to_id["requires_confirmation"]
    unknown_mask = targets == unknown_id
    sensitive_mask = targets == sensitive_id
    control_ids = {label_to_id[label] for label in CONTROL_LABELS}
    unknown_false_accept = float(np.mean(predictions[unknown_mask] != unknown_id)) if unknown_mask.any() else 0.0
    sensitive_miss = float(np.mean(predictions[sensitive_mask] != sensitive_id)) if sensitive_mask.any() else 0.0
    sensitive_control = float(np.mean(np.isin(predictions[sensitive_mask], list(control_ids)))) if sensitive_mask.any() else 0.0
    return {
        "loss": loss,
        "threshold": threshold,
        "accuracy": float(accuracy_score(targets, predictions)),
        "macro_f1": float(f1_score(targets, predictions, labels=ids, average="macro", zero_division=0)),
        "weighted_f1": float(f1_score(targets, predictions, labels=ids, average="weighted", zero_division=0)),
        "unknown_false_accept_rate": unknown_false_accept,
        "requires_confirmation_miss_rate": sensitive_miss,
        "sensitive_control_misexecution_rate": sensitive_control,
        "mean_confidence": float(probabilities.max(axis=1).mean()),
        "per_intent": {label: report[label] for label in labels},
    }


def write_confusion_matrix(path: Path, targets: np.ndarray, predictions: np.ndarray, labels: list[str]) -> None:
    matrix = confusion_matrix(targets, predictions, labels=list(range(len(labels))))
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["actual\\predicted", *labels])
        for label, row in zip(labels, matrix.tolist()):
            writer.writerow([label, *row])


def write_errors(
    path: Path,
    rows: list[dict[str, Any]],
    targets: np.ndarray,
    predictions: np.ndarray,
    probabilities: np.ndarray,
    labels: list[str],
) -> None:
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        for row, expected, predicted, probs in zip(rows, targets, predictions, probabilities):
            if int(expected) == int(predicted):
                continue
            ranked = np.argsort(probs)[::-1][:3]
            error = {
                "id": row["id"],
                "text": row["text"],
                "family_id": row["family_id"],
                "expected": labels[int(expected)],
                "predicted": labels[int(predicted)],
                "confidence": float(probs[int(predicted)]),
                "top3": [{"intent": labels[int(index)], "confidence": float(probs[index])} for index in ranked],
            }
            handle.write(json.dumps(error, ensure_ascii=False, sort_keys=True) + "\n")


def slot_metrics(rows: list[dict[str, Any]]) -> dict[str, Any]:
    sample_total = len(rows)
    exact = 0
    values_total = 0
    values_correct = 0
    validity_correct = 0
    by_field: dict[str, Counter[str]] = {}
    for row in rows:
        predicted = extract_slots(row["text"], row["intent"])
        expected = row["slots"]
        if predicted == expected:
            exact += 1
        for field, value in expected.items():
            values_total += 1
            counter = by_field.setdefault(field, Counter())
            counter["total"] += 1
            if predicted.get(field) == value:
                values_correct += 1
                counter["correct"] += 1
        if validate_slots(row["intent"], predicted) == row["slot_valid"]:
            validity_correct += 1
    return {
        "samples": sample_total,
        "exact_match_accuracy": exact / sample_total if sample_total else 0.0,
        "value_accuracy": values_correct / values_total if values_total else 0.0,
        "range_validation_accuracy": validity_correct / sample_total if sample_total else 0.0,
        "per_field": {
            field: {
                "correct": counts["correct"],
                "total": counts["total"],
                "accuracy": counts["correct"] / counts["total"],
            }
            for field, counts in sorted(by_field.items())
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=ROOT / "configs" / "train_config.json")
    parser.add_argument("--data-dir", type=Path, default=ROOT / "data" / "generated")
    parser.add_argument("--run-dir", type=Path)
    parser.add_argument(
        "--device",
        choices=("cuda", "cpu", "auto"),
        default="cuda",
        help="Training defaults to CUDA and fails fast when CUDA is unavailable; CPU requires an explicit choice.",
    )
    parser.add_argument("--threads", type=int, default=0, help="CPU intra-op threads; 0 keeps the torch default")
    parser.add_argument("--overwrite", action="store_true")
    args = parser.parse_args()

    config_path = args.config.resolve()
    data_dir = args.data_dir.resolve()
    config = json.loads(config_path.read_text(encoding="utf-8"))
    labels_payload = json.loads((ROOT / "configs" / "labels.json").read_text(encoding="utf-8"))
    labels: list[str] = labels_payload["labels"]
    label_to_id = {label: index for index, label in enumerate(labels)}
    id_to_label = {index: label for label, index in label_to_id.items()}
    run_dir = (args.run_dir or (ROOT / "artifacts" / config["run_name"])).resolve()
    if run_dir.exists() and any(run_dir.iterdir()) and not args.overwrite:
        raise RuntimeError(f"Run directory is not empty: {run_dir}. Use --overwrite or choose --run-dir.")
    run_dir.mkdir(parents=True, exist_ok=True)
    checkpoint_dir = run_dir / "best_checkpoint"
    model_cache_dir = ROOT / ".cache" / "huggingface"
    model_cache_dir.mkdir(parents=True, exist_ok=True)

    seed = int(config["seed"])
    seed_everything(seed)
    if args.threads > 0:
        torch.set_num_threads(args.threads)
    device = resolve_device(args.device)
    print(f"device={device} torch={torch.__version__} python={platform.python_version()}", flush=True)

    rows_by_split = {
        split: load_jsonl(data_dir / f"{split}.jsonl")
        for split in ("train", "validation", "test", "asr_noise_test", "boundary_test")
    }
    class_counts = Counter(row["intent"] for row in rows_by_split["train"])
    if config.get("class_weighting") == "sqrt_inverse_frequency":
        raw_weights = np.array(
            [np.sqrt(len(rows_by_split["train"]) / (len(labels) * class_counts[label])) for label in labels],
            dtype=np.float32,
        )
        raw_weights /= raw_weights.mean()
    elif config.get("class_weighting", "none") == "none":
        raw_weights = np.ones(len(labels), dtype=np.float32)
    else:
        raise ValueError(f"Unsupported class_weighting: {config.get('class_weighting')}")
    for label, override in config.get("class_weight_overrides", {}).items():
        if label not in label_to_id:
            raise ValueError(f"Unknown class_weight_overrides label: {label}")
        raw_weights[label_to_id[label]] = float(override)
    class_weights = torch.tensor(raw_weights, dtype=torch.float32, device=device)
    print(
        "class_weights=" + json.dumps(
            {label: round(float(raw_weights[index]), 4) for index, label in enumerate(labels)},
            ensure_ascii=False,
        ),
        flush=True,
    )
    tokenizer = AutoTokenizer.from_pretrained(
        config["base_model"], use_fast=True, cache_dir=model_cache_dir
    )
    model = AutoModelForSequenceClassification.from_pretrained(
        config["base_model"],
        num_labels=len(labels),
        label2id=label_to_id,
        id2label=id_to_label,
        ignore_mismatched_sizes=True,
        cache_dir=model_cache_dir,
    ).to(device)

    datasets = {
        split: EncodedDataset(rows, tokenizer, label_to_id, int(config["max_length"]))
        for split, rows in rows_by_split.items()
    }
    generator = torch.Generator().manual_seed(seed)
    train_loader = DataLoader(
        datasets["train"],
        batch_size=int(config["batch_size"]),
        shuffle=True,
        generator=generator,
        num_workers=int(config["num_workers"]),
    )
    eval_loaders = {
        split: DataLoader(
            dataset,
            batch_size=int(config["eval_batch_size"]),
            shuffle=False,
            num_workers=int(config["num_workers"]),
        )
        for split, dataset in datasets.items()
        if split != "train"
    }

    optimizer = AdamW(model.parameters(), lr=float(config["learning_rate"]), weight_decay=float(config["weight_decay"]))
    total_steps = len(train_loader) * int(config["epochs"])
    warmup_steps = round(total_steps * float(config["warmup_ratio"]))
    scheduler = get_linear_schedule_with_warmup(optimizer, warmup_steps, total_steps)
    use_amp = device.type == "cuda"
    scaler = torch.amp.GradScaler("cuda", enabled=use_amp)
    history: list[dict[str, Any]] = []
    best_macro_f1 = -1.0
    best_epoch = 0
    stale_epochs = 0
    started_at = time.time()

    for epoch in range(1, int(config["epochs"]) + 1):
        epoch_started = time.time()
        model.train()
        train_losses: list[float] = []
        for batch in train_loader:
            batch = {name: tensor.to(device) for name, tensor in batch.items()}
            batch_labels = batch.pop("labels")
            optimizer.zero_grad(set_to_none=True)
            with torch.amp.autocast(device_type=device.type, enabled=use_amp):
                outputs = model(**batch)
                loss = F.cross_entropy(
                    outputs.logits,
                    batch_labels,
                    weight=class_weights,
                    label_smoothing=float(config.get("label_smoothing", 0.0)),
                )
            scaler.scale(loss).backward()
            scaler.unscale_(optimizer)
            clip_grad_norm_(model.parameters(), float(config["gradient_clip_norm"]))
            scaler.step(optimizer)
            scaler.update()
            scheduler.step()
            train_losses.append(float(loss.detach().cpu()))

        val_loss, val_probabilities, val_targets = infer(model, eval_loaders["validation"], device)
        val_predictions = val_probabilities.argmax(axis=1)
        val_macro_f1 = float(
            f1_score(val_targets, val_predictions, labels=list(range(len(labels))), average="macro", zero_division=0)
        )
        epoch_record = {
            "epoch": epoch,
            "train_loss": float(np.mean(train_losses)),
            "validation_loss": val_loss,
            "validation_macro_f1": val_macro_f1,
            "seconds": time.time() - epoch_started,
        }
        history.append(epoch_record)
        print(json.dumps(epoch_record, ensure_ascii=False), flush=True)

        if val_macro_f1 > best_macro_f1 + float(config["early_stopping_min_delta"]):
            best_macro_f1 = val_macro_f1
            best_epoch = epoch
            stale_epochs = 0
            checkpoint_dir.mkdir(parents=True, exist_ok=True)
            model.save_pretrained(checkpoint_dir, safe_serialization=True)
            tokenizer.save_pretrained(checkpoint_dir)
        else:
            stale_epochs += 1
            if stale_epochs >= int(config["early_stopping_patience"]):
                print(f"early stopping at epoch {epoch}", flush=True)
                break

    del model
    if device.type == "cuda":
        torch.cuda.empty_cache()
    model = AutoModelForSequenceClassification.from_pretrained(checkpoint_dir).to(device)
    val_loss, val_probabilities, val_targets = infer(model, eval_loaders["validation"], device)
    calibration = calibrate_threshold(
        val_probabilities,
        val_targets,
        label_to_id["unknown"],
        float(config["threshold_min"]),
        float(config["threshold_max"]),
        float(config["threshold_step"]),
        list(range(len(labels))),
    )
    threshold = float(calibration["selected_threshold"])
    json_dump(run_dir / "confidence_threshold.json", calibration)

    evaluation_summary: dict[str, Any] = {}
    for split, loader in eval_loaders.items():
        loss, probabilities, targets = infer(model, loader, device)
        predictions = threshold_predictions(probabilities, threshold, label_to_id["unknown"])
        metrics = calculate_metrics(targets, predictions, probabilities, labels, threshold, loss)
        json_dump(run_dir / f"metrics_{split}.json", metrics)
        write_confusion_matrix(run_dir / f"confusion_matrix_{split}.csv", targets, predictions, labels)
        write_errors(run_dir / f"errors_{split}.jsonl", rows_by_split[split], targets, predictions, probabilities, labels)
        evaluation_summary[split] = {
            key: metrics[key]
            for key in (
                "loss", "accuracy", "macro_f1", "weighted_f1", "unknown_false_accept_rate",
                "requires_confirmation_miss_rate", "sensitive_control_misexecution_rate",
            )
        }
        print(f"{split}: accuracy={metrics['accuracy']:.4f} macro_f1={metrics['macro_f1']:.4f}", flush=True)

    held_out_rows = rows_by_split["test"] + rows_by_split["asr_noise_test"] + rows_by_split["boundary_test"]
    json_dump(run_dir / "slot_metrics.json", slot_metrics(held_out_rows))
    json_dump(run_dir / "training_history.json", history)
    shutil.copyfile(ROOT / "configs" / "labels.json", run_dir / "labels.json")
    shutil.copyfile(config_path, run_dir / "train_config.json")
    dataset_hashes = {
        path.name: sha256_file(path)
        for path in sorted(data_dir.glob("*.jsonl"))
    }
    metadata = {
        "run_name": config["run_name"],
        "base_model": config["base_model"],
        "seed": seed,
        "device": str(device),
        "python_version": platform.python_version(),
        "torch_version": torch.__version__,
        "best_epoch": best_epoch,
        "best_validation_macro_f1_before_threshold": best_macro_f1,
        "confidence_threshold": threshold,
        "elapsed_seconds": time.time() - started_at,
        "dataset_hashes": dataset_hashes,
        "split_sizes": {split: len(rows) for split, rows in rows_by_split.items()},
        "evaluation": evaluation_summary,
    }
    json_dump(run_dir / "run_metadata.json", metadata)
    print(f"run artifacts: {run_dir}", flush=True)


if __name__ == "__main__":
    main()
