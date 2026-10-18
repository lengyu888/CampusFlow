import systemDateTime from '@ohos.systemDateTime';
import { PlatformClockReading, PlatformClockSource } from '../model/PlatformServiceTypes';

interface HarmonyClockReading extends PlatformClockReading { wall_ms: number; monotonic_ms: number; }

// Loaded only after identifying a Harmony/OpenHarmony host. API 10+; device verification pending.
export class HarmonyFocusClock implements PlatformClockSource {
  async read(): Promise<HarmonyClockReading> {
    return { wall_ms: Date.now(), monotonic_ms: systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, false) };
  }
}
