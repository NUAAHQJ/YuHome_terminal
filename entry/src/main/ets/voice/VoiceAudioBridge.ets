import { Context } from '@ohos.abilityAccessCtrl'
import socket from '@ohos.net.socket'

const CAPTURE_PORT: number = 19101
const PLAYBACK_PORT: number = 19102
const CAPTURE_SAMPLE_RATE: number = 16000
const PLAYBACK_SAMPLE_RATE: number = 48000
const PLAYBACK_CHUNK_BYTES: number = 16384
const CAPTURE_BATCH_BYTES: number = Math.floor(CAPTURE_SAMPLE_RATE * 2 * 0.24)

export interface VoiceAudioBridgeCallbacks {
  onPcm16: (samples: ArrayBuffer, sampleRate: number) => void
  onLevel: (level: number) => void
  onError: (message: string) => void
}

export class VoiceAudioBridge {
  private callbacks: VoiceAudioBridgeCallbacks | null = null
  private captureSocket: socket.UDPSocket | null = null
  private playbackSocket: socket.TCPSocket | null = null
  private running: boolean = false
  private suppressCapture: boolean = false
  private lastLevelAt: number = 0
  private captureChunks: Uint8Array[] = []
  private captureBytes: number = 0

  setCallbacks(callbacks: VoiceAudioBridgeCallbacks): void {
    this.callbacks = callbacks
  }

  async start(): Promise<void> {
    if (this.running) {
      return
    }
    await this.openCaptureSocket()
    this.running = true
  }

  async playPrompt(context: Context, rawFileName: string): Promise<void> {
    const wav = await context.resourceManager.getRawFileContent(rawFileName)
    const pcm = this.extractPcmFromWav(wav)
    if (pcm.byteLength === 0) {
      throw new Error(`提示音没有 PCM 数据: ${rawFileName}`)
    }

    this.suppressCapture = true
    this.clearCaptureBatch()
    try {
      const playback = await this.connectPlaybackSocket()
      this.playbackSocket = playback
      for (let offset = 0; offset < pcm.byteLength; offset += PLAYBACK_CHUNK_BYTES) {
        const end = Math.min(pcm.byteLength, offset + PLAYBACK_CHUNK_BYTES)
        const chunk = pcm.slice(offset, end)
        await playback.send({ data: chunk.buffer })
      }
      await playback.close()
      this.playbackSocket = null
      const durationMs = Math.ceil(pcm.byteLength * 1000 / (PLAYBACK_SAMPLE_RATE * 2))
      await this.delay(durationMs + 350)
    } finally {
      await this.closePlaybackSocket()
      this.clearCaptureBatch()
      this.suppressCapture = false
    }
  }

  async release(): Promise<void> {
    this.running = false
    this.suppressCapture = true
    this.clearCaptureBatch()
    await this.closePlaybackSocket()
    if (this.captureSocket !== null) {
      const capture = this.captureSocket
      this.captureSocket = null
      await capture.close().catch((err: Error) => {
        console.info(`[VoiceAudio][capture-close] ${err.message}`)
      })
    }
  }

  private async openCaptureSocket(): Promise<void> {
    if (this.captureSocket !== null) {
      return
    }
    const receiver = socket.constructUDPSocketInstance()
    receiver.on('message', (info: socket.SocketMessageInfo): void => {
      if (this.running && !this.suppressCapture) {
        this.handleCapturedBuffer(info.message)
      }
    })
    receiver.on('error', (err: Object): void => {
      const message = `ALSA Bridge UDP 异常: ${JSON.stringify(err)}`
      console.info(`[VoiceAudio][capture-error] ${message}`)
      if (this.callbacks !== null) {
        this.callbacks.onError(message)
      }
    })
    try {
      await receiver.bind({ address: '127.0.0.1', port: CAPTURE_PORT, family: 1 })
      this.captureSocket = receiver
    } catch (err) {
      await receiver.close().catch((closeErr: Error) => {
        console.info(`[VoiceAudio][capture-bind-close] ${closeErr.message}`)
      })
      throw new Error(`无法监听 ALSA Bridge 端口 ${CAPTURE_PORT}: ${(err as Error).message}`)
    }
  }

  private handleCapturedBuffer(buffer: ArrayBuffer): void {
    const chunk = new Uint8Array(buffer)
    if (chunk.byteLength === 0) {
      return
    }
    this.captureChunks.push(chunk)
    this.captureBytes += chunk.byteLength
    if (this.captureBytes < CAPTURE_BATCH_BYTES) {
      return
    }

    const bytes = new Uint8Array(this.captureBytes)
    let writeOffset = 0
    this.captureChunks.forEach((item: Uint8Array) => {
      bytes.set(item, writeOffset)
      writeOffset += item.byteLength
    })
    this.clearCaptureBatch()
    const sampleCount = Math.floor(bytes.byteLength / 2)
    if (sampleCount === 0) {
      return
    }

    if (this.callbacks !== null) {
      const now = Date.now()
      if (now - this.lastLevelAt >= 50) {
        this.lastLevelAt = now
        let sumSquares = 0
        let peak = 0
        let levelSamples = 0
        for (let i = 0; i < sampleCount; i += 8) {
          const offset = i * 2
          let sample = bytes[offset] | (bytes[offset + 1] << 8)
          if (sample >= 32768) {
            sample -= 65536
          }
          const absolute = Math.abs(sample)
          peak = Math.max(peak, absolute)
          sumSquares += sample * sample
          levelSamples += 1
        }
        const rms = levelSamples > 0 ? Math.sqrt(sumSquares / levelSamples) : 0
        this.callbacks.onLevel(Math.min(1, Math.max(rms / 500, peak / 4000)))
      }
      const pcmBuffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer
      this.callbacks.onPcm16(pcmBuffer, CAPTURE_SAMPLE_RATE)
    }
  }

  private clearCaptureBatch(): void {
    this.captureChunks = []
    this.captureBytes = 0
  }

  private extractPcmFromWav(wav: Uint8Array): Uint8Array {
    if (wav.byteLength < 44 || this.readAscii(wav, 0, 4) !== 'RIFF' ||
      this.readAscii(wav, 8, 4) !== 'WAVE') {
      throw new Error('提示音不是有效的 WAV 文件')
    }
    const view = new DataView(wav.buffer, wav.byteOffset, wav.byteLength)
    let offset = 12
    while (offset + 8 <= wav.byteLength) {
      const chunkName = this.readAscii(wav, offset, 4)
      const chunkSize = view.getUint32(offset + 4, true)
      const dataStart = offset + 8
      if (chunkName === 'data') {
        const dataEnd = Math.min(wav.byteLength, dataStart + chunkSize)
        return wav.slice(dataStart, dataEnd)
      }
      offset = dataStart + chunkSize + (chunkSize % 2)
    }
    throw new Error('WAV 文件缺少 data 块')
  }

  private readAscii(bytes: Uint8Array, offset: number, length: number): string {
    let value = ''
    for (let i = 0; i < length; i++) {
      value += String.fromCharCode(bytes[offset + i])
    }
    return value
  }

  private async connectPlaybackSocket(): Promise<socket.TCPSocket> {
    let lastError: Error = new Error('ALSA 播放服务未就绪')
    for (let attempt = 0; attempt < 5; attempt++) {
      const playback = socket.constructTCPSocketInstance()
      try {
        await playback.bind({ address: '127.0.0.1', port: 0, family: 1 })
        await playback.connect({
          address: { address: '127.0.0.1', port: PLAYBACK_PORT, family: 1 },
          timeout: 3000
        })
        return playback
      } catch (err) {
        lastError = err as Error
        await playback.close().catch((closeErr: Error) => {
          console.info(`[VoiceAudio][playback-retry-close] ${closeErr.message}`)
        })
        await this.delay(400)
      }
    }
    throw new Error(`无法连接 ALSA Bridge 播放端口 ${PLAYBACK_PORT}: ${lastError.message}`)
  }

  private async closePlaybackSocket(): Promise<void> {
    if (this.playbackSocket !== null) {
      const playback = this.playbackSocket
      this.playbackSocket = null
      await playback.close().catch((err: Error) => {
        console.info(`[VoiceAudio][playback-close] ${err.message}`)
      })
    }
  }

  private delay(ms: number): Promise<void> {
    return new Promise((resolve: () => void) => {
      setTimeout(() => resolve(), ms)
    })
  }
}
