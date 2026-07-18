import socket from '@ohos.net.socket'
import { util } from '@kit.ArkTS'
import { DAYU_CLIENT_CERT, DAYU_CLIENT_KEY } from './TlsClientIdentity'

const MQTT_PROTO_LEVEL = 4
const MQTT_PROTO_NAME = 'MQTT'
const MQTT_KEEP_ALIVE_SECONDS: number = 60
const MQTT_PING_INTERVAL_MS: number = 15000
const MQTT_RECONNECT_DELAY_MS: number = 5000
const MQTT_PUBACK_TIMEOUT_MS: number = 6000
const MQTT_SOCKET_CONNECT_TIMEOUT_MS: number = 5000
const MQTT_SEND_TIMEOUT_MS: number = 5000
const MQTT_CONNACK_TIMEOUT_MS: number = 6000

// Public CA certificate that signed certs/server.crt. Private keys stay only on the broker.
export const BROKER_CA_CERT = `-----BEGIN CERTIFICATE-----
MIID6TCCAtGgAwIBAgIUBYWSCdPlmmPfr7XmfOH0eET797MwDQYJKoZIhvcNAQEL
BQAwfDELMAkGA1UEBhMCQ04xDjAMBgNVBAgMBUxvY2FsMQ4wDAYDVQQHDAVMb2Nh
bDEWMBQGA1UECgwNTXkgU21hcnQgSG9tZTEWMBQGA1UECwwNTG9jYWwgTVFUVCBD
QTEdMBsGA1UEAwwUTXlTbWFydEhvbWUgTG9jYWwgQ0EwHhcNMjYwNjI4MDQzMDQ1
WhcNMzYwNjI1MDQzMDQ1WjB8MQswCQYDVQQGEwJDTjEOMAwGA1UECAwFTG9jYWwx
DjAMBgNVBAcMBUxvY2FsMRYwFAYDVQQKDA1NeSBTbWFydCBIb21lMRYwFAYDVQQL
DA1Mb2NhbCBNUVRUIENBMR0wGwYDVQQDDBRNeVNtYXJ0SG9tZSBMb2NhbCBDQTCC
ASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBALkrYrYaxMr1VSu3InLBVNxQ
mpdSClL1vWziCiofTrt3iLFx+rXHscBi9FgwQxxOZ4j8paHsPW4bM8cAHnAdajHp
BMNxAwTQ8O3BbOgg0Oabo3LoQW2Nb0Nl36Yz6ZlkkhlTbmedUWks+d/MJ6zw/KaC
El1jSX6Icjqow0F6cIvEd1o4ubIC/1iykKrTQr/q+wb+fjT5FRTIktA9YIO0kvxe
QQZ+cs3Kawo6cb5owoxYyVtDyzZWCu9ZotoogZbdF6RIOwnbJMQY9MvpJ9qIjXjM
puCNrURm+GHcK/C92qWpb3Kvpaj4kMLdnr1DvrMI24uZxG7ie+W9oL8seyLj11UC
AwEAAaNjMGEwDwYDVR0TAQH/BAUwAwEB/zAOBgNVHQ8BAf8EBAMCAQYwHQYDVR0O
BBYEFHnBXb67+wWRwhw62+4UDPnHKY/sMB8GA1UdIwQYMBaAFHnBXb67+wWRwhw6
2+4UDPnHKY/sMA0GCSqGSIb3DQEBCwUAA4IBAQCPxRRdUn9op87iZ7Qdknj881Lf
KOFpNjRkWkhlliUA3addkdHvzaKIRltIGPT/KR5S/g6jlLcUjyZvhiXXCzpi9+gl
moWjjwUpDWApLy4WOkBs1gzcevZVzJls4fJ/fuiCZT1VeWk4DgzoGE5KnkDmwNwO
d0yTcn6H3VmmmgSDqPm8XihQwpV2pZI1v4xSnWABR0ApG5435abrkRm7J2zDRiy+
PRSvPo3NeG/+lwgfWQbNALacROlq8ykqHX9jdAgXrco3CSXand5nNDM0ExrLEuhz
m2Ar+heto6sMG5FPgmhGm5kyspxxyNLSxCuHOSQDx80i8czfaVZEk4DfqFDv
-----END CERTIFICATE-----`

export type MqttMessageCallback = (topic: string, payload: Uint8Array) => void
export type MqttStatusCallback = (connected: boolean, message: string) => void

interface MqttSubscription {
  topic: string
  qos: number
}

interface MqttPendingPuback {
  topic: string
  timerId: number
  resolve: () => void
  reject: (err: Error) => void
}

interface MqttPublishPacket {
  packet: Uint8Array
  packetId: number
}

export class MqttClient {
  private tcp: socket.TCPSocket | null = null
  private tls: socket.TLSSocket | null = null
  private brokerIp: string = ''
  private brokerPort: number = 1883
  private useTls: boolean = false
  private clientId: string
  private keepAlive: number = MQTT_KEEP_ALIVE_SECONDS
  private connected: boolean = false
  private packetId: number = 1
  private recvBuf: Uint8Array = new Uint8Array(0)
  private pingTimer: number = -1
  private reconnectTimer: number = -1
  private onMessage: MqttMessageCallback | null = null
  private onStatus: MqttStatusCallback | null = null
  private topics: MqttSubscription[] = []
  private connectResolve: ((value: void) => void) | null = null
  private connectReject: ((reason: Error) => void) | null = null
  private connectTask: Promise<void> | null = null
  private pendingPubacks: Map<number, MqttPendingPuback> = new Map()
  private socketGeneration: number = 0

  constructor(clientId?: string) {
    this.clientId = clientId ?? `dayu_${Date.now()}`
  }

  setBroker(ip: string, port: number, useTls: boolean = false): void {
    this.brokerIp = ip
    this.brokerPort = port
    this.useTls = useTls
  }

  setCallbacks(onMsg: MqttMessageCallback, onStatus: MqttStatusCallback): void {
    this.onMessage = onMsg
    this.onStatus = onStatus
  }

  isConnected(): boolean {
    return this.connected
  }

  matchesBroker(ip: string, port: number, useTls: boolean): boolean {
    return this.brokerIp === ip && this.brokerPort === port && this.useTls === useTls
  }

  async connect(brokerIp?: string, brokerPort?: number, useTls?: boolean): Promise<void> {
    const nextBrokerIp = brokerIp ?? this.brokerIp
    const nextBrokerPort = brokerPort ?? this.brokerPort
    const nextUseTls = useTls ?? this.useTls

    if (this.connected) {
      if (this.matchesBroker(nextBrokerIp, nextBrokerPort, nextUseTls)) {
        return
      }
      await this.disconnect()
    }

    this.brokerIp = nextBrokerIp
    this.brokerPort = nextBrokerPort
    this.useTls = nextUseTls

    if (this.brokerIp.length === 0) {
      this.notifyStatus(false, 'MQTT: no broker IP')
      return
    }

    if (this.connectTask !== null) {
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
    await this.disconnect()
    this.recvBuf = new Uint8Array(0)
    const generation = this.socketGeneration + 1
    this.socketGeneration = generation
    let tcpSocket: socket.TCPSocket | null = null
    let tlsSocket: socket.TLSSocket | null = null

    try {
      const addr: socket.NetAddress = { address: this.brokerIp, port: this.brokerPort, family: 1 }
      if (this.useTls) {
        tlsSocket = socket.constructTLSSocketInstance()
        this.tls = tlsSocket
        this.bindTlsEvents(tlsSocket, generation)
        await tlsSocket.bind({ address: '0.0.0.0', port: 0, family: 1 })
        await this.withTimeout(tlsSocket.connect({
          address: addr,
          secureOptions: {
            ca: BROKER_CA_CERT,
            cert: DAYU_CLIENT_CERT,
            key: DAYU_CLIENT_KEY
          }
        }), MQTT_SOCKET_CONNECT_TIMEOUT_MS, 'MQTTS socket connect')
      } else {
        tcpSocket = socket.constructTCPSocketInstance()
        this.tcp = tcpSocket
        this.bindTcpEvents(tcpSocket, generation)
        await this.withTimeout(tcpSocket.connect({ address: addr, timeout: 5000 }), MQTT_SOCKET_CONNECT_TIMEOUT_MS, 'MQTT socket connect')
      }

      const connackPromise = this.waitForConnack()
      await this.withTimeout(this.sendConnect(), MQTT_SEND_TIMEOUT_MS, 'MQTT CONNECT send')
      await connackPromise

      this.connected = true
      const scheme = this.useTls ? 'MQTTS' : 'MQTT'
      this.notifyStatus(true, `${scheme} ${this.brokerIp}:${this.brokerPort}`)
      console.info(`[MQTT] connected to ${scheme.toLowerCase()}://${this.brokerIp}:${this.brokerPort}`)

      for (const item of this.topics) {
        await this.subscribe(item.topic, item.qos)
      }

      this.startPing()
    } catch (err) {
      if (generation === this.socketGeneration) {
        this.connected = false
        this.stopPing()
        this.connectResolve = null
        this.connectReject = null
      }
      if (tcpSocket) {
        try {
          await tcpSocket.close()
        } catch (_) { /* ignore */ }
      }
      if (tlsSocket) {
        try {
          await tlsSocket.close()
        } catch (_) { /* ignore */ }
      }
      if (generation === this.socketGeneration) {
        this.tcp = null
        this.tls = null
        this.socketGeneration += 1
      }
      console.info(`[MQTT] connect failed: ${JSON.stringify(err)}`)
      this.notifyStatus(false, `MQTT: ${(err as Error).message}`)
      this.scheduleReconnect()
    }
  }

  async subscribe(topic: string, qos: number = 1): Promise<void> {
    const existing = this.topics.find((item: MqttSubscription) => item.topic === topic)
    if (existing) {
      existing.qos = qos
    } else {
      this.topics.push({ topic, qos })
    }
    if (!this.connected) return

    const pkt = this.buildSubscribe(topic, qos)
    await this.sendRaw(pkt)
    console.info(`[MQTT] subscribed: ${topic}`)
  }

  async publish(topic: string, payload: Uint8Array, qos: number = 1): Promise<void> {
    if (!this.connected) {
      throw new Error('MQTT not connected')
    }
    const publishPacket = this.buildPublish(topic, payload, qos)
    const ackTask = qos > 0 ? this.waitForPuback(publishPacket.packetId, topic) : null
    try {
      await this.sendRaw(publishPacket.packet)
      if (ackTask !== null) {
        await ackTask
      }
      console.info(`[MQTT] published to ${topic}: ${payload.length} bytes`)
    } catch (err) {
      if (publishPacket.packetId > 0) {
        this.clearPendingPuback(publishPacket.packetId)
      }
      this.markDisconnected(`MQTT send failed: ${(err as Error).message}`)
      throw new Error((err as Error).message)
    }
  }

  async disconnect(): Promise<void> {
    this.connected = false
    this.stopPing()
    this.clearReconnect()
    this.socketGeneration += 1
    this.connectResolve = null
    this.connectReject = null
    this.rejectPendingPubacks('MQTT disconnected')

    if (this.tcp) {
      try {
        await this.tcp.send({ data: this.toArrayBuffer(new Uint8Array([0xE0, 0x00])) })
        await this.tcp.close()
      } catch (_) { /* ignore */ }
      this.tcp = null
    }

    if (this.tls) {
      try {
        await this.tls.send(this.toArrayBuffer(new Uint8Array([0xE0, 0x00])))
        await this.tls.close()
      } catch (_) { /* ignore */ }
      this.tls = null
    }
  }

  private bindTcpEvents(sock: socket.TCPSocket, generation: number): void {
    sock.on('message', (data: socket.SocketMessageInfo) => this.handleSocketMessage(data, generation))
    sock.on('close', () => this.handleSocketClose(generation))
    sock.on('error', (err: Object) => this.handleSocketError(err, generation))
  }

  private bindTlsEvents(sock: socket.TLSSocket, generation: number): void {
    sock.on('message', (data: socket.SocketMessageInfo) => this.handleSocketMessage(data, generation))
    sock.on('close', () => this.handleSocketClose(generation))
    sock.on('error', (err: Object) => this.handleSocketError(err, generation))
  }

  private handleSocketMessage(data: socket.SocketMessageInfo, generation: number): void {
    if (generation !== this.socketGeneration) {
      return
    }
    const chunk = new Uint8Array(data.message as ArrayBuffer)
    const newBuf = new Uint8Array(this.recvBuf.length + chunk.length)
    newBuf.set(this.recvBuf, 0)
    newBuf.set(chunk, this.recvBuf.length)
    this.recvBuf = newBuf
    this.tryParsePackets()
  }

  private handleSocketClose(generation: number): void {
    if (generation !== this.socketGeneration) {
      return
    }
    if (this.connected) {
      this.markDisconnected('MQTT disconnected')
    }
  }

  private handleSocketError(err: Object, generation: number): void {
    if (generation !== this.socketGeneration) {
      return
    }
    console.info(`[MQTT] socket error: ${JSON.stringify(err)}`)
    if (this.connected) {
      this.markDisconnected('MQTT socket error')
    }
  }

  private markDisconnected(message: string): void {
    if (!this.connected && this.reconnectTimer !== -1) {
      return
    }
    this.connected = false
    this.socketGeneration += 1
    this.rejectPendingPubacks(message)
    this.notifyStatus(false, message)
    this.scheduleReconnect()
  }

  private async sendRaw(data: Uint8Array): Promise<void> {
    const buffer = this.toArrayBuffer(data)
    if (this.useTls && this.tls) {
      await this.tls.send(buffer)
      return
    }
    if (this.tcp) {
      await this.tcp.send({ data: buffer })
      return
    }
    throw new Error('MQTT socket not ready')
  }

  private waitForConnack(): Promise<void> {
    return new Promise((resolve, reject) => {
      this.connectResolve = resolve
      this.connectReject = reject
      setTimeout(() => {
        if (this.connectReject) {
          this.connectReject(new Error('CONNACK timeout'))
          this.connectResolve = null
          this.connectReject = null
        }
      }, MQTT_CONNACK_TIMEOUT_MS)
    })
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

  private waitForPuback(packetId: number, topic: string): Promise<void> {
    return new Promise<void>((resolve: () => void, reject: (err: Error) => void) => {
      const timerId = setTimeout(() => {
        this.pendingPubacks.delete(packetId)
        reject(new Error(`PUBACK timeout ${topic}`))
      }, MQTT_PUBACK_TIMEOUT_MS)
      this.pendingPubacks.set(packetId, { topic, timerId, resolve, reject })
    })
  }

  private clearPendingPuback(packetId: number): void {
    const pending = this.pendingPubacks.get(packetId)
    if (!pending) {
      return
    }
    clearTimeout(pending.timerId)
    this.pendingPubacks.delete(packetId)
  }

  private rejectPendingPubacks(message: string): void {
    this.pendingPubacks.forEach((pending: MqttPendingPuback, packetId: number) => {
      clearTimeout(pending.timerId)
      pending.reject(new Error(message))
      this.pendingPubacks.delete(packetId)
    })
  }

  private tryParsePackets(): void {
    while (this.recvBuf.length >= 2) {
      let pos = 1
      let multiplier = 1
      let remainingLen = 0
      let malformed = false
      while (pos < this.recvBuf.length && pos < 5) {
        const byte = this.recvBuf[pos++]
        remainingLen += (byte & 127) * multiplier
        if ((byte & 128) === 0) {
          const totalLen = pos + remainingLen
          if (this.recvBuf.length >= totalLen) {
            const packet = this.recvBuf.slice(0, totalLen)
            this.recvBuf = this.recvBuf.slice(totalLen)
            this.handlePacket(packet)
            if (packet[0] === 0x20 && this.connectResolve) {
              if (packet.length >= 4 && packet[3] === 0x00) {
                this.connectResolve()
              } else {
                this.connectReject?.(new Error(`CONNACK error code: ${packet[3]}`))
              }
              this.connectResolve = null
              this.connectReject = null
            }
            pos = 1
            remainingLen = 0
            continue
          }
          break
        }
        multiplier *= 128
        if (multiplier > 128 * 128 * 128) {
          malformed = true
          break
        }
      }
      if (malformed) break
      if (remainingLen === 0) break
      break
    }
  }

  private startPing(): void {
    this.stopPing()
    this.pingTimer = setInterval(async () => {
      if (this.connected) {
        try {
          await this.sendRaw(new Uint8Array([0xC0, 0x00]))
        } catch (err) {
          this.markDisconnected(`MQTT ping failed: ${(err as Error).message}`)
        }
      }
    }, MQTT_PING_INTERVAL_MS)
  }

  private stopPing(): void {
    if (this.pingTimer !== -1) {
      clearInterval(this.pingTimer)
      this.pingTimer = -1
    }
  }

  private scheduleReconnect(): void {
    this.clearReconnect()
    this.reconnectTimer = setTimeout(() => {
      console.info('[MQTT] reconnecting...')
      this.connect()
    }, MQTT_RECONNECT_DELAY_MS)
  }

  private clearReconnect(): void {
    if (this.reconnectTimer !== -1) {
      clearTimeout(this.reconnectTimer)
      this.reconnectTimer = -1
    }
  }

  private notifyStatus(connected: boolean, msg: string): void {
    console.info(`[MQTT] notifyStatus: connected=${connected} msg=${msg}`)
    if (this.onStatus) {
      this.onStatus(connected, msg)
    }
  }

  private toArrayBuffer(data: Uint8Array): ArrayBuffer {
    const buf = new ArrayBuffer(data.length)
    const view = new Uint8Array(buf)
    view.set(data)
    return buf
  }

  private encodeRemainingLength(length: number): Uint8Array {
    const result: number[] = []
    let remaining = length
    do {
      let digit = remaining % 128
      remaining = Math.floor(remaining / 128)
      if (remaining > 0) digit |= 0x80
      result.push(digit)
    } while (remaining > 0)
    return new Uint8Array(result)
  }

  private encodeString(str: string): Uint8Array {
    const encoder = new util.TextEncoder()
    const bytes = encoder.encodeInto(str)
    const len = bytes.length
    const result = new Uint8Array(len + 2)
    result[0] = (len >> 8) & 0xFF
    result[1] = len & 0xFF
    result.set(bytes, 2)
    return result
  }

  private async sendConnect(): Promise<void> {
    const protoBytes = this.encodeString(MQTT_PROTO_NAME)
    const clientIdBytes = this.encodeString(this.clientId)

    const varHeader = new Uint8Array(10)
    varHeader.set(protoBytes, 0)
    varHeader[protoBytes.length] = MQTT_PROTO_LEVEL
    varHeader[protoBytes.length + 1] = 0x02
    varHeader[protoBytes.length + 2] = (this.keepAlive >> 8) & 0xFF
    varHeader[protoBytes.length + 3] = this.keepAlive & 0xFF

    const payload = clientIdBytes
    const remainingLen = varHeader.length + payload.length
    const remBytes = this.encodeRemainingLength(remainingLen)

    const packet = new Uint8Array(1 + remBytes.length + remainingLen)
    packet[0] = 0x10
    packet.set(remBytes, 1)
    packet.set(varHeader, 1 + remBytes.length)
    packet.set(payload, 1 + remBytes.length + varHeader.length)

    await this.sendRaw(packet)
  }

  private buildSubscribe(topic: string, qos: number): Uint8Array {
    const packetId = this.nextPacketId()
    const varHeader = new Uint8Array(2)
    varHeader[0] = (packetId >> 8) & 0xFF
    varHeader[1] = packetId & 0xFF

    const topicBytes = this.encodeString(topic)
    const qosByte = new Uint8Array([qos & 0x03])
    const payload = new Uint8Array(topicBytes.length + 1)
    payload.set(topicBytes, 0)
    payload.set(qosByte, topicBytes.length)

    const remainingLen = varHeader.length + payload.length
    const remBytes = this.encodeRemainingLength(remainingLen)

    const packet = new Uint8Array(1 + remBytes.length + remainingLen)
    packet[0] = 0x82
    packet.set(remBytes, 1)
    packet.set(varHeader, 1 + remBytes.length)
    packet.set(payload, 1 + remBytes.length + varHeader.length)
    return packet
  }

  private buildPublish(topic: string, payload: Uint8Array, qos: number): MqttPublishPacket {
    const topicBytes = this.encodeString(topic)
    let varHeader: Uint8Array = topicBytes
    let packetId = 0
    if (qos > 0) {
      packetId = this.nextPacketId()
      const pidBytes = new Uint8Array(2)
      pidBytes[0] = (packetId >> 8) & 0xFF
      pidBytes[1] = packetId & 0xFF
      varHeader = new Uint8Array(topicBytes.length + 2)
      varHeader.set(topicBytes, 0)
      varHeader.set(pidBytes, topicBytes.length)
    }

    const remainingLen = varHeader.length + payload.length
    const remBytes = this.encodeRemainingLength(remainingLen)

    const packet = new Uint8Array(1 + remBytes.length + remainingLen)
    packet[0] = 0x30 | ((qos & 0x03) << 1)
    packet.set(remBytes, 1)
    packet.set(varHeader, 1 + remBytes.length)
    packet.set(payload, 1 + remBytes.length + varHeader.length)
    return { packet, packetId }
  }

  private handlePacket(packet: Uint8Array): void {
    if (packet.length < 2) return

    const type = packet[0] & 0xF0
    if (type === 0x30) {
      this.handlePublish(packet)
    } else if (type === 0x40) {
      this.handlePuback(packet)
    }
  }

  private handlePuback(packet: Uint8Array): void {
    if (packet.length < 4) {
      return
    }
    const packetId = (packet[2] << 8) | packet[3]
    const pending = this.pendingPubacks.get(packetId)
    if (!pending) {
      return
    }
    this.pendingPubacks.delete(packetId)
    clearTimeout(pending.timerId)
    console.info(`[MQTT] PUBACK ${pending.topic} #${packetId}`)
    pending.resolve()
  }

  private handlePublish(packet: Uint8Array): void {
    let pos = 1
    let multiplier = 1
    while (pos < packet.length) {
      const byte = packet[pos++]
      if ((byte & 128) === 0) break
      multiplier *= 128
      if (multiplier > 128 * 128 * 128) return
    }

    if (pos + 2 > packet.length) return
    const topicLen = (packet[pos] << 8) | packet[pos + 1]
    pos += 2
    if (pos + topicLen > packet.length) return

    const decoder = new util.TextDecoder()
    const topic = decoder.decodeWithStream(packet.slice(pos, pos + topicLen))
    pos += topicLen

    const qos = (packet[0] & 0x06) >> 1
    if (qos > 0) {
      if (pos + 2 > packet.length) {
        return
      }
      const packetId = (packet[pos] << 8) | packet[pos + 1]
      pos += 2
      this.sendPuback(packetId).catch((err: Error) => {
        console.info(`[MQTT] PUBACK send failed #${packetId}: ${err.message}`)
      })
    }
    if (pos > packet.length) return

    const payload = packet.slice(pos)

    console.info(`[MQTT] rx ${topic}: ${payload.length}B`)
    if (this.onMessage) {
      this.onMessage(topic, payload)
    }
  }

  private nextPacketId(): number {
    const id = this.packetId
    this.packetId = (this.packetId + 1) & 0xFFFF
    if (this.packetId === 0) this.packetId = 1
    return id
  }

  private async sendPuback(packetId: number): Promise<void> {
    await this.sendRaw(new Uint8Array([
      0x40,
      0x02,
      (packetId >> 8) & 0xFF,
      packetId & 0xFF
    ]))
  }
}
