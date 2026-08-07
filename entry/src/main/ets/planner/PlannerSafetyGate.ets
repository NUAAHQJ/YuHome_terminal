import { PlannerContext, PlannerGoal, PlannerPlan, PlannerPolicy, PlannerProposal, PlannerRequest, PlannerToolCall } from './PlannerTypes'

const FORBIDDEN_SECURITY_PREFIXES: string[] = ['door.', 'alarm.']

function isForbiddenSecurityTool(tool: string): boolean {
  for (const prefix of FORBIDDEN_SECURITY_PREFIXES) {
    if (tool.indexOf(prefix) === 0) return true
  }
  return false
}

function allows(policy: PlannerPolicy, tool: string): boolean {
  if (isForbiddenSecurityTool(tool)) return false
  if (policy.forbiddenTools.indexOf(tool) >= 0) return false
  return policy.allowedTools.indexOf(tool) >= 0
}

function call(tool: string, target: string, power: boolean, percentage: number,
  temperature: number, mode: string, reason: string): PlannerToolCall {
  return { tool, target, power, percentage, temperature, mode, reason }
}

function isGoal(request: PlannerRequest, name: string): boolean {
  return request.goals.some((goal: PlannerGoal): boolean =>
    goal.type === name || goal.scene === name)
}

function compileAtomicGoal(request: PlannerRequest, proposal: PlannerProposal): PlannerPlan {
  const context = request.context
  const goal = request.goals.length > 0 ? request.goals[0] : null
  if (goal === null) {
    return { safe: false, message: '缺少明确规划目标', calls: [], confidence: proposal.confidence, modelVersion: proposal.modelVersion }
  }
  const calls: PlannerToolCall[] = []
  if ((goal.type === 'light_on' || goal.type === 'light_off') && allows(request.policy, 'light.set')) {
    const targetOn = goal.type === 'light_on'
    if (context.livingLightOn !== targetOn) {
      calls.push(call('light.set', 'living', targetOn, -1, 0, '', '联邦明确建议'))
    }
  } else if ((goal.type === 'curtain_open' || goal.type === 'curtain_close') &&
    allows(request.policy, 'curtain.set')) {
    const percentage = goal.type === 'curtain_open' ? 100 : 0
    if (Math.round(context.curtainPercent) !== percentage) {
      calls.push(call('curtain.set', 'curtain', false, percentage, 0, '', '联邦明确建议'))
    }
  } else if ((goal.type === 'ac_on' || goal.type === 'ac_off') && allows(request.policy, 'ac.set')) {
    const targetOn = goal.type === 'ac_on'
    if (context.acPower !== targetOn) {
      calls.push(call('ac.set', 'ac', targetOn, -1, context.acTemperature, context.acMode, '联邦明确建议'))
    }
  } else {
    return { safe: false, message: '不允许的明确规划工具', calls: [], confidence: proposal.confidence, modelVersion: proposal.modelVersion }
  }
  return calls.length === 0 ?
    { safe: true, message: '设备已经处于目标状态', calls, confidence: proposal.confidence, modelVersion: proposal.modelVersion } :
    { safe: true, message: '已生成一项联邦设备建议', calls, confidence: proposal.confidence, modelVersion: proposal.modelVersion }
}

export function compilePlannerProposal(request: PlannerRequest, proposal: PlannerProposal): PlannerPlan {
  if (request.schemaVersion !== 1 || Date.now() > request.expiresAtMs) {
    return { safe: false, message: '规划请求已过期', calls: [], confidence: 0, modelVersion: proposal.modelVersion }
  }
  if (!Number.isFinite(proposal.confidence) || proposal.confidence < 0.55) {
    return { safe: false, message: '规划模型置信度不足，请确认后再执行', calls: [], confidence: proposal.confidence, modelVersion: proposal.modelVersion }
  }
  if (request.source === 'federated' && request.sourceConfidence < 0.75) {
    return { safe: false, message: '联邦需求置信度不足，保留为观察记录', calls: [], confidence: proposal.confidence, modelVersion: proposal.modelVersion }
  }
  if (request.source === 'federated' && (!contextOnline(request.context))) {
    return { safe: false, message: '设备状态未就绪，不能生成联邦演示计划', calls: [], confidence: proposal.confidence, modelVersion: proposal.modelVersion }
  }
  if (!request.policy.allowAdditionalTools) {
    return compileAtomicGoal(request, proposal)
  }
  const context: PlannerContext = request.context
  const calls: PlannerToolCall[] = []
  const allowAdditional = request.policy.allowAdditionalTools
  const primaryGoal = request.goals.length > 0 ? request.goals[0] : null
  const allowLight = allows(request.policy, 'light.set')
  const allowCurtain = allows(request.policy, 'curtain.set')
  const allowAc = allows(request.policy, 'ac.set')

  // An explicit MLP atomic suggestion is projected to its one requested tool.
  const allowLiving = allowAdditional || isGoal(request, 'light_on') || isGoal(request, 'light_off')
  const allowCurtainAction = allowAdditional || isGoal(request, 'curtain_open') || isGoal(request, 'curtain_close')
  const allowAcAction = allowAdditional || isGoal(request, 'ac_on') || isGoal(request, 'ac_off')

  if (allowLiving && allowLight && proposal.livingLight !== 'no_change') {
    const targetOn = proposal.livingLight === 'on'
    if (context.livingLightOn !== targetOn) {
      calls.push(call('light.set', 'living', targetOn, -1, 0, '', '规划模型'))
    }
  }
  if (allowAdditional && allowLight && proposal.bedroomLight !== 'no_change') {
    const targetOn = proposal.bedroomLight === 'on'
    if (context.bedroomLightOn !== targetOn) {
      calls.push(call('light.set', 'bedroom', targetOn, -1, 0, '', '规划模型'))
    }
  }
  if (allowCurtainAction && allowCurtain && proposal.curtainChanged) {
    const percentage = Math.max(0, Math.min(100, Math.round(proposal.curtainPercent)))
    if (Math.round(context.curtainPercent) !== percentage) {
      calls.push(call('curtain.set', 'curtain', false, percentage, 0, '', '规划模型'))
    }
  }

  const acGoalAllowed = allowAcAction || allowAdditional || isGoal(request, 'comfort_warmer') ||
    isGoal(request, 'comfort_cooler') || isGoal(request, 'sleep')
  if (acGoalAllowed && allowAc && (proposal.acPower !== 'no_change' || proposal.acMode !== 'no_change' ||
    proposal.acTemperatureChanged)) {
    const targetPower = proposal.acPower === 'no_change' ? context.acPower : proposal.acPower === 'on'
    const targetMode = proposal.acMode === 'no_change' ? context.acMode : proposal.acMode
    const targetTemperature = proposal.acTemperatureChanged ?
      Math.max(20, Math.min(30, Math.round(proposal.acTemperature))) : context.acTemperature
    if (targetPower !== context.acPower || targetMode !== context.acMode ||
      targetTemperature !== context.acTemperature) {
      calls.push(call('ac.set', 'ac', targetPower, -1, targetTemperature, targetMode, '规划模型'))
    }
  }

  if (calls.length === 0) {
    return { safe: true, message: '设备已经处于目标状态', calls: [], confidence: proposal.confidence, modelVersion: proposal.modelVersion }
  }
  if (request.source === 'federated' && calls.length > 2) {
    calls.splice(2)
  }
  if (primaryGoal !== null && primaryGoal.type === 'away' && request.mode === 'suggestion') {
    return { safe: true, message: '已生成离家场景计划，请确认后执行', calls, confidence: proposal.confidence, modelVersion: proposal.modelVersion }
  }
  return { safe: true, message: `规划完成，共${calls.length}项设备动作`, calls, confidence: proposal.confidence, modelVersion: proposal.modelVersion }
}

function contextOnline(context: PlannerContext): boolean {
  return context.livingLightOnline && context.curtainOnline && context.acOnline
}
