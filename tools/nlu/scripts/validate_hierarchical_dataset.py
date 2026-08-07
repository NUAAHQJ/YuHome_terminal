#!/usr/bin/env python3
"""Validate hierarchical labels, split isolation and hard safety routing."""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DATA = ROOT / "data" / "hierarchical_v1"
SPLITS = (
    "train",
    "validation",
    "test",
    "asr_noise_test",
    "boundary_test",
    "safety_adversarial_test",
)

sys.path.insert(0, str(Path(__file__).resolve().parent))
from hierarchical_rules import hard_route  # noqa: E402
from validate_dataset import load_jsonl  # noqa: E402


def normalized_key(text: str) -> str:
    return re.sub(r"[\s，。！？、,.!?；;：:]", "", text).lower()


def expected_route(intent: str) -> str:
    if intent in ("unknown", "requires_confirmation"):
        return intent
    return "in_domain"


def validate(data_dir: Path) -> dict[str, Any]:
    label_config = json.loads((ROOT / "configs" / "hierarchical_labels.json").read_text(encoding="utf-8"))
    final_labels = set(label_config["final_labels"])
    planner_goal_labels = {
        "comfort_warmer", "comfort_cooler", "sleep_scene", "away_scene", "home_scene"
    }
    route_labels = set(label_config["route_labels"])
    datasets = {split: load_jsonl(data_dir / f"{split}.jsonl") for split in SPLITS}
    errors: list[str] = []
    text_owner: dict[str, str] = {}
    family_owner: dict[str, str] = {}
    hard_rule_total = 0
    hard_rule_correct = 0
    hard_route_counts: Counter[str] = Counter()

    for split, rows in datasets.items():
        for index, row in enumerate(rows):
            row_id = row.get("id", f"{split}[{index}]")
            required = {"route", "safety_case", "hard_rule_expected"}
            missing = required.difference(row)
            if missing:
                errors.append(f"{row_id}: missing hierarchical fields {sorted(missing)}")
                continue
            if row["intent"] not in final_labels:
                errors.append(f"{row_id}: invalid final intent {row['intent']}")
            if row["route"] not in route_labels:
                errors.append(f"{row_id}: invalid route {row['route']}")
            if row["route"] != expected_route(row["intent"]):
                errors.append(f"{row_id}: route {row['route']} disagrees with intent {row['intent']}")
            if row["intent"] in planner_goal_labels and row.get("slots") != {"goal": row["intent"]}:
                errors.append(f"{row_id}: planner goal must carry its matching goal slot")

            text_key = normalized_key(row["text"])
            previous = text_owner.get(text_key)
            if previous is not None and previous != split:
                errors.append(f"{row_id}: text leakage between {previous} and {split}")
            text_owner[text_key] = split

            if split in ("train", "validation", "test"):
                previous = family_owner.get(row["family_id"])
                if previous is not None and previous != split:
                    errors.append(f"{row_id}: family leakage between {previous} and {split}")
                family_owner[row["family_id"]] = split

            decision = hard_route(row["text"])
            expected = row["hard_rule_expected"]
            if expected is not None:
                hard_rule_total += 1
                if decision is not None and decision.intent == expected:
                    hard_rule_correct += 1
                    hard_route_counts[decision.rule] += 1
                else:
                    errors.append(
                        f"{row_id}: hard rule expected {expected}, got "
                        f"{None if decision is None else decision.intent}: {row['text']}"
                    )
            elif decision is not None and decision.intent != row["intent"]:
                errors.append(
                    f"{row_id}: hard rule overrode {row['intent']} with {decision.intent}: {row['text']}"
                )

    safety_rows = datasets["safety_adversarial_test"]
    safety_counts = Counter(row["safety_case"] for row in safety_rows)
    if safety_counts["cancelled_control"] < 40:
        errors.append("safety_adversarial_test requires at least 40 cancelled controls")
    if safety_counts["sensitive_action"] < 40:
        errors.append("safety_adversarial_test requires at least 40 sensitive actions")
    if hard_rule_total == 0 or hard_rule_correct != hard_rule_total:
        errors.append(f"hard-rule exact coverage is {hard_rule_correct}/{hard_rule_total}")

    if errors:
        preview = "\n".join(f"- {message}" for message in errors[:80])
        suffix = f"\n... and {len(errors) - 80} more" if len(errors) > 80 else ""
        raise AssertionError(f"hierarchical dataset validation failed ({len(errors)} errors):\n{preview}{suffix}")

    return {
        "splits": {
            split: {
                "samples": len(rows),
                "intent_counts": dict(sorted(Counter(row["intent"] for row in rows).items())),
            }
            for split, rows in datasets.items()
        },
        "safety_adversarial_samples": len(safety_rows),
        "safety_case_counts": dict(sorted(safety_counts.items())),
        "hard_rule_exact_accuracy": hard_rule_correct / hard_rule_total,
        "hard_rule_cases": hard_rule_total,
        "hard_rule_counts": dict(sorted(hard_route_counts.items())),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-dir", type=Path, default=DEFAULT_DATA)
    args = parser.parse_args()
    report = validate(args.data_dir.resolve())
    print(json.dumps(report, ensure_ascii=False, indent=2))
    print("hierarchical dataset validation: PASS")


if __name__ == "__main__":
    main()
