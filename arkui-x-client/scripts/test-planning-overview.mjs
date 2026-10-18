import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';

const read = name => readFileSync(new URL(`../entry/src/main/ets/utils/${name}.ets`, import.meta.url), 'utf8')
  .replace(/^import [^\n]+;\r?\n/gm, '');
const url = source => `data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source)).toString('base64')}`;
const dailyUrl = url(read('DailyAgenda'));
const overviewUrl = url(`import {buildDailyAgenda,shanghaiDate,validDate,timestamp,courseTimestamp,allDayDate} from '${dailyUrl}';\n${read('PlanningOverview')}`);
const { filterPlanningTasks, buildPlanningWeek, resolvePlanningCourse, validPlanningTimetable,
  dailyPlannedLoad, projectPlanningCandidate } = await import(overviewUrl);
const revision = 'a'.repeat(64);
const date = '2026-10-19';
const course = (change = {}) => ({ date, title: '操作系统', start_time: '08:00', end_time: '09:40',
  location: '第7教学楼北406', teacher: '陈老师', ...change });
const task = (change = {}) => ({ task_id: 'task-a', plan_id: 'plan-a', milestone_id: 'milestone-a', title: '复习 Chapter [1]',
  start_at: `${date}T10:00:00+08:00`, end_at: `${date}T11:00:00+08:00`, reminder_minutes: 0,
  location: 'Library A', status: 'pending', source: 'agent', created_at: '2026-10-18T08:00:00+08:00', completed_at: null, ...change });
const query = (change = {}) => ({ text: '', status: 'all', dateMode: 'all', fromDate: '', toDate: '', sort: 'schedule', ...change });
const ids = values => values.map(item => item.task_id);
const stamp = (time, day = date) => `${day}T${time}:00+08:00`;
const draft = (change = {}) => ({ title: '新增', start_at: stamp('11:00'), end_at: stamp('12:00'),
  reminder_minutes: null, location: null, ...change });

// These are production pure functions under Node, not ArkUI layout or native-device tests.
test('100 tasks remain individually searchable, case-insensitive and literal; text/status/date combine with AND', () => {
  const tasks = Array.from({ length: 100 }, (_, i) => task({ task_id: `task-${String(i).padStart(3, '0')}`,
    title: '同名 Chapter [1]', location: i % 2 ? 'Lab' : 'LIBRARY', status: i % 3 ? 'pending' : 'completed',
    start_at: stamp('10:00', i < 50 ? date : '2026-10-20'), end_at: stamp('11:00', i < 50 ? date : '2026-10-20') }));
  const before = JSON.stringify(tasks);
  const all = filterPlanningTasks(tasks, query({ text: ' [1] ' }));
  assert.equal(all.total, 100); assert.equal(all.matched, 100); assert.equal(new Set(ids(all.tasks)).size, 100);
  const filtered = filterPlanningTasks(tasks, query({ text: 'library', status: 'pending', dateMode: 'day', fromDate: date }));
  const expected = Array.from({ length: 50 }, (_, i) => i).filter(i => i % 2 === 0 && i % 3 !== 0).map(i => `task-${String(i).padStart(3, '0')}`);
  assert.deepEqual(ids(filtered.tasks), expected); assert.equal(filtered.total, 100);
  assert.equal(JSON.stringify(tasks), before);
});

test('empty data differs from empty filter results, and clearing conditions restores every ID', () => {
  const tasks = [task(), task({ task_id: 'task-b', title: '不同' })];
  assert.equal(filterPlanningTasks([], query()).total, 0);
  const result = filterPlanningTasks(tasks, query({ text: 'none' }));
  assert.equal(result.total, 2); assert.equal(result.matched, 0); assert.equal(result.valid, true);
  assert.deepEqual(ids(filterPlanningTasks(tasks, query()).tasks), ['task-a', 'task-b']);
});

test('schedule and creation sorting are deterministic with equal titles/times and missing dates', () => {
  const tasks = [task({ task_id: 'z' }), task({ task_id: 'a' }), task({ task_id: 'new', created_at: '2026-10-18T09:00:00+08:00' }),
    task({ task_id: 'undated', start_at: null }), task({ task_id: 'all-day', start_at: date, end_at: null })];
  assert.deepEqual(ids(filterPlanningTasks(tasks, query()).tasks), ['all-day', 'a', 'z', 'new', 'undated']);
  assert.deepEqual(ids(filterPlanningTasks(tasks.slice().reverse(), query()).tasks), ['all-day', 'a', 'z', 'new', 'undated']);
  assert.deepEqual(ids(filterPlanningTasks(tasks, query({ sort: 'created' })).tasks), ['new', 'a', 'all-day', 'undated', 'z']);
});

test('date filters use Shanghai intersections, including offset/cross-midnight and half-open endpoints', () => {
  const tasks = [task({ task_id: 'overnight', start_at: '2026-10-18T23:30:00+08:00', end_at: stamp('00:30') }),
    task({ task_id: 'ends-at-midnight', start_at: '2026-10-18T23:00:00+08:00', end_at: stamp('00:00') }),
    task({ task_id: 'offset', start_at: '2026-10-18T15:00:00-07:00', end_at: '2026-10-18T16:00:00-07:00' }),
    task({ task_id: 'start-only', start_at: stamp('08:00'), end_at: null }),
    task({ task_id: 'outside', start_at: stamp('00:00', '2026-10-20'), end_at: null })];
  assert.deepEqual(ids(filterPlanningTasks(tasks, query({ dateMode: 'day', fromDate: date })).tasks), ['overnight', 'offset', 'start-only']);
  assert.equal(filterPlanningTasks(tasks, query({ dateMode: 'range', fromDate: '2026-10-18', toDate: date })).matched, 4);
});

test('all-day legacy sentinel is separated from real 23:59 timed work and invalid dates stay recoverable', () => {
  const tasks = [task({ task_id: 'sentinel', source: 'manual', start_at: stamp('23:59'), end_at: null }),
    task({ task_id: 'timed', source: 'manual', start_at: stamp('23:59'), end_at: stamp('00:10', '2026-10-20') }),
    task({ task_id: 'bad', start_at: '2026-02-30T10:00:00+08:00' }),
    task({ task_id: 'blank', start_at: null, status: 'completed' })];
  const undated = filterPlanningTasks(tasks, query({ dateMode: 'undated' }));
  assert.deepEqual(ids(undated.tasks), ['bad', 'blank']); assert.equal(undated.invalidDateCount, 1);
  const week = buildPlanningWeek([], revision, tasks, date);
  assert.deepEqual(ids(week.days[0].allDay), ['sentinel']);
  assert.equal(week.days[0].rows[0].taskId, 'timed'); assert.equal(week.days[1].rows[0].taskId, 'timed');
  assert.deepEqual(ids(week.undated), ['bad', 'blank']);
});

test('invalid dates or reversed ranges fail explicitly instead of silently broadening filters or rolling calendar dates', () => {
  for (const q of [query({ dateMode: 'day', fromDate: '2026-02-30' }), query({ dateMode: 'range', fromDate: date, toDate: '2026-10-18' }),
    query({ dateMode: 'day', fromDate: ` ${date}` }), query({ status: 'arbitrary' })]) {
    const result = filterPlanningTasks([task()], q); assert.equal(result.valid, false); assert.equal(result.tasks.length, 0); assert.ok(result.message);
  }
  assert.equal(buildPlanningWeek([], revision, [], '2026-02-30').valid, false);
  assert.equal(dailyPlannedLoad([], [], '2026-02-30').valid, false);
});

test('week is actual Monday-Sunday data with seven days, including empty days and month/year crossings', () => {
  const week = buildPlanningWeek([course({ date: '2026-10-25' })], revision, [task()], '2026-10-25');
  assert.equal(week.startDate, date); assert.equal(week.endDate, '2026-10-25'); assert.equal(week.days.length, 7);
  assert.deepEqual(week.days.map(d => d.rows.length), [1, 0, 0, 0, 0, 0, 1]);
  const crossing = buildPlanningWeek([], revision, [], '2027-01-01');
  assert.equal(crossing.startDate, '2026-12-28'); assert.equal(crossing.endDate, '2027-01-03');
  assert.equal(buildPlanningWeek([], revision, [], '2027-01-04').startDate, '2027-01-04');
});

test('parallel courses and tasks all remain visible; cross-day segments clip without changing full timestamps', () => {
  const courses = [course(), course({ title: '另一门课' })];
  const tasks = [task({ task_id: 'cross', start_at: '2026-10-18T23:00:00+08:00', end_at: stamp('09:00') }),
    task({ task_id: 'same-time', start_at: stamp('08:00'), end_at: stamp('10:00') }),
    task({ task_id: 'no-end', start_at: stamp('09:00'), end_at: null })];
  const week = buildPlanningWeek(courses, revision, tasks, date); const rows = week.days[0].rows;
  assert.equal(rows.length, 5); assert.equal(new Set(rows.map(r => r.id)).size, 5);
  const cross = rows.find(r => r.taskId === 'cross');
  assert.equal(cross.date, '2026-10-18'); assert.equal(cross.startTime, '23:00');
  assert.equal(cross.segmentStartMs, Date.parse(stamp('00:00'))); assert.equal(cross.segmentEndMs, Date.parse(stamp('09:00')));
  assert.equal(rows.find(r => r.taskId === 'no-end').segmentEndMs, null);
});

test('course reference includes all six fields, revision and duplicate occurrence, never an array-index identity', () => {
  const courses = [course(), course(), course({ teacher: '另一个老师' }), course({ location: '另一个教室' })];
  const before = JSON.stringify(courses); const refs = buildPlanningWeek(courses, revision, [], date).days[0].rows.map(r => r.courseRef);
  assert.equal(new Set(refs.map(r => r.key)).size, 4);
  assert.deepEqual(refs.filter(r => r.course.teacher === '陈老师' && r.course.location === '第7教学楼北406').map(r => r.occurrence), [1, 2]);
  refs.forEach(ref => assert.deepEqual(resolvePlanningCourse(ref, courses.slice().reverse(), revision), ref.course));
  assert.equal(resolvePlanningCourse(refs[0], courses, 'b'.repeat(64)), null);
  assert.equal(resolvePlanningCourse({ ...refs[0], course: { ...refs[0].course, teacher: '篡改' } }, courses, revision), null);
  assert.equal(resolvePlanningCourse({ ...refs[0], occurrence: 99 }, courses, revision), null);
  assert.equal(resolvePlanningCourse(refs[0], [], revision), null);
  refs[0].course.title = 'local mutation'; assert.equal(JSON.stringify(courses), before);
});

test('snapshot validation preserves canonical raw facts and unplaced courses remain explicit', () => {
  assert.equal(validPlanningTimetable({ entries: [], revision }), true);
  for (const c of [course({ date: ` ${date}` }), course({ start_time: '8:00' }), course({ end_time: '07:00' }),
    course({ date: '2026-02-30' }), course({ teacher: null }), course({ title: ' ' })]) {
    assert.equal(validPlanningTimetable({ entries: [c], revision }), false);
  }
  assert.equal(validPlanningTimetable({ entries: Array.from({ length: 501 }, () => course()), revision }), false);
  assert.equal(validPlanningTimetable({ entries: [course()], revision: 'old' }), false);
  const week = buildPlanningWeek([course({ end_time: '07:00' }), course()], revision, [], date);
  assert.equal(week.unplacedCourses.length, 1); assert.equal(week.days[0].rows.length, 1);
});

test('course and task minutes are separate unions; accepted in-class work does not inflate combined occupancy', () => {
  const courses = [course({ start_time: '08:00', end_time: '10:00' }), course({ start_time: '09:00', end_time: '11:00' })];
  const tasks = [task({ task_id: 'in-class', start_at: stamp('09:00'), end_at: stamp('10:30'), allow_during_course: true,
    course_overlap: { state: 'accepted' } }), task({ task_id: 'outside', start_at: stamp('10:00'), end_at: stamp('12:00') })];
  const load = dailyPlannedLoad(courses, tasks, date);
  assert.equal(load.courseMinutes, 180); assert.equal(load.taskMinutes, 180); assert.equal(load.totalMinutes, 240);
  assert.equal(load.timedCourseCount, 2); assert.equal(load.timedTaskCount, 2);
  assert.equal(dailyPlannedLoad(courses, [{ ...tasks[0], course_overlap: { state: 'needs_review' } }, tasks[1]], date).totalMinutes, 240);
});

test('occupancy clips midnight, unions adjacent/nested intervals and retains subminute precision', () => {
  const tasks = [task({ task_id: 'cross', start_at: '2026-10-18T23:00:00+08:00', end_at: stamp('01:00') }),
    task({ task_id: 'nested', start_at: stamp('00:15'), end_at: stamp('00:45') }),
    task({ task_id: 'adjacent', start_at: stamp('01:00'), end_at: `${date}T01:00:30+08:00` }),
    task({ task_id: 'next', start_at: stamp('23:30'), end_at: stamp('00:30', '2026-10-20') })];
  assert.equal(dailyPlannedLoad([], tasks, date).taskMinutes, 90.5);
  assert.equal(dailyPlannedLoad([], tasks, '2026-10-20').taskMinutes, 30);
});

test('all-day, undated, missing end and invalid time counts never invent duration', () => {
  const tasks = [task({ task_id: 'all-day', start_at: date, end_at: null }),
    task({ task_id: 'manual-all', source: 'manual', start_at: stamp('23:59'), end_at: null }),
    task({ task_id: 'none', start_at: null, end_at: null }), task({ task_id: 'no-end', end_at: null }),
    task({ task_id: 'backwards', end_at: stamp('09:00') }), task({ task_id: 'bad-start', start_at: '2026-02-30T10:00+08:00' })];
  const load = dailyPlannedLoad([course({ end_time: '25:00' })], tasks, date);
  assert.equal(load.courseMinutes, 0); assert.equal(load.taskMinutes, 0); assert.equal(load.totalMinutes, 0);
  assert.equal(load.allDayCount, 2); assert.equal(load.undatedCount, 1); assert.equal(load.incompleteTaskCount, 1);
  assert.equal(load.invalidTaskCount, 2); assert.equal(load.invalidCourseCount, 1); assert.match(load.message, /未计入/);
});

test('completed scheduled work remains expected occupancy, cancelled work is excluded, and inputs are untouched', () => {
  const tasks = [task({ status: 'completed' }), task({ task_id: 'cancel', status: 'cancelled', end_at: stamp('13:00') })];
  const before = JSON.stringify(tasks); const load = dailyPlannedLoad([], tasks, date);
  assert.equal(load.taskMinutes, 60); assert.equal(load.timedTaskCount, 1); assert.equal(JSON.stringify(tasks), before);
});

test('new candidate and exact-ID edit calculate separate before/after occupancy without mutating plans or equal titles', () => {
  const tasks = [task({ task_id: 'one', title: '同名' }), task({ task_id: 'two', title: '同名', start_at: stamp('12:00'), end_at: stamp('13:00') })];
  const before = JSON.stringify(tasks);
  const added = projectPlanningCandidate(tasks, { task: draft(), replaceTaskId: null, source: 'manual' });
  assert.equal(added.tasks.length, 3); assert.equal(dailyPlannedLoad([], added.tasks, date).taskMinutes, 180);
  const edit = projectPlanningCandidate(tasks, { task: draft({ start_at: stamp('12:00'), end_at: stamp('13:00') }), replaceTaskId: 'one', source: 'manual' });
  assert.equal(edit.tasks.length, 2); assert.deepEqual(ids(edit.tasks), ['one', 'two']);
  assert.equal(edit.tasks[0].plan_id, 'plan-a'); assert.equal(edit.tasks[0].milestone_id, 'milestone-a'); assert.equal(edit.tasks[0].source, 'agent');
  assert.equal(dailyPlannedLoad([], tasks, date).taskMinutes, 120); assert.equal(dailyPlannedLoad([], edit.tasks, date).taskMinutes, 60);
  assert.equal(JSON.stringify(tasks), before);
});

test('unknown/duplicate edit IDs reject projection instead of adding or replacing a same-title task', () => {
  const tasks = [task()];
  for (const [data, id] of [[tasks, 'missing'], [tasks, ''], [[task(), task()], 'task-a']]) {
    const result = projectPlanningCandidate(data, { task: draft(), replaceTaskId: id, source: 'manual' });
    assert.equal(result.valid, false); assert.deepEqual(result.tasks, data); assert.ok(result.message);
  }
});

test('candidate source preserves manual all-day semantics and synthetic IDs never collide with real tasks', () => {
  const tasks = [task({ task_id: 'planning-preview' }), task({ task_id: 'planning-preview-new' })];
  const result = projectPlanningCandidate(tasks, { task: draft({ start_at: stamp('23:59'), end_at: null }), replaceTaskId: null, source: 'manual' });
  assert.equal(new Set(ids(result.tasks)).size, 3); assert.equal(dailyPlannedLoad([], result.tasks, date).allDayCount, 1);
  assert.equal(dailyPlannedLoad([], result.tasks, date).taskMinutes, 60);
});

test('all query/week/load results are identical across device timezones for offset and naive legacy times', () => {
  const tasks = [task({ start_at: '2026-10-19T10:00', end_at: '2026-10-19 11:00:00.123456' }),
    task({ task_id: 'offset', start_at: '2026-10-18T17:00:00Z', end_at: '2026-10-18T18:00:00Z' })];
  const script = `import {filterPlanningTasks,buildPlanningWeek,dailyPlannedLoad} from ${JSON.stringify(overviewUrl)};
    const tasks=${JSON.stringify(tasks)},courses=${JSON.stringify([course()])};console.log(JSON.stringify([
      filterPlanningTasks(tasks,${JSON.stringify(query({ dateMode: 'day', fromDate: date }))}),
      buildPlanningWeek(courses,${JSON.stringify(revision)},tasks,${JSON.stringify(date)}),
      dailyPlannedLoad(courses,tasks,${JSON.stringify(date)})]));`;
  const results = ['UTC', 'America/Los_Angeles', 'Asia/Tokyo'].map(TZ => execFileSync(process.execPath,
    ['--input-type=module', '-e', script], { encoding: 'utf8', env: { ...process.env, TZ } }).trim());
  assert.equal(new Set(results).size, 1);
  const [filtered, week, load] = JSON.parse(results[0]);
  assert.equal(filtered.matched, 2); assert.equal(week.startDate, date); assert.equal(load.taskMinutes, 120 + 0.123 / 60);
});
