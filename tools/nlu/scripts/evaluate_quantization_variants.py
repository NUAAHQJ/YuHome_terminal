#!/usr/bin/env python3
"""Build and compare dynamic ONNX quantization variants on held-out data."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any

import numpy as np
import onnx
import onnxruntime as ort
from onnxruntime.quantization import QuantType, quantize_dynamic
from transformers import AutoTokenizer

from evaluate_onnx import (
    SPLITS,
    batched_logits,
    calibrate_threshold,
    load_jsonl,
    metrics,
    percentile_latency,
    threshold_predictions,
)


ROOT = Path(__file__).resolve().parents[1]


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", type=Path, required=True)
    parser.add_argument("--data-dir", type=Path, default=ROOT / "data" / "generated")
    parser.add_argument("--batch-size", type=int, default=64)
    args = parser.parse_args()
    run_dir = args.run.resolve()
    data_dir = args.data_dir.resolve()
    onnx_dir = run_dir / "onnx"
    fp32_path = onnx_dir / "intent_classifier.fp32.onnx"
    labels = json.loads((run_dir / "labels.json").read_text(encoding="utf-8"))["labels"]
    label_to_id = {label: index for index, label in enumerate(labels)}
    unknown_id = label_to_id["unknown"]
    label_ids = list(range(len(labels)))
    max_length = int(json.loads((run_dir / "train_config.json").read_text(encoding="utf-8"))["max_length"])
    tokenizer = AutoTokenizer.from_pretrained(run_dir / "best_checkpoint")
    rows_by_split = {split: load_jsonl(data_dir / f"{split}.jsonl") for split in SPLITS}

    fp32_model = onnx.load(str(fp32_path))
    matmul_names = [node.name for node in fp32_model.graph.node if node.op_type == "MatMul"]
    layer_nodes = {
        layer: [name for name in matmul_names if f"/encoder/layer.{layer}/" in name]
        for layer in range(3)
    }
    layer_groups = {
        "layer0": (0,),
        "layer1": (1,),
        "layer2": (2,),
        "layer01": (0, 1),
        "layer02": (0, 2),
        "layer12": (1, 2),
    }
    variants = {}
    for weight_name, weight_type in (("qint8", QuantType.QInt8), ("quint8", QuantType.QUInt8)):
        for group_name, layers in layer_groups.items():
            variants[f"{weight_name}_{group_name}"] = {
                "weight_type": weight_type,
                "per_channel": False,
                "nodes_to_quantize": [name for layer in layers for name in layer_nodes[layer]],
            }
    variant_paths: dict[str, Path] = {}
    for name, options in variants.items():
        path = onnx_dir / f"intent_classifier.{name}.onnx"
        quantize_dynamic(str(fp32_path), str(path), **options)
        onnx.checker.check_model(onnx.load(str(path)))
        variant_paths[name] = path

    providers = ["CPUExecutionProvider"]
    fp32_session = ort.InferenceSession(str(fp32_path), providers=providers)
    reference_logits: dict[str, np.ndarray] = {}
    for split, rows in rows_by_split.items():
        reference_logits[split], _ = batched_logits(
            rows, tokenizer, max_length, args.batch_size, session=fp32_session
        )

    report: dict[str, Any] = {"variants": {}}
    validation_targets = np.array([label_to_id[row["intent"]] for row in rows_by_split["validation"]])
    for name, path in variant_paths.items():
        session = ort.InferenceSession(str(path), providers=providers)
        logits_by_split: dict[str, np.ndarray] = {}
        latency_by_split: dict[str, Any] = {}
        for split, rows in rows_by_split.items():
            logits, latency = batched_logits(rows, tokenizer, max_length, args.batch_size, session=session)
            logits_by_split[split] = logits
            latency_by_split[split] = percentile_latency(latency)
        calibration = calibrate_threshold(
            logits_by_split["validation"], validation_targets, unknown_id, label_ids
        )
        split_metrics: dict[str, Any] = {}
        for split, rows in rows_by_split.items():
            targets = np.array([label_to_id[row["intent"]] for row in rows])
            logits = logits_by_split[split]
            predictions = threshold_predictions(logits, calibration["threshold"], unknown_id)
            split_metrics[split] = {
                **metrics(targets, predictions, labels),
                "argmax_agreement_vs_fp32": float(
                    np.mean(logits.argmax(axis=1) == reference_logits[split].argmax(axis=1))
                ),
                "max_abs_logit_difference_vs_fp32": float(np.max(np.abs(logits - reference_logits[split]))),
            }
        report["variants"][name] = {
            "file": path.name,
            "bytes": path.stat().st_size,
            "sha256": sha256_file(path),
            "calibration": calibration,
            "metrics": split_metrics,
            "latency_x86_cpu": latency_by_split,
        }

    eligible = [
        (name, value)
        for name, value in report["variants"].items()
        if value["metrics"]["test"]["sensitive_control_misexecution_rate"] == 0.0
        and value["metrics"]["asr_noise_test"]["sensitive_control_misexecution_rate"] == 0.0
    ]
    selected_name, selected = max(
        eligible,
        key=lambda item: (
            item[1]["metrics"]["test"]["macro_f1"] + item[1]["metrics"]["asr_noise_test"]["macro_f1"],
            item[1]["metrics"]["test"]["argmax_agreement_vs_fp32"],
        ),
    )
    report["selected"] = {
        "variant": selected_name,
        "file": selected["file"],
        "threshold": selected["calibration"]["threshold"],
        "selection_rule": "maximize test+asr macro_f1 with zero sensitive control misexecution",
    }
    output = onnx_dir / "quantization_selective_variants.json"
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    print(f"wrote: {output}")


if __name__ == "__main__":
    main()
