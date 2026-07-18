import abilityAccessCtrl, { Context, Permissions } from '@ohos.abilityAccessCtrl'
import camera from '@ohos.multimedia.camera'
import fs from '@ohos.file.fs'
import image from '@ohos.multimedia.image'
import { checkFaceModelName, extractFaceEmbedding, getFaceInferenceBackendInfo, loadFaceRecognizer } from './FaceInferenceNative'

const CAMERA_PERMISSION: Permissions = 'ohos.permission.CAMERA'
const FACE_USERS_FILE: string = 'face_users.json'
const FACE_USERS_BACKUP_FILE: string = 'face_users.backup.json'
const FACE_PHOTO_CALLBACK_TIMEOUT_MS: number = 8000
const FACE_INFERENCE_TIMEOUT_MS: number = 30000
const FACE_MODEL_FILES: string[] = [
  'face/det_500m.onnx',
  'face/2d106det.onnx',
  'face/w600k_mbf.onnx',
  'face/1k3d68.onnx',
  'face/genderage.onnx'
]
const FACE_RUNTIME_MODEL_FILES: string[] = [
  'face_ncnn/det_500m.ncnn.param',
  'face_ncnn/det_500m.ncnn.bin',
  'face_ncnn/2d106det.ncnn.param',
  'face_ncnn/2d106det.ncnn.bin',
  'face_ncnn/w600k_mbf.ncnn.param',
  'face_ncnn/w600k_mbf.ncnn.bin'
]
export const FACE_PREPROCESS_CENTER: string = 'center'

export interface FaceUser {
  userId: string
  name: string
  enabled: boolean
  samples: number
  createdAt: number
  preprocessVersion: string
  embedding: number[]
}

interface StoredFaceUsers {
  version: number
  users: FaceUser[]
}

export interface FaceAccessProbeResult {
  ok: boolean
  message: string
  cameraCount: number
  cameraSummary: string
  previewSummary: string
  photoSummary: string
  modelSummary: string
}

export interface FaceCaptureResult {
  ok: boolean
  message: string
  byteLength: number
  width: number
  height: number
  format: number
  embeddingDimension: number
  embeddingPreview: string
  preprocessVersion: string
  cropMode: string
  qualityScore: number
  embedding: number[]
}

export interface FaceMatchResult {
  matched: boolean
  userName: string
  userId: string
  score: number
  threshold: number
  preprocessVersion: string
}

interface FaceEmbeddingCapture {
  ok: boolean
  message: string
  dimension: number
  preview: string
  preprocessVersion: string
  cropMode: string
  qualityScore: number
  embedding: number[]
}

function formatProfile(profile: camera.Profile | undefined): string {
  if (!profile) {
    return '无'
  }
  return `${profile.size.width}x${profile.size.height} fmt=${profile.format}`
}

function pickPreviewProfile(profiles: camera.Profile[], targetRatio: number): camera.Profile {
  let best = profiles[0]
  let bestScore = Number.MAX_VALUE
  profiles.forEach((profile: camera.Profile) => {
    const width = profile.size.width
    const height = profile.size.height
    if (width <= 0 || height <= 0) {
      return
    }
    const ratio = width / height
    const score = Math.abs(ratio - targetRatio)
    if (score < bestScore) {
      best = profile
      bestScore = score
    }
  })
  return best
}

function pickSmallestPhotoProfile(profiles: camera.Profile[]): camera.Profile {
  let best = profiles[0]
  let bestArea = best.size.width * best.size.height
  profiles.forEach((profile: camera.Profile) => {
    const area = profile.size.width * profile.size.height
    if (area > 0 && area < bestArea) {
      best = profile
      bestArea = area
    }
  })
  return best
}

function writeLeU32(buffer: Uint8Array, offset: number, value: number): void {
  buffer[offset] = value & 0xFF
  buffer[offset + 1] = (value >> 8) & 0xFF
  buffer[offset + 2] = (value >> 16) & 0xFF
  buffer[offset + 3] = (value >> 24) & 0xFF
}

function normalizeEmbedding(values: number[]): number[] {
  let sumSquares = 0
  values.forEach((value: number) => {
    sumSquares += value * value
  })
  const norm = Math.sqrt(sumSquares)
  if (norm <= 1e-6) {
    return values.slice()
  }
  return values.map((value: number) => value / norm)
}

function averageEmbeddings(samples: number[][]): number[] {
  if (samples.length === 0) {
    return []
  }
  const dimension = samples[0].length
  const averaged: number[] = new Array(dimension).fill(0)
  samples.forEach((sample: number[]) => {
    for (let i = 0; i < dimension; i++) {
      averaged[i] += sample[i]
    }
  })
  for (let i = 0; i < dimension; i++) {
    averaged[i] /= samples.length
  }
  return normalizeEmbedding(averaged)
}

function cosineSimilarity(a: number[], b: number[]): number {
  if (a.length === 0 || a.length !== b.length) {
    return -1
  }
  let score = 0
  for (let i = 0; i < a.length; i++) {
    score += a[i] * b[i]
  }
  return score
}

export class FaceAccessManager {
  private users: FaceUser[] = []
  private cameraInput: camera.CameraInput | null = null
  private previewOutput: camera.PreviewOutput | null = null
  private photoOutput: camera.PhotoOutput | null = null
  private session: camera.PhotoSession | null = null

  listUsers(): FaceUser[] {
    return this.users.slice()
  }

  async loadUsers(context: Context): Promise<number> {
    const primaryPath = `${context.filesDir}/${FACE_USERS_FILE}`
    const backupPath = `${context.filesDir}/${FACE_USERS_BACKUP_FILE}`
    const primaryUsers = await this.readStoredUsers(primaryPath)
    if (primaryUsers !== null) {
      this.users = primaryUsers
      const backupPayload: StoredFaceUsers = { version: 1, users: this.users }
      await this.writeStoredUsers(backupPath, JSON.stringify(backupPayload)).catch((err: Error) => {
        console.info(`[FaceAccess][backup-users-fail] ${err.message}`)
      })
      console.info(`[FaceAccess][load-users] primary=${this.users.length}`)
      return this.users.length
    }
    const backupUsers = await this.readStoredUsers(backupPath)
    if (backupUsers !== null) {
      this.users = backupUsers
      console.info(`[FaceAccess][load-users] backup=${this.users.length}`)
      return this.users.length
    }
    if (this.users.length > 0) {
      console.info(`[FaceAccess][load-users] keep-memory=${this.users.length}`)
      return this.users.length
    }
    this.users = []
    return 0
  }

  async saveUsers(context: Context): Promise<void> {
    try {
      const payload: StoredFaceUsers = {
        version: 1,
        users: this.users
      }
      const json = JSON.stringify(payload)
      const primaryPath = `${context.filesDir}/${FACE_USERS_FILE}`
      const backupPath = `${context.filesDir}/${FACE_USERS_BACKUP_FILE}`
      await this.writeStoredUsers(backupPath, json)
      await this.writeStoredUsers(primaryPath, json)
      console.info(`[FaceAccess][save-users] ${this.users.length} ${primaryPath}`)
    } catch (err) {
      console.info(`[FaceAccess][save-users-fail] ${(err as Error).message}`)
      throw new Error((err as Error).message)
    }
  }

  private async readStoredUsers(filePath: string): Promise<FaceUser[] | null> {
    try {
      const exists = await fs.access(filePath).catch(() => false)
      if (!exists) {
        return null
      }
      const raw = await fs.readText(filePath)
      const parsed = JSON.parse(raw) as StoredFaceUsers
      if (!parsed.users || !Array.isArray(parsed.users)) {
        return null
      }
      return parsed.users
        .map((item: FaceUser): FaceUser => this.normalizeStoredUser(item))
        .filter((item: FaceUser) => item.embedding.length > 0)
    } catch (err) {
      console.info(`[FaceAccess][read-users-fail] ${filePath}: ${(err as Error).message}`)
      return null
    }
  }

  private async writeStoredUsers(filePath: string, json: string): Promise<void> {
    const file = await fs.open(filePath, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE)
    try {
      await fs.write(file.fd, json)
    } finally {
      fs.closeSync(file)
    }
  }

  addMockUser(name: string, sampleCount: number): FaceUser {
    const user: FaceUser = {
      userId: `face_${Date.now()}`,
      name: name.trim().length > 0 ? name.trim() : `用户${this.users.length + 1}`,
      enabled: true,
      samples: sampleCount,
      createdAt: Date.now(),
      preprocessVersion: FACE_PREPROCESS_CENTER,
      embedding: []
    }
    this.users = [user, ...this.users]
    return user
  }

  addUserFromEmbeddings(name: string, samples: number[][]): FaceUser {
    const embedding = averageEmbeddings(samples)
    const user: FaceUser = {
      userId: `face_${Date.now()}`,
      name: name.trim().length > 0 ? name.trim() : `User ${this.users.length + 1}`,
      enabled: true,
      samples: samples.length,
      createdAt: Date.now(),
      preprocessVersion: FACE_PREPROCESS_CENTER,
      embedding
    }
    this.users = [user, ...this.users]
    return user
  }

  deleteUser(userId: string): void {
    this.users = this.users.filter((item: FaceUser) => item.userId !== userId)
  }

  private normalizeStoredUser(item: FaceUser): FaceUser {
    const embedding = Array.isArray(item.embedding) ? item.embedding.filter((value: number) => typeof value === 'number') : []
    return {
      userId: typeof item.userId === 'string' && item.userId.length > 0 ? item.userId : `face_${Date.now()}`,
      name: typeof item.name === 'string' && item.name.length > 0 ? item.name : 'User',
      enabled: item.enabled !== false,
      samples: typeof item.samples === 'number' ? item.samples : 0,
      createdAt: typeof item.createdAt === 'number' ? item.createdAt : Date.now(),
      preprocessVersion: typeof item.preprocessVersion === 'string' && item.preprocessVersion.length > 0 ? item.preprocessVersion : FACE_PREPROCESS_CENTER,
      embedding: normalizeEmbedding(embedding)
    }
  }

  matchEmbedding(embedding: number[], threshold: number = 0.75, preprocessVersion: string = FACE_PREPROCESS_CENTER): FaceMatchResult {
    let bestUserName = ''
    let bestUserId = ''
    let bestScore = -1
    const normalized = normalizeEmbedding(embedding)
    this.users.forEach((user: FaceUser) => {
      if (!user.enabled || user.embedding.length === 0 || user.preprocessVersion !== preprocessVersion) {
        return
      }
      const score = cosineSimilarity(normalized, user.embedding)
      if (score > bestScore) {
        bestScore = score
        bestUserName = user.name
        bestUserId = user.userId
      }
    })
    return {
      matched: bestUserId.length > 0 && bestScore >= threshold,
      userName: bestUserName,
      userId: bestUserId,
      score: bestScore,
      threshold,
      preprocessVersion
    }
  }

  async requestCameraPermission(context: Context): Promise<boolean> {
    const atManager = abilityAccessCtrl.createAtManager()
    const result = await atManager.requestPermissionsFromUser(context, [CAMERA_PERMISSION])
    if (!result.authResults || result.authResults.length === 0) {
      return false
    }
    return result.authResults[0] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED
  }

  async checkModels(context: Context): Promise<string> {
    const names: string[] = []
    let readyCount = 0
    const modelFiles = FACE_MODEL_FILES.concat(FACE_RUNTIME_MODEL_FILES)
    const totalCount = modelFiles.length
    for (const fileName of modelFiles) {
      try {
        const fd = await context.resourceManager.getRawFd(fileName)
        readyCount++
        names.push(`${fileName.split('/').pop()} ${Math.round(fd.length / 1024)}KB`)
        await context.resourceManager.closeRawFileDescriptor(fileName)
      } catch (err) {
        names.push(`${fileName.split('/').pop()} 缺失`)
        console.info(`[FaceAccess][model-missing] ${fileName}: ${(err as Error).message}`)
      }
    }
    console.info(`[FaceAccess][models] ${names.join(' | ')}`)
    try {
      const loadResult = loadFaceRecognizer(context.resourceManager)
      const backend = getFaceInferenceBackendInfo()
      const modelCheck = checkFaceModelName('face_ncnn/w600k_mbf.ncnn.param')
      console.info(`[FaceAccess][backend] ${backend.plannedEngine} native=${backend.nativeReady ? 'ready' : 'off'} engine=${backend.engineReady ? 'ready' : 'pending'} model=${modelCheck.ok ? 'ok' : 'bad'}`)
      if (readyCount < totalCount) {
        return `资源 ${readyCount}/${totalCount} | 文件缺失`
      }
      if (!loadResult.ok) {
        console.info(`[FaceAccess][recognizer-load] ${loadResult.message}`)
        return `资源 ${readyCount}/${totalCount} | NCNN待调试`
      }
      const ready = backend.nativeReady && backend.engineReady && modelCheck.ok
      return `资源 ${readyCount}/${totalCount} | ${ready ? 'NCNN就绪' : 'NCNN待调试'}`
    } catch (err) {
      console.info(`[FaceAccess][native-bridge-fail] ${(err as Error).message}`)
      return `资源 ${readyCount}/${totalCount} | Native异常`
    }
  }

  async probeCamera(context: Context): Promise<FaceAccessProbeResult> {
    try {
      const granted = await this.requestCameraPermission(context)
      if (!granted) {
        return this.buildProbeResult(false, '相机权限未授权', 0, '无权限', '', '', await this.checkModels(context))
      }

      const cameraManager = camera.getCameraManager(context)
      const cameras = cameraManager.getSupportedCameras()
      if (cameras.length === 0) {
        return this.buildProbeResult(false, '未发现相机', 0, '无', '', '', await this.checkModels(context))
      }

      const device = cameras[0]
      const capability = cameraManager.getSupportedOutputCapability(device, camera.SceneMode.NORMAL_PHOTO)
      const preview = capability.previewProfiles.length > 0 ? capability.previewProfiles[0] : undefined
      const photo = capability.photoProfiles.length > 0 ? capability.photoProfiles[0] : undefined
      const cameraSummary = `${device.cameraId} pos=${device.cameraPosition} type=${device.cameraType}`
      const modelSummary = await this.checkModels(context)

      console.info(`[FaceAccess][camera] ${cameraSummary}`)
      console.info(`[FaceAccess][profile] preview=${formatProfile(preview)} photo=${formatProfile(photo)}`)
      return this.buildProbeResult(true, '相机入口已就绪', cameras.length, cameraSummary, formatProfile(preview), formatProfile(photo), modelSummary)
    } catch (err) {
      return this.buildProbeResult(false, `相机检测失败: ${(err as Error).message}`, 0, '', '', '', await this.checkModels(context))
    }
  }

  async startPreview(context: Context, surfaceId: string, targetRatio: number = 300 / 370): Promise<FaceAccessProbeResult> {
    try {
      const granted = await this.requestCameraPermission(context)
      if (!granted) {
        return this.buildProbeResult(false, '相机权限未授权', 0, '无权限', '', '', await this.checkModels(context))
      }
      if (surfaceId.trim().length === 0) {
        return this.buildProbeResult(false, '预览 Surface 未就绪', 0, '', '', '', await this.checkModels(context))
      }

      const cameraManager = camera.getCameraManager(context)
      const cameras = cameraManager.getSupportedCameras()
      if (cameras.length === 0) {
        return this.buildProbeResult(false, '未发现相机', 0, '无', '', '', await this.checkModels(context))
      }

      const device = cameras[0]
      const capability = cameraManager.getSupportedOutputCapability(device, camera.SceneMode.NORMAL_PHOTO)
      if (capability.previewProfiles.length === 0) {
        return this.buildProbeResult(false, '相机没有预览输出能力', cameras.length, `${device.cameraId}`, '', '', await this.checkModels(context))
      }
      if (capability.photoProfiles.length === 0) {
        return this.buildProbeResult(false, '相机没有拍照输出能力', cameras.length, `${device.cameraId}`, formatProfile(capability.previewProfiles[0]), '', await this.checkModels(context))
      }

      await this.stopPreview()
      const previewProfile = pickPreviewProfile(capability.previewProfiles, targetRatio)
      const photoProfile = pickSmallestPhotoProfile(capability.photoProfiles)
      this.cameraInput = cameraManager.createCameraInput(device)
      await this.cameraInput.open()
      this.previewOutput = cameraManager.createPreviewOutput(previewProfile, surfaceId)
      this.photoOutput = cameraManager.createPhotoOutput(photoProfile)
      this.session = cameraManager.createSession<camera.PhotoSession>(camera.SceneMode.NORMAL_PHOTO)
      this.session.beginConfig()
      this.session.addInput(this.cameraInput)
      this.session.addOutput(this.previewOutput)
      this.session.addOutput(this.photoOutput)
      await this.session.commitConfig()
      await this.session.start()

      const cameraSummary = `${device.cameraId} pos=${device.cameraPosition} type=${device.cameraType}`
      console.info(`[FaceAccess][preview] surface=${surfaceId} preview=${formatProfile(previewProfile)} photo=${formatProfile(photoProfile)}`)
      return this.buildProbeResult(true, '相机预览已启动', cameras.length, cameraSummary, formatProfile(previewProfile), formatProfile(photoProfile), await this.checkModels(context))
    } catch (err) {
      console.info(`[FaceAccess][preview-fail] ${(err as Error).message}`)
      await this.stopPreview()
      return this.buildProbeResult(false, `预览启动失败: ${(err as Error).message}`, 0, '', '', '', await this.checkModels(context))
    }
  }

  async stopPreview(): Promise<void> {
    if (this.session !== null) {
      try { await this.session.stop() } catch (_) {}
      try { await this.session.release() } catch (_) {}
      this.session = null
    }
    if (this.photoOutput !== null) {
      try { await this.photoOutput.release() } catch (_) {}
      this.photoOutput = null
    }
    if (this.previewOutput !== null) {
      try { await this.previewOutput.release() } catch (_) {}
      this.previewOutput = null
    }
    if (this.cameraInput !== null) {
      try { await this.cameraInput.close() } catch (_) {}
      this.cameraInput = null
    }
  }

  async captureFaceSample(_context: Context): Promise<FaceCaptureResult> {
    try {
      if (this.photoOutput === null) {
        return this.buildCaptureResult(false, '请先启动相机预览', 0, 0, 0, 0)
      }
      const capturePromise = this.waitForPhoto(this.photoOutput)
      this.photoOutput.capture({
        quality: camera.QualityLevel.QUALITY_LEVEL_LOW,
        rotation: camera.ImageRotation.ROTATION_0,
        mirror: false
      }).catch((err: Error) => {
        console.info(`[FaceAccess][capture-call-fail] ${err.message}`)
      })
      const result = await capturePromise
      console.info(`[FaceAccess][capture] ${result.byteLength}B ${result.width}x${result.height} fmt=${result.format}`)
      return result
    } catch (err) {
      console.info(`[FaceAccess][capture-fail] ${(err as Error).message}`)
      return this.buildCaptureResult(false, `拍照失败: ${(err as Error).message}`, 0, 0, 0, 0)
    }
  }

  private waitForPhoto(photoOutput: camera.PhotoOutput): Promise<FaceCaptureResult> {
    return new Promise((resolve) => {
      let finished = false
      const finish = (result: FaceCaptureResult): void => {
        if (finished) {
          return
        }
        finished = true
        clearTimeout(timer)
        try { photoOutput.off('photoAvailable') } catch (_) {}
        resolve(result)
      }
      const timer = setTimeout(() => {
        finish(this.buildCaptureResult(false, 'capture timeout', 0, 0, 0, 0))
        return
        if (finished) {
          return
        }
        finished = true
        try { photoOutput.off('photoAvailable') } catch (_) {}
        resolve(this.buildCaptureResult(false, '拍照超时', 0, 0, 0, 0))
      }, FACE_PHOTO_CALLBACK_TIMEOUT_MS)

      photoOutput.on('photoAvailable', async (err, photo: camera.Photo) => {
        if (finished) {
          return
        }
        clearTimeout(timer)
        console.info('[FaceAccess][photo-callback]')
        if (err) {
          finish(this.buildCaptureResult(false, `photo callback failed: ${err.message}`, 0, 0, 0, 0))
          return
        }
        let width = 0
        let height = 0
        let format = 0
        try {
          const mainImage = photo.main
          width = mainImage.size.width
          height = mainImage.size.height
          format = mainImage.format
          console.info(`[FaceAccess][jpeg-read-start] ${width}x${height} fmt=${format}`)
          let jpegDone = false
          const jpegTimer = setTimeout(() => {
            if (jpegDone) {
              return
            }
            jpegDone = true
            console.info('[FaceAccess][jpeg-read-timeout]')
            finish(this.buildCaptureResult(false, 'jpeg read timeout', 0, width, height, format))
          }, 5000)
          mainImage.getComponent(image.ComponentType.JPEG).then((component: image.Component) => {
            if (jpegDone) {
              return
            }
            jpegDone = true
            clearTimeout(jpegTimer)
            const bytes = new Uint8Array(component.byteBuffer)
            console.info(`[FaceAccess][jpeg-read-ok] ${bytes.length}B`)
            let preprocessDone = false
            const preprocessTimer = setTimeout(() => {
              if (preprocessDone) {
                return
              }
              preprocessDone = true
              console.info('[FaceAccess][pixel-decode-timeout]')
              finish(this.buildCaptureResult(false, 'pixel decode timeout', bytes.length, width, height, format))
            }, FACE_INFERENCE_TIMEOUT_MS)
            this.extractEmbeddingFromJpeg(component.byteBuffer).then((embedding: FaceEmbeddingCapture) => {
              if (preprocessDone) {
                return
              }
              preprocessDone = true
              clearTimeout(preprocessTimer)
              finish(this.buildCaptureResult(embedding.ok, embedding.message, bytes.length, width, height, format, embedding.dimension, embedding.preview, embedding.embedding, embedding.preprocessVersion, embedding.cropMode, embedding.qualityScore))
            }).catch((decodeErr: Error) => {
              if (preprocessDone) {
                return
              }
              preprocessDone = true
              clearTimeout(preprocessTimer)
              console.info(`[FaceAccess][pixel-decode-fail] ${decodeErr.message}`)
              finish(this.buildCaptureResult(false, `pixel decode failed: ${decodeErr.message}`, bytes.length, width, height, format))
            })
          }).catch((componentErr: Error) => {
            if (jpegDone) {
              return
            }
            jpegDone = true
            clearTimeout(jpegTimer)
            console.info(`[FaceAccess][jpeg-read-fail] ${componentErr.message}`)
            finish(this.buildCaptureResult(false, `jpeg read failed: ${componentErr.message}`, 0, width, height, format))
          })
        } catch (metaErr) {
          console.info(`[FaceAccess][photo-meta-fail] ${(metaErr as Error).message}`)
          finish(this.buildCaptureResult(true, 'photo callback received; metadata unavailable', 0, width, height, format))
        }
        return
        finished = true
        clearTimeout(timer)
        try { photoOutput.off('photoAvailable') } catch (_) {}
        if (err) {
          resolve(this.buildCaptureResult(false, `拍照回调失败: ${err.message}`, 0, 0, 0, 0))
          return
        }
        try {
          const mainImage = photo.main
          const component = await mainImage.getComponent(image.ComponentType.JPEG)
          const bytes = new Uint8Array(component.byteBuffer)
          const embedding = await this.extractEmbeddingFromJpeg(component.byteBuffer)
          const embeddingResult = this.buildCaptureResult(true, embedding.message, bytes.length, mainImage.size.width, mainImage.size.height, mainImage.format, embedding.dimension, embedding.preview, embedding.embedding, embedding.preprocessVersion, embedding.cropMode, embedding.qualityScore)
          const result = this.buildCaptureResult(true, '真实相机样本已采集', bytes.length, mainImage.size.width, mainImage.size.height, mainImage.format)
          try { await mainImage.release() } catch (_) {}
          try { await photo.release() } catch (_) {}
          resolve(embeddingResult)
        } catch (err) {
          resolve(this.buildCaptureResult(false, `读取照片失败: ${(err as Error).message}`, 0, 0, 0, 0))
        }
      })
    })
  }

  private async extractEmbeddingFromJpeg(jpegBuffer: ArrayBuffer): Promise<FaceEmbeddingCapture> {
    let source: image.ImageSource | null = null
    let pixelMap: image.PixelMap | null = null
    try {
      source = image.createImageSource(jpegBuffer)
      pixelMap = await source.createPixelMap({
        desiredSize: {
          width: 640,
          height: 640
        },
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      })
      const info = await pixelMap.getImageInfo()
      const width = info.size.width
      const height = info.size.height
      const rgbaBuffer = new ArrayBuffer(width * height * 4)
      await pixelMap.readPixelsToBuffer(rgbaBuffer)

      const payloadBuffer = new ArrayBuffer(8 + rgbaBuffer.byteLength)
      const payload = new Uint8Array(payloadBuffer)
      writeLeU32(payload, 0, width)
      writeLeU32(payload, 4, height)
      payload.set(new Uint8Array(rgbaBuffer), 8)

      const inferenceStartedAt = Date.now()
      const result = extractFaceEmbedding(payloadBuffer)
      console.info(`[FaceAccess][inference] ${Date.now() - inferenceStartedAt}ms ok=${result.ok}`)
      const resultOk: boolean = result.ok
      const resultDimension: number = result.dimension
      const resultMessage: string = result.message
      const preprocessVersion: string = result.preprocessVersion ?? FACE_PREPROCESS_CENTER
      const cropMode: string = result.cropMode ?? FACE_PREPROCESS_CENTER
      const qualityScore: number = result.qualityScore ?? -1
      const values: number[] = result.embedding ? result.embedding : []
      const preview = values.slice(0, 4).map((value: number) => value.toFixed(3)).join(',')
      const message = resultOk ? `embedding ${resultDimension}维` : `embedding失败: ${resultMessage}`
      const qualityText = qualityScore >= 0 ? ` q=${qualityScore.toFixed(3)}` : ''
      const displayMessage = resultOk && resultDimension > 0 ? `embedding ${resultDimension} dims · ${preprocessVersion}/${cropMode}${qualityText}` : resultMessage
      const capture: FaceEmbeddingCapture = {
        ok: resultOk,
        message: displayMessage,
        dimension: resultDimension,
        preview,
        preprocessVersion,
        cropMode,
        qualityScore,
        embedding: values
      }
      return capture
    } catch (err) {
      console.info(`[FaceAccess][embedding-fail] ${(err as Error).message}`)
      const capture: FaceEmbeddingCapture = {
        ok: false,
        message: `embedding失败: ${(err as Error).message}`,
        dimension: 0,
        preview: '',
        preprocessVersion: FACE_PREPROCESS_CENTER,
        cropMode: FACE_PREPROCESS_CENTER,
        qualityScore: -1,
        embedding: []
      }
      return capture
    }
  }

  private async decodeJpegToRgba(jpegBuffer: ArrayBuffer): Promise<FaceEmbeddingCapture> {
    let source: image.ImageSource | null = null
    let pixelMap: image.PixelMap | null = null
    try {
      console.info('[FaceAccess][pixel-decode-start]')
      source = image.createImageSource(jpegBuffer)
      pixelMap = await source.createPixelMap({
        desiredSize: {
          width: 224,
          height: 224
        },
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      })
      const info = await pixelMap.getImageInfo()
      const width = info.size.width
      const height = info.size.height
      const rgbaBuffer = new ArrayBuffer(width * height * 4)
      await pixelMap.readPixelsToBuffer(rgbaBuffer)
      console.info(`[FaceAccess][pixel-decode-ok] ${width}x${height} ${rgbaBuffer.byteLength}B`)
      const capture: FaceEmbeddingCapture = {
        ok: true,
        message: `RGBA ${width}x${height} ready; inference disabled`,
        dimension: 0,
        preview: '',
        preprocessVersion: FACE_PREPROCESS_CENTER,
        cropMode: FACE_PREPROCESS_CENTER,
        qualityScore: -1,
        embedding: []
      }
      return capture
    } catch (err) {
      console.info(`[FaceAccess][pixel-decode-fail] ${(err as Error).message}`)
      const capture: FaceEmbeddingCapture = {
        ok: false,
        message: `pixel decode failed: ${(err as Error).message}`,
        dimension: 0,
        preview: '',
        preprocessVersion: FACE_PREPROCESS_CENTER,
        cropMode: FACE_PREPROCESS_CENTER,
        qualityScore: -1,
        embedding: []
      }
      return capture
    } finally {
      if (pixelMap !== null) {
        try { await pixelMap.release() } catch (_) {}
      }
      if (source !== null) {
        try { await source.release() } catch (_) {}
      }
    }
  }

  private buildProbeResult(ok: boolean, message: string, cameraCount: number, cameraSummary: string, previewSummary: string, photoSummary: string, modelSummary: string): FaceAccessProbeResult {
    return {
      ok,
      message,
      cameraCount,
      cameraSummary,
      previewSummary,
      photoSummary,
      modelSummary
    }
  }

  private buildCaptureResult(ok: boolean, message: string, byteLength: number, width: number, height: number, format: number, embeddingDimension: number = 0, embeddingPreview: string = '', embedding: number[] = [], preprocessVersion: string = FACE_PREPROCESS_CENTER, cropMode: string = FACE_PREPROCESS_CENTER, qualityScore: number = -1): FaceCaptureResult {
    return {
      ok,
      message,
      byteLength,
      width,
      height,
      format,
      embeddingDimension,
      embeddingPreview,
      preprocessVersion,
      cropMode,
      qualityScore,
      embedding
    }
  }
}
