import { Context } from '@ohos.abilityAccessCtrl'
import fs from '@ohos.file.fs'

const SPEAKER_USERS_FILE: string = 'speaker_profiles.json'
const SPEAKER_USERS_BACKUP_FILE: string = 'speaker_profiles.backup.json'
export const SPEAKER_MATCH_THRESHOLD: number = 0.60
export const SPEAKER_MODEL_VERSION: string = 'campplus-zh-cn-16k-common-v1'

export interface SpeakerProfile {
  userId: string
  name: string
  enabled: boolean
  samples: number
  createdAt: number
  modelVersion: string
  dimension: number
  embeddings: number[][]
}

interface StoredSpeakerProfiles {
  version: number
  protectionEnabled: boolean
  users: SpeakerProfile[]
}

export interface SpeakerMatchResult {
  matched: boolean
  userId: string
  userName: string
  score: number
  threshold: number
}

export interface SpeakerEnrollmentQuality {
  valid: boolean
  averageSimilarity: number
  message: string
}

function normalizeEmbedding(values: number[]): number[] {
  let sumSquares = 0
  values.forEach((value: number) => {
    sumSquares += value * value
  })
  const norm = Math.sqrt(sumSquares)
  if (norm <= 1e-6) {
    return []
  }
  return values.map((value: number) => value / norm)
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

export class SpeakerProfileManager {
  private users: SpeakerProfile[] = []
  private protectionEnabled: boolean = false

  listUsers(): SpeakerProfile[] {
    return this.users.slice()
  }

  isProtectionEnabled(): boolean {
    return this.protectionEnabled && this.getEnabledUserCount() > 0
  }

  isProtectionRequested(): boolean {
    return this.protectionEnabled
  }

  getEnabledUserCount(): number {
    return this.users.filter((user: SpeakerProfile) => user.enabled && user.embeddings.length > 0).length
  }

  setProtectionEnabled(enabled: boolean): void {
    this.protectionEnabled = enabled
  }

  async load(context: Context): Promise<number> {
    const primaryPath = `${context.filesDir}/${SPEAKER_USERS_FILE}`
    const backupPath = `${context.filesDir}/${SPEAKER_USERS_BACKUP_FILE}`
    const primary = await this.readStored(primaryPath)
    if (primary !== null) {
      this.applyStored(primary)
      await this.writeStored(backupPath, JSON.stringify(this.toStored())).catch((err: Error) => {
        console.info(`[Voiceprint][backup-fail] ${err.message}`)
      })
      return this.users.length
    }
    const backup = await this.readStored(backupPath)
    if (backup !== null) {
      this.applyStored(backup)
      return this.users.length
    }
    this.users = []
    this.protectionEnabled = false
    return 0
  }

  async save(context: Context): Promise<void> {
    const json = JSON.stringify(this.toStored())
    await this.writeStored(`${context.filesDir}/${SPEAKER_USERS_BACKUP_FILE}`, json)
    await this.writeStored(`${context.filesDir}/${SPEAKER_USERS_FILE}`, json)
    console.info(`[Voiceprint][save] users=${this.users.length} enabled=${this.protectionEnabled}`)
  }

  addUser(name: string, samples: number[][]): SpeakerProfile {
    const normalized = this.normalizeSamples(samples)
    if (normalized.length < 3) {
      throw new Error('需要完成三轮有效声纹采集')
    }
    const profile: SpeakerProfile = {
      userId: `speaker_${Date.now()}`,
      name: name.trim().length > 0 ? name.trim() : `用户${this.users.length + 1}`,
      enabled: true,
      samples: normalized.length,
      createdAt: Date.now(),
      modelVersion: SPEAKER_MODEL_VERSION,
      dimension: normalized[0].length,
      embeddings: normalized
    }
    this.users = [profile, ...this.users]
    this.protectionEnabled = true
    return profile
  }

  deleteUser(userId: string): void {
    this.users = this.users.filter((user: SpeakerProfile) => user.userId !== userId)
    if (this.getEnabledUserCount() === 0) {
      this.protectionEnabled = false
    }
  }

  setUserEnabled(userId: string, enabled: boolean): void {
    this.users = this.users.map((user: SpeakerProfile): SpeakerProfile => {
      if (user.userId !== userId) {
        return user
      }
      return {
        userId: user.userId,
        name: user.name,
        enabled,
        samples: user.samples,
        createdAt: user.createdAt,
        modelVersion: user.modelVersion,
        dimension: user.dimension,
        embeddings: user.embeddings
      }
    })
    if (this.getEnabledUserCount() === 0) {
      this.protectionEnabled = false
    }
  }

  evaluateEnrollment(samples: number[][]): SpeakerEnrollmentQuality {
    const normalized = this.normalizeSamples(samples)
    if (normalized.length < 3) {
      return { valid: false, averageSimilarity: -1, message: '需要三轮有效语音' }
    }
    let total = 0
    let pairs = 0
    for (let i = 0; i < normalized.length; i++) {
      for (let j = i + 1; j < normalized.length; j++) {
        total += cosineSimilarity(normalized[i], normalized[j])
        pairs++
      }
    }
    const average = pairs > 0 ? total / pairs : -1
    return {
      valid: average >= 0.35,
      averageSimilarity: average,
      message: average >= 0.35 ? '三轮声纹一致' : '三轮差异较大，请重新录入'
    }
  }

  match(embedding: number[], threshold: number = SPEAKER_MATCH_THRESHOLD): SpeakerMatchResult {
    const query = normalizeEmbedding(embedding)
    let bestUserId = ''
    let bestUserName = ''
    let bestScore = -1
    this.users.forEach((user: SpeakerProfile) => {
      if (!user.enabled || user.modelVersion !== SPEAKER_MODEL_VERSION || user.dimension !== query.length) {
        return
      }
      let userScore = -1
      user.embeddings.forEach((sample: number[]) => {
        const score = cosineSimilarity(query, sample)
        if (score > userScore) {
          userScore = score
        }
      })
      if (userScore > bestScore) {
        bestScore = userScore
        bestUserId = user.userId
        bestUserName = user.name
      }
    })
    return {
      matched: bestScore >= threshold,
      userId: bestUserId,
      userName: bestUserName,
      score: bestScore,
      threshold
    }
  }

  private normalizeSamples(samples: number[][]): number[][] {
    if (samples.length === 0) {
      return []
    }
    const dimension = samples[0].length
    return samples
      .filter((sample: number[]) => sample.length === dimension && dimension > 0)
      .map((sample: number[]) => normalizeEmbedding(sample))
      .filter((sample: number[]) => sample.length === dimension)
  }

  private normalizeStoredUser(item: SpeakerProfile): SpeakerProfile {
    const embeddings = Array.isArray(item.embeddings) ? this.normalizeSamples(item.embeddings) : []
    return {
      userId: typeof item.userId === 'string' && item.userId.length > 0 ? item.userId : `speaker_${Date.now()}`,
      name: typeof item.name === 'string' && item.name.length > 0 ? item.name : '用户',
      enabled: item.enabled !== false,
      samples: embeddings.length,
      createdAt: typeof item.createdAt === 'number' ? item.createdAt : Date.now(),
      modelVersion: SPEAKER_MODEL_VERSION,
      dimension: embeddings.length > 0 ? embeddings[0].length : 0,
      embeddings
    }
  }

  private toStored(): StoredSpeakerProfiles {
    return {
      version: 1,
      protectionEnabled: this.protectionEnabled,
      users: this.users
    }
  }

  private applyStored(stored: StoredSpeakerProfiles): void {
    this.users = stored.users
      .map((item: SpeakerProfile): SpeakerProfile => this.normalizeStoredUser(item))
      .filter((item: SpeakerProfile) => item.embeddings.length > 0)
    this.protectionEnabled = stored.protectionEnabled === true && this.getEnabledUserCount() > 0
  }

  private async readStored(filePath: string): Promise<StoredSpeakerProfiles | null> {
    try {
      const exists = await fs.access(filePath).catch(() => false)
      if (!exists) {
        return null
      }
      const parsed = JSON.parse(await fs.readText(filePath)) as StoredSpeakerProfiles
      if (!parsed.users || !Array.isArray(parsed.users)) {
        return null
      }
      return parsed
    } catch (err) {
      console.info(`[Voiceprint][read-fail] ${filePath}: ${(err as Error).message}`)
      return null
    }
  }

  private async writeStored(filePath: string, json: string): Promise<void> {
    const file = await fs.open(filePath, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE)
    try {
      await fs.write(file.fd, json)
    } finally {
      fs.closeSync(file)
    }
  }
}
