#!/usr/bin/env python3
"""Export a hierarchical YuHome checkpoint to ONNX and verify logits."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any

import numpy as np
import onnx
import onnxruntime as ort
import torch
from transformers import AutoTokenizer

from hierarchical_model import load_hierarchical_checkpoint


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    with path.open("r", encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", type=Path, required=True)
    parser.add_argument("--data-dir", type=Path, required=True)
    parser.add_argument("--batch-size", type=int, default=64)
    args = parser.parse_args()
    run_dir = args.run.resolve()
    data_dir = args.data_dir.resolve()
    checkpoint = run_dir / "best_checkpoint"
    onnx_dir = run_dir / "onnx"
    onnx_dir.mkdir(parents=True, exist_ok=True)
    output = onnx_dir / "hierarchical_nlu.fp32.onnx"

    device = torch.device("cpu")
    model, metadata = load_hierarchical_checkpoint(checkpoint, device)
    model.eval()
    tokenizer = AutoTokenizer.from_pretrained(checkpoint)
    encoded = tokenizer(
        ["打开客厅灯", "家门锁给我打开", "启动空调还是算了"],
        padding="max_length",
        truncation=True,
        max_length=int(metadata["max_length"]),
        return_tensors="pt",
    )
    input_names = ["input_ids", "attention_mask", "token_type_ids"]
    inputs = tuple(encoded[name] for name in input_names)
    dynamic_axes = {
        name: {0: "batch", 1: "sequence"} for name in input_names
    }
    dynamic_axes.update(
        {"route_logits": {0: "batch"}, "intent_logits": {0: "batch"}}
    )
    torch.onnx.export(
        model,
        inputs,
        str(output),
        input_names=input_names,
        output_names=["route_logits", "intent_logits"],
        dynamic_axes=dynamic_axes,
        opset_version=17,
        do_constant_folding=True,
    )
    onnx.checker.check_model(onnx.load(str(output)))

    session = ort.InferenceSession(str(output), providers=["CPUExecutionProvider"])
    rows = load_jsonl(data_dir / "validation.jsonl")
    max_route_diff = 0.0
    max_intent_diff = 0.0
    route_agreement: list[bool] = []
    intent_agreement: list[bool] = []
    for start in range(0, len(rows), args.batch_size):
        batch = rows[start : start + args.batch_size]
        tokens = tokenizer(
            [row["text"] for row in batch],
            padding="max_length",
            truncation=True,
            max_length=int(metadata["max_length"]),
            return_tensors="pt",
        )
        with torch.inference_mode():
            torch_route, torch_intent = model(**{name: tokens[name] for name in input_names})
        ort_route, ort_intent = session.run(
            None, {name: tokens[name].numpy() for name in input_names}
        )
        torch_route_np = torch_route.numpy()
        torch_intent_np = torch_intent.numpy()
        max_route_diff = max(max_route_diff, float(np.max(np.abs(torch_route_np - ort_route))))
        max_intent_diff = max(max_intent_diff, float(np.max(np.abs(torch_intent_np - ort_intent))))
        route_agreement.extend((torch_route_np.argmax(1) == ort_route.argmax(1)).tolist())
        intent_agreement.extend((torch_intent_np.argmax(1) == ort_intent.argmax(1)).tolist())

    report = {
        "file": output.name,
        "bytes": output.stat().st_size,
        "sha256": sha256_file(output),
        "opset": 17,
        "validation_samples": len(rows),
        "route_argmax_agreement": float(np.mean(route_agreement)),
        "intent_argmax_agreement": float(np.mean(intent_agreement)),
        "max_abs_route_logit_difference": max_route_diff,
        "max_abs_intent_logit_difference": max_intent_diff,
    }
    (onnx_dir / "onnx_consistency.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
