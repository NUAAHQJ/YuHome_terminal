const net = require('net')
const tls = require('tls')
const http = require('http')
const https = require('https')
const os = require('os')
const dgram = require('dgram')
const crypto = require('crypto')
const fs = require('fs')
const path = require('path')
const aedes = require('aedes')()
const { WebSocket, WebSocketServer } = require('ws')

const RUNTIME_LOG_PATH = path.join(__dirname, 'broker-runtime.log')
const originalConsoleLog = console.log.bind(console)
console.log = (...args) => {
  const line = args.map((item) => {
    if (typeof item === 'string') {
      return item
    }
    try {
      return JSON.stringify(item)
    } catch (_) {
      return String(item)
    }
  }).join(' ')
  originalConsoleLog(line)
  try {
    fs.appendFileSync(RUNTIME_LOG_PATH, `[${new Date().toISOString()}] ${line}\n`)
  } catch (_) {
    // Keep broker running even if file logging fails.
  }
}

const MQTT_PORT = Number(process.env.MQTT_PORT || 1883)
const MQTT_TLS_PORT = Number(process.env.MQTT_TLS_PORT || 8883)
const ESP32_MQTT_TLS_PORT = Number(process.env.ESP32_MQTT_TLS_PORT || 8884)
const HTTP_PORT = Number(process.env.BRIDGE_PORT || 3000)
const HTTPS_PORT = Number(process.env.BRIDGE_HTTPS_PORT || 3444)
const BRIDGE_TLS_PORT = Number(process.env.BRIDGE_TLS_PORT || 3443)
const HOST = process.env.MQTT_HOST || '0.0.0.0'
const TLS_ENABLED = process.env.MQTT_TLS_DISABLED !== '1'
const TLS_CERT_DIR = process.env.MQTT_TLS_CERT_DIR || path.join(__dirname, 'certs')
const CLOUD_API_BASE = process.env.CLOUD_API_BASE || 'https://occupation-customise-dozen-frontier.trycloudflare.com'
const CLOUD_COMMAND_POLL_ENABLED = process.env.CLOUD_COMMAND_POLL_ENABLED === '1'
const CLOUD_COMMAND_POLL_INTERVAL = Number(process.env.CLOUD_COMMAND_POLL_INTERVAL || 2500)
const TLS_KEY_PATH = process.env.MQTT_TLS_KEY || path.join(TLS_CERT_DIR, 'server.key')
const TLS_CERT_PATH = process.env.MQTT_TLS_CERT || path.join(TLS_CERT_DIR, 'server.crt')
const TLS_CA_PATH = process.env.MQTT_TLS_CA || path.join(TLS_CERT_DIR, 'ca.crt')
const BEACON_PORT = Number(process.env.BEACON_PORT || 1346)
const BEACON_INTERVAL = Number(process.env.BEACON_INTERVAL || 5000)
const BEACON_ENABLED = process.env.BEACON_DISABLED !== '1'
const ESP32_UDP_RELAY_PORT = Number(process.env.ESP32_UDP_RELAY_PORT || 1351)
const DAYU_UDP_PORT = Number(process.env.DAYU_UDP_PORT || 1346)
const DAYU_TLS_CLIENT_CN = process.env.DAYU_TLS_CLIENT_CN || 'dayu_gateway_001'
let beaconTimer = null
const mqttServer = net.createServer(aedes.handle)
const tlsOptions = loadTlsOptions(false)
const mutualTlsOptions = loadTlsOptions(true)
const mqttTlsServer = mutualTlsOptions ? tls.createServer(mutualTlsOptions, handleMqttMutualTlsSocket) : null
const esp32MqttTlsServer = tlsOptions ? tls.createServer(tlsOptions, aedes.handle) : null
const bridgeTlsServer = mutualTlsOptions ? https.createServer(mutualTlsOptions) : null
const bridgeWebSocketServer = bridgeTlsServer ? new WebSocketServer({ noServer: true }) : null
const httpsBridgeServer = tlsOptions ? https.createServer(tlsOptions, handleHttpRequest) : null
const esp32UdpRelayServer = dgram.createSocket({ type: 'udp4' })
const bridgeClients = new Set()
const pendingDayuEcdhPublicKeys = new Map()
const mqttClients = new Set()
const mqttTopicSubscriptions = new Map()
const httpCommandQueues = new Map()
const DAYU_ECDH_MARK_TTL_MS = 10000
const ECDH_PUBLIC_KEY_CACHE_TTL_MS = Number(process.env.ECDH_PUBLIC_KEY_CACHE_TTL_MS || 24 * 60 * 60 * 1000)
const HTTP_COMMAND_QUEUE_LIMIT = 20
const HTTP_PROTO_COMMAND_TTL_MS = 10000

function ecdhMessageKey(topic, payloadBuffer) {
  return `${topic}:${payloadBuffer.toString('base64')}`
}

function isKeyExchangePublicKey(topic, payloadBuffer) {
  return (topic === TOPIC_KEY_ECDH || topic.startsWith(TOPIC_KEY_ECDH_PREFIX)) &&
    Buffer.isBuffer(payloadBuffer) &&
    payloadBuffer.length === 65
}

function rememberDayuEcdhPublicKey(topic, payloadBuffer) {
  pendingDayuEcdhPublicKeys.set(ecdhMessageKey(topic, payloadBuffer), Date.now())
  setTimeout(() => {
    pendingDayuEcdhPublicKeys.delete(ecdhMessageKey(topic, payloadBuffer))
  }, DAYU_ECDH_MARK_TTL_MS)
}

const TOPIC_SENSOR_INDOOR = 'smart_home/esp32/sensor/indoor'
const TOPIC_SENSOR_LEGACY = 'esp32/sensor'
const TOPIC_STATUS = 'esp32/status'
const TOPIC_AC = 'esp32/ac'
const TOPIC_LIGHT_STATUS = 'smart_home/esp32/light/status'
const TOPIC_LIGHT_SET = 'smart_home/esp32/light/set'
const TOPIC_DAYU_CMD = 'dayu/cmd'                    // 澶х 鈫?ESP32 鎺у埗鎸囦护
const TOPIC_KEY_ECDH = 'key/ecdh/pub'                 // ECDH 瀵嗛挜鍗忓晢
const TOPIC_KEY_ECDH_PREFIX = 'key/ecdh/pub/'
const AES_KEY_RAW = Buffer.from([
  0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
  0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
  0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
  0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F
])
const SM4_KEY_RAW = Buffer.from([
  0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF,
  0xFE, 0xDC, 0xBA, 0x98, 0x76, 0x54, 0x32, 0x10
])
const HAS_SM4_ECB = crypto.getCiphers().includes('sm4-ecb')

function loadTlsOptions(requireClientCertificate) {
  if (!TLS_ENABLED) {
    console.log('[MQTTS] TLS disabled by MQTT_TLS_DISABLED=1')
    return null
  }
  const missing = [TLS_KEY_PATH, TLS_CERT_PATH, TLS_CA_PATH].filter((filePath) => !fs.existsSync(filePath))
  if (missing.length > 0) {
    console.log(`[MQTTS] TLS cert files missing, mqtts disabled: ${missing.join(', ')}`)
    console.log('[MQTTS] Generate certs under ./certs first, then restart broker.')
    return null
  }
  return {
    key: fs.readFileSync(TLS_KEY_PATH),
    cert: fs.readFileSync(TLS_CERT_PATH),
    ca: fs.readFileSync(TLS_CA_PATH),
    minVersion: 'TLSv1.2',
    requestCert: requireClientCertificate,
    rejectUnauthorized: requireClientCertificate
  }
}

function authorizeDayuMutualTlsSocket(socket, channel) {
  const peer = socket.getPeerCertificate()
  const commonName = peer && peer.subject ? peer.subject.CN : ''
  if (!socket.authorized || commonName !== DAYU_TLS_CLIENT_CN) {
    console.log(`[${channel}][mTLS] rejected authorized=${socket.authorized} cn=${commonName || '-'} error=${socket.authorizationError || '-'}`)
    socket.destroy()
    return false
  }
  console.log(`[${channel}][mTLS] authenticated cn=${commonName} fingerprint=${peer.fingerprint256 || peer.fingerprint || '-'}`)
  return true
}

function handleMqttMutualTlsSocket(socket) {
  if (authorizeDayuMutualTlsSocket(socket, 'MQTTS')) {
    aedes.handle(socket)
  }
}

if (bridgeTlsServer && bridgeWebSocketServer) {
  bridgeTlsServer.on('upgrade', (request, socket, head) => {
    if (!authorizeDayuMutualTlsSocket(socket, 'BridgeWSS')) {
      return
    }
    bridgeWebSocketServer.handleUpgrade(request, socket, head, (webSocket) => {
      bridgeWebSocketServer.emit('connection', webSocket, request)
    })
  })
  bridgeWebSocketServer.on('connection', handleBridgeWebSocket)
}

function isVirtualInterface(name) {
  return /vmware|virtualbox|hyper-v|vethernet|loopback|npcap/i.test(name)
}

function isPreferredInterface(name) {
  return /wlan|wi-?fi|wireless|鏃犵嚎/i.test(name)
}

function sortLanInterfaces(left, right) {
  const leftPreferred = isPreferredInterface(left.name) ? 0 : 1
  const rightPreferred = isPreferredInterface(right.name) ? 0 : 1
  if (leftPreferred !== rightPreferred) {
    return leftPreferred - rightPreferred
  }
  return left.name.localeCompare(right.name)
}

const state = {
  sensor: {
    temperature: 24.6,
    humidity: 48,
    alertLevel: 0,
    message: '等待 ESP32 上报传感器数据'
  },
  light: {
    living: false,
    bedroom: false,
    pirEnabled: true
  },
  udpRelay: {
    receivedCount: 0,
    lastFrom: '',
    lastMessage: '',
    lastTime: 0
  },
  encrypted: {
    enabled: false,
    lastRawBase64: '',
    lastRawTime: 0,
    lastPlainText: '',
    lastTopic: '',
  },
  httpSensor: {
    enabled: false,
    lastRawBase64: '',
    lastRawTime: 0,
    lastTopic: '',
    deviceId: '',
    crypto: '',
    packets: [],
  },
  keyExchange: {
    pending: false,
    topic: '',
    payloadBase64: '',
    timestamp: 0,
    devices: {}
  },
  httpCommand: {
    lastQueuedTime: 0,
    lastDeviceId: '',
    lastTopic: '',
    lastBytes: 0,
    lastDeliveredTime: 0,
    lastDeliveredDeviceId: '',
    lastDeliveredTopic: '',
    lastDeliveredBytes: 0,
    lastEmptyPollTime: 0,
    lastEmptyPollDeviceId: ''
  },
  lastMessage: 'Bridge 已启动，等待 MQTT 消息'
}

function getLanAddresses() {
  const interfaces = os.networkInterfaces()
  const addresses = []
  Object.keys(interfaces).forEach((name) => {
    if (isVirtualInterface(name)) {
      return
    }
    interfaces[name]
      .filter((item) => item.family === 'IPv4' && !item.internal)
      .forEach((item) => addresses.push({ name, address: item.address }))
  })
  return addresses.sort(sortLanInterfaces)
}

// Calculate each LAN interface broadcast address.
function getBroadcastAddresses() {
  const interfaces = os.networkInterfaces()
  const result = []
  Object.keys(interfaces).forEach((name) => {
    if (isVirtualInterface(name)) {
      return
    }
    interfaces[name]
      .filter((item) => item.family === 'IPv4' && !item.internal && item.netmask)
      .forEach((item) => {
        const addrParts = item.address.split('.').map(Number)
        const maskParts = item.netmask.split('.').map(Number)
        // 骞挎挱鍦板潃 = IP | (~瀛愮綉鎺╃爜)
        const broadcast = addrParts.map((octet, i) => (octet | (~maskParts[i] & 0xFF))).join('.')
        result.push({ name, address: item.address, broadcast })
      })
  })
  return result.sort(sortLanInterfaces)
}

// UDP 骞挎挱淇℃爣锛氬悜灞€鍩熺綉鎵€鏈夎澶囧鍛?Broker 鍦板潃
function sendUdpBeacon() {
  const beacons = getBroadcastAddresses()
  if (beacons.length === 0) {
    console.log('[Beacon] no LAN broadcast address found, skipping')
    return
  }

  const socket = dgram.createSocket({ type: 'udp4' })

  beacons.forEach(({ name, address, broadcast }) => {
    const payload = JSON.stringify({
      type: 'beacon',
      broker_ip: address,
      mqtt_port: MQTT_PORT,
      mqtt_tls_port: mqttTlsServer ? MQTT_TLS_PORT : 0,
      esp32_mqtt_tls_port: esp32MqttTlsServer ? ESP32_MQTT_TLS_PORT : 0,
      bridge_tls_port: bridgeTlsServer ? BRIDGE_TLS_PORT : 0,
      http_port: HTTP_PORT,
      https_port: httpsBridgeServer ? HTTPS_PORT : 0,
      hostname: os.hostname(),
      interface: name,
      timestamp: Date.now()
    })

    socket.send(payload, BEACON_PORT, broadcast, (err) => {
      if (err) {
        console.log(`[Beacon] send to ${broadcast}:${BEACON_PORT} failed: ${err.message}`)
      } else {
        console.log(`[Beacon] sent ${address} to ${broadcast}:${BEACON_PORT} (${name})`)
      }
    })
  })

  // Close the temporary socket after beacon send.
  setTimeout(() => {
    try { socket.close() } catch (_) { /* ignore */ }
  }, 500)
}

function forwardUdpToDayu(message, remote) {
  const targets = getBroadcastAddresses()
  if (targets.length === 0) {
    targets.push({ name: 'fallback', address: '0.0.0.0', broadcast: '255.255.255.255' })
  }

  const sender = dgram.createSocket({ type: 'udp4' })
  let pending = targets.length

  const closeWhenDone = () => {
    pending -= 1
    if (pending <= 0) {
      try { sender.close() } catch (_) { /* ignore */ }
    }
  }

  sender.on('error', (err) => {
    console.log(`[UDP-in] forward socket error: ${err.message}`)
    try { sender.close() } catch (_) { /* ignore */ }
  })

  sender.bind(() => {
    sender.setBroadcast(true)
    targets.forEach(({ name, broadcast }) => {
      sender.send(message, DAYU_UDP_PORT, broadcast, (err) => {
        if (err) {
          console.log(`[UDP-in] ${remote.address}:${remote.port} -> ${broadcast}:${DAYU_UDP_PORT} failed: ${err.message}`)
        } else {
          console.log(`[UDP-in] ${remote.address}:${remote.port} -> ${broadcast}:${DAYU_UDP_PORT} (${name}): ${message.toString().trim()}`)
        }
        closeWhenDone()
      })
    })
  })
}

function getEncryptedBridgeState() {
  if (state.encrypted.enabled &&
    state.encrypted.lastTopic &&
    state.encrypted.lastTopic.startsWith(TOPIC_KEY_ECDH_PREFIX) &&
    Date.now() - state.encrypted.lastRawTime > ECDH_PUBLIC_KEY_CACHE_TTL_MS) {
    return { enabled: false }
  }
  return state.encrypted.enabled ? {
    enabled: true,
    payloadBase64: state.encrypted.lastRawBase64,
    timestamp: state.encrypted.lastRawTime,
    topic: state.encrypted.lastTopic
  } : { enabled: false }
}

function getHttpSensorBridgeState() {
  return state.httpSensor.enabled ? {
    enabled: true,
    payloadBase64: state.httpSensor.lastRawBase64,
    timestamp: state.httpSensor.lastRawTime,
    topic: state.httpSensor.lastTopic,
    deviceId: state.httpSensor.deviceId,
    crypto: state.httpSensor.crypto,
    packets: state.httpSensor.packets
  } : { enabled: false }
}

function getHttpCommandBridgeState() {
  const queues = {}
  httpCommandQueues.forEach((queue, deviceId) => {
    queues[deviceId] = queue.map((item) => ({
      id: item.id,
      topic: item.topic,
      bytes: item.bytes,
      timestamp: item.timestamp,
      ageMs: Math.max(0, Date.now() - item.timestamp)
    }))
  })
  return {
    ...state.httpCommand,
    queues
  }
}

function getBridgeSnapshot() {
  return {
    ok: true,
    message: state.lastMessage,
    state,
    encrypted: getEncryptedBridgeState(),
    httpSensor: getHttpSensorBridgeState(),
    httpCommand: getHttpCommandBridgeState(),
    keyExchange: getKeyExchangeState()
  }
}

function rememberEncryptedPayload(topic, payloadBuffer, source, tryDecrypt = true) {
  const timestamp = Date.now()
  const transport = source.startsWith('HTTP/') ? 'HTTP' : (source === 'MQTT' ? 'MQTT' : '')
  state.encrypted.enabled = true
  state.encrypted.lastRawBase64 = payloadBuffer.toString('base64')
  state.encrypted.lastRawTime = timestamp
  state.encrypted.lastTopic = topic
  state.encrypted.lastPlainText = '[encrypted]'
  state.lastMessage = `${source} 收到加密数据 ${new Date(timestamp).toLocaleTimeString()} (${payloadBuffer.length}B)`
  console.log(`[Bridge] ${source} encrypted payload on ${topic}: ${payloadBuffer.length} bytes`)
  if (tryDecrypt) {
    applyEncryptedSensorPayload(topic, payloadBuffer)
  }
  if (shouldForwardToBridge(topic)) {
    broadcastBridgeJson({
      type: 'sensor',
      ok: true,
      topic,
      deviceId: deviceIdFromTopic(topic),
      ...(transport.length > 0 ? { transport } : {}),
      source,
      payloadBase64: state.encrypted.lastRawBase64,
      timestamp
    })
  }
  return {
    payloadBase64: state.encrypted.lastRawBase64,
    timestamp
  }
}

function rememberKeyExchangePublicKey(topic, payloadBuffer) {
  pruneKeyExchangePublicKeys()
  const payloadBase64 = payloadBuffer.toString('base64')
  const timestamp = Date.now()
  state.keyExchange.pending = true
  state.keyExchange.topic = topic
  state.keyExchange.payloadBase64 = payloadBase64
  state.keyExchange.timestamp = timestamp
  if (topic.startsWith(TOPIC_KEY_ECDH_PREFIX) && payloadBuffer.length === 65) {
    const deviceId = topic.substring(TOPIC_KEY_ECDH_PREFIX.length)
    if (deviceId.length > 0) {
      state.keyExchange.devices[deviceId] = {
        topic,
        payloadBase64,
        timestamp
      }
    }
  }
}

function clearKeyExchangePublicKey(topic) {
  if (state.keyExchange.pending && state.keyExchange.topic === topic) {
    state.keyExchange.pending = false
    state.keyExchange.topic = ''
    state.keyExchange.payloadBase64 = ''
    state.keyExchange.timestamp = 0
  }
}

function pruneKeyExchangePublicKeys(now = Date.now()) {
  Object.keys(state.keyExchange.devices).forEach((deviceId) => {
    const cached = state.keyExchange.devices[deviceId]
    if (!cached || !cached.timestamp || now - cached.timestamp > ECDH_PUBLIC_KEY_CACHE_TTL_MS) {
      delete state.keyExchange.devices[deviceId]
    }
  })
  if (state.keyExchange.pending && now - state.keyExchange.timestamp > ECDH_PUBLIC_KEY_CACHE_TTL_MS) {
    state.keyExchange.pending = false
    state.keyExchange.topic = ''
    state.keyExchange.payloadBase64 = ''
    state.keyExchange.timestamp = 0
  }
}

function getKeyExchangeState() {
  pruneKeyExchangePublicKeys()
  const result = state.keyExchange.pending ? Object.assign({}, state.keyExchange) : {
    pending: false,
    devices: state.keyExchange.devices
  }
  result.devices = state.keyExchange.devices
  return result
}

function sendBridgeJson(socket, data) {
  if (!socket || socket.readyState !== WebSocket.OPEN) {
    return
  }
  try {
    socket.send(JSON.stringify(data))
  } catch (err) {
    console.log(`[BridgeTLS] send failed: ${err.message}`)
  }
}

function broadcastBridgeJson(data) {
  if (data && data.topic && String(data.topic).startsWith(TOPIC_KEY_ECDH_PREFIX)) {
    console.log(`[BridgeTLS] broadcast ${data.topic} to ${bridgeClients.size} client(s)`)
  }
  bridgeClients.forEach((socket) => {
    sendBridgeJson(socket, data)
  })
}

function publishBridgeCommand(message, socket) {
  const targetTopic = typeof message.topic === 'string' && message.topic.length > 0 ? message.topic : TOPIC_DAYU_CMD
  let mqttPayload

  if (typeof message.payloadBase64 === 'string' && message.payloadBase64.length > 0) {
    mqttPayload = Buffer.from(message.payloadBase64, 'base64')
    console.log(`[BridgeTLS] encrypted cmd -> ${targetTopic}: ${mqttPayload.length} bytes`)
    state.lastMessage = `BridgeTLS 加密指令已转发 (${mqttPayload.length}B)`
  } else if (typeof message.plainText === 'string') {
    mqttPayload = message.plainText
    console.log(`[BridgeTLS] plain cmd -> ${targetTopic}: ${mqttPayload}`)
    state.lastMessage = 'BridgeTLS 明文指令已转发'
  } else {
    sendBridgeJson(socket, { type: 'error', ok: false, message: 'missing payloadBase64 or plainText' })
    return
  }

  if (isKeyExchangePublicKey(targetTopic, mqttPayload)) {
    rememberDayuEcdhPublicKey(targetTopic, mqttPayload)
  }

  aedes.publish({
    topic: targetTopic,
    payload: mqttPayload,
    qos: 1,
    retain: false
  })
  logCommandRoute('BridgeTLS', targetTopic, Buffer.isBuffer(mqttPayload) ? mqttPayload.length : Buffer.byteLength(String(mqttPayload)), 1)

  if (isKeyExchangePublicKey(targetTopic, mqttPayload)) {
    console.log(`[ECDH] Dayu public key relayed by BridgeTLS on ${targetTopic}: ${mqttPayload.length} bytes`)
    clearKeyExchangePublicKey(targetTopic)
  }

  sendBridgeJson(socket, {
    type: 'ack',
    ok: true,
    reqId: message.reqId,
    message: state.lastMessage,
    topic: targetTopic,
    timestamp: Date.now()
  })
}

function handleBridgeJsonLine(socket, line) {
  if (line.length === 0) {
    return
  }

  let message
  try {
    message = JSON.parse(line)
  } catch (err) {
    sendBridgeJson(socket, { type: 'error', ok: false, message: `invalid JSON: ${err.message}` })
    return
  }

  if (message.type === 'state') {
    sendBridgeJson(socket, Object.assign({ type: 'state' }, getBridgeSnapshot()))
    return
  }
  if (message.type === 'ping') {
    sendBridgeJson(socket, { type: 'pong', ok: true, timestamp: Date.now() })
    return
  }
  if (message.type === 'publish') {
    publishBridgeCommand(message, socket)
    return
  }

  sendBridgeJson(socket, { type: 'error', ok: false, message: `unknown type: ${message.type}` })
}

function handleBridgeWebSocket(webSocket, request) {
  const remoteSocket = request.socket
  const remote = `${remoteSocket.remoteAddress || 'unknown'}:${remoteSocket.remotePort || 0}`
  bridgeClients.add(webSocket)
  console.log(`[BridgeWSS] client connected: ${remote}`)

  webSocket.on('message', (data, isBinary) => {
    if (isBinary) {
      sendBridgeJson(webSocket, { type: 'error', ok: false, message: 'binary frames are not supported' })
      return
    }
    const line = data.toString('utf8').trim()
    if (line.length > 1024 * 1024) {
      sendBridgeJson(webSocket, { type: 'error', ok: false, message: 'message too large' })
      return
    }
    handleBridgeJsonLine(webSocket, line)
  })
  webSocket.on('error', (err) => {
    console.log(`[BridgeWSS] client error ${remote}: ${err.message}`)
  })
  webSocket.on('close', () => {
    bridgeClients.delete(webSocket)
    console.log(`[BridgeWSS] client disconnected: ${remote}`)
  })
}

function shouldForwardToBridge(topic) {
  return topic === TOPIC_SENSOR_INDOOR ||
    topic === TOPIC_SENSOR_LEGACY ||
    topic === TOPIC_AC ||
    topic === TOPIC_LIGHT_STATUS ||
    topic === TOPIC_KEY_ECDH ||
    topic.startsWith('device/') ||
    topic.startsWith(TOPIC_KEY_ECDH_PREFIX)
}

function deviceIdFromTopic(topic) {
  const parts = String(topic || '').split('/')
  if (parts.length >= 3 && parts[0] === 'device') {
    return parts[1]
  }
  if (String(topic || '').startsWith(TOPIC_KEY_ECDH_PREFIX)) {
    return String(topic).substring(TOPIC_KEY_ECDH_PREFIX.length)
  }
  return 'esp32'
}

function rememberMqttSubscriptions(subscriptions, client) {
  if (!client || !client.id) {
    return
  }
  subscriptions.forEach((item) => {
    if (!mqttTopicSubscriptions.has(item.topic)) {
      mqttTopicSubscriptions.set(item.topic, new Map())
    }
    mqttTopicSubscriptions.get(item.topic).set(client.id, item.qos)
  })
}

function forgetMqttClient(clientId) {
  mqttClients.delete(clientId)
  mqttTopicSubscriptions.forEach((clients) => {
    clients.delete(clientId)
  })
}

function describeMqttSubscribers(topic) {
  const subscriptions = mqttTopicSubscriptions.get(topic)
  if (!subscriptions || subscriptions.size === 0) {
    return 'none'
  }
  return Array.from(subscriptions.entries()).map(([clientId, qos]) => {
    const online = mqttClients.has(clientId) ? 'online' : 'offline'
    return `${clientId}(qos=${qos},${online})`
  }).join(', ')
}

function logCommandRoute(source, topic, payloadLength, qos) {
  if (topic !== TOPIC_DAYU_CMD) {
    return
  }
  console.log(`[Route] ${source} -> ${topic}: ${payloadLength} bytes qos=${qos}; subscribers=${describeMqttSubscribers(topic)}`)
}

function isLikelyProtocolSwitchCommand(topic, bytes) {
  // {"cmd":"proto","val":"mqtt|http","seq":N} is 36-41B plaintext,
  // and GCM frames add 12B IV + 16B TAG.
  return (topic === TOPIC_DAYU_CMD || topic.startsWith(`${TOPIC_DAYU_CMD}/`)) && bytes >= 64 && bytes <= 69
}

function removeQueuedProtocolSwitches(queue) {
  let removed = 0
  for (let i = queue.length - 1; i >= 0; i -= 1) {
    if (isLikelyProtocolSwitchCommand(queue[i].topic, queue[i].bytes)) {
      queue.splice(i, 1)
      removed += 1
    }
  }
  return removed
}

function dropExpiredProtocolSwitches(queue, targetDevice) {
  const now = Date.now()
  let removed = 0
  for (let i = queue.length - 1; i >= 0; i -= 1) {
    const item = queue[i]
    if (isLikelyProtocolSwitchCommand(item.topic, item.bytes) && now - item.timestamp > HTTP_PROTO_COMMAND_TTL_MS) {
      queue.splice(i, 1)
      removed += 1
    }
  }
  if (removed > 0) {
    console.log(`[HTTP-CMD] dropped ${removed} expired proto command(s) for ${targetDevice}`)
  }
}

function queueHttpCommand(deviceId, topic, payloadBuffer) {
  const targetDevice = deviceId && deviceId.length > 0 ? deviceId : 'esp32'
  const item = {
    id: `${Date.now()}-${Math.random().toString(16).slice(2)}`,
    topic,
    payloadBase64: payloadBuffer.toString('base64'),
    bytes: payloadBuffer.length,
    timestamp: Date.now()
  }
  if (!httpCommandQueues.has(targetDevice)) {
    httpCommandQueues.set(targetDevice, [])
  }
  const queue = httpCommandQueues.get(targetDevice)
  dropExpiredProtocolSwitches(queue, targetDevice)
  if (isLikelyProtocolSwitchCommand(topic, payloadBuffer.length)) {
    const removed = removeQueuedProtocolSwitches(queue)
    if (removed > 0) {
      console.log(`[HTTP-CMD] replaced ${removed} queued proto command(s) for ${targetDevice}`)
    }
  }
  queue.push(item)
  while (queue.length > HTTP_COMMAND_QUEUE_LIMIT) {
    queue.shift()
  }
  state.httpCommand.lastQueuedTime = item.timestamp
  state.httpCommand.lastDeviceId = targetDevice
  state.httpCommand.lastTopic = topic
  state.httpCommand.lastBytes = payloadBuffer.length
  state.lastMessage = `HTTP 指令已入队 ${targetDevice}/${topic} (${payloadBuffer.length}B)`
  console.log(`[HTTP-CMD] queued for ${targetDevice} ${topic}: ${payloadBuffer.length} bytes`)
  return item
}

function isValidDeviceId(deviceId) {
  return typeof deviceId === 'string' && deviceId.length >= 3 && deviceId.length <= 64 &&
    deviceId !== 'auto' && /^[A-Za-z0-9][A-Za-z0-9_-]*$/.test(deviceId)
}

function scopedTopicMatchesDevice(topic, deviceId) {
  if (topic.startsWith('device/')) {
    return deviceIdFromTopic(topic) === deviceId
  }
  if (topic.startsWith(`${TOPIC_DAYU_CMD}/`)) {
    return topic.substring(`${TOPIC_DAYU_CMD}/`.length) === deviceId
  }
  if (topic.startsWith(TOPIC_KEY_ECDH_PREFIX)) {
    return topic.substring(TOPIC_KEY_ECDH_PREFIX.length) === deviceId
  }
  return deviceId === 'esp32'
}

function popHttpCommand(deviceId) {
  const targetDevice = deviceId && deviceId.length > 0 ? deviceId : 'esp32'
  const queue = httpCommandQueues.get(targetDevice)
  if (!queue || queue.length === 0) {
    state.httpCommand.lastEmptyPollTime = Date.now()
    state.httpCommand.lastEmptyPollDeviceId = targetDevice
    return null
  }
  dropExpiredProtocolSwitches(queue, targetDevice)
  if (queue.length === 0) {
    state.httpCommand.lastEmptyPollTime = Date.now()
    state.httpCommand.lastEmptyPollDeviceId = targetDevice
    return null
  }
  return queue.shift()
}

function logHttpCommandDelivery(deviceId, item) {
  const ageMs = Math.max(0, Date.now() - item.timestamp)
  state.httpCommand.lastDeliveredTime = Date.now()
  state.httpCommand.lastDeliveredDeviceId = deviceId
  state.httpCommand.lastDeliveredTopic = item.topic
  state.httpCommand.lastDeliveredBytes = item.bytes
  console.log(`[HTTP-CMD] delivered to ${deviceId} ${item.topic}: ${item.bytes} bytes age=${ageMs}ms`)
}

function maybeReplayCachedEcdhKeys(subscriptions, client) {
  if (!client || !client.id || !client.id.startsWith('dayu_')) {
    return
  }
  const wantsEcdh = subscriptions.some((item) => item.topic === `${TOPIC_KEY_ECDH_PREFIX}+` || item.topic === TOPIC_KEY_ECDH || item.topic.startsWith(TOPIC_KEY_ECDH_PREFIX))
  if (!wantsEcdh) {
    return
  }
  Object.keys(state.keyExchange.devices).forEach((deviceId) => {
    const cached = state.keyExchange.devices[deviceId]
    if (!cached || !cached.topic || !cached.payloadBase64) {
      return
    }
    if (!cached.timestamp || Date.now() - cached.timestamp > ECDH_PUBLIC_KEY_CACHE_TTL_MS) {
      delete state.keyExchange.devices[deviceId]
      return
    }
    const payload = Buffer.from(cached.payloadBase64, 'base64')
    if (payload.length !== 65) {
      return
    }
    setTimeout(() => {
      aedes.publish({
        topic: cached.topic,
        payload,
        qos: 0,
        retain: false
      })
      console.log(`[ECDH] replay cached public key ${cached.topic} to ${client.id}: ${payload.length} bytes`)
    }, 250)
  })
}

aedes.on('client', (client) => {
  if (client && client.id) {
    mqttClients.add(client.id)
  }
  console.log(`[MQTT] client connected: ${client ? client.id : 'unknown'}`)
})

aedes.on('clientDisconnect', (client) => {
  if (client && client.id) {
    forgetMqttClient(client.id)
  }
  console.log(`[MQTT] client disconnected: ${client ? client.id : 'unknown'}`)
})

aedes.on('clientError', (client, err) => {
  console.log(`[MQTT][client-error] ${client ? client.id : 'unknown'}: ${err ? err.message : 'unknown error'}`)
})

aedes.on('connectionError', (client, err) => {
  console.log(`[MQTT][connection-error] ${client ? client.id : 'unknown'}: ${err ? err.message : 'unknown error'}`)
})

aedes.on('subscribe', (subscriptions, client) => {
  rememberMqttSubscriptions(subscriptions, client)
  const topics = subscriptions.map((item) => `${item.topic}(qos=${item.qos})`).join(', ')
  console.log(`[MQTT] ${client ? client.id : 'unknown'} subscribed: ${topics}`)
  maybeReplayCachedEcdhKeys(subscriptions, client)
})

aedes.on('unsubscribe', (subscriptions, client) => {
  if (client && client.id) {
    subscriptions.forEach((topic) => {
      const clients = mqttTopicSubscriptions.get(topic)
      if (clients) {
        clients.delete(client.id)
      }
    })
  }
})

aedes.on('publish', (packet, client) => {
  if (!client || packet.topic.startsWith('$SYS/')) {
    return
  }
  const payloadBuffer = Buffer.from(packet.payload)
  let payloadSummary = `${payloadBuffer.length} bytes`
  if (payloadBuffer.length <= 160 && (payloadBuffer[0] === 0x7B || payloadBuffer[0] === 0x5B)) {
    payloadSummary = payloadBuffer.toString('utf8')
  }
  console.log(`[MQTT] ${client.id} -> ${packet.topic}: ${payloadSummary}`)
  logCommandRoute(`MQTT/${client.id}`, packet.topic, payloadBuffer.length, packet.qos || 0)
  const isDayuEcdhPublicKey = client.id.startsWith('dayu_') && isKeyExchangePublicKey(packet.topic, payloadBuffer)
  if (isDayuEcdhPublicKey) {
    rememberDayuEcdhPublicKey(packet.topic, payloadBuffer)
    console.log(`[ECDH] Dayu public key from ${client.id} on ${packet.topic}; skip broker cache/broadcast`)
    clearKeyExchangePublicKey(packet.topic)
  } else {
    handleMqttPacket(packet.topic, payloadBuffer)
  }
  if (!isDayuEcdhPublicKey && shouldForwardToBridge(packet.topic)) {
    broadcastBridgeJson({
      type: 'sensor',
      ok: true,
      topic: packet.topic,
      deviceId: deviceIdFromTopic(packet.topic),
      transport: 'MQTT',
      source: `MQTT/${client.id}`,
      payloadBase64: payloadBuffer.toString('base64'),
      timestamp: Date.now()
    })
  }
})

function handleMqttPacket(topic, payloadBuffer) {
  if (topic === TOPIC_KEY_ECDH || topic.startsWith(TOPIC_KEY_ECDH_PREFIX)) {
    const dayuKey = ecdhMessageKey(topic, payloadBuffer)
    if (pendingDayuEcdhPublicKeys.has(dayuKey)) {
      pendingDayuEcdhPublicKeys.delete(dayuKey)
      console.log(`[ECDH] skip caching Dayu public key on ${topic}: ${payloadBuffer.length} bytes`)
      return
    }
    state.lastMessage = `鏀跺埌 ECDH 鍏挜 ${new Date().toLocaleTimeString()} (${payloadBuffer.length}B)`
    state.encrypted.enabled = true
    state.encrypted.lastRawBase64 = payloadBuffer.toString('base64')
    state.encrypted.lastRawTime = Date.now()
    state.encrypted.lastTopic = topic
    state.encrypted.lastPlainText = '[ecdh-public-key]'
    rememberKeyExchangePublicKey(topic, payloadBuffer)
    console.log(`[ECDH] public key on ${topic}: ${payloadBuffer.length} bytes`)
    return
  }

  const payloadText = payloadBuffer.toString('utf8')
  // 鍏堝皾璇?JSON 瑙ｆ瀽
  try {
    const data = JSON.parse(payloadText)
    // 鈹€鈹€ 鏄庢枃 JSON 娑堟伅 鈹€鈹€
    if (topic === TOPIC_SENSOR_INDOOR || topic === TOPIC_SENSOR_LEGACY ||
      (topic.startsWith('device/') && topic.endsWith('/sensor'))) {
      const sensor = Object.assign({}, data)
      if (typeof sensor.temp === 'number' && typeof sensor.temperature !== 'number') {
        sensor.temperature = sensor.temp
      }
      if (typeof sensor.hum === 'number' && typeof sensor.humidity !== 'number') {
        sensor.humidity = sensor.hum
      }
      state.sensor = Object.assign({}, state.sensor, sensor)
      state.lastMessage = `鏀跺埌浼犳劅鍣ㄦ暟鎹?${new Date().toLocaleTimeString()}`
      // 鍚屾椂淇濆瓨鏄庢枃鐢ㄤ簬璋冭瘯
      state.encrypted.lastPlainText = payloadText
      state.encrypted.lastRawTime = Date.now()
      state.encrypted.lastTopic = topic
      state.encrypted.lastRawBase64 = ''
      state.encrypted.enabled = false
      return
    }
    if (topic === TOPIC_LIGHT_STATUS) {
      state.light = Object.assign({}, state.light, data)
      state.lastMessage = `鏀跺埌鐓ф槑鐘舵€?${new Date().toLocaleTimeString()}`
    }
  } catch (_) {
    // 鈹€鈹€ 涓嶆槸 JSON锛屼綔涓哄姞瀵嗕簩杩涘埗 payload 澶勭悊 鈹€鈹€
    if (topic === TOPIC_STATUS || (topic.startsWith('device/') && topic.endsWith('/status'))) {
      state.lastMessage = `收到 ESP32 status ${new Date().toLocaleTimeString()} (${payloadBuffer.length}B)`
      console.log(`[MQTT] encrypted status on ${topic}: ${payloadBuffer.length} bytes (not cached)`)
      return
    }
    rememberEncryptedPayload(topic, payloadBuffer, 'MQTT', false)
  }
}

function decryptAesGcm(payloadBuffer) {
  if (payloadBuffer.length < 29) {
    throw new Error(`encrypted payload too short: ${payloadBuffer.length}B`)
  }

  const iv = payloadBuffer.subarray(0, 12)
  const tag = payloadBuffer.subarray(12, 28)
  const ciphertext = payloadBuffer.subarray(28)
  const decipher = crypto.createDecipheriv('aes-256-gcm', AES_KEY_RAW, iv)
  decipher.setAuthTag(tag)
  return Buffer.concat([decipher.update(ciphertext), decipher.final()]).toString('utf8')
}

function sm4EncryptBlock(block) {
  if (!HAS_SM4_ECB) {
    throw new Error('Node/OpenSSL does not provide sm4-ecb')
  }
  const cipher = crypto.createCipheriv('sm4-ecb', SM4_KEY_RAW, null)
  cipher.setAutoPadding(false)
  return Buffer.concat([cipher.update(block), cipher.final()])
}

function xorBlock(left, right) {
  const out = Buffer.alloc(16)
  for (let i = 0; i < 16; i += 1) {
    out[i] = left[i] ^ right[i]
  }
  return out
}

function getBit(buffer, bitIndex) {
  return (buffer[Math.floor(bitIndex / 8)] >>> (7 - (bitIndex % 8))) & 1
}

function shiftRightOne(buffer) {
  const out = Buffer.alloc(16)
  let carry = 0
  for (let i = 0; i < 16; i += 1) {
    const value = buffer[i]
    out[i] = ((value >>> 1) | carry) & 0xff
    carry = (value & 1) === 1 ? 0x80 : 0
  }
  return out
}

function galoisMultiply(x, y) {
  let z = Buffer.alloc(16)
  let v = Buffer.from(y)
  for (let i = 0; i < 128; i += 1) {
    if (getBit(x, i) === 1) {
      z = xorBlock(z, v)
    }
    const lsbSet = (v[15] & 1) === 1
    v = shiftRightOne(v)
    if (lsbSet) {
      v[0] ^= 0xe1
    }
  }
  return z
}

function ghash(h, ciphertext) {
  let y = Buffer.alloc(16)
  for (let offset = 0; offset < ciphertext.length; offset += 16) {
    const block = Buffer.alloc(16)
    ciphertext.copy(block, 0, offset, Math.min(offset + 16, ciphertext.length))
    y = galoisMultiply(xorBlock(y, block), h)
  }
  const lengthBlock = Buffer.alloc(16)
  lengthBlock.writeBigUInt64BE(0n, 0)
  lengthBlock.writeBigUInt64BE(BigInt(ciphertext.length) * 8n, 8)
  return galoisMultiply(xorBlock(y, lengthBlock), h)
}

function incrementCounter(counter) {
  for (let i = 15; i >= 12; i -= 1) {
    counter[i] = (counter[i] + 1) & 0xff
    if (counter[i] !== 0) {
      return
    }
  }
}

function sm4CtrCrypt(input, j0) {
  const output = Buffer.alloc(input.length)
  const counter = Buffer.from(j0)
  for (let offset = 0; offset < input.length; offset += 16) {
    incrementCounter(counter)
    const stream = sm4EncryptBlock(counter)
    const blockLength = Math.min(16, input.length - offset)
    for (let i = 0; i < blockLength; i += 1) {
      output[offset + i] = input[offset + i] ^ stream[i]
    }
  }
  return output
}

function randomIv() {
  return crypto.randomBytes(12)
}

function encryptSm4Gcm(plaintext) {
  const iv = randomIv()
  const input = Buffer.from(plaintext, 'utf8')
  const h = sm4EncryptBlock(Buffer.alloc(16))
  const j0 = Buffer.alloc(16)
  iv.copy(j0, 0)
  j0[15] = 1
  const ciphertext = sm4CtrCrypt(input, j0)
  const tag = xorBlock(sm4EncryptBlock(j0), ghash(h, ciphertext))
  return Buffer.concat([iv, tag, ciphertext])
}

function decryptSm4Gcm(payloadBuffer) {
  if (payloadBuffer.length < 29) {
    throw new Error(`encrypted payload too short: ${payloadBuffer.length}B`)
  }

  const iv = payloadBuffer.subarray(0, 12)
  const tag = payloadBuffer.subarray(12, 28)
  const ciphertext = payloadBuffer.subarray(28)
  const h = sm4EncryptBlock(Buffer.alloc(16))
  const j0 = Buffer.alloc(16)
  iv.copy(j0, 0)
  j0[15] = 1
  const expectedTag = xorBlock(sm4EncryptBlock(j0), ghash(h, ciphertext))
  if (!crypto.timingSafeEqual(tag, expectedTag)) {
    throw new Error('SM4-GCM auth tag mismatch')
  }
  return sm4CtrCrypt(ciphertext, j0).toString('utf8')
}

function decryptSensorPayload(payloadBuffer) {
  const attempts = []
  for (const mode of ['SM4', 'AES']) {
    try {
      const plaintext = mode === 'SM4' ? decryptSm4Gcm(payloadBuffer) : decryptAesGcm(payloadBuffer)
      return { plaintext, mode }
    } catch (err) {
      attempts.push(`${mode}:${err.message}`)
    }
  }
  throw new Error(attempts.join('; '))
}

function normalizeSensorPacket(data) {
  const sensor = Object.assign({}, data)
  if (typeof sensor.temp === 'number' && typeof sensor.temperature !== 'number') {
    sensor.temperature = sensor.temp
  }
  if (typeof sensor.hum === 'number' && typeof sensor.humidity !== 'number') {
    sensor.humidity = sensor.hum
  }
  return sensor
}

function applyEncryptedSensorPayload(topic, payloadBuffer) {
  if (topic !== TOPIC_SENSOR_INDOOR && topic !== TOPIC_SENSOR_LEGACY) {
    return
  }

  try {
    const { plaintext, mode } = decryptSensorPayload(payloadBuffer)
    const data = JSON.parse(plaintext)
    const sensor = normalizeSensorPacket(data)
    state.sensor = Object.assign({}, state.sensor, sensor, {
      message: data.message || `鏀跺埌鍔犲瘑浼犳劅鍣ㄦ暟鎹?${new Date().toLocaleTimeString()}`
    })
    state.encrypted.lastPlainText = plaintext
    state.lastMessage = `鏀跺埌鍔犲瘑浼犳劅鍣ㄦ暟鎹?${new Date().toLocaleTimeString()}`
    const tempText = typeof sensor.temperature === 'number' ? sensor.temperature.toFixed(1) : 'n/a'
    const humText = typeof sensor.humidity === 'number' ? sensor.humidity.toFixed(1) : 'n/a'
    console.log(`[Bridge] encrypted sensor decrypted (${mode}): temp=${tempText} hum=${humText}`)
  } catch (err) {
    console.log(`[Bridge] encrypted sensor decrypt failed: ${err.message}`)
  }
}

function readRequestBody(req) {
  return new Promise((resolve, reject) => {
    let body = ''
    req.on('data', (chunk) => {
      body += chunk.toString()
      if (body.length > 1024 * 1024) {
        req.destroy()
        reject(new Error('request body too large'))
      }
    })
    req.on('end', () => resolve(body))
    req.on('error', reject)
  })
}

function sendJson(res, statusCode, data) {
  const body = JSON.stringify(data)
  res.writeHead(statusCode, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    'Connection': 'close',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type'
  })
  res.end(body)
}

function publishLightControl(control) {
  const payload = JSON.stringify(control)
  // 鍚屾椂鍙戝竷鍒颁富 topic 鍜屽吋瀹瑰埆鍚?topic锛岀‘淇?ESP32 鏃犺璁㈤槄鍝釜閮借兘鏀跺埌
  const publishTargets = [TOPIC_LIGHT_SET, 'dayu/cmd']
  publishTargets.forEach((topic) => {
    aedes.publish({
      topic,
      payload,
      qos: 1,
      retain: false
    })
    console.log(`[Bridge] HTTP -> ${topic}: ${payload}`)
  })
}

async function handleHttpRequest(req, res) {
  if (req.url !== '/api/state') {
    console.log(`[HTTP] ${req.method} ${req.url} from ${req.socket.remoteAddress}:${req.socket.remotePort}`)
  }
  if (req.method === 'OPTIONS') {
    sendJson(res, 200, { ok: true })
    return
  }

  if (req.method === 'GET' && req.url === '/api/state') {
    sendJson(res, 200, {
      ok: true,
      message: state.lastMessage,
      state,
      // 鍔犲瘑閫氫俊瀛楁 鈥?澶х绔粠姝ゅ瓧娈佃幏鍙栧姞瀵?payload
      encrypted: state.encrypted.enabled ? {
        enabled: true,
        payloadBase64: state.encrypted.lastRawBase64,
        timestamp: state.encrypted.lastRawTime,
        topic: state.encrypted.lastTopic
      } : { enabled: false },
      httpSensor: getHttpSensorBridgeState(),
      httpCommand: getHttpCommandBridgeState(),
      keyExchange: getKeyExchangeState()
    })
    return
  }

  if (req.method === 'POST' && req.url === '/api/light/control') {
    try {
      const body = await readRequestBody(req)
      const control = JSON.parse(body)
      if (typeof control.target !== 'string' || typeof control.power !== 'boolean') {
        sendJson(res, 400, { ok: false, message: 'target or power format invalid', state })
        return
      }
      state.light[control.target] = control.power
      state.lastMessage = `已发送照明控制 ${control.target}=${control.power}`
      publishLightControl({
        target: control.target,
        power: control.power,
        timestamp: control.timestamp || Date.now()
      })
      sendJson(res, 200, {
        ok: true,
        message: '控制已发送到 MQTT',
        state
      })
    } catch (err) {
      sendJson(res, 500, { ok: false, message: err.message, state })
    }
    return
  }

  // ESP32 -> Broker HTTP encrypted sensor bridge.
  // Body: { deviceId, topic, payloadBase64, crypto }
  if (req.method === 'POST' && req.url === '/api/http/sensor') {
    try {
      const body = await readRequestBody(req)
      const message = JSON.parse(body)
      const topic = typeof message.topic === 'string' && message.topic.length > 0 ? message.topic : TOPIC_SENSOR_LEGACY
      const deviceId = typeof message.deviceId === 'string' ? message.deviceId : 'esp32'
      const cryptoMode = typeof message.crypto === 'string' ? message.crypto : 'unknown'

      if (!isValidDeviceId(deviceId)) {
        sendJson(res, 400, { ok: false, message: 'invalid or unresolved deviceId' })
        return
      }
      if (!scopedTopicMatchesDevice(topic, deviceId)) {
        sendJson(res, 400, { ok: false, message: 'topic/deviceId mismatch' })
        return
      }

      if (typeof message.payloadBase64 !== 'string' || message.payloadBase64.length === 0) {
        sendJson(res, 400, { ok: false, message: 'missing payloadBase64' })
        return
      }

      const payloadBuffer = Buffer.from(message.payloadBase64, 'base64')
      if (payloadBuffer.length < 29) {
        sendJson(res, 400, { ok: false, message: `encrypted payload too short: ${payloadBuffer.length}B` })
        return
      }

      if (isKeyExchangePublicKey(topic, payloadBuffer)) {
        rememberKeyExchangePublicKey(topic, payloadBuffer)
      }
      const remembered = rememberEncryptedPayload(topic, payloadBuffer, `HTTP/${deviceId}/${cryptoMode}`, false)
      state.httpSensor.enabled = true
      state.httpSensor.lastRawBase64 = remembered.payloadBase64
      state.httpSensor.lastRawTime = remembered.timestamp
      state.httpSensor.lastTopic = topic
      state.httpSensor.deviceId = deviceId
      state.httpSensor.crypto = cryptoMode
      state.httpSensor.packets.push({
        payloadBase64: remembered.payloadBase64,
        timestamp: remembered.timestamp,
        topic,
        deviceId,
        crypto: cryptoMode,
        bytes: payloadBuffer.length
      })
      while (state.httpSensor.packets.length > 30) {
        state.httpSensor.packets.shift()
      }
      sendJson(res, 200, {
        ok: true,
        message: state.lastMessage,
        topic,
        deviceId,
        crypto: cryptoMode,
        bytes: payloadBuffer.length,
        timestamp: remembered.timestamp
      })
    } catch (err) {
      sendJson(res, 500, { ok: false, message: err.message })
    }
    return
  }

  // Dayu -> Broker HTTP command queue. ESP32 should poll /api/http/command?deviceId=esp32
  // while protocol mode is HTTP. This does not publish to MQTT.
  if (req.method === 'POST' && req.url === '/api/http/command') {
    try {
      const body = await readRequestBody(req)
      const cmd = JSON.parse(body)
      const targetTopic = typeof cmd.topic === 'string' && cmd.topic.length > 0 ? cmd.topic : TOPIC_DAYU_CMD
      const deviceId = typeof cmd.deviceId === 'string' && cmd.deviceId.length > 0 ? cmd.deviceId : 'esp32'

      if (!isValidDeviceId(deviceId)) {
        sendJson(res, 400, { ok: false, message: 'invalid deviceId' })
        return
      }
      if (!scopedTopicMatchesDevice(targetTopic, deviceId)) {
        sendJson(res, 400, { ok: false, message: 'topic/deviceId mismatch' })
        return
      }

      if (typeof cmd.payloadBase64 !== 'string' || cmd.payloadBase64.length === 0) {
        const item = popHttpCommand(deviceId)
        if (!item) {
          sendJson(res, 200, { ok: true, hasCommand: false, deviceId })
          return
        }
        logHttpCommandDelivery(deviceId, item)
        sendJson(res, 200, {
          ok: true,
          hasCommand: true,
          deviceId,
          commandId: item.id,
          topic: item.topic,
          payloadBase64: item.payloadBase64,
          bytes: item.bytes,
          timestamp: item.timestamp
        })
        return
      }

      const payloadBuffer = Buffer.from(cmd.payloadBase64, 'base64')
      if (isKeyExchangePublicKey(targetTopic, payloadBuffer)) {
        rememberDayuEcdhPublicKey(targetTopic, payloadBuffer)
      }
      const queued = queueHttpCommand(deviceId, targetTopic, payloadBuffer)
      sendJson(res, 200, {
        ok: true,
        message: state.lastMessage,
        deviceId,
        topic: targetTopic,
        bytes: payloadBuffer.length,
        commandId: queued.id,
        timestamp: queued.timestamp
      })
    } catch (err) {
      sendJson(res, 500, { ok: false, message: err.message })
    }
    return
  }

  if (req.method === 'GET' && req.url.startsWith('/api/http/command')) {
    try {
      let deviceId = 'esp32'
      if (req.method === 'GET') {
        const parsedUrl = new URL(req.url, `http://${req.headers.host || 'broker.invalid'}`)
        deviceId = parsedUrl.searchParams.get('deviceId') || 'esp32'
      } else {
        const body = await readRequestBody(req)
        if (body.length > 0) {
          const reqData = JSON.parse(body)
          if (typeof reqData.deviceId === 'string' && reqData.deviceId.length > 0) {
            deviceId = reqData.deviceId
          }
        }
      }
      if (!isValidDeviceId(deviceId)) {
        sendJson(res, 400, { ok: false, message: 'invalid deviceId' })
        return
      }
      const item = popHttpCommand(deviceId)
      if (!item) {
        sendJson(res, 200, { ok: true, hasCommand: false, deviceId })
        return
      }
      logHttpCommandDelivery(deviceId, item)
      sendJson(res, 200, {
        ok: true,
        hasCommand: true,
        deviceId,
        commandId: item.id,
        topic: item.topic,
        payloadBase64: item.payloadBase64,
        bytes: item.bytes,
        timestamp: item.timestamp
      })
    } catch (err) {
      sendJson(res, 500, { ok: false, message: err.message })
    }
    return
  }

  // UDP 杞彂锛氭帴鏀?Dayu210 娑堟伅锛孭C 绔?socket 鏉冮檺瀹屾暣鍙彂骞挎挱
  if (req.method === 'POST' && req.url === '/api/udp/send') {
    try {
      const body = await readRequestBody(req)
      const reqData = JSON.parse(body)
      const message = reqData.message || ''
      const targetBroadcast = reqData.broadcast || '255.255.255.255'
      const targetPort = Number(reqData.port) || 1350

      const udpSocket = dgram.createSocket({ type: 'udp4' })
      udpSocket.bind(() => {
        udpSocket.setBroadcast(true)
        udpSocket.send(message, targetPort, targetBroadcast, (err) => {
          udpSocket.close()
          if (err) {
            console.log(`[UDP-relay] send to ${targetBroadcast}:${targetPort} failed: ${err.message}`)
            sendJson(res, 500, { ok: false, message: err.message })
          } else {
            console.log(`[UDP-relay] sent "${message}" to ${targetBroadcast}:${targetPort}`)
            sendJson(res, 200, { ok: true, message: `已发送到 ${targetBroadcast}:${targetPort}` })
          }
        })
      })
    } catch (err) {
      sendJson(res, 500, { ok: false, message: err.message })
    }
    return
  }

  // Dayu -> ESP32 encrypted/raw command relay.
  if (req.method === 'POST' && req.url === '/api/encrypted/command') {
    try {
      const body = await readRequestBody(req)
      const cmd = JSON.parse(body)
      const targetTopic = typeof cmd.topic === 'string' && cmd.topic.length > 0 ? cmd.topic : TOPIC_DAYU_CMD
      let mqttPayload

      if (cmd.payloadBase64) {
        mqttPayload = Buffer.from(cmd.payloadBase64, 'base64')
        console.log(`[Bridge] encrypted cmd -> ${targetTopic}: ${mqttPayload.length} bytes`)
        state.lastMessage = `加密指令已转发 (${mqttPayload.length}B)`
      } else if (cmd.plainText) {
        mqttPayload = cmd.plainText
        console.log(`[Bridge] plain cmd -> ${targetTopic}: ${mqttPayload}`)
        state.lastMessage = '明文指令已转发'
      } else {
        sendJson(res, 400, { ok: false, message: 'missing payloadBase64 or plainText' })
        return
      }

      if (isKeyExchangePublicKey(targetTopic, mqttPayload)) {
        rememberDayuEcdhPublicKey(targetTopic, mqttPayload)
      }

      aedes.publish({
        topic: targetTopic,
        payload: mqttPayload,
        qos: 1,
        retain: false
      })
      logCommandRoute('HTTP', targetTopic, Buffer.isBuffer(mqttPayload) ? mqttPayload.length : Buffer.byteLength(String(mqttPayload)), 1)

      if (isKeyExchangePublicKey(targetTopic, mqttPayload)) {
        console.log(`[ECDH] Dayu public key relayed on ${targetTopic}: ${mqttPayload.length} bytes`)
        clearKeyExchangePublicKey(targetTopic)
      }

      sendJson(res, 200, {
        ok: true,
        message: state.lastMessage,
        topic: targetTopic
      })
    } catch (err) {
      sendJson(res, 500, { ok: false, message: err.message })
    }
    return
  }

  sendJson(res, 404, { ok: false, message: '接口不存在', state })
}

function cloudRequest(method, pathName, body) {
  return new Promise((resolve, reject) => {
    const url = new URL(pathName, CLOUD_API_BASE)
    const text = body ? JSON.stringify(body) : ''
    const req = https.request(url, {
      method,
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(text)
      },
      timeout: 8000
    }, (res) => {
      let data = ''
      res.setEncoding('utf8')
      res.on('data', (chunk) => { data += chunk })
      res.on('end', () => {
        if (res.statusCode < 200 || res.statusCode >= 300) {
          reject(new Error(`HTTP ${res.statusCode}: ${data.slice(0, 160)}`))
          return
        }
        try {
          resolve(data ? JSON.parse(data) : {})
        } catch (err) {
          reject(err)
        }
      })
    })
    req.on('timeout', () => req.destroy(new Error('cloud request timeout')))
    req.on('error', reject)
    if (text.length > 0) req.write(text)
    req.end()
  })
}

async function ackCloudCommand(id, ok, message) {
  await cloudRequest('POST', '/api/control/ack', { id, ok, message })
}

function publishSm4CommandToEsp32(jsonCmd, cloudCommandId) {
  const payload = encryptSm4Gcm(jsonCmd)
  aedes.publish({
    topic: TOPIC_DAYU_CMD,
    payload,
    qos: 0,
    retain: false
  })
  logCommandRoute('CloudRelay', TOPIC_DAYU_CMD, payload.length, 0)
  state.lastMessage = `云端App指令已通过SM4/MQTT下发 (${payload.length}B)`
  console.log(`[CloudRelay] ${cloudCommandId} -> ${TOPIC_DAYU_CMD}: ${payload.length} bytes ${jsonCmd}`)
  rememberEncryptedPayload(TOPIC_DAYU_CMD, payload, 'CloudRelay', false)
}

let cloudCommandPollInFlight = false
let cloudLedSeq = 0

async function pollCloudCommand() {
  if (!CLOUD_COMMAND_POLL_ENABLED || cloudCommandPollInFlight) return
  cloudCommandPollInFlight = true
  try {
    const response = await cloudRequest('GET', '/api/control/pending?consumer=broker')
    const command = response.command
    if (!command || !command.id) return
    if (command.kind !== 'light' || command.dayuTarget !== 'living') {
      await ackCloudCommand(command.id, false, `unsupported command ${command.kind}/${command.dayuTarget}`)
      return
    }
    cloudLedSeq = (cloudLedSeq % 999999) + 1
    const ledCmd = {
      cmd: 'led',
      val: command.power === true ? 1 : 0,
      source: 'dayu',
      priority: 10,
      lockMs: 5000,
      seq: cloudLedSeq
    }
    publishSm4CommandToEsp32(JSON.stringify(ledCmd), command.id)
    await ackCloudCommand(command.id, true, `${command.action || '灯控'}已由本地Broker通过MQTT+SM4下发`)
  } catch (err) {
    console.log(`[CloudRelay] poll failed: ${err.message}`)
  } finally {
    cloudCommandPollInFlight = false
  }
}
const httpServer = http.createServer(handleHttpRequest)
httpServer.keepAliveTimeout = 1000
httpServer.headersTimeout = 3000
httpServer.requestTimeout = 5000
if (httpsBridgeServer) {
  httpsBridgeServer.keepAliveTimeout = 1000
  httpsBridgeServer.headersTimeout = 3000
  httpsBridgeServer.requestTimeout = 5000
}

mqttServer.listen(MQTT_PORT, HOST, () => {
  console.log(`[MQTT] broker listening on mqtt://${HOST}:${MQTT_PORT}`)
  getLanAddresses().forEach((item) => {
    console.log(`[MQTT] LAN address: ${item.name} -> mqtt://${item.address}:${MQTT_PORT}`)
  })
})

if (mqttTlsServer) {
  mqttTlsServer.listen(MQTT_TLS_PORT, HOST, () => {
    console.log(`[MQTTS] mutual TLS broker listening on mqtts://${HOST}:${MQTT_TLS_PORT}`)
    console.log(`[MQTTS] required client CN: ${DAYU_TLS_CLIENT_CN}`)
    getLanAddresses().forEach((item) => {
      console.log(`[MQTTS] LAN address: ${item.name} -> mqtts://${item.address}:${MQTT_TLS_PORT}`)
    })
  })
}

if (bridgeTlsServer) {
  bridgeTlsServer.listen(BRIDGE_TLS_PORT, HOST, () => {
    console.log(`[BridgeWSS] mutual TLS WebSocket bridge listening on wss://${HOST}:${BRIDGE_TLS_PORT}`)
    getLanAddresses().forEach((item) => {
      console.log(`[BridgeWSS] DAYU address: ${item.name} -> wss://${item.address}:${BRIDGE_TLS_PORT}`)
    })
  })
}

httpServer.listen(HTTP_PORT, HOST, () => {
  console.log(`[Bridge] HTTP bridge listening on http://${HOST}:${HTTP_PORT}`)
  getLanAddresses().forEach((item) => {
    console.log(`[Bridge] DAYU address: ${item.name} -> http://${item.address}:${HTTP_PORT}`)
  })
  console.log('[Bridge] API: GET /api/state, POST /api/light/control, POST /api/encrypted/command, POST /api/http/sensor')

  // 鍚姩 UDP 骞挎挱淇℃爣
  if (BEACON_ENABLED) {
    sendUdpBeacon()
    beaconTimer = setInterval(sendUdpBeacon, BEACON_INTERVAL)
    console.log(`[Beacon] broadcasting every ${BEACON_INTERVAL}ms to port ${BEACON_PORT}`)
  }
  if (CLOUD_COMMAND_POLL_ENABLED) {
    pollCloudCommand()
    setInterval(pollCloudCommand, CLOUD_COMMAND_POLL_INTERVAL)
    console.log(`[CloudRelay] polling ${CLOUD_API_BASE}/api/control/pending every ${CLOUD_COMMAND_POLL_INTERVAL}ms`)
  }
})

if (httpsBridgeServer) {
  httpsBridgeServer.listen(HTTPS_PORT, HOST, () => {
    console.log(`[BridgeHTTPS] HTTPS bridge listening on https://${HOST}:${HTTPS_PORT}`)
    console.log(`[BridgeHTTPS] CA certificate for ESP32 HTTP TLS: ${TLS_CA_PATH}`)
    getLanAddresses().forEach((item) => {
      console.log(`[BridgeHTTPS] ESP32 address: ${item.name} -> https://${item.address}:${HTTPS_PORT}`)
    })
    console.log('[BridgeHTTPS] API: GET /api/state, POST /api/http/sensor, GET/POST /api/http/command')
  })
}

if (esp32MqttTlsServer) {
  esp32MqttTlsServer.listen(ESP32_MQTT_TLS_PORT, HOST, () => {
    console.log(`[MQTTS-ESP32] server-auth TLS broker listening on mqtts://${HOST}:${ESP32_MQTT_TLS_PORT}`)
    console.log('[MQTTS-ESP32] client certificate is not required; server CA verification remains required')
    getLanAddresses().forEach((item) => {
      console.log(`[MQTTS-ESP32] ESP32 address: ${item.name} -> mqtts://${item.address}:${ESP32_MQTT_TLS_PORT}`)
    })
  })
}

esp32UdpRelayServer.on('message', (message, remote) => {
  state.udpRelay.receivedCount += 1
  state.udpRelay.lastFrom = `${remote.address}:${remote.port}`
  state.udpRelay.lastMessage = message.toString().trim()
  state.udpRelay.lastTime = Date.now()
  state.lastMessage = `鏀跺埌 ESP32 UDP ${new Date(state.udpRelay.lastTime).toLocaleTimeString()}`
  console.log(`[UDP-in] received #${state.udpRelay.receivedCount} from ${state.udpRelay.lastFrom}: ${state.udpRelay.lastMessage}`)
  forwardUdpToDayu(message, remote)
})

esp32UdpRelayServer.on('error', (err) => {
  console.log(`[UDP-in] relay server error: ${err.message}`)
})

esp32UdpRelayServer.bind(ESP32_UDP_RELAY_PORT, HOST, () => {
  console.log(`[UDP-in] ESP32 UDP relay listening on udp://${HOST}:${ESP32_UDP_RELAY_PORT}`)
  getLanAddresses().forEach((item) => {
    console.log(`[UDP-in] ESP32 send to ${item.address}:${ESP32_UDP_RELAY_PORT}; broker forwards to Dayu UDP ${DAYU_UDP_PORT}`)
  })
})

process.on('SIGINT', () => {
  console.log('\n[MQTT] shutting down broker and bridge')
  if (beaconTimer) clearInterval(beaconTimer)
  httpServer.close(() => {})
  if (httpsBridgeServer) httpsBridgeServer.close(() => {})
  try { esp32UdpRelayServer.close() } catch (_) { /* ignore */ }
  if (mqttTlsServer) mqttTlsServer.close(() => {})
  if (esp32MqttTlsServer) esp32MqttTlsServer.close(() => {})
  if (bridgeTlsServer) bridgeTlsServer.close(() => {})
  mqttServer.close(() => {
    aedes.close(() => process.exit(0))
  })
})
