import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import UIAbility from '@ohos.app.ability.UIAbility';
import Want from '@ohos.app.ability.Want';
import window from '@ohos.window';
import { initializeLocalHistory } from '../services/LocalHistory';
import { initializeLocalDrafts } from '../services/LocalDrafts';
import { initializeLocalFocus } from '../services/LocalFocus';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    AppStorage.setOrCreate<string>('apiBaseUrl', 'http://127.0.0.1:8000');
    AppStorage.setOrCreate<boolean>('voiceForeground', false);
  }

  onForeground(): void {
    AppStorage.setOrCreate<boolean>('voiceForeground', true);
  }

  onBackground(): void {
    AppStorage.setOrCreate<boolean>('voiceForeground', false);
  }

  onDestroy(): void {
    AppStorage.setOrCreate<boolean>('voiceForeground', false);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    const focusReady = initializeLocalFocus(this.context.filesDir).catch(() => {
      AppStorage.setOrCreate<string>('localFocusError', '本机专注记录读取失败，原文件保留。清除会丢失未同步记录，请明确确认后再操作。');
    });
    const draftsReady = initializeLocalDrafts(this.context.filesDir).catch(() => {
      AppStorage.setOrCreate<string>('localDraftsError', '本机草稿读取失败，原文件仍保留。可在设置中明确清除后重试。');
    });
    initializeLocalHistory(this.context.filesDir).catch(() => {
      AppStorage.setOrCreate<string>('localHistoryError', '本机对话读取失败，暂不覆盖已有记录。联网登录仍可使用。');
    }).then(() => draftsReady).then(() => focusReady).then(() => windowStage.loadContent('pages/Index')).catch((error: Error) => {
      console.error(`Failed to load CampusFlow content: ${error.message}`);
    });
  }
}
