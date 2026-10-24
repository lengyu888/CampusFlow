import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { JSDOM } from 'jsdom';

const app = readFileSync(new URL('../../src/campusflow_agent/web/app.js', import.meta.url), 'utf8');
const operationId = '8f236f72-7607-4d54-8006-bd8e6b202b99';
const sourceId = '8024a1fe-9499-4a46-bf77-aa5cfe2686b9';
const task = { task_id: 'task-fixture', title: '<img src=x onerror=alert(1)>', status: 'completed',
  task_version: 3, completion_operation_id: sourceId };
function operation(kind = 'restore', state = 'pending') {
  return { operation_id: operationId, task_id: task.task_id, user_id: 'owner', kind, state,
    expected_revision: kind === 'restore' ? 3 : 2, source_operation_id: kind === 'restore' ? sourceId : null,
    receipt: state === 'applied' ? { operation_id: operationId, task_id: task.task_id,
      after_status: kind === 'restore' ? 'pending' : 'completed' } : null,
    preview: kind === 'restore' ? { task, warnings: ['保留原时间，不会补发过去的提醒。'], conflicts: [],
      candidate_id: 'status:fixture', course_review: { state: 'none', requires_acknowledgement: false,
        candidate_id: 'status:fixture', review_digest: 'a'.repeat(64), overlaps: [] } } : null };
}
function environment(responder) {
  const dom = new JSDOM('<button id="toggle">恢复待办</button>', { url: 'http://127.0.0.1:8000', runScripts: 'outside-only' });
  const calls = [], toasts = [];
  dom.window.crypto.randomUUID = () => operationId;
  dom.window.HTMLDialogElement.prototype.showModal = function () { this.open = true; };
  dom.window.HTMLDialogElement.prototype.close = function () { this.open = false; this.dispatchEvent(new dom.window.Event('close')); };
  dom.window.fixtureTask = structuredClone(task);
  dom.window.fixtureApi = async (path, options = {}) => {
    calls.push({ path, method: options.method ?? 'GET', body: options.body ? JSON.parse(options.body) : null });
    return responder(calls.at(-1), calls.length);
  };
  dom.window.fixtureToast = (message, kind) => toasts.push({ message, kind });
  const start = app.includes('function taskStatusKey(') ? app.indexOf('function taskStatusKey(') : app.indexOf('async function setTaskCompleted(');
  dom.window.eval(`const state = { user: {user_id: 'owner'} }; const api = window.fixtureApi;
    const showToast = window.fixtureToast; function taskTimeLabel() { return '原时间'; }
    let loaded = 0; async function loadPlans() { loaded++; }
    ${app.slice(start, app.indexOf('async function removeTask('))}
    window.runToggle = (completed = false) => setTaskCompleted(window.fixtureTask, completed, document.getElementById('toggle'));
    window.switchOwner = () => { state.user = {user_id: 'another-owner'}; };
    window.loadedCount = () => loaded;`);
  return { dom, calls, toasts, window: dom.window, document: dom.window.document };
}
const settle = () => new Promise(resolve => setTimeout(resolve, 0));

test('restore starts V2 preview with current version and original completion receipt; no mutation until explicit confirm', async () => {
  const fixture = environment(() => operation());
  await fixture.window.runToggle();
  assert.equal(fixture.calls[0].method, 'POST');
  assert.match(fixture.calls[0].path, /\/tasks\/task-fixture\/status-operations$/);
  assert.equal(fixture.calls[0].body.kind, 'restore');
  assert.equal(fixture.calls[0].body.expected_revision, 3);
  assert.equal(fixture.calls[0].body.source_operation_id, sourceId);
  assert.equal(fixture.calls.length, 1);
  assert.equal(fixture.document.querySelector('[data-task-status-confirm]').disabled, false);
  assert.equal(fixture.document.querySelector('dialog img'), null, 'preview data must be text, not HTML');
  assert.match(fixture.document.querySelector('dialog').textContent, /保留原时间/);
  fixture.dom.window.close();
});

test('completion uses the same versioned receipt protocol instead of legacy PATCH', async () => {
  const fixture = environment(() => operation('complete', 'applied'));
  fixture.window.fixtureTask = { ...task, status: 'pending', task_version: 2, completion_operation_id: null };
  await fixture.window.runToggle(true);
  assert.equal(fixture.calls[0].method, 'POST');
  assert.equal(fixture.calls[0].body.expected_revision, 2);
  assert.equal(fixture.calls[0].body.kind, 'complete');
  assert.equal(fixture.window.loadedCount(), 1);
  assert.match(fixture.toasts.at(-1).message, /已完成/);
  fixture.dom.window.close();
});

test('restore confirmation submits only the exact reviewed operation and requires course acknowledgement', async () => {
  const pending = operation(); pending.preview.course_review.requires_acknowledgement = true;
  pending.preview.course_review.state = 'needs_review';
  const fixture = environment((call, number) => number === 1 ? pending : operation('restore', 'applied'));
  await fixture.window.runToggle();
  const confirm = fixture.document.querySelector('[data-task-status-confirm]');
  assert.equal(confirm.disabled, true);
  const check = fixture.document.querySelector('[data-task-status-ack]');
  check.checked = true; check.dispatchEvent(new fixture.window.Event('change'));
  assert.equal(confirm.disabled, false); confirm.click(); await settle();
  assert.equal(fixture.calls[1].path, `/api/v1/task-status-operations/${fixture.calls[0].body.operation_id}/confirm`);
  assert.deepEqual(fixture.calls[1].body, { acknowledgements: [{ candidate_id: 'status:fixture', review_digest: 'a'.repeat(64) }] });
  assert.equal(fixture.window.loadedCount(), 1);
  fixture.dom.window.close();
});

test('conflicts block restore confirmation and missing completion receipts do not send requests', async () => {
  const pending = operation(); pending.preview.conflicts = ['和已有任务冲突'];
  const fixture = environment(() => pending); await fixture.window.runToggle();
  assert.equal(fixture.document.querySelector('[data-task-status-confirm]').disabled, true);
  assert.match(fixture.document.querySelector('dialog').textContent, /和已有任务冲突/);
  fixture.dom.window.close();
  const missing = environment(() => pending); missing.window.fixtureTask.completion_operation_id = null;
  await missing.window.runToggle(); assert.equal(missing.calls.length, 0); missing.dom.window.close();
});

test('an uncertain response persists original id and clicking again only queries its receipt', async () => {
  const fixture = environment((call, number) => { if (number === 1) throw Error('connection lost'); return operation(); });
  await fixture.window.runToggle();
  assert.equal(fixture.calls.length, 1);
  assert.match(fixture.document.querySelector('dialog').textContent, /结果未核实/);
  await fixture.window.runToggle();
  assert.equal(fixture.calls[1].method, 'GET');
  assert.equal(fixture.calls[1].path, `/api/v1/task-status-operations/${fixture.calls[0].body.operation_id}`);
  assert.equal(fixture.calls.filter(call => call.method === 'POST').length, 1);
  fixture.dom.window.close();
});

test('blocked local persistence fails closed before HTTP; late responses cannot update another account', async () => {
  const blocked = environment(() => operation());
  Object.defineProperty(blocked.window.Storage.prototype, 'setItem', { value() { throw Error('quota'); } });
  await blocked.window.runToggle(); assert.equal(blocked.calls.length, 0); blocked.dom.window.close();
  let resolve;
  const switched = environment(() => new Promise(done => { resolve = done; }));
  const request = switched.window.runToggle(); switched.window.switchOwner(); resolve(operation('restore', 'applied')); await request;
  assert.equal(switched.window.loadedCount(), 0); assert.equal(switched.document.querySelector('dialog'), null);
  switched.dom.window.close();
});

test('mismatched receipts never report success, rejection clears only the unsent terminal intent, cancellation uses original id', async () => {
  const mismatch = environment(() => ({ ...operation('restore', 'applied'), user_id: 'wrong-owner' }));
  await mismatch.window.runToggle();
  assert.equal(mismatch.window.loadedCount(), 0);
  assert.match(mismatch.document.querySelector('dialog').textContent, /不一致/); mismatch.dom.window.close();
  const rejected = environment(() => { const error = Error('任务已变化'); error.status = 409; throw error; });
  await rejected.window.runToggle(); assert.equal(rejected.window.localStorage.length, 0); rejected.dom.window.close();
  const cancel = environment((call, count) => count === 1 ? operation() : operation('restore', 'cancelled'));
  await cancel.window.runToggle();
  [...cancel.document.querySelectorAll('dialog button')].find(button => button.textContent === '取消恢复').click();
  await settle(); assert.match(cancel.calls[1].path, new RegExp(`${operationId}/cancel$`));
  assert.equal(cancel.window.loadedCount(), 0); assert.equal(cancel.window.localStorage.length, 0); cancel.dom.window.close();
});

test('untimed tasks retain the explicit unchecked warning and are not falsely blocked', async () => {
  const pending = operation(); pending.preview.course_review.state = 'unchecked';
  pending.preview.warnings.push('未提供完整起止时间，未参与时间冲突核对。');
  const fixture = environment(() => pending); await fixture.window.runToggle();
  assert.equal(fixture.document.querySelector('[data-task-status-confirm]').disabled, false);
  assert.match(fixture.document.querySelector('dialog').textContent, /未参与时间冲突核对/); fixture.dom.window.close();
});

test('browser restart resumes only the saved receipt lookup, never a new mutation', async () => {
  const first = environment(() => { throw Error('response lost'); }); await first.window.runToggle();
  const key = first.window.localStorage.key(0), saved = first.window.localStorage.getItem(key); first.dom.window.close();
  const restarted = environment(() => operation()); restarted.window.localStorage.setItem(key, saved);
  await restarted.window.runToggle(); assert.equal(restarted.calls.length, 1);
  assert.equal(restarted.calls[0].method, 'GET'); assert.match(restarted.calls[0].path, new RegExp(`${operationId}$`));
  restarted.dom.window.close();
});

test('action proposals are placed inside the conversation, not the hidden mobile trace panel', () => {
  const dom = new JSDOM('<main id="messages"></main><aside id="trace" style="display:none"></aside>', {runScripts: 'outside-only'});
  const append = app.slice(app.indexOf('function appendMessage('), app.indexOf('const SVG_NS'));
  const proposal = app.slice(app.indexOf('function actionDescription('), app.indexOf('async function confirmAction('));
  dom.window.eval(`const state = {user: {display_name: '合成同学'}};
    const elements = {messages: document.querySelector('#messages'), traceList: document.querySelector('#trace')};
    function ensureTraceArea() {} function clearEmptyState() {} function scrollMessages() {}
    function modelLabel() { return 'FLASH'; } function confirmAction() {}
    ${append} ${proposal}`);
  dom.window.renderPendingAction({proposal_id: operationId, title: '<img src=x>', action: 'create', kind: 'task', reason: '核对后才写入'});
  assert.equal(dom.window.document.querySelector('#messages .action-card button').textContent, '确认执行此操作');
  assert.equal(dom.window.document.querySelector('#trace .action-card'), null);
  assert.equal(dom.window.document.querySelector('#messages img'), null); dom.window.close();
});
