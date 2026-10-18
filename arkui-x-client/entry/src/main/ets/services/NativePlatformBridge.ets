import bridge from '@arkui-x.bridge';
import { PlatformReminderItem, PlatformCommandArguments, PlatformServiceResult, PlatformServicePort } from '../model/PlatformServiceTypes';

export type NativeReminderItem = PlatformReminderItem;
export type NativeCommandArguments = PlatformCommandArguments;
interface NativeCommand extends NativeCommandArguments { v: number; request_id: string; op: string; }
export type NativePlatformResult = PlatformServiceResult;
export interface NativeVoiceEvent {
  v: number;
  kind: string;
  operation_id: string;
  event: string;
  text?: string;
  code?: string;
}
interface NativeReply { v: number; kind: string; request_id: string; ok: boolean; code: string; result?: NativePlatformResult; }
export interface NativeBridgeTransport {
  register(receiver: (json: string) => void): Promise<void>;
  dispatch(json: string): Promise<string>;
}
export interface NativeBridgeClock {
  setTimeout(callback: () => void, delay: number): number;
  clearTimeout(id: number): void;
}
class BridgeClock implements NativeBridgeClock {
  setTimeout(callback: () => void, delay: number): number { return setTimeout(callback, delay); }
  clearTimeout(id: number): void { clearTimeout(id); }
}
export class NativeBridgeError extends Error {
  code: string;
  constructor(code: string) {
    super('设备服务暂未完成，请核对状态后重试。');
    this.name = 'NativeBridgeError'; this.code = code;
  }
}
class ArkUIBridgeTransport implements NativeBridgeTransport {
  private port: bridge.BridgeObject;
  constructor() {
    // Called lazily from mounted pages, after UIAbility/window initialization; never at module evaluation.
    this.port = bridge.createBridge('CampusFlowPlatform', bridge.BridgeType.JSON_TYPE);
  }
  async register(receiver: (json: string) => void): Promise<void> {
    await this.port.registerMethod({ name: 'onEvent', method: (...parameters: bridge.Parameter[]): bridge.ResultValue => {
      if (parameters.length !== 1 || typeof parameters[0] !== 'string') { return 'rejected'; }
      receiver(parameters[0] as string);
      return 'accepted';
    } });
  }
  async dispatch(json: string): Promise<string> {
    const result = await this.port.callMethod('dispatch', json);
    return typeof result === 'string' ? result : 'rejected';
  }
}
interface PendingNativeRequest {
  id: string;
  timer: number;
  resolve: (result: NativePlatformResult) => void;
  reject: (error: NativeBridgeError) => void;
}
interface VoiceSubscription { id: number; listener: (event: NativeVoiceEvent) => void; }

function asciiId(value: string, maximum: number): boolean {
  return typeof value === 'string' && value.length > 0 && value.length <= maximum && /^[A-Za-z0-9._-]+$/.test(value);
}

export class NativePlatformBridge implements PlatformServicePort {
  private transport: NativeBridgeTransport;
  private clock: NativeBridgeClock;
  private registration: Promise<void> | null = null;
  private dispatchTail: Promise<void> = Promise.resolve();
  private pending: PendingNativeRequest[] = [];
  private listeners: VoiceSubscription[] = [];
  private sequence: number = 0;
  private prefix: string = `cf-${Date.now().toString(36)}-${Math.random().toString(36).substring(2, 10)}`;

  constructor(transport: NativeBridgeTransport = new ArkUIBridgeTransport(), clock: NativeBridgeClock = new BridgeClock()) {
    this.transport = transport; this.clock = clock;
  }

  subscribeVoice(listener: (event: NativeVoiceEvent) => void): () => void {
    const id = ++this.sequence;
    this.listeners.push({ id: id, listener: listener });
    return () => { this.listeners = this.listeners.filter((item: VoiceSubscription) => item.id !== id); };
  }

  private bounded<T>(promise: Promise<T>, timeout: number): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      let settled = false;
      const timer = this.clock.setTimeout(() => { if (!settled) { settled = true; reject(new NativeBridgeError('TIMEOUT')); } }, timeout);
      promise.then((value: T) => {
        if (!settled) { settled = true; this.clock.clearTimeout(timer); resolve(value); }
      }).catch(() => {
        if (!settled) { settled = true; this.clock.clearTimeout(timer); reject(new NativeBridgeError('UNAVAILABLE')); }
      });
    });
  }

  private ready(): Promise<void> {
    if (this.registration === null) {
      try { this.registration = this.bounded(this.transport.register((json: string) => this.receive(json)), 15000); }
      catch { this.registration = Promise.reject(new NativeBridgeError('UNAVAILABLE')); }
      // Registration is attempted once: a late successful registration must not be duplicated after timeout.
    }
    return this.registration;
  }

  private finish(id: string, result: NativePlatformResult | null, error: string = ''): void {
    const item = this.pending.find((request: PendingNativeRequest) => request.id === id);
    if (item === undefined) { return; }
    this.pending = this.pending.filter((request: PendingNativeRequest) => request.id !== id);
    this.clock.clearTimeout(item.timer);
    if (result !== null) { item.resolve(result); }
    else { item.reject(new NativeBridgeError(error)); }
  }

  private receive(json: string): void {
    if (typeof json !== 'string' || json.length > 150000) { return; }
    try {
      const event = JSON.parse(json) as NativeReply;
      if (event === null || typeof event !== 'object' || event.v !== 1) { return; }
      if (event.kind === 'reply') {
        if (!asciiId(event.request_id, 128) || typeof event.ok !== 'boolean' || typeof event.code !== 'string') { return; }
        if (event.ok) {
          if (event.result === undefined) { this.finish(event.request_id, {}); }
          else if (event.result !== null && typeof event.result === 'object' && !Array.isArray(event.result)) {
            this.finish(event.request_id, event.result);
          } else { this.finish(event.request_id, null, 'INVALID_RESPONSE'); }
        } else {
          const code = ['PERMISSION_DENIED', 'UNAVAILABLE', 'INVALID_REQUEST', 'OPERATION_CANCELLED', 'SYSTEM_ERROR'].includes(event.code) ? event.code : 'SYSTEM_ERROR';
          this.finish(event.request_id, null, code);
        }
      } else if (event.kind === 'voice') {
        const voice = JSON.parse(json) as NativeVoiceEvent;
        if (!asciiId(voice.operation_id, 128) || !['recognition_start', 'recognition_result', 'recognition_complete',
          'recognition_error', 'speech_start', 'speech_complete', 'speech_error'].includes(voice.event) ||
          (voice.text !== undefined && (typeof voice.text !== 'string' || voice.text.length > 64000))) { return; }
        const projected: NativeVoiceEvent = { v: 1, kind: 'voice', operation_id: voice.operation_id, event: voice.event,
          text: voice.text, code: typeof voice.code === 'string' && ['PERMISSION_DENIED', 'UNAVAILABLE', 'INVALID_REQUEST',
            'OPERATION_CANCELLED', 'SYSTEM_ERROR'].includes(voice.code) ? voice.code : 'SYSTEM_ERROR' };
        this.listeners.slice().forEach((item: VoiceSubscription) => { item.listener(projected); });
      }
    } catch { /* Untrusted native data never escapes as raw diagnostics. */ }
  }

  request(op: string, args: NativeCommandArguments = {}): Promise<NativePlatformResult> {
    if (args === null || typeof args !== 'object' || Array.isArray(args)) { return Promise.reject(new NativeBridgeError('INVALID_REQUEST')); }
    if (!['clock.sample', 'capabilities', 'recognition.start', 'recognition.finish', 'recognition.cancel', 'speech.start', 'speech.stop',
      'voice.dispose', 'reminders.status', 'reminders.authorize', 'reminders.replace', 'reminders.clear'].includes(op)) {
      return Promise.reject(new NativeBridgeError('INVALID_REQUEST'));
    }
    if ((op.startsWith('recognition.') || op === 'speech.start') && args.operation_id === undefined ||
      op === 'speech.start' && (typeof args.text !== 'string' || args.text.trim().length === 0) ||
      ['reminders.authorize', 'reminders.replace', 'reminders.clear'].includes(op) && args.scope === undefined ||
      op === 'reminders.replace' && args.reminders === undefined) {
      return Promise.reject(new NativeBridgeError('INVALID_REQUEST'));
    }
    if (op === 'clock.sample' && Object.keys(args).length !== 0) { return Promise.reject(new NativeBridgeError('INVALID_REQUEST')); }
    const id = `${this.prefix}-${++this.sequence}`;
    const command: NativeCommand = { v: 1, request_id: id, op: op };
    if (args.operation_id !== undefined) {
      if (!asciiId(args.operation_id, 128)) { return Promise.reject(new NativeBridgeError('INVALID_REQUEST')); }
      command.operation_id = args.operation_id;
    }
    if (args.text !== undefined) {
      if (typeof args.text !== 'string' || args.text.length > 32000) { return Promise.reject(new NativeBridgeError('INVALID_REQUEST')); }
      command.text = args.text;
    }
    if (args.scope !== undefined) {
      if (typeof args.scope !== 'string' || args.scope.length === 0 || args.scope.length > 512) { return Promise.reject(new NativeBridgeError('INVALID_REQUEST')); }
      command.scope = args.scope;
    }
    if (args.reminders !== undefined) {
      const now = Date.now();
      if (!Array.isArray(args.reminders) || args.reminders.length > 60 || !args.reminders.every((item: NativeReminderItem) =>
        item !== null && typeof item === 'object' && asciiId(item.id, 180) && Number.isSafeInteger(item.fire_at_ms) && item.fire_at_ms > now &&
        item.fire_at_ms <= now + 366 * 86400000) || new Set(args.reminders.map((item: NativeReminderItem) => item.id)).size !== args.reminders.length) {
        return Promise.reject(new NativeBridgeError('INVALID_REQUEST'));
      }
      command.reminders = args.reminders.map((item: NativeReminderItem): NativeReminderItem => ({ id: item.id, fire_at_ms: item.fire_at_ms }));
    }
    const json = JSON.stringify(command);
    return new Promise<NativePlatformResult>((resolve, reject) => {
      const timeout = op === 'recognition.start' || op === 'reminders.authorize' ? 60000 : 15000;
      const timer = this.clock.setTimeout(() => this.finish(id, null, 'TIMEOUT'), timeout);
      this.pending.push({ id: id, timer: timer, resolve: resolve, reject: reject });
      this.ready().then(() => {
        // Serialize only the immediate dispatch ACK. Permission/ASR replies never block cancellation commands.
        this.dispatchTail = this.dispatchTail.then(async () => {
          if (!this.pending.some((item: PendingNativeRequest) => item.id === id)) { return; }
          try {
            const accepted = await this.bounded(this.transport.dispatch(json), 15000);
            if (accepted !== 'accepted') { this.finish(id, null, 'UNAVAILABLE'); }
          } catch { this.finish(id, null, 'UNAVAILABLE'); }
        });
      }).catch(() => this.finish(id, null, 'UNAVAILABLE'));
    });
  }
}

let sharedBridge: NativePlatformBridge | null = null;
export function nativePlatformBridge(): NativePlatformBridge {
  if (sharedBridge === null) { sharedBridge = new NativePlatformBridge(); }
  return sharedBridge;
}
