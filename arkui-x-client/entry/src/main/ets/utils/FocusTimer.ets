import { FocusClockSample, FocusInterval, FocusGap } from '../model/FocusModels';

export const FOCUS_SAMPLE_MS: number = 1000;
export const FOCUS_CHECKPOINT_MS: number = 5000;
export const FOCUS_MAX_SAMPLE_MS: number = 10000;
export const FOCUS_WALL_TOLERANCE_MS: number = 2000;
export interface FocusAnchor {
  recordId: string; segmentId: string; intervalId: string; clockSessionId: string; sequence: number;
  firstSample: FocusClockSample; lastAcceptedSample: FocusClockSample; elapsedMs: number;
}
export type FocusGapReason = 'process_interrupted' | 'clock_changed' | 'sample_gap' | 'remote_end' | 'storage_failed';
export interface FocusTimerResult { accepted: boolean; reason: string; }
export function validFocusSample(value: FocusClockSample): boolean {
  return value !== null && typeof value === 'object' && Number.isSafeInteger(value.wallMs) && value.wallMs >= 0 &&
    value.wallMs <= 253402300799999 && Number.isSafeInteger(value.monotonicMs) && value.monotonicMs >= 0 &&
    typeof value.clockSessionId === 'string' && /^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/i.test(value.clockSessionId);
}
function copySample(value: FocusClockSample): FocusClockSample {
  return { wallMs: value.wallMs, monotonicMs: value.monotonicMs, clockSessionId: value.clockSessionId };
}
export function copyFocusAnchor(value: FocusAnchor): FocusAnchor {
  return { recordId: value.recordId, segmentId: value.segmentId, intervalId: value.intervalId, clockSessionId: value.clockSessionId,
    sequence: value.sequence, firstSample: copySample(value.firstSample), lastAcceptedSample: copySample(value.lastAcceptedSample), elapsedMs: value.elapsedMs };
}
// No timer, wall-clock fallback or persistence lives here. The caller supplies real
// samples and owns the app-foreground generation and durable checkpoint barrier.
export class FocusTimer {
  private anchor: FocusAnchor;
  constructor(anchor: FocusAnchor) { this.anchor = copyFocusAnchor(anchor); }
  snapshot(): FocusAnchor { return copyFocusAnchor(this.anchor); }
  accept(sample: FocusClockSample): FocusTimerResult {
    if (!validFocusSample(sample) || sample.clockSessionId !== this.anchor.clockSessionId) { return { accepted: false, reason: 'process_interrupted' }; }
    const previous = this.anchor.lastAcceptedSample;
    const mono = sample.monotonicMs - previous.monotonicMs;
    if (mono < 0) { return { accepted: false, reason: 'clock_changed' }; }
    if (mono > FOCUS_MAX_SAMPLE_MS) { return { accepted: false, reason: 'sample_gap' }; }
    const elapsed = sample.monotonicMs - this.anchor.firstSample.monotonicMs;
    if (Math.abs(sample.wallMs - previous.wallMs - mono) > FOCUS_WALL_TOLERANCE_MS ||
      Math.abs(sample.wallMs - this.anchor.firstSample.wallMs - elapsed) > FOCUS_WALL_TOLERANCE_MS) {
      return { accepted: false, reason: 'clock_changed' };
    }
    if (elapsed > 86400000) { return { accepted: false, reason: 'sample_gap' }; }
    this.anchor.lastAcceptedSample = copySample(sample); this.anchor.elapsedMs = elapsed;
    return { accepted: true, reason: '' };
  }
  interval(): FocusInterval | null {
    if (this.anchor.elapsedMs <= 0) { return null; }
    return { interval_id: this.anchor.intervalId, segment_id: this.anchor.segmentId, clock_session_id: this.anchor.clockSessionId,
      sequence: this.anchor.sequence, started_at: new Date(this.anchor.firstSample.wallMs).toISOString(),
      ended_at: new Date(this.anchor.firstSample.wallMs + this.anchor.elapsedMs).toISOString(), elapsed_ms: this.anchor.elapsedMs };
  }
  gap(id: string, reason: FocusGapReason, observedEnd: number | null = null): FocusGap {
    return { gap_id: id, segment_id: this.anchor.segmentId, reason: reason,
      observed_start_at: new Date(this.anchor.lastAcceptedSample.wallMs).toISOString(),
      observed_end_at: observedEnd === null ? null : new Date(observedEnd).toISOString() };
  }
}
