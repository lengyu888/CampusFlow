import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';

// Execute the real page methods with controlled HTTP and clocks. This does not render ArkUI.
const source = readFileSync(new URL('../entry/src/main/ets/pages/HomePage.ets', import.meta.url), 'utf8');
const controller = source.slice(0, source.indexOf('\n  @Builder'))
  .replace(/^import [^\n]+;\r?\n/gm, '')
  .replace(/^@Component\r?\n/gm, '')
  .replace(/@(State|Prop)\s+|@Watch\('[^']+'\)\s*/g, '')
  .replace('export struct HomePage', 'class HomePage') + '\n}\n';
const helperSource = readFileSync(new URL('../entry/src/main/ets/utils/DailyAgenda.ets', import.meta.url), 'utf8')
  .replace(/^import [^\n]+;\r?\n/gm, '');
const helpers = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(helperSource)).toString('base64')}`);
const feedbackSource = readFileSync(new URL('../entry/src/main/ets/utils/AgentFeedback.ets', import.meta.url), 'utf8').replace(/^import [^\n]+;\r?\n/gm, '');
const feedback = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(feedbackSource)).toString('base64')}`);
const create = new Function('CampusFlowRequestError', 'CampusFlowApi', 'Scroller', 'Date', 'setInterval', 'clearInterval',
  'buildDailyAgenda', 'shanghaiDate', 'shanghaiTime', stripTypeScriptTypes(controller) + '\nreturn HomePage;');

function deferred() {
  let resolve, reject;
  const promise = new Promise((ok, fail) => { resolve = ok; reject = fail; });
  return { promise, resolve, reject };
}
const flush = async () => { for (let index = 0; index < 6; index++) await Promise.resolve(); };
const course = (title = '课程') => ({ date: '2026-10-19', title, start_time: '08:05', end_time: '09:40', location: '教研楼', teacher: '' });
function task(overrides = {}) {
  return { task_id: 'task-1', plan_id: 'plan-1', milestone_id: null, title: '同名任务',
    start_at: '2026-10-19T10:00:00+08:00', end_at: '2026-10-19T11:00:00+08:00',
    location: '自习室', status: 'pending', source: 'agent', reminder_minutes: null,
    created_at: '2026-10-18T10:00:00+08:00', completed_at: null, ...overrides };
}
const overview = (tasks = []) => ({ plans: [], tasks, total_tasks: tasks.length, completed_tasks: 0,
  due_today: tasks.length, overdue_tasks: 0, progress: 0 });

function setup(overrides = {}) {
  const calls = [];
  const hooks = { context: async () => ({ timetable: [course('更新课程')] }),
    planning: async () => overview([task()]), updateTask: async () => ({}), ...overrides };
  class Api {
    constructor(base, token) { this.base = base; this.token = token; }
    async context() { calls.push(['context', this.token]); return hooks.context(this.token); }
    async planning() { calls.push(['planning', this.token]); return hooks.planning(this.token); }
    async updateTask(id, done) { calls.push(['updateTask', id, done, this.token]); return hooks.updateTask(id, done, this.token); }
  }
  const clock = { now: Date.parse('2026-10-19T09:00:00+08:00'), nextId: 1, intervals: new Map() };
  class ClockDate extends Date { static now() { return clock.now; } }
  const HomePage = create(feedback.CampusFlowRequestError, Api, class Scroller {}, ClockDate,
    (callback) => { const id = clock.nextId++; clock.intervals.set(id, callback); return id; },
    (id) => clock.intervals.delete(id), helpers.buildDailyAgenda, helpers.shanghaiDate, helpers.shanghaiTime);
  const page = new HomePage();
  page.baseUrl = 'https://campus.invalid'; page.token = 'account-a';
  page.user = { display_name: '同学' };
  page.courses = [course('原课程')]; page.overview = overview([task({ title: '原任务' })]);
  return { page, calls, hooks, clock };
}

test('context and planning commit as a coherent snapshot only after both succeed', async () => {
  const context = deferred(); const planning = deferred();
  const { page, calls } = setup({ context: () => context.promise, planning: () => planning.promise });
  const oldCourses = page.courses; const oldOverview = page.overview;
  const loading = page.loadToday();
  assert.equal(page.loading, true);
  context.resolve({ timetable: [course('新课程')] }); await flush();
  assert.equal(page.courses, oldCourses, 'a partial read must not replace the prior coherent snapshot');
  assert.equal(page.overview, oldOverview);
  planning.resolve(overview([task({ title: '新任务' })])); await loading;
  assert.deepEqual(calls.map((call) => call[0]), ['context', 'planning']);
  assert.equal(page.courses[0].title, '新课程'); assert.equal(page.overview.tasks[0].title, '新任务');
  assert.equal(page.loading, false); assert.equal(page.errorText, '');
});

test('hiding during the context request prevents its planning follow-up and any data replacement', async () => {
  const context = deferred(); const { page, calls, clock } = setup({ context: () => context.promise });
  const old = page.overview; const loading = page.loadToday();
  page.active = false; page.activityChanged();
  context.resolve({ timetable: [course('迟到课程')] }); await loading;
  assert.equal(page.overview, old); assert.equal(page.courses[0].title, '原课程');
  assert.equal(page.loading, false); assert.equal(clock.intervals.size, 0);
  assert.deepEqual(calls.map((call) => call[0]), ['context']);
});

test('logout/disappearance while planning is pending cannot write old account data or errors', async () => {
  for (const fail of [false, true]) {
    const planning = deferred(); const { page } = setup({ planning: () => planning.promise });
    const old = page.overview; const loading = page.loadToday(); await flush();
    page.token = ''; page.aboutToDisappear(); page.errorText = '已退出';
    if (fail) planning.reject(new Error('late private failure')); else planning.resolve(overview([task({ title: '旧账号回包' })]));
    await loading;
    assert.equal(page.overview, old); assert.equal(page.courses[0].title, '原课程');
    assert.equal(page.errorText, '已退出');
  }
});

test('token or server change blocks old reads even before the native disappear callback runs', async () => {
  for (const field of ['token', 'baseUrl']) {
    const context = deferred(); const { page, calls } = setup({ context: () => context.promise });
    const old = page.overview; const loading = page.loadToday();
    page[field] = field === 'token' ? 'account-b' : 'https://other.invalid';
    context.resolve({ timetable: [course('旧账户课程')] }); await loading;
    assert.equal(page.overview, old); assert.equal(page.courses[0].title, '原课程');
    assert.deepEqual(calls.map((call) => call[0]), ['context']);
  }
});

test('an older planning response cannot replace a newer completed refresh', async () => {
  const oldPlanning = deferred(); let reads = 0;
  const { page } = setup({ planning: () => ++reads === 1 ? oldPlanning.promise : Promise.resolve(overview([task({ title: '最新任务' })])) });
  const first = page.loadToday(); await flush();
  await page.loadToday(); assert.equal(page.overview.tasks[0].title, '最新任务');
  oldPlanning.resolve(overview([task({ title: '过时任务' })])); await first;
  assert.equal(page.overview.tasks[0].title, '最新任务'); assert.equal(page.loading, false);
});

test('context or planning failure preserves prior content and marks it unverified instead of empty', async () => {
  for (const endpoint of ['context', 'planning']) {
    const { page } = setup({ [endpoint]: async () => { throw new Error('network detail'); } });
    const oldCourses = page.courses; const oldOverview = page.overview;
    await page.loadToday();
    assert.equal(page.courses, oldCourses); assert.equal(page.overview, oldOverview);
    assert.match(page.errorText, /不是最新.*重试/); assert.equal(page.loading, false);
    assert.doesNotMatch(page.errorText, /network detail/);
  }
  const { page } = setup({ context: async () => { throw new Error('offline'); } });
  page.courses = []; page.overview = overview();
  await page.loadToday();
  assert.ok(page.errorText, 'a failed initial request is not a successful empty schedule');
  assert.equal(page.agenda().next, null);
});

test('duplicate task completion is locked until the server state is refreshed, with no optimistic mutation', async () => {
  const mutation = deferred(); const updated = overview([task({ status: 'completed' })]);
  const { page, calls } = setup({ updateTask: () => mutation.promise, planning: async () => updated });
  const current = page.overview.tasks[0]; const first = page.toggleTask(current);
  await page.toggleTask(current); await page.toggleTask(task({ task_id: 'task-2' }));
  assert.equal(calls.filter((call) => call[0] === 'updateTask').length, 1);
  assert.equal(page.overview.tasks[0].status, 'pending'); assert.equal(page.busyTaskId, current.task_id);
  mutation.resolve(); await first;
  assert.equal(page.overview, updated); assert.equal(page.busyTaskId, '');
  assert.deepEqual(calls[0], ['updateTask', 'task-1', true, 'account-a']);
  await page.toggleTask(updated.tasks[0]);
  assert.deepEqual(calls.filter((call) => call[0] === 'updateTask')[1], ['updateTask', 'task-1', false, 'account-a']);
});

test('a failed task request keeps the last known status, asks for verification, and does not replay the write', async () => {
  const { page, calls, hooks } = setup({ updateTask: async () => { throw new Error('ambiguous result'); } });
  const old = page.overview; await page.toggleTask(old.tasks[0]);
  assert.equal(page.overview, old); assert.equal(page.busyTaskId, '');
  assert.match(page.errorText, /核实.*重新加载/);
  assert.doesNotMatch(page.errorText, /ambiguous result|未写入|已撤销/);
  assert.deepEqual(calls.map((call) => call[0]), ['updateTask']);
  hooks.planning = async () => overview([task({ status: 'completed' })]);
  await page.loadToday();
  assert.equal(page.overview.tasks[0].status, 'completed'); assert.equal(page.errorText, '');
  assert.equal(calls.filter((call) => call[0] === 'updateTask').length, 1);
});

test('successful mutation followed by failed read retains content with a retryable stale notice', async () => {
  const { page, calls } = setup({ planning: async () => { throw new Error('read failed'); } });
  const old = page.overview; await page.toggleTask(old.tasks[0]);
  assert.equal(page.overview, old); assert.match(page.errorText, /不是最新.*重试/);
  assert.equal(page.busyTaskId, '');
  assert.deepEqual(calls.map((call) => call[0]), ['updateTask', 'context', 'planning']);
});

test('refresh started before a task commit cannot suppress its newer authoritative status', async () => {
  const mutation = deferred(); const oldRead = deferred(); let reads = 0;
  const updated = overview([task({ status: 'completed', title: '最新已完成' })]);
  const { page } = setup({ updateTask: () => mutation.promise,
    planning: () => ++reads === 1 ? oldRead.promise : Promise.resolve(updated) });
  const updating = page.toggleTask(page.overview.tasks[0]);
  const refreshing = page.loadToday(); await flush();
  assert.equal(reads, 1);
  mutation.resolve(); await updating;
  assert.equal(page.overview, updated, 'the write must start its own current refresh regardless of a newer pre-commit read');
  oldRead.resolve(overview([task({ status: 'pending', title: '提交前的旧数据' })])); await refreshing;
  assert.equal(page.overview, updated); assert.equal(page.busyTaskId, '');
});

test('a task completion while hidden does not fetch more data; returning refreshes it and restarts one clock', async () => {
  const mutation = deferred(); const { page, calls, clock } = setup({ updateTask: () => mutation.promise,
    planning: async () => overview([task({ status: 'completed' })]) });
  const updating = page.toggleTask(page.overview.tasks[0]);
  page.active = false; page.activityChanged(); mutation.resolve(); await updating;
  assert.deepEqual(calls.map((call) => call[0]), ['updateTask']);
  assert.equal(page.overview.tasks[0].status, 'pending'); assert.equal(page.busyTaskId, '');
  page.active = true; page.activityChanged(); await flush();
  assert.equal(page.overview.tasks[0].status, 'completed'); assert.equal(clock.intervals.size, 1);
  page.activityChanged(); await flush(); assert.equal(clock.intervals.size, 1);
  page.aboutToDisappear(); assert.equal(clock.intervals.size, 0);
});

test('old destroyed operation cannot clear a new operation lock after the page reappears', async () => {
  const oldMutation = deferred(); const newMutation = deferred(); let writes = 0;
  const { page } = setup({ updateTask: () => ++writes === 1 ? oldMutation.promise : newMutation.promise });
  const old = page.toggleTask(page.overview.tasks[0]);
  page.aboutToDisappear(); page.pageActive = true;
  const current = page.toggleTask(task({ task_id: 'new-task' }));
  oldMutation.resolve(); await old;
  assert.equal(page.busyTaskId, 'new-task');
  newMutation.resolve(); await current; assert.equal(page.busyTaskId, '');
});

test('date, greeting and agenda share the Shanghai clock including local midnight rollover', () => {
  const { page, clock } = setup();
  page.nowMs = Date.parse('2026-10-18T16:05:00Z');
  assert.equal(page.dateLabel(), '10月19日，周一'); assert.equal(page.greeting(), '上午好，同学');
  assert.equal(page.agenda().today, '2026-10-19');
  page.nowMs = Date.parse('2026-10-19T11:05:00Z'); assert.equal(page.greeting(), '晚上好，同学');
  page.nowMs = Date.parse('2026-10-19T15:59:59Z'); clock.now = Date.parse('2026-10-19T16:00:00Z');
  page.activityChanged();
  assert.equal(page.dateLabel(), '10月20日，周二'); assert.equal(page.agenda().today, '2026-10-20');
  page.aboutToDisappear();
});

test('same-title tasks use exact IDs for detail and completion callbacks, while courses open the route selector', async () => {
  const { page, calls } = setup(); const opened = [];
  page.overview = overview([task({ task_id: 'one' }), task({ task_id: 'two', plan_id: 'plan-two' })]);
  page.onOpenTaskDetails = (id) => opened.push(['task', id]); page.onOpenRoute = () => opened.push(['route']);
  const row = page.agenda().rows.find((item) => item.taskId === 'two');
  page.nextAction(row); page.toggleAgendaTask(row); await flush();
  assert.deepEqual(opened, [['task', 'two']]);
  assert.deepEqual(calls.find((call) => call[0] === 'updateTask'), ['updateTask', 'two', true, 'account-a']);
  page.nextAction(helpers.buildDailyAgenda([course()], [], page.nowMs).rows[0]);
  assert.deepEqual(opened, [['task', 'two'], ['route']]);
  const before = calls.length; page.toggleAgendaTask({ ...row, taskId: 'not-found' }); await flush();
  assert.equal(calls.length, before, 'an unknown ID must not fall back to a same-title task');
  assert.match(source, /onClick\(\(\) => this\.onOpenPlanDetails\(plan\.plan_id\)\)/,
    'the plan card passes the actual ID to the parent, not its duplicated title');
});

test('unscheduled labels distinguish absent dates from malformed data and never normalize invalid calendar dates', () => {
  const { page } = setup();
  for (const value of [null, '', '  ']) {
    assert.equal(page.taskUnscheduledLabel(task({ start_at: value })), '尚未安排日期');
  }
  for (const value of [undefined, 123, {}, false]) {
    const item = task({ start_at: value });
    page.overview = overview([item]);
    assert.equal(page.agenda().unscheduled[0], item);
    assert.equal(page.taskUnscheduledLabel(item), '时间数据异常，请在详情核对。');
  }
  const invalidDate = '2026-02-30T08:00:00+08:00';
  assert.equal(page.taskUnscheduledLabel(task({ start_at: invalidDate })), `待核对时间 · ${invalidDate}`);
  assert.doesNotMatch(page.taskUnscheduledLabel(task({ start_at: invalidDate })), /03-02/);
});

test('a definite conflict on restore explains how to adjust it without inventing a successful completion state', async () => {
  const { page } = setup({ updateTask: async () => { throw new feedback.CampusFlowRequestError(409, 'ACTION_CONFLICT', 'fixture'); } });
  const before = page.overview;
  await page.toggleTask(task({status: 'completed'}));
  assert.equal(page.overview, before); assert.match(page.errorText, /时间冲突/); assert.match(page.errorText, /任务详情/);
  assert.equal(page.busyTaskId, '');
});
