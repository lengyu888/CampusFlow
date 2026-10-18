import { CourseAcknowledgement, CourseAcknowledgementReceipt, CourseOverlap, PlanningTask,
  TaskStatusOperation, TaskStatusPreview, TaskStatusReceipt, TaskStatusStartRequest } from '../model/ApiModels';
import { timestamp, courseTimestamp } from './DailyAgenda';

function text(value: string): boolean { return typeof value === 'string' && value.trim().length > 0; }
function nullableText(value: string | null): boolean { return value === null || typeof value === 'string'; }
function version(value: number, minimum: number = 0): boolean { return Number.isSafeInteger(value) && value >= minimum; }
function digest(value: string): boolean { return typeof value === 'string' && /^[a-f0-9]{64}$/.test(value); }
export function taskStatusUuid(value: string): boolean {
  return typeof value === 'string' && /^[a-f0-9]{8}-[a-f0-9]{4}-[1-5][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/i.test(value);
}
export function validTaskStatusRequest(value: TaskStatusStartRequest): boolean {
  if (value === null || typeof value !== 'object' || Array.isArray(value) || !taskStatusUuid(value.operation_id) ||
    !version(value.expected_revision, 1) || value.expected_revision >= Number.MAX_SAFE_INTEGER) { return false; }
  if (value.kind === 'complete') { return !Object.keys(value).includes('source_operation_id'); }
  return value.kind === 'restore' && taskStatusUuid(value.source_operation_id);
}
function validTask(task: PlanningTask, operation: TaskStatusOperation): boolean {
  return task !== null && typeof task === 'object' && !Array.isArray(task) && task.task_id === operation.task_id &&
    task.task_version === operation.expected_revision && task.status === 'completed' &&
    task.completion_operation_id === operation.source_operation_id && text(task.title) &&
    nullableText(task.plan_id) && nullableText(task.milestone_id) && nullableText(task.start_at) && nullableText(task.end_at) &&
    nullableText(task.location) && typeof task.source === 'string' && typeof task.allow_during_course === 'boolean' &&
    (task.reminder_minutes === null || version(task.reminder_minutes)) && timestamp(task.created_at) !== null &&
    timestamp(task.completed_at) !== null;
}
function overlap(value: CourseOverlap, task: PlanningTask): boolean {
  if (value === null || typeof value !== 'object' || !digest(value.course_key) ||
    value.course === null || typeof value.course !== 'object') { return false; }
  const course = value.course;
  if (!text(course.title) || typeof course.location !== 'string' || typeof course.teacher !== 'string') { return false; }
  const start = courseTimestamp(course.date, course.start_time); const end = courseTimestamp(course.date, course.end_time);
  const taskStart = timestamp(task.start_at); const taskEnd = timestamp(task.end_at);
  if (start === null || end === null || end <= start || taskStart === null || taskEnd === null || taskEnd <= taskStart) { return false; }
  const from = Math.max(start, taskStart); const until = Math.min(end, taskEnd);
  return from < until && timestamp(value.overlap_start_at) === from && timestamp(value.overlap_end_at) === until;
}
function validPreview(value: TaskStatusPreview, operation: TaskStatusOperation): boolean {
  if (value === null || typeof value !== 'object' || !validTask(value.task, operation) ||
    value.from_status !== 'completed' || value.to_status !== 'pending' || !text(value.candidate_id) || value.candidate_id.length > 128 ||
    value.state_version === null || typeof value.state_version !== 'object' ||
    !version(value.state_version.timetable) || !version(value.state_version.planning) ||
    !Array.isArray(value.conflicts) || !value.conflicts.every((item: string) => text(item)) ||
    !Array.isArray(value.warnings) || !value.warnings.every((item: string) => text(item))) { return false; }
  const review = value.course_review;
  if (review === null || typeof review !== 'object' || review.candidate_id !== value.candidate_id ||
    review.task_id !== operation.task_id || review.task_version !== operation.expected_revision ||
    review.allow_during_course !== value.task.allow_during_course || review.revoke_only !== false ||
    review.timezone !== 'Asia/Shanghai' || typeof review.school !== 'string' || typeof review.campus !== 'string' ||
    review.timetable_version !== value.state_version.timetable || review.planning_version !== value.state_version.planning ||
    !digest(review.review_digest) || !digest(review.candidate_digest) || typeof review.requires_acknowledgement !== 'boolean' ||
    !Array.isArray(review.overlaps) || !review.overlaps.every((item: CourseOverlap) => overlap(item, value.task))) { return false; }
  // The task's historical accepted course_overlap is not this restore's acknowledgement.
  if (review.overlaps.length > 0) {
    if (review.allow_during_course) { return review.state === 'needs_review' && review.requires_acknowledgement; }
    return review.state === 'blocked' && !review.requires_acknowledgement && value.conflicts.length > 0;
  }
  return ['none', 'unchecked'].includes(review.state) && !review.requires_acknowledgement;
}
export function requiredTaskStatusAcknowledgements(value: TaskStatusOperation): CourseAcknowledgement[] {
  if (value.kind !== 'restore' || value.preview === null || !value.preview.course_review.requires_acknowledgement) { return []; }
  return [{ candidate_id: value.preview.candidate_id, review_digest: value.preview.course_review.review_digest }];
}
export function validTaskStatusAcknowledgements(value: TaskStatusOperation, acknowledgements: CourseAcknowledgement[]): boolean {
  if (!Array.isArray(acknowledgements)) { return false; }
  const required = requiredTaskStatusAcknowledgements(value);
  return acknowledgements.length === required.length && acknowledgements.every((item: CourseAcknowledgement, index: number) =>
    item !== null && typeof item === 'object' && item.candidate_id === required[index].candidate_id && item.review_digest === required[index].review_digest);
}
function validReceipt(receipt: TaskStatusReceipt, operation: TaskStatusOperation): boolean {
  if (receipt === null || typeof receipt !== 'object' || receipt.operation_id !== operation.operation_id ||
    receipt.task_id !== operation.task_id || receipt.kind !== operation.kind || receipt.source_operation_id !== operation.source_operation_id ||
    receipt.before_revision !== operation.expected_revision || receipt.after_revision !== receipt.before_revision + 1 ||
    !version(receipt.after_revision, 2) || timestamp(receipt.applied_at) === null ||
    !Array.isArray(receipt.course_acknowledgement_ids) || !Array.isArray(receipt.course_acknowledgements)) { return false; }
  const expected = requiredTaskStatusAcknowledgements(operation);
  if (receipt.course_acknowledgement_ids.length !== expected.length || receipt.course_acknowledgements.length !== expected.length ||
    !receipt.course_acknowledgement_ids.every((id: string) => text(id)) ||
    !receipt.course_acknowledgements.every((item: CourseAcknowledgementReceipt, index: number) => item !== null &&
      typeof item === 'object' && item.candidate_id === expected[index].candidate_id &&
      item.acknowledgement_id === receipt.course_acknowledgement_ids[index])) { return false; }
  if (operation.kind === 'complete') {
    return receipt.candidate_id === null && receipt.before_status === 'pending' && receipt.after_status === 'completed' &&
      receipt.before_completed_at === null && timestamp(receipt.after_completed_at) !== null;
  }
  return operation.preview !== null && receipt.candidate_id === operation.preview.candidate_id &&
    receipt.before_status === 'completed' && receipt.after_status === 'pending' && receipt.after_completed_at === null &&
    timestamp(receipt.before_completed_at) === timestamp(operation.preview.task.completed_at);
}
export function sameTaskStatusCandidate(left: TaskStatusOperation, right: TaskStatusOperation): boolean {
  return left.contract_version === right.contract_version && left.user_id === right.user_id && left.operation_id === right.operation_id &&
    left.task_id === right.task_id && left.kind === right.kind && left.expected_revision === right.expected_revision &&
    left.source_operation_id === right.source_operation_id && left.created_at === right.created_at &&
    left.expires_at === right.expires_at && JSON.stringify(left.preview) === JSON.stringify(right.preview);
}
export function validTaskStatusOperation(value: TaskStatusOperation, userId: string, taskId: string,
  request: TaskStatusStartRequest, previous: TaskStatusOperation | null = null): boolean {
  if (!validTaskStatusRequest(request) || value === null || typeof value !== 'object' || Array.isArray(value) ||
    value.contract_version !== 1 || value.user_id !== userId || value.task_id !== taskId || value.operation_id !== request.operation_id ||
    value.kind !== request.kind || value.expected_revision !== request.expected_revision ||
    value.source_operation_id !== (request.kind === 'restore' ? request.source_operation_id : null) ||
    timestamp(value.created_at) === null || !['pending', 'applied', 'cancelled'].includes(value.state)) { return false; }
  if (value.kind === 'complete') {
    if (value.state !== 'applied' || value.preview !== null || value.expires_at !== null) { return false; }
  } else {
    const expires = timestamp(value.expires_at); const created = timestamp(value.created_at);
    if (expires === null || created === null || expires <= created || !validPreview(value.preview as TaskStatusPreview, value)) { return false; }
  }
  if (value.state === 'applied' ? !validReceipt(value.receipt as TaskStatusReceipt, value) : value.receipt !== null) { return false; }
  if (previous !== null && (!sameTaskStatusCandidate(previous, value) ||
    (previous.state !== 'pending' && previous.state !== value.state) ||
    (previous.receipt !== null && JSON.stringify(previous.receipt) !== JSON.stringify(value.receipt)))) { return false; }
  return true;
}
export function taskStatusCanConfirm(value: TaskStatusOperation, now: number): boolean {
  const expires = timestamp(value.expires_at);
  return value.kind === 'restore' && value.state === 'pending' && value.preview !== null &&
    value.preview.conflicts.length === 0 && expires !== null && expires > now && value.preview.course_review.state !== 'blocked';
}
