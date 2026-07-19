import http from '@ohos.net.http'
import socket from '@ohos.net.socket'
import wifiManager from '@ohos.wifiManager'
import { common } from '@kit.AbilityKit'
import { util } from '@kit.ArkTS'
import { CryptoDecryptResult, clearDeviceDynamicCryptoKeys, clearDynamicCryptoKeys, decryptWithExpectedMode, decryptWithExpectedModeForDevice, decryptWithMode, decryptWithProvidedKey, decryptWithStaticExpectedMode, encryptWithMode, encryptWithModeForDevice, getDeviceDynamicAesKey, getDeviceDynamicSm4Key, getDynamicAesKey, getDynamicSm4Key, looksEncrypted, selfTest, currentCryptoMode, setCryptoMode, setDeviceDynamicCryptoKeys, setDynamicCryptoKeys } from '../crypto/CryptoLayer'
import { MqttClient } from '../mqtt/MqttClient'
import { ensureTlsCaFile } from '../mqtt/TlsIdentityFiles'
import { BridgeTlsClient, BridgeTlsJson } from '../bridge/BridgeTlsClient'
import { KeyExchangeLayer, KeyExchangeResult } from '../crypto/KeyExchangeLayer'
import { CloudSecureClient } from '../cloud/CloudSecureClient'
import { CloudMqttClient } from '../cloud/CloudMqttClient'
import { FaceAccessManager, FaceAccessProbeResult, FaceCaptureResult, FaceMatchResult, FaceUser } from '../face/FaceAccessManager'
import { ProvisioningConfig, ProvisioningFrame, ProvisioningFrameType, buildProvisioningConfigPayload, provisioningTypeName, toHex, utf8Decode } from '../provisioning/SerialProvisioningProtocol'
import { UsbSerialDeviceInfo, UsbSerialProvisioningPort } from '../provisioning/UsbSerialProvisioningPort'
import { VoiceAssistant, VoiceAssistantState, VoiceExecutionResult } from '../voice/VoiceAssistant'
import { VoiceIntent, VoiceIntentType } from '../voice/VoiceIntentParser'
import { SpeakerEnrollmentQuality, SpeakerProfile, SpeakerProfileManager } from '../voice/SpeakerProfileManager'
import { LocalGatewayService } from '../gateway/LocalGatewayService'
import { LocalGatewayEvent } from 'liblocal_gateway.so'

const ECDH_CACHED_PUBLIC_KEY_MAX_AGE_MS: number = 10 * 60 * 1000
const ECDH_RECOVERY_PUBLIC_KEY_MAX_AGE_MS: number = 24 * 60 * 60 * 1000
const HTTP_SENSOR_LIVE_RECOVERY_MAX_AGE_MS: number = 10 * 1000
const PROVISIONING_STAGE_IDLE: number = 0
const PROVISIONING_STAGE_ENTERING: number = 1
const PROVISIONING_STAGE_CONFIG_MODE: number = 2
const PROVISIONING_STAGE_CONFIG_SENT: number = 3
const PROVISIONING_STAGE_CONFIG_ACKED: number = 4
const PROVISIONING_STAGE_REBOOT_SENT: number = 5
const PROVISIONING_STAGE_SAVED: number = 6
const PROVISIONING_CONFIG_MODE_CONFIRM_ATTEMPTS: number = 3
const PROVISIONING_CONFIG_MODE_CONFIRM_TIMEOUT_MS: number = 800
const PROVISIONING_CONFIG_ACK_TIMEOUT_MS: number = 3000
const IR_COMMAND_ACK_TIMEOUT_MS: number = 8000
const IR_LEARN_STEP_ACK_TIMEOUT_MS: number = 90000
const IR_LEARN_KEY_LABELS: string[] = ['开机', '关机', '温度+', '温度-', '制冷', '制热']
const VOICEPRINT_PHRASES: string[] = [
  '小禹小禹，打开客厅灯',
  '小禹小禹，关闭客厅灯',
  '小禹小禹，打开空调'
]

interface SensorPacket {
  temperature?: number | string
  humidity?: number | string
  temp?: number | string
  hum?: number | string
  smoke?: boolean | AlarmSensorReading
  water?: AlarmSensorReading
  waterLeak?: boolean
  fallDetected?: boolean
  alertLevel?: number
  message?: string
}

interface AlarmSensorReading {
  alarm?: boolean | number | string
  raw?: number | string
  voltage?: number | string
}

interface AlarmReadingSnapshot {
  alarm: boolean
  raw: number
  voltage: number
}

interface LightStatusPacket {
  living?: boolean
  bedroom?: boolean
  pirEnabled?: boolean
  led?: boolean | number | string
  ledLock?: LedLockStatus
  door?: boolean | number | string
  locked?: boolean | number | string
  percent?: number | string
  doorLock?: LedLockStatus
  source?: string
  seq?: number
}

interface LightControlPacket {
  target: string
  power: boolean
  timestamp: number
}

interface LedLockStatus {
  owner?: string
  priority?: number
  ttlMs?: number
}

interface LedControlCommand {
  cmd: string
  val: number
  source: string
  priority: number
  lockMs: number
  seq: number
}

interface DoorControlCommand {
  cmd: string
  val: number
  source: string
  priority: number
  lockMs: number
  seq: number
  userId?: string
  userName?: string
  score?: number
}

interface IrControlCommand {
  cmd: string
  action: string
  seq: number
  index?: number
}

interface BridgeStatePacket {
  sensor?: SensorPacket
  light?: LightStatusPacket
  connected?: boolean
  lastMessage?: string
}

interface BridgeResponsePacket {
  ok?: boolean
  message?: string
  state?: BridgeStatePacket
  encrypted?: EncryptedBridgePacket
  httpSensor?: HttpSensorBridgePacket
  keyExchange?: KeyExchangeBridgePacket
}

interface EncryptedBridgePacket {
  enabled?: boolean
  payloadBase64?: string
  timestamp?: number
  topic?: string
}

interface HttpSensorBridgePacket {
  enabled?: boolean
  payloadBase64?: string
  timestamp?: number
  topic?: string
  deviceId?: string
  crypto?: string
  packets?: HttpSensorBridgeItem[]
}

interface HttpSensorBridgeItem {
  payloadBase64?: string
  timestamp?: number
  topic?: string
  deviceId?: string
  crypto?: string
  bytes?: number
}

interface PersistedDeviceCryptoKeys {
  aes: string
  sm4: string
}

interface DeviceDescriptor {
  deviceId: string
  name: string
  room: string
  capabilities: string[]
  transport: string
  crypto: string
  lastSeen: number
}

interface KeyExchangeBridgePacket {
  pending?: boolean
  payloadBase64?: string
  timestamp?: number
  topic?: string
  devices?: Record<string, KeyExchangeCachedPublicKey>
}

interface KeyExchangeCachedPublicKey {
  payloadBase64?: string
  timestamp?: number
  topic?: string
}

// UDP 信标包：broker.js 周期性广播，用于零配置自动发现
interface BeaconPacket {
  type: string
  broker_ip: string
  mqtt_port: number
  mqtt_tls_port?: number
  esp32_mqtt_tls_port?: number
  bridge_tls_port?: number
  http_port: number
  https_port?: number
  hostname?: string
  timestamp: number
}

interface MessageItem {
  id: string
  time: string
  from: string
  text: string
  deviceId?: string
}

interface CloudIngestPacket {
  source: string
  kind: string
  deviceId?: string
  deviceType?: string
  topic?: string
  text?: string
  crypto?: string
  target?: string
  action?: string
  state?: string
  commandId?: string
  level?: string
  result?: string
  esp32Online?: boolean
  sensor?: SensorPacket
  light?: LightStatusPacket
  percent?: number
}

interface CloudControlCommand {
  id: string
  kind?: string
  target?: string
  dayuTarget?: string
  action?: string
  power?: boolean
  temperature?: number
  mode?: string
  brand?: string
  percent?: number
  unlock?: boolean
  locked?: boolean
  source?: string
  protocol?: string
  crypto?: string
}

interface CloudPendingRequest {
  consumer: string
}

interface CloudAckRequest {
  id: string
  ok: boolean
  message: string
}

interface OutdoorWeatherPacket {
  temperature?: number | string
  humidity?: number | string
  label?: string
  icon?: string
  updatedAt?: string
  provider?: string
}

interface CloudWeatherRequest {
  clientId: string
  latitude: number
  longitude: number
}

interface MetricCardParams {
  title: string
  primary: string
  secondary: string
  accent: string
  icon: Resource
}

interface FaceVerifyBucket {
  userId: string
  userName: string
  hits: number
  totalScore: number
  bestScore: number
}

// IP 地址全部通过 UDP Beacon 信标自动发现，不硬编码
// 初始值仅作为信标到达前的占位
const DEFAULT_BRIDGE_URL: string = 'http://192.168.3.5:3000'  // 信标未到达时的 fallback
const CLOUD_API_BASES: string[] = [
  'https://121.43.49.213:8443'
]
const CLOUD_MQTT_URL: string = 'wss://121.43.49.213:8443/mqtt'
const MQTT_COMMAND_CONNECT_TIMEOUT_MS: number = 5000
const MQTT_COMMAND_PUBLISH_TIMEOUT_MS: number = 7000
const BRIDGE_TLS_COMMAND_CONNECT_TIMEOUT_MS: number = 6000
const MQTT_AUTO_CONNECT_TIMEOUT_MS: number = 8000
const BRIDGE_TLS_AUTO_CONNECT_MIN_INTERVAL_MS: number = 8000
const KEY_EXCHANGE_HTTP_POLL_MIN_INTERVAL_MS: number = 10000
// This DAYU firmware only accepts strings in TLSSocket.send(), so MQTT binary
// frames use the Broker's Base64-framed mutual-TLS bridge instead.
const DAYU_DIRECT_MQTT_ENABLED: boolean = false
const DAYU_PREFER_MQTT_TLS: boolean = true
const DAYU_ALLOW_PLAIN_MQTT_FALLBACK: boolean = false
const BRIDGE_TLS_AUTO_CONNECT_ENABLED: boolean = true
const CLOUD_SYNC_ENABLED: boolean = true

function createCloudSecureClients(): CloudSecureClient[] {
  const clients: CloudSecureClient[] = []
  for (let i = 0; i < CLOUD_API_BASES.length; i++) {
    clients.push(new CloudSecureClient(CLOUD_API_BASES[i]))
  }
  return clients
}
const DEFAULT_UDP_LISTEN_PORT: number = 1346  // Beacon 信标监听端口
const MAX_MQTT_MESSAGES: number = 30
const CRYPTO_MODE_STORAGE_KEY: string = 'cryptoMode'
const DYNAMIC_AES_STORAGE_KEY: string = 'dynamicAesKey'
const DYNAMIC_SM4_STORAGE_KEY: string = 'dynamicSm4Key'
const ACTIVE_DEVICE_STORAGE_KEY: string = 'activeEsp32DeviceId'
const DEVICE_KEYS_STORAGE_KEY: string = 'deviceCryptoKeys'
const DEVICE_REGISTRY_STORAGE_KEY: string = 'esp32DeviceRegistry'
const LIGHT_DEVICE_STORAGE_KEY: string = 'lightDeviceId'
const AC_DEVICE_STORAGE_KEY: string = 'acDeviceId'
const CURTAIN_DEVICE_STORAGE_KEY: string = 'curtainDeviceId'
const DOOR_DEVICE_STORAGE_KEY: string = 'doorDeviceId'
const LED_CONTROL_PRIORITY: number = 10
const LED_CONTROL_LOCK_MS: number = 5000
const LED_OPTIMISTIC_HOLD_MS: number = 20000
const DOOR_CONTROL_PRIORITY: number = 10
const DOOR_CONTROL_LOCK_MS: number = 5000
const JIANGNING_LATITUDE: number = 31.953168
const JIANGNING_LONGITUDE: number = 118.83951
const OUTDOOR_WEATHER_REFRESH_MS: number = 10 * 60 * 1000
const FACE_ENROLL_MIN_QUALITY: number = 0.50
const FACE_IDENTIFY_MIN_QUALITY: number = 0.40
const FACE_ENROLL_MAX_ATTEMPTS: number = 10
const FACE_VERIFY_REQUIRED_SAMPLES: number = 3
const FACE_VERIFY_REQUIRED_HITS: number = 2
const FACE_VERIFY_MAX_ATTEMPTS: number = 5
const FACE_VERIFY_AVG_THRESHOLD: number = 0.75

PersistentStorage.persistProp(CRYPTO_MODE_STORAGE_KEY, 'SM4')
PersistentStorage.persistProp(DYNAMIC_AES_STORAGE_KEY, '')
PersistentStorage.persistProp(DYNAMIC_SM4_STORAGE_KEY, '')
PersistentStorage.persistProp(ACTIVE_DEVICE_STORAGE_KEY, 'esp32')
PersistentStorage.persistProp(DEVICE_KEYS_STORAGE_KEY, '')
PersistentStorage.persistProp(DEVICE_REGISTRY_STORAGE_KEY, '')
PersistentStorage.persistProp(LIGHT_DEVICE_STORAGE_KEY, 'auto')
PersistentStorage.persistProp(AC_DEVICE_STORAGE_KEY, 'auto')
PersistentStorage.persistProp(CURTAIN_DEVICE_STORAGE_KEY, 'auto')
PersistentStorage.persistProp(DOOR_DEVICE_STORAGE_KEY, 'auto')

@Entry
@Component
struct Index {
  @State isDarkMode: boolean = false
  @State activeNav: string = 'overview'
  @State voiceAssistantStatus: string = '正在初始化'
  @State voiceAssistantDetail: string = '正在加载本地语音模型'
  @State voiceAssistantTranscript: string = ''
  @State voiceWaveform: number[] = [0.04, 0.04, 0.04, 0.04, 0.04, 0.04, 0.04, 0.04,
    0.04, 0.04, 0.04, 0.04, 0.04, 0.04, 0.04, 0.04, 0.04, 0.04, 0.04, 0.04]
  @State voiceAssistantActive: boolean = false
  @State voiceAssistantError: boolean = false

  @State currentTime: string = '08:30'
  @State currentDate: string = '2026/05/22'
  @State indoorTemp: number = 24.6
  @State indoorHumidity: number = 48
  private indoorTempText: string = '—℃'
  private indoorHumidityText: string = '—%'
  private sensorLastUpdateText: string = '等待设备上报'
  @State sensorDisplay: string[] = ['—℃', '—%', '等待设备上报']
  @State outdoorTempText: string = '—℃'
  @State outdoorHumidityText: string = '—%'
  @State outdoorWeatherLabel: string = '等待云平台天气'
  @State outdoorWeatherIcon: string = '云'
  @State outdoorWeatherUpdateText: string = '南京市江宁区'
  @State hasOutdoorWeather: boolean = false

  @State alertLevel: number = 0
  @State alertMessage: string = '全屋设备运行正常'
  @State showCriticalDialog: boolean = false
  @State smokeAlarm: boolean = false
  @State waterAlarm: boolean = false
  @State smokeRaw: number = 0
  @State waterRaw: number = 0
  @State smokeVoltage: number = 0
  @State waterVoltage: number = 0
  @State alarmClearPending: boolean = false
  @State alarmClearConfirmed: boolean = false
  @State alarmDialogTarget: string = ''
  @State alarmAckText: string = '点击异常项可关闭报警'
  private alarmCommandSeq: number = 0
  private alarmPendingSeq: number = 0
  private alarmDeviceId: string = ''
  private alarmAckTimerId: number = -1
  private lastAlarmEventSignature: string = ''
  private lastAlarmEventAt: number = 0

  @State doorLocked: boolean = true
  @State doorOpen: boolean = false
  private hasDoorOpenStatus: boolean = false
  @State doorPending: boolean = false
  @State doorAckText: string = '等待识别'
  @State showAcControlPanel: boolean = false
  private doorCommandSeq: number = 0
  private doorPendingSeq: number = 0
  private doorPendingTargetLocked: boolean = true
  private doorAckTimerId: number = -1
  private overviewDoorTapTimerId: number = -1
  private overviewDoorLastTapAt: number = 0
  @State acBrand: string = '格力'
  @State acTemp: number = 24
  @State acPower: boolean = true
  @State acMode: string = 'cool'
  @State acAckText: string = '等待控制'
  @State acPending: boolean = false
  private acCommandSeq: number = 0
  private acPendingSeq: number = 0
  private acAckTimerId: number = -1
  private acControlTimerId: number = -1
  private acQueuedReason: string = ''
  private acNeedsSendAfterPending: boolean = false
  private acLastSentSignature: string = ''
  private acLastSentAt: number = 0
  @State pirEnabled: boolean = true
  @State livingLightOn: boolean = false
  @State livingLightPending: boolean = false
  @State livingLightAckText: string = '等待控制'
  private livingLightControlInFlight: boolean = false
  private lastLivingLightClickAt: number = 0
  private lastLivingLightCommandKey: string = ''
  private lastLivingLightCommandAt: number = 0
  private livingLightControlTimerId: number = -1
  private livingLightOptimisticUntil: number = 0
  private livingLightPendingTargetOn: boolean = true
  private hasLivingLightPendingTarget: boolean = false
  @State bedroomLightOn: boolean = false
  @State curtainPercent: number = 62
  private curtainDragStartPercent: number = 62
  private curtainCommandSeq: number = 0
  @State leavingMode: boolean = false
  @State bridgeConnected: boolean = false
  @State bridgeLinkConnected: boolean = false
  @State bridgeTlsConnected: boolean = false
  @State bridgeLastMessage: string = 'Bridge 待连接'
  @State bridgeLastError: string = ''
  @State bridgeUrl: string = DEFAULT_BRIDGE_URL
  @State commandTransport: string = 'MQTT'
  @StorageLink(ACTIVE_DEVICE_STORAGE_KEY) activeDeviceId: string = 'esp32'
  @State knownDeviceIds: string[] = ['esp32']
  @State protocolPendingMode: string = ''
  // ── 加密通信状态 ──
  @State cryptoEnabled: boolean = false
  @State cryptoLastDecrypted: string = '等待加密数据...'
  @State cryptoDebugText: string = '加密包: 等待'
  @StorageLink(CRYPTO_MODE_STORAGE_KEY) cryptoMode: string = 'SM4'
  @StorageLink(DYNAMIC_AES_STORAGE_KEY) dynamicAesKeyBase64: string = ''
  @StorageLink(DYNAMIC_SM4_STORAGE_KEY) dynamicSm4KeyBase64: string = ''
  @StorageLink(DEVICE_KEYS_STORAGE_KEY) deviceCryptoKeysJson: string = ''
  @StorageLink(DEVICE_REGISTRY_STORAGE_KEY) deviceRegistryJson: string = ''
  @StorageLink(LIGHT_DEVICE_STORAGE_KEY) lightDeviceId: string = 'auto'
  @StorageLink(AC_DEVICE_STORAGE_KEY) acDeviceId: string = 'auto'
  @StorageLink(CURTAIN_DEVICE_STORAGE_KEY) curtainDeviceId: string = 'auto'
  @StorageLink(DOOR_DEVICE_STORAGE_KEY) doorDeviceId: string = 'auto'
  @State cryptoPendingMode: string = ''
  @State beaconLastReceived: string = '等待信标...'
  @State beaconAutoDiscovered: boolean = false
  @State showDebugPanel: boolean = false
  @State debugShowAllDevices: boolean = false
  // MQTT 消息记录（替代旧 UDP 列表）
  @State mqttMessages: MessageItem[] = []
  @State mqttLastMsgTime: string = '--:--:--'
  private debugPanelTapCount: number = 0
  private debugPanelLastTapAt: number = 0

  private timerId: number = -1
  private pollTimerId: number = -1
  private weatherTimerId: number = -1
  private weatherInFlight: boolean = false
  private cloudHeartbeatTimerId: number = -1
  private udpReceiver: socket.UDPSocket | null = null
  private mqtt: MqttClient = new MqttClient()
  private localMqtt: MqttClient = new MqttClient(`dayu_local_${Date.now()}`)
  private localGatewayDeviceIds: Set<string> = new Set()
  private localGatewayTransportByDevice: Map<string, string> = new Map()
  private bridgeTls: BridgeTlsClient = new BridgeTlsClient()
  private keyExchange: KeyExchangeLayer = new KeyExchangeLayer()
  private cloudSecureClients: CloudSecureClient[] = createCloudSecureClients()
  private cloudCommandSecureClients: CloudSecureClient[] = this.cloudSecureClients
  private cloudWeatherSecureClients: CloudSecureClient[] = this.cloudSecureClients
  private cloudMqttTransport: CloudMqttClient = new CloudMqttClient(CLOUD_MQTT_URL)
  private cloudMqttSecureClient: CloudSecureClient = new CloudSecureClient(CLOUD_MQTT_URL)
  private cloudTransport: string = 'HTTP'
  private cloudSecureIndex: number = 0
  private cloudCommandSecureIndex: number = 0
  private cloudWeatherSecureIndex: number = 0
  private faceAccess: FaceAccessManager = new FaceAccessManager()
  private voiceAssistant: VoiceAssistant = new VoiceAssistant()
  private speakerProfiles: SpeakerProfileManager = new SpeakerProfileManager()
  private localGateway: LocalGatewayService = new LocalGatewayService()
  private lastEncryptedTimestamp: number = 0
  private lastHttpSensorTimestamp: number = 0
  private lastSuccessfulDecryptAt: number = 0
  private lastSuccessfulDecryptAtByDevice: Map<string, number> = new Map()
  private recentEncryptedPayloads: Map<string, number> = new Map()
  private processedHttpSensorPackets: Set<string> = new Set()
  private bridgeStateFailCount: number = 0
  private bridgeStateRefreshInFlight: boolean = false
  private lastBridgeOkAt: number = 0
  private cloudFailCount: number = 0
  private cloudPausedUntil: number = 0
  private cloudReportInFlight: boolean = false
  private cloudAlarmReportInFlight: boolean = false
  private cloudActuatorReportInFlight: boolean = false
  private pendingCloudAlarm: CloudIngestPacket | null = null
  private pendingCloudActuator: CloudIngestPacket | null = null
  private cloudAlarmRetryTimerId: number = -1
  private cloudActuatorRetryTimerId: number = -1
  private cloudCommandPollTimerId: number = -1
  private cloudCommandInFlight: boolean = false
  private lastSensorDebugMessageAt: number = 0
  private lastKeyExchangeTimestampByTopic: Map<string, number> = new Map()
  private cryptoSwitchTimerId: number = -1
  private cryptoSwitchHttpSensorBaseline: number = 0
  private cryptoSwitchEncryptedBaseline: number = 0
  private cryptoModeAutoCorrectHoldUntil: number = 0
  private cryptoSwitchSeq: number = 0
  private cryptoPendingSeq: number = 0
  private protocolSwitchTimerId: number = -1
  private protocolSwitchSeq: number = 0
  private protocolPendingSeq: number = 0
  private ledCommandSeq: number = 0
  private ledPendingSeq: number = 0
  private suppressLivingLightChange: boolean = false
  private lastDeviceLivingLightValue: boolean = true
  private lastDeviceLivingLightChangeAt: number = 0
  private decryptFailCount: number = 0
  private ecdhRecoveryInProgress: boolean = false
  private lastEcdhRecoveryTime: number = 0
  private decryptFailCountByDevice: Map<string, number> = new Map()
  private ecdhRecoveryDevices: Set<string> = new Set()
  private lastEcdhRecoveryTimeByDevice: Map<string, number> = new Map()
  private recentSentEcdhPublicKeys: Map<string, number> = new Map()
  private ecdhTopicsInProgress: Set<string> = new Set()
  private lastEcdhPendingTime: number = 0
  private lastEcdhInstallTime: number = 0
  private lastEcdhPendingTimeByDevice: Map<string, number> = new Map()
  private lastEcdhInstallTimeByDevice: Map<string, number> = new Map()
  private ecdhReplyRetryTimerId: number = -1
  private ecdhReplyRetryAttempt: number = 0
  private pendingEcdhReplyDeviceId: string = ''
  private pendingEcdhRemoteTopic: string = ''
  private pendingEcdhRemotePublicKey: Uint8Array | null = null
  private pendingEcdhReplyTopic: string = ''
  private pendingEcdhReplyPublicKey: Uint8Array | null = null
  private deviceEpoch: number = 0
  private deviceKeySource: string = 'static'
  private lastBootRekeyAt: number = 0
  private keySyncSeq: number = 0
  private lastDeviceBootAt: number = 0
  private lastDeviceBootSignature: string = ''
  private bridgeTlsIp: string = ''
  private bridgeTlsPort: number = 0
  private beaconBrokerIp: string = ''
  private beaconMqttPort: number = 0
  private beaconMqttTlsPort: number = 0
  private beaconEsp32MqttTlsPort: number = 0
  private beaconHttpPort: number = 0
  private beaconHttpsPort: number = 0
  private localGatewayHost: string = ''
  private mqttTlsFallbackUntil: number = 0
  private bridgeTlsAutoConnectInFlight: boolean = false
  private lastBridgeTlsAutoConnectAt: number = 0
  private lastKeyExchangeHttpPollAt: number = 0
  @State hasLiveSensorData: boolean = false
  @State mqttConnected: boolean = false
  @State mqttStatus: string = 'MQTT 待连接'
  private hasLiveLedStatus: boolean = false
  @State showFaceEnrollPanel: boolean = false
  @State faceEnrollName: string = ''
  @State faceEnrollProgress: number = 0
  @State faceAccessStatus: string = '相机未检测'
  @State faceCameraSummary: string = '等待人脸录入'
  @State faceUsers: FaceUser[] = []
  @State facePreviewReady: boolean = false
  @State faceEnrollBusy: boolean = false
  @State faceIdentifyBusy: boolean = false
  @State showVoiceprintPanel: boolean = false
  @State showDeviceStatusPanel: boolean = false
  @State voiceprintUsers: SpeakerProfile[] = []
  @State voiceprintProtectionEnabled: boolean = false
  @State voiceprintModelReady: boolean = false
  @State voiceprintModelDimension: number = 0
  @State voiceprintStatus: string = '正在准备声纹识别'
  @State voiceprintEnrollName: string = ''
  @State voiceprintEnrollProgress: number = 0
  @State voiceprintEnrollBusy: boolean = false
  private voiceprintEnrollmentSamples: number[][] = []
  private facePreviewController: XComponentController = new XComponentController()
  private facePreviewSurfaceId: string = ''
  private provisioningPort: UsbSerialProvisioningPort = new UsbSerialProvisioningPort()
  private provisioningSeq: number = 0
  private provisioningEnterTimerId: number = -1
  private provisioningEnterStopAt: number = 0
  private provisioningAutoProbeActive: boolean = false
  private provisioningAutoProbeMatched: boolean = false
  private provisioningAutoProbeRunId: number = 0
  private provisioningFlowStage: number = PROVISIONING_STAGE_IDLE
  private provisioningPendingFrameType: number = -1
  private provisioningPendingFrameSeq: number = -1
  private provisioningPendingFrameAllowAnySeq: boolean = false
  private provisioningPendingFrameTimerId: number = -1
  private provisioningPendingFrameResolve: ((matched: boolean) => void) | null = null
  private provisioningLastPendingMatchedSeq: number = -1
  private provisioningPendingErrorText: string = ''
  private provisioningLogSeq: number = 0
  private provisioningLogFlushTimerId: number = -1
  private pendingProvisioningFrameLogs: string[] = []
  @State showProvisioningPanel: boolean = false
  @State showProvisioningOutputPanel: boolean = false
  @State showDeviceBindingPanel: boolean = false
  @State provisioningUsbDevices: UsbSerialDeviceInfo[] = []
  @State provisioningSelectedDeviceIndex: number = 0
  @State provisioningConnected: boolean = false
  @State provisioningBusy: boolean = false
  @State provisioningStatus: string = '等待连接设备串口'
  @State provisioningWifiSsid: string = ''
  @State provisioningWifiPassword: string = ''
  @State provisioningBrokerUrl: string = ''
  @State provisioningHttpBridge: string = ''
  @State provisioningUseTls: boolean = false
  @State provisioningCrypto: string = 'sm4'
  @State provisioningTransport: string = 'mqtt'
  @State provisioningFrameLog: string[] = []
  private irLearnTimerId: number = -1
  private irCommandSeq: number = 0
  private irLearnExpectedSeq: number = -1
  private irLearnExpectedAction: string = ''
  private irLearnExpectedIndex: number = 0
  private irLearnHandshakeConfirmed: boolean = false
  @State showIrLearnPanel: boolean = false
  @State irLearnActive: boolean = false
  @State irLearnBusy: boolean = false
  @State irLearnStep: number = 0
  @State irLearnCompletedCount: number = 0
  @State irLearnResults: number[] = [0, 0, 0, 0, 0, 0]
  @State irLearnStatus: string = '只需一个遥控器，就可以学习控制你的任何品牌空调'

  aboutToAppear(): void {
    try {
      this.getUIContext().getFont().registerFont({
        familyName: 'YouSheTitle',
        familySrc: $rawfile('fonts/youshe_title.ttf')
      })
    } catch (err) {
      console.info(`[UI][font-register-fail] ${(err as Error).message}`)
    }
    this.refreshClock()
    this.setupVoiceAssistant()
    this.startUdpReceiver()
    this.setupMqtt()
    this.setupBridgeTls()
    this.loadStoredFaceUsers()
    this.loadStoredSpeakerProfiles()
    this.resetCommunicationModesOnStartup()
    this.restoreActiveDeviceFromRegistry()
    this.restoreDynamicCryptoKeys()
    this.refreshProvisioningDefaults()
    this.refreshProvisioningWifiInfo()
    const gatewayStart = this.localGateway.start(3000, (event: LocalGatewayEvent): void => {
      this.handleLocalGatewayEvent(event)
    })
    console.info(`[LocalGateway] start ok=${gatewayStart.ok} port=${gatewayStart.port} ${gatewayStart.message}`)
    this.setupLocalMqtt()
    setTimeout(() => {
      this.connectLocalMqtt()
    }, 500)

    // 自测加密模块
    selfTest().then((result: string) => {
      console.info(`[Crypto:selftest] ${result}`)
    })
    this.timerId = setInterval(() => {
      this.refreshClock()
    }, 60000)
    setTimeout(() => {
      this.refreshOutdoorWeather()
    }, 1000)
    this.weatherTimerId = setInterval(() => {
      this.refreshOutdoorWeather()
    }, OUTDOOR_WEATHER_REFRESH_MS)
    this.refreshActiveProtocol()
    // 只轮询当前业务协议；默认 MQTT 时不访问 HTTP /api/state。
    this.pollTimerId = setInterval(() => {
      this.refreshActiveProtocol()
    }, 3000)
    if (CLOUD_SYNC_ENABLED) {
      this.reportCloudHeartbeat()
      this.cloudHeartbeatTimerId = setInterval(() => {
        this.reportCloudHeartbeat()
      }, 30000)
      this.pollCloudCommand()
      this.cloudCommandPollTimerId = setInterval(() => {
        this.pollCloudCommand()
      }, 2500)
    } else {
      console.info('[Cloud] sync disabled for local broker control')
    }
  }

  aboutToDisappear(): void {
    if (this.overviewDoorTapTimerId !== -1) {
      clearTimeout(this.overviewDoorTapTimerId)
      this.overviewDoorTapTimerId = -1
    }
    if (this.timerId !== -1) {
      clearInterval(this.timerId)
    }
    if (this.pollTimerId !== -1) {
      clearInterval(this.pollTimerId)
    }
    if (this.weatherTimerId !== -1) {
      clearInterval(this.weatherTimerId)
      this.weatherTimerId = -1
    }
    if (this.cloudHeartbeatTimerId !== -1) {
      clearInterval(this.cloudHeartbeatTimerId)
      this.cloudHeartbeatTimerId = -1
    }
    if (this.cloudCommandPollTimerId !== -1) {
      clearInterval(this.cloudCommandPollTimerId)
      this.cloudCommandPollTimerId = -1
    }
    if (this.cloudAlarmRetryTimerId !== -1) {
      clearTimeout(this.cloudAlarmRetryTimerId)
      this.cloudAlarmRetryTimerId = -1
    }
    if (this.cloudActuatorRetryTimerId !== -1) {
      clearTimeout(this.cloudActuatorRetryTimerId)
      this.cloudActuatorRetryTimerId = -1
    }
    this.cloudMqttTransport.disconnect().catch((err: Error) => {
      console.info(`[CloudMQTT][disconnect-fail] ${err.message}`)
    })
    this.stopProvisioningEnterLoop()
    this.clearIrLearnTimer()
    this.provisioningPort.close().catch((err: Error) => {
      console.info(`[Provisioning][close-fail] ${err.message}`)
    })
    if (this.cryptoSwitchTimerId !== -1) {
      clearTimeout(this.cryptoSwitchTimerId)
      this.cryptoSwitchTimerId = -1
    }
    if (this.protocolSwitchTimerId !== -1) {
      clearTimeout(this.protocolSwitchTimerId)
      this.protocolSwitchTimerId = -1
    }
    this.clearAlarmAckTimer()
    this.stopUdpReceiver()
    this.mqtt.disconnect()
    this.localMqtt.disconnect()
    this.bridgeTls.disconnect()
    this.faceAccess.stopPreview().catch((err: Error) => {
      console.info(`[FaceAccess][stop-fail] ${err.message}`)
    })
    this.voiceAssistant.release().catch((err: Error) => {
      console.info(`[VoiceAssistant][release-fail] ${err.message}`)
    })
  }

  setupVoiceAssistant(): void {
    this.voiceAssistant.setSpeakerProfileManager(this.speakerProfiles)
    this.voiceAssistant.setCallbacks({
      onState: (state: VoiceAssistantState, detail: string, transcript: string): void => {
        this.voiceAssistantStatus = this.voiceAssistantStateText(state)
        this.voiceAssistantDetail = detail
        this.voiceAssistantTranscript = transcript
        this.voiceAssistantActive = state === VoiceAssistantState.WAITING_WAKE ||
          state === VoiceAssistantState.WAKE_DETECTED ||
          state === VoiceAssistantState.LISTENING_COMMAND ||
          state === VoiceAssistantState.RECOGNIZING ||
          state === VoiceAssistantState.EXECUTING ||
          state === VoiceAssistantState.VOICEPRINT_ENROLLING
        this.voiceAssistantError = state === VoiceAssistantState.ERROR
      },
      onLevel: (level: number): void => {
        const next = this.voiceWaveform.slice(1)
        next.push(Math.max(0.04, level))
        this.voiceWaveform = next
      },
      onExecuteIntent: async (intent: VoiceIntent): Promise<VoiceExecutionResult> => {
        return await this.executeVoiceIntent(intent)
      },
      onVoiceprintModel: (ready: boolean, dimension: number, message: string): void => {
        this.voiceprintModelReady = ready
        this.voiceprintModelDimension = dimension
        this.voiceprintStatus = ready ?
          (this.voiceprintUsers.length > 0 ? `已授权 ${this.voiceprintUsers.length} 位用户` : '可以开始录入授权用户') :
          '声纹功能暂不可用'
        if (!ready) {
          console.info(`[Voiceprint][model-unavailable] ${message}`)
        }
      },
      onVoiceprintResult: (matched: boolean, userName: string, score: number): void => {
        this.voiceprintStatus = matched ?
          `刚刚确认：${userName} · ${score.toFixed(2)}` :
          `刚刚拒绝未授权声音 · ${Math.max(0, score).toFixed(2)}`
      }
    })
    setTimeout(() => {
      const context = getContext(this)
      this.voiceAssistant.start(context).catch((err: Error) => {
        console.info(`[VoiceAssistant][start-fail] ${err.message}`)
      })
    }, 500)
  }

  async restartVoiceAssistant(): Promise<void> {
    this.voiceAssistantError = false
    this.voiceAssistantStatus = '正在重新启动'
    try {
      const context = getContext(this)
      await this.voiceAssistant.restart(context)
    } catch (err) {
      console.info(`[VoiceAssistant][restart-fail] ${(err as Error).message}`)
    }
  }

  voiceAssistantStateText(state: VoiceAssistantState): string {
    if (state === VoiceAssistantState.INITIALIZING) {
      return '正在初始化'
    }
    if (state === VoiceAssistantState.WAITING_WAKE) {
      return '待唤醒'
    }
    if (state === VoiceAssistantState.WAKE_DETECTED) {
      return '我在'
    }
    if (state === VoiceAssistantState.LISTENING_COMMAND) {
      return '我在听'
    }
    if (state === VoiceAssistantState.RECOGNIZING) {
      return '识别中'
    }
    if (state === VoiceAssistantState.EXECUTING) {
      return '正在执行'
    }
    if (state === VoiceAssistantState.SUCCEEDED) {
      return '已执行'
    }
    if (state === VoiceAssistantState.FAILED) {
      return '执行失败'
    }
    if (state === VoiceAssistantState.ERROR) {
      return '助手异常'
    }
    if (state === VoiceAssistantState.VOICEPRINT_ENROLLING) {
      return '采集声纹'
    }
    return '已停止'
  }

  async loadStoredSpeakerProfiles(): Promise<void> {
    try {
      const context = getContext(this)
      const count = await this.speakerProfiles.load(context)
      this.voiceprintUsers = this.speakerProfiles.listUsers()
      this.voiceprintProtectionEnabled = this.speakerProfiles.isProtectionEnabled()
      if (count > 0) {
        this.voiceprintStatus = `已加载 ${count} 位本地声纹用户`
      }
    } catch (err) {
      this.voiceprintStatus = `声纹用户读取失败: ${(err as Error).message}`
    }
  }

  async setVoiceprintProtection(enabled: boolean): Promise<void> {
    if (enabled && this.speakerProfiles.getEnabledUserCount() === 0) {
      this.voiceprintProtectionEnabled = false
      this.voiceprintStatus = '请先录入至少一位授权用户'
      return
    }
    this.speakerProfiles.setProtectionEnabled(enabled)
    this.voiceprintProtectionEnabled = this.speakerProfiles.isProtectionEnabled()
    await this.speakerProfiles.save(getContext(this)).catch((err: Error) => {
      this.voiceprintStatus = `保存失败: ${err.message}`
    })
    if (this.voiceprintStatus.indexOf('失败') < 0) {
      this.voiceprintStatus = enabled ? '声纹保护已开启' : '声纹保护已关闭'
    }
  }

  openVoiceprintManager(): void {
    this.voiceprintEnrollmentSamples = []
    this.voiceprintEnrollProgress = 0
    this.voiceprintEnrollBusy = false
    this.showVoiceprintPanel = true
  }

  closeVoiceprintManager(): void {
    if (this.voiceprintEnrollBusy) {
      this.voiceAssistant.cancelVoiceprintSample()
    }
    this.voiceprintEnrollBusy = false
    this.showVoiceprintPanel = false
  }

  async captureVoiceprintRound(): Promise<void> {
    if (this.voiceprintEnrollBusy) {
      return
    }
    if (!this.voiceprintModelReady) {
      this.voiceprintStatus = '声纹识别正在准备，请稍后再试'
      return
    }
    if (this.voiceprintEnrollName.trim().length === 0) {
      this.voiceprintStatus = '请先填写姓名或昵称'
      return
    }
    if (this.voiceprintEnrollProgress >= 3) {
      this.voiceprintEnrollmentSamples = []
      this.voiceprintEnrollProgress = 0
    }
    this.voiceprintEnrollBusy = true
    const round = this.voiceprintEnrollProgress + 1
    this.voiceprintStatus = `第 ${round} 轮采集中 · 请连续说约 4 秒`
    try {
      const embedding = await this.voiceAssistant.captureVoiceprintSample()
      this.voiceprintEnrollmentSamples.push(embedding)
      this.voiceprintEnrollProgress = this.voiceprintEnrollmentSamples.length
      if (this.voiceprintEnrollProgress < 3) {
        this.voiceprintStatus = `第 ${round} 轮完成，请继续下一轮`
        return
      }
      const quality: SpeakerEnrollmentQuality = this.speakerProfiles.evaluateEnrollment(this.voiceprintEnrollmentSamples)
      if (!quality.valid) {
        this.voiceprintEnrollmentSamples = []
        this.voiceprintEnrollProgress = 0
        this.voiceprintStatus = `${quality.message} · 一致度 ${Math.max(0, quality.averageSimilarity).toFixed(2)}`
        return
      }
      const user = this.speakerProfiles.addUser(this.voiceprintEnrollName, this.voiceprintEnrollmentSamples)
      await this.speakerProfiles.save(getContext(this))
      this.voiceprintUsers = this.speakerProfiles.listUsers()
      this.voiceprintProtectionEnabled = this.speakerProfiles.isProtectionEnabled()
      this.voiceprintStatus = `${user.name} 录入完成 · 三轮一致度 ${quality.averageSimilarity.toFixed(2)}`
      this.voiceprintEnrollName = ''
    } catch (err) {
      this.voiceprintStatus = (err as Error).message
    } finally {
      this.voiceprintEnrollBusy = false
    }
  }

  async deleteVoiceprintUser(userId: string): Promise<void> {
    this.speakerProfiles.deleteUser(userId)
    await this.speakerProfiles.save(getContext(this)).catch((err: Error) => {
      this.voiceprintStatus = `删除保存失败: ${err.message}`
    })
    this.voiceprintUsers = this.speakerProfiles.listUsers()
    this.voiceprintProtectionEnabled = this.speakerProfiles.isProtectionEnabled()
    if (this.voiceprintUsers.length === 0) {
      this.voiceprintStatus = '尚未录入授权声纹'
    }
  }

  async setVoiceprintUserEnabled(userId: string, enabled: boolean): Promise<void> {
    this.speakerProfiles.setUserEnabled(userId, enabled)
    await this.speakerProfiles.save(getContext(this)).catch((err: Error) => {
      this.voiceprintStatus = `保存失败: ${err.message}`
    })
    this.voiceprintUsers = this.speakerProfiles.listUsers()
    this.voiceprintProtectionEnabled = this.speakerProfiles.isProtectionEnabled()
  }

  async loadStoredFaceUsers(): Promise<void> {
    try {
      const context = getContext(this)
      const count = await this.faceAccess.loadUsers(context)
      this.faceUsers = this.faceAccess.listUsers()
      if (count > 0) {
        this.faceAccessStatus = `已加载 ${count} 位本地授权用户`
      }
    } catch (err) {
      this.faceAccessStatus = `加载人脸模板失败: ${(err as Error).message}`
    }
  }

  normalizeBridgeUrl(value: string): string {
    const input = value.trim()
    if (input.length === 0) {
      return DEFAULT_BRIDGE_URL
    }
    const bridgeUrl = input.startsWith('http://') || input.startsWith('https://') ? input : `http://${input}`
    const protocolEnd = bridgeUrl.indexOf('://')
    const address = protocolEnd >= 0 ? bridgeUrl.substring(protocolEnd + 3) : bridgeUrl
    if (address.indexOf(':') < 0) {
      return `${bridgeUrl}:3000`
    }
    return bridgeUrl
  }

  handleLocalGatewayEvent(event: LocalGatewayEvent): void {
    if (event.type !== 'http_sensor' || event.body.length === 0) {
      return
    }
    try {
      const message = JSON.parse(event.body) as Record<string, Object>
      const payloadBase64 = message['payloadBase64'] as string
      const topic = message['topic'] as string
      const rawDeviceId = message['deviceId'] as string
      if (typeof payloadBase64 !== 'string' || payloadBase64.length === 0 ||
        typeof topic !== 'string' || topic.length === 0) {
        console.info('[LocalGateway][HTTP] ignored incomplete sensor packet')
        return
      }
      const deviceId = typeof rawDeviceId === 'string' ? this.normalizeDeviceId(rawDeviceId) :
        this.deviceIdFromScopedTopic(topic)
      this.localGatewayDeviceIds.add(deviceId)
      this.localGatewayTransportByDevice.set(deviceId, 'HTTP')
      this.registerDeviceId(deviceId)
      this.observeDeviceTransport(deviceId, 'HTTP_SENSOR')
      const raw = this.base64ToUint8Array(payloadBase64)
      if (this.keyExchange.isKeyExchangeTopic(topic)) {
        this.handleEcdhPublicKey(topic, raw, event.timestamp)
        return
      }
      if (looksEncrypted(raw)) {
        this.handleEncryptedPayload(payloadBase64, 'HTTP_SENSOR', topic, deviceId, true)
        return
      }
      const text = new util.TextDecoder().decodeWithStream(raw)
      this.addMqttMessage(topic, text)
      if (!this.handleDeviceStatusJson(text, deviceId)) {
        this.applySensorJson(text, 'HTTP_SENSOR', deviceId)
      }
    } catch (err) {
      console.info(`[LocalGateway][HTTP] invalid JSON ${(err as Error).message}`)
    }
  }

  resetCommunicationModesOnStartup(): void {
    this.commandTransport = 'MQTT'
    this.protocolPendingMode = ''
    this.cryptoPendingMode = ''
    this.cryptoMode = 'SM4'
    setCryptoMode('SM4')

    const registry = this.loadDeviceRegistry()
    Object.keys(registry).forEach((deviceId: string) => {
      registry[deviceId].transport = 'mqtt'
      registry[deviceId].crypto = 'sm4'
    })
    if (Object.keys(registry).length > 0) {
      this.deviceRegistryJson = JSON.stringify(registry)
    }
    this.cryptoDebugText = '启动默认 MQTT + SM4'
    console.info('[PROTO][startup-reset] all devices reset to MQTT + SM4')
  }

  normalizeDeviceId(deviceId: string): string {
    const normalized = deviceId.trim()
    return normalized.length > 0 ? normalized : 'esp32'
  }

  restoreActiveDeviceFromRegistry(): void {
    const registry = this.loadDeviceRegistry()
    const registeredIds = Object.keys(registry)
    registeredIds.forEach((deviceId: string) => {
      this.registerDeviceId(deviceId)
    })
    if (registeredIds.length === 0) {
      return
    }
    if (registry[this.activeDeviceId] === undefined) {
      this.activeDeviceId = registeredIds[0]
      console.info(`[DEVICE] restored active=${this.activeDeviceId}`)
    }
    this.syncActiveDeviceModes(this.activeDeviceId)
  }

  registerDeviceId(deviceId: string): string {
    const normalized = this.normalizeDeviceId(deviceId)
    if (this.knownDeviceIds.indexOf(normalized) < 0) {
      this.knownDeviceIds = this.knownDeviceIds.concat([normalized])
      console.info(`[DEVICE] discovered ${normalized}`)
    }
    return normalized
  }

  selectActiveDevice(deviceId: string): void {
    const normalized = this.registerDeviceId(deviceId)
    if (normalized === this.activeDeviceId) {
      this.syncActiveDeviceModes(normalized)
      return
    }
    this.activeDeviceId = normalized
    const aesKey = getDeviceDynamicAesKey(normalized)
    const sm4Key = getDeviceDynamicSm4Key(normalized)
    if (aesKey !== null && sm4Key !== null) {
      setDynamicCryptoKeys(aesKey, sm4Key)
      this.deviceKeySource = 'dynamic'
      this.deviceEpoch = 1
    } else {
      clearDynamicCryptoKeys()
      this.deviceKeySource = 'static'
      this.deviceEpoch = 0
    }
    this.syncActiveDeviceModes(normalized)
    this.cryptoDebugText = `已选择设备 ${normalized}`
    console.info(`[DEVICE] active=${normalized} key=${this.deviceKeySource}`)
  }

  syncActiveDeviceModes(deviceId: string): void {
    if (deviceId !== this.activeDeviceId) {
      return
    }
    const descriptor = this.loadDeviceRegistry()[deviceId]
    if (!descriptor) {
      return
    }
    if (this.protocolPendingMode.length === 0 && descriptor.transport.length > 0) {
      this.commandTransport = this.normalizeProtocolMode(descriptor.transport.toUpperCase())
    }
    if (this.cryptoPendingMode.length === 0 && descriptor.crypto.length > 0) {
      this.applyCryptoMode(descriptor.crypto.toUpperCase())
    }
  }

  updateDeviceDescriptorModes(deviceId: string, transport: string = '', crypto: string = ''): void {
    const registry = this.loadDeviceRegistry()
    const descriptor = registry[deviceId]
    if (!descriptor) {
      return
    }
    if (transport.length > 0) {
      descriptor.transport = this.normalizeProtocolMode(transport.toUpperCase()).toLowerCase()
    }
    if (crypto.length > 0) {
      descriptor.crypto = this.normalizeCryptoMode(crypto.toUpperCase()).toLowerCase()
    }
    descriptor.lastSeen = Date.now()
    registry[deviceId] = descriptor
    this.deviceRegistryJson = JSON.stringify(registry)
  }

  selectNextActiveDevice(): void {
    const registeredIds = Object.keys(this.loadDeviceRegistry())
    const candidates = registeredIds.length > 0 ? registeredIds : this.knownDeviceIds
    if (candidates.length <= 1) {
      this.cryptoDebugText = `当前仅发现 ${this.activeDeviceId}`
      return
    }
    const current = candidates.indexOf(this.activeDeviceId)
    this.selectActiveDevice(candidates[(current + 1) % candidates.length])
  }

  deviceIdFromScopedTopic(topic: string): string {
    if (topic.startsWith('device/')) {
      const parts = topic.split('/')
      return parts.length >= 3 ? this.normalizeDeviceId(parts[1]) : this.activeDeviceId
    }
    if (topic.startsWith('key/ecdh/pub/')) {
      return this.normalizeDeviceId(topic.substring('key/ecdh/pub/'.length))
    }
    return this.activeDeviceId
  }

  commandTopicForDevice(topic: string, deviceId: string): string {
    if (topic.startsWith('key/ecdh/pub/')) {
      return topic
    }
    return deviceId === 'esp32' ? 'dayu/cmd' : `dayu/cmd/${deviceId}`
  }

  deviceForCapability(capability: string): string {
    const binding = capability === 'light' ? this.lightDeviceId :
      capability === 'ac' ? this.acDeviceId :
        capability === 'curtain' ? this.curtainDeviceId :
          capability === 'door' ? this.doorDeviceId : 'auto'
    if (binding !== 'auto' && binding.length > 0) {
      return binding
    }
    const registry = this.loadDeviceRegistry()
    const capableDeviceIds = Object.keys(registry).filter((deviceId: string) =>
      registry[deviceId].capabilities.indexOf(capability) >= 0)
    if (capableDeviceIds.length > 0) {
      return capableDeviceIds[0]
    }
    // The current curtain motor is hosted by the AC controller. Until a
    // dedicated curtain binding is selected, keep both controls on that board.
    if (capability === 'curtain' && this.acDeviceId !== 'auto' && this.acDeviceId.length > 0) {
      return this.acDeviceId
    }
    return this.activeDeviceId
  }

  transportRouteForDevice(deviceId: string): string {
    return this.localGatewayTransportByDevice.get(deviceId) ?? this.transportForDevice(deviceId)
  }

  deviceBindingLabel(capability: string): string {
    const deviceId = this.deviceForCapability(capability)
    const registry = this.loadDeviceRegistry()
    const descriptor = registry[deviceId]
    if (descriptor && descriptor.capabilities.indexOf(capability) < 0) {
      return '未发现对应设备'
    }
    if (!descriptor && deviceId === 'esp32' && Object.keys(registry).length > 0) {
      if (capability === 'light') {
        return '未发现照明设备'
      }
      if (capability === 'ac') {
        return '未发现空调设备'
      }
      if (capability === 'door') {
        return '未发现门锁设备'
      }
      return '未发现窗帘设备'
    }
    if (descriptor && descriptor.name.trim().length > 0 && descriptor.name !== deviceId) {
      return descriptor.name.trim()
    }
    if (deviceId === 'esp32') {
      return '兼容设备'
    }
    return deviceId.length > 8 ? `...${deviceId.substring(deviceId.length - 6)}` : deviceId
  }

  deviceBindingIdHint(capability: string): string {
    const deviceId = this.deviceForCapability(capability)
    const registry = this.loadDeviceRegistry()
    const descriptor = registry[deviceId]
    if ((descriptor && descriptor.capabilities.indexOf(capability) < 0) ||
      (!descriptor && deviceId === 'esp32' && Object.keys(registry).length > 0)) {
      return '等待上线'
    }
    if (deviceId === 'esp32') {
      return '兼容模式'
    }
    return deviceId.length > 6 ? deviceId.substring(deviceId.length - 6) : deviceId
  }

  deviceIdDisplayText(deviceId: string): string {
    if (deviceId === 'esp32') {
      return '兼容设备'
    }
    const normalized = deviceId.toLowerCase().startsWith('esp32-') ? deviceId.substring(6) : deviceId
    return `设备编号 ${normalized}`
  }

  userFacingDeviceText(value: string): string {
    return value.split('ESP32').join('设备').split('esp32').join('设备')
  }

  registeredDeviceCount(): number {
    const count = Object.keys(this.loadDeviceRegistry()).length
    return count > 0 ? count : this.knownDeviceIds.length
  }

  bindingNeedsCapabilityDevice(binding: string, capability: string,
    registry: Record<string, DeviceDescriptor>): boolean {
    if (binding.length === 0 || binding === 'auto') {
      return true
    }
    const descriptor = registry[binding]
    return descriptor === undefined || descriptor.capabilities.indexOf(capability) < 0
  }

  activeDeviceName(): string {
    const descriptor = this.loadDeviceRegistry()[this.activeDeviceId]
    if (descriptor && descriptor.name.trim().length > 0 && descriptor.name !== this.activeDeviceId) {
      return descriptor.name.trim()
    }
    return this.activeDeviceId === 'esp32' ? '兼容设备' : '智能设备'
  }

  activeDeviceIdHint(): string {
    if (this.activeDeviceId === 'esp32') {
      return '兼容模式'
    }
    return this.activeDeviceId.length > 6 ?
      this.activeDeviceId.substring(this.activeDeviceId.length - 6) : this.activeDeviceId
  }

  activeDeviceCapabilitiesText(): string {
    const descriptor = this.loadDeviceRegistry()[this.activeDeviceId]
    return descriptor && descriptor.capabilities.length > 0 ? descriptor.capabilities.join(', ') : '未声明能力'
  }

  activeDeviceBindingsText(): string {
    const bindings: string[] = []
    if (this.deviceForCapability('light') === this.activeDeviceId) {
      bindings.push('照明')
    }
    if (this.deviceForCapability('ac') === this.activeDeviceId) {
      bindings.push('空调')
    }
    if (this.deviceForCapability('curtain') === this.activeDeviceId) {
      bindings.push('窗帘')
    }
    if (this.deviceForCapability('door') === this.activeDeviceId) {
      bindings.push('门锁')
    }
    return bindings.length > 0 ? bindings.join(' / ') : '未绑定控制卡片'
  }

  activeDeviceKeyText(): string {
    const hasAes = getDeviceDynamicAesKey(this.activeDeviceId) !== null
    const hasSm4 = getDeviceDynamicSm4Key(this.activeDeviceId) !== null
    if (hasAes && hasSm4) {
      return 'ECDH 动态密钥已加载'
    }
    if (hasAes || hasSm4) {
      return '动态密钥不完整'
    }
    return '静态密钥 / 等待 ECDH'
  }

  activeDeviceLastSeenText(): string {
    const descriptor = this.loadDeviceRegistry()[this.activeDeviceId]
    return descriptor && descriptor.lastSeen > 0 ? new Date(descriptor.lastSeen).toLocaleTimeString() : '暂无上线记录'
  }

  transportForDevice(deviceId: string): string {
    const descriptor = this.loadDeviceRegistry()[deviceId]
    return descriptor && descriptor.transport.length > 0 ?
      this.normalizeProtocolMode(descriptor.transport.toUpperCase()) : this.commandTransport
  }

  cryptoModeForDevice(deviceId: string): string {
    const descriptor = this.loadDeviceRegistry()[deviceId]
    return descriptor && descriptor.crypto.length > 0 ?
      this.normalizeCryptoMode(descriptor.crypto.toUpperCase()) : this.normalizeCryptoMode(currentCryptoMode())
  }

  loadDeviceRegistry(): Record<string, DeviceDescriptor> {
    if (this.deviceRegistryJson.length === 0) {
      return {}
    }
    try {
      return JSON.parse(this.deviceRegistryJson) as Record<string, DeviceDescriptor>
    } catch (_) {
      return {}
    }
  }

  registerDeviceHello(jsonStr: string, sourceDeviceId: string): boolean {
    try {
      const data = JSON.parse(jsonStr) as Record<string, Object>
      const rawType = data['type'] as string
      if (typeof rawType !== 'string' || rawType.toLowerCase() !== 'device_hello') {
        return false
      }
      const announcedId = this.normalizeDeviceId((data['deviceId'] as string) ?? sourceDeviceId)
      if (announcedId !== sourceDeviceId) {
        console.info(`[DEVICE][hello-reject] source=${sourceDeviceId} announced=${announcedId}`)
        return true
      }
      const rawCapabilities = data['capabilities'] as Object[]
      const capabilities: string[] = []
      if (Array.isArray(rawCapabilities)) {
        rawCapabilities.forEach((item: Object) => {
          if (typeof item === 'string' && capabilities.indexOf((item as string).toLowerCase()) < 0) {
            capabilities.push((item as string).toLowerCase())
          }
        })
      }
      const existingDescriptor = this.loadDeviceRegistry()[announcedId]
      // device_hello reports the device's observation, but must not overwrite
      // the transport/crypto mode selected and persisted by Dayu.
      const configuredTransport = existingDescriptor && existingDescriptor.transport.length > 0 ?
        this.normalizeProtocolMode(existingDescriptor.transport.toUpperCase()) : 'MQTT'
      const configuredCrypto = existingDescriptor && existingDescriptor.crypto.length > 0 ?
        this.normalizeCryptoMode(existingDescriptor.crypto.toUpperCase()) : 'SM4'
      const reportedTransport = typeof data['transport'] === 'string' ? data['transport'] as string : ''
      const reportedCrypto = typeof data['crypto'] === 'string' ? data['crypto'] as string : ''
      const descriptor: DeviceDescriptor = {
        deviceId: announcedId,
        name: typeof data['name'] === 'string' ? data['name'] as string : announcedId,
        room: typeof data['room'] === 'string' ? data['room'] as string : '',
        capabilities,
        transport: configuredTransport.toLowerCase(),
        crypto: configuredCrypto.toLowerCase(),
        lastSeen: Date.now()
      }
      const registry = this.loadDeviceRegistry()
      registry[announcedId] = descriptor
      this.deviceRegistryJson = JSON.stringify(registry)
      this.registerDeviceId(announcedId)
      if (registry[this.activeDeviceId] === undefined && announcedId !== 'esp32') {
        this.selectActiveDevice(announcedId)
      } else {
        this.syncActiveDeviceModes(announcedId)
      }
      if (capabilities.indexOf('light') >= 0 &&
        this.bindingNeedsCapabilityDevice(this.lightDeviceId, 'light', registry)) {
        this.lightDeviceId = announcedId
      }
      if ((capabilities.indexOf('ac') >= 0 || capabilities.indexOf('ir_learning') >= 0) &&
        this.bindingNeedsCapabilityDevice(this.acDeviceId, 'ac', registry)) {
        this.acDeviceId = announcedId
      }
      if (capabilities.indexOf('curtain') >= 0 &&
        this.bindingNeedsCapabilityDevice(this.curtainDeviceId, 'curtain', registry)) {
        this.curtainDeviceId = announcedId
      }
      if (capabilities.indexOf('door') >= 0 &&
        this.bindingNeedsCapabilityDevice(this.doorDeviceId, 'door', registry)) {
        this.doorDeviceId = announcedId
      }
      this.cryptoDebugText = `设备注册 ${descriptor.name}: ${capabilities.join(',')}`
      console.info(`[DEVICE][hello] id=${announcedId} caps=${capabilities.join(',')} configured=${descriptor.transport}/${descriptor.crypto} reported=${reportedTransport}/${reportedCrypto}`)
      return true
    } catch (_) {
      return false
    }
  }

  devicesForCapability(capability: string): string[] {
    const matches: string[] = []
    const registry = this.loadDeviceRegistry()
    Object.keys(registry).forEach((deviceId: string) => {
      if (registry[deviceId].capabilities.indexOf(capability) >= 0) {
        matches.push(deviceId)
      }
    })
    return matches.length > 0 ? matches : this.knownDeviceIds
  }

  deviceBindingIds(): string[] {
    const registeredIds = Object.keys(this.loadDeviceRegistry())
    return registeredIds.length > 0 ? registeredIds : this.knownDeviceIds
  }

  deviceBindingNameForId(deviceId: string): string {
    const descriptor = this.loadDeviceRegistry()[deviceId]
    if (descriptor && descriptor.name.trim().length > 0 && descriptor.name !== deviceId) {
      return descriptor.name.trim()
    }
    return deviceId === 'esp32' ? '兼容设备' : '智能设备'
  }

  deviceBindingCapabilitiesForId(deviceId: string): string {
    const descriptor = this.loadDeviceRegistry()[deviceId]
    if (!descriptor || descriptor.capabilities.length === 0) {
      return deviceId === 'esp32' ? '兼容模式 · 能力未声明' : '能力未声明'
    }
    const labels: string[] = []
    descriptor.capabilities.forEach((capability: string) => {
      if (capability === 'light') {
        labels.push('照明')
      } else if (capability === 'ac') {
        labels.push('空调')
      } else if (capability === 'ir_learning') {
        labels.push('红外学习')
      } else if (capability === 'alarm') {
        labels.push('报警')
      } else if (capability === 'sensor') {
        labels.push('传感器')
      } else if (capability === 'curtain') {
        labels.push('窗帘')
      } else if (capability === 'door') {
        labels.push('门锁')
      } else {
        labels.push(capability)
      }
    })
    return labels.join(' · ')
  }

  deviceCanBindCapability(deviceId: string, capability: string): boolean {
    const descriptor = this.loadDeviceRegistry()[deviceId]
    if (!descriptor) {
      return deviceId === 'esp32'
    }
    if (capability === 'ac') {
      return descriptor.capabilities.indexOf('ac') >= 0 || descriptor.capabilities.indexOf('ir_learning') >= 0
    }
    return descriptor.capabilities.indexOf(capability) >= 0
  }

  bindingControlCapabilities(): string[] {
    return ['light', 'ac', 'curtain', 'door']
  }

  bindingCapabilityLabel(capability: string): string {
    if (capability === 'light') {
      return '照明'
    }
    if (capability === 'ac') {
      return '空调'
    }
    if (capability === 'curtain') {
      return '窗帘'
    }
    if (capability === 'door') {
      return '门锁'
    }
    return capability
  }

  bindCapabilityDevice(capability: string, deviceId: string): void {
    if (!this.deviceCanBindCapability(deviceId, capability)) {
      return
    }
    if (capability === 'light') {
      this.lightDeviceId = deviceId
    } else if (capability === 'ac') {
      this.acDeviceId = deviceId
    } else if (capability === 'curtain') {
      this.curtainDeviceId = deviceId
    } else if (capability === 'door') {
      this.doorDeviceId = deviceId
    }
    this.cryptoDebugText = `${this.bindingCapabilityLabel(capability)}已绑定 ${deviceId}`
  }

  cycleCapabilityDevice(capability: string): void {
    const candidates = this.devicesForCapability(capability)
    if (candidates.length === 0) {
      return
    }
    const current = capability === 'light' ? this.lightDeviceId :
      capability === 'ac' ? this.acDeviceId :
        capability === 'curtain' ? this.curtainDeviceId : this.doorDeviceId
    const currentIndex = candidates.indexOf(current)
    const next = candidates[(currentIndex + 1) % candidates.length]
    if (capability === 'light') {
      this.lightDeviceId = next
    } else if (capability === 'ac') {
      this.acDeviceId = next
    } else if (capability === 'curtain') {
      this.curtainDeviceId = next
    } else {
      this.doorDeviceId = next
    }
    this.cryptoDebugText = `${this.bindingCapabilityLabel(capability)}已绑定 ${next}`
  }

  async refreshBridge(): Promise<void> {
    if (this.bridgeStateRefreshInFlight) {
      console.info('[Bridge][state] skip overlapping refresh')
      return
    }
    this.bridgeStateRefreshInFlight = true
    const baseUrl = this.normalizeBridgeUrl(this.bridgeUrl)
    this.bridgeUrl = baseUrl
    try {
      const text = await this.httpRequest(`${baseUrl}/api/state`, http.RequestMethod.GET)
      const response: Record<string, Object> = JSON.parse(text) as Record<string, Object>
      const bridgeResp = response as BridgeResponsePacket
      this.bridgeStateFailCount = 0
      this.lastBridgeOkAt = Date.now()
      this.bridgeLastError = ''
      this.bridgeConnected = bridgeResp.ok === true
      this.bridgeLinkConnected = bridgeResp.ok === true || this.bridgeTlsConnected || this.mqttConnected
      this.bridgeLastMessage = (bridgeResp.message as string) ?? 'Bridge 已连接'

      const httpSensor = bridgeResp.httpSensor
      if (httpSensor?.enabled === true) {
        const packets = httpSensor.packets && httpSensor.packets.length > 0 ? httpSensor.packets : [httpSensor as HttpSensorBridgeItem]
        packets.sort((left: HttpSensorBridgeItem, right: HttpSensorBridgeItem) =>
          (left.timestamp ?? 0) - (right.timestamp ?? 0))
        for (let i = 0; i < packets.length; i++) {
          await this.handleHttpSensorBridgePacket(packets[i])
        }
      }

      if (bridgeResp.encrypted?.enabled === true &&
        bridgeResp.encrypted.payloadBase64 &&
        bridgeResp.encrypted.timestamp &&
        bridgeResp.encrypted.timestamp > this.lastEncryptedTimestamp &&
        (this.cryptoPendingMode.length === 0 || bridgeResp.encrypted.timestamp > this.cryptoSwitchEncryptedBaseline) &&
        (bridgeResp.encrypted.timestamp !== this.lastHttpSensorTimestamp || this.cryptoPendingMode.length > 0)) {
        this.lastEncryptedTimestamp = bridgeResp.encrypted.timestamp
        const cachedTopic = bridgeResp.encrypted.topic ?? 'esp32/sensor'
        if (this.keyExchange.isKeyExchangeTopic(cachedTopic)) {
          console.info(`[ECDH] HTTP cached public key topic=${cachedTopic}`)
          this.handleEcdhPublicKey(cachedTopic, this.base64ToUint8Array(bridgeResp.encrypted.payloadBase64), bridgeResp.encrypted.timestamp)
        } else if (this.cryptoPendingMode.length > 0 || this.shouldProcessBusinessSource('HTTP')) {
          this.cryptoDebugText = `HTTP加密包 ${bridgeResp.encrypted.payloadBase64.length}B64`
          this.handleEncryptedPayload(bridgeResp.encrypted.payloadBase64, 'HTTP', cachedTopic)
        } else {
          console.info(`[PROTO] ignore HTTP cached packet while active=${this.commandTransport} pending=${this.protocolPendingMode}`)
        }
      }

      const keyExchange = bridgeResp.keyExchange
      if (keyExchange?.pending === true && keyExchange.payloadBase64 && keyExchange.topic) {
        console.info(`[ECDH] HTTP pending public key topic=${keyExchange.topic}`)
        this.handleEcdhPublicKey(keyExchange.topic, this.base64ToUint8Array(keyExchange.payloadBase64), keyExchange.timestamp ?? Date.now())
      }
      if (keyExchange?.devices) {
        await this.handleCachedKeyExchangeDevices(keyExchange.devices)
      }

      if (this.shouldProcessBusinessSource('HTTP') && !this.hasLiveSensorData && bridgeResp.state?.sensor) {
        this.applySensorData(bridgeResp.state.sensor, 'HTTP_BOOT')
      }

      if (this.shouldProcessBusinessSource('HTTP') && bridgeResp.state?.light) {
        this.applyLightStatus(bridgeResp.state.light, 'HTTP_BOOT')
      }
    } catch (err) {
      console.info(`[Bridge][state][error] ${JSON.stringify(err)}`)
      this.bridgeLastError = `${baseUrl} ${(err as Error).message}`
      this.bridgeStateFailCount += 1
      const now = Date.now()
      if (this.bridgeTlsConnected || this.bridgeTls.isConnected() || this.mqttConnected) {
        this.bridgeConnected = true
        this.bridgeLinkConnected = true
        this.bridgeLastMessage = (this.bridgeTlsConnected || this.bridgeTls.isConnected()) ? 'BridgeTLS 已连接' : 'MQTT 已连接'
        return
      }
      if (this.bridgeStateFailCount >= 3 && now - this.lastBridgeOkAt > 10000) {
        this.bridgeConnected = false
        this.bridgeLinkConnected = false
        this.bridgeLastMessage = 'Bridge 连接失败'
      } else {
        this.bridgeLastMessage = `Bridge 状态重试 ${this.bridgeStateFailCount}/3`
      }
    } finally {
      this.bridgeStateRefreshInFlight = false
    }
  }

  async reconnectBridge(): Promise<void> {
    await this.refreshActiveProtocol()
  }

  async refreshActiveProtocol(): Promise<void> {
    if (this.shouldPollHttpBridge()) {
      await this.refreshBridge()
      return
    }
    if (this.mqttConnected) {
      this.bridgeConnected = true
      this.bridgeLinkConnected = true
      this.bridgeLastMessage = 'MQTT 已连接'
      return
    }
    if (this.bridgeTlsConnected || this.bridgeTls.isConnected()) {
      this.bridgeConnected = true
      this.bridgeLinkConnected = true
      this.bridgeLastMessage = 'BridgeTLS 已连接'
      return
    }
    await this.refreshBridgeKeyExchangeState()
    if (this.bridgeConnected && Date.now() - this.lastBridgeOkAt < 10000) {
      this.bridgeLinkConnected = true
      return
    }
    this.bridgeConnected = false
    this.bridgeLinkConnected = false
    this.bridgeLastMessage = 'MQTT 待连接'
  }

  shouldPollHttpBridge(): boolean {
    return this.commandTransport === 'HTTP' || this.protocolPendingMode === 'HTTP' || this.cryptoPendingMode.length > 0
  }

  async refreshBridgeKeyExchangeState(force: boolean = false): Promise<void> {
    const now = Date.now()
    if (!force && now - this.lastKeyExchangeHttpPollAt < KEY_EXCHANGE_HTTP_POLL_MIN_INTERVAL_MS) {
      return
    }
    this.lastKeyExchangeHttpPollAt = now
    const baseUrl = this.normalizeBridgeUrl(this.bridgeUrl)
    this.bridgeUrl = baseUrl
    try {
      const text = await this.httpRequest(`${baseUrl}/api/state`, http.RequestMethod.GET)
      const bridgeResp = JSON.parse(text) as BridgeResponsePacket
      if (bridgeResp.ok === true) {
        this.bridgeStateFailCount = 0
        this.lastBridgeOkAt = Date.now()
        this.bridgeLastError = ''
        this.bridgeConnected = true
        this.bridgeLinkConnected = true
        if (!this.mqttConnected && !this.bridgeTlsConnected && !this.bridgeTls.isConnected()) {
          this.bridgeLastMessage = (bridgeResp.message as string) ?? 'Bridge 已连接'
        }
      }
      const encrypted = bridgeResp.encrypted
      if (encrypted?.enabled === true && encrypted.payloadBase64 && encrypted.timestamp && encrypted.topic &&
        this.keyExchange.isKeyExchangeTopic(encrypted.topic)) {
        this.handleEcdhPublicKey(encrypted.topic, this.base64ToUint8Array(encrypted.payloadBase64), encrypted.timestamp)
      }
      const keyExchange = bridgeResp.keyExchange
      if (keyExchange?.pending === true && keyExchange.payloadBase64 && keyExchange.topic) {
        this.handleEcdhPublicKey(keyExchange.topic, this.base64ToUint8Array(keyExchange.payloadBase64), keyExchange.timestamp ?? Date.now())
      }
      if (keyExchange?.devices) {
        this.handleCachedKeyExchangeDevices(keyExchange.devices)
      }
    } catch (err) {
      this.bridgeLastError = `${baseUrl} ${(err as Error).message}`
      console.info(`[ECDH][state-skip] ${(err as Error).message}`)
    }
  }

  isBridgeActuallyConnected(): boolean {
    return this.localMqtt.isConnected() || this.bridgeLinkConnected || this.bridgeConnected ||
      this.bridgeTlsConnected || this.bridgeTls.isConnected() || this.mqttConnected
  }

  async handleHttpSensorBridgePacket(packet: HttpSensorBridgeItem): Promise<void> {
    if (!packet.payloadBase64 || !packet.timestamp) {
      return
    }
    const packetDeviceId = this.registerDeviceId(packet.deviceId ?? this.deviceIdFromScopedTopic(packet.topic ?? ''))
    if (packetDeviceId !== this.activeDeviceId) {
      console.info(`[DEVICE] process background HTTP packet from ${packetDeviceId}; active=${this.activeDeviceId}`)
    }
    const packetKey = this.httpSensorPacketKey(packet)
    if (this.processedHttpSensorPackets.has(packetKey)) {
      return
    }
    this.processedHttpSensorPackets.add(packetKey)
    if (this.processedHttpSensorPackets.size > 120) {
      const keys = Array.from(this.processedHttpSensorPackets)
      for (let i = 0; i < Math.min(30, keys.length); i++) {
        this.processedHttpSensorPackets.delete(keys[i])
      }
    }
    if (this.cryptoPendingMode.length > 0 && packet.timestamp <= this.cryptoSwitchHttpSensorBaseline) {
      console.info(`[Crypto][switch][skip-stale-http] ts=${packet.timestamp} baseline=${this.cryptoSwitchHttpSensorBaseline}`)
      return
    }
    this.lastHttpSensorTimestamp = Math.max(this.lastHttpSensorTimestamp, packet.timestamp)
    const httpTopic = packet.topic ?? 'esp32/sensor'
    const isStatusTopic = httpTopic === 'esp32/status' || httpTopic.endsWith('/status')
    if (isStatusTopic || this.cryptoPendingMode.length > 0 ||
      this.transportForDevice(packetDeviceId) === 'HTTP' || this.shouldProcessBusinessSource('HTTP_SENSOR')) {
      const deviceText = packet.deviceId ?? this.deviceIdFromTopic(httpTopic)
      const cryptoText = packet.crypto ?? currentCryptoMode()
      this.cryptoDebugText = `HTTP_SENSOR ${deviceText}/${cryptoText} ${packet.payloadBase64.length}B64`
      if (this.keyExchange.isKeyExchangeTopic(httpTopic)) {
        await this.handleEcdhPublicKey(httpTopic, this.base64ToUint8Array(packet.payloadBase64), packet.timestamp)
      } else {
        const isLivePacket = Date.now() - packet.timestamp <= HTTP_SENSOR_LIVE_RECOVERY_MAX_AGE_MS
        await this.handleEncryptedPayload(packet.payloadBase64, 'HTTP_SENSOR', httpTopic, packetDeviceId, isLivePacket)
      }
    } else {
      console.info(`[PROTO] ignore HTTP_SENSOR while active=${this.commandTransport} pending=${this.protocolPendingMode}`)
    }
  }

  httpSensorPacketKey(packet: HttpSensorBridgeItem): string {
    const timestamp = packet.timestamp ?? 0
    const topic = packet.topic ?? ''
    const payload = packet.payloadBase64 ?? ''
    return `${packet.deviceId ?? ''}|${timestamp}|${topic}|${payload.length}|${payload.substring(0, 48)}`
  }

  async tryActivateInactiveDeviceKey(raw: Uint8Array, source: string, deviceId: string): Promise<void> {
    try {
      const decrypted = await this.tryDecryptPendingKeyAck(raw, source, deviceId)
      if (decrypted !== null) {
        console.info(`[ECDH] activated background device ${deviceId}`)
      }
    } catch (err) {
      console.info(`[ECDH] background ACK pending ${deviceId}: ${(err as Error).message}`)
    }
  }

  async selectCryptoMode(mode: string): Promise<void> {
    if (mode === this.cryptoMode) {
      this.cryptoDebugText = `当前已是 ${mode}-GCM`
      return
    }
    if (this.cryptoPendingMode.length > 0) {
      this.cryptoDebugText = `正在切换到 ${this.cryptoPendingMode}-GCM`
      return
    }
    await this.requestCryptoModeSwitch(mode)
  }

  normalizeCryptoMode(mode: string): string {
    return mode === 'AES' ? 'AES' : 'SM4'
  }

  normalizeProtocolMode(mode: string): string {
    return mode === 'HTTP' ? 'HTTP' : 'MQTT'
  }

  protocolAckAllowed(source: string): boolean {
    const normalizedSource = this.protocolFromSource(source)
    return this.protocolPendingMode.length > 0 && normalizedSource === this.protocolPendingMode
  }

  shouldProcessBusinessSource(source: string): boolean {
    const normalizedSource = this.protocolFromSource(source)
    if (this.protocolAckAllowed(source)) {
      return true
    }
    return this.protocolPendingMode.length === 0 && normalizedSource === this.commandTransport
  }

  protocolFromSource(source: string): string {
    if (source === 'HTTP' || source === 'HTTP_SENSOR' || source === 'HTTP_BOOT') {
      return 'HTTP'
    }
    return 'MQTT'
  }

  bridgePayloadSource(message: BridgeTlsJson): string {
    const transport = message['transport'] as string
    if (typeof transport === 'string') {
      return this.normalizeProtocolMode(transport.toUpperCase()) === 'HTTP' ? 'HTTP_SENSOR' : 'MQTT'
    }
    return 'BridgeTLS'
  }

  observeDeviceTransport(deviceId: string, source: string): void {
    if (source !== 'HTTP_SENSOR' && source !== 'MQTT') {
      return
    }
    const observed = this.protocolFromSource(source)
    if (deviceId !== this.activeDeviceId) {
      return
    }
    if (this.protocolPendingMode.length > 0) {
      if (observed === this.protocolPendingMode) {
        this.completeProtocolSwitch(observed, JSON.stringify({
          type: 'ack',
          cmd: 'proto',
          ok: true,
          val: observed.toLowerCase(),
          inferred: true,
          source,
          reason: 'broker-route'
        }))
      }
      return
    }
    // A device may keep the old transport alive briefly, or deliberately use
    // both transports for maintenance. Ordinary traffic therefore proves only
    // reachability; it must not overwrite a confirmed protocol selection.
  }

  resolvePayloadSource(source: string, jsonStr: string): string {
    if (source !== 'BridgeTLS') {
      return source
    }
    try {
      const data = JSON.parse(jsonStr) as Record<string, Object>
      let declaredProtocol = data['proto'] as string
      if (data['type'] === 'ack' && data['cmd'] === 'proto') {
        declaredProtocol = data['val'] as string
      }
      if (typeof declaredProtocol === 'string') {
        return this.normalizeProtocolMode(declaredProtocol.toUpperCase()) === 'HTTP' ? 'HTTP_SENSOR' : 'MQTT'
      }
    } catch (_) {
      // Older brokers omit transport metadata; non-protocol payloads keep the legacy source.
    }
    return source
  }

  otherCryptoMode(mode: string): string {
    return this.normalizeCryptoMode(mode) === 'AES' ? 'SM4' : 'AES'
  }

  applyCryptoMode(mode: string): void {
    const normalized = this.normalizeCryptoMode(mode)
    setCryptoMode(normalized)
    this.cryptoMode = normalized
  }

  restoreDynamicCryptoKeys(): void {
    if (this.deviceCryptoKeysJson.length > 0) {
      try {
        const registry = JSON.parse(this.deviceCryptoKeysJson) as Record<string, Object>
        Object.keys(registry).forEach((deviceId: string) => {
          const item = registry[deviceId] as Record<string, string>
          const aesKey = this.base64ToUint8Array(item['aes'] ?? '')
          const sm4Key = this.base64ToUint8Array(item['sm4'] ?? '')
          if (aesKey.length === 32 && sm4Key.length === 16) {
            setDeviceDynamicCryptoKeys(deviceId, aesKey, sm4Key)
            this.registerDeviceId(deviceId)
          }
        })
        const activeAes = getDeviceDynamicAesKey(this.activeDeviceId)
        const activeSm4 = getDeviceDynamicSm4Key(this.activeDeviceId)
        if (activeAes !== null && activeSm4 !== null) {
          setDynamicCryptoKeys(activeAes, activeSm4)
          this.deviceEpoch = 1
          this.deviceKeySource = 'dynamic'
          console.info(`[Crypto] restored device key registry active=${this.activeDeviceId}`)
          return
        }
      } catch (err) {
        console.info(`[Crypto] device key registry invalid: ${(err as Error).message}`)
        this.deviceCryptoKeysJson = ''
      }
    }
    if (this.dynamicAesKeyBase64.length === 0 || this.dynamicSm4KeyBase64.length === 0) {
      clearDynamicCryptoKeys()
      this.deviceEpoch = 0
      this.deviceKeySource = 'static'
      console.info('[Crypto] no persisted dynamic keys; waiting for fresh ECDH session')
      return
    }
    try {
      const aesKey = this.base64ToUint8Array(this.dynamicAesKeyBase64)
      const sm4Key = this.base64ToUint8Array(this.dynamicSm4KeyBase64)
      if (aesKey.length !== 32 || sm4Key.length !== 16) {
        throw new Error(`bad persisted key length aes=${aesKey.length} sm4=${sm4Key.length}`)
      }
      setDynamicCryptoKeys(aesKey, sm4Key)
      setDeviceDynamicCryptoKeys(this.activeDeviceId, aesKey, sm4Key)
      this.deviceEpoch = 1
      this.deviceKeySource = 'dynamic'
      console.info('[Crypto] restored persisted dynamic AES/SM4 keys')
    } catch (err) {
      this.dynamicAesKeyBase64 = ''
      this.dynamicSm4KeyBase64 = ''
      clearDynamicCryptoKeys()
      this.deviceEpoch = 0
      this.deviceKeySource = 'static'
      console.info(`[Crypto] persisted dynamic keys invalid: ${(err as Error).message}`)
    }
  }

  persistDynamicCryptoKeys(): void {
    const aesKey = getDynamicAesKey()
    const sm4Key = getDynamicSm4Key()
    if (aesKey === null || sm4Key === null) {
      return
    }
    this.dynamicAesKeyBase64 = this.uint8ArrayToBase64(aesKey)
    this.dynamicSm4KeyBase64 = this.uint8ArrayToBase64(sm4Key)
    this.persistDeviceKeys(this.activeDeviceId, aesKey, sm4Key)
  }

  persistDeviceKeys(deviceId: string, aesKey: Uint8Array, sm4Key: Uint8Array): void {
    const aesBase64 = this.uint8ArrayToBase64(aesKey)
    const sm4Base64 = this.uint8ArrayToBase64(sm4Key)
    let registry: Record<string, Object> = {}
    try {
      if (this.deviceCryptoKeysJson.length > 0) {
        registry = JSON.parse(this.deviceCryptoKeysJson) as Record<string, Object>
      }
    } catch (_) {
      registry = {}
    }
    const persisted: PersistedDeviceCryptoKeys = {
      aes: aesBase64,
      sm4: sm4Base64
    }
    registry[deviceId] = persisted
    this.deviceCryptoKeysJson = JSON.stringify(registry)
    console.info(`[Crypto] persisted dynamic AES/SM4 keys for ${deviceId}`)
  }

  removePersistedDeviceKeys(deviceId: string): void {
    if (this.deviceCryptoKeysJson.length === 0) {
      return
    }
    try {
      const registry = JSON.parse(this.deviceCryptoKeysJson) as Record<string, Object>
      const retained: Record<string, Object> = {}
      Object.keys(registry).forEach((storedDeviceId: string) => {
        if (storedDeviceId !== deviceId) {
          retained[storedDeviceId] = registry[storedDeviceId]
        }
      })
      this.deviceCryptoKeysJson = JSON.stringify(retained)
    } catch (_) {
      this.deviceCryptoKeysJson = ''
    }
  }

  switchToStaticCryptoSession(source: string, mode: string): void {
    this.switchDeviceToStaticCryptoSession(this.activeDeviceId, source, mode)
  }

  switchDeviceToStaticCryptoSession(deviceId: string, source: string, mode: string): void {
    clearDeviceDynamicCryptoKeys(deviceId)
    this.removePersistedDeviceKeys(deviceId)
    this.keyExchange.resetDevice(deviceId)
    this.lastKeyExchangeTimestampByTopic.delete(`key/ecdh/pub/${deviceId}`)
    this.lastSuccessfulDecryptAtByDevice.delete(deviceId)
    this.decryptFailCountByDevice.delete(deviceId)
    this.lastEcdhPendingTimeByDevice.delete(deviceId)
    this.lastEcdhInstallTimeByDevice.delete(deviceId)
    this.updateDeviceDescriptorModes(deviceId, '', mode)
    if (deviceId === this.activeDeviceId) {
      clearDynamicCryptoKeys()
      this.dynamicAesKeyBase64 = ''
      this.dynamicSm4KeyBase64 = ''
      this.lastEcdhPendingTime = 0
      this.lastEcdhInstallTime = 0
      this.deviceEpoch = 0
      this.deviceKeySource = 'static'
      this.applyCryptoMode(mode)
    }
    console.info(`[Crypto][static-session] device=${deviceId} ${source} mode=${mode}; outgoing commands now use static key`)
  }

  ensureOutgoingCryptoKey(mode: string, source: string): string {
    const hasDynamicAes = getDynamicAesKey() !== null
    const hasDynamicSm4 = getDynamicSm4Key() !== null
    if (this.deviceKeySource === 'static') {
      if (hasDynamicAes || hasDynamicSm4) {
        this.switchToStaticCryptoSession(source, mode)
      }
      return 'static'
    }
    if (this.deviceKeySource === 'dynamic') {
      if (!hasDynamicAes || !hasDynamicSm4) {
        throw new Error(`dynamic key missing at epoch=${this.deviceEpoch}`)
      }
      return 'dynamic'
    }
    this.switchToStaticCryptoSession(`${source}-invalid-${this.deviceKeySource}`, mode)
    return 'static'
  }

  async requestCryptoModeSwitch(targetMode: string): Promise<void> {
    const fromMode = this.normalizeCryptoMode(currentCryptoMode())
    const normalizedTarget = this.normalizeCryptoMode(targetMode)
    const targetVal = normalizedTarget.toLowerCase()
    const seq = this.nextCryptoSwitchSeq()
    const cmd = JSON.stringify({ cmd: 'crypto', val: targetVal, seq })

    this.cryptoSwitchHttpSensorBaseline = this.lastHttpSensorTimestamp
    this.cryptoSwitchEncryptedBaseline = this.lastEncryptedTimestamp
    this.cryptoPendingMode = normalizedTarget
    this.cryptoPendingSeq = seq
    this.cryptoDebugText = `切换中 ${fromMode}->${normalizedTarget}`
    this.cryptoLastDecrypted = '等待切换ACK'
    console.info(`[Crypto][switch] request ${fromMode}->${normalizedTarget} seq=${seq} ui=${this.cryptoMode} active=${currentCryptoMode()}: ${cmd}`)

    try {
      await this.sendEncryptedCommandUsingCurrentSession(this.normalizeBridgeUrl(this.bridgeUrl), cmd, this.commandTransport)
      this.startCryptoSwitchTimeout(fromMode, normalizedTarget)
      if (this.commandTransport === 'HTTP') {
        this.pollHttpCryptoSwitchAck(normalizedTarget)
      }
    } catch (err) {
      this.cryptoPendingMode = ''
      this.cryptoPendingSeq = 0
      this.cryptoLastDecrypted = '切换发送失败'
      this.cryptoDebugText = `切换失败 ${(err as Error).message}`
      console.info(`[Crypto][switch][send-fail] ${JSON.stringify(err)}`)
    }
  }

  nextCryptoSwitchSeq(): number {
    this.cryptoSwitchSeq = (this.cryptoSwitchSeq % 999999) + 1
    return this.cryptoSwitchSeq
  }

  startCryptoSwitchTimeout(fromMode: string, targetMode: string): void {
    if (this.cryptoSwitchTimerId !== -1) {
      clearTimeout(this.cryptoSwitchTimerId)
    }
    this.cryptoSwitchTimerId = setTimeout(() => {
      if (this.cryptoPendingMode === targetMode) {
        this.cryptoPendingMode = ''
        this.cryptoPendingSeq = 0
        this.applyCryptoMode(fromMode)
        this.cryptoLastDecrypted = '切换超时'
        this.cryptoDebugText = `${fromMode}->${targetMode} ACK超时`
        console.info(`[Crypto][switch][timeout] ${fromMode}->${targetMode}`)
      }
      this.cryptoSwitchTimerId = -1
    }, 15000)
  }

  async pollHttpCryptoSwitchAck(targetMode: string): Promise<void> {
    for (let i = 0; i < 14; i += 1) {
      if (this.cryptoPendingMode !== targetMode || this.commandTransport !== 'HTTP') {
        return
      }
      await new Promise<void>((resolve) => setTimeout(resolve, 700))
      if (this.cryptoPendingMode !== targetMode || this.commandTransport !== 'HTTP') {
        return
      }
      try {
        await this.refreshBridge()
      } catch (err) {
        console.info(`[Crypto][switch][http-poll-skip] ${(err as Error).message}`)
      }
    }
  }

  completeCryptoSwitch(mode: string, jsonStr: string): void {
    if (this.cryptoSwitchTimerId !== -1) {
      clearTimeout(this.cryptoSwitchTimerId)
      this.cryptoSwitchTimerId = -1
    }
    this.applyCryptoMode(mode)
    this.updateDeviceDescriptorModes(this.activeDeviceId, '', mode)
    this.decryptFailCount = 0
    this.decryptFailCountByDevice.delete(this.activeDeviceId)
    this.cryptoPendingMode = ''
    this.cryptoPendingSeq = 0
    this.cryptoModeAutoCorrectHoldUntil = Date.now() + 20000
    this.cryptoEnabled = true
    this.cryptoLastDecrypted = new Date().toLocaleTimeString() + ' ACK'
    this.cryptoDebugText = `${mode}-GCM 已生效`
    this.addMqttMessage('esp32/sensor', jsonStr)
    console.info(`[Crypto][switch][ack] mode=${mode} raw=${jsonStr}`)
  }

  isCryptoSwitchAck(jsonStr: string, mode: string): boolean {
    try {
      const data = JSON.parse(jsonStr) as Record<string, Object>
      const type = data['type'] as string
      const cmd = data['cmd'] as string
      const ok = data['ok'] as boolean
      const success = data['success'] as boolean
      const msg = data['msg'] as string
      const ackMode = mode.toUpperCase()
      const seq = typeof data['seq'] === 'number' ? data['seq'] as number : 0
      if (ok === false || success === false) {
        return false
      }
      if (this.cryptoPendingSeq > 0 && seq > 0 && seq !== this.cryptoPendingSeq) {
        console.info(`[Crypto][switch][seq-mismatch] pending=${this.cryptoPendingSeq} ack=${seq}`)
        return false
      }
      const typeIsAck = typeof type === 'string' && type.toLowerCase() === 'ack'
      const cmdIsCrypto = typeof cmd === 'string' && cmd.toLowerCase() === 'crypto'
      const val = data['val'] as string
      const modeValue = data['mode'] as string
      const crypto = data['crypto'] as string
      const target = data['target'] as string
      const result = data['result'] as string
      const status = data['status'] as string
      const hasAckSignal = typeIsAck || ok === true || success === true ||
        (typeof result === 'string' && result.toLowerCase() === 'ok') ||
        (typeof status === 'string' && status.toLowerCase() === 'ok')
      if (cmdIsCrypto && hasAckSignal && typeof val === 'string' && val.toUpperCase() === ackMode) {
        return true
      }
      if (cmdIsCrypto && hasAckSignal && typeof modeValue === 'string' && modeValue.toUpperCase() === ackMode) {
        return true
      }
      if (cmdIsCrypto && hasAckSignal && typeof crypto === 'string' && crypto.toUpperCase() === ackMode) {
        return true
      }
      if (cmdIsCrypto && hasAckSignal && typeof target === 'string' && target.toUpperCase() === ackMode) {
        return true
      }
      if (!typeIsAck) {
        return false
      }
      if (typeof msg === 'string' && msg.toUpperCase().indexOf(ackMode) >= 0) {
        return true
      }
      if (typeof modeValue === 'string' && modeValue.toUpperCase() === ackMode) {
        return true
      }
      if (typeof crypto === 'string' && crypto.toUpperCase() === ackMode) {
        return true
      }
    } catch (_) {
      const text = jsonStr.toUpperCase()
      const ackMode = mode.toUpperCase()
      return text.indexOf(ackMode) >= 0 &&
        (text.indexOf('ACK') >= 0 || text.indexOf('OK') >= 0 || text.indexOf('SUCCESS') >= 0)
    }
    return false
  }

  async tryHandleCryptoSwitchAck(raw: Uint8Array): Promise<boolean> {
    if (this.cryptoPendingMode.length === 0) {
      return false
    }
    const targetMode = this.cryptoPendingMode
    const candidates: string[] = [
      targetMode,
      this.normalizeCryptoMode(currentCryptoMode()),
      this.normalizeCryptoMode(this.cryptoMode),
      this.otherCryptoMode(targetMode)
    ]
    const modes: string[] = []
    for (let i = 0; i < candidates.length; i += 1) {
      const candidate = this.normalizeCryptoMode(candidates[i])
      if (modes.indexOf(candidate) < 0) {
        modes.push(candidate)
      }
    }
    let lastError = ''
    for (let i = 0; i < modes.length; i += 1) {
      const decryptMode = modes[i]
      try {
        const decrypted = await decryptWithExpectedMode(raw, decryptMode)
        if (this.tryCompleteCryptoSwitchFromPlaintext(decrypted.plaintext, targetMode, decryptMode, decrypted.keySource ?? 'active')) {
          return true
        }
        console.info(`[Crypto][switch][ack-not-match] target=${targetMode} decrypt=${decryptMode}/${decrypted.keySource ?? 'active'} text=${decrypted.plaintext.substring(0, 80)}`)
      } catch (err) {
        lastError = `${decryptMode} active ${(err as Error).message}`
      }
      try {
        const staticDecrypted = await decryptWithStaticExpectedMode(raw, decryptMode)
        if (this.tryCompleteCryptoSwitchFromPlaintext(staticDecrypted.plaintext, targetMode, decryptMode, 'static')) {
          return true
        }
        console.info(`[Crypto][switch][ack-not-match] target=${targetMode} decrypt=${decryptMode}/static text=${staticDecrypted.plaintext.substring(0, 80)}`)
      } catch (err) {
        lastError = `${decryptMode} static ${(err as Error).message}`
      }
    }
    console.info(`[Crypto][switch][ack-decrypt-fail] target=${targetMode} last=${lastError}`)
    return false
  }

  tryCompleteCryptoSwitchFromPlaintext(text: string, targetMode: string, decryptMode: string, keySource: string): boolean {
    if (this.isCryptoSwitchAck(text, targetMode)) {
      this.completeCryptoSwitch(targetMode, text)
      console.info(`[Crypto][switch][ack-mode] target=${targetMode} decrypt=${decryptMode}/${keySource}`)
      return true
    }
    if (this.cryptoPendingSeq === 0 && decryptMode === targetMode && this.looksLikeJsonObject(text)) {
      const inferredAck = JSON.stringify({
        type: 'ack',
        cmd: 'crypto',
        ok: true,
        val: targetMode.toLowerCase(),
        inferred: true,
        reason: 'target-mode-payload',
        keySource
      })
      this.completeCryptoSwitch(targetMode, inferredAck)
      console.info(`[Crypto][switch][observed-target] target=${targetMode} decrypt=${decryptMode}/${keySource} text=${text.substring(0, 80)}`)
      return true
    }
    return false
  }

  looksLikeJsonObject(text: string): boolean {
    try {
      const data = JSON.parse(text) as Object
      return data !== null && Array.isArray(data) === false
    } catch (_) {
      return false
    }
  }

  async requestProtocolSwitch(targetProtocol: string): Promise<void> {
    const target = this.normalizeProtocolMode(targetProtocol)
    const fromProtocol = this.transportForDevice(this.activeDeviceId)
    this.commandTransport = fromProtocol
    if (target === fromProtocol) {
      this.cryptoDebugText = `当前已是 ${target}`
      return
    }
    if (this.protocolPendingMode.length > 0) {
      this.cryptoDebugText = `协议切换中 ${fromProtocol}->${this.protocolPendingMode}`
      return
    }

    const seq = this.nextProtocolSwitchSeq()
    const cmd = JSON.stringify({ cmd: 'proto', val: target.toLowerCase(), seq })
    this.protocolPendingMode = target
    this.protocolPendingSeq = seq
    this.cryptoDebugText = `协议切换中 ${fromProtocol}->${target}`
    console.info(`[PROTO][switch] request ${fromProtocol}->${target} seq=${seq}`)
    try {
      await this.sendEncryptedCommandUsingCurrentSession(this.normalizeBridgeUrl(this.bridgeUrl), cmd, fromProtocol)
      this.cryptoDebugText = `协议切换命令已发送 ${fromProtocol}->${target}`
      console.info(`[PROTO][switch][sent] active=${fromProtocol} pending=${target} seq=${seq}`)
      this.startProtocolSwitchTimeout(fromProtocol, target, seq)
    } catch (err) {
      this.protocolPendingMode = ''
      this.protocolPendingSeq = 0
      this.commandTransport = fromProtocol
      this.cryptoDebugText = `协议切换发送失败 ${(err as Error).message}`
      console.info(`[PROTO][switch][send-fail] ${JSON.stringify(err)}`)
    }
  }

  async sendProtocolSwitchCommand(fromProtocol: string, targetProtocol: string): Promise<void> {
    const target = this.normalizeProtocolMode(targetProtocol)
    const seq = this.nextProtocolSwitchSeq()
    const cmd = JSON.stringify({ cmd: 'proto', val: target.toLowerCase(), seq })
    console.info(`[PROTO][switch-bg] request ${fromProtocol}->${target} seq=${seq}`)
    await this.sendEncryptedCommandUsingCurrentSession(this.normalizeBridgeUrl(this.bridgeUrl), cmd, fromProtocol)
  }

  nextProtocolSwitchSeq(): number {
    this.protocolSwitchSeq = (this.protocolSwitchSeq % 999999) + 1
    return this.protocolSwitchSeq
  }

  startProtocolSwitchTimeout(fromProtocol: string, targetProtocol: string, seq: number): void {
    if (this.protocolSwitchTimerId !== -1) {
      clearTimeout(this.protocolSwitchTimerId)
    }
    this.protocolSwitchTimerId = setTimeout(() => {
      if (this.protocolPendingMode === targetProtocol && this.protocolPendingSeq === seq) {
        this.protocolPendingMode = ''
        this.protocolPendingSeq = 0
        this.commandTransport = fromProtocol
        this.cryptoDebugText = `${fromProtocol}->${targetProtocol} ACK超时，已保持${fromProtocol}`
        this.addMqttMessage('proto/switch', JSON.stringify({
          type: 'ack',
          cmd: 'proto',
          ok: false,
          val: targetProtocol.toLowerCase(),
          reason: 'ack-timeout-keep-source',
          seq
        }))
        console.info(`[PROTO][switch][timeout-keep-source] ${fromProtocol}->${targetProtocol} seq=${seq}`)
      }
      this.protocolSwitchTimerId = -1
    }, 8000)
  }

  tryCompleteProtocolSwitchFromJson(jsonStr: string, source: string): boolean {
    if (this.protocolPendingMode.length === 0) {
      return false
    }
    try {
      const data = JSON.parse(jsonStr) as Record<string, Object>
      const type = data['type'] as string
      const cmd = data['cmd'] as string
      const ok = data['ok'] !== false
      const val = data['val'] as string
      const seq = typeof data['seq'] === 'number' ? data['seq'] as number : 0
      const target = this.protocolPendingMode
      const sourceProtocol = this.protocolFromSource(source)
      if (type !== 'ack' || cmd !== 'proto' || !ok) {
        return false
      }
      if (seq !== 0 && seq !== this.protocolPendingSeq) {
        return false
      }
      if (typeof val === 'string' && this.normalizeProtocolMode(val.toUpperCase()) !== target) {
        return false
      }
      if (sourceProtocol !== target) {
        console.info(`[PROTO][switch][ack-source] target=${target} source=${sourceProtocol}`)
      }
      this.completeProtocolSwitch(target, jsonStr)
      return true
    } catch (_) {
      return false
    }
  }

  tryCompleteProtocolSwitchFromObservedPayload(source: string): boolean {
    if (this.protocolPendingMode.length === 0) {
      return false
    }
    const sourceProtocol = this.protocolFromSource(source)
    const target = this.protocolPendingMode
    if (sourceProtocol !== target) {
      return false
    }
    const inferredAck = JSON.stringify({
      type: 'ack',
      cmd: 'proto',
      ok: true,
      val: target.toLowerCase(),
      inferred: true,
      source
    })
    console.info(`[PROTO][switch][observed] active=${target} source=${source}`)
    this.completeProtocolSwitch(target, inferredAck)
    return true
  }

  completeProtocolSwitch(mode: string, jsonStr: string): void {
    if (this.protocolSwitchTimerId !== -1) {
      clearTimeout(this.protocolSwitchTimerId)
      this.protocolSwitchTimerId = -1
    }
    this.commandTransport = this.normalizeProtocolMode(mode)
    this.updateDeviceDescriptorModes(this.activeDeviceId, mode, '')
    this.protocolPendingMode = ''
    this.protocolPendingSeq = 0
    this.decryptFailCount = 0
    this.decryptFailCountByDevice.delete(this.activeDeviceId)
    this.cryptoDebugText = `业务协议已切换到 ${this.commandTransport}`
    this.addMqttMessage('proto/switch', jsonStr)
    console.info(`[PROTO][switch][ack] active=${this.commandTransport} raw=${jsonStr}`)
  }

  async decryptIncomingPayload(raw: Uint8Array, source: string,
    deviceId: string = this.activeDeviceId): Promise<CryptoDecryptResult> {
    const pendingKeyAck = await this.tryDecryptPendingKeyAck(raw, source, deviceId)
    if (pendingKeyAck !== null) {
      return pendingKeyAck
    }

    const attempts: string[] = []
    const expectedMode = this.cryptoModeForDevice(deviceId)
    try {
      return await decryptWithExpectedModeForDevice(raw, expectedMode, deviceId)
    } catch (firstErr) {
      const firstMsg = (firstErr as Error).message
      attempts.push(firstMsg)
      try {
        const staticFallback = await decryptWithStaticExpectedMode(raw, expectedMode)
        const hasConfirmedDynamicSession = getDeviceDynamicAesKey(deviceId) !== null &&
          getDeviceDynamicSm4Key(deviceId) !== null
        if (!hasConfirmedDynamicSession) {
          this.switchDeviceToStaticCryptoSession(deviceId, source, staticFallback.mode)
          if (deviceId === this.activeDeviceId) {
            this.cryptoDebugText = `${source}回退静态${staticFallback.mode}密钥`
          }
        } else {
          console.info(`[Crypto][static-compat] ${source} ${deviceId}; keep confirmed dynamic session`)
        }
        console.info(`[Crypto][static-fallback] ${source} ${staticFallback.mode}`)
        return staticFallback
      } catch (staticErr) {
        attempts.push((staticErr as Error).message)
        // Continue to algorithm auto-correction below.
      }

      const staticOtherMode = this.otherCryptoMode(expectedMode)
      try {
        const staticOtherFallback = await decryptWithStaticExpectedMode(raw, staticOtherMode)
        const hasConfirmedDynamicSession = getDeviceDynamicAesKey(deviceId) !== null &&
          getDeviceDynamicSm4Key(deviceId) !== null
        if (!hasConfirmedDynamicSession) {
          this.switchDeviceToStaticCryptoSession(deviceId, source, staticOtherFallback.mode)
          if (deviceId === this.activeDeviceId) {
            this.cryptoDebugText = `${source}回退静态${staticOtherFallback.mode}密钥`
          }
        } else {
          console.info(`[Crypto][static-compat] ${source} ${deviceId}; keep confirmed dynamic session`)
        }
        console.info(`[Crypto][static-other-fallback] ${source} ${staticOtherFallback.mode}`)
        return staticOtherFallback
      } catch (staticOtherErr) {
        attempts.push((staticOtherErr as Error).message)
        // Continue to dynamic algorithm auto-correction below.
      }

      if (this.cryptoPendingMode.length > 0) {
        throw new Error(this.formatDecryptFailure(raw, firstMsg, attempts))
      }
      if (deviceId === this.activeDeviceId && Date.now() < this.cryptoModeAutoCorrectHoldUntil) {
        console.info(`[Crypto][mode-auto-correct-hold] ${source} skip fallback while switch is fresh`)
        throw new Error(this.formatDecryptFailure(raw, firstMsg, attempts))
      }

      const fallbackMode = this.otherCryptoMode(expectedMode)
      try {
        const fallback = await decryptWithExpectedModeForDevice(raw, fallbackMode, deviceId)
        this.updateDeviceDescriptorModes(deviceId, '', fallback.mode)
        if (deviceId === this.activeDeviceId) {
          const previousMode = this.cryptoMode
          this.applyCryptoMode(fallback.mode)
          this.cryptoDebugText = `${source}自动校正到 ${fallback.mode}-GCM`
          this.addMqttMessage('crypto/mode', `[AUTO] corrected to ${fallback.mode}-GCM`)
          console.info(`[Crypto][mode-auto-correct] device=${deviceId} ${previousMode}->${fallback.mode}`)
        } else {
          console.info(`[Crypto][mode-auto-correct-bg] device=${deviceId} ${expectedMode}->${fallback.mode}`)
        }
        return fallback
      } catch (fallbackErr) {
        attempts.push((fallbackErr as Error).message)
        throw new Error(this.formatDecryptFailure(raw, firstMsg, attempts))
      }
    }
  }

  formatDecryptFailure(raw: Uint8Array, primary: string, attempts: string[]): string {
    const uniqueAttempts: string[] = []
    attempts.forEach((item: string) => {
      if (item.length > 0 && uniqueAttempts.indexOf(item) < 0) {
        uniqueAttempts.push(item)
      }
    })
    const ivHex = this.bytesToHex(raw.slice(0, Math.min(12, raw.length)))
    const tagHex = raw.length >= 28 ? this.bytesToHex(raw.slice(12, 28)) : ''
    const state = `mode=${this.cryptoMode} key=${this.deviceKeySource} epoch=${this.deviceEpoch} dyn=${getDynamicSm4Key() !== null ? 'Y' : 'N'}`
    const tried = uniqueAttempts.length > 1 ? ` tried=${uniqueAttempts.join(' | ')}` : ''
    return `${primary} [${state} iv=${ivHex} tag=${tagHex}]${tried}`
  }

  async tryDecryptPendingKeyAck(raw: Uint8Array, source: string,
    deviceId: string = this.activeDeviceId): Promise<CryptoDecryptResult | null> {
    const pending = this.keyExchange.getPendingKeys(deviceId)
    if (pending === null) {
      return null
    }
    const firstMode = this.normalizeCryptoMode(this.cryptoMode)
    const secondMode = this.otherCryptoMode(firstMode)
    const modes: string[] = [firstMode, secondMode]
    let lastError = ''
    for (let i = 0; i < modes.length; i++) {
      const mode = modes[i]
      try {
        const pendingKey = mode === 'AES' ? pending.aesKey : pending.sm4Key
        const decrypted = await decryptWithProvidedKey(raw, mode, pendingKey)
        if (this.handleKeyExchangeAckJson(decrypted.plaintext, source, mode, deviceId)) {
          return decrypted
        }
        if (this.looksLikeJsonObject(decrypted.plaintext)) {
          this.activatePendingDynamicKeys(source, mode, 'observed', decrypted.plaintext, deviceId)
          return decrypted
        } else {
          continue
        }
      } catch (err) {
        lastError = `${mode} ${(err as Error).message}`
      }
    }
    if (lastError.length > 0) {
      console.info(`[ECDH][ack-pending-fail] ${lastError}`)
    }
    return null
  }

  handleKeyExchangeAckJson(jsonStr: string, source: string, mode: string,
    deviceId: string = this.activeDeviceId): boolean {
    if (!this.isKeyExchangeAck(jsonStr)) {
      return false
    }
    return this.activatePendingDynamicKeys(source, mode, 'ack', jsonStr, deviceId)
  }

  activatePendingDynamicKeys(source: string, mode: string, reason: string, jsonStr: string,
    deviceId: string = this.activeDeviceId): boolean {
    const pending = this.keyExchange.getPendingKeys(deviceId)
    if (pending === null) {
      console.info(`[ECDH][${reason}] no pending key material source=${source} mode=${mode} raw=${jsonStr}`)
      this.addMqttMessage('key/ecdh/ack', jsonStr)
      return true
    }
    const activated = this.keyExchange.activatePendingKeys(pending.deviceId)
    if (activated === null) {
      console.info(`[ECDH][${reason}] activate failed source=${source} mode=${mode} raw=${jsonStr}`)
      this.addMqttMessage('key/ecdh/ack', jsonStr)
      return true
    }
    setDeviceDynamicCryptoKeys(activated.deviceId, activated.aesKey, activated.sm4Key)
    this.persistDeviceKeys(activated.deviceId, activated.aesKey, activated.sm4Key)
    this.decryptFailCountByDevice.delete(activated.deviceId)
    this.lastEcdhPendingTimeByDevice.delete(activated.deviceId)
    this.lastEcdhInstallTimeByDevice.set(activated.deviceId, Date.now())
    if (activated.deviceId === this.activeDeviceId) {
      setDynamicCryptoKeys(activated.aesKey, activated.sm4Key)
      this.persistDynamicCryptoKeys()
      this.applyCryptoMode(mode)
      this.decryptFailCount = 0
      this.lastEcdhPendingTime = 0
      this.lastEcdhInstallTime = Date.now()
      this.deviceEpoch = 1
      this.deviceKeySource = 'dynamic'
      this.cryptoDebugText = `ECDH动态密钥已确认 ${pending.deviceId}/${mode}`
    }
    this.addMqttMessage('key/ecdh/ack', jsonStr)
    console.info(`[ECDH][${reason}] activated dynamic keys source=${source} mode=${mode} raw=${jsonStr}`)
    return true
  }

  isKeyExchangeAck(jsonStr: string): boolean {
    try {
      const data = JSON.parse(jsonStr) as Record<string, Object>
      const type = data['type'] as string
      const cmd = data['cmd'] as string
      const ok = data['ok'] !== false
      return type === 'ack' && cmd === 'key' && ok
    } catch (_) {
      return false
    }
  }

  async httpRequest(url: string, method: http.RequestMethod, body?: string): Promise<string> {
    const request = http.createHttp()
    try {
      const options: http.HttpRequestOptions = {
        method: method,
        header: {
          'Content-Type': 'application/json'
        },
        extraData: body ?? '',
        connectTimeout: 8000,
        readTimeout: 8000
      }
      if (url.startsWith('https://')) {
        const host = this.extractHostFromUrl(url)
        const isLocalBroker = host === '192.168.3.5' || host === '127.0.0.1' || host === 'localhost' ||
          (this.beaconBrokerIp.length > 0 && host === this.beaconBrokerIp)
        if (isLocalBroker) {
          const context = getContext(this) as common.UIAbilityContext
          options.caPath = await ensureTlsCaFile(context.filesDir)
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

  async withTimeout<T>(task: Promise<T>, timeoutMs: number, label: string): Promise<T> {
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

  cloudCryptoText(): string {
    const transport = this.cloudTransport === 'MQTT' ? 'MQTTS' : 'HTTPS'
    return `${transport} + ${currentCryptoMode()} + ECDH`
  }

  updateCloudTransport(response: Record<string, Object>): void {
    const transport = response['transport'] as string
    if (transport !== 'HTTP' && transport !== 'MQTT') return
    if (this.cloudTransport !== transport) {
      console.info(`[Cloud][transport] switched to ${transport}`)
    }
    this.cloudTransport = transport
  }

  async postCloudMqttSecure(path: string, payload: Object): Promise<Record<string, Object>> {
    const response = await this.cloudMqttSecureClient.postSecure(path, payload)
    this.updateCloudTransport(response)
    return response
  }

  async postCloudReportSecure(path: string, payload: Object): Promise<Record<string, Object>> {
    if (this.cloudTransport === 'MQTT') {
      return await this.postCloudMqttSecure(path, payload)
    }
    let lastError = ''
    for (let offset = 0; offset < this.cloudSecureClients.length; offset++) {
      const index = (this.cloudSecureIndex + offset) % this.cloudSecureClients.length
      const client = this.cloudSecureClients[index]
      try {
        const response = await client.postSecure(path, payload)
        if (this.cloudSecureIndex !== index) {
          console.info(`[Cloud][endpoint] report switched to ${client.getEndpoint()}`)
        }
        this.cloudSecureIndex = index
        this.updateCloudTransport(response)
        return response
      } catch (err) {
        lastError = (err as Error).message
        console.info(`[Cloud][endpoint][report-fail] ${client.getEndpoint()} ${lastError}`)
      }
    }
    throw new Error(lastError || 'cloud endpoint unavailable')
  }

  async postCloudCommandSecure(path: string, payload: Object): Promise<Record<string, Object>> {
    if (this.cloudTransport === 'MQTT') {
      return await this.postCloudMqttSecure(path, payload)
    }
    let lastError = ''
    for (let offset = 0; offset < this.cloudCommandSecureClients.length; offset++) {
      const index = (this.cloudCommandSecureIndex + offset) % this.cloudCommandSecureClients.length
      const client = this.cloudCommandSecureClients[index]
      try {
        const response = await client.postSecure(path, payload)
        if (this.cloudCommandSecureIndex !== index) {
          console.info(`[Cloud][endpoint] command switched to ${client.getEndpoint()}`)
        }
        this.cloudCommandSecureIndex = index
        this.updateCloudTransport(response)
        return response
      } catch (err) {
        lastError = (err as Error).message
        console.info(`[Cloud][endpoint][command-fail] ${client.getEndpoint()} ${lastError}`)
      }
    }
    throw new Error(lastError || 'cloud endpoint unavailable')
  }

  async postCloudWeatherSecure(path: string, payload: Object): Promise<Record<string, Object>> {
    if (this.cloudTransport === 'MQTT') {
      return await this.postCloudMqttSecure(path, payload)
    }
    let lastError = ''
    for (let offset = 0; offset < this.cloudWeatherSecureClients.length; offset++) {
      const index = (this.cloudWeatherSecureIndex + offset) % this.cloudWeatherSecureClients.length
      const client = this.cloudWeatherSecureClients[index]
      try {
        const response = await client.postSecure(path, payload)
        this.cloudWeatherSecureIndex = index
        this.updateCloudTransport(response)
        return response
      } catch (err) {
        lastError = (err as Error).message
        console.info(`[Cloud][endpoint][weather-fail] ${client.getEndpoint()} ${lastError}`)
      }
    }
    throw new Error(lastError || 'cloud weather endpoint unavailable')
  }

  async refreshOutdoorWeather(): Promise<void> {
    if (!CLOUD_SYNC_ENABLED || this.weatherInFlight) {
      return
    }
    this.weatherInFlight = true
    try {
      const request: CloudWeatherRequest = {
        clientId: 'dayu_gateway_001',
        latitude: JIANGNING_LATITUDE,
        longitude: JIANGNING_LONGITUDE
      }
      const response = await this.postCloudWeatherSecure('/api/secure/app/weather', request as Object)
      const weather = response['weather'] as OutdoorWeatherPacket
      if (!weather) {
        throw new Error('weather payload missing')
      }
      const temp = this.readNumber(weather.temperature)
      const humidity = this.readNumber(weather.humidity)
      if (temp !== null) {
        this.outdoorTempText = `${temp.toFixed(1)}℃`
      }
      if (humidity !== null) {
        this.outdoorHumidityText = `${Math.round(humidity)}%`
      }
      this.outdoorWeatherLabel = weather.label ?? '天气已更新'
      this.outdoorWeatherIcon = weather.icon ?? '云'
      this.outdoorWeatherUpdateText = `南京市江宁区 · ${new Date().toLocaleTimeString()}`
      this.hasOutdoorWeather = temp !== null || humidity !== null
    } catch (err) {
      this.hasOutdoorWeather = false
      this.outdoorWeatherLabel = '天气暂不可用'
      this.outdoorWeatherUpdateText = `南京市江宁区 · ${(err as Error).message}`
      console.info(`[Weather][refresh-fail] ${(err as Error).message}`)
    } finally {
      this.weatherInFlight = false
    }
  }

  async reportCloud(packet: CloudIngestPacket): Promise<void> {
    if (!CLOUD_SYNC_ENABLED) {
      return
    }
    const now = Date.now()
    if (now < this.cloudPausedUntil || this.cloudReportInFlight || this.cloudAlarmReportInFlight ||
      this.cloudActuatorReportInFlight) {
      return
    }
    this.cloudReportInFlight = true
    try {
      await this.postCloudReportSecure('/api/secure/ingest', packet as Object)
      this.cloudFailCount = 0
    } catch (err) {
      this.cloudFailCount += 1
      if (this.cloudFailCount >= 2) {
        this.cloudPausedUntil = Date.now() + 60000
        console.info('[Cloud][report-paused] pause cloud report for 60s')
      }
      console.info(`[Cloud][report-fail] ${(err as Error).message}`)
    } finally {
      this.cloudReportInFlight = false
      if (this.pendingCloudActuator !== null) {
        this.scheduleCloudActuatorRetry(100)
      }
    }
  }

  scheduleCloudAlarmRetry(delayMs: number): void {
    if (this.cloudAlarmRetryTimerId !== -1) {
      return
    }
    this.cloudAlarmRetryTimerId = setTimeout(() => {
      this.cloudAlarmRetryTimerId = -1
      this.flushCloudAlarmReport()
    }, delayMs)
  }

  queueCloudAlarmReport(packet: CloudIngestPacket): void {
    if (!CLOUD_SYNC_ENABLED) {
      return
    }
    this.pendingCloudAlarm = packet
    this.flushCloudAlarmReport()
  }

  async flushCloudAlarmReport(): Promise<void> {
    if (this.pendingCloudAlarm === null || this.cloudAlarmReportInFlight) {
      return
    }
    if (this.cloudReportInFlight || this.cloudActuatorReportInFlight) {
      this.scheduleCloudAlarmRetry(300)
      return
    }
    const packet = this.pendingCloudAlarm as CloudIngestPacket
    this.cloudAlarmReportInFlight = true
    try {
      await this.postCloudReportSecure('/api/secure/ingest', packet as Object)
      if (this.pendingCloudAlarm === packet) {
        this.pendingCloudAlarm = null
      }
      console.info(`[Cloud][alarm-reported] ${packet.text ?? packet.kind}`)
    } catch (err) {
      console.info(`[Cloud][alarm-report-fail] ${(err as Error).message}`)
      this.scheduleCloudAlarmRetry(2000)
    } finally {
      this.cloudAlarmReportInFlight = false
      if (this.pendingCloudAlarm !== null && this.cloudAlarmRetryTimerId === -1) {
        this.scheduleCloudAlarmRetry(300)
      }
      if (this.pendingCloudActuator !== null) {
        this.scheduleCloudActuatorRetry(300)
      }
    }
  }

  scheduleCloudActuatorRetry(delayMs: number): void {
    if (this.cloudActuatorRetryTimerId !== -1) {
      return
    }
    this.cloudActuatorRetryTimerId = setTimeout(() => {
      this.cloudActuatorRetryTimerId = -1
      this.flushCloudActuatorReport()
    }, delayMs)
  }

  queueCloudActuatorReport(packet: CloudIngestPacket): void {
    if (!CLOUD_SYNC_ENABLED) {
      return
    }
    this.pendingCloudActuator = packet
    this.flushCloudActuatorReport()
  }

  async flushCloudActuatorReport(): Promise<void> {
    if (this.pendingCloudActuator === null || this.cloudActuatorReportInFlight) {
      return
    }
    if (this.cloudReportInFlight || this.cloudAlarmReportInFlight) {
      this.scheduleCloudActuatorRetry(300)
      return
    }
    const packet = this.pendingCloudActuator as CloudIngestPacket
    this.cloudActuatorReportInFlight = true
    try {
      await this.postCloudReportSecure('/api/secure/ingest', packet as Object)
      if (this.pendingCloudActuator === packet) {
        this.pendingCloudActuator = null
      }
      console.info('[Cloud][actuator-reported] latest state synchronized')
    } catch (err) {
      console.info(`[Cloud][actuator-report-fail] ${(err as Error).message}`)
      this.scheduleCloudActuatorRetry(2000)
    } finally {
      this.cloudActuatorReportInFlight = false
      if (this.pendingCloudActuator !== null && this.cloudActuatorRetryTimerId === -1) {
        this.scheduleCloudActuatorRetry(300)
      }
      if (this.pendingCloudAlarm !== null) {
        this.scheduleCloudAlarmRetry(300)
      }
    }
  }

  async pollCloudCommand(): Promise<void> {
    if (this.cloudCommandInFlight) {
      return
    }
    this.cloudCommandInFlight = true
    try {
      const request: CloudPendingRequest = { consumer: 'dayu' }
      const response = await this.postCloudCommandSecure('/api/secure/control/pending', request)
      const command = response['command'] as CloudControlCommand
      if (!command || !command.id) {
        return
      }
      console.info(`[Cloud][command-received] ${command.id} ${command.power === true ? 'on' : 'off'}`)
      await this.executeCloudCommand(command)
    } catch (err) {
      console.info(`[Cloud][command-poll-fail] ${(err as Error).message}`)
    } finally {
      this.cloudCommandInFlight = false
    }
  }

  async executeCloudCommand(command: CloudControlCommand): Promise<void> {
    let isLightCommand = false
    try {
      if (command.kind === 'ac') {
        if (!this.isBridgeActuallyConnected()) {
          console.info(`[Cloud][command-retry] ${command.id} local bridge not ready`)
          return
        }
        const temperature = Math.max(16, Math.min(30, Math.round(command.temperature ?? 26)))
        const mode = command.mode === 'heat' ? 'heat' : 'cool'
        const power = command.power === true
        const brand = command.brand === 'Midea' ? '美的' : (command.brand === 'Haier' ? '海尔' : '格力')
        const seq = this.nextACCommandSeq()
        this.acTemp = temperature
        this.acMode = mode
        this.acPower = power
        this.acBrand = brand
        this.acPendingSeq = seq
        this.acAckText = `正在发送 ${this.commandTransportText()}`
        await this.sendACControl(temperature, power, mode, seq)
        this.acAckText = `等待设备确认 #${seq}`
        this.startACAckTimer(seq)
        await this.ackCloudCommand(command.id, true, `空调${power ? '开启' : '关闭'} ${temperature}℃ ${mode === 'heat' ? '制热' : '制冷'}指令已由大禹下发`)
        this.addMqttMessage('cloud/app/ac', `[SENT:CLOUD] AC power=${power} temp=${temperature} mode=${mode} ${command.id}`)
        return
      }
      if (command.kind === 'curtain') {
        if (!this.isBridgeActuallyConnected()) {
          console.info(`[Cloud][command-retry] ${command.id} local bridge not ready`)
          return
        }
        const percent = Math.max(0, Math.min(100, Math.round(command.percent ?? 0)))
        this.curtainPercent = percent
        await this.sendCurtainControl(percent)
        await this.ackCloudCommand(command.id, true, `窗帘已调整至 ${percent}%`)
        this.addMqttMessage('cloud/app/curtain', `[SENT:CLOUD] curtain=${percent}% ${command.id}`)
        return
      }
      if (command.kind === 'door') {
        if (!this.isBridgeActuallyConnected()) {
          console.info(`[Cloud][command-retry] ${command.id} local bridge not ready`)
          return
        }
        const unlock = command.unlock === true || command.locked === false
        await this.sendDoorControl(unlock)
        await this.ackCloudCommand(command.id, true, `${unlock ? '解锁' : '上锁'}指令已由大禹下发`)
        this.addMqttMessage('cloud/app/door', `[SENT:CLOUD] door=${unlock ? 'unlock' : 'lock'} ${command.id}`)
        return
      }
      if (command.kind !== 'light') {
        await this.ackCloudCommand(command.id, false, `unsupported kind ${command.kind ?? ''}`)
        return
      }
      isLightCommand = true
      const target = command.dayuTarget && command.dayuTarget.length > 0 ? command.dayuTarget : 'living'
      const power = command.power === true
      if (target !== 'living') {
        await this.ackCloudCommand(command.id, false, `unsupported target ${target}`)
        return
      }
      if (this.livingLightControlInFlight) {
        console.info(`[Cloud][command-retry] ${command.id} living light send busy`)
        return
      }
      if (!this.isBridgeActuallyConnected()) {
        console.info(`[Cloud][command-retry] ${command.id} local bridge not ready`)
        return
      }

      this.livingLightControlInFlight = true
      this.livingLightAckText = `${this.livingLightOn ? 'ON' : 'OFF'} → ${power ? 'ON' : 'OFF'}`
      this.livingLightOptimisticUntil = 0
      this.startLivingLightControlTimer()
      await this.sendLightControl('living', power)
      await this.ackCloudCommand(command.id, true, `${power ? '开灯' : '关灯'}指令已由大禹下发`)
      this.addMqttMessage('cloud/app/light', `[SENT:CLOUD] ${power ? '开灯' : '关灯'} ${command.id}`)
    } catch (err) {
      const message = (err as Error).message
      if (this.isTransientCloudCommandError(message)) {
        console.info(`[Cloud][command-retry] ${command.id} ${message}`)
        return
      }
      await this.ackCloudCommand(command.id, false, message)
    } finally {
      if (isLightCommand && !this.livingLightPending) {
        this.livingLightControlInFlight = false
      }
    }
  }

  isTransientCloudCommandError(message: string): boolean {
    return message.indexOf('BridgeTLS') >= 0 ||
      message.indexOf('MQTT') >= 0 ||
      message.indexOf('bridge not ready') >= 0 ||
      message.indexOf('send failed') >= 0 ||
      message.indexOf('connect') >= 0 ||
      message.indexOf('timeout') >= 0
  }

  async ackCloudCommand(id: string, ok: boolean, message: string): Promise<void> {
    const request: CloudAckRequest = { id, ok, message }
    await this.postCloudCommandSecure('/api/secure/control/ack', request)
  }

  reportCloudHeartbeat(): void {
    const actuatorState: LightStatusPacket = {
      living: this.livingLightOn,
      locked: this.doorLocked,
      source: 'dayu'
    }
    if (this.hasDoorOpenStatus) {
      actuatorState.door = this.doorOpen
    }
    const packet: CloudIngestPacket = {
      source: 'dayu',
      kind: 'heartbeat',
      deviceId: 'dayu_gateway_001',
      deviceType: '大禹网关',
      text: this.isBridgeActuallyConnected() ? '大禹在线，Bridge 已连接' : '大禹在线，Bridge 待连接',
      crypto: this.cloudCryptoText(),
      esp32Online: this.isBridgeActuallyConnected(),
      light: actuatorState,
      target: 'living_curtain',
      percent: this.curtainPercent,
      state: this.mqttConnected ? 'MQTT/Bridge 在线' : this.mqttStatus
    }
    this.reportCloud(packet)
  }

  reportCloudMessage(topic: string, text: string): void {
    let kind = 'message'
    let source = 'dayu'
    let deviceId = 'dayu_gateway_001'
    let deviceType = '大禹网关'

    if (topic.indexOf('esp32') >= 0) {
      kind = 'sensor'
      source = 'esp32'
      deviceId = 'esp32_living_001'
      deviceType = '设备节点'
    }
    if (topic.indexOf('key/ecdh') >= 0 || text.indexOf('decrypt fail') >= 0 || text.indexOf('解密失败') >= 0) {
      kind = 'security'
    }
    if (topic === 'dayu/cmd' || text.indexOf('[SENT') >= 0) {
      kind = 'control'
      source = 'dayu'
      deviceId = 'esp32_living_001'
      deviceType = '设备节点'
    }

    const packet: CloudIngestPacket = {
      source,
      kind,
      deviceId,
      deviceType,
      topic,
      text,
      crypto: this.cloudCryptoText(),
      target: topic,
      action: text,
      state: '已由大禹上报'
    }
    this.reportCloud(packet)
  }

  reportCloudSensor(data: SensorPacket, source: string): void {
    const packet: CloudIngestPacket = {
      source: source.indexOf('ESP') >= 0 ? 'esp32' : 'dayu',
      kind: 'sensor',
      deviceId: 'esp32_living_001',
      deviceType: '设备节点',
      topic: 'esp32/sensor',
      text: '传感器状态已脱敏上报',
      crypto: this.cloudCryptoText(),
      sensor: data,
      state: '已接收'
    }
    this.reportCloud(packet)
  }

  reportCloudLight(data: LightStatusPacket): void {
    const packet: CloudIngestPacket = {
      source: 'esp32',
      kind: 'ack',
      deviceId: 'esp32_living_001',
      deviceType: '设备节点',
      topic: 'esp32/sensor',
      text: '执行器状态已同步',
      crypto: this.cloudCryptoText(),
      light: data,
      state: '已同步'
    }
    this.queueCloudActuatorReport(packet)
  }

  reportCloudCurtain(percent: number, source: string = 'esp32'): void {
    const normalized = Math.max(0, Math.min(100, Math.round(percent)))
    const packet: CloudIngestPacket = {
      source,
      kind: 'ack',
      deviceId: 'esp32_living_001',
      deviceType: '设备节点',
      topic: 'esp32/curtain',
      text: `窗帘开合度已同步 ${normalized}%`,
      crypto: this.cloudCryptoText(),
      target: 'living_curtain',
      percent: normalized,
      action: `窗帘调整至 ${normalized}%`,
      state: '已同步'
    }
    this.reportCloud(packet)
  }

  // 接收 ESP32 上报的温湿度、烟雾、水浸、跌倒等标准 JSON 数据。
  receiveSensorData(jsonStr: string): void {
    console.info(`[HW][receiveSensorData] raw=${jsonStr}`)
    try {
      const data: SensorPacket = JSON.parse(jsonStr) as SensorPacket
      this.applySensorData(data, 'DIRECT')
    } catch (err) {
      console.info(`[HW][receiveSensorData][parse-error] ${JSON.stringify(err)}`)
    }
  }

  isSensorCapableDevice(deviceId: string): boolean {
    const registry = this.loadDeviceRegistry()
    const descriptor = registry[deviceId]
    if (descriptor === undefined) {
      return deviceId === 'esp32' || Object.keys(registry).length === 0
    }
    return descriptor.capabilities.indexOf('sensor') >= 0
  }

  applySensorData(data: SensorPacket, source: string = 'LIVE', deviceId: string = this.activeDeviceId): void {
    if ((source === 'MQTT' || source === 'DIRECT') && !this.isSensorCapableDevice(deviceId)) {
      console.info(`[Sensor][ignore-non-sensor-device] source=${source} device=${deviceId}`)
      return
    }
    this.syncProtocolFromSensorData(data, source, deviceId)
    const nextTemp = this.findNumber(data as Object as Record<string, Object>, [
      'temperature', 'temp', 't', 'Temperature', 'Temp', 'TEMP'
    ])
    const nextHumidity = this.findNumber(data as Object as Record<string, Object>, [
      'humidity', 'hum', 'h', 'Humidity', 'Hum', 'HUM'
    ])

    if (nextTemp !== null) {
      this.indoorTemp = nextTemp
      this.indoorTempText = `${nextTemp.toFixed(1)}℃`
    }
    if (nextHumidity !== null) {
      this.indoorHumidity = nextHumidity
      this.indoorHumidityText = `${nextHumidity.toFixed(1)}%`
    }
    if (nextTemp !== null || nextHumidity !== null) {
      this.sensorLastUpdateText = `已更新 ${new Date().toLocaleTimeString()}`
      if (source !== 'HTTP_BOOT') {
        this.hasLiveSensorData = true
      }
      // 替换整个数组强制 ArkTS 检测变化
      this.sensorDisplay = [this.indoorTempText, this.indoorHumidityText, this.sensorLastUpdateText]
      console.info(`[Sensor] sensorDisplay = [${this.sensorDisplay[0]}, ${this.sensorDisplay[1]}, ${this.sensorDisplay[2]}]`)
    }
    console.info(`[Sensor][apply] temp=${this.indoorTemp}, humidity=${this.indoorHumidity}, raw=${JSON.stringify(data)}`)

    let nextLevel: number = typeof data.alertLevel === 'number' ? data.alertLevel : 0
    let msg: string = data.message ?? '传感器数据已更新'
    if (data.smoke === true || data.waterLeak === true || data.fallDetected === true) {
      nextLevel = Math.max(nextLevel, 3)
      msg = data.message ?? '检测到一级严重突发预警'
    }

    if (this.hasActiveDeviceAlarm()) {
      this.refreshAlarmPresentation()
    } else {
      this.alertLevel = Math.max(0, Math.min(3, nextLevel))
      this.alertMessage = this.userFacingDeviceText(msg)
      if (this.alertLevel >= 3) {
        this.triggerLocalAlarm(this.alertLevel, this.alertMessage)
      } else {
        this.showCriticalDialog = false
      }
    }
    if (source !== 'HTTP_BOOT') {
      this.reportCloudSensor(data, source)
    }
  }

  syncProtocolFromSensorData(data: SensorPacket, source: string, deviceId: string = this.activeDeviceId): void {
    if (source === 'HTTP_BOOT' || source === 'TLS_BOOT') {
      return
    }
    const rawData = data as Object as Record<string, Object>
    const rawProtocol = rawData['proto'] as string
    if (typeof rawProtocol !== 'string') {
      return
    }
    const observed = this.normalizeProtocolMode(rawProtocol.toUpperCase())
    const sourceProtocol = this.protocolFromSource(source)
    if (observed !== sourceProtocol) {
      console.info(`[PROTO][sensor-ignore-stale] declared=${observed} source=${sourceProtocol}/${source}`)
      return
    }
    if (deviceId !== this.activeDeviceId) {
      return
    }
    if (this.protocolPendingMode.length > 0) {
      if (observed === this.protocolPendingMode) {
        const inferredAck = JSON.stringify({
          type: 'ack',
          cmd: 'proto',
          ok: true,
          val: observed.toLowerCase(),
          inferred: true,
          reason: 'sensor-proto',
          source
        })
        this.completeProtocolSwitch(observed, inferredAck)
      }
      return
    }
    // The proto field in a periodic packet can belong to the previous route.
    // Only an explicit switch ACK, a pending-target observation, or
    // device_hello is allowed to change the selected transport.
  }

  applySensorJson(jsonStr: string, source: string, deviceId: string = this.activeDeviceId): void {
    try {
      const data = JSON.parse(jsonStr) as SensorPacket
      this.applySensorData(data, source, deviceId)
      if (deviceId === this.activeDeviceId && this.cryptoPendingMode.length === 0) {
        this.cryptoDebugText = `${source}解析OK ${this.sensorDisplay[0]}/${this.sensorDisplay[1]}`
      }
    } catch (err) {
      if (deviceId === this.activeDeviceId && this.cryptoPendingMode.length === 0) {
        this.cryptoDebugText = `${source}JSON失败 ${(err as Error).message}`
      }
      console.info(`[Sensor][json-fail] ${JSON.stringify(err)}, raw=${jsonStr}`)
    }
  }

  readNumber(value: number | string | undefined): number | null {
    if (typeof value === 'number') {
      return value !== Infinity && value !== -Infinity && value === value ? value : null
    }
    if (typeof value === 'string') {
      const parsed = parseFloat(value)
      return parsed !== Infinity && parsed !== -Infinity && parsed === parsed ? parsed : null
    }
    return null
  }

  findNumber(data: Record<string, Object>, keys: string[]): number | null {
    for (let i = 0; i < keys.length; i++) {
      const value = data[keys[i]]
      const parsed = this.readNumber(value as number | string | undefined)
      if (parsed !== null) {
        return parsed
      }
    }

    const nestedKeys: string[] = ['data', 'sensor', 'payload', 'msg', 'message']
    for (let i = 0; i < nestedKeys.length; i++) {
      const nested = data[nestedKeys[i]]
      if (typeof nested === 'object' && nested !== null) {
        const parsed = this.findNumber(nested as Record<string, Object>, keys)
        if (parsed !== null) {
          return parsed
        }
      }
    }

    return null
  }

  receiveLightStatus(jsonStr: string): void {
    console.info(`[HW][receiveLightStatus] raw=${jsonStr}`)
    try {
      const data: LightStatusPacket = JSON.parse(jsonStr) as LightStatusPacket
      this.applyLightStatus(data, 'DIRECT')
    } catch (err) {
      console.info(`[HW][receiveLightStatus][parse-error] ${JSON.stringify(err)}`)
    }
  }

  applyLightStatus(data: LightStatusPacket, source: string = 'LIVE'): void {
    const now = Date.now()
    const isCachedBridgeState = source === 'HTTP_BOOT' || source === 'TLS_BOOT'
    const ledState = this.readBoolLike(data.led)
    if (ledState !== null) {
      this.hasLiveLedStatus = true
      if (this.livingLightPending && this.hasLivingLightPendingTarget && ledState !== this.livingLightPendingTargetOn) {
        console.info(`[LED][status-ignore] pending seq=${this.ledPendingSeq} device=${ledState} target=${this.livingLightPendingTargetOn}`)
        return
      }
      if (this.livingLightPending && (!this.hasLivingLightPendingTarget || ledState === this.livingLightPendingTargetOn)) {
        this.livingLightPending = false
        this.ledPendingSeq = 0
        this.hasLivingLightPendingTarget = false
        this.livingLightControlInFlight = false
        this.clearLivingLightControlTimer()
      }
      this.livingLightOptimisticUntil = 0
      this.setLivingLightFromDevice(ledState)
      if (data.ledLock?.owner === 'dayu') {
        const ttl = typeof data.ledLock.ttlMs === 'number' ? Math.max(0, Math.round(data.ledLock.ttlMs)) : 0
        this.livingLightAckText = ttl > 0 ? `已锁定 ${Math.ceil(ttl / 1000)}s` : '已同步'
      } else {
        this.livingLightAckText = '设备状态已同步'
      }
    }
    if (typeof data.living === 'boolean') {
      if (this.livingLightPending && this.hasLivingLightPendingTarget) {
        if (data.living === this.livingLightPendingTargetOn) {
          this.livingLightPending = false
          this.ledPendingSeq = 0
          this.hasLivingLightPendingTarget = false
          this.livingLightControlInFlight = false
          this.clearLivingLightControlTimer()
          this.livingLightOptimisticUntil = 0
          this.setLivingLightFromDevice(data.living)
          this.livingLightAckText = '设备状态已同步'
        } else {
          console.info(`[LED][living-ignore] pending seq=${this.ledPendingSeq} cached=${data.living} target=${this.livingLightPendingTargetOn}`)
        }
      } else if (!isCachedBridgeState || !this.hasLiveLedStatus) {
        if (now < this.livingLightOptimisticUntil && data.living !== this.livingLightOn) {
          console.info(`[LED][living-ignore] ${source} optimistic cached=${data.living} ui=${this.livingLightOn}`)
        } else {
          this.setLivingLightFromDevice(data.living)
        }
      } else {
        console.info(`[LED][living-ignore] ${source} cached=${data.living} hasLiveLedStatus=${this.hasLiveLedStatus}`)
      }
    }
    if (typeof data.bedroom === 'boolean') {
      this.bedroomLightOn = data.bedroom
    }
    if (typeof data.pirEnabled === 'boolean') {
      this.pirEnabled = data.pirEnabled
    }
    const lockedState = this.readBoolLike(data.locked)
    const doorOpenState = this.readBoolLike(data.door)
    if (lockedState !== null) {
      this.doorLocked = lockedState
      const owner = data.doorLock?.owner ?? data.source ?? 'esp32'
      this.doorAckText = owner === 'dayu' ? '大禹门锁状态已同步' : '设备门锁状态已同步'
    }
    if (doorOpenState !== null) {
      this.doorOpen = doorOpenState
      this.hasDoorOpenStatus = true
      const owner = data.doorLock?.owner ?? data.source ?? 'esp32'
      this.doorAckText = owner === 'dayu' ? '大禹开门状态已同步' : '设备开门状态已同步'
    }
    const reportedLocked = lockedState
    if (this.doorPending && reportedLocked !== null && reportedLocked === this.doorPendingTargetLocked) {
      const confirmedSeq = this.doorPendingSeq
      this.doorPending = false
      this.doorPendingSeq = 0
      this.clearDoorAckTimer()
      this.doorAckText = `设备状态已确认 #${confirmedSeq}`
      console.info(`[DOOR][status-confirm] seq=${confirmedSeq} locked=${reportedLocked}`)
    }
    if (ledState !== null || lockedState !== null || doorOpenState !== null) {
      this.reportCloudLight(data)
    }
  }

  setLivingLightFromDevice(value: boolean): void {
    if (this.livingLightOn === value) {
      return
    }
    this.lastDeviceLivingLightValue = value
    this.lastDeviceLivingLightChangeAt = Date.now()
    this.suppressLivingLightChange = true
    this.livingLightOn = value
    setTimeout(() => {
      this.suppressLivingLightChange = false
    }, 800)
  }

  readBoolLike(value: boolean | number | string | undefined): boolean | null {
    if (typeof value === 'boolean') {
      return value
    }
    if (typeof value === 'number') {
      if (value === 1) {
        return true
      }
      if (value === 0) {
        return false
      }
    }
    if (typeof value === 'string') {
      const normalized = value.toLowerCase()
      if (normalized === '1' || normalized === 'true' || normalized === 'on') {
        return true
      }
      if (normalized === '0' || normalized === 'false' || normalized === 'off') {
        return false
      }
    }
    return null
  }

  handleDeviceStatusJson(jsonStr: string, deviceId: string = this.activeDeviceId): boolean {
    try {
      if (this.registerDeviceHello(jsonStr, deviceId)) {
        return true
      }
      const data = JSON.parse(jsonStr) as Record<string, Object>
      const payloadDeviceId = data['deviceId'] as string
      if (typeof payloadDeviceId === 'string' && this.normalizeDeviceId(payloadDeviceId) !== deviceId) {
        console.info(`[DEVICE][payload-reject] source=${deviceId} payload=${payloadDeviceId}`)
        return true
      }
      const type = data['type'] as string
      if (this.handleDeviceBoot(data)) {
        return true
      }
      if (typeof type === 'string' && type.toLowerCase() === 'alarm') {
        this.handleAlarmEvent(data, deviceId)
        return true
      }
      if (type === 'ack') {
        this.handleDeviceAck(data, deviceId)
        return true
      }
      const rawCmd = data['cmd'] as string
      if (typeof rawCmd === 'string' && rawCmd.toLowerCase() === 'ac') {
        console.info('[AC][echo] ignore outbound command echoed by esp32/ac subscription')
        return true
      }

      const ledState = this.readBoolLike(data['led'] as boolean | number | string | undefined)
      if (ledState !== null && deviceId === this.deviceForCapability('light')) {
        const lightStatus: LightStatusPacket = {
          led: ledState,
          ledLock: data['ledLock'] as LedLockStatus | undefined,
          seq: typeof data['seq'] === 'number' ? data['seq'] as number : undefined
        }
        this.applyLightStatus(lightStatus, 'DEVICE_JSON')
      }
      const lockedState = this.readBoolLike(data['locked'] as boolean | number | string | undefined)
      const doorState = this.readBoolLike(data['door'] as boolean | number | string | undefined)
      if ((lockedState !== null || doorState !== null) && deviceId === this.deviceForCapability('door')) {
        this.applyLightStatus({
          locked: lockedState !== null ? lockedState : undefined,
          door: doorState !== null ? doorState : undefined,
          doorLock: data['doorLock'] as LedLockStatus | undefined,
          source: data['source'] as string | undefined,
          seq: typeof data['seq'] === 'number' ? data['seq'] as number : undefined
        }, 'DEVICE_JSON')
      }
      const curtainPercent = this.findNumber(data, ['percent', 'openPercent', 'curtainPercent'])
      if (curtainPercent !== null && deviceId === this.deviceForCapability('curtain')) {
        const normalized = Math.max(0, Math.min(100, Math.round(curtainPercent)))
        this.curtainPercent = normalized
        this.reportCloudCurtain(normalized)
        console.info(`[CURTAIN][status] percent=${normalized}`)
      }
    } catch (err) {
      console.info(`[DeviceStatus][json-fail] ${(err as Error).message}`)
    }
    return false
  }

  parseAlarmReading(value: Object | undefined): AlarmReadingSnapshot {
    if (typeof value !== 'object' || value === null) {
      return { alarm: false, raw: 0, voltage: 0 }
    }
    const reading = value as Record<string, Object>
    const alarm = this.readBoolLike(reading['alarm'] as boolean | number | string | undefined)
    const raw = this.readNumber(reading['raw'] as number | string | undefined)
    const voltage = this.readNumber(reading['voltage'] as number | string | undefined)
    return {
      alarm: alarm === true,
      raw: raw === null ? 0 : raw,
      voltage: voltage === null ? 0 : voltage
    }
  }

  hasActiveDeviceAlarm(): boolean {
    return this.smokeAlarm || this.waterAlarm
  }

  refreshAlarmPresentation(): void {
    if (!this.hasActiveDeviceAlarm()) {
      this.alertLevel = 0
      this.alertMessage = '全屋设备运行正常'
      return
    }
    this.alertLevel = 3
    if (this.smokeAlarm && this.waterAlarm) {
      this.alertMessage = '检测到烟雾与水浸异常，请立即处理'
    } else if (this.smokeAlarm) {
      this.alertMessage = `检测到烟雾异常（ADC ${Math.round(this.smokeRaw)}）`
    } else {
      this.alertMessage = `检测到水浸异常（ADC ${Math.round(this.waterRaw)}）`
    }
  }

  handleAlarmEvent(data: Record<string, Object>, deviceId: string = this.activeDeviceId): void {
    const smoke = this.parseAlarmReading(data['smoke'])
    const water = this.parseAlarmReading(data['water'])
    if (!smoke.alarm && !water.alarm) {
      console.info('[ALARM][event-ignore] alarm packet has no active sensor')
      return
    }

    const signature = `${deviceId}|${smoke.alarm}|${Math.round(smoke.raw)}|${smoke.voltage.toFixed(3)}|` +
      `${water.alarm}|${Math.round(water.raw)}|${water.voltage.toFixed(3)}`
    const now = Date.now()
    if (signature === this.lastAlarmEventSignature && now - this.lastAlarmEventAt < 15000) {
      console.info(`[ALARM][duplicate] ${signature}`)
      return
    }
    this.lastAlarmEventSignature = signature
    this.lastAlarmEventAt = now

    this.smokeRaw = smoke.raw
    this.smokeVoltage = smoke.voltage
    this.waterRaw = water.raw
    this.waterVoltage = water.voltage
    this.alarmDeviceId = deviceId
    this.smokeAlarm = this.smokeAlarm || smoke.alarm
    this.waterAlarm = this.waterAlarm || water.alarm
    this.alarmClearConfirmed = false
    this.alarmAckText = '报警已收到，点击异常项处理'
    this.refreshAlarmPresentation()
    console.info(`[ALARM][event] smoke=${this.smokeAlarm} water=${this.waterAlarm} raw=${this.smokeRaw}/${this.waterRaw}`)
    this.reportCloudAlarmState('alarm')
    this.sendAlarmReceiptAck(smoke.alarm, water.alarm, deviceId).catch((err: Error) => {
      this.alarmAckText = `报警回执发送失败：${err.message}`
      console.info(`[ALARM][receipt-fail] ${err.message}`)
    })
  }

  reportCloudAlarmState(kind: string): void {
    const active = kind === 'alarm'
    const smokeReading: AlarmSensorReading = {
      alarm: active && this.smokeAlarm,
      raw: this.smokeRaw,
      voltage: this.smokeVoltage
    }
    const waterReading: AlarmSensorReading = {
      alarm: active && this.waterAlarm,
      raw: this.waterRaw,
      voltage: this.waterVoltage
    }
    let message = '本地智能终端已解除烟雾和水浸预警'
    if (active && this.smokeAlarm && this.waterAlarm) {
      message = '本地智能终端提示出现烟雾和水浸'
    } else if (active && this.smokeAlarm) {
      message = '本地智能终端提示出现烟雾'
    } else if (active && this.waterAlarm) {
      message = '本地智能终端提示出现水浸'
    }
    const sensor: SensorPacket = {
      smoke: smokeReading,
      water: waterReading,
      alertLevel: active ? 3 : 0,
      message
    }
    const packet: CloudIngestPacket = {
      source: 'dayu',
      kind,
      deviceId: 'esp32_living_001',
      deviceType: '设备节点',
      topic: 'esp32/alarm',
      text: message,
      crypto: this.cloudCryptoText(),
      level: active ? '高' : '低',
      result: active ? '已触发本地预警' : '设备已确认消警',
      sensor,
      state: active ? '报警中' : '已解除'
    }
    this.queueCloudAlarmReport(packet)
  }

  nextAlarmCommandSeq(): number {
    this.alarmCommandSeq = (this.alarmCommandSeq % 999999) + 1
    return this.alarmCommandSeq
  }

  async sendAlarmReceiptAck(smoke: boolean, water: boolean, deviceId: string): Promise<void> {
    const seq = this.nextAlarmCommandSeq()
    const ack = JSON.stringify({
      type: 'ack',
      cmd: 'alarm',
      action: 'received',
      ok: true,
      source: 'dayu',
      smoke,
      water,
      seq
    })
    await this.sendEncryptedCommand(this.normalizeBridgeUrl(this.bridgeUrl), ack, 'dayu/cmd', deviceId)
    console.info(`[ALARM][receipt] seq=${seq} smoke=${smoke} water=${water}`)
  }

  openAlarmClearDialog(target: string): void {
    const active = target === 'smoke' ? this.smokeAlarm : this.waterAlarm
    if (!active) {
      return
    }
    this.alarmDialogTarget = target
    this.showCriticalDialog = true
  }

  clearAlarmAckTimer(): void {
    if (this.alarmAckTimerId !== -1) {
      clearTimeout(this.alarmAckTimerId)
      this.alarmAckTimerId = -1
    }
  }

  startAlarmAckTimer(seq: number): void {
    this.clearAlarmAckTimer()
    this.alarmAckTimerId = setTimeout(() => {
      if (this.alarmPendingSeq === seq) {
        this.alarmClearPending = false
        this.alarmAckText = `设备消警确认超时 #${seq}`
        console.info(`[ALARM][off-timeout] seq=${seq}`)
      }
      this.alarmAckTimerId = -1
    }, 6000)
  }

  async requestAlarmClear(): Promise<void> {
    if (!this.hasActiveDeviceAlarm() || this.alarmClearPending) {
      return
    }
    const seq = this.nextAlarmCommandSeq()
    this.alarmPendingSeq = seq
    this.alarmClearPending = true
    this.alarmClearConfirmed = false
    this.alarmAckText = `正在通知设备关闭蜂鸣器 #${seq}`
    this.startAlarmAckTimer(seq)
    const cmd = JSON.stringify({ cmd: 'alarm', action: 'off', seq })
    const targetDeviceId = this.alarmDeviceId.length > 0 ? this.alarmDeviceId : this.activeDeviceId
    try {
      await this.sendEncryptedCommand(this.normalizeBridgeUrl(this.bridgeUrl), cmd, 'dayu/cmd', targetDeviceId)
      console.info(`[ALARM][off-sent] seq=${seq} device=${targetDeviceId}`)
    } catch (err) {
      this.clearAlarmAckTimer()
      this.alarmClearPending = false
      this.alarmAckText = `消警指令发送失败：${(err as Error).message}`
      console.info(`[ALARM][off-send-fail] seq=${seq} ${(err as Error).message}`)
    }
  }

  handleAlarmAck(data: Record<string, Object>, deviceId: string): void {
    const action = typeof data['action'] === 'string' ? (data['action'] as string).toLowerCase() : ''
    if (action !== 'off') {
      return
    }
    if (this.alarmDeviceId.length > 0 && deviceId !== this.alarmDeviceId) {
      console.info(`[ALARM][ack-ignore-device] expected=${this.alarmDeviceId} received=${deviceId}`)
      return
    }
    const seq = typeof data['seq'] === 'number' ? data['seq'] as number : 0
    if (this.alarmPendingSeq <= 0 || (seq > 0 && seq !== this.alarmPendingSeq)) {
      console.info(`[ALARM][ack-ignore] pending=${this.alarmPendingSeq} received=${seq}`)
      return
    }
    const ok = data['ok'] === true
    this.clearAlarmAckTimer()
    this.alarmClearPending = false
    if (!ok) {
      const msg = typeof data['msg'] === 'string' ? data['msg'] as string : '设备消警失败'
      this.alarmAckText = `${msg} #${seq}`
      console.info(`[ALARM][ack-fail] seq=${seq} msg=${msg}`)
      return
    }

    this.alarmPendingSeq = 0
    this.smokeAlarm = false
    this.waterAlarm = false
    this.alertLevel = 0
    this.alertMessage = '全屋设备运行正常'
    this.alarmClearConfirmed = true
    this.alarmAckText = `设备已关闭蜂鸣器 #${seq}`
    this.alarmDialogTarget = ''
    this.showCriticalDialog = false
    this.cryptoDebugText = `ALARM ACK #${seq}`
    console.info(`[ALARM][ack] cleared seq=${seq}`)
    this.reportCloudAlarmState('alarm_clear')
    this.alarmDeviceId = ''
  }

  handleDeviceBoot(data: Record<string, Object>): boolean {
    const rawType = data['type'] as string
    const type = typeof rawType === 'string' ? rawType.toLowerCase() : ''
    if (type !== 'boot' && type !== 'boost') {
      return false
    }
    const deviceId = typeof data['deviceId'] === 'string' ? data['deviceId'] as string : 'esp32'
    const epoch = typeof data['epoch'] === 'number' ? data['epoch'] as number : 0
    const rawKeySource = data['keySource'] as string
    const keySource = typeof rawKeySource === 'string' ? rawKeySource.toLowerCase() : ''
    const descriptor = this.loadDeviceRegistry()[deviceId]
    // A boot report describes the device state; it is not permission to
    // overwrite Dayu's selected transport and crypto mode.
    const bootCrypto = descriptor && descriptor.crypto.length > 0 ?
      this.normalizeCryptoMode(descriptor.crypto.toUpperCase()) : 'SM4'
    const bootTransport = descriptor && descriptor.transport.length > 0 ?
      this.normalizeProtocolMode(descriptor.transport.toUpperCase()) : 'MQTT'
    if (epoch !== 0 || keySource !== 'static') {
      return false
    }
    const now = Date.now()
    const pendingAt = this.lastEcdhPendingTimeByDevice.get(deviceId) ?? 0
    const installedAt = this.lastEcdhInstallTimeByDevice.get(deviceId) ?? 0
    const hasPendingRekey = this.keyExchange.getPendingKeys(deviceId) !== null || now - pendingAt < 15000
    const hasFreshDynamicKey = installedAt > 0 && now - installedAt < 15000
    if (hasPendingRekey || hasFreshDynamicKey) {
      console.info(`[BOOT] stale epoch=0 ignored during/following ECDH device=${deviceId} pending=${hasPendingRekey} fresh=${hasFreshDynamicKey}`)
      return true
    }
    const signature = `${deviceId}|${epoch}|${keySource}|${bootCrypto}|${bootTransport}`
    if (signature === this.lastDeviceBootSignature && now - this.lastDeviceBootAt < 15000) {
      console.info(`[BOOT] duplicate ignored ${signature}`)
      return true
    }
    this.lastDeviceBootSignature = signature
    this.lastDeviceBootAt = now
    this.resetDeviceCryptoSession(deviceId, bootCrypto, bootTransport)
    this.addMqttMessage(`${deviceId}/boot`, JSON.stringify(data))
    console.info(`[BOOT] ${deviceId} epoch=${epoch} keySource=${keySource} crypto=${bootCrypto} transport=${bootTransport}`)
    return true
  }

  resetDeviceCryptoSession(deviceId: string, cryptoMode: string, transport: string): void {
    clearDeviceDynamicCryptoKeys(deviceId)
    this.lastSuccessfulDecryptAtByDevice.delete(deviceId)
    this.decryptFailCountByDevice.delete(deviceId)
    this.lastEcdhPendingTimeByDevice.delete(deviceId)
    this.lastEcdhInstallTimeByDevice.delete(deviceId)
    this.updateDeviceDescriptorModes(deviceId, transport, cryptoMode)
    if (deviceId === this.activeDeviceId) {
      clearDynamicCryptoKeys()
      this.dynamicAesKeyBase64 = ''
      this.dynamicSm4KeyBase64 = ''
      this.lastEcdhPendingTime = 0
      this.lastEcdhInstallTime = 0
      this.decryptFailCount = 0
      this.deviceEpoch = 0
      this.deviceKeySource = 'static'
      this.applyCryptoMode(cryptoMode)
      if (this.protocolPendingMode.length === 0) {
        this.commandTransport = this.normalizeProtocolMode(transport)
      }
      this.cryptoDebugText = `设备重启，回静态${this.cryptoMode}`
      this.cryptoLastDecrypted = '设备 boot epoch=0'
    }
    this.keyExchange.resetDevice(deviceId)
    this.lastKeyExchangeTimestampByTopic.delete(`key/ecdh/pub/${deviceId}`)
    this.retryKeyExchangeSoon(deviceId)
  }

  retryKeyExchangeSoon(deviceId: string): void {
    const now = Date.now()
    if (now - this.lastBootRekeyAt < 2500) {
      return
    }
    this.lastBootRekeyAt = now
    setTimeout(() => {
      this.refreshBridgeKeyExchangeState(true).catch((err: Error) => {
        console.info(`[BOOT][key-state-refresh-fail] ${err.message}`)
      })
    }, 1000)
  }

  handleDeviceAck(data: Record<string, Object>, deviceId: string = this.activeDeviceId): void {
    const rawCmd = data['cmd'] as string
    const cmd = typeof rawCmd === 'string' ? rawCmd.toLowerCase() : ''
    if (cmd === 'alarm') {
      this.handleAlarmAck(data, deviceId)
      return
    }
    if (cmd === 'ac') {
      if (deviceId !== this.deviceForCapability('ac')) {
        console.info(`[AC][ack-ignore-device] expected=${this.deviceForCapability('ac')} received=${deviceId}`)
        return
      }
      this.handleACAck(data)
      return
    }
    if (cmd === 'ir') {
      if (deviceId !== this.deviceForCapability('ac')) {
        console.info(`[IR][ack-ignore-device] expected=${this.deviceForCapability('ac')} received=${deviceId}`)
        return
      }
      this.handleIrAck(data)
      return
    }
    if (cmd === 'door') {
      if (deviceId !== this.deviceForCapability('door')) {
        console.info(`[DOOR][ack-ignore-device] expected=${this.deviceForCapability('door')} received=${deviceId}`)
        return
      }
      this.handleDoorAck(data)
      return
    }
    if (cmd === 'curtain') {
      if (deviceId !== this.deviceForCapability('curtain')) {
        console.info(`[CURTAIN][ack-ignore-device] expected=${this.deviceForCapability('curtain')} received=${deviceId}`)
        return
      }
      const percent = this.findNumber(data, ['percent', 'val', 'openPercent', 'curtainPercent'])
      if (percent !== null && data['ok'] === true) {
        const normalized = Math.max(0, Math.min(100, Math.round(percent)))
        this.curtainPercent = normalized
        this.reportCloudCurtain(normalized)
        console.info(`[CURTAIN][ack] percent=${normalized}`)
      }
      return
    }
    if (cmd !== 'led') {
      return
    }
    if (deviceId !== this.deviceForCapability('light')) {
      console.info(`[LED][ack-ignore-device] expected=${this.deviceForCapability('light')} received=${deviceId}`)
      return
    }

    const seq = typeof data['seq'] === 'number' ? data['seq'] as number : 0
    const ok = data['ok'] === true
    const ledState = this.readBoolLike(data['val'] as boolean | number | string | undefined)
    const acknowledgedLightOn = ledState !== null ? ledState :
      (this.hasLivingLightPendingTarget ? this.livingLightPendingTargetOn : this.livingLightOn)
    if (this.livingLightPending && seq > 0 && seq !== this.ledPendingSeq) {
      console.info(`[LED][ack-ignore] pending=${this.ledPendingSeq} stale=${seq} val=${ledState}`)
      return
    }
    if (ledState !== null && ok) {
      this.hasLiveLedStatus = true
      this.livingLightOptimisticUntil = 0
      this.setLivingLightFromDevice(ledState)
    }
    if (seq === 0 || seq === this.ledPendingSeq) {
      this.livingLightPending = false
      this.ledPendingSeq = 0
      this.hasLivingLightPendingTarget = false
      this.livingLightControlInFlight = false
      this.livingLightOptimisticUntil = 0
      this.clearLivingLightControlTimer()
    }
    this.livingLightAckText = ok ? `已执行${acknowledgedLightOn ? '开灯' : '关灯'}` : '执行失败，请重试'
    this.cryptoDebugText = ok ? `LED ACK #${seq}` : `LED ACK失败 #${seq}`
    if (ok) {
      const status: LightStatusPacket = {
        living: acknowledgedLightOn,
        locked: this.doorLocked,
        source: 'esp32',
        seq
      }
      if (this.hasDoorOpenStatus) {
        status.door = this.doorOpen
      }
      this.reportCloudLight(status)
    }
    console.info(`[LED][ack] ok=${ok} seq=${seq} val=${ledState}`)
  }

  handleDoorAck(data: Record<string, Object>): void {
    const seq = typeof data['seq'] === 'number' ? data['seq'] as number : 0
    const ok = data['ok'] === true
    const lockedState = this.readBoolLike(data['locked'] as boolean | number | string | undefined)
    const doorOpenState = this.readBoolLike(data['door'] as boolean | number | string | undefined)
    const valState = this.readBoolLike(data['val'] as boolean | number | string | undefined)
    if (this.doorPendingSeq > 0 && seq > 0 && seq !== this.doorPendingSeq) {
      console.info(`[DOOR][ack-ignore] pending=${this.doorPendingSeq} stale=${seq}`)
      return
    }
    this.doorPending = false
    this.doorPendingSeq = 0
    this.clearDoorAckTimer()
    if (ok) {
      if (lockedState !== null) {
        this.doorLocked = lockedState
      } else if (valState !== null) {
        this.doorLocked = !valState
      } else {
        this.doorLocked = this.doorPendingTargetLocked
      }
      if (doorOpenState !== null) {
        this.doorOpen = doorOpenState
        this.hasDoorOpenStatus = true
      }
    }
    this.doorAckText = ok ? `设备门锁已执行 #${seq}` : `设备门锁失败 #${seq}`
    this.cryptoDebugText = ok ? `DOOR ACK #${seq}` : `DOOR ACK失败 #${seq}`
    if (ok) {
      const status: LightStatusPacket = {
        locked: this.doorLocked,
        source: 'esp32',
        seq
      }
      if (this.hasDoorOpenStatus) {
        status.door = this.doorOpen
      }
      this.reportCloudLight(status)
    }
    console.info(`[DOOR][ack] ok=${ok} seq=${seq} locked=${this.doorLocked}`)
  }

  handleACAck(data: Record<string, Object>): void {
    const seq = typeof data['seq'] === 'number' ? data['seq'] as number : 0
    const ok = data['ok'] === true
    if (this.acPendingSeq > 0 && seq > 0 && seq !== this.acPendingSeq) {
      console.info(`[AC][ack-ignore] pending=${this.acPendingSeq} stale=${seq}`)
      return
    }

    if (ok) {
      const power = this.readBoolLike(data['power'] as boolean | number | string | undefined)
      const temp = this.readNumber(data['temp'] as number | string | undefined)
      const mode = typeof data['mode'] === 'string' ? (data['mode'] as string).toLowerCase() : ''
      if (power !== null) {
        this.acPower = power
      }
      if (temp !== null && temp >= 16 && temp <= 30) {
        this.acTemp = Math.round(temp)
      }
      if (mode === 'cool' || mode === 'heat') {
        this.acMode = mode
      }
    }

    this.clearACAckTimer()
    this.acPendingSeq = 0
    this.acAckText = ok ? `设备已执行 #${seq}` : `设备执行失败 #${seq}`
    this.cryptoDebugText = ok ? `AC ACK #${seq}` : `AC ACK失败 #${seq}`
    console.info(`[AC][ack] ok=${ok} seq=${seq} power=${this.acPower} temp=${this.acTemp} mode=${this.acMode}`)
  }

  // ── 加密数据处理器 ────────────────────────────────────────────────
  /**
   * 直接解密 Uint8Array（MQTT 直连时使用，无需 base64 中转）
   */
  async handleEncryptedRaw(raw: Uint8Array, topic: string = 'esp32/sensor',
    deviceId: string = this.activeDeviceId): Promise<void> {
    console.info(`[Crypto] decrypting ${raw.length} bytes raw encrypted payload on ${topic}`)
    try {
      if (deviceId === this.activeDeviceId && await this.tryHandleCryptoSwitchAck(raw)) {
        return
      }
      const decrypted = await this.decryptIncomingPayload(raw, 'MQTT', deviceId)
      const jsonStr = decrypted.plaintext
      const decryptedAt = Date.now()
      this.lastSuccessfulDecryptAtByDevice.set(deviceId, decryptedAt)
      this.decryptFailCountByDevice.delete(deviceId)
      if (deviceId === this.activeDeviceId) {
        this.lastSuccessfulDecryptAt = decryptedAt
      }
      console.info(`[Crypto] decrypted OK: ${jsonStr.substring(0, 80)}`)
      if (decrypted.keySource === 'provided' && this.isKeyExchangeAck(jsonStr)) {
        return
      }
      if (this.handleKeyExchangeAckJson(jsonStr, 'MQTT', decrypted.mode, deviceId)) {
        return
      }
      if (deviceId === this.activeDeviceId) {
        this.decryptFailCount = 0
        this.cryptoEnabled = true
        this.cryptoLastDecrypted = new Date().toLocaleTimeString() + ' OK'
        this.cryptoDebugText = `MQTT解密OK ${decrypted.mode} ${jsonStr.substring(0, 24)}`
      }
      if (deviceId === this.activeDeviceId && this.tryCompleteProtocolSwitchFromJson(jsonStr, 'MQTT')) {
        return
      }
      if (deviceId === this.activeDeviceId) {
        this.tryCompleteProtocolSwitchFromObservedPayload('MQTT')
      }
      if (this.protocolPendingMode.length > 0) {
        console.info(`[PROTO] ignore non-switch MQTT payload while pending=${this.protocolPendingMode}`)
        return
      }
      this.addMqttMessage(topic, jsonStr)
      setTimeout(() => {
        if (this.handleDeviceStatusJson(jsonStr, deviceId)) {
          return
        }
        this.applySensorJson(jsonStr, 'MQTT', deviceId)
      }, 0)
    } catch (err) {
      const message = (err as Error).message
      console.info(`[Crypto][decrypt-fail] ${message}`)
      this.handleDecryptFailure(deviceId, 'MQTT')
      if (deviceId === this.activeDeviceId) {
        this.cryptoLastDecrypted = 'decrypt fail'
        this.cryptoDebugText = `MQTT解密失败 ${message}`
      }
      this.addMqttMessage(topic, `[err] ${raw.length}B decrypt fail ${message}`)
    }
  }

  /**
   * 处理来自 broker HTTP 的加密 payload（base64 编码的 IV+TAG+CIPHER）
   */
  async handleEncryptedPayload(payloadBase64: string, source: string = 'HTTP', topic: string = 'esp32/sensor',
    deviceId: string = this.activeDeviceId, allowKeyRecovery: boolean = true): Promise<void> {
    if (payloadBase64.length === 0) {
      return
    }
    if (this.isDuplicateEncryptedPayload(topic, payloadBase64)) {
      console.info(`[Crypto][duplicate-skip] topic=${topic} source=${source} ${payloadBase64.length}B64`)
      return
    }
    try {
      // 步骤1: base64 解码
      const raw = this.base64ToUint8Array(payloadBase64)
      console.info(`[Crypto] received topic=${topic} source=${source} ${raw.length} bytes encrypted payload`)

      if (deviceId === this.activeDeviceId && await this.tryHandleCryptoSwitchAck(raw)) {
        return
      }

      // 步骤2: 使用当前选择的 GCM 算法严格解密
      const decrypted = await this.decryptIncomingPayload(raw, source, deviceId)
      const jsonStr = decrypted.plaintext
      const payloadSource = this.resolvePayloadSource(source, jsonStr)
      const decryptedAt = Date.now()
      this.lastSuccessfulDecryptAtByDevice.set(deviceId, decryptedAt)
      this.decryptFailCountByDevice.delete(deviceId)
      if (deviceId === this.activeDeviceId) {
        this.lastSuccessfulDecryptAt = decryptedAt
      }
      console.info(`[Crypto] decrypted: ${jsonStr.substring(0, 80)}...`)
      if (decrypted.keySource === 'provided' && this.isKeyExchangeAck(jsonStr)) {
        return
      }
      if (this.handleKeyExchangeAckJson(jsonStr, payloadSource, decrypted.mode, deviceId)) {
        return
      }
      if (deviceId === this.activeDeviceId) {
        this.decryptFailCount = 0
        this.cryptoEnabled = true
        this.cryptoLastDecrypted = new Date().toLocaleTimeString() + ' ✓'
        this.cryptoDebugText = `${payloadSource}解密OK ${decrypted.mode} ${jsonStr.substring(0, 24)}`
      }

      if (deviceId === this.activeDeviceId && this.tryCompleteProtocolSwitchFromJson(jsonStr, payloadSource)) {
        return
      }
      if (deviceId === this.activeDeviceId) {
        this.tryCompleteProtocolSwitchFromObservedPayload(payloadSource)
      }
      if (this.protocolPendingMode.length > 0) {
        console.info(`[PROTO] ignore non-switch ${payloadSource} payload while pending=${this.protocolPendingMode}`)
        return
      }

      this.addMqttMessage(topic, jsonStr)
      if (this.handleDeviceStatusJson(jsonStr, deviceId)) {
        return
      }
      this.applySensorJson(jsonStr, payloadSource, deviceId)

      const data = JSON.parse(jsonStr) as SensorPacket
      const rawData = data as Object as Record<string, Object>
      if (typeof rawData['lux'] === 'number') {
        // 光照度 — 暂不显示在 UI，仅日志
        console.info(`[Crypto] lux=${rawData['lux']}`)
      }
      if (typeof rawData['pir'] === 'number') {
        // PIR 人体检测映射到 alertLevel
        const pirVal = rawData['pir'] as number
        if (pirVal === 1 && this.alertLevel < 1) {
          this.alertLevel = 1
          this.alertMessage = '检测到人员活动'
        }
      }
      if (typeof rawData['proto'] === 'string') {
        console.info(`[Crypto] proto=${rawData['proto']}, dev=${rawData['dev']}`)
      }
    } catch (err) {
      const message = (err as Error).message
      console.info(`[Crypto][decrypt-fail] topic=${topic} source=${source} ${message}`)
      if (source === 'HTTP_SENSOR' && !allowKeyRecovery) {
        // /api/state returns a rolling history. Old-session packets must not force
        // the current command key back to static while the live channel is healthy.
        console.info('[ECDH][recover-skip] HTTP sensor history is not a key-recovery signal')
      } else if (this.irLearnActive && topic === 'esp32/ac') {
        console.info(`[ECDH][recover-skip] keep IR learning key after ${source} decrypt failure`)
      } else {
        this.handleDecryptFailure(deviceId, source)
      }
      if (deviceId === this.activeDeviceId) {
        this.cryptoLastDecrypted = '解密失败: ' + message
        this.cryptoDebugText = `${source}解密失败 ${message}`
      }
      this.addMqttMessage(topic, `[err] ${source} ${payloadBase64.length}B64 decrypt fail ${message}`)
    }
  }

  isDuplicateEncryptedPayload(topic: string, payloadBase64: string): boolean {
    const now = Date.now()
    const key = `${topic}|${payloadBase64}`
    const previous = this.recentEncryptedPayloads.get(key) ?? 0
    if (previous > 0 && now - previous < 5000) {
      return true
    }
    this.recentEncryptedPayloads.set(key, now)
    if (this.recentEncryptedPayloads.size > 80) {
      const expiresBefore = now - 10000
      this.recentEncryptedPayloads.forEach((receivedAt: number, cachedKey: string) => {
        if (receivedAt < expiresBefore) {
          this.recentEncryptedPayloads.delete(cachedKey)
        }
      })
    }
    return false
  }

  deviceIdFromTopic(topic: string): string {
    return this.deviceIdFromScopedTopic(topic)
  }

  isIrLearningKeyExchangeLocked(): boolean {
    return this.irLearnActive || this.irLearnHandshakeConfirmed
  }

  handleDecryptFailure(deviceId: string, source: string): void {
    if (this.isIrLearningKeyExchangeLocked()) {
      console.info(`[ECDH][locked-by-ir] ignore ${source} decrypt recovery during learn-all`)
      return
    }
    const now = Date.now()
    const failCount = (this.decryptFailCountByDevice.get(deviceId) ?? 0) + 1
    this.decryptFailCountByDevice.set(deviceId, failCount)
    if (deviceId === this.activeDeviceId) {
      this.decryptFailCount = failCount
    }
    const successfulAt = this.lastSuccessfulDecryptAtByDevice.get(deviceId) ?? 0
    if (successfulAt > 0 && now - successfulAt < 6000) {
      console.info(`[ECDH][recover-skip] ${source} device=${deviceId} has a successful decrypt ${now - successfulAt}ms ago`)
      return
    }
    const pendingAt = this.lastEcdhPendingTimeByDevice.get(deviceId) ?? 0
    if (this.keyExchange.getPendingKeys(deviceId) !== null && now - pendingAt < 15000) {
      console.info(`[ECDH][recover-skip] ${source} decrypt failed while waiting key ACK`)
      return
    }
    const installedAt = this.lastEcdhInstallTimeByDevice.get(deviceId) ?? 0
    if (installedAt > 0 && now - installedAt < 8000) {
      console.info(`[ECDH][recover-skip] ${source} decrypt failed during key switch grace`)
      return
    }
    const recoveryAt = this.lastEcdhRecoveryTimeByDevice.get(deviceId) ?? 0
    if (failCount < 3 || this.ecdhRecoveryDevices.has(deviceId) || now - recoveryAt < 20000) {
      return
    }
    this.lastEcdhRecoveryTimeByDevice.set(deviceId, now)
    this.ecdhRecoveryDevices.add(deviceId)
    this.lastEcdhRecoveryTime = now
    this.ecdhRecoveryInProgress = true
    console.info(`[ECDH][recover] ${source} decrypt failed ${failCount} times, publish local key for ${deviceId}`)
    if (deviceId === this.activeDeviceId) {
      this.cryptoDebugText = `连续解密失败，重新ECDH ${deviceId}`
    }
    this.switchDeviceToStaticCryptoSession(deviceId, `recover-${source}`, this.cryptoModeForDevice(deviceId))
    this.startKeyExchange(deviceId, `recover-${source}`).finally(() => {
      this.ecdhRecoveryDevices.delete(deviceId)
      this.ecdhRecoveryInProgress = this.ecdhRecoveryDevices.size > 0
    })
  }

  async retryKeyExchange(deviceId: string): Promise<void> {
    if (this.isIrLearningKeyExchangeLocked()) {
      console.info(`[ECDH][locked-by-ir] defer retry for ${deviceId}`)
      return
    }
    try {
      this.keyExchange.resetDevice(deviceId)
      this.lastEcdhPendingTime = 0
      this.lastEcdhPendingTimeByDevice.delete(deviceId)
      this.lastKeyExchangeTimestampByTopic.delete(`key/ecdh/pub/${deviceId}`)
      await this.startKeyExchange(deviceId, 'retry')
    } catch (err) {
      console.info(`[ECDH][recover-fail] ${(err as Error).message}`)
    }
  }

  async startKeyExchange(deviceId: string, source: string): Promise<void> {
    if (this.isIrLearningKeyExchangeLocked()) {
      console.info(`[ECDH][locked-by-ir] defer start source=${source} device=${deviceId}`)
      return
    }
    await this.refreshBridgeKeyExchangeState(true)
    if (this.keyExchange.getPendingKeys(deviceId) !== null) {
      this.lastEcdhPendingTime = Date.now()
      this.lastEcdhPendingTimeByDevice.set(deviceId, this.lastEcdhPendingTime)
      this.cryptoDebugText = `ECDH等待ACK ${deviceId}`
      this.addMqttMessage(`key/ecdh/pub/${deviceId}`, `[ECDH:PENDING:${source}] cached device public key`)
      return
    }

    await this.requestDevicePublicKey(deviceId, source)
  }

  nextKeySyncSeq(): number {
    this.keySyncSeq = (this.keySyncSeq % 999999) + 1
    return this.keySyncSeq
  }

  async requestDevicePublicKey(deviceId: string, source: string): Promise<void> {
    if (this.isIrLearningKeyExchangeLocked()) {
      console.info(`[ECDH][locked-by-ir] suppress key/pub source=${source} device=${deviceId}`)
      return
    }
    const localKey = await this.keyExchange.createLocalPublicKey(deviceId)
    if (localKey.replyTopic && localKey.replyPublicKey) {
      const sent = await this.sendEcdhPublicKey(localKey.replyTopic, localKey.replyPublicKey)
      if (sent) {
        this.cryptoDebugText = `已向设备发送ECDH公钥 ${deviceId}`
        this.addMqttMessage(localKey.replyTopic,
          `[ECDH:BOOTSTRAP:${source}] ${localKey.replyPublicKey.length}B public key`)
        console.info(`[ECDH][bootstrap] local public key sent to ${deviceId} via ${this.transportForDevice(deviceId)}`)
        return
      }
    }

    const seq = this.nextKeySyncSeq()
    const cmd = JSON.stringify({
      cmd: 'key',
      action: 'pub',
      deviceId,
      source: 'dayu',
      seq
    })
    try {
      await this.sendEncryptedCommand(this.normalizeBridgeUrl(this.bridgeUrl), cmd, 'dayu/cmd', deviceId)
      this.cryptoDebugText = `已请求设备重发公钥 #${seq}`
      this.addMqttMessage(`key/ecdh/pub/${deviceId}`, `[ECDH:REQ:${source}] request device public key #${seq}`)
    } catch (err) {
      this.cryptoDebugText = `请求设备公钥失败 ${(err as Error).message}`
      this.addMqttMessage(`key/ecdh/pub/${deviceId}`, `[ECDH:REQ:FAIL] ${(err as Error).message}`)
    }
  }

  /**
   * Base64 string -> Uint8Array (no string intermediate, binary-safe)
   */
  base64ToUint8Array(base64: string): Uint8Array {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    // strip padding & whitespace
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

  /**
   * Uint8Array -> Base64 string
   */
  uint8ArrayToBase64(data: Uint8Array): string {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    let result = ''
    const len = data.length
    for (let i = 0; i < len; i += 3) {
      const b0 = data[i]
      const b1 = i + 1 < len ? data[i + 1] : 0
      const b2 = i + 2 < len ? data[i + 2] : 0
      result += chars.charAt(b0 >> 2)
      result += chars.charAt(((b0 & 3) << 4) | (b1 >> 4))
      result += i + 1 < len ? chars.charAt(((b1 & 15) << 2) | (b2 >> 6)) : '='
      result += i + 2 < len ? chars.charAt(b2 & 63) : '='
    }
    return result
  }

  bytesToHex(data: Uint8Array): string {
    return Array.from(data).map((b: number) => b.toString(16).padStart(2, '0')).join('')
  }

  // ── MQTT 直连 ────────────────────────────────────────────────────
  setupMqtt(): void {
    this.mqtt.setCallbacks(
      (topic: string, payload: Uint8Array) => {
        this.handleMqttPacket(topic, payload, false)
      },
      (connected: boolean, message: string) => {
        this.mqttConnected = connected
        this.mqttStatus = message
        if (connected) {
          this.bridgeConnected = true
          this.bridgeLinkConnected = true
          if (!this.bridgeTlsConnected) {
            this.bridgeLastMessage = 'MQTT 已连接'
          }
          this.flushPendingEcdhReply()
        } else if (!this.bridgeTlsConnected && !this.bridgeTls.isConnected()) {
          if (this.bridgeConnected && Date.now() - this.lastBridgeOkAt < 10000) {
            this.bridgeLinkConnected = true
            this.bridgeLastMessage = 'Bridge 已连接，MQTT 重连中'
          } else {
            this.bridgeConnected = false
            this.bridgeLinkConnected = false
          }
        }
      }
    )
  }

  setupLocalMqtt(): void {
    this.localMqtt.setCallbacks(
      (topic: string, payload: Uint8Array): void => {
        this.handleMqttPacket(topic, payload, true)
      },
      (connected: boolean, message: string): void => {
        console.info(`[LocalGateway][MQTT-client] connected=${connected} ${message}`)
      }
    )
  }

  async connectLocalMqtt(): Promise<void> {
    try {
      this.localMqtt.setBroker('127.0.0.1', 1883, false)
      await this.localMqtt.connect()
      await this.localMqtt.subscribe('esp32/sensor', 0)
      await this.localMqtt.subscribe('esp32/status', 1)
      await this.localMqtt.subscribe('esp32/ac', 1)
      await this.localMqtt.subscribe('smart_home/esp32/sensor/indoor', 0)
      await this.localMqtt.subscribe('device/+/+', 1)
      await this.localMqtt.subscribe('key/ecdh/pub/+', 1)
      console.info('[LocalGateway][MQTT-client] subscribed to local broker')
    } catch (err) {
      console.info(`[LocalGateway][MQTT-client] connect failed ${(err as Error).message}`)
    }
  }

  handleMqttPacket(topic: string, payload: Uint8Array, fromLocalGateway: boolean): void {
    const time = new Date().toLocaleTimeString()
    this.mqttLastMsgTime = time
    const route = fromLocalGateway ? 'LOCAL' : 'REMOTE'
    console.info(`[MQTT][${route}] msg on ${topic}: ${payload.length}B`)
    const packetDeviceId = this.registerDeviceId(this.deviceIdFromScopedTopic(topic))
    if (fromLocalGateway) {
      this.localGatewayDeviceIds.add(packetDeviceId)
      if (!this.keyExchange.isKeyExchangeTopic(topic) || !this.isRecentlySentEcdhPublicKey(payload)) {
        this.localGatewayTransportByDevice.set(packetDeviceId, 'MQTT')
      }
    }

    if (this.keyExchange.isKeyExchangeTopic(topic)) {
      this.handleEcdhPublicKey(topic, payload)
      return
    }
    if (packetDeviceId !== this.activeDeviceId) {
      console.info(`[DEVICE] process background MQTT packet from ${packetDeviceId}; active=${this.activeDeviceId}`)
    }

    const isStatusTopic = topic === 'esp32/status' || topic.endsWith('/status')
    if (!isStatusTopic && this.transportForDevice(packetDeviceId) !== 'MQTT' &&
      !this.shouldProcessBusinessSource('MQTT')) {
      console.info(`[PROTO] ignore MQTT ${topic} while active=${this.commandTransport} pending=${this.protocolPendingMode}`)
      return
    }

    if (looksEncrypted(payload)) {
      this.handleEncryptedRaw(payload, topic, packetDeviceId)
      return
    }
    const decoder = new util.TextDecoder()
    const text = decoder.decodeWithStream(payload)
    this.addMqttMessage(topic, text)
    try {
      if (this.handleDeviceStatusJson(text, packetDeviceId)) {
        return
      }
      const sensor: SensorPacket = JSON.parse(text) as SensorPacket
      setTimeout(() => {
        this.applySensorData(sensor, 'MQTT', packetDeviceId)
      }, 0)
    } catch (_) { /* ignore */ }
  }

  setupBridgeTls(): void {
    const context = getContext(this) as common.UIAbilityContext
    this.bridgeTls.configureCertificateDirectory(context.filesDir)
    for (let i = 0; i < this.cloudSecureClients.length; i++) {
      this.cloudSecureClients[i].configureMutualTls(context.filesDir)
    }
    this.cloudMqttTransport.configureCertificateDirectory(context.filesDir)
    this.cloudMqttSecureClient.configureMutualTls(context.filesDir)
    this.cloudMqttSecureClient.configureRequestHandler((path: string, body: string): Promise<string> => {
      return this.cloudMqttTransport.request(path, body)
    })
    this.bridgeTls.setCallbacks(
      (message: BridgeTlsJson) => {
        this.handleBridgeTlsMessage(message)
      },
      (connected: boolean, message: string) => {
        this.bridgeTlsConnected = connected
        this.bridgeConnected = connected || this.bridgeConnected
        if (connected) {
          this.bridgeLinkConnected = true
          this.bridgeLastMessage = 'BridgeTLS 已连接'
          this.addMqttMessage('bridge/tls', `[CONNECTED] ${message}`)
          this.flushPendingEcdhReply()
        } else {
          this.bridgeLastMessage = message
        }
      }
    )
  }

  handleBridgeTlsMessage(message: BridgeTlsJson): void {
    const type = message['type'] as string
    const debugTopic = (message['topic'] as string) ?? ''
    const payloadSource = this.bridgePayloadSource(message)
    if (debugTopic.startsWith('key/ecdh/pub/')) {
      console.info(`[ECDH] BridgeTLS message type=${type} topic=${debugTopic}`)
    }
    const earlyPayloadBase64 = message['payloadBase64'] as string
    if (debugTopic.length > 0 && earlyPayloadBase64 && this.keyExchange.isKeyExchangeTopic(debugTopic)) {
      const timestamp = (message['timestamp'] as number) ?? Date.now()
      this.handleEcdhPublicKey(debugTopic, this.base64ToUint8Array(earlyPayloadBase64), timestamp)
      return
    }
    const earlyKeyExchange = message['keyExchange'] as KeyExchangeBridgePacket | undefined
    if (earlyKeyExchange?.devices) {
      this.handleCachedKeyExchangeDevices(earlyKeyExchange.devices)
    }
    if (type === 'pong') {
      return
    }
    if (type === 'error') {
      const errMsg = (message['message'] as string) ?? 'unknown error'
      this.cryptoDebugText = `BridgeTLS错误 ${errMsg}`
      console.info(`[BridgeTLS][error] ${JSON.stringify(message)}`)
      return
    }
    if (type === 'ack') {
      const ackMsg = (message['message'] as string) ?? 'ACK'
      this.addMqttMessage('bridge/tls', `[ACK] ${ackMsg}`)
      return
    }

    const processGlobalBridgeState = this.shouldProcessBusinessSource('BridgeTLS')
    if (!processGlobalBridgeState) {
      console.info(`[PROTO] ignore BridgeTLS message while active=${this.commandTransport} pending=${this.protocolPendingMode}`)
    }

    const state = message['state'] as BridgeStatePacket | undefined
    if (processGlobalBridgeState && state?.sensor) {
      this.applySensorData(state.sensor, 'TLS_BOOT')
    }
    if (processGlobalBridgeState && state?.light) {
      this.applyLightStatus(state.light, 'TLS_BOOT')
    }

    const encrypted = message['encrypted'] as EncryptedBridgePacket | undefined
    if (encrypted?.enabled === true && encrypted.payloadBase64 && encrypted.timestamp &&
      encrypted.timestamp > this.lastEncryptedTimestamp) {
      this.lastEncryptedTimestamp = encrypted.timestamp
      this.cryptoDebugText = `BridgeTLS缓存包 ${encrypted.payloadBase64.length}B64`
      const cachedTopic = encrypted.topic ?? 'esp32/sensor'
      const cachedDeviceId = this.registerDeviceId(this.deviceIdFromScopedTopic(cachedTopic))
      if (this.keyExchange.isKeyExchangeTopic(cachedTopic)) {
        this.handleEcdhPublicKey(cachedTopic, this.base64ToUint8Array(encrypted.payloadBase64), encrypted.timestamp ?? Date.now())
        return
      }
      this.handleEncryptedPayload(encrypted.payloadBase64, payloadSource, cachedTopic, cachedDeviceId)
    }
    if (type === 'sensor') {
      const topic = (message['topic'] as string) ?? 'esp32/sensor'
      const packetDeviceId = this.registerDeviceId(this.deviceIdFromScopedTopic(topic))
      this.observeDeviceTransport(packetDeviceId, payloadSource)
      const payloadBase64 = message['payloadBase64'] as string
      const timestamp = (message['timestamp'] as number) ?? Date.now()
      if (payloadBase64) {
        this.lastEncryptedTimestamp = timestamp
        this.mqttLastMsgTime = new Date(timestamp).toLocaleTimeString()
        const raw = this.base64ToUint8Array(payloadBase64)
        if (this.keyExchange.isKeyExchangeTopic(topic)) {
          this.handleEcdhPublicKey(topic, raw, timestamp)
          return
        }
        if (looksEncrypted(raw)) {
          this.handleEncryptedPayload(payloadBase64, payloadSource, topic, packetDeviceId, true)
        } else {
          const decoder = new util.TextDecoder()
          const text = decoder.decodeWithStream(raw)
          this.addMqttMessage(topic, text)
          if (!this.handleDeviceStatusJson(text, packetDeviceId)) {
            this.applySensorJson(text, this.resolvePayloadSource(payloadSource, text), packetDeviceId)
          }
        }
      }
    }
  }

  async handleCachedKeyExchangeDevices(devices: Record<string, KeyExchangeCachedPublicKey>): Promise<void> {
    const deviceIds = Object.keys(devices)
    for (let i = 0; i < deviceIds.length; i++) {
      const deviceId = deviceIds[i]
      const cached = devices[deviceId]
      if (!cached || !cached.payloadBase64 || !cached.topic) {
        continue
      }
      const timestamp = cached.timestamp ?? Date.now()
      await this.handleEcdhPublicKey(cached.topic, this.base64ToUint8Array(cached.payloadBase64), timestamp)
    }
  }

  async handleEcdhPublicKey(topic: string, raw: Uint8Array, timestamp: number = Date.now()): Promise<void> {
    if (this.isIrLearningKeyExchangeLocked()) {
      console.info(`[ECDH][locked-by-ir] defer public key topic=${topic}`)
      return
    }
    try {
      const ageMs = Date.now() - timestamp
      const deviceId = this.deviceIdFromScopedTopic(topic)
      const hasDeviceKeys = getDeviceDynamicAesKey(deviceId) !== null &&
        getDeviceDynamicSm4Key(deviceId) !== null
      const lastTimestamp = this.lastKeyExchangeTimestampByTopic.get(topic) ?? 0
      if (timestamp > 0 && timestamp <= lastTimestamp) {
        return
      }
      if (timestamp > 0 && ageMs > ECDH_CACHED_PUBLIC_KEY_MAX_AGE_MS) {
        if (hasDeviceKeys || ageMs > ECDH_RECOVERY_PUBLIC_KEY_MAX_AGE_MS) {
          console.info(`[ECDH] ignored stale public key topic=${topic} ageMs=${ageMs} hasKeys=${hasDeviceKeys}`)
          return
        }
        console.info(`[ECDH][recovery-cache] use cached public key topic=${topic} ageMs=${ageMs}`)
      }
      if (this.isRecentlySentEcdhPublicKey(raw)) {
        console.info(`[ECDH] ignored own public key echo topic=${topic}`)
        this.addMqttMessage(topic, '[ECDH:SKIP] own public key echo')
        return
      }
      if (this.ecdhTopicsInProgress.has(topic)) {
        console.info(`[ECDH] ignored concurrent public key topic=${topic}`)
        return
      }
      this.ecdhTopicsInProgress.add(topic)
      this.lastKeyExchangeTimestampByTopic.set(topic, timestamp)
      const result: KeyExchangeResult = await this.keyExchange.handlePublicKey(topic, raw)
      this.cryptoDebugText = result.message
      this.addMqttMessage(topic, `[ECDH] ${result.message}`)
      let replySent = false
      if (result.replyTopic && result.replyPublicKey) {
        replySent = await this.sendEcdhPublicKey(result.replyTopic, result.replyPublicKey)
        if (replySent) {
          this.addMqttMessage(result.replyTopic, `[ECDH:SENT] ${result.replyPublicKey.length}B public key`)
        } else {
          this.lastKeyExchangeTimestampByTopic.delete(topic)
          this.cryptoDebugText = `ECDH等待连接后重试 ${result.deviceId}`
          this.addMqttMessage(result.replyTopic, '[ECDH:WAIT] broker未就绪，稍后重试')
          this.scheduleEcdhReplyRetry(result.deviceId, topic, raw, result.replyTopic, result.replyPublicKey)
          return
        }
      }
      if (replySent || !result.replyTopic) {
        const prepared = await this.keyExchange.prepareKeysForPublicKey(topic, raw)
        if (prepared) {
          this.decryptFailCount = 0
          this.lastEcdhPendingTime = Date.now()
          this.decryptFailCountByDevice.delete(result.deviceId)
          this.lastEcdhPendingTimeByDevice.set(result.deviceId, this.lastEcdhPendingTime)
          this.cryptoDebugText = `ECDH动态密钥待确认 ${result.deviceId}`
        }
      }
    } catch (err) {
      const msg = (err as Error).message
      this.cryptoDebugText = `ECDH失败 ${msg}`
      this.addMqttMessage(topic, `[ECDH:ERR] ${msg}`)
      console.info(`[ECDH][fail] ${JSON.stringify(err)}`)
    } finally {
      this.ecdhTopicsInProgress.delete(topic)
    }
  }

  scheduleEcdhReplyRetry(deviceId: string, remoteTopic: string, remotePublicKey: Uint8Array | null, replyTopic: string, replyPublicKey: Uint8Array): void {
    this.pendingEcdhReplyDeviceId = deviceId
    this.pendingEcdhRemoteTopic = remoteTopic
    this.pendingEcdhRemotePublicKey = remotePublicKey ? remotePublicKey.slice() : null
    this.pendingEcdhReplyTopic = replyTopic
    this.pendingEcdhReplyPublicKey = replyPublicKey.slice()
    if (this.ecdhReplyRetryTimerId !== -1) {
      return
    }
    this.ecdhReplyRetryAttempt = Math.min(this.ecdhReplyRetryAttempt + 1, 6)
    const delayMs = Math.min(5000, 700 + this.ecdhReplyRetryAttempt * 600)
    console.info(`[ECDH][reply-retry-schedule] device=${deviceId} delay=${delayMs}`)
    this.ecdhReplyRetryTimerId = setTimeout(() => {
      this.ecdhReplyRetryTimerId = -1
      this.flushPendingEcdhReply()
    }, delayMs)
  }

  async flushPendingEcdhReply(): Promise<void> {
    if (this.isIrLearningKeyExchangeLocked()) {
      console.info('[ECDH][locked-by-ir] defer pending public key reply')
      return
    }
    const remotePublicKey = this.pendingEcdhRemotePublicKey
    const replyPublicKey = this.pendingEcdhReplyPublicKey
    const deviceId = this.pendingEcdhReplyDeviceId
    const remoteTopic = this.pendingEcdhRemoteTopic
    const replyTopic = this.pendingEcdhReplyTopic
    if (!replyPublicKey || deviceId.length === 0 || replyTopic.length === 0) {
      return
    }
    try {
      await this.refreshActiveProtocol()
    } catch (err) {
      console.info(`[ECDH][reply-retry-refresh-fail] ${(err as Error).message}`)
    }
    const sent = await this.sendEcdhPublicKey(replyTopic, replyPublicKey)
    if (!sent) {
      this.cryptoDebugText = `ECDH等待连接后重试 ${deviceId}`
      if (this.ecdhReplyRetryAttempt < 6) {
        this.scheduleEcdhReplyRetry(deviceId, remoteTopic, remotePublicKey, replyTopic, replyPublicKey)
      } else {
        this.addMqttMessage(replyTopic, '[ECDH:WAIT] 公钥重试仍未发出')
      }
      return
    }
    let prepared = false
    if (remotePublicKey && remoteTopic.length > 0) {
      prepared = await this.keyExchange.prepareKeysForPublicKey(remoteTopic, remotePublicKey)
    }
    if (prepared || remotePublicKey === null) {
      this.decryptFailCount = 0
      this.lastEcdhPendingTime = Date.now()
      this.decryptFailCountByDevice.delete(deviceId)
      this.lastEcdhPendingTimeByDevice.set(deviceId, this.lastEcdhPendingTime)
      this.cryptoDebugText = `ECDH动态密钥待确认 ${deviceId}`
      this.addMqttMessage(replyTopic, `[ECDH:SENT:retry] ${replyPublicKey.length}B public key`)
    }
    this.ecdhReplyRetryAttempt = 0
    this.pendingEcdhReplyDeviceId = ''
    this.pendingEcdhRemoteTopic = ''
    this.pendingEcdhRemotePublicKey = null
    this.pendingEcdhReplyTopic = ''
    this.pendingEcdhReplyPublicKey = null
  }

  async sendEcdhPublicKey(topic: string, publicKey: Uint8Array): Promise<boolean> {
    if (this.isIrLearningKeyExchangeLocked()) {
      console.info(`[ECDH][locked-by-ir] suppress public key publish topic=${topic}`)
      return false
    }
    const payloadBase64 = this.uint8ArrayToBase64(publicKey)
    const targetDeviceId = this.deviceIdFromScopedTopic(topic)
    if (this.localGatewayDeviceIds.has(targetDeviceId)) {
      try {
        if (this.transportRouteForDevice(targetDeviceId) === 'HTTP') {
          this.localGateway.enqueueCommand(targetDeviceId, topic, payloadBase64, publicKey.length)
          this.rememberSentEcdhPublicKey(publicKey)
          console.info(`[ECDH] local HTTP public key queued ${topic}`)
          return true
        }
        if (this.localMqtt.isConnected()) {
          await this.localMqtt.publish(topic, publicKey, 0)
          this.rememberSentEcdhPublicKey(publicKey)
          console.info(`[ECDH] local MQTT public key sent ${topic}`)
          return true
        }
      } catch (err) {
        console.info(`[ECDH] local public key send failed: ${JSON.stringify(err)}`)
        return false
      }
    }
    if (this.transportForDevice(targetDeviceId) === 'HTTP') {
      try {
        const baseUrl = this.normalizeBridgeUrl(this.bridgeUrl)
        this.bridgeUrl = baseUrl
        const responseText = await this.httpRequest(
          `${baseUrl}/api/http/command`,
          http.RequestMethod.POST,
          JSON.stringify({ deviceId: targetDeviceId, payloadBase64, topic })
        )
        const response = JSON.parse(responseText) as Record<string, Object>
        if (response['ok'] !== true) {
          throw new Error((response['message'] as string) ?? 'HTTP key queue failed')
        }
        this.rememberSentEcdhPublicKey(publicKey)
        console.info(`[ECDH] HTTP public key queued ${topic} device=${targetDeviceId}`)
        return true
      } catch (err) {
        console.info(`[ECDH] HTTP public key queue failed: ${JSON.stringify(err)}`)
        return false
      }
    }
    if (this.mqtt.isConnected()) {
      try {
        await this.mqtt.publish(topic, publicKey, 0)
        this.rememberSentEcdhPublicKey(publicKey)
        console.info(`[ECDH] MQTT public key sent ${topic} qos=0`)
        return true
      } catch (err) {
        console.info(`[ECDH] MQTT public key send failed: ${JSON.stringify(err)}`)
      }
    }
    if (this.bridgeTls.isConnected()) {
      try {
        await this.bridgeTls.publishRaw(topic, publicKey)
        this.rememberSentEcdhPublicKey(publicKey)
        console.info(`[ECDH] BridgeTLS public key sent ${topic}`)
        return true
      } catch (err) {
        console.info(`[ECDH] BridgeTLS public key send failed: ${JSON.stringify(err)}`)
      }
    }
    try {
      await this.ensureBridgeTlsReady()
      if (this.bridgeTls.isConnected()) {
        await this.bridgeTls.publishRaw(topic, publicKey)
        this.rememberSentEcdhPublicKey(publicKey)
        console.info(`[ECDH] BridgeTLS public key sent ${topic}`)
        return true
      }
    } catch (err) {
      console.info(`[ECDH] BridgeTLS public key retry failed: ${JSON.stringify(err)}`)
    }

    try {
      const baseUrl = this.normalizeBridgeUrl(this.bridgeUrl)
      this.bridgeUrl = baseUrl
      await this.httpRequest(
        `${baseUrl}/api/encrypted/command`,
        http.RequestMethod.POST,
        JSON.stringify({ payloadBase64, topic })
      )
      this.rememberSentEcdhPublicKey(publicKey)
      console.info(`[ECDH] HTTP relay public key sent ${topic}`)
      return true
    } catch (err) {
      console.info(`[ECDH] HTTP relay public key send failed: ${JSON.stringify(err)}`)
    }
    return false
  }

  rememberSentEcdhPublicKey(publicKey: Uint8Array): void {
    const now = Date.now()
    const expiresBefore = now - 120000
    this.recentSentEcdhPublicKeys.forEach((sentAt: number, key: string) => {
      if (sentAt < expiresBefore) {
        this.recentSentEcdhPublicKeys.delete(key)
      }
    })
    this.recentSentEcdhPublicKeys.set(this.uint8ArrayToBase64(publicKey), now)
  }

  isRecentlySentEcdhPublicKey(publicKey: Uint8Array): boolean {
    const key = this.uint8ArrayToBase64(publicKey)
    const sentAt = this.recentSentEcdhPublicKeys.get(key) ?? 0
    if (sentAt <= 0) {
      return false
    }
    if (Date.now() - sentAt > 120000) {
      this.recentSentEcdhPublicKeys.delete(key)
      return false
    }
    return true
  }

  addMqttMessage(topic: string, text: string): void {
    const now = Date.now()
    const isSensorDebug = topic.indexOf('esp32/sensor') >= 0 && text.indexOf('[err]') < 0 &&
      text.indexOf('"type":"ack"') < 0 && text.indexOf('"cmd":"led"') < 0
    if (isSensorDebug && now - this.lastSensorDebugMessageAt < 5000) {
      return
    }
    if (isSensorDebug) {
      this.lastSensorDebugMessageAt = now
    }
    const item: MessageItem = {
      id: `${now}-${this.mqttMessages.length}`,
      time: new Date().toLocaleTimeString(),
      from: topic,
      text: text,
      deviceId: this.debugDeviceIdFromTopic(topic)
    }
    this.mqttMessages = [item, ...this.mqttMessages].slice(0, MAX_MQTT_MESSAGES)
    if (CLOUD_SYNC_ENABLED) {
      this.reportCloudMessage(topic, text)
    }
  }

  debugDeviceIdFromTopic(topic: string): string {
    if (topic.startsWith('device/')) {
      const parts = topic.split('/')
      return parts.length >= 3 ? this.normalizeDeviceId(parts[1]) : ''
    }
    if (topic.startsWith('dayu/cmd/')) {
      return this.normalizeDeviceId(topic.substring('dayu/cmd/'.length))
    }
    if (topic.startsWith('key/ecdh/pub/')) {
      return this.normalizeDeviceId(topic.substring('key/ecdh/pub/'.length))
    }
    if (topic === 'dayu/cmd' || topic.startsWith('esp32/')) {
      return 'esp32'
    }
    return ''
  }

  debugVisibleMessages(): MessageItem[] {
    if (this.debugShowAllDevices) {
      return this.mqttMessages
    }
    return this.mqttMessages.filter((item: MessageItem) => {
      return item.deviceId === this.activeDeviceId || !item.deviceId || item.deviceId.length === 0
    })
  }

  private mqttConnecting: boolean = false

  async connectMqtt(brokerIp: string, brokerPort: number = 1883, useTls: boolean = false): Promise<void> {
    if (this.mqttConnecting) return
    if (this.mqtt.isConnected() && this.mqtt.matchesBroker(brokerIp, brokerPort, useTls)) return
    this.mqttConnecting = true
    try {
      this.mqtt.setBroker(brokerIp, brokerPort, useTls)
      await this.withTimeout(this.mqtt.connect(), MQTT_AUTO_CONNECT_TIMEOUT_MS, useTls ? 'MQTTS connect' : 'MQTT connect')
    } catch (err) {
      try {
        await this.mqtt.disconnect()
      } catch (_) { /* ignore */ }
      throw new Error((err as Error).message)
    } finally {
      this.mqttConnecting = false
    }
    if (this.mqtt.isConnected()) {
      await this.mqtt.subscribe('esp32/sensor', 0)
      await this.mqtt.subscribe('esp32/status', 1)
      await this.mqtt.subscribe('esp32/ac', 1)
      await this.mqtt.subscribe('smart_home/esp32/sensor/indoor', 0)
      await this.mqtt.subscribe('device/+/+', 1)
      await this.mqtt.subscribe('key/ecdh/pub/+', 1)
      const scheme = useTls ? 'MQTTS' : 'MQTT'
      console.info(`[MQTT] subscribed via ${scheme} to esp32/sensor(qos=0), esp32/status(qos=1), esp32/ac(qos=1), smart_home/esp32/sensor/indoor(qos=0) and key/ecdh/pub/+(qos=1)`)
    }
  }

  async connectMqttWithFallback(brokerIp: string, mqttPort: number, mqttTlsPort: number): Promise<void> {
    const now = Date.now()
    const shouldTryTls = DAYU_PREFER_MQTT_TLS && mqttTlsPort > 0 && now >= this.mqttTlsFallbackUntil
    if (shouldTryTls) {
      this.mqttStatus = `MQTTS ${brokerIp}:${mqttTlsPort}...`
      try {
        await this.connectMqtt(brokerIp, mqttTlsPort, true)
        if (this.mqtt.isConnected() && this.mqtt.matchesBroker(brokerIp, mqttTlsPort, true)) {
          return
        }
      } catch (err) {
        console.info(`[MQTT][tls-fallback] ${(err as Error).message}`)
      }
      if (!DAYU_ALLOW_PLAIN_MQTT_FALLBACK) {
        throw new Error('MQTTS mutual authentication failed; plain MQTT fallback disabled')
      }
      this.mqttTlsFallbackUntil = Date.now() + 60000
      try {
        await this.mqtt.disconnect()
      } catch (_) { /* ignore */ }
    }

    const plainPort = mqttPort > 0 ? mqttPort : 1883
    this.mqttStatus = `MQTT ${brokerIp}:${plainPort}...`
    await this.connectMqtt(brokerIp, plainPort, false)
  }

  /**
   * Base64 解码 (atob polyfill for ArkTS)
   */
  async sendLightControl(target: string, power: boolean): Promise<void> {
    const payload: LightControlPacket = {
      target: target,
      power: power,
      timestamp: Date.now()
    }
    const baseUrl = this.normalizeBridgeUrl(this.bridgeUrl)
    this.bridgeUrl = baseUrl

    if (target !== 'living') {
      try {
        await this.httpRequest(`${baseUrl}/api/light/control`, http.RequestMethod.POST, JSON.stringify(payload))
        this.bridgeConnected = true
      } catch (err) {
        console.info(`[Bridge][light-control][error] ${JSON.stringify(err)}`)
      }
    }

    // 加密路径 — 客厅开关映射到 ESP32 LED 控制协议
    try {
      let esp32Cmd = ''
      if (target === 'living') {
        const seq = this.nextLedCommandSeq()
        this.ledPendingSeq = seq
        this.livingLightPending = true
        this.livingLightPendingTargetOn = power
        this.hasLivingLightPendingTarget = true
        this.livingLightAckText = `正在发送 #${seq}`
        const ledCmd: LedControlCommand = {
          cmd: 'led',
          val: power ? 1 : 0,
          source: 'dayu',
          priority: LED_CONTROL_PRIORITY,
          lockMs: LED_CONTROL_LOCK_MS,
          seq: seq
        }
        esp32Cmd = JSON.stringify(ledCmd)
      } else {
        esp32Cmd = JSON.stringify({
          cmd: target,
          val: power ? 1 : 0
        })
      }
      await this.sendEncryptedCommand(baseUrl, esp32Cmd, 'dayu/cmd', this.deviceForCapability('light'))
      if (target === 'living') {
        this.livingLightOn = power
        this.livingLightOptimisticUntil = Date.now() + LED_OPTIMISTIC_HOLD_MS
        this.livingLightAckText = `等待设备确认 #${this.ledPendingSeq}`
      }
    } catch (err) {
      if (target === 'living') {
        this.livingLightPending = false
        this.hasLivingLightPendingTarget = false
        this.livingLightAckText = '发送失败'
      }
      console.info(`[Crypto][light-encrypted][error] ${JSON.stringify(err)}`)
      throw new Error((err as Error).message)
    }

    if (target !== 'living') {
      setTimeout(() => {
        this.refreshActiveProtocol()
      }, 1500)
    }
  }

  nextLedCommandSeq(): number {
    this.ledCommandSeq = (this.ledCommandSeq % 999999) + 1
    return this.ledCommandSeq
  }

  nextDoorCommandSeq(): number {
    this.doorCommandSeq = (this.doorCommandSeq % 999999) + 1
    return this.doorCommandSeq
  }

  clearDoorAckTimer(): void {
    if (this.doorAckTimerId >= 0) {
      clearTimeout(this.doorAckTimerId)
      this.doorAckTimerId = -1
    }
  }

  startDoorAckTimer(seq: number): void {
    this.clearDoorAckTimer()
    this.doorAckTimerId = setTimeout(() => {
      this.doorAckTimerId = -1
      if (!this.doorPending || this.doorPendingSeq !== seq) {
        return
      }
      this.doorPending = false
      this.doorPendingSeq = 0
      this.doorAckText = `门锁确认超时 #${seq}`
      console.info(`[DOOR][ack-timeout] seq=${seq}`)
    }, 12000)
  }

  doorStateText(): string {
    return this.doorLocked ? '当前已上锁' : '当前已解锁'
  }

  faceDoorActionText(): string {
    return this.doorLocked ? '识别通过后开锁' : '识别通过后关锁'
  }

  async sendDoorControl(unlock: boolean, userId: string = '', userName: string = '', score: number = -1): Promise<void> {
    const baseUrl = this.normalizeBridgeUrl(this.bridgeUrl)
    this.bridgeUrl = baseUrl
    const seq = this.nextDoorCommandSeq()
    const actionText = unlock ? '开锁' : '关锁'
    this.doorPending = true
    this.doorPendingSeq = seq
    this.doorPendingTargetLocked = !unlock
    this.doorAckText = `正在发送门锁 #${seq}`
    this.startDoorAckTimer(seq)
    const cmd: DoorControlCommand = {
      cmd: 'door',
      val: unlock ? 1 : 0,
      source: 'dayu',
      priority: DOOR_CONTROL_PRIORITY,
      lockMs: DOOR_CONTROL_LOCK_MS,
      seq
    }
    if (userId.length > 0) {
      cmd.userId = userId
    }
    if (userName.length > 0) {
      cmd.userName = userName
    }
    if (score >= 0) {
      cmd.score = Number(score.toFixed(3))
    }

    try {
      await this.sendEncryptedCommand(baseUrl, JSON.stringify(cmd), 'dayu/cmd', this.deviceForCapability('door'))
      this.doorAckText = `${actionText}指令已发送 #${seq}`
      this.faceAccessStatus = userName.length > 0 ? `识别通过: ${userName}，已发送${actionText} #${seq}` : `已发送${actionText} #${seq}`
    } catch (err) {
      this.doorPending = false
      this.doorPendingSeq = 0
      this.clearDoorAckTimer()
      this.doorAckText = '门锁发送失败'
      this.faceAccessStatus = `门锁发送失败: ${(err as Error).message}`
      throw new Error((err as Error).message)
    }
  }

  async executeVoiceIntent(intent: VoiceIntent): Promise<VoiceExecutionResult> {
    if (intent.type === VoiceIntentType.LIGHT_SET && intent.target === 'living') {
      if (this.livingLightOn === intent.power && !this.livingLightPending) {
        return {
          success: true,
          message: intent.power ? '客厅灯已经打开' : '客厅灯已经关闭',
          promptRawFile: intent.power ? 'voice/prompts/light_on_ok.wav' : 'voice/prompts/light_off_ok.wav'
        }
      }
      if (this.livingLightControlInFlight || this.livingLightPending) {
        return { success: false, message: '客厅灯正在执行其他控制' }
      }

      console.info(`[VoiceAssistant][execute] ${intent.rawText} -> living light ${intent.power ? 'on' : 'off'}`)
      this.livingLightControlInFlight = true
      this.startLivingLightControlTimer()
      try {
        await this.sendLightControl('living', intent.power)
      } catch (err) {
        this.livingLightControlInFlight = false
        this.clearLivingLightControlTimer()
        return { success: false, message: `客厅灯发送失败: ${(err as Error).message}` }
      }
      this.livingLightControlInFlight = false
      return {
        success: true,
        message: intent.power ? '客厅灯开启指令已发送' : '客厅灯关闭指令已发送',
        promptRawFile: intent.power ? 'voice/prompts/light_on_ok.wav' : 'voice/prompts/light_off_ok.wav'
      }
    }

    if (intent.type === VoiceIntentType.AC_SET && intent.target === 'ac') {
      if (this.acPower === intent.power && !this.acPending && this.acPendingSeq === 0) {
        return {
          success: true,
          message: intent.power ? '空调已经打开' : '空调已经关闭',
          promptRawFile: intent.power ? 'voice/prompts/ac_on_ok.wav' : 'voice/prompts/ac_off_ok.wav'
        }
      }
      if (this.acPending || this.acPendingSeq > 0) {
        return { success: false, message: '空调正在执行其他控制' }
      }

      const previousPower = this.acPower
      this.acPower = intent.power
      console.info(`[VoiceAssistant][execute] ${intent.rawText} -> ac ${intent.power ? 'on' : 'off'}`)
      await this.requestACControl('power')
      if (this.acAckText.startsWith('发送失败')) {
        this.acPower = previousPower
        return { success: false, message: this.acAckText }
      }
      return {
        success: true,
        message: intent.power ? '空调开启指令已发送' : '空调关闭指令已发送',
        promptRawFile: intent.power ? 'voice/prompts/ac_on_ok.wav' : 'voice/prompts/ac_off_ok.wav'
      }
    }

    return { success: false, message: '暂时不支持这个语音指令' }
  }

  requestLivingLightToggle(preserveOptimisticOnFailure: boolean = false): void {
    const now = Date.now()
    if (this.livingLightControlInFlight && now - this.lastLivingLightCommandAt > 3000) {
      console.info('[LED][ui-recover] stale in-flight cleared')
      this.livingLightControlInFlight = false
    }
    if (this.livingLightControlInFlight) {
      console.info('[LED][ui-ignore] send in flight')
      return
    }
    if (now - this.lastLivingLightClickAt < 800) {
      console.info('[LED][ui-ignore] debounce')
      return
    }
    this.lastLivingLightClickAt = now
    const nextValue = !this.livingLightOn
    const commandKey = nextValue ? 'on' : 'off'
    if (commandKey === this.lastLivingLightCommandKey && now - this.lastLivingLightCommandAt < 1200) {
      console.info(`[LED][ui-ignore] duplicate target=${nextValue}`)
      return
    }
    if (this.livingLightPending) {
      console.info(`[LED][ui-override] previous pending seq=${this.ledPendingSeq} target=${nextValue}`)
    }
    this.livingLightControlInFlight = true
    this.lastLivingLightCommandKey = commandKey
    this.lastLivingLightCommandAt = now
    console.info(`[LED][ui-click] target=${nextValue}`)
    this.cryptoDebugText = `灯光按钮已点击 ${nextValue ? '开灯' : '关灯'}`
    this.addMqttMessage('dayu/cmd', `[CLICK] ${nextValue ? '开灯' : '关灯'} 准备发送`)
    this.livingLightAckText = `${this.livingLightOn ? 'ON' : 'OFF'} → ${nextValue ? 'ON' : 'OFF'}`
    this.livingLightOptimisticUntil = 0
    this.startLivingLightControlTimer()
    this.sendLightControl('living', nextValue)
      .catch((err: Error) => {
        console.info(`[LED][ui-send-fail] ${err.message}`)
        if (!preserveOptimisticOnFailure) {
          this.livingLightOptimisticUntil = 0
        }
        this.hasLivingLightPendingTarget = false
        this.lastLivingLightCommandKey = ''
        this.lastLivingLightCommandAt = 0
        this.clearLivingLightControlTimer()
        this.livingLightControlInFlight = false
      })
      .finally(() => {
        this.livingLightControlInFlight = false
      })
  }

  clearLivingLightControlTimer(): void {
    if (this.livingLightControlTimerId !== -1) {
      clearTimeout(this.livingLightControlTimerId)
      this.livingLightControlTimerId = -1
    }
  }

  startLivingLightControlTimer(): void {
    this.clearLivingLightControlTimer()
    this.livingLightControlTimerId = setTimeout(() => {
      if (this.livingLightPending) {
        console.info(`[LED][timeout] seq=${this.ledPendingSeq}`)
        this.livingLightPending = false
        this.ledPendingSeq = 0
        this.hasLivingLightPendingTarget = false
        this.livingLightControlInFlight = false
        this.livingLightAckText = '发送超时'
      }
      this.livingLightControlTimerId = -1
    }, 3500)
  }

  /**
   * 发送加密指令到 ESP32
   * 流程: JSON → GCM 加密 → MQTT 直发或 HTTP bridge → ESP32
   */
  async sendEncryptedCommand(baseUrl: string, jsonCmd: string, topic: string = 'dayu/cmd',
    targetDeviceId: string = this.activeDeviceId): Promise<void> {
    const protocol = this.protocolPendingMode.length > 0 && targetDeviceId === this.activeDeviceId ?
      this.protocolPendingMode : this.transportRouteForDevice(targetDeviceId)
    if (this.protocolPendingMode.length > 0 && targetDeviceId === this.activeDeviceId) {
      console.info(`[CMD] protocol pending ${this.commandTransport}->${this.protocolPendingMode}, send via target=${protocol}`)
    }
    await this.sendEncryptedCommandUsingCurrentSession(baseUrl, jsonCmd, protocol, topic, targetDeviceId)
  }

  async sendEncryptedCommandUsingCurrentSession(baseUrl: string, jsonCmd: string,
    protocol: string, topic: string = 'dayu/cmd', targetDeviceId: string = this.activeDeviceId): Promise<void> {
    const mode = this.cryptoModeForDevice(targetDeviceId)
    if (targetDeviceId === this.activeDeviceId && this.cryptoMode !== mode) {
      console.info(`[CMD][CRYPTO] align UI mode ${this.cryptoMode}->${mode}`)
      this.cryptoMode = mode
    }
    await this.sendEncryptedCommandWithMode(baseUrl, jsonCmd, mode, protocol, topic, targetDeviceId)
  }

  async sendEncryptedCommandWithMode(baseUrl: string, jsonCmd: string, mode: string,
    protocol: string = this.commandTransport, topic: string = 'dayu/cmd',
    requestedDeviceId: string = this.activeDeviceId): Promise<void> {
    const commandStartAt = Date.now()
    const targetDeviceId = this.normalizeDeviceId(requestedDeviceId)
    const commandTopic = this.commandTopicForDevice(topic.length > 0 ? topic : 'dayu/cmd', targetDeviceId)
    try {
    const keySource = getDeviceDynamicSm4Key(targetDeviceId) !== null &&
      getDeviceDynamicAesKey(targetDeviceId) !== null ? 'dynamic' : 'static'
    const encrypted = await encryptWithModeForDevice(jsonCmd, mode, targetDeviceId)
    console.info(`[CMD][TIMING] encrypt ${Date.now() - commandStartAt}ms`)
    console.info(`[CMD][CRYPTO] mode=${mode} keySource=${keySource} epoch=${this.deviceEpoch} topic=${commandTopic} len=${encrypted.length}`)
    const shortCmd = jsonCmd.substring(0, 60)

    const payloadBase64 = this.uint8ArrayToBase64(encrypted)
    let bridgeTlsSent = false
    const targetProtocol = this.normalizeProtocolMode(protocol)
    console.info(`[CMD] start ${mode}/${targetProtocol}: ${shortCmd}`)
    this.cryptoDebugText = `准备发送 ${targetProtocol} ${shortCmd}`
    if (targetProtocol === 'MQTT' && this.localGatewayDeviceIds.has(targetDeviceId) &&
      this.localMqtt.isConnected()) {
      await this.withTimeout(this.localMqtt.publish(commandTopic, encrypted, 0),
        MQTT_COMMAND_PUBLISH_TIMEOUT_MS, 'local MQTT publish')
      console.info(`[CMD] local MQTT total=${Date.now() - commandStartAt}ms: ${shortCmd}`)
      this.cryptoDebugText = `本地MQTT指令已发 ${encrypted.length}B`
      this.addMqttMessage(commandTopic, `[SENT:LOCAL-MQTT] ${shortCmd}`)
      return
    }
    if (targetProtocol === 'MQTT' && DAYU_DIRECT_MQTT_ENABLED) {
      try {
        if (!this.mqtt.isConnected()) {
          console.info('[CMD][MQTT] connecting before publish')
          this.cryptoDebugText = 'MQTT未连接，正在重连'
          await this.withTimeout(this.mqtt.connect(), MQTT_COMMAND_CONNECT_TIMEOUT_MS, 'MQTT connect')
          if (!this.mqtt.isConnected()) {
            throw new Error('MQTT connect failed')
          }
        }
        await this.withTimeout(this.mqtt.publish(commandTopic, encrypted, 0), MQTT_COMMAND_PUBLISH_TIMEOUT_MS, 'MQTT publish')
        console.info(`[CMD] MQTT direct total=${Date.now() - commandStartAt}ms: ${shortCmd}`)
        this.cryptoDebugText = `MQTT指令已发 ${encrypted.length}B`
        this.addMqttMessage(commandTopic, `[SENT:MQTT] ${shortCmd}`)
        return
      } catch (mqttErr) {
        console.info(`[CMD] MQTT direct fail, reconnect once: ${(mqttErr as Error).message}`)
        try {
          this.cryptoDebugText = 'MQTT直发失败，重连重试'
          await this.withTimeout(this.mqtt.connect(), MQTT_COMMAND_CONNECT_TIMEOUT_MS, 'MQTT reconnect')
          if (this.mqtt.isConnected()) {
            await this.withTimeout(this.mqtt.publish(commandTopic, encrypted, 0), MQTT_COMMAND_PUBLISH_TIMEOUT_MS, 'MQTT retry publish')
            console.info(`[CMD] MQTT direct retry total=${Date.now() - commandStartAt}ms: ${shortCmd}`)
            this.cryptoDebugText = `MQTT重试已发 ${encrypted.length}B`
            this.addMqttMessage(commandTopic, `[SENT:MQTT:retry] ${shortCmd}`)
            return
          }
          throw new Error('MQTT reconnect failed')
        } catch (retryErr) {
          console.info(`[CMD] MQTT retry fail, fallback to BridgeTLS: ${(retryErr as Error).message}`)
        }
        this.addMqttMessage(commandTopic, `[MQTT fallback] ${(mqttErr as Error).message}`)
      }
    }
    if (targetProtocol === 'MQTT' && !this.bridgeTls.isConnected()) {
      const connectStartAt = Date.now()
      this.cryptoDebugText = '正在尝试 BridgeTLS 降级发送'
      await this.withTimeout(this.ensureBridgeTlsReady(), BRIDGE_TLS_COMMAND_CONNECT_TIMEOUT_MS, 'BridgeTLS connect')
      console.info(`[CMD][TIMING] ensure BridgeTLS ${Date.now() - connectStartAt}ms connected=${this.bridgeTls.isConnected()}`)
    }
    if (targetProtocol === 'MQTT' && this.bridgeTls.isConnected()) {
      try {
        const publishStartAt = Date.now()
        await this.bridgeTls.publish(commandTopic, payloadBase64)
        bridgeTlsSent = true
        console.info(`[CMD] BridgeTLS OK ${Date.now() - publishStartAt}ms total=${Date.now() - commandStartAt}ms: ${shortCmd}`)
        this.addMqttMessage(commandTopic, `[SENT:BridgeTLS] ${shortCmd}`)
      } catch (err) {
        console.info(`[CMD] BridgeTLS fail: ${JSON.stringify(err)}`)
        try { await this.bridgeTls.disconnect() } catch (_) { /* ignore */ }
      }
    }

    if (targetProtocol === 'MQTT' && !bridgeTlsSent && this.bridgeTlsPort > 0) {
      const retryStartAt = Date.now()
      await this.withTimeout(this.ensureBridgeTlsReady(), BRIDGE_TLS_COMMAND_CONNECT_TIMEOUT_MS, 'BridgeTLS retry connect')
      if (this.bridgeTls.isConnected()) {
        await this.bridgeTls.publish(commandTopic, payloadBase64)
        bridgeTlsSent = true
        console.info(`[CMD] BridgeTLS retry OK ${Date.now() - retryStartAt}ms total=${Date.now() - commandStartAt}ms: ${shortCmd}`)
        this.addMqttMessage(commandTopic, `[SENT:BridgeTLS:retry] ${shortCmd}`)
      }
    }

    if (targetProtocol === 'MQTT') {
      if (!bridgeTlsSent) {
        throw new Error('BridgeTLS send failed')
      }
      return
    }

    if (targetProtocol === 'HTTP') {
      if (this.localGatewayDeviceIds.has(targetDeviceId)) {
        this.localGateway.enqueueCommand(targetDeviceId, commandTopic, payloadBase64, encrypted.length)
        this.cryptoDebugText = `本地HTTP指令已入队 ${encrypted.length}B`
        console.info(`[CMD] local HTTP queued ${encrypted.length}B: ${shortCmd}`)
        this.addMqttMessage(commandTopic, `[SENT:LOCAL-HTTP ${encrypted.length}B] ${shortCmd}`)
        return
      }
      const responseText = await this.httpRequest(
        `${baseUrl}/api/http/command`,
        http.RequestMethod.POST,
        JSON.stringify({ deviceId: targetDeviceId, payloadBase64, topic: commandTopic })
      )
      const response = JSON.parse(responseText) as Record<string, Object>
      if (response['ok'] !== true) {
        const message = (response['message'] as string) ?? 'HTTP command queue failed'
        throw new Error(message)
      }
      const commandId = (response['commandId'] as string) ?? ''
      const bytes = typeof response['bytes'] === 'number' ? response['bytes'] as number : encrypted.length
      const queueText = commandId.length > 0 ? `id=${commandId}` : `${bytes}B`
      this.cryptoDebugText = `HTTP指令已入队 ${queueText}`
      console.info(`[CMD] HTTP queued ${queueText}: ${shortCmd}`)
      this.addMqttMessage(commandTopic, `[SENT:HTTP queued ${queueText}] ${shortCmd}`)
      return
    }
    } catch (e) {
      console.info(`[CMD] FAIL: ${(e as Error).message}`)
      this.addMqttMessage(commandTopic, `[FAIL] ${(e as Error).message}`)
      throw new Error((e as Error).message)
    }
  }

  async ensureBridgeTlsReady(): Promise<void> {
    if (this.bridgeTls.isConnected()) {
      return
    }
    if (this.bridgeTlsIp.length === 0 || this.bridgeTlsPort <= 0) {
      return
    }
    await this.bridgeTls.connect(this.bridgeTlsIp, this.bridgeTlsPort)
  }

  ensureBridgeTlsAutoConnect(ip: string, port: number): void {
    if (this.bridgeTlsAutoConnectInFlight) {
      return
    }
    const now = Date.now()
    const sameBridge = this.bridgeTls.matchesBridge(ip, port)
    if (sameBridge && now - this.lastBridgeTlsAutoConnectAt < BRIDGE_TLS_AUTO_CONNECT_MIN_INTERVAL_MS) {
      return
    }
    this.bridgeTlsAutoConnectInFlight = true
    this.lastBridgeTlsAutoConnectAt = now
    this.bridgeTls.connect(ip, port).catch((err: Error) => {
      console.info(`[BridgeTLS][auto-connect-fail] ${err.message}`)
    }).finally(() => {
      this.bridgeTlsAutoConnectInFlight = false
    })
  }

  // Beacon 信标监听（UDP 1346 端口）— 仅用于自动发现 broker 地址
  async startUdpReceiver(): Promise<void> {
    if (this.udpReceiver !== null) return

    const receiver = socket.constructUDPSocketInstance()
    receiver.on('message', (info: socket.SocketMessageInfo) => {
      const text = this.arrayBufferToUtf8(info.message).trim()
      console.info(`[Beacon][UDP] from ${info.remoteInfo.address}:${info.remoteInfo.port} — ${text.substring(0, 100)}`)
      this.applyPcUdpCommand(text)
    })
    receiver.on('error', (err) => {
      console.info(`[Beacon][UDP][error] ${JSON.stringify(err)}`)
    })

    try {
      await receiver.bind({ address: '0.0.0.0', port: DEFAULT_UDP_LISTEN_PORT, family: 1 })
      this.udpReceiver = receiver
      console.info(`[Beacon] listening on UDP ${DEFAULT_UDP_LISTEN_PORT}`)
    } catch (err) {
      console.info(`[Beacon][bind-error] ${JSON.stringify(err)}`)
      try { await receiver.close() } catch (_) { /* ignore */ }
    }
  }

  async stopUdpReceiver(): Promise<void> {
    if (!this.udpReceiver) return
    try { await this.udpReceiver.close() } catch (_) { /* ignore */ }
    this.udpReceiver = null
  }

  // 仅处理 Beacon 信标，MQTT 负责传感器数据
  applyPcUdpCommand(text: string): void {
    try {
      const obj = JSON.parse(text) as Record<string, Object>
      if (obj['type'] === 'beacon') {
        this.handleBeacon({
          type: obj['type'] as string,
          broker_ip: obj['broker_ip'] as string,
          mqtt_port: obj['mqtt_port'] as number,
          mqtt_tls_port: obj['mqtt_tls_port'] as number | undefined,
          esp32_mqtt_tls_port: obj['esp32_mqtt_tls_port'] as number | undefined,
          bridge_tls_port: obj['bridge_tls_port'] as number | undefined,
          http_port: obj['http_port'] as number,
          https_port: obj['https_port'] as number | undefined,
          hostname: obj['hostname'] as string | undefined,
          timestamp: obj['timestamp'] as number
        })
      }
    } catch (_) { /* ignore non-JSON UDP */ }
  }

  // 处理 UDP 信标：自动发现 Broker 地址，零配置连接
  handleBeacon(data: BeaconPacket): void {
    if (this.localGatewayHost.length > 0 && data.broker_ip !== this.localGatewayHost) {
      console.info(`[Beacon] ignored external broker ${data.broker_ip}; local gateway=${this.localGatewayHost}`)
      return
    }
    const httpsPort = data.https_port ?? 0
    const newBridgeUrl = `http://${data.broker_ip}:${data.http_port}`
    const oldBridgeUrl = this.bridgeUrl

    this.bridgeUrl = newBridgeUrl
    this.beaconLastReceived = `${data.broker_ip}:${data.http_port} @ ${new Date(data.timestamp).toLocaleTimeString()}`
    this.beaconAutoDiscovered = true

    const tlsPort = data.mqtt_tls_port ?? 0
    const esp32TlsPort = data.esp32_mqtt_tls_port ?? 0
    const bridgeTlsPort = data.bridge_tls_port ?? 0
    this.beaconBrokerIp = data.broker_ip
    this.beaconMqttPort = data.mqtt_port
    this.beaconMqttTlsPort = tlsPort
    this.beaconEsp32MqttTlsPort = esp32TlsPort
    this.beaconHttpPort = data.http_port
    this.beaconHttpsPort = httpsPort
    if (bridgeTlsPort > 0) {
      this.bridgeTlsIp = data.broker_ip
      this.bridgeTlsPort = bridgeTlsPort
    }

    console.info(`[Beacon] broker=${data.broker_ip}, mqtt=${data.mqtt_port}, dayuMqtts=${tlsPort}, esp32Mqtts=${esp32TlsPort}, bridgeTls=${bridgeTlsPort}, http=${data.http_port}, https=${httpsPort}`)

    // 地址变化时自动重连 HTTP
    if (newBridgeUrl !== oldBridgeUrl) {
      console.info(`[Beacon] address changed, reconnecting from ${oldBridgeUrl} to ${newBridgeUrl}`)
      this.reconnectBridge()
    }

    if (BRIDGE_TLS_AUTO_CONNECT_ENABLED && bridgeTlsPort > 0) {
      if (!this.bridgeTls.isConnected() || !this.bridgeTls.matchesBridge(data.broker_ip, bridgeTlsPort)) {
        this.ensureBridgeTlsAutoConnect(data.broker_ip, bridgeTlsPort)
      }
    }

    if (DAYU_DIRECT_MQTT_ENABLED) {
      const preferredMqttTls = DAYU_PREFER_MQTT_TLS && tlsPort > 0 && Date.now() >= this.mqttTlsFallbackUntil
      const desiredMqttPort = preferredMqttTls ? tlsPort : data.mqtt_port
      const desiredMqttUseTls = preferredMqttTls
      if (newBridgeUrl !== oldBridgeUrl || !this.mqtt.isConnected() || !this.mqtt.matchesBroker(data.broker_ip, desiredMqttPort, desiredMqttUseTls)) {
        this.connectMqttWithFallback(data.broker_ip, data.mqtt_port, tlsPort).catch((err: Error) => {
          console.info(`[MQTT][auto-connect-fail] ${err.message}`)
        })
      }
    }
  }

  arrayBufferToUtf8(buffer: ArrayBuffer): string {
    const bytes = new Uint8Array(buffer)
    let result = ''
    for (let i = 0; i < bytes.length; i++) {
      const first = bytes[i]
      if (first < 0x80) {
        result += String.fromCharCode(first)
      } else if (first >= 0xC0 && first < 0xE0 && i + 1 < bytes.length) {
        const second = bytes[++i]
        result += String.fromCharCode(((first & 0x1F) << 6) | (second & 0x3F))
      } else if (first >= 0xE0 && first < 0xF0 && i + 2 < bytes.length) {
        const second = bytes[++i]
        const third = bytes[++i]
        result += String.fromCharCode(((first & 0x0F) << 12) | ((second & 0x3F) << 6) | (third & 0x3F))
      }
    }
    return result
  }

  // 空调控制 → 加密后发送到 ESP32 专用 AC Topic
  async sendACControl(temp: number, power: boolean, mode: string, seq: number): Promise<void> {
    const baseUrl = this.normalizeBridgeUrl(this.bridgeUrl)
    this.bridgeUrl = baseUrl
    const acCmd = JSON.stringify({ cmd: 'ac', power, temp, mode, seq })
    await this.sendEncryptedCommand(baseUrl, acCmd, 'dayu/cmd', this.deviceForCapability('ac'))
  }

  // 窗帘电机控制 — 加密 MQTT 发送
  async sendCurtainControl(percentage: number): Promise<void> {
    const baseUrl = this.normalizeBridgeUrl(this.bridgeUrl)
    const normalized = Math.max(0, Math.min(100, Math.round(percentage)))
    const seq = this.nextCurtainCommandSeq()
    const cmd = JSON.stringify({ cmd: 'curtain', val: normalized, seq })
    await this.sendEncryptedCommand(baseUrl, cmd, 'dayu/cmd', this.deviceForCapability('curtain'))
    this.reportCloudCurtain(normalized, 'dayu')
  }

  // 联动 DAYU210 本地预警弹窗。
  triggerLocalAlarm(alertLevel: number, msg: string): void {
    console.info(`[HW][triggerLocalAlarm] level=${alertLevel}, msg=${msg}`)
    this.alertLevel = alertLevel
    this.alertMessage = msg
    this.showCriticalDialog = false
  }

  async registerFaceData(): Promise<void> {
    this.showFaceEnrollPanel = true
    this.faceAccessStatus = '正在请求相机权限...'
    await this.probeFaceAccess()
  }

  async probeFaceAccess(): Promise<void> {
    try {
      const context = getContext(this)
      const result: FaceAccessProbeResult = await this.faceAccess.probeCamera(context)
      this.faceAccessStatus = result.ok ? '相机已准备好' : '相机暂不可用，请检查连接'
      this.faceCameraSummary = result.ok ? '相机已连接，可以开始录入或识别' : '相机暂不可用'
      console.info(`[FaceAccess][probe] ${JSON.stringify(result)}`)
    } catch (err) {
      this.faceAccessStatus = '相机暂不可用，请稍后重试'
      console.info(`[FaceAccess][probe-fail] ${(err as Error).message}`)
    }
  }

  async startFacePreview(): Promise<boolean> {
    try {
      if (this.facePreviewSurfaceId.length === 0) {
        this.facePreviewSurfaceId = this.facePreviewController.getXComponentSurfaceId()
      }
      if (this.facePreviewSurfaceId.length === 0) {
        this.faceAccessStatus = '预览窗口还没准备好'
        return false
      }
      const context = getContext(this)
      const result: FaceAccessProbeResult = await this.faceAccess.startPreview(context, this.facePreviewSurfaceId, 370 / 300)
      this.facePreviewReady = result.ok
      this.faceAccessStatus = result.ok ? '请正对摄像头' : '预览启动失败，请重试'
      this.faceCameraSummary = result.ok ? '相机已连接，可以开始录入或识别' : '相机暂不可用'
      console.info(`[FaceAccess][preview-start] ${JSON.stringify(result)}`)
      return result.ok
    } catch (err) {
      this.facePreviewReady = false
      this.faceAccessStatus = '预览启动失败，请重试'
      console.info(`[FaceAccess][preview-start-fail] ${(err as Error).message}`)
      return false
    }
  }

  async stopFacePreview(): Promise<void> {
    this.facePreviewReady = false
    await this.faceAccess.stopPreview()
  }

  async startFaceEnrollment(): Promise<void> {
    if (this.faceEnrollBusy) {
      return
    }
    const name = this.faceEnrollName.trim()
    if (name.length === 0) {
      this.faceAccessStatus = '请先输入用户姓名'
      return
    }
    if (!this.facePreviewReady) {
      this.faceAccessStatus = '正在打开预览...'
      const previewOk = await this.startFacePreview()
      if (!previewOk) {
        return
      }
    }
    this.faceEnrollProgress = 0
    this.faceEnrollBusy = true
    this.faceAccessStatus = '采集中 0/5'
    try {
      const context = getContext(this)
      const embeddingSamples: number[][] = []
      const captureRounds = 5
      let attempt = 0
      while (embeddingSamples.length < captureRounds && attempt < FACE_ENROLL_MAX_ATTEMPTS) {
        attempt++
        this.faceAccessStatus = `正在拍摄 ${embeddingSamples.length + 1}/${captureRounds} · 尝试 ${attempt}/${FACE_ENROLL_MAX_ATTEMPTS}`
        const result: FaceCaptureResult = await this.faceAccess.captureFaceSample(context)
        if (!result.ok) {
          this.faceAccessStatus = '未检测到清晰人脸，请正对摄像头重试'
          return
        }
        if (result.embeddingDimension <= 0 || result.embedding.length !== result.embeddingDimension) {
          this.faceAccessStatus = '人脸特征提取失败，请重试'
          return
        }
        if (result.qualityScore >= 0 && result.qualityScore < FACE_ENROLL_MIN_QUALITY) {
          this.faceAccessStatus = `画面质量偏低，请保持正对摄像头 ${embeddingSamples.length}/${captureRounds}`
          continue
        }
        embeddingSamples.push(result.embedding)
        this.faceEnrollProgress = embeddingSamples.length
        this.faceAccessStatus = `已采集 ${this.faceEnrollProgress}/${captureRounds}`
      }
      if (embeddingSamples.length < captureRounds) {
        this.faceAccessStatus = `采集失败: 合格样本不足 ${embeddingSamples.length}/${captureRounds}，请正对摄像头重试`
        return
      }
      const user = this.faceAccess.addUserFromEmbeddings(name, embeddingSamples)
      await this.faceAccess.saveUsers(context)
      this.faceUsers = this.faceAccess.listUsers()
      this.faceAccessStatus = `已录入 ${user.name}，共 ${user.samples} 个本地样本`
      this.faceEnrollName = ''
    } catch (err) {
      this.faceAccessStatus = '采集失败，请稍后重试'
      console.info(`[FaceAccess][enroll-fail] ${(err as Error).message}`)
    } finally {
      this.faceEnrollBusy = false
    }
  }

  async identifyFaceOnce(): Promise<void> {
    if (this.faceIdentifyBusy || this.faceEnrollBusy) {
      return
    }
    if (this.faceUsers.length === 0) {
      this.faceAccessStatus = '请先录入授权用户'
      return
    }
    if (!this.facePreviewReady) {
      this.faceAccessStatus = '正在打开预览...'
      const previewOk = await this.startFacePreview()
      if (!previewOk) {
        return
      }
    }
    this.faceIdentifyBusy = true
    this.faceAccessStatus = `正在识别 0/${FACE_VERIFY_REQUIRED_SAMPLES}`
    try {
      const context = getContext(this)
      const buckets: Record<string, FaceVerifyBucket> = {}
      let validSamples = 0
      let attempts = 0
      let lastMatch: FaceMatchResult | null = null

      while (validSamples < FACE_VERIFY_REQUIRED_SAMPLES && attempts < FACE_VERIFY_MAX_ATTEMPTS) {
        attempts++
        this.faceAccessStatus = `正在识别 ${validSamples}/${FACE_VERIFY_REQUIRED_SAMPLES} · 尝试 ${attempts}/${FACE_VERIFY_MAX_ATTEMPTS}`
        const result: FaceCaptureResult = await this.faceAccess.captureFaceSample(context)
        if (!result.ok) {
          this.faceAccessStatus = '未检测到清晰人脸，请正对摄像头重试'
          return
        }
        if (result.embeddingDimension <= 0 || result.embedding.length !== result.embeddingDimension) {
          this.faceAccessStatus = '未能识别人脸，请重试'
          return
        }
        if (result.qualityScore >= 0 && result.qualityScore < FACE_IDENTIFY_MIN_QUALITY) {
          this.faceAccessStatus = '人脸不够清晰，请正对摄像头'
          continue
        }

        validSamples++
        const match: FaceMatchResult = this.faceAccess.matchEmbedding(result.embedding, 0.75, result.preprocessVersion)
        lastMatch = match
        if (match.matched) {
          const oldBucket: FaceVerifyBucket | undefined = buckets[match.userId]
          const bucket: FaceVerifyBucket = oldBucket ?? {
            userId: match.userId,
            userName: match.userName,
            hits: 0,
            totalScore: 0,
            bestScore: -1
          }
          bucket.hits += 1
          bucket.totalScore += match.score
          bucket.bestScore = Math.max(bucket.bestScore, match.score)
          buckets[match.userId] = bucket
        }
        this.faceAccessStatus = `正在确认身份 ${validSamples}/${FACE_VERIFY_REQUIRED_SAMPLES}`
      }

      if (validSamples < FACE_VERIFY_REQUIRED_SAMPLES) {
        this.faceAccessStatus = `识别失败: 合格帧不足 ${validSamples}/${FACE_VERIFY_REQUIRED_SAMPLES}，请正对摄像头重试`
        return
      }

      let hasBestBucket = false
      let bestBucket: FaceVerifyBucket = {
        userId: '',
        userName: '',
        hits: 0,
        totalScore: 0,
        bestScore: -1
      }
      Object.keys(buckets).forEach((key: string) => {
        const bucket = buckets[key]
        if (!hasBestBucket || bucket.hits > bestBucket.hits || (bucket.hits === bestBucket.hits && bucket.bestScore > bestBucket.bestScore)) {
          bestBucket = bucket
          hasBestBucket = true
        }
      })

      if (hasBestBucket) {
        const avgScore = bestBucket.totalScore / bestBucket.hits
        if (bestBucket.hits >= FACE_VERIFY_REQUIRED_HITS && avgScore >= FACE_VERIFY_AVG_THRESHOLD) {
          const shouldUnlock = this.doorLocked
          const actionText = shouldUnlock ? '开锁' : '关锁'
          this.faceAccessStatus = `识别通过：${bestBucket.userName}，正在${actionText}`
          await this.sendDoorControl(shouldUnlock, bestBucket.userId, bestBucket.userName, avgScore)
          return
        }
        this.faceAccessStatus = '识别结果不稳定，请正对摄像头重试'
        return
      }

      if (lastMatch !== null) {
        this.faceAccessStatus = '未识别到授权用户'
      } else {
        this.faceAccessStatus = '未识别到授权用户'
      }
    } catch (err) {
      this.faceAccessStatus = '识别失败，请稍后重试'
      console.info(`[FaceAccess][identify-fail] ${(err as Error).message}`)
    } finally {
      this.faceIdentifyBusy = false
    }
  }

  async deleteFaceUser(userId: string): Promise<void> {
    this.faceAccess.deleteUser(userId)
    this.faceUsers = this.faceAccess.listUsers()
    try {
      const context = getContext(this)
      await this.faceAccess.saveUsers(context)
      this.faceAccessStatus = '用户已删除并保存'
    } catch (err) {
      this.faceAccessStatus = `用户已删除，但保存失败: ${(err as Error).message}`
    }
  }

  refreshProvisioningDefaults(): void {
    const httpBridge = this.normalizeBridgeUrl(this.bridgeUrl)
    const fallbackHost = this.extractHostFromUrl(httpBridge)
    const host = this.localGatewayHost.length > 0 ? this.localGatewayHost : fallbackHost
    this.applyProvisioningTlsMode(this.provisioningUseTls, host.length > 0 ? host : '192.168.3.5')
    this.provisioningCrypto = currentCryptoMode().toLowerCase()
    this.provisioningTransport = 'mqtt'
  }

  applyProvisioningTlsMode(useTls: boolean, preferredHost: string = ''): void {
    const brokerHost = this.extractHostFromUrl(this.provisioningBrokerUrl)
    const bridgeHost = this.extractHostFromUrl(this.provisioningHttpBridge)
    const host = preferredHost.length > 0 ? preferredHost :
      brokerHost.length > 0 ? brokerHost :
      bridgeHost.length > 0 ? bridgeHost :
      this.beaconBrokerIp.length > 0 ? this.beaconBrokerIp :
      this.extractHostFromUrl(this.normalizeBridgeUrl(this.bridgeUrl))
    const targetHost = host.length > 0 ? host : '192.168.3.5'
    const isLocalGateway = this.localGatewayHost.length > 0 && targetHost === this.localGatewayHost
    const mqttPort = isLocalGateway ? (useTls ? 8884 : 1883) :
      useTls ? this.portOrDefault(this.beaconEsp32MqttTlsPort, 8884) : this.portOrDefault(this.beaconMqttPort, 1883)
    const bridgePort = isLocalGateway ? (useTls ? 3444 : 3000) :
      useTls ? this.portOrDefault(this.beaconHttpsPort, 3444) : this.portOrDefault(this.beaconHttpPort, 3000)
    this.provisioningUseTls = useTls
    this.provisioningBrokerUrl = useTls ? `mqtts://${targetHost}:${mqttPort}` : `mqtt://${targetHost}:${mqttPort}`
    this.provisioningHttpBridge = useTls ? `https://${targetHost}:${bridgePort}` : `http://${targetHost}:${bridgePort}`
  }

  portOrDefault(port: number, fallback: number): number {
    return port > 0 ? port : fallback
  }

  extractHostFromUrl(url: string): string {
    const protocolEnd = url.indexOf('://')
    const start = protocolEnd >= 0 ? protocolEnd + 3 : 0
    let end = url.indexOf('/', start)
    if (end < 0) {
      end = url.length
    }
    const hostPort = url.substring(start, end)
    const colon = hostPort.indexOf(':')
    return colon >= 0 ? hostPort.substring(0, colon) : hostPort
  }

  ipv4NumberToString(ipAddress: number): string {
    const normalized = ipAddress >>> 0
    return `${(normalized >>> 24) & 0xFF}.${(normalized >>> 16) & 0xFF}.${(normalized >>> 8) & 0xFF}.${normalized & 0xFF}`
  }

  async refreshProvisioningWifiInfo(): Promise<void> {
    try {
      const linkedInfo = await wifiManager.getLinkedInfo()
      if (linkedInfo.ipAddress !== 0) {
        const localHost = this.ipv4NumberToString(linkedInfo.ipAddress)
        if (localHost !== '0.0.0.0') {
          this.localGatewayHost = localHost
          this.bridgeUrl = `http://${localHost}:3000`
          this.beaconBrokerIp = localHost
          this.beaconMqttPort = 1883
          this.beaconMqttTlsPort = 8884
          this.beaconEsp32MqttTlsPort = 8884
          this.beaconHttpPort = 3000
          this.beaconHttpsPort = 3444
          this.applyProvisioningTlsMode(this.provisioningUseTls, localHost)
          this.addProvisioningLog(`设备网关地址已就绪: ${localHost}`)
        }
      }
      if (linkedInfo.ssid && linkedInfo.ssid.length > 0 && linkedInfo.ssid !== '<unknown ssid>') {
        this.provisioningWifiSsid = linkedInfo.ssid
        this.addProvisioningLog(`WiFi SSID 自动填充: ${linkedInfo.ssid}`)
      } else {
        this.addProvisioningLog('未读取到当前 WiFi SSID，可手动填写')
      }
    } catch (err) {
      this.addProvisioningLog(`WiFi SSID 自动获取失败: ${(err as Error).message}`)
    }
  }

  openProvisioningPanel(): void {
    this.showProvisioningPanel = true
    this.refreshProvisioningDefaults()
    setTimeout(() => {
      if (this.showProvisioningPanel) {
        this.refreshProvisioningUsbDevices()
        this.refreshProvisioningWifiInfo()
      }
    }, 0)
  }

  closeProvisioningPanel(): void {
    this.showProvisioningOutputPanel = false
    this.showProvisioningPanel = false
    this.stopProvisioningEnterLoop()
    this.cancelProvisioningAutoProbe()
    this.clearProvisioningPendingFrame(false)
    this.provisioningBusy = false
    this.provisioningPort.close().catch((err: Error) => {
      console.info(`[Provisioning][close-fail] ${err.message}`)
    })
  }

  refreshProvisioningUsbDevices(): void {
    try {
      const previousIndex = this.provisioningSelectedDeviceIndex
      const previousDevice = this.provisioningUsbDevices.length > 0 ?
        this.provisioningUsbDevices[Math.max(0, Math.min(this.provisioningUsbDevices.length - 1, previousIndex))] :
        undefined
      const previousKey = previousDevice === undefined ? '' : this.provisioningDeviceKey(previousDevice)
      const devices = this.provisioningPort.listDevices()
      let nextIndex = 0
      if (previousKey.length > 0) {
        for (let i = 0; i < devices.length; i += 1) {
          if (this.provisioningDeviceKey(devices[i]) === previousKey) {
            nextIndex = i
            break
          }
        }
      } else if (previousIndex < devices.length) {
        nextIndex = previousIndex
      }
      this.provisioningUsbDevices = devices
      this.provisioningSelectedDeviceIndex = devices.length > 0 ? nextIndex : 0
      this.provisioningStatus = this.provisioningUsbDevices.length > 0 ?
        `发现 ${this.provisioningUsbDevices.length} 个 USB 设备` :
        '未发现 USB 设备'
      this.addProvisioningDiagnosticLog(this.provisioningStatus)
    } catch (err) {
      this.provisioningStatus = `USB 扫描失败: ${(err as Error).message}`
      this.addProvisioningLog(this.provisioningStatus)
    }
  }

  provisioningDeviceKey(device: UsbSerialDeviceInfo): string {
    return `${device.kind}|${device.vendorId}|${device.productId}|${device.name}|` +
      `${device.serialPortId !== undefined ? device.serialPortId : '-'}|` +
      `${device.usbIndex !== undefined ? device.usbIndex : '-'}|` +
      `${device.usbInterfaceId !== undefined ? device.usbInterfaceId : '-'}|` +
      `${device.usbControlInterfaceId !== undefined ? device.usbControlInterfaceId : '-'}`
  }

  selectedProvisioningDeviceText(): string {
    if (this.provisioningUsbDevices.length === 0) {
      return '未选择设备'
    }
    const index = Math.max(0, Math.min(this.provisioningUsbDevices.length - 1, this.provisioningSelectedDeviceIndex))
    const device = this.provisioningUsbDevices[index]
    return `${index + 1}/${this.provisioningUsbDevices.length} ${device.title}`
  }

  selectProvisioningDevice(delta: number): void {
    if (this.provisioningUsbDevices.length === 0) {
      return
    }
    const count = this.provisioningUsbDevices.length
    this.provisioningSelectedDeviceIndex = (this.provisioningSelectedDeviceIndex + delta + count) % count
  }

  async connectProvisioningUsb(): Promise<void> {
    if (this.provisioningBusy) {
      return
    }
    this.provisioningBusy = true
    try {
      const result = await this.provisioningPort.open(
        this.provisioningSelectedDeviceIndex,
        (frame: ProvisioningFrame) => {
          this.handleProvisioningFrame(frame)
        },
        (message: string) => {
          this.handleProvisioningPortLog(message)
        }
      )
      this.provisioningConnected = result.ok
      this.provisioningFlowStage = PROVISIONING_STAGE_IDLE
      this.provisioningStatus = result.message
      this.addProvisioningLog(result.message)
    } catch (err) {
      this.provisioningConnected = false
      this.provisioningFlowStage = PROVISIONING_STAGE_IDLE
      this.provisioningStatus = `串口连接失败: ${(err as Error).message}`
      this.addProvisioningLog(this.provisioningStatus)
    } finally {
      this.provisioningBusy = false
    }
  }

  async disconnectProvisioningUsb(): Promise<void> {
    this.stopProvisioningEnterLoop()
    await this.provisioningPort.close()
    this.provisioningConnected = false
    this.provisioningFlowStage = PROVISIONING_STAGE_IDLE
    this.provisioningStatus = '串口已断开'
    this.addProvisioningLog(this.provisioningStatus)
  }

  waitProvisioningMs(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve()
      }, ms)
    })
  }

  waitProvisioningFrame(type: ProvisioningFrameType, seq: number, timeoutMs: number, allowAnySeq: boolean = false): Promise<boolean> {
    this.clearProvisioningPendingFrame(false)
    this.provisioningPendingFrameType = type
    this.provisioningPendingFrameSeq = seq
    this.provisioningPendingFrameAllowAnySeq = allowAnySeq
    this.provisioningLastPendingMatchedSeq = -1
    this.provisioningPendingErrorText = ''
    return new Promise<boolean>((resolve: (matched: boolean) => void) => {
      this.provisioningPendingFrameResolve = resolve
      this.provisioningPendingFrameTimerId = setTimeout(() => {
        this.clearProvisioningPendingFrame(false)
      }, timeoutMs)
    })
  }

  clearProvisioningPendingFrame(matched: boolean): void {
    if (this.provisioningPendingFrameTimerId !== -1) {
      clearTimeout(this.provisioningPendingFrameTimerId)
      this.provisioningPendingFrameTimerId = -1
    }
    const resolve = this.provisioningPendingFrameResolve
    this.provisioningPendingFrameResolve = null
    this.provisioningPendingFrameType = -1
    this.provisioningPendingFrameSeq = -1
    this.provisioningPendingFrameAllowAnySeq = false
    if (resolve !== null) {
      resolve(matched)
    }
  }

  nextProvisioningSeq(): number {
    this.provisioningSeq = (this.provisioningSeq + 1) & 0xFF
    if (this.provisioningSeq === 0) {
      this.provisioningSeq = 1
    }
    return this.provisioningSeq
  }

  async sendProvisioningFrame(type: ProvisioningFrameType, payload: Uint8Array = new Uint8Array(0)): Promise<boolean> {
    return this.sendProvisioningFrameWithSeq(type, this.nextProvisioningSeq(), payload)
  }

  async sendProvisioningFrameWithSeq(type: ProvisioningFrameType, seq: number, payload: Uint8Array = new Uint8Array(0)): Promise<boolean> {
    if (!this.provisioningConnected) {
      this.provisioningStatus = '请先连接 USB 串口'
      this.addProvisioningLog(this.provisioningStatus)
      return false
    }
    const typeName = provisioningTypeName(type)
    try {
      await this.provisioningPort.writeFrame(type, seq, payload)
      this.provisioningStatus = `已发送 ${typeName} #${seq}`
      return true
    } catch (err) {
      this.provisioningStatus = `发送 ${typeName} 失败: ${this.describeProvisioningError(err)}`
      this.addProvisioningDiagnosticLog(this.provisioningStatus)
      return false
    }
  }

  describeProvisioningError(err: Object | string | number | boolean | null | undefined): string {
    if (err === null || err === undefined) {
      return 'empty error'
    }
    if (typeof err === 'string' || typeof err === 'number' || typeof err === 'boolean') {
      return `${err}`
    }
    const maybeError = err as Error
    if (maybeError.message && maybeError.message.length > 0) {
      return maybeError.message
    }
    return JSON.stringify(err)
  }

  startProvisioningMode(): void {
    if (!this.provisioningConnected) {
      this.provisioningStatus = '请先连接 USB 串口'
      this.addProvisioningLog(this.provisioningStatus)
      return
    }
    this.stopProvisioningEnterLoop()
    this.provisioningSeq = 1
    this.provisioningFlowStage = PROVISIONING_STAGE_ENTERING
    this.provisioningEnterStopAt = Date.now() + 15000
    this.provisioningStatus = '正在进入配网模式，请现在按设备 Reset 键'
    this.addProvisioningLog('开始配网: 15 秒内每 1 秒发送 ENTER_CONFIG #1，等待 0x11 ACK')
    this.sendProvisioningFrameWithSeq(ProvisioningFrameType.ENTER_CONFIG, 1)
      .catch((err: Error) => {
        this.addProvisioningLog(`[ENTER_CONFIG] ${err.message}`)
      })
    this.provisioningEnterTimerId = setInterval(() => {
      if (Date.now() > this.provisioningEnterStopAt) {
        this.stopProvisioningEnterLoop()
        this.provisioningFlowStage = PROVISIONING_STAGE_IDLE
        this.provisioningStatus = '进入配网模式超时：设备没有响应'
        this.addProvisioningLog(this.provisioningStatus)
        return
      }
      this.sendProvisioningFrameWithSeq(ProvisioningFrameType.ENTER_CONFIG, 1)
        .catch((err: Error) => {
          this.addProvisioningLog(`[ENTER_CONFIG] ${err.message}`)
        })
    }, 1000)
  }

  async autoProbeProvisioningUsb(): Promise<void> {
    if (this.provisioningBusy) {
      return
    }
    this.stopProvisioningEnterLoop()
    this.provisioningBusy = true
    this.provisioningAutoProbeActive = true
    this.provisioningAutoProbeMatched = false
    const runId = this.nextProvisioningAutoProbeRunId()
    this.provisioningSeq = 1
    this.provisioningFlowStage = PROVISIONING_STAGE_ENTERING
    try {
      const deadline = Date.now() + 15000
      this.provisioningStatus = '自动探测中：请现在按设备 Reset 键'

      if (this.provisioningConnected && this.provisioningPort.isOpen()) {
        this.addProvisioningDiagnosticLog('自动探测: 使用当前已连接串口，不重新打开 USB，不切 DTR/RTS')
        await this.probeProvisioningEnterUntil(deadline, 'current', runId)
      } else {
        await this.provisioningPort.close()
        if (!this.isProvisioningAutoProbeCurrent(runId)) {
          return
        }
        this.provisioningConnected = false
        this.refreshProvisioningUsbDevices()
        if (this.provisioningUsbDevices.length === 0) {
          this.provisioningStatus = '没有可探测的 USB 串口接口'
          this.addProvisioningDiagnosticLog(this.provisioningStatus)
          return
        }
        const index = Math.max(0, Math.min(this.provisioningUsbDevices.length - 1, this.provisioningSelectedDeviceIndex))
        this.provisioningSelectedDeviceIndex = index
        this.addProvisioningDiagnosticLog(`自动探测: 锁定当前选中接口 ${this.selectedProvisioningDeviceText()}，不自动切换其他候选`)
        const result = await this.provisioningPort.open(
          index,
          (frame: ProvisioningFrame) => {
            this.handleProvisioningFrame(frame)
          },
          (message: string) => {
            this.handleProvisioningPortLog(message)
          }
        )
        if (!this.isProvisioningAutoProbeCurrent(runId)) {
          return
        }
        this.provisioningConnected = result.ok
        this.provisioningStatus = result.message
        this.addProvisioningDiagnosticLog(result.message)
        if (result.ok) {
          await this.probeProvisioningEnterUntil(deadline, `device-${index}`, runId)
          if (this.isProvisioningAutoProbeCurrent(runId) && !this.provisioningAutoProbeMatched) {
            this.provisioningConnected = this.provisioningPort.isOpen()
            this.provisioningFlowStage = PROVISIONING_STAGE_IDLE
            this.addProvisioningDiagnosticLog('自动探测未收到 ACK，已保持当前串口连接，方便继续查看设备输出')
          }
        }
      }
      if (!this.isProvisioningAutoProbeCurrent(runId)) {
        return
      }
      if (this.provisioningAutoProbeMatched) {
        this.provisioningStatus = `自动探测成功：${this.selectedProvisioningDeviceText()}`
        this.addProvisioningDiagnosticLog(this.provisioningStatus)
      } else {
        this.provisioningFlowStage = PROVISIONING_STAGE_IDLE
        this.provisioningStatus = '自动探测结束：设备没有响应，请检查串口连接'
        this.addProvisioningDiagnosticLog(this.provisioningStatus)
      }
    } catch (err) {
      this.provisioningConnected = this.provisioningPort.isOpen()
      this.provisioningStatus = `自动探测失败: ${(err as Error).message}`
      this.addProvisioningDiagnosticLog(this.provisioningStatus)
    } finally {
      if (this.isProvisioningAutoProbeCurrent(runId)) {
        this.provisioningAutoProbeActive = false
        this.provisioningBusy = false
      }
    }
  }

  async probeProvisioningEnterUntil(deadline: number, label: string, runId: number): Promise<void> {
    while (Date.now() < deadline && !this.provisioningAutoProbeMatched && this.isProvisioningAutoProbeCurrent(runId)) {
      try {
        await this.provisioningPort.writeFrame(ProvisioningFrameType.ENTER_CONFIG, 1)
      } catch (err) {
        this.provisioningConnected = this.provisioningPort.isOpen()
        this.addProvisioningDiagnosticLog(`[PROBE][${label}][TX] ${(err as Error).message}`)
        return
      }
      await this.waitProvisioningMs(1000)
    }
  }

  nextProvisioningAutoProbeRunId(): number {
    this.provisioningAutoProbeRunId = (this.provisioningAutoProbeRunId + 1) & 0x7FFFFFFF
    if (this.provisioningAutoProbeRunId === 0) {
      this.provisioningAutoProbeRunId = 1
    }
    return this.provisioningAutoProbeRunId
  }

  cancelProvisioningAutoProbe(): void {
    if (!this.provisioningAutoProbeActive) {
      return
    }
    this.provisioningAutoProbeRunId = (this.provisioningAutoProbeRunId + 1) & 0x7FFFFFFF
    if (this.provisioningAutoProbeRunId === 0) {
      this.provisioningAutoProbeRunId = 1
    }
    this.provisioningAutoProbeActive = false
    this.provisioningBusy = false
  }

  isProvisioningAutoProbeCurrent(runId: number): boolean {
    return this.provisioningAutoProbeActive && this.provisioningAutoProbeRunId === runId
  }

  stopProvisioningEnterLoop(): void {
    if (this.provisioningEnterTimerId !== -1) {
      clearInterval(this.provisioningEnterTimerId)
      this.provisioningEnterTimerId = -1
    }
  }

  async sendProvisioningConfig(): Promise<void> {
    this.cancelProvisioningAutoProbe()
    if (this.provisioningBusy) {
      this.addProvisioningDiagnosticLog('已忽略重复的发送配置操作')
      return
    }
    if (this.provisioningWifiSsid.trim().length === 0) {
      this.provisioningStatus = '请填写 WiFi SSID'
      this.addProvisioningLog(this.provisioningStatus)
      return
    }
    if (this.provisioningBrokerUrl.trim().length === 0) {
      this.provisioningStatus = '请填写 MQTT brokerUrl'
      this.addProvisioningLog(this.provisioningStatus)
      return
    }
    const config: ProvisioningConfig = {
      ssid: this.provisioningWifiSsid.trim(),
      password: this.provisioningWifiPassword,
      brokerUrl: this.provisioningBrokerUrl.trim(),
      httpBridge: this.provisioningHttpBridge.trim(),
      deviceId: 'auto',
      crypto: this.provisioningCrypto,
      transport: this.provisioningTransport
    }
    this.stopProvisioningEnterLoop()
    this.provisioningBusy = true
    const previousStage = this.provisioningFlowStage
    try {
      const sessionAlreadyReady = this.provisioningConnected && this.provisioningPort.isOpen() &&
        previousStage >= PROVISIONING_STAGE_CONFIG_MODE
      if (sessionAlreadyReady) {
        this.addProvisioningDiagnosticLog('沿用本次自动探测已确认的配网会话，直接发送 CONFIG_SET')
      }
      const ready = sessionAlreadyReady || await this.confirmProvisioningConfigMode()
      if (!ready) {
        this.provisioningFlowStage = previousStage
        this.provisioningStatus = '发送配置前确认失败：设备未处于配网模式'
        this.addProvisioningDiagnosticLog(this.provisioningStatus)
        return
      }
      await this.waitForProvisioningHandshakeDrain()
      this.provisioningFlowStage = PROVISIONING_STAGE_CONFIG_SENT
      const configSeq = this.nextProvisioningSeq()
      const configPayload = buildProvisioningConfigPayload(config)
      const rxBytesBeforeConfig = this.provisioningPort.receivedByteCount()
      const waitConfigAck = this.waitProvisioningFrame(
        ProvisioningFrameType.CONFIG_ACK,
        configSeq,
        PROVISIONING_CONFIG_ACK_TIMEOUT_MS,
        true
      )
      const sent = await this.sendProvisioningFrameWithSeq(
        ProvisioningFrameType.CONFIG_SET,
        configSeq,
        configPayload
      )
      if (sent) {
        this.addProvisioningDiagnosticLog(
          `CONFIG_SET 已发送: payload=${configPayload.length}B, ssid=${config.ssid}, broker=${config.brokerUrl}, password=******`
        )
        this.provisioningStatus = `等待设备确认配置 #${configSeq}`
        this.addProvisioningDiagnosticLog(this.provisioningStatus)
        if (await waitConfigAck) {
          this.provisioningFlowStage = PROVISIONING_STAGE_CONFIG_ACKED
          if (this.provisioningLastPendingMatchedSeq === configSeq) {
            this.provisioningStatus = `设备已接收网络配置 #${configSeq}`
          } else {
            this.provisioningStatus = `收到 CONFIG_ACK 但 seq 不一致：期望 #${configSeq}，实际 #${this.provisioningLastPendingMatchedSeq}`
          }
          this.addProvisioningDiagnosticLog(this.provisioningStatus)
        } else {
          if (this.provisioningPendingErrorText.length > 0) {
            this.provisioningStatus = `设备拒绝网络配置 #${configSeq}：${this.provisioningPendingErrorText}`
            this.addProvisioningDiagnosticLog(this.provisioningStatus)
          } else {
            const receivedBytes = Math.max(0, this.provisioningPort.receivedByteCount() - rxBytesBeforeConfig)
            this.provisioningStatus = '网络配置已发送，请点击“保存重启”完成设备接入'
            this.addProvisioningDiagnosticLog(this.provisioningStatus)
            this.addProvisioningDiagnosticLog(
              `未收到 CONFIG_ACK #${configSeq}，期间串口返回 ${receivedBytes}B；未收到设备 ERROR，允许使用 REBOOT 容错保存`
            )
          }
        }
      } else {
        this.clearProvisioningPendingFrame(false)
        this.provisioningFlowStage = previousStage
      }
    } finally {
      this.clearProvisioningPendingFrame(false)
      this.provisioningBusy = false
    }
  }

  async confirmProvisioningConfigMode(): Promise<boolean> {
    this.provisioningFlowStage = PROVISIONING_STAGE_ENTERING
    for (let i = 0; i < PROVISIONING_CONFIG_MODE_CONFIRM_ATTEMPTS; i += 1) {
      const seq = this.nextProvisioningSeq()
      const waitAck = this.waitProvisioningFrame(
        ProvisioningFrameType.CONFIG_MODE_ACK,
        seq,
        PROVISIONING_CONFIG_MODE_CONFIRM_TIMEOUT_MS
      )
      const sent = await this.sendProvisioningFrameWithSeq(ProvisioningFrameType.ENTER_CONFIG, seq)
      if (!sent) {
        this.clearProvisioningPendingFrame(false)
        return false
      }
      this.provisioningStatus = `正在确认设备配网模式 #${seq}`
      this.addProvisioningDiagnosticLog(this.provisioningStatus)
      if (await waitAck) {
        this.provisioningFlowStage = PROVISIONING_STAGE_CONFIG_MODE
        return true
      }
    }
    return false
  }

  async waitForProvisioningHandshakeDrain(): Promise<void> {
    const startedAt = Date.now()
    let lastRxBytes = this.provisioningPort.receivedByteCount()
    let quietSince = startedAt
    while (Date.now() - startedAt < 5000) {
      await this.waitProvisioningMs(100)
      const currentRxBytes = this.provisioningPort.receivedByteCount()
      if (currentRxBytes !== lastRxBytes) {
        lastRxBytes = currentRxBytes
        quietSince = Date.now()
      }
      const minimumDrainElapsed = Date.now() - startedAt >= 2500
      const receiveQueueQuiet = Date.now() - quietSince >= 800
      if (minimumDrainElapsed && receiveQueueQuiet) {
        this.addProvisioningDiagnosticLog('配网握手回复队列已清空，准备发送网络配置')
        return
      }
    }
    this.addProvisioningDiagnosticLog('配网握手回复持续到达，等待上限后继续发送网络配置')
  }

  async saveProvisioningConfig(): Promise<void> {
    const previousStage = this.provisioningFlowStage
    this.provisioningFlowStage = PROVISIONING_STAGE_REBOOT_SENT
    const sent = await this.sendProvisioningFrame(ProvisioningFrameType.REBOOT)
    if (sent) {
      this.provisioningStatus = '配置已发送，等待设备保存并重启'
      this.addProvisioningLog(this.provisioningStatus)
    } else {
      this.provisioningFlowStage = previousStage
    }
  }

  async testProvisioningConfig(): Promise<void> {
    await this.sendProvisioningFrame(ProvisioningFrameType.CONFIG_TEST)
  }

  async rebootProvisioningDevice(): Promise<void> {
    const previousStage = this.provisioningFlowStage
    this.provisioningFlowStage = PROVISIONING_STAGE_REBOOT_SENT
    const sent = await this.sendProvisioningFrame(ProvisioningFrameType.REBOOT)
    if (sent) {
      this.provisioningStatus = '配置已发送，等待设备保存并重启'
      this.addProvisioningLog(this.provisioningStatus)
    } else {
      this.provisioningFlowStage = previousStage
    }
  }

  openIrLearnPanel(): void {
    this.showIrLearnPanel = true
    if (!this.irLearnActive && this.irLearnCompletedCount < IR_LEARN_KEY_LABELS.length) {
      this.irLearnStatus = '正在准备空调万能适配'
      setTimeout(() => {
        if (this.showIrLearnPanel && !this.irLearnActive) {
          this.irLearnStatus = this.isBridgeActuallyConnected() ?
            `当前 ${this.commandTransportText()} / ${this.cryptoMode}-GCM，可以开始红外学习` :
            '当前加密通信未连接，请先等待设备和服务上线'
        }
      }, 0)
    }
  }

  irLearnCurrentLabel(): string {
    const index = Math.max(0, Math.min(IR_LEARN_KEY_LABELS.length - 1, this.irLearnStep))
    return IR_LEARN_KEY_LABELS[index]
  }

  irLearnPrimaryActionText(): string {
    if (this.irLearnBusy) {
      return this.irLearnActive ? '学习进行中' : '等待设备'
    }
    if (this.irLearnActive) {
      return '学习进行中'
    }
    if (this.irLearnCompletedCount >= IR_LEARN_KEY_LABELS.length) {
      return '重新学习'
    }
    return '开始学习'
  }

  countIrLearnResults(results: number[]): number {
    let count = 0
    for (let i = 0; i < results.length; i++) {
      if (results[i] > 0) {
        count += 1
      }
    }
    return count
  }

  async runIrLearnPrimaryAction(): Promise<void> {
    if (this.irLearnBusy || this.irLearnActive) {
      return
    }
    await this.startIrLearning()
  }

  clearIrLearnTimer(): void {
    if (this.irLearnTimerId !== -1) {
      clearTimeout(this.irLearnTimerId)
      this.irLearnTimerId = -1
    }
  }

  startIrLearnTimeout(timeoutMs: number, message: string): void {
    this.clearIrLearnTimer()
    this.irLearnTimerId = setTimeout(() => {
      this.irLearnTimerId = -1
      if (this.irLearnExpectedAction === 'learn-all') {
        if (!this.irLearnHandshakeConfirmed) {
          this.irLearnActive = false
          this.irLearnBusy = false
          this.irLearnExpectedSeq = -1
          this.irLearnExpectedAction = ''
        } else {
          this.irLearnActive = true
          this.irLearnBusy = true
        }
      } else {
        this.irLearnBusy = false
      }
      this.irLearnStatus = message
      console.info(`[IR][timeout] action=${this.irLearnExpectedAction} seq=${this.irLearnExpectedSeq} ${message}`)
      this.addMqttMessage('esp32/ac', `[IR timeout] ${message}`)
    }, timeoutMs)
  }

  nextIrCommandSeq(): number {
    this.irCommandSeq = (this.irCommandSeq % 999999) + 1
    return this.irCommandSeq
  }

  async sendIrCommand(action: string, index: number, timeoutMs: number, timeoutMessage: string): Promise<boolean> {
    if (!this.isBridgeActuallyConnected()) {
      this.irLearnBusy = false
      this.irLearnStatus = '当前加密通信未连接，请等待设备和服务上线'
      return false
    }
    const seq = this.nextIrCommandSeq()
    const command: IrControlCommand = {
      cmd: 'ir',
      action,
      seq
    }
    if (index > 0) {
      command.index = index
    }
    this.irLearnBusy = true
    this.irLearnExpectedAction = action
    this.irLearnExpectedIndex = index
    this.irLearnExpectedSeq = seq
    this.startIrLearnTimeout(timeoutMs, timeoutMessage)
    try {
      await this.sendEncryptedCommand(this.normalizeBridgeUrl(this.bridgeUrl), JSON.stringify(command), 'dayu/cmd',
        this.deviceForCapability('ac'))
      console.info(`[IR][sent] transport=${this.commandTransportText()} action=${action} index=${index} seq=${seq}`)
      return true
    } catch (err) {
      this.clearIrLearnTimer()
      this.irLearnBusy = false
      if (action === 'learn-all') {
        this.irLearnActive = false
      }
      this.irLearnStatus = `红外指令发送失败：${(err as Error).message}`
      console.info(`[IR][send-fail] action=${action} index=${index} seq=${seq} ${(err as Error).message}`)
      return false
    }
  }

  async startIrLearning(): Promise<void> {
    if (this.irLearnBusy) {
      return
    }
    if (!this.isBridgeActuallyConnected()) {
      this.irLearnStatus = '当前加密通信未连接，请等待设备和服务上线'
      return
    }
    this.irLearnActive = true
    this.irLearnHandshakeConfirmed = false
    this.irLearnStep = 0
    this.irLearnCompletedCount = 0
    this.irLearnResults = [0, 0, 0, 0, 0, 0]
    this.irLearnStatus = `正在通过 ${this.commandTransportText()} 通知设备进入学习模式`
    await this.sendIrCommand('learn-all', 0, IR_COMMAND_ACK_TIMEOUT_MS,
      '设备未确认学习请求，请检查通信状态')
  }

  async exitIrLearning(closePanel: boolean = true): Promise<void> {
    this.clearIrLearnTimer()
    const shouldNotifyEsp32 = this.irLearnActive && this.isBridgeActuallyConnected()
    if (closePanel) {
      this.showIrLearnPanel = false
    }
    this.irLearnActive = false
    this.irLearnHandshakeConfirmed = false
    this.irLearnBusy = false
    this.irLearnExpectedSeq = -1
    this.irLearnExpectedAction = ''
    this.irLearnExpectedIndex = 0
    if (this.irLearnCompletedCount < IR_LEARN_KEY_LABELS.length) {
      this.irLearnStatus = '已退出红外学习模式'
    }
    if (shouldNotifyEsp32) {
      this.sendIrCommand('exit', 0, IR_COMMAND_ACK_TIMEOUT_MS, '设备退出学习模式未回复').then(() => {
        this.clearIrLearnTimer()
        this.irLearnBusy = false
      }).catch((err: Error) => {
        this.clearIrLearnTimer()
        this.irLearnBusy = false
        console.info(`[IR][exit-fail] ${err.message}`)
      })
    }
  }

  async testIrLearnedKey(index: number): Promise<void> {
    if (this.irLearnBusy || index < 1 || index > IR_LEARN_KEY_LABELS.length) {
      return
    }
    this.irLearnStatus = `正在测试发射“${IR_LEARN_KEY_LABELS[index - 1]}”编码`
    await this.sendIrCommand('send', index, IR_COMMAND_ACK_TIMEOUT_MS,
      `测试“${IR_LEARN_KEY_LABELS[index - 1]}”未收到设备回复`)
  }

  handleIrAck(data: Record<string, Object>): void {
    const actionValue = data['action']
    const action = typeof actionValue === 'string' ? actionValue.toLowerCase() : ''
    const seq = typeof data['seq'] === 'number' ? data['seq'] as number : 0
    const index = typeof data['index'] === 'number' ? data['index'] as number : 0
    const ok = data['ok'] === true
    const msgValue = data['msg']
    const msg = typeof msgValue === 'string' ? msgValue : ''

    const perKeyLearnAck = this.irLearnActive && this.irLearnExpectedAction === 'learn-all' &&
      action === 'learn' && index >= 1 && index <= IR_LEARN_KEY_LABELS.length
    if (perKeyLearnAck) {
      if (this.irLearnResults[index - 1] > 0) {
        console.info(`[IR][ack-duplicate] index=${index} seq=${seq}`)
        return
      }
      if (seq > 0 && seq !== this.irLearnExpectedSeq) {
        console.info(`[IR][ack-seq-note] session=${this.irLearnExpectedSeq} received=${seq} index=${index}; accepted by index`)
      }
      this.clearIrLearnTimer()
      const label = IR_LEARN_KEY_LABELS[index - 1]
      const results = this.irLearnResults.slice()
      results[index - 1] = ok ? 1 : 2
      this.irLearnResults = results
      const receivedCount = this.countIrLearnResults(results)
      this.irLearnCompletedCount = receivedCount

      if (!ok && msg !== 'timeout') {
        this.irLearnActive = false
        this.irLearnBusy = false
        this.irLearnHandshakeConfirmed = false
        this.irLearnExpectedSeq = -1
        this.irLearnExpectedAction = ''
        this.irLearnStatus = `“${label}”进入学习失败：${msg.length > 0 ? msg : '红外模块异常'}，流程已停止`
        console.info(`[IR][learn-stop] index=${index} seq=${seq} msg=${msg}`)
        return
      }

      console.info(`[IR][learn-result] index=${index} ok=${ok} seq=${seq} msg=${msg}`)
      if (index >= IR_LEARN_KEY_LABELS.length) {
        this.irLearnStep = IR_LEARN_KEY_LABELS.length - 1
        this.irLearnActive = false
        this.irLearnBusy = false
        this.irLearnHandshakeConfirmed = false
        this.irLearnExpectedSeq = -1
        this.irLearnExpectedAction = ''
        this.irLearnCompletedCount = IR_LEARN_KEY_LABELS.length
        this.irLearnStatus = receivedCount >= IR_LEARN_KEY_LABELS.length ?
          '六项学习流程完成，编码已保存，可测试开机和关机' :
          `设备已完成六项学习，大禹收到 ${receivedCount}/6 条结果`
        return
      }

      this.irLearnStep = Math.max(this.irLearnStep, index)
      this.irLearnBusy = true
      this.irLearnStatus = ok ?
        `“${label}”学习成功，3 秒后请按“${this.irLearnCurrentLabel()}”` :
        `“${label}”等待超时，已跳过；3 秒后请按“${this.irLearnCurrentLabel()}”`
      this.startIrLearnTimeout(IR_LEARN_STEP_ACK_TIMEOUT_MS,
        `未收到“${this.irLearnCurrentLabel()}”的学习结果，请检查设备状态`)
      return
    }

    if (seq > 0 && seq !== this.irLearnExpectedSeq) {
      console.info(`[IR][ack-ignore] pending=${this.irLearnExpectedSeq} received=${seq} action=${action} index=${index}`)
      return
    }
    const matchedSeq = this.irLearnExpectedSeq
    const learnAllAck = this.irLearnExpectedAction === 'learn-all' && action === 'learn-all'
    if (!learnAllAck && action !== this.irLearnExpectedAction) {
      console.info(`[IR][ack-action-ignore] pending=${this.irLearnExpectedAction} received=${action} seq=${seq}`)
      return
    }
    if (action === 'learn' && !learnAllAck && index !== this.irLearnExpectedIndex) {
      console.info(`[IR][ack-index-ignore] pending=${this.irLearnExpectedIndex} received=${index} seq=${seq}`)
      return
    }
    this.clearIrLearnTimer()
    this.irLearnBusy = false
    this.irLearnExpectedSeq = -1

    if (!ok) {
      if (learnAllAck) {
        this.irLearnActive = false
        this.irLearnStatus = `设备进入学习模式失败：${msg.length > 0 ? msg : 'unknown'}，请重试`
        return
      }
      const label = index >= 1 && index <= IR_LEARN_KEY_LABELS.length ? IR_LEARN_KEY_LABELS[index - 1] : this.irLearnCurrentLabel()
      const reason = msg === 'timeout' ? '等待遥控器信号超时' : (msg.length > 0 ? msg : '设备执行失败')
      this.irLearnStatus = action === 'send' ? `“${label}”测试失败：${reason}` : `“${label}”学习失败：${reason}，可以重试`
      console.info(`[IR][ack-fail] action=${action} index=${index} seq=${seq} msg=${msg}`)
      return
    }

    if (learnAllAck) {
      this.irLearnActive = true
      this.irLearnBusy = true
      this.irLearnHandshakeConfirmed = true
      this.irLearnExpectedAction = 'learn-all'
      this.irLearnExpectedSeq = matchedSeq
      this.irLearnStep = 0
      this.irLearnStatus = '请将遥控器对准 ZJ-IR-V2，按下“开机”键'
      this.startIrLearnTimeout(IR_LEARN_STEP_ACK_TIMEOUT_MS,
        '未收到“开机”的学习结果，请检查设备状态')
      return
    }

    if (action === 'send') {
      const label = index >= 1 && index <= IR_LEARN_KEY_LABELS.length ? IR_LEARN_KEY_LABELS[index - 1] : `${index}`
      this.irLearnStatus = `“${label}”红外编码已发射，请确认空调是否响应`
      return
    }

    if (action === 'exit') {
      this.irLearnActive = false
      this.irLearnStatus = '设备已退出红外学习模式'
    }
  }

  handleProvisioningFrame(frame: ProvisioningFrame): void {
    const payloadText = frame.payload.length > 0 ? utf8Decode(frame.payload) : ''
    this.addProvisioningEsp32Log(this.describeProvisioningFrame(frame, payloadText))
    const pendingSeqMatches = frame.seq === this.provisioningPendingFrameSeq ||
      this.provisioningPendingFrameAllowAnySeq
    if (frame.type === ProvisioningFrameType.ERROR && this.provisioningPendingFrameResolve !== null &&
      pendingSeqMatches) {
      this.provisioningPendingErrorText = payloadText.length > 0 ? payloadText : `ERROR #${frame.seq}`
      this.clearProvisioningPendingFrame(false)
    } else if (frame.type === this.provisioningPendingFrameType && pendingSeqMatches) {
      this.provisioningLastPendingMatchedSeq = frame.seq
      this.clearProvisioningPendingFrame(true)
    }
    switch (frame.type) {
      case ProvisioningFrameType.CONFIG_MODE_ACK:
        this.stopProvisioningEnterLoop()
        this.provisioningAutoProbeMatched = true
        this.cancelProvisioningAutoProbe()
        if (this.provisioningFlowStage <= PROVISIONING_STAGE_CONFIG_MODE) {
          this.provisioningFlowStage = PROVISIONING_STAGE_CONFIG_MODE
          this.provisioningStatus = `设备已进入配网模式 #${frame.seq}`
        } else {
          this.addProvisioningEsp32Log(`忽略迟到的 CONFIG_MODE_ACK #${frame.seq}，当前已在后续步骤`)
          return
        }
        break
      case ProvisioningFrameType.CONFIG_ACK:
        this.provisioningFlowStage = PROVISIONING_STAGE_CONFIG_ACKED
        this.provisioningStatus = `设备已接收网络配置 #${frame.seq}`
        break
      case ProvisioningFrameType.CONFIG_SAVED:
        this.provisioningFlowStage = PROVISIONING_STAGE_SAVED
        this.provisioningStatus = `设备已保存配置 #${frame.seq}，将自动重启`
        console.info(`[Provisioning][saved] waiting device_hello seq=${frame.seq}`)
        break
      case ProvisioningFrameType.CONFIG_TEST_RESULT:
        this.provisioningStatus = payloadText.length > 0 ? `测试结果: ${payloadText}` : `测试结果 #${frame.seq}`
        break
      case ProvisioningFrameType.ERROR:
        this.provisioningStatus = payloadText.length > 0 ? `设备错误：${payloadText}` : `设备错误 #${frame.seq}`
        break
      default:
        this.provisioningStatus = `收到 ${provisioningTypeName(frame.type)} #${frame.seq}`
        break
    }
    this.addProvisioningEsp32Log(this.provisioningStatus)
  }

  describeProvisioningFrame(frame: ProvisioningFrame, payloadText: string): string {
    const typeHex = frame.type.toString(16).toUpperCase().padStart(2, '0')
    if (frame.payload.length === 0) {
      return `[FRAME] ${provisioningTypeName(frame.type)} type=0x${typeHex} seq=${frame.seq} len=0`
    }
    const text = payloadText.length > 0 ? ` text="${payloadText.substring(0, 96)}"` : ''
    return `[FRAME] ${provisioningTypeName(frame.type)} type=0x${typeHex} seq=${frame.seq} len=${frame.payload.length} payload=${toHex(frame.payload, 64)}${text}`
  }

  addProvisioningLog(message: string): void {
    console.info(`[Provisioning] ${message}`)
  }

  handleProvisioningPortLog(message: string): void {
    this.addProvisioningLog(message)
    if (message.startsWith('[RX][raw]') ||
      message.startsWith('[RX][candidate]') ||
      message.startsWith('[RX][drop]') ||
      message.startsWith('[RX][ascii-hex]') ||
      message.startsWith('[TX]') ||
      message.startsWith('[OPEN]') ||
      (message.startsWith('[RX]') && message.indexOf('idle, no data') < 0)) {
      this.addProvisioningEsp32Log(message)
    }
  }

  addProvisioningDiagnosticLog(message: string): void {
    this.addProvisioningLog(message)
    this.addProvisioningEsp32Log(`[APP] ${message}`)
  }

  addProvisioningEsp32Log(message: string): void {
    const time = new Date().toLocaleTimeString()
    this.provisioningLogSeq = (this.provisioningLogSeq + 1) % 10000
    const seqText = this.provisioningLogSeq.toString().padStart(4, '0')
    this.pendingProvisioningFrameLogs.unshift(`${time} #${seqText} ${message}`)
    if (this.provisioningLogFlushTimerId === -1) {
      this.provisioningLogFlushTimerId = setTimeout(() => {
        this.flushProvisioningEsp32Log()
      }, 50)
    }
  }

  flushProvisioningEsp32Log(): void {
    this.provisioningLogFlushTimerId = -1
    if (this.pendingProvisioningFrameLogs.length === 0) {
      return
    }
    const next = [...this.pendingProvisioningFrameLogs, ...this.provisioningFrameLog]
    this.pendingProvisioningFrameLogs = []
    this.provisioningFrameLog = next.slice(0, 200)
  }

  clearProvisioningEsp32Log(): void {
    if (this.provisioningLogFlushTimerId !== -1) {
      clearTimeout(this.provisioningLogFlushTimerId)
      this.provisioningLogFlushTimerId = -1
    }
    this.pendingProvisioningFrameLogs = []
    this.provisioningFrameLog = []
  }

  refreshClock(): void {
    const now = new Date()
    const hh = this.pad2(now.getHours())
    const mm = this.pad2(now.getMinutes())
    const yyyy = now.getFullYear()
    const month = now.getMonth() + 1
    const day = now.getDate()
    const weekList: string[] = ['星期日', '星期一', '星期二', '星期三', '星期四', '星期五', '星期六']
    this.currentTime = `${hh}:${mm}`
    this.currentDate = `${yyyy}年${month}月${day}日  ${weekList[now.getDay()]}`
  }

  pad2(value: number): string {
    return value < 10 ? `0${value}` : `${value}`
  }

  requestOpenDebugPanel(): void {
    const now = Date.now()
    if (now - this.debugPanelLastTapAt > 1400) {
      this.debugPanelTapCount = 0
    }
    this.debugPanelLastTapAt = now
    this.debugPanelTapCount += 1
    if (this.debugPanelTapCount >= 3) {
      this.debugPanelTapCount = 0
      this.debugShowAllDevices = false
      this.showDebugPanel = true
    }
  }

  settingsProtocolIcon(): Resource {
    return this.transportForDevice(this.activeDeviceId) === 'HTTP' ?
      $r('app.media.settings_http_comic') : $r('app.media.settings_mqtt_comic')
  }

  settingsCryptoIcon(): Resource {
    return this.cryptoMode === 'AES' ?
      $r('app.media.settings_aes_comic') : $r('app.media.settings_sm4_comic')
  }

  handleSettingsFeature(action: string): void {
    if (action === 'status') {
      this.showDeviceStatusPanel = true
      return
    }
    if (action === 'provisioning') {
      this.openProvisioningPanel()
      return
    }
    if (action === 'ir') {
      // Force a fresh panel instance so a stale invisible overlay cannot swallow the next open.
      this.showIrLearnPanel = false
      setTimeout(() => {
        this.openIrLearnPanel()
      }, 16)
      return
    }
    if (action === 'voiceprint') {
      this.openVoiceprintManager()
      return
    }
    if (action === 'binding') {
      this.showDeviceBindingPanel = true
      return
    }
    if (action === 'protocol') {
      if (this.protocolPendingMode.length === 0) {
        const currentTransport = this.transportForDevice(this.activeDeviceId)
        this.selectCommandTransport(currentTransport === 'MQTT' ? 'HTTP' : 'MQTT')
      }
      return
    }
    if (action === 'crypto') {
      if (this.cryptoPendingMode.length === 0) {
        this.selectCryptoMode(this.cryptoMode === 'SM4' ? 'AES' : 'SM4')
      }
      return
    }
    if (action === 'debug') {
      this.requestOpenDebugPanel()
    }
  }

  pageBg(): string {
    if (this.hasActiveDeviceAlarm()) {
      return this.isDarkMode ? '#2B0D12' : '#F9E8E9'
    }
    return this.isDarkMode ? '#07111A' : '#DDF5EC'
  }

  backgroundGradientColors(): Array<[string, number]> {
    if (this.hasActiveDeviceAlarm()) {
      return this.isDarkMode
        ? [['#4A1118', 0.0], ['#2A0C12', 0.48], ['#6B1D20', 1.0]]
        : [
          ['#F0C9CC', 0.0],
          ['#F4D5D7', 0.16],
          ['#F8E2E3', 0.33],
          ['#FCEEEF', 0.50],
          ['#FFF7F6', 0.64],
          ['#F9E8E9', 0.78],
          ['#F5DADC', 0.90],
          ['#EFCBCD', 1.0]
        ]
    }
    if (this.isDarkMode) {
      return [['#0D2925', 0.0], ['#09161A', 0.48], ['#12362F', 1.0]]
    }
    return [
      ['#B4E3CE', 0.0],
      ['#C3E9D8', 0.16],
      ['#D3F0E4', 0.33],
      ['#E5F7F0', 0.50],
      ['#EFFAF6', 0.64],
      ['#DDF3EA', 0.78],
      ['#CDEBDD', 0.90],
      ['#BCE5D6', 1.0]
    ]
  }

  navItemGradientColors(key: string): Array<[string, number]> {
    if (this.activeNav === key) {
      if (this.hasActiveDeviceAlarm()) {
        return this.isDarkMode
          ? [['#51252B', 0.0], ['#78363E', 1.0]]
          : [['#FFF0F1', 0.0], ['#EFAEB4', 1.0]]
      }
      return this.isDarkMode
        ? [['#174B43', 0.0], ['#1C6B5D', 1.0]]
        : [['#C9FFF1', 0.0], ['#63E2C2', 1.0]]
    }
    const background = this.softPanelBg()
    return [[background, 0.0], [background, 1.0]]
  }

  sideBg(): string {
    if (this.hasActiveDeviceAlarm()) {
      return this.isDarkMode ? '#351016' : '#F8E5E6'
    }
    return this.isDarkMode ? '#07111A' : '#DDF5EC'
  }

  cardBg(): string {
    return this.isDarkMode ? '#E6101926' : '#E0FFFFFF'
  }

  softPanelBg(): string {
    if (this.hasActiveDeviceAlarm()) {
      return this.isDarkMode ? '#3B2228' : '#F9E9EA'
    }
    return this.isDarkMode ? '#19273A' : '#E5F7F4'
  }

  textColor(): string {
    return this.isDarkMode ? '#EEF6FF' : '#111716'
  }

  pageTitleColor(): string {
    if (this.hasActiveDeviceAlarm()) {
      return this.isDarkMode ? '#F1A8AF' : '#963E47'
    }
    return this.isDarkMode ? '#70E6D2' : '#106C61'
  }

  pageTitleGlowColor(): string {
    if (this.hasActiveDeviceAlarm()) {
      return this.isDarkMode ? '#F18E9866' : '#CE6D7742'
    }
    return this.isDarkMode ? '#5EF2D866' : '#27C7AA42'
  }

  subTextColor(): string {
    if (this.hasActiveDeviceAlarm()) {
      return this.isDarkMode ? '#D0A7AC' : '#785D61'
    }
    return this.isDarkMode ? '#95A7BB' : '#5D7472'
  }

  hairlineColor(): string {
    if (this.hasActiveDeviceAlarm()) {
      return this.isDarkMode ? '#E48A9438' : '#E1B8BC'
    }
    return this.isDarkMode ? '#7EB3FF29' : '#A9D2CA'
  }

  accentBlue(): string {
    if (this.hasActiveDeviceAlarm()) {
      return this.isDarkMode ? '#E07B84' : '#CC6670'
    }
    return this.isDarkMode ? '#5AA9FF' : '#2589FF'
  }

  accentOrange(): string {
    return this.hasActiveDeviceAlarm() ? '#E49A58' : '#5AA9FF'
  }

  accentGreen(): string {
    return this.hasActiveDeviceAlarm() ? '#C45D67' : '#25A395'
  }

  accentGlowColor(): string {
    return this.hasActiveDeviceAlarm() ? '#C45D6742' : '#28C9AA42'
  }

  activeDeviceBorderColor(): string {
    return this.hasActiveDeviceAlarm() ? '#C45D6788' : '#25A39588'
  }

  brandLogoGradientColors(): Array<[string, number]> {
    return this.hasActiveDeviceAlarm()
      ? [['#C45D67', 0.0], ['#E49A58', 1.0]]
      : [['#863BFF', 0.0], ['#47BFFF', 1.0]]
  }

  controlTrackColor(): string {
    if (this.hasActiveDeviceAlarm()) {
      return this.isDarkMode ? '#5A353A' : '#EAD2D5'
    }
    return this.isDarkMode ? '#3A3F44' : '#DCE7EF'
  }

  alarmCardBg(): string {
    return this.isDarkMode ? '#4A2026' : '#F7DCDD'
  }

  alarmTextColor(): string {
    return this.isDarkMode ? '#FFDDE0' : '#762D36'
  }

  alarmSubTextColor(): string {
    return this.isDarkMode ? '#EAB7BC' : '#92545B'
  }

  warningRed(): string {
    return '#D97662'
  }

  alertColor(): string {
    if (this.alertLevel === 1) {
      return '#4FA8F6'
    }
    if (this.alertLevel === 2) {
      return '#D97662'
    }
    if (this.alertLevel === 3) {
      return '#A94442'
    }
    return '#38C98D'
  }

  alertTitle(): string {
    if (this.smokeAlarm && this.waterAlarm) {
      return '烟雾与水浸异常'
    }
    if (this.smokeAlarm) {
      return '烟雾异常'
    }
    if (this.waterAlarm) {
      return '水浸异常'
    }
    if (this.alertLevel === 1) {
      return '轻微漂移，正在自检'
    }
    if (this.alertLevel === 2) {
      return '检测到疑似微渗'
    }
    if (this.alertLevel === 3) {
      return '严重事件，请立即处理'
    }
    return '安全运行，系统稳定'
  }

  alertIcon(): string {
    if (this.alertLevel === 1) {
      return '!'
    }
    if (this.alertLevel === 2) {
      return '!!'
    }
    if (this.alertLevel === 3) {
      return 'AL'
    }
    return 'OK'
  }

  navTitle(): string {
    if (this.activeNav === 'devices') {
      return '设备'
    }
    if (this.activeNav === 'settings') {
      return '设置'
    }
    return '总览'
  }

  navSubtitle(): string {
    if (this.activeNav === 'devices') {
      return '空调、照明、窗帘与扩展设备'
    }
    if (this.activeNav === 'settings') {
      return '通信、加密、接入与调试'
    }
    return '鸿蒙家居智能终端'
  }

  commandTransportText(): string {
    const currentTransport = this.transportForDevice(this.activeDeviceId)
    if (this.protocolPendingMode.length > 0) {
      return `${currentTransport}->${this.protocolPendingMode}`
    }
    return currentTransport
  }

  selectCommandTransport(mode: string): void {
    const target = this.normalizeProtocolMode(mode)
    const previous = this.transportForDevice(this.activeDeviceId)
    if (this.protocolPendingMode.length > 0) {
      this.cryptoDebugText = `协议切换中 ${previous}->${this.protocolPendingMode}`
      console.info(`[PROTO][ui-select] ignore ${previous}->${target}; pending=${this.protocolPendingMode}`)
      return
    }
    console.info(`[PROTO][ui-select] request ${previous}->${target}`)
    this.requestProtocolSwitch(target)
      .catch((err: Error) => {
        console.info(`[PROTO][ui-select][send-fail] ${previous}->${target}: ${err.message}`)
      })
  }

  simulateAlert(): void {
    const nextLevel = (this.alertLevel + 1) % 4
    const messages: string[] = [
      '全屋设备运行正常',
      '烟雾传感器基线轻微漂移，正在自检',
      '厨房水浸探头检测到疑似微渗',
      '检测到烟雾/水浸/跌倒复合严重事件'
    ]
    console.info(`[MOCK][simulateAlert] nextLevel=${nextLevel}`)
    if (nextLevel >= 3) {
      this.triggerLocalAlarm(nextLevel, messages[nextLevel])
    } else {
      this.alertLevel = nextLevel
      this.alertMessage = messages[nextLevel]
      this.showCriticalDialog = false
    }
  }

  async setACBrand(brand: string): Promise<void> {
    this.acBrand = brand
    this.acAckText = `已选择 ${brand}`
    console.info(`[AC][brand] local selection=${brand}; ESP32 AC protocol has no brand field`)
  }

  async changeACTemp(value: number): Promise<void> {
    this.acTemp = Math.max(16, Math.min(30, Math.round(value)))
    console.info(`[MOCK][changeACTemp] temp=${this.acTemp}`)
    await this.requestACControl('temp')
  }

  changeACTempBy(delta: number): void {
    const nextTemp = Math.max(16, Math.min(30, this.acTemp + delta))
    if (nextTemp === this.acTemp) {
      return
    }
    this.changeACTemp(nextTemp).catch((err: Error) => {
      console.info(`[AC][temp-step-fail] ${err.message}`)
    })
  }

  toggleACMode(): void {
    this.acMode = this.acMode === 'cool' ? 'heat' : 'cool'
    console.info(`[AC][mode] ${this.acMode}`)
    this.requestACControl('mode').catch((err: Error) => {
      console.info(`[AC][mode-fail] ${err.message}`)
    })
  }

  acModeText(): string {
    return this.acMode === 'heat' ? '制热' : '制冷'
  }

  nextACCommandSeq(): number {
    this.acCommandSeq = (this.acCommandSeq % 999999) + 1
    return this.acCommandSeq
  }

  nextCurtainCommandSeq(): number {
    this.curtainCommandSeq = (this.curtainCommandSeq % 999999) + 1
    return this.curtainCommandSeq
  }

  clearACAckTimer(): void {
    if (this.acAckTimerId !== -1) {
      clearTimeout(this.acAckTimerId)
      this.acAckTimerId = -1
    }
  }

  startACAckTimer(seq: number): void {
    this.clearACAckTimer()
    this.acAckTimerId = setTimeout(() => {
      if (this.acPendingSeq === seq) {
        this.acPendingSeq = 0
        this.acAckText = `设备确认超时 #${seq}`
        console.info(`[AC][ack-timeout] seq=${seq}`)
      }
      this.acAckTimerId = -1
    }, 4500)
  }

  async requestACControl(reason: string): Promise<void> {
    this.acQueuedReason = reason
    if (this.acControlTimerId !== -1) {
      clearTimeout(this.acControlTimerId)
      this.acControlTimerId = -1
    }

    if (reason !== 'power') {
      this.acAckText = `等待合并 ${this.commandTransportText()}`
      this.acControlTimerId = setTimeout(() => {
        this.acControlTimerId = -1
        this.flushACControl(this.acQueuedReason.length > 0 ? this.acQueuedReason : reason)
      }, 260)
      return
    }

    await this.flushACControl(reason)
  }

  async flushACControl(reason: string): Promise<void> {
    if (this.acPending) {
      this.acNeedsSendAfterPending = true
      this.acQueuedReason = reason
      console.info(`[AC][ui-queue] pending reason=${reason}`)
      return
    }
    const signature = `${this.acTemp}|${this.acPower}|${this.acMode}`
    const now = Date.now()
    if (signature === this.acLastSentSignature && now - this.acLastSentAt < 900) {
      console.info(`[AC][ui-skip] duplicate ${signature}`)
      this.acAckText = `已发送 ${this.commandTransportText()}`
      return
    }

    this.acPending = true
    this.acNeedsSendAfterPending = false
    this.acAckText = `正在发送 ${this.commandTransportText()}`
    console.info(`[AC][ui] reason=${reason} brand=${this.acBrand} temp=${this.acTemp} power=${this.acPower} mode=${this.acMode} transport=${this.commandTransportText()}`)
    const seq = this.nextACCommandSeq()
    this.acPendingSeq = seq
    try {
      await this.sendACControl(this.acTemp, this.acPower, this.acMode, seq)
      this.acLastSentSignature = signature
      this.acLastSentAt = Date.now()
      if (this.acPendingSeq === seq) {
        this.acAckText = `等待设备确认 #${seq}`
        this.startACAckTimer(seq)
      }
      console.info(`[AC][sent] reason=${reason} seq=${seq}`)
    } catch (err) {
      if (this.acPendingSeq === seq) {
        this.acPendingSeq = 0
      }
      this.clearACAckTimer()
      this.acAckText = `发送失败 ${(err as Error).message}`
      console.info(`[AC][send-fail] reason=${reason} ${(err as Error).message}`)
    } finally {
      this.acPending = false
      if (this.acNeedsSendAfterPending) {
        this.acNeedsSendAfterPending = false
        const queuedReason = this.acQueuedReason.length > 0 ? this.acQueuedReason : 'queued'
        setTimeout(() => {
          this.flushACControl(queuedReason)
        }, 80)
      }
    }
  }

  async changeCurtain(value: number): Promise<void> {
    this.curtainPercent = Math.max(0, Math.min(100, Math.round(value)))
    console.info(`[MOCK][changeCurtain] percentage=${this.curtainPercent}`)
    await this.sendCurtainControl(this.curtainPercent)
  }

  overviewWeatherText(): string {
    const location = this.outdoorWeatherUpdateText.split(' · ')[0]
    return `${location.length > 0 ? location : '南京市江宁区'} · ${this.outdoorWeatherLabel}`
  }

  overviewVoiceLevel(): number {
    let peak = 0.04
    const start = Math.max(0, this.voiceWaveform.length - 8)
    for (let index = start; index < this.voiceWaveform.length; index++) {
      peak = Math.max(peak, this.voiceWaveform[index])
    }
    return Math.max(0.04, Math.min(1, peak))
  }

  overviewDoorTap(): void {
    const now = Date.now()
    if (this.overviewDoorTapTimerId !== -1 && now - this.overviewDoorLastTapAt < 360) {
      clearTimeout(this.overviewDoorTapTimerId)
      this.overviewDoorTapTimerId = -1
      this.overviewDoorLastTapAt = 0
      this.registerFaceData()
      return
    }
    this.overviewDoorLastTapAt = now
    this.overviewDoorTapTimerId = setTimeout(() => {
      this.overviewDoorTapTimerId = -1
      if (this.doorPending) {
        return
      }
      this.sendDoorControl(this.doorLocked).catch((err: Error) => {
        console.info(`[DOOR][overview-fail] ${err.message}`)
      })
    }, 260)
  }

  beginCurtainOverviewDrag(): void {
    this.curtainDragStartPercent = this.curtainPercent
  }

  updateCurtainOverviewDrag(offsetX: number): void {
    const next = this.curtainDragStartPercent + offsetX / 2.1
    this.curtainPercent = Math.max(0, Math.min(100, Math.round(next)))
  }

  finishCurtainOverviewDrag(): void {
    this.sendCurtainControl(this.curtainPercent).catch((err: Error) => {
      console.info(`[CURTAIN][overview-fail] ${err.message}`)
    })
  }

  leaveHome(): void {
    this.leavingMode = true
    this.doorLocked = true
    this.livingLightOn = false
    this.bedroomLightOn = false
    this.acPower = false
    this.curtainPercent = 0
    console.info('[MOCK][leaveHome] lock door, lights off, AC off, curtain closed')
    this.sendLightControl('living', false)
    this.sendLightControl('bedroom', false)
    const acSeq = this.nextACCommandSeq()
    this.acPendingSeq = acSeq
    this.sendACControl(this.acTemp, false, this.acMode, acSeq).then(() => {
      if (this.acPendingSeq === acSeq) {
        this.acAckText = `等待设备确认 #${acSeq}`
        this.startACAckTimer(acSeq)
      }
    }).catch((err: Error) => {
      if (this.acPendingSeq === acSeq) {
        this.acPendingSeq = 0
      }
      this.acAckText = `发送失败 ${err.message}`
    })
    this.sendCurtainControl(0)
  }

  exitApp(): void {
    const context = getContext(this) as common.UIAbilityContext
    context.terminateSelf().catch((err: Error) => {
      console.info(`[App][exit-fail] ${err.message}`)
    })
  }

  @Builder
  SectionTitle(title: string, subTitle: string, mark: string) {
    Row() {
      Text(mark)
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.subTextColor())
        .width(28)
        .height(28)
        .textAlign(TextAlign.Center)
        .backgroundColor(this.softPanelBg())
        .borderRadius(10)

      Column() {
        Text(title)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.textColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(subTitle)
          .fontSize(12)
          .fontColor(this.subTextColor())
          .margin({ top: 3 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 12 })

      Text('>')
        .fontSize(20)
        .fontColor(this.subTextColor())
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  DeviceSectionTitle(title: string, subTitle: string, icon: Resource, active: boolean, accent: string) {
    Row() {
      Stack({ alignContent: Alignment.Center }) {
        Image(icon)
          .width(20)
          .height(20)
          .objectFit(ImageFit.Contain)
      }
      .width(28)
      .height(28)
      .backgroundColor(accent)
      .borderRadius(8)

      Column() {
        Text(title)
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.textColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(subTitle)
          .fontSize(12)
          .fontColor(this.subTextColor())
          .margin({ top: 3 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 12 })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  Pill(label: string, value: string, color: string) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor(this.subTextColor())
        .layoutWeight(1)
      Text(value)
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(color)
    }
    .height(42)
    .padding({ left: 14, right: 14 })
    .borderRadius(21)
    .backgroundColor(this.softPanelBg())
    .border({ width: 1, color: this.hairlineColor() })
  }

  @Builder
  MiniPill(label: string, value: string, color: string) {
    Row() {
      Text(label)
        .fontSize(12)
        .fontColor(this.subTextColor())
        .maxLines(1)
      Blank()
      Text(value)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(color)
        .maxLines(1)
    }
    .layoutWeight(1)
    .height(38)
    .padding({ left: 12, right: 12 })
    .borderRadius(19)
    .backgroundColor(this.softPanelBg())
    .border({ width: 1, color: this.hairlineColor() })
  }

  @Builder
  AlarmStatusPill(label: string, target: string, active: boolean) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor(active ? '#FFE9E6' : this.subTextColor())
        .maxLines(1)
      Blank()
      Text(active ? '异常' : '正常')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(active ? '#FFFFFF' : this.accentGreen())
        .maxLines(1)
    }
    .layoutWeight(1)
    .height(42)
    .padding({ left: 13, right: 13 })
    .borderRadius(8)
    .backgroundColor(active ? '#D06A73' : this.softPanelBg())
    .border({ width: 1, color: active ? '#E8A8AE' : this.hairlineColor() })
    .onClick(() => {
      this.openAlarmClearDialog(target)
    })
  }

  @Builder
  BrandLogo() {
    Column() {
      Image($r('app.media.app_icon'))
        .width(58)
        .height(58)
        .objectFit(ImageFit.Cover)
        .borderRadius(16)
        .border({ width: 2, color: '#E3C56B' })

      Column() {
        Text('智能家居')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.textColor())
          .maxLines(1)
        Text('禹家')
          .fontSize(10)
          .fontColor(this.subTextColor())
          .margin({ top: 3 })
          .maxLines(1)
      }
      .alignItems(HorizontalAlign.Center)
      .margin({ top: 8 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  NavItem(key: string, label: string, icon: Resource) {
    Column() {
      Image(icon)
        .width(22)
        .height(22)
        .objectFit(ImageFit.Contain)

      Text(label)
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.activeNav === key ? this.textColor() : this.subTextColor())
        .margin({ top: 6 })
    }
    .width('100%')
    .height(68)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .linearGradient({
      angle: 135,
      colors: this.navItemGradientColors(key)
    })
    .border({ width: this.activeNav === key ? 2 : 1.5, color: this.activeNav === key ? this.accentGreen() : this.hairlineColor() })
    .borderRadius(16)
    .shadow({ radius: this.activeNav === key ? 12 : 0, color: this.activeNav === key ? this.accentGlowColor() : '#00000000', offsetY: 3 })
    .margin({ bottom: 10 })
    .onClick(() => {
      this.activeNav = key
    })
  }

  @Builder
  AppNavigation() {
    Column() {
      this.BrandLogo()
      Column() {
        this.NavItem('overview', '总览', $r('app.media.nav_overview'))
        this.NavItem('settings', '设置', $r('app.media.nav_settings'))
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .margin({ top: 24, bottom: 16 })

      Button('退出')
        .width('100%')
        .height(42)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .backgroundColor(this.warningRed())
        .borderRadius(21)
        .onClick(() => {
          this.exitApp()
        })
    }
    .width(132)
    .height('100%')
    .padding({ left: 16, right: 14, top: 22, bottom: 18 })
    .backgroundColor('#00000000')
  }

  @Builder
  PageHeader() {
    Column() {
      Row() {
        Column() {
          Text(this.navTitle())
            .fontSize(36)
            .fontWeight(FontWeight.Normal)
            .fontFamily('YouSheTitle')
            .fontColor(this.pageTitleColor())
            .textShadow({ radius: 3, color: this.pageTitleGlowColor(), offsetX: 1, offsetY: 2 })
            .letterSpacing(0)
          Text(this.navSubtitle())
            .fontSize(14)
            .fontColor(this.subTextColor())
            .margin({ top: 6 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Column() {
          Text(this.currentTime)
            .fontSize(30)
            .fontWeight(FontWeight.Normal)
            .fontFamily('YouSheTitle')
            .fontColor(this.pageTitleColor())
            .textShadow({ radius: 2, color: this.pageTitleGlowColor(), offsetX: 1, offsetY: 1 })
            .letterSpacing(0)
          Text(this.currentDate)
            .fontSize(12)
            .fontColor(this.subTextColor())
            .margin({ top: 4 })
        }
        .alignItems(HorizontalAlign.End)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row() {
        Row() {}
          .width(96)
          .height(2)
          .backgroundColor(this.accentGreen())
        Row() {}
          .layoutWeight(1)
          .height(1)
          .backgroundColor(this.hairlineColor())
      }
      .width('100%')
      .height(2)
      .alignItems(VerticalAlign.Center)
      .margin({ top: 14 })
    }
    .width('100%')
    .margin({ bottom: 18 })
  }

  @Builder
  MetricCard(params: MetricCardParams) {
    Column() {
      Row() {
        Stack({ alignContent: Alignment.Center }) {
          Image(params.icon)
            .width(20)
            .height(20)
            .objectFit(ImageFit.Contain)
        }
          .width(34)
          .height(34)
          .backgroundColor(params.accent)
          .borderRadius(13)
        Blank()
        Text(params.title)
          .fontSize(13)
          .fontColor(this.subTextColor())
          .maxLines(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(params.primary)
        .width('100%')
        .height(34)
        .fontSize(25)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.textColor())
        .margin({ top: 4 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Blank()
        .height(4)

      Row() {
        Text(params.secondary)
          .layoutWeight(1)
          .fontSize(11)
          .fontColor(this.subTextColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
        .width('100%')
        .height(32)
        .padding({ left: 10, right: 10 })
        .alignItems(VerticalAlign.Center)
        .backgroundColor(this.softPanelBg())
        .borderRadius(16)
    }
    .width('100%')
    .height(136)
    .padding(12)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(this.cardBg())
    .border({ width: 1.5, color: this.hairlineColor() })
    .borderRadius(22)
  }

  @Builder
  PlaceholderDeviceCard(title: string, state: string, detail: string, icon: Resource, color: string, active: boolean) {
    Column() {
      this.DeviceSectionTitle(title, detail, icon, active, color)
      Blank()
      Text(state)
        .fontSize(34)
        .fontWeight(FontWeight.Bold)
        .fontColor(active ? color : this.textColor())
        .maxLines(1)
      Text('联动策略预留')
        .fontSize(13)
        .fontColor(this.subTextColor())
        .margin({ top: 12 })
      Blank()
      Row() {
        Text('状态')
          .fontSize(13)
          .fontColor(this.subTextColor())
          .layoutWeight(1)
        Text('在线')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.accentGreen())
      }
      .width('100%')
      .height(46)
      .padding({ left: 16, right: 16 })
      .backgroundColor(this.softPanelBg())
      .borderRadius(23)
    }
    .width('100%')
    .height('100%')
    .padding(20)
    .borderRadius(16)
    .backgroundColor(this.cardBg())
    .border({ width: 1.5, color: this.hairlineColor() })
  }

  @Builder
  VoiceAssistantCard() {
    Column() {
      this.DeviceSectionTitle('语音助手', '小禹小禹', $r('app.media.device_mic'),
        this.voiceAssistantActive, this.accentBlue())

      Row({ space: 4 }) {
        ForEach(this.voiceWaveform, (level: number) => {
          Column()
            .width(6)
            .height(Math.max(3, level * 54))
            .borderRadius(3)
            .backgroundColor(this.voiceAssistantError ? this.warningRed() :
              (this.voiceAssistantActive ? this.accentBlue() : this.hairlineColor()))
        })
      }
      .width('100%')
      .height(42)
      .alignItems(VerticalAlign.Bottom)
      .justifyContent(FlexAlign.Center)
      .margin({ top: 6 })

      Row() {
        Text(this.voiceAssistantStatus)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.voiceAssistantError ? this.warningRed() :
            (this.voiceAssistantActive ? this.accentBlue() : this.textColor()))
          .maxLines(1)
        Blank()
        Text('本地离线')
          .fontSize(12)
          .fontColor(this.subTextColor())
          .maxLines(1)
      }
      .width('100%')
      .height(26)

      Text(this.voiceAssistantTranscript.length > 0 ? `“${this.voiceAssistantTranscript}”` :
        this.voiceAssistantDetail)
        .width('100%')
        .height(36)
        .fontSize(this.voiceAssistantTranscript.length > 0 ? 15 : 12)
        .fontWeight(this.voiceAssistantTranscript.length > 0 ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.voiceAssistantTranscript.length > 0 ? this.textColor() : this.subTextColor())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      if (this.voiceAssistantError) {
        Text('重新启动')
          .width('100%')
          .height(40)
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .textAlign(TextAlign.Center)
          .backgroundColor(this.warningRed())
          .borderRadius(20)
          .onClick(() => {
            this.restartVoiceAssistant()
          })
      } else {
        Row() {
          Text(this.voiceAssistantDetail)
            .layoutWeight(1)
            .fontSize(12)
            .fontColor(this.subTextColor())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.voiceAssistantActive ? '监听中' : '待机')
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.voiceAssistantActive ? this.accentGreen() : this.subTextColor())
            .maxLines(1)
        }
        .width('100%')
        .height(40)
        .padding({ left: 12, right: 12 })
        .backgroundColor(this.softPanelBg())
        .borderRadius(20)
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .borderRadius(16)
    .backgroundColor(this.cardBg())
    .border({ width: 1.5, color: this.hairlineColor() })
  }

  @Builder
  AddDeviceCard() {
    Column() {
      Stack({ alignContent: Alignment.Center }) {
        Image($r('app.media.device_add'))
          .width(28)
          .height(28)
          .objectFit(ImageFit.Contain)
      }
        .width(58)
        .height(58)
        .backgroundColor(this.accentGreen())
        .borderRadius(29)

      Text('添加新设备')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.textColor())
        .margin({ top: 22 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Text('通过 USB 串口添加新设备')
        .fontSize(13)
        .fontColor(this.subTextColor())
        .margin({ top: 10 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Blank()
        .height(24)

      Button('开始接入')
        .width('100%')
        .height(44)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .backgroundColor(this.accentBlue())
        .borderRadius(22)
        .onClick(() => {
          this.openProvisioningPanel()
        })
    }
    .width('100%')
    .height('100%')
    .padding(22)
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
    .borderRadius(16)
    .backgroundColor(this.cardBg())
    .border({ width: 1.5, color: this.hairlineColor() })
    .onClick(() => {
      this.openProvisioningPanel()
    })
  }

  @Builder
  SettingCardHeader(title: string, desc: string, icon: Resource, accent: string) {
    Row() {
      Stack({ alignContent: Alignment.Center }) {
        Image(icon)
          .width(23)
          .height(23)
          .objectFit(ImageFit.Contain)
      }
        .width(42)
        .height(42)
        .backgroundColor(accent)
        .borderRadius(16)
      Column() {
        Text(title)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.textColor())
          .maxLines(1)
        Text(desc)
          .fontSize(12)
          .fontColor(this.subTextColor())
          .margin({ top: 4 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 12 })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  OverviewMetricCell(label: string, value: string) {
    Column() {
      Text(label)
        .fontSize(16)
        .fontColor(this.subTextColor())
        .maxLines(1)
      if (value.endsWith('℃')) {
        Row() {
          Text(value.slice(0, -1))
            .fontSize(36)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.pageTitleColor())
            .letterSpacing(0)
          Text('°')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.pageTitleColor())
            .margin({ left: 2, bottom: 15 })
          Text('C')
            .fontSize(36)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.pageTitleColor())
            .letterSpacing(0)
        }
        .height(48)
        .alignItems(VerticalAlign.Center)
        .margin({ top: 7 })
      } else {
        Text(value)
          .fontSize(36)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.pageTitleColor())
          .letterSpacing(0)
          .margin({ top: 7 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(this.cardBg())
  }

  @Builder
  TemperatureUnitValue(value: number, fontSize: number, color: string) {
    Row() {
      Text(`${value}`)
        .fontSize(fontSize)
        .fontWeight(FontWeight.Normal)
        .fontFamily('YouSheTitle')
        .fontColor(color)
        .letterSpacing(0)
      Text('°')
        .fontSize(fontSize * 0.54)
        .fontColor(color)
        .margin({ left: 2, bottom: fontSize * 0.42 })
      Text('C')
        .fontSize(fontSize)
        .fontWeight(FontWeight.Normal)
        .fontFamily('YouSheTitle')
        .fontColor(color)
        .letterSpacing(0)
    }
    .height(fontSize + 8)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  OverviewDoorControl() {
    Column() {
      Image(this.doorLocked ? $r('app.media.overview_door_locked') : $r('app.media.overview_door_unlocked'))
        .width(82)
        .height(80)
        .objectFit(ImageFit.Contain)
      Text(this.doorPending ? '正在同步门锁' : this.doorLocked ? '单击解锁' : '单击上锁')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.textColor())
        .margin({ top: 5 })
        .maxLines(1)
      Text('双击管理人脸')
        .fontSize(11)
        .fontColor(this.subTextColor())
        .margin({ top: 3 })
        .maxLines(1)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(this.cardBg())
    .border({ width: 1.5, color: this.accentGreen() })
    .borderRadius(14)
    .onClick(() => {
      this.overviewDoorTap()
    })
  }

  @Builder
  OverviewLightControl() {
    Column() {
      Image(this.livingLightOn ? $r('app.media.overview_light_on') : $r('app.media.overview_light_off'))
        .width(88)
        .height(80)
        .objectFit(ImageFit.Contain)
      Text(this.livingLightPending ? '正在同步照明' : this.livingLightOn ? '灯已开启' : '灯已关闭')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.textColor())
        .margin({ top: 5 })
        .maxLines(1)
      Text('点击图标控制照明')
        .fontSize(11)
        .fontColor(this.subTextColor())
        .margin({ top: 3 })
        .maxLines(1)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(this.cardBg())
    .border({ width: 1.5, color: this.accentGreen() })
    .borderRadius(14)
    .onClick(() => {
      if (!this.livingLightPending) {
        this.requestLivingLightToggle()
      }
    })
  }

  @Builder
  OverviewAcControl() {
    Column() {
      Image($r('app.media.overview_ac'))
        .width(112)
        .height(78)
        .objectFit(ImageFit.Contain)
      Text('点击控制空调')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.textColor())
        .margin({ top: 5 })
        .maxLines(1)
      if (this.acPower) {
        Row() {
          Text(`${this.acTemp}`)
            .fontSize(11)
            .fontColor(this.accentBlue())
          Text('°')
            .fontSize(7)
            .fontColor(this.accentBlue())
            .margin({ left: 1, bottom: 5 })
          Text('C')
            .fontSize(11)
            .fontColor(this.accentBlue())
          Text(` · ${this.acModeText()}`)
            .fontSize(11)
            .fontColor(this.accentBlue())
            .maxLines(1)
        }
        .height(19)
        .alignItems(VerticalAlign.Center)
        .margin({ top: 3 })
      } else {
        Text('空调已关闭')
          .fontSize(11)
          .fontColor(this.subTextColor())
          .margin({ top: 3 })
          .maxLines(1)
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(this.cardBg())
    .border({ width: 1.5, color: this.accentGreen() })
    .borderRadius(14)
    .onClick(() => {
      this.showAcControlPanel = true
    })
  }

  @Builder
  OverviewCurtainControl() {
    Column() {
      Stack({ alignContent: Alignment.Center }) {
        if (this.curtainPercent <= 12) {
          Image($r('app.media.overview_curtain_0')).width(106).height(78).objectFit(ImageFit.Contain)
        } else if (this.curtainPercent <= 37) {
          Image($r('app.media.overview_curtain_25')).width(106).height(78).objectFit(ImageFit.Contain)
        } else if (this.curtainPercent <= 62) {
          Image($r('app.media.overview_curtain_50')).width(106).height(78).objectFit(ImageFit.Contain)
        } else if (this.curtainPercent <= 87) {
          Image($r('app.media.overview_curtain_75')).width(106).height(78).objectFit(ImageFit.Contain)
        } else {
          Image($r('app.media.overview_curtain_100')).width(106).height(78).objectFit(ImageFit.Contain)
        }
      }
      .width(116)
      .height(80)
      .gesture(
        PanGesture({ direction: PanDirection.Horizontal, distance: 4 })
          .onActionStart(() => {
            this.beginCurtainOverviewDrag()
          })
          .onActionUpdate((event: GestureEvent) => {
            this.updateCurtainOverviewDrag(event.offsetX)
          })
          .onActionEnd(() => {
            this.finishCurtainOverviewDrag()
          })
          .onActionCancel(() => {
            this.finishCurtainOverviewDrag()
          })
      )
      Text('滑动图标控制窗帘开合')
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.textColor())
        .margin({ top: 5 })
        .maxLines(1)
      Text(`窗帘开合度 ${this.curtainPercent}%`)
        .fontSize(11)
        .fontColor(this.accentBlue())
        .margin({ top: 3 })
        .maxLines(1)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(this.cardBg())
    .border({ width: 1.5, color: this.accentGreen() })
    .borderRadius(14)
  }

  @Builder
  OverviewVoiceControl() {
    Column() {
      Image(this.overviewVoiceLevel() >= 0.16 ?
        $r('app.media.overview_microphone_active') : $r('app.media.overview_microphone_quiet'))
        .width(112)
        .height(80)
        .objectFit(ImageFit.Contain)
      Text('小禹小禹')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.textColor())
        .margin({ top: 5 })
        .maxLines(1)
      Text(this.voiceAssistantStatus)
        .fontSize(11)
        .fontColor(this.voiceAssistantActive ? this.accentGreen() : this.subTextColor())
        .margin({ top: 3 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(this.cardBg())
    .border({ width: 1.5, color: this.accentGreen() })
    .borderRadius(14)
  }

  @Builder
  OverviewAddDeviceControl() {
    Column() {
      Image($r('app.media.overview_add_device'))
        .width(92)
        .height(80)
        .objectFit(ImageFit.Contain)
      Text('点击图标添加设备')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.textColor())
        .margin({ top: 5 })
        .maxLines(1)
      Text('通过 USB 数据线接入')
        .fontSize(11)
        .fontColor(this.subTextColor())
        .margin({ top: 3 })
        .maxLines(1)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(this.cardBg())
    .border({ width: 1.5, color: this.accentGreen() })
    .borderRadius(14)
    .onClick(() => {
      this.openProvisioningPanel()
    })
  }

  overviewAlarmLineText(): string {
    if (this.hasActiveDeviceAlarm()) {
      return `一级预警：${this.alertMessage}`
    }
    return '预警已解除，设备确认完成'
  }

  @Builder
  OverviewAlarmLine() {
    Row() {
      Text(this.overviewAlarmLineText())
        .layoutWeight(1)
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.alarmClearConfirmed ? '#168A6B' : '#B9363E')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.hasActiveDeviceAlarm()) {
        Button(this.alarmClearPending ? '取消中' : '取消报警')
          .width(86)
          .height(30)
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.alarmClearPending ? '#8F6B6E' : '#FFFFFF')
          .backgroundColor(this.alarmClearPending ? '#E7CDD0' : '#B9363E')
          .borderRadius(6)
          .margin({ left: 14 })
          .enabled(!this.alarmClearPending)
          .onClick(() => {
            this.requestAlarmClear().catch((err: Error) => {
              console.info(`[ALARM][overview-off-fail] ${err.message}`)
            })
          })
      }
    }
    .width('100%')
    .height(28)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  OverviewPage() {
    Row() {
      Column() {
        Column() {
          Text(this.currentTime)
            .fontSize(84)
            .fontWeight(FontWeight.Normal)
            .fontFamily('YouSheTitle')
            .fontColor(this.pageTitleColor())
            .textShadow({ radius: 4, color: this.pageTitleGlowColor(), offsetX: 1, offsetY: 2 })
            .letterSpacing(0)
          Text(this.currentDate)
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.pageTitleColor())
            .margin({ top: 18 })
            .maxLines(1)
          Text(this.overviewWeatherText())
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.subTextColor())
            .margin({ top: 12 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.hasActiveDeviceAlarm() || this.alarmClearConfirmed) {
            this.OverviewAlarmLine()
          }
        }
        .width('100%')
        .height(292)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 28, right: 20 })

        Grid() {
          GridItem() { this.OverviewMetricCell('室内温度', this.sensorDisplay[0]) }
          GridItem() { this.OverviewMetricCell('室内湿度', this.sensorDisplay[1]) }
          GridItem() { this.OverviewMetricCell('室外温度', this.outdoorTempText) }
          GridItem() { this.OverviewMetricCell('室外湿度', this.outdoorHumidityText) }
        }
        .columnsTemplate('1fr 1fr')
        .rowsTemplate('1fr 1fr')
        .columnsGap(1)
        .rowsGap(1)
        .width('100%')
        .layoutWeight(1)
        .padding(1)
        .backgroundColor(this.hairlineColor())
        .border({ width: 1.5, color: this.hairlineColor() })
        .borderRadius(18)
        .clip(true)
      }
      .layoutWeight(1)
      .height('100%')
      .margin({ right: 9 })

      Grid() {
        GridItem() { this.OverviewDoorControl() }
        GridItem() { this.OverviewLightControl() }
        GridItem() { this.OverviewAcControl() }
        GridItem() { this.OverviewCurtainControl() }
        GridItem() { this.OverviewVoiceControl() }
        GridItem() { this.OverviewAddDeviceControl() }
      }
      .columnsTemplate('1fr 1fr')
      .rowsTemplate('1fr 1fr 1fr')
      .columnsGap(12)
      .rowsGap(12)
      .layoutWeight(1)
      .height('100%')
      .padding(14)
      .backgroundColor(this.hasActiveDeviceAlarm() ?
        (this.isDarkMode ? '#32171C' : '#F8E7E8') :
        (this.isDarkMode ? '#101B22' : '#EAF7F2'))
      .border({ width: 2, color: this.hairlineColor() })
      .borderRadius(20)
      .margin({ left: 9 })
    }
      .width('100%')
    .height('100%')
    .padding(22)
  }

  @Builder
  ProtocolSettingCard() {
    Column() {
      this.SettingCardHeader('控制通道', this.protocolPendingMode.length > 0 ? '正在等待 ACK' : 'MQTT / HTTP 切换', $r('app.media.setting_protocol'), this.accentBlue())
      Blank()
        .height(26)
      Row() {
        Text('MQTT')
          .layoutWeight(1)
          .height(40)
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.commandTransport === 'MQTT' ? '#FFFFFF' : this.textColor())
          .textAlign(TextAlign.Center)
          .backgroundColor(this.commandTransport === 'MQTT' ? this.accentBlue() : this.softPanelBg())
          .border({ width: 1, color: this.hairlineColor() })
          .borderRadius(20)
          .onClick(() => {
            this.selectCommandTransport('MQTT')
          })
        Text('HTTP')
          .layoutWeight(1)
          .height(40)
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.commandTransport === 'HTTP' ? '#FFFFFF' : this.textColor())
          .textAlign(TextAlign.Center)
          .backgroundColor(this.commandTransport === 'HTTP' ? this.accentBlue() : this.softPanelBg())
          .border({ width: 1, color: this.hairlineColor() })
          .borderRadius(20)
          .margin({ left: 10 })
          .onClick(() => {
            this.selectCommandTransport('HTTP')
          })
      }
      .width('100%')
      Blank()
      Text(`当前 ${this.commandTransportText()}`)
        .fontSize(12)
        .fontColor(this.subTextColor())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height('100%')
    .padding(20)
    .backgroundColor(this.cardBg())
    .border({ width: 1.5, color: this.hairlineColor() })
    .borderRadius(26)
  }

  @Builder
  CryptoSettingCard() {
    Column() {
      this.SettingCardHeader('加密算法', this.cryptoPendingMode.length > 0 ? '正在切换' : `${this.cryptoMode}-GCM`, $r('app.media.setting_crypto'), this.accentGreen())
      Blank()
        .height(26)
      Row() {
        Text('AES')
          .layoutWeight(1)
          .height(40)
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor((this.cryptoMode === 'AES' || this.cryptoPendingMode === 'AES') ? '#FFFFFF' : this.textColor())
          .textAlign(TextAlign.Center)
          .backgroundColor((this.cryptoMode === 'AES' || this.cryptoPendingMode === 'AES') ? this.accentGreen() : this.softPanelBg())
          .border({ width: 1, color: this.hairlineColor() })
          .borderRadius(20)
          .onClick(() => {
            this.selectCryptoMode('AES')
          })
        Text('SM4')
          .layoutWeight(1)
          .height(40)
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor((this.cryptoMode === 'SM4' || this.cryptoPendingMode === 'SM4') ? '#FFFFFF' : this.textColor())
          .textAlign(TextAlign.Center)
          .backgroundColor((this.cryptoMode === 'SM4' || this.cryptoPendingMode === 'SM4') ? this.accentGreen() : this.softPanelBg())
          .border({ width: 1, color: this.hairlineColor() })
          .borderRadius(20)
          .margin({ left: 10 })
          .onClick(() => {
            this.selectCryptoMode('SM4')
          })
      }
      .width('100%')
      Blank()
      Text(this.cryptoDebugText)
        .fontSize(12)
        .fontColor(this.subTextColor())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height('100%')
    .padding(20)
    .backgroundColor(this.cardBg())
    .border({ width: 1.5, color: this.hairlineColor() })
    .borderRadius(26)
  }

  @Builder
  BridgeSettingCard() {
    Column() {
      Row() {
        Stack({ alignContent: Alignment.Center }) {
          Image($r('app.media.setting_bridge'))
            .width(23)
            .height(23)
            .objectFit(ImageFit.Contain)
        }
        .width(42)
        .height(42)
        .backgroundColor(this.isBridgeActuallyConnected() ? this.accentGreen() : this.warningRed())
        .borderRadius(16)
        Column() {
          Text('设备状态')
            .width('100%')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.textColor())
            .maxLines(1)
          Text(`${this.registeredDeviceCount()} 台已发现 · ${this.isBridgeActuallyConnected() ? '在线' : '离线'}`)
            .width('100%')
            .fontSize(11)
            .fontColor(this.subTextColor())
            .margin({ top: 3 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: 10 })
        Button() {
          Image($r('app.media.setting_refresh'))
            .width(19)
            .height(19)
            .objectFit(ImageFit.Contain)
        }
        .width(40)
        .height(40)
        .padding(0)
        .backgroundColor(this.accentBlue())
        .borderRadius(20)
        .margin({ left: 10 })
        .onClick(() => {
          this.reconnectBridge()
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      Blank()
        .height(12)
      Text('选择协议与加密的控制目标')
        .fontSize(12)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.subTextColor())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Button() {
        Row() {
          Column() {
            Text(this.activeDeviceName())
              .width('100%')
              .fontSize(13)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.textColor())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.deviceIdDisplayText(this.activeDeviceId))
              .width('100%')
              .fontSize(10)
              .fontColor(this.accentBlue())
              .margin({ top: 2 })
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          if (this.registeredDeviceCount() > 1) {
            Stack({ alignContent: Alignment.Center }) {
              Image($r('app.media.setting_protocol'))
                .width(16)
                .height(16)
                .objectFit(ImageFit.Contain)
            }
            .width(30)
            .height(30)
            .backgroundColor(this.accentBlue())
            .borderRadius(15)
            .margin({ left: 10 })
          }
        }
        .width('100%')
        .padding({ left: 16, right: 10 })
        .alignItems(VerticalAlign.Center)
      }
        .width('100%')
        .height(52)
        .backgroundColor(this.softPanelBg())
        .border({ width: 1.5, color: this.accentBlue() })
        .borderRadius(14)
        .margin({ top: 8 })
        .onClick(() => {
          this.selectNextActiveDevice()
        })
      Text('协议和加密设置将应用于当前选中的设备')
        .width('100%')
        .height(28)
        .fontSize(11)
        .fontColor(this.subTextColor())
        .margin({ top: 7 })
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height('100%')
    .padding(20)
    .backgroundColor(this.cardBg())
    .border({ width: 1.5, color: this.hairlineColor() })
    .borderRadius(26)
  }

  @Builder
  DebugSettingCard() {
    Column() {
      this.SettingCardHeader('调试信息', `${this.mqttMessages.length} 条 · 三连打开`, $r('app.media.setting_debug'), this.accentOrange())
      Blank()
        .height(28)
      Text(this.cryptoLastDecrypted)
        .fontSize(13)
        .fontColor(this.subTextColor())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Button('查看调试信息')
        .width('100%')
        .height(40)
        .fontSize(14)
        .fontColor('#FFFFFF')
        .backgroundColor(this.accentOrange())
        .borderRadius(20)
        .margin({ top: 24 })
        .onClick(() => {
          this.requestOpenDebugPanel()
        })
    }
    .width('100%')
    .height('100%')
    .padding(20)
    .backgroundColor(this.cardBg())
    .border({ width: 1.5, color: this.hairlineColor() })
    .borderRadius(26)
  }

  @Builder
  ProvisioningSettingCard() {
    Column() {
      this.SettingCardHeader('设备接入', this.provisioningConnected ? '串口已连接' : '使用串口接入新设备', $r('app.media.setting_provision'), this.accentBlue())
      Blank()
        .height(12)
      Button('开始接入')
        .width('100%')
        .height(40)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .backgroundColor(this.accentBlue())
        .borderRadius(20)
        .margin({ top: 12 })
        .onClick(() => {
          this.openProvisioningPanel()
        })
      Button('查看串口日志')
        .width('100%')
        .height(36)
        .fontSize(13)
        .fontColor(this.textColor())
        .backgroundColor(this.softPanelBg())
        .border({ width: 1, color: this.hairlineColor() })
        .borderRadius(18)
        .margin({ top: 10 })
        .onClick(() => {
          this.showProvisioningOutputPanel = true
        })
    }
    .width('100%')
    .height('100%')
    .padding(20)
    .backgroundColor(this.cardBg())
    .border({ width: 1.5, color: this.hairlineColor() })
    .borderRadius(26)
  }

  @Builder
  IrLearningSettingCard() {
    Column() {
      this.SettingCardHeader('空调万能适配', this.irLearnCompletedCount === IR_LEARN_KEY_LABELS.length ?
        '已保存遥控器' : '快来试试吧', $r('app.media.setting_ir'), this.accentOrange())
      Blank()
        .height(28)
      Text('只需一个遥控器，就可以学习控制你的任何品牌空调')
        .fontSize(13)
        .fontColor(this.subTextColor())
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Button(this.irLearnCompletedCount === IR_LEARN_KEY_LABELS.length ? '重新适配' : '开始适配')
        .width('100%')
        .height(40)
        .fontSize(14)
        .fontColor('#FFFFFF')
        .backgroundColor(this.accentOrange())
        .borderRadius(20)
        .margin({ top: 24 })
        .onClick(() => {
          this.openIrLearnPanel()
        })
    }
    .width('100%')
    .height('100%')
    .padding(20)
    .backgroundColor(this.cardBg())
    .border({ width: 1.5, color: this.hairlineColor() })
    .borderRadius(26)
  }

  @Builder
  DeviceBindingSettingCard() {
    Column() {
      this.SettingCardHeader('设备绑定', `${this.registeredDeviceCount()} 台已发现`, $r('app.media.setting_bridge'), this.accentGreen())

      Image($r('app.media.device_binding_illustration_card'))
        .width('100%')
        .height(78)
        .objectFit(ImageFit.Contain)
        .margin({ top: 4 })

      Blank()

      Button('管理设备绑定')
        .width('100%')
        .height(42)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .backgroundColor(this.accentGreen())
        .borderRadius(21)
        .onClick(() => {
          this.showDeviceBindingPanel = true
        })
    }
    .width('100%')
    .height('100%')
    .padding(20)
    .backgroundColor(this.cardBg())
    .border({ width: 1.5, color: this.hairlineColor() })
    .borderRadius(26)
  }

  @Builder
  VoiceprintSettingCard() {
    Column() {
      this.SettingCardHeader('声纹保护', this.voiceprintUsers.length > 0 ?
        `${this.voiceprintUsers.length} 位授权用户` : '仅在本地保存特征',
      $r('app.media.device_mic'), this.accentBlue())
      Blank()
        .height(12)
      Column() {
        Row() {
          Text('执行前验证身份')
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.textColor())
            .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.voiceprintProtectionEnabled })
            .width(44)
            .height(24)
            .selectedColor(this.accentGreen())
            .onChange((isOn: boolean) => {
              this.setVoiceprintProtection(isOn)
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .height(48)
      .padding({ left: 14, right: 10, top: 4, bottom: 4 })
      .alignItems(HorizontalAlign.Start)
      .backgroundColor(this.softPanelBg())
      .borderRadius(12)
      Text(this.voiceprintProtectionEnabled ? '未通过时不会执行指令' : '当前不拦截语音指令')
        .width('100%')
        .fontSize(11)
        .fontColor(this.subTextColor())
        .margin({ top: 8 })
        .maxLines(1)
      Button('管理声纹')
        .width('100%')
        .height(34)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .backgroundColor(this.voiceprintModelReady ? this.accentBlue() : '#777D83')
        .borderRadius(17)
        .margin({ top: 8 })
        .onClick(() => {
          this.openVoiceprintManager()
        })
    }
    .width('100%')
    .height('100%')
    .padding(20)
    .backgroundColor(this.cardBg())
    .border({ width: 1.5, color: this.hairlineColor() })
    .borderRadius(26)
  }

  @Builder
  SettingsFeatureImage(icon: Resource, dimmed: boolean) {
    Image(icon)
      .width(124)
      .height(104)
      .objectFit(ImageFit.Contain)
      .opacity(dimmed ? 0.55 : 1)
  }

  @Builder
  SettingsFeatureIcon(icon: Resource, action: string) {
    if (action === 'protocol') {
      if (this.transportForDevice(this.activeDeviceId) === 'HTTP') {
        this.SettingsFeatureImage($r('app.media.settings_http_comic'), this.protocolPendingMode.length > 0)
      } else {
        this.SettingsFeatureImage($r('app.media.settings_mqtt_comic'), this.protocolPendingMode.length > 0)
      }
    } else if (action === 'crypto') {
      if (this.cryptoModeForDevice(this.activeDeviceId) === 'AES') {
        this.SettingsFeatureImage($r('app.media.settings_aes_comic'), this.cryptoPendingMode.length > 0)
      } else {
        this.SettingsFeatureImage($r('app.media.settings_sm4_comic'), this.cryptoPendingMode.length > 0)
      }
    } else {
      this.SettingsFeatureImage(icon, false)
    }
  }

  @Builder
  SettingsFeatureCard(title: string, subtitle: string, icon: Resource, action: string, accent: string) {
    Column() {
      this.SettingsFeatureIcon(icon, action)
      Text(title)
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.textColor())
        .margin({ top: 3 })
        .maxLines(1)
      Text(subtitle)
        .width('92%')
        .height(38)
        .fontSize(12)
        .fontColor(this.subTextColor())
        .textAlign(TextAlign.Center)
        .margin({ top: 3 })
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(this.cardBg())
    .border({ width: 1.5, color: this.accentGreen() })
    .borderRadius(14)
    .onClick(() => {
      this.handleSettingsFeature(action)
    })
  }

  @Builder
  SettingsPage() {
    Column() {
      this.PageHeader()
      Grid() {
        GridItem() {
          this.SettingsFeatureCard('设备状态', '点击图标查看设备状态',
            $r('app.media.settings_device_status_comic'), 'status', this.accentGreen())
        }
        GridItem() {
          this.SettingsFeatureCard('设备接入', '点击图标开始接入设备',
            $r('app.media.settings_device_access_comic'), 'provisioning', this.accentBlue())
        }
        GridItem() {
          this.SettingsFeatureCard('空调万能适配', '点击图标试试我们的空调万能适配吧',
            $r('app.media.settings_ir_adapter_comic'), 'ir', this.accentOrange())
        }
        GridItem() {
          this.SettingsFeatureCard('声纹保护', '点击图标管理声纹',
            $r('app.media.settings_voiceprint_comic'), 'voiceprint', this.accentBlue())
        }
        GridItem() {
          this.SettingsFeatureCard('设备绑定', '点击图标管理设备绑定',
            $r('app.media.settings_device_binding_comic'), 'binding', this.accentGreen())
        }
        GridItem() {
          this.SettingsFeatureCard('控制通道', '点击图标切换控制协议',
            this.settingsProtocolIcon(), 'protocol', this.accentBlue())
        }
        GridItem() {
          this.SettingsFeatureCard('加密算法', '点击图标切换加密方式',
            this.settingsCryptoIcon(), 'crypto', this.accentGreen())
        }
        GridItem() {
          this.SettingsFeatureCard('调试信息', '点击图标三次查看调试信息',
            $r('app.media.settings_debug_comic'), 'debug', this.accentOrange())
        }
      }
      .columnsTemplate('1fr 1fr 1fr 1fr')
      .rowsTemplate('1fr 1fr')
      .columnsGap(12)
      .rowsGap(12)
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .padding(22)
  }

  @Builder
  ActivePage() {
    if (this.activeNav === 'settings') {
      this.SettingsPage()
    } else {
      this.OverviewPage()
    }
  }

  @Builder
  MainShell() {
    Row() {
      this.AppNavigation()
      Column() {}
        .width(1)
        .height('100%')
        .backgroundColor(this.hairlineColor())
      Column() {
        this.ActivePage()
      }
      .height('100%')
      .layoutWeight(1)
      .backgroundColor('#00000000')
    }
    .width('100%')
    .height('100%')
    .padding({ left: 0, right: 0, top: 0, bottom: 0 })
    .linearGradient({
      angle: 155,
      colors: this.backgroundGradientColors()
    })
  }

  @Builder
  LeftPanel() {
    Column() {
      Text('鸿蒙智能家居')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.isDarkMode ? '#F4F7FA' : '#20242A')
        .margin({ bottom: 10 })

      Button('设备接入')
        .width('100%')
        .height(40)
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .backgroundColor(this.accentBlue())
        .borderRadius(20)
        .margin({ bottom: 10 })
        .onClick(() => {
          this.openProvisioningPanel()
        })

      Button('退出软件')
        .width('100%')
        .height(40)
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .backgroundColor(this.warningRed())
        .borderRadius(20)
        .margin({ bottom: 10 })
        .onClick(() => {
          this.exitApp()
        })

      Scroll() {
        Column() {
          Column() {
            Text(this.currentTime)
          .fontSize(48)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.isDarkMode ? '#F4F7FA' : '#171A1F')
          .letterSpacing(0)

        Text(this.currentDate)
          .fontSize(16)
          .fontColor(this.subTextColor())
          .margin({ top: 4 })

        Column() {
          Row() {
            Text('室内温度')
              .fontSize(13)
              .fontColor(this.subTextColor())
              .layoutWeight(1)
            Text(this.sensorDisplay[0])
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.accentOrange())
          }
          .height(42)
          .padding({ left: 14, right: 14 })
          .borderRadius(21)
          .backgroundColor(this.softPanelBg())
          .border({ width: 1, color: this.hairlineColor() })
          Blank()
            .height(8)
          Row() {
            Text('室内湿度')
              .fontSize(13)
              .fontColor(this.subTextColor())
              .layoutWeight(1)
            Text(this.sensorDisplay[1])
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.accentBlue())
          }
          .height(42)
          .padding({ left: 14, right: 14 })
          .borderRadius(21)
          .backgroundColor(this.softPanelBg())
          .border({ width: 1, color: this.hairlineColor() })
          Text(this.sensorDisplay[2])
            .fontSize(11)
            .fontColor(this.subTextColor())
            .maxLines(1)
            .margin({ top: 6, left: 8 })
        }
        .width('100%')
        .margin({ top: 14 })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Column() {
        Row() {
          Text(this.isBridgeActuallyConnected() ? 'Bridge 已连接' : 'Bridge 未连接')
            .fontSize(14)
            .fontColor(this.isBridgeActuallyConnected() ? this.accentGreen() : this.warningRed())
            .layoutWeight(1)
          Button('刷新')
            .width(70)
            .height(34)
            .fontSize(13)
            .fontColor('#FFFFFF')
            .backgroundColor(this.accentBlue())
            .borderRadius(17)
            .onClick(() => {
              this.reconnectBridge()
            })
        }
        .width('100%')
        .height(42)
        .padding({ left: 16, right: 8 })
        .backgroundColor(this.softPanelBg())
        .borderRadius(21)

        Text(this.bridgeLastMessage)
          .width('100%')
          .fontSize(12)
          .fontColor(this.subTextColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 6, left: 8 })

        if (this.bridgeLastError.length > 0 && !this.isBridgeActuallyConnected()) {
          Text(this.bridgeLastError)
            .width('100%')
            .fontSize(10)
            .fontColor(this.warningRed())
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 4, left: 8, right: 8 })
        }

        Row() {
          Text(`控制通道: ${this.commandTransportText()}`)
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.textColor())
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text('MQTT')
            .width(62)
            .height(30)
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.commandTransport === 'MQTT' ? '#FFFFFF' : this.textColor())
            .textAlign(TextAlign.Center)
            .backgroundColor(this.commandTransport === 'MQTT' ? this.accentBlue() : this.softPanelBg())
            .border({ width: 1, color: this.hairlineColor() })
            .borderRadius(15)
            .onClick(() => {
              this.selectCommandTransport('MQTT')
            })
          Text('HTTP')
            .width(62)
            .height(30)
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.commandTransport === 'HTTP' ? '#FFFFFF' : this.textColor())
            .textAlign(TextAlign.Center)
            .backgroundColor(this.commandTransport === 'HTTP' ? this.accentBlue() : this.softPanelBg())
            .border({ width: 1, color: this.hairlineColor() })
            .borderRadius(15)
            .margin({ left: 8 })
            .onClick(() => {
              this.selectCommandTransport('HTTP')
            })
        }
        .width('100%')
        .height(36)
        .padding({ left: 12, right: 8 })
        .margin({ top: 8 })
        .backgroundColor(this.softPanelBg())
        .border({ width: 1, color: this.hairlineColor() })
        .borderRadius(18)

        Row() {
          Text('AES')
            .layoutWeight(1)
            .height(32)
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor((this.cryptoMode === 'AES' || this.cryptoPendingMode === 'AES') ? '#FFFFFF' : this.textColor())
            .textAlign(TextAlign.Center)
            .backgroundColor((this.cryptoMode === 'AES' || this.cryptoPendingMode === 'AES') ? this.accentBlue() : this.softPanelBg())
            .border({ width: 1, color: this.hairlineColor() })
            .borderRadius(16)
            .onClick(() => {
              this.selectCryptoMode('AES')
            })
          Blank()
            .width(8)
          Text('SM4')
            .layoutWeight(1)
            .height(32)
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor((this.cryptoMode === 'SM4' || this.cryptoPendingMode === 'SM4') ? '#FFFFFF' : this.textColor())
            .textAlign(TextAlign.Center)
            .backgroundColor((this.cryptoMode === 'SM4' || this.cryptoPendingMode === 'SM4') ? this.accentBlue() : this.softPanelBg())
            .border({ width: 1, color: this.hairlineColor() })
            .borderRadius(16)
            .onClick(() => {
              this.selectCryptoMode('SM4')
            })
        }
        .width('100%')
        .height(36)
        .padding({ left: 8, right: 8 })
        .margin({ top: 6 })

        Row() {
          Column() {
            Text('调试信息')
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.textColor())
            Text(this.cryptoDebugText)
              .fontSize(11)
              .fontColor(this.subTextColor())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 3 })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Button(`${this.mqttMessages.length} 条`)
            .width(76)
            .height(32)
            .fontSize(12)
            .fontColor('#FFFFFF')
            .backgroundColor(this.accentBlue())
            .borderRadius(16)
            .onClick(() => {
              this.requestOpenDebugPanel()
            })
        }
        .width('100%')
        .height(54)
        .padding({ left: 16, right: 10 })
        .margin({ top: 10 })
        .backgroundColor(this.softPanelBg())
        .border({ width: 1, color: this.hairlineColor() })
        .borderRadius(16)

        Row() {
          Text(this.beaconAutoDiscovered ? '自动发现已连接' : '等待自动发现')
            .fontSize(12)
            .fontColor(this.beaconAutoDiscovered ? this.accentGreen() : this.subTextColor())
            .layoutWeight(1)
          Text(this.mqttLastMsgTime)
            .fontSize(12)
            .fontColor(this.subTextColor())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .height(26)
        .padding({ left: 8, right: 8 })
        .margin({ top: 6 })

        Row() {
          Text('深色模式')
            .fontSize(14)
            .fontColor(this.textColor())
            .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.isDarkMode })
            .selectedColor(this.accentBlue())
            .onChange((isOn: boolean) => {
              this.isDarkMode = isOn
              console.info(`[MOCK][themeToggle] isDarkMode=${isOn}`)
            })
        }
        .width('100%')
        .height(42)
        .padding({ left: 16, right: 12 })
        .backgroundColor(this.softPanelBg())
        .borderRadius(21)
        .margin({ top: 10 })

        Button('一键离家')
          .width('100%')
          .height(42)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .backgroundColor('#2E3033')
          .borderRadius(21)
          .margin({ top: 8 })
          .onClick(() => {
            this.leaveHome()
          })
        }
        .width('100%')
        .margin({ top: 16 })
      }
      .width('100%')
      .padding({ right: 10 })
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Auto)
    }
    .width('25%')
    .height('100%')
    .padding({ left: 24, right: 24, top: 18, bottom: 18 })
    .backgroundColor(this.sideBg())
  }

  @Builder
  SafetyCard() {
    Column() {
      this.SectionTitle('安全预警中心', '烟雾 / 水浸 / 跌倒 / 自检漂移', '盾')

      Row() {
        Column() {
          Text(this.alertTitle())
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.hasActiveDeviceAlarm() ? this.alarmTextColor() : this.alertLevel === 3 ? '#FFFFFF' : this.textColor())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Text(this.alertMessage)
            .fontSize(14)
            .fontColor(this.hasActiveDeviceAlarm() ? this.alarmSubTextColor() : this.alertLevel === 3 ? '#F9E2DF' : this.subTextColor())
            .margin({ top: 6 })
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Column() {
          Text(this.alertIcon())
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .textAlign(TextAlign.Center)
          .width(60)
          .height(60)
            .backgroundColor(this.hasActiveDeviceAlarm() ? this.accentGreen() : this.alertColor())
            .borderRadius(30)
          Text(`LEVEL ${this.alertLevel}`)
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.hasActiveDeviceAlarm() ? this.alarmTextColor() : this.alertLevel === 3 ? '#F9E2DF' : this.alertColor())
            .margin({ top: 4 })
        }
        .alignItems(HorizontalAlign.Center)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: 8 })

      Blank()
        .height(4)

      Row() {
        this.AlarmStatusPill('烟雾', 'smoke', this.smokeAlarm)
        Blank()
          .width(8)
        this.AlarmStatusPill('水浸', 'water', this.waterAlarm)
        Button('模拟演练')
          .width(106)
          .height(42)
          .fontSize(13)
          .fontColor('#FFFFFF')
          .backgroundColor(this.hasActiveDeviceAlarm() ? '#BE5963' : this.alertLevel === 3 ? '#7D2F2D' : '#2E3033')
          .borderRadius(19)
          .margin({ left: 8 })
          .onClick(() => {
            this.simulateAlert()
          })
      }
      .width('100%')
      .height(48)

      Text(this.hasActiveDeviceAlarm() ? this.alarmAckText : '烟雾与水浸状态实时监测')
        .width('100%')
        .fontSize(12)
        .fontColor(this.hasActiveDeviceAlarm() ? this.alarmSubTextColor() : this.alertLevel === 3 ? '#FFE3DF' : this.subTextColor())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 4 })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 14, bottom: 14 })
    .borderRadius(26)
    .backgroundColor(this.hasActiveDeviceAlarm() ? this.alarmCardBg() : this.alertLevel === 3 ? this.warningRed() : this.cardBg())
    .border({ width: 1.5, color: this.hairlineColor() })
  }

  @Builder
  DoorCard() {
    Column() {
      this.SectionTitle('智能门禁', '人脸识别与本地摄像头', '门')

      Column() {
        Text(this.doorLocked ? '已上锁' : '已解锁')
          .width('100%')
          .height(34)
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.doorLocked ? this.accentGreen() : this.warningRed())
          .textAlign(TextAlign.Center)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .height(60)
      .justifyContent(FlexAlign.Center)
      .padding({ left: 14, right: 14, top: 8, bottom: 8 })
      .borderRadius(18)
      .backgroundColor(this.isDarkMode ? '#17191B' : '#F4F8FB')
      .border({ width: 1, color: this.hairlineColor() })
      .margin({ top: 10, bottom: 10 })
      .clip(true)

      Column() {
        Button('人脸管理')
          .width('100%')
          .height(38)
          .fontSize(13)
          .fontColor('#FFFFFF')
          .backgroundColor(this.accentBlue())
          .borderRadius(19)
          .onClick(() => {
            this.registerFaceData()
          })
        Button(this.doorPending ? '同步中' : this.doorLocked ? '解锁' : '上锁')
          .width('100%')
          .height(38)
          .fontSize(13)
          .fontColor('#FFFFFF')
          .backgroundColor(this.doorPending ? '#666B72' : this.doorLocked ? '#2E3033' : this.warningRed())
          .borderRadius(19)
          .margin({ top: 8 })
          .onClick(() => {
            if (this.doorPending) {
              return
            }
            this.sendDoorControl(this.doorLocked)
              .catch((err: Error) => {
                console.info(`[DOOR][manual-fail] ${err.message}`)
              })
          })
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 14, bottom: 14 })
    .borderRadius(26)
    .backgroundColor(this.cardBg())
    .border({ width: 1.5, color: this.hairlineColor() })
  }

  @Builder
  AirCard() {
    Column() {
      Row() {
        Stack({ alignContent: Alignment.Center }) {
          Image($r('app.media.device_ac'))
            .width(20)
            .height(20)
            .objectFit(ImageFit.Contain)
        }
        .width(28)
        .height(28)
        .backgroundColor(this.accentBlue())
        .borderRadius(8)

        Column() {
          Text('空调控制')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.textColor())
            .maxLines(1)
          Text(this.acPending ? '同步中' : this.acAckText)
            .fontSize(12)
            .fontColor(this.acPending ? this.accentBlue() : this.subTextColor())
            .margin({ top: 3 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 12 })

        Stack({ alignContent: Alignment.Center }) {
          Row() {}
            .width(17)
            .height(17)
            .border({ width: 2, color: this.acPower ? '#FFFFFF' : this.subTextColor() })
            .borderRadius(9)
          Row() {}
            .width(3)
            .height(11)
            .backgroundColor(this.acPower ? '#FFFFFF' : this.subTextColor())
            .borderRadius(2)
            .translate({ y: -6 })
        }
        .width(40)
        .height(40)
        .backgroundColor(this.acPower ? this.accentGreen() : this.softPanelBg())
        .border({ width: 1, color: this.acPower ? this.accentGreen() : this.hairlineColor() })
        .borderRadius(20)
        .onClick(() => {
          if (this.acPending) {
            return
          }
          this.acPower = !this.acPower
          console.info(`[AC][power] ${this.acPower}`)
          this.requestACControl('power').catch((err: Error) => {
            console.info(`[AC][power-fail] ${err.message}`)
          })
        })
      }
      .width('100%')
      .height(40)
      .alignItems(VerticalAlign.Center)

      Row() {
        this.TemperatureUnitValue(
          this.acTemp,
          34,
          this.acMode === 'heat' ? this.accentOrange() : this.accentBlue()
        )
        Blank()
          .layoutWeight(1)
        Row({ space: 6 }) {
          Stack({ alignContent: Alignment.Center }) {
            Text('-')
              .fontSize(21)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.acTemp > 16 ? this.textColor() : this.subTextColor())
              .translate({ y: -1 })
          }
          .width(32)
          .height(32)
          .backgroundColor(this.cardBg())
          .border({ width: 1, color: this.hairlineColor() })
          .borderRadius(16)
          .opacity(this.acTemp > 16 ? 1 : 0.45)
          .onClick(() => {
            this.changeACTempBy(-1)
          })
          Stack({ alignContent: Alignment.Center }) {
            Text('+')
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.acTemp < 30 ? '#FFFFFF' : this.subTextColor())
              .translate({ y: -1 })
          }
          .width(32)
          .height(32)
          .backgroundColor(this.acTemp < 30 ? this.accentBlue() : this.cardBg())
          .border({ width: 1, color: this.acTemp < 30 ? this.accentBlue() : this.hairlineColor() })
          .borderRadius(16)
          .opacity(this.acTemp < 30 ? 1 : 0.45)
          .onClick(() => {
            this.changeACTempBy(1)
          })
        }
        .height(32)
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .height(62)
      .alignItems(VerticalAlign.Center)
      .margin({ top: 8 })
      .padding({ left: 10, right: 10 })
      .backgroundColor(this.softPanelBg())
      .borderRadius(12)

      Row() {
        Text('运行模式')
          .fontSize(12)
          .fontColor(this.subTextColor())
          .maxLines(1)
        Blank()
        Stack({ alignContent: Alignment.Center }) {
          Image($r('app.media.ac_mode_cool'))
            .width(18)
            .height(18)
            .objectFit(ImageFit.Contain)
        }
        .width(38)
        .height(34)
        .backgroundColor(this.acMode === 'cool' ? '#E8F3FF' : this.softPanelBg())
        .border({ width: this.acMode === 'cool' ? 2 : 1, color: this.acMode === 'cool' ? this.accentBlue() : this.hairlineColor() })
        .borderRadius(10)
        .opacity(this.acMode === 'cool' ? 1 : 0.7)
        .onClick(() => {
          if (this.acMode !== 'cool') {
            this.toggleACMode()
          }
        })
        Stack({ alignContent: Alignment.Center }) {
          Image($r('app.media.ac_mode_heat'))
            .width(18)
            .height(18)
            .objectFit(ImageFit.Contain)
        }
        .width(38)
        .height(34)
        .backgroundColor(this.acMode === 'heat' ? '#FFF2DD' : this.softPanelBg())
        .border({ width: this.acMode === 'heat' ? 2 : 1, color: this.acMode === 'heat' ? this.accentOrange() : this.hairlineColor() })
        .borderRadius(10)
        .opacity(this.acMode === 'heat' ? 1 : 0.7)
        .margin({ left: 8 })
        .onClick(() => {
          if (this.acMode !== 'heat') {
            this.toggleACMode()
          }
        })
      }
      .width('100%')
      .height(34)
      .alignItems(VerticalAlign.Center)
      .margin({ top: 8 })

      Row({ space: 8 }) {
        ForEach(['格力', '美的', '海尔'], (brand: string) => {
          Text(brand)
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.acBrand === brand ? '#FFFFFF' : this.textColor())
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
            .height(32)
            .borderRadius(10)
            .backgroundColor(this.acBrand === brand ? this.accentBlue() : this.softPanelBg())
            .border({ width: 1, color: this.hairlineColor() })
            .onClick(() => {
              this.setACBrand(brand)
            })
        }, (brand: string) => brand)
      }
      .width('100%')
      .height(32)
      .margin({ top: 8 })
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .borderRadius(16)
    .backgroundColor(this.cardBg())
    .border({ width: 1.5, color: this.acPower ? this.activeDeviceBorderColor() : this.hairlineColor() })
    .clip(true)
  }

  @Builder
  LightCard() {
    Column() {
      Row() {
        Stack({ alignContent: Alignment.Center }) {
          Image($r('app.media.device_light'))
            .width(20)
            .height(20)
            .objectFit(ImageFit.Contain)
        }
          .width(28)
          .height(28)
          .backgroundColor(this.accentGreen())
          .borderRadius(8)

        Column() {
          Text('照明控制')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.textColor())
            .maxLines(1)
          Text(this.livingLightPending ? '同步中' : this.livingLightAckText)
            .fontSize(12)
            .fontColor(this.livingLightPending ? this.accentBlue() : this.subTextColor())
            .margin({ top: 3 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 12 })

        Stack({ alignContent: Alignment.Center }) {
          Row() {}
            .width(17)
            .height(17)
            .border({ width: 2, color: this.livingLightOn ? '#FFFFFF' : this.subTextColor() })
            .borderRadius(9)
          Row() {}
            .width(3)
            .height(11)
            .backgroundColor(this.livingLightOn ? '#FFFFFF' : this.subTextColor())
            .borderRadius(2)
            .translate({ y: -6 })
        }
        .width(40)
        .height(40)
        .backgroundColor(this.livingLightOn ? this.accentGreen() : this.softPanelBg())
        .border({ width: 1, color: this.livingLightOn ? this.accentGreen() : this.hairlineColor() })
        .borderRadius(20)
        .onClick(() => {
          if (!this.livingLightPending) {
            this.requestLivingLightToggle()
          }
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Image(this.livingLightOn ? $r('app.media.light_bulb_on_card') : $r('app.media.light_bulb_off_card'))
      .width('100%')
      .layoutWeight(1)
      .objectFit(ImageFit.Contain)
      .margin({ top: 10 })
    }
    .width('100%')
    .height('100%')
    .padding(20)
    .alignItems(HorizontalAlign.Start)
    .borderRadius(16)
    .backgroundColor(this.cardBg())
    .border({ width: 1.5, color: this.livingLightOn ? this.activeDeviceBorderColor() : this.hairlineColor() })
    .clip(true)
  }

  @Builder
  CurtainCard() {
    Column() {
      this.DeviceSectionTitle('电动窗帘电机', '支持本地断网控制', $r('app.media.device_curtain'), this.curtainPercent > 0, this.accentBlue())

      Row() {
        Text(`${this.curtainPercent}`)
          .fontSize(44)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.accentBlue())
        Text('%')
          .fontSize(20)
          .fontColor(this.accentBlue())
          .margin({ top: 15, left: 4 })
      }
      .width('100%')
      .height(58)
      .margin({ top: 14 })

      Slider({ value: this.curtainPercent, min: 0, max: 100, step: 1, style: SliderStyle.OutSet })
        .width('100%')
        .height(36)
        .selectedColor(this.accentBlue())
        .trackColor(this.controlTrackColor())
        .margin({ top: 8 })
        .onChange((value: number) => {
          this.changeCurtain(value)
        })

      Blank()

      Text(this.curtainPercent === 0 ? '窗帘已关闭' : this.curtainPercent === 100 ? '窗帘已全开' : '窗帘开合调节中')
        .fontSize(14)
        .fontColor(this.subTextColor())
        .height(34)
        .padding({ left: 16, right: 16 })
        .borderRadius(17)
        .backgroundColor(this.softPanelBg())
        .margin({ bottom: 10 })
    }
    .width('100%')
    .height('100%')
    .padding(20)
    .borderRadius(16)
    .backgroundColor(this.cardBg())
    .border({ width: 1.5, color: this.hairlineColor() })
    .clip(true)
  }

  @Builder
  OverviewAcPanel() {
    Column() {
      Row() {
        Column() {
          Text('空调控制')
            .fontSize(26)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.textColor())
          Text(this.acPending ? '正在等待设备确认' : this.acAckText)
            .fontSize(13)
            .fontColor(this.acPending ? this.accentBlue() : this.subTextColor())
            .margin({ top: 5 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Button('关闭')
          .width(72)
          .height(36)
          .fontSize(13)
          .fontColor('#FFFFFF')
          .backgroundColor('#2E3033')
          .borderRadius(18)
          .onClick(() => {
            this.showAcControlPanel = false
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row() {
        Image($r('app.media.overview_ac'))
          .width(220)
          .height(178)
          .objectFit(ImageFit.Contain)

        Column() {
          Row() {
            this.TemperatureUnitValue(
              this.acTemp,
              58,
              this.acMode === 'heat' ? this.accentOrange() : this.accentBlue()
            )
            Blank()
              .layoutWeight(1)
            Button(this.acPower ? '关闭空调' : '开启空调')
              .width(118)
              .height(42)
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
              .backgroundColor(this.acPower ? this.warningRed() : this.accentGreen())
              .borderRadius(21)
              .enabled(!this.acPending)
              .onClick(() => {
                this.acPower = !this.acPower
                this.requestACControl('power').catch((err: Error) => {
                  console.info(`[AC][panel-power-fail] ${err.message}`)
                })
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Row({ space: 12 }) {
            Button('-')
              .layoutWeight(1)
              .height(46)
              .fontSize(24)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.textColor())
              .backgroundColor(this.softPanelBg())
              .border({ width: 1, color: this.hairlineColor() })
              .borderRadius(12)
              .enabled(this.acTemp > 16 && !this.acPending)
              .onClick(() => {
                this.changeACTempBy(-1)
              })
            Button('+')
              .layoutWeight(1)
              .height(46)
              .fontSize(22)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
              .backgroundColor(this.accentBlue())
              .borderRadius(12)
              .enabled(this.acTemp < 30 && !this.acPending)
              .onClick(() => {
                this.changeACTempBy(1)
              })
          }
          .width('100%')
          .margin({ top: 18 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 28 })
      }
      .width('100%')
      .height(188)
      .alignItems(VerticalAlign.Center)
      .margin({ top: 18 })

      Row({ space: 12 }) {
        Button('制冷')
          .layoutWeight(1)
          .height(46)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.acMode === 'cool' ? '#FFFFFF' : this.textColor())
          .backgroundColor(this.acMode === 'cool' ? this.accentBlue() : this.softPanelBg())
          .border({ width: 1, color: this.acMode === 'cool' ? this.accentBlue() : this.hairlineColor() })
          .borderRadius(12)
          .onClick(() => {
            if (this.acMode !== 'cool') {
              this.toggleACMode()
            }
          })
        Button('制热')
          .layoutWeight(1)
          .height(46)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.acMode === 'heat' ? '#FFFFFF' : this.textColor())
          .backgroundColor(this.acMode === 'heat' ? this.accentOrange() : this.softPanelBg())
          .border({ width: 1, color: this.acMode === 'heat' ? this.accentOrange() : this.hairlineColor() })
          .borderRadius(12)
          .onClick(() => {
            if (this.acMode !== 'heat') {
              this.toggleACMode()
            }
          })
      }
      .width('100%')

      Row({ space: 12 }) {
        ForEach(['格力', '美的', '海尔'], (brand: string) => {
          Button(brand)
            .layoutWeight(1)
            .height(44)
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.acBrand === brand ? '#FFFFFF' : this.textColor())
            .backgroundColor(this.acBrand === brand ? this.accentGreen() : this.softPanelBg())
            .border({ width: 1, color: this.acBrand === brand ? this.accentGreen() : this.hairlineColor() })
            .borderRadius(12)
            .onClick(() => {
              this.setACBrand(brand)
            })
        }, (brand: string) => brand)
      }
      .width('100%')
      .margin({ top: 14 })
    }
    .width(660)
    .height(460)
    .padding(28)
    .backgroundColor(this.cardBg())
    .border({ width: 1.5, color: this.hairlineColor() })
    .borderRadius(22)
  }

  @Builder
  DebugInfoRow(label: string, value: string, color: string) {
    Column() {
      Text(label)
        .fontSize(12)
        .fontColor(this.subTextColor())
        .maxLines(1)
      Text(value)
        .fontSize(12)
        .fontWeight(FontWeight.Bold)
        .fontColor(color)
        .margin({ top: 4 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 9, bottom: 9 })
    .backgroundColor(this.softPanelBg())
    .border({ width: 1, color: this.hairlineColor() })
    .borderRadius(8)
  }

  @Builder
  DebugInfoPanel() {
    Column() {
      Row() {
        Column() {
          Text('调试信息')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.textColor())
          Text(`${this.activeDeviceName()} · ${this.activeDeviceIdHint()}`)
            .fontSize(12)
            .fontColor(this.subTextColor())
            .margin({ top: 4 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Button('关闭')
          .width(72)
          .height(34)
          .fontSize(13)
          .fontColor('#FFFFFF')
          .backgroundColor('#2E3033')
          .borderRadius(8)
          .onClick(() => {
            this.showDebugPanel = false
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Column() {
          this.DebugInfoRow('当前目标', `${this.activeDeviceName()} · ${this.deviceIdDisplayText(this.activeDeviceId)}`, this.accentBlue())
          this.DebugInfoRow('设备能力', this.activeDeviceCapabilitiesText(), this.textColor())
          this.DebugInfoRow('控制卡片绑定', this.activeDeviceBindingsText(), this.accentGreen())
          this.DebugInfoRow('设备配置', `${this.transportForDevice(this.activeDeviceId)} / ${this.cryptoModeForDevice(this.activeDeviceId)}-GCM`, this.accentGreen())
          this.DebugInfoRow('密钥状态', this.activeDeviceKeyText(), this.activeDeviceKeyText().startsWith('ECDH') ? this.accentGreen() : this.accentOrange())
          this.DebugInfoRow('最近注册', this.activeDeviceLastSeenText(), this.subTextColor())
          this.DebugInfoRow('最近解密', this.cryptoLastDecrypted, this.cryptoEnabled ? this.accentGreen() : this.subTextColor())
          this.DebugInfoRow('当前调试行', this.cryptoDebugText, this.accentBlue())
          this.DebugInfoRow('MQTT 地址 / 端口', this.mqttStatus, this.mqttConnected ? this.accentGreen() : this.accentOrange())
          this.DebugInfoRow('Beacon 自动发现', this.beaconLastReceived, this.beaconAutoDiscovered ? this.accentGreen() : this.subTextColor())

          Row() {
            Text(this.debugShowAllDevices ? '全部通信消息' : '当前设备消息')
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.textColor())
              .layoutWeight(1)
            Text(`${this.debugVisibleMessages().length} 条 · ${this.mqttLastMsgTime}`)
              .fontSize(11)
              .fontColor(this.subTextColor())
          }
          .width('100%')
          .margin({ top: 8, bottom: 8 })

          Row() {
            Text('当前设备')
              .layoutWeight(1)
              .height(32)
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(!this.debugShowAllDevices ? '#FFFFFF' : this.textColor())
              .textAlign(TextAlign.Center)
              .backgroundColor(!this.debugShowAllDevices ? this.accentBlue() : this.softPanelBg())
              .border({ width: 1, color: this.hairlineColor() })
              .borderRadius(8)
              .onClick(() => {
                this.debugShowAllDevices = false
              })
            Text('全部设备')
              .layoutWeight(1)
              .height(32)
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.debugShowAllDevices ? '#FFFFFF' : this.textColor())
              .textAlign(TextAlign.Center)
              .backgroundColor(this.debugShowAllDevices ? this.accentBlue() : this.softPanelBg())
              .border({ width: 1, color: this.hairlineColor() })
              .borderRadius(8)
              .margin({ left: 8 })
              .onClick(() => {
                this.debugShowAllDevices = true
              })
          }
          .width('100%')
          .margin({ bottom: 8 })

          if (this.debugVisibleMessages().length === 0) {
            Text('暂无 MQTT 消息')
              .width('100%')
              .height(90)
              .fontSize(14)
              .fontColor(this.subTextColor())
              .textAlign(TextAlign.Center)
          } else {
            ForEach(this.debugVisibleMessages(), (item: MessageItem) => {
              Column() {
                Row() {
                  Text(item.time)
                    .fontSize(11)
                    .fontColor(this.accentGreen())
                    .layoutWeight(1)
                  Text(item.from)
                    .fontSize(11)
                    .fontColor(this.accentBlue())
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .width('100%')
                Text(item.text)
                  .width('100%')
                  .fontSize(12)
                  .fontColor(this.textColor())
                  .margin({ top: 4 })
                  .maxLines(3)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')
              .padding({ left: 10, right: 10, top: 8, bottom: 8 })
              .backgroundColor(this.softPanelBg())
              .border({ width: 1, color: this.hairlineColor() })
              .borderRadius(8)
              .margin({ bottom: 6 })
            }, (item: MessageItem) => item.id)
          }
        }
        .width('100%')
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .margin({ top: 12 })
    }
    .width(520)
    .height(430)
    .padding(16)
    .backgroundColor(this.cardBg())
    .border({ width: 1, color: this.hairlineColor() })
    .borderRadius(16)
  }

  @Builder
  DeviceStatusPanel() {
    Column() {
      Row() {
        Column() {
          Text('设备状态')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.textColor())
          Text(`${this.registeredDeviceCount()} 台设备 · ${this.isBridgeActuallyConnected() ? '通信正常' : '等待连接'}`)
            .fontSize(12)
            .fontColor(this.isBridgeActuallyConnected() ? this.accentGreen() : this.warningRed())
            .margin({ top: 4 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Button() {
          Image($r('app.media.setting_refresh'))
            .width(19)
            .height(19)
            .objectFit(ImageFit.Contain)
        }
        .width(40)
        .height(40)
        .padding(0)
        .backgroundColor(this.accentBlue())
        .borderRadius(20)
        .margin({ right: 10 })
        .onClick(() => {
          this.reconnectBridge()
        })

        Button('关闭')
          .width(70)
          .height(36)
          .fontSize(13)
          .fontColor('#FFFFFF')
          .backgroundColor('#2E3033')
          .borderRadius(18)
          .onClick(() => {
            this.showDeviceStatusPanel = false
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row() {
        Column() {
          Text(this.activeDeviceName())
            .width('100%')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.textColor())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.deviceIdDisplayText(this.activeDeviceId))
            .width('100%')
            .fontSize(11)
            .fontColor(this.accentBlue())
            .margin({ top: 4 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Column() {
          Text(`${this.transportForDevice(this.activeDeviceId)} / ${this.cryptoModeForDevice(this.activeDeviceId)}-GCM`)
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.accentGreen())
          Text(this.activeDeviceLastSeenText())
            .fontSize(11)
            .fontColor(this.subTextColor())
            .margin({ top: 4 })
        }
        .alignItems(HorizontalAlign.End)
      }
      .width('100%')
      .height(78)
      .padding({ left: 18, right: 18 })
      .margin({ top: 18 })
      .alignItems(VerticalAlign.Center)
      .backgroundColor(this.softPanelBg())
      .border({ width: 1.5, color: this.accentBlue() })
      .borderRadius(12)

      Row() {
        Text('已发现设备')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.textColor())
          .layoutWeight(1)
        Text('点击设备可切换控制目标')
          .fontSize(11)
          .fontColor(this.subTextColor())
      }
      .width('100%')
      .margin({ top: 16, bottom: 8 })

      List({ space: 8 }) {
        ForEach(this.deviceBindingIds(), (deviceId: string) => {
          ListItem() {
            Row() {
              Column() {
                Text(this.deviceBindingNameForId(deviceId))
                  .width('100%')
                  .fontSize(15)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(this.textColor())
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(`${this.deviceIdDisplayText(deviceId)} · ${this.deviceBindingCapabilitiesForId(deviceId)}`)
                  .width('100%')
                  .fontSize(11)
                  .fontColor(this.subTextColor())
                  .margin({ top: 4 })
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Text(deviceId === this.activeDeviceId ? '当前目标' :
                `${this.transportForDevice(deviceId)} / ${this.cryptoModeForDevice(deviceId)}`)
                .fontSize(11)
                .fontWeight(FontWeight.Bold)
                .fontColor(deviceId === this.activeDeviceId ? this.accentGreen() : this.accentBlue())
            }
            .width('100%')
            .height(62)
            .padding({ left: 14, right: 14 })
            .alignItems(VerticalAlign.Center)
            .backgroundColor(this.softPanelBg())
            .border({ width: 1, color: deviceId === this.activeDeviceId ?
              this.accentGreen() : this.hairlineColor() })
            .borderRadius(10)
            .onClick(() => {
              this.selectActiveDevice(deviceId)
            })
          }
        }, (deviceId: string) => deviceId)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.None)

      Text(`能力：${this.activeDeviceCapabilitiesText()} · 绑定：${this.activeDeviceBindingsText()} · ${this.activeDeviceKeyText()}`)
        .width('100%')
        .fontSize(11)
        .fontColor(this.subTextColor())
        .margin({ top: 10 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width(780)
    .height(520)
    .padding(22)
    .backgroundColor(this.cardBg())
    .border({ width: 1.5, color: this.hairlineColor() })
    .borderRadius(18)
  }

  @Builder
  DeviceBindingPanel() {
    Column() {
      Row() {
        Column() {
          Text('设备绑定')
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.textColor())
          Text(`${this.deviceBindingIds().length} 台设备 · 按设备能力分配控制卡片`)
            .fontSize(12)
            .fontColor(this.subTextColor())
            .margin({ top: 4 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Button('关闭')
          .width(70)
          .height(34)
          .fontSize(13)
          .fontColor('#FFFFFF')
          .backgroundColor('#2E3033')
          .borderRadius(17)
          .onClick(() => {
            this.showDeviceBindingPanel = false
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text('设备列表')
        .width('100%')
        .fontSize(12)
        .fontColor(this.subTextColor())
        .textAlign(TextAlign.Start)
      .width('100%')
      .padding({ left: 14, right: 14 })
      .margin({ top: 18, bottom: 8 })

      List({ space: 10 }) {
        ForEach(this.deviceBindingIds(), (deviceId: string) => {
          ListItem() {
            Column() {
              Row() {
                Text(this.deviceBindingNameForId(deviceId))
                  .fontSize(15)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(this.textColor())
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                if (deviceId === this.activeDeviceId) {
                  Text('当前目标')
                    .fontSize(10)
                    .fontColor(this.accentBlue())
                    .margin({ left: 8 })
                }
              }
              .width('100%')
              Text(this.deviceIdDisplayText(deviceId))
                .width('100%')
                .fontSize(11)
                .fontColor(this.subTextColor())
                .margin({ top: 3 })
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(`声明能力：${this.deviceBindingCapabilitiesForId(deviceId)}`)
                .width('100%')
                .fontSize(11)
                .fontColor(this.accentGreen())
                .margin({ top: 5 })
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap }) {
                ForEach(this.bindingControlCapabilities(), (capability: string) => {
                  Button(this.bindingCapabilityLabel(capability))
                    .width(88)
                    .height(32)
                    .fontSize(12)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.deviceForCapability(capability) === deviceId ? '#FFFFFF' : this.textColor())
                    .backgroundColor(this.deviceForCapability(capability) === deviceId ?
                      this.accentGreen() : this.cardBg())
                    .border({ width: 1, color: this.deviceForCapability(capability) === deviceId ?
                      this.accentGreen() : this.hairlineColor() })
                    .borderRadius(16)
                    .margin({ right: 10, top: 8 })
                    .enabled(this.deviceCanBindCapability(deviceId, capability))
                    .opacity(this.deviceCanBindCapability(deviceId, capability) ? 1 : 0.38)
                    .onClick(() => {
                      this.bindCapabilityDevice(capability, deviceId)
                    })
                }, (capability: string) => capability)
              }
              .width('100%')
            }
            .width('100%')
            .padding({ left: 14, right: 14, top: 12, bottom: 12 })
            .alignItems(HorizontalAlign.Start)
            .backgroundColor(this.softPanelBg())
            .border({ width: 1, color: this.hairlineColor() })
            .borderRadius(12)
          }
        }, (deviceId: string) => deviceId)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.None)

      Text('声明能力会全部显示；传感器和报警等上报能力自动接入，这里只分配已有控制卡片')
        .width('100%')
        .fontSize(11)
        .fontColor(this.subTextColor())
        .margin({ top: 4 })
    }
    .width(760)
    .height(520)
    .padding(20)
    .backgroundColor(this.cardBg())
    .border({ width: 1.5, color: this.hairlineColor() })
    .borderRadius(20)
  }

  @Builder
  ProvisioningOutputPanel() {
    Column() {
      Row() {
        Column() {
          Text('设备输出')
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.textColor())
          Text(`${this.provisioningFrameLog.length} 条`)
            .fontSize(12)
            .fontColor(this.subTextColor())
            .margin({ top: 4 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Button('清空')
          .width(70)
          .height(34)
          .fontSize(13)
          .fontColor(this.textColor())
          .backgroundColor(this.softPanelBg())
          .border({ width: 1, color: this.hairlineColor() })
          .borderRadius(8)
          .margin({ right: 8 })
          .onClick(() => {
            this.clearProvisioningEsp32Log()
          })

        Button('关闭')
          .width(70)
          .height(34)
          .fontSize(13)
          .fontColor('#FFFFFF')
          .backgroundColor('#2E3033')
          .borderRadius(8)
          .onClick(() => {
            this.showProvisioningOutputPanel = false
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Column() {
          if (this.provisioningFrameLog.length === 0) {
            Text('暂无设备输出')
              .width('100%')
              .fontSize(13)
              .fontColor(this.subTextColor())
              .textAlign(TextAlign.Center)
              .margin({ top: 180 })
          }
          ForEach(this.provisioningFrameLog, (line: string) => {
            Text(line)
              .width('100%')
              .fontSize(12)
              .fontColor(this.textColor())
              .maxLines(10)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ bottom: 8 })
          }, (line: string) => line)
        }
        .width('100%')
      }
      .width('100%')
      .height(450)
      .scrollBar(BarState.Auto)
      .padding(14)
      .margin({ top: 16 })
      .backgroundColor(this.pageBg())
      .border({ width: 1, color: this.hairlineColor() })
      .borderRadius(8)
    }
    .width(820)
    .height(540)
    .padding(22)
    .backgroundColor(this.cardBg())
    .border({ width: 1, color: this.hairlineColor() })
    .borderRadius(20)
  }

  @Builder
  ProvisioningPanel() {
    Column() {
      Row() {
        Column() {
          Text('串口接入设备')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.textColor())
          Text('请通过 USB Type-C 数据线将设备连接大禹，添加成功后即可无线使用')
            .fontSize(12)
            .fontColor(this.subTextColor())
            .margin({ top: 4 })
            .maxLines(2)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Button('关闭')
          .width(72)
          .height(34)
          .fontSize(13)
          .fontColor('#FFFFFF')
          .backgroundColor('#2E3033')
          .borderRadius(17)
          .onClick(() => {
            this.closeProvisioningPanel()
          })
      }
      .width('100%')

      Text(this.provisioningStatus)
        .width('100%')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.provisioningConnected ? this.accentGreen() : this.accentOrange())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 10 })

      Row() {
        Text(this.selectedProvisioningDeviceText())
          .layoutWeight(1)
          .height(38)
          .fontSize(12)
          .fontColor(this.textColor())
          .padding({ left: 12, right: 12 })
          .backgroundColor(this.softPanelBg())
          .border({ width: 1, color: this.hairlineColor() })
          .borderRadius(8)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Button('扫描')
          .width(66)
          .height(38)
          .fontSize(13)
          .fontColor('#FFFFFF')
          .backgroundColor(this.accentBlue())
          .borderRadius(8)
          .margin({ left: 8 })
          .onClick(() => {
            this.refreshProvisioningUsbDevices()
          })
        Button('<')
          .width(42)
          .height(38)
          .fontSize(15)
          .fontColor(this.textColor())
          .backgroundColor(this.softPanelBg())
          .border({ width: 1, color: this.hairlineColor() })
          .borderRadius(8)
          .margin({ left: 8 })
          .onClick(() => {
            this.selectProvisioningDevice(-1)
          })
        Button('>')
          .width(42)
          .height(38)
          .fontSize(15)
          .fontColor(this.textColor())
          .backgroundColor(this.softPanelBg())
          .border({ width: 1, color: this.hairlineColor() })
          .borderRadius(8)
          .margin({ left: 6 })
          .onClick(() => {
            this.selectProvisioningDevice(1)
          })
        Button(this.provisioningConnected ? '断开' : '连接')
          .width(70)
          .height(38)
          .fontSize(13)
          .fontColor('#FFFFFF')
          .backgroundColor(this.provisioningConnected ? this.warningRed() : this.accentGreen())
          .borderRadius(8)
          .margin({ left: 8 })
          .onClick(() => {
            if (this.provisioningConnected) {
              this.disconnectProvisioningUsb()
            } else {
              this.connectProvisioningUsb()
            }
          })
      }
      .width('100%')
      .margin({ top: 14 })

      Row() {
        TextInput({ placeholder: 'WiFi SSID', text: this.provisioningWifiSsid })
          .layoutWeight(1)
          .height(40)
          .fontSize(13)
          .backgroundColor(this.softPanelBg())
          .border({ width: 1, color: this.hairlineColor() })
          .borderRadius(8)
          .onChange((value: string) => {
            this.provisioningWifiSsid = value
          })
        Button('自动')
          .width(62)
          .height(40)
          .fontSize(13)
          .fontColor('#FFFFFF')
          .backgroundColor(this.accentBlue())
          .borderRadius(8)
          .margin({ left: 8 })
          .onClick(() => {
            this.refreshProvisioningWifiInfo()
          })
      }
      .width('100%')
      .margin({ top: 12 })

      TextInput({ placeholder: 'WiFi Password', text: this.provisioningWifiPassword })
        .width('100%')
        .height(40)
        .fontSize(13)
        .type(InputType.Password)
        .backgroundColor(this.softPanelBg())
        .border({ width: 1, color: this.hairlineColor() })
        .borderRadius(8)
        .margin({ top: 8 })
        .onChange((value: string) => {
          this.provisioningWifiPassword = value
        })

      Row() {
        Text('TLS')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.textColor())
          .layoutWeight(1)
        Text(this.provisioningUseTls ? 'mqtts / https' : 'mqtt / http')
          .fontSize(12)
          .fontColor(this.subTextColor())
          .margin({ right: 8 })
        Toggle({ type: ToggleType.Switch, isOn: this.provisioningUseTls })
          .selectedColor(this.accentGreen())
          .onChange((value: boolean) => {
            this.applyProvisioningTlsMode(value)
          })
      }
      .width('100%')
      .height(36)
      .padding({ left: 12, right: 12 })
      .backgroundColor(this.softPanelBg())
      .border({ width: 1, color: this.hairlineColor() })
      .borderRadius(8)
      .margin({ top: 8 })

      TextInput({ placeholder: 'MQTT Broker URL，例如 mqtts://192.168.3.5:8884', text: this.provisioningBrokerUrl })
        .width('100%')
        .height(40)
        .fontSize(13)
        .backgroundColor(this.softPanelBg())
        .border({ width: 1, color: this.hairlineColor() })
        .borderRadius(8)
        .margin({ top: 8 })
        .onChange((value: string) => {
          this.provisioningBrokerUrl = value
          this.provisioningUseTls = value.trim().toLowerCase().startsWith('mqtts://') ||
            this.provisioningHttpBridge.trim().toLowerCase().startsWith('https://')
        })

      TextInput({ placeholder: 'HTTP Bridge，例如 https://192.168.3.5:3444', text: this.provisioningHttpBridge })
        .width('100%')
        .height(40)
        .fontSize(13)
        .backgroundColor(this.softPanelBg())
        .border({ width: 1, color: this.hairlineColor() })
        .borderRadius(8)
        .margin({ top: 8 })
        .onChange((value: string) => {
          this.provisioningHttpBridge = value
          this.provisioningUseTls = value.trim().toLowerCase().startsWith('https://') ||
            this.provisioningBrokerUrl.trim().toLowerCase().startsWith('mqtts://')
        })

      Row() {
        Text('设备编号自动生成')
          .layoutWeight(1)
          .height(40)
          .fontSize(13)
          .fontColor(this.subTextColor())
          .textAlign(TextAlign.Center)
          .backgroundColor(this.softPanelBg())
          .border({ width: 1, color: this.hairlineColor() })
          .borderRadius(8)
        Text(this.provisioningCrypto.toUpperCase())
          .width(62)
          .height(40)
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .textAlign(TextAlign.Center)
          .backgroundColor(this.provisioningCrypto === 'sm4' ? this.accentBlue() : '#2E3033')
          .borderRadius(8)
          .margin({ left: 8 })
          .onClick(() => {
            this.provisioningCrypto = this.provisioningCrypto === 'sm4' ? 'aes' : 'sm4'
          })
        Text(this.provisioningTransport.toUpperCase())
          .width(70)
          .height(40)
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .textAlign(TextAlign.Center)
          .backgroundColor(this.provisioningTransport === 'mqtt' ? this.accentGreen() : this.accentOrange())
          .borderRadius(8)
          .margin({ left: 8 })
          .onClick(() => {
            this.provisioningTransport = this.provisioningTransport === 'mqtt' ? 'http' : 'mqtt'
          })
      }
      .width('100%')
      .margin({ top: 8 })

      Row() {
        Button('自动探测')
          .layoutWeight(1)
          .height(40)
          .fontSize(13)
          .fontColor('#FFFFFF')
          .backgroundColor(this.accentOrange())
          .borderRadius(8)
          .onClick(() => {
            this.autoProbeProvisioningUsb()
          })
        Button('发送配置')
          .layoutWeight(1)
          .height(40)
          .fontSize(13)
          .fontColor('#FFFFFF')
          .backgroundColor(this.accentBlue())
          .borderRadius(8)
          .margin({ left: 8 })
          .onClick(() => {
            this.sendProvisioningConfig()
          })
        Button('保存重启')
          .layoutWeight(1)
          .height(40)
          .fontSize(13)
          .fontColor('#FFFFFF')
          .backgroundColor(this.accentGreen())
          .borderRadius(8)
          .margin({ left: 8 })
          .onClick(() => {
            this.saveProvisioningConfig()
          })
      }
      .width('100%')
      .margin({ top: 12 })

      Row() {
        Button('设备输出')
          .width(112)
          .height(34)
          .fontSize(12)
          .fontColor(this.textColor())
          .backgroundColor(this.softPanelBg())
          .border({ width: 1, color: this.hairlineColor() })
          .borderRadius(8)
          .onClick(() => {
            this.showProvisioningOutputPanel = true
          })
        Text('点击“自动探测”，进入配网模式之后点击“发送配置”，上方状态显示收到之后点击“保存重启”，完成设备接入')
          .fontSize(11)
          .fontColor(this.subTextColor())
          .layoutWeight(1)
          .margin({ left: 10 })
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .margin({ top: 8 })
    }
    .width(780)
    .height(560)
    .padding(22)
    .borderRadius(20)
    .backgroundColor(this.cardBg())
    .border({ width: 1, color: this.hairlineColor() })
  }

  @Builder
  IrLearningPanel() {
    Column() {
      Row() {
        Column() {
          Text('空调万能适配')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.textColor())
          Text('按提示完成遥控器按键学习')
            .fontSize(12)
            .fontColor(this.subTextColor())
            .margin({ top: 4 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Button('关闭')
          .width(72)
          .height(34)
          .fontSize(13)
          .fontColor('#FFFFFF')
          .backgroundColor('#2E3033')
          .borderRadius(17)
          .onClick(() => {
            this.exitIrLearning(true).catch((err: Error) => {
              console.info(`[IR][exit-fail] ${err.message}`)
              this.showIrLearnPanel = false
            })
          })
      }
      .width('100%')

      Row() {
        Row() {
          Text('控制通道')
            .fontSize(12)
            .fontColor(this.subTextColor())
          Text(this.commandTransportText())
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.accentBlue())
            .margin({ left: 8 })
        }
          .layoutWeight(1)
          .height(38)
          .padding({ left: 12, right: 12 })
          .backgroundColor(this.softPanelBg())
          .border({ width: 1, color: this.hairlineColor() })
          .borderRadius(8)
        Row() {
          Text('加密算法')
            .fontSize(12)
            .fontColor(this.subTextColor())
          Text(`${this.cryptoMode}-GCM`)
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.accentGreen())
            .margin({ left: 8 })
        }
          .width(170)
          .height(38)
          .padding({ left: 12, right: 12 })
          .backgroundColor(this.softPanelBg())
          .border({ width: 1, color: this.hairlineColor() })
          .borderRadius(8)
          .margin({ left: 8 })
        Row() {
          Row() {}
            .width(8)
            .height(8)
            .borderRadius(4)
            .backgroundColor(this.isBridgeActuallyConnected() ? '#22B881' : this.warningRed())
          Text(this.isBridgeActuallyConnected() ? '设备通信在线' : '等待通信连接')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.textColor())
            .margin({ left: 8 })
        }
          .width(170)
          .height(38)
          .padding({ left: 12, right: 12 })
          .backgroundColor(this.softPanelBg())
          .border({ width: 1, color: this.hairlineColor() })
          .borderRadius(8)
          .margin({ left: 8 })
      }
      .width('100%')
      .margin({ top: 14 })

      Row() {
        Text('1')
          .width(30)
          .height(30)
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .textAlign(TextAlign.Center)
          .backgroundColor(this.accentOrange())
          .borderRadius(15)
        Column() {
          Text('将空调遥控器对准设备上的红外模块')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.textColor())
            .maxLines(1)
          Text('只需一个遥控器，就可以学习控制你的任何品牌空调')
            .fontSize(12)
            .fontColor(this.subTextColor())
            .margin({ top: 3 })
            .maxLines(1)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 12 })
      }
      .width('100%')
      .height(58)
      .padding({ left: 14, right: 14 })
      .backgroundColor(this.softPanelBg())
      .borderRadius(10)
      .margin({ top: 12 })

      Row({ space: 8 }) {
        ForEach(IR_LEARN_KEY_LABELS, (label: string) => {
          Column() {
            Text(`${IR_LEARN_KEY_LABELS.indexOf(label) + 1}`)
              .width(26)
              .height(26)
              .fontSize(12)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.irLearnResults[IR_LEARN_KEY_LABELS.indexOf(label)] > 0 ? '#FFFFFF' : this.subTextColor())
              .textAlign(TextAlign.Center)
              .backgroundColor(this.irLearnResults[IR_LEARN_KEY_LABELS.indexOf(label)] === 1 ? this.accentGreen() :
                (this.irLearnResults[IR_LEARN_KEY_LABELS.indexOf(label)] === 2 ? '#D94F4F' : this.softPanelBg()))
              .border({ width: IR_LEARN_KEY_LABELS.indexOf(label) === this.irLearnStep && this.irLearnActive ? 2 : 1,
                color: IR_LEARN_KEY_LABELS.indexOf(label) === this.irLearnStep && this.irLearnActive ? this.accentOrange() : this.hairlineColor() })
              .borderRadius(13)
            Text(label)
              .fontSize(11)
              .fontColor(IR_LEARN_KEY_LABELS.indexOf(label) === this.irLearnStep && this.irLearnActive ? this.textColor() : this.subTextColor())
              .margin({ top: 5 })
              .maxLines(1)
          }
          .layoutWeight(1)
        }, (label: string) => label)
      }
      .width('100%')
      .height(56)
      .margin({ top: 12 })

      Column() {
        Text(this.irLearnCompletedCount >= IR_LEARN_KEY_LABELS.length ? '全部完成' :
          `${this.irLearnStep + 1} / ${IR_LEARN_KEY_LABELS.length} · ${this.irLearnCurrentLabel()}`)
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.irLearnCompletedCount >= IR_LEARN_KEY_LABELS.length ? this.accentGreen() : this.textColor())
        Text(this.irLearnStatus)
          .width('100%')
          .fontSize(13)
          .fontColor(this.irLearnBusy ? this.accentOrange() : this.subTextColor())
          .textAlign(TextAlign.Center)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 9 })
      }
      .width('100%')
      .height(92)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(this.pageBg())
      .border({ width: 1.5, color: this.irLearnActive ? this.accentOrange() : this.hairlineColor() })
      .borderRadius(10)
      .margin({ top: 10 })

      if (this.irLearnCompletedCount >= IR_LEARN_KEY_LABELS.length) {
        Row() {
          Button('测试开机')
            .layoutWeight(1)
            .height(42)
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .backgroundColor(this.accentBlue())
            .borderRadius(8)
            .enabled(!this.irLearnBusy)
            .onClick(() => {
              this.testIrLearnedKey(1).catch((err: Error) => {
                this.irLearnStatus = `测试开机失败：${err.message}`
              })
            })
          Button('测试关机')
            .layoutWeight(1)
            .height(42)
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .backgroundColor(this.accentOrange())
            .borderRadius(8)
            .margin({ left: 10 })
            .enabled(!this.irLearnBusy)
            .onClick(() => {
              this.testIrLearnedKey(2).catch((err: Error) => {
                this.irLearnStatus = `测试关机失败：${err.message}`
              })
            })
          Button('重新学习')
            .layoutWeight(1)
            .height(42)
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.textColor())
            .backgroundColor(this.softPanelBg())
            .border({ width: 1, color: this.hairlineColor() })
            .borderRadius(8)
            .margin({ left: 10 })
            .enabled(!this.irLearnBusy)
            .onClick(() => {
              this.irLearnActive = false
              this.irLearnCompletedCount = 0
              this.irLearnStep = 0
              this.irLearnResults = [0, 0, 0, 0, 0, 0]
              this.startIrLearning().catch((err: Error) => {
                this.irLearnStatus = `重新学习失败：${err.message}`
              })
            })
          Button('完成并退出')
            .width(130)
            .height(42)
            .fontSize(14)
            .fontColor(this.textColor())
            .backgroundColor(this.softPanelBg())
            .border({ width: 1, color: this.hairlineColor() })
            .borderRadius(8)
            .margin({ left: 10 })
            .onClick(() => {
              this.exitIrLearning(true).catch((err: Error) => {
                console.info(`[IR][exit-fail] ${err.message}`)
              })
            })
        }
        .width('100%')
        .margin({ top: 14 })
      } else {
        Row() {
          Button(this.irLearnPrimaryActionText())
            .layoutWeight(1)
            .height(42)
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .backgroundColor(this.irLearnBusy ? this.subTextColor() : this.accentOrange())
            .borderRadius(8)
            .enabled(!this.irLearnBusy)
            .onClick(() => {
              this.runIrLearnPrimaryAction().catch((err: Error) => {
                this.irLearnBusy = false
                this.irLearnStatus = `操作失败: ${err.message}`
              })
            })
          Button('退出设置模式')
            .width(150)
            .height(42)
            .fontSize(14)
            .fontColor(this.textColor())
            .backgroundColor(this.softPanelBg())
            .border({ width: 1, color: this.hairlineColor() })
            .borderRadius(8)
            .margin({ left: 10 })
            .onClick(() => {
              this.exitIrLearning(true).catch((err: Error) => {
                console.info(`[IR][exit-fail] ${err.message}`)
              })
            })
        }
        .width('100%')
        .margin({ top: 14 })
      }
    }
    .width(720)
    .height(500)
    .padding(22)
    .borderRadius(20)
    .backgroundColor(this.cardBg())
    .border({ width: 1.5, color: this.hairlineColor() })
  }

  @Builder
  FaceEnrollPanel() {
    Column() {
      Row() {
        Column() {
          Text('人脸识别')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.textColor())
          Text(`${this.faceUsers.length} 位授权用户`)
            .fontSize(12)
            .fontColor(this.subTextColor())
            .margin({ top: 3 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Button('关闭')
          .width(72)
          .height(34)
          .fontSize(13)
          .fontColor('#FFFFFF')
          .backgroundColor('#2E3033')
          .borderRadius(17)
          .onClick(() => {
            this.stopFacePreview().catch((err: Error) => {
              console.info(`[FaceAccess][stop-fail] ${err.message}`)
            })
            this.showFaceEnrollPanel = false
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Stack({ alignContent: Alignment.Center }) {
        XComponent({
          id: 'face_preview_surface',
          type: XComponentType.TEXTURE,
          controller: this.facePreviewController
        })
          .width(300)
          .height(370)
          .rotate({ angle: 90, centerX: '50%', centerY: '50%' })
          .scale({ x: 1.18, y: 1.18, centerX: '50%', centerY: '50%' })
          .onLoad(() => {
            this.facePreviewSurfaceId = this.facePreviewController.getXComponentSurfaceId()
            this.facePreviewController.setXComponentSurfaceSize({
              surfaceWidth: 370,
              surfaceHeight: 300
            })
            this.startFacePreview().catch((err: Error) => {
              console.info(`[FaceAccess][preview-load-fail] ${err.message}`)
            })
          })
          .onDestroy(() => {
            this.facePreviewSurfaceId = ''
            this.stopFacePreview().catch((err: Error) => {
              console.info(`[FaceAccess][preview-destroy-fail] ${err.message}`)
            })
          })
        if (!this.facePreviewReady) {
          Column() {
            Text('预览准备中')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
            Text(this.faceAccessStatus)
              .fontSize(12)
              .fontColor('#C6CCD2')
              .textAlign(TextAlign.Center)
              .margin({ top: 8 })
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Center)
          .justifyContent(FlexAlign.Center)
          .width('100%')
          .height('100%')
        }
        if (this.facePreviewReady) {
          Text('LIVE')
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .width(52)
            .height(26)
            .textAlign(TextAlign.Center)
            .backgroundColor(this.accentGreen())
            .borderRadius(13)
            .position({ x: 12, y: 12 })
        }
      }
      .width('100%')
      .height(210)
      .margin({ top: 12 })
      .backgroundColor('#111315')
      .borderRadius(14)
      .border({ width: 1, color: this.hairlineColor() })
      .clip(true)

      Text(this.faceAccessStatus)
        .width('100%')
        .fontSize(13)
        .fontColor(this.textColor())
        .margin({ top: 8 })
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Row() {
        Text(this.doorStateText())
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.doorLocked ? this.accentGreen() : this.warningRed())
        Blank()
        Text(this.faceDoorActionText())
          .fontSize(12)
          .fontColor(this.accentBlue())
      }
      .width('100%')
      .height(28)
      .padding({ left: 12, right: 12 })
      .margin({ top: 6 })
      .backgroundColor(this.softPanelBg())
      .border({ width: 1, color: this.hairlineColor() })
      .borderRadius(8)
      Text(this.faceCameraSummary)
        .width('100%')
        .fontSize(11)
        .fontColor(this.subTextColor())
        .margin({ top: 3 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Column() {
        TextInput({ placeholder: '姓名 / 昵称', text: this.faceEnrollName })
          .width('100%')
          .height(40)
          .fontSize(14)
          .onChange((value: string) => {
            this.faceEnrollName = value
          })
        Row() {
          ForEach([1, 2, 3, 4, 5], (index: number) => {
            Text(index <= this.faceEnrollProgress ? 'OK' : `${index}`)
              .fontSize(11)
              .fontWeight(FontWeight.Bold)
              .fontColor(index <= this.faceEnrollProgress ? '#FFFFFF' : this.subTextColor())
              .textAlign(TextAlign.Center)
              .width(30)
              .height(30)
              .backgroundColor(index <= this.faceEnrollProgress ? this.accentGreen() : this.cardBg())
              .border({ width: 1, color: this.hairlineColor() })
              .borderRadius(15)
              .margin({ right: 7 })
          }, (index: number) => `${index}`)
        }
        .width('100%')
        .margin({ top: 10 })
        Row() {
          Button('检查相机')
            .layoutWeight(1)
            .height(38)
            .fontSize(13)
            .fontColor('#FFFFFF')
            .backgroundColor(this.accentBlue())
            .borderRadius(19)
            .onClick(() => {
              this.probeFaceAccess()
            })
          Button(this.faceIdentifyBusy ? '识别中' : '识别控制')
            .layoutWeight(1)
            .height(38)
            .fontSize(13)
            .fontColor('#FFFFFF')
            .backgroundColor(this.faceIdentifyBusy ? '#666B72' : this.accentBlue())
            .borderRadius(19)
            .margin({ left: 10 })
            .onClick(() => {
              this.identifyFaceOnce()
            })
          Button(this.faceEnrollBusy ? '采集中' : '人脸录入')
            .layoutWeight(1)
            .height(38)
            .fontSize(13)
            .fontColor('#FFFFFF')
            .backgroundColor(this.faceEnrollBusy ? '#666B72' : this.accentGreen())
            .borderRadius(19)
            .margin({ left: 10 })
            .onClick(() => {
              this.startFaceEnrollment()
            })
        }
        .width('100%')
        .margin({ top: 12 })
      }
      .width('100%')
      .padding(10)
      .margin({ top: 10 })
      .backgroundColor(this.softPanelBg())
      .border({ width: 1, color: this.hairlineColor() })
      .borderRadius(10)

      Row() {
        Text('授权用户')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.textColor())
          .layoutWeight(1)
        Text(`${this.faceUsers.length}`)
          .fontSize(13)
          .fontColor(this.accentBlue())
      }
      .width('100%')
      .margin({ top: 10 })

      List({ space: 8 }) {
        if (this.faceUsers.length === 0) {
          ListItem() {
            Text('还没有本地授权用户')
              .width('100%')
              .fontSize(14)
              .fontColor(this.subTextColor())
              .height(52)
              .textAlign(TextAlign.Center)
          }
        } else {
          ForEach(this.faceUsers, (user: FaceUser) => {
            ListItem() {
              Row() {
                Column() {
                  Text(user.name)
                    .width('100%')
                    .fontSize(16)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(this.textColor())
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(`${user.samples} 个本地样本 · 仅保存在本机`)
                    .width('100%')
                    .fontSize(12)
                    .fontColor(this.subTextColor())
                    .margin({ top: 3 })
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Button('删除')
                  .width(76)
                  .height(34)
                  .fontSize(13)
                  .fontColor('#FFFFFF')
                  .backgroundColor(this.warningRed())
                  .borderRadius(17)
                  .onClick(() => {
                    this.deleteFaceUser(user.userId)
                  })
              }
              .width('100%')
              .height(58)
              .padding({ left: 14, right: 10 })
              .backgroundColor(this.cardBg())
              .border({ width: 1, color: this.hairlineColor() })
              .borderRadius(8)
            }
          }, (user: FaceUser) => user.userId)
        }
      }
      .width('100%')
      .height(198)
      .margin({ top: 6 })
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.None)
    }
    .width(410)
    .height(810)
    .padding(20)
    .backgroundColor(this.cardBg())
    .border({ width: 1, color: this.hairlineColor() })
    .borderRadius(22)
    .rotate({ angle: 90, centerX: '50%', centerY: '50%' })
  }

  @Builder
  VoiceprintPanel() {
    Column() {
      Row() {
        Column() {
          Text('声纹保护')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.textColor())
          Text('本地声纹验证 · 不保存原始录音')
            .fontSize(12)
            .fontColor(this.subTextColor())
            .margin({ top: 3 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Button('关闭')
          .width(72)
          .height(34)
          .fontSize(13)
          .fontColor('#FFFFFF')
          .backgroundColor('#2E3033')
          .borderRadius(17)
          .onClick(() => {
            this.closeVoiceprintManager()
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row() {
        Column() {
          Text(this.voiceprintProtectionEnabled ? '声纹保护已开启' : '声纹保护未开启')
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.voiceprintProtectionEnabled ? this.accentGreen() : this.subTextColor())
          Text(this.voiceprintStatus)
            .width('100%')
            .fontSize(12)
            .fontColor(this.voiceprintStatus === '请先填写姓名或昵称' ?
              this.warningRed() : this.subTextColor())
            .margin({ top: 4 })
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Text('保护')
          .fontSize(13)
          .fontColor(this.textColor())
          .margin({ right: 8 })
        Toggle({ type: ToggleType.Switch, isOn: this.voiceprintProtectionEnabled })
          .selectedColor(this.accentGreen())
          .onChange((isOn: boolean) => {
            this.setVoiceprintProtection(isOn)
          })
      }
      .width('100%')
      .height(54)
      .padding({ left: 14, right: 12 })
      .margin({ top: 10 })
      .backgroundColor(this.softPanelBg())
      .border({ width: 1, color: this.hairlineColor() })
      .borderRadius(10)

      Column() {
        TextInput({ placeholder: '姓名 / 昵称', text: this.voiceprintEnrollName })
          .width('100%')
          .height(36)
          .fontSize(14)
          .enabled(!this.voiceprintEnrollBusy)
          .onChange((value: string) => {
            this.voiceprintEnrollName = value
            if (value.trim().length > 0 && this.voiceprintStatus === '请先填写姓名或昵称') {
              this.voiceprintStatus = `准备录入第 ${Math.min(this.voiceprintEnrollProgress + 1, 3)} 轮`
            }
          })
        Row() {
          ForEach([1, 2, 3], (index: number) => {
            Row() {
              Text(index <= this.voiceprintEnrollProgress ? 'OK' : `${index}`)
                .fontSize(11)
                .fontWeight(FontWeight.Bold)
                .fontColor(index <= this.voiceprintEnrollProgress ? '#FFFFFF' : this.subTextColor())
                .textAlign(TextAlign.Center)
                .width(32)
                .height(32)
                .backgroundColor(index <= this.voiceprintEnrollProgress ? this.accentGreen() : this.cardBg())
                .border({ width: 1.5, color: index <= this.voiceprintEnrollProgress ? this.accentGreen() : this.hairlineColor() })
                .borderRadius(16)
              if (index < 3) {
                Column() {}
                  .width(46)
                  .height(2)
                  .backgroundColor(index < this.voiceprintEnrollProgress ? this.accentGreen() : this.hairlineColor())
                  .margin({ left: 7, right: 7 })
              }
            }
            .alignItems(VerticalAlign.Center)
          }, (index: number) => `${index}`)
        }
        .width('100%')
        .height(34)
        .justifyContent(FlexAlign.Center)
        .margin({ top: 8 })
        Text(VOICEPRINT_PHRASES[Math.min(this.voiceprintEnrollProgress, 2)])
          .width('100%')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.textColor())
          .textAlign(TextAlign.Center)
          .margin({ top: 4 })
        Text(this.voiceprintEnrollBusy ? '正在采集，请自然连续说出上面的句子' :
          `准备录入第 ${Math.min(this.voiceprintEnrollProgress + 1, 3)} 轮，每轮约 4 秒`)
          .width('100%')
          .fontSize(12)
          .fontColor(this.subTextColor())
          .textAlign(TextAlign.Center)
          .margin({ top: 3 })
        Row() {
          Button(this.voiceprintEnrollBusy ? '正在采集…' :
            (this.voiceprintEnrollProgress >= 3 ? '重新录入' : `采集第 ${this.voiceprintEnrollProgress + 1} 轮`))
            .layoutWeight(1)
            .height(38)
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .backgroundColor(this.voiceprintEnrollBusy || !this.voiceprintModelReady ? '#777D83' : this.accentBlue())
            .borderRadius(19)
            .enabled(!this.voiceprintEnrollBusy && this.voiceprintModelReady)
            .onClick(() => {
              this.captureVoiceprintRound()
            })
          Button('清空本轮')
            .layoutWeight(1)
            .height(38)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.textColor())
            .backgroundColor(this.cardBg())
            .border({ width: 1, color: this.hairlineColor() })
            .borderRadius(19)
            .margin({ left: 10 })
            .enabled(!this.voiceprintEnrollBusy)
            .onClick(() => {
              this.voiceprintEnrollmentSamples = []
              this.voiceprintEnrollProgress = 0
              this.voiceprintStatus = '已清空本次录入进度'
            })
        }
        .width('100%')
        .margin({ top: 8 })
      }
      .width('100%')
      .padding(10)
      .margin({ top: 10 })
      .backgroundColor(this.softPanelBg())
      .border({ width: 1, color: this.hairlineColor() })
      .borderRadius(10)

      Row() {
        Text('授权用户')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.textColor())
          .layoutWeight(1)
        Text(`${this.voiceprintUsers.length}`)
          .fontSize(13)
          .fontColor(this.accentBlue())
      }
      .width('100%')
      .margin({ top: 10 })

      Scroll() {
        Column() {
          if (this.voiceprintUsers.length === 0) {
            Text('还没有授权声纹，请完成上方三轮录入')
              .width('100%')
              .height(60)
              .fontSize(13)
              .fontColor(this.subTextColor())
              .textAlign(TextAlign.Center)
          } else {
            ForEach(this.voiceprintUsers, (user: SpeakerProfile) => {
              Row() {
                Column() {
                  Text(user.name)
                    .width('100%')
                    .fontSize(15)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(this.textColor())
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(`${user.samples} 轮样本 · 仅保存在本机`)
                    .width('100%')
                    .fontSize(11)
                    .fontColor(this.subTextColor())
                    .margin({ top: 3 })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Toggle({ type: ToggleType.Switch, isOn: user.enabled })
                  .selectedColor(this.accentGreen())
                  .onChange((isOn: boolean) => {
                    this.setVoiceprintUserEnabled(user.userId, isOn)
                  })
                Button('删除')
                  .width(66)
                  .height(32)
                  .fontSize(12)
                  .fontColor('#FFFFFF')
                  .backgroundColor(this.warningRed())
                  .borderRadius(16)
                  .margin({ left: 10 })
                  .onClick(() => {
                    this.deleteVoiceprintUser(user.userId)
                  })
              }
              .width('100%')
              .height(58)
              .padding({ left: 14, right: 10 })
              .backgroundColor(this.cardBg())
              .border({ width: 1, color: this.hairlineColor() })
              .borderRadius(8)
              .margin({ bottom: 8 })
            }, (user: SpeakerProfile) => user.userId)
          }
        }
        .width('100%')
      }
      .width('100%')
      .height(84)
      .margin({ top: 6 })
      .scrollBar(BarState.Auto)
    }
    .width(680)
    .height(500)
    .padding(18)
    .backgroundColor(this.cardBg())
    .border({ width: 1.5, color: this.hairlineColor() })
    .borderRadius(22)
  }

  @Builder
  CriticalDialog() {
    Column() {
      Text('关闭报警？')
        .fontSize(28)
        .fontWeight(FontWeight.Bold)
        .fontColor('#762D36')
      Text(`${this.alarmDialogTarget === 'water' ? '水浸' : '烟雾'}异常仍在报警，确认后将通知设备关闭蜂鸣器。`)
        .fontSize(16)
        .fontColor('#865158')
        .textAlign(TextAlign.Center)
        .margin({ top: 14 })
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Text(this.alarmAckText)
        .width('100%')
        .fontSize(13)
        .fontColor('#A25760')
        .textAlign(TextAlign.Center)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 12, bottom: 24 })

      Row() {
        Button('取消')
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .fontColor('#762D36')
          .backgroundColor('#E9B7BB')
          .borderRadius(8)
          .enabled(!this.alarmClearPending)
          .onClick(() => {
            this.showCriticalDialog = false
          })
        Button(this.alarmClearPending ? '等待设备确认' : '关闭报警')
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .backgroundColor('#BE5963')
          .borderRadius(8)
          .margin({ left: 12 })
          .enabled(!this.alarmClearPending)
          .onClick(() => {
            this.requestAlarmClear().catch((err: Error) => {
              console.info(`[ALARM][off-ui-fail] ${err.message}`)
            })
          })
      }
      .width('100%')
    }
    .width(480)
    .padding(28)
    .borderRadius(8)
    .backgroundColor('#F7DCDD')
    .border({ width: 1, color: '#DFA5AA' })
  }

  build() {
    Stack() {
      this.MainShell()

      if (this.showFaceEnrollPanel) {
        Stack({ alignContent: Alignment.Center }) {
          Stack({ alignContent: Alignment.Center }) {
            this.FaceEnrollPanel()
          }
          .width(810)
          .height(410)
        }
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(32, 36, 42, 0.52)')
      }

      if (this.showAcControlPanel) {
        Stack({ alignContent: Alignment.Center }) {
          this.OverviewAcPanel()
        }
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(32, 36, 42, 0.52)')
      }

      if (this.showVoiceprintPanel) {
        Stack({ alignContent: Alignment.Center }) {
          this.VoiceprintPanel()
        }
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(32, 36, 42, 0.58)')
      }

      if (this.showDeviceBindingPanel) {
        Stack({ alignContent: Alignment.Center }) {
          this.DeviceBindingPanel()
        }
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(32, 36, 42, 0.58)')
      }

      if (this.showDeviceStatusPanel) {
        Stack({ alignContent: Alignment.Center }) {
          this.DeviceStatusPanel()
        }
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(32, 36, 42, 0.58)')
      }

      if (this.showProvisioningPanel) {
        Stack({ alignContent: Alignment.Center }) {
          this.ProvisioningPanel()
        }
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(32, 36, 42, 0.52)')
      }

      if (this.showProvisioningOutputPanel) {
        Stack({ alignContent: Alignment.Center }) {
          this.ProvisioningOutputPanel()
        }
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(32, 36, 42, 0.68)')
      }

      if (this.showIrLearnPanel) {
        Stack({ alignContent: Alignment.Center }) {
          this.IrLearningPanel()
        }
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(32, 36, 42, 0.58)')
      }

      if (this.showDebugPanel) {
        Stack({ alignContent: Alignment.Center }) {
          this.DebugInfoPanel()
        }
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(32, 36, 42, 0.52)')
      }

      if (this.showCriticalDialog) {
        Stack({ alignContent: Alignment.Center }) {
          this.CriticalDialog()
        }
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(94, 34, 42, 0.34)')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageBg())
  }
}
