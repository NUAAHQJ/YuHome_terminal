declare module 'liblocal_gateway.so' {
  export interface LocalGatewayStartResult {
    ok: boolean
    message: string
    port: number
  }

  export interface LocalGatewayStatus {
    running: boolean
    mqttRunning: boolean
    httpsRunning: boolean
    port: number
    httpsPort: number
    requests: number
  }

  export interface LocalGatewayEvent {
    type: string
    body: string
    timestamp: number
  }

  interface LocalGatewayNative {
    start(port: number): LocalGatewayStartResult
    startMqtt(port: number, tlsPort?: number, certificatePem?: string, privateKeyPem?: string): LocalGatewayStartResult
    startHttps(port: number, certificatePem: string, privateKeyPem: string): LocalGatewayStartResult
    stop(): boolean
    getStatus(): LocalGatewayStatus
    enqueueCommand(deviceId: string, topic: string, payloadBase64: string, bytes: number): boolean
    pollEvents(): LocalGatewayEvent[]
  }

  const localGateway: LocalGatewayNative
  export default localGateway
}
