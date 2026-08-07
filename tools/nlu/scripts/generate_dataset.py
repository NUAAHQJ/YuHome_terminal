#!/usr/bin/env python3
"""Generate deterministic, family-disjoint YuHome NLU datasets."""

from __future__ import annotations

import argparse
import hashlib
import itertools
import json
import random
import re
from collections import Counter
from pathlib import Path
from typing import Any, Callable, Iterable


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = ROOT / "data" / "generated"
PRIMARY_SPLITS = ("train", "validation", "test")
ALL_SPLITS = PRIMARY_SPLITS + ("asr_noise_test", "boundary_test")
SEED = 20260802


def normalized_key(text: str) -> str:
    return re.sub(r"[\s，。！？、,.!?]", "", text).lower()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


class DatasetBuilder:
    def __init__(self, labels: list[str]) -> None:
        self.labels = set(labels)
        self.rows: dict[str, list[dict[str, Any]]] = {name: [] for name in ALL_SPLITS}
        self.seen: dict[str, str] = {}

    def add(
        self,
        split: str,
        intent: str,
        text: str,
        family_id: str,
        slots: dict[str, Any] | None = None,
        source: str = "template",
        slot_valid: bool = True,
    ) -> None:
        text = re.sub(r"\s+", "", text).strip()
        if not text:
            return
        if split not in self.rows:
            raise ValueError(f"Unknown split: {split}")
        if intent not in self.labels:
            raise ValueError(f"Unknown intent: {intent}")
        key = normalized_key(text)
        previous = self.seen.get(key)
        if previous is not None:
            if previous != split:
                raise ValueError(f"Text leaks across splits: {text!r} ({previous} -> {split})")
            return
        self.seen[key] = split
        self.rows[split].append(
            {
                "text": text,
                "intent": intent,
                "family_id": family_id,
                "source": source,
                "slots": slots or {},
                "slot_valid": slot_valid,
            }
        )

    def grid(
        self,
        split: str,
        intent: str,
        family: str,
        patterns: Iterable[str],
        fields: dict[str, Iterable[Any]],
        slots: Callable[[dict[str, Any]], dict[str, Any]],
        source: str = "template",
        limit_per_pattern: int | None = None,
    ) -> None:
        names = list(fields)
        values = [list(fields[name]) for name in names]
        combinations = [dict(zip(names, values_tuple)) for values_tuple in itertools.product(*values)]
        for pattern_index, pattern in enumerate(patterns):
            candidates = list(combinations)
            rng = random.Random(f"{SEED}:{split}:{intent}:{family}:{pattern_index}")
            rng.shuffle(candidates)
            if limit_per_pattern is not None:
                candidates = candidates[:limit_per_pattern]
            for values_map in candidates:
                text = pattern.format(**values_map)
                self.add(
                    split,
                    intent,
                    text,
                    f"{intent}/{split}/{family}_{pattern_index}",
                    slots(values_map),
                    source,
                )


def prefixes(split: str) -> list[str]:
    return {
        "train": ["", "请", "麻烦", "小禹"],
        "validation": ["", "帮忙"],
        "test": ["", "劳驾"],
    }[split]


def build_control_data(builder: DatasetBuilder) -> None:
    syntax = {
        "train": ["{prefix}{action}{device}", "{prefix}把{device}{action}", "{device}{action}一下", "现在{action}{device}"],
        "validation": ["{prefix}能不能{action}{device}", "我想让{device}{action}", "{device}麻烦{action}"],
        "test": ["{prefix}{device}给我{action}", "把{device}弄成{state}", "{device}{state}吧"],
    }
    light_vocab = {
        "train": {
            "device": ["客厅灯", "客厅照明", "大厅灯"],
            "op": [("打开", "亮着", True), ("开启", "开着", True), ("点亮", "亮起来", True),
                   ("关掉", "关着", False), ("关闭", "灭着", False), ("熄灭", "暗下来", False)],
        },
        "validation": {
            "device": ["起居室灯", "大厅照明"],
            "op": [("开起来", "开着", True), ("弄亮", "亮着", True), ("灭掉", "关着", False), ("关上", "灭着", False)],
        },
        "test": {
            "device": ["客厅的灯", "屋里灯光"],
            "op": [("开开", "亮着", True), ("亮起来", "开着", True), ("关一关", "灭着", False), ("弄灭", "关着", False)],
        },
    }
    ac_vocab = {
        "train": {
            "device": ["空调", "客厅空调", "冷气"],
            "op": [("打开", "开着", True), ("开启", "运行", True), ("启动", "工作", True),
                   ("关掉", "关着", False), ("关闭", "停止", False), ("停掉", "不运行", False)],
        },
        "validation": {
            "device": ["起居室空调", "制冷机"],
            "op": [("开起来", "运行", True), ("开机", "工作", True), ("关上", "停止", False), ("关机", "关着", False)],
        },
        "test": {
            "device": ["屋里空调", "大厅冷气"],
            "op": [("开开", "开着", True), ("运转起来", "运行", True), ("关一关", "关着", False), ("停止运行", "停止", False)],
        },
    }

    for split in PRIMARY_SPLITS:
        for intent, vocab, device_name in (
            ("light_set", light_vocab[split], "light"),
            ("ac_power_set", ac_vocab[split], "ac"),
        ):
            rows = [
                {"device": device, "action": action, "state": state, "power": power, "prefix": prefix}
                for device, (action, state, power), prefix in itertools.product(
                    vocab["device"], vocab["op"], prefixes(split)
                )
            ]
            for pattern_index, pattern in enumerate(syntax[split]):
                rng = random.Random(f"{SEED}:{split}:{intent}:{pattern_index}")
                candidates = list(rows)
                rng.shuffle(candidates)
                limit = 60 if split == "train" else 24
                for values in candidates[:limit]:
                    slots: dict[str, Any] = {"device": device_name, "power": values["power"]}
                    if device_name == "light":
                        slots["room"] = "living"
                    builder.add(
                        split,
                        intent,
                        pattern.format(**values),
                        f"{intent}/{split}/power_syntax_{pattern_index}",
                        slots,
                    )

    curtain_devices = {
        "train": ["窗帘", "客厅窗帘", "帘子"],
        "validation": ["起居室窗帘", "大厅帘子"],
        "test": ["客厅的窗帘", "落地帘"],
    }
    curtain_ops = {
        "train": [("全部打开", 100), ("拉开", 100), ("全部关闭", 0), ("合上", 0), ("开一半", 50), ("拉到四分之一", 25)],
        "validation": [("完全展开", 100), ("完全收起", 0), ("调成一半", 50), ("开到四分之三", 75)],
        "test": [("敞开", 100), ("严实关好", 0), ("停在中间", 50), ("留四分之一", 25)],
    }
    curtain_patterns = {
        "train": ["{prefix}{action}{device}", "{prefix}把{device}{action}", "{device}{action}一下"],
        "validation": ["我想让{device}{action}", "{prefix}让{device}{action}"],
        "test": ["{device}给我{action}", "把{device}{action}吧"],
    }
    percentage_values = {
        "train": [10, 20, 30, 40, 60, 70, 80, 90],
        "validation": [15, 35, 55, 85],
        "test": [5, 45, 65, 95],
    }
    percentage_patterns = {
        "train": ["{prefix}{device}开到{percentage}%", "{prefix}把{device}调到百分之{percentage}", "{device}设置成{percentage}%"],
        "validation": ["让{device}停在百分之{percentage}", "{prefix}{device}调整为{percentage}%"],
        "test": ["{device}留到{percentage}%", "把{device}开合度设为百分之{percentage}"],
    }
    for split in PRIMARY_SPLITS:
        for pattern_index, pattern in enumerate(percentage_patterns[split]):
            for prefix, device, percentage in itertools.product(
                prefixes(split), curtain_devices[split], percentage_values[split]
            ):
                builder.add(
                    split,
                    "curtain_set",
                    pattern.format(prefix=prefix, device=device, percentage=percentage),
                    f"curtain_set/{split}/numeric_{pattern_index}",
                    {"device": "curtain", "room": "living", "percentage": percentage},
                )

    for split in PRIMARY_SPLITS:
        for pattern_index, pattern in enumerate(curtain_patterns[split]):
            for prefix, device, (action, percentage) in itertools.product(
                prefixes(split), curtain_devices[split], curtain_ops[split]
            ):
                builder.add(
                    split,
                    "curtain_set",
                    pattern.format(prefix=prefix, device=device, action=action),
                    f"curtain_set/{split}/qualitative_{pattern_index}",
                    {"device": "curtain", "room": "living", "percentage": percentage},
                )

    temp_devices = {
        "train": ["空调", "客厅空调"],
        "validation": ["起居室空调"],
        "test": ["屋里空调", "大厅冷气"],
    }
    temperatures = {
        "train": [18, 20, 22, 24, 26, 28],
        "validation": [17, 21, 25, 29],
        "test": [16, 19, 23, 27, 30],
    }
    temp_patterns = {
        "train": ["{prefix}把{device}调到{temperature}度", "{prefix}{device}设成{temperature}℃", "{device}温度设置为{temperature}度", "调{device}到{temperature}度"],
        "validation": ["我想把{device}定在{temperature}度", "{prefix}{device}目标温度{temperature}℃", "让{device}维持{temperature}度"],
        "test": ["{device}给我来个{temperature}度", "让{device}保持{temperature}℃"],
    }
    for split in PRIMARY_SPLITS:
        builder.grid(
            split,
            "ac_temperature_set",
            "temperature",
            temp_patterns[split],
            {"prefix": prefixes(split), "device": temp_devices[split], "temperature": temperatures[split]},
            lambda v: {"device": "ac", "temperature": v["temperature"]},
        )

    mode_devices = {
        "train": ["空调", "客厅空调", "大厅空调"],
        "validation": ["起居室空调", "屋内冷气"],
        "test": ["屋里空调", "大厅冷气", "家中空调"],
    }
    modes = {
        "train": [("制冷", "cool"), ("冷风", "cool"), ("制热", "heat"), ("暖风", "heat")],
        "validation": [("降温", "cool"), ("凉风", "cool"), ("取暖", "heat"), ("加热", "heat")],
        "test": [("冷气模式", "cool"), ("清凉模式", "cool"), ("热风模式", "heat"), ("暖气模式", "heat")],
    }
    mode_patterns = {
        "train": ["{prefix}把{device}切到{mode}", "{prefix}{device}开启{mode}", "{device}改成{mode}模式", "让{device}进入{mode}"],
        "validation": ["我想让{device}用{mode}", "{prefix}{device}换为{mode}", "将{device}设置成{mode}"],
        "test": ["{device}给我调成{mode}", "让{device}运行在{mode}", "{device}现在改用{mode}"],
    }
    for split in PRIMARY_SPLITS:
        for pattern_index, pattern in enumerate(mode_patterns[split]):
            for prefix, device, (mode_text, mode_value) in itertools.product(
                prefixes(split), mode_devices[split], modes[split]
            ):
                builder.add(
                    split,
                    "ac_mode_set",
                    pattern.format(prefix=prefix, device=device, mode=mode_text),
                    f"ac_mode_set/{split}/mode_syntax_{pattern_index}",
                    {"device": "ac", "mode": mode_value},
                )


def build_query_data(builder: DatasetBuilder) -> None:
    specs: dict[str, dict[str, Any]] = {
        "light_status_query": {
            "device": {"train": ["客厅灯", "客厅照明"], "validation": ["起居室灯"], "test": ["客厅的灯", "屋里灯光"]},
            "attribute": ["开没开", "现在亮不亮", "是什么状态", "是不是关着", "还开着吗"],
            "slot_builder": lambda _v: {"device": "light", "room": "living", "query_attribute": "power"},
        },
        "curtain_status_query": {
            "device": {"train": ["窗帘", "客厅窗帘"], "validation": ["起居室帘子"], "test": ["客厅的窗帘", "落地帘"]},
            "attribute": ["开了多少", "现在开合度多少", "是什么位置", "开到百分之几", "目前关了多少"],
            "slot_builder": lambda _v: {"device": "curtain", "room": "living", "query_attribute": "percentage"},
        },
        "ac_status_query": {
            "device": {"train": ["空调", "客厅空调"], "validation": ["起居室空调"], "test": ["屋里空调", "大厅冷气"]},
            "attribute": ["开着吗", "当前什么状态", "有没有运行", "设定多少度", "现在是什么模式"],
            "slot_builder": lambda v: {
                "device": "ac",
                "query_attribute": "temperature" if "多少度" in v["attribute"] else
                ("mode" if "模式" in v["attribute"] else "power"),
            },
        },
        "door_status_query": {
            "device": {"train": ["门", "门锁"], "validation": ["入户门"], "test": ["家门", "门禁"]},
            "attribute": ["锁好了吗", "现在锁着吗", "有没有上锁", "当前什么状态", "是不是解锁了"],
            "slot_builder": lambda _v: {"device": "door", "query_attribute": "lock"},
        },
    }
    patterns = {
        "train": ["{prefix}{device}{attribute}", "{prefix}看一下{device}{attribute}", "告诉我{device}{attribute}"],
        "validation": ["我想知道{device}{attribute}", "{prefix}查查{device}{attribute}"],
        "test": ["{device}{attribute}帮我确认下", "能说下{device}{attribute}"],
    }
    for intent, spec in specs.items():
        for split in PRIMARY_SPLITS:
            builder.grid(
                split,
                intent,
                "query",
                patterns[split],
                {"prefix": prefixes(split), "device": spec["device"][split], "attribute": spec["attribute"]},
                spec["slot_builder"],
                limit_per_pattern=50 if split == "train" else 24,
            )

    environment_specs: dict[str, dict[str, Any]] = {
        "temperature_query": {
            "terms": {"train": ["室内温度", "家里温度", "当前温度", "房间几度", "屋里冷暖"], "validation": ["屋内气温"], "test": ["房间里几度", "家中冷不冷"]},
            "questions": ["是多少", "有几度", "怎么样", "高不高", "现在多少度"],
            "slots": {"device": "environment", "query_attribute": "temperature"},
        },
        "humidity_query": {
            "terms": {"train": ["室内湿度", "家里湿度", "当前湿度", "房间潮不潮", "屋里干湿"], "validation": ["屋内湿度"], "test": ["房间潮湿程度", "家中干不干"]},
            "questions": ["是多少", "有多少", "怎么样", "高不高", "现在百分之几"],
            "slots": {"device": "environment", "query_attribute": "humidity"},
        },
        "environment_query": {
            "terms": {"train": ["温度和湿度", "室内环境", "家里温湿度"], "validation": ["屋内温湿度"], "test": ["房间冷热和干湿", "家中环境"]},
            "questions": ["怎么样", "分别是多少", "现在什么情况", "正常吗", "都告诉我"],
            "slots": {"device": "environment"},
        },
        "alarm_status_query": {
            "terms": {"train": ["烟雾报警", "水浸报警", "漏水报警", "家里安全报警"], "validation": ["烟感告警", "水淹告警"], "test": ["烟雾警报", "漏水警报"]},
            "questions": ["有没有", "触发了吗", "现在正常吗", "是什么状态", "响了吗"],
            "slots": {"device": "alarm", "query_attribute": "alarm"},
        },
    }
    environment_patterns = {
        "train": ["{prefix}{term}{question}", "{prefix}查一下{term}{question}", "告诉我{term}{question}"],
        "validation": ["我想知道{term}{question}", "{prefix}看看{term}{question}"],
        "test": ["{term}{question}帮我确认", "能说说{term}{question}"],
    }
    for intent, spec in environment_specs.items():
        for split in PRIMARY_SPLITS:
            builder.grid(
                split,
                intent,
                "query",
                environment_patterns[split],
                {"prefix": prefixes(split), "term": spec["terms"][split], "question": spec["questions"]},
                lambda _v, slot_spec=spec["slots"]: dict(slot_spec),
                limit_per_pattern=50 if split == "train" else 24,
            )


def build_safety_and_unknown_data(builder: DatasetBuilder) -> None:
    risky_actions = {
        "train": ["打开门", "开门", "解锁门锁", "把门锁打开", "解除门禁", "门锁给我解开",
                  "松开门锁", "放开大门", "取消门锁定", "打开入户门", "让门禁开门"],
        "validation": ["把家门开开", "允许门锁解锁", "门禁放行", "解除入户门锁定", "开启大门"],
        "test": ["替我把入户门打开", "家门锁给我松开", "让门禁开门", "取消家门锁定", "放开入户门"],
    }
    risky_patterns = {
        "train": ["{prefix}{action}", "{prefix}现在{action}", "{action}让我进去", "马上{action}",
                  "替我{action}", "立即{action}", "我要求你{action}", "赶紧{action}",
                  "能帮我{action}吗", "{action}可以吗", "是否可以{action}", "{action}好不好"],
        "validation": ["我需要你{action}", "{prefix}能否{action}", "请确认后{action}", "现在替我{action}"],
        "test": ["{action}行不行", "赶紧替我{action}", "我命令你{action}", "直接{action}"],
    }
    for split in PRIMARY_SPLITS:
        builder.grid(
            split,
            "requires_confirmation",
            "door_unlock",
            risky_patterns[split],
            {"prefix": prefixes(split), "action": risky_actions[split]},
            lambda _v: {"device": "door"},
            limit_per_pattern=50 if split == "train" else 24,
        )

    fixed_unknown: dict[str, list[str]] = {
        "train": [
            "你好", "你是谁", "今天天气怎么样", "讲个笑话", "播放音乐", "现在几点", "给我打电话", "打开电视",
            "关闭风扇", "启动扫地机器人", "打开加湿器", "煮一壶水", "灯", "空调", "窗帘", "帮帮我", "随便吧",
            "不用了", "取消操作", "刚才那条撤销", "别动", "什么都不要做", "打开然后关闭客厅灯", "空调开关都按一下",
            "门锁是什么牌子", "窗帘用了多久", "空调耗电多少", "灯泡坏了吗", "为什么这么热", "我回来了",
        ],
        "validation": [
            "晚上吃什么", "放一首歌", "帮我查快递", "电视声音小点", "启动洗衣机", "什么也别做", "撤回上一条",
            "灯和空调随便开一个", "窗帘还是算了", "设备都怎么样", "我有点困", "明天会下雨吗",
        ],
        "test": [
            "订一张车票", "读一下新闻", "给猫喂食", "风扇转快点", "把卧房的灯点亮", "把灶台灯关了", "算了不要执行",
            "开灯不对还是关灯", "空调要不要开呢", "窗帘先别管", "你听见我了吗", "家里有人吗",
        ],
    }
    for split, utterances in fixed_unknown.items():
        for index, utterance in enumerate(utterances):
            builder.add(split, "unknown", utterance, f"unknown/{split}/fixed_{index // 4}")

    unsupported_rooms = {
        "train": ["卧室", "厨房", "卫生间", "阳台", "书房"],
        "validation": ["餐厅", "浴室"],
        "test": ["车库", "地下室", "儿童房"],
    }
    unsupported_patterns = {
        "train": ["{prefix}打开{room}灯", "{prefix}关闭{room}灯", "{room}灯开着吗"],
        "validation": ["把{room}照明打开", "查一下{room}的灯"],
        "test": ["{room}灯给我关上", "看看{room}灯亮不亮"],
    }
    cancellation_actions = {
        "train": ["打开客厅灯", "关闭空调", "拉开窗帘", "空调调到二十四度", "切换空调制冷", "关掉客厅照明"],
        "validation": ["开启客厅照明", "关掉冷气", "窗帘开一半"],
        "test": ["点亮屋里灯光", "启动大厅冷气", "窗帘全部关闭"],
    }
    cancellation_patterns = {
        "train": ["不要{action}", "别{action}", "取消{action}", "不用{action}", "先别急着{action}",
                  "我不确定要不要{action}", "准备{action}但还是撤销", "暂时不执行{action}",
                  "中止即将执行{action}", "{action}不过先作罢", "不要再准备{action}"],
        "validation": ["先别急着{action}", "我不想{action}"],
        "test": ["{action}还是算了", "停止准备{action}"],
    }
    for split in PRIMARY_SPLITS:
        builder.grid(
            split,
            "unknown",
            "unsupported_room",
            unsupported_patterns[split],
            {"prefix": prefixes(split), "room": unsupported_rooms[split]},
            lambda _v: {},
        )
        builder.grid(
            split,
            "unknown",
            "cancellation",
            cancellation_patterns[split],
            {"action": cancellation_actions[split]},
            lambda _v: {},
        )

    unsupported_devices = ["电视", "风扇", "扫地机器人", "加湿器", "热水器", "洗衣机", "空气净化器"]
    unsupported_device_patterns = [
        "请打开{device}", "把{device}关掉", "看看{device}开着吗", "将{device}调到自动模式",
        "帮我控制一下{device}",
    ]
    builder.grid(
        "train",
        "unknown",
        "unsupported_device",
        unsupported_device_patterns,
        {"device": unsupported_devices},
        lambda _v: {},
    )
    hard_unknown_rooms = ["储物间", "走廊", "院子", "阁楼", "客房"]
    builder.grid(
        "train",
        "unknown",
        "unsupported_room_hard_query",
        ["确认{room}灯亮着没有", "我想知道{room}灯是否开启", "查询{room}照明状态"],
        {"room": hard_unknown_rooms},
        lambda _v: {},
    )
    for index, text in enumerate([
        "你能听到我说话吗", "设备控制先暂停", "我只是随便问问", "不要做任何改变", "刚才的话不算数",
        "所有操作暂缓", "我还没有想好", "先保持现在这样", "什么设备都别碰", "这不是一条控制命令",
    ]):
        builder.add("train", "unknown", text, f"unknown/train/meta_negative_{index // 2}")


def add_asr_augmentation(builder: DatasetBuilder) -> None:
    known_replacements = [
        ("客厅灯", "客厅都"),
        ("空调", "空掉"),
        ("窗帘", "窗连"),
        ("湿度", "适度"),
        ("门锁", "门所"),
    ]
    train_snapshot = list(builder.rows["train"])
    for source_text, noisy_text in known_replacements:
        per_intent: Counter[str] = Counter()
        matches: list[dict[str, Any]] = []
        for row in train_snapshot:
            if source_text not in row["text"] or per_intent[row["intent"]] >= 12:
                continue
            matches.append(row)
            per_intent[row["intent"]] += 1
        for index, row in enumerate(matches):
            builder.add(
                "train",
                row["intent"],
                row["text"].replace(source_text, noisy_text),
                f"{row['intent']}/train/asr_known_{source_text}_{index // 12}",
                dict(row["slots"]),
                "asr_augmented",
                row["slot_valid"],
            )

    noise_by_intent: dict[str, list[tuple[str, str]]] = {
        "light_set": [("灯", "等"), ("客厅", "客听")],
        "light_status_query": [("灯", "等"), ("亮", "量")],
        "ac_power_set": [("空调", "空条"), ("冷气", "冷器")],
        "ac_temperature_set": [("空调", "空条"), ("度", "读")],
        "ac_mode_set": [("冷气", "冷器"), ("模式", "模试")],
        "ac_status_query": [("冷气", "冷器"), ("状态", "状太")],
        "curtain_set": [("窗帘", "窗年"), ("落地帘", "落地连")],
        "curtain_status_query": [("窗帘", "窗年"), ("开合度", "开和度")],
        "door_status_query": [("门禁", "门进"), ("家门", "家们")],
        "temperature_query": [("几度", "几读"), ("冷不冷", "冷不楞")],
        "humidity_query": [("潮湿", "潮时"), ("干不干", "干不甘")],
        "environment_query": [("环境", "环静"), ("干湿", "干是")],
        "alarm_status_query": [("烟雾", "烟务"), ("漏水", "露水"), ("警报", "景报")],
        "requires_confirmation": [("门禁", "门进"), ("门锁", "门所"), ("开门", "开们")],
        "unknown": [("新闻", "新文"), ("风扇", "风善"), ("不要", "不腰")],
    }
    test_rows = list(builder.rows["test"])
    for intent in sorted(builder.labels):
        intent_rows = [row for row in test_rows if row["intent"] == intent]
        replacements = noise_by_intent.get(intent, [])
        emitted = 0
        for row in intent_rows:
            noisy = row["text"]
            for source_text, noisy_text in replacements:
                if source_text in noisy:
                    noisy = noisy.replace(source_text, noisy_text, 1)
                    break
            else:
                if len(noisy) > 3:
                    noisy = noisy[:2] + noisy[3:]
            if noisy == row["text"]:
                continue
            builder.add(
                "asr_noise_test",
                intent,
                noisy,
                f"{intent}/asr_noise/balanced_{emitted // 4}",
                dict(row["slots"]),
                "asr_noise_held_out",
                row["slot_valid"],
            )
            emitted += 1
            if emitted >= 16:
                break


def add_boundary_data(builder: DatasetBuilder) -> None:
    for value, valid in [(-1, False), (0, True), (1, True), (99, True), (100, True), (101, False)]:
        for pattern_index, pattern in enumerate(("把窗帘调到{value}%", "窗帘开合度设为百分之{value}")):
            builder.add(
                "boundary_test",
                "curtain_set",
                pattern.format(value=value),
                f"curtain_set/boundary/percentage_{pattern_index}",
                {"device": "curtain", "room": "living", "percentage": value},
                "numeric_boundary",
                valid,
            )
    for value, valid in [(15, False), (16, True), (17, True), (29, True), (30, True), (31, False)]:
        for pattern_index, pattern in enumerate(("空调调到{value}度", "把客厅空调设成{value}℃")):
            builder.add(
                "boundary_test",
                "ac_temperature_set",
                pattern.format(value=value),
                f"ac_temperature_set/boundary/temperature_{pattern_index}",
                {"device": "ac", "temperature": value},
                "numeric_boundary",
                valid,
            )


def write_dataset(builder: DatasetBuilder, output: Path) -> None:
    output.mkdir(parents=True, exist_ok=True)
    rng = random.Random(SEED)
    file_metadata: dict[str, Any] = {}
    for split in ALL_SPLITS:
        rows = list(builder.rows[split])
        rng.shuffle(rows)
        path = output / f"{split}.jsonl"
        with path.open("w", encoding="utf-8", newline="\n") as handle:
            for index, row in enumerate(rows):
                record = {"id": f"{split}-{index:05d}", **row}
                handle.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")
        file_metadata[split] = {
            "file": path.name,
            "samples": len(rows),
            "families": len({row["family_id"] for row in rows}),
            "intent_counts": dict(sorted(Counter(row["intent"] for row in rows).items())),
            "sha256": sha256_file(path),
        }
    manifest = {
        "dataset": "yuhome_local_nlu",
        "version": 1,
        "seed": SEED,
        "split_strategy": "expression_template_family",
        "labels": sorted(builder.labels),
        "files": file_metadata,
    }
    manifest_path = output / "dataset_manifest.json"
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    labels_payload = json.loads((ROOT / "configs" / "labels.json").read_text(encoding="utf-8"))
    builder = DatasetBuilder(labels_payload["labels"])
    build_control_data(builder)
    build_query_data(builder)
    build_safety_and_unknown_data(builder)
    add_asr_augmentation(builder)
    add_boundary_data(builder)
    write_dataset(builder, args.output.resolve())
    for split in ALL_SPLITS:
        print(f"{split}: {len(builder.rows[split])} samples")
    print(f"wrote: {args.output.resolve()}")


if __name__ == "__main__":
    main()
