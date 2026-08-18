import http from '@ohos.net.http'
import fs from '@ohos.file.fs'
import { common } from '@kit.AbilityKit'
import { ensureTlsIdentityFiles } from '../mqtt/TlsIdentityFiles'
import { FederatedObservation } from './FederatedDataCollector'

interface NormalizationStat {
  mean: number
  std: number
  min: number
  max: number
}

interface NormalizationMap {
  temperature: NormalizationStat
  humidity: NormalizationStat
  light: NormalizationStat
  curtain_percent: NormalizationStat
  last_light_minutes: NormalizationStat
  last_curtain_minutes: NormalizationStat
  last_ac_minutes: NormalizationStat
  temp_trend: NormalizationStat
  light_trend: NormalizationStat
  time_since_wake: NormalizationStat
}

interface ActionThresholds {
}

interface ModelInferenceMetadata {
  decision?: string
  calibration_baked_into_bias?: boolean
}

interface ModelParameters {
  fc1_weight: number[][]
  fc1_bias: number[]
  fc2_weight: number[][]
  fc2_bias: number[]
  fc3_weight: number[][]
  fc3_bias: number[]
}

export interface ModelMetrics {
  accuracy?: number
  macro_f1?: number
  action_recall?: number
  false_trigger_rate?: number
}

export interface ModelComparison {
  current_version: number
  candidate_version: number
  sample_count: number
  action_sample_count: number
  minimum_samples: number
  minimum_action_samples: number
  current_metrics: ModelMetrics
  candidate_metrics: ModelMetrics
  recommend_candidate: boolean
  decision: string
  reason: string
  evaluated_at: string
}

interface BehaviorModelPackage {
  schema_version: number
  model_id: string
  version: number
  generated_at: string
  source_sha256: string
  package_sha256: string
  architecture: number[]
  feature_names: string[]
  labels: string[]
  normalization: NormalizationMap
  thresholds: ActionThresholds
  inference?: ModelInferenceMetadata
  parameters: ModelParameters
  comparison: ModelComparison
}

export interface BehaviorSuggestion {
  action: string
  confidence: number
  reason: string
  modelVersion: number
  createdAt: number
}

export interface BehaviorModelStatus {
  activeVersion: number
  candidateVersion: number
  source: string
  message: string
  comparison: ModelComparison
}

const MODEL_FILE: string = 'yujia_behavior_model.json'
const MIN_SUGGESTION_CONFIDENCE: number = 0.75
const BEHAVIOR_NEED_LABELS: string[] = [
  'no_action', 'lighting_brighten_needed', 'lighting_reduce_needed',
  'thermal_cooler_needed', 'thermal_warmer_needed', 'away_candidate'
]

function defaultComparison(): ModelComparison {
  return {
    current_version: 0,
    candidate_version: 0,
    sample_count: 0,
    action_sample_count: 0,
    minimum_samples: 100,
    minimum_action_samples: 10,
    current_metrics: {},
    candidate_metrics: {},
    recommend_candidate: false,
    decision: 'insufficient_data',
    reason: '真实家庭样本不足，继续使用基础模型',
    evaluated_at: ''
  }
}

function utf8Decode(bytes: Uint8Array): string {
  let result = ''
  for (let index = 0; index < bytes.length; index++) {
    const first = bytes[index]
    if (first < 0x80) {
      result += String.fromCharCode(first)
    } else if (first < 0xE0 && index + 1 < bytes.length) {
      const second = bytes[++index]
      result += String.fromCharCode(((first & 0x1F) << 6) | (second & 0x3F))
    } else if (first < 0xF0 && index + 2 < bytes.length) {
      const second = bytes[++index]
      const third = bytes[++index]
      result += String.fromCharCode(((first & 0x0F) << 12) | ((second & 0x3F) << 6) | (third & 0x3F))
    } else if (index + 3 < bytes.length) {
      const second = bytes[++index]
      const third = bytes[++index]
      const fourth = bytes[++index]
      const codePoint = ((first & 0x07) << 18) | ((second & 0x3F) << 12) |
        ((third & 0x3F) << 6) | (fourth & 0x3F)
      const adjusted = codePoint - 0x10000
      result += String.fromCharCode(0xD800 + (adjusted >> 10), 0xDC00 + (adjusted & 0x3FF))
    }
  }
  return result
}

export class BehaviorModelEngine {
  private context: common.UIAbilityContext | null = null
  private pcUrl: string = ''
  private certificateDirectory: string = ''
  private activeModel: BehaviorModelPackage | null = null
  private candidateModel: BehaviorModelPackage | null = null
  private lastLightActionAt: number = -1
  private lastCurtainActionAt: number = -1
  private lastAcActionAt: number = -1
  private recentActions: number[] = []
  private environmentHistory: FederatedObservation[] = []

  async initialize(context: common.UIAbilityContext, pcUrl: string,
    certificateDirectory: string): Promise<BehaviorModelStatus> {
    this.context = context
    this.pcUrl = pcUrl.replace(/\/$/, '')
    this.certificateDirectory = certificateDirectory
    await this.loadBundledModel()
    await this.loadSavedModel()
    try {
      await this.refreshCandidate()
    } catch (err) {
      console.info(`[Federated][model-sync-fail] ${(err as Error).message}`)
    }
    return this.getStatus()
  }

  private async loadBundledModel(): Promise<void> {
    if (this.context === null) {
      return
    }
    const raw = await this.context.resourceManager.getRawFileContent('federated/global_v0.json')
    const model = this.parseAndValidate(utf8Decode(raw))
    this.activeModel = model
  }

  private async loadSavedModel(): Promise<void> {
    if (this.context === null || this.activeModel === null) {
      return
    }
    const path = `${this.context.filesDir}/${MODEL_FILE}`
    const exists = await fs.access(path).catch(() => false)
    if (!exists) {
      return
    }
    try {
      const saved = this.parseAndValidate(await fs.readText(path))
      if (saved.version >= this.activeModel.version && saved.comparison.recommend_candidate) {
        this.activeModel = saved
      }
    } catch (err) {
      console.info(`[Federated][model-saved-invalid] ${(err as Error).message}`)
    }
  }

  async refreshCandidate(): Promise<BehaviorModelStatus> {
    if (this.pcUrl.length === 0) {
      return this.getStatus()
    }
    const request = http.createHttp()
    try {
      const paths = await ensureTlsIdentityFiles(this.certificateDirectory)
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        connectTimeout: 8000,
        readTimeout: 8000,
        caPath: paths.caPath,
        clientCert: { certPath: paths.certPath, keyPath: paths.keyPath }
      }
      const result = await request.request(`${this.pcUrl}/model/latest`, options)
      if (result.responseCode < 200 || result.responseCode >= 300) {
        throw new Error(`HTTP ${result.responseCode}`)
      }
      const text = typeof result.result === 'string' ? result.result : JSON.stringify(result.result)
      const candidate = this.parseAndValidate(text)
      this.candidateModel = candidate
      if (this.activeModel === null ||
        (candidate.version > this.activeModel.version && candidate.comparison.recommend_candidate)) {
        this.activeModel = candidate
        await this.saveActiveModel(candidate)
      }
    } finally {
      request.destroy()
    }
    return this.getStatus()
  }

  private async saveActiveModel(model: BehaviorModelPackage): Promise<void> {
    if (this.context === null) {
      return
    }
    const file = await fs.open(`${this.context.filesDir}/${MODEL_FILE}`,
      fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE)
    try {
      await fs.write(file.fd, JSON.stringify(model))
    } finally {
      fs.closeSync(file)
    }
  }

  private parseAndValidate(text: string): BehaviorModelPackage {
    const model = JSON.parse(text) as BehaviorModelPackage
    if (model.schema_version !== 1 || model.model_id !== 'yujia_behavior_mlp') {
      throw new Error('不支持的模型包格式')
    }
    if (model.architecture.length !== 4 || model.architecture[0] !== 25 ||
      model.architecture[1] !== 32 || model.architecture[2] !== 16 ||
      model.architecture[3] !== model.labels.length ||
      model.labels.length !== BEHAVIOR_NEED_LABELS.length) {
      throw new Error('模型结构与大禹推理器不匹配')
    }
    for (let index = 0; index < BEHAVIOR_NEED_LABELS.length; index++) {
      if (model.labels[index] !== BEHAVIOR_NEED_LABELS[index]) {
        throw new Error('模型标签与需求规划协议不匹配')
      }
    }
    this.checkMatrix(model.parameters.fc1_weight, 32, 25, 'fc1')
    this.checkVector(model.parameters.fc1_bias, 32, 'fc1_bias')
    this.checkMatrix(model.parameters.fc2_weight, 16, 32, 'fc2')
    this.checkVector(model.parameters.fc2_bias, 16, 'fc2_bias')
    this.checkMatrix(model.parameters.fc3_weight, model.labels.length, 16, 'fc3')
    this.checkVector(model.parameters.fc3_bias, model.labels.length, 'fc3_bias')
    const output = this.forward(new Array<number>(25).fill(0), model)
    this.checkVector(output, model.labels.length, 'self_test')
    return model
  }

  private checkMatrix(value: number[][], rows: number, columns: number, name: string): void {
    if (!value || value.length !== rows) {
      throw new Error(`${name}行数错误`)
    }
    for (let row = 0; row < value.length; row++) {
      this.checkVector(value[row], columns, name)
    }
  }

  private checkVector(value: number[], length: number, name: string): void {
    if (!value || value.length !== length) {
      throw new Error(`${name}维度错误`)
    }
    for (let index = 0; index < value.length; index++) {
      if (!Number.isFinite(value[index])) {
        throw new Error(`${name}包含无效参数`)
      }
    }
  }

  private dense(input: number[], weights: number[][], bias: number[], relu: boolean): number[] {
    const output: number[] = []
    for (let row = 0; row < weights.length; row++) {
      let value = bias[row]
      for (let column = 0; column < input.length; column++) {
        value += weights[row][column] * input[column]
      }
      output.push(relu ? Math.max(0, value) : value)
    }
    return output
  }

  private forward(features: number[], model: BehaviorModelPackage): number[] {
    const layer1 = this.dense(features, model.parameters.fc1_weight, model.parameters.fc1_bias, true)
    const layer2 = this.dense(layer1, model.parameters.fc2_weight, model.parameters.fc2_bias, true)
    return this.dense(layer2, model.parameters.fc3_weight, model.parameters.fc3_bias, false)
  }

  infer(observation: FederatedObservation): BehaviorSuggestion | null {
    const timestamp = new Date(observation.timestamp).getTime()
    if (!Number.isFinite(timestamp)) {
      return null
    }
    this.pruneHistory(timestamp)
    let suggestion: BehaviorSuggestion | null = null
    if (observation.user_action === 'no_action' && this.activeModel !== null) {
      const features = this.buildFeatures(observation, timestamp, this.activeModel.normalization)
      const logits = this.forward(features, this.activeModel)
      const bestAction = this.argmax(logits)
      if (bestAction > 0) {
        const probabilities = this.softmax(logits)
        const actionConfidence = probabilities[bestAction]
        const noActionConfidence = probabilities[0]
        if (actionConfidence >= MIN_SUGGESTION_CONFIDENCE && actionConfidence > noActionConfidence) {
          suggestion = {
            action: this.activeModel.labels[bestAction],
            confidence: actionConfidence,
            reason: this.reasonFor(this.activeModel.labels[bestAction], observation),
            modelVersion: this.activeModel.version,
            createdAt: timestamp
          }
        } else {
          console.info(`[Federated][suggestion-rejected] action=${this.activeModel.labels[bestAction]} ` +
            `confidence=${actionConfidence.toFixed(4)} noAction=${noActionConfidence.toFixed(4)}`)
        }
      }
    }
    this.updateHistory(observation, timestamp)
    return suggestion
  }

  private buildFeatures(observation: FederatedObservation, timestamp: number,
    normalization: NormalizationMap): number[] {
    const date = new Date(timestamp)
    const hour = date.getHours()
    const minute = date.getMinutes()
    const weekday = (date.getDay() + 6) % 7
    const previous = this.environmentHistory.length > 0 ? this.environmentHistory[0] : observation
    const wakeMinutes = 7 * 60
    const currentMinutes = hour * 60 + minute
    const lastLight = this.minutesSince(timestamp, this.lastLightActionAt)
    const lastCurtain = this.minutesSince(timestamp, this.lastCurtainActionAt)
    const lastAc = this.minutesSince(timestamp, this.lastAcActionAt)
    const features: number[] = [
      Math.sin(2 * Math.PI * hour / 24), Math.cos(2 * Math.PI * hour / 24),
      Math.sin(2 * Math.PI * minute / 60), Math.cos(2 * Math.PI * minute / 60),
      Math.sin(2 * Math.PI * weekday / 7), Math.cos(2 * Math.PI * weekday / 7),
      weekday < 5 ? 1 : 0, (date.getMonth() + 1) / 12,
      this.normalize(observation.indoor_temp, normalization.temperature),
      this.normalize(observation.indoor_humidity, normalization.humidity),
      this.normalize(observation.light_level, normalization.light),
      this.normalize(observation.curtain_percent, normalization.curtain_percent),
      this.normalizeOptional(lastLight, normalization.last_light_minutes),
      this.normalizeOptional(lastCurtain, normalization.last_curtain_minutes),
      this.normalizeOptional(lastAc, normalization.last_ac_minutes),
      this.normalize(observation.indoor_temp - previous.indoor_temp, normalization.temp_trend),
      this.normalize(observation.light_level - previous.light_level, normalization.light_trend),
      this.normalizeOptional(currentMinutes >= wakeMinutes ? currentMinutes - wakeMinutes : -1,
        normalization.time_since_wake),
      observation.presence, observation.light_on ? 1 : 0, observation.ac_on ? 1 : 0,
      observation.away_mode ? 1 : 0,
      this.countRecent(timestamp, 5), this.countRecent(timestamp, 15), this.countRecent(timestamp, 30)
    ]
    return features
  }

  private normalize(value: number, stat: NormalizationStat): number {
    return stat.std > 0 ? (value - stat.mean) / stat.std : 0
  }

  private normalizeOptional(value: number, stat: NormalizationStat): number {
    return value < 0 ? -1 : this.normalize(value, stat)
  }

  private minutesSince(now: number, previous: number): number {
    return previous < 0 ? -1 : Math.max(0, (now - previous) / 60000)
  }

  private countRecent(now: number, minutes: number): number {
    const cutoff = now - minutes * 60000
    return this.recentActions.filter((value: number): boolean => value >= cutoff).length
  }

  private pruneHistory(now: number): void {
    const cutoff = now - 30 * 60000
    this.recentActions = this.recentActions.filter((value: number): boolean => value >= cutoff)
    this.environmentHistory = this.environmentHistory.filter((item: FederatedObservation): boolean =>
      new Date(item.timestamp).getTime() >= cutoff)
  }

  private updateHistory(observation: FederatedObservation, timestamp: number): void {
    this.environmentHistory.push(observation)
    if (observation.user_action === 'no_action') {
      return
    }
    this.recentActions.push(timestamp)
    if (observation.user_action.startsWith('light_')) {
      this.lastLightActionAt = timestamp
    } else if (observation.user_action.startsWith('curtain_')) {
      this.lastCurtainActionAt = timestamp
    } else if (observation.user_action.startsWith('ac_')) {
      this.lastAcActionAt = timestamp
    }
  }

  private argmax(values: number[]): number {
    let best = 0
    for (let index = 1; index < values.length; index++) {
      if (values[index] > values[best]) best = index
    }
    return best
  }

  private softmax(logits: number[]): number[] {
    const maximum = Math.max(...logits)
    const values = logits.map((value: number): number => Math.exp(value - maximum))
    const sum = values.reduce((total: number, value: number): number => total + value, 0)
    return values.map((value: number): number => value / sum)
  }

  private reasonFor(action: string, observation: FederatedObservation): string {
    if (action === 'lighting_brighten_needed') return `当前光照 ${Math.round(observation.light_level)}，识别到需要增加有效照明`
    if (action === 'lighting_reduce_needed') return `当前光照 ${Math.round(observation.light_level)}，识别到需要减弱照明或保护隐私`
    if (action === 'thermal_cooler_needed') return `当前室温 ${observation.indoor_temp.toFixed(1)}℃，识别到制冷需求`
    if (action === 'thermal_warmer_needed') return `当前室温 ${observation.indoor_temp.toFixed(1)}℃，识别到制热需求`
    return '识别到可能适合离家场景，必须由用户确认'
  }

  getStatus(): BehaviorModelStatus {
    const activeVersion = this.activeModel ? this.activeModel.version : 0
    const candidateVersion = this.candidateModel ? this.candidateModel.version : activeVersion
    const comparison = this.candidateModel ? this.candidateModel.comparison :
      (this.activeModel ? this.activeModel.comparison : defaultComparison())
    return {
      activeVersion,
      candidateVersion,
      source: activeVersion > 0 ? '联邦聚合模型' : '内置基础模型',
      message: comparison.reason,
      comparison
    }
  }
}
