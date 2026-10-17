import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';

const read = path => readFileSync(new URL(`../entry/src/main/ets/${path}`, import.meta.url), 'utf8');
const withoutImports = source => source.replace(/^import \{[\s\S]*?\} from '[^']+';\r?\n/gm, '')
  .replace(/^import [^\n]+;\r?\n/gm, '');
async function utility(name) {
  return import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(withoutImports(read(`utils/${name}.ets`)))).toString('base64')}`);
}
const { CampusFlowRequestError } = await utility('AgentFeedback');
const { validateTimetableEntry } = await utility('OnboardingTimetable');
const agenda = await utility('DailyAgenda');
const replanSource = withoutImports(read('utils/PlanningReplan.ets')).replace(/^export /gm, '');
const Replan = new Function('CampusFlowRequestError', 'validateTimetableEntry',
  stripTypeScriptTypes(replanSource) + '\nreturn PlanningReplanController;')(CampusFlowRequestError, validateTimetableEntry);

function component(path, name, names, values) {
  const source = read(path);
  const boundary = source.indexOf('\n  @Builder');
  assert.ok(boundary > 0, 'execute production methods before the first ArkUI builder');
  const methods = withoutImports(source.slice(0, boundary))
    .replace(/^@Component\r?\n/m, '')
    .replace(/@(Prop|State)\s+|@Watch\('[^']+'\)\s*|@StorageLink\('[^']+'\)\s*/g, '')
    .replace(`export struct ${name}`, `class ${name}`) + '\n}\n';
  return new Function(...names, stripTypeScriptTypes(methods) + `\nreturn ${name};`)(...values);
}
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
const tick = () => new Promise(resolve => setImmediate(resolve));
const now = Date.parse('2026-10-20T08:00:00+08:00');
function report(count = 1) {
  return { checked_at: '2026-10-20T08:00:00+08:00', policy: '仅核对明确时段',
    conflicts: Array.from({ length: count }, (_, i) => ({ task_id: `task-${i}`, title: `复习 ${i}`,
      start_at: '2026-10-20T10:00:00+08:00', end_at: '2026-10-20T11:00:00+08:00', courses: [{
        date: '2026-10-20', title: '操作系统', start_time: '10:00', end_time: '11:30', location: '', teacher: ''
      }] })),
    unchecked: Array.from({ length: count }, (_, i) => ({ task_id: `unchecked-${i}`, title: `待办 ${i}`, reason: '缺少结束时间' })) };
}
function preview(count = 1) {
  return { replan_id: 'test-preview', status: 'pending', created_at: '2026-10-20T08:00:00+08:00',
    expires_at: '2026-10-20T08:15:00+08:00', policy: '在课表空档寻找同样时长',
    changes: Array.from({ length: count }, (_, i) => ({ task_id: `task-${i}`, title: `复习 ${i}`,
      old_start_at: '2026-10-20T10:00:00+08:00', old_end_at: '2026-10-20T11:00:00+08:00',
      new_start_at: '2026-10-20T12:00:00+08:00', new_end_at: '2026-10-20T13:00:00+08:00' })),
    unresolved: Array.from({ length: count }, (_, i) => ({ task_id: `unresolved-${i}`, title: `任务 ${i}`, reason: '没有合适空档' })) };
}
function panelFixture(handlers = {}, count = 1) {
  const calls = [], applied = [];
  class Api {
    async planningConflicts() { calls.push('report'); return handlers.report ? handlers.report() : report(count); }
    async previewReplan() { calls.push('preview'); return handlers.preview ? handlers.preview() : preview(count); }
    async confirmReplan(id) { calls.push(`confirm:${id}`); return handlers.confirm ? handlers.confirm(id) : { ...preview(count), status: 'confirmed' }; }
    async replanStatus(id) { calls.push(`status:${id}`); return handlers.status ? handlers.status(id) : { ...preview(count), status: 'confirmed' }; }
  }
  class ClockedController {
    constructor(api, changed, applied) { return new Replan(api, changed, applied, () => now); }
  }
  const Panel = component('components/PlanningConflictsPanel.ets', 'PlanningConflictsPanel',
    ['CampusFlowApi', 'PlanningReplanController'], [Api, ClockedController]);
  const page = new Panel(); page.onApplied = () => applied.push(true);
  return { page, calls, applied };
}

test('Panel first appearance respects visibility; activation loads once and refresh calls the real controller', async () => {
  const f = panelFixture(); f.page.active = false; f.page.aboutToAppear(); await tick();
  f.page.refreshRequested(); await tick(); assert.deepEqual(f.calls, []);
  f.page.active = true; f.page.activityChanged(); await tick(); assert.deepEqual(f.calls, ['report']);
  assert.equal(f.page.state.report.conflicts.length, 1);
  f.page.refreshRequested(); await tick(); assert.deepEqual(f.calls, ['report', 'report']);
});

test('Panel pagination reaches every item across all four lists, with bounded pages and no truncation', async () => {
  const f = panelFixture({}, 13); f.page.aboutToAppear(); await tick(); await f.page.replanner().preview();
  for (const [kind, method, expectedPrefix] of [
    ['conflicts', 'conflictRows', 'task-'], ['unchecked', 'uncheckedRows', 'unchecked-'],
    ['changes', 'changeRows', 'task-'], ['unresolved', 'unresolvedRows', 'unresolved-']
  ]) {
    const ids = [];
    for (let page = 0; page < 3; page++) {
      assert.equal(f.page.pageFor(kind), page); assert.ok(f.page[method]().length <= 6);
      ids.push(...f.page[method]().map(row => row.task_id)); f.page.movePage(kind, 1, 13);
    }
    assert.deepEqual(ids, Array.from({ length: 13 }, (_, i) => `${expectedPrefix}${i}`));
    assert.equal(f.page.pageFor(kind), 2); f.page.movePage(kind, -99, 13); assert.equal(f.page.pageFor(kind), 0);
  }
  assert.equal(f.page.validPage(3, 0), 0); assert.equal(f.page.validPage(3, 2), 0);
});

test('Panel hidden during preview ignores its late result and clears old read-only content', async () => {
  const late = deferred(); const f = panelFixture({ preview: () => late.promise });
  f.page.aboutToAppear(); await tick(); const pending = f.page.replanner().preview();
  f.page.active = false; f.page.activityChanged(); late.resolve(preview()); await pending;
  assert.equal(f.page.state.preview, null); assert.equal(f.page.state.report, null);
  assert.equal(f.applied.length, 0); assert.equal(f.calls.some(x => x.startsWith('confirm:')), false);
});

test('Panel hidden during confirmation returns to query-only mode and propagates verified success once', async () => {
  const late = deferred(); const f = panelFixture({ confirm: () => late.promise });
  f.page.aboutToAppear(); await tick(); await f.page.replanner().preview();
  const saving = f.page.replanner().confirm(); assert.equal(f.page.busy(), true);
  f.page.active = false; f.page.activityChanged(); late.resolve({ ...preview(), status: 'confirmed' }); await saving;
  assert.equal(f.page.state.phase, 'uncertain'); assert.equal(f.applied.length, 0);
  f.page.active = true; f.page.activityChanged(); assert.equal(f.page.needsResultCheck(), true);
  const before = f.calls.length;
  f.page.refreshRequested(); await f.page.replanner().confirm(); await f.page.replanner().preview(); f.page.replanner().dismiss();
  assert.equal(f.calls.length, before, 'uncertain writes cannot be bypassed through page events');
  await f.page.replanner().checkResult(); assert.equal(f.page.state.phase, 'applied');
  assert.equal(f.applied.length, 1); assert.equal(f.calls.filter(x => x.startsWith('confirm:')).length, 1);
});

test('Panel disposal suppresses late confirmation state and parent callbacks', async () => {
  const late = deferred(); const f = panelFixture({ confirm: () => late.promise });
  f.page.aboutToAppear(); await tick(); await f.page.replanner().preview();
  const saving = f.page.replanner().confirm(); f.page.aboutToDisappear(); const before = f.page.viewRevision;
  late.resolve({ ...preview(), status: 'confirmed' }); await saving;
  assert.equal(f.applied.length, 0); assert.equal(f.page.viewRevision, before); assert.equal(f.page.controller, null);
});

function profileFixture(handler) {
  const calls = [], changed = [];
  class Api {
    async saveSubscription(url) { calls.push(['save', url]); return handler(); }
    async syncSubscription() { calls.push(['sync']); return handler(); }
  }
  const Profile = component('pages/ProfilePage.ets', 'ProfilePage',
    ['CampusFlowApi', 'CampusFlowRequestError'], [Api, CampusFlowRequestError]);
  const page = new Profile(); page.scheduleUrl = 'https://test.invalid/private?token=fixture-secret';
  page.onTimetableChanged = () => changed.push(true);
  return { page, calls, changed };
}

test('Profile subscription save and sync double taps send once and notify only after success', async () => {
  for (const method of ['saveSubscription', 'syncSubscription']) {
    const pending = deferred(); const f = profileFixture(() => pending.promise);
    const saving = f.page[method](); await f.page[method]();
    assert.equal(f.calls.length, 1); assert.equal(f.changed.length, 0); assert.equal(f.page.subscriptionBusy, true);
    pending.resolve({ status: { configured: true }, imported_count: 3 }); await saving;
    assert.equal(f.changed.length, 1); assert.equal(f.page.timetableUpdated, true);
    assert.equal(f.page.subscriptionBusy, false); if (method === 'saveSubscription') assert.equal(f.page.scheduleUrl, '');
  }
});

test('Profile failed sync never emits a success callback or leaks response text and private URL', async () => {
  for (const error of [new Error('raw https://test.invalid/private?token=fixture-secret'),
    new CampusFlowRequestError(500, 'HTTP_ERROR', 'fixture-secret'),
    new CampusFlowRequestError(401, 'HTTP_ERROR', 'fixture-secret'),
    new CampusFlowRequestError(422, 'HTTP_ERROR', 'fixture-secret')]) {
    for (const method of ['saveSubscription', 'syncSubscription']) {
      const f = profileFixture(async () => { throw error; }); f.page.timetableUpdated = true;
      await f.page[method](); assert.equal(f.changed.length, 0); assert.equal(f.page.timetableUpdated, false);
      assert.equal(f.page.subscriptionBusy, false); assert.doesNotMatch(f.page.message, /fixture-secret|https:|raw/);
      assert.equal(f.page.subscriptionNeedsCheck, !(error instanceof CampusFlowRequestError) || error.statusCode === 500);
    }
  }
});

test('Profile destroyed during either sync ignores old-account success or failure', async () => {
  for (const method of ['saveSubscription', 'syncSubscription']) {
    for (const fails of [false, true]) {
      const pending = deferred(); const f = profileFixture(() => pending.promise);
      const saving = f.page[method](); f.page.aboutToDisappear();
      if (fails) pending.reject(new Error('old secret')); else pending.resolve({ status: { configured: true }, imported_count: 3 });
      await saving; assert.equal(f.changed.length, 0); assert.equal(f.page.timetableUpdated, false); assert.equal(f.page.message, '');
    }
  }
});

const overview = name => ({ plans: [], tasks: [{ task_id: name }], total_tasks: 1, completed_tasks: 0,
  due_today: 0, overdue_tasks: 0, progress: 0 });
function planFixture(context, planning) {
  const calls = [];
  class Api {
    async context() { calls.push('context'); return context(); }
    async planning() { calls.push('planning'); return planning(); }
  }
  const Plan = component('pages/PlanCenterPage.ets', 'PlanCenterPage',
    ['CampusFlowApi', 'TextInputController', 'AppTheme', 'Curve', 'Scroller', 'shanghaiDate', 'buildDailyAgenda'],
    [Api, class {}, { motion: () => 0 }, { EaseOut: '' }, class {}, agenda.shanghaiDate, agenda.buildDailyAgenda]);
  const page = new Plan(); page.getUIContext = () => ({ animateTo: (_options, update) => update() });
  return { page, calls };
}

test('PlanCenter latest full-refresh generation wins and never applies the older course response', async () => {
  const first = deferred(); let reads = 0;
  const f = planFixture(() => ++reads === 1 ? first.promise : { timetable: [{ title: 'new' }] }, () => overview('new'));
  const old = f.page.reload(true); await f.page.reload(true);
  first.resolve({ timetable: [{ title: 'old' }] }); await old;
  assert.equal(f.page.timetable[0].title, 'new'); assert.equal(f.page.overview.tasks[0].task_id, 'new');
  assert.deepEqual(f.calls, ['context', 'context', 'planning']);
});

test('PlanCenter failed second read keeps both previous snapshots; ordinary refresh preserves outstanding course refresh', async () => {
  const f = planFixture(() => ({ timetable: [{ title: 'new' }] }), async () => { throw new Error('offline'); });
  f.page.timetable = [{ title: 'old' }]; f.page.overview = overview('old'); await f.page.reload(true);
  assert.equal(f.page.timetable[0].title, 'old'); assert.equal(f.page.overview.tasks[0].task_id, 'old');
  assert.equal(f.page.timetableNeedsRefresh, true);
  const pending = deferred(); let reads = 0;
  const g = planFixture(() => ++reads === 1 ? pending.promise : { timetable: [{ title: 'latest' }] }, () => overview('latest'));
  const old = g.page.reload(true); await g.page.reload(); pending.resolve({ timetable: [{ title: 'older' }] }); await old;
  assert.deepEqual(g.calls, ['context', 'context', 'planning']); assert.equal(g.page.timetable[0].title, 'latest');
});

test('PlanCenter hidden or destroyed during refresh discards late data without affecting draft or disclosure state', async () => {
  for (const leave of ['hidden', 'destroyed']) {
    const pending = deferred(); const f = planFixture(() => pending.promise, () => overview('late'));
    f.page.title = '未发送任务草稿'; f.page.taskFormExpanded = true;
    const reading = f.page.reload(true);
    if (leave === 'hidden') { f.page.active = false; f.page.activityChanged(); } else f.page.aboutToDisappear();
    pending.resolve({ timetable: [{ title: 'late' }] }); await reading;
    assert.deepEqual(f.page.timetable, []); assert.deepEqual(f.calls, ['context']);
    assert.equal(f.page.title, '未发送任务草稿'); assert.equal(f.page.taskFormExpanded, true);
  }
});

// These tests execute production non-Builder methods and the real controller with mocked I/O.
// They do not compile ArkTS builders or prove native rendering, keyboard or accessibility behavior.


test('compact conflict summary uses the same controller and preserves query-only state after folding', async () => {
  const f = panelFixture({ confirm: async () => { throw new Error('timeout'); } });
  f.page.compact = true;
  let opened = 0; f.page.onOpenDetails = () => opened++;
  f.page.aboutToAppear(); await tick();
  const controller = f.page.replanner();
  assert.match(f.page.summaryTitle(), /1 项任务/);
  f.page.openDetails(); assert.equal(opened, 1);
  f.page.compact = false;
  await controller.preview(); await controller.confirm();
  assert.equal(f.page.state.phase, 'uncertain');
  const before = f.calls.length;
  f.page.compact = true;
  assert.equal(f.page.replanner(), controller);
  assert.match(f.page.summaryTitle(), /核对结果/);
  assert.match(f.page.summaryDetail(), /勿重复提交/);
  f.page.openDetails(); f.page.compact = false;
  assert.equal(opened, 2); assert.equal(f.calls.length, before);
  await controller.confirm(); await controller.preview(); controller.dismiss();
  assert.equal(f.calls.length, before, 'folding cannot revive a second POST');
  f.page.active = false; f.page.activityChanged(); f.page.openDetails();
  assert.equal(opened, 2, 'hidden summary cannot navigate');
});

test('another unresolved planning write prevents replan preview/confirmation while result reads remain available', async () => {
  const f = panelFixture(); const writeStates = []; f.page.onWriteStateChanged = value => writeStates.push(value);
  f.page.aboutToAppear(); await tick(); f.page.writeBlocked = true;
  f.page.previewRequested(); await tick(); assert.deepEqual(f.calls, ['report']);
  f.page.writeBlocked = false; f.page.previewRequested(); await tick(); assert.equal(f.page.state.phase, 'review');
  f.page.writeBlocked = true; f.page.confirmRequested(); await tick(); assert.equal(f.calls.some(x => x.startsWith('confirm:')), false);
  f.page.writeBlocked = false; f.page.confirmRequested(); await tick();
  assert.equal(f.applied.length, 1); assert.equal(writeStates.includes(true), true); assert.equal(writeStates.at(-1), false);
});
