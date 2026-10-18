import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { validation as focusValidation, CampusFlowRequestError, uuid, deferred, tick } from './focus-fixture.mjs';
import { DraftMemoryDriver } from './local-draft-fixture.mjs';
const read = name => readFileSync(new URL(`../../entry/src/main/ets/utils/${name}.ets`, import.meta.url), 'utf8');
const clean = source => source.replace(/^import \{[\s\S]*?\} from '[^']+';\r?\n/gm, '').replace(/^import [^\n]+;\r?\n/gm, '');
const load = (name, dependencies, exports) => new Function(...Object.keys(dependencies), stripTypeScriptTypes(clean(read(name)).replace(/^export /gm, '')) + `\nreturn {${exports.join(',')}}`)(...Object.values(dependencies));
const feedback = load('AgentFeedback', {}, ['CampusFlowRequestError','localRequestFailure']);
export const time = load('ReviewTime', {}, ['reviewRange','reviewShiftAnchor','reviewToday','reviewInstant','reviewCompare','reviewDifferenceUs','reviewMulDiv','reviewClip','REVIEW_MAX_SPAN_US']);
export const validation = load('ReviewValidation', { ...time, ...focusValidation }, ['validateReview']);
export const summary = load('ReviewSummary', { ...time, ...validation }, ['reviewSummary']);
export const { ReviewController, emptyReviewState } = load('ReviewController', { ...time, ...validation, ...feedback }, ['ReviewController','emptyReviewState']);
export const { DraftStore, reviewNoteKey } = load('DraftStore', {}, ['DraftStore','reviewNoteKey']);
export { DraftMemoryDriver, CampusFlowRequestError, uuid, deferred, tick };
export function reviewTask(extra = {}) {
  return { task_id: 'task-a', title: '私密课程复习', task_version: 2, status: 'completed', created_at: '2030-10-18T01:00:00Z',
    start_at: null, end_at: null, completed_at: '2030-10-19T09:00:00+08:00', completion_operation_id: uuid(91), completion_evidence: 'operation_receipt', ...extra };
}
export function reviewInterval(extra = {}) {
  return { interval_id: uuid(21), segment_id: uuid(22), clock_session_id: uuid(23), sequence: 1,
    started_at: '2030-10-19T08:00:00+08:00', ended_at: '2030-10-19T08:25:00+08:00', elapsed_ms: 1500000, ...extra };
}
export function reviewAllocation(interval = reviewInterval(), period = 'day', anchor = '2030-10-19', extra = {}) {
  const clip = time.reviewClip(interval.started_at, interval.ended_at, interval.elapsed_ms, time.reviewRange(period, anchor));
  if (!clip) throw Error('fixture interval must intersect period');
  return { record_id: uuid(30), task_id: 'task-a', task_title: '私密课程复习', task_missing: false, record_revision: 2, interval,
    span_us: clip.spanUs, clip_from_us: clip.fromUs, clip_to_us: clip.toUs, allocated_elapsed_ms: clip.allocatedMs, ...extra };
}
export function reviewSnapshot(period = 'day', anchor = '2030-10-19', extra = {}) {
  const range = time.reviewRange(period, anchor);
  return { contract_version: 1, user_id: 'account-a', period, anchor, timezone: 'Asia/Shanghai', timezone_policy: 'fixed_utc_plus_08',
    period_start: range.start, period_end: range.end, as_of: '2030-10-20T01:00:00Z', snapshot_digest: 'a'.repeat(64),
    totals: { current_completed_count: 0, current_unscheduled_count: 0, confirmed_elapsed_ms: 0, unknown_gap_count: 0 },
    completed_tasks: [], unscheduled_tasks: [], unattributed_completed_tasks: [], focus_intervals: [], unknown_gaps: [], ...extra };
}
export function populatedReview() {
  const allocation = reviewAllocation();
  return reviewSnapshot('day', '2030-10-19', {
    completed_tasks: [reviewTask()],
    unscheduled_tasks: [reviewTask({ task_id: 'task-b', status: 'pending', completion_operation_id: null, completed_at: null, completion_evidence: 'pending' })],
    unattributed_completed_tasks: [reviewTask({ task_id: 'task-c', completion_operation_id: null, completed_at: null, completion_evidence: 'unattributed' })],
    focus_intervals: [allocation], unknown_gaps: [{ record_id: allocation.record_id, task_id: allocation.task_id, task_title: allocation.task_title,
      task_missing: false, record_revision: 2, gap: { gap_id: uuid(24), segment_id: uuid(22), reason: 'process_interrupted',
        observed_start_at: '2030-10-19T08:25:00+08:00', observed_end_at: null } }],
    totals: { current_completed_count: 1, current_unscheduled_count: 1, confirmed_elapsed_ms: 1500000, unknown_gap_count: 1 }
  });
}
export function reviewFixture() {
  const calls = [], changes = [];
  const api = { async review(period, anchor) { calls.push([period, anchor]); return reviewSnapshot(period, anchor); } };
  const controller = new ReviewController(state => changes.push(state));
  controller.configure('https://example.test|account-a', 'account-a', api); controller.setActive(true);
  return { api, calls, changes, controller, state: () => controller.snapshot() };
}
