export enum VoiceIntentType {
  LIGHT_SET = 'light_set',
  AC_SET = 'ac_set',
  CURTAIN_SET = 'curtain_set',
  AC_TEMPERATURE_SET = 'ac_temperature_set',
  AC_MODE_SET = 'ac_mode_set',
  LIGHT_STATUS_QUERY = 'light_status_query',
  CURTAIN_STATUS_QUERY = 'curtain_status_query',
  AC_STATUS_QUERY = 'ac_status_query',
  DOOR_STATUS_QUERY = 'door_status_query',
  TEMPERATURE_QUERY = 'temperature_query',
  HUMIDITY_QUERY = 'humidity_query',
  ENVIRONMENT_QUERY = 'environment_query',
  ALARM_STATUS_QUERY = 'alarm_status_query',
  COMFORT_WARMER = 'comfort_warmer',
  COMFORT_COOLER = 'comfort_cooler',
  SLEEP_SCENE = 'sleep_scene',
  AWAY_SCENE = 'away_scene',
  HOME_SCENE = 'home_scene',
  REQUIRES_CONFIRMATION = 'requires_confirmation',
  UNKNOWN = 'unknown'
}

export interface VoiceIntent {
  type: VoiceIntentType
  target: string
  power: boolean
  temperature: number
  percentage: number
  mode: string
  sensor: string
  queryAttribute: string
  rawText: string
  normalizedText: string
}

const LIGHT_DEVICE_TERMS: string[] = ['客厅灯', '灯光', '照明', '电灯', '灯']
const LIGHT_ON_ACTION_TERMS: string[] = ['打开', '开启', '启动', '点亮', '亮起', '开']
const POWER_OFF_ACTION_TERMS: string[] = ['关闭', '关掉', '熄灭', '停掉', '停止', '关']
const LIGHT_POWER_OFF_SLOT_TERMS: string[] = ['关', '灭', '暗']
const AC_POWER_OFF_SLOT_TERMS: string[] = ['关', '停', '不运行']
const AC_DEVICE_TERMS: string[] = ['空调', '冷气', '制冷']
const CURTAIN_DEVICE_TERMS: string[] = ['窗帘', '帘子']
const DOOR_DEVICE_TERMS: string[] = ['门锁', '门禁', '门']
const TEMPERATURE_TERMS: string[] = ['温度', '多少度', '几度', '冷不冷', '热不热']
const HUMIDITY_TERMS: string[] = ['湿度', '干不干', '潮不潮']
const ALARM_TERMS: string[] = ['报警', '烟雾', '水浸', '漏水', '安全']

const QUERY_TERMS: string[] = [
  '多少', '几', '状态', '情况', '是否', '是不是', '有没有', '开着', '关着', '锁着', '正常吗', '吗'
]

const CONTROL_BLOCKERS: string[] = [
  '不要', '别', '不用', '不许', '不能', '不了', '开着', '关着', '已经开', '已经关',
  '已打开', '已关闭', '是否', '是不是', '有没有', '吗'
]

const UNSUPPORTED_LIGHT_LOCATIONS: string[] = [
  '卧室', '厨房', '卫生间', '浴室', '阳台', '书房', '餐厅'
]

const HIGH_RISK_PHRASES: string[] = ['开门', '打开门', '解锁', '门锁']

const ASR_ALIAS_SOURCES: string[] = [
  '门进', '门所', '家们', '开们', '所定', '户们', '冷器', '空条', '空掉', '制冷鸡',
  '等光', '造明', '窗年', '连子', '温读', '几读', '适度', '潮时', '环静', '烟务', '露水', '景报'
]

const ASR_ALIAS_TARGETS: string[] = [
  '门禁', '门锁', '家门', '开门', '锁定', '户门', '冷气', '空调', '空调', '制冷机',
  '灯光', '照明', '窗帘', '帘子', '温度', '几度', '湿度', '潮湿', '环境', '烟雾', '漏水', '警报'
]

const CANCEL_PREFIX_RE: RegExp = /^(?:不要|别|不用|不必|先别|暂时别|暂时不要|取消(?:刚才|之前|上一条)?|撤销(?:刚才|之前|上一条)?|停止准备|中止准备|停止即将|中止即将).*(?:打开|开启|启动|点亮|关掉|关闭|关上|熄灭|调到|设成|设置|切换|切到|切成|拉开|合上|展开|收起|开到|调整|运行)/
const CANCEL_SUFFIX_RE: RegExp = /(?:打开|开启|启动|点亮|关掉|关闭|关上|熄灭|调到|设成|设置|切换|切到|切成|拉开|合上|展开|收起|开到|调整|运行).*(?:还是算了|还是别执行|算了吧|算了|作罢|不执行了|不要执行|先别执行|取消掉)$/
const GENERIC_CANCEL_RE: RegExp = /^(?:算了|不用了|取消操作|撤销操作|停止执行|中止执行|什么都别做|保持不变|别动)$/
const UNSUPPORTED_ROOM_RE: RegExp = /卧室|厨房|卫生间|阳台|书房|餐厅|浴室|车库|地下室|儿童房|储物间|走廊|院子|阁楼|客房/
const ROOM_SCOPED_DEVICE_RE: RegExp = /灯|照明|窗帘|帘子|空调|冷气|制冷机/
const UNSUPPORTED_DEVICE_RE: RegExp = /电视|风扇|扫地机器人|扫地机|加湿器|热水器|洗衣机|空气净化器|净化器|洗碗机|灶台|电饭煲/
const OPEN_DOMAIN_REQUEST_RE: RegExp = /天气|新闻|音乐|歌曲|笑话|故事|快递|车票|交通|日期|星期几|几点|打电话|发消息|发短信|订票|喂猫|吃什么/
const META_OOD_RE: RegExp = /你是谁|听见我|听到我|听懂|这句话.*测试|不是.*(?:设备|控制).*命令|没有发.*命令|随便聊|不要猜|我还没有想好|只是.*问/
const UNSUPPORTED_ATTRIBUTE_RE: RegExp = /什么牌子|品牌|耗电|用了多久|为什么|坏了|维修|保修/
const DOOR_DEVICE_RE: RegExp = /住宅入口门|入口门|入户门|户门|家门|大门|门锁|门禁|门/
const DOOR_ACTION_RE: RegExp = /开门|开一下|打开|开启|放开|松开|解锁|解开|开锁|解除.*(?:门锁|锁定|门禁)|取消(?:门锁|锁定|门禁)|允许.*进入|放行/
const DOOR_IMPERATIVE_RE: RegExp = /(?:帮我|替我|给我|我命令你|我要求你|让|请|马上|赶紧|直接|能不能|能否).*(?:开门|开一下|打开|开启|放开|松开|解锁|解开|开锁|解除|取消|允许|放行)/
const DOOR_STATUS_QUERY_RE: RegExp = /是不是(?:解锁|锁定|锁着|打开|关闭)|是否(?:解锁|锁定|锁着|打开|关闭)|有没有(?:锁|打开|关闭)|(?:门锁|门禁|家门|入户门|大门).*(?:状态|情况|是否正常)|(?:解锁|锁定|打开|关闭)了(?:吗|没|没有)|(?:锁着|锁好|开着|关着)(?:吗|没|没有)|(?:查查|查询|查看|看看|看一下|我想知道|告诉我|能说下).*(?:门|门锁|门禁)/
const DOOR_EXPLICIT_QUERY_RE: RegExp = /是不是|是否|有没有|当前状态|现在状态|查查|查询|查看|看看|看一下|我想知道|告诉我|能说下/
const UNSUPPORTED_DOOR_SCOPE_RE: RegExp = /卧室门|厨房门|卫生间门|浴室门|阳台门|书房门|车库门|院门|儿童房门/
const COMFORT_WARMER_RE: RegExp = /有点冷|有一点冷|有些冷|太冷了|好冷|觉得冷|感觉冷|冷死了/
const COMFORT_COOLER_RE: RegExp = /有点热|有一点热|有些热|太热了|好热|觉得热|感觉热|热死了|闷热/
const SLEEP_SCENE_RE: RegExp = /我要睡觉|我想睡觉|准备睡觉|准备休息|睡眠模式|我要休息/
const AWAY_SCENE_RE: RegExp = /我要出门|我想出门|准备出门|我要离家|准备离家|离家模式/
const HOME_SCENE_RE: RegExp = /我回来了|我回家了|我到家了|回家模式/

export class VoiceIntentParser {
  splitExplicitControlClauses(text: string): string[] {
    // Goals, queries, and any safety-sensitive phrasing must stay a single request.
    if (this.parseHardRule(text) !== null) {
      return []
    }
    const clauses = text.split(/(?:然后|接着|再把|再将|同时|并且|，|,|；|;|。)/)
      .map((clause: string): string => clause.trim())
      .filter((clause: string): boolean => clause.length > 0)
    return clauses.length >= 2 && clauses.length <= 4 ? clauses : []
  }

  parse(text: string): VoiceIntent {
    const hardIntent = this.parseHardRule(text)
    if (hardIntent !== null) {
      return hardIntent
    }
    const plannerGoalIntent = this.parsePlannerGoalFallback(text)
    if (plannerGoalIntent !== null) {
      return plannerGoalIntent
    }
    const normalized = this.normalize(text)
    const queryIntent = this.parseQueryIntent(text, normalized)
    if (queryIntent.type !== VoiceIntentType.UNKNOWN) {
      return queryIntent
    }
    if (this.containsAny(normalized, HIGH_RISK_PHRASES)) {
      return this.createIntent(VoiceIntentType.REQUIRES_CONFIRMATION, 'door', false, text, normalized)
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

  parseHardRule(text: string): VoiceIntent | null {
    const normalized = this.normalizeForRules(text)
    if (DOOR_DEVICE_RE.test(normalized) && /取消.*(?:锁定|门锁|门禁)/.test(normalized)) {
      return this.createIntent(VoiceIntentType.REQUIRES_CONFIRMATION, 'door', false, text, normalized)
    }
    if (CANCEL_PREFIX_RE.test(normalized) || CANCEL_SUFFIX_RE.test(normalized)) {
      return this.createIntent(VoiceIntentType.UNKNOWN, '', false, text, normalized)
    }
    if (UNSUPPORTED_DOOR_SCOPE_RE.test(normalized)) {
      return this.createIntent(VoiceIntentType.UNKNOWN, '', false, text, normalized)
    }
    if (DOOR_DEVICE_RE.test(normalized) && DOOR_STATUS_QUERY_RE.test(normalized) &&
      (DOOR_EXPLICIT_QUERY_RE.test(normalized) || !DOOR_IMPERATIVE_RE.test(normalized))) {
      return this.createIntent(VoiceIntentType.DOOR_STATUS_QUERY, 'door', false, text, normalized, 'lock')
    }
    if (DOOR_DEVICE_RE.test(normalized) && DOOR_ACTION_RE.test(normalized)) {
      return this.createIntent(VoiceIntentType.REQUIRES_CONFIRMATION, 'door', false, text, normalized)
    }
    if (GENERIC_CANCEL_RE.test(normalized)) {
      return this.createIntent(VoiceIntentType.UNKNOWN, '', false, text, normalized)
    }
    if (UNSUPPORTED_ROOM_RE.test(normalized) && ROOM_SCOPED_DEVICE_RE.test(normalized)) {
      return this.createIntent(VoiceIntentType.UNKNOWN, '', false, text, normalized)
    }
    if (UNSUPPORTED_DEVICE_RE.test(normalized) || OPEN_DOMAIN_REQUEST_RE.test(normalized) ||
      META_OOD_RE.test(normalized) || UNSUPPORTED_ATTRIBUTE_RE.test(normalized)) {
      return this.createIntent(VoiceIntentType.UNKNOWN, '', false, text, normalized)
    }
    return null
  }

  private parsePlannerGoalFallback(text: string): VoiceIntent | null {
    const normalized = this.normalizeForRules(text)
    if (COMFORT_WARMER_RE.test(normalized)) {
      return this.createIntent(VoiceIntentType.COMFORT_WARMER, 'environment', false, text, normalized)
    }
    if (COMFORT_COOLER_RE.test(normalized)) {
      return this.createIntent(VoiceIntentType.COMFORT_COOLER, 'environment', false, text, normalized)
    }
    if (SLEEP_SCENE_RE.test(normalized)) {
      return this.createIntent(VoiceIntentType.SLEEP_SCENE, 'scene', false, text, normalized)
    }
    if (AWAY_SCENE_RE.test(normalized)) {
      return this.createIntent(VoiceIntentType.AWAY_SCENE, 'scene', false, text, normalized)
    }
    if (HOME_SCENE_RE.test(normalized)) {
      return this.createIntent(VoiceIntentType.HOME_SCENE, 'scene', false, text, normalized)
    }
    return null
  }

  parseModelLabel(text: string, label: string): VoiceIntent {
    const normalized = this.normalize(text)
    if (label === 'requires_confirmation') {
      return this.createIntent(VoiceIntentType.REQUIRES_CONFIRMATION, 'door', false, text, normalized)
    }
    if (label === 'comfort_warmer') {
      return this.createIntent(VoiceIntentType.COMFORT_WARMER, 'environment', false, text, normalized)
    }
    if (label === 'comfort_cooler') {
      return this.createIntent(VoiceIntentType.COMFORT_COOLER, 'environment', false, text, normalized)
    }
    if (label === 'sleep_scene') {
      return this.createIntent(VoiceIntentType.SLEEP_SCENE, 'scene', false, text, normalized)
    }
    if (label === 'away_scene') {
      return this.createIntent(VoiceIntentType.AWAY_SCENE, 'scene', false, text, normalized)
    }
    if (label === 'home_scene') {
      return this.createIntent(VoiceIntentType.HOME_SCENE, 'scene', false, text, normalized)
    }
    if (label === 'light_set') {
      return this.createIntent(VoiceIntentType.LIGHT_SET, 'living',
        !this.containsAny(normalized, LIGHT_POWER_OFF_SLOT_TERMS), text, normalized)
    }
    if (label === 'ac_power_set') {
      return this.createIntent(VoiceIntentType.AC_SET, 'ac',
        !this.containsAny(normalized, AC_POWER_OFF_SLOT_TERMS), text, normalized)
    }
    if (label === 'curtain_set') {
      const percentage = this.extractPercentage(normalized)
      if (percentage < 0 || percentage > 100) {
        return this.createIntent(VoiceIntentType.UNKNOWN, '', false, text, normalized)
      }
      const intent = this.createIntent(VoiceIntentType.CURTAIN_SET, 'curtain', false, text, normalized)
      intent.percentage = percentage
      return intent
    }
    if (label === 'ac_temperature_set') {
      const temperature = this.extractTemperature(normalized)
      if (temperature < 16 || temperature > 30) {
        return this.createIntent(VoiceIntentType.UNKNOWN, '', false, text, normalized)
      }
      const intent = this.createIntent(VoiceIntentType.AC_TEMPERATURE_SET, 'ac', false, text, normalized)
      intent.temperature = temperature
      return intent
    }
    if (label === 'ac_mode_set') {
      const intent = this.createIntent(VoiceIntentType.AC_MODE_SET, 'ac', false, text, normalized)
      intent.mode = this.containsAny(normalized, ['制热', '暖', '热风', '取暖', '加热']) ? 'heat' : 'cool'
      return intent
    }
    return this.parseModelQuery(text, normalized, label)
  }

  private parseModelQuery(rawText: string, normalized: string, label: string): VoiceIntent {
    if (label === 'light_status_query') {
      return this.createIntent(VoiceIntentType.LIGHT_STATUS_QUERY, 'living', false, rawText, normalized, 'power')
    }
    if (label === 'curtain_status_query') {
      return this.createIntent(VoiceIntentType.CURTAIN_STATUS_QUERY, 'curtain', false, rawText, normalized, 'percentage')
    }
    if (label === 'ac_status_query') {
      const attribute = this.containsAny(normalized, ['多少度', '设定温度']) ? 'temperature' :
        (normalized.indexOf('模式') >= 0 ? 'mode' : 'power')
      return this.createIntent(VoiceIntentType.AC_STATUS_QUERY, 'ac', false, rawText, normalized, attribute)
    }
    if (label === 'door_status_query') {
      return this.createIntent(VoiceIntentType.DOOR_STATUS_QUERY, 'door', false, rawText, normalized, 'lock')
    }
    if (label === 'temperature_query') {
      return this.createIntent(VoiceIntentType.TEMPERATURE_QUERY, 'temperature', false, rawText, normalized, 'temperature')
    }
    if (label === 'humidity_query') {
      return this.createIntent(VoiceIntentType.HUMIDITY_QUERY, 'humidity', false, rawText, normalized, 'humidity')
    }
    if (label === 'environment_query') {
      return this.createIntent(VoiceIntentType.ENVIRONMENT_QUERY, 'environment', false, rawText, normalized)
    }
    if (label === 'alarm_status_query') {
      return this.createIntent(VoiceIntentType.ALARM_STATUS_QUERY, 'alarm', false, rawText, normalized, 'alarm')
    }
    return this.createIntent(VoiceIntentType.UNKNOWN, '', false, rawText, normalized)
  }

  private parseQueryIntent(rawText: string, normalized: string): VoiceIntent {
    if (!this.containsAny(normalized, QUERY_TERMS)) {
      return this.createIntent(VoiceIntentType.UNKNOWN, '', false, rawText, normalized)
    }
    if (this.isLivingLightIntent(normalized)) {
      return this.createIntent(VoiceIntentType.LIGHT_STATUS_QUERY, 'living', false, rawText, normalized, 'power')
    }
    if (this.containsAny(normalized, CURTAIN_DEVICE_TERMS)) {
      return this.createIntent(VoiceIntentType.CURTAIN_STATUS_QUERY, 'curtain', false, rawText, normalized, 'percentage')
    }
    if (this.containsAny(normalized, AC_DEVICE_TERMS)) {
      return this.createIntent(VoiceIntentType.AC_STATUS_QUERY, 'ac', false, rawText, normalized, 'power')
    }
    if (this.containsAny(normalized, DOOR_DEVICE_TERMS)) {
      return this.createIntent(VoiceIntentType.DOOR_STATUS_QUERY, 'door', false, rawText, normalized, 'lock')
    }
    const asksTemperature = this.containsAny(normalized, TEMPERATURE_TERMS)
    const asksHumidity = this.containsAny(normalized, HUMIDITY_TERMS)
    if (asksTemperature && asksHumidity) {
      return this.createIntent(VoiceIntentType.ENVIRONMENT_QUERY, 'environment', false, rawText, normalized)
    }
    if (asksTemperature) {
      return this.createIntent(VoiceIntentType.TEMPERATURE_QUERY, 'temperature', false, rawText, normalized, 'temperature')
    }
    if (asksHumidity) {
      return this.createIntent(VoiceIntentType.HUMIDITY_QUERY, 'humidity', false, rawText, normalized, 'humidity')
    }
    if (this.containsAny(normalized, ALARM_TERMS)) {
      return this.createIntent(VoiceIntentType.ALARM_STATUS_QUERY, 'alarm', false, rawText, normalized, 'alarm')
    }
    return this.createIntent(VoiceIntentType.UNKNOWN, '', false, rawText, normalized)
  }

  private normalizeForRules(text: string): string {
    let normalized = text
    for (let i = 0; i < ASR_ALIAS_SOURCES.length; i++) {
      normalized = normalized.split(ASR_ALIAS_SOURCES[i]).join(ASR_ALIAS_TARGETS[i])
    }
    return normalized
      .replace(/(客厅|大厅|屋里|起居室)(的)?等(?=给|开|关|亮|状态|光)/g, '$1$2灯')
      .replace(/[\s，。！？、,.!?；;：:]/g, '')
      .toLowerCase()
  }

  private normalize(text: string): string {
    return this.normalizeForRules(text).replace(/请|帮我|麻烦|劳驾|给我/g, '').trim()
  }

  private extractPercentage(text: string): number {
    if (this.containsAny(text, ['全开', '全部打开', '拉开', '完全展开', '敞开'])) return 100
    if (this.containsAny(text, ['全关', '全部关闭', '合上', '完全收起', '严实关好'])) return 0
    if (this.containsAny(text, ['一半', '中间'])) return 50
    if (text.indexOf('四分之三') >= 0) return 75
    if (text.indexOf('四分之一') >= 0) return 25
    return this.firstNumber(text)
  }

  private extractTemperature(text: string): number {
    const matches = text.replace('摄氏', '').match(/(-?\d{1,2}|[一二两三四五六七八九十]{1,3})(?:度|℃|读)/g)
    if (matches === null || matches.length === 0) return -1
    const token = matches[matches.length - 1].replace(/度|℃|读/g, '')
    if (/^-?\d+$/.test(token)) return Number.parseInt(token)
    return this.chineseNumber(token)
  }

  private firstNumber(text: string): number {
    const arabic = text.match(/-?\d{1,3}/)
    if (arabic !== null && arabic.length > 0) return Number.parseInt(arabic[0])
    const chinese = text.match(/[零〇一二两三四五六七八九十]{1,4}/)
    return chinese === null || chinese.length === 0 ? -1 : this.chineseNumber(chinese[0])
  }

  private chineseNumber(token: string): number {
    const digits: string[] = ['零', '一', '二', '三', '四', '五', '六', '七', '八', '九']
    if (token === '〇') return 0
    if (token === '两') return 2
    if (token === '十') return 10
    const tenIndex = token.indexOf('十')
    if (tenIndex >= 0) {
      const left = tenIndex === 0 ? 1 : this.singleChineseDigit(token.substring(0, tenIndex))
      const right = tenIndex === token.length - 1 ? 0 : this.singleChineseDigit(token.substring(tenIndex + 1))
      return left < 0 || right < 0 ? -1 : left * 10 + right
    }
    let valueText = ''
    for (let i = 0; i < token.length; i++) {
      const digit = token[i] === '〇' ? 0 : (token[i] === '两' ? 2 : digits.indexOf(token[i]))
      if (digit < 0) return -1
      valueText += `${digit}`
    }
    return valueText.length > 0 ? Number.parseInt(valueText) : -1
  }

  private singleChineseDigit(token: string): number {
    if (token === '零' || token === '〇') return 0
    if (token === '一') return 1
    if (token === '二' || token === '两') return 2
    if (token === '三') return 3
    if (token === '四') return 4
    if (token === '五') return 5
    if (token === '六') return 6
    if (token === '七') return 7
    if (token === '八') return 8
    if (token === '九') return 9
    return -1
  }

  private isSafeControlText(text: string): boolean {
    return text.length > 0 && !this.containsAny(text, CONTROL_BLOCKERS)
  }

  private isLivingLightIntent(text: string): boolean {
    return !this.containsAny(text, UNSUPPORTED_LIGHT_LOCATIONS) && this.containsAny(text, LIGHT_DEVICE_TERMS)
  }

  private containsAny(text: string, phrases: string[]): boolean {
    for (let i = 0; i < phrases.length; i++) {
      if (text.indexOf(phrases[i]) >= 0) return true
    }
    return false
  }

  private createIntent(type: VoiceIntentType, target: string, power: boolean,
    rawText: string, normalizedText: string, queryAttribute: string = ''): VoiceIntent {
    return {
      type: type,
      target: target,
      power: power,
      temperature: 0,
      percentage: -1,
      mode: '',
      sensor: '',
      queryAttribute: queryAttribute,
      rawText: rawText,
      normalizedText: normalizedText
    }
  }
}
