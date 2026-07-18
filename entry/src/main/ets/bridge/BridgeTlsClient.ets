import webSocket from '@ohos.net.webSocket'
import { util } from '@kit.ArkTS'
import { ensureTlsIdentityFiles, TlsIdentityPaths } from '../mqtt/TlsIdentityFiles'

const BRIDGE_TLS_CONNECT_TIMEOUT_MS: number = 5000
const BRIDGE_TLS_SEND_TIMEOUT_MS: number = 5000
const BRIDGE_TLS_ACK_TIMEOUT_MS: number = 6000
const BRIDGE_TLS_PONG_TIMEOUT_MS: number = 5000
const BRIDGE_TLS_HEARTBEAT_INTERVAL_MS: number = 6000
const BRIDGE_TLS_MAX_HEARTBEAT_FAILS: number = 2

export type BridgeTlsJson = Record<string, Object | string | number | boolean>
export type BridgeTlsMessageCallback = (message: BridgeTlsJson) => void
export type BridgeTlsStatusCallback = (connected: boolean, message: string) => void

interface BridgeTlsSendPacket {
  type: string
  reqId?: string
  topic?: string
  payloadBase64?: string
}

interface PendingAck {
  topic: string
  timerId: number
  resolve: () => void
  reject: (err: Error) => void
}

interface PendingPong {
  timerId: number
  resolve: () => void
  reject: (err: Error) => void
}

export class BridgeTlsClient {
  private tls: webSocket.WebSocket | null = null
  private bridgeIp: string = ''
  private bridgePort: number = 3443
  private certificateDirectory: string = ''
  private connected: boolean = false
  private connecting: boolean = false
  private connectPromise: Promise<void> | null = null
  private heartbeatTimer: number = -1
  private heartbeatFailCount: number = 0
  private nextReqSeq: number = 0
  private socketGeneration: number = 0
  private pendingAcks: Map<string, PendingAck> = new Map()
  private pendingPong: PendingPong | null = null
  private onMessage: BridgeTlsMessageCallback | null = null
  private onStatus: BridgeTlsStatusCallback | null = null

  setCallbacks(onMsg: BridgeTlsMessageCallback, onStatus: BridgeTlsStatusCallback): void {
    this.onMessage = onMsg
    this.onStatus = onStatus
  }

  configureCertificateDirectory(directory: string): void {
    this.certificateDirectory = directory
  }

  isConnected(): boolean {
    return this.connected
  }

  isConnecting(): boolean {
    return this.connecting
  }

  matchesBridge(ip: string, port: number): boolean {
    return this.bridgeIp === ip && this.bridgePort === port
  }

  async connect(ip: string, port: number): Promise<void> {
    if (this.connectPromise !== null) {
      await this.connectPromise
      return
    }
    if (this.connected && this.matchesBridge(ip, port)) {
      return
    }

    this.connectPromise = this.doConnect(ip, port)
    try {
      await this.connectPromise
    } finally {
      this.connectPromise = null
    }
  }

  private async doConnect(ip: string, port: number): Promise<void> {
    this.connecting = true
    this.bridgeIp = ip
    this.bridgePort = port
    this.notifyStatus(false, `BridgeTLS ${ip}:${port}...`)

    try {
      await this.closeCurrentSocket('BridgeTLS reconnecting')
      const certificatePaths = await this.ensureCertificateFiles()
      const tlsSocket = webSocket.createWebSocket()
      const generation = this.socketGeneration + 1
      this.socketGeneration = generation
      this.tls = tlsSocket
      this.bindEvents(tlsSocket, generation)
      await this.withTimeout(tlsSocket.connect(`wss://${ip}:${port}`, {
        caPath: certificatePaths.caPath,
        clientCert: {
          certPath: certificatePaths.certPath,
          keyPath: certificatePaths.keyPath
        },
        proxy: 'no-proxy'
      }), BRIDGE_TLS_CONNECT_TIMEOUT_MS, 'BridgeWSS connect')
      await this.pingOnce()
      this.connected = true
      this.notifyStatus(true, `BridgeTLS ${ip}:${port}`)
      const statePacket: BridgeTlsSendPacket = { type: 'state' }
      await this.sendJson(statePacket)
      this.heartbeatFailCount = 0
      this.startHeartbeat()
    } catch (err) {
      const failedTls = this.tls
      this.connected = false
      this.notifyStatus(false, `BridgeTLS: ${(err as Error).message}`)
      this.abandonSocket(`BridgeTLS connect failed: ${(err as Error).message}`)
      if (failedTls) {
        try {
          await failedTls.close()
        } catch (_) { /* ignore */ }
      }
      throw new Error((err as Error).message)
    } finally {
      this.connecting = false
    }
  }

  async disconnect(): Promise<void> {
    await this.closeCurrentSocket('BridgeTLS disconnected')
  }

  async publish(topic: string, payloadBase64: string): Promise<void> {
    if (!this.connected || !this.tls) {
      throw new Error('BridgeTLS not connected')
    }
    const reqId = this.nextRequestId()
    const packet: BridgeTlsSendPacket = {
      type: 'publish',
      reqId,
      topic,
      payloadBase64
    }
    const ackTask = this.waitForAck(reqId, topic)
    try {
      await this.sendJson(packet)
      await ackTask
    } catch (err) {
      this.clearPendingAck(reqId)
      throw new Error((err as Error).message)
    }
  }

  async publishRaw(topic: string, payload: Uint8Array): Promise<void> {
    await this.publish(topic, this.uint8ArrayToBase64(payload))
  }

  async sendJson(data: BridgeTlsSendPacket): Promise<void> {
    if (!this.tls) {
      throw new Error('BridgeTLS socket not ready')
    }
    await this.withTimeout(this.tls.send(JSON.stringify(data)), BRIDGE_TLS_SEND_TIMEOUT_MS, 'BridgeWSS send')
  }

  private bindEvents(sock: webSocket.WebSocket, generation: number): void {
    sock.on('message', (err: Object, data: string | ArrayBuffer) => {
      if (err) {
        this.handleSocketError(err, generation)
        return
      }
      this.handleSocketMessage(data, generation)
    })
    sock.on('close', () => this.handleSocketClose(generation))
    sock.on('error', (err: Object) => this.handleSocketError(err, generation))
  }

  private handleSocketMessage(data: string | ArrayBuffer, generation: number): void {
    if (generation !== this.socketGeneration) {
      return
    }
    let text = ''
    if (typeof data === 'string') {
      text = data
    } else {
      const decoder = new util.TextDecoder()
      text = decoder.decodeWithStream(new Uint8Array(data))
    }
    const line = text.trim()
    if (line.length === 0) {
      return
    }
    try {
      const message = JSON.parse(line) as BridgeTlsJson
      if (this.resolvePongMessage(message) || this.resolveAckMessage(message)) {
        return
      }
      if (this.onMessage) {
        this.onMessage(message)
      }
    } catch (err) {
      console.info(`[BridgeTLS][json-fail] ${(err as Error).message}: ${line.substring(0, 120)}`)
    }
  }

  private handleSocketClose(generation: number): void {
    if (generation !== this.socketGeneration) {
      return
    }
    if (this.connected) {
      this.markDisconnected('BridgeTLS disconnected')
    }
  }

  private handleSocketError(err: Object, generation: number): void {
    if (generation !== this.socketGeneration) {
      return
    }
    console.info(`[BridgeTLS][socket-error] ${JSON.stringify(err)}`)
    this.markDisconnected('BridgeTLS socket error')
  }

  private markDisconnected(message: string): void {
    this.connected = false
    this.heartbeatFailCount = 0
    this.stopHeartbeat()
    this.rejectPendingAcks(message)
    this.rejectPendingPong(message)
    this.notifyStatus(false, message)
  }

  private abandonSocket(message: string): void {
    this.socketGeneration += 1
    this.connected = false
    this.heartbeatFailCount = 0
    this.stopHeartbeat()
    this.rejectPendingAcks(message)
    this.rejectPendingPong(message)
    this.tls = null
  }

  private async closeCurrentSocket(message: string): Promise<void> {
    const oldTls = this.tls
    this.abandonSocket(message)
    if (oldTls) {
      try {
        await oldTls.close()
      } catch (_) { /* ignore */ }
    }
  }

  private async ensureCertificateFiles(): Promise<TlsIdentityPaths> {
    return await ensureTlsIdentityFiles(this.certificateDirectory)
  }

  private nextRequestId(): string {
    this.nextReqSeq = (this.nextReqSeq % 999999) + 1
    return `${Date.now()}-${this.nextReqSeq}`
  }

  private waitForAck(reqId: string, topic: string): Promise<void> {
    return new Promise<void>((resolve: () => void, reject: (err: Error) => void) => {
      const timerId = setTimeout(() => {
        this.pendingAcks.delete(reqId)
        reject(new Error(`BridgeTLS ack timeout ${topic}`))
      }, BRIDGE_TLS_ACK_TIMEOUT_MS)
      this.pendingAcks.set(reqId, {
        topic,
        timerId,
        resolve,
        reject
      })
    })
  }

  private clearPendingAck(reqId: string): void {
    const pending = this.pendingAcks.get(reqId)
    if (!pending) {
      return
    }
    clearTimeout(pending.timerId)
    this.pendingAcks.delete(reqId)
  }

  private resolveAckMessage(message: BridgeTlsJson): boolean {
    const type = message['type'] as string
    const reqId = message['reqId'] as string
    if (type !== 'ack' || typeof reqId !== 'string' || reqId.length === 0) {
      return false
    }
    const pending = this.pendingAcks.get(reqId)
    if (!pending) {
      return false
    }
    this.pendingAcks.delete(reqId)
    clearTimeout(pending.timerId)
    if (message['ok'] === false) {
      const msg = (message['message'] as string) ?? 'BridgeTLS ack failed'
      pending.reject(new Error(msg))
    } else {
      pending.resolve()
    }
    return true
  }

  private waitForPong(): Promise<void> {
    if (this.pendingPong !== null) {
      return Promise.reject(new Error('BridgeTLS pong already pending'))
    }
    return new Promise<void>((resolve: () => void, reject: (err: Error) => void) => {
      const timerId = setTimeout(() => {
        this.pendingPong = null
        reject(new Error('BridgeTLS pong timeout'))
      }, BRIDGE_TLS_PONG_TIMEOUT_MS)
      this.pendingPong = {
        timerId,
        resolve,
        reject
      }
    })
  }

  private resolvePongMessage(message: BridgeTlsJson): boolean {
    const type = message['type'] as string
    if (type !== 'pong') {
      return false
    }
    const pending = this.pendingPong
    if (pending) {
      this.pendingPong = null
      clearTimeout(pending.timerId)
      pending.resolve()
    }
    return true
  }

  private rejectPendingPong(message: string): void {
    const pending = this.pendingPong
    if (!pending) {
      return
    }
    this.pendingPong = null
    clearTimeout(pending.timerId)
    pending.reject(new Error(message))
  }

  private async pingOnce(): Promise<void> {
    const pongTask = this.waitForPong()
    try {
      const pingPacket: BridgeTlsSendPacket = { type: 'ping' }
      await this.sendJson(pingPacket)
      await pongTask
    } catch (err) {
      this.rejectPendingPong((err as Error).message)
      throw new Error((err as Error).message)
    }
  }

  private rejectPendingAcks(message: string): void {
    this.pendingAcks.forEach((pending: PendingAck) => {
      clearTimeout(pending.timerId)
      pending.reject(new Error(message))
    })
    this.pendingAcks.clear()
  }

  private startHeartbeat(): void {
    this.stopHeartbeat()
    this.heartbeatTimer = setInterval(() => {
      if (this.pendingPong !== null) {
        return
      }
      this.pingOnce().then(() => {
        this.heartbeatFailCount = 0
      }).catch((err: Error) => {
        this.heartbeatFailCount += 1
        console.info(`[BridgeTLS][ping-fail] ${err.message}`)
        if (this.heartbeatFailCount >= BRIDGE_TLS_MAX_HEARTBEAT_FAILS) {
          this.markDisconnected(`BridgeTLS ping failed: ${err.message}`)
        }
      })
    }, BRIDGE_TLS_HEARTBEAT_INTERVAL_MS)
  }

  private stopHeartbeat(): void {
    if (this.heartbeatTimer !== -1) {
      clearInterval(this.heartbeatTimer)
      this.heartbeatTimer = -1
    }
  }

  private notifyStatus(connected: boolean, message: string): void {
    if (this.onStatus) {
      this.onStatus(connected, message)
    }
  }

  private withTimeout<T>(task: Promise<T>, timeoutMs: number, label: string): Promise<T> {
    return new Promise<T>((resolve: (value: T) => void, reject: (err: Error) => void) => {
      let settled = false
      const timerId = setTimeout(() => {
        if (settled) {
          return
        }
        settled = true
        reject(new Error(`${label} timeout`))
      }, timeoutMs)
      task.then((value: T) => {
        if (settled) {
          return
        }
        settled = true
        clearTimeout(timerId)
        resolve(value)
      }).catch((err: Error) => {
        if (settled) {
          return
        }
        settled = true
        clearTimeout(timerId)
        reject(err)
      })
    })
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
