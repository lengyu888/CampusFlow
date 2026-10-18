import { ReviewPeriod } from '../model/ReviewModels';

export interface ReviewRange { start: string; end: string; noteAnchor: string; }
export interface ReviewInstant { wholeMs: number; remainderUs: number; }
export interface ReviewClip { spanUs: number; fromUs: number; toUs: number; allocatedMs: number; }

const DAY_MS: number = 86400000;
const CAMPUS_OFFSET_MS: number = 28800000;
export const REVIEW_MAX_SPAN_US: number = 86402000000;

function dateValid(value: string): boolean {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) { return false; }
  const year = Number(value.slice(0, 4)); const month = Number(value.slice(5, 7)); const day = Number(value.slice(8, 10));
  const leap = year % 400 === 0 || year % 4 === 0 && year % 100 !== 0;
  const lengths: number[] = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  return year >= 1 && year <= 9999 && month >= 1 && month <= 12 && day >= 1 && day <= lengths[month - 1];
}

export function reviewShiftAnchor(anchor: string, days: number): string {
  if (!dateValid(anchor) || !Number.isSafeInteger(days) || Math.abs(days) > 3660000) { return ''; }
  const shifted = new Date(Date.parse(`${anchor}T00:00:00Z`) + days * DAY_MS);
  const year = shifted.getUTCFullYear();
  if (!Number.isFinite(shifted.getTime()) || year < 1 || year > 9999) { return ''; }
  return shifted.toISOString().slice(0, 10);
}

export function reviewToday(nowMs: number = Date.now()): string {
  if (!Number.isFinite(nowMs)) { return ''; }
  const date = new Date(nowMs + CAMPUS_OFFSET_MS);
  if (!Number.isFinite(date.getTime()) || date.getUTCFullYear() < 1 || date.getUTCFullYear() > 9999) { return ''; }
  return date.toISOString().slice(0, 10);
}

export function reviewRange(period: ReviewPeriod, anchor: string): ReviewRange | null {
  if (!dateValid(anchor) || period !== 'day' && period !== 'week') { return null; }
  const weekday = new Date(`${anchor}T00:00:00Z`).getUTCDay();
  const startDate = period === 'week' ? reviewShiftAnchor(anchor, -((weekday + 6) % 7)) : anchor;
  const endDate = reviewShiftAnchor(startDate, period === 'week' ? 7 : 1);
  if (startDate.length === 0 || endDate.length === 0) { return null; }
  const start = `${startDate}T00:00:00+08:00`; const end = `${endDate}T00:00:00+08:00`;
  // The server uses Python datetime years 1..9999, including after conversion to UTC.
  if (reviewInstant(start) === null || reviewInstant(end) === null) { return null; }
  return { start: start, end: end, noteAnchor: startDate };
}

// Keep the last three microsecond digits separately. Absolute epoch microseconds
// are not safe integers for every supported year; milliseconds are safe here.
export function reviewInstant(value: string): ReviewInstant | null {
  if (typeof value !== 'string') { return null; }
  const match = /^(\d{4}-\d{2}-\d{2})T([01]\d|2[0-3]):([0-5]\d):([0-5]\d)(?:\.(\d{1,6}))?(Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)$/.exec(value);
  if (match === null || !dateValid(match[1])) { return null; }
  const fraction = (match[5] ?? '').padEnd(6, '0');
  const ms = Date.parse(`${match[1]}T${match[2]}:${match[3]}:${match[4]}.${fraction.slice(0, 3)}${match[6]}`);
  const year = new Date(ms).getUTCFullYear();
  if (!Number.isSafeInteger(ms) || year < 1 || year > 9999) { return null; }
  return { wholeMs: ms, remainderUs: Number(fraction.slice(3)) };
}

export function reviewCompare(left: ReviewInstant, right: ReviewInstant): number {
  return left.wholeMs < right.wholeMs ? -1 : left.wholeMs > right.wholeMs ? 1 :
    left.remainderUs < right.remainderUs ? -1 : left.remainderUs > right.remainderUs ? 1 : 0;
}

// Only bounded source-relative differences are converted to microseconds.
export function reviewDifferenceUs(start: ReviewInstant, end: ReviewInstant): number | null {
  const whole = end.wholeMs - start.wholeMs;
  if (!Number.isSafeInteger(whole) || Math.abs(whole) > 86402001) { return null; }
  const result = whole * 1000 + end.remainderUs - start.remainderUs;
  return Number.isSafeInteger(result) && result >= 0 && result <= REVIEW_MAX_SPAN_US ? result : null;
}

// floor(elapsed * offset / span), without a product above Number.MAX_SAFE_INTEGER.
// Process elapsed's binary digits; remainder is reduced below span every step.
// Before reduction it is < 3*span, still a safe integer for the bounded span.
export function reviewMulDiv(elapsed: number, offset: number, span: number): number | null {
  if (!Number.isSafeInteger(elapsed) || elapsed < 0 || elapsed > 86400000 || !Number.isSafeInteger(span) || span < 1 ||
    span > REVIEW_MAX_SPAN_US || !Number.isSafeInteger(offset) || offset < 0 || offset > span) { return null; }
  let bit = 1;
  while (bit <= Math.floor(elapsed / 2)) { bit *= 2; }
  let quotient = 0; let remainder = 0; let remaining = elapsed;
  while (bit >= 1) {
    quotient *= 2; remainder *= 2;
    if (remaining >= bit) { remaining -= bit; remainder += offset; }
    quotient += Math.floor(remainder / span); remainder %= span;
    bit /= 2;
  }
  return quotient;
}

export function reviewClip(startIso: string, endIso: string, elapsed: number, range: ReviewRange): ReviewClip | null {
  const start = reviewInstant(startIso); const end = reviewInstant(endIso);
  const periodStart = reviewInstant(range.start); const periodEnd = reviewInstant(range.end);
  if (start === null || end === null || periodStart === null || periodEnd === null ||
    reviewCompare(start, end) >= 0 || reviewCompare(periodStart, periodEnd) >= 0 ||
    reviewCompare(start, periodEnd) >= 0 || reviewCompare(end, periodStart) <= 0) { return null; }
  const clippedStart = reviewCompare(start, periodStart) < 0 ? periodStart : start;
  const clippedEnd = reviewCompare(end, periodEnd) > 0 ? periodEnd : end;
  const span = reviewDifferenceUs(start, end); const from = reviewDifferenceUs(start, clippedStart); const to = reviewDifferenceUs(start, clippedEnd);
  if (span === null || span === 0 || from === null || to === null || from >= to) { return null; }
  const first = reviewMulDiv(elapsed, from, span); const last = reviewMulDiv(elapsed, to, span);
  if (first === null || last === null) { return null; }
  return { spanUs: span, fromUs: from, toUs: to, allocatedMs: last - first };
}
