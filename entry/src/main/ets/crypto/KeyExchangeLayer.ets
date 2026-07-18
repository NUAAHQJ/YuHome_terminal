import cryptoFramework from '@ohos.security.cryptoFramework'
import { util } from '@kit.ArkTS'
const CURVE_CANDIDATES: string[] = ['NID_X9_62_prime256v1', 'prime256v1', 'secp256r1']
const ECDH_TOPIC_PREFIX = 'key/ecdh/pub/'
const SALT = new Uint8Array([
  0xC0, 0xFF, 0xEE, 0xCA, 0xFE, 0xBA, 0xBE, 0xDA,
  0xCE, 0xDE, 0xAD, 0xBE, 0xEF, 0xFE, 0xED, 0xFA
])

interface DeviceKeyState {
  deviceId: string
  keyPair: cryptoFramework.KeyPair | null
  publicKeyRaw: Uint8Array | null
  remotePublicKeyRaw: Uint8Array | null
  established: boolean
  curveName: string
  pendingAesKey: Uint8Array | null
  pendingSm4Key: Uint8Array | null
  pendingRemotePublicKeyRaw: Uint8Array | null
}

interface CurveChoice {
  name: string
  params: cryptoFramework.ECCCommonParamsSpec
}

export interface KeyExchangeResult {
  ok: boolean
  message: string
  deviceId: string
  replyTopic?: string
  replyPublicKey?: Uint8Array
  keyReady?: boolean
}

export interface PendingKeyMaterial {
  deviceId: string
  aesKey: Uint8Array
  sm4Key: Uint8Array
}

function bytesEqual(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) {
    return false
  }
  let diff = 0
  for (let i = 0; i < left.length; i++) {
    diff |= left[i] ^ right[i]
  }
  return diff === 0
}

function bytesToHex(data: Uint8Array): string {
  return Array.from(data).map((b: number) => b.toString(16).padStart(2, '0')).join('')
}

function concatBytes(left: Uint8Array, right: Uint8Array): Uint8Array {
  const out = new Uint8Array(left.length + right.length)
  out.set(left, 0)
  out.set(right, left.length)
  return out
}

function bytesToBigint(data: Uint8Array): bigint {
  let hex = ''
  for (let i = 0; i < data.length; i++) {
    hex += data[i].toString(16).padStart(2, '0')
  }
  return BigInt(`0x${hex}`)
}

function bigintToFixedBytes(value: bigint, length: number): Uint8Array {
  let hex = value.toString(16)
  if (hex.length > length * 2) {
    hex = hex.substring(hex.length - length * 2)
  }
  while (hex.length < length * 2) {
    hex = `0${hex}`
  }
  const out = new Uint8Array(length)
  for (let i = 0; i < length; i++) {
    out[i] = Number.parseInt(hex.substring(i * 2, i * 2 + 2), 16)
  }
  return out
}

function rawPublicKeyToPoint(payload: Uint8Array): cryptoFramework.Point {
  return {
    x: bytesToBigint(payload.slice(1, 33)),
    y: bytesToBigint(payload.slice(33, 65))
  }
}

function pointToRawPublicKey(point: cryptoFramework.Point): Uint8Array {
  const out = new Uint8Array(65)
  out[0] = 0x04
  out.set(bigintToFixedBytes(point.x, 32), 1)
  out.set(bigintToFixedBytes(point.y, 32), 33)
  return out
}

function encodeUtf8(text: string): Uint8Array {
  const encoder = new util.TextEncoder()
  return encoder.encodeInto(text)
}

function normalizeSecret(secret: Uint8Array): Uint8Array {
  if (secret.length === 32) {
    return secret
  }
  if (secret.length > 32) {
    return secret.slice(secret.length - 32)
  }
  const out = new Uint8Array(32)
  out.set(secret, 32 - secret.length)
  return out
}

function parseDeviceId(topic: string): string {
  if (!topic.startsWith(ECDH_TOPIC_PREFIX)) {
    return ''
  }
  return topic.substring(ECDH_TOPIC_PREFIX.length)
}

function getCurveChoice(): CurveChoice {
  let lastError = ''
  for (const curveName of CURVE_CANDIDATES) {
    try {
      const choice: CurveChoice = {
        name: curveName,
        params: cryptoFramework.ECCKeyUtil.genECCCommonParamsSpec(curveName)
      }
      return choice
    } catch (err) {
      lastError = (err as Error).message
    }
  }
  throw new Error(`P-256 curve unavailable: ${lastError}`)
}

function getCurveParamsByName(curveName: string): cryptoFramework.ECCCommonParamsSpec {
  return cryptoFramework.ECCKeyUtil.genECCCommonParamsSpec(curveName)
}

function buildResult(ok: boolean, message: string, deviceId: string, replyTopic?: string, replyPublicKey?: Uint8Array, keyReady?: boolean): KeyExchangeResult {
  const result: KeyExchangeResult = {
    ok,
    message,
    deviceId,
    replyTopic,
    replyPublicKey,
    keyReady
  }
  return result
}

const SHA256_K: number[] = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
  0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
  0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
  0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
]

function rotr(value: number, bits: number): number {
  return ((value >>> bits) | (value << (32 - bits))) >>> 0
}

function sha256(data: Uint8Array): Uint8Array {
  const bitLenHigh = Math.floor(data.length / 0x20000000) >>> 0
  const bitLenLow = (data.length * 8) >>> 0
  const padLength = (64 - ((data.length + 1 + 8) % 64)) % 64
  const padded = new Uint8Array(data.length + 1 + padLength + 8)
  padded.set(data, 0)
  padded[data.length] = 0x80

  const lenOffset = padded.length - 8
  padded[lenOffset] = (bitLenHigh >>> 24) & 0xff
  padded[lenOffset + 1] = (bitLenHigh >>> 16) & 0xff
  padded[lenOffset + 2] = (bitLenHigh >>> 8) & 0xff
  padded[lenOffset + 3] = bitLenHigh & 0xff
  padded[lenOffset + 4] = (bitLenLow >>> 24) & 0xff
  padded[lenOffset + 5] = (bitLenLow >>> 16) & 0xff
  padded[lenOffset + 6] = (bitLenLow >>> 8) & 0xff
  padded[lenOffset + 7] = bitLenLow & 0xff

  let h0 = 0x6a09e667
  let h1 = 0xbb67ae85
  let h2 = 0x3c6ef372
  let h3 = 0xa54ff53a
  let h4 = 0x510e527f
  let h5 = 0x9b05688c
  let h6 = 0x1f83d9ab
  let h7 = 0x5be0cd19

  for (let offset = 0; offset < padded.length; offset += 64) {
    const w: number[] = new Array<number>(64)
    for (let i = 0; i < 16; i++) {
      const j = offset + i * 4
      w[i] = (((padded[j] << 24) | (padded[j + 1] << 16) | (padded[j + 2] << 8) | padded[j + 3]) >>> 0)
    }
    for (let i = 16; i < 64; i++) {
      const s0 = (rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3)) >>> 0
      const s1 = (rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10)) >>> 0
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) >>> 0
    }

    let a = h0
    let b = h1
    let c = h2
    let d = h3
    let e = h4
    let f = h5
    let g = h6
    let h = h7

    for (let i = 0; i < 64; i++) {
      const s1 = (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) >>> 0
      const ch = ((e & f) ^ ((~e) & g)) >>> 0
      const temp1 = (h + s1 + ch + SHA256_K[i] + w[i]) >>> 0
      const s0 = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) >>> 0
      const maj = ((a & b) ^ (a & c) ^ (b & c)) >>> 0
      const temp2 = (s0 + maj) >>> 0

      h = g
      g = f
      f = e
      e = (d + temp1) >>> 0
      d = c
      c = b
      b = a
      a = (temp1 + temp2) >>> 0
    }

    h0 = (h0 + a) >>> 0
    h1 = (h1 + b) >>> 0
    h2 = (h2 + c) >>> 0
    h3 = (h3 + d) >>> 0
    h4 = (h4 + e) >>> 0
    h5 = (h5 + f) >>> 0
    h6 = (h6 + g) >>> 0
    h7 = (h7 + h) >>> 0
  }

  const digestWords: number[] = [h0, h1, h2, h3, h4, h5, h6, h7]
  const digest = new Uint8Array(32)
  for (let i = 0; i < digestWords.length; i++) {
    const word = digestWords[i]
    digest[i * 4] = (word >>> 24) & 0xff
    digest[i * 4 + 1] = (word >>> 16) & 0xff
    digest[i * 4 + 2] = (word >>> 8) & 0xff
    digest[i * 4 + 3] = word & 0xff
  }
  return digest
}

async function hmacSha256(key: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
  let actualKey = key
  if (actualKey.length > 64) {
    actualKey = sha256(actualKey)
  }

  const keyBlock = new Uint8Array(64)
  keyBlock.set(actualKey, 0)
  const innerPad = new Uint8Array(64)
  const outerPad = new Uint8Array(64)
  for (let i = 0; i < 64; i++) {
    innerPad[i] = keyBlock[i] ^ 0x36
    outerPad[i] = keyBlock[i] ^ 0x5c
  }

  const innerInput = new Uint8Array(innerPad.length + data.length)
  innerInput.set(innerPad, 0)
  innerInput.set(data, innerPad.length)
  const innerHash = sha256(innerInput)

  const outerInput = new Uint8Array(outerPad.length + innerHash.length)
  outerInput.set(outerPad, 0)
  outerInput.set(innerHash, outerPad.length)
  return sha256(outerInput)
}

async function hkdfSha256(ikm: Uint8Array, infoText: string, length: number): Promise<Uint8Array> {
  const prk = await hmacSha256(SALT, ikm)
  const info = encodeUtf8(infoText)
  let previous = new Uint8Array(0)
  let output = new Uint8Array(0)
  let counter = 1

  while (output.length < length) {
    const blockInput = new Uint8Array(previous.length + info.length + 1)
    blockInput.set(previous, 0)
    blockInput.set(info, previous.length)
    blockInput[blockInput.length - 1] = counter
    previous = await hmacSha256(prk, blockInput)
    output = concatBytes(output, previous)
    counter += 1
  }

  return output.slice(0, length)
}

export class KeyExchangeLayer {
  private states: Map<string, DeviceKeyState> = new Map()

  isKeyExchangeTopic(topic: string): boolean {
    return topic.startsWith(ECDH_TOPIC_PREFIX)
  }

  resetDevice(deviceId: string): void {
    this.states.delete(deviceId)
    console.info(`[ECDH] reset local state for ${deviceId}`)
  }

  async createLocalPublicKey(deviceId: string): Promise<KeyExchangeResult> {
    if (deviceId.length === 0) {
      return buildResult(false, 'empty ECDH deviceId', '')
    }
    let state = this.states.get(deviceId)
    if (!state) {
      state = {
        deviceId,
        keyPair: null,
        publicKeyRaw: null,
        remotePublicKeyRaw: null,
        established: false,
        curveName: CURVE_CANDIDATES[0],
        pendingAesKey: null,
        pendingSm4Key: null,
        pendingRemotePublicKeyRaw: null
      }
      this.states.set(deviceId, state)
    }
    if (state.keyPair === null || state.publicKeyRaw === null) {
      const curve = getCurveChoice()
      const generator = cryptoFramework.createAsyKeyGeneratorBySpec(curve.params)
      state.keyPair = await generator.generateKeyPair()
      state.curveName = curve.name
      const publicPoint: cryptoFramework.Point = {
        x: state.keyPair.pubKey.getAsyKeySpec(cryptoFramework.AsyKeySpecItem.ECC_PK_X_BN) as bigint,
        y: state.keyPair.pubKey.getAsyKeySpec(cryptoFramework.AsyKeySpecItem.ECC_PK_Y_BN) as bigint
      }
      state.publicKeyRaw = pointToRawPublicKey(publicPoint)
    }
    return buildResult(true, `ECDH local public key ready ${deviceId}`, deviceId, `${ECDH_TOPIC_PREFIX}${deviceId}`, state.publicKeyRaw, state.established)
  }

  async derivePendingKeys(deviceId: string, state: DeviceKeyState, payload: Uint8Array): Promise<boolean> {
    try {
      if (state.keyPair === null) {
        throw new Error('local key pair missing')
      }
      if (state.established && state.remotePublicKeyRaw !== null && bytesEqual(payload, state.remotePublicKeyRaw)) {
        console.info(`[ECDH] skip repeated key install ${deviceId}`)
        return false
      }
      const remotePoint = rawPublicKeyToPoint(payload)
      const remotePubSpec: cryptoFramework.ECCPubKeySpec = {
        algName: 'ECC',
        specType: cryptoFramework.AsyKeySpecType.PUBLIC_KEY_SPEC,
        params: getCurveParamsByName(state.curveName),
        pk: remotePoint
      }
      const remotePubKey = await cryptoFramework.createAsyKeyGeneratorBySpec(remotePubSpec).generatePubKey()
      const agreement = cryptoFramework.createKeyAgreement('ECC')
      const secret = normalizeSecret((await agreement.generateSecret(state.keyPair.priKey, remotePubKey)).data)
      const aesKey = await hkdfSha256(secret, 'aes-key', 32)
      const sm4Key = await hkdfSha256(secret, 'sm4-key', 16)

      state.pendingAesKey = aesKey.slice()
      state.pendingSm4Key = sm4Key.slice()
      state.pendingRemotePublicKeyRaw = payload.slice()

      console.info(`[ECDH] ${deviceId} remotePub=${bytesToHex(payload)}`)
      if (state.publicKeyRaw !== null) {
        console.info(`[ECDH] ${deviceId} localPub=${bytesToHex(state.publicKeyRaw)}`)
      }
      console.info(`[ECDH] ${deviceId} secret=${bytesToHex(secret)}`)
      console.info(`[ECDH] ${deviceId} pending aes=${bytesToHex(aesKey)} sm4=${bytesToHex(sm4Key)}`)
      return true
    } catch (err) {
      console.info(`[ECDH] key derive failed ${deviceId}: ${(err as Error).message}`)
      return false
    }
  }

  async prepareKeysForPublicKey(topic: string, payload: Uint8Array): Promise<boolean> {
    const deviceId = parseDeviceId(topic)
    if (deviceId.length === 0) {
      return false
    }
    const state = this.states.get(deviceId)
    if (!state) {
      return false
    }
    return await this.derivePendingKeys(deviceId, state, payload)
  }

  getPendingKeys(deviceId: string): PendingKeyMaterial | null {
    const state = this.states.get(deviceId)
    if (!state || state.pendingAesKey === null || state.pendingSm4Key === null) {
      return null
    }
    return {
      deviceId,
      aesKey: state.pendingAesKey.slice(),
      sm4Key: state.pendingSm4Key.slice()
    }
  }

  activatePendingKeys(deviceId: string): PendingKeyMaterial | null {
    const state = this.states.get(deviceId)
    if (!state || state.pendingAesKey === null || state.pendingSm4Key === null || state.pendingRemotePublicKeyRaw === null) {
      return null
    }
    const material: PendingKeyMaterial = {
      deviceId,
      aesKey: state.pendingAesKey.slice(),
      sm4Key: state.pendingSm4Key.slice()
    }
    state.remotePublicKeyRaw = state.pendingRemotePublicKeyRaw.slice()
    state.established = true
    state.pendingAesKey = null
    state.pendingSm4Key = null
    state.pendingRemotePublicKeyRaw = null
    console.info(`[ECDH] activated pending keys ${deviceId}`)
    return material
  }

  async handlePublicKey(topic: string, payload: Uint8Array): Promise<KeyExchangeResult> {
    const deviceId = parseDeviceId(topic)
    if (deviceId.length === 0) {
      return buildResult(false, `bad ECDH topic: ${topic}`, '')
    }
    if (payload.length !== 65 || payload[0] !== 0x04) {
      return buildResult(false, `bad ECDH public key length=${payload.length}`, deviceId)
    }

    let state = this.states.get(deviceId)
    if (!state) {
      state = {
        deviceId,
        keyPair: null,
        publicKeyRaw: null,
        remotePublicKeyRaw: null,
        established: false,
        curveName: CURVE_CANDIDATES[0],
        pendingAesKey: null,
        pendingSm4Key: null,
        pendingRemotePublicKeyRaw: null
      }
      this.states.set(deviceId, state)
    }

    if (state.publicKeyRaw !== null && bytesEqual(payload, state.publicKeyRaw)) {
      return buildResult(true, `ECDH ignored own public key ${deviceId}`, deviceId, undefined, undefined, state.established)
    }

    if (state.established && state.remotePublicKeyRaw !== null && bytesEqual(payload, state.remotePublicKeyRaw)) {
      return buildResult(true, `ECDH ignored repeated remote key ${deviceId}`, deviceId, undefined, undefined, true)
    }

    if (state.keyPair === null || state.publicKeyRaw === null) {
      const curve = getCurveChoice()
      const generator = cryptoFramework.createAsyKeyGeneratorBySpec(curve.params)
      state.keyPair = await generator.generateKeyPair()
      state.curveName = curve.name
      const publicPoint: cryptoFramework.Point = {
        x: state.keyPair.pubKey.getAsyKeySpec(cryptoFramework.AsyKeySpecItem.ECC_PK_X_BN) as bigint,
        y: state.keyPair.pubKey.getAsyKeySpec(cryptoFramework.AsyKeySpecItem.ECC_PK_Y_BN) as bigint
      }
      state.publicKeyRaw = pointToRawPublicKey(publicPoint)
    }

    return buildResult(true, `ECDH public key ready ${deviceId}`, deviceId, `${ECDH_TOPIC_PREFIX}${deviceId}`, state.publicKeyRaw, state.established)
  }
}
