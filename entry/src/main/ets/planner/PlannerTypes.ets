export enum PlannerSource {
  VOICE = 'voice',
  FEDERATED = 'federated'
}

export enum PlannerMode {
  EXPLICIT = 'explicit',
  GOAL = 'goal',
  SUGGESTION = 'suggestion'
}

export interface PlannerGoal {
  type: string
  target: string
  power: boolean
  temperature: number
  percentage: number
  mode: string
  scene: string
  explicitFields: string[]
}

export interface PlannerPolicy {
  allowAdditionalTools: boolean
  allowedTools: string[]
  forbiddenTools: string[]
}

export interface PlannerContext {
  stateTimestampMs: number
  livingLightOn: boolean
  bedroomLightOn: boolean
  curtainPercent: number
  acPower: boolean
  acMode: string
  acTemperature: number
  indoorTemperature: number
  indoorHumidity: number
  lightLevel: number
  presence: boolean
  awayMode: boolean
  preferredTemperature: number
  livingLightOnline: boolean
  bedroomLightOnline: boolean
  curtainOnline: boolean
  acOnline: boolean
}

export interface PlannerRequest {
  schemaVersion: number
  requestId: string
  createdAtMs: number
  expiresAtMs: number
  source: PlannerSource
  mode: PlannerMode
  authority: number
  sourceConfidence: number
  goals: PlannerGoal[]
  policy: PlannerPolicy
  context: PlannerContext
}

export interface PlannerProposal {
  livingLight: string
  bedroomLight: string
  curtainChanged: boolean
  curtainPercent: number
  acPower: string
  acMode: string
  acTemperatureChanged: boolean
  acTemperature: number
  confidence: number
  modelVersion: number
}

export interface PlannerToolCall {
  tool: string
  target: string
  power: boolean
  percentage: number
  temperature: number
  mode: string
  reason: string
}

export interface PlannerPlan {
  safe: boolean
  message: string
  calls: PlannerToolCall[]
  confidence: number
  modelVersion: number
}
