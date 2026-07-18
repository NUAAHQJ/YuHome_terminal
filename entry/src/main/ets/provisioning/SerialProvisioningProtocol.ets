export const PROVISION_FRAME_HEAD_0: number = 0xAA
export const PROVISION_FRAME_HEAD_1: number = 0x55
export const PROVISION_FRAME_VERSION: number = 0x01
export const PROVISION_MAX_PAYLOAD_BYTES: number = 2048

export enum ProvisioningFrameType {
  ENTER_CONFIG = 0x10,
  CONFIG_MODE_ACK = 0x11,
  CONFIG_SET = 0x20,
  CONFIG_ACK = 0x21,
  CONFIG_SAVED = 0x31,
  CONFIG_TEST = 0x40,
  CONFIG_TEST_RESULT = 0x41,
  REBOOT = 0x50,
  ERROR = 0x7F
}

export interface ProvisioningFrame {
  version: number
  type: number
  seq: number
  payload: Uint8Array
}

export interface ProvisioningParseResult {
  frames: ProvisioningFrame[]
  remaining: Uint8Array
  errors: string[]
}

export interface ProvisioningConfig {
  ssid: string
  password: string
  brokerUrl: string
  httpBridge: string
  deviceId: string
  crypto: string
  transport: string
}

function concatBytes(left: Uint8Array, right: Uint8Array): Uint8Array {
  const output = new Uint8Array(left.length + right.length)
  output.set(left, 0)
  output.set(right, left.length)
  return output
}

function sliceBytes(input: Uint8Array, start: number, end: number): Uint8Array {
  const safeStart = Math.max(0, Math.min(input.length, start))
  const safeEnd = Math.max(safeStart, Math.min(input.length, end))
  const output = new Uint8Array(safeEnd - safeStart)
  for (let i = safeStart; i < safeEnd; i += 1) {
    output[i - safeStart] = input[i]
  }
  return output
}

function isKnownProvisioningType(type: number): boolean {
  switch (type) {
    case ProvisioningFrameType.ENTER_CONFIG:
    case ProvisioningFrameType.CONFIG_MODE_ACK:
    case ProvisioningFrameType.CONFIG_SET:
    case ProvisioningFrameType.CONFIG_ACK:
    case ProvisioningFrameType.CONFIG_SAVED:
    case ProvisioningFrameType.CONFIG_TEST:
    case ProvisioningFrameType.CONFIG_TEST_RESULT:
    case ProvisioningFrameType.REBOOT:
    case ProvisioningFrameType.ERROR:
      return true
    default:
      return false
  }
}

function findNextPlausibleHeader(buffer: Uint8Array, start: number): number {
  for (let i = start; i + 1 < buffer.length; i += 1) {
    if (buffer[i] !== PROVISION_FRAME_HEAD_0 || buffer[i + 1] !== PROVISION_FRAME_HEAD_1) {
      continue
    }
    if (i + 2 < buffer.length && buffer[i + 2] !== PROVISION_FRAME_VERSION) {
      continue
    }
    if (i + 3 < buffer.length && !isKnownProvisioningType(buffer[i + 3])) {
      continue
    }
    if (i + 6 < buffer.length) {
      const length = (buffer[i + 5] << 8) | buffer[i + 6]
      if (length > PROVISION_MAX_PAYLOAD_BYTES) {
        continue
      }
    }
    return i
  }
  return -1
}

export function crc16Modbus(data: Uint8Array): number {
  let crc = 0xFFFF
  for (let i = 0; i < data.length; i += 1) {
    crc ^= data[i]
    for (let bit = 0; bit < 8; bit += 1) {
      if ((crc & 0x0001) !== 0) {
        crc = (crc >>> 1) ^ 0xA001
      } else {
        crc = crc >>> 1
      }
    }
  }
  return crc & 0xFFFF
}

export function encodeProvisioningFrame(type: number, seq: number, payload: Uint8Array = new Uint8Array(0)): Uint8Array {
  if (payload.length > PROVISION_MAX_PAYLOAD_BYTES) {
    throw new Error(`payload too large: ${payload.length}B`)
  }
  const bodyLength = 5 + payload.length
  const frameWithoutCrc = new Uint8Array(2 + bodyLength)
  frameWithoutCrc[0] = PROVISION_FRAME_HEAD_0
  frameWithoutCrc[1] = PROVISION_FRAME_HEAD_1
  frameWithoutCrc[2] = PROVISION_FRAME_VERSION
  frameWithoutCrc[3] = type & 0xFF
  frameWithoutCrc[4] = seq & 0xFF
  // Length is big-endian. CRC16-MODBUS covers version..payload, excluding AA55,
  // and is appended low byte first.
  frameWithoutCrc[5] = (payload.length >>> 8) & 0xFF
  frameWithoutCrc[6] = payload.length & 0xFF
  frameWithoutCrc.set(payload, 7)

  const crc = crc16Modbus(sliceBytes(frameWithoutCrc, 2, frameWithoutCrc.length))
  const frame = new Uint8Array(frameWithoutCrc.length + 2)
  frame.set(frameWithoutCrc, 0)
  frame[frame.length - 2] = crc & 0xFF
  frame[frame.length - 1] = (crc >>> 8) & 0xFF
  return frame
}

export function parseProvisioningFrames(previous: Uint8Array, incoming: Uint8Array): ProvisioningParseResult {
  let buffer = concatBytes(previous, incoming)
  const frames: ProvisioningFrame[] = []
  const errors: string[] = []
  let offset = 0

  while (offset + 2 <= buffer.length) {
    if (buffer[offset] !== PROVISION_FRAME_HEAD_0 || buffer[offset + 1] !== PROVISION_FRAME_HEAD_1) {
      offset += 1
      continue
    }

    if (offset + 3 > buffer.length) {
      break
    }
    const version = buffer[offset + 2]
    if (version !== PROVISION_FRAME_VERSION) {
      errors.push(`drop header with unsupported version=0x${version.toString(16)}`)
      offset += 1
      continue
    }

    if (offset + 4 > buffer.length) {
      break
    }
    const type = buffer[offset + 3]
    if (!isKnownProvisioningType(type)) {
      errors.push(`drop header with unknown type=0x${type.toString(16)}`)
      offset += 1
      continue
    }

    if (offset + 7 > buffer.length) {
      break
    }
    const length = (buffer[offset + 5] << 8) | buffer[offset + 6]
    if (length > PROVISION_MAX_PAYLOAD_BYTES) {
      errors.push(`drop oversized frame len=${length}`)
      offset += 1
      continue
    }

    const total = 2 + 5 + length + 2
    if (offset + total > buffer.length) {
      const nextHeader = findNextPlausibleHeader(buffer, offset + 1)
      if (nextHeader >= 0) {
        errors.push(`resync incomplete frame type=0x${type.toString(16)} seq=${buffer[offset + 4]} need=${total}B have=${buffer.length - offset}B`)
        offset = nextHeader
        continue
      }
      break
    }

    const frameBytes = sliceBytes(buffer, offset, offset + total)
    const receivedCrc = frameBytes[frameBytes.length - 2] | (frameBytes[frameBytes.length - 1] << 8)
    const actualCrc = crc16Modbus(sliceBytes(frameBytes, 2, frameBytes.length - 2))
    if (receivedCrc !== actualCrc) {
      errors.push(`crc mismatch type=0x${type.toString(16)} seq=${buffer[offset + 4]} expected=0x${actualCrc.toString(16)} got=0x${receivedCrc.toString(16)}`)
      offset += 1
      continue
    }

    frames.push({
      version,
      type,
      seq: buffer[offset + 4],
      payload: sliceBytes(buffer, offset + 7, offset + 7 + length)
    })
    offset += total
  }

  buffer = sliceBytes(buffer, offset, buffer.length)
  return { frames, remaining: buffer, errors }
}

export function provisioningTypeName(type: number): string {
  switch (type) {
    case ProvisioningFrameType.ENTER_CONFIG:
      return 'ENTER_CONFIG'
    case ProvisioningFrameType.CONFIG_MODE_ACK:
      return 'CONFIG_MODE_ACK'
    case ProvisioningFrameType.CONFIG_SET:
      return 'CONFIG_SET'
    case ProvisioningFrameType.CONFIG_ACK:
      return 'CONFIG_ACK'
    case ProvisioningFrameType.CONFIG_SAVED:
      return 'CONFIG_SAVED'
    case ProvisioningFrameType.CONFIG_TEST:
      return 'CONFIG_TEST'
    case ProvisioningFrameType.CONFIG_TEST_RESULT:
      return 'CONFIG_TEST_RESULT'
    case ProvisioningFrameType.REBOOT:
      return 'REBOOT'
    case ProvisioningFrameType.ERROR:
      return 'ERROR'
    default:
      return `UNKNOWN_0x${type.toString(16)}`
  }
}

export function utf8Encode(text: string): Uint8Array {
  const bytes: number[] = []
  for (let i = 0; i < text.length; i += 1) {
    const code = text.charCodeAt(i)
    if (code < 0x80) {
      bytes.push(code)
    } else if (code < 0x800) {
      bytes.push(0xC0 | (code >>> 6))
      bytes.push(0x80 | (code & 0x3F))
    } else if (code >= 0xD800 && code <= 0xDBFF && i + 1 < text.length) {
      const next = text.charCodeAt(i + 1)
      if (next >= 0xDC00 && next <= 0xDFFF) {
        const cp = 0x10000 + ((code - 0xD800) << 10) + (next - 0xDC00)
        bytes.push(0xF0 | (cp >>> 18))
        bytes.push(0x80 | ((cp >>> 12) & 0x3F))
        bytes.push(0x80 | ((cp >>> 6) & 0x3F))
        bytes.push(0x80 | (cp & 0x3F))
        i += 1
      }
    } else {
      bytes.push(0xE0 | (code >>> 12))
      bytes.push(0x80 | ((code >>> 6) & 0x3F))
      bytes.push(0x80 | (code & 0x3F))
    }
  }
  return new Uint8Array(bytes)
}

export function utf8Decode(bytes: Uint8Array): string {
  let output = ''
  let i = 0
  while (i < bytes.length) {
    const b0 = bytes[i]
    if (b0 < 0x80) {
      output += String.fromCharCode(b0)
      i += 1
    } else if ((b0 & 0xE0) === 0xC0 && i + 1 < bytes.length) {
      const code = ((b0 & 0x1F) << 6) | (bytes[i + 1] & 0x3F)
      output += String.fromCharCode(code)
      i += 2
    } else if ((b0 & 0xF0) === 0xE0 && i + 2 < bytes.length) {
      const code = ((b0 & 0x0F) << 12) | ((bytes[i + 1] & 0x3F) << 6) | (bytes[i + 2] & 0x3F)
      output += String.fromCharCode(code)
      i += 3
    } else if ((b0 & 0xF8) === 0xF0 && i + 3 < bytes.length) {
      const cp = ((b0 & 0x07) << 18) | ((bytes[i + 1] & 0x3F) << 12) | ((bytes[i + 2] & 0x3F) << 6) | (bytes[i + 3] & 0x3F)
      const offset = cp - 0x10000
      output += String.fromCharCode(0xD800 + (offset >>> 10), 0xDC00 + (offset & 0x3FF))
      i += 4
    } else {
      output += '?'
      i += 1
    }
  }
  return output
}

export function buildProvisioningConfigPayload(config: ProvisioningConfig): Uint8Array {
  return utf8Encode(JSON.stringify({
    ssid: config.ssid,
    password: config.password,
    brokerUrl: config.brokerUrl,
    httpBridge: config.httpBridge,
    deviceId: config.deviceId,
    crypto: config.crypto,
    transport: config.transport
  }))
}

export function toHex(bytes: Uint8Array, maxBytes: number = 96): string {
  const end = Math.min(bytes.length, maxBytes)
  const parts: string[] = []
  for (let i = 0; i < end; i += 1) {
    parts.push(bytes[i].toString(16).padStart(2, '0').toUpperCase())
  }
  if (bytes.length > maxBytes) {
    parts.push('...')
  }
  return parts.join(' ')
}
