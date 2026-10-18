import systemDateTime from '@ohos.systemDateTime';

interface HarmonyClockReading { wall_ms: number; monotonic_ms: number; }

// Loaded only after identifying a Harmony/OpenHarmony host. API 10+; device verification pending.
export class HarmonyFocusClock {
  async read(): Promise<HarmonyClockReading> {
    return { wall_ms: Date.now(), monotonic_ms: systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, false) };
  }
}
