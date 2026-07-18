const SM4_SBOX: number[] = [
  0xd6, 0x90, 0xe9, 0xfe, 0xcc, 0xe1, 0x3d, 0xb7, 0x16, 0xb6, 0x14, 0xc2, 0x28, 0xfb, 0x2c, 0x05,
  0x2b, 0x67, 0x9a, 0x76, 0x2a, 0xbe, 0x04, 0xc3, 0xaa, 0x44, 0x13, 0x26, 0x49, 0x86, 0x06, 0x99,
  0x9c, 0x42, 0x50, 0xf4, 0x91, 0xef, 0x98, 0x7a, 0x33, 0x54, 0x0b, 0x43, 0xed, 0xcf, 0xac, 0x62,
  0xe4, 0xb3, 0x1c, 0xa9, 0xc9, 0x08, 0xe8, 0x95, 0x80, 0xdf, 0x94, 0xfa, 0x75, 0x8f, 0x3f, 0xa6,
  0x47, 0x07, 0xa7, 0xfc, 0xf3, 0x73, 0x17, 0xba, 0x83, 0x59, 0x3c, 0x19, 0xe6, 0x85, 0x4f, 0xa8,
  0x68, 0x6b, 0x81, 0xb2, 0x71, 0x64, 0xda, 0x8b, 0xf8, 0xeb, 0x0f, 0x4b, 0x70, 0x56, 0x9d, 0x35,
  0x1e, 0x24, 0x0e, 0x5e, 0x63, 0x58, 0xd1, 0xa2, 0x25, 0x22, 0x7c, 0x3b, 0x01, 0x21, 0x78, 0x87,
  0xd4, 0x00, 0x46, 0x57, 0x9f, 0xd3, 0x27, 0x52, 0x4c, 0x36, 0x02, 0xe7, 0xa0, 0xc4, 0xc8, 0x9e,
  0xea, 0xbf, 0x8a, 0xd2, 0x40, 0xc7, 0x38, 0xb5, 0xa3, 0xf7, 0xf2, 0xce, 0xf9, 0x61, 0x15, 0xa1,
  0xe0, 0xae, 0x5d, 0xa4, 0x9b, 0x34, 0x1a, 0x55, 0xad, 0x93, 0x32, 0x30, 0xf5, 0x8c, 0xb1, 0xe3,
  0x1d, 0xf6, 0xe2, 0x2e, 0x82, 0x66, 0xca, 0x60, 0xc0, 0x29, 0x23, 0xab, 0x0d, 0x53, 0x4e, 0x6f,
  0xd5, 0xdb, 0x37, 0x45, 0xde, 0xfd, 0x8e, 0x2f, 0x03, 0xff, 0x6a, 0x72, 0x6d, 0x6c, 0x5b, 0x51,
  0x8d, 0x1b, 0xaf, 0x92, 0xbb, 0xdd, 0xbc, 0x7f, 0x11, 0xd9, 0x5c, 0x41, 0x1f, 0x10, 0x5a, 0xd8,
  0x0a, 0xc1, 0x31, 0x88, 0xa5, 0xcd, 0x7b, 0xbd, 0x2d, 0x74, 0xd0, 0x12, 0xb8, 0xe5, 0xb4, 0xb0,
  0x89, 0x69, 0x97, 0x4a, 0x0c, 0x96, 0x77, 0x7e, 0x65, 0xb9, 0xf1, 0x09, 0xc5, 0x6e, 0xc6, 0x84,
  0x18, 0xf0, 0x7d, 0xec, 0x3a, 0xdc, 0x4d, 0x20, 0x79, 0xee, 0x5f, 0x3e, 0xd7, 0xcb, 0x39, 0x48
]

const SM4_FK: number[] = [0xa3b1bac6, 0x56aa3350, 0x677d9197, 0xb27022dc]
const SM4_CK: number[] = [
  0x00070e15, 0x1c232a31, 0x383f464d, 0x545b6269, 0x70777e85, 0x8c939aa1, 0xa8afb6bd, 0xc4cbd2d9,
  0xe0e7eef5, 0xfc030a11, 0x181f262d, 0x343b4249, 0x50575e65, 0x6c737a81, 0x888f969d, 0xa4abb2b9,
  0xc0c7ced5, 0xdce3eaf1, 0xf8ff060d, 0x141b2229, 0x30373e45, 0x4c535a61, 0x686f767d, 0x848b9299,
  0xa0a7aeb5, 0xbcc3cad1, 0xd8dfe6ed, 0xf4fb0209, 0x10171e25, 0x2c333a41, 0x484f565d, 0x646b7279
]

const GCM_IV_LENGTH = 12
const GCM_TAG_LENGTH = 16
const BLOCK_LENGTH = 16

function rotl(value: number, bits: number): number {
  return ((value << bits) | (value >>> (32 - bits))) >>> 0
}

function readU32BE(input: Uint8Array, offset: number): number {
  return (((input[offset] << 24) >>> 0) | (input[offset + 1] << 16) | (input[offset + 2] << 8) | input[offset + 3]) >>> 0
}

function writeU32BE(value: number, output: Uint8Array, offset: number): void {
  output[offset] = (value >>> 24) & 0xff
  output[offset + 1] = (value >>> 16) & 0xff
  output[offset + 2] = (value >>> 8) & 0xff
  output[offset + 3] = value & 0xff
}

function tau(value: number): number {
  return ((SM4_SBOX[(value >>> 24) & 0xff] << 24) |
    (SM4_SBOX[(value >>> 16) & 0xff] << 16) |
    (SM4_SBOX[(value >>> 8) & 0xff] << 8) |
    SM4_SBOX[value & 0xff]) >>> 0
}

function tTransform(value: number): number {
  const b = tau(value)
  return (b ^ rotl(b, 2) ^ rotl(b, 10) ^ rotl(b, 18) ^ rotl(b, 24)) >>> 0
}

function tKeyTransform(value: number): number {
  const b = tau(value)
  return (b ^ rotl(b, 13) ^ rotl(b, 23)) >>> 0
}

function expandKey(key: Uint8Array): number[] {
  if (key.length !== 16) {
    throw new Error(`SM4 key must be 16 bytes, got ${key.length}`)
  }
  const k = new Array<number>(36)
  const rk = new Array<number>(32)
  for (let i = 0; i < 4; i++) {
    k[i] = (readU32BE(key, i * 4) ^ SM4_FK[i]) >>> 0
  }
  for (let i = 0; i < 32; i++) {
    k[i + 4] = (k[i] ^ tKeyTransform((k[i + 1] ^ k[i + 2] ^ k[i + 3] ^ SM4_CK[i]) >>> 0)) >>> 0
    rk[i] = k[i + 4]
  }
  return rk
}

function sm4EncryptBlockWithRoundKeys(block: Uint8Array, roundKeys: number[]): Uint8Array {
  const x = new Array<number>(36)
  for (let i = 0; i < 4; i++) {
    x[i] = readU32BE(block, i * 4)
  }
  for (let i = 0; i < 32; i++) {
    x[i + 4] = (x[i] ^ tTransform((x[i + 1] ^ x[i + 2] ^ x[i + 3] ^ roundKeys[i]) >>> 0)) >>> 0
  }
  const out = new Uint8Array(BLOCK_LENGTH)
  writeU32BE(x[35], out, 0)
  writeU32BE(x[34], out, 4)
  writeU32BE(x[33], out, 8)
  writeU32BE(x[32], out, 12)
  return out
}

function xorBlock(left: Uint8Array, right: Uint8Array): Uint8Array {
  const out = new Uint8Array(BLOCK_LENGTH)
  for (let i = 0; i < BLOCK_LENGTH; i++) {
    out[i] = left[i] ^ right[i]
  }
  return out
}

function getBit(input: Uint8Array, bitIndex: number): number {
  return (input[Math.floor(bitIndex / 8)] >>> (7 - (bitIndex % 8))) & 1
}

function shiftRightOne(input: Uint8Array): Uint8Array {
  const out = new Uint8Array(BLOCK_LENGTH)
  let carry = 0
  for (let i = 0; i < BLOCK_LENGTH; i++) {
    const value = input[i]
    out[i] = ((value >>> 1) | carry) & 0xff
    carry = (value & 1) === 1 ? 0x80 : 0
  }
  return out
}

function galoisMultiply(x: Uint8Array, y: Uint8Array): Uint8Array {
  let z = new Uint8Array(BLOCK_LENGTH)
  let v = y.slice()
  for (let i = 0; i < 128; i++) {
    if (getBit(x, i) === 1) {
      z = xorBlock(z, v)
    }
    const lsbSet = (v[BLOCK_LENGTH - 1] & 1) === 1
    v = shiftRightOne(v)
    if (lsbSet) {
      v[0] ^= 0xe1
    }
  }
  return z
}

function ghashBlock(y: Uint8Array, h: Uint8Array, block: Uint8Array): Uint8Array {
  return galoisMultiply(xorBlock(y, block), h)
}

function writeU64BE(value: number, output: Uint8Array, offset: number): void {
  const high = Math.floor(value / 0x100000000)
  const low = value >>> 0
  writeU32BE(high, output, offset)
  writeU32BE(low, output, offset + 4)
}

function ghash(h: Uint8Array, ciphertext: Uint8Array): Uint8Array {
  let y = new Uint8Array(BLOCK_LENGTH)
  for (let offset = 0; offset < ciphertext.length; offset += BLOCK_LENGTH) {
    const block = new Uint8Array(BLOCK_LENGTH)
    block.set(ciphertext.slice(offset, Math.min(offset + BLOCK_LENGTH, ciphertext.length)))
    y = ghashBlock(y, h, block)
  }
  const lengthBlock = new Uint8Array(BLOCK_LENGTH)
  writeU64BE(0, lengthBlock, 0)
  writeU64BE(ciphertext.length * 8, lengthBlock, 8)
  return ghashBlock(y, h, lengthBlock)
}

function incrementCounter(counter: Uint8Array): void {
  for (let i = 15; i >= 12; i--) {
    counter[i] = (counter[i] + 1) & 0xff
    if (counter[i] !== 0) {
      return
    }
  }
}

function cryptCtr(input: Uint8Array, roundKeys: number[], j0: Uint8Array): Uint8Array {
  const output = new Uint8Array(input.length)
  const counter = j0.slice()
  for (let offset = 0; offset < input.length; offset += BLOCK_LENGTH) {
    incrementCounter(counter)
    const stream = sm4EncryptBlockWithRoundKeys(counter, roundKeys)
    const blockLength = Math.min(BLOCK_LENGTH, input.length - offset)
    for (let i = 0; i < blockLength; i++) {
      output[offset + i] = input[offset + i] ^ stream[i]
    }
  }
  return output
}

function buildJ0(iv: Uint8Array): Uint8Array {
  if (iv.length !== GCM_IV_LENGTH) {
    throw new Error(`SM4-GCM IV must be 12 bytes, got ${iv.length}`)
  }
  const j0 = new Uint8Array(BLOCK_LENGTH)
  j0.set(iv, 0)
  j0[15] = 1
  return j0
}

function constantTimeEqual(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) {
    return false
  }
  let diff = 0
  for (let i = 0; i < left.length; i++) {
    diff |= left[i] ^ right[i]
  }
  return diff === 0
}

export function sm4EncryptBlock(block: Uint8Array, key: Uint8Array): Uint8Array {
  if (block.length !== BLOCK_LENGTH) {
    throw new Error(`SM4 block must be 16 bytes, got ${block.length}`)
  }
  return sm4EncryptBlockWithRoundKeys(block, expandKey(key))
}

export function sm4GcmEncrypt(plaintext: Uint8Array, key: Uint8Array, iv: Uint8Array): Uint8Array {
  const roundKeys = expandKey(key)
  const zero = new Uint8Array(BLOCK_LENGTH)
  const h = sm4EncryptBlockWithRoundKeys(zero, roundKeys)
  const j0 = buildJ0(iv)
  const ciphertext = cryptCtr(plaintext, roundKeys, j0)
  const s = ghash(h, ciphertext)
  const eJ0 = sm4EncryptBlockWithRoundKeys(j0, roundKeys)
  const tag = xorBlock(eJ0, s)

  const output = new Uint8Array(GCM_IV_LENGTH + GCM_TAG_LENGTH + ciphertext.length)
  output.set(iv, 0)
  output.set(tag, GCM_IV_LENGTH)
  output.set(ciphertext, GCM_IV_LENGTH + GCM_TAG_LENGTH)
  return output
}

export function sm4GcmDecrypt(payload: Uint8Array, key: Uint8Array): Uint8Array {
  if (payload.length < GCM_IV_LENGTH + GCM_TAG_LENGTH) {
    throw new Error(`SM4-GCM payload too short: ${payload.length}B`)
  }

  const iv = payload.slice(0, GCM_IV_LENGTH)
  const tag = payload.slice(GCM_IV_LENGTH, GCM_IV_LENGTH + GCM_TAG_LENGTH)
  const ciphertext = payload.slice(GCM_IV_LENGTH + GCM_TAG_LENGTH)
  const roundKeys = expandKey(key)
  const zero = new Uint8Array(BLOCK_LENGTH)
  const h = sm4EncryptBlockWithRoundKeys(zero, roundKeys)
  const j0 = buildJ0(iv)
  const s = ghash(h, ciphertext)
  const eJ0 = sm4EncryptBlockWithRoundKeys(j0, roundKeys)
  const expectedTag = xorBlock(eJ0, s)

  if (!constantTimeEqual(tag, expectedTag)) {
    throw new Error('SM4-GCM auth tag mismatch')
  }
  return cryptCtr(ciphertext, roundKeys, j0)
}

export function sm4SelfTest(): boolean {
  const key = new Uint8Array([
    0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
    0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10
  ])
  const plain = key.slice()
  const encrypted = sm4EncryptBlock(plain, key)
  const expected = '681edf34d206965e86b3e94f536e4246'
  const actual = Array.from(encrypted).map((b: number) => b.toString(16).padStart(2, '0')).join('')
  if (actual !== expected) {
    return false
  }
  const iv = new Uint8Array(12).fill(0xaa)
  const payload = sm4GcmEncrypt(plain, key, iv)
  const decrypted = sm4GcmDecrypt(payload, key)
  return constantTimeEqual(plain, decrypted)
}
