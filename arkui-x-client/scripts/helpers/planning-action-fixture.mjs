import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
const read = name => readFileSync(new URL(`../../entry/src/main/ets/utils/${name}.ets`, import.meta.url), 'utf8');
const noImports = s => s.replace(/^import \{[\s\S]*?\} from '[^']+';\r?\n/gm, '').replace(/^import [^\n]+;\r?\n/gm, '');
const load = async name => import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(noImports(read(name)))).toString('base64')}`);
export const reliability = await load('ActionReliability');
export const presentation = await load('PlanPresentation');
const feedback = await load('AgentFeedback');
export const CampusFlowRequestError = feedback.CampusFlowRequestError;
const source = noImports(read('PlanningAction')).replace(/^export /gm, '');
const loaded = new Function('CampusFlowRequestError', 'validReliableAction', 'validatedActionReceipt', 'sameActionCandidate',
  'sameActionReceipt', 'decisionDisposition', 'formatPlanDateTime', stripTypeScriptTypes(source) +
  '\nreturn {PlanningActionController, editedPlanningTime, validPlanningDate, planningTimestamp};')(CampusFlowRequestError,
  reliability.validReliableAction, reliability.validatedActionReceipt, reliability.sameActionCandidate,
  reliability.sameActionReceipt, reliability.decisionDisposition, presentation.formatPlanDateTime);
export const { PlanningActionController, editedPlanningTime, validPlanningDate, planningTimestamp } = loaded;
export const clone = value => JSON.parse(JSON.stringify(value));
export const sampleTask = (id = 'task-a', extra = {}) => ({ task_id: id, plan_id: null, milestone_id: null,
  title: '复习操作系统', start_at: '2028-10-20T09:00:03+08:00', end_at: '2028-10-20T10:00:07+08:00',
  location: '图书馆', reminder_minutes: 0, status: 'pending', source: 'manual', created_at: '2026-10-18T08:00:00+08:00', completed_at: null, ...extra });
export const samplePlan = (id = 'plan-a', extra = {}) => ({ plan_id: id, title: '复习目标', summary: '保留原内容',
  target_date: '2028-10-28', status: 'active', progress: 0, task_count: 2, completed_count: 0, overdue_count: 0,
  milestones: [], created_at: '2026-10-18T08:00:00+08:00', ...extra });
export function candidate(request, extra = {}) {
  const [action, kind] = request.operation.split('_');
  const beforeTask = action !== 'create' && kind === 'task' ? sampleTask(request.task_id) : null;
  const beforePlan = action !== 'create' && kind === 'plan' ? samplePlan(request.plan_id) : null;
  const task = request.task ?? beforeTask;
  const plan = request.plan ?? beforePlan;
  return { proposal_id: 'proposal-a', contract_version: 2, action, kind, title: task?.title ?? plan?.title,
    start_at: action === 'delete' ? null : task?.start_at ?? null, end_at: action === 'delete' ? null : task?.end_at ?? null, reminder_minutes: action === 'delete' ? null : task?.reminder_minutes ?? null,
    reason: null, conflicts: [], warnings: [], status: 'pending',
    created_at: new Date().toISOString(), expires_at: new Date(Date.now() + 900000).toISOString(),
    target_task_id: request.task_id ?? null, target_plan_id: request.plan_id ?? null,
    before_task: beforeTask, before_plan: beforePlan, receipt: null,
    payload: request.task ? { task: clone(request.task) } : request.plan ? { plan: clone(request.plan) } : {}, ...extra };
}
export function applied(action) {
  return { ...clone(action), status: 'confirmed', receipt: { receipt_id: 'receipt-a', proposal_id: action.proposal_id,
    action: action.action, kind: action.kind, applied_at: new Date().toISOString(),
    task_ids: action.kind === 'task' ? [action.target_task_id ?? 'created-task-a'] : [],
    plan_ids: action.kind === 'plan' ? [action.target_plan_id ?? 'created-plan-a'] : [],
    milestone_ids: [], retained_task_ids: action.kind === 'plan' && action.action === 'delete' ? ['child-a', 'child-b'] : [] } };
}
export function deferred() {
  let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject };
}
