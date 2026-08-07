#!/usr/bin/env python3
"""Recalibrate and evaluate a trained hierarchical checkpoint with current rules."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

import torch
from torch.utils.data import DataLoader
from transformers import AutoTokenizer

from hierarchical_model import load_hierarchical_checkpoint
from train_hierarchical_classifier import (
    SPLITS,
    HierarchicalDataset,
    calculate_metrics,
    calibrate_thresholds,
    final_predictions,
    infer,
    load_jsonl,
    write_errors,
)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", type=Path, required=True)
    parser.add_argument("--data-dir", type=Path, required=True)
    parser.add_argument("--device", choices=("cuda", "cpu"), default="cuda")
    parser.add_argument("--tag", default="current_rules")
    parser.add_argument(
        "--fixed-thresholds",
        type=float,
        nargs=3,
        metavar=("CONFIRMATION", "IN_DOMAIN", "INTENT"),
        help="Evaluate a supplied threshold triple instead of recalibrating on validation data.",
    )
    args = parser.parse_args()
    run_dir = args.run.resolve()
    data_dir = args.data_dir.resolve()
    device = torch.device(args.device)
    model, metadata = load_hierarchical_checkpoint(run_dir / "best_checkpoint", device)
    tokenizer = AutoTokenizer.from_pretrained(run_dir / "best_checkpoint")
    config = json.loads((run_dir / "train_config.json").read_text(encoding="utf-8"))
    route_labels = metadata["route_labels"]
    intent_labels = metadata["intent_labels"]
    final_labels = metadata["final_labels"]
    route_to_id = {label: index for index, label in enumerate(route_labels)}
    intent_to_id = {label: index for index, label in enumerate(intent_labels)}
    rows_by_split = {split: load_jsonl(data_dir / f"{split}.jsonl") for split in SPLITS}
    loaders = {
        split: DataLoader(
            HierarchicalDataset(
                rows,
                tokenizer,
                route_to_id,
                intent_to_id,
                int(metadata["max_length"]),
            ),
            batch_size=int(config["eval_batch_size"]),
            shuffle=False,
        )
        for split, rows in rows_by_split.items()
    }
    route_weights = torch.ones(len(route_labels), device=device)
    intent_weights = torch.ones(len(intent_labels), device=device)
    probabilities: dict[str, tuple[Any, Any]] = {}
    losses: dict[str, float] = {}
    for split in SPLITS:
        loss, route_probs, intent_probs, _, _ = infer(
            model, loaders[split], device, route_weights, intent_weights, config
        )
        losses[split] = loss
        probabilities[split] = (route_probs, intent_probs)

    validation_route, validation_intent = probabilities["validation"]
    if args.fixed_thresholds is None:
        calibration = calibrate_thresholds(
            rows_by_split["validation"],
            validation_route,
            validation_intent,
            route_labels,
            intent_labels,
            final_labels,
            float(config["max_validation_unknown_false_accept_rate"]),
        )
        thresholds = calibration["selected"]["thresholds"]
    else:
        calibration = None
        thresholds = {
            "confirmation": args.fixed_thresholds[0],
            "in_domain": args.fixed_thresholds[1],
            "intent": args.fixed_thresholds[2],
        }
    evaluation: dict[str, Any] = {}
    for split in SPLITS[1:]:
        route_probs, intent_probs = probabilities[split]
        predictions, rules = final_predictions(
            rows_by_split[split],
            route_probs,
            intent_probs,
            route_labels,
            intent_labels,
            thresholds,
        )
        metrics = calculate_metrics(
            rows_by_split[split], predictions, rules, final_labels, losses[split]
        )
        evaluation[split] = {key: value for key, value in metrics.items() if key != "per_intent"}
        write_errors(
            run_dir / f"errors_{args.tag}_{split}.jsonl",
            rows_by_split[split],
            predictions,
            rules,
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
    report = {
        "tag": args.tag,
        "thresholds": thresholds,
        "calibration": calibration,
        "evaluation": evaluation,
        "acceptance": acceptance,
    }
    output = run_dir / f"reevaluation_{args.tag}.json"
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
