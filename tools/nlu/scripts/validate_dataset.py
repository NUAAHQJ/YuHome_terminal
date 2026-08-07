#!/usr/bin/env python3
"""Validate YuHome NLU schema, leakage, balance, safety and slot rules."""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DATA = ROOT / "data" / "generated"
SPLITS = ("train", "validation", "test", "asr_noise_test", "boundary_test")
PRIMARY_SPLITS = ("train", "validation", "test")
ALLOWED_SLOT_KEYS = {"device", "room", "power", "percentage", "temperature", "mode", "query_attribute"}

sys.path.insert(0, str(Path(__file__).resolve().parent))
from slot_rules import extract_slots, validate_slots  # noqa: E402


def normalized_key(text: str) -> str:
    return re.sub(r"[\s，。！？、,.!?]", "", text).lower()


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            try:
                row = json.loads(line)
            except json.JSONDecodeError as exc:
                raise AssertionError(f"{path.name}:{line_number}: invalid JSON: {exc}") from exc
            rows.append(row)
    return rows


def validate(data_dir: Path) -> dict[str, Any]:
    labels_payload = json.loads((ROOT / "configs" / "labels.json").read_text(encoding="utf-8"))
    labels = labels_payload["labels"]
    label_set = set(labels)
    if len(labels) != len(label_set):
        raise AssertionError("labels.json contains duplicate labels")

    datasets = {split: load_jsonl(data_dir / f"{split}.jsonl") for split in SPLITS}
    text_owner: dict[str, str] = {}
    family_owner: dict[str, str] = {}
    slot_total = 0
    slot_exact = 0
    slot_value_total = 0
    slot_value_correct = 0
    errors: list[str] = []

    for split, rows in datasets.items():
        ids: set[str] = set()
        for row_index, row in enumerate(rows):
            required = {"id", "text", "intent", "family_id", "source", "slots", "slot_valid"}
            missing = required.difference(row)
            if missing:
                errors.append(f"{split}[{row_index}] missing {sorted(missing)}")
                continue
            if row["id"] in ids:
                errors.append(f"{split}: duplicate id {row['id']}")
            ids.add(row["id"])
            if row["intent"] not in label_set:
                errors.append(f"{row['id']}: unknown intent {row['intent']}")
            if not isinstance(row["text"], str) or not row["text"].strip():
                errors.append(f"{row['id']}: empty text")
                continue
            if not isinstance(row["slots"], dict):
                errors.append(f"{row['id']}: slots must be an object")
                continue
            unknown_slot_keys = set(row["slots"]).difference(ALLOWED_SLOT_KEYS)
            if unknown_slot_keys:
                errors.append(f"{row['id']}: unsupported slot keys {sorted(unknown_slot_keys)}")

            key = normalized_key(row["text"])
            previous_split = text_owner.get(key)
            if previous_split is not None and previous_split != split:
                errors.append(f"text leakage: {row['text']!r} in {previous_split} and {split}")
            text_owner[key] = split

            if split in PRIMARY_SPLITS:
                previous_family_split = family_owner.get(row["family_id"])
                if previous_family_split is not None and previous_family_split != split:
                    errors.append(
                        f"family leakage: {row['family_id']} in {previous_family_split} and {split}"
                    )
                family_owner[row["family_id"]] = split

            predicted_slots = extract_slots(row["text"], row["intent"])
            expected_slots = row["slots"]
            slot_total += 1
            exact = True
            for key_name, expected_value in expected_slots.items():
                slot_value_total += 1
                if predicted_slots.get(key_name) == expected_value:
                    slot_value_correct += 1
                else:
                    exact = False
            if set(predicted_slots) != set(expected_slots):
                exact = False
            if exact:
                slot_exact += 1
            actual_valid = validate_slots(row["intent"], predicted_slots)
            if actual_valid != row["slot_valid"]:
                errors.append(
                    f"{row['id']}: slot_valid expected={row['slot_valid']} actual={actual_valid} "
                    f"text={row['text']!r} slots={predicted_slots}"
                )

    for split in PRIMARY_SPLITS:
        counts = Counter(row["intent"] for row in datasets[split])
        missing_labels = label_set.difference(counts)
        if missing_labels:
            errors.append(f"{split}: missing labels {sorted(missing_labels)}")
        minimum = 80 if split == "train" else 15
        too_small = {label: count for label, count in counts.items() if count < minimum}
        if too_small:
            errors.append(f"{split}: class counts below {minimum}: {too_small}")

    if len(datasets["asr_noise_test"]) < 80:
        errors.append("asr_noise_test must contain at least 80 samples")
    if not any(row["text"].find("客厅都") >= 0 for row in datasets["train"]):
        errors.append("training set must include the observed ASR error 客厅灯 -> 客厅都")
    if not any(row["slot_valid"] is False for row in datasets["boundary_test"]):
        errors.append("boundary_test must contain invalid slot ranges")

    if errors:
        preview = "\n".join(f"- {message}" for message in errors[:50])
        suffix = f"\n... and {len(errors) - 50} more" if len(errors) > 50 else ""
        raise AssertionError(f"dataset validation failed ({len(errors)} errors):\n{preview}{suffix}")

    summary: dict[str, Any] = {
        "splits": {},
        "slot_exact_accuracy": slot_exact / slot_total if slot_total else 0.0,
        "slot_value_accuracy": slot_value_correct / slot_value_total if slot_value_total else 0.0,
    }
    for split, rows in datasets.items():
        summary["splits"][split] = {
            "samples": len(rows),
            "families": len({row["family_id"] for row in rows}),
            "intent_counts": dict(sorted(Counter(row["intent"] for row in rows).items())),
        }
    return summary


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-dir", type=Path, default=DEFAULT_DATA)
    args = parser.parse_args()
    summary = validate(args.data_dir.resolve())
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    print("dataset validation: PASS")


if __name__ == "__main__":
    main()
