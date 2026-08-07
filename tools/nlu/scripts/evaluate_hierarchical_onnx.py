#!/usr/bin/env python3
"""Evaluate a hierarchical ONNX model with the same rule and routing policy."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

import numpy as np
import onnxruntime as ort
from transformers import AutoTokenizer

from train_hierarchical_classifier import (
    SPLITS,
    calculate_metrics,
    calibrate_thresholds,
    final_predictions,
    load_jsonl,
    write_errors,
)


def softmax(values: np.ndarray) -> np.ndarray:
    shifted = values - values.max(axis=1, keepdims=True)
    exponential = np.exp(shifted)
    return exponential / exponential.sum(axis=1, keepdims=True)


def infer_onnx(
    session: ort.InferenceSession,
    rows: list[dict[str, Any]],
    tokenizer: Any,
    max_length: int,
    batch_size: int,
) -> tuple[np.ndarray, np.ndarray]:
    route_chunks: list[np.ndarray] = []
    intent_chunks: list[np.ndarray] = []
    input_names = {value.name for value in session.get_inputs()}
    for start in range(0, len(rows), batch_size):
        batch = rows[start : start + batch_size]
        tokens = tokenizer(
            [row["text"] for row in batch],
            padding="max_length",
            truncation=True,
            max_length=max_length,
            return_tensors="np",
        )
        inputs = {name: tokens[name].astype(np.int64) for name in input_names}
        route_logits, intent_logits = session.run(None, inputs)
        route_chunks.append(softmax(route_logits))
        intent_chunks.append(softmax(intent_logits))
    return np.concatenate(route_chunks), np.concatenate(intent_chunks)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", type=Path, required=True)
    parser.add_argument("--data-dir", type=Path, required=True)
    parser.add_argument("--model", type=Path)
    parser.add_argument("--calibrate", action="store_true")
    parser.add_argument("--batch-size", type=int, default=64)
    args = parser.parse_args()
    run_dir = args.run.resolve()
    data_dir = args.data_dir.resolve()
    checkpoint = run_dir / "best_checkpoint"
    metadata = json.loads((checkpoint / "hierarchical_config.json").read_text(encoding="utf-8"))
    route_labels = metadata["route_labels"]
    intent_labels = metadata["intent_labels"]
    final_labels = metadata["final_labels"]
    model_path = (args.model or (run_dir / "onnx" / "hierarchical_nlu.fp32.onnx")).resolve()
    tokenizer = AutoTokenizer.from_pretrained(checkpoint)
    rows_by_split = {split: load_jsonl(data_dir / f"{split}.jsonl") for split in SPLITS}
    session = ort.InferenceSession(str(model_path), providers=["CPUExecutionProvider"])
    probabilities = {
        split: infer_onnx(
            session, rows, tokenizer, int(metadata["max_length"]), args.batch_size
        )
        for split, rows in rows_by_split.items()
    }
    if args.calibrate:
        route_probs, intent_probs = probabilities["validation"]
        calibration = calibrate_thresholds(
            rows_by_split["validation"],
            route_probs,
            intent_probs,
            route_labels,
            intent_labels,
            final_labels,
            0.05,
        )
        thresholds = calibration["selected"]["thresholds"]
    else:
        calibration = None
        thresholds = metadata["thresholds"]

    output_dir = run_dir / "onnx"
    model_tag = model_path.stem
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
        metrics = calculate_metrics(rows_by_split[split], predictions, rules, final_labels, 0.0)
        evaluation[split] = {key: value for key, value in metrics.items() if key != "per_intent"}
        write_errors(
            output_dir / f"errors_{model_tag}_{split}.jsonl",
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
        "model": model_path.name,
        "thresholds": thresholds,
        "calibration": calibration,
        "evaluation": evaluation,
        "acceptance": acceptance,
    }
    output = output_dir / f"evaluation_{model_tag}.json"
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
