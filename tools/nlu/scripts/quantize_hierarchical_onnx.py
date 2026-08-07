#!/usr/bin/env python3
"""Create conservative and experimental dynamic INT8 hierarchical ONNX files."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import onnx
from onnxruntime.quantization import QuantType, quantize_dynamic


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", type=Path, required=True)
    args = parser.parse_args()
    run_dir = args.run.resolve()
    onnx_dir = run_dir / "onnx"
    source = onnx_dir / "hierarchical_nlu.fp32.onnx"
    graph = onnx.load(str(source))
    matmul_names = [node.name for node in graph.graph.node if node.op_type == "MatMul"]
    selected_nodes = [
        name
        for name in matmul_names
        if "/encoder/layer.1/" in name or "/encoder/layer.2/" in name
    ]
    variants = {
        "hybrid_int8": {
            "path": onnx_dir / "hierarchical_nlu.hybrid_int8.onnx",
            "options": {
                "weight_type": QuantType.QUInt8,
                "per_channel": False,
                "nodes_to_quantize": selected_nodes,
            },
            "deploy_candidate": True,
            "description": "QUInt8 encoder layers 1 and 2; embeddings and layer 0 remain FP32",
        },
        "full_int8_experimental": {
            "path": onnx_dir / "hierarchical_nlu.full_int8_experimental.onnx",
            "options": {"weight_type": QuantType.QInt8, "per_channel": False},
            "deploy_candidate": False,
            "description": "Broad dynamic QInt8 experiment; must pass independent acceptance before use",
        },
    }
    report = {"source": source.name, "variants": {}}
    for name, variant in variants.items():
        path = variant["path"]
        quantize_dynamic(str(source), str(path), **variant["options"])
        onnx.checker.check_model(onnx.load(str(path)))
        report["variants"][name] = {
            "file": path.name,
            "bytes": path.stat().st_size,
            "sha256": sha256_file(path),
            "deploy_candidate": variant["deploy_candidate"],
            "description": variant["description"],
        }
    output = onnx_dir / "quantization_manifest.json"
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
