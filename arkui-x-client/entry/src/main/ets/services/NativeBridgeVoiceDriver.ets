import { RecognitionEvents, SpeechEvents, VoiceCapabilities, VoiceDriver, VoiceInteractionError } from '../utils/VoiceInteraction';
import { NativePlatformBridge, NativeVoiceEvent, NativeBridgeError, nativePlatformBridge } from './NativePlatformBridge';

function voiceFailure(error: Error): VoiceInteractionError {
  const code = error instanceof NativeBridgeError ? error.code : 'SYSTEM_ERROR';
  return new VoiceInteractionError(code === 'PERMISSION_DENIED' ? '未获得系统语音或麦克风权限，可在系统设置中允许后重试。' :
    code === 'TIMEOUT' ? '设备语音服务响应超时，已停止本次操作，请重试或使用文字。' :
    code === 'UNAVAILABLE' ? '此设备的系统语音服务暂不可用，请继续使用文字。' :
    code === 'OPERATION_CANCELLED' ? '语音操作已停止。' : '设备语音服务未完成，请重试或使用文字。');
}

export class NativeBridgeVoiceDriver implements VoiceDriver {
  private bridge: NativePlatformBridge;
  private unsubscribe: () => void;
  private available: VoiceCapabilities = { recognition: false, synthesis: false };
  private prefix: string = `v-${Date.now().toString(36)}-${Math.random().toString(36).substring(2, 10)}`;
  private recognitionId: string = '';
  private speechId: string = '';
  private recognitionEvents: RecognitionEvents | null = null;
  private speechEvents: SpeechEvents | null = null;
  private disposed: boolean = false;

  constructor(platformBridge: NativePlatformBridge = nativePlatformBridge()) {
    this.bridge = platformBridge;
    this.unsubscribe = this.bridge.subscribeVoice((event: NativeVoiceEvent) => this.receive(event));
  }
  capabilities(): VoiceCapabilities { return { recognition: this.available.recognition, synthesis: this.available.synthesis }; }
  async probe(): Promise<VoiceCapabilities> {
    if (this.disposed) { return { recognition: false, synthesis: false }; }
    try {
      const result = await this.bridge.request('capabilities');
      if (this.disposed) { return { recognition: false, synthesis: false }; }
      if (typeof result.recognition !== 'boolean' || typeof result.synthesis !== 'boolean') { throw new NativeBridgeError('UNAVAILABLE'); }
      this.available = { recognition: result.recognition, synthesis: result.synthesis };
      return this.capabilities();
    } catch (error) { throw voiceFailure(error); }
  }
  private wire(id: string): string { return `${this.prefix}-${id}`; }
  private receive(event: NativeVoiceEvent): void {
    if (this.disposed) { return; }
    if (this.recognitionId.length > 0 && event.operation_id === this.wire(this.recognitionId) && this.recognitionEvents !== null) {
      const events = this.recognitionEvents;
      if (event.event === 'recognition_start') { events.onStart(); }
      else if (event.event === 'recognition_result' && typeof event.text === 'string') { events.onResult(event.text); }
      else if (event.event === 'recognition_complete' || event.event === 'recognition_error') {
        this.recognitionId = ''; this.recognitionEvents = null;
        if (event.event === 'recognition_complete') { events.onComplete(); }
        else { events.onError(voiceFailure(new NativeBridgeError(event.code ?? 'SYSTEM_ERROR')).message); }
      }
    } else if (this.speechId.length > 0 && event.operation_id === this.wire(this.speechId) && this.speechEvents !== null) {
      const events = this.speechEvents;
      if (event.event === 'speech_start') { events.onStart(); }
      else if (event.event === 'speech_complete' || event.event === 'speech_error') {
        this.speechId = ''; this.speechEvents = null;
        if (event.event === 'speech_complete') { events.onComplete(); }
        else { events.onError(voiceFailure(new NativeBridgeError(event.code ?? 'SYSTEM_ERROR')).message); }
      }
    }
  }
  async startListening(id: string, events: RecognitionEvents): Promise<void> {
    if (this.disposed) { throw new VoiceInteractionError('语音已停止。'); }
    this.cancelListening(this.recognitionId); this.stopSpeaking();
    this.recognitionId = id; this.recognitionEvents = events;
    try { await this.bridge.request('recognition.start', { operation_id: this.wire(id) }); }
    catch (error) { if (this.recognitionId === id) { this.cancelListening(id); throw voiceFailure(error); } }
  }
  finishListening(id: string): void {
    if (this.disposed || id.length === 0 || this.recognitionId !== id) { return; }
    this.bridge.request('recognition.finish', { operation_id: this.wire(id) }).catch((error: Error) => {
      if (this.recognitionId === id) {
        const events = this.recognitionEvents; this.cancelListening(id); events?.onError(voiceFailure(error).message);
      }
    });
  }
  cancelListening(id: string): void {
    if (id.length === 0 || this.recognitionId !== id) { return; }
    this.recognitionId = ''; this.recognitionEvents = null;
    this.bridge.request('recognition.cancel', { operation_id: this.wire(id) }).catch(() => {});
  }
  async speak(id: string, text: string, events: SpeechEvents): Promise<void> {
    if (this.disposed) { throw new VoiceInteractionError('语音已停止。'); }
    if (text.length > 32000) { throw new VoiceInteractionError('此回答超过设备朗读长度上限，全文仍可阅读或复制。'); }
    this.cancelListening(this.recognitionId); this.stopSpeaking();
    this.speechId = id; this.speechEvents = events;
    try { await this.bridge.request('speech.start', { operation_id: this.wire(id), text: text }); }
    catch (error) { if (this.speechId === id) { this.stopSpeaking(); throw voiceFailure(error); } }
  }
  stopSpeaking(): void {
    if (this.speechId.length === 0) { return; }
    const id = this.speechId;
    this.speechId = ''; this.speechEvents = null;
    this.bridge.request('speech.stop', { operation_id: this.wire(id) }).catch(() => {});
  }
  dispose(): void {
    if (this.disposed) { return; }
    this.disposed = true; this.cancelListening(this.recognitionId); this.stopSpeaking(); this.unsubscribe();
    // This facade does not own the shared native plugin. A late old facade must not stop a new page's audio.
    // The native Activity/ViewController releases global audio resources when its host closes.
  }
}
