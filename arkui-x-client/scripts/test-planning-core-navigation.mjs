import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';

const read = path => readFileSync(new URL(`../entry/src/main/ets/${path}`, import.meta.url), 'utf8');
const noImports = text => text.replace(/^import \{[\s\S]*?\} from '[^']+';\r?\n/gm, '').replace(/^import [^\n]+;\r?\n/gm, '');
const utility = async name => import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(noImports(read(`utils/${name}.ets`)))).toString('base64')}`);
const agenda = await utility('DailyAgenda');
const presentation = await utility('PlanPresentation');
const source = read('pages/PlanCenterPage.ets');
const boundary = source.indexOf('\n  @Builder');
assert.ok(boundary > 0);
const controller = noImports(source.slice(0, boundary))
  .replace(/^@Component\r?\n/m, '').replace(/@(Prop|State)\s+|@Watch\('[^']+'\)\s*/g, '')
  .replace('export struct PlanCenterPage', 'class PlanCenterPage') + '\n}\n';
const factory = new Function('CampusFlowApi', 'TextInputController', 'Scroller', 'AppTheme', 'Curve',
  'shanghaiDate', 'buildDailyAgenda', 'formatPlanDateTime', 'Date', stripTypeScriptTypes(controller) + '\nreturn PlanCenterPage;');
const empty = () => ({ plans: [], tasks: [], total_tasks: 0, completed_tasks: 0, due_today: 0, overdue_tasks: 0, progress: 0 });
const task = (id, extra = {}) => ({ task_id: id, title: '相同标题', plan_id: null, milestone_id: null,
  start_at: '2026-10-20T09:00:00+08:00', end_at: '2026-10-20T10:00:00+08:00',
  reminder_minutes: null, location: '', status: 'pending', source: 'agent', created_at: '', completed_at: null, ...extra });
function deferred() { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; }
function fixture(handlers = {}, now = Date.parse('2026-10-19T23:30:00Z')) {
  const calls = [], navigation = [], closed = [];
  const data = empty();
  class Api {
    async context() { calls.push('context'); return handlers.context ? handlers.context() : { timetable: [] }; }
    async planning() { calls.push('planning'); return handlers.planning ? handlers.planning() : data; }
    async createTask(title, at) { calls.push(['create', title, at]); return handlers.create?.(); }
    async updateTask(id, done) { calls.push(['update', id, done]); return handlers.update?.(); }
    async deleteTask(id) { calls.push(['delete', id]); return handlers.delete?.(); }
  }
  class Input { stopEditing() {} }
  class Scroller { offset = 0; }
  class Clock extends Date { static now() { return now; } }
  const Page = factory(Api, Input, Scroller, { motion: () => 0, pageInset: 20 }, { EaseOut: '' },
    agenda.shanghaiDate, agenda.buildDailyAgenda, presentation.formatPlanDateTime, Clock);
  const page = new Page();
  page.getUIContext = () => ({ animateTo: (_options, update) => update() });
  page.onInnerNavigationChanged = active => navigation.push(active);
  page.onCloseFocus = () => closed.push(true);
  return { page, data, calls, navigation, closed };
}

test('three views preserve independent scrolling, calendar, filters and one task draft', () => {
  const { page, calls } = fixture();
  page.selectedDate = '2026-11-09'; page.calendarMonth = new Date(2026, 10, 1).getTime();
  page.title = '长任务草稿'.repeat(40); page.draftTaskDate = '2026-10-22'; page.draftDateChoice = 'calendar'; page.draftTaskTime = '18:45';
  page.expandedPlanIds = ['plan-1']; page.taskFilter = 'completed';
  const snapshot = [page.title, page.draftTaskDate, page.draftDateChoice, page.draftTaskTime, page.selectedDate, page.calendarMonth];
  const scrolls = [page.scheduleScroller, page.plansScroller, page.tasksScroller];
  scrolls.forEach((item, i) => item.offset = 100 + i);
  for (const view of ['plans', 'tasks', 'schedule']) { page.selectView(view); assert.equal(page.currentView, view); }
  page.selectView('not-a-view'); assert.equal(page.currentView, 'schedule');
  assert.deepEqual([page.title, page.draftTaskDate, page.draftDateChoice, page.draftTaskTime, page.selectedDate, page.calendarMonth], snapshot);
  assert.equal(page.taskFilter, 'completed'); assert.deepEqual(page.expandedPlanIds, ['plan-1']);
  assert.deepEqual([page.scheduleScroller, page.plansScroller, page.tasksScroller], scrolls);
  assert.deepEqual(scrolls.map(item => item.offset), [100, 101, 102]); assert.deepEqual(calls, []);
});

test('internal task/plan/draft/conflict details share the same return path without changing source view', () => {
  const { page, navigation, closed } = fixture(); page.selectView('tasks'); page.taskFilter = 'pending';
  page.title = '保留'; page.draftTaskDate = '2026-10-22';
  for (const kind of ['task', 'plan', 'draft', 'conflicts']) {
    page.openDetails(kind, 'id'); assert.equal(page.detailKind, kind); page.backRequested();
    assert.equal(page.detailKind, ''); assert.equal(page.currentView, 'tasks'); assert.equal(page.taskFilter, 'pending');
  }
  assert.equal(page.title, '保留'); assert.equal(page.draftTaskDate, '2026-10-22');
  assert.deepEqual(navigation, [true, false, true, false, true, false, true, false]); assert.deepEqual(closed, []);
});

test('external ID focus finds exact record despite duplicate titles and returns to Index once', () => {
  const { page, closed } = fixture(); page.overview.tasks = [task('a'), task('b')]; page.currentView = 'plans';
  page.focusTaskId = 'b'; page.focusRevision = 1; page.focusChanged();
  assert.deepEqual(page.focusedTasks().map(item => item.task_id), ['b']); assert.equal(page.currentView, 'plans');
  page.backRequested(); page.backRequested(); assert.equal(closed.length, 1); assert.equal(page.detailKind, '');
  page.focusPlanId = 'plan-b'; page.focusTaskId = ''; page.focusRevision++;
  page.overview.plans = [{ plan_id: 'plan-a', title: '重复' }, { plan_id: 'plan-b', title: '重复' }];
  page.focusChanged(); assert.deepEqual(page.focusedPlans().map(item => item.plan_id), ['plan-b']);
});

test('external task → owning plan → back task → back origin preserves exact frames and only pops Index once', () => {
  const { page, closed, navigation } = fixture();
  page.overview.tasks = [task('task-1', { plan_id: 'plan-1' }), task('task-2', { plan_id: 'plan-2' })];
  page.overview.plans = [{ plan_id: 'plan-1', title: '相同标题' }, { plan_id: 'plan-2', title: '相同标题' }];
  page.focusTaskId = 'task-1'; page.focusRevision = 1; page.focusChanged();
  const originFrame = page.detailStack[0];
  page.openDetails('plan', page.focusedTasks()[0].plan_id);
  assert.equal(page.detailStack.length, 2); assert.strictEqual(page.detailStack[0], originFrame);
  assert.equal(page.detailId, 'plan-1'); assert.equal(page.backLabel(), '返回任务详情');
  page.backRequested(); assert.equal(page.detailId, 'task-1'); assert.equal(page.detailKind, 'task');
  assert.strictEqual(page.detailStack[0], originFrame); assert.equal(page.topDetailKey(), originFrame.key);
  assert.equal(page.backLabel(), '返回来源页面'); assert.equal(closed.length, 0);
  page.backRequested(); page.backRequested(); assert.equal(closed.length, 1); assert.equal(page.detailStack.length, 0);
  assert.deepEqual(navigation, [true, true, true, false]);
});

test('internal plan → task → back restores the same plan frame and original goals view', () => {
  const { page, closed } = fixture(); page.currentView = 'plans'; page.plansScroller.offset = 480;
  page.openDetails('plan', 'plan-1'); const planFrame = page.detailStack[0];
  page.openDetails('task', 'task-1'); assert.equal(page.backLabel(), '返回目标计划');
  page.openDetails('task', 'task-1'); assert.equal(page.detailStack.length, 2, 'double navigation to current detail does not duplicate it');
  page.closeDetails(); assert.strictEqual(page.detailStack[0], planFrame); assert.equal(page.detailId, 'plan-1');
  page.closeDetails(); assert.equal(page.currentView, 'plans'); assert.equal(page.plansScroller.offset, 480);
  assert.equal(page.detailKind, ''); assert.deepEqual(closed, []);
});

test('new or cleared external focus discards the entire old detail stack without a second origin pop', () => {
  const { page, closed } = fixture();
  page.focusTaskId = 'old'; page.focusRevision = 1; page.focusChanged(); page.openDetails('plan', 'old-plan');
  page.focusTaskId = 'new'; page.focusRevision++; page.focusChanged();
  assert.equal(page.detailStack.length, 1); assert.equal(page.detailStack[0].id, 'new');
  page.openDetails('plan', 'new-plan'); page.focusTaskId = ''; page.focusRevision++; page.focusChanged();
  assert.deepEqual(page.detailStack, []); assert.equal(page.detailKind, ''); assert.deepEqual(closed, []);
});

test('explicit list navigation clears nested details without returning to their old external origin', () => {
  const { page, closed } = fixture(); page.focusTaskId = 'task-1'; page.focusRevision = 1; page.focusChanged();
  page.openDetails('plan', 'plan-1'); page.requestedView = 'tasks'; page.viewRevision = 1; page.viewRequested();
  assert.equal(page.currentView, 'tasks'); assert.deepEqual(page.detailStack, []); assert.equal(page.detailKind, '');
  assert.deepEqual(closed, []); page.backRequested(); assert.deepEqual(closed, []);
});

test('cleared external focus closes stale detail without popping the new Index route', () => {
  const { page, closed } = fixture(); page.focusTaskId = 'old'; page.focusRevision = 1; page.focusChanged();
  page.focusTaskId = ''; page.focusRevision = 2; page.focusChanged();
  assert.equal(page.detailKind, ''); assert.deepEqual(closed, []);
  page.openDetails('draft'); page.focusRevision = 3; page.focusChanged();
  assert.equal(page.detailKind, 'draft', 'empty props do not destroy a new internal editor');
});

test('missing or ambiguous focus never guesses by title and repeated revision does not reopen closed detail', () => {
  const { page } = fixture(); page.overview.tasks = [task('other')];
  page.focusTaskId = 'missing'; page.focusRevision = 1; page.focusChanged(); assert.deepEqual(page.focusedTasks(), []);
  page.closeDetails(); page.focusChanged(); assert.equal(page.detailKind, '');
  page.focusPlanId = 'also-set'; page.focusRevision++; page.focusChanged(); assert.equal(page.detailKind, 'invalid');
});

test('explicit agenda navigation selects Shanghai today while ordinary tab activation preserves browsing and draft', async () => {
  const { page } = fixture(); page.selectedDate = '2026-11-08'; page.draftTaskDate = '2026-11-12'; page.title = '草稿';
  page.requestedView = 'agenda'; page.viewRevision = 1; page.viewRequested();
  assert.equal(page.selectedDate, '2026-10-20'); assert.equal(page.currentView, 'schedule');
  assert.equal(page.draftTaskDate, '2026-11-12');
  page.selectedDate = '2026-11-09'; page.active = false; page.activityChanged(); page.active = true; page.activityChanged();
  assert.equal(page.selectedDate, '2026-11-09');
  for (const [request, view] of [['tasks', 'tasks'], ['goals', 'plans']]) {
    page.requestedView = request; page.viewRevision++; page.viewRequested(); assert.equal(page.currentView, view);
  }
  assert.equal(page.draftTaskDate, '2026-11-12'); assert.equal(page.title, '草稿');
});

test('timeline merges courses and offset-aware tasks, keeps overnight entries, and separates all-day/undated', () => {
  const { page } = fixture(); page.selectedDate = '2026-10-20';
  page.timetable = [{ date: '2026-10-20', title: '课程', start_time: '08:00', end_time: '09:00', location: '教室', teacher: '老师' }];
  page.overview.tasks = [task('late'), task('early', { start_at: '2026-10-19T23:00:00Z', end_at: null }),
    task('overnight', { start_at: '2026-10-19T23:00:00+08:00', end_at: '2026-10-20T01:00:00+08:00' }),
    task('allday', { source: 'manual', start_at: '2026-10-20T23:59:00+08:00', end_at: null }), task('undated', { start_at: null })];
  assert.deepEqual(page.dayTimeline().map(item => item.taskId || 'course'), ['overnight', 'early', 'course', 'late']);
  assert.match(page.dayTimeline()[0].time, /2026-10-19 23:00/); assert.match(page.dayTimeline()[2].detail, /老师/);
  assert.deepEqual(page.allDayTasks().map(item => item.task_id), ['allday']);
  assert.equal(page.selectedTasks().length, 4); assert.equal(page.unscheduledCount(), 1);
});

test('all task filters retain complete arrays without the old five-row cap', () => {
  const { page } = fixture(); page.overview.tasks = Array.from({ length: 18 }, (_, i) => task(`id-${i}`, {
    status: i < 6 ? 'completed' : 'pending', start_at: i >= 12 ? null : '2026-10-20T09:00:00+08:00' }));
  assert.equal(page.filteredTasks().length, 18);
  for (const [filter, count] of [['pending', 12], ['completed', 6], ['undated', 6]]) {
    page.selectTaskFilter(filter); assert.equal(page.filteredTasks().length, count);
  }
  page.selectTaskFilter('invalid'); assert.equal(page.taskFilter, 'undated');
});

test('undated filter is pending-only and malformed schedule values remain visible with an explicit warning', () => {
  const { page } = fixture(); page.selectedDate = '2026-10-20';
  page.overview.tasks = [task('undated', { start_at: null }), task('done', { start_at: null, status: 'completed' }),
    task('number', { start_at: 42 }), task('missing', { start_at: undefined }), task('invalid', { start_at: 'not-a-date' }),
    task('date-only', { start_at: '2026-10-20', end_at: null }), task('end-invalid', { end_at: 42 })];
  page.selectTaskFilter('undated'); assert.deepEqual(page.filteredTasks().map(item => item.task_id), ['undated']);
  page.selectTaskFilter('all'); assert.equal(page.filteredTasks().length, 7);
  for (const id of ['number', 'missing', 'invalid']) {
    assert.match(page.taskScheduleLabel(page.tasksForId(id)[0]), /时间格式异常/);
  }
  assert.equal(page.taskScheduleLabel(page.tasksForId('date-only')[0]), '2026-10-20 · 全天');
  assert.equal(page.scheduleTypesValid(page.tasksForId('end-invalid')[0]), false);
  assert.match(page.taskScheduleLabel(page.tasksForId('end-invalid')[0]), /结束时间异常/);
  assert.match(page.taskScheduleLabel(task('end-date', { end_at: '2026-10-20' })), /结束 2026-10-20（未设时间）/);
  assert.doesNotThrow(() => page.dayTimeline()); assert.doesNotThrow(() => page.calendarDays());
});

test('six-row month includes every real date and browsing does not mutate the applied draft', () => {
  const { page } = fixture(); page.calendarMonth = new Date(2026, 7, 1).getTime(); page.draftTaskDate = '2026-10-20';
  const cells = page.calendarDays(); assert.equal(cells.length, 37);
  assert.deepEqual(cells.filter(item => item.day > 0).map(item => item.day), Array.from({ length: 31 }, (_, i) => i + 1));
  page.selectDay('2026-08-31'); page.moveMonth(1); assert.equal(page.draftTaskDate, '2026-10-20');
});

test('full plan grouping preserves empty milestones and unknown milestone tasks by IDs', () => {
  const { page } = fixture(); const plan = { plan_id: 'p', milestones: [{ milestone_id: 'm1' }, { milestone_id: 'm2' }] };
  page.overview.tasks = [task('t1', { plan_id: 'p', milestone_id: 'm1' }), task('t2', { plan_id: 'p', milestone_id: 'missing' }),
    task('t3', { plan_id: 'other', milestone_id: 'm1' })];
  assert.deepEqual(page.milestoneTasks('p', 'm1').map(item => item.task_id), ['t1']);
  assert.deepEqual(page.milestoneTasks('p', 'm2'), []); assert.deepEqual(page.ungroupedPlanTasks(plan).map(item => item.task_id), ['t2']);
});

test('refresh cannot replace a newer focus and old hidden response cannot overwrite newer data', async () => {
  const late = deferred(); const { page } = fixture({ context: () => late.promise });
  page.focusTaskId = 'old'; page.focusRevision = 1; page.focusChanged(); const read = page.reload(true);
  page.focusTaskId = 'new'; page.focusRevision = 2; page.focusChanged(); page.active = false; page.activityChanged();
  late.resolve({ timetable: [{ title: 'stale' }] }); await read;
  assert.equal(page.detailId, 'new'); assert.deepEqual(page.timetable, []);
});

test('double tap creates one task and completion never erases a newly edited draft', async () => {
  const pending = deferred(); const { page, calls } = fixture({ create: () => pending.promise });
  page.title = '原任务'; page.draftTaskDate = '2026-10-20';
  const first = page.addTask(); await page.addTask(); page.title = '后来编辑的草稿'; pending.resolve(); await first;
  assert.equal(calls.filter(item => Array.isArray(item) && item[0] === 'create').length, 1);
  assert.equal(page.title, '后来编辑的草稿'); assert.equal(page.mutationBusy, false);
});

test('inactive system back cannot pop an unrelated root page', () => {
  const { page, closed } = fixture(); page.focusTaskId = 'task'; page.focusRevision = 1; page.focusChanged();
  page.active = false; page.backRequested(); assert.equal(page.detailKind, 'task'); assert.deepEqual(closed, []);
});

// These execute actual page methods with mocked I/O. Scroller identity checks do not prove
// native scroll retention, ArkUI layout, keyboard, accessibility or three-platform compilation.
