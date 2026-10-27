import './helpers/theme-fixture.mjs';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripThemeTypeScriptTypes as stripTypeScriptTypes } from './helpers/theme-fixture.mjs';
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
const evidence = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(readFileSync(new URL('../entry/src/main/ets/utils/EvidencePresentation.ets', import.meta.url), 'utf8').replace(/^import [^\n]+;\r?\n/gm, ''))).toString('base64')}`);
const timetableHelpers = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(readFileSync(new URL('../entry/src/main/ets/utils/OnboardingTimetable.ets', import.meta.url), 'utf8').replace(/^import [^\n]+;\r?\n/gm, ''))).toString('base64')}`);
const freeSource = readFileSync(new URL('../entry/src/main/ets/utils/FreeWindows.ets', import.meta.url), 'utf8').replace(/^import [^\n]+;\r?\n/gm, '').replace(/^export /gm, '');
const free = new Function('buildDailyAgenda', 'shanghaiDate', 'shanghaiTime', 'validateTimetableEntry', stripTypeScriptTypes(freeSource) + '\nreturn { partitionToday, findFreeWindow };')(helpers.buildDailyAgenda, helpers.shanghaiDate, helpers.shanghaiTime, timetableHelpers.validateTimetableEntry);
const create = new Function('CampusFlowRequestError', 'CampusFlowApi', 'Scroller', 'Date', 'setInterval', 'clearInterval',
  'buildDailyAgenda', 'shanghaiDate', 'shanghaiTime', 'partitionToday', 'findFreeWindow', 'hasFreshEvidence', 'validateTimetableEntry', stripTypeScriptTypes(controller) + '\nreturn HomePage;');

function deferred() {
  let resolve, reject;
  const promise = new Promise((ok, fail) => { resolve = ok; reject = fail; });
  return { promise, resolve, reject };
}
const flush = async () => { for (let index = 0; index < 6; index++) await Promise.resolve(); };
const snapshot = (entries) => ({ entries, revision: 'a'.repeat(64), evidence: [{ source_id: 'saved', label: '保存课表', kind: 'user', status: 'fresh', updated_at: '2026-10-18T10:00:00+08:00', expires_at: null, url: null, note: '用户录入' }] });
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
  const hooks = { timetable: async () => snapshot([course('更新课程')]),
    planning: async () => overview([task()]), updateTask: async () => ({}), ...overrides };
  class Api {
    constructor(base, token) { this.base = base; this.token = token; }
    async timetable() { calls.push(['timetable', this.token]); return hooks.timetable(this.token); }
    async planning() { calls.push(['planning', this.token]); return hooks.planning(this.token); }
    async updateTask(id, done) { calls.push(['updateTask', id, done, this.token]); return hooks.updateTask(id, done, this.token); }
  }
  const clock = { now: Date.parse('2026-10-19T09:00:00+08:00'), nextId: 1, intervals: new Map() };
  class ClockDate extends Date { static now() { return clock.now; } }
  const HomePage = create(feedback.CampusFlowRequestError, Api, class Scroller {}, ClockDate,
    (callback) => { const id = clock.nextId++; clock.intervals.set(id, callback); return id; },
    (id) => clock.intervals.delete(id), helpers.buildDailyAgenda, helpers.shanghaiDate, helpers.shanghaiTime, free.partitionToday, free.findFreeWindow, evidence.hasFreshEvidence, timetableHelpers.validateTimetableEntry);
  const page = new HomePage();
  page.baseUrl = 'https://campus.invalid'; page.token = 'account-a';
  page.user = { display_name: '同学', school: '杭州电子科技大学', campus: '下沙校区' };
  page.courseReadAt = clock.now - 60000; page.taskReadAt = clock.now - 60000;
  page.courses = [course('原课程')]; page.overview = overview([task({ title: '原任务' })]);
  return { page, calls, hooks, clock };
}

test('timetable and planning settle independently with explicit source state in one read generation', async () => {
  const courses = deferred(); const planning = deferred();
  const { page, calls } = setup({ timetable: () => courses.promise, planning: () => planning.promise });
  const oldOverview = page.overview;
  const loading = page.loadToday();
  assert.equal(page.loading, true); assert.equal(page.coursePhase, 'loading'); assert.equal(page.taskPhase, 'loading');
  courses.resolve(snapshot([course('新课程')])); await flush();
  assert.equal(page.courses[0].title, '新课程'); assert.equal(page.coursePhase, 'ready');
  assert.equal(page.overview, oldOverview); assert.equal(page.freeTime().window, null);
  planning.resolve(overview([task({ title: '新任务' })])); await loading;
  assert.deepEqual(calls.map((call) => call[0]), ['timetable', 'planning']);
  assert.equal(page.overview.tasks[0].title, '新任务'); assert.equal(page.taskPhase, 'ready');
  assert.equal(page.loading, false); assert.equal(page.errorText, '');
});

test('hiding during either read prevents late data replacement and stops the clock', async () => {
  const courses = deferred(); const planning = deferred();
  const { page, calls, clock } = setup({ timetable: () => courses.promise, planning: () => planning.promise });
  const old = page.overview; const loading = page.loadToday();
  page.active = false; page.activityChanged();
  courses.resolve(snapshot([course('迟到课程')])); planning.resolve(overview([task({title:'迟到任务'})])); await loading;
  assert.equal(page.overview, old); assert.equal(page.courses[0].title, '原课程');
  assert.equal(page.loading, false); assert.equal(clock.intervals.size, 0); assert.equal(page.sourcesReady(), false);
  assert.deepEqual(calls.map((call) => call[0]), ['timetable', 'planning']);
});

test('logout/disappearance while reads are pending cannot write old account data or errors', async () => {
  for (const fail of [false, true]) {
    const courses = deferred(); const planning = deferred();
    const { page } = setup({ timetable: () => courses.promise, planning: () => planning.promise });
    const old = page.overview; const loading = page.loadToday();
    page.token = ''; page.aboutToDisappear(); page.errorText = '已退出';
    courses.resolve(snapshot([course('旧账号课程')]));
    if (fail) planning.reject(new Error('late private failure')); else planning.resolve(overview([task({ title: '旧账号回包' })]));
    await loading;
    assert.equal(page.overview, old); assert.equal(page.courses[0].title, '原课程'); assert.equal(page.errorText, '已退出');
  }
});

test('token or server changes block old reads even before the native disappear callback', async () => {
  for (const field of ['token', 'baseUrl']) {
    const courses = deferred(); const planning = deferred();
    const { page, calls } = setup({ timetable: () => courses.promise, planning: () => planning.promise });
    const old = page.overview; const loading = page.loadToday();
    page[field] = field === 'token' ? 'account-b' : 'https://other.invalid';
    courses.resolve(snapshot([course('旧账户课程')])); planning.resolve(overview()); await loading;
    assert.equal(page.overview, old); assert.equal(page.courses[0].title, '原课程');
    assert.deepEqual(calls.map((call) => call[0]), ['timetable', 'planning']);
  }
});

test('older independent responses cannot replace a newer completed refresh', async () => {
  const oldPlanning = deferred(); const oldCourses = deferred(); let reads = 0, courseReads = 0;
  const { page } = setup({ timetable: () => ++courseReads === 1 ? oldCourses.promise : Promise.resolve(snapshot([course('最新课程')])),
    planning: () => ++reads === 1 ? oldPlanning.promise : Promise.resolve(overview([task({ title: '最新任务' })])) });
  const first = page.loadToday(); await flush(); await page.loadToday();
  oldPlanning.resolve(overview([task({ title: '过时任务' })])); oldCourses.resolve(snapshot([course('过时课程')])); await first;
  assert.equal(page.overview.tasks[0].title, '最新任务'); assert.equal(page.courses[0].title, '最新课程'); assert.equal(page.loading, false);
});

test('one source failure preserves its own prior data and does not suppress the independently successful source', async () => {
  for (const endpoint of ['timetable', 'planning']) {
    const { page } = setup({ [endpoint]: async () => { throw new Error('network detail'); } });
    const oldCourses = page.courses; const oldOverview = page.overview;
    await page.loadToday();
    if (endpoint === 'timetable') {
      assert.equal(page.courses, oldCourses); assert.equal(page.coursePhase, 'stale');
      assert.equal(page.overview.tasks[0].title, '同名任务'); assert.equal(page.taskPhase, 'ready');
    } else {
      assert.equal(page.overview, oldOverview); assert.equal(page.taskPhase, 'stale');
      assert.equal(page.courses[0].title, '更新课程'); assert.equal(page.coursePhase, 'ready');
    }
    assert.match(page.errorText, /不是最新.*重试/); assert.equal(page.loading, false);
    assert.equal(page.freeTime().window, null); assert.doesNotMatch(page.errorText, /network detail/);
  }
  const { page } = setup({ timetable: async () => { throw new Error('offline'); }, planning: async () => overview() });
  page.courses = []; page.overview = overview(); page.courseReadAt = 0; page.taskReadAt = 0;
  await page.loadToday(); assert.ok(page.errorText); assert.equal(page.coursePhase, 'error');
  assert.equal(page.taskPhase, 'ready'); assert.equal(page.freeTime().window, null); assert.equal(page.agenda().next, null);
});

test('status actions delegate exact tasks once per shared lock without optimistic mutation or old PATCH', async () => {
  const { page, calls } = setup(); const requests = [], opened = [];
  page.onTaskStatus = value => { requests.push(value); page.statusLockedTaskIds = page.statusLockedTaskIds.concat(value.task_id); };
  page.onOpenStatus = id => opened.push(id); const current = page.overview.tasks[0];
  await page.toggleTask(current); await page.toggleTask(current); await page.toggleTask(task({ task_id: 'task-2' }));
  assert.deepEqual(requests.map(value => value.task_id), ['task-1', 'task-2']);
  assert.deepEqual(opened, ['task-1']); assert.equal(page.overview.tasks[0].status, 'pending'); assert.deepEqual(calls, []);
});

test('unknown status stays query-only from the shared lock and a refreshed task flag does not replay a write', async () => {
  const { page, calls, hooks } = setup(); const requests = [], opened = [];
  page.onTaskStatus = value => requests.push(value); page.onOpenStatus = id => opened.push(id);
  page.statusLockedTaskIds = ['task-1']; const old = page.overview;
  await page.toggleTask(old.tasks[0]); assert.equal(page.overview, old); assert.deepEqual(opened, ['task-1']); assert.deepEqual(requests, []);
  hooks.planning = async () => overview([task({ status: 'completed' })]); await page.loadToday();
  await page.toggleTask(page.overview.tasks[0]); assert.deepEqual(opened, ['task-1', 'task-1']); assert.deepEqual(requests, []);
  assert.equal(calls.some(call => call[0] === 'updateTask'), false);
});

test('a parent receipt refresh that fails keeps current content with a stale notice instead of overlaying old receipt fields', async () => {
  const { page, calls } = setup({ planning: async () => { throw new Error('read failed'); } });
  const old = page.overview; await page.loadToday();
  assert.equal(page.overview, old); assert.match(page.errorText, /不是最新.*重试/);
  assert.deepEqual(calls.map(call => call[0]), ['timetable', 'planning']);
});

test('receipt-triggered newer authoritative refresh supersedes a read begun before the operation committed', async () => {
  const oldRead = deferred(); let reads = 0; const updated = overview([task({ status: 'completed', title: '最新已完成' })]);
  const { page } = setup({ planning: () => ++reads === 1 ? oldRead.promise : Promise.resolve(updated) });
  const old = page.loadToday(); await flush(); await page.loadToday();
  assert.equal(page.overview, updated); oldRead.resolve(overview([task({ title: '提交前旧数据' })])); await old;
  assert.equal(page.overview, updated);
});

test('hidden Home receives no new status writes; returning re-reads latest task and restarts only one clock', async () => {
  const { page, calls, clock } = setup({ planning: async () => overview([task({ status: 'completed' })]) });
  const requests = []; page.onTaskStatus = value => requests.push(value);
  await page.toggleTask(page.overview.tasks[0]); page.active = false; page.activityChanged();
  await page.toggleTask(task({task_id:'hidden'})); assert.equal(requests.length, 1); assert.deepEqual(calls, []);
  assert.equal(page.overview.tasks[0].status, 'pending'); page.active = true; page.activityChanged(); await flush();
  assert.equal(page.overview.tasks[0].status, 'completed'); assert.equal(clock.intervals.size, 1);
  page.activityChanged(); await flush(); assert.equal(clock.intervals.size, 1); page.aboutToDisappear(); assert.equal(clock.intervals.size, 0);
});

test('a destroyed Home cannot clear the account-level status lock or emit another completion', async () => {
  const { page } = setup(); const requests = [];
  page.onTaskStatus = value => requests.push(value); page.statusLockedTaskIds = ['new-task'];
  page.aboutToDisappear(); await page.toggleTask(task({task_id:'old-task'}));
  assert.deepEqual(requests, []); assert.deepEqual(page.statusLockedTaskIds, ['new-task']);
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
  const { page, calls } = setup(); const opened = [], status = []; page.onTaskStatus = value => status.push(value);
  page.overview = overview([task({ task_id: 'one' }), task({ task_id: 'two', plan_id: 'plan-two' })]);
  page.onOpenTaskDetails = (id) => opened.push(['task', id]); page.onOpenCourseRoute = (intent) => opened.push(['route', intent]);
  const row = page.agenda().rows.find((item) => item.taskId === 'two');
  page.nextAction(row); page.toggleAgendaTask(row); await flush();
  assert.deepEqual(opened, [['task', 'two']]);
  assert.deepEqual(status.map(value => value.task_id), ['two']); assert.equal(calls.some(call => call[0] === 'updateTask'), false);
  const currentCourse = page.courses[0];
  page.nextAction(page.agenda().rows.find((item) => item.kind === 'course'));
  assert.equal(opened[1][0], 'route'); assert.deepEqual(opened[1][1].course, currentCourse);
  assert.notEqual(opened[1][1].course, currentCourse, 'the intent receives a copy of all six source fields');
  assert.equal(opened[1][1].school, '杭州电子科技大学'); assert.equal(opened[1][1].campus, '下沙校区');
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

test('completed legacy tasks keep the real completed state and explain why no recovery receipt is available', async () => {
  const { page, calls } = setup(); const requested = []; page.onTaskStatus = value => requested.push(value);
  const completed = task({ status: 'completed' }); const old = page.overview; await page.toggleTask(completed);
  assert.equal(page.overview, old); assert.equal(requested[0], completed); assert.match(page.statusLabel(completed), /未保留可恢复凭据/);
  assert.deepEqual(calls, []); assert.equal(page.statusLabel(task({status:'completed',completion_operation_id:'exact-id'})), '恢复未完成');
});

test('plain capture is an explicit draft intent with Shanghai anchor and never calls an API', () => {
  const { page, calls, clock } = setup(); const opened = [];
  page.onOpenCapture = intent => opened.push(intent);
  clock.now = Date.parse('2026-10-19T16:00:00Z'); page.openCapture();
  assert.deepEqual(opened, [{ text:'',date:'',time:'',durationMinutes:null,anchorDate:'2026-10-20',timezone:'Asia/Shanghai',source:'home' }]);
  assert.equal(calls.length,0); page.active=false; page.openCapture(); assert.equal(opened.length,1);
});

test('free-time entry rechecks sources/time and only fills a 25-minute draft once that day', async () => {
  const { page, calls, clock } = setup({timetable:async()=>snapshot([course()]),planning:async()=>overview()});
  clock.now=Date.parse('2026-10-19T10:00:20+08:00'); await page.loadToday();
  const opened=[]; page.onOpenCapture=intent=>opened.push(intent); const before=calls.length;
  page.setBuffer(5); page.useFreeTime();
  assert.deepEqual(opened,[{text:'复习',date:'2026-10-19',time:'10:01',durationMinutes:25,anchorDate:'2026-10-19',timezone:'Asia/Shanghai',source:'gap'}]);
  assert.equal(calls.length,before); page.useFreeTime(); assert.equal(opened.length,1);
  page.gapDismissedDate=''; page.taskPhase='stale'; page.useFreeTime(); assert.equal(opened.length,1);
});

test('unknown or expired evidence cannot unlock a free-time action after a successful timetable GET', async () => {
  const { page, hooks, clock } = setup({planning:async()=>overview()}); const payload=snapshot([]);
  payload.evidence[0].expires_at='2026-10-19T09:01:00+08:00'; hooks.timetable=async()=>payload;
  await page.loadToday(); assert.ok(page.freeTime().window);
  clock.now=Date.parse('2026-10-19T09:01:00+08:00'); page.nowMs=clock.now;
  assert.equal(page.freeTime().window,null); assert.equal(page.coursePhase,'ready','transport success is distinct from evidence expiry');
  hooks.timetable=async()=>({...snapshot([]),evidence:[]}); await page.loadToday(); assert.equal(page.freeTime().window,null);
});

test('connection watcher immediately removes prior account source data, expansion and suggestion state', async () => {
  const pending=deferred(); const {page}=setup({timetable:()=>pending.promise,planning:async()=>overview()});
  const old=page.loadToday(); page.sourceExpanded=true; page.earlierExpanded=true; page.bufferMinutes=15;
  page.gapDismissedDate='2026-10-19'; page.active=false; page.baseUrl='https://other.invalid'; page.connectionChanged();
  assert.equal(page.courses.length,0); assert.equal(page.overview.tasks.length,0);
  assert.equal(page.courseReadAt,0); assert.equal(page.taskReadAt,0); assert.equal(page.timetableRevision,'');
  assert.equal(page.sourceExpanded,false); assert.equal(page.earlierExpanded,false); assert.equal(page.bufferMinutes,0);
  pending.resolve(snapshot([course('旧回包')])); await old; assert.equal(page.courses.length,0);
});

test('same-title course routes carry the precise six fields, snapshot, scope and cloned evidence', async () => {
  const second={...course('同名课'),start_time:'15:00',end_time:'16:30',location:'另一栋教研楼 204',teacher:'另一位老师'};
  const {page}=setup({timetable:async()=>snapshot([course('同名课'),second])}); await page.loadToday();
  const opened=[];page.onOpenCourseRoute=intent=>opened.push(intent);
  page.nextAction(page.agenda().rows.find(row=>row.kind==='course' && row.startTime==='15:00'));
  assert.deepEqual(opened[0].course,second); assert.equal(opened[0].timetableRevision,'a'.repeat(64));
  assert.deepEqual(opened[0].evidence,page.courseEvidence); opened[0].evidence[0].note='外部改变'; assert.notEqual(page.courseEvidence[0].note,'外部改变');
  const row=page.agenda().rows.find(row=>row.kind==='course'); page.courses[0]={...page.courses[0],location:'已修改'};
  page.nextAction(row); assert.equal(opened.length,1); assert.match(page.errorText,/已变化/);
});

test('stale course route attribution includes a visible read-status warning instead of silently claiming a current location', async () => {
  const {page}=setup();await page.loadToday();page.coursePhase='stale';const opened=[];page.onOpenCourseRoute=intent=>opened.push(intent);
  page.nextAction(page.agenda().rows.find(row=>row.kind==='course'));
  assert.equal(opened[0].evidence.at(-1).status,'unverified'); assert.match(opened[0].evidence.at(-1).note,/上次成功读取/);
});

test('invalid timetable rows or revisions cannot replace a last known complete timetable', async () => {
  for(const payload of [{...snapshot([]),revision:'broken'},snapshot([{...course(),end_time:'07:00'}]),snapshot([{...course(),location:undefined}]),
    snapshot([{...course(),start_time:' 08:05 '}]),snapshot([{...course(),date:' 2026-10-19 '}])]) {
    const {page}=setup({timetable:async()=>payload}); const old=page.courses; await page.loadToday();
    assert.equal(page.courses,old);assert.equal(page.coursePhase,'stale');assert.equal(page.freeTime().window,null);
  }
});

test('page groups retain all rows and never collapse incomplete timed work', () => {
  const {page}=setup(); page.nowMs=Date.parse('2026-10-19T14:10:00+08:00');
  page.overview=overview([task({task_id:'late'}),task({task_id:'unknown',start_at:'2026-10-19T13:00:00+08:00',end_at:null}),task({task_id:'done',status:'completed'})]);
  const groups=page.groups(); assert.equal(groups.overdue[0].taskId,'late'); assert.equal(groups.upcoming[0].taskId,'unknown');
  assert.equal(groups.earlier.length,2); assert.equal(groups.upcoming.length+groups.overdue.length+groups.earlier.length,page.agenda().rows.length);
  assert.match(source,/TimelineList\(\(\) => this\.groups\(\)\.overdue\)/); assert.match(source,/if \(this\.earlierExpanded\)/);
});

test('focus entry uses an exact current task and a bounded honest shortcut list without task mutation',()=>{
 const {page,calls}=setup(),opened=[];page.taskPhase='ready';page.onOpenFocus=value=>opened.push(value);
 page.overview=overview(Array.from({length:5},(_,i)=>task({task_id:`focus-${i}`,title:'同名任务',status:i===4?'completed':'pending'})));
 assert.deepEqual(page.focusCandidates().map(t=>t.task_id),['focus-0','focus-1','focus-2']);
 const old=page.overview.tasks[1];page.overview.tasks[1]={...old,title:'最新标题'};page.focusRequested(old);
 assert.equal(opened[0],page.overview.tasks[1]);assert.equal(opened[0].title,'最新标题');assert.deepEqual(calls,[]);
 page.taskPhase='stale';page.focusRequested(old);assert.deepEqual(page.focusCandidates(),[]);assert.equal(opened.length,1);
 page.taskPhase='ready';page.active=false;page.focusRequested(old);assert.equal(opened.length,1);
});

test('review entry uses exact campus today and is inert while hidden',()=>{const {page}=setup(),calls=[];page.active=true;page.onOpenReview=(...args)=>calls.push(args);page.reviewRequested();assert.deepEqual(calls,[['day','2026-10-19']]);page.active=false;page.reviewRequested();assert.equal(calls.length,1);});
