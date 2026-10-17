import { draftFixture } from './helpers/local-draft-fixture.mjs';
import { PlanningActionController, candidate, applied, validPlanningDate, quickCapture, courseReview } from './helpers/planning-action-fixture.mjs';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';

const agendaSource = readFileSync(new URL('../entry/src/main/ets/utils/DailyAgenda.ets', import.meta.url), 'utf8').replace(/^import [^\n]+;\r?\n/gm, '');
const agenda = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(agendaSource)).toString('base64')}`);

const source = readFileSync(new URL('../entry/src/main/ets/pages/PlanCenterPage.ets', import.meta.url), 'utf8');
const firstBuilder = source.indexOf('\n  @Builder');
assert.ok(firstBuilder > 0, 'the non-UI method boundary must exist');
// Run the actual page methods. This does not compile ArkUI builders or validate native layout.
const controllerSource = source.slice(0, firstBuilder)
  .replace(/^import \{[\s\S]*?\} from '[^']+';\r?\n/gm, '')
  .replace(/^import [^\n]+;\r?\n/gm, '')
  .replace(/^@Component\r?\n/m, '')
  .replace(/@(Prop|State)\s+|@Watch\('[^']+'\)\s*/g, '')
  .replace('export struct PlanCenterPage', 'class PlanCenterPage') + '\n}\n';
const createController = new Function('TextInputController', 'AppTheme', 'Curve', 'CampusFlowApi', 'Scroller', 'shanghaiDate', 'buildDailyAgenda', 'PlanningActionController', 'localDrafts', 'validPlanningDate', 'parseQuickCapture', 'captureEndAt', 'validCourseAcknowledgements',
  stripTypeScriptTypes(controllerSource) + '\nreturn PlanCenterPage;');

async function page({ createError = null } = {}) {
  const drafts = await draftFixture();
  const calls = [];
  const overview = {
    plans: [], tasks: [], total_tasks: 0, completed_tasks: 0, due_today: 0, overdue_tasks: 0, progress: 0
  };
  class InputController {
    stopCount = 0;
    stopEditing() { this.stopCount++; }
  }
  let pending;
  class Api {
    async previewPlanningAction(request) {
      calls.push(['preview', request]);
      if (createError) throw createError;
      pending = candidate(request); return pending;
    }
    async confirmAction(id) {
      calls.push(['confirm', id]); const result = applied(pending);
      return { applied: true, action: result, receipt: result.receipt, message: '' };
    }
    async planning() {
      calls.push(['planning']);
      return overview;
    }
    async updateTask(id, completed) { calls.push(['updateTask', id, completed]); }
    async deleteTask(id) { calls.push(['deleteTask', id]); }
  }
  const Controller = createController(InputController, { motion: () => 0 }, { EaseOut: 'ease-out' }, Api, class {}, agenda.shanghaiDate, agenda.buildDailyAgenda, PlanningActionController, drafts.store, validPlanningDate, quickCapture.parseQuickCapture, quickCapture.captureEndAt, courseReview.validCourseAcknowledgements);
  const instance = new Controller();
  instance.draftLease = drafts.lease; instance.draftScopeChanged();
  instance.getUIContext = () => ({ animateTo: (_options, update) => update() });
  return { instance, calls, overview };
}

function draftSnapshot(instance) {
  return {
    title: instance.title,
    date: instance.draftTaskDate,
    choice: instance.draftDateChoice,
    time: instance.draftTaskTime,
    selectedDate: instance.selectedDate,
    calendarMonth: instance.calendarMonth
  };
}

test('calendar and task form start collapsed and opening them performs no API work', async () => {
  const { instance, calls } = await page();
  assert.equal(instance.calendarExpanded, false);
  assert.equal(instance.taskFormExpanded, false);
  instance.toggleCalendar();
  instance.toggleTaskForm();
  assert.equal(instance.calendarExpanded, true);
  assert.equal(instance.taskFormExpanded, true);
  assert.equal(instance.taskInputController.stopCount, 0);
  assert.deepEqual(calls, []);
});

test('repeated disclosure toggles preserve long draft, date choice, custom time and agenda selection', async () => {
  const { instance, calls } = await page();
  instance.title = '复习离散数学，并完成较长的课程总结草稿。'.repeat(20);
  instance.selectedDate = '2026-10-22';
  instance.calendarMonth = new Date(2026, 9, 1).getTime();
  instance.selectDraftDate('2026-10-21', 'calendar');
  instance.selectDraftTime('18:45');
  const before = draftSnapshot(instance);
  for (let i = 0; i < 3; i++) {
    instance.toggleCalendar();
    instance.toggleTaskForm();
    instance.toggleCalendar();
    instance.toggleTaskForm();
  }
  assert.deepEqual(draftSnapshot(instance), before);
  assert.equal(instance.calendarExpanded, false);
  assert.equal(instance.taskFormExpanded, false);
  assert.equal(instance.taskInputController.stopCount, 3, 'only collapsing the form dismisses its keyboard');
  assert.deepEqual(calls, []);
});

test('calendar browsing remains independent of a collapsed draft date', async () => {
  const { instance } = await page();
  instance.calendarMonth = new Date(2026, 9, 1).getTime();
  instance.selectedDate = '2026-10-21';
  instance.selectDraftDate(instance.selectedDate, 'calendar');
  instance.selectDraftTime('14:00');
  instance.toggleCalendar();
  instance.moveMonth(1);
  instance.toggleCalendar();
  assert.equal(instance.selectedDate, '2026-11-01');
  assert.equal(instance.draftTaskDate, '2026-10-21');
  assert.equal(instance.draftTaskTime, '14:00');
  assert.equal(instance.dateChoiceSelected('calendar', instance.selectedDate), false);
  assert.equal(instance.taskFormExpanded, false);
});

test('collapsed draft summary distinguishes no date, all day and custom time', async () => {
  const { instance } = await page();
  instance.selectDraftDate('', 'none');
  assert.equal(instance.draftScheduleSummary(), '未设日期 · 待安排时间');
  instance.selectDraftDate('2026-10-22', 'calendar');
  assert.equal(instance.draftScheduleSummary(), '2026-10-22 · 全天');
  instance.selectDraftTime('18:45');
  assert.equal(instance.draftScheduleSummary(), '2026-10-22 · 18:45');
});

test('reopened draft creates the original title and schedule, then retains disclosure state after reload', async () => {
  const { instance, calls } = await page();
  instance.title = '  完成课程总结  ';
  instance.selectedDate = '2026-11-01';
  instance.selectDraftDate('2026-10-22', 'calendar');
  instance.selectDraftTime('18:45');
  instance.toggleTaskForm();
  instance.toggleTaskForm();
  instance.toggleTaskForm();
  await instance.addTask();
  assert.deepEqual(calls, [
    ['preview', { operation: 'create_task', task: { title: '完成课程总结', start_at: '2026-10-22T18:45:00+08:00', end_at: null, reminder_minutes: null, location: null, allow_during_course: false } }]
  ]);
  assert.equal(instance.title, '  完成课程总结  ', 'preview preserves draft');
  await instance.confirmPlanningAction();
  assert.equal(instance.title, '');
  assert.deepEqual(calls.slice(1), [['confirm', 'proposal-a'], ['planning']]);
  assert.equal(instance.draftTaskDate, '2026-10-22');
  assert.equal(instance.draftTaskTime, '18:45');
  assert.equal(instance.selectedDate, '2026-11-01');
  assert.equal(instance.taskFormExpanded, true);
  assert.equal(instance.calendarExpanded, false);
});

test('no-date and all-day API parameters remain intact after form collapse', async () => {
  for (const [date, choice, expected] of [
    ['', 'none', null], ['2026-10-22', 'calendar', '2026-10-22T23:59:00+08:00']
  ]) {
    const { instance, calls } = await page();
    instance.title = '整理笔记';
    instance.selectDraftDate(date, choice);
    instance.toggleTaskForm();
    instance.toggleTaskForm();
    instance.toggleTaskForm();
    await instance.addTask();
    assert.deepEqual(calls[0], ['preview', { operation: 'create_task', task: { title: '整理笔记', start_at: expected, end_at: null, reminder_minutes: null, location: null, allow_during_course: false } }]);
  }
});

test('failed create retains the draft through collapse and reopening for correction or retry', async () => {
  const { instance, calls } = await page({ createError: new Error('offline') });
  instance.title = '失败后保留的草稿';
  instance.selectDraftDate('2026-10-22', 'calendar');
  instance.selectDraftTime('18:45');
  const before = draftSnapshot(instance);
  instance.toggleTaskForm();
  await instance.addTask();
  instance.toggleTaskForm();
  instance.toggleTaskForm();
  assert.deepEqual(draftSnapshot(instance), before);
  assert.equal(instance.actionState.phase, 'error');
  assert.match(instance.actionState.message, /草稿已保留/);
  assert.deepEqual(calls.map(item => item[0]), ['preview']);
  assert.equal(calls[0][1].task.title, '失败后保留的草稿');
  assert.equal(calls[0][1].task.start_at, '2026-10-22T18:45:00+08:00');
});

test('task completion stays idempotent and deletion requires preview then explicit confirmation', async () => {
  const { instance, calls } = await page();
  const task = { task_id: 'task-1', status: 'pending' };
  instance.toggleCalendar();
  instance.toggleTaskForm();
  await instance.toggle(task);
  assert.deepEqual(calls, [['updateTask', 'task-1', true], ['planning']]);
  calls.length = 0;
  await instance.requestDelete(task);
  assert.deepEqual(calls, [['preview', { operation: 'delete_task', task_id: 'task-1' }]], 'first click only builds a preview');
  await instance.requestDelete(task);
  assert.equal(calls.length, 1, 'pending preview prevents another delete request');
  await instance.confirmPlanningAction();
  assert.deepEqual(calls.slice(1), [['confirm', 'proposal-a'], ['planning']]);
  assert.equal(instance.deletePendingId, '');
  assert.equal(instance.calendarExpanded, true);
  assert.equal(instance.taskFormExpanded, true);
});
