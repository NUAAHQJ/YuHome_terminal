from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from hierarchical_rules import hard_route, normalize_for_model  # noqa: E402
from validate_hierarchical_dataset import validate  # noqa: E402


class HardRouteTests(unittest.TestCase):
    def assert_route(self, text: str, expected: str | None) -> None:
        decision = hard_route(text)
        self.assertEqual(expected, None if decision is None else decision.intent, text)

    def test_observed_cancellation_failures(self) -> None:
        self.assert_route("停止准备启动大厅冷气", "unknown")
        self.assert_route("停止准备窗帘全部关闭", "unknown")
        self.assert_route("启动大厅冷气还是算了", "unknown")

    def test_sensitive_actions_and_asr(self) -> None:
        self.assert_route("替我把入户门打开行不行", "requires_confirmation")
        self.assert_route("让门进开门行不行", "requires_confirmation")
        self.assert_route("家门所给我松开行不行", "requires_confirmation")
        self.assert_route("取消家门所定行不行", "requires_confirmation")

    def test_queries_and_regular_controls_are_not_blocked(self) -> None:
        self.assert_route("请看一下门锁是不是解锁了", "door_status_query")
        self.assert_route("查询一下家门锁状态", "door_status_query")
        self.assert_route("门禁现在是否正常", "door_status_query")
        self.assert_route("停止空调运行", None)
        self.assert_route("关闭客厅灯", None)

    def test_explicit_out_of_domain_scope(self) -> None:
        self.assert_route("看看地下室灯亮不亮", "unknown")
        self.assert_route("打开卧室顶灯", "unknown")
        self.assert_route("启动空气净化器", "unknown")
        self.assert_route("帮我订一张车票", "unknown")
        self.assert_route("空调用了多久", "unknown")
        self.assert_route("卧室门是不是关了", "unknown")
        self.assert_route("车库门开着没有", "unknown")

    def test_narrow_asr_normalization(self) -> None:
        self.assertEqual("大厅冷气给我开开", normalize_for_model("大厅冷器给我开开"))
        self.assertEqual("家中环境正常吗", normalize_for_model("家中环静正常吗"))
        self.assertEqual("屋里灯光给我开开", normalize_for_model("屋里等光给我开开"))


class HierarchicalDatasetTests(unittest.TestCase):
    def test_generated_dataset(self) -> None:
        report = validate(ROOT / "data" / "hierarchical_v1")
        self.assertEqual(1.0, report["hard_rule_exact_accuracy"])
        self.assertGreaterEqual(report["safety_adversarial_samples"], 100)

    def test_routes_match_intents(self) -> None:
        labels = json.loads(
            (ROOT / "configs" / "hierarchical_labels.json").read_text(encoding="utf-8")
        )
        intent_labels = set(labels["intent_labels"])
        for split in ("train", "validation", "test", "asr_noise_test", "safety_adversarial_test"):
            with (ROOT / "data" / "hierarchical_v1" / f"{split}.jsonl").open(
                encoding="utf-8"
            ) as handle:
                for line in handle:
                    row = json.loads(line)
                    expected = row["intent"] if row["intent"] not in intent_labels else "in_domain"
                    self.assertEqual(expected, row["route"])


if __name__ == "__main__":
    unittest.main()
