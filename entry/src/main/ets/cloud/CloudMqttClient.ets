import webSocket from '@ohos.net.webSocket'
import { util } from '@kit.ArkTS'
import { ensureTlsIdentityFiles } from '../mqtt/TlsIdentityFiles'

const CONNECT_TIMEOUT_MS: number = 8000
const REQUEST_TIMEOUT_MS: number = 12000
const KEEPALIVE_MS: number = 30000
const REQUEST_TOPIC: string = 'cloud/dayu/dayu_gateway_001/request'
const RESPONSE_TOPIC: string = 'cloud/dayu/dayu_gateway_001/response'

interface PendingRequest {
  timerId: number
  resolve: (body: string) => void
  reject: (err: Error) => void
}

interface MqttRequestEnvelope {
  type: string
  reqId: string
  path?: string
  hello?: Object
  packet?: Object
}

function concatBytes(parts: Uint8Array[]): Uint8Array {
  let length = 0
  for (let i = 0; i < parts.length; i++) length += parts[i].length
  const out = new Uint8Array(length)
  let offset = 0
  for (let i = 0; i < parts.length; i++) {
    out.set(parts[i], offset)
    offset += parts[i].length
  }
  return out
}

function encodeUtf8(text: string): Uint8Array {
  return new util.TextEncoder().encodeInto(text)
}

function decodeUtf8(bytes: Uint8Array): string {
  return new util.TextDecoder().decodeWithStream(bytes)
}

function encodeMqttString(text: string): Uint8Array {
  const data = encodeUtf8(text)
  const out = new Uint8Array(data.length + 2)
  out[0] = (data.length >>> 8) & 0xff
  out[1] = data.length & 0xff
  out.set(data, 2)
  return out
}

function encodeRemainingLength(value: number): Uint8Array {
  const bytes: number[] = []
  let remaining = value
  do {
    let digit = remaining % 128
    remaining = Math.floor(remaining / 128)
    if (remaining > 0) digit |= 0x80
    bytes.push(digit)
  } while (remaining > 0)
  return new Uint8Array(bytes)
}

function toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  const buffer = new ArrayBuffer(bytes.length)
  new Uint8Array(buffer).set(bytes)
  return buffer
}

export class CloudMqttClient {
  private url: string
  private clientId: string
  private certificateDirectory: string = ''
  private socket: webSocket.WebSocket | null = null
  private connected: boolean = false
  private connectTask: Promise<void> | null = null
  private recvBuffer: Uint8Array = new Uint8Array(0)
  private packetId: number = 1
  private requestSeq: number = 0
  private generation: number = 0
  private heartbeatTimer: number = -1
  private connackResolve: (() => void) | null = null
  private connackReject: ((err: Error) => void) | null = null
  private subackResolve: (() => void) | null = null
  private subackReject: ((err: Error) => void) | null = null
  private pendingRequests: Map<string, PendingRequest> = new Map()

  constructor(url: string, clientId: string = 'dayu_gateway_001') {
    this.url = url
    this.clientId = clientId
  }

  configureCertificateDirectory(directory: string): void {
    this.certificateDirectory = directory
  }

  async request(path: string, body: string): Promise<string> {
    await this.connect()
    const reqId = `${Date.now()}-${++this.requestSeq}`
    const responseTask = this.waitForResponse(reqId)
    const parsed = JSON.parse(body) as Object
    const envelope: MqttRequestEnvelope = path === '/api/secure/hello' ? {
      type: 'hello', reqId, hello: parsed
    } : {
      type: 'secure', reqId, path, packet: parsed
    }
    try {
      await this.publish(REQUEST_TOPIC, JSON.stringify(envelope))
      return await responseTask
    } catch (err) {
      this.rejectRequest(reqId, (err as Error).message)
      throw new Error((err as Error).message)
    }
  }

  async disconnect(): Promise<void> {
    const old = this.socket
    this.abandon('Cloud MQTT disconnected')
    if (old) {
      try { await old.close() } catch (_) { /* ignore */ }
    }
  }

  private async connect(): Promise<void> {
    if (this.connected && this.socket) return
    if (this.connectTask) {
      await this.connectTask
      return
    }
    this.connectTask = this.connectOnce()
    try {
      await this.connectTask
    } finally {
      this.connectTask = null
    }
  }

  private async connectOnce(): Promise<void> {
    if (this.certificateDirectory.length === 0) {
      throw new Error('Cloud MQTT mutual TLS identity is not configured')
    }
    await this.disconnect()
    const paths = await ensureTlsIdentityFiles(this.certificateDirectory)
    const generation = this.generation + 1
    this.generation = generation
    const socket = webSocket.createWebSocket()
    this.socket = socket
    this.bindEvents(socket, generation)
    await this.withTimeout(socket.connect(this.url, {
      caPath: paths.caPath,
      clientCert: { certPath: paths.certPath, keyPath: paths.keyPath },
      protocol: 'mqtt',
      proxy: 'no-proxy'
    }), CONNECT_TIMEOUT_MS, 'MQTT WebSocket connect')
    const connackTask = this.waitForConnack()
    await this.sendPacket(this.buildConnectPacket())
    await this.withTimeout(connackTask, CONNECT_TIMEOUT_MS, 'MQTT CONNACK')
    const subackTask = this.waitForSuback()
    await this.sendPacket(this.buildSubscribePacket(RESPONSE_TOPIC))
    await this.withTimeout(subackTask, CONNECT_TIMEOUT_MS, 'MQTT SUBACK')
    this.connected = true
    this.startHeartbeat()
    console.info(`[CloudMQTT] connected ${this.url}`)
  }

  private bindEvents(socket: webSocket.WebSocket, generation: number): void {
    socket.on('message', (err: Object, data: string | ArrayBuffer) => {
      if (generation !== this.generation) return
      if (err) {
        this.handleFailure(`Cloud MQTT message error: ${JSON.stringify(err)}`)
        return
      }
      const chunk = typeof data === 'string' ? encodeUtf8(data) : new Uint8Array(data)
      const combined = new Uint8Array(this.recvBuffer.length + chunk.length)
      combined.set(this.recvBuffer, 0)
      combined.set(chunk, this.recvBuffer.length)
      this.recvBuffer = combined
      this.parsePackets()
    })
    socket.on('close', () => {
      if (generation === this.generation) this.handleFailure('Cloud MQTT closed')
    })
    socket.on('error', (err: Object) => {
      if (generation === this.generation) this.handleFailure(`Cloud MQTT error: ${JSON.stringify(err)}`)
    })
  }

  private parsePackets(): void {
    while (this.recvBuffer.length >= 2) {
      let multiplier = 1
      let remaining = 0
      let offset = 1
      let digit = 0
      do {
        if (offset >= this.recvBuffer.length) return
        digit = this.recvBuffer[offset++]
        remaining += (digit & 0x7f) * multiplier
        multiplier *= 128
      } while ((digit & 0x80) !== 0)
      const packetLength = offset + remaining
      if (this.recvBuffer.length < packetLength) return
      const packet = this.recvBuffer.slice(0, packetLength)
      this.recvBuffer = this.recvBuffer.slice(packetLength)
      this.handlePacket(packet, offset)
    }
  }

  private handlePacket(packet: Uint8Array, bodyOffset: number): void {
    const type = packet[0] >>> 4
    if (type === 2) {
      if (packet.length > bodyOffset + 1 && packet[bodyOffset + 1] === 0 && this.connackResolve) {
        const resolve = this.connackResolve
        this.connackResolve = null
        this.connackReject = null
        resolve()
      }
      return
    }
    if (type === 9) {
      if (this.subackResolve) {
        const resolve = this.subackResolve
        this.subackResolve = null
        this.subackReject = null
        resolve()
      }
      return
    }
    if (type !== 3 || packet.length < bodyOffset + 2) return
    const topicLength = (packet[bodyOffset] << 8) | packet[bodyOffset + 1]
    const topicStart = bodyOffset + 2
    const topicEnd = topicStart + topicLength
    if (topicEnd > packet.length) return
    const topic = decodeUtf8(packet.slice(topicStart, topicEnd))
    let payloadOffset = topicEnd
    const qos = (packet[0] >>> 1) & 0x03
    if (qos > 0) payloadOffset += 2
    if (topic !== RESPONSE_TOPIC || payloadOffset > packet.length) return
    try {
      const message = JSON.parse(decodeUtf8(packet.slice(payloadOffset))) as Record<string, Object | string>
      const reqId = message['reqId'] as string
      const body = message['body'] as Object
      const pending = this.pendingRequests.get(reqId)
      if (!pending) return
      clearTimeout(pending.timerId)
      this.pendingRequests.delete(reqId)
      pending.resolve(JSON.stringify(body))
    } catch (err) {
      console.info(`[CloudMQTT] response parse failed: ${(err as Error).message}`)
    }
  }

  private async publish(topic: string, payload: string): Promise<void> {
    await this.sendPacket(this.buildPublishPacket(topic, payload))
  }

  private async sendPacket(packet: Uint8Array): Promise<void> {
    if (!this.socket) throw new Error('Cloud MQTT socket not ready')
    await this.socket.send(toArrayBuffer(packet))
  }

  private buildConnectPacket(): Uint8Array {
    const variableHeader = new Uint8Array([0x00, 0x04, 0x4d, 0x51, 0x54, 0x54, 0x04, 0x02, 0x00, 0x3c])
    const payload = encodeMqttString(this.clientId)
    return concatBytes([new Uint8Array([0x10]), encodeRemainingLength(variableHeader.length + payload.length), variableHeader, payload])
  }

  private buildSubscribePacket(topic: string): Uint8Array {
    this.packetId = (this.packetId % 65535) + 1
    const variable = new Uint8Array([(this.packetId >>> 8) & 0xff, this.packetId & 0xff])
    const payload = concatBytes([encodeMqttString(topic), new Uint8Array([0x00])])
    return concatBytes([new Uint8Array([0x82]), encodeRemainingLength(variable.length + payload.length), variable, payload])
  }

  private buildPublishPacket(topic: string, payload: string): Uint8Array {
    const topicBytes = encodeMqttString(topic)
    const payloadBytes = encodeUtf8(payload)
    return concatBytes([new Uint8Array([0x30]), encodeRemainingLength(topicBytes.length + payloadBytes.length), topicBytes, payloadBytes])
  }

  private waitForConnack(): Promise<void> {
    return new Promise<void>((resolve: () => void, reject: (err: Error) => void) => {
      this.connackResolve = resolve
      this.connackReject = reject
    })
  }

  private waitForSuback(): Promise<void> {
    return new Promise<void>((resolve: () => void, reject: (err: Error) => void) => {
      this.subackResolve = resolve
      this.subackReject = reject
    })
  }

  private waitForResponse(reqId: string): Promise<string> {
    return new Promise<string>((resolve: (body: string) => void, reject: (err: Error) => void) => {
      const timerId = setTimeout(() => {
        this.pendingRequests.delete(reqId)
        reject(new Error(`Cloud MQTT request timeout ${reqId}`))
      }, REQUEST_TIMEOUT_MS)
      this.pendingRequests.set(reqId, { timerId, resolve, reject })
    })
  }

  private rejectRequest(reqId: string, message: string): void {
    const pending = this.pendingRequests.get(reqId)
    if (!pending) return
    clearTimeout(pending.timerId)
    this.pendingRequests.delete(reqId)
    pending.reject(new Error(message))
  }

  private handleFailure(message: string): void {
    this.abandon(message)
    console.info(`[CloudMQTT] ${message}`)
  }

  private abandon(message: string): void {
    this.generation += 1
    this.connected = false
    this.socket = null
    this.recvBuffer = new Uint8Array(0)
    this.stopHeartbeat()
    if (this.connackReject) this.connackReject(new Error(message))
    if (this.subackReject) this.subackReject(new Error(message))
    this.connackResolve = null
    this.connackReject = null
    this.subackResolve = null
    this.subackReject = null
    this.pendingRequests.forEach((pending: PendingRequest) => {
      clearTimeout(pending.timerId)
      pending.reject(new Error(message))
    })
    this.pendingRequests.clear()
  }

  private startHeartbeat(): void {
    this.stopHeartbeat()
    this.heartbeatTimer = setInterval(() => {
      this.sendPacket(new Uint8Array([0xc0, 0x00])).catch((err: Error) => this.handleFailure(err.message))
    }, KEEPALIVE_MS)
  }

  private stopHeartbeat(): void {
    if (this.heartbeatTimer !== -1) {
      clearInterval(this.heartbeatTimer)
      this.heartbeatTimer = -1
    }
  }

  private withTimeout<T>(task: Promise<T>, timeoutMs: number, label: string): Promise<T> {
    return new Promise<T>((resolve: (value: T) => void, reject: (err: Error) => void) => {
      let settled = false
      const timerId = setTimeout(() => {
        if (settled) return
        settled = true
        reject(new Error(`${label} timeout`))
      }, timeoutMs)
      task.then((value: T) => {
        if (settled) return
        settled = true
        clearTimeout(timerId)
        resolve(value)
      }).catch((err: Error) => {
        if (settled) return
        settled = true
        clearTimeout(timerId)
        reject(err)
      })
    })
  }
}
