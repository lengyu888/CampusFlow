import common from '@ohos.app.ability.common';
import abilityAccessCtrl from '@ohos.abilityAccessCtrl';
import { speechRecognizer, textToSpeech } from '@kit.CoreSpeechKit';
import { RecognitionEvents, SpeechEvents, VoiceCapabilities, VoiceDriver, VoiceInteractionError } from '../utils/VoiceInteraction';

// This adapter is loaded only by PlatformVoiceDriver on a capable Harmony device.
// API contracts: Huawei Core Speech Kit references linked in the stage-6 handoff.
// Native SDK compilation/device behavior remains a separate acceptance step.
export class HarmonyVoiceDriver implements VoiceDriver {
  private recognizer: speechRecognizer.SpeechRecognitionEngine | null = null;
  private synthesizer: textToSpeech.TextToSpeechEngine | null = null;
  private recognitionId: string = '';
  private speechId: string = '';
  private recognitionRevision: number = 0;
  private speechRevision: number = 0;
  private disposed: boolean = false;
  private context: common.UIAbilityContext | undefined;

  constructor(context: common.UIAbilityContext | undefined) {
    this.context = context;
  }

  capabilities(): VoiceCapabilities {
    return {
      recognition: canIUse('SystemCapability.AI.SpeechRecognizer'),
      synthesis: canIUse('SystemCapability.AI.TextToSpeech')
    };
  }

  private releaseRecognizer(): void {
    const engine = this.recognizer;
    this.recognizer = null;
    if (engine !== null) {
      try { engine.shutdown(); } catch { /* Already stopped by the system. */ }
    }
  }

  async startListening(id: string, events: RecognitionEvents): Promise<void> {
    if (this.disposed) { throw new VoiceInteractionError('语音已停止。'); }
    this.cancelListening(this.recognitionId);
    this.stopSpeaking();
    this.recognitionId = id;
    const revision = ++this.recognitionRevision;
    if (this.context === undefined) {
      throw new VoiceInteractionError('暂时无法申请麦克风权限，请返回 Agent 页面后重试。');
    }
    let granted = false;
    try {
      const permission = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(
        this.context, ['ohos.permission.MICROPHONE']);
      granted = permission.authResults.length > 0 && permission.authResults[0] === 0;
    } catch {
      throw new VoiceInteractionError('麦克风授权未完成，请继续文字输入，或稍后重试。');
    }
    if (this.disposed || revision !== this.recognitionRevision) { return; }
    if (!granted) {
      throw new VoiceInteractionError('未获得麦克风权限。可在系统设置中允许 CampusFlow 使用麦克风，或继续文字输入。');
    }
    let engine: speechRecognizer.SpeechRecognitionEngine;
    try {
      // online=1 is OFFLINE in the documented API; never silently switch to cloud ASR.
      engine = await speechRecognizer.createEngine({ language: 'zh-CN', online: 1,
        extraParams: { locate: 'CN', recognizerMode: 'short' } });
    } catch {
      throw new VoiceInteractionError('设备语音识别服务暂不可用，请稍后重试或使用文字输入。');
    }
    if (this.disposed || revision !== this.recognitionRevision) {
      try { engine.shutdown(); } catch { /* Dispose a late initialization. */ }
      return;
    }
    this.recognizer = engine;
    let committed = '';
    let current = '';
    const live = (sessionId: string): boolean => !this.disposed &&
      revision === this.recognitionRevision && sessionId === this.recognitionId;
    const complete = (): void => {
      if (!live(id)) { return; }
      this.recognitionId = '';
      this.releaseRecognizer();
      events.onComplete();
    };
    try {
      engine.setListener({
        onStart: (sessionId: string, _eventMessage: string): void => {
          if (live(sessionId)) { events.onStart(); }
        },
        onEvent: (_sessionId: string, _eventCode: number, _eventMessage: string): void => {},
        onResult: (sessionId: string, result: speechRecognizer.SpeechRecognitionResult): void => {
          if (!live(sessionId)) { return; }
          // A partial replaces the current sentence; only final sentences accumulate.
          current = result.result;
          if (result.isFinal) {
            committed += current;
            current = '';
          }
          events.onResult(committed + current);
          if (result.isFinal && result.isLast) { complete(); }
        },
        onComplete: (sessionId: string, _eventMessage: string): void => {
          if (live(sessionId)) { complete(); }
        },
        onError: (sessionId: string, _errorCode: number, _errorMessage: string): void => {
          if (!live(sessionId)) { return; }
          this.recognitionId = '';
          this.releaseRecognizer();
          events.onError('语音识别未完成。请检查麦克风是否被占用，或重新说一遍。');
        }
      });
      // recognitionMode=0 uses the system microphone; the default is audio-stream input.
      engine.startListening({ sessionId: id,
        audioInfo: { audioType: 'pcm', sampleRate: 16000, sampleBit: 16, soundChannel: 1 },
        extraParams: { recognitionMode: 0 } });
    } catch {
      this.cancelListening(id);
      throw new VoiceInteractionError('暂时无法开始录音，请确认麦克风可用后重试。');
    }
  }

  finishListening(id: string): void {
    if (this.recognitionId !== id || this.recognizer === null) { return; }
    try {
      this.recognizer.finish(id);
    } catch {
      this.cancelListening(id);
      throw new VoiceInteractionError('未取得完整识别结果，请重新说一遍。');
    }
  }

  cancelListening(id: string): void {
    if (id !== this.recognitionId) { return; }
    this.recognitionId = '';
    this.recognitionRevision++;
    if (this.recognizer !== null && id.length > 0) {
      try { this.recognizer.cancel(id); } catch { /* Still release the engine. */ }
    }
    this.releaseRecognizer();
  }

  async speak(id: string, text: string, events: SpeechEvents): Promise<void> {
    if (this.disposed) { throw new VoiceInteractionError('播报已停止。'); }
    this.stopSpeaking();
    this.cancelListening(this.recognitionId);
    this.speechId = id;
    const revision = ++this.speechRevision;
    let engine: textToSpeech.TextToSpeechEngine;
    try {
      engine = await textToSpeech.createEngine({ language: 'zh-CN', person: 0, online: 1,
        extraParams: { locate: 'CN' } });
    } catch {
      throw new VoiceInteractionError('设备播报服务暂不可用，文字回答仍可阅读。');
    }
    if (this.disposed || revision !== this.speechRevision) {
      try { engine.shutdown(); } catch { /* Dispose a late initialization. */ }
      return;
    }
    this.synthesizer = engine;
    // Bound each request without cutting surrogate pairs or truncating the answer.
    const characters = Array.from(text);
    const chunks: string[] = [];
    for (let offset = 0; offset < characters.length; offset += 500) {
      chunks.push(characters.slice(offset, offset + 500).join(''));
    }
    if (chunks.length === 0) {
      this.stopSpeaking();
      throw new VoiceInteractionError('这条回答没有可播报的正文。');
    }
    let index = 0;
    let started = false;
    const live = (requestId: string): boolean => !this.disposed &&
      revision === this.speechRevision && this.speechId === id && requestId === `${id}-${index}`;
    const speakChunk = (): void => {
      try {
        engine.speak(chunks[index], { requestId: `${id}-${index}`, extraParams: { playType: 1, queueMode: 0 } });
      } catch {
        this.stopSpeaking();
        events.onError('播报中断，文字回答仍可阅读；可重新点击播报。');
      }
    };
    try {
      engine.setListener({
        onStart: (requestId: string, _response: textToSpeech.StartResponse): void => {
          if (live(requestId) && !started) { started = true; events.onStart(); }
        },
        onComplete: (requestId: string, response: textToSpeech.CompleteResponse): void => {
          // type=0 only means synthesis completed; audio may still be playing.
          if (!live(requestId) || response.type !== 1) { return; }
          index++;
          if (index < chunks.length) {
            speakChunk();
          } else {
            this.stopSpeaking();
            events.onComplete();
          }
        },
        onStop: (requestId: string, _response: textToSpeech.StopResponse): void => {
          if (!live(requestId)) { return; }
          this.stopSpeaking();
          events.onError('系统已停止播报，可重新点击播放。');
        },
        onError: (requestId: string, _errorCode: number, _errorMessage: string): void => {
          if (!live(requestId)) { return; }
          this.stopSpeaking();
          events.onError('播报未完成，请检查设备声音设置后重试。');
        }
      });
      speakChunk();
    } catch {
      this.stopSpeaking();
      throw new VoiceInteractionError('暂时无法播报这条回答，文字内容仍可阅读。');
    }
  }

  stopSpeaking(): void {
    this.speechId = '';
    this.speechRevision++;
    const engine = this.synthesizer;
    this.synthesizer = null;
    if (engine !== null) {
      try { engine.stop(); } catch { /* Still release the engine. */ }
      try { engine.shutdown(); } catch { /* Already stopped by the system. */ }
    }
  }

  dispose(): void {
    this.disposed = true;
    this.cancelListening(this.recognitionId);
    this.stopSpeaking();
  }
}
