import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import UIAbility from '@ohos.app.ability.UIAbility';
import Want from '@ohos.app.ability.Want';
import window from '@ohos.window';
import { initializeLocalHistory } from '../services/LocalHistory';
import { initializeLocalDrafts } from '../services/LocalDrafts';
import { initializeLocalFocus } from '../services/LocalFocus';
import { initializeAppTheme } from '../theme/ThemePalette';
import { initializeLocalSession } from '../services/LocalSession';

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
    const sessionReady = initializeLocalSession(this.context.filesDir).catch(() => {
      AppStorage.setOrCreate<string>('localSessionError', '安全登录存储暂不可用，本次可手动登录。');
    });
    const focusReady = initializeLocalFocus(this.context.filesDir).catch(() => {
      AppStorage.setOrCreate<string>('localFocusError', '本机专注记录读取失败，原文件保留。清除会丢失未同步记录，请明确确认后再操作。');
    });
    const draftsReady = initializeLocalDrafts(this.context.filesDir).catch(() => {
      AppStorage.setOrCreate<string>('localDraftsError', '本机草稿读取失败，原文件仍保留。可在设置中明确清除后重试。');
    });
    initializeLocalHistory(this.context.filesDir).catch(() => {
      AppStorage.setOrCreate<string>('localHistoryError', '本机对话读取失败，暂不覆盖已有记录。联网登录仍可使用。');
    }).then(() => draftsReady).then(() => focusReady).then(() => sessionReady).then(() => windowStage.loadContent('pages/Index', (error) => {
      if (error.code) {
        console.error(`Failed to load CampusFlow content: ${error.message}`);
        return;
      }
      // PersistentStorage needs the initialized UI instance. An earlier call can
      // miss disk data and permanently publish the default for this process.
      initializeAppTheme();
    })).catch((error: Error) => {
      console.error(`Failed to load CampusFlow content: ${error.message}`);
    });
  }
}
