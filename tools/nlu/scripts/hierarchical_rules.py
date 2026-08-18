#!/usr/bin/env python3
"""Conservative rule layer that runs before the learned YuHome NLU model."""

from __future__ import annotations

import re
from dataclasses import dataclass


PUNCTUATION_RE = re.compile(r"[\s，。！？、,.!?；;：:]")

ASR_ALIASES = {
    "门进": "门禁",
    "门所": "门锁",
    "家们": "家门",
    "开们": "开门",
    "所定": "锁定",
    "户们": "户门",
    "冷器": "冷气",
    "空条": "空调",
    "空掉": "空调",
    "制冷鸡": "制冷机",
    "等光": "灯光",
    "造明": "照明",
    "窗年": "窗帘",
    "连子": "帘子",
    "温读": "温度",
    "几读": "几度",
    "适度": "湿度",
    "潮时": "潮湿",
    "环静": "环境",
    "烟务": "烟雾",
    "露水": "漏水",
    "景报": "警报",
}

CONTROL_ACTION_RE = re.compile(
    r"打开|开启|启动|点亮|关掉|关闭|关上|熄灭|调到|设成|设置|切换|"
    r"切到|切成|拉开|合上|展开|收起|开到|调整|运行"
)
CANCEL_PREFIX_RE = re.compile(
    r"^(?:不要|别|不用|不必|先别|暂时别|暂时不要|取消(?:刚才|之前|上一条)?|"
    r"撤销(?:刚才|之前|上一条)?|停止准备|中止准备|停止即将|中止即将).*(?:"
    + CONTROL_ACTION_RE.pattern
    + r")"
)
CANCEL_SUFFIX_RE = re.compile(
    r"(?:" + CONTROL_ACTION_RE.pattern + r").*(?:还是算了|还是别执行|算了吧|算了|作罢|不执行了|不要执行|先别执行|取消掉)$"
)
GENERIC_CANCEL_RE = re.compile(
    r"^(?:算了|不用了|取消操作|撤销操作|停止执行|中止执行|什么都别做|保持不变|别动)$"
)

UNSUPPORTED_ROOM_RE = re.compile(
    r"卧室|厨房|卫生间|阳台|书房|餐厅|浴室|车库|地下室|儿童房|储物间|走廊|院子|阁楼|客房"
)
ROOM_SCOPED_DEVICE_RE = re.compile(r"灯|照明|窗帘|帘子|空调|冷气|制冷机")
UNSUPPORTED_DEVICE_RE = re.compile(
    r"电视|风扇|扫地机器人|扫地机|加湿器|热水器|洗衣机|空气净化器|净化器|洗碗机|灶台|电饭煲"
)
OPEN_DOMAIN_REQUEST_RE = re.compile(
    r"天气|新闻|音乐|歌曲|笑话|故事|快递|车票|交通|日期|星期几|几点|"
    r"打电话|发消息|发短信|订票|喂猫|吃什么"
)
META_OOD_RE = re.compile(
    r"你是谁|听见我|听到我|听懂|这句话.*测试|不是.*(?:设备|控制).*命令|"
    r"没有发.*命令|随便聊|不要猜|我还没有想好|只是.*问"
)
UNSUPPORTED_ATTRIBUTE_RE = re.compile(r"什么牌子|品牌|耗电|用了多久|为什么|坏了|维修|保修")

DOOR_DEVICE_RE = re.compile(r"住宅入口门|入口门|入户门|户门|家门|大门|门锁|门禁|门")
DOOR_ACTION_RE = re.compile(
    r"开门|开一下|打开|开启|放开|松开|解锁|解开|开锁|解除.*(?:门锁|锁定|门禁)|"
    r"取消(?:门锁|锁定|门禁)|允许.*进入|放行"
)
DOOR_IMPERATIVE_RE = re.compile(
    r"(?:帮我|替我|给我|我命令你|我要求你|让|请|马上|赶紧|直接|能不能|能否).*(?:"
    + DOOR_ACTION_RE.pattern
    + r")"
)
DOOR_STATUS_QUERY_RE = re.compile(
    r"是不是(?:解锁|锁定|锁着|打开|关闭)|是否(?:解锁|锁定|锁着|打开|关闭)|"
    r"有没有(?:锁|打开|关闭)|(?:门锁|门禁|家门|入户门|大门).*(?:状态|情况|是否正常)|"
    r"(?:解锁|锁定|打开|关闭)了(?:吗|没|没有)|"
    r"(?:锁着|锁好|开着|关着)(?:吗|没|没有)|"
    r"(?:查查|查询|查看|看看|看一下|我想知道|告诉我|能说下).*(?:门|门锁|门禁)"
)
DOOR_EXPLICIT_QUERY_RE = re.compile(
    r"是不是|是否|有没有|当前状态|现在状态|查查|查询|查看|看看|看一下|我想知道|告诉我|能说下"
)
UNSUPPORTED_DOOR_SCOPE_RE = re.compile(r"卧室门|厨房门|卫生间门|浴室门|阳台门|书房门|车库门|院门|儿童房门")


@dataclass(frozen=True)
class RuleDecision:
    intent: str
    rule: str


def normalize_for_rules(text: str) -> str:
    normalized = PUNCTUATION_RE.sub("", normalize_for_model(text)).lower()
    return normalized


def normalize_for_model(text: str) -> str:
    normalized = text
    for source, target in ASR_ALIASES.items():
        normalized = normalized.replace(source, target)
    normalized = re.sub(r"(客厅|大厅|屋里|起居室)(的)?等(?=给|开|关|亮|状态|光)", r"\1\2灯", normalized)
    return normalized


def hard_route(text: str) -> RuleDecision | None:
    """Return a terminal safety decision, or ``None`` to invoke the model.

    Cancellation of an ordinary device command fails closed to ``unknown``.
    Unlocking/opening an entry door always requires confirmation.  The narrow
    special case for phrases such as ``取消门锁锁定`` is evaluated before the
    generic cancellation rule because that phrase means unlocking the door.
    """

    normalized = normalize_for_rules(text)

    if DOOR_DEVICE_RE.search(normalized) and re.search(r"取消.*(?:锁定|门锁|门禁)", normalized):
        return RuleDecision("requires_confirmation", "sensitive_door_unlock")

    if CANCEL_PREFIX_RE.search(normalized) or CANCEL_SUFFIX_RE.search(normalized):
        return RuleDecision("unknown", "cancelled_or_negated_control")

    if UNSUPPORTED_DOOR_SCOPE_RE.search(normalized):
        return RuleDecision("unknown", "unsupported_door_scope")

    if DOOR_DEVICE_RE.search(normalized) and DOOR_STATUS_QUERY_RE.search(normalized):
        if DOOR_EXPLICIT_QUERY_RE.search(normalized) or not DOOR_IMPERATIVE_RE.search(normalized):
            return RuleDecision("door_status_query", "door_status_query")

    if DOOR_DEVICE_RE.search(normalized) and DOOR_ACTION_RE.search(normalized):
        return RuleDecision("requires_confirmation", "sensitive_door_action")

    if GENERIC_CANCEL_RE.search(normalized):
        return RuleDecision("unknown", "generic_cancellation")

    if UNSUPPORTED_ROOM_RE.search(normalized) and ROOM_SCOPED_DEVICE_RE.search(normalized):
        return RuleDecision("unknown", "unsupported_room")

    if UNSUPPORTED_DEVICE_RE.search(normalized):
        return RuleDecision("unknown", "unsupported_device")

    if OPEN_DOMAIN_REQUEST_RE.search(normalized):
        return RuleDecision("unknown", "open_domain_request")

    if META_OOD_RE.search(normalized) or UNSUPPORTED_ATTRIBUTE_RE.search(normalized):
        return RuleDecision("unknown", "out_of_domain_meta_or_attribute")

    return None
