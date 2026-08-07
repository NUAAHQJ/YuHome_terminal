#!/usr/bin/env python3
"""Run focused final safety-adversarial evaluation for exported ONNX variants."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import onnxruntime as ort
from transformers import AutoTokenizer

from evaluate_hierarchical_onnx import infer_onnx
from train_hierarchical_classifier import calculate_metrics, final_predictions, load_jsonl


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", type=Path, required=True)
    parser.add_argument("--data-dir", type=Path, required=True)
    args = parser.parse_args()
    run_dir = args.run.resolve()
    checkpoint = run_dir / "best_checkpoint"
    metadata = json.loads((checkpoint / "hierarchical_config.json").read_text(encoding="utf-8"))
    tokenizer = AutoTokenizer.from_pretrained(checkpoint)
    rows = load_jsonl(args.data_dir.resolve() / "safety_adversarial_test.jsonl")
    variants = {
        "fp32": {
            "model": run_dir / "onnx" / "hierarchical_nlu.fp32.onnx",
            "thresholds": metadata["thresholds"],
        },
        "hybrid_int8": {
            "model": run_dir / "onnx" / "hierarchical_nlu.hybrid_int8.onnx",
            "report": run_dir / "onnx" / "evaluation_hierarchical_nlu.hybrid_int8.json",
        },
        "full_int8_experimental": {
            "model": run_dir / "onnx" / "hierarchical_nlu.full_int8_experimental.onnx",
            "report": run_dir / "onnx" / "evaluation_hierarchical_nlu.full_int8_experimental.json",
        },
    }
    output = {"samples": len(rows), "variants": {}}
    for name, variant in variants.items():
        thresholds = variant.get("thresholds")
        if thresholds is None:
            thresholds = json.loads(variant["report"].read_text(encoding="utf-8"))["thresholds"]
        session = ort.InferenceSession(str(variant["model"]), providers=["CPUExecutionProvider"])
        route_probs, intent_probs = infer_onnx(
            session, rows, tokenizer, int(metadata["max_length"]), 100
        )
        predictions, rules = final_predictions(
            rows,
            route_probs,
            intent_probs,
            metadata["route_labels"],
            metadata["intent_labels"],
            thresholds,
        )
        metrics = calculate_metrics(rows, predictions, rules, metadata["final_labels"], 0.0)
        output["variants"][name] = {
            "accuracy": metrics["accuracy"],
            "unknown_false_accept_count": metrics["unknown_false_accept_count"],
            "unknown_to_control_count": metrics["unknown_to_control_count"],
            "requires_confirmation_bypass_count": metrics[
                "requires_confirmation_bypass_count"
            ],
            "cancelled_control_execution_count": metrics[
                "cancelled_control_execution_count"
            ],
            "positive_control_block_count": metrics["positive_control_block_count"],
            "hard_rule_coverage_rate": metrics["hard_rule_coverage_rate"],
        }
    path = run_dir / "onnx" / "final_safety_gate_evaluation.json"
    path.write_text(json.dumps(output, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(output, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
