#!/usr/bin/env python3
"""Export a trained YuHome intent classifier to FP32 and dynamic INT8 ONNX."""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import time
from pathlib import Path
from typing import Any

import numpy as np
import onnx
import onnxruntime as ort
import torch
from onnxruntime.quantization import QuantType, quantize_dynamic
from transformers import AutoModelForSequenceClassification, AutoTokenizer


ROOT = Path(__file__).resolve().parents[1]


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def json_dump(path: Path, payload: Any) -> None:
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


class ClassifierWrapper(torch.nn.Module):
    def __init__(self, model: torch.nn.Module, include_token_type_ids: bool) -> None:
        super().__init__()
        self.model = model
        self.include_token_type_ids = include_token_type_ids

    def forward(
        self,
        input_ids: torch.Tensor,
        attention_mask: torch.Tensor,
        token_type_ids: torch.Tensor | None = None,
    ) -> torch.Tensor:
        if self.include_token_type_ids:
            return self.model(
                input_ids=input_ids,
                attention_mask=attention_mask,
                token_type_ids=token_type_ids,
            ).logits
        return self.model(input_ids=input_ids, attention_mask=attention_mask).logits


def compare_runtime(
    model: torch.nn.Module,
    tokenizer: Any,
    model_path: Path,
    samples: list[str],
    max_length: int,
) -> dict[str, Any]:
    session = ort.InferenceSession(str(model_path), providers=["CPUExecutionProvider"])
    input_names = {item.name for item in session.get_inputs()}
    encoded = tokenizer(
        samples,
        padding=True,
        truncation=True,
        max_length=max_length,
        return_tensors="pt",
    )
    with torch.inference_mode():
        torch_logits = model(**encoded).logits.cpu().numpy()
    ort_inputs = {
        name: encoded[name].cpu().numpy().astype(np.int64)
        for name in input_names
    }
    started = time.perf_counter()
    ort_logits = session.run(["logits"], ort_inputs)[0]
    elapsed_ms = (time.perf_counter() - started) * 1000
    return {
        "samples": len(samples),
        "max_abs_logit_difference": float(np.max(np.abs(torch_logits - ort_logits))),
        "mean_abs_logit_difference": float(np.mean(np.abs(torch_logits - ort_logits))),
        "prediction_agreement": float(np.mean(torch_logits.argmax(axis=1) == ort_logits.argmax(axis=1))),
        "batch_latency_ms": elapsed_ms,
        "providers": session.get_providers(),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", type=Path, required=True, help="Training run directory")
    parser.add_argument("--opset", type=int, default=17)
    args = parser.parse_args()
    run_dir = args.run.resolve()
    checkpoint_dir = run_dir / "best_checkpoint"
    if not checkpoint_dir.exists():
        raise FileNotFoundError(f"Missing checkpoint: {checkpoint_dir}")
    config = json.loads((run_dir / "train_config.json").read_text(encoding="utf-8"))
    threshold = json.loads((run_dir / "confidence_threshold.json").read_text(encoding="utf-8"))["selected_threshold"]
    labels_payload = json.loads((run_dir / "labels.json").read_text(encoding="utf-8"))
    labels: list[str] = labels_payload["labels"]

    tokenizer = AutoTokenizer.from_pretrained(checkpoint_dir)
    model = AutoModelForSequenceClassification.from_pretrained(checkpoint_dir).eval()
    max_length = int(config["max_length"])
    dummy = tokenizer(
        "客厅灯现在开着吗",
        padding="max_length",
        truncation=True,
        max_length=max_length,
        return_tensors="pt",
    )
    include_token_type_ids = "token_type_ids" in dummy
    input_names = ["input_ids", "attention_mask"] + (["token_type_ids"] if include_token_type_ids else [])
    input_tensors = tuple(dummy[name] for name in input_names)
    dynamic_axes = {name: {0: "batch", 1: "sequence"} for name in input_names}
    dynamic_axes["logits"] = {0: "batch"}
    wrapper = ClassifierWrapper(model, include_token_type_ids).eval()

    onnx_dir = run_dir / "onnx"
    onnx_dir.mkdir(parents=True, exist_ok=True)
    fp32_path = onnx_dir / "intent_classifier.fp32.onnx"
    int8_path = onnx_dir / "intent_classifier.int8.onnx"
    torch.onnx.export(
        wrapper,
        input_tensors,
        fp32_path,
        input_names=input_names,
        output_names=["logits"],
        dynamic_axes=dynamic_axes,
        opset_version=args.opset,
        do_constant_folding=True,
        dynamo=False,
    )
    onnx.checker.check_model(onnx.load(str(fp32_path)))
    quantize_dynamic(
        model_input=str(fp32_path),
        model_output=str(int8_path),
        weight_type=QuantType.QInt8,
        per_channel=True,
    )
    onnx.checker.check_model(onnx.load(str(int8_path)))

    samples = [
        "打开客厅灯", "把空调调到二十四度", "窗帘现在开了多少", "门锁了吗",
        "请打开门", "今天想吃火锅", "客厅都给我关掉", "家里温度和湿度怎么样",
    ]
    fp32_comparison = compare_runtime(model, tokenizer, fp32_path, samples, max_length)
    int8_session = ort.InferenceSession(str(int8_path), providers=["CPUExecutionProvider"])
    encoded = tokenizer(samples, padding=True, truncation=True, max_length=max_length, return_tensors="np")
    int8_inputs = {
        item.name: encoded[item.name].astype(np.int64)
        for item in int8_session.get_inputs()
    }
    fp32_session = ort.InferenceSession(str(fp32_path), providers=["CPUExecutionProvider"])
    fp32_inputs = {
        item.name: encoded[item.name].astype(np.int64)
        for item in fp32_session.get_inputs()
    }
    fp32_logits = fp32_session.run(["logits"], fp32_inputs)[0]
    started = time.perf_counter()
    int8_logits = int8_session.run(["logits"], int8_inputs)[0]
    int8_ms = (time.perf_counter() - started) * 1000
    int8_comparison = {
        "samples": len(samples),
        "max_abs_logit_difference_vs_fp32": float(np.max(np.abs(fp32_logits - int8_logits))),
        "mean_abs_logit_difference_vs_fp32": float(np.mean(np.abs(fp32_logits - int8_logits))),
        "prediction_agreement_vs_fp32": float(np.mean(fp32_logits.argmax(axis=1) == int8_logits.argmax(axis=1))),
        "batch_latency_ms": int8_ms,
        "providers": int8_session.get_providers(),
    }
    comparison = {"fp32_vs_pytorch": fp32_comparison, "int8_vs_fp32": int8_comparison}
    json_dump(onnx_dir / "onnx_consistency.json", comparison)

    files = [fp32_path, int8_path]
    manifest = {
        "model_name": "yuhome_intent_classifier",
        "model_version": 1,
        "base_model": config["base_model"],
        "opset": args.opset,
        "max_length": max_length,
        "confidence_threshold": threshold,
        "labels": labels,
        "inputs": input_names,
        "output": "logits",
        "quantization": "dynamic_int8_weights",
        "python_version": platform.python_version(),
        "torch_version": torch.__version__,
        "onnx_version": onnx.__version__,
        "onnxruntime_version": ort.__version__,
        "files": {
            path.name: {"bytes": path.stat().st_size, "sha256": sha256_file(path)}
            for path in files
        },
        "consistency": comparison,
        "safety": {
            "rule_guard_before_model": True,
            "requires_confirmation_direct_execution_allowed": False,
            "fallback": "VoiceIntentParser",
        },
    }
    json_dump(onnx_dir / "model_manifest.json", manifest)
    print(json.dumps(manifest, ensure_ascii=False, indent=2))
    print(f"ONNX artifacts: {onnx_dir}")


if __name__ == "__main__":
    main()
