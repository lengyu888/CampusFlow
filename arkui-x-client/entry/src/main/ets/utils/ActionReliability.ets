import { ActionReceipt, PendingAction, PendingMilestonePreview, PendingTaskPreview,
  PlanningTaskDraft, PlanningPlanDraft, PlanningTask, PlanSummary, PlanMilestone } from '../model/ApiModels';

function text(value: string): boolean { return typeof value === 'string' && value.trim().length > 0; }
function nullableText(value: string | null): boolean { return value === null || typeof value === 'string'; }
function dateTime(value: string | null): boolean {
  return value === null || (text(value) && Number.isFinite(Date.parse(value)));
}
function reminder(value: number | null): boolean {
  return value === null || (typeof value === 'number' && Number.isInteger(value) && value >= 0);
}
function taskFields(value: PlanningTaskDraft | PendingTaskPreview, requireValidRange: boolean = true): boolean {
  return value !== null && typeof value === 'object' && !Array.isArray(value) && text(value.title) &&
    dateTime(value.start_at) && dateTime(value.end_at) && nullableText(value.location) && reminder(value.reminder_minutes) &&
    (!requireValidRange || value.start_at === null || value.end_at === null || Date.parse(value.end_at) > Date.parse(value.start_at));
}
function planFields(value: PlanningPlanDraft): boolean {
  return value !== null && typeof value === 'object' && !Array.isArray(value) && text(value.title) &&
    typeof value.summary === 'string' && dateTime(value.target_date);
}
function taskSnapshot(value: PlanningTask | null | undefined, id: string): boolean {
  return value !== undefined && value !== null && typeof value === 'object' && value.task_id === id &&
    // An old reversed interval is evidence to display, and may be repaired or deleted.
    // Only the new candidate needs a valid interval; the before snapshot must remain exact.
    taskFields(value, false) && nullableText(value.plan_id) && nullableText(value.milestone_id) &&
    ['pending', 'completed'].includes(value.status) && typeof value.source === 'string' && dateTime(value.created_at) &&
    dateTime(value.completed_at);
}
function planSnapshot(value: PlanSummary | null | undefined, id: string): boolean {
  return value !== undefined && value !== null && typeof value === 'object' && value.plan_id === id && planFields(value) &&
    typeof value.status === 'string' && typeof value.progress === 'number' && Number.isFinite(value.progress) &&
    Number.isInteger(value.task_count) && value.task_count >= 0 && Number.isInteger(value.completed_count) &&
    value.completed_count >= 0 && Number.isInteger(value.overdue_count) && value.overdue_count >= 0 &&
    Array.isArray(value.milestones) && value.milestones.every((milestone: PlanMilestone) =>
      milestone !== null && typeof milestone === 'object' && text(milestone.milestone_id) && text(milestone.title) &&
      dateTime(milestone.due_at) && Number.isInteger(milestone.task_count) && milestone.task_count >= 0 &&
      Number.isInteger(milestone.completed_count) && milestone.completed_count >= 0);
}

// Legacy proposals remain readable. This does not authorize their execution.
export function validActionPreview(action: PendingAction): boolean {
  if (action === null || typeof action !== 'object' || Array.isArray(action) || !text(action.proposal_id) ||
    !['create', 'update', 'delete'].includes(action.action) || !['task', 'plan'].includes(action.kind) || !text(action.title) ||
    !nullableText(action.start_at) || !nullableText(action.end_at) || !reminder(action.reminder_minutes) ||
    !nullableText(action.reason) || !['pending', 'confirmed', 'cancelled'].includes(action.status) ||
    !Array.isArray(action.conflicts) || !action.conflicts.every((conflict: string) => typeof conflict === 'string') ||
    action.payload === null || typeof action.payload !== 'object' || Array.isArray(action.payload)) { return false; }
  const payload = action.payload;
  if (payload.summary !== undefined && typeof payload.summary !== 'string') { return false; }
  if (payload.target_date !== undefined && !nullableText(payload.target_date)) { return false; }
  if (payload.location !== undefined && !nullableText(payload.location)) { return false; }
  if (action.warnings !== undefined && (!Array.isArray(action.warnings) ||
    !action.warnings.every((warning: string) => typeof warning === 'string'))) { return false; }
  if (payload.task !== undefined && !taskFields(payload.task)) { return false; }
  if (payload.plan !== undefined && !planFields(payload.plan)) { return false; }
  if (payload.milestones !== undefined && (!Array.isArray(payload.milestones) ||
    !payload.milestones.every((milestone: PendingMilestonePreview) => milestone !== null &&
      typeof milestone === 'object' && text(milestone.title) && nullableText(milestone.due_at) &&
      Array.isArray(milestone.tasks) && milestone.tasks.every((task: PendingTaskPreview) => taskFields(task))))) { return false; }
  return true;
}

export function validReliableAction(action: PendingAction): boolean {
  if (!validActionPreview(action) || action.contract_version !== 2 || !text(action.created_at ?? '') ||
    !text(action.expires_at ?? '') || !Number.isFinite(Date.parse(action.created_at ?? '')) ||
    !Number.isFinite(Date.parse(action.expires_at ?? '')) ||
    Date.parse(action.expires_at ?? '') <= Date.parse(action.created_at ?? '')) { return false; }
  if (action.kind === 'task' && action.action !== 'delete') {
    const task = action.payload.task;
    if (task === undefined || action.title !== task.title || action.start_at !== task.start_at ||
      action.end_at !== task.end_at || action.reminder_minutes !== task.reminder_minutes ||
      (action.payload.location !== undefined && action.payload.location !== task.location)) { return false; }
  } else if (action.start_at !== null || action.end_at !== null || action.reminder_minutes !== null) { return false; }
  if (action.kind === 'plan' && action.action === 'update' && action.title !== action.payload.plan?.title) { return false; }
  if (action.action === 'create') {
    if (action.target_task_id !== null || action.target_plan_id !== null || action.before_task !== null || action.before_plan !== null) { return false; }
    return action.kind === 'task' ? action.payload.task !== undefined && taskFields(action.payload.task) :
      typeof action.payload.summary === 'string' && dateTime(action.payload.target_date ?? null) &&
      Array.isArray(action.payload.milestones) && action.payload.milestones.length > 0 &&
      action.payload.milestones.every((milestone: PendingMilestonePreview) => milestone.tasks.length > 0 && dateTime(milestone.due_at));
  }
  if (action.kind === 'task') {
    const id = action.target_task_id ?? '';
    return text(id) && action.target_plan_id === null && action.before_plan === null && taskSnapshot(action.before_task, id) &&
      (action.action === 'delete' ? action.title === action.before_task?.title :
        (action.payload.task !== undefined && taskFields(action.payload.task)));
  }
  const id = action.target_plan_id ?? '';
  return text(id) && action.target_task_id === null && action.before_task === null && planSnapshot(action.before_plan, id) &&
    (action.action === 'delete' ? action.title === action.before_plan?.title :
      (action.payload.plan !== undefined && planFields(action.payload.plan)));
}

function ids(value: string[]): boolean {
  return Array.isArray(value) && value.every((id: string) => text(id)) && new Set<string>(value).size === value.length;
}

function sameIds(left: string[], right: string[]): boolean {
  return left.length === right.length && left.every((id: string, index: number) => id === right[index]);
}

export function validatedActionReceipt(action: PendingAction): ActionReceipt | null {
  if (!validReliableAction(action) || action.status !== 'confirmed') { return null; }
  const receipt = action.receipt;
  if (receipt === undefined || receipt === null || typeof receipt !== 'object' || !text(receipt.receipt_id) ||
    receipt.proposal_id !== action.proposal_id || receipt.action !== action.action || receipt.kind !== action.kind ||
    !text(receipt.applied_at) || !Number.isFinite(Date.parse(receipt.applied_at)) || !ids(receipt.task_ids) ||
    !ids(receipt.plan_ids) || !ids(receipt.milestone_ids) || !ids(receipt.retained_task_ids)) { return null; }
  if (action.kind === 'task') {
    // The v2 task endpoint changes one task and does not write its owning plan/milestones.
    if (receipt.task_ids.length !== 1 || receipt.plan_ids.length > 0 || receipt.milestone_ids.length > 0 || receipt.retained_task_ids.length > 0 ||
      (action.action !== 'create' && receipt.task_ids[0] !== action.target_task_id)) { return null; }
  } else if (receipt.plan_ids.length !== 1 ||
    (action.action !== 'create' && receipt.plan_ids[0] !== action.target_plan_id)) { return null; }
  if (action.kind === 'plan' && action.action === 'create') {
    let count = 0;
    (action.payload.milestones ?? []).forEach((milestone: PendingMilestonePreview) => count += milestone.tasks.length);
    if (receipt.task_ids.length !== count || receipt.milestone_ids.length !== action.payload.milestones?.length ||
      receipt.retained_task_ids.length > 0) { return null; }
  }
  if (action.kind === 'plan' && action.action === 'update' &&
    (receipt.task_ids.length > 0 || receipt.milestone_ids.length > 0 || receipt.retained_task_ids.length > 0)) { return null; }
  if (action.kind === 'plan' && action.action === 'delete' &&
    (receipt.task_ids.length > 0 || receipt.retained_task_ids.length !== action.before_plan?.task_count ||
      receipt.milestone_ids.length !== action.before_plan?.milestones.length ||
      !receipt.milestone_ids.every((id: string) => action.before_plan?.milestones.some((item: PlanMilestone) => item.milestone_id === id) ?? false))) { return null; }
  return receipt;
}

export function receiptTaskId(action: PendingAction): string {
  const receipt = validatedActionReceipt(action);
  return receipt !== null && action.kind === 'task' && action.action !== 'delete' ? receipt.task_ids[0] : '';
}

export function receiptPlanId(action: PendingAction): string {
  const receipt = validatedActionReceipt(action);
  return receipt !== null && action.kind === 'plan' && action.action !== 'delete' ? receipt.plan_ids[0] : '';
}

export function sameActionReceipt(left: ActionReceipt | null | undefined, right: ActionReceipt | null | undefined): boolean {
  if (left === null || left === undefined || right === null || right === undefined) { return left === right; }
  return left.receipt_id === right.receipt_id && left.proposal_id === right.proposal_id && left.action === right.action &&
    left.kind === right.kind && left.applied_at === right.applied_at && ids(left.task_ids) && ids(right.task_ids) &&
    ids(left.plan_ids) && ids(right.plan_ids) && ids(left.milestone_ids) && ids(right.milestone_ids) &&
    ids(left.retained_task_ids) && ids(right.retained_task_ids) &&
    sameIds(left.task_ids, right.task_ids) && sameIds(left.plan_ids, right.plan_ids) &&
    sameIds(left.milestone_ids, right.milestone_ids) && sameIds(left.retained_task_ids, right.retained_task_ids);
}

export function decisionDisposition(action: PendingAction, nowMs: number = Date.now()): string {
  if (!validActionPreview(action)) { return 'invalid'; }
  if (action.contract_version !== 2) { return 'legacy'; }
  if (!validReliableAction(action)) { return 'invalid'; }
  if (action.status === 'confirmed') { return validatedActionReceipt(action) === null ? 'invalid' : 'confirmed'; }
  if (action.status === 'cancelled') { return action.receipt === null ? 'cancelled' : 'invalid'; }
  if (action.receipt !== null) { return 'invalid'; }
  if (Date.parse(action.expires_at ?? '') <= nowMs) { return 'expired'; }
  return action.conflicts.length > 0 ? 'conflict' : 'ready';
}

export function canConfirmAction(action: PendingAction, nowMs: number = Date.now()): boolean {
  return decisionDisposition(action, nowMs) === 'ready';
}

function sameTaskFields(left: PlanningTaskDraft | undefined, right: PlanningTaskDraft | undefined): boolean {
  if (left === undefined || right === undefined) { return left === right; }
  return left.title === right.title && left.start_at === right.start_at && left.end_at === right.end_at &&
    left.location === right.location && left.reminder_minutes === right.reminder_minutes;
}
function samePlanFields(left: PlanningPlanDraft | undefined, right: PlanningPlanDraft | undefined): boolean {
  if (left === undefined || right === undefined) { return left === right; }
  return left.title === right.title && left.summary === right.summary && left.target_date === right.target_date;
}
function sameTaskBefore(left: PlanningTask | null | undefined, right: PlanningTask | null | undefined): boolean {
  if (left === null || left === undefined || right === null || right === undefined) { return left === right; }
  return taskSnapshot(left, left.task_id) && taskSnapshot(right, right.task_id) &&
    sameTaskFields(left, right) && left.task_id === right.task_id && left.plan_id === right.plan_id &&
    left.milestone_id === right.milestone_id && left.status === right.status && left.source === right.source &&
    left.created_at === right.created_at && left.completed_at === right.completed_at;
}
function samePlanBefore(left: PlanSummary | null | undefined, right: PlanSummary | null | undefined): boolean {
  if (left === null || left === undefined || right === null || right === undefined) { return left === right; }
  return planSnapshot(left, left.plan_id) && planSnapshot(right, right.plan_id) &&
    samePlanFields(left, right) && left.plan_id === right.plan_id && left.status === right.status &&
    left.progress === right.progress && left.task_count === right.task_count && left.completed_count === right.completed_count &&
    left.overdue_count === right.overdue_count && left.created_at === right.created_at && left.milestones.length === right.milestones.length &&
    left.milestones.every((item: PlanMilestone, index: number) => item.milestone_id === right.milestones[index].milestone_id &&
      item.title === right.milestones[index].title && item.due_at === right.milestones[index].due_at &&
      item.task_count === right.milestones[index].task_count && item.completed_count === right.milestones[index].completed_count);
}
function sameMilestones(left: PendingMilestonePreview[] | undefined, right: PendingMilestonePreview[] | undefined): boolean {
  if (left === undefined || right === undefined) { return left === right; }
  return left.length === right.length && left.every((item: PendingMilestonePreview, index: number) =>
    item.title === right[index].title && item.due_at === right[index].due_at && item.tasks.length === right[index].tasks.length &&
    item.tasks.every((task: PendingTaskPreview, taskIndex: number) => sameTaskFields(task, right[index].tasks[taskIndex])));
}

export function sameActionCandidate(original: PendingAction, latest: PendingAction): boolean {
  return validActionPreview(original) && validActionPreview(latest) && original.proposal_id === latest.proposal_id &&
    original.contract_version === latest.contract_version && original.action === latest.action && original.kind === latest.kind &&
    original.target_task_id === latest.target_task_id && original.target_plan_id === latest.target_plan_id &&
    original.title === latest.title && original.start_at === latest.start_at && original.end_at === latest.end_at &&
    original.reminder_minutes === latest.reminder_minutes && original.created_at === latest.created_at && original.expires_at === latest.expires_at &&
    sameTaskFields(original.payload.task, latest.payload.task) && samePlanFields(original.payload.plan, latest.payload.plan) &&
    original.payload.summary === latest.payload.summary && original.payload.target_date === latest.payload.target_date &&
    original.payload.location === latest.payload.location && sameMilestones(original.payload.milestones, latest.payload.milestones) &&
    sameTaskBefore(original.before_task, latest.before_task) && samePlanBefore(original.before_plan, latest.before_plan);
}
