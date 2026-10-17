import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';

// Execute the shared production validator, independently of the UI and native runtime.
const source = readFileSync(new URL('../entry/src/main/ets/utils/ActionReliability.ets', import.meta.url), 'utf8')
  .replace(/^import \{[\s\S]*?\} from '[^']+';\r?\n/gm, '');
const api = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source)).toString('base64')}`);
const clone = value => JSON.parse(JSON.stringify(value));
const now = Date.parse('2028-10-20T08:00:00+08:00');
const fields = () => ({ title: '复习', start_at: '2028-10-20T09:00:00+08:00', end_at: '2028-10-20T10:00:00+08:00',
  location: '图书馆', reminder_minutes: 0 });
const task = () => ({ ...fields(), task_id: 'task-1', plan_id: 'plan-1', milestone_id: 'milestone-1',
  status: 'pending', source: 'manual', created_at: '2028-10-19T08:00:00+08:00', completed_at: null });
const plan = () => ({ plan_id: 'plan-1', title: '一周复习', summary: '按课程推进', target_date: '2028-10-27',
  status: 'active', progress: 0, task_count: 2, completed_count: 0, overdue_count: 0,
  created_at: '2028-10-19T08:00:00+08:00', milestones: [
    { milestone_id: 'milestone-1', title: '第一章', due_at: null, task_count: 2, completed_count: 0 }
  ] });
function candidate(kind = 'task', operation = 'create') {
  const value = { proposal_id: `${operation}-${kind}`, contract_version: 2, action: operation, kind,
    title: kind === 'task' ? fields().title : plan().title,
    start_at: kind === 'task' && operation !== 'delete' ? fields().start_at : null,
    end_at: kind === 'task' && operation !== 'delete' ? fields().end_at : null,
    reminder_minutes: kind === 'task' && operation !== 'delete' ? 0 : null,
    reason: null, payload: {}, conflicts: [], warnings: [], status: 'pending',
    created_at: new Date(now).toISOString(), expires_at: new Date(now + 900000).toISOString(),
    target_task_id: null, target_plan_id: null, before_task: null, before_plan: null, receipt: null };
  if (operation !== 'create') {
    if (kind === 'task') { value.target_task_id = 'task-1'; value.before_task = task(); }
    else { value.target_plan_id = 'plan-1'; value.before_plan = plan(); }
  }
  if (kind === 'task' && operation !== 'delete') { value.payload.task = fields(); }
  if (kind === 'plan' && operation === 'update') {
    value.payload.plan = { title: plan().title, summary: '更新说明', target_date: '2028-10-28' };
  }
  if (kind === 'plan' && operation === 'create') {
    value.payload = { summary: '按课程推进', target_date: '2028-10-27',
      milestones: [{ title: '第一章', due_at: null, tasks: [fields(), { ...fields(), title: '第二节复习' }] }] };
  }
  return value;
}
function applied(action) {
  const value = clone(action);
  value.status = 'confirmed';
  value.receipt = { receipt_id: `receipt-${action.proposal_id}`, proposal_id: action.proposal_id,
    action: action.action, kind: action.kind, applied_at: new Date(now + 60000).toISOString(),
    task_ids: action.kind === 'task' ? [action.target_task_id ?? 'created-task'] : action.action === 'create' ? ['created-a', 'created-b'] : [],
    plan_ids: action.kind === 'plan' ? [action.target_plan_id ?? 'created-plan'] : [],
    milestone_ids: action.kind === 'plan' && action.action !== 'update' ? ['milestone-1'] : [],
    retained_task_ids: action.kind === 'plan' && action.action === 'delete' ? ['retained-a', 'retained-b'] : [] };
  return value;
}

test('all six v2 operations validate, with exact task/plan result destinations only for existing results', () => {
  for (const kind of ['task', 'plan']) for (const operation of ['create', 'update', 'delete']) {
    const value = candidate(kind, operation);
    assert.equal(api.validReliableAction(value), true, `${operation} ${kind}`);
    assert.equal(api.canConfirmAction(value, now), true);
    const result = applied(value);
    assert.equal(api.validatedActionReceipt(result), result.receipt);
    assert.equal(api.decisionDisposition(result, now + 86400000), 'confirmed', 'terminal receipts survive preview expiry');
    assert.equal(api.receiptTaskId(result), kind === 'task' && operation !== 'delete' ? result.receipt.task_ids[0] : '');
    assert.equal(api.receiptPlanId(result), kind === 'plan' && operation !== 'delete' ? result.receipt.plan_ids[0] : '');
  }
});

test('legacy, incomplete snapshots, invalid targets and expired previews cannot be confirmed', () => {
  const legacy = candidate(); delete legacy.contract_version;
  assert.equal(api.validActionPreview(legacy), true);
  assert.equal(api.decisionDisposition(legacy, now), 'legacy');
  for (const mutate of [a => { a.before_task = null; }, a => { a.target_task_id = 'different'; },
    a => { a.before_task.status = 'unsupported'; }, a => { a.payload.task.end_at = a.payload.task.start_at; }]) {
    const value = candidate('task', 'update'); mutate(value);
    assert.equal(api.validReliableAction(value), false);
    assert.equal(api.canConfirmAction(value, now), false);
  }
  assert.equal(api.decisionDisposition(candidate(), now + 900000), 'expired');
  assert.equal(api.canConfirmAction(legacy, now), false);
});

test('the visible task/plan projection must equal the actual full payload', () => {
  for (const property of ['title', 'start_at', 'end_at', 'reminder_minutes']) {
    const value = candidate(); value[property] = property === 'reminder_minutes' ? 5 : 'not-the-payload';
    assert.equal(api.validReliableAction(value), false, property);
  }
  const location = candidate(); location.payload.location = '不同地点';
  assert.equal(api.validReliableAction(location), false);
  const value = candidate('plan', 'update'); value.title = '另一份计划';
  assert.equal(api.validReliableAction(value), false);
});

test('warnings are visible nonblocking data; conflicts block and malformed explanations are rejected', () => {
  const value = candidate(); value.warnings = ['无完整时段，仍需手动核对'];
  assert.equal(api.canConfirmAction(value, now), true);
  const updated = clone(value); updated.warnings = ['补充核对说明']; updated.conflicts = ['与已有任务重叠'];
  assert.equal(api.sameActionCandidate(value, updated), true, 'fresh explanations do not replace the immutable candidate');
  assert.equal(api.decisionDisposition(updated, now), 'conflict');
  value.warnings = [null]; assert.equal(api.validActionPreview(value), false);
  value.warnings = []; value.conflicts = [{}]; assert.equal(api.validActionPreview(value), false);
});

test('plan creation cannot lose milestones or subtasks and a partial success receipt is rejected', () => {
  const empty = candidate('plan'); empty.payload.milestones[0].tasks = [];
  assert.equal(api.validReliableAction(empty), false);
  for (const field of ['task_ids', 'milestone_ids']) {
    const value = applied(candidate('plan')); value.receipt[field].pop();
    assert.equal(api.validatedActionReceipt(value), null, field);
    assert.equal(api.receiptPlanId(value), '');
  }
});

test('forged receipt IDs, wrong operations, missing/deceptive arrays and incorrect retained counts have no destination', () => {
  for (const mutate of [r => { r.proposal_id = 'other'; }, r => { r.action = 'delete'; }, r => { r.kind = 'plan'; },
    r => { r.task_ids = ['wrong-task']; }, r => { r.task_ids = []; }, r => { r.plan_ids = ['foreign-plan']; },
    r => { r.applied_at = 'bad-time'; }, r => { r.retained_task_ids = null; }]) {
    const value = applied(candidate('task', 'update')); mutate(value.receipt);
    assert.equal(api.validatedActionReceipt(value), null);
    assert.equal(api.receiptTaskId(value), '');
  }
  const deleted = applied(candidate('plan', 'delete')); deleted.receipt.retained_task_ids.pop();
  assert.equal(api.validatedActionReceipt(deleted), null);
  const milestones = applied(candidate('plan', 'delete')); milestones.receipt.milestone_ids = ['not-in-before'];
  assert.equal(api.validatedActionReceipt(milestones), null);
});

test('receipt envelope comparison is structural and cannot collide through ID delimiters', () => {
  const receipt = applied(candidate()).receipt;
  assert.equal(api.sameActionReceipt(receipt, Object.fromEntries(Object.entries(receipt).reverse())), true);
  const left = { ...receipt, task_ids: ['a,b', 'c'] };
  const right = { ...receipt, task_ids: ['a', 'b,c'] };
  assert.equal(api.sameActionReceipt(left, right), false);
  assert.equal(api.sameActionReceipt(receipt, null), false);
  assert.equal(api.sameActionReceipt(null, null), true);
});

test('candidate comparison ignores object key order but guards full before/after values and malformed snapshots', () => {
  const value = candidate('task', 'update');
  const reordered = clone(value);
  reordered.payload.task = Object.fromEntries(Object.entries(reordered.payload.task).reverse());
  reordered.before_task = Object.fromEntries(Object.entries(reordered.before_task).reverse());
  assert.equal(api.sameActionCandidate(value, reordered), true);
  for (const mutate of [a => { a.payload.task.location = '新地点'; }, a => { a.before_task.status = 'completed'; },
    a => { a.target_task_id = 'other'; }, a => { a.before_task = {}; }]) {
    const changed = clone(value); mutate(changed); assert.equal(api.sameActionCandidate(value, changed), false);
  }
  const goal = candidate('plan', 'delete'); const malformed = clone(goal); malformed.before_plan = {};
  assert.equal(api.sameActionCandidate(goal, malformed), false);
  const childChanged = clone(goal); childChanged.before_plan.milestones[0].task_count = 1;
  assert.equal(api.sameActionCandidate(goal, childChanged), false);
});

test('durable cancellation is terminal without an execution receipt; raw confirmed labels are insufficient', () => {
  const value = candidate(); value.status = 'cancelled';
  assert.equal(api.decisionDisposition(value, now + 86400000), 'cancelled');
  assert.equal(api.canConfirmAction(value, now), false);
  value.status = 'confirmed'; assert.equal(api.decisionDisposition(value, now), 'invalid');
  value.status = 'cancelled'; value.receipt = applied(candidate()).receipt;
  assert.equal(api.decisionDisposition(value, now), 'invalid');
});

test('reversed historical intervals remain visible and support repair/delete, while new reversed intervals are rejected', () => {
  for (const operation of ['update', 'delete']) {
    const value = candidate('task', operation);
    value.before_task.end_at = '2028-10-20T08:00:00+08:00';
    assert.equal(api.validReliableAction(value), true, 'before evidence is not a new scheduling request');
    assert.equal(api.canConfirmAction(value, now), true);
    assert.equal(api.sameActionCandidate(value, clone(value)), true);
    assert.ok(api.validatedActionReceipt(applied(value)));
  }
  const invalid = candidate('task', 'update');
  invalid.payload.task.end_at = invalid.end_at = '2028-10-20T08:00:00+08:00';
  assert.equal(api.validReliableAction(invalid), false);
});
