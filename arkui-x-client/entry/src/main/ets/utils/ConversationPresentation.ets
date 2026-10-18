import { PendingAction, PendingMilestonePreview, PlanningTaskDraft, DataEvidence, ToolDisplaySummary, SessionContext, HistoryMessage, CoursePermissionChoice } from '../model/ApiModels';
import { formatPlanDateTime } from './PlanPresentation';
import { normalizeEvidence } from './EvidencePresentation';
import { courseCandidates } from './CourseReview';
import { validReliableAction, sameActionCandidate } from './ActionReliability';

export interface ProposalOverview {
  taskCount: number;
  milestoneCount: number;
  completeTimeCount: number;
  incompleteTimeCount: number;
  timeRange: string;
  deadline: string;
  conflictCount: number;
  warningCount: number;
}

export function conversationTitle(title: string, firstQuestion: string = ''): string {
  const value = title.trim() || firstQuestion.trim();
  return value.length > 0 ? value : '新对话';
}

function timestamp(value: string | null): number {
  if (value === null || typeof value !== 'string' || formatPlanDateTime(value).length !== 16) { return NaN; }
  return Date.parse(/Z$|[+-]\d{2}:\d{2}$/.test(value) ? value : `${value}+08:00`);
}

// A range is only the envelope of explicitly timed tasks, never continuous occupied time.
export function proposalOverview(action: PendingAction): ProposalOverview {
  let tasks: PlanningTaskDraft[] = [];
  if (action.kind === 'task') {
    if (action.action === 'delete' && action.before_task !== undefined && action.before_task !== null) { tasks = [action.before_task]; }
    else if (action.payload.task !== undefined) { tasks = [action.payload.task]; }
    else { tasks = [{ title: action.title, start_at: action.start_at, end_at: action.end_at,
      reminder_minutes: action.reminder_minutes, location: action.payload.location ?? null }]; }
  } else if (action.action === 'create') {
    (action.payload.milestones ?? []).forEach((milestone: PendingMilestonePreview) => { tasks = tasks.concat(milestone.tasks); });
  }
  let first: string | null = null;
  let last: string | null = null;
  let complete = 0;
  tasks.forEach((task: PlanningTaskDraft) => {
    const start = timestamp(task.start_at); const end = timestamp(task.end_at);
    if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start) { return; }
    complete++;
    if (first === null || start < timestamp(first)) { first = task.start_at; }
    if (last === null || end > timestamp(last)) { last = task.end_at; }
  });
  const existingPlan = action.kind === 'plan' && action.action !== 'create';
  return {
    taskCount: existingPlan ? action.before_plan?.task_count ?? 0 : tasks.length,
    milestoneCount: existingPlan ? action.before_plan?.milestones.length ?? 0 : (action.payload.milestones ?? []).length,
    completeTimeCount: complete,
    incompleteTimeCount: existingPlan ? 0 : tasks.length - complete,
    timeRange: existingPlan ? '本次不调整子任务时间' : first === null || last === null ? '尚无完整起止时段' :
      `最早开始 ${formatPlanDateTime(first)} · 最晚结束 ${formatPlanDateTime(last)}（北京时间）`,
    deadline: action.payload.plan?.target_date ?? action.payload.target_date ?? action.before_plan?.target_date ?? '',
    conflictCount: action.conflicts.length,
    warningCount: (action.warnings ?? []).length
  };
}

// Attribution belongs to the answering turn, not an invented reasoning chain for the proposal.
export function proposalSources(tools: ToolDisplaySummary[]): DataEvidence[] {
  const result: DataEvidence[] = [];
  const seen: string[] = [];
  tools.forEach((tool: ToolDisplaySummary) => {
    if (!Array.isArray(tool.evidence) || tool.evidence.length === 0) { return; }
    normalizeEvidence(tool.evidence).forEach((item: DataEvidence) => {
      const key = JSON.stringify([item.source_id, item.label, item.status, item.updated_at, item.expires_at, item.url, item.note]);
      if (!seen.includes(key)) { seen.push(key); result.push(item); }
    });
  });
  return result;
}

export function validSessionContext(value: SessionContext, userId: string, sessionId: string): boolean {
  if (value === null || typeof value !== 'object' || Array.isArray(value) || userId.length === 0 || sessionId.length === 0 ||
    value.user_id !== userId || value.session_id !== sessionId || !/^[a-f0-9]{64}$/.test(value.context_revision) ||
    value.summary === null || typeof value.summary !== 'object' || value.summary.session_id !== sessionId ||
    typeof value.summary.title !== 'string' || typeof value.summary.model_name !== 'string' ||
    !Array.isArray(value.messages) || value.messages.length === 0 || value.summary.message_count !== value.messages.length ||
    typeof value.summary.last_message !== 'string' ||
    typeof value.summary.created_at !== 'string' || !Number.isFinite(Date.parse(value.summary.created_at)) ||
    typeof value.summary.updated_at !== 'string' || !Number.isFinite(Date.parse(value.summary.updated_at)) ||
    !value.messages.every((message: HistoryMessage) => message !== null && typeof message === 'object' &&
      ['user', 'assistant'].includes(message.role) && typeof message.content === 'string' &&
      typeof message.created_at === 'string' && Number.isFinite(Date.parse(message.created_at)))) { return false; }
  return value.active_run === null || (value.active_run !== undefined && typeof value.active_run === 'object' &&
    value.active_run.session_id === sessionId && typeof value.active_run.run_id === 'string' &&
    /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(value.active_run.run_id) &&
    ['queued', 'running'].includes(value.active_run.status));
}

export function samePermissionReplacement(original: PendingAction, replacement: PendingAction, choices: CoursePermissionChoice[]): boolean {
  if (!validReliableAction(original) || !validReliableAction(replacement) || original.proposal_id === replacement.proposal_id ||
    !Array.isArray(choices) || choices.length === 0 || !choices.every((item: CoursePermissionChoice) =>
      item !== null && typeof item === 'object' && typeof item.candidate_id === 'string' && typeof item.allow_during_course === 'boolean') || new Set<string>(choices.map((item: CoursePermissionChoice) => item.candidate_id)).size !== choices.length) { return false; }
  const expected = JSON.parse(JSON.stringify(original)) as PendingAction;
  const tasks = courseCandidates(expected);
  if (!choices.every((choice: CoursePermissionChoice) => typeof choice.allow_during_course === 'boolean' &&
    tasks.some((task: PlanningTaskDraft) => task.candidate_id === choice.candidate_id))) { return false; }
  tasks.forEach((task: PlanningTaskDraft) => {
    const choice = choices.find((item: CoursePermissionChoice) => item.candidate_id === task.candidate_id);
    if (choice !== undefined) { task.allow_during_course = choice.allow_during_course; }
  });
  expected.proposal_id = replacement.proposal_id;
  expected.created_at = replacement.created_at; expected.expires_at = replacement.expires_at;
  expected.course_policy_version = replacement.course_policy_version;
  expected.state_version = replacement.state_version; expected.course_reviews = replacement.course_reviews;
  return sameActionCandidate(expected, replacement);
}
