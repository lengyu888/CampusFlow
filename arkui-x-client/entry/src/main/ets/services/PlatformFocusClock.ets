import deviceInfo from '@ohos.deviceInfo';
import { FocusClock, FocusClockSample } from '../model/FocusModels';
import { timetableOperationId } from '../utils/TimetableMaintenance';

interface FocusClockReading { wall_ms?: number; monotonic_ms?: number; }
interface FocusClockSource { read(): Promise<FocusClockReading>; }
interface FocusClockNativePort { request(op: string): Promise<FocusClockReading>; }
export interface FocusClockEnvironment {
  platform(): string;
  harmony(): Promise<FocusClockSource>;
  native(): Promise<FocusClockNativePort>;
  sessionId(): string;
}

class DeviceFocusClockEnvironment implements FocusClockEnvironment {
  platform(): string { return deviceInfo.osFullName; }
  async harmony(): Promise<FocusClockSource> {
    const module = await import('./HarmonyFocusClock');
    return new module.HarmonyFocusClock();
  }
  async native(): Promise<FocusClockNativePort> {
    const module = await import('./NativePlatformBridge');
    return module.nativePlatformBridge(); // The same receiver already used by voice/reminders.
  }
  sessionId(): string { return timetableOperationId(); }
}

export class FocusClockError extends Error {
  code: string;
  constructor(code: string) {
    super('设备计时服务暂不可用，本次未开始计时。请稍后重试。');
    this.name = 'FocusClockError'; this.code = code;
  }
}

// This facade supplies samples only. FocusTimer decides which foreground spans are countable.
// A fresh facade uses a random session ID: persisted uptime is never compared across restarts.
export class PlatformFocusClock implements FocusClock {
  private environment: FocusClockEnvironment;
  private session: string;
  private harmonySource: Promise<FocusClockSource> | null = null;
  private nativeSource: Promise<FocusClockNativePort> | null = null;
  constructor(environment: FocusClockEnvironment = new DeviceFocusClockEnvironment()) {
    this.environment = environment; this.session = environment.sessionId();
  }
  async sample(): Promise<FocusClockSample> {
    try {
      if (!/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(this.session)) {
        throw new FocusClockError('FOCUS_CLOCK_INVALID_RESPONSE');
      }
      const platform = this.environment.platform();
      let reading: FocusClockReading;
      if (platform.startsWith('HarmonyOS') || platform.startsWith('OpenHarmony')) {
        if (this.harmonySource === null) { this.harmonySource = this.environment.harmony(); }
        reading = await (await this.harmonySource).read();
      } else if (platform.startsWith('Android') || platform.startsWith('iOS') || platform.startsWith('iPadOS')) {
        if (this.nativeSource === null) { this.nativeSource = this.environment.native(); }
        reading = await (await this.nativeSource).request('clock.sample');
      } else { throw new FocusClockError('FOCUS_CLOCK_UNAVAILABLE'); }
      if (reading === null || typeof reading !== 'object' || Array.isArray(reading) ||
        typeof reading.wall_ms !== 'number' || !Number.isSafeInteger(reading.wall_ms) || reading.wall_ms <= 0 || reading.wall_ms > 8640000000000000 ||
        typeof reading.monotonic_ms !== 'number' || !Number.isSafeInteger(reading.monotonic_ms) || reading.monotonic_ms < 0) {
        throw new FocusClockError('FOCUS_CLOCK_INVALID_RESPONSE');
      }
      return { wallMs: reading.wall_ms, monotonicMs: reading.monotonic_ms, clockSessionId: this.session };
    } catch (error) {
      this.harmonySource = null; this.nativeSource = null;
      if (error instanceof FocusClockError) { throw error; }
      throw new FocusClockError('FOCUS_CLOCK_UNAVAILABLE');
    }
  }
}
