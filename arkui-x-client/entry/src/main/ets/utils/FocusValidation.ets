import { FocusRequest, FocusOperation, FocusRecord, FocusDetail, FocusList, FocusActive, FocusInterval, FocusGap } from '../model/FocusModels';
import { timestamp } from './DailyAgenda';
import { focusRequestDigest } from './FocusDigest';

export function focusUuid(value: string): boolean {
  return typeof value === 'string' && /^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/.test(value);
}
export function focusInteger(value: number, minimum: number = 0, maximum: number = Number.MAX_SAFE_INTEGER - 1): boolean {
  return Number.isSafeInteger(value) && value >= minimum && value <= maximum;
}
export function focusKeys(value: Object, names: string[]): boolean {
  return value !== null && typeof value === 'object' && !Array.isArray(value) && Object.keys(value).length === names.length &&
    Object.keys(value).every((key: string) => names.includes(key));
}
export function focusIso(value: string): boolean {
  return typeof value === 'string' && /(?:Z|[+-]\d{2}:\d{2})$/.test(value) && timestamp(value) !== null;
}
export function focusTarget(value: number | null): boolean { return value === null || focusInteger(value, 60000, 14400000); }
function digest(value: string): boolean { return typeof value === 'string' && /^[a-f0-9]{64}$/.test(value); }
function unique(values: string[]): boolean { return new Set<string>(values).size === values.length; }
export function validFocusInterval(value: FocusInterval): boolean {
  if (!focusKeys(value, ['interval_id','segment_id','clock_session_id','sequence','started_at','ended_at','elapsed_ms']) ||
    !focusUuid(value.interval_id) || !focusUuid(value.segment_id) || !focusUuid(value.clock_session_id) ||
    !focusInteger(value.sequence, 1) || !focusInteger(value.elapsed_ms, 1, 86400000) || !focusIso(value.started_at) || !focusIso(value.ended_at)) { return false; }
  const span = (timestamp(value.ended_at) ?? 0) - (timestamp(value.started_at) ?? 0);
  return span > 0 && Math.abs(span - value.elapsed_ms) <= 2000;
}
export function validFocusGap(value: FocusGap): boolean {
  return focusKeys(value, ['gap_id','segment_id','reason','observed_start_at','observed_end_at']) && focusUuid(value.gap_id) && focusUuid(value.segment_id) &&
    ['process_interrupted','clock_changed','sample_gap','remote_end','storage_failed'].includes(value.reason) &&
    focusIso(value.observed_start_at) && (value.observed_end_at === null || focusIso(value.observed_end_at));
}
export function validFocusPieces(intervals: FocusInterval[], gaps: FocusGap[], maximum: number = 100): boolean {
  if (!Array.isArray(intervals) || !Array.isArray(gaps) || intervals.length + gaps.length > maximum ||
    !intervals.every((value: FocusInterval) => validFocusInterval(value)) || !gaps.every((value: FocusGap) => validFocusGap(value)) ||
    !unique(intervals.map((value: FocusInterval) => value.interval_id)) || !unique(gaps.map((value: FocusGap) => value.gap_id)) ||
    !unique(intervals.map((value: FocusInterval) => value.interval_id).concat(gaps.map((value: FocusGap) => value.gap_id)))) { return false; }
  for (let i = 0; i < intervals.length; i++) {
    for (let j = i + 1; j < intervals.length; j++) {
      const a = intervals[i]; const b = intervals[j];
      if (a.segment_id !== b.segment_id) { continue; }
      if (a.clock_session_id !== b.clock_session_id || a.sequence === b.sequence) { return false; }
      const first = a.sequence < b.sequence ? a : b; const second = a.sequence < b.sequence ? b : a;
      if ((timestamp(first.ended_at) ?? 0) > (timestamp(second.started_at) ?? 0)) { return false; }
    }
  }
  return true;
}
export function validFocusRequest(value: FocusRequest): boolean {
  if (value === null || typeof value !== 'object' || !focusUuid(value.operation_id) || !focusUuid(value.device_id) ||
    !focusInteger(value.expected_revision) || !focusIso(value.occurred_at)) { return false; }
  const base: string[] = ['operation_id','kind','expected_revision','device_id','occurred_at'];
  if (value.kind === 'start') { return focusKeys(value, base.concat(['task_id','clock_session_id','target_ms'])) &&
    value.expected_revision === 0 && typeof value.task_id === 'string' && value.task_id.trim().length > 0 && value.task_id.length <= 128 &&
    focusUuid(value.clock_session_id) && focusTarget(value.target_ms); }
  if (value.expected_revision < 1) { return false; }
  if (value.kind === 'delete') { return focusKeys(value, base); }
  if (value.kind === 'resume') { return focusKeys(value, base.concat(['clock_session_id'])) && focusUuid(value.clock_session_id); }
  if (value.kind !== 'pause' && value.kind !== 'end') { return false; }
  if (!focusKeys(value, base.concat(value.kind === 'pause' ? ['segment_id','clock_session_id','intervals','unknown_gaps'] :
    ['reason','segment_id','clock_session_id','intervals','unknown_gaps'])) || !validFocusPieces(value.intervals, value.unknown_gaps)) { return false; }
  if (value.kind === 'end' && !['local_end','remote_end'].includes(value.reason)) { return false; }
  if (value.segment_id === null || value.clock_session_id === null || value.kind === 'end' && value.reason === 'remote_end') {
    return value.kind === 'end' && value.segment_id === null && value.clock_session_id === null && value.intervals.length === 0 && value.unknown_gaps.length === 0;
  }
  return focusUuid(value.segment_id) && focusUuid(value.clock_session_id) &&
    value.intervals.every((piece: FocusInterval) => piece.segment_id === value.segment_id && piece.clock_session_id === value.clock_session_id) &&
    value.unknown_gaps.every((piece: FocusGap) => piece.segment_id === value.segment_id);
}
function sameIds(left: string[], right: string[]): boolean {
  return Array.isArray(left) && unique(left) && left.length === right.length && left.every((id: string) => right.includes(id));
}
export function validFocusOperation(value: FocusOperation, userId: string, recordId: string, request: FocusRequest): boolean {
  if (!validFocusRequest(request) || !focusKeys(value, ['contract_version','user_id','operation_id','record_id','kind','request_digest','receipt']) ||
    value.contract_version !== 1 || value.user_id !== userId || value.record_id !== recordId || !focusUuid(recordId) ||
    value.operation_id !== request.operation_id || value.kind !== request.kind || !digest(value.request_digest) ||
    value.request_digest !== focusRequestDigest(userId, recordId, request)) { return false; }
  const receipt = value.receipt;
  if (!focusKeys(receipt, ['before_revision','after_revision','before_state','after_state','accepted_interval_ids','accepted_gap_ids','added_elapsed_ms','applied_at']) ||
    receipt.before_revision !== request.expected_revision || receipt.after_revision !== request.expected_revision + 1 ||
    !focusInteger(receipt.after_revision, 1) || !focusIso(receipt.applied_at) || !focusInteger(receipt.added_elapsed_ms) ||
    !Array.isArray(receipt.accepted_interval_ids) || !Array.isArray(receipt.accepted_gap_ids) ||
    !receipt.accepted_interval_ids.every((id: string) => focusUuid(id)) || !receipt.accepted_gap_ids.every((id: string) => focusUuid(id))) { return false; }
  if (request.kind === 'start' && (receipt.before_state !== null || receipt.after_state !== 'running') ||
    request.kind === 'resume' && (receipt.before_state !== 'paused' || receipt.after_state !== 'running') ||
    request.kind === 'pause' && (receipt.before_state !== 'running' || receipt.after_state !== 'paused') ||
    request.kind === 'end' && (!['running','paused'].includes(receipt.before_state ?? '') || receipt.after_state !== 'ended') ||
    request.kind === 'delete' && (!['paused','ended'].includes(receipt.before_state ?? '') || receipt.after_state !== 'deleted')) { return false; }
  const intervals = request.kind === 'pause' || request.kind === 'end' ? request.intervals : [];
  const gaps = request.kind === 'pause' || request.kind === 'end' ? request.unknown_gaps : [];
  if (!sameIds(receipt.accepted_interval_ids, intervals.map((item: FocusInterval) => item.interval_id)) ||
    receipt.added_elapsed_ms !== intervals.reduce((total: number, item: FocusInterval) => total + item.elapsed_ms, 0)) { return false; }
  if (request.kind === 'end' && request.reason === 'remote_end') {
    return receipt.accepted_gap_ids.length === (receipt.before_state === 'running' ? 1 : 0);
  }
  if (request.kind === 'end' && (receipt.before_state === 'paused') !== (request.segment_id === null)) { return false; }
  return sameIds(receipt.accepted_gap_ids, gaps.map((item: FocusGap) => item.gap_id));
}
export function validFocusRecord(value: FocusRecord, userId: string): boolean {
  if (!focusKeys(value, ['contract_version','user_id','record_id','task_id','task_title','task_missing','state','revision',
    'creator_device_id','current_device_id','clock_session_id','segment_id','started_at','ended_at','target_ms','confirmed_elapsed_ms',
    'interval_count','unknown_gap_count','created_at','updated_at']) || value.contract_version !== 1 || value.user_id !== userId ||
    !focusUuid(value.record_id) || typeof value.task_id !== 'string' || value.task_id.trim().length === 0 || value.task_id.length > 128 ||
    !(value.task_title === null || typeof value.task_title === 'string') || typeof value.task_missing !== 'boolean' ||
    value.task_missing && value.task_title !== null || !['running','paused','ended'].includes(value.state) || !focusInteger(value.revision, 1) ||
    !focusUuid(value.creator_device_id) || !focusUuid(value.current_device_id) || !focusIso(value.started_at) || !focusIso(value.created_at) ||
    !focusIso(value.updated_at) || !focusTarget(value.target_ms) || !focusInteger(value.confirmed_elapsed_ms) ||
    value.confirmed_elapsed_ms > value.interval_count * 86400000 ||
    !focusInteger(value.interval_count, 0, 2000) || !focusInteger(value.unknown_gap_count, 0, 2000) || value.interval_count + value.unknown_gap_count > 2000) { return false; }
  return (value.state === 'running' ? focusUuid(value.clock_session_id ?? '') && focusUuid(value.segment_id ?? '') : value.clock_session_id === null && value.segment_id === null) &&
    (value.state === 'ended' ? focusIso(value.ended_at ?? '') : value.ended_at === null);
}
export function validFocusDetail(value: FocusDetail, userId: string, recordId: string): boolean {
  return focusKeys(value, ['contract_version','user_id','record','record_revision','intervals','unknown_gaps']) && value.contract_version === 1 &&
    value.user_id === userId && validFocusRecord(value.record, userId) && value.record.record_id === recordId && value.record_revision === value.record.revision &&
    validFocusPieces(value.intervals, value.unknown_gaps, 2000) && value.intervals.length === value.record.interval_count &&
    value.unknown_gaps.length === value.record.unknown_gap_count && value.intervals.reduce((sum: number, item: FocusInterval) => sum + item.elapsed_ms, 0) === value.record.confirmed_elapsed_ms;
}
export function validFocusActive(value: FocusActive, userId: string): boolean {
  return focusKeys(value, ['contract_version','user_id','record']) && value.contract_version === 1 && value.user_id === userId &&
    (value.record === null || validFocusRecord(value.record, userId) && value.record.state !== 'ended');
}
export function validFocusList(value: FocusList, userId: string): boolean {
  return focusKeys(value, ['contract_version','user_id','records','next_cursor','snapshot_token']) && value.contract_version === 1 && value.user_id === userId &&
    Array.isArray(value.records) && value.records.length <= 100 && value.records.every((item: FocusRecord) => validFocusRecord(item, userId) && item.state === 'ended') &&
    unique(value.records.map((item: FocusRecord) => item.record_id)) && digest(value.snapshot_token) &&
    (value.next_cursor === null || typeof value.next_cursor === 'string' && value.next_cursor.length > 0 && value.next_cursor.length <= 4096);
}
