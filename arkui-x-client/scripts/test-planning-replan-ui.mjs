import './helpers/theme-fixture.mjs';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripThemeTypeScriptTypes as stripTypeScriptTypes } from './helpers/theme-fixture.mjs';
import { test } from 'node:test';
import { planningPageDependencies, timetableSnapshot, preferenceSnapshot } from './helpers/planning-overview-fixture.mjs';

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
const replan = new Function('CampusFlowRequestError', 'validateTimetableEntry', 'timestamp', 'courseTimestamp',
  stripTypeScriptTypes(replanSource) + '\nreturn { PlanningReplanController, hasCourseClassification, conflictCourseOverlap };')(CampusFlowRequestError, validateTimetableEntry, agenda.timestamp, agenda.courseTimestamp);
const Replan = replan.PlanningReplanController;
const plan = await utility('PlanPresentation');

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
    ['CampusFlowApi', 'PlanningReplanController', 'hasCourseClassification', 'conflictCourseOverlap', 'formatPlanTimeRange'], [Api, ClockedController, replan.hasCourseClassification, replan.conflictCourseOverlap, plan.formatPlanTimeRange]);
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
    assert.deepEqual([...ids].sort(), Array.from({ length: 13 }, (_, i) => `${expectedPrefix}${i}`).sort());
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
    ['CampusFlowApi', 'CampusFlowRequestError', 'Scroller'], [Api, CampusFlowRequestError, class { scrollTo() {} }]);
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
const courseSnapshot = title => timetableSnapshot([{date:'2026-10-20',title,start_time:'08:00',end_time:'09:00',location:'一教',teacher:'陈老师'}]);
function planFixture(timetable, planning, preferences = () => preferenceSnapshot()) {
  const calls = [];
  class Api {
    async timetable() { calls.push('timetable'); return timetable(); }
    async planning() { calls.push('planning'); return planning(); }
    async learningPreferences() { calls.push('preferences'); return preferences(); }
  }
  const Plan = component('pages/PlanCenterPage.ets', 'PlanCenterPage',
    ['CampusFlowApi', 'TextInputController', 'AppTheme', 'Curve', 'Scroller', 'shanghaiDate', 'buildDailyAgenda', ...Object.keys(planningPageDependencies)],
    [Api, class {}, { motion: () => 0 }, { EaseOut: '' }, class {}, agenda.shanghaiDate, agenda.buildDailyAgenda,...Object.values(planningPageDependencies)]);
  const page = new Plan(); page.getUIContext = () => ({ animateTo: (_options, update) => update() });
  return { page, calls };
}

test('PlanCenter latest refresh generation wins independently for each source', async () => {
  const first = deferred(); let reads = 0;
  const f = planFixture(() => ++reads === 1 ? first.promise : courseSnapshot('new'), () => overview('new'));
  const old = f.page.reload(true); await f.page.reload(true);
  first.resolve(courseSnapshot('old')); await old;
  assert.equal(f.page.timetable[0].title, 'new'); assert.equal(f.page.overview.tasks[0].task_id, 'new');
  assert.equal(f.page.timetableState,'ready'); assert.equal(f.page.planningState,'ready');
  assert.deepEqual(f.calls, ['planning','preferences','timetable','planning','preferences','timetable']);
});

test('PlanCenter failed source retains its own snapshot while fresh sources update; next refresh supersedes pending course read', async () => {
  const f = planFixture(() => courseSnapshot('new'), async () => { throw new Error('offline'); });
  f.page.timetable = courseSnapshot('old').entries; f.page.overview = overview('old'); await f.page.reload(true);
  assert.equal(f.page.timetable[0].title, 'new'); assert.equal(f.page.overview.tasks[0].task_id, 'old');
  assert.equal(f.page.timetableState,'ready'); assert.equal(f.page.planningState,'error'); assert.equal(f.page.sourcesComplete(),false);
  const pending = deferred(); let reads = 0;
  const g = planFixture(() => ++reads === 1 ? pending.promise : courseSnapshot('latest'), () => overview('latest'));
  const old = g.page.reload(true); await g.page.reload(); pending.resolve(courseSnapshot('older')); await old;
  assert.deepEqual(g.calls, ['planning','preferences','timetable','planning','preferences','timetable']); assert.equal(g.page.timetable[0].title, 'latest');
});

test('PlanCenter hidden or destroyed during refresh discards late data without affecting draft or disclosure state', async () => {
  for (const leave of ['hidden', 'destroyed']) {
    const pending = deferred(), planning=deferred(), preferences=deferred();
    const f = planFixture(() => pending.promise, () => planning.promise, () => preferences.promise);
    f.page.title = '未发送任务草稿'; f.page.taskFormExpanded = true;
    const reading = f.page.reload(true);
    if (leave === 'hidden') { f.page.active = false; f.page.activityChanged(); } else f.page.aboutToDisappear();
    pending.resolve(courseSnapshot('late'));planning.resolve(overview('late'));preferences.resolve(preferenceSnapshot());await reading;
    assert.deepEqual(f.page.timetable, []); assert.deepEqual(f.page.overview.tasks, []); assert.equal(f.page.preferences,null);
    assert.deepEqual(f.calls, ['planning','preferences','timetable']);
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

test('panel separates accepted and changed course overlaps, reaches all rows and reports exact intersection', async()=>{
  const value=report(1);value.conflicts=[];value.unchecked=[];
  value.accepted_course_overlaps=Array.from({length:13},(_,i)=>({...report().conflicts[0],task_id:`accepted-${String(i).padStart(2,'0')}`,title:'同名任务'}));
  value.course_overlap_reviews=[{...report().conflicts[0],task_id:'changed-id',title:'同名任务'}];
  const f=panelFixture({report:async()=>value});f.page.aboutToAppear();await tick();
  assert.match(f.page.summaryTitle(),/1 项课内安排需要重新核对/);assert.match(f.page.summaryDetail(),/13 项已确认安排保持原时段/);
  assert.equal(f.page.detailCount(),14);const found=[];
  for(let i=0;i<3;i++){found.push(...f.page.overlapRows('accepted').map(x=>x.task_id));f.page.movePage('accepted',1,13);}
  assert.deepEqual(found,value.accepted_course_overlaps.map(x=>x.task_id));assert.equal(f.page.pageFor('accepted'),2);
  const item=value.course_overlap_reviews[0];assert.match(f.page.overlapText(item,item.courses[0]),/2026-10-20 10:00.*11:00/);
  const opened=[];f.page.onOpenTask=id=>opened.push(id);f.page.openTask('changed-id');f.page.openTask('absent');
  assert.deepEqual(opened,['changed-id']);f.page.state.phase='uncertain';f.page.openTask('accepted-00');assert.equal(opened.length,1,'unknown write cannot lose its recovery page');
  f.page.state.phase='idle';f.page.active=false;f.page.openTask('accepted-00');assert.equal(opened.length,1);
});

test('legacy no-conflict report is visibly incomplete rather than all course arrangements verified',async()=>{
  const value=report(0);const f=panelFixture({report:async()=>value});f.page.aboutToAppear();await tick();
  assert.match(f.page.summaryTitle(),/普通/);assert.match(f.page.summaryDetail(),/未提供课内确认分类/);
  value.accepted_course_overlaps=[];value.course_overlap_reviews=[];await f.page.replanner().refresh();
  assert.match(f.page.summaryTitle(),/未发现待处理/);assert.doesNotMatch(f.page.summaryDetail(),/未提供/);
});

test('course scan pagination is stably ordered by time then exact task ID, including same titles',async()=>{
  const value=report(0),base=report().conflicts[0];value.accepted_course_overlaps=[{...base,task_id:'z'}, {...base,task_id:'a'},
    {...base,task_id:'earlier',start_at:'2026-10-20T09:30:00+08:00'}];value.course_overlap_reviews=[];
  const f=panelFixture({report:async()=>value});f.page.aboutToAppear();await tick();
  assert.deepEqual(f.page.overlapRows('accepted').map(x=>x.task_id),['earlier','a','z']);
  assert.deepEqual(value.accepted_course_overlaps.map(x=>x.task_id),['z','a','earlier'],'source snapshot remains unchanged');
});


test('confirmed replan unresolved task remains reachable after controller clears scanner report',async()=>{
 const f=panelFixture();f.page.aboutToAppear();await tick();await f.page.replanner().preview();await f.page.replanner().confirm();
 assert.equal(f.page.state.report,null);assert.ok(f.page.state.preview.unresolved.length);
 const opened=[];f.page.onOpenTask=id=>opened.push(id);f.page.openTask('unresolved-0');f.page.openTask('absent');
 assert.deepEqual(opened,['unresolved-0']);f.page.state.phase='uncertain';f.page.openTask('unresolved-0');assert.equal(opened.length,1);
});


test('subscription review-required response preserves timetable and uses an actionable safe message',async()=>{
 const f=profileFixture(async()=>{throw new CampusFlowRequestError(422,'IMPORT_REVIEW_REQUIRED','raw private-url');});
 await f.page.syncSubscription();assert.equal(f.page.timetableUpdated,false);assert.equal(f.changed.length,0);assert.equal(f.page.subscriptionNeedsCheck,false);
 assert.match(f.page.message,/逐条核对/);assert.doesNotMatch(f.page.message,/private-url/);
});

test('successful subscription retains the controlled interpretation warnings next to its receipt',async()=>{
 const f=profileFixture(async()=>({status:{configured:true},imported_count:2,warnings:['来源未提供时区，本次按北京时间解释，请核对。']}));
 await f.page.syncSubscription();assert.equal(f.changed.length,1);assert.match(f.page.message,/北京时间/);
});

test('UX08 scanner permits read-only previews but cannot confirm a batch containing a status-locked task',async()=>{
  const f=panelFixture();const opened=[];f.page.onOpenStatus=id=>opened.push(id);
  f.page.aboutToAppear();await tick();f.page.previewRequested();await tick();
  f.page.statusLockedTaskIds=['task-0'];f.page.confirmRequested();await tick();
  assert.deepEqual(opened,['task-0']);assert.equal(f.calls.some(call=>call.startsWith('confirm:')),false);
  f.page.statusLockedTaskIds=['unrelated-task'];f.page.confirmRequested();await tick();
  assert.equal(f.calls.filter(call=>call.startsWith('confirm:')).length,1);
});
