#!/usr/bin/env python3
"""Evaluate PyTorch, FP32 ONNX and INT8 ONNX on every held-out NLU split."""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path
from typing import Any

import numpy as np
import onnxruntime as ort
import torch
from sklearn.metrics import accuracy_score, f1_score
from transformers import AutoModelForSequenceClassification, AutoTokenizer


ROOT = Path(__file__).resolve().parents[1]
SPLITS = ("validation", "test", "asr_noise_test", "boundary_test")
CONTROL_LABELS = {"light_set", "ac_power_set", "curtain_set", "ac_temperature_set", "ac_mode_set"}


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def batched_logits(
    rows: list[dict[str, Any]],
    tokenizer: Any,
    max_length: int,
    batch_size: int,
    model: torch.nn.Module | None = None,
    session: ort.InferenceSession | None = None,
) -> tuple[np.ndarray, list[float]]:
    chunks: list[np.ndarray] = []
    latency_ms: list[float] = []
    session_inputs = {item.name for item in session.get_inputs()} if session is not None else set()
    for start in range(0, len(rows), batch_size):
        texts = [row["text"] for row in rows[start:start + batch_size]]
        encoded = tokenizer(
            texts,
            padding=True,
            truncation=True,
            max_length=max_length,
            return_tensors="np",
        )
        began = time.perf_counter()
        if session is not None:
            inputs = {name: encoded[name].astype(np.int64) for name in session_inputs}
            logits = session.run(["logits"], inputs)[0]
        elif model is not None:
            tensor_inputs = {name: torch.from_numpy(value) for name, value in encoded.items()}
            with torch.inference_mode():
                logits = model(**tensor_inputs).logits.cpu().numpy()
        else:
            raise ValueError("model or session is required")
        latency_ms.append((time.perf_counter() - began) * 1000)
        chunks.append(logits)
    return np.concatenate(chunks), latency_ms


def threshold_predictions(logits: np.ndarray, threshold: float, unknown_id: int) -> np.ndarray:
    shifted = logits - logits.max(axis=1, keepdims=True)
    probabilities = np.exp(shifted)
    probabilities /= probabilities.sum(axis=1, keepdims=True)
    predictions = probabilities.argmax(axis=1)
    return np.where(probabilities.max(axis=1) >= threshold, predictions, unknown_id)


def calibrate_threshold(logits: np.ndarray, targets: np.ndarray, unknown_id: int, label_ids: list[int]) -> dict[str, float]:
    candidates: list[tuple[float, float]] = []
    for threshold in np.arange(0.25, 0.901, 0.01):
        predictions = threshold_predictions(logits, float(threshold), unknown_id)
        score = f1_score(targets, predictions, labels=label_ids, average="macro", zero_division=0)
        candidates.append((float(score), float(round(threshold, 2))))
    score, threshold = max(candidates, key=lambda item: (item[0], item[1]))
    return {"threshold": threshold, "validation_macro_f1": score}


def metrics(targets: np.ndarray, predictions: np.ndarray, labels: list[str]) -> dict[str, float]:
    ids = list(range(len(labels)))
    label_to_id = {label: index for index, label in enumerate(labels)}
    unknown_id = label_to_id["unknown"]
    sensitive_id = label_to_id["requires_confirmation"]
    control_ids = [label_to_id[label] for label in CONTROL_LABELS]
    unknown_mask = targets == unknown_id
    sensitive_mask = targets == sensitive_id
    return {
        "accuracy": float(accuracy_score(targets, predictions)),
        "macro_f1": float(f1_score(targets, predictions, labels=ids, average="macro", zero_division=0)),
        "unknown_false_accept_rate": float(np.mean(predictions[unknown_mask] != unknown_id)) if unknown_mask.any() else 0.0,
        "requires_confirmation_miss_rate": float(np.mean(predictions[sensitive_mask] != sensitive_id)) if sensitive_mask.any() else 0.0,
        "sensitive_control_misexecution_rate": float(np.mean(np.isin(predictions[sensitive_mask], control_ids))) if sensitive_mask.any() else 0.0,
    }


def percentile_latency(values: list[float]) -> dict[str, float]:
    return {
        "batches": len(values),
        "p50_ms": float(np.percentile(values, 50)),
        "p95_ms": float(np.percentile(values, 95)),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", type=Path, required=True)
    parser.add_argument("--data-dir", type=Path, default=ROOT / "data" / "generated")
    parser.add_argument("--batch-size", type=int, default=64)
    args = parser.parse_args()
    run_dir = args.run.resolve()
    data_dir = args.data_dir.resolve()
    checkpoint = run_dir / "best_checkpoint"
    onnx_dir = run_dir / "onnx"
    config = json.loads((run_dir / "train_config.json").read_text(encoding="utf-8"))
    labels = json.loads((run_dir / "labels.json").read_text(encoding="utf-8"))["labels"]
    label_to_id = {label: index for index, label in enumerate(labels)}
    unknown_id = label_to_id["unknown"]
    label_ids = list(range(len(labels)))
    rows_by_split = {split: load_jsonl(data_dir / f"{split}.jsonl") for split in SPLITS}

    tokenizer = AutoTokenizer.from_pretrained(checkpoint)
    model = AutoModelForSequenceClassification.from_pretrained(checkpoint).eval()
    providers = ["CPUExecutionProvider"]
    fp32_session = ort.InferenceSession(str(onnx_dir / "intent_classifier.fp32.onnx"), providers=providers)
    int8_session = ort.InferenceSession(str(onnx_dir / "intent_classifier.int8.onnx"), providers=providers)
    max_length = int(config["max_length"])

    logits_by_runtime: dict[str, dict[str, np.ndarray]] = {name: {} for name in ("pytorch", "fp32", "int8")}
    latencies: dict[str, dict[str, Any]] = {name: {} for name in logits_by_runtime}
    for split, rows in rows_by_split.items():
        pytorch_logits, pytorch_ms = batched_logits(rows, tokenizer, max_length, args.batch_size, model=model)
        fp32_logits, fp32_ms = batched_logits(rows, tokenizer, max_length, args.batch_size, session=fp32_session)
        int8_logits, int8_ms = batched_logits(rows, tokenizer, max_length, args.batch_size, session=int8_session)
        logits_by_runtime["pytorch"][split] = pytorch_logits
        logits_by_runtime["fp32"][split] = fp32_logits
        logits_by_runtime["int8"][split] = int8_logits
        latencies["pytorch"][split] = percentile_latency(pytorch_ms)
        latencies["fp32"][split] = percentile_latency(fp32_ms)
        latencies["int8"][split] = percentile_latency(int8_ms)

    calibration = {
        runtime: calibrate_threshold(logits["validation"], np.array([
            label_to_id[row["intent"]] for row in rows_by_split["validation"]
        ]), unknown_id, label_ids)
        for runtime, logits in logits_by_runtime.items()
    }
    result: dict[str, Any] = {"calibration": calibration, "splits": {}, "latency_x86_cpu": latencies}
    for split, rows in rows_by_split.items():
        targets = np.array([label_to_id[row["intent"]] for row in rows])
        split_result: dict[str, Any] = {}
        for runtime, logits_by_split in logits_by_runtime.items():
            logits = logits_by_split[split]
            predictions = threshold_predictions(logits, calibration[runtime]["threshold"], unknown_id)
            split_result[runtime] = metrics(targets, predictions, labels)
        pytorch_logits = logits_by_runtime["pytorch"][split]
        fp32_logits = logits_by_runtime["fp32"][split]
        int8_logits = logits_by_runtime["int8"][split]
        split_result["agreement"] = {
            "fp32_vs_pytorch_argmax": float(np.mean(fp32_logits.argmax(axis=1) == pytorch_logits.argmax(axis=1))),
            "int8_vs_fp32_argmax": float(np.mean(int8_logits.argmax(axis=1) == fp32_logits.argmax(axis=1))),
            "fp32_vs_pytorch_max_abs_logit_difference": float(np.max(np.abs(fp32_logits - pytorch_logits))),
            "int8_vs_fp32_max_abs_logit_difference": float(np.max(np.abs(int8_logits - fp32_logits))),
        }
        result["splits"][split] = split_result

    output = onnx_dir / "onnx_full_evaluation.json"
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    print(f"wrote: {output}")


if __name__ == "__main__":
    main()
