import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';

const source = (name) => readFileSync(new URL(`../entry/src/main/ets/utils/${name}.ets`, import.meta.url), 'utf8')
  .replace(/^import [^\n]+;\r?\n/gm, '');
const load = async (name) => import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source(name))).toString('base64')}`);
const agenda = await load('DailyAgenda');
const timetable = await load('OnboardingTimetable');
const helper = new Function('buildDailyAgenda', 'shanghaiDate', 'shanghaiTime', 'validateTimetableEntry',
  stripTypeScriptTypes(source('FreeWindows').replace(/^export /gm, '')) + '\nreturn {partitionToday, findFreeWindow};')(
  agenda.buildDailyAgenda, agenda.shanghaiDate, agenda.shanghaiTime, timetable.validateTimetableEntry);
const ms = (time) => Date.parse(`2026-10-19T${time}:00+08:00`);
const task = (id, start, end, extra = {}) => ({ task_id: id, plan_id: null, milestone_id: null, title: '同名事项',
  start_at: start === null ? null : `2026-10-19T${start}:00+08:00`, end_at: end === null ? null : `2026-10-19T${end}:00+08:00`,
  status: 'pending', source: 'agent', location: null, reminder_minutes: null, ...extra });
const course = (start, end, extra = {}) => ({ date: '2026-10-19', title: '课程', start_time: start, end_time: end,
  location: '教研楼', teacher: '', ...extra });
const find = (courses = [], tasks = [], time = '14:10', buffer = 0, ready = true) => helper.findFreeWindow(courses, tasks, ms(time), buffer, ready);

test('the three timeline groups preserve all eight entries, including late unfinished and unknown-end tasks', () => {
  const rows = agenda.buildDailyAgenda([course('08:05','09:40'), course('14:30','16:05')], [
    task('done','10:00','11:00',{status:'completed'}), task('late','12:00','13:00'),
    task('no-end','13:00',null), task('future','17:00','18:00'), task('same-time','17:00','18:00'),
    task('done-no-end','07:00',null,{status:'completed'})], ms('14:10')).rows;
  const before = JSON.stringify(rows); const result = helper.partitionToday(rows, ms('14:10'));
  assert.equal(rows.length, 8); assert.equal(result.upcoming.length, 4); assert.equal(result.overdue.length, 1); assert.equal(result.earlier.length, 3);
  assert.equal(result.overdue[0].taskId, 'late'); assert.ok(result.upcoming.some(row => row.taskId === 'no-end'));
  assert.equal(new Set([...result.upcoming,...result.overdue,...result.earlier].map(row => row.id)).size, 8);
  assert.equal(JSON.stringify(rows), before);
});

test('ended courses move at the actual boundary and a never-completed timed task remains actionable', () => {
  const rows = agenda.buildDailyAgenda([course('08:00','09:00')], [task('late','08:00','09:00')], ms('08:59')).rows;
  assert.equal(helper.partitionToday(rows, ms('08:59')).upcoming.length, 2);
  const result = helper.partitionToday(rows, ms('09:00'));
  assert.equal(result.earlier[0].kind, 'course'); assert.equal(result.overdue[0].taskId, 'late');
});

test('partial or unverified sources never yield a free-window action even when lists are empty', () => {
  assert.equal(find([], [], '14:10', 0, false).window, null);
  assert.match(find([], [], '14:10', 0, false).reason, /完整核对/);
});

test('window uses complete half-open interval union and includes tasks beyond the first five', () => {
  const tasks = Array.from({length:6}, (_,index) => task(String(index),'14:00','14:30'));
  tasks.push(task('seventh','14:30','16:00'));
  const result = find([course('15:00','16:30')], tasks);
  assert.equal(result.window.startTime, '16:30'); assert.equal(result.window.endTime, '24:00');
  assert.equal(result.window.durationMinutes, 25);
});

test('user buffer is reserved on both sides of known intervals without invented travel time', () => {
  const courses = [course('13:00','14:00'),course('15:00','16:00')];
  const zero = find(courses, [], '14:00', 0).window;
  const ten = find(courses, [], '14:00', 10).window;
  assert.deepEqual([zero.startTime,zero.endTime], ['14:00','15:00']);
  assert.deepEqual([ten.startTime,ten.endTime], ['14:10','14:50']);
  assert.equal(ten.bufferMinutes,10);
  assert.equal(find(courses,[],'14:00',7).window,null);
});

test('fractional current minute rounds forward and an exact 25-minute gap fits', () => {
  const now = ms('14:10') + 1000;
  const result = helper.findFreeWindow([course('14:36','23:59')], [], now, 0, true);
  assert.equal(result.window.startTime,'14:11'); assert.equal(result.window.endTime,'14:36');
  assert.ok(result.window.startMs > now);
});

test('day end is an explicit boundary, not a fabricated evening activity or recurring workday', () => {
  assert.equal(find([], [], '23:35').window.startTime, '23:35');
  assert.equal(find([], [], '23:36').window,null);
  assert.equal(find([], [], '00:00').window.startTime,'00:00');
});

test('cross-midnight occupancy and midnight end use the same strict agenda parser', () => {
  const overnight = task('overnight',null,null,{start_at:'2026-10-18T23:00:00+08:00',end_at:'2026-10-19T10:00:00+08:00'});
  assert.equal(find([], [overnight], '09:00').window.startTime,'10:00');
  const ended = {...overnight,end_at:'2026-10-19T00:00:00+08:00'};
  assert.equal(find([], [ended], '09:00').window.startTime,'09:00');
});

test('missing, invalid or reversed end times suppress suggestions, including older start-only tasks', () => {
  const cases = [task('none','08:00',null),task('reverse','09:00','08:00'),task('invalid','09:00',null,{end_at:'bad'}),
    task('yesterday',null,null,{start_at:'2026-10-18T09:00:00+08:00'})];
  for(const item of cases) { const result=find([], [item]); assert.equal(result.window,null); assert.match(result.reason,/结束时间/); }
  const tomorrow=task('future',null,null,{start_at:'2026-10-20T09:00:00+08:00'});
  assert.equal(find([], [tomorrow]).window.startTime,'14:10','an unknown interval that cannot start today does not block today');
});

test('bad dates cannot silently roll into a different day and become free time', () => {
  for(const value of ['2026-02-30T09:00:00+08:00','2026-10-19T25:00:00+08:00',123,undefined,'bad']) {
    const result=find([], [task('bad',null,null,{start_at:value})]); assert.equal(result.window,null); assert.match(result.reason,/日期/);
  }
  assert.equal(find([course('08:00','09:00',{date:'2026-02-30'})]).window,null);
});

test('all-day and undated work is counted honestly and does not occupy an invented day-long interval', () => {
  const tasks=[task('undated',null,null),task('legacy','23:59',null,{source:'manual'}),
    task('date-only',null,null,{start_at:'2026-10-19'}),task('tomorrow-day',null,null,{start_at:'2026-10-20'})];
  const result=find([],tasks);
  assert.equal(result.untimedCount,3); assert.equal(result.window.startTime,'14:10');
  assert.equal(find([], [task('explicit-2359','23:59',null,{source:'agent'})]).window,null);
});

test('completed/cancelled items do not reserve time; malformed state blocks rather than disappears', () => {
  assert.equal(find([], [task('done','14:00','18:00',{status:'completed'}),task('cancel','14:00','18:00',{status:'cancelled'})]).window.startTime,'14:10');
  assert.equal(find([], [task('unknown','14:00','18:00',{status:'unexpected'})]).window,null);
});

test('offset timestamps refer to Shanghai occupancy and inputs remain unchanged', () => {
  const tasks=[task('utc',null,null,{start_at:'2026-10-19T06:00:00Z',end_at:'2026-10-19T08:00:00Z'})];
  const before=JSON.stringify(tasks); const result=find([],tasks);
  assert.equal(result.window.startTime,'16:00'); assert.equal(JSON.stringify(tasks),before);
});

test('trim-normalizable course times cannot validate and then disappear from strict occupancy parsing', () => {
  for(const extra of [{date:' 2026-10-19 '},{start_time:' 14:00 '},{end_time:'15:00 '}]) {
    const result=find([course('14:00','15:00',extra)]);
    assert.equal(result.window,null); assert.match(result.reason,/课程时间/);
  }
});
