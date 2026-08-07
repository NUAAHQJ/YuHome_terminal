export interface PerformanceEvent {
  version: number
  traceId: string
  category: string
  stage: string
  timestampMs: number
  seq: number
  success: boolean
  detail: string
}

let traceCounter: number = 0

function asciiSafeDetail(value: string): string {
  let result = ''
  for (let index = 0; index < value.length; index++) {
    const code = value.charCodeAt(index)
    if (code >= 32 && code <= 126) {
      result += value.charAt(index)
    } else {
      result += `[U+${code.toString(16).toUpperCase()}]`
    }
  }
  return result
}

export function createPerformanceTrace(category: string): string {
  traceCounter = (traceCounter % 999999) + 1
  return `${category.toUpperCase()}-${Date.now()}-${traceCounter}`
}

export function emitPerformanceEvent(traceId: string, category: string, stage: string,
  seq: number = 0, success: boolean = true, detail: string = ''): void {
  if (traceId.length === 0) {
    return
  }
  const event: PerformanceEvent = {
    version: 1,
    traceId,
    category,
    stage,
    timestampMs: Date.now(),
    seq,
    success,
    detail: asciiSafeDetail(detail)
  }
  console.info(`[PERF] ${JSON.stringify(event)}`)
}
