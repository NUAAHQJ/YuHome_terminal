import { Context } from '@ohos.abilityAccessCtrl'
import voiceInference, { VoiceNativeDecodeResult, VoiceNativeInitResult, VoiceNativeSpeakerResult } from 'libvoice_inference.so'
import { VoiceAudioBridge } from './VoiceAudioBridge'
import { VoiceIntent, VoiceIntentParser, VoiceIntentType } from './VoiceIntentParser'
import { SpeakerMatchResult, SpeakerProfileManager } from './SpeakerProfileManager'

const COMMAND_TIMEOUT_MS: number = 7000
const EARLY_INTENT_STABLE_MS: number = 700
const WAKE_AUDIO_SECONDS: number = 2
const ENROLLMENT_MIN_SPEECH_SECONDS: number = 0.7
const PROMPT_AWAKE: string = 'voice/prompts/awake.wav'
const PROMPT_SUCCESS: string = 'voice/prompts/light_on_ok.wav'
const PROMPT_FAILED: string = 'voice/prompts/failed.wav'
const PROMPT_VOICEPRINT_DENIED: string = 'voice/prompts/voiceprint_denied.wav'

interface KeywordResultJson {
  keyword: string
}

interface RecognizerResultJson {
  text: string
}

export enum VoiceAssistantState {
  INITIALIZING = 'initializing',
  WAITING_WAKE = 'waiting_wake',
  WAKE_DETECTED = 'wake_detected',
  LISTENING_COMMAND = 'listening_command',
  RECOGNIZING = 'recognizing',
  EXECUTING = 'executing',
  SUCCEEDED = 'succeeded',
  FAILED = 'failed',
  ERROR = 'error',
  VOICEPRINT_ENROLLING = 'voiceprint_enrolling',
  STOPPED = 'stopped'
}

export interface VoiceExecutionResult {
  success: boolean
  message: string
  promptRawFile?: string
}

export interface VoiceAssistantCallbacks {
  onState: (state: VoiceAssistantState, detail: string, transcript: string) => void
  onLevel: (level: number) => void
  onExecuteIntent: (intent: VoiceIntent) => Promise<VoiceExecutionResult>
  onVoiceprintModel?: (ready: boolean, dimension: number, message: string) => void
  onVoiceprintResult?: (matched: boolean, userName: string, score: number) => void
}

export class VoiceAssistant {
  private callbacks: VoiceAssistantCallbacks | null = null
  private audio: VoiceAudioBridge = new VoiceAudioBridge()
  private parser: VoiceIntentParser = new VoiceIntentParser()
  private context: Context | null = null
  private state: VoiceAssistantState = VoiceAssistantState.STOPPED
  private running: boolean = false
  private commandFinishing: boolean = false
  private commandTimerId: number = -1
  private earlyIntentTimerId: number = -1
  private transcript: string = ''
  private speakerProfiles: SpeakerProfileManager | null = null
  private speakerModelReady: boolean = false
  private speakerDimension: number = 0
  private speakerStreamActive: boolean = false
  private wakeAudioRing: ArrayBuffer[] = []
  private wakeAudioSamples: number = 0
  private wakeAudioSampleRate: number = 16000
  private wakeDecodeQueue: ArrayBuffer[] = []
  private wakeDecodeQueuedSamples: number = 0
  private wakeDecodeInFlight: boolean = false
  private wakeDecodeGeneration: number = 0
  private enrollmentActive: boolean = false
  private enrollmentTimerId: number = -1
  private enrollmentResolve: ((embedding: number[]) => void) | null = null
  private enrollmentReject: ((error: Error) => void) | null = null
  private enrollmentSpeechSamples: number = 0
  private enrollmentSampleRate: number = 16000

  constructor() {
    this.audio.setCallbacks({
      onPcm16: (samples: ArrayBuffer, sampleRate: number): void => {
        this.handlePcm16(samples, sampleRate)
      },
      onLevel: (level: number): void => {
        if (this.callbacks !== null) {
          this.callbacks.onLevel(level)
        }
      },
      onError: (message: string): void => {
        this.setState(VoiceAssistantState.ERROR, message)
      }
    })
  }

  setCallbacks(callbacks: VoiceAssistantCallbacks): void {
    this.callbacks = callbacks
  }

  setSpeakerProfileManager(manager: SpeakerProfileManager): void {
    this.speakerProfiles = manager
  }

  isSpeakerModelReady(): boolean {
    return this.speakerModelReady
  }

  getSpeakerDimension(): number {
    return this.speakerDimension
  }

  captureVoiceprintSample(durationMs: number = 4200): Promise<number[]> {
    if (!this.running) {
      return Promise.reject(new Error('语音助手尚未启动'))
    }
    if (!this.speakerModelReady) {
      return Promise.reject(new Error('声纹模型尚未就绪'))
    }
    if (this.enrollmentActive || this.commandFinishing ||
      (this.state !== VoiceAssistantState.WAITING_WAKE && this.state !== VoiceAssistantState.FAILED &&
        this.state !== VoiceAssistantState.SUCCEEDED)) {
      return Promise.reject(new Error('语音通道正忙，请稍后再试'))
    }
    if (!voiceInference.startSpeaker()) {
      return Promise.reject(new Error('无法创建声纹采集流'))
    }
    this.speakerStreamActive = true
    this.enrollmentActive = true
    this.enrollmentSpeechSamples = 0
    this.enrollmentSampleRate = 16000
    this.clearWakeAudioRing()
    this.setState(VoiceAssistantState.VOICEPRINT_ENROLLING, '正在采集声纹，请自然说出提示语')
    return new Promise((resolve: (embedding: number[]) => void, reject: (error: Error) => void) => {
      this.enrollmentResolve = resolve
      this.enrollmentReject = reject
      this.enrollmentTimerId = setTimeout(() => {
        this.finishVoiceprintSample()
      }, durationMs)
    })
  }

  cancelVoiceprintSample(): void {
    if (!this.enrollmentActive) {
      return
    }
    this.clearEnrollmentTimer()
    voiceInference.cancelSpeaker()
    this.speakerStreamActive = false
    this.enrollmentActive = false
    const reject = this.enrollmentReject
    this.enrollmentResolve = null
    this.enrollmentReject = null
    if (reject !== null) {
      reject(new Error('已取消声纹采集'))
    }
    this.resumeWakeListening('声纹采集已取消')
  }

  async start(context: Context): Promise<void> {
    if (this.running) {
      return
    }
    this.context = context
    this.setState(VoiceAssistantState.INITIALIZING, '正在加载本地唤醒和识别模型')
    try {
      await this.initializeModels(context)
      this.running = true
      await this.audio.start()
      if (!voiceInference.resetWake()) {
        throw new Error('无法创建唤醒词音频流')
      }
      this.resetWakeDecodeQueue()
      this.setState(VoiceAssistantState.WAITING_WAKE, '请说“小禹小禹”')
      this.initializeSpeakerModel(context)
    } catch (err) {
      this.running = false
      const message = (err as Error).message
      this.setState(VoiceAssistantState.ERROR, message)
      throw new Error(message)
    }
  }

  async restart(context: Context): Promise<void> {
    await this.release()
    await this.start(context)
  }

  async release(): Promise<void> {
    this.running = false
    this.clearCommandTimer()
    this.clearEarlyIntentTimer()
    this.clearEnrollmentTimer()
    if (this.enrollmentActive && this.enrollmentReject !== null) {
      this.enrollmentReject(new Error('语音助手已停止'))
    }
    this.enrollmentActive = false
    this.enrollmentResolve = null
    this.enrollmentReject = null
    this.clearWakeAudioRing()
    this.resetWakeDecodeQueue()
    await this.audio.release()
    voiceInference.release()
    this.context = null
    this.transcript = ''
    this.setState(VoiceAssistantState.STOPPED, '语音助手已停止')
  }

  private async initializeModels(context: Context): Promise<void> {
    const result: VoiceNativeInitResult = await voiceInference.initialize(context.resourceManager)
    if (!result.success) {
      throw new Error(result.message)
    }
    this.speakerModelReady = result.speakerReady
    this.speakerDimension = result.speakerDimension
    if (this.callbacks?.onVoiceprintModel) {
      this.callbacks.onVoiceprintModel(false, 0, '声纹模型正在后台加载')
    }
    console.info(`[VoiceAssistant][native] ${result.message}`)
  }

  private async initializeSpeakerModel(context: Context): Promise<void> {
    try {
      const result: VoiceNativeInitResult = await voiceInference.initializeSpeaker(context.resourceManager)
      if (!this.running) {
        return
      }
      this.speakerModelReady = result.success && result.speakerReady
      this.speakerDimension = result.speakerDimension
      if (this.callbacks?.onVoiceprintModel) {
        this.callbacks.onVoiceprintModel(this.speakerModelReady, this.speakerDimension, result.message)
      }
      console.info(`[VoiceAssistant][speaker-native] ${result.message} dim=${result.speakerDimension}`)
    } catch (err) {
      this.speakerModelReady = false
      this.speakerDimension = 0
      const message = (err as Error).message
      if (this.callbacks?.onVoiceprintModel) {
        this.callbacks.onVoiceprintModel(false, 0, message)
      }
      console.info(`[VoiceAssistant][speaker-native-fail] ${message}`)
    }
  }

  private handlePcm16(samples: ArrayBuffer, sampleRate: number): void {
    if (!this.running) {
      return
    }
    if (this.enrollmentActive) {
      this.processEnrollmentAudio(this.pcm16ToFloat(samples), sampleRate)
    } else if (this.state === VoiceAssistantState.WAITING_WAKE) {
      this.processWakeAudio(samples, sampleRate)
    } else if (this.state === VoiceAssistantState.LISTENING_COMMAND ||
      this.state === VoiceAssistantState.RECOGNIZING) {
      this.processCommandAudio(this.pcm16ToFloat(samples), sampleRate)
    }
  }

  private processWakeAudio(samples: ArrayBuffer, sampleRate: number): void {
    this.rememberWakeAudio(samples, sampleRate)
    this.wakeDecodeQueue.push(samples)
    this.wakeDecodeQueuedSamples += Math.floor(samples.byteLength / 2)
    const maxQueuedSamples = sampleRate * 2
    while (this.wakeDecodeQueuedSamples > maxQueuedSamples && this.wakeDecodeQueue.length > 1) {
      const removed = this.wakeDecodeQueue.shift()
      if (removed !== undefined) {
        this.wakeDecodeQueuedSamples -= Math.floor(removed.byteLength / 2)
      }
    }
    this.drainWakeDecodeQueue(sampleRate)
  }

  private drainWakeDecodeQueue(sampleRate: number): void {
    const minimumBatchSamples = Math.floor(sampleRate * 0.12)
    if (this.wakeDecodeInFlight || this.wakeDecodeQueuedSamples < minimumBatchSamples ||
      this.state !== VoiceAssistantState.WAITING_WAKE) {
      return
    }
    const samples = new Uint8Array(this.wakeDecodeQueuedSamples * 2)
    let offset = 0
    this.wakeDecodeQueue.forEach((chunk: ArrayBuffer) => {
      const bytes = new Uint8Array(chunk)
      samples.set(bytes, offset)
      offset += bytes.byteLength
    })
    this.wakeDecodeQueue = []
    this.wakeDecodeQueuedSamples = 0
    this.wakeDecodeInFlight = true
    const generation = this.wakeDecodeGeneration
    voiceInference.acceptWakePcm16(samples.buffer, sampleRate).then((json: string) => {
      if (generation === this.wakeDecodeGeneration && this.state === VoiceAssistantState.WAITING_WAKE) {
        const result = JSON.parse(json) as KeywordResultJson
        if (result.keyword.length > 0) {
          console.info(`[VoiceAssistant][wake] ${result.keyword}`)
          this.wakeDecodeGeneration += 1
          this.wakeDecodeQueue = []
          this.wakeDecodeQueuedSamples = 0
          this.setState(VoiceAssistantState.WAKE_DETECTED, '我在')
          setTimeout(() => {
            this.handleWakeDetected().catch((err: Error) => {
              this.failAndResume(`唤醒处理失败: ${err.message}`)
            })
          }, 0)
        }
      }
      this.finishWakeDecode(sampleRate)
    }).catch((err: Error) => {
      console.info(`[VoiceAssistant][wake-decode] ${err.message}`)
      this.finishWakeDecode(sampleRate)
    })
  }

  private finishWakeDecode(sampleRate: number): void {
    this.wakeDecodeInFlight = false
    if (this.state === VoiceAssistantState.WAITING_WAKE) {
      this.drainWakeDecodeQueue(sampleRate)
    }
  }

  private resetWakeDecodeQueue(): void {
    this.wakeDecodeGeneration += 1
    this.wakeDecodeQueue = []
    this.wakeDecodeQueuedSamples = 0
  }

  private async handleWakeDetected(): Promise<void> {
    if (!this.running || this.context === null) {
      return
    }
    try {
      await this.audio.playPrompt(this.context, PROMPT_AWAKE)
    } catch (err) {
      console.info(`[VoiceAssistant][awake-prompt] ${(err as Error).message}`)
    }
    if (!this.running) {
      return
    }
    this.transcript = ''
    this.commandFinishing = false
    this.clearEarlyIntentTimer()
    if (!voiceInference.startCommand()) {
      throw new Error('无法创建指令识别音频流')
    }
    if (this.shouldVerifySpeaker()) {
      this.speakerStreamActive = voiceInference.startSpeaker()
      if (this.speakerStreamActive) {
        this.wakeAudioRing.forEach((chunk: ArrayBuffer) => {
          voiceInference.acceptSpeaker(this.pcm16ToFloat(chunk), this.wakeAudioSampleRate)
        })
      }
    } else {
      this.speakerStreamActive = false
    }
    this.clearWakeAudioRing()
    this.setState(VoiceAssistantState.LISTENING_COMMAND, '我在听，请说指令')
    this.clearCommandTimer()
    this.commandTimerId = setTimeout(() => {
      this.finishCommand().catch((err: Error) => {
        this.failAndResume(`识别结束失败: ${err.message}`)
      })
    }, COMMAND_TIMEOUT_MS)
  }

  private processCommandAudio(samples: Float32Array, sampleRate: number): void {
    if (this.commandFinishing) {
      return
    }
    const nativeResult: VoiceNativeDecodeResult = voiceInference.acceptCommand(samples, sampleRate)
    if (this.speakerStreamActive) {
      voiceInference.acceptSpeaker(samples, sampleRate)
    }
    const result: RecognizerResultJson = JSON.parse(nativeResult.json) as RecognizerResultJson
    if (result.text.length > 0 && result.text !== this.transcript) {
      this.transcript = result.text
      console.info(`[VoiceAssistant][asr] ${this.transcript}`)
      this.setState(VoiceAssistantState.RECOGNIZING, '正在识别指令', this.transcript)
      this.scheduleEarlyIntentCommit()
    }
    if (nativeResult.endpoint && this.transcript.length > 0) {
      setTimeout(() => {
        this.finishCommand().catch((err: Error) => {
          this.failAndResume(`指令处理失败: ${err.message}`)
        })
      }, 0)
    }
  }

  private async finishCommand(): Promise<void> {
    if (this.commandFinishing || !this.running) {
      return
    }
    this.commandFinishing = true
    this.clearCommandTimer()
    this.clearEarlyIntentTimer()
    const finalJson: string = voiceInference.finishCommand()
    const result: RecognizerResultJson = JSON.parse(finalJson) as RecognizerResultJson
    if (result.text.length > 0) {
      this.transcript = result.text
    }
    console.info(`[VoiceAssistant][asr-final] ${this.transcript.length > 0 ? this.transcript : '<empty>'}`)

    if (this.transcript.length === 0) {
      this.cancelCommandSpeakerStream()
      await this.completeWithFailure('没有听清，请重新唤醒')
      return
    }

    const speakerFailure = this.verifyCurrentSpeaker()
    if (speakerFailure.length > 0) {
      const prompt = speakerFailure.indexOf('声纹验证未通过') === 0 ?
        PROMPT_VOICEPRINT_DENIED : PROMPT_FAILED
      await this.completeWithFailure(speakerFailure, prompt)
      return
    }

    const intent = this.parser.parse(this.transcript)
    if (intent.type === VoiceIntentType.REQUIRES_CONFIRMATION) {
      await this.completeWithFailure('门锁指令需要人脸或手动确认')
      return
    }
    if (intent.type === VoiceIntentType.UNKNOWN) {
      await this.completeWithFailure('暂时不支持这个指令')
      return
    }
    if (this.callbacks === null) {
      await this.completeWithFailure('语音执行器未连接')
      return
    }

    this.setState(VoiceAssistantState.EXECUTING, '正在执行', this.transcript)
    let execution: VoiceExecutionResult
    try {
      execution = await this.callbacks.onExecuteIntent(intent)
    } catch (err) {
      execution = { success: false, message: (err as Error).message }
    }
    if (execution.success) {
      this.setState(VoiceAssistantState.SUCCEEDED, execution.message, this.transcript)
      await this.playResultPrompt(execution.promptRawFile ?? PROMPT_SUCCESS)
      this.resumeWakeListening(execution.message)
    } else {
      await this.completeWithFailure(execution.message)
    }
  }

  private async completeWithFailure(message: string, promptRawFile: string = PROMPT_FAILED): Promise<void> {
    this.setState(VoiceAssistantState.FAILED, message, this.transcript)
    await this.playResultPrompt(promptRawFile)
    this.resumeWakeListening(message)
  }

  private async playResultPrompt(rawFileName: string): Promise<void> {
    if (this.context === null) {
      return
    }
    try {
      await this.audio.playPrompt(this.context, rawFileName)
    } catch (err) {
      console.info(`[VoiceAssistant][result-prompt] ${(err as Error).message}`)
    }
  }

  private failAndResume(message: string): void {
    console.info(`[VoiceAssistant][flow-error] ${message}`)
    this.setState(VoiceAssistantState.FAILED, message, this.transcript)
    this.resumeWakeListening(message)
  }

  private resumeWakeListening(lastMessage: string): void {
    if (!this.running) {
      return
    }
    this.commandFinishing = false
    this.cancelCommandSpeakerStream()
    this.clearWakeAudioRing()
    this.resetWakeDecodeQueue()
    if (!voiceInference.resetWake()) {
      this.setState(VoiceAssistantState.ERROR, '无法恢复唤醒词监听', this.transcript)
      return
    }
    this.setState(VoiceAssistantState.WAITING_WAKE, `待唤醒 · ${lastMessage}`, this.transcript)
  }

  private clearCommandTimer(): void {
    if (this.commandTimerId !== -1) {
      clearTimeout(this.commandTimerId)
      this.commandTimerId = -1
    }
  }

  private scheduleEarlyIntentCommit(): void {
    this.clearEarlyIntentTimer()
    if (this.shouldVerifySpeaker()) {
      return
    }
    const intent = this.parser.parse(this.transcript)
    const isLightControl = intent.type === VoiceIntentType.LIGHT_SET && intent.target === 'living'
    const isACControl = intent.type === VoiceIntentType.AC_SET && intent.target === 'ac'
    if (!isLightControl && !isACControl) {
      return
    }
    const candidateText = this.transcript
    this.earlyIntentTimerId = setTimeout(() => {
      this.earlyIntentTimerId = -1
      if (!this.running || this.commandFinishing || this.transcript !== candidateText) {
        return
      }
      console.info(`[VoiceAssistant][intent-stable] ${candidateText}`)
      this.finishCommand().catch((err: Error) => {
        this.failAndResume(`指令处理失败: ${err.message}`)
      })
    }, EARLY_INTENT_STABLE_MS)
  }

  private clearEarlyIntentTimer(): void {
    if (this.earlyIntentTimerId !== -1) {
      clearTimeout(this.earlyIntentTimerId)
      this.earlyIntentTimerId = -1
    }
  }

  private shouldVerifySpeaker(): boolean {
    return this.speakerProfiles !== null && this.speakerProfiles.isProtectionEnabled()
  }

  private verifyCurrentSpeaker(): string {
    if (!this.shouldVerifySpeaker()) {
      this.cancelCommandSpeakerStream()
      return ''
    }
    if (!this.speakerModelReady || !this.speakerStreamActive || this.speakerProfiles === null) {
      this.cancelCommandSpeakerStream()
      return '声纹验证暂不可用，指令未执行'
    }
    const result: VoiceNativeSpeakerResult = voiceInference.finishSpeaker()
    this.speakerStreamActive = false
    if (!result.success || !result.ready || result.embedding.length === 0) {
      return '有效语音太短，声纹验证未完成'
    }
    const embedding = this.toNumberArray(result.embedding)
    const match: SpeakerMatchResult = this.speakerProfiles.match(embedding)
    if (this.callbacks?.onVoiceprintResult) {
      this.callbacks.onVoiceprintResult(match.matched, match.userName, match.score)
    }
    console.info(`[VoiceAssistant][voiceprint] matched=${match.matched} user=${match.userName} score=${match.score.toFixed(3)}`)
    if (!match.matched) {
      return `声纹验证未通过 · 相似度 ${Math.max(0, match.score).toFixed(2)}`
    }
    this.setState(VoiceAssistantState.RECOGNIZING,
      `已确认 ${match.userName} · 相似度 ${match.score.toFixed(2)}`, this.transcript)
    return ''
  }

  private processEnrollmentAudio(samples: Float32Array, sampleRate: number): void {
    if (!this.speakerStreamActive) {
      return
    }
    voiceInference.acceptSpeaker(samples, sampleRate)
    this.enrollmentSampleRate = sampleRate
    let sumSquares = 0
    for (let i = 0; i < samples.length; i++) {
      sumSquares += samples[i] * samples[i]
    }
    const rms = samples.length > 0 ? Math.sqrt(sumSquares / samples.length) : 0
    if (rms >= 0.005) {
      this.enrollmentSpeechSamples += samples.length
    }
  }

  private finishVoiceprintSample(): void {
    if (!this.enrollmentActive) {
      return
    }
    this.clearEnrollmentTimer()
    const resolve = this.enrollmentResolve
    const reject = this.enrollmentReject
    this.enrollmentResolve = null
    this.enrollmentReject = null
    this.enrollmentActive = false

    if (this.enrollmentSpeechSamples < this.enrollmentSampleRate * ENROLLMENT_MIN_SPEECH_SECONDS) {
      voiceInference.cancelSpeaker()
      this.speakerStreamActive = false
      this.resumeWakeListening('有效语音太短，请重新采集')
      if (reject !== null) {
        reject(new Error('有效语音太短，请靠近麦克风重新说一遍'))
      }
      return
    }

    const result: VoiceNativeSpeakerResult = voiceInference.finishSpeaker()
    this.speakerStreamActive = false
    this.resumeWakeListening(result.success ? '本轮声纹采集完成' : '声纹采集失败')
    if (!result.success || !result.ready || result.embedding.length === 0) {
      if (reject !== null) {
        reject(new Error('声纹特征提取失败，请重新采集'))
      }
      return
    }
    if (resolve !== null) {
      resolve(this.toNumberArray(result.embedding))
    }
  }

  private rememberWakeAudio(samples: ArrayBuffer, sampleRate: number): void {
    this.wakeAudioSampleRate = sampleRate
    this.wakeAudioRing.push(samples)
    this.wakeAudioSamples += Math.floor(samples.byteLength / 2)
    const maxSamples = sampleRate * WAKE_AUDIO_SECONDS
    while (this.wakeAudioSamples > maxSamples && this.wakeAudioRing.length > 1) {
      const removed = this.wakeAudioRing.shift()
      if (removed !== undefined) {
        this.wakeAudioSamples -= Math.floor(removed.byteLength / 2)
      }
    }
  }

  private clearWakeAudioRing(): void {
    this.wakeAudioRing = []
    this.wakeAudioSamples = 0
  }

  private pcm16ToFloat(buffer: ArrayBuffer): Float32Array {
    const bytes = new Uint8Array(buffer)
    const sampleCount = Math.floor(bytes.byteLength / 2)
    const samples = new Float32Array(sampleCount)
    for (let i = 0; i < sampleCount; i++) {
      const offset = i * 2
      let sample = bytes[offset] | (bytes[offset + 1] << 8)
      if (sample >= 32768) {
        sample -= 65536
      }
      samples[i] = sample / 32768
    }
    return samples
  }

  private cancelCommandSpeakerStream(): void {
    if (this.speakerStreamActive) {
      voiceInference.cancelSpeaker()
      this.speakerStreamActive = false
    }
  }

  private clearEnrollmentTimer(): void {
    if (this.enrollmentTimerId !== -1) {
      clearTimeout(this.enrollmentTimerId)
      this.enrollmentTimerId = -1
    }
  }

  private toNumberArray(values: Float32Array): number[] {
    const result: number[] = []
    for (let i = 0; i < values.length; i++) {
      result.push(values[i])
    }
    return result
  }

  private setState(state: VoiceAssistantState, detail: string, transcript: string = this.transcript): void {
    this.state = state
    if (this.callbacks !== null) {
      this.callbacks.onState(state, detail, transcript)
    }
  }
}
