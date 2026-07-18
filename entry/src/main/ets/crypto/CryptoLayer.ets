/**
 * CryptoLayer - ESP32 data-layer crypto adapter.
 *
 * Wire format stays aligned with ESP32:
 *   IV(12B) | TAG(16B) | CIPHERTEXT(NB)
 *
 * Selected mode is strict: SM4 only decrypts SM4, AES only decrypts AES.
 */
import cryptoFramework from '@ohos.security.cryptoFramework'
import { util } from '@kit.ArkTS'
import { sm4GcmDecrypt, sm4GcmEncrypt, sm4SelfTest } from './Sm4Gcm'

let activeCryptoMode: string = 'SM4'

export interface CryptoDecryptResult {
  plaintext: string
  mode: string
  keySource?: string
}

const AES_KEY_RAW = new Uint8Array([
  0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
  0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
  0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
  0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F
])

const SM4_KEY_RAW = new Uint8Array([
  0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF,
  0xFE, 0xDC, 0xBA, 0x98, 0x76, 0x54, 0x32, 0x10
])

const GCM_IV_LENGTH = 12
const GCM_TAG_LENGTH = 16
const AES_ALG_NAME = 'AES256'
const AES_CIPHER_TRANS = 'AES256|GCM'

let cachedAesSymKey: cryptoFramework.SymKey | null = null
let dynamicAesKey: Uint8Array | null = null
let dynamicSm4Key: Uint8Array | null = null

interface DeviceDynamicKeys {
  aesKey: Uint8Array
  sm4Key: Uint8Array
}

const deviceDynamicKeys: Map<string, DeviceDynamicKeys> = new Map()

function activeAesKeyBytes(): Uint8Array {
  return dynamicAesKey ?? AES_KEY_RAW
}

function activeSm4KeyBytes(): Uint8Array {
  return dynamicSm4Key ?? SM4_KEY_RAW
}

export function setDynamicCryptoKeys(aesKey: Uint8Array, sm4Key: Uint8Array): void {
  if (aesKey.length !== 32) {
    throw new Error(`dynamic AES key must be 32 bytes, got ${aesKey.length}`)
  }
  if (sm4Key.length !== 16) {
    throw new Error(`dynamic SM4 key must be 16 bytes, got ${sm4Key.length}`)
  }
  dynamicAesKey = aesKey.slice()
  dynamicSm4Key = sm4Key.slice()
  cachedAesSymKey = null
  console.info('[Crypto] dynamic AES/SM4 keys installed')
}

export function clearDynamicCryptoKeys(): void {
  dynamicAesKey = null
  dynamicSm4Key = null
  cachedAesSymKey = null
  console.info('[Crypto] dynamic AES/SM4 keys cleared')
}

export function getDynamicAesKey(): Uint8Array | null {
  return dynamicAesKey === null ? null : dynamicAesKey.slice()
}

export function getDynamicSm4Key(): Uint8Array | null {
  return dynamicSm4Key === null ? null : dynamicSm4Key.slice()
}

export function hasDynamicCryptoKeys(): boolean {
  return dynamicAesKey !== null && dynamicSm4Key !== null
}

export function setDeviceDynamicCryptoKeys(deviceId: string, aesKey: Uint8Array, sm4Key: Uint8Array): void {
  if (deviceId.length === 0) {
    throw new Error('deviceId is required for dynamic keys')
  }
  if (aesKey.length !== 32 || sm4Key.length !== 16) {
    throw new Error(`bad device key length aes=${aesKey.length} sm4=${sm4Key.length}`)
  }
  deviceDynamicKeys.set(deviceId, { aesKey: aesKey.slice(), sm4Key: sm4Key.slice() })
  console.info(`[Crypto] dynamic AES/SM4 keys installed for ${deviceId}`)
}

export function clearDeviceDynamicCryptoKeys(deviceId: string): void {
  deviceDynamicKeys.delete(deviceId)
  console.info(`[Crypto] dynamic AES/SM4 keys cleared for ${deviceId}`)
}

export function getDeviceDynamicAesKey(deviceId: string): Uint8Array | null {
  const keys = deviceDynamicKeys.get(deviceId)
  return keys ? keys.aesKey.slice() : null
}

export function getDeviceDynamicSm4Key(deviceId: string): Uint8Array | null {
  const keys = deviceDynamicKeys.get(deviceId)
  return keys ? keys.sm4Key.slice() : null
}

async function getAesSymKey(keyBytes?: Uint8Array): Promise<cryptoFramework.SymKey> {
  if (keyBytes !== undefined) {
    const generator = cryptoFramework.createSymKeyGenerator(AES_ALG_NAME)
    return await generator.convertKey({ data: keyBytes })
  }
  if (cachedAesSymKey !== null) {
    return cachedAesSymKey
  }
  const generator = cryptoFramework.createSymKeyGenerator(AES_ALG_NAME)
  cachedAesSymKey = await generator.convertKey({ data: activeAesKeyBytes() })
  return cachedAesSymKey
}

async function randomIv(): Promise<Uint8Array> {
  const random = cryptoFramework.createRandom()
  const ivBlob = random.generateRandomSync(GCM_IV_LENGTH)
  return ivBlob.data
}

async function encryptAesGcm(plaintext: string, iv?: Uint8Array, keyBytes?: Uint8Array): Promise<Uint8Array> {
  const symKey = await getAesSymKey(keyBytes)
  const cipher = cryptoFramework.createCipher(AES_CIPHER_TRANS)
  const actualIv = iv ?? await randomIv()

  const gcmParams: cryptoFramework.GcmParamsSpec = {
    algName: 'GcmParamsSpec',
    iv: { data: actualIv },
    aad: { data: new Uint8Array(0) },
    authTag: { data: new Uint8Array(GCM_TAG_LENGTH) }
  }

  await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, gcmParams)

  const encoder = new util.TextEncoder()
  const encrypted = await cipher.doFinal({ data: encoder.encodeInto(plaintext) })
  const ctLen = encrypted.data.length - GCM_TAG_LENGTH
  const ct = encrypted.data.slice(0, ctLen)
  const tag = encrypted.data.slice(ctLen)

  const result = new Uint8Array(GCM_IV_LENGTH + GCM_TAG_LENGTH + ct.length)
  result.set(actualIv, 0)
  result.set(tag, GCM_IV_LENGTH)
  result.set(ct, GCM_IV_LENGTH + GCM_TAG_LENGTH)
  return result
}

async function decryptAesGcm(payload: Uint8Array, keyBytes?: Uint8Array): Promise<string> {
  if (payload.length < GCM_IV_LENGTH + GCM_TAG_LENGTH) {
    throw new Error(`AES-GCM payload too short (${payload.length}B)`)
  }

  const symKey = await getAesSymKey(keyBytes)
  const cipher = cryptoFramework.createCipher(AES_CIPHER_TRANS)
  const iv = payload.slice(0, GCM_IV_LENGTH)
  const tag = payload.slice(GCM_IV_LENGTH, GCM_IV_LENGTH + GCM_TAG_LENGTH)
  const ciphertext = payload.slice(GCM_IV_LENGTH + GCM_TAG_LENGTH)

  const gcmParams: cryptoFramework.GcmParamsSpec = {
    algName: 'GcmParamsSpec',
    iv: { data: iv },
    aad: { data: new Uint8Array(0) },
    authTag: { data: tag }
  }

  await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, gcmParams)
  const decrypted = await cipher.doFinal({ data: ciphertext })
  const decoder = new util.TextDecoder()
  return decoder.decodeWithStream(decrypted.data)
}

async function encryptSm4GcmText(plaintext: string, iv?: Uint8Array, keyBytes?: Uint8Array): Promise<Uint8Array> {
  const encoder = new util.TextEncoder()
  const actualIv = iv ?? await randomIv()
  return sm4GcmEncrypt(encoder.encodeInto(plaintext), keyBytes ?? activeSm4KeyBytes(), actualIv)
}

function decryptSm4GcmText(payload: Uint8Array, keyBytes?: Uint8Array): string {
  const decrypted = sm4GcmDecrypt(payload, keyBytes ?? activeSm4KeyBytes())
  const decoder = new util.TextDecoder()
  return decoder.decodeWithStream(decrypted)
}

export function currentCryptoMode(): string {
  return activeCryptoMode
}

export function setCryptoMode(mode: string): void {
  if (mode === 'AES' || mode === 'SM4') {
    activeCryptoMode = mode
    return
  }
  throw new Error(`unsupported crypto mode: ${mode}`)
}

function assertCryptoMode(mode: string): void {
  if (mode !== 'AES' && mode !== 'SM4') {
    throw new Error(`unsupported crypto mode: ${mode}`)
  }
}

export async function encryptWithMode(plaintext: string, mode: string): Promise<Uint8Array> {
  assertCryptoMode(mode)
  if (mode === 'SM4') {
    return encryptSm4GcmText(plaintext)
  }
  return encryptAesGcm(plaintext)
}

export async function encryptWithModeForDevice(plaintext: string, mode: string, deviceId: string): Promise<Uint8Array> {
  assertCryptoMode(mode)
  const keys = deviceDynamicKeys.get(deviceId)
  if (!keys) {
    return mode === 'SM4' ? encryptSm4GcmText(plaintext, undefined, SM4_KEY_RAW) :
      encryptAesGcm(plaintext, undefined, AES_KEY_RAW)
  }
  if (mode === 'SM4') {
    return encryptSm4GcmText(plaintext, undefined, keys.sm4Key)
  }
  return encryptAesGcm(plaintext, undefined, keys.aesKey)
}

/**
 * Encrypts outgoing Dayu -> ESP32 commands.
 * Default output is SM4-GCM to match ESP32 CRYPTO_USE_SM4=1.
 */
export async function encrypt(plaintext: string): Promise<Uint8Array> {
  return encryptWithMode(plaintext, activeCryptoMode)
}

/**
 * Decrypts incoming ESP32 sensor packets with the selected algorithm only.
 */
export async function decryptWithMode(payload: Uint8Array): Promise<CryptoDecryptResult> {
  return decryptWithExpectedMode(payload, activeCryptoMode)
}

export async function decryptWithExpectedMode(payload: Uint8Array, mode: string): Promise<CryptoDecryptResult> {
  return decryptWithExpectedModeAndKeySource(payload, mode, 'active')
}

export async function decryptWithExpectedModeForDevice(payload: Uint8Array, mode: string,
  deviceId: string): Promise<CryptoDecryptResult> {
  const keys = deviceDynamicKeys.get(deviceId)
  if (!keys) {
    const staticKey = mode === 'AES' ? AES_KEY_RAW : SM4_KEY_RAW
    const result = await decryptWithProvidedKey(payload, mode, staticKey)
    result.keySource = 'static'
    return result
  }
  const key = mode === 'AES' ? keys.aesKey : keys.sm4Key
  const result = await decryptWithProvidedKey(payload, mode, key)
  result.keySource = 'device-dynamic'
  return result
}

export async function decryptWithStaticExpectedMode(payload: Uint8Array, mode: string): Promise<CryptoDecryptResult> {
  return decryptWithExpectedModeAndKeySource(payload, mode, 'static')
}

export async function decryptWithProvidedKey(payload: Uint8Array, mode: string, keyBytes: Uint8Array): Promise<CryptoDecryptResult> {
  assertCryptoMode(mode)
  if (mode === 'SM4' && keyBytes.length !== 16) {
    throw new Error(`SM4 pending key must be 16 bytes, got ${keyBytes.length}`)
  }
  if (mode === 'AES' && keyBytes.length !== 32) {
    throw new Error(`AES pending key must be 32 bytes, got ${keyBytes.length}`)
  }
  if (payload.length < GCM_IV_LENGTH + GCM_TAG_LENGTH) {
    throw new Error(`CryptoLayer: payload too short (${payload.length}B, min ${GCM_IV_LENGTH + GCM_TAG_LENGTH})`)
  }
  try {
    if (mode === 'SM4') {
      return {
        plaintext: decryptSm4GcmText(payload, keyBytes),
        mode: 'SM4',
        keySource: 'provided'
      }
    }
    return {
      plaintext: await decryptAesGcm(payload, keyBytes),
      mode: 'AES',
      keySource: 'provided'
    }
  } catch (err) {
    throw new Error(`${mode} provided decrypt failed: ${(err as Error).message}`)
  }
}

async function decryptWithExpectedModeAndKeySource(payload: Uint8Array, mode: string, keySource: string): Promise<CryptoDecryptResult> {
  assertCryptoMode(mode)
  if (payload.length < GCM_IV_LENGTH + GCM_TAG_LENGTH) {
    throw new Error(`CryptoLayer: payload too short (${payload.length}B, min ${GCM_IV_LENGTH + GCM_TAG_LENGTH})`)
  }

  try {
    if (mode === 'SM4') {
      return {
        plaintext: decryptSm4GcmText(payload, keySource === 'static' ? SM4_KEY_RAW : undefined),
        mode: 'SM4',
        keySource
      }
    }
    return {
      plaintext: await decryptAesGcm(payload, keySource === 'static' ? AES_KEY_RAW : undefined),
      mode: 'AES',
      keySource
    }
  } catch (err) {
    throw new Error(`${mode} ${keySource} decrypt failed: ${(err as Error).message}`)
  }
}

export async function decrypt(payload: Uint8Array): Promise<string> {
  const result = await decryptWithMode(payload)
  return result.plaintext
}

export function looksEncrypted(payload: Uint8Array): boolean {
  if (payload.length < GCM_IV_LENGTH + GCM_TAG_LENGTH) {
    return false
  }
  const first = payload[0]
  return first !== 0x7B && first !== 0x5B && payload.length >= 28
}

export async function autoDecrypt(raw: Uint8Array): Promise<string> {
  if (looksEncrypted(raw)) {
    return await decrypt(raw)
  }
  const decoder = new util.TextDecoder()
  return decoder.decodeWithStream(raw)
}

export async function selfTest(): Promise<string> {
  const testMsg = '{"test":"hello","val":42}'
  const testIv = new Uint8Array(12).fill(0xAA)

  if (!sm4SelfTest()) {
    return 'FAIL SM4 block/GCM selftest'
  }

  try {
    const sm4Encrypted = await encryptSm4GcmText(testMsg, testIv)
    const sm4Decrypted = decryptSm4GcmText(sm4Encrypted)
    if (sm4Decrypted !== testMsg) {
      return `FAIL SM4 roundtrip: "${testMsg}" vs "${sm4Decrypted}"`
    }
    const sm4TagHex = Array.from(sm4Encrypted.slice(12, 28)).map((b: number) => b.toString(16).padStart(2, '0')).join('')
    const sm4CtHex = Array.from(sm4Encrypted.slice(28)).map((b: number) => b.toString(16).padStart(2, '0')).join('')
    const sm4PayloadHex = Array.from(sm4Encrypted).map((b: number) => b.toString(16).padStart(2, '0')).join('')
    console.info(`[Crypto:selftest] SM4 fixed-IV plain=${testMsg}`)
    console.info(`[Crypto:selftest] SM4 fixed-IV IV=aaaaaaaaaaaaaaaaaaaaaaaa`)
    console.info(`[Crypto:selftest] SM4 fixed-IV TAG=${sm4TagHex} CT=${sm4CtHex}`)
    console.info(`[Crypto:selftest] SM4 fixed-IV PAYLOAD=${sm4PayloadHex}`)
  } catch (err) {
    return `FAIL SM4 roundtrip: ${(err as Error).message}`
  }

  try {
    const aesEncrypted = await encryptAesGcm(testMsg, testIv)
    const aesDecrypted = await decryptAesGcm(aesEncrypted)
    if (aesDecrypted !== testMsg) {
      return `FAIL AES roundtrip: "${testMsg}" vs "${aesDecrypted}"`
    }
  } catch (err) {
    return `FAIL AES roundtrip: ${(err as Error).message}`
  }

  return `PASS ${activeCryptoMode}`
}
