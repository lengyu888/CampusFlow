import common from '@ohos.app.ability.common';
import deviceInfo from '@ohos.deviceInfo';
import { RecognitionEvents, SpeechEvents, VoiceCapabilities, VoiceDriver, VoiceInteractionError } from '../utils/VoiceInteraction';

// Keep the Harmony-only module out of Android/iOS module initialization.
// A constant dynamic import still needs compilation; see stage-6-voice-interaction.md.
export class PlatformVoiceDriver implements VoiceDriver {
  private provider: VoiceDriver | null = null;
  private pendingProvider: Promise<VoiceDriver> | null = null;
  private recognitionId: string = '';
  private speechId: string = '';
  private disposed: boolean = false;
  private context: common.UIAbilityContext | undefined;

  constructor(context: common.UIAbilityContext | undefined) {
    this.context = context;
  }

  capabilities(): VoiceCapabilities {
    try {
      const os = deviceInfo.osFullName;
      const harmony = os.startsWith('OpenHarmony') || os.startsWith('HarmonyOS');
      return {
        recognition: harmony && canIUse('SystemCapability.AI.SpeechRecognizer'),
        synthesis: harmony && canIUse('SystemCapability.AI.TextToSpeech')
      };
    } catch {
      return { recognition: false, synthesis: false };
    }
  }

  private async getProvider(): Promise<VoiceDriver> {
    if (this.disposed) { throw new VoiceInteractionError('语音已停止，请重新打开 Agent 页面。'); }
    if (this.provider !== null) { return this.provider; }
    if (this.pendingProvider === null) {
      this.pendingProvider = import('./HarmonyVoiceDriver').then((module) => {
        const provider: VoiceDriver = new module.HarmonyVoiceDriver(this.context);
        if (this.disposed) {
          provider.dispose();
          throw new VoiceInteractionError('语音已停止。');
        }
        this.provider = provider;
        return provider;
      });
    }
    try {
      return await this.pendingProvider;
    } catch {
      this.pendingProvider = null;
      throw new VoiceInteractionError('此设备的语音服务暂不可用，请继续使用文字输入。');
    }
  }

  async startListening(id: string, events: RecognitionEvents): Promise<void> {
    if (!this.capabilities().recognition) {
      throw new VoiceInteractionError('当前设备暂不支持语音识别，可继续文字输入。');
    }
    this.recognitionId = id;
    const provider = await this.getProvider();
    if (this.disposed || this.recognitionId !== id) { return; }
    await provider.startListening(id, events);
  }

  finishListening(id: string): void {
    if (this.recognitionId === id) { this.provider?.finishListening(id); }
  }

  cancelListening(id: string): void {
    if (this.recognitionId !== id) { return; }
    this.recognitionId = '';
    this.provider?.cancelListening(id);
  }

  async speak(id: string, text: string, events: SpeechEvents): Promise<void> {
    if (!this.capabilities().synthesis) {
      throw new VoiceInteractionError('当前设备暂不支持回答播报，文字回答仍可阅读。');
    }
    this.speechId = id;
    const provider = await this.getProvider();
    if (this.disposed || this.speechId !== id) { return; }
    await provider.speak(id, text, events);
  }

  stopSpeaking(): void {
    this.speechId = '';
    this.provider?.stopSpeaking();
  }

  dispose(): void {
    this.disposed = true;
    this.recognitionId = '';
    this.speechId = '';
    this.provider?.dispose();
    this.provider = null;
  }
}
