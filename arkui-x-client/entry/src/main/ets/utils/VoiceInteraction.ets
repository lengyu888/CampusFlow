export interface VoiceCapabilities {
  recognition: boolean;
  synthesis: boolean;
}

// Only deliberately classified, user-facing adapter failures retain their wording.
export class VoiceInteractionError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'VoiceInteractionError';
  }
}

export interface RecognitionEvents {
  onStart: () => void;
  // The driver supplies the complete accumulated transcript, including partial results.
  onResult: (text: string) => void;
  onComplete: () => void;
  onError: (message: string) => void;
}

export interface SpeechEvents {
  onStart: () => void;
  // Completion means playback ended, not that synthesis or queuing finished.
  onComplete: () => void;
  onError: (message: string) => void;
}

export interface VoiceDriver {
  capabilities(): VoiceCapabilities;
  startListening(id: string, events: RecognitionEvents): Promise<void>;
  finishListening(id: string): void;
  cancelListening(id: string): void;
  speak(id: string, text: string, events: SpeechEvents): Promise<void>;
  stopSpeaking(): void;
  dispose(): void;
}

export interface VoiceState {
  phase: string;
  transcript: string;
  message: string;
  speakingMessageId: string;
}

export interface VoiceClock {
  setTimeout(callback: () => void, delayMs: number): number;
  clearTimeout(id: number): void;
}

class SystemVoiceClock implements VoiceClock {
  setTimeout(callback: () => void, delayMs: number): number {
    return setTimeout(callback, delayMs);
  }

  clearTimeout(id: number): void {
    clearTimeout(id);
  }
}

function characterCount(text: string): number {
  let count = 0;
  for (const character of text) {
    count += 1;
  }
  return count;
}

// This is a spoken-text projection, never a length-limited copy of the answer.
// Native drivers may split the full result into chunks for their synthesis API.
export function speechText(text: string): string {
  return text
    .replace(/```[\s\S]*?(?:```|$)/g, '')
    .replace(/~~~[\s\S]*?(?:~~~|$)/g, '')
    .replace(/`[^`\n]*`/g, '')
    .replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, '')
    .replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, '')
    .replace(/!\[[^\]]*\]\([^)]*\)/g, '')
    .replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')
    .replace(/\[([^\]]+)\]\[[^\]]*\]/g, '$1')
    .replace(/^\s{0,3}\[[^\]]+\]:\s+\S+.*$/gm, '')
    .replace(/\b(?:https?:\/\/|www\.)[^\s<>\u3000-\u303f\u3400-\u9fff\uff00-\uffef]+/gi, '')
    .replace(/<[^>]*>/g, '')
    .replace(/^\s{0,3}#{1,6}\s+/gm, '')
    .replace(/^\s*>\s?/gm, '')
    .replace(/^\s*([-*_])(?:\s*\1){2,}\s*$/gm, '')
    .replace(/^\s*(?:[-+*]|\d+[.)])\s+/gm, '')
    .replace(/[*_~]{1,3}/g, '')
    .replace(/\|/g, '，')
    .replace(/&nbsp;|&#160;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/[\t\r ]+/g, ' ')
    .replace(/ *\n */g, '\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

export class VoiceInteraction {
  private driver: VoiceDriver;
  private onChange: (state: VoiceState) => void;
  private clock: VoiceClock;
  private current: VoiceState = { phase: 'idle', transcript: '', message: '', speakingMessageId: '' };
  private sequence: number = 0;
  private operationId: string = '';
  private operation: string = '';
  private timeoutId: number = -1;
  private disposed: boolean = false;

  constructor(driver: VoiceDriver, onChange: (state: VoiceState) => void,
    clock: VoiceClock = new SystemVoiceClock()) {
    this.driver = driver;
    this.onChange = onChange;
    this.clock = clock;
    this.publish();
  }

  private publish(): void {
    if (!this.disposed) {
      this.onChange({ phase: this.current.phase, transcript: this.current.transcript,
        message: this.current.message, speakingMessageId: this.current.speakingMessageId });
    }
  }

  private update(phase: string, transcript: string, message: string, speakingMessageId: string = ''): void {
    this.current = { phase, transcript, message, speakingMessageId };
    this.publish();
  }

  private active(id: string): boolean {
    return !this.disposed && this.operationId === id && this.operation.length > 0;
  }

  private clearTimer(): void {
    if (this.timeoutId !== -1) {
      this.clock.clearTimeout(this.timeoutId);
      this.timeoutId = -1;
    }
  }

  private setTimer(id: string, delayMs: number, callback: () => void): void {
    if (!this.active(id)) {
      return;
    }
    this.clearTimer();
    const timerId = this.clock.setTimeout(() => {
      if (this.timeoutId !== timerId || !this.active(id)) {
        return;
      }
      this.timeoutId = -1;
      callback();
    }, delayMs);
    this.timeoutId = timerId;
  }

  private invalidate(): void {
    this.clearTimer();
    this.sequence += 1;
    this.operationId = '';
    this.operation = '';
  }

  private stopCurrent(): void {
    const id = this.operationId;
    const operation = this.operation;
    // Invalidate first: some engines synchronously emit onError when stopped.
    this.invalidate();
    try {
      if (operation === 'recognition') {
        this.driver.cancelListening(id);
      } else if (operation === 'speech') {
        this.driver.stopSpeaking();
      }
    } catch {
      // Cancellation is best effort; invalidated callbacks still cannot change the UI.
    }
  }

  private begin(operation: string): string {
    this.stopCurrent();
    const id = `${operation}-${this.sequence}`;
    this.operationId = id;
    this.operation = operation;
    return id;
  }

  private reviewMessage(text: string): string {
    return characterCount(text.trim()) > 8000 ? '识别文字超过 8000 字，请编辑缩短后再填入；原文已保留。'
      : '请检查或编辑文字，再填入输入框。';
  }

  private recognitionFailed(id: string, message: string): void {
    if (!this.active(id)) {
      return;
    }
    const transcript = this.current.transcript;
    this.stopCurrent();
    if (transcript.trim().length > 0) {
      this.update('review', transcript,
        `${message} 以下仅为已识别的文字，请检查后再使用。${characterCount(transcript.trim()) > 8000 ? ' 超过 8000 字，请先编辑缩短。' : ''}`);
    } else {
      this.update('error', '', message);
    }
  }

  async startListening(): Promise<void> {
    if (this.disposed || this.operation === 'recognition') {
      return;
    }
    if (!this.driver.capabilities().recognition) {
      this.stopCurrent();
      this.update('error', '', '当前设备暂不支持语音输入，请使用文字输入。');
      return;
    }
    const id = this.begin('recognition');
    this.update('starting', '', '正在准备语音输入，请允许使用麦克风…');
    this.setTimer(id, 30000, () => this.recognitionFailed(id, '语音输入准备超时，请检查麦克风权限后重试。'));
    if (!this.active(id)) {
      return;
    }
    const events: RecognitionEvents = {
      onStart: () => {
        if (!this.active(id) || this.current.phase !== 'starting') {
          return;
        }
        this.update('listening', this.current.transcript, '正在聆听，说完后点“完成录音”。');
        this.setTimer(id, 60000, () => this.finishListening());
      },
      onResult: (text: string) => {
        if (this.active(id)) {
          this.update(this.current.phase, text, this.current.message);
        }
      },
      onComplete: () => {
        if (!this.active(id)) {
          return;
        }
        const transcript = this.current.transcript;
        this.invalidate();
        if (transcript.trim().length === 0) {
          this.update('error', '', '没有识别到文字，请重试或直接输入。');
        } else {
          this.update('review', transcript, this.reviewMessage(transcript));
        }
      },
      onError: (message: string) => {
        this.recognitionFailed(id, message.trim().length > 0 ? message : '语音识别失败，请重试或直接输入。');
      }
    };
    try {
      await this.driver.startListening(id, events);
      if (!this.active(id)) {
        // Permission may finish after cancellation. The driver must cancel by this old ID only.
        this.driver.cancelListening(id);
      }
    } catch (error) {
      this.recognitionFailed(id, error instanceof VoiceInteractionError && error.message.trim().length > 0
        ? error.message : '语音识别启动失败，请重试或直接输入。');
    }
  }

  finishListening(): void {
    if (this.disposed || this.operation !== 'recognition') {
      return;
    }
    if (this.current.phase === 'starting') {
      this.cancel();
      return;
    }
    if (this.current.phase !== 'listening') {
      return;
    }
    const id = this.operationId;
    this.update('recognizing', this.current.transcript, '正在整理识别结果…');
    this.setTimer(id, 15000, () => this.recognitionFailed(id, '等待识别结果超时。'));
    if (!this.active(id)) {
      return;
    }
    try {
      this.driver.finishListening(id);
    } catch (error) {
      this.recognitionFailed(id, error instanceof VoiceInteractionError && error.message.trim().length > 0
        ? error.message : '录音结束失败，请重试。');
    }
  }

  cancel(): void {
    if (this.disposed) {
      return;
    }
    this.stopCurrent();
    this.update('idle', '', '');
  }

  suspend(): void {
    if (this.disposed) {
      return;
    }
    const phase = this.current.phase;
    const transcript = this.current.transcript;
    const message = this.current.message;
    const wasRecognizing = this.operation === 'recognition';
    this.stopCurrent();
    if (phase === 'review') {
      // A page switch must retain edits, including an intentionally empty review.
      this.update('review', transcript, message);
    } else if (wasRecognizing && transcript.trim().length > 0) {
      this.update('review', transcript, `录音已停止，已识别文字保留在此。${this.reviewMessage(transcript)}`);
    } else {
      this.update('idle', '', '');
    }
  }

  editTranscript(text: string): void {
    if (this.disposed || this.current.phase !== 'review') {
      return;
    }
    this.update('review', text, this.reviewMessage(text));
  }

  takeTranscript(): string {
    if (this.disposed || this.current.phase !== 'review') {
      return '';
    }
    const text = this.current.transcript.trim();
    if (text.length === 0) {
      this.update('review', this.current.transcript, '请先填写文字，或重新录制语音。');
      return '';
    }
    if (characterCount(text) > 8000) {
      this.update('review', this.current.transcript, this.reviewMessage(text));
      return '';
    }
    this.invalidate();
    this.update('idle', '', '');
    return text;
  }

  private speechFailed(id: string, message: string): void {
    if (this.active(id)) {
      this.stopCurrent();
      this.update('error', '', message);
    }
  }

  async speak(messageId: string, text: string): Promise<void> {
    if (this.disposed) {
      return;
    }
    if (this.operation === 'recognition' ||
      (this.current.phase === 'review' && this.current.transcript.trim().length > 0)) {
      this.update(this.current.phase, this.current.transcript, '请先使用或取消语音文字，再朗读回答。');
      return;
    }
    if (this.operation === 'speech' && this.current.speakingMessageId === messageId) {
      return;
    }
    const readable = speechText(text);
    if (readable.length === 0 || !this.driver.capabilities().synthesis) {
      this.stopCurrent();
      this.update('error', '', readable.length === 0 ? '这条回答没有可朗读的文字。'
        : '当前设备暂不支持朗读，请阅读文字回答。');
      return;
    }
    const id = this.begin('speech');
    this.update('preparingSpeech', '', '正在准备朗读…', messageId);
    this.setTimer(id, 30000, () => this.speechFailed(id, '朗读准备超时，请稍后重试。'));
    if (!this.active(id)) {
      return;
    }
    const events: SpeechEvents = {
      onStart: () => {
        if (!this.active(id) || this.current.phase !== 'preparingSpeech') {
          return;
        }
        this.update('speaking', '', '正在朗读，可随时停止。', messageId);
        this.setTimer(id, 15 * 60 * 1000, () => this.speechFailed(id, '朗读时间过长，已停止。可重新选择回答朗读。'));
      },
      onComplete: () => {
        if (this.active(id)) {
          this.invalidate();
          this.update('idle', '', '朗读已结束。');
        }
      },
      onError: (message: string) => {
        this.speechFailed(id, message.trim().length > 0 ? message : '朗读失败，请稍后重试。');
      }
    };
    try {
      await this.driver.speak(id, readable, events);
    } catch (error) {
      this.speechFailed(id, error instanceof VoiceInteractionError && error.message.trim().length > 0
        ? error.message : '朗读启动失败，请稍后重试。');
    }
  }

  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.stopCurrent();
    this.current = { phase: 'idle', transcript: '', message: '', speakingMessageId: '' };
    try {
      this.driver.dispose();
    } catch {
      // Disposed state and invalidated operation IDs remain authoritative.
    }
  }
}
