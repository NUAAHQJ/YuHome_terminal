import { common } from '@kit.AbilityKit'
import { PlannerContext, PlannerGoal, PlannerProposal, PlannerRequest } from './PlannerTypes'

interface PlannerLayer {
  weight: number[][]
  bias: number[]
}

interface PlannerOutputHead {
  name: string
  offset: number
  size: number
  labels: string[]
}

interface PlannerModelPackage {
  schema_version: number
  model_id: string
  version: number
  feature_names: string[]
  input_size: number
  output_size: number
  layers: PlannerLayer[]
  heads: PlannerOutputHead[]
}

const MODEL_RAW_FILE: string = 'planner/action_planner_v1.json'
const MODEL_ID: string = 'yuhome_action_planner_mlp'
const MODEL_SCHEMA_VERSION: number = 1
const STATE_MAX_AGE_MS: number = 30000
const GOAL_NAMES: string[] = [
  'away', 'sleep', 'home', 'comfort_warmer', 'comfort_cooler',
  'light_on', 'light_off', 'curtain_open', 'curtain_close',
  'ac_on', 'ac_off', 'ac_temperature', 'ac_mode',
  'lighting_brighten_needed', 'lighting_reduce_needed',
  'thermal_cooler_needed', 'thermal_warmer_needed', 'away_candidate'
]

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
      result += String.fromCharCode(((first & 0x0F) << 12) | ((second & 0x3F) << 6) |
        (third & 0x3F))
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

export class ActionPlanner {
  private context: common.UIAbilityContext | null = null
  private model: PlannerModelPackage | null = null
  private ready: boolean = false

  async initialize(context: common.UIAbilityContext): Promise<boolean> {
    this.context = context
    this.ready = false
    try {
      const raw = await context.resourceManager.getRawFileContent(MODEL_RAW_FILE)
      const model = JSON.parse(utf8Decode(raw)) as PlannerModelPackage
      this.validateModel(model)
      this.model = model
      this.ready = true
      console.info(`[Planner][ready] model=${model.model_id} version=${model.version} ` +
        `features=${model.input_size} outputs=${model.output_size}`)
    } catch (err) {
      this.model = null
      console.info(`[Planner][load-fail] ${(err as Error).message}`)
    }
    return this.ready
  }

  isReady(): boolean {
    return this.ready && this.model !== null
  }

  infer(request: PlannerRequest): PlannerProposal | null {
    if (!this.isReady() || this.model === null) {
      return null
    }
    if (request.context.stateTimestampMs <= 0 ||
      Date.now() - request.context.stateTimestampMs > STATE_MAX_AGE_MS) {
      console.info('[Planner][reject] device state is stale')
      return null
    }
    const features = this.buildFeatures(request)
    const logits = this.forward(features, this.model)
    const livingHead = this.headLogits(logits, 'living_light')
    const bedroomHead = this.headLogits(logits, 'bedroom_light')
    const curtainHead = this.headLogits(logits, 'curtain')
    const acPowerHead = this.headLogits(logits, 'ac_power')
    const acModeHead = this.headLogits(logits, 'ac_mode')
    const acTemperatureHead = this.headLogits(logits, 'ac_temperature')
    if (livingHead === null || bedroomHead === null || curtainHead === null ||
      acPowerHead === null || acModeHead === null || acTemperatureHead === null) {
      return null
    }
    const living = this.decode(livingHead, ['no_change', 'on', 'off'])
    const bedroom = this.decode(bedroomHead, ['no_change', 'on', 'off'])
    const curtain = this.decode(curtainHead, ['no_change'])
    const acPower = this.decode(acPowerHead, ['no_change', 'on', 'off'])
    const acMode = this.decode(acModeHead, ['no_change', 'cool', 'heat'])
    const acTemperature = this.decode(acTemperatureHead, ['no_change'])
    const curtainIndex = this.argmax(curtainHead)
    const temperatureIndex = this.argmax(acTemperatureHead)
    const confidence = (this.maxProbability(livingHead) + this.maxProbability(bedroomHead) +
      this.maxProbability(curtainHead) + this.maxProbability(acPowerHead) +
      this.maxProbability(acModeHead) + this.maxProbability(acTemperatureHead)) / 6
    return {
      livingLight: living,
      bedroomLight: bedroom,
      curtainChanged: curtainIndex > 0,
      curtainPercent: curtainIndex > 0 ? curtainIndex - 1 : request.context.curtainPercent,
      acPower: acPower,
      acMode: acMode,
      acTemperatureChanged: temperatureIndex > 0,
      acTemperature: temperatureIndex > 0 ? temperatureIndex + 19 : request.context.acTemperature,
      confidence: confidence,
      modelVersion: this.model.version
    }
  }

  private buildFeatures(request: PlannerRequest): number[] {
    const features: number[] = new Array<number>(this.model === null ? 0 : this.model.input_size).fill(0)
    for (const goal of request.goals) {
      let goalName = goal.scene.length > 0 ? goal.scene : goal.type
      const index = GOAL_NAMES.indexOf(goalName)
      if (index >= 0) {
        features[index] = 1
      }
    }
    const context = request.context
    const offset = GOAL_NAMES.length
    features[offset] = request.source === 'federated' ? 1 : 0
    features[offset + 1] = Math.max(0, Math.min(1, request.sourceConfidence))
    features[offset + 2] = context.livingLightOn ? 1 : 0
    features[offset + 3] = context.bedroomLightOn ? 1 : 0
    features[offset + 4] = Math.max(0, Math.min(1, context.curtainPercent / 100))
    features[offset + 5] = context.acPower ? 1 : 0
    features[offset + 6] = context.acMode === 'cool' ? 1 : 0
    features[offset + 7] = context.acMode === 'heat' ? 1 : 0
    features[offset + 8] = Math.max(0, Math.min(1, (context.acTemperature - 16) / 14))
    features[offset + 9] = Math.max(0, Math.min(1, (context.indoorTemperature - 10) / 30))
    features[offset + 10] = Math.max(0, Math.min(1, context.indoorHumidity / 100))
    features[offset + 11] = Math.max(0, Math.min(1, context.lightLevel / 500))
    features[offset + 12] = context.presence ? 1 : 0
    features[offset + 13] = context.awayMode ? 1 : 0
    features[offset + 14] = Math.max(0, Math.min(1, (context.preferredTemperature - 16) / 14))
    return features
  }

  private forward(input: number[], model: PlannerModelPackage): number[] {
    let current = input
    for (let layerIndex = 0; layerIndex < model.layers.length; layerIndex++) {
      const layer = model.layers[layerIndex]
      const next: number[] = []
      for (let row = 0; row < layer.weight.length; row++) {
        let value = layer.bias[row]
        for (let column = 0; column < current.length; column++) {
          value += layer.weight[row][column] * current[column]
        }
        next.push(layerIndex === model.layers.length - 1 ? value : Math.max(0, value))
      }
      current = next
    }
    return current
  }

  private headLogits(logits: number[], name: string): number[] | null {
    if (this.model === null) return null
    for (const head of this.model.heads) {
      if (head.name === name) {
        return logits.slice(head.offset, head.offset + head.size)
      }
    }
    return null
  }

  private decode(logits: number[], fallback: string[]): string {
    const index = this.argmax(logits)
    if (index === 0) return 'no_change'
    return fallback[index] ?? 'no_change'
  }

  private argmax(values: number[]): number {
    let index = 0
    for (let i = 1; i < values.length; i++) {
      if (values[i] > values[index]) index = i
    }
    return index
  }

  private maxProbability(logits: number[]): number {
    const maximum = Math.max(...logits)
    const values = logits.map((value: number): number => Math.exp(value - maximum))
    const sum = values.reduce((total: number, value: number): number => total + value, 0)
    return sum > 0 ? Math.max(...values) / sum : 0
  }

  private validateModel(model: PlannerModelPackage): void {
    if (model.schema_version !== MODEL_SCHEMA_VERSION || model.model_id !== MODEL_ID) {
      throw new Error('规划模型包格式不匹配')
    }
    if (model.input_size !== GOAL_NAMES.length + 15 || model.output_size !== 126 || model.layers.length !== 3) {
      throw new Error('规划模型维度不匹配')
    }
    let inputSize = model.input_size
    for (let i = 0; i < model.layers.length; i++) {
      const layer = model.layers[i]
      if (layer.weight.length !== layer.bias.length || layer.weight.length === 0 ||
        layer.weight[0].length !== inputSize) {
        throw new Error(`规划模型第${i}层维度错误`)
      }
      inputSize = layer.weight.length
    }
    if (inputSize !== model.output_size) {
      throw new Error('规划模型输出维度错误')
    }
  }
}
