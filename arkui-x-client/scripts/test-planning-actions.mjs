import assert from 'node:assert/strict';
import { test } from 'node:test';
import { PlanningActionController, editedPlanningTime, validPlanningDate, CampusFlowRequestError, candidate, applied,
  sampleTask, samplePlan, clone, deferred } from './helpers/planning-action-fixture.mjs';
const draft = { title: '复习操作系统', start_at: null, end_at: null, reminder_minutes: 0, location: null };
const create = () => ({ operation: 'create_task', task: { ...draft } });
function fixture(handlers = {}) {
  const calls = [], states = [], receipts = []; let action;
  const api = {
    async previewPlanningAction(request) { calls.push(['preview', clone(request)]); action = candidate(request); action = handlers.preview ? await handlers.preview(request, action) : clone(action); return action; },
    async confirmAction(id) { calls.push(['confirm', id]); if (handlers.confirm) return handlers.confirm(id, action); const result = applied(action); return { applied: true, action: result, receipt: result.receipt, message: '' }; },
    async cancelAction(id) { calls.push(['cancel', id]); return handlers.cancel ? handlers.cancel(id, action) : { applied: false, action: { ...action, status: 'cancelled' }, receipt: null, message: '' }; },
    async actionStatus(id) { calls.push(['status', id]); return handlers.status ? handlers.status(id, action) : applied(action); }
  };
  const controller = new PlanningActionController(api, state => states.push(state), action => receipts.push(action));
  return { controller, calls, states, receipts, action: () => action };
}

test('preview freezes full input and never executes; confirmation yields one exact receipt', async () => {
  const { controller, calls, receipts } = fixture(); const request = create();
  await controller.preview(request); request.task.title = '已变草稿';
  assert.equal(controller.snapshot().action.payload.task.title, draft.title);
  assert.equal(controller.blocksNewWrites(), true); assert.deepEqual(calls.map(x => x[0]), ['preview']);
  await controller.confirm(); await controller.confirm();
  assert.deepEqual(calls.map(x => x[0]), ['preview', 'confirm']); assert.equal(receipts.length, 1);
  assert.equal(receipts[0].receipt.task_ids[0], 'created-task-a'); assert.equal(controller.blocksNewWrites(), false);
});

test('all five operations retain precise targets, complete before/after values and zero reminders', async () => {
  const task = sampleTask(); const { task_id, plan_id, milestone_id, status, source, created_at, completed_at, ...fields } = task;
  const plan = samplePlan();
  for (const request of [create(), { operation: 'update_task', task_id: 'task-a', task: fields },
    { operation: 'delete_task', task_id: 'task-a' }, { operation: 'update_plan', plan_id: 'plan-a', plan: { title: plan.title, summary: '', target_date: null } },
    { operation: 'delete_plan', plan_id: 'plan-a' }]) {
    const { controller, receipts } = fixture(); await controller.preview(request);
    assert.equal(controller.snapshot().phase, 'review'); await controller.confirm(); assert.equal(controller.snapshot().phase, 'resolved');
    assert.equal(receipts.length, 1);
    if (request.task_id) assert.equal(receipts[0].receipt.task_ids[0], request.task_id);
    if (request.plan_id) assert.equal(receipts[0].receipt.plan_ids[0], request.plan_id);
    if (request.operation === 'delete_plan') assert.deepEqual(receipts[0].receipt.retained_task_ids, ['child-a', 'child-b']);
  }
});

test('wrong target, dropped fields or altered content cannot become a preview', async () => {
  for (const mutate of [a => ({ ...a, target_task_id: 'other' }), a => ({ ...a, payload: {} }),
    a => ({ ...a, payload: { task: { ...a.payload.task, title: '另一个任务' } } }), a => ({ ...a, contract_version: 1 })]) {
    const { controller, calls } = fixture({ preview: (_request, a) => mutate(a) });
    await controller.preview(create()); await controller.confirm(); assert.equal(controller.snapshot().phase, 'error');
    assert.deepEqual(calls.map(x => x[0]), ['preview']);
  }
});

test('ambiguous confirm blocks all new proposals and cannot be automatically repeated', async () => {
  const f = fixture({ confirm: () => { throw new Error('lost response'); } });
  await f.controller.preview(create()); await f.controller.confirm();
  assert.equal(f.controller.snapshot().phase, 'uncertain');
  await f.controller.preview(create()); await f.controller.confirm(); await f.controller.cancel(); f.controller.dismiss();
  assert.equal(f.controller.blocksNewWrites(), true); assert.deepEqual(f.calls.map(x => x[0]), ['preview', 'confirm']);
  await f.controller.check(); await f.controller.check();
  assert.equal(f.controller.snapshot().phase, 'resolved'); assert.equal(f.receipts.length, 1);
});

test('status cannot impersonate a write receipt with a changed candidate or an unrelated receipt', async () => {
  for (const mutate of [a => ({ ...applied(a), proposal_id: 'different' }), a => ({ ...applied(a), payload: { task: { ...draft, title: 'changed' } } }),
    a => ({ ...applied(a), receipt: null }), a => ({ ...applied(a), receipt: { ...applied(a).receipt, proposal_id: 'other' } })]) {
    const f = fixture({ confirm: () => { throw new Error(); }, status: (_id, a) => mutate(a) });
    await f.controller.preview(create()); await f.controller.confirm(); await f.controller.check();
    assert.equal(f.controller.snapshot().phase, 'uncertain'); assert.equal(f.receipts.length, 0);
  }
});

test('pending status enables explicit same-proposal retry, never another operation', async () => {
  let fail = true;
  const f = fixture({ confirm: (_id, a) => { if (fail) { fail = false; throw new Error(); } const resolved = applied(a); return { applied: true, action: resolved, receipt: resolved.receipt }; }, status: (_id, a) => clone(a) });
  await f.controller.preview(create()); await f.controller.confirm(); await f.controller.check();
  assert.equal(f.controller.snapshot().phase, 'retryable'); assert.equal(f.controller.retryIntent(), 'confirm');
  await f.controller.preview(create()); await f.controller.confirm();
  assert.deepEqual(f.calls.map(x => x[0]), ['preview', 'confirm', 'status', 'confirm']);
  assert.equal(f.calls[1][1], f.calls[3][1]); assert.equal(f.receipts.length, 1);
});

test('hide during confirm requires read-back and ignores the late response', async () => {
  const d = deferred(); const f = fixture({ confirm: () => d.promise });
  await f.controller.preview(create()); const confirm = f.controller.confirm(); f.controller.setActive(false);
  assert.equal(f.controller.snapshot().phase, 'uncertain'); d.resolve({ action: applied(f.action()) }); await confirm;
  assert.equal(f.receipts.length, 0); f.controller.setActive(true); await f.controller.check(); assert.equal(f.receipts.length, 1);
});

test('old preview after hide and disposal does not replace another candidate or publish receipts', async () => {
  const d = deferred(); let delayed = true;
  const f = fixture({ preview: (_request, a) => delayed ? d.promise : a });
  const first = f.controller.preview(create()); f.controller.setActive(false); f.controller.setActive(true); delayed = false;
  await f.controller.preview({ operation: 'delete_task', task_id: 'second' });
  d.resolve(candidate(create())); await first; assert.equal(f.controller.snapshot().action.target_task_id, 'second');
  const count = f.states.length; f.controller.dispose(); await f.controller.confirm(); assert.equal(f.states.length, count);
});

test('cancel response uses action envelope and does not claim tasks were never written', async () => {
  const f = fixture(); await f.controller.preview(create()); await f.controller.cancel();
  assert.equal(f.controller.snapshot().phase, 'cancelled'); assert.equal(f.controller.snapshot().message, '提案已取消。');
  assert.equal(f.receipts.length, 0); f.controller.dismiss(); assert.equal(f.controller.snapshot().action, null);
});

test('only known rejection codes release stale candidates; generic 409 remains unknown', async () => {
  for (const code of ['ACTION_STALE', 'ACTION_EXPIRED', 'ACTION_CONFLICT', 'ACTION_INVALID', 'ACTION_LEGACY_UNVERIFIED', 'COURSE_ACK_STALE', 'COURSE_ACK_INVALID', 'UNKNOWN_CODE']) {
    const f = fixture({ confirm: () => { throw new CampusFlowRequestError(409, code, 'do not display'); } });
    await f.controller.preview(create()); await f.controller.confirm();
    assert.equal(f.controller.snapshot().phase, code === 'UNKNOWN_CODE' ? 'uncertain' : 'invalidated');
    assert.equal(f.controller.blocksNewWrites(), code === 'UNKNOWN_CODE');
  }
});

test('conflicted or expired preview cannot be confirmed; warnings stay visible without becoming conflicts', async () => {
  for (const extra of [{ conflicts: ['课程重叠'] }, { expires_at: new Date(Date.now() - 1000).toISOString(), created_at: new Date(Date.now() - 2000).toISOString() }]) {
    const f = fixture({ preview: (_r, a) => ({ ...a, ...extra }) }); await f.controller.preview(create()); await f.controller.confirm();
    assert.deepEqual(f.calls.map(x => x[0]), ['preview']); await f.controller.cancel(); assert.equal(f.controller.snapshot().phase, 'cancelled');
  }
  const f = fixture({ preview: (_r, a) => ({ ...a, warnings: ['缺少结束时间，未核查冲突'] }) }); await f.controller.preview(create());
  assert.deepEqual(f.controller.snapshot().action.warnings, ['缺少结束时间，未核查冲突']);
});

test('timestamp editing preserves unchanged seconds/offsets, uses Shanghai and rejects invalid dates', () => {
  assert.equal(editedPlanningTime('2028-10-20 09:00', '2028-10-20T01:00:37Z'), '2028-10-20T01:00:37Z');
  assert.equal(editedPlanningTime('2028-10-21 00:30', '2028-10-20T23:00:00+08:00'), '2028-10-21T00:30:00+08:00');
  assert.equal(editedPlanningTime('', '2028-10-20T01:00:37Z'), null);
  for (const value of ['2026-02-30 10:00', '2026-10-20 24:15', '2026-10-20', '<script>']) assert.equal(editedPlanningTime(value, null), 'invalid');
  assert.equal(validPlanningDate('2028-02-29'), true); assert.equal(validPlanningDate('2026-02-29'), false);
});

test('read-back of pending expired/conflicted action can cancel the same ID to recover', async () => {
  for (const mode of ['expired', 'conflict']) {
    const f = fixture({ confirm: () => { throw new Error('lost'); }, status: (_id, a) => {
      if (mode === 'expired') return { ...a }; // Simulate time advancing without changing immutable candidate timestamps.
      return { ...a, conflicts: ['最新冲突'] };
    } });
    await f.controller.preview(create()); await f.controller.confirm();
    if (mode === 'expired') {
      f.action().expires_at = new Date(Date.now() - 1000).toISOString();
      f.action().created_at = new Date(Date.now() - 2000).toISOString();
      f.controller.state.action.expires_at = f.action().expires_at;
      f.controller.state.action.created_at = f.action().created_at;
    }
    await f.controller.check(); assert.equal(f.controller.snapshot().phase, 'retryable');
    await f.controller.confirm(); assert.match(f.controller.snapshot().message, /取消本提案/);
    await f.controller.cancel(); assert.equal(f.controller.snapshot().phase, 'cancelled');
    assert.equal(f.controller.blocksNewWrites(), false); assert.equal(f.calls.at(-1)[1], 'proposal-a');
  }
});

test('a preview expiring while open gives a new explicit message on confirm', async () => {
  const f = fixture(); await f.controller.preview(create());
  f.controller.state.action.expires_at = new Date(Date.now() - 1000).toISOString();
  f.controller.state.action.created_at = new Date(Date.now() - 2000).toISOString();
  const before = f.states.length; await f.controller.confirm();
  assert.equal(f.states.length, before + 1); assert.match(f.states.at(-1).message, /已过期/);
  assert.deepEqual(f.calls.map(x => x[0]), ['preview']);
});

test('write envelope must agree with inner action and receipt before success', async () => {
  for (const make of [a => ({ action: applied(a), applied: false, receipt: applied(a).receipt }),
    a => ({ action: applied(a), applied: true, receipt: null }),
    a => ({ action: applied(a), applied: true, receipt: { ...applied(a).receipt, receipt_id: 'other' } })]) {
    const f = fixture({ confirm: (_id, a) => make(a) }); await f.controller.preview(create()); await f.controller.confirm();
    assert.equal(f.controller.snapshot().phase, 'uncertain'); assert.equal(f.receipts.length, 0);
  }
});

test('legacy naive campus timestamps match server Shanghai normalization even on a UTC device', async () => {
  const previous = process.env.TZ; process.env.TZ = 'UTC';
  try {
    const request = create(); request.task.start_at = '2028-10-20T09:00:37'; request.task.end_at = '2028-10-20T10:00:43';
    const f = fixture({ preview: (_r, a) => ({ ...a, start_at: `${a.start_at}+08:00`, end_at: `${a.end_at}+08:00`,
      payload: { task: { ...a.payload.task, start_at: `${a.start_at}+08:00`, end_at: `${a.end_at}+08:00` } } }) });
    await f.controller.preview(request); assert.equal(f.controller.snapshot().phase, 'review');
  } finally { if (previous === undefined) delete process.env.TZ; else process.env.TZ = previous; }
});
