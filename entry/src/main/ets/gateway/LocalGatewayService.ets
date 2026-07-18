import localGateway, {
  LocalGatewayEvent,
  LocalGatewayStartResult,
  LocalGatewayStatus
} from 'liblocal_gateway.so'

export type LocalGatewayEventHandler = (event: LocalGatewayEvent) => void

export class LocalGatewayService {
  private eventTimerId: number = -1
  private eventHandler: LocalGatewayEventHandler | null = null

  start(port: number = 3000, eventHandler?: LocalGatewayEventHandler): LocalGatewayStartResult {
    if (eventHandler) {
      this.eventHandler = eventHandler
    }
    const result: LocalGatewayStartResult = localGateway.start(port)
    if (result.ok) {
      const mqttResult: LocalGatewayStartResult = localGateway.startMqtt(1883)
      console.info(`[LocalGateway][MQTT] ok=${mqttResult.ok} ${mqttResult.message}`)
      this.startEventPump()
    }
    return result
  }

  stop(): void {
    if (this.eventTimerId !== -1) {
      clearInterval(this.eventTimerId)
      this.eventTimerId = -1
    }
    localGateway.stop()
  }

  status(): LocalGatewayStatus {
    return localGateway.getStatus()
  }

  enqueueCommand(deviceId: string, topic: string, payloadBase64: string, bytes: number): boolean {
    return localGateway.enqueueCommand(deviceId, topic, payloadBase64, bytes)
  }

  private startEventPump(): void {
    if (this.eventTimerId !== -1) {
      return
    }
    this.eventTimerId = setInterval(() => {
      const events: LocalGatewayEvent[] = localGateway.pollEvents()
      if (this.eventHandler === null || events.length === 0) {
        return
      }
      events.forEach((event: LocalGatewayEvent) => {
        if (this.eventHandler) {
          this.eventHandler(event)
        }
      })
    }, 100)
  }
}
