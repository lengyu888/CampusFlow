import { ReviewSnapshot, ReviewTask, ReviewPeriod, ReviewAllocation, ReviewUnknownGap } from '../model/ReviewModels';
import { FocusInterval, FocusGap } from '../model/FocusModels';
import { focusKeys, focusInteger, focusUuid } from './FocusValidation';
import { reviewRange, reviewInstant, reviewCompare, reviewClip, reviewDifferenceUs, ReviewRange } from './ReviewTime';

interface RecordEvidence { taskId: string; title: string | null; missing: boolean; revision: number; }
interface TaskEvidence { title: string | null; missing: boolean; }
function id(value: string): boolean { return typeof value === 'string' && value.length > 0; }
function operationId(value: string): boolean {
  return typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value);
}
function time(value: string): boolean { return reviewInstant(value) !== null; }
function optionalTime(value: string | null): boolean { return value === null || time(value); }
function inRange(value: string, range: ReviewRange): boolean {
  const point = reviewInstant(value); const start = reviewInstant(range.start); const end = reviewInstant(range.end);
  return point !== null && start !== null && end !== null && reviewCompare(point, start) >= 0 && reviewCompare(point, end) < 0;
}
function sameTime(left: string, right: string): boolean {
  const a = reviewInstant(left); const b = reviewInstant(right);
  return a !== null && b !== null && reviewCompare(a, b) === 0;
}
function task(value: ReviewTask, category: string, range: ReviewRange): boolean {
  if (!focusKeys(value, ['task_id','title','task_version','status','created_at','start_at','end_at','completed_at',
    'completion_operation_id','completion_evidence']) || !id(value.task_id) || typeof value.title !== 'string' ||
    !focusInteger(value.task_version, 1, Number.MAX_SAFE_INTEGER) || !time(value.created_at) || !optionalTime(value.start_at) ||
    !optionalTime(value.end_at) || !optionalTime(value.completed_at) ||
    !(value.completion_operation_id === null || operationId(value.completion_operation_id))) { return false; }
  if (category === 'unscheduled') {
    return value.status === 'pending' && value.start_at === null && value.completed_at === null &&
      value.completion_operation_id === null && value.completion_evidence === 'pending';
  }
  if (value.status !== 'completed') { return false; }
  if (category === 'unattributed') {
    return value.completed_at === null && value.completion_operation_id === null && value.completion_evidence === 'unattributed';
  }
  return value.completed_at !== null && inRange(value.completed_at, range) &&
    (value.completion_operation_id === null ? value.completion_evidence === 'current_task_time' : value.completion_evidence === 'operation_receipt');
}
function interval(value: FocusInterval): boolean {
  if (!focusKeys(value, ['interval_id','segment_id','clock_session_id','sequence','started_at','ended_at','elapsed_ms']) ||
    !focusUuid(value.interval_id) || !focusUuid(value.segment_id) || !focusUuid(value.clock_session_id) ||
    !focusInteger(value.sequence, 1, Number.MAX_SAFE_INTEGER) || !focusInteger(value.elapsed_ms, 1, 86400000)) { return false; }
  const start = reviewInstant(value.started_at); const end = reviewInstant(value.ended_at);
  if (start === null || end === null) { return false; }
  const span = reviewDifferenceUs(start, end);
  return span !== null && span > 0 && Math.abs(span - value.elapsed_ms * 1000) <= 2000000;
}
function gap(value: FocusGap): boolean {
  return focusKeys(value, ['gap_id','segment_id','reason','observed_start_at','observed_end_at']) && focusUuid(value.gap_id) &&
    focusUuid(value.segment_id) && ['process_interrupted','clock_changed','sample_gap','remote_end','storage_failed'].includes(value.reason) &&
    time(value.observed_start_at) && optionalTime(value.observed_end_at);
}
function metadata(value: ReviewAllocation | ReviewUnknownGap, records: Map<string, RecordEvidence>, tasks: Map<string, TaskEvidence>): boolean {
  if (!focusUuid(value.record_id) || !id(value.task_id) || !(value.task_title === null || typeof value.task_title === 'string') ||
    typeof value.task_missing !== 'boolean' || (value.task_missing ? value.task_title !== null : value.task_title === null) ||
    !focusInteger(value.record_revision, 1, Number.MAX_SAFE_INTEGER)) { return false; }
  const knownTask = tasks.get(value.task_id);
  if (knownTask !== undefined && (knownTask.title !== value.task_title || knownTask.missing !== value.task_missing)) { return false; }
  tasks.set(value.task_id, { title: value.task_title, missing: value.task_missing });
  const known = records.get(value.record_id);
  if (known !== undefined) { return known.taskId === value.task_id && known.title === value.task_title &&
    known.missing === value.task_missing && known.revision === value.record_revision; }
  records.set(value.record_id, { taskId: value.task_id, title: value.task_title, missing: value.task_missing, revision: value.record_revision });
  return true;
}
function withinBytes(value: ReviewSnapshot): boolean {
  const text = JSON.stringify(value);
  if (text.length > 2097152) { return false; }
  let bytes = 0;
  for (let i = 0; i < text.length; i++) {
    const unit = text.charCodeAt(i);
    if (unit < 0x80) { bytes++; } else if (unit < 0x800) { bytes += 2; }
    else if (unit >= 0xD800 && unit <= 0xDBFF && text.charCodeAt(i + 1) >= 0xDC00 && text.charCodeAt(i + 1) <= 0xDFFF) { bytes += 4; i++; }
    else { bytes += 3; }
    if (bytes > 2097152) { return false; }
  }
  return true;
}

// Validates identity and the arithmetic of every returned source. The digest is a
// snapshot identifier, not independent proof that the server omitted no records.
export function validateReview(value: ReviewSnapshot, userId: string, period: ReviewPeriod, anchor: string): boolean {
  try { return validateSnapshot(value, userId, period, anchor); } catch (_) { return false; }
}
function validateSnapshot(value: ReviewSnapshot, userId: string, period: ReviewPeriod, anchor: string): boolean {
  const range = reviewRange(period, anchor);
  if (range === null || !id(userId) || !focusKeys(value, ['contract_version','user_id','period','anchor','timezone','timezone_policy',
    'period_start','period_end','as_of','snapshot_digest','totals','completed_tasks','unscheduled_tasks','unattributed_completed_tasks',
    'focus_intervals','unknown_gaps']) || value.contract_version !== 1 || value.user_id !== userId || value.period !== period ||
    value.anchor !== anchor || value.timezone !== 'Asia/Shanghai' || value.timezone_policy !== 'fixed_utc_plus_08' ||
    !sameTime(value.period_start, range.start) || !sameTime(value.period_end, range.end) || !time(value.as_of) ||
    typeof value.snapshot_digest !== 'string' || !/^[a-f0-9]{64}$/.test(value.snapshot_digest) ||
    !focusKeys(value.totals, ['current_completed_count','current_unscheduled_count','confirmed_elapsed_ms','unknown_gap_count']) ||
    !Array.isArray(value.completed_tasks) || !Array.isArray(value.unscheduled_tasks) || !Array.isArray(value.unattributed_completed_tasks) ||
    !Array.isArray(value.focus_intervals) || !Array.isArray(value.unknown_gaps) ||
    value.completed_tasks.length + value.unscheduled_tasks.length + value.unattributed_completed_tasks.length > 10000 ||
    value.focus_intervals.length + value.unknown_gaps.length > 5000 || !withinBytes(value)) { return false; }
  const totals = value.totals;
  if (!focusInteger(totals.current_completed_count, 0, 10000) || !focusInteger(totals.current_unscheduled_count, 0, 10000) ||
    !focusInteger(totals.confirmed_elapsed_ms, 0, 5000 * 86400000) || !focusInteger(totals.unknown_gap_count, 0, 5000) ||
    totals.current_completed_count !== value.completed_tasks.length || totals.current_unscheduled_count !== value.unscheduled_tasks.length ||
    totals.unknown_gap_count !== value.unknown_gaps.length ||
    !value.completed_tasks.every((item: ReviewTask) => task(item, 'completed', range)) ||
    !value.unscheduled_tasks.every((item: ReviewTask) => task(item, 'unscheduled', range)) ||
    !value.unattributed_completed_tasks.every((item: ReviewTask) => task(item, 'unattributed', range))) { return false; }
  const taskIds = value.completed_tasks.concat(value.unscheduled_tasks, value.unattributed_completed_tasks).map((item: ReviewTask) => item.task_id);
  if (new Set<string>(taskIds).size !== taskIds.length) { return false; }
  const ids = new Set<string>(); const records = new Map<string, RecordEvidence>(); const segments = new Map<string, FocusInterval[]>();
  const tasks = new Map<string, TaskEvidence>();
  value.completed_tasks.concat(value.unscheduled_tasks, value.unattributed_completed_tasks).forEach((item: ReviewTask) => {
    tasks.set(item.task_id, { title: item.title, missing: false });
  });
  let total = 0;
  for (const item of value.focus_intervals) {
    if (!focusKeys(item, ['record_id','task_id','task_title','task_missing','record_revision','interval','span_us','clip_from_us','clip_to_us','allocated_elapsed_ms']) ||
      !metadata(item, records, tasks) || !interval(item.interval) || ids.has(item.interval.interval_id)) { return false; }
    ids.add(item.interval.interval_id);
    const clip = reviewClip(item.interval.started_at, item.interval.ended_at, item.interval.elapsed_ms, range);
    if (clip === null || clip.spanUs !== item.span_us || clip.fromUs !== item.clip_from_us || clip.toUs !== item.clip_to_us ||
      clip.allocatedMs !== item.allocated_elapsed_ms) { return false; }
    total += clip.allocatedMs;
    const key = `${item.record_id}:${item.interval.segment_id}`;
    const group = segments.get(key) ?? []; group.push(item.interval); segments.set(key, group);
  }
  if (total !== totals.confirmed_elapsed_ms) { return false; }
  for (const item of value.unknown_gaps) {
    if (!focusKeys(item, ['record_id','task_id','task_title','task_missing','record_revision','gap']) || !metadata(item, records, tasks) ||
      !gap(item.gap) || !inRange(item.gap.observed_start_at, range) || ids.has(item.gap.gap_id)) { return false; }
    ids.add(item.gap.gap_id);
  }
  let coherent = true;
  segments.forEach((pieces: FocusInterval[]) => {
    pieces.sort((a: FocusInterval, b: FocusInterval) => a.sequence - b.sequence);
    for (let index = 1; index < pieces.length; index++) {
      const first = pieces[index - 1]; const second = pieces[index];
      const end = reviewInstant(first.ended_at); const start = reviewInstant(second.started_at);
      if (first.sequence === second.sequence || first.clock_session_id !== second.clock_session_id || end === null || start === null ||
        reviewCompare(end, start) > 0) { coherent = false; }
    }
  });
  return coherent;
}
