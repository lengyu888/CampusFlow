import common from '@ohos.app.ability.common';
import deviceInfo from '@ohos.deviceInfo';
import { RecognitionEvents, SpeechEvents, VoiceCapabilities, VoiceDriver, VoiceInteractionError } from '../utils/VoiceInteraction';

interface ProbedVoiceDriver extends VoiceDriver { probe(): Promise<VoiceCapabilities>; }

// Keep the Harmony-only module out of Android/iOS module initialization.
// A constant dynamic import still needs compilation; see stage-6-voice-interaction.md.
export class PlatformVoiceDriver implements VoiceDriver {
  private provider: VoiceDriver | null = null;
  private pendingProvider: Promise<VoiceDriver> | null = null;
  private recognitionId: string = '';
  private speechId: string = '';
  private disposed: boolean = false;
  private context: common.UIAbilityContext | undefined;
  private nativeCapabilities: VoiceCapabilities = { recognition: false, synthesis: false };

  constructor(context: common.UIAbilityContext | undefined) {
    this.context = context;
  }

  capabilities(): VoiceCapabilities {
    try {
      if (this.disposed) { return { recognition: false, synthesis: false }; }
      const os = deviceInfo.osFullName;
      if (this.nativePlatform()) { return { recognition: this.nativeCapabilities.recognition, synthesis: this.nativeCapabilities.synthesis }; }
      const harmony = os.startsWith('OpenHarmony') || os.startsWith('HarmonyOS');
      return {
        recognition: harmony && canIUse('SystemCapability.AI.SpeechRecognizer'),
        synthesis: harmony && canIUse('SystemCapability.AI.TextToSpeech')
      };
    } catch {
      return { recognition: false, synthesis: false };
    }
  }

  private nativePlatform(): boolean {
    const os = deviceInfo.osFullName;
    return os.startsWith('Android') || os.startsWith('iOS') || os.startsWith('iPadOS');
  }

  async probe(): Promise<VoiceCapabilities> {
    if (this.disposed) { return { recognition: false, synthesis: false }; }
    try {
      if (!this.nativePlatform()) { return this.capabilities(); }
      const provider = await this.getProvider() as ProbedVoiceDriver;
      const result = await provider.probe();
      if (!this.disposed) { this.nativeCapabilities = { recognition: result.recognition, synthesis: result.synthesis }; }
      return this.capabilities();
    } catch {
      this.nativeCapabilities = { recognition: false, synthesis: false };
      throw new VoiceInteractionError('设备语音能力尚未核实，可重试检测；文字输入仍可使用。');
    }
  }

  private async getProvider(): Promise<VoiceDriver> {
    if (this.disposed) { throw new VoiceInteractionError('语音已停止，请重新打开 Agent 页面。'); }
    if (this.provider !== null) { return this.provider; }
    if (this.pendingProvider === null) {
      this.pendingProvider = this.nativePlatform() ? import('./NativeBridgeVoiceDriver').then((module) => {
        return new module.NativeBridgeVoiceDriver();
      }) : import('./HarmonyVoiceDriver').then((module) => {
        return new module.HarmonyVoiceDriver(this.context);
      });
      this.pendingProvider = this.pendingProvider.then((provider: VoiceDriver) => {
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
    if (this.disposed) { throw new VoiceInteractionError('语音已停止。'); }
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
    if (this.disposed) { throw new VoiceInteractionError('语音已停止。'); }
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
