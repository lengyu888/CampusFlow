import { FocusRequest, FocusInterval, FocusGap } from '../model/FocusModels';
import { timestamp } from './DailyAgenda';

function utf8(value: string): number[] {
  const bytes: number[] = [];
  for (let i = 0; i < value.length; i++) {
    let point = value.charCodeAt(i);
    if (point >= 0xd800 && point <= 0xdbff && i + 1 < value.length) {
      const low = value.charCodeAt(i + 1);
      if (low >= 0xdc00 && low <= 0xdfff) { point = 0x10000 + ((point - 0xd800) << 10) + low - 0xdc00; i++; }
    }
    if (point < 0x80) { bytes.push(point); }
    else if (point < 0x800) { bytes.push(0xc0 | point >>> 6, 0x80 | point & 63); }
    else if (point < 0x10000) { bytes.push(0xe0 | point >>> 12, 0x80 | point >>> 6 & 63, 0x80 | point & 63); }
    else { bytes.push(0xf0 | point >>> 18, 0x80 | point >>> 12 & 63, 0x80 | point >>> 6 & 63, 0x80 | point & 63); }
  }
  return bytes;
}
function rotate(value: number, bits: number): number { return value >>> bits | value << 32 - bits; }
export function focusSha256(value: string): string {
  const constants: number[] = [0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,
    0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,
    0xd192e819,0xd6990624,0xf40e3585,0x106aa070,0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2];
  const h: number[] = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19];
  const bytes = utf8(value); const length = bytes.length * 8; bytes.push(128);
  while (bytes.length % 64 !== 56) { bytes.push(0); }
  const upper = Math.floor(length / 4294967296); const lower = length >>> 0;
  for (let shift = 24; shift >= 0; shift -= 8) { bytes.push(upper >>> shift & 255); }
  for (let shift = 24; shift >= 0; shift -= 8) { bytes.push(lower >>> shift & 255); }
  for (let offset = 0; offset < bytes.length; offset += 64) {
    const w: number[] = [];
    for (let i = 0; i < 16; i++) { const at = offset + i * 4; w.push(bytes[at] << 24 | bytes[at + 1] << 16 | bytes[at + 2] << 8 | bytes[at + 3]); }
    for (let i = 16; i < 64; i++) {
      const s0 = rotate(w[i - 15], 7) ^ rotate(w[i - 15], 18) ^ w[i - 15] >>> 3;
      const s1 = rotate(w[i - 2], 17) ^ rotate(w[i - 2], 19) ^ w[i - 2] >>> 10;
      w.push((w[i - 16] + s0 + w[i - 7] + s1) | 0);
    }
    let a = h[0]; let b = h[1]; let c = h[2]; let d = h[3]; let e = h[4]; let f = h[5]; let g = h[6]; let z = h[7];
    for (let i = 0; i < 64; i++) {
      const t1 = (z + (rotate(e,6) ^ rotate(e,11) ^ rotate(e,25)) + ((e & f) ^ (~e & g)) + constants[i] + w[i]) | 0;
      const t2 = ((rotate(a,2) ^ rotate(a,13) ^ rotate(a,22)) + ((a & b) ^ (a & c) ^ (b & c))) | 0;
      z = g; g = f; f = e; e = d + t1 | 0; d = c; c = b; b = a; a = t1 + t2 | 0;
    }
    const next: number[] = [a,b,c,d,e,f,g,z]; for (let i = 0; i < 8; i++) { h[i] = h[i] + next[i] | 0; }
  }
  return h.map((value: number) => (value >>> 0).toString(16).padStart(8, '0')).join('');
}
function iso(value: string): string {
  const stamp = timestamp(value); if (stamp === null) { throw new Error('日期不可核验'); }
  const fraction = /\.(\d+)/.exec(value); const micro = (fraction?.[1] ?? '').substring(0,6).padEnd(6,'0');
  return new Date(stamp).toISOString().substring(0,19) + (micro === '000000' ? '' : '.' + micro) + 'Z';
}
function entry(key: string, value: string): string { return JSON.stringify(key) + ':' + value; }
function text(value: string): string { return JSON.stringify(value); }
function interval(value: FocusInterval): string {
  return '{' + [entry('clock_session_id',text(value.clock_session_id)),entry('elapsed_ms',String(value.elapsed_ms)),entry('ended_at',text(iso(value.ended_at))),
    entry('interval_id',text(value.interval_id)),entry('segment_id',text(value.segment_id)),entry('sequence',String(value.sequence)),entry('started_at',text(iso(value.started_at)))].join(',') + '}';
}
function gap(value: FocusGap): string {
  return '{' + [entry('gap_id',text(value.gap_id)),entry('observed_end_at',value.observed_end_at === null ? 'null' : text(iso(value.observed_end_at))),
    entry('observed_start_at',text(iso(value.observed_start_at))),entry('reason',text(value.reason)),entry('segment_id',text(value.segment_id))].join(',') + '}';
}
// Exactly the backend's typed request -> UTC microseconds -> sorted compact UTF-8 JSON.
// Explicit fields avoid a generic dynamic-object serializer in shared ArkTS.
export function focusRequestDigest(userId: string, recordId: string, value: FocusRequest): string {
  const fields: string[] = [];
  if (value.kind !== 'delete') { fields.push(entry('clock_session_id',value.clock_session_id === null ? 'null' : text(value.clock_session_id))); }
  fields.push(entry('device_id',text(value.device_id)),entry('expected_revision',String(value.expected_revision)));
  if (value.kind === 'pause' || value.kind === 'end') { fields.push(entry('intervals','[' + value.intervals.map((item: FocusInterval) => interval(item)).join(',') + ']')); }
  fields.push(entry('kind',text(value.kind)),entry('occurred_at',text(iso(value.occurred_at))),entry('operation_id',text(value.operation_id)));
  if (value.kind === 'end') { fields.push(entry('reason',text(value.reason))); }
  if (value.kind === 'pause' || value.kind === 'end') { fields.push(entry('segment_id',value.segment_id === null ? 'null' : text(value.segment_id))); }
  if (value.kind === 'start') { fields.push(entry('target_ms',value.target_ms === null ? 'null' : String(value.target_ms)),entry('task_id',text(value.task_id))); }
  if (value.kind === 'pause' || value.kind === 'end') { fields.push(entry('unknown_gaps','[' + value.unknown_gaps.map((item: FocusGap) => gap(item)).join(',') + ']')); }
  const request = '{' + fields.join(',') + '}';
  return focusSha256('{' + entry('record_id',text(recordId)) + ',' + entry('request',request) + ',' + entry('user_id',text(userId)) + '}');
}
