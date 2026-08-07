import http from '@ohos.net.http'
import { ensureTlsIdentityFiles } from '../mqtt/TlsIdentityFiles'

export interface FederatedObservation {
  timestamp: string
  indoor_temp: number
  indoor_humidity: number
  light_level: number
  presence: number
  light_on: boolean
  curtain_percent: number
  ac_on: boolean
  away_mode: boolean
  user_action: string
  source: string
  training_eligible: boolean
}

interface FederatedUploadPayload {
  schema_version: number
  client_id: string
  batch_id: string
  num_samples: number
  samples: FederatedObservation[]
}

interface FederatedHeaders {
  'Content-Type': string
  'X-YuJia-Token'?: string
}

export type FederatedSnapshotProvider = () => FederatedObservation
export type FederatedObservationListener = (observation: FederatedObservation) => void

const DEFAULT_PC_URL: string = 'https://192.168.3.5:5443'
const DEFAULT_SAMPLE_INTERVAL_MS: number = 5 * 60 * 1000
const DEFAULT_BATCH_SIZE: number = 12
const MAX_BUFFERED_SAMPLES: number = 500

function localIsoTimestamp(): string {
  const now = new Date()
  const offsetMinutes = -now.getTimezoneOffset()
  const sign = offsetMinutes >= 0 ? '+' : '-'
  const absoluteOffset = Math.abs(offsetMinutes)
  const pad = (value: number): string => value.toString().padStart(2, '0')
  return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}` +
    `T${pad(now.getHours())}:${pad(now.getMinutes())}:${pad(now.getSeconds())}.` +
    `${now.getMilliseconds().toString().padStart(3, '0')}${sign}${pad(Math.floor(absoluteOffset / 60))}:${pad(absoluteOffset % 60)}`
}

export class FederatedDataCollector {
  private clientId: string = 'family_a'
  private pcUrl: string = DEFAULT_PC_URL
  private token: string = ''
  private certificateDirectory: string = ''
  private samples: FederatedObservation[] = []
  private timerId: number = -1
  private uploadInFlight: boolean = false
  private batchSequence: number = 0
  private provider: FederatedSnapshotProvider | null = null
  private listener: FederatedObservationListener | null = null

  configure(
    pcUrl: string,
    clientId: string = 'family_a',
    token: string = '',
    certificateDirectory: string = ''
  ): void {
    const normalized = pcUrl.trim().replace(/\/$/, '')
    if (normalized.startsWith('http://') || normalized.startsWith('https://')) {
      this.pcUrl = normalized
    }
    this.clientId = clientId.length > 0 ? clientId : 'family_a'
    this.token = token
    this.certificateDirectory = certificateDirectory
  }

  start(provider: FederatedSnapshotProvider, listener: FederatedObservationListener | null = null): void {
    this.stop()
    this.provider = provider
    this.listener = listener
    this.capture('no_action', 'periodic')
    this.timerId = setInterval(() => {
      this.capture('no_action', 'periodic')
    }, DEFAULT_SAMPLE_INTERVAL_MS)
    console.info(`[Federated][collector] started pc=${this.pcUrl} interval=${DEFAULT_SAMPLE_INTERVAL_MS}`)
  }

  stop(): void {
    if (this.timerId !== -1) {
      clearInterval(this.timerId)
      this.timerId = -1
    }
    this.provider = null
    this.listener = null
  }

  recordAction(action: string, source: string = 'dayu', trainingEligible: boolean = true): void {
    this.capture(action, source, trainingEligible)
  }

  private capture(action: string, source: string, trainingEligible: boolean = true): void {
    if (this.provider === null) {
      return
    }
    const sample = this.provider()
    sample.timestamp = localIsoTimestamp()
    sample.user_action = action
    sample.source = source
    sample.training_eligible = trainingEligible
    if (this.listener !== null) {
      this.listener(sample)
    }
    this.samples.push(sample)
    if (this.samples.length > MAX_BUFFERED_SAMPLES) {
      this.samples.splice(0, this.samples.length - MAX_BUFFERED_SAMPLES)
    }
    console.info(`[Federated][sample] buffered=${this.samples.length} action=${action}`)
    if (action !== 'no_action' || this.samples.length >= DEFAULT_BATCH_SIZE) {
      this.flush().catch((err: Error) => {
        console.info(`[Federated][upload-fail] ${err.message}`)
      })
    }
  }

  async flush(): Promise<void> {
    if (this.uploadInFlight || this.samples.length === 0) {
      return
    }
    this.uploadInFlight = true
    const count = Math.min(this.samples.length, 500)
    const batch = this.samples.slice(0, count)
    this.batchSequence = (this.batchSequence % 999999) + 1
    const batchId = `${this.clientId}-${Date.now()}-${this.batchSequence}`
    const payload: FederatedUploadPayload = {
      schema_version: 1,
      client_id: this.clientId,
      batch_id: batchId,
      num_samples: batch.length,
      samples: batch
    }
    const headers: FederatedHeaders = this.token.length > 0 ? {
      'Content-Type': 'application/json',
      'X-YuJia-Token': this.token
    } : {
      'Content-Type': 'application/json'
    }
    const request = http.createHttp()
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: JSON.stringify(payload),
        connectTimeout: 8000,
        readTimeout: 8000
      }
      if (this.pcUrl.startsWith('https://')) {
        const paths = await ensureTlsIdentityFiles(this.certificateDirectory)
        options.caPath = paths.caPath
        options.clientCert = {
          certPath: paths.certPath,
          keyPath: paths.keyPath
        }
      }
      const result = await request.request(`${this.pcUrl}/upload_data`, options)
      if (result.responseCode < 200 || result.responseCode >= 300) {
        throw new Error(`HTTP ${result.responseCode}`)
      }
      this.samples.splice(0, count)
      console.info(`[Federated][upload-ok] batch=${batchId} samples=${count} pending=${this.samples.length}`)
    } finally {
      request.destroy()
      this.uploadInFlight = false
    }
  }

  getBufferedSampleCount(): number {
    return this.samples.length
  }
}

let collector: FederatedDataCollector | null = null

export function getFederatedDataCollector(): FederatedDataCollector {
  if (collector === null) {
    collector = new FederatedDataCollector()
  }
  return collector
}
