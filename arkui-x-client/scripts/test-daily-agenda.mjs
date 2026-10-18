import assert from 'node:assert/strict';
import { runModuleSource } from './helpers/run-module.mjs';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';

// Run the actual ArkTS pure helper, without simulating native layout or invoking an API.
const source = readFileSync(new URL('../entry/src/main/ets/utils/DailyAgenda.ets', import.meta.url), 'utf8')
  .replace(/^import [^\n]+;\r?\n/gm, '');
const moduleUrl = `data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source)).toString('base64')}`;
const { buildDailyAgenda, labelNext, shanghaiDate, shanghaiTime } = await import(moduleUrl);
const now = Date.parse('2026-10-19T09:00:00+08:00');

function course(overrides = {}) {
  return { date: '2026-10-19', title: '操作系统', start_time: '08:05', end_time: '09:40',
    location: '第7教研楼北406', teacher: '叶老师', ...overrides };
}

function task(overrides = {}) {
  return { task_id: 'task-a', plan_id: 'plan-a', milestone_id: 'milestone-a', title: '完成实验',
    start_at: '2026-10-19T10:00:00+08:00', end_at: '2026-10-19T11:00:00+08:00',
    reminder_minutes: 10, location: '实验室', status: 'pending', source: 'agent',
    created_at: '2026-10-18T10:00:00+08:00', completed_at: null, ...overrides };
}

test('Shanghai clock changes date at UTC 16:00 and keeps year/month boundaries', () => {
  assert.equal(shanghaiDate(Date.parse('2026-10-18T15:59:59Z')), '2026-10-18');
  assert.equal(shanghaiDate(Date.parse('2026-10-18T16:00:00Z')), '2026-10-19');
  assert.equal(shanghaiTime(Date.parse('2026-10-18T16:00:00Z')), '00:00');
  assert.equal(shanghaiDate(Date.parse('2026-12-31T16:01:00Z')), '2027-01-01');
});

test('clock and offset-free legacy timestamps do not depend on device timezone', () => {
  const script = `import {buildDailyAgenda,shanghaiDate,shanghaiTime} from ${JSON.stringify(moduleUrl)};
    const now=${now}; const task=${JSON.stringify(task({ start_at: '2026-10-19T10:00', end_at: '2026-10-19 11:00:00.123456' }))};
    console.log(JSON.stringify([shanghaiDate(now),shanghaiTime(now),buildDailyAgenda([], [task], now)]));`;
  const results = ['UTC', 'America/Los_Angeles', 'Asia/Tokyo'].map((timezone) =>
    runModuleSource(script, { env: { ...process.env, TZ: timezone } }).trim());
  assert.equal(new Set(results).size, 1);
  const [, , agenda] = JSON.parse(results[0]);
  assert.equal(agenda.rows[0].startTime, '10:00');
  assert.equal(agenda.rows[0].endMs, Date.parse('2026-10-19T11:00:00.123+08:00'));
});

test('courses and all timed tasks form one sorted list with original identity/location and completed state', () => {
  const tasks = Array.from({ length: 7 }, (_, index) => task({ task_id: `task-${index}`,
    start_at: `2026-10-19T${String(10 + index).padStart(2, '0')}:00:00+08:00`, end_at: null }));
  tasks.push(task({ task_id: 'done', status: 'completed', start_at: '2026-10-19T07:00:00+08:00' }));
  const input = JSON.stringify({ tasks, courses: [course()] });
  const agenda = buildDailyAgenda([course()], tasks, now);
  assert.equal(agenda.rows.length, 9, 'timeline is not truncated to the previous five-task limit');
  assert.deepEqual(agenda.rows.map((row) => row.startTime), ['07:00', '08:05', '10:00', '11:00', '12:00', '13:00', '14:00', '15:00', '16:00']);
  assert.equal(agenda.rows[0].done, true);
  assert.equal(agenda.rows[2].taskId, 'task-0');
  assert.equal(agenda.rows[2].planId, 'plan-a');
  assert.equal(agenda.rows[2].location, '实验室');
  assert.equal(agenda.rows[1].taskId, null);
  assert.equal(agenda.rows[1].location, '第7教研楼北406');
  assert.equal(JSON.stringify({ tasks, courses: [course()] }), input, 'aggregation must not mutate API objects');
});

test('all-day manual sentinel and date-only tasks stay separate from undated and timed tasks', () => {
  const tasks = [
    task({ task_id: 'all-day', source: 'manual', start_at: '2026-10-19T23:59:00+08:00', end_at: null }),
    task({ task_id: 'date-only', start_at: '2026-10-19', end_at: null }),
    task({ task_id: 'undated', start_at: null, end_at: null }),
    task({ task_id: 'done-undated', status: 'completed', start_at: null, end_at: null }),
    task({ task_id: 'tomorrow', source: 'manual', start_at: '2026-10-20T23:59:00+08:00', end_at: null }),
    task({ task_id: 'real-2359', start_at: '2026-10-19T23:59:00+08:00', end_at: null }),
    task({ task_id: 'manual-timed', source: 'manual', start_at: '2026-10-19T23:59:00+08:00', end_at: '2026-10-20T00:20:00+08:00' })
  ];
  const agenda = buildDailyAgenda([], tasks, now);
  assert.deepEqual(agenda.allDay.map((item) => item.task_id), ['all-day', 'date-only']);
  assert.deepEqual(agenda.unscheduled.map((item) => item.task_id), ['undated']);
  assert.deepEqual(agenda.rows.map((item) => item.taskId), ['manual-timed', 'real-2359']);
  assert.equal(agenda.rows.some((item) => item.taskId === 'undated'), false);
});

test('UTC and negative offsets use the Shanghai date and clock, not timestamp prefixes', () => {
  const agenda = buildDailyAgenda([], [
    task({ task_id: 'z', start_at: '2026-10-18T17:00:00Z', end_at: '2026-10-18T18:00:00Z' }),
    task({ task_id: 'negative', start_at: '2026-10-18T15:00:00-07:00', end_at: '2026-10-18T16:00:00-07:00' }),
    task({ task_id: 'offset-all-day', source: 'manual', start_at: '2026-10-19T15:59:00Z', end_at: null }),
    task({ task_id: 'next-date', start_at: '2026-10-19T17:00:00Z', end_at: null })
  ], now);
  assert.deepEqual(agenda.rows.map((row) => [row.taskId, row.date, row.startTime]),
    [['z', '2026-10-19', '01:00'], ['negative', '2026-10-19', '06:00']]);
  assert.deepEqual(agenda.allDay.map((item) => item.task_id), ['offset-all-day']);
});

test('cross-midnight intervals appear on the overlap day and preserve both actual dates', () => {
  const overnight = task({ start_at: '2026-10-18T23:30:00+08:00', end_at: '2026-10-19T09:30:00+08:00' });
  const agenda = buildDailyAgenda([], [overnight], now);
  assert.equal(agenda.rows.length, 1);
  assert.equal(agenda.rows[0].date, '2026-10-18');
  assert.equal(agenda.rows[0].endDate, '2026-10-19');
  assert.equal(agenda.next.taskId, 'task-a');
  assert.equal(labelNext(agenda.next, now), '正在进行');
  assert.equal(buildDailyAgenda([], [task({ start_at: '2026-10-18T23:00:00+08:00', end_at: '2026-10-19T00:00:00+08:00' })], now).rows.length, 0,
    'half-open intervals ending exactly at midnight do not occupy the next day');
});

test('next prefers ongoing entries then future entries, excluding completed/cancelled/ended tasks', () => {
  const items = [
    task({ task_id: 'ended', start_at: '2026-10-19T07:00:00+08:00', end_at: '2026-10-19T09:00:00+08:00' }),
    task({ task_id: 'done', status: 'completed', start_at: '2026-10-19T08:00:00+08:00' }),
    task({ task_id: 'cancelled', status: 'cancelled', start_at: '2026-10-19T08:00:00+08:00' }),
    task({ task_id: 'ongoing', start_at: '2026-10-19T08:30:00+08:00', end_at: '2026-10-19T09:30:00+08:00' }), task()
  ];
  assert.equal(buildDailyAgenda([], items, now).next.taskId, 'ongoing');
  assert.equal(buildDailyAgenda([], items, Date.parse('2026-10-19T09:30:00+08:00')).next.taskId, 'task-a');
  assert.equal(buildDailyAgenda([], items, Date.parse('2026-10-19T11:00:00+08:00')).next, null);
  assert.equal(buildDailyAgenda([course()], [], now).next.kind, 'course');
});

test('a start-only task does not get an invented duration or ongoing state', () => {
  const startOnly = task({ start_at: '2026-10-19T08:00:00+08:00', end_at: null });
  const agenda = buildDailyAgenda([], [startOnly], now);
  assert.equal(agenda.rows.length, 1);
  assert.equal(agenda.rows[0].endMs, null);
  assert.equal(agenda.rows[0].endTime, '');
  assert.equal(agenda.next, null);
  assert.equal(labelNext(agenda.rows[0], now), '已到开始时间');
  const exact = buildDailyAgenda([], [task({ start_at: '2026-10-19T09:00:00+08:00', end_at: null })], now);
  assert.equal(labelNext(exact.next, now), '现在开始');
});

test('same-time rows retain parallel entries and have deterministic course-first ordering', () => {
  const one = task({ task_id: 'b', start_at: '2026-10-19T08:05:00+08:00' });
  const two = task({ task_id: 'a', start_at: one.start_at, title: one.title });
  const first = buildDailyAgenda([course(), course({ title: '平行课程' })], [one, two], now);
  const second = buildDailyAgenda([course(), course({ title: '平行课程' })], [two, one], now);
  assert.equal(new Set(first.rows.map((row) => row.id)).size, 4);
  assert.deepEqual(first.rows.map((row) => row.id), second.rows.map((row) => row.id));
  assert.deepEqual(first.rows.map((row) => row.kind), ['course', 'course', 'task', 'task']);
});

test('other dates and malformed dates never roll into a false upcoming appointment', () => {
  const agenda = buildDailyAgenda([
    course({ date: '2026-10-20' }), course({ date: '2026-02-30' }),
    course({ start_time: '09:40', end_time: '08:05' }), course({ start_time: '25:00' })
  ], [
    task({ task_id: 'tomorrow', start_at: '2026-10-20T08:00:00+08:00', end_at: null }),
    task({ task_id: 'bad', start_at: '2026-02-30T08:00:00+08:00' }),
    task({ task_id: 'bad-time', start_at: '2026-10-19T24:00:00+08:00' })
  ], now);
  assert.equal(agenda.rows.length, 0);
  assert.equal(agenda.next, null);
  assert.deepEqual(agenda.unscheduled.map((item) => item.task_id), ['bad', 'bad-time'],
    'pending invalid dates remain visible for explicit time review, with the original timestamp intact');
  assert.equal(agenda.unscheduled[0].start_at, '2026-02-30T08:00:00+08:00');
  const invalidCompleted = task({ task_id: 'done-bad', status: 'completed', start_at: 'broken' });
  assert.equal(buildDailyAgenda([], [invalidCompleted], now).unscheduled.length, 0);
});

test('next labels derive from exact time instead of guessed progress', () => {
  const row = buildDailyAgenda([], [task()], now).next;
  assert.equal(labelNext(row, now), '1 小时后开始');
  assert.equal(labelNext(row, now - 61_000), '1 小时 2 分钟后开始');
  assert.equal(labelNext(row, row.startMs - 1000), '1 分钟后开始');
  assert.equal(labelNext(row, row.startMs), '正在进行');
  assert.equal(labelNext(row, row.endMs), '已结束');
  assert.equal(labelNext({ ...row, done: true }, now), '已完成');
});

test('missing or non-string start values stay visible for review without crashing the daily list', () => {
  const values = [undefined, 123, {}, ['2026-10-19'], false];
  const tasks = values.map((value, index) => task({ task_id: `bad-${index}`, start_at: value }));
  tasks.push(task({ task_id: 'done-bad', status: 'completed', start_at: undefined }));
  const agenda = buildDailyAgenda([], tasks, now);
  assert.deepEqual(agenda.unscheduled.map((item) => item.task_id), ['bad-0', 'bad-1', 'bad-2', 'bad-3', 'bad-4']);
  assert.equal(agenda.rows.length, 0); assert.equal(agenda.next, null);
  values.forEach((value, index) => assert.equal(agenda.unscheduled[index].start_at, value));
});
