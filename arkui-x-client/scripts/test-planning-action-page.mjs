import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';
import { PlanningActionController, editedPlanningTime, validPlanningDate, planningTimestamp, CampusFlowRequestError, candidate, applied,
  sampleTask, samplePlan, presentation, deferred, clone } from './helpers/planning-action-fixture.mjs';
const read = name => readFileSync(new URL(`../entry/src/main/ets/${name}`, import.meta.url), 'utf8');
const noImports = s => s.replace(/^import \{[\s\S]*?\} from '[^']+';\r?\n/gm, '').replace(/^import [^\n]+;\r?\n/gm, '');
const raw = read('pages/PlanCenterPage.ets');
const methods = noImports(raw.slice(0, raw.indexOf('\n  @Builder')))
  .replace(/^@Component\r?\n/m, '').replace(/@(Prop|State)\s+|@Watch\('[^']+'\)\s*/g, '')
  .replace('export struct PlanCenterPage', 'class PlanCenterPage') + '\n}\n';
const utility = async name => import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(noImports(read(`utils/${name}.ets`)))).toString('base64')}`);
const agenda = await utility('DailyAgenda');
function fixture(handlers = {}) {
  const calls = [], changed = []; let action;
  const overview = { plans: [samplePlan()], tasks: [sampleTask()], total_tasks: 1, completed_tasks: 0, due_today: 0, overdue_tasks: 0, progress: 0 };
  class Api {
    async planning() { calls.push(['planning']); return clone(overview); }
    async context() { return { timetable: [] }; }
    async updateTask(id, completed) { calls.push(['toggle', id, completed]); if (handlers.toggle) return handlers.toggle(); }
    async previewPlanningAction(request) { calls.push(['preview', clone(request)]); action = candidate(request); return handlers.preview ? handlers.preview(action) : clone(action); }
    async confirmAction(id) {
      calls.push(['confirm', id]); const result = applied(action);
      return handlers.confirm ? handlers.confirm(result) : { applied: true, action: result, receipt: result.receipt, message: '' };
    }
    async cancelAction(id) { calls.push(['cancel', id]); return { action: { ...action, status: 'cancelled' }, receipt: null, applied: false }; }
    async actionStatus(id) { calls.push(['status', id]); return applied(action); }
  }
  class Input { stopEditing() {} }
  const Page = new Function('CampusFlowApi', 'TextInputController', 'Scroller', 'AppTheme', 'Curve', 'shanghaiDate', 'buildDailyAgenda',
    'formatPlanDateTime', 'PlanningActionController', 'editedPlanningTime', 'validPlanningDate', 'planningTimestamp', 'CampusFlowRequestError',
    stripTypeScriptTypes(methods) + '\nreturn PlanCenterPage;')(Api, Input, class {}, { motion: () => 0 }, { EaseOut: '' },
    agenda.shanghaiDate, agenda.buildDailyAgenda, presentation.formatPlanDateTime, PlanningActionController, editedPlanningTime, validPlanningDate, planningTimestamp, CampusFlowRequestError);
  const page = new Page(); page.overview = clone(overview); page.getUIContext = () => ({ animateTo: (_, update) => update() });
  page.onPlanningChanged = () => changed.push(true);
  return { page, calls, changed };
}

test('create draft is cleared only after exact receipt; edited title or date survives confirmation', async () => {
  for (const changedDraft of ['none', 'title', 'date']) {
    const f = fixture(); f.page.title = '原草稿'; f.page.draftTaskDate = '2028-10-20';
    await f.page.addTask(); assert.equal(f.page.title, '原草稿'); assert.equal(f.changed.length, 0);
    if (changedDraft === 'title') f.page.title = '新草稿';
    if (changedDraft === 'date') f.page.draftTaskDate = '2028-10-21';
    await f.page.confirmPlanningAction(); assert.equal(f.page.title, changedDraft === 'none' ? '' : changedDraft === 'title' ? '新草稿' : '原草稿');
    assert.equal(f.changed.length, 1); assert.equal(f.page.actionState.action.receipt.task_ids[0], 'created-task-a');
  }
});

test('task editor sends all five values, preserves precise unedited timestamps and reminder zero', async () => {
  const f = fixture(); f.page.beginTaskEdit(sampleTask('target-exact', { title: '同名任务' }));
  f.page.editTaskTitle = '仅改名称'; await f.page.previewTaskEdit();
  assert.deepEqual(f.calls[0], ['preview', { operation: 'update_task', task_id: 'target-exact', task: {
    title: '仅改名称', start_at: '2028-10-20T09:00:03+08:00', end_at: '2028-10-20T10:00:07+08:00', reminder_minutes: 0, location: '图书馆' } }]);
  assert.equal(f.page.actionState.phase, 'review');
});

test('editor rejects invalid intervals/reminders and keeps drafts until fixed', async () => {
  const f = fixture(); f.page.beginTaskEdit(sampleTask()); f.page.editTaskStart = '2028-02-30 09:00';
  await f.page.previewTaskEdit(); assert.equal(f.calls.length, 0); assert.match(f.page.errorText, /有效/);
  f.page.editTaskStart = ''; f.page.editTaskEnd = ''; f.page.editTaskReminder = '-1';
  await f.page.previewTaskEdit(); assert.equal(f.calls.length, 0); assert.match(f.page.errorText, /提醒/);
  f.page.editTaskReminder = ''; await f.page.previewTaskEdit(); assert.equal(f.calls[0][1].task.start_at, null);
  assert.equal(f.calls[0][1].task.reminder_minutes, null);
});

test('task/plan drafts survive back, other IDs cannot overwrite them, and discard is explicit', () => {
  const f = fixture(); f.page.beginTaskEdit(sampleTask('a')); f.page.editTaskTitle = '保留草稿'; f.page.closeDetails();
  f.page.beginTaskEdit(sampleTask('b')); assert.equal(f.page.editTaskId, 'a'); assert.equal(f.page.editTaskTitle, '保留草稿');
  assert.equal(f.page.detailId, 'a'); f.page.discardTaskEdit(); f.page.beginTaskEdit(sampleTask('b')); assert.equal(f.page.editTaskId, 'b');
  f.page.beginPlanEdit(samplePlan('p1')); f.page.editPlanSummary = '较长草稿'; f.page.closeDetails();
  f.page.beginPlanEdit(samplePlan('p2')); assert.equal(f.page.editPlanId, 'p1'); assert.equal(f.page.editPlanSummary, '较长草稿');
});

test('plan metadata preview contains only editable fields and exact plan ID, deletion remains preview only', async () => {
  const f = fixture(); f.page.beginPlanEdit(samplePlan('p-exact')); f.page.editPlanDate = ''; f.page.editPlanSummary = '';
  await f.page.previewPlanEdit(); assert.deepEqual(f.calls[0][1], { operation: 'update_plan', plan_id: 'p-exact', plan: { title: '复习目标', summary: '', target_date: null } });
  await f.page.actionManager().cancel(); f.page.dismissAction();
  await f.page.requestPlanDelete(samplePlan('p-exact')); assert.deepEqual(f.calls.at(-1), ['preview', { operation: 'delete_plan', plan_id: 'p-exact' }]);
  assert.equal(f.changed.length, 0); assert.equal(f.page.actionState.action.before_plan.task_count, 2);
});

test('unknown action blocks create, update, completion, both deletes, and discarding its editor', async () => {
  const f = fixture({ confirm: () => { throw new Error('response lost'); } }); f.page.beginTaskEdit(sampleTask());
  await f.page.previewTaskEdit(); await f.page.confirmPlanningAction(); assert.equal(f.page.actionState.phase, 'uncertain');
  const count = f.calls.length; f.page.title = 'new'; await f.page.addTask(); await f.page.toggle(sampleTask());
  await f.page.requestDelete(sampleTask('other')); await f.page.requestPlanDelete(samplePlan());
  await f.page.previewTaskEdit(); f.page.discardTaskEdit(); assert.equal(f.calls.length, count); assert.equal(f.page.editTaskId, 'task-a');
  await f.page.actionManager().check(); assert.equal(f.page.actionState.phase, 'resolved'); assert.equal(f.changed.length, 1);
});

test('replan unresolved state blocks all new action previews and task completion', async () => {
  const f = fixture(); f.page.replanWriteBlocked = true; f.page.title = '待办';
  await f.page.addTask(); await f.page.toggle(sampleTask()); await f.page.requestDelete(sampleTask());
  await f.page.requestPlanDelete(samplePlan()); assert.deepEqual(f.calls, []);
});

test('hide/dispose during confirm ignores late result and never clears the draft or emits success', async () => {
  for (const kind of ['hide', 'dispose']) {
    const d = deferred(); const f = fixture({ confirm: () => d.promise }); f.page.title = '保留'; await f.page.addTask();
    const pending = f.page.confirmPlanningAction();
    if (kind === 'hide') { f.page.active = false; f.page.activityChanged(); } else f.page.aboutToDisappear();
    const result = applied(f.page.actionState.action); d.resolve({ applied: true, action: result, receipt: result.receipt }); await pending;
    assert.equal(f.page.title, '保留'); assert.equal(f.changed.length, 0);
    if (kind === 'hide') { f.page.active = true; f.page.activityChanged(); await f.page.actionManager().check(); assert.equal(f.changed.length, 1); }
  }
});

test('successful edit clears its own unchanged draft only; later edits remain intact', async () => {
  for (const later of [false, true]) {
    const f = fixture(); f.page.beginTaskEdit(sampleTask()); await f.page.previewTaskEdit();
    if (later) f.page.editTaskTitle = '后续草稿'; await f.page.confirmPlanningAction();
    assert.equal(f.page.editTaskId, later ? 'task-a' : '');
  }
});

test('restore conflict is a determinate error directing the user to edit the exact task', async () => {
  const f = fixture({ toggle: () => { throw new CampusFlowRequestError(409, 'ACTION_CONFLICT', 'raw ignored'); } });
  await f.page.toggle(sampleTask('completed', { status: 'completed' }));
  assert.match(f.page.errorText, /调整时间/); assert.equal(f.changed.length, 0); assert.equal(f.page.mutationBusy, false);
});

test('editing one boundary of a naive legacy interval uses Shanghai on non-Shanghai devices', async () => {
  const previous = process.env.TZ; process.env.TZ = 'UTC';
  try {
    const f = fixture(); f.page.beginTaskEdit(sampleTask('legacy', { start_at: '2028-10-20T09:00:00', end_at: '2028-10-20T10:00:00' }));
    f.page.editTaskEnd = '2028-10-20 11:00'; await f.page.previewTaskEdit();
    assert.equal(f.calls[0][1].task.start_at, '2028-10-20T09:00:00');
    assert.equal(f.calls[0][1].task.end_at, '2028-10-20T11:00:00+08:00');
  } finally { if (previous === undefined) delete process.env.TZ; else process.env.TZ = previous; }
});
