import { VoiceIntent, VoiceIntentType } from '../voice/VoiceIntentParser'
import { PlannerContext, PlannerGoal, PlannerMode, PlannerPolicy, PlannerRequest, PlannerSource } from './PlannerTypes'

function emptyGoal(type: string, scene: string = ''): PlannerGoal {
  return {
    type: type,
    target: '',
    power: false,
    temperature: 0,
    percentage: -1,
    mode: '',
    scene: scene,
    explicitFields: []
  }
}

function defaultPolicy(allowAdditionalTools: boolean): PlannerPolicy {
  return {
    allowAdditionalTools: allowAdditionalTools,
    allowedTools: ['light.set', 'curtain.set', 'ac.set'],
    forbiddenTools: ['door.open', 'door.close', 'door.lock', 'door.unlock',
      'alarm.enable', 'alarm.disable', 'alarm.ack', 'alarm.reset']
  }
}

export function voiceIntentToPlannerGoal(intent: VoiceIntent): PlannerGoal | null {
  if (intent.type === VoiceIntentType.COMFORT_WARMER) return emptyGoal('comfort_warmer')
  if (intent.type === VoiceIntentType.COMFORT_COOLER) return emptyGoal('comfort_cooler')
  if (intent.type === VoiceIntentType.SLEEP_SCENE) return emptyGoal('sleep', 'sleep')
  if (intent.type === VoiceIntentType.AWAY_SCENE) return emptyGoal('away', 'away')
  if (intent.type === VoiceIntentType.HOME_SCENE) return emptyGoal('home', 'home')
  return null
}

export function buildVoicePlannerRequest(intent: VoiceIntent, context: PlannerContext): PlannerRequest | null {
  const goal = voiceIntentToPlannerGoal(intent)
  if (goal === null) return null
  return {
    schemaVersion: 1,
    requestId: `voice-${Date.now()}`,
    createdAtMs: Date.now(),
    expiresAtMs: Date.now() + 30000,
    source: PlannerSource.VOICE,
    mode: PlannerMode.GOAL,
    authority: 90,
    sourceConfidence: 1,
    goals: [goal],
    policy: defaultPolicy(true),
    context: context
  }
}

export function buildFederatedPlannerRequest(need: string, confidence: number,
  context: PlannerContext): PlannerRequest | null {
  const allowedNeeds: string[] = [
    'lighting_brighten_needed', 'lighting_reduce_needed', 'thermal_cooler_needed',
    'thermal_warmer_needed', 'away_candidate'
  ]
  if (allowedNeeds.indexOf(need) < 0) return null
  return {
    schemaVersion: 1,
    requestId: `federated-${Date.now()}`,
    createdAtMs: Date.now(),
    expiresAtMs: Date.now() + 30000,
    source: PlannerSource.FEDERATED,
    mode: PlannerMode.SUGGESTION,
    authority: 20,
    sourceConfidence: confidence,
    goals: [emptyGoal(need)],
    policy: defaultPolicy(true),
    context: context
  }
}
