#!/usr/bin/env python3
"""Shared two-head Transformer model for hierarchical YuHome NLU."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import torch
from safetensors.torch import load_file, save_file
from torch import nn
from transformers import AutoConfig, AutoModel


class HierarchicalNLUModel(nn.Module):
    def __init__(self, encoder: nn.Module, route_count: int, intent_count: int, dropout: float) -> None:
        super().__init__()
        self.encoder = encoder
        hidden_size = int(encoder.config.hidden_size)
        self.dropout = nn.Dropout(dropout)
        self.route_classifier = nn.Linear(hidden_size, route_count)
        self.intent_classifier = nn.Linear(hidden_size, intent_count)

    @classmethod
    def from_pretrained(
        cls,
        model_name_or_path: str | Path,
        route_count: int,
        intent_count: int,
        dropout: float | None = None,
        cache_dir: str | Path | None = None,
    ) -> "HierarchicalNLUModel":
        encoder = AutoModel.from_pretrained(str(model_name_or_path), cache_dir=cache_dir)
        resolved_dropout = float(
            dropout if dropout is not None else getattr(encoder.config, "hidden_dropout_prob", 0.1)
        )
        return cls(encoder, route_count, intent_count, resolved_dropout)

    def forward(
        self,
        input_ids: torch.Tensor,
        attention_mask: torch.Tensor,
        token_type_ids: torch.Tensor | None = None,
    ) -> tuple[torch.Tensor, torch.Tensor]:
        kwargs: dict[str, torch.Tensor] = {
            "input_ids": input_ids,
            "attention_mask": attention_mask,
        }
        if token_type_ids is not None:
            kwargs["token_type_ids"] = token_type_ids
        outputs = self.encoder(**kwargs)
        pooled = self.dropout(outputs.last_hidden_state[:, 0])
        return self.route_classifier(pooled), self.intent_classifier(pooled)


def save_hierarchical_checkpoint(
    model: HierarchicalNLUModel,
    tokenizer: Any,
    output: Path,
    metadata: dict[str, Any],
) -> None:
    output.mkdir(parents=True, exist_ok=True)
    encoder_dir = output / "encoder"
    model.encoder.save_pretrained(encoder_dir, safe_serialization=True)
    tokenizer.save_pretrained(output)
    head_tensors = {
        "route_classifier.weight": model.route_classifier.weight.detach().cpu().contiguous(),
        "route_classifier.bias": model.route_classifier.bias.detach().cpu().contiguous(),
        "intent_classifier.weight": model.intent_classifier.weight.detach().cpu().contiguous(),
        "intent_classifier.bias": model.intent_classifier.bias.detach().cpu().contiguous(),
    }
    save_file(head_tensors, output / "classification_heads.safetensors")
    (output / "hierarchical_config.json").write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )


def load_hierarchical_checkpoint(checkpoint: Path, device: torch.device) -> tuple[HierarchicalNLUModel, dict[str, Any]]:
    metadata = json.loads((checkpoint / "hierarchical_config.json").read_text(encoding="utf-8"))
    config = AutoConfig.from_pretrained(checkpoint / "encoder")
    encoder = AutoModel.from_pretrained(checkpoint / "encoder", config=config)
    model = HierarchicalNLUModel(
        encoder,
        len(metadata["route_labels"]),
        len(metadata["intent_labels"]),
        float(metadata["dropout"]),
    )
    heads = load_file(checkpoint / "classification_heads.safetensors")
    model.route_classifier.load_state_dict(
        {"weight": heads["route_classifier.weight"], "bias": heads["route_classifier.bias"]}
    )
    model.intent_classifier.load_state_dict(
        {"weight": heads["intent_classifier.weight"], "bias": heads["intent_classifier.bias"]}
    )
    return model.to(device), metadata

