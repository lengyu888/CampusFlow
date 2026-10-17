import { ActionReceipt, PendingAction, PlanningTaskDraft, PendingTaskPreview, PendingMilestonePreview,
  CourseReview, CourseOverlap, CourseAcknowledgement, CandidateTaskReceipt, CourseAcknowledgementReceipt } from '../model/ApiModels';

function nonempty(value: string | undefined): boolean { return typeof value === 'string' && value.trim().length > 0; }
function version(value: number): boolean { return Number.isInteger(value) && value >= 0; }
function digest(value: string): boolean { return typeof value === 'string' && /^[a-f0-9]{64}$/.test(value); }
function validDate(value: string): boolean {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) { return false; }
  const parsed = Date.parse(`${value}T00:00:00Z`);
  return Number.isFinite(parsed) && new Date(parsed).toISOString().substring(0, 10) === value;
}
function timestamp(value: string | null): number {
  if (typeof value !== 'string') { return NaN; }
  return Date.parse(/Z$|[+-]\d{2}:\d{2}$/.test(value) ? value : `${value}+08:00`);
}
export function courseCandidates(action: PendingAction): PlanningTaskDraft[] {
  if (action.action === 'delete') { return []; }
  if (action.kind === 'task') { return action.payload.task === undefined ? [] : [action.payload.task]; }
  if (action.action !== 'create') { return []; }
  const tasks: PlanningTaskDraft[] = [];
  (action.payload.milestones ?? []).forEach((milestone: PendingMilestonePreview) => {
    milestone.tasks.forEach((task: PendingTaskPreview) => tasks.push(task));
  });
  return tasks;
}
function validOverlap(value: CourseOverlap, task: PlanningTaskDraft): boolean {
  if (value === null || typeof value !== 'object' || !digest(value.course_key) ||
    value.course === null || typeof value.course !== 'object') { return false; }
  const course = value.course;
  if (!nonempty(course.title) || !validDate(course.date) ||
    !/^([01]\d|2[0-3]):[0-5]\d$/.test(course.start_time) || !/^([01]\d|2[0-3]):[0-5]\d$/.test(course.end_time) ||
    typeof course.location !== 'string' || typeof course.teacher !== 'string') { return false; }
  const start = Math.max(timestamp(task.start_at), timestamp(`${course.date}T${course.start_time}:00+08:00`));
  const end = Math.min(timestamp(task.end_at), timestamp(`${course.date}T${course.end_time}:00+08:00`));
  return Number.isFinite(start) && Number.isFinite(end) && end > start &&
    timestamp(value.overlap_start_at) === start && timestamp(value.overlap_end_at) === end;
}

// Missing v1 is legacy, never a way to grant course permission. The server remains authoritative.
export function validCoursePolicy(action: PendingAction): boolean {
  const candidates = courseCandidates(action);
  if (action.course_policy_version === undefined || action.course_policy_version === 0) {
    return candidates.every((task: PlanningTaskDraft) => task.allow_during_course !== true) &&
      (action.course_reviews === undefined || (Array.isArray(action.course_reviews) && action.course_reviews.length === 0));
  }
  if (action.course_policy_version !== 1 || action.state_version === undefined || action.state_version === null || typeof action.state_version !== 'object' ||
    !version(action.state_version.timetable) || !version(action.state_version.planning) ||
    !Array.isArray(action.course_reviews) || action.course_reviews.length !== candidates.length ||
    !candidates.every((task: PlanningTaskDraft) => nonempty(task.candidate_id) && typeof task.allow_during_course === 'boolean') ||
    new Set<string>(candidates.map((task: PlanningTaskDraft) => task.candidate_id ?? '')).size !== candidates.length) { return false; }
  const seen: string[] = [];
  return action.course_reviews.every((review: CourseReview) => {
    if (review === null || typeof review !== 'object' || seen.includes(review.candidate_id)) { return false; }
    seen.push(review.candidate_id);
    const task = candidates.find((item: PlanningTaskDraft) => item.candidate_id === review.candidate_id);
    if (task === undefined || review.allow_during_course !== task.allow_during_course ||
      !['none', 'accepted', 'needs_review', 'blocked', 'unchecked'].includes(review.state) ||
      !digest(review.review_digest) || !digest(review.candidate_digest) ||
      typeof review.requires_acknowledgement !== 'boolean' || typeof review.revoke_only !== 'boolean' ||
      typeof review.school !== 'string' || typeof review.campus !== 'string' || review.timezone !== 'Asia/Shanghai' ||
      review.timetable_version !== action.state_version?.timetable || review.planning_version !== action.state_version?.planning ||
      (review.task_version !== null && (!Number.isInteger(review.task_version) || review.task_version < 1)) ||
      review.task_id !== (action.action === 'update' && action.kind === 'task' ? action.target_task_id : null) ||
      !Array.isArray(review.overlaps) || !review.overlaps.every((item: CourseOverlap) => validOverlap(item, task))) { return false; }
    if (review.requires_acknowledgement !== (review.state === 'needs_review' && review.allow_during_course && review.overlaps.length > 0)) { return false; }
    if ((review.state === 'none' || review.state === 'unchecked') && review.overlaps.length > 0) { return false; }
    if (['accepted', 'needs_review', 'blocked'].includes(review.state) && review.overlaps.length === 0) { return false; }
    if (review.state === 'accepted' && !review.allow_during_course) { return false; }
    if (review.revoke_only && (review.allow_during_course || action.action !== 'update' || action.before_task?.allow_during_course !== true)) { return false; }
    return true;
  });
}

export function requiredCourseAcknowledgements(action: PendingAction): CourseAcknowledgement[] {
  if (!validCoursePolicy(action)) { return []; }
  return (action.course_reviews ?? []).filter((review: CourseReview) => review.requires_acknowledgement)
    .map((review: CourseReview): CourseAcknowledgement => ({ candidate_id: review.candidate_id, review_digest: review.review_digest }));
}
export function validCourseAcknowledgements(action: PendingAction, values: CourseAcknowledgement[]): boolean {
  if (!validCoursePolicy(action) || !Array.isArray(values)) { return false; }
  const required = requiredCourseAcknowledgements(action);
  if (!values.every((value: CourseAcknowledgement) => value !== null && typeof value === 'object' && nonempty(value.candidate_id) && digest(value.review_digest))) { return false; }
  return values.length === required.length && new Set<string>(values.map((value: CourseAcknowledgement) => value.candidate_id)).size === values.length &&
    values.every((value: CourseAcknowledgement) => required.some((item: CourseAcknowledgement) =>
      item.candidate_id === value.candidate_id && item.review_digest === value.review_digest));
}

export function validCourseReceipt(action: PendingAction, receipt: ActionReceipt): boolean {
  if (action.course_policy_version !== 1) { return true; }
  const tasks = courseCandidates(action);
  const pairs = receipt.candidate_tasks;
  const acks = receipt.course_acknowledgements;
  const ids = receipt.course_acknowledgement_ids;
  const required = requiredCourseAcknowledgements(action);
  if (!Array.isArray(pairs) || !Array.isArray(acks) || !Array.isArray(ids) ||
    !pairs.every((pair: CandidateTaskReceipt) => pair !== null && typeof pair === 'object' && nonempty(pair.candidate_id) && nonempty(pair.task_id)) ||
    !acks.every((ack: CourseAcknowledgementReceipt) => ack !== null && typeof ack === 'object' && nonempty(ack.candidate_id) && nonempty(ack.acknowledgement_id)) ||
    !ids.every((id: string) => nonempty(id)) || pairs.length !== tasks.length ||
    acks.length !== required.length || ids.length !== acks.length ||
    new Set<string>(pairs.map((pair: CandidateTaskReceipt) => pair.candidate_id)).size !== pairs.length ||
    new Set<string>(pairs.map((pair: CandidateTaskReceipt) => pair.task_id)).size !== pairs.length ||
    new Set<string>(ids).size !== ids.length || new Set<string>(acks.map((ack: CourseAcknowledgementReceipt) => ack.candidate_id)).size !== acks.length) { return false; }
  return pairs.every((pair: CandidateTaskReceipt) => pair !== null && tasks.some((task: PlanningTaskDraft) => task.candidate_id === pair.candidate_id) &&
    receipt.task_ids.includes(pair.task_id)) && acks.every((ack: CourseAcknowledgementReceipt, index: number) =>
      ack !== null && nonempty(ack.acknowledgement_id) && ack.acknowledgement_id === ids[index] &&
      required.some((item: CourseAcknowledgement) => item.candidate_id === ack.candidate_id));
}

function reviewIdentity(value: CourseReview): string {
  return JSON.stringify([value.candidate_id, value.task_id, value.allow_during_course, value.state, value.review_digest,
    value.requires_acknowledgement, value.revoke_only, value.school, value.campus, value.timezone,
    value.timetable_version, value.planning_version, value.task_version, value.candidate_digest,
    value.overlaps.map((item: CourseOverlap) => [item.course_key, item.course.date, item.course.title,
      item.course.start_time, item.course.end_time, item.course.location, item.course.teacher, item.overlap_start_at, item.overlap_end_at])]);
}
export function sameCoursePolicy(left: PendingAction, right: PendingAction): boolean {
  return validCoursePolicy(left) && validCoursePolicy(right) && left.course_policy_version === right.course_policy_version &&
    left.state_version?.timetable === right.state_version?.timetable && left.state_version?.planning === right.state_version?.planning &&
    (left.course_reviews ?? []).length === (right.course_reviews ?? []).length &&
    (left.course_reviews ?? []).every((review: CourseReview, index: number) => reviewIdentity(review) === reviewIdentity((right.course_reviews ?? [])[index]));
}
export function sameCourseReceipt(left: ActionReceipt, right: ActionReceipt): boolean {
  const leftTasks = left.candidate_tasks ?? []; const rightTasks = right.candidate_tasks ?? [];
  const leftAcks = left.course_acknowledgements ?? []; const rightAcks = right.course_acknowledgements ?? [];
  const leftIds = left.course_acknowledgement_ids ?? []; const rightIds = right.course_acknowledgement_ids ?? [];
  return Array.isArray(leftTasks) && Array.isArray(rightTasks) && Array.isArray(leftAcks) && Array.isArray(rightAcks) &&
    Array.isArray(leftIds) && Array.isArray(rightIds) && leftTasks.length === rightTasks.length &&
    leftAcks.length === rightAcks.length && leftIds.length === rightIds.length &&
    leftTasks.every((item: CandidateTaskReceipt, index: number) => item !== null && rightTasks[index] !== null &&
      item.candidate_id === rightTasks[index].candidate_id && item.task_id === rightTasks[index].task_id) &&
    leftAcks.every((item: CourseAcknowledgementReceipt, index: number) => item !== null && rightAcks[index] !== null &&
      item.candidate_id === rightAcks[index].candidate_id && item.acknowledgement_id === rightAcks[index].acknowledgement_id) &&
    leftIds.every((id: string, index: number) => id === rightIds[index]);
}
