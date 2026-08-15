import usbManager from '@ohos.usbManager'
import serialManager from '@ohos.usbManager.serial'
import localGateway from 'liblocal_gateway.so'
import {
  ProvisioningFrame,
  encodeProvisioningFrame,
  parseProvisioningFrames,
  provisioningTypeName,
  toHex
} from './SerialProvisioningProtocol'

const USB_ENDPOINT_XFER_BULK: number = 2
const USB_DIR_IN: number = 0x80
const USB_CLASS_CDC_COMM: number = 0x02
const USB_CLASS_CDC_DATA: number = 0x0A
const SERIAL_NONE: number = -1
const WCH_VENDOR_ID: number = 0x1A86
const CP210X_VENDOR_ID: number = 0x10C4
const READ_TIMEOUT_MS: number = 250
// A pending USB IN transfer completes immediately when data arrives. A longer
// idle timeout avoids waking ArkTS and the USB service every second while the
// BLE gateway is connected but quiet, without adding receive latency.
const USB_READ_TIMEOUT_MS: number = 5000
const USB_READ_RETRY_DELAY_MS: number = 500
const USB_READ_BUFFER_SIZE: number = 1024
const READ_ACTIVE_DELAY_MS: number = 0
// 分级空闲退避：刚空闲时保持较快轮询以压低首字节延迟，
// 持续空闲超过 READ_IDLE_SLOW_AFTER_MS 后放慢，避免空载占满 UI 线程。
// 配网帧重发周期为 1s、整体超时 15s，最大 120ms 的检测延迟不影响配网流程。
const READ_IDLE_DELAY_MS: number = 20
const READ_IDLE_SLOW_DELAY_MS: number = 120
const READ_IDLE_SLOW_AFTER_MS: number = 1000

type UsbSerialBackend = 'none' | 'serial' | 'usb'

export interface UsbSerialDeviceInfo {
  index: number
  name: string
  title: string
  vendorId: number
  productId: number
  productName: string
  manufacturerName: string
  kind: string
  serialPortId?: number
  usbIndex?: number
  usbInterfaceId?: number
  usbControlInterfaceId?: number
}

export interface UsbSerialOpenResult {
  ok: boolean
  message: string
}

interface UsbSerialEndpointSet {
  iface: usbManager.USBInterface
  inEndpoint: usbManager.USBEndpoint
  outEndpoint: usbManager.USBEndpoint
  cdcControlInterfaceId: number
}

interface UsbBulkReadEndpoint {
  iface: usbManager.USBInterface
  endpoint: usbManager.USBEndpoint
}

interface UsbBulkInterfaceCandidate {
  ifaceId: number
  controlInterfaceId: number
  clazz: number
  subClass: number
  protocol: number
  inAddress: number
  outAddress: number
}

interface UsbErrorLike {
  code?: number
  name?: string
  message?: string
}

type UsbErrorInput = UsbErrorLike | string | number | boolean | null | undefined

function vidPidText(value: number): string {
  return (value || 0).toString(16).toUpperCase().padStart(4, '0')
}

function nonEmptyText(value: string, fallback: string): string {
  return value && value.length > 0 ? value : fallback
}

function describeUsbError(err: UsbErrorInput): string {
  if (err === null || err === undefined) {
    return 'empty error'
  }
  if (typeof err === 'string') {
    return err
  }
  if (typeof err === 'number' || typeof err === 'boolean') {
    return `${err}`
  }
  const parts: string[] = []
  if (err.code !== undefined) {
    parts.push(`code=${err.code}`)
  }
  if (err.name && err.name.length > 0) {
    parts.push(`name=${err.name}`)
  }
  if (err.message && err.message.length > 0) {
    parts.push(`message=${err.message}`)
  }
  return parts.length > 0 ? parts.join(' ') : 'empty error'
}

function isQuietRxError(text: string): boolean {
  const lower = text.toLowerCase()
  return text === 'empty error' ||
    text === '-1' ||
    lower.indexOf('code=-1') >= 0 ||
    lower.indexOf('timeout') >= 0 ||
    lower.indexOf('timed out') >= 0 ||
    lower.indexOf('31400006') >= 0
}

function le32(value: number): Uint8Array {
  const bytes = new Uint8Array(4)
  bytes[0] = value & 0xFF
  bytes[1] = (value >>> 8) & 0xFF
  bytes[2] = (value >>> 16) & 0xFF
  bytes[3] = (value >>> 24) & 0xFF
  return bytes
}

function emptyBytes(): Uint8Array {
  return new Uint8Array(0)
}

function asciiPreview(bytes: Uint8Array, maxBytes: number = 80): string {
  const end = Math.min(bytes.length, maxBytes)
  let output = ''
  for (let i = 0; i < end; i += 1) {
    const value = bytes[i]
    if (value === 0x0D) {
      output += '\\r'
    } else if (value === 0x0A) {
      output += '\\n'
    } else if (value >= 0x20 && value <= 0x7E) {
      output += String.fromCharCode(value)
    } else {
      output += '.'
    }
  }
  if (bytes.length > maxBytes) {
    output += '...'
  }
  return output
}

function asciiText(bytes: Uint8Array, maxBytes: number = 160): string {
  const end = Math.min(bytes.length, maxBytes)
  let output = ''
  for (let i = 0; i < end; i += 1) {
    const value = bytes[i]
    if (value === 0x0D || value === 0x0A || value === 0x09) {
      output += ' '
    } else if (value >= 0x20 && value <= 0x7E) {
      output += String.fromCharCode(value)
    } else {
      output += ' '
    }
  }
  return output
}

function hasAsciiHexFrameCandidate(bytes: Uint8Array): boolean {
  const text = asciiText(bytes).toUpperCase()
  return text.indexOf('AA 55') >= 0 || text.indexOf('AA55') >= 0
}

function concatDebugBytes(left: Uint8Array, right: Uint8Array): Uint8Array {
  const output = new Uint8Array(left.length + right.length)
  output.set(left, 0)
  output.set(right, left.length)
  return output
}

export class UsbSerialProvisioningPort {
  private backend: UsbSerialBackend = 'none'
  private serialPortId: number = SERIAL_NONE
  private device: usbManager.USBDevice | null = null
  private pipe: usbManager.USBDevicePipe | null = null
  private endpointSet: UsbSerialEndpointSet | null = null
  private claimedInterfaces: usbManager.USBInterface[] = []
  private usbReadEndpoints: UsbBulkReadEndpoint[] = []
  private usbReadInFlightByEndpoint: boolean[] = []
  private readGeneration: number = 0
  private readBuffer: Uint8Array = new Uint8Array(0)
  private reading: boolean = false
  private usbWriteInProgress: boolean = false
  private usbWritePending: boolean = false
  private nextRxErrorLogAt: number = 0
  private nextEnterConfigTxLogAt: number = 0
  private nextAsciiHexHintAt: number = 0
  private lastRxAt: number = 0
  private rxByteCount: number = 0
  private burstReadUntil: number = 0
  // 连续空读的起始时间戳，0 表示当前不处于空闲状态
  private idleReadSince: number = 0
  private frameHandler: ((frame: ProvisioningFrame) => void) | null = null
  private logHandler: ((message: string) => void) | null = null

  listDevices(): UsbSerialDeviceInfo[] {
    const rawDevices: UsbSerialDeviceInfo[] = []
    this.appendRawUsbDevices(rawDevices)
    const preferredRawDevices = this.preferExplicitUsbSerialDevices(rawDevices)
    const dedupedRawDevices = this.deduplicateUsbSerialDevices(
      preferredRawDevices.length > 0 ? preferredRawDevices : rawDevices
    )
    const result: UsbSerialDeviceInfo[] = dedupedRawDevices
    if (result.length === 0) {
      this.appendSerialManagerDevices(result)
    }
    for (let i = 0; i < result.length; i += 1) {
      result[i].index = i
    }
    return result
  }

  isOpen(): boolean {
    return (this.backend === 'serial' && this.serialPortId !== SERIAL_NONE) ||
      (this.backend === 'usb' && this.pipe !== null && this.endpointSet !== null)
  }

  receivedByteCount(): number {
    return this.rxByteCount
  }

  boostReceive(durationMs: number): void {
    this.burstReadUntil = Math.max(this.burstReadUntil, Date.now() + Math.max(0, durationMs))
  }

  endReceiveBoost(): void {
    this.burstReadUntil = 0
  }

  hasDeviceAccessRight(device: UsbSerialDeviceInfo): boolean {
    try {
      if (device.kind === 'serial' && device.serialPortId !== undefined) {
        return serialManager.hasSerialRight(device.serialPortId)
      }
      if (device.kind === 'usb') {
        return usbManager.hasRight(device.name)
      }
    } catch (_) {
      return false
    }
    return false
  }

  async open(index: number, onFrame: (frame: ProvisioningFrame) => void, onLog: (message: string) => void): Promise<UsbSerialOpenResult> {
    await this.close()
    this.frameHandler = onFrame
    this.logHandler = onLog

    const candidates = this.listDevices()
    if (index < 0 || index >= candidates.length) {
      return { ok: false, message: '没有选中的 USB 串口设备' }
    }

    const selected = candidates[index]
    this.log(`[OPEN] selected ${selected.title}`)
    if (selected.kind === 'serial' && selected.serialPortId !== undefined) {
      return this.openSerialPort(selected)
    }
    if (selected.usbIndex !== undefined) {
      return this.openRawUsbDevice(selected.usbIndex, selected.usbInterfaceId, selected.usbControlInterfaceId)
    }
    return { ok: false, message: '选中的设备缺少可用端口信息' }
  }

  async close(): Promise<void> {
    this.reading = false
    this.readGeneration += 1
    this.idleReadSince = 0
    this.burstReadUntil = 0
    this.usbWritePending = false
    this.usbWriteInProgress = false
    if (this.backend === 'serial' && this.serialPortId !== SERIAL_NONE) {
      try {
        serialManager.close(this.serialPortId)
      } catch (_) {
        // ignore
      }
    }
    if (this.pipe !== null) {
      for (let i = this.claimedInterfaces.length - 1; i >= 0; i -= 1) {
        try {
          usbManager.releaseInterface(this.pipe, this.claimedInterfaces[i])
        } catch (_) {
          // ignore
        }
      }
    }
    if (this.pipe !== null) {
      try {
        usbManager.closePipe(this.pipe)
      } catch (_) {
        // ignore
      }
    }
    this.backend = 'none'
    this.serialPortId = SERIAL_NONE
    this.pipe = null
    this.endpointSet = null
    this.device = null
    this.claimedInterfaces = []
    this.usbReadEndpoints = []
    this.usbReadInFlightByEndpoint = []
    this.readBuffer = new Uint8Array(0)
    this.nextRxErrorLogAt = 0
    this.nextEnterConfigTxLogAt = 0
    this.nextAsciiHexHintAt = 0
    this.lastRxAt = 0
    this.rxByteCount = 0
  }

  async writeFrame(type: number, seq: number, payload: Uint8Array = new Uint8Array(0)): Promise<void> {
    const frame = encodeProvisioningFrame(type, seq, payload)
    let written = 0
    if (this.backend === 'serial' && this.serialPortId !== SERIAL_NONE) {
      written = await serialManager.write(this.serialPortId, frame, 1200)
      this.logTxFrame(type, seq, frame, written, 'SERIAL')
      this.ensureFrameFullyWritten(frame.length, written, 'SERIAL')
      return
    }
    if (this.backend === 'usb' && this.pipe !== null && this.endpointSet !== null) {
      this.usbWritePending = true
      const waitDeadline = Date.now() + USB_READ_TIMEOUT_MS + 250
      while (this.usbReadInFlightByEndpoint.some((inFlight: boolean) => inFlight) &&
        Date.now() < waitDeadline) {
        await this.waitMs(2)
      }
      // OpenHarmony can abort an outstanding bulk-IN transfer when the same
      // pipe is used for bulk-OUT without ever settling the original Promise.
      // In that case the old in-flight bit would permanently prevent the IN
      // endpoint from being armed again after this write. Move to a new read
      // generation atomically so late callbacks from the abandoned transfer
      // cannot clear or re-arm the new generation's slot.
      if (this.usbReadInFlightByEndpoint.some((inFlight: boolean) => inFlight)) {
        this.readGeneration += 1
        this.usbReadInFlightByEndpoint = this.usbReadEndpoints.map(() => false)
        this.log(`[USB] abandoned stalled IN transfer; rearming generation=${this.readGeneration}`)
      }
      while (this.usbWriteInProgress) {
        await this.waitMs(2)
      }
      this.usbWriteInProgress = true
      try {
        written = await usbManager.bulkTransfer(this.pipe, this.endpointSet.outEndpoint, frame, 1200)
        this.logTxFrame(type, seq, frame, written, 'USB-BULK')
        this.ensureFrameFullyWritten(frame.length, written, 'USB-BULK')
      } finally {
        this.usbWriteInProgress = false
        this.usbWritePending = false
        this.startUsbReadLoops(this.readGeneration)
      }
      return
    }
    throw new Error('USB 串口未连接')
  }

  private ensureFrameFullyWritten(expected: number, written: number, transport: string): void {
    if (written < 0) {
      throw new Error(`${transport} write returned ${written}`)
    }
    if (written !== expected) {
      throw new Error(`${transport} short write ${written}/${expected}`)
    }
  }

  private waitMs(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve()
      }, ms)
    })
  }

  async setControlLines(asserted: boolean): Promise<void> {
    if (!this.isOpen()) {
      throw new Error('USB serial is not open')
    }
    if (this.backend === 'serial') {
      this.log(`[SERIAL] DTR/RTS ${asserted ? 'asserted' : 'released'} skipped by system serial backend`)
      return
    }
    if (this.device === null || this.pipe === null || this.endpointSet === null) {
      throw new Error('USB raw backend is not ready')
    }
    await this.applyRawUsbControlLines(this.device, this.endpointSet.cdcControlInterfaceId, asserted)
  }

  private appendSerialManagerDevices(result: UsbSerialDeviceInfo[]): void {
    try {
      const ports = serialManager.getPortList()
      ports.forEach((port: Readonly<serialManager.SerialPort>) => {
        result.push({
          index: result.length,
          name: nonEmptyText(port.deviceName, `serial-${port.portId}`),
          title: `SerialPort ${nonEmptyText(port.deviceName, '-') } port=${port.portId}`,
          vendorId: 0,
          productId: 0,
          productName: 'USB SerialPort',
          manufacturerName: 'system',
          kind: 'serial',
          serialPortId: port.portId
        })
      })
    } catch (_) {
      // Some devices expose only raw USB host APIs. Keep the raw USB fallback.
    }
  }

  private appendRawUsbDevices(result: UsbSerialDeviceInfo[]): void {
    const devices = usbManager.getDevices()
    devices.forEach((device: Readonly<usbManager.USBDevice>, usbIndex: number) => {
      const productName = nonEmptyText(device.productName, 'USB device')
      const manufacturerName = nonEmptyText(device.manufacturerName, 'unknown')
      const chip = this.deviceFamily(device as usbManager.USBDevice)
      const candidates = this.findBulkInterfaceCandidates(device as usbManager.USBDevice)
      if (candidates.length === 0) {
        return
      }
      const candidate = this.pickBestBulkInterfaceCandidate(device as usbManager.USBDevice, candidates)
      result.push({
        index: result.length,
        name: nonEmptyText(device.name, `usb-${usbIndex}`),
        title: `USB-BULK ${chip} dataIface=${candidate.ifaceId} ctrlIface=${candidate.controlInterfaceId >= 0 ? candidate.controlInterfaceId : '-'} in=0x${candidate.inAddress.toString(16)} out=0x${candidate.outAddress.toString(16)} ${vidPidText(device.vendorId)}:${vidPidText(device.productId)}`,
        vendorId: device.vendorId || 0,
        productId: device.productId || 0,
        productName,
        manufacturerName,
        kind: 'usb',
        usbIndex,
        usbInterfaceId: candidate.ifaceId,
        usbControlInterfaceId: candidate.controlInterfaceId
      })
    })
  }

  private preferExplicitUsbSerialDevices(devices: UsbSerialDeviceInfo[]): UsbSerialDeviceInfo[] {
    const explicitDevices = devices.filter((device: UsbSerialDeviceInfo) => this.isExplicitUsbSerialVid(device.vendorId))
    return explicitDevices.length > 0 ? explicitDevices : devices
  }

  private deduplicateUsbSerialDevices(devices: UsbSerialDeviceInfo[]): UsbSerialDeviceInfo[] {
    const output: UsbSerialDeviceInfo[] = []
    const keys: string[] = []
    devices.forEach((device: UsbSerialDeviceInfo) => {
      const key = this.usbSerialDedupKey(device)
      let existingIndex = -1
      for (let i = 0; i < keys.length; i += 1) {
        if (keys[i] === key) {
          existingIndex = i
          break
        }
      }
      if (existingIndex < 0) {
        keys.push(key)
        output.push(device)
        return
      }
      if (this.usbSerialDeviceScore(device) > this.usbSerialDeviceScore(output[existingIndex])) {
        output[existingIndex] = device
      }
    })
    return output
  }

  private usbSerialDedupKey(device: UsbSerialDeviceInfo): string {
    const productName = device.productName && device.productName.length > 0 ? device.productName : '-'
    const manufacturerName = device.manufacturerName && device.manufacturerName.length > 0 ? device.manufacturerName : '-'
    if (device.kind === 'usb' && this.isExplicitUsbSerialVid(device.vendorId)) {
      return `usb-explicit|${device.vendorId}|${device.productId}|${productName}|${manufacturerName}`
    }
    return `${device.kind}|${device.vendorId}|${device.productId}|${productName}|${manufacturerName}|${device.name}`
  }

  private usbSerialDeviceScore(device: UsbSerialDeviceInfo): number {
    let score = 0
    if (this.isExplicitUsbSerialVid(device.vendorId)) {
      score += 100
    }
    if (device.usbInterfaceId !== undefined) {
      score += 20
    }
    if (device.usbControlInterfaceId !== undefined && device.usbControlInterfaceId >= 0) {
      score += 10
    }
    if (device.productName && device.productName.length > 0 && device.productName !== 'USB device') {
      score += 5
    }
    if (device.manufacturerName && device.manufacturerName.length > 0 && device.manufacturerName !== 'unknown') {
      score += 5
    }
    if (device.usbInterfaceId !== undefined) {
      score -= device.usbInterfaceId
    }
    return score
  }

  private pickBestBulkInterfaceCandidate(device: usbManager.USBDevice, candidates: UsbBulkInterfaceCandidate[]): UsbBulkInterfaceCandidate {
    let best = candidates[0]
    let bestScore = this.bulkInterfaceCandidateScore(device, best)
    for (let i = 1; i < candidates.length; i += 1) {
      const candidate = candidates[i]
      const score = this.bulkInterfaceCandidateScore(device, candidate)
      if (score > bestScore) {
        best = candidate
        bestScore = score
      }
    }
    return best
  }

  private bulkInterfaceCandidateScore(device: usbManager.USBDevice, candidate: UsbBulkInterfaceCandidate): number {
    let score = 0
    if (this.isExplicitUsbSerialVid(device.vendorId || 0)) {
      score += 100
    }
    if (candidate.clazz === USB_CLASS_CDC_DATA) {
      score += 40
    }
    if (candidate.controlInterfaceId >= 0) {
      score += 20
    }
    if (candidate.clazz === 0xFF) {
      score += 10
    }
    // ESP32-S3's native USB Serial/JTAG is a composite device. The JTAG
    // function can also expose bulk endpoints, but the application protocol
    // is carried by the CDC data interface. Prefer CDC data explicitly and,
    // when descriptors are vendor-specific, prefer the second endpoint pair
    // conventionally used by the CDC serial function (0x02/0x82).
    if ((device.vendorId || 0) === 0x303A) {
      if (candidate.clazz === USB_CLASS_CDC_DATA) {
        score += 160
      }
      if (candidate.inAddress === 0x82 && candidate.outAddress === 0x02) {
        score += 100
      } else if ((candidate.inAddress & 0x7F) >= 2 || (candidate.outAddress & 0x7F) >= 2) {
        score += 20
      }
      if (candidate.clazz === 0xFF && candidate.inAddress === 0x81 && candidate.outAddress === 0x01) {
        score -= 80
      }
    }
    score -= Math.abs(candidate.ifaceId - Math.max(0, candidate.controlInterfaceId))
    return score
  }

  private async openSerialPort(info: UsbSerialDeviceInfo): Promise<UsbSerialOpenResult> {
    const portId = info.serialPortId !== undefined ? info.serialPortId : SERIAL_NONE
    if (portId === SERIAL_NONE) {
      return { ok: false, message: 'SerialPort 缺少 portId' }
    }
    try {
      if (!serialManager.hasSerialRight(portId)) {
        const granted = await serialManager.requestSerialRight(portId)
        if (!granted) {
          return { ok: false, message: 'SerialPort 授权被拒绝' }
        }
      }
      serialManager.open(portId)
      serialManager.setAttribute(portId, {
        baudRate: serialManager.BaudRates.BAUDRATE_115200,
        dataBits: serialManager.DataBits.DATABIT_8,
        parity: serialManager.Parity.PARITY_NONE,
        stopBits: serialManager.StopBits.STOPBIT_1
      })
      this.backend = 'serial'
      this.serialPortId = portId
      this.startReadLoop()
      this.log(`[SERIAL] opened port=${portId} 115200/8N1`)
      return { ok: true, message: `已连接 SerialPort ${portId} 115200/8N1` }
    } catch (err) {
      this.backend = 'none'
      this.serialPortId = SERIAL_NONE
      return { ok: false, message: `SerialPort 连接失败: ${describeUsbError(err as UsbErrorLike)}` }
    }
  }

  private async openRawUsbDevice(usbIndex: number, preferredInterfaceId?: number, preferredControlInterfaceId?: number): Promise<UsbSerialOpenResult> {
    const devices = usbManager.getDevices()
    if (usbIndex < 0 || usbIndex >= devices.length) {
      return { ok: false, message: '没有选中的 USB 设备' }
    }

    const selected = devices[usbIndex] as usbManager.USBDevice
    const deviceName = nonEmptyText(selected.name, '')
    this.log(`[USB] selected ${this.deviceSummary(selected)}`)
    if (deviceName.length === 0) {
      return { ok: false, message: 'USB 设备缺少系统 name，无法授权' }
    }
    if (!usbManager.hasRight(deviceName)) {
      const granted = await usbManager.requestRight(deviceName)
      if (!granted) {
        return { ok: false, message: 'USB 访问授权被拒绝' }
      }
    }

    const endpointSet = this.findBulkEndpoints(selected, preferredInterfaceId, preferredControlInterfaceId)
    if (endpointSet === null) {
      return { ok: false, message: '未找到 USB bulk IN/OUT 端点' }
    }

    this.log(`[USB] selected dataIface=${endpointSet.iface.id} ctrlIface=${endpointSet.cdcControlInterfaceId} ` +
      `in=0x${(endpointSet.inEndpoint.address || 0).toString(16)} out=0x${(endpointSet.outEndpoint.address || 0).toString(16)}`)
    const pipe = usbManager.connectDevice(selected) as usbManager.USBDevicePipe
    const claimResult = usbManager.claimInterface(pipe, endpointSet.iface, true)
    if (claimResult !== 0) {
      usbManager.closePipe(pipe)
      return { ok: false, message: `claim interface 失败: ${claimResult}` }
    }

    this.claimedInterfaces = [endpointSet.iface]
    this.claimRelatedInterfaces(pipe, selected, endpointSet.iface.id, endpointSet.cdcControlInterfaceId)
    // ESP32-S3 exposes two independent bulk functions: CDC Serial and JTAG.
    // The application protocol is carried only by the selected CDC data
    // interface. Reading the JTAG IN endpoint concurrently makes the SDK
    // issue competing reads on one USB pipe and can prevent CDC data from
    // being delivered at all (the device then appears to ACK, while the host
    // receives zero bytes).
    this.usbReadEndpoints = [{ iface: endpointSet.iface, endpoint: endpointSet.inEndpoint }]
    this.usbReadInFlightByEndpoint = this.usbReadEndpoints.map(() => false)
    this.log(`[USB] RX endpoints=${this.usbReadEndpoints.map((item: UsbBulkReadEndpoint) =>
      `iface${item.iface.id}:0x${(item.endpoint.address || 0).toString(16)}`).join(', ')}`)

    this.device = selected
    this.pipe = pipe
    this.endpointSet = endpointSet
    this.backend = 'usb'
    await this.configureRawUsbSerial(selected, endpointSet.cdcControlInterfaceId)
    this.startReadLoop()
    return {
      ok: true,
      message: `已连接 USB-BULK ${nonEmptyText(selected.productName, selected.name)} 115200/8N1`
    }
  }

  private findBulkInterfaceCandidates(device: usbManager.USBDevice): UsbBulkInterfaceCandidate[] {
    const output: UsbBulkInterfaceCandidate[] = []
    const configs = device.configs ? device.configs : []
    for (const config of configs) {
      const interfaces = config.interfaces ? config.interfaces : []
      for (const iface of interfaces) {
        let inAddress = -1
        let outAddress = -1
        const endpoints = iface.endpoints ? iface.endpoints : []
        for (const endpoint of endpoints) {
          const endpointAddress = endpoint.address || 0
          const endpointDirection = endpoint.direction || 0
          const transferType = endpoint.type !== undefined ? endpoint.type : ((endpoint.attributes || 0) & 0x03)
          if (transferType !== USB_ENDPOINT_XFER_BULK) {
            continue
          }
          const isIn = endpointDirection === USB_DIR_IN || (endpointAddress & USB_DIR_IN) === USB_DIR_IN
          if (isIn) {
            inAddress = endpointAddress
          } else {
            outAddress = endpointAddress
          }
        }
        if (inAddress >= 0 && outAddress >= 0) {
          const controlInterfaceId = this.findNearestCdcControlInterfaceId(device, iface.id)
          output.push({
            ifaceId: iface.id,
            controlInterfaceId,
            clazz: iface.clazz || 0,
            subClass: iface.subClass || 0,
            protocol: iface.protocol || 0,
            inAddress,
            outAddress
          })
        }
      }
    }
    return output
  }

  private findBulkEndpoints(device: usbManager.USBDevice, preferredInterfaceId?: number, preferredControlInterfaceId?: number): UsbSerialEndpointSet | null {
    const configs = device.configs ? device.configs : []
    this.log(`[USB] descriptor configs=${configs.length} preferredIface=${preferredInterfaceId !== undefined ? preferredInterfaceId : '-'} preferredCtrl=${preferredControlInterfaceId !== undefined ? preferredControlInterfaceId : '-'}`)
    for (const config of configs) {
      const interfaces = config.interfaces ? config.interfaces : []
      this.log(`[USB] config id=${config.id} interfaces=${interfaces.length}`)
      for (const iface of interfaces) {
        if (preferredInterfaceId !== undefined && iface.id !== preferredInterfaceId) {
          continue
        }
        let inEndpoint: usbManager.USBEndpoint | null = null
        let outEndpoint: usbManager.USBEndpoint | null = null
        const endpoints = iface.endpoints ? iface.endpoints : []
        this.log(`[USB] iface id=${iface.id} class=${iface.clazz} sub=${iface.subClass} proto=${iface.protocol} endpoints=${endpoints.length}`)
        for (const endpoint of endpoints) {
          const endpointAddress = endpoint.address || 0
          const endpointDirection = endpoint.direction || 0
          const transferType = endpoint.type !== undefined ? endpoint.type : ((endpoint.attributes || 0) & 0x03)
          if (transferType !== USB_ENDPOINT_XFER_BULK) {
            continue
          }
          const isIn = endpointDirection === USB_DIR_IN || (endpointAddress & USB_DIR_IN) === USB_DIR_IN
          if (isIn) {
            inEndpoint = endpoint
          } else {
            outEndpoint = endpoint
          }
          this.log(`[USB] bulk ep addr=0x${endpointAddress.toString(16)} dir=0x${endpointDirection.toString(16)} max=${endpoint.maxPacketSize || 0}`)
        }
        if (inEndpoint !== null && outEndpoint !== null) {
          let controlInterfaceId = preferredControlInterfaceId !== undefined ?
            preferredControlInterfaceId :
            this.findNearestCdcControlInterfaceId(device, iface.id)
          if (controlInterfaceId < 0) {
            controlInterfaceId = iface.id
          }
          return {
            iface,
            inEndpoint,
            outEndpoint,
            cdcControlInterfaceId: controlInterfaceId
          }
        }
      }
    }
    return null
  }

  private hasClaimedInterface(interfaceId: number): boolean {
    for (let i = 0; i < this.claimedInterfaces.length; i += 1) {
      if (this.claimedInterfaces[i].id === interfaceId) {
        return true
      }
    }
    return false
  }

  private claimRelatedInterfaces(
    pipe: usbManager.USBDevicePipe,
    device: usbManager.USBDevice,
    dataInterfaceId: number,
    controlInterfaceId: number
  ): void {
    // ESP32-S3 may expose Serial and JTAG as a composite USB device. Claim only
    // the selected data interface and its paired CDC control interface.
    if (controlInterfaceId < 0 || controlInterfaceId === dataInterfaceId) {
      return
    }
    const configs = device.configs ? device.configs : []
    for (const config of configs) {
      const interfaces = config.interfaces ? config.interfaces : []
      for (const iface of interfaces) {
        if (iface.id !== controlInterfaceId) {
          continue
        }
        try {
          const result = usbManager.claimInterface(pipe, iface, true)
          this.log(`[USB] claim paired control iface id=${iface.id} dataIface=${dataInterfaceId} class=${iface.clazz} result=${result}`)
          if (result === 0) {
            this.claimedInterfaces.push(iface)
          }
        } catch (err) {
          this.log(`[USB] claim related iface id=${iface.id} skipped: ${describeUsbError(err as UsbErrorLike)}`)
        }
      }
    }
  }

  private findCdcControlInterfaceId(device: usbManager.USBDevice): number {
    const configs = device.configs ? device.configs : []
    for (const config of configs) {
      const interfaces = config.interfaces ? config.interfaces : []
      for (const iface of interfaces) {
        if (iface.clazz === USB_CLASS_CDC_COMM) {
          return iface.id
        }
      }
    }
    return -1
  }

  private findNearestCdcControlInterfaceId(device: usbManager.USBDevice, dataInterfaceId: number): number {
    const configs = device.configs ? device.configs : []
    let bestInterfaceId = -1
    let bestDistance = 1024
    for (const config of configs) {
      const interfaces = config.interfaces ? config.interfaces : []
      for (const iface of interfaces) {
        if (iface.clazz !== USB_CLASS_CDC_COMM) {
          continue
        }
        const distance = Math.abs((iface.id || 0) - dataInterfaceId)
        if (distance < bestDistance) {
          bestDistance = distance
          bestInterfaceId = iface.id
        }
      }
    }
    if (bestInterfaceId >= 0) {
      return bestInterfaceId
    }
    return this.findCdcControlInterfaceId(device)
  }

  private deviceSummary(device: usbManager.USBDevice): string {
    const configs = device.configs ? device.configs.length : 0
    return `${this.deviceFamily(device)} ${nonEmptyText(device.productName, 'USB device')} ` +
      `${vidPidText(device.vendorId)}:${vidPidText(device.productId)} name=${nonEmptyText(device.name, '-')} ` +
      `class=${device.clazz || 0} configs=${configs}`
  }

  private isExplicitUsbSerialVid(vid: number): boolean {
    return vid === WCH_VENDOR_ID ||
      vid === CP210X_VENDOR_ID ||
      vid === 0x0403 ||
      vid === 0x303A
  }

  private deviceFamily(device: usbManager.USBDevice): string {
    const vid = device.vendorId || 0
    const pid = device.productId || 0
    if (vid === WCH_VENDOR_ID) {
      if (this.isCh341Family(device)) {
        return 'CH340/CH341'
      }
      if (pid === 0x55D3 || pid === 0x55D4 || pid === 0x55D5) {
        return 'CH9102/CH343-CDC'
      }
      return 'WCH-Serial'
    }
    if (vid === CP210X_VENDOR_ID) {
      return 'CP210x'
    }
    if (vid === 0x0403) {
      return 'FTDI'
    }
    if (vid === 0x303A) {
      return 'Espressif-CDC'
    }
    if (this.hasCdcInterface(device)) {
      return 'CDC-ACM'
    }
    return 'USB'
  }

  private hasCdcInterface(device: usbManager.USBDevice): boolean {
    const configs = device.configs ? device.configs : []
    for (const config of configs) {
      const interfaces = config.interfaces ? config.interfaces : []
      for (const iface of interfaces) {
        if (iface.clazz === USB_CLASS_CDC_COMM || iface.clazz === USB_CLASS_CDC_DATA) {
          return true
        }
      }
    }
    return false
  }

  private isCp210x(device: usbManager.USBDevice): boolean {
    return (device.vendorId || 0) === CP210X_VENDOR_ID
  }

  private isCh34x(device: usbManager.USBDevice): boolean {
    return this.isCh341Family(device)
  }

  private isCh341Family(device: usbManager.USBDevice): boolean {
    const vid = device.vendorId || 0
    const pid = device.productId || 0
    return vid === WCH_VENDOR_ID && (pid === 0x7523 || pid === 0x7522 || pid === 0x5523)
  }

  private async configureRawUsbSerial(device: usbManager.USBDevice, interfaceId: number): Promise<void> {
    const family = this.deviceFamily(device)
    this.log(`[USB] raw driver candidate=${family}`)
    try {
      if (this.isCp210x(device)) {
        await this.configureCp210x(interfaceId)
        return
      }
      if (this.isCh34x(device)) {
        await this.configureCh34x()
        return
      }
      if ((device.vendorId || 0) === WCH_VENDOR_ID && this.hasCdcInterface(device)) {
        this.log('[USB] WCH CDC chip detected; using CDC ACM init instead of CH341 vendor init')
        await this.configureCdcAcmLineCoding(interfaceId)
        return
      }
      await this.configureCdcAcmLineCoding(interfaceId, (device.vendorId || 0) === 0x303A)
    } catch (err) {
      this.log(`[USB] raw init failed, continuing anyway: ${describeUsbError(err as UsbErrorLike)}`)
    }
  }

  private async configureCdcAcmLineCoding(interfaceId: number, assertDtr: boolean = false): Promise<void> {
    const lineCoding = new Uint8Array(7)
    const baud = 115200
    lineCoding[0] = baud & 0xFF
    lineCoding[1] = (baud >>> 8) & 0xFF
    lineCoding[2] = (baud >>> 16) & 0xFF
    lineCoding[3] = (baud >>> 24) & 0xFF
    lineCoding[4] = 0
    lineCoding[5] = 0
    lineCoding[6] = 8

    try {
      await this.controlOut(0x21, 0x20, 0, interfaceId, lineCoding, 'CDC SET_LINE_CODING')
      // Native ESP32-S3 USB CDC needs DTR asserted before it reliably sends
      // bytes back to the host. Keep RTS low so this does not resemble the
      // DTR/RTS auto-reset sequence used by external USB-UART bridges.
      const controlLineState = assertDtr ? 0x0001 : 0x0000
      let nativeControlResult = 0
      if (assertDtr && this.pipe !== null) {
        const fd = usbManager.getFileDescriptor(this.pipe)
        nativeControlResult = localGateway.usbControlLineState(fd, interfaceId, true)
        this.log(`[USB] native CDC DTR iface=${interfaceId} fd=${fd} result=${nativeControlResult}`)
      }
      if (!assertDtr || nativeControlResult < 0) {
        await this.controlOut(0x21, 0x22, controlLineState, interfaceId, emptyBytes(),
          'CDC SET_CONTROL_LINE_STATE')
      }
      this.log(`[USB] CDC ACM line coding set: iface=${interfaceId} 115200/8N1 ` +
        `DTR=${assertDtr ? 'asserted' : 'released'} RTS=released`)
    } catch (err) {
      this.log(`[USB] CDC line coding skipped: ${describeUsbError(err as UsbErrorLike)}`)
    }
  }

  private async configureCp210x(interfaceId: number): Promise<void> {
    await this.controlOut(0x41, 0x00, 0x0001, interfaceId, emptyBytes(), 'CP210x IFC_ENABLE')
    await this.controlOut(0x41, 0x1E, 0x0000, interfaceId, le32(115200), 'CP210x SET_BAUDRATE')
    await this.controlOut(0x41, 0x03, 0x0800, interfaceId, emptyBytes(), 'CP210x SET_LINE_CTL 8N1')
    await this.controlOut(0x41, 0x07, 0x0300, interfaceId, emptyBytes(), 'CP210x SET_MHS release DTR/RTS')
    this.log(`[USB] CP210x configured: iface=${interfaceId} 115200/8N1 DTR/RTS released`)
  }

  private async configureCh34x(): Promise<void> {
    try {
      const version = await this.controlIn(0xC0, 0x5F, 0x0000, 0x0000, 2, 'CH34x READ_VERSION')
      this.log(`[USB] CH34x version raw=${toHex(version, 8)}`)
    } catch (err) {
      this.log(`[USB] CH34x version read skipped: ${describeUsbError(err as UsbErrorLike)}`)
    }
    await this.controlOut(0x40, 0xA1, 0x0000, 0x0000, emptyBytes(), 'CH34x SERIAL_INIT')
    await this.controlOut(0x40, 0x9A, 0x1312, 0xCC83, emptyBytes(), 'CH34x BAUD_115200')
    await this.controlOut(0x40, 0x9A, 0x2518, 0x00C3, emptyBytes(), 'CH34x LCR_8N1')
    await this.controlOut(0x40, 0xA4, 0xFFFF, 0x0000, emptyBytes(), 'CH34x release DTR/RTS')
    this.log('[USB] CH34x configured: 115200/8N1 DTR/RTS released')
  }

  private async applyRawUsbControlLines(device: usbManager.USBDevice, interfaceId: number, asserted: boolean): Promise<void> {
    const state = asserted ? 'asserted' : 'released'
    if (this.isCp210x(device)) {
      await this.controlOut(
        0x41,
        0x07,
        asserted ? 0x0303 : 0x0300,
        interfaceId,
        emptyBytes(),
        `CP210x SET_MHS ${state}`
      )
      this.log(`[USB] CP210x DTR/RTS ${state}: iface=${interfaceId}`)
      return
    }
    if (this.isCh34x(device)) {
      await this.controlOut(
        0x40,
        0xA4,
        asserted ? 0xFF9F : 0xFFFF,
        0x0000,
        emptyBytes(),
        `CH34x DTR/RTS ${state}`
      )
      this.log(`[USB] CH34x DTR/RTS ${state}`)
      return
    }
    await this.controlOut(
      0x21,
      0x22,
      asserted ? 0x0003 : 0x0000,
      interfaceId,
      emptyBytes(),
      `CDC SET_CONTROL_LINE_STATE ${state}`
    )
    this.log(`[USB] CDC DTR/RTS ${state}: iface=${interfaceId}`)
  }

  private async controlOut(
    bmRequestType: number,
    bRequest: number,
    wValue: number,
    wIndex: number,
    data: Uint8Array,
    label: string
  ): Promise<void> {
    if (this.pipe === null) {
      throw new Error('USB pipe closed')
    }
    const written = await this.controlTransferCompat(bmRequestType, bRequest, wValue, wIndex, data, 1000)
    if (written < 0) {
      throw new Error(`${label} returned ${written}`)
    }
  }

  private async controlIn(
    bmRequestType: number,
    bRequest: number,
    wValue: number,
    wIndex: number,
    length: number,
    label: string
  ): Promise<Uint8Array> {
    if (this.pipe === null) {
      throw new Error('USB pipe closed')
    }
    const data = new Uint8Array(length)
    const read = await this.controlTransferCompat(bmRequestType, bRequest, wValue, wIndex, data, 1000)
    if (read < 0) {
      throw new Error(`${label} returned ${read}`)
    }
    const output = new Uint8Array(read)
    for (let i = 0; i < read; i += 1) {
      output[i] = data[i]
    }
    return output
  }

  private async controlTransferCompat(
    bmRequestType: number,
    bRequest: number,
    wValue: number,
    wIndex: number,
    data: Uint8Array,
    timeout: number
  ): Promise<number> {
    if (this.pipe === null) {
      throw new Error('USB pipe closed')
    }
    try {
      return await usbManager.usbControlTransfer(this.pipe, {
        bmRequestType,
        bRequest,
        wValue,
        wIndex,
        wLength: data.length,
        data
      }, timeout)
    } catch (err) {
      this.log(`[USB] usbControlTransfer unavailable, fallback controlTransfer: ${describeUsbError(err as UsbErrorLike)}`)
    }

    if (data.length === 0) {
      // SDK 11 rejects zero-length legacy control buffers. This is an
      // optional CDC line-state request for the raw bulk data path.
      this.log(`[USB] legacy controlTransfer cannot send zero-length request bRequest=0x${bRequest.toString(16)} value=0x${wValue.toString(16)} index=${wIndex}`)
      return 0
    }

    const legacyTarget = (bmRequestType & 0x1F) as usbManager.USBRequestTargetType
    const legacyReqType = ((bmRequestType >>> 5) & 0x03) as usbManager.USBControlRequestType
    return usbManager.controlTransfer(this.pipe, {
      request: bRequest,
      target: legacyTarget,
      reqType: legacyReqType,
      value: wValue,
      index: wIndex,
      data
    }, timeout)
  }

  private startReadLoop(): void {
    if (!this.isOpen()) {
      return
    }
    this.reading = true
    this.readGeneration += 1
    this.idleReadSince = 0
    if (this.backend === 'usb') {
      this.startUsbReadLoops(this.readGeneration)
      return
    }
    this.readOnce()
  }

  private readOnce(): void {
    if (!this.reading) {
      return
    }
    if (this.backend === 'serial') {
      this.readSerialOnce()
      return
    }
    if (this.backend === 'usb') {
      this.startUsbReadLoops(this.readGeneration)
    }
  }

  private readSerialOnce(): void {
    if (!this.reading || this.serialPortId === SERIAL_NONE) {
      return
    }
    const buffer = new Uint8Array(256)
    serialManager.read(this.serialPortId, buffer, READ_TIMEOUT_MS)
      .then((count: number) => {
        this.consumeReadBuffer(buffer, count)
        this.scheduleNextRead(count)
      })
      .catch((err: Error) => {
        this.logRxError(err as UsbErrorLike)
        this.scheduleNextRead(0)
      })
  }

  private startUsbReadLoops(generation: number): void {
    if (!this.reading || this.backend !== 'usb' || this.pipe === null) {
      return
    }
    if (this.usbReadEndpoints.length === 0 && this.endpointSet !== null) {
      this.usbReadEndpoints = [{ iface: this.endpointSet.iface, endpoint: this.endpointSet.inEndpoint }]
      this.usbReadInFlightByEndpoint = [false]
    }
    for (let index = 0; index < this.usbReadEndpoints.length; index += 1) {
      this.readUsbEndpointOnce(index, generation)
    }
  }

  private readUsbEndpointOnce(index: number, generation: number): void {
    if (!this.reading || this.backend !== 'usb' || this.pipe === null ||
      generation !== this.readGeneration || index < 0 || index >= this.usbReadEndpoints.length ||
      this.usbReadInFlightByEndpoint[index] || this.usbWritePending || this.usbWriteInProgress) {
      return
    }
    const pipe = this.pipe
    const readEndpoint = this.usbReadEndpoints[index]
    const buffer = new Uint8Array(USB_READ_BUFFER_SIZE)
    this.usbReadInFlightByEndpoint[index] = true
    usbManager.bulkTransfer(pipe, readEndpoint.endpoint, buffer, USB_READ_TIMEOUT_MS)
      .then((count: number) => {
        if (generation !== this.readGeneration || pipe !== this.pipe) {
          return
        }
        this.usbReadInFlightByEndpoint[index] = false
        // Re-arm the IN endpoint before parsing the current chunk. BLE replay
        // sends several near-maximum frames in quick succession, and returning
        // through the ArkTS timer queue here leaves a receive gap between them.
        this.scheduleUsbEndpointRead(index, generation, count)
        this.consumeReadBuffer(buffer, count)
      })
      .catch((err: Error) => {
        if (generation !== this.readGeneration || pipe !== this.pipe) {
          return
        }
        this.usbReadInFlightByEndpoint[index] = false
        this.logRxError(err as UsbErrorLike)
        this.scheduleUsbEndpointRead(index, generation, 0)
      })
  }

  private scheduleUsbEndpointRead(index: number, generation: number, lastReadCount: number): void {
    if (!this.reading || generation !== this.readGeneration) {
      return
    }
    if (this.usbWritePending || this.usbWriteInProgress) {
      return
    }
    if (lastReadCount > 0) {
      this.readUsbEndpointOnce(index, generation)
      return
    }
    // OpenHarmony may abort an in-flight USB IN transfer when a control frame is
    // written on the same pipe. During the command/ACK window, re-arm quickly so
    // the gateway's immediate control_result and device ACK stay in the CDC queue.
    const retryDelay = Date.now() < this.burstReadUntil ? 5 : USB_READ_RETRY_DELAY_MS
    setTimeout(() => {
      this.readUsbEndpointOnce(index, generation)
    }, retryDelay)
  }

  private consumeReadBuffer(buffer: Uint8Array, count: number): void {
    if (count <= 0) {
      this.logRxError(count)
      return
    }
    if (count > 0) {
      this.lastRxAt = Date.now()
      this.rxByteCount += count
      const incoming = new Uint8Array(count)
      for (let i = 0; i < count; i += 1) {
        incoming[i] = buffer[i]
      }
      this.log(`[RX][raw] ${count}B ${toHex(incoming, 64)} ascii="${asciiPreview(incoming, 80)}"`)
      if (hasAsciiHexFrameCandidate(incoming) && Date.now() >= this.nextAsciiHexHintAt) {
        this.nextAsciiHexHintAt = Date.now() + 3000
        this.log('[RX][ascii-hex] 检测到文本形式 AA 55；配网 ACK 必须发送二进制字节，不是打印十六进制字符串')
      }
      this.consumeIncoming(incoming)
    }
  }

  private scheduleNextRead(lastReadCount: number): void {
    if (!this.reading) {
      return
    }
    setTimeout(() => {
      this.readOnce()
    }, this.nextReadDelay(lastReadCount))
  }

  // 有数据时立即继续读，保证连续帧的接收速度不受影响。
  // 空闲时先以 READ_IDLE_DELAY_MS 轮询，持续空闲超过
  // READ_IDLE_SLOW_AFTER_MS 后退避到 READ_IDLE_SLOW_DELAY_MS，
  // 避免没有设备或设备静默时空转占用 UI 线程。
  private nextReadDelay(lastReadCount: number): number {
    if (lastReadCount > 0) {
      this.idleReadSince = 0
      return READ_ACTIVE_DELAY_MS
    }
    const now = Date.now()
    if (now < this.burstReadUntil) {
      return READ_ACTIVE_DELAY_MS
    }
    if (this.idleReadSince === 0) {
      this.idleReadSince = now
      return READ_IDLE_DELAY_MS
    }
    return now - this.idleReadSince >= READ_IDLE_SLOW_AFTER_MS ?
      READ_IDLE_SLOW_DELAY_MS : READ_IDLE_DELAY_MS
  }

  private logRxError(err: UsbErrorInput): void {
    if (!this.reading) {
      return
    }
    const text = describeUsbError(err)
    if (!isQuietRxError(text)) {
      this.log(`[RX] ${text}`)
    } else if (Date.now() >= this.nextRxErrorLogAt) {
      this.nextRxErrorLogAt = Date.now() + 20000
      const lastRxText = this.lastRxAt > 0 ? `${Math.round((Date.now() - this.lastRxAt) / 1000)}s ago, total=${this.rxByteCount}B` : 'never'
      this.log(`[RX] idle, no data yet (lastRx=${lastRxText})`)
    }
  }

  private consumeIncoming(incoming: Uint8Array): void {
    const candidateBuffer = concatDebugBytes(this.readBuffer, incoming)
    this.logFrameCandidates(candidateBuffer)
    const result = parseProvisioningFrames(this.readBuffer, incoming)
    this.readBuffer = result.remaining
    result.errors.forEach((err: string) => {
      this.log(`[RX][drop] ${err}`)
    })
    result.frames.forEach((frame: ProvisioningFrame) => {
      this.log(`[RX] ${provisioningTypeName(frame.type)} seq=${frame.seq} payload=${frame.payload.length}B`)
      if (this.frameHandler !== null) {
        this.frameHandler(frame)
      }
    })
  }

  private logFrameCandidates(buffer: Uint8Array): void {
    for (let i = 0; i + 1 < buffer.length; i += 1) {
      if (buffer[i] === 0xAA && buffer[i + 1] === 0x55) {
        const end = Math.min(buffer.length, i + 18)
        const candidate = new Uint8Array(end - i)
        for (let j = i; j < end; j += 1) {
          candidate[j - i] = buffer[j]
        }
        this.log(`[RX][candidate] offset=${i} ${toHex(candidate, 18)}`)
      }
    }
  }

  private logTxFrame(type: number, seq: number, frame: Uint8Array, written: number, transport: string): void {
    if (type === 0x20) {
      this.log(`[TX][${transport}] ${provisioningTypeName(type)} seq=${seq} ${frame.length}B payload=hidden written=${written}`)
    } else if (type === 0x10) {
      if (Date.now() >= this.nextEnterConfigTxLogAt) {
        this.nextEnterConfigTxLogAt = Date.now() + 1000
        this.log(`[TX][${transport}] ${provisioningTypeName(type)} seq=${seq} ${frame.length}B ${toHex(frame, 48)} written=${written}`)
      }
    } else {
      this.log(`[TX][${transport}] ${provisioningTypeName(type)} seq=${seq} ${frame.length}B ${toHex(frame, 48)} written=${written}`)
    }
  }

  private log(message: string): void {
    if (this.logHandler !== null) {
      this.logHandler(message)
    }
  }
}
