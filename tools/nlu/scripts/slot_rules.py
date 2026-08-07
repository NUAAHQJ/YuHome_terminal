#!/usr/bin/env python3
"""Deterministic slot extraction used beside the intent classifier."""

from __future__ import annotations

import re
from typing import Any


PUNCTUATION_RE = re.compile(r"[\s，。！？、,.!?]")
ARABIC_NUMBER_RE = re.compile(r"-?\d{1,3}")
CHINESE_DIGITS = {"零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
                  "五": 5, "六": 6, "七": 7, "八": 8, "九": 9}


def normalize(text: str) -> str:
    return PUNCTUATION_RE.sub("", text).replace("摄氏", "").lower()


def chinese_number(token: str) -> int | None:
    if not token:
        return None
    if token in CHINESE_DIGITS:
        return CHINESE_DIGITS[token]
    if token == "十":
        return 10
    if "十" in token:
        left, right = token.split("十", 1)
        tens = CHINESE_DIGITS.get(left, 1) if left else 1
        units = CHINESE_DIGITS.get(right, 0) if right else 0
        return tens * 10 + units
    digits: list[str] = []
    for char in token:
        value = CHINESE_DIGITS.get(char)
        if value is None:
            return None
        digits.append(str(value))
    return int("".join(digits)) if digits else None


def first_number(text: str) -> int | None:
    match = ARABIC_NUMBER_RE.search(text)
    if match:
        return int(match.group(0))
    match = re.search(r"[零〇一二两三四五六七八九十]{1,4}", text)
    return chinese_number(match.group(0)) if match else None


def extract_percentage(text: str) -> int | None:
    normalized = normalize(text)
    if any(term in normalized for term in ("全开", "全部打开", "拉开", "完全展开", "敞开")):
        return 100
    if any(term in normalized for term in ("全关", "全部关闭", "合上", "完全收起", "严实关好")):
        return 0
    if any(term in normalized for term in ("一半", "中间")):
        return 50
    if "四分之三" in normalized:
        return 75
    if "四分之一" in normalized:
        return 25
    return first_number(normalized)


def extract_temperature(text: str) -> int | None:
    normalized = normalize(text)
    matches = re.findall(r"(-?\d{1,2}|[一二两三四五六七八九十]{1,3})(?:度|℃|读)", normalized)
    if not matches:
        return None
    token = matches[-1]
    return int(token) if re.fullmatch(r"-?\d+", token) else chinese_number(token)


def extract_slots(text: str, intent: str) -> dict[str, Any]:
    normalized = normalize(text)
    if intent == "unknown":
        return {}
    if intent == "requires_confirmation":
        return {"device": "door"}
    if intent == "light_set":
        is_off = any(term in normalized for term in ("关", "灭", "暗"))
        return {"device": "light", "room": "living", "power": not is_off}
    if intent == "ac_power_set":
        is_off = any(term in normalized for term in ("关", "停", "不运行"))
        return {"device": "ac", "power": not is_off}
    if intent == "curtain_set":
        return {"device": "curtain", "room": "living", "percentage": extract_percentage(normalized)}
    if intent == "ac_temperature_set":
        return {"device": "ac", "temperature": extract_temperature(normalized)}
    if intent == "ac_mode_set":
        mode = "heat" if any(term in normalized for term in ("制热", "暖", "热风", "取暖", "加热")) else "cool"
        return {"device": "ac", "mode": mode}
    if intent == "light_status_query":
        return {"device": "light", "room": "living", "query_attribute": "power"}
    if intent == "curtain_status_query":
        return {"device": "curtain", "room": "living", "query_attribute": "percentage"}
    if intent == "ac_status_query":
        attribute = "temperature" if any(term in normalized for term in ("多少度", "设定温度")) else (
            "mode" if "模式" in normalized else "power"
        )
        return {"device": "ac", "query_attribute": attribute}
    if intent == "door_status_query":
        return {"device": "door", "query_attribute": "lock"}
    if intent == "temperature_query":
        return {"device": "environment", "query_attribute": "temperature"}
    if intent == "humidity_query":
        return {"device": "environment", "query_attribute": "humidity"}
    if intent == "environment_query":
        return {"device": "environment"}
    if intent == "alarm_status_query":
        return {"device": "alarm", "query_attribute": "alarm"}
    return {}


def validate_slots(intent: str, slots: dict[str, Any]) -> bool:
    if intent == "curtain_set":
        value = slots.get("percentage")
        return isinstance(value, int) and 0 <= value <= 100
    if intent == "ac_temperature_set":
        value = slots.get("temperature")
        return isinstance(value, int) and 16 <= value <= 30
    if intent in ("light_set", "ac_power_set"):
        return isinstance(slots.get("power"), bool)
    if intent == "ac_mode_set":
        return slots.get("mode") in ("cool", "heat")
    return True
