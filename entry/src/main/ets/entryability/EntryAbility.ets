import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import localGateway, { LocalGatewayStartResult } from 'liblocal_gateway.so';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  private applyImmersiveWindow(windowStage: window.WindowStage): void {
    try {
      const mainWindow = windowStage.getMainWindowSync();
      mainWindow.setPreferredOrientation(window.Orientation.LANDSCAPE);
      // 注释掉 setWindowLayoutFullScreen(true)：Dayu210 内置屏 HWC overlay 平面分配异常，
      // 会在横屏下产生随机位置竖向黑条闪烁。外接显示器不受影响。
      // mainWindow.setWindowLayoutFullScreen(true);
      // 隐藏所有系统栏（状态栏、导航栏），全屏显示
      mainWindow.setWindowSystemBarEnable([]);
      // 设置窗口背景色，填补可能的 framebuffer 未初始化区域
      mainWindow.setWindowBackgroundColor('#E8EDF2');
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set window config. Cause: %{public}s', JSON.stringify(err));
    }
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    const gatewayStart: LocalGatewayStartResult = localGateway.start(3000);
    let mqttStart: LocalGatewayStartResult;
    try {
      const decoder = new util.TextDecoder();
      const certificate = decoder.decodeWithStream(
        this.context.resourceManager.getRawFileContentSync('gateway/server.crt'));
      const privateKey = decoder.decodeWithStream(
        this.context.resourceManager.getRawFileContentSync('gateway/server.key'));
      mqttStart = localGateway.startMqtt(1883, 8884, certificate, privateKey);
      const httpsStart: LocalGatewayStartResult = localGateway.startHttps(3444, certificate, privateKey);
      hilog.info(DOMAIN, 'LocalGateway', 'https ok=%{public}s port=%{public}d %{public}s',
        `${httpsStart.ok}`, httpsStart.port, httpsStart.message);
    } catch (err) {
      hilog.error(DOMAIN, 'LocalGateway', 'TLS material unavailable: %{public}s', JSON.stringify(err));
      mqttStart = localGateway.startMqtt(1883);
    }
    hilog.info(DOMAIN, 'LocalGateway', 'start ok=%{public}s port=%{public}d %{public}s',
      `${gatewayStart.ok}`, gatewayStart.port, gatewayStart.message);
    hilog.info(DOMAIN, 'LocalGateway', 'mqtt ok=%{public}s %{public}s', `${mqttStart.ok}`, mqttStart.message);
  }

  onDestroy(): void {
    localGateway.stop();
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    this.applyImmersiveWindow(windowStage);

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}
