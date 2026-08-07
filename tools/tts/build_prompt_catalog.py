#!/usr/bin/env python3
import json
from pathlib import Path


DIGITS = '零一二三四五六七八九'


def chinese_integer(value: int) -> str:
    if value < 0 or value > 100:
        raise ValueError(value)
    if value < 10:
        return DIGITS[value]
    if value < 20:
        return '十' + (DIGITS[value % 10] if value % 10 else '')
    if value < 100:
        return DIGITS[value // 10] + '十' + (DIGITS[value % 10] if value % 10 else '')
    return '一百'


def temperature_text(tenths: int) -> str:
    integer, decimal = divmod(tenths, 10)
    value = chinese_integer(integer)
    if decimal:
        value += '点' + DIGITS[decimal]
    return value


def add(outputs: list[dict[str, str]], prompt_id: str, text: str, file_name: str) -> None:
    outputs.append({'id': prompt_id, 'text': text, 'file': file_name})


def build_catalog() -> dict[str, object]:
    outputs: list[dict[str, str]] = []

    fixed = {
        'awake': '我在，请说。',
        'generic_success': '操作已完成。',
        'generic_failed': '抱歉，执行失败，请再试一次。',
        'unsupported': '暂时不支持这个语音指令。',
        'not_heard': '没有听清，请重新唤醒。',
        'sensor_unavailable': '暂未收到温湿度传感器数据。',
        'device_unavailable': '设备暂时无法连接，请稍后再试。',
        'voiceprint_denied': '声纹验证未通过，指令已拒绝。',
        'light_status_on': '客厅灯当前开着。',
        'light_status_off': '客厅灯当前关着。',
        'light_set_on': '客厅灯开启指令已发送。',
        'light_set_off': '客厅灯关闭指令已发送。',
        'ac_status_off': '空调当前已关闭。',
        'ac_mode_cool': '空调已切换为制冷模式。',
        'ac_mode_heat': '空调已切换为制热模式。',
        'ac_set_on': '空调开启指令已发送。',
        'ac_set_off': '空调关闭指令已发送。',
        'goal_comfort_warmer': '已调整为制热模式。',
        'goal_comfort_cooler': '已调整为制冷模式。',
        'goal_sleep_scene': '已为你调整睡眠环境。',
        'goal_away_scene': '已为你设置离家场景。',
        'goal_home_scene': '已为你准备回家环境。',
        'door_open_locked': '门当前开着，门锁已上锁。',
        'door_open_unlocked': '门当前开着，门锁已解锁。',
        'door_closed_locked': '门当前关着，门锁已上锁。',
        'door_closed_unlocked': '门当前关着，门锁已解锁。',
        'door_lock_locked': '门锁当前已上锁。',
        'door_lock_unlocked': '门锁当前已解锁。',
        'alarm_smoke_water': '当前存在烟雾和水浸报警。',
        'alarm_smoke': '当前存在烟雾报警。',
        'alarm_water': '当前存在水浸报警。',
        'alarm_clear': '当前没有烟雾或水浸报警。',
    }
    for prompt_id, text in fixed.items():
        add(outputs, prompt_id, text, f'fixed/{prompt_id}.wav')

    for tenths in range(200, 301):
        value = temperature_text(tenths)
        add(outputs, f'temperature_{tenths}', f'当前室内温度为{value}度。',
            f'temperature/temperature_{tenths}.wav')

    for humidity in range(0, 101):
        value = chinese_integer(humidity)
        add(outputs, f'humidity_{humidity:03d}', f'当前室内湿度为百分之{value}。',
            f'humidity/humidity_{humidity:03d}.wav')

    for percent in range(0, 101):
        value = chinese_integer(percent)
        if percent == 0:
            status_text = '窗帘当前已完全关闭。'
            set_text = '窗帘已完全关闭。'
        elif percent == 100:
            status_text = '窗帘当前已完全打开。'
            set_text = '窗帘已完全打开。'
        else:
            status_text = f'窗帘当前开合度为百分之{value}。'
            set_text = f'窗帘已调至百分之{value}。'
        add(outputs, f'curtain_status_{percent:03d}', status_text,
            f'curtain/status_{percent:03d}.wav')
        add(outputs, f'curtain_set_{percent:03d}', set_text,
            f'curtain/set_{percent:03d}.wav')

    for temperature in range(20, 31):
        value = chinese_integer(temperature)
        add(outputs, f'ac_status_cool_{temperature}',
            f'空调当前已开启，制冷模式，设定温度{value}度。',
            f'ac/status_cool_{temperature}.wav')
        add(outputs, f'ac_status_heat_{temperature}',
            f'空调当前已开启，制热模式，设定温度{value}度。',
            f'ac/status_heat_{temperature}.wav')
        add(outputs, f'ac_temperature_set_{temperature}',
            f'空调温度已设置为{value}度。',
            f'ac/temperature_set_{temperature}.wav')

    return {
        'voiceId': 'yuhome_current_female_v1',
        'reference': {
            'audio': 'reference/voice_reference_16k.wav',
            'text': '声纹验证未通过，指令已拒绝。',
            'consentConfirmed': True,
        },
        'ranges': {
            'temperatureTenths': {'min': 200, 'max': 300, 'step': 1},
            'humidityInteger': {'min': 0, 'max': 100, 'step': 1},
            'curtainPercent': {'min': 0, 'max': 100, 'step': 1},
            'acTemperature': {'min': 20, 'max': 30, 'step': 1},
        },
        'outputs': outputs,
    }


def main() -> None:
    target = Path(__file__).resolve().parent / 'full_prompt_catalog.json'
    catalog = build_catalog()
    with target.open('w', encoding='utf-8') as output:
        json.dump(catalog, output, ensure_ascii=False, indent=2)
        output.write('\n')
    print(f"WROTE {target} prompts={len(catalog['outputs'])}")


if __name__ == '__main__':
    main()
