export enum VoiceIntentType {
  LIGHT_SET = 'light_set',
  AC_SET = 'ac_set',
  REQUIRES_CONFIRMATION = 'requires_confirmation',
  UNKNOWN = 'unknown'
}

export interface VoiceIntent {
  type: VoiceIntentType
  target: string
  power: boolean
  temperature: number
  sensor: string
  rawText: string
  normalizedText: string
}

const LIGHT_DEVICE_TERMS: string[] = [
  '客厅灯',
  '灯光',
  '照明',
  '电灯',
  '灯'
]

const LIGHT_ON_ACTION_TERMS: string[] = [
  '打开',
  '开启',
  '启动',
  '点亮',
  '亮起',
  '开'
]

const POWER_OFF_ACTION_TERMS: string[] = [
  '关闭',
  '关掉',
  '熄灭',
  '停掉',
  '停止',
  '关'
]

const AC_DEVICE_TERMS: string[] = [
  '空调',
  '冷气',
  '制冷'
]

const CONTROL_BLOCKERS: string[] = [
  '不要',
  '别',
  '不用',
  '不许',
  '不能',
  '不了',
  '开着',
  '关着',
  '已经开',
  '已经关',
  '已打开',
  '已关闭',
  '是否',
  '是不是',
  '有没有',
  '吗'
]

const UNSUPPORTED_LIGHT_LOCATIONS: string[] = [
  '卧室',
  '厨房',
  '卫生间',
  '浴室',
  '阳台',
  '书房',
  '餐厅'
]

const HIGH_RISK_PHRASES: string[] = [
  '开门',
  '打开门',
  '解锁',
  '门锁'
]

export class VoiceIntentParser {
  parse(text: string): VoiceIntent {
    const normalized = this.normalize(text)
    if (this.containsAny(normalized, HIGH_RISK_PHRASES)) {
      return this.createIntent(VoiceIntentType.REQUIRES_CONFIRMATION, '', false, text, normalized)
    }
    if (this.isSafeControlText(normalized)) {
      const isOff = this.containsAny(normalized, POWER_OFF_ACTION_TERMS)
      const isOn = this.containsAny(normalized, LIGHT_ON_ACTION_TERMS)
      if (isOff !== isOn && this.isLivingLightIntent(normalized)) {
        return this.createIntent(VoiceIntentType.LIGHT_SET, 'living', isOn, text, normalized)
      }
      if (isOff !== isOn && this.containsAny(normalized, AC_DEVICE_TERMS)) {
        return this.createIntent(VoiceIntentType.AC_SET, 'ac', isOn, text, normalized)
      }
    }
    return this.createIntent(VoiceIntentType.UNKNOWN, '', false, text, normalized)
  }

  private normalize(text: string): string {
    return text
      .replace(/\s+/g, '')
      .replace(/[，。！？、,.!?]/g, '')
      .replace(/请|帮我|麻烦|劳驾|给我/g, '')
      .trim()
  }

  private isSafeControlText(text: string): boolean {
    return text.length > 0 && !this.containsAny(text, CONTROL_BLOCKERS)
  }

  private isLivingLightIntent(text: string): boolean {
    return !this.containsAny(text, UNSUPPORTED_LIGHT_LOCATIONS) && this.containsAny(text, LIGHT_DEVICE_TERMS)
  }

  private containsAny(text: string, phrases: string[]): boolean {
    for (let i = 0; i < phrases.length; i++) {
      if (text.indexOf(phrases[i]) >= 0) {
        return true
      }
    }
    return false
  }

  private createIntent(type: VoiceIntentType, target: string, power: boolean,
    rawText: string, normalizedText: string): VoiceIntent {
    return {
      type: type,
      target: target,
      power: power,
      temperature: 0,
      sensor: '',
      rawText: rawText,
      normalizedText: normalizedText
    }
  }
}
