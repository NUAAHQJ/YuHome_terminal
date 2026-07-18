declare module 'libvoice_inference.so' {
  import { resourceManager } from '@kit.LocalizationKit'

  export interface VoiceNativeInitResult {
    success: boolean
    message: string
    speakerReady: boolean
    speakerDimension: number
  }

  export interface VoiceNativeDecodeResult {
    json: string
    endpoint: boolean
  }

  export interface VoiceNativeSpeakerResult {
    success: boolean
    ready: boolean
    message: string
    dimension: number
    embedding: Float32Array
  }

  interface VoiceInferenceNative {
    initialize(resourceManager: resourceManager.ResourceManager): Promise<VoiceNativeInitResult>
    initializeSpeaker(resourceManager: resourceManager.ResourceManager): Promise<VoiceNativeInitResult>
    resetWake(): boolean
    acceptWake(samples: Float32Array, sampleRate: number): Promise<string>
    acceptWakePcm16(samples: ArrayBuffer, sampleRate: number): Promise<string>
    startCommand(): boolean
    acceptCommand(samples: Float32Array, sampleRate: number): VoiceNativeDecodeResult
    finishCommand(): string
    startSpeaker(): boolean
    acceptSpeaker(samples: Float32Array, sampleRate: number): boolean
    finishSpeaker(): VoiceNativeSpeakerResult
    cancelSpeaker(): boolean
    release(): boolean
  }

  const voiceInference: VoiceInferenceNative
  export default voiceInference
}
