from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from slot_rules import extract_slots, validate_slots  # noqa: E402
from validate_dataset import validate  # noqa: E402


class SlotRuleTests(unittest.TestCase):
    def test_control_slots(self) -> None:
        self.assertEqual(
            extract_slots("请把客厅灯关掉", "light_set"),
            {"device": "light", "room": "living", "power": False},
        )
        self.assertEqual(
            extract_slots("空调调到二十四度", "ac_temperature_set"),
            {"device": "ac", "temperature": 24},
        )
        self.assertEqual(
            extract_slots("窗帘开到百分之75", "curtain_set"),
            {"device": "curtain", "room": "living", "percentage": 75},
        )

    def test_query_slots(self) -> None:
        self.assertEqual(
            extract_slots("空调现在是什么模式", "ac_status_query"),
            {"device": "ac", "query_attribute": "mode"},
        )
        self.assertEqual(
            extract_slots("家里湿度怎么样", "humidity_query"),
            {"device": "environment", "query_attribute": "humidity"},
        )

    def test_range_validation(self) -> None:
        self.assertTrue(validate_slots("ac_temperature_set", {"temperature": 16}))
        self.assertTrue(validate_slots("ac_temperature_set", {"temperature": 30}))
        self.assertFalse(validate_slots("ac_temperature_set", {"temperature": 15}))
        self.assertFalse(validate_slots("ac_temperature_set", {"temperature": 31}))
        self.assertTrue(validate_slots("curtain_set", {"percentage": 0}))
        self.assertTrue(validate_slots("curtain_set", {"percentage": 100}))
        self.assertFalse(validate_slots("curtain_set", {"percentage": 101}))


class DatasetTests(unittest.TestCase):
    def test_generated_dataset(self) -> None:
        summary = validate(ROOT / "data" / "generated")
        self.assertEqual(summary["slot_exact_accuracy"], 1.0)
        self.assertEqual(summary["slot_value_accuracy"], 1.0)
        self.assertGreaterEqual(summary["splits"]["asr_noise_test"]["samples"], 80)

    def test_sensitive_samples_never_use_control_labels(self) -> None:
        control_labels = {"light_set", "ac_power_set", "curtain_set", "ac_temperature_set", "ac_mode_set"}
        path = ROOT / "data" / "generated" / "test.jsonl"
        rows = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]
        sensitive = [row for row in rows if row["intent"] == "requires_confirmation"]
        self.assertGreaterEqual(len(sensitive), 15)
        self.assertTrue(all(row["intent"] not in control_labels for row in sensitive))


if __name__ == "__main__":
    unittest.main()
