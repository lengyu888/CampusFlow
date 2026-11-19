import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { JSDOM } from 'jsdom';

const source = readFileSync(new URL('../../src/campusflow_agent/web/desktop-workflow.js', import.meta.url), 'utf8');
const task = { task_id: 'pending-review', title: 'Test task title', status: 'pending' };
const clockDate = Date.UTC(2026, 10, 14, 8);
const settle = () => new Promise(resolve => setTimeout(resolve, 5));
const missing = () => Object.assign(Error('未找到操作'), { status: 404, code: 'FOCUS_OPERATION_NOT_FOUND' });

function environment({ owner = 'focus-owner', load, offline = false, submitError } = {}) {
  const dom = new JSDOM('<main id="windowsFocusRoot"></main><main id="windowsReviewRoot"></main>', {
    url: 'http://localhost:8000', runScripts: 'outside-only', pretendToBeVisual: true,
  });
  const { window } = dom;
  let wall = clockDate;
  let mono = 0;
  let interval;
  let record = null;
  const calls = [];
  const receipts = new Map();
  const history = [];
  window.confirm = () => true;
  window.Date.now = () => wall;
  window.performance.now = () => mono;
  window.setInterval = (callback) => { interval = callback; };
  for (const [key, value] of load ?? []) window.localStorage.setItem(key, value);
  const view = (tab = 'focus') => window.document.dispatchEvent(new window.CustomEvent('campusflow:desktop-view', { detail: { tab, userId: owner } }));
  window.CampusFlowWindows = {
    async api(path, options) {
      const payload = options?.body ? JSON.parse(options.body) : null;
      calls.push({ path, payload });
      if (offline) throw Error('Disconnected');
      if (path.endsWith('/planning')) return { tasks: [task] };
      if (path.endsWith('/active')) return { user_id: owner, record };
      if (path.includes('?limit=')) return { user_id: owner, records: history };
      if (path.includes('/focus-operations/')) {
        const match = receipts.get(path.split('/').at(-1));
        if (!match) throw missing();
        return match;
      }
      assert.match(path, /\/operations$/);
      if (submitError) throw submitError;
      const recordId = path.split('/').at(-2);
      const state = { start: 'running', resume: 'running', pause: 'paused', end: 'ended' }[payload.kind];
      const elapsed = (payload.intervals ?? []).reduce((sum, item) => sum + item.elapsed_ms, 0);
      const receipt = { user_id: owner, record_id: recordId, operation_id: payload.operation_id, kind: payload.kind,
        receipt: { before_revision: payload.expected_revision, after_revision: payload.expected_revision + 1,
          after_state: state, accepted_interval_ids: (payload.intervals ?? []).map(item => item.interval_id),
          accepted_gap_ids: (payload.unknown_gaps ?? []).map(item => item.gap_id), added_elapsed_ms: elapsed } };
      record = { ...record, record_id: recordId, state, revision: receipt.receipt.after_revision,
        current_device_id: payload.device_id, clock_session_id: state === 'running' ? payload.clock_session_id : null,
        segment_id: state === 'running' ? payload.operation_id : null, started_at: new Date(wall).toISOString(),
        confirmed_elapsed_ms: (record?.confirmed_elapsed_ms ?? 0) + elapsed, task_title: task.title };
      receipts.set(payload.operation_id, receipt);
      if (state === 'ended') { history.push(record); record = null; }
      return receipt;
    },
    toast() {}, open: view, user: () => owner ? { user_id: owner } : null, uuid: randomUUID, focusTasks: () => [task],
  };
  window.eval(source);
  view('today');
  const element = (name) => window.document.querySelector(`[data-focus-${name}]`);
  const button = (name) => [...window.document.querySelectorAll('#windowsFocusRoot button')].find(item => item.textContent === name);
  return {
    window, element, button, view, calls,
    close: () => window.close(),
    selectOffline: () => {
      window.CampusFlowWindows.focusTask(task.task_id, task.title);
      element('mode').value = 'offline';
      element('mode').dispatchEvent(new window.Event('change'));
    },
    setOffline: (value) => { offline = value; },
    setSubmitError: (value) => { submitError = value; },
    tick: (elapsed, wallElapsed = elapsed) => { wall += wallElapsed; mono += elapsed; interval(); },
    hide: () => {
      Object.defineProperty(window.document, 'hidden', { value: true });
      window.document.dispatchEvent(new window.Event('visibilitychange'));
    },
    local: () => JSON.parse(window.localStorage.getItem(`campusflow.windows.focus-local:${owner}`))?.records,
    storage: () => Object.entries(window.localStorage),
  };
}

test('offline focus uses selected task, measures two segments, and writes ordered receipts only after sync', async () => {
  const env = environment({ offline: true });
  env.selectOffline();
  await settle();
  assert.equal(env.element('task').value, task.task_id);
  env.button('开始专注').click();
  env.tick(2000);
  env.button('暂停').click();
  env.button('继续').click();
  env.tick(1000);
  env.button('结束').click();
  assert.equal(env.local()[0].confirmed_elapsed_ms, 3000);
  assert.equal(JSON.stringify(env.local()).includes(task.title), false);
  assert.equal(env.calls.filter(call => call.payload).length, 0);
  env.setOffline(false);
  env.button('同步本机记录').click();
  await settle();
  assert.deepEqual(env.calls.flatMap(call => call.payload ? [[call.payload.kind, call.payload.expected_revision]] : []),
    [['start', 0], ['pause', 1], ['resume', 2], ['end', 3]]);
  assert.equal(env.local().length, 0);
  assert.match(env.element('list').textContent, /0 分 3 秒/);
  env.close();
});

test('restart keeps the last saved checkpoint, pauses the local record and isolates logged-in accounts', async () => {
  const first = environment({ offline: true });
  first.selectOffline();
  first.button('开始专注').click();
  first.tick(5000);
  first.tick(2000);
  const stored = first.storage();
  first.close();
  const other = environment({ owner: 'second-owner', load: stored, offline: true });
  other.view();
  assert.equal(other.element('local').hidden, true);
  other.close();
  const restored = environment({ load: stored, offline: true });
  restored.view();
  assert.equal(restored.local()[0].state, 'paused');
  assert.equal(restored.local()[0].confirmed_elapsed_ms, 5000);
  assert.equal(restored.local()[0].operations[1].payload.unknown_gaps[0].reason, 'process_interrupted');
  assert.equal(restored.button('继续').disabled, false);
  restored.close();
});

test('visibility pauses offline counting and wall clock changes do not backfill time', () => {
  const env = environment({ offline: true });
  env.selectOffline();
  env.button('开始专注').click();
  env.tick(3000);
  env.tick(1000, 3600000);
  assert.equal(env.local()[0].confirmed_elapsed_ms, 3000);
  assert.equal(env.local()[0].operations[1].payload.unknown_gaps[0].reason, 'clock_changed');
  env.button('继续').click();
  env.tick(2000);
  env.hide();
  assert.equal(env.local()[0].state, 'paused');
  assert.equal(env.local()[0].confirmed_elapsed_ms, 5000);
  env.close();
});

test('uncertain delivery queries the original receipt before retrying and preserves a definite conflict', async () => {
  const env = environment({ submitError: Error('Connection reset') });
  env.selectOffline();
  env.button('开始专注').click();
  env.tick(2000);
  env.button('结束').click();
  env.button('同步本机记录').click();
  await settle();
  const sent = env.calls.find(call => call.payload);
  assert.equal(env.local()[0].operations[0].dispatch, 'unknown');
  env.button('核对本机同步结果').click();
  await settle();
  assert.ok(env.calls.some(call => call.path.endsWith(`/focus-operations/${sent.payload.operation_id}`)));
  assert.equal(env.local()[0].operations[0].dispatch, 'not_found');
  env.setSubmitError(Object.assign(Error('另一设备有进行中的记录'), { status: 409, code: 'FOCUS_ACTIVE_EXISTS' }));
  env.button('重试原同步操作').click();
  await settle();
  assert.deepEqual(env.calls.filter(call => call.payload), [sent, sent]);
  assert.equal(env.local()[0].operations[0].dispatch, 'conflict');
  assert.match(env.element('local-list').textContent, /另一设备有进行中的记录/);
  env.close();
});

test('online focus verifies the active segment before starting the local clock', async () => {
  const env = environment();
  env.window.CampusFlowWindows.focusTask(task.task_id, task.title);
  await settle();
  env.button('开始专注').click();
  await settle();
  const sent = env.calls.findIndex(call => call.payload);
  assert.equal(env.calls[sent].payload.kind, 'start');
  assert.match(env.calls[sent + 1].path, /\/active$/);
  env.tick(2000);
  assert.match(env.element('timer').textContent, /0 分 2 秒/);
  env.hide();
  await settle();
  assert.equal(env.calls.filter(call => call.payload).at(-1).payload.kind, 'pause');
  assert.equal(env.calls.filter(call => call.payload).at(-1).payload.intervals[0].elapsed_ms, 2000);
  env.close();
});
