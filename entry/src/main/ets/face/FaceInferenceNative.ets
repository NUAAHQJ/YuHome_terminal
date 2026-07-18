import faceInference from 'libface_inference.so'
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

export class FaceEmbeddingResult {
  ok: boolean = false
  dimension: number = 0
  message: string = ''
  preprocessVersion: string = 'center'
  cropMode: string = 'center'
  qualityScore: number = -1
  embedding?: number[]
}

interface FaceInferenceNativeModule {
  getBackendInfo(): FaceInferenceBackendInfo
  checkModelName(modelName: string): FaceModelCheckResult
  loadRecognizer(resourceManager: resourceManager.ResourceManager): FaceEmbeddingResult
  extractEmbedding(input: ArrayBuffer): FaceEmbeddingResult
}

const nativeModule = faceInference as FaceInferenceNativeModule

export function getFaceInferenceBackendInfo(): FaceInferenceBackendInfo {
  return nativeModule.getBackendInfo()
}

export function checkFaceModelName(modelName: string): FaceModelCheckResult {
  return nativeModule.checkModelName(modelName)
}

export function loadFaceRecognizer(resourceMgr: resourceManager.ResourceManager): FaceEmbeddingResult {
  const raw = nativeModule.loadRecognizer(resourceMgr)
  const result = new FaceEmbeddingResult()
  result.ok = raw.ok
  result.dimension = raw.dimension
  result.message = raw.message
  result.preprocessVersion = raw.preprocessVersion ?? 'center'
  result.cropMode = raw.cropMode ?? 'center'
  result.qualityScore = raw.qualityScore ?? -1
  result.embedding = raw.embedding
  return result
}

export function extractFaceEmbedding(input: ArrayBuffer): FaceEmbeddingResult {
  const raw = nativeModule.extractEmbedding(input)
  const result = new FaceEmbeddingResult()
  result.ok = raw.ok
  result.dimension = raw.dimension
  result.message = raw.message
  result.preprocessVersion = raw.preprocessVersion ?? 'center'
  result.cropMode = raw.cropMode ?? 'center'
  result.qualityScore = raw.qualityScore ?? -1
  result.embedding = raw.embedding
  return result
}
