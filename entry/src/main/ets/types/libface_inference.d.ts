declare module 'libface_inference.so' {
  import { resourceManager } from '@kit.LocalizationKit'

  export interface FaceInferenceBackendInfo {
    backend: string
    plannedEngine: string
    nativeReady: boolean
    engineReady: boolean
    message: string
  }

  export interface FaceModelCheckResult {
    ok: boolean
    modelName: string
    message: string
  }

  export interface FaceEmbeddingResult {
    ok: boolean
    dimension: number
    message: string
    preprocessVersion?: string
    cropMode?: string
    qualityScore?: number
    embedding?: number[]
  }

  const faceInference: {
    getBackendInfo(): FaceInferenceBackendInfo
    checkModelName(modelName: string): FaceModelCheckResult
    loadRecognizer(resourceManager: resourceManager.ResourceManager): FaceEmbeddingResult
    extractEmbedding(input: ArrayBuffer): FaceEmbeddingResult
  }

  export default faceInference
}
