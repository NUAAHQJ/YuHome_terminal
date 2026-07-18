import { Context } from '@ohos.abilityAccessCtrl'
import fs from '@ohos.file.fs'
import socket from '@ohos.net.socket'

const CAPTURE_PORT: number = 19101
const PLAYBACK_PORT: number = 19102
const SAMPLE_RATE: number = 48000
const CHANNEL_COUNT: number = 1
const BYTES_PER_SAMPLE: number = 2
const WAV_FILE_NAME: string = 'voice_test_latest.wav'

export interface VoiceRecorderTestCallbacks {
  onState: (state: string, detail: string) => void
  onLevel: (level: number) => void
  onDevice: (device: string) => void
  onReady: (filePath: string, durationMs: number) => void
}

export class VoiceRecorderTest {
  private callbacks: VoiceRecorderTestCallbacks | null = null
  private captureSocket: socket.UDPSocket | null = null
  private playbackSocket: socket.TCPSocket | null = null
  private recording: boolean = false
  private playing: boolean = false
  private pcmChunks: ArrayBuffer[] = []
  private pcmBytes: number = 0
  private filesDir: string = ''
  private lastLevelAt: number = 0

  setCallbacks(callbacks: VoiceRecorderTestCallbacks): void {
    this.callbacks = callbacks
  }

  isRecording(): boolean {
    return this.recording
  }

  isPlaying(): boolean {
    return this.playing
  }

  hasRecording(): boolean {
    return this.pcmBytes > 0
  }

  async startRecording(context: Context): Promise<void> {
    if (this.recording || this.playing) {
      return
    }
    this.emitState('准备中', '正在连接大禹 ALSA 音频服务')
    this.filesDir = context.filesDir
    this.pcmChunks = []
    this.pcmBytes = 0
    this.lastLevelAt = 0
    try {
      await this.ensureCaptureSocket()
      this.recording = true
      if (this.callbacks !== null) {
        this.callbacks.onDevice('ALSA Bridge: HECATE G1500 BAR')
      }
      this.emitState('录音中', '48 kHz / 单声道 / 请对着 USB 麦克风说话')
    } catch (err) {
      this.emitState('录音失败', (err as Error).message)
      throw new Error((err as Error).message)
    }
  }

  async stopRecording(): Promise<void> {
    if (!this.recording) {
      return
    }
    this.recording = false
    this.emitState('处理中', '正在生成 WAV 文件')
    if (this.pcmBytes === 0) {
      this.emitState('录音失败', '没有收到 ALSA 音频数据，请检查开机服务')
      return
    }
    try {
      const filePath = await this.saveWavFile()
      const durationMs = Math.round(this.pcmBytes * 1000 /
        (SAMPLE_RATE * CHANNEL_COUNT * BYTES_PER_SAMPLE))
      if (this.callbacks !== null) {
        this.callbacks.onReady(filePath, durationMs)
      }
      this.emitState('录音完成', '可以点击回放检查 USB 麦克风声音')
    } catch (err) {
      this.emitState('保存失败', (err as Error).message)
      throw new Error((err as Error).message)
    }
  }

  async playRecording(): Promise<void> {
    if (this.recording || this.playing || this.pcmBytes === 0) {
      return
    }
    this.playing = true
    this.emitState('回放中', '正在通过 USB 音箱播放录音')
    try {
      const playback = await this.connectPlaybackSocket()
      this.playbackSocket = playback
      for (let i = 0; i < this.pcmChunks.length; i++) {
        await playback.send({ data: this.pcmChunks[i] })
      }
      await playback.close()
      this.playbackSocket = null
      this.emitState('回放完成', '录音已发送到 ALSA 播放服务')
    } catch (err) {
      this.emitState('回放失败', (err as Error).message)
      throw new Error((err as Error).message)
    } finally {
      await this.closePlaybackSocket()
      this.playing = false
    }
  }

  async release(): Promise<void> {
    this.recording = false
    this.playing = false
    await this.closePlaybackSocket()
    if (this.captureSocket !== null) {
      const capture = this.captureSocket
      this.captureSocket = null
      await capture.close().catch((err: Error) => {
        console.info(`[VoiceRecorder][capture-close] ${err.message}`)
      })
    }
  }

  private async ensureCaptureSocket(): Promise<void> {
    if (this.captureSocket !== null) {
      return
    }
    const receiver = socket.constructUDPSocketInstance()
    receiver.on('message', (info: socket.SocketMessageInfo): void => {
      if (this.recording) {
        this.handleCapturedBuffer(info.message)
      }
    })
    receiver.on('error', (err: Object): void => {
      console.info(`[VoiceRecorder][capture-error] ${JSON.stringify(err)}`)
      if (this.recording) {
        this.emitState('录音失败', `ALSA Bridge UDP 异常: ${JSON.stringify(err)}`)
        this.recording = false
      }
    })
    try {
      await receiver.bind({ address: '127.0.0.1', port: CAPTURE_PORT, family: 1 })
      this.captureSocket = receiver
    } catch (err) {
      await receiver.close().catch((closeErr: Error) => {
        console.info(`[VoiceRecorder][capture-bind-close] ${closeErr.message}`)
      })
      throw new Error(`无法监听 ALSA Bridge 端口 ${CAPTURE_PORT}: ${(err as Error).message}`)
    }
  }

  private async connectPlaybackSocket(): Promise<socket.TCPSocket> {
    let lastError: Error = new Error('ALSA 播放服务未就绪')
    for (let attempt = 0; attempt < 3; attempt++) {
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
          console.info(`[VoiceRecorder][playback-retry-close] ${closeErr.message}`)
        })
        await this.delay(500)
      }
    }
    throw new Error(`无法连接 ALSA Bridge 端口 ${PLAYBACK_PORT}: ${lastError.message}`)
  }

  private handleCapturedBuffer(buffer: ArrayBuffer): void {
    if (buffer.byteLength === 0) {
      return
    }
    const source = new Uint8Array(buffer)
    const stored = new ArrayBuffer(source.byteLength)
    const copy = new Uint8Array(stored)
    copy.set(source)
    this.pcmChunks.push(stored)
    this.pcmBytes += copy.byteLength
    const now = Date.now()
    if (now - this.lastLevelAt >= 50) {
      this.lastLevelAt = now
      if (this.callbacks !== null) {
        this.callbacks.onLevel(this.measureLevel(copy))
      }
    }
  }

  private measureLevel(bytes: Uint8Array): number {
    let sumSquares = 0
    let peak = 0
    let sampleCount = 0
    for (let i = 0; i + 1 < bytes.length; i += 2) {
      let sample = bytes[i] | (bytes[i + 1] << 8)
      if (sample >= 32768) {
        sample -= 65536
      }
      const absolute = Math.abs(sample)
      peak = Math.max(peak, absolute)
      sumSquares += sample * sample
      sampleCount++
    }
    if (sampleCount === 0) {
      return 0
    }
    const rms = Math.sqrt(sumSquares / sampleCount)
    return Math.min(1, Math.max(rms / 500, peak / 4000))
  }

  private async saveWavFile(): Promise<string> {
    const wav = new Uint8Array(44 + this.pcmBytes)
    const view = new DataView(wav.buffer)
    this.writeAscii(view, 0, 'RIFF')
    view.setUint32(4, 36 + this.pcmBytes, true)
    this.writeAscii(view, 8, 'WAVE')
    this.writeAscii(view, 12, 'fmt ')
    view.setUint32(16, 16, true)
    view.setUint16(20, 1, true)
    view.setUint16(22, CHANNEL_COUNT, true)
    view.setUint32(24, SAMPLE_RATE, true)
    view.setUint32(28, SAMPLE_RATE * CHANNEL_COUNT * BYTES_PER_SAMPLE, true)
    view.setUint16(32, CHANNEL_COUNT * BYTES_PER_SAMPLE, true)
    view.setUint16(34, 16, true)
    this.writeAscii(view, 36, 'data')
    view.setUint32(40, this.pcmBytes, true)
    let offset = 44
    for (let i = 0; i < this.pcmChunks.length; i++) {
      const chunk = new Uint8Array(this.pcmChunks[i])
      wav.set(chunk, offset)
      offset += chunk.byteLength
    }
    const filePath = `${this.filesDir}/${WAV_FILE_NAME}`
    const file = await fs.open(filePath, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE)
    try {
      await fs.write(file.fd, wav.buffer)
    } finally {
      fs.closeSync(file)
    }
    return filePath
  }

  private writeAscii(view: DataView, offset: number, value: string): void {
    for (let i = 0; i < value.length; i++) {
      view.setUint8(offset + i, value.charCodeAt(i))
    }
  }

  private async closePlaybackSocket(): Promise<void> {
    if (this.playbackSocket !== null) {
      const playback = this.playbackSocket
      this.playbackSocket = null
      await playback.close().catch((err: Error) => {
        console.info(`[VoiceRecorder][playback-close] ${err.message}`)
      })
    }
  }

  private delay(ms: number): Promise<void> {
    return new Promise((resolve: () => void) => {
      setTimeout(() => resolve(), ms)
    })
  }

  private emitState(state: string, detail: string): void {
    if (this.callbacks !== null) {
      this.callbacks.onState(state, detail)
    }
  }
}
