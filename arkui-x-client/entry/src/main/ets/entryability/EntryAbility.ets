import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import UIAbility from '@ohos.app.ability.UIAbility';
import Want from '@ohos.app.ability.Want';
import window from '@ohos.window';
import { initializeLocalHistory } from '../services/LocalHistory';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    AppStorage.setOrCreate<string>('apiBaseUrl', 'http://127.0.0.1:8000');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    initializeLocalHistory(this.context.filesDir).catch(() => {
      AppStorage.setOrCreate<string>('localHistoryError', '本机对话读取失败，暂不覆盖已有记录。联网登录仍可使用。');
    }).then(() => windowStage.loadContent('pages/Index')).catch((error: Error) => {
      console.error(`Failed to load CampusFlow content: ${error.message}`);
    });
  }
}
