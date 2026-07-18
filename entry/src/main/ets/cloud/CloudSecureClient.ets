import http from '@ohos.net.http'
import cryptoFramework from '@ohos.security.cryptoFramework'
import { util } from '@kit.ArkTS'
import { sm4GcmDecrypt, sm4GcmEncrypt } from '../crypto/Sm4Gcm'
import { ensureTlsIdentityFiles } from '../mqtt/TlsIdentityFiles'

export type CloudRequestHandler = (path: string, body: string) => Promise<string>

const CURVE_CANDIDATES: string[] = ['NID_X9_62_prime256v1', 'prime256v1', 'secp256r1']
const CLOUD_ECDH_SALT = new Uint8Array([
  0xC0, 0xFF, 0xEE, 0xCA, 0xFE, 0xBA, 0xBE, 0xDA,
  0xCE, 0xDE, 0xAD, 0xBE, 0xEF, 0xFE, 0xED, 0xFA
])
const GCM_IV_LENGTH: number = 12
const GCM_TAG_LENGTH: number = 16
const AES_ALG_NAME: string = 'AES256'
const AES_CIPHER_TRANS: string = 'AES256|GCM'

interface CloudSecureSession {
  sessionId: string
  cloudPublicKey: Uint8Array
  crypto: string
  aesKey: Uint8Array
  sm4Key: Uint8Array
  expiresAtMs: number
  seq: number
}

interface CloudSecureHelloRequest {
  clientId: string
  role: string
  publicKeyBase64: string
  supportedCrypto: string[]
}

interface CloudSecurePacket {
  sessionId: string
  crypto: string
  seq: number
  iv: string
  tag: string
  ciphertext: string
  timestamp: number
}

interface AesGcmParts {
  ciphertext: Uint8Array
  tag: Uint8Array
}

interface CurveChoice {
  name: string
  params: cryptoFramework.ECCCommonParamsSpec
}

function encodeUtf8(text: string): Uint8Array {
  const encoder = new util.TextEncoder()
  return encoder.encodeInto(text)
}

function decodeUtf8(data: Uint8Array): string {
  const decoder = new util.TextDecoder()
  return decoder.decodeWithStream(data)
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

function getCurveChoice(): CurveChoice {
  let lastError = ''
  for (const curveName of CURVE_CANDIDATES) {
    try {
      return {
        name: curveName,
        params: cryptoFramework.ECCKeyUtil.genECCCommonParamsSpec(curveName)
      }
    } catch (err) {
      lastError = (err as Error).message
    }
  }
  throw new Error(`P-256 curve unavailable: ${lastError}`)
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
  const prk = await hmacSha256(CLOUD_ECDH_SALT, ikm)
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

export class CloudSecureClient {
  private baseUrl: string
  private certificateDirectory: string = ''
  private requestHandler: CloudRequestHandler | null = null
  private session: CloudSecureSession | null = null
  private requestInFlight: boolean = false

  constructor(baseUrl: string) {
    this.baseUrl = baseUrl
  }

  getEndpoint(): string {
    return this.baseUrl
  }

  configureMutualTls(directory: string): void {
    this.certificateDirectory = directory
    this.session = null
  }

  configureRequestHandler(handler: CloudRequestHandler): void {
    this.requestHandler = handler
    this.session = null
  }

  isReady(): boolean {
    return this.session !== null && Date.now() < this.session.expiresAtMs - 30000
  }

  async ensureSession(): Promise<void> {
    if (this.isReady()) {
      return
    }
    const curve = getCurveChoice()
    const generator = cryptoFramework.createAsyKeyGeneratorBySpec(curve.params)
    const keyPair = await generator.generateKeyPair()
    const publicPoint: cryptoFramework.Point = {
      x: keyPair.pubKey.getAsyKeySpec(cryptoFramework.AsyKeySpecItem.ECC_PK_X_BN) as bigint,
      y: keyPair.pubKey.getAsyKeySpec(cryptoFramework.AsyKeySpecItem.ECC_PK_Y_BN) as bigint
    }
    const publicKeyRaw = pointToRawPublicKey(publicPoint)
    const hello: CloudSecureHelloRequest = {
      clientId: 'dayu_gateway_001',
      role: 'dayu',
      publicKeyBase64: this.uint8ArrayToBase64(publicKeyRaw),
      supportedCrypto: ['SM4', 'AES']
    }
    const text = await this.httpRequest(`${this.baseUrl}/api/secure/hello`, http.RequestMethod.POST, JSON.stringify(hello))
    const response = JSON.parse(text) as Record<string, Object>
    if (response['ok'] !== true) {
      throw new Error(`secure hello failed: ${text}`)
    }
    const cloudPublicKey = this.base64ToUint8Array(response['cloudPublicKeyBase64'] as string)
    const remotePubSpec: cryptoFramework.ECCPubKeySpec = {
      algName: 'ECC',
      specType: cryptoFramework.AsyKeySpecType.PUBLIC_KEY_SPEC,
      params: curve.params,
      pk: rawPublicKeyToPoint(cloudPublicKey)
    }
    const remotePubKey = await cryptoFramework.createAsyKeyGeneratorBySpec(remotePubSpec).generatePubKey()
    const agreement = cryptoFramework.createKeyAgreement('ECC')
    const secret = normalizeSecret((await agreement.generateSecret(keyPair.priKey, remotePubKey)).data)
    const aesKey = await hkdfSha256(secret, 'cloud-aes-key', 32)
    const sm4Key = await hkdfSha256(secret, 'cloud-sm4-key', 16)
    const expiresAt = response['expiresAt'] as string
    const selectedCrypto = this.normalizeCryptoMode(response['crypto'] as string)
    this.session = {
      sessionId: response['sessionId'] as string,
      cloudPublicKey,
      crypto: selectedCrypto,
      aesKey,
      sm4Key,
      expiresAtMs: Date.parse(expiresAt),
      seq: 0
    }
    console.info(`[CloudSecure] ${selectedCrypto} session ready ${this.session.sessionId}`)
  }

  async postSecure(path: string, payload: Object): Promise<Record<string, Object>> {
    await this.waitForRequestTurn()
    try {
      try {
        return await this.postSecureOnce(path, payload)
      } catch (err) {
        const message = (err as Error).message
        if (message.indexOf('secure session not found') < 0 &&
          message.indexOf('secure session expired') < 0 &&
          message.indexOf('secure crypto changed') < 0 &&
          message.indexOf('secure crypto mismatch') < 0) {
          throw new Error(message)
        }
        console.info(`[CloudSecure] reset stale session: ${message}`)
        this.session = null
        return await this.postSecureOnce(path, payload)
      }
    } finally {
      this.requestInFlight = false
    }
  }

  private async waitForRequestTurn(): Promise<void> {
    while (this.requestInFlight) {
      await new Promise<void>((resolve: () => void) => setTimeout(resolve, 20))
    }
    this.requestInFlight = true
  }

  private async postSecureOnce(path: string, payload: Object): Promise<Record<string, Object>> {
    await this.ensureSession()
    const session = this.session as CloudSecureSession
    const packet = await this.encryptPacket(session, payload)
    const text = await this.httpRequest(`${this.baseUrl}${path}`, http.RequestMethod.POST, JSON.stringify(packet))
    const response = JSON.parse(text) as Record<string, Object>
    if (response['ok'] !== true) {
      throw new Error(`secure request failed: ${text}`)
    }
    const secure = response['secure'] as Record<string, Object>
    if (!secure) {
      return response
    }
    const plaintext = await this.decryptPacket(session, secure)
    return JSON.parse(plaintext) as Record<string, Object>
  }

  private async encryptPacket(session: CloudSecureSession, payload: Object): Promise<CloudSecurePacket> {
    const iv = await this.randomIv()
    const encrypted = session.crypto === 'SM4' ?
      this.encryptSm4Gcm(JSON.stringify(payload), session.sm4Key, iv) :
      await this.encryptAesGcm(JSON.stringify(payload), session.aesKey, iv)
    session.seq += 1
    const packet: CloudSecurePacket = {
      sessionId: session.sessionId,
      crypto: session.crypto,
      seq: session.seq,
      iv: this.uint8ArrayToBase64(iv),
      tag: this.uint8ArrayToBase64(encrypted.tag),
      ciphertext: this.uint8ArrayToBase64(encrypted.ciphertext),
      timestamp: Date.now()
    }
    return packet
  }

  private async decryptPacket(session: CloudSecureSession, packet: Record<string, Object>): Promise<string> {
    const iv = this.base64ToUint8Array(packet['iv'] as string)
    const tag = this.base64ToUint8Array(packet['tag'] as string)
    const ciphertext = this.base64ToUint8Array(packet['ciphertext'] as string)
    if (this.normalizeCryptoMode(packet['crypto'] as string) !== session.crypto) {
      throw new Error('secure crypto mismatch')
    }
    if (session.crypto === 'SM4') {
      return this.decryptSm4Gcm(ciphertext, tag, iv, session.sm4Key)
    }
    return await this.decryptAesGcm(ciphertext, tag, iv, session.aesKey)
  }

  private normalizeCryptoMode(value: string): string {
    return value === 'SM4' ? 'SM4' : 'AES'
  }

  private encryptSm4Gcm(plaintext: string, keyBytes: Uint8Array, iv: Uint8Array): AesGcmParts {
    const encrypted = sm4GcmEncrypt(encodeUtf8(plaintext), keyBytes, iv)
    return {
      ciphertext: encrypted.slice(GCM_IV_LENGTH + GCM_TAG_LENGTH),
      tag: encrypted.slice(GCM_IV_LENGTH, GCM_IV_LENGTH + GCM_TAG_LENGTH)
    }
  }

  private decryptSm4Gcm(ciphertext: Uint8Array, tag: Uint8Array, iv: Uint8Array, keyBytes: Uint8Array): string {
    const payload = new Uint8Array(GCM_IV_LENGTH + GCM_TAG_LENGTH + ciphertext.length)
    payload.set(iv, 0)
    payload.set(tag, GCM_IV_LENGTH)
    payload.set(ciphertext, GCM_IV_LENGTH + GCM_TAG_LENGTH)
    return decodeUtf8(sm4GcmDecrypt(payload, keyBytes))
  }

  private async encryptAesGcm(plaintext: string, keyBytes: Uint8Array, iv: Uint8Array): Promise<AesGcmParts> {
    const generator = cryptoFramework.createSymKeyGenerator(AES_ALG_NAME)
    const symKey = await generator.convertKey({ data: keyBytes })
    const cipher = cryptoFramework.createCipher(AES_CIPHER_TRANS)
    const gcmParams: cryptoFramework.GcmParamsSpec = {
      algName: 'GcmParamsSpec',
      iv: { data: iv },
      aad: { data: new Uint8Array(0) },
      authTag: { data: new Uint8Array(GCM_TAG_LENGTH) }
    }
    await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, gcmParams)
    const encrypted = await cipher.doFinal({ data: encodeUtf8(plaintext) })
    const ctLen = encrypted.data.length - GCM_TAG_LENGTH
    const result: AesGcmParts = {
      ciphertext: encrypted.data.slice(0, ctLen),
      tag: encrypted.data.slice(ctLen)
    }
    return result
  }

  private async decryptAesGcm(ciphertext: Uint8Array, tag: Uint8Array, iv: Uint8Array, keyBytes: Uint8Array): Promise<string> {
    const generator = cryptoFramework.createSymKeyGenerator(AES_ALG_NAME)
    const symKey = await generator.convertKey({ data: keyBytes })
    const cipher = cryptoFramework.createCipher(AES_CIPHER_TRANS)
    const gcmParams: cryptoFramework.GcmParamsSpec = {
      algName: 'GcmParamsSpec',
      iv: { data: iv },
      aad: { data: new Uint8Array(0) },
      authTag: { data: tag }
    }
    await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, gcmParams)
    const decrypted = await cipher.doFinal({ data: ciphertext })
    return decodeUtf8(decrypted.data)
  }

  private async randomIv(): Promise<Uint8Array> {
    const random = cryptoFramework.createRandom()
    const ivBlob = random.generateRandomSync(GCM_IV_LENGTH)
    return ivBlob.data
  }

  private async httpRequest(url: string, method: http.RequestMethod, body?: string): Promise<string> {
    if (this.requestHandler) {
      const path = url.startsWith(this.baseUrl) ? url.substring(this.baseUrl.length) : url
      return await this.requestHandler(path, body ?? '')
    }
    const request = http.createHttp()
    try {
      const options: http.HttpRequestOptions = {
        method,
        header: {
          'Content-Type': 'application/json'
        },
        extraData: body ?? '',
        connectTimeout: 12000,
        readTimeout: 12000
      }
      if (url.startsWith('https://')) {
        const paths = await ensureTlsIdentityFiles(this.certificateDirectory)
        options.caPath = paths.caPath
        options.clientCert = {
          certPath: paths.certPath,
          keyPath: paths.keyPath
        }
      }
      const result = await request.request(url, options)
      const responseText = `${result.result}`
      if (result.responseCode < 200 || result.responseCode >= 300) {
        throw new Error(`HTTP ${result.responseCode}: ${responseText.substring(0, 120)}`)
      }
      return responseText
    } finally {
      request.destroy()
    }
  }

  private base64ToUint8Array(base64: string): Uint8Array {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    let clean = ''
    for (let i = 0; i < base64.length; i++) {
      const c = base64.charAt(i)
      if (c !== '=' && c !== ' ' && c !== '\n' && c !== '\r') {
        clean += c
      }
    }
    const outLen = Math.floor(clean.length * 3 / 4)
    const out = new Uint8Array(outLen)
    let o = 0
    let i = 0
    while (i < clean.length) {
      const b0 = chars.indexOf(clean.charAt(i))
      const b1 = i + 1 < clean.length ? chars.indexOf(clean.charAt(i + 1)) : 0
      const b2 = i + 2 < clean.length ? chars.indexOf(clean.charAt(i + 2)) : 0
      const b3 = i + 3 < clean.length ? chars.indexOf(clean.charAt(i + 3)) : 0
      out[o++] = (b0 << 2) | (b1 >> 4)
      if (i + 2 < clean.length && clean.charAt(i + 2) !== '=') {
        out[o++] = ((b1 & 15) << 4) | (b2 >> 2)
      }
      if (i + 3 < clean.length && clean.charAt(i + 3) !== '=') {
        out[o++] = ((b2 & 3) << 6) | b3
      }
      i += 4
    }
    return out.slice(0, o)
  }

  private uint8ArrayToBase64(data: Uint8Array): string {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    let result = ''
    for (let i = 0; i < data.length; i += 3) {
      const b0 = data[i]
      const b1 = i + 1 < data.length ? data[i + 1] : 0
      const b2 = i + 2 < data.length ? data[i + 2] : 0
      result += chars.charAt(b0 >> 2)
      result += chars.charAt(((b0 & 3) << 4) | (b1 >> 4))
      result += i + 1 < data.length ? chars.charAt(((b1 & 15) << 2) | (b2 >> 6)) : '='
      result += i + 2 < data.length ? chars.charAt(b2 & 63) : '='
    }
    return result
  }
}
