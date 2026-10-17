import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import * as nodeFs from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';

// Execute the production store and file adapter; the fs shim is not native/device evidence.
const source = readFileSync(new URL('../entry/src/main/ets/utils/DraftStore.ets', import.meta.url), 'utf8');
const module = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source)).toString('base64')}`);
const { DraftStore, MAX_LOCAL_DRAFT_BYTES, MAX_DRAFT_RECORD_BYTES, draftUtf8Bytes } = module;
const scopeA = JSON.stringify(['https://campus.invalid', 'account-a']);
const scopeB = JSON.stringify(['https://campus.invalid', 'account-b']);
const key = { kind: 'assistant', ownerId: 'session-1' };
const timetableKey = { kind: 'timetable', ownerId: 'main' };
const onboardingKey = { kind: 'onboarding', ownerId: 'main' };

class Clock {
  time = Date.UTC(2026, 9, 18, 8);
  serial = 0;
  tasks = new Map();
  now() { return this.time; }
  set(callback, delayMs) { const id = ++this.serial; this.tasks.set(id, { callback, at: this.time + delayMs }); return id; }
  clear(id) { this.tasks.delete(id); }
  advance(ms) {
    this.time += ms;
    for (const [id, task] of this.tasks) {
      if (task.at <= this.time) { this.tasks.delete(id); task.callback(); }
    }
  }
}

function deferred() {
  let resolve;
  const promise = new Promise((done) => { resolve = done; });
  return { promise, resolve };
}

class MemoryDriver {
  text;
  writes = 0;
  failRead = false;
  failWrite = false;
  failRemove = false;
  nextWrite;
  started;
  constructor(text) { this.text = text; }
  async read() { if (this.failRead) throw Error('private path'); return this.text; }
  async write(text) {
    this.writes++;
    const blocked = this.nextWrite;
    this.nextWrite = undefined;
    this.started?.resolve();
    if (blocked) await blocked.promise;
    if (this.failWrite) throw Error('private disk error');
    this.text = text;
  }
  async remove() { if (this.failRemove) throw Error('private path'); this.text = undefined; }
}

function assistant(value = '  今晚复习线性代数 📖\n保留空白  ') {
  return { text: value, sessionId: 'session-1', anchorDate: '2026-10-18', timezone: 'Asia/Shanghai' };
}
function entry(index = 0) {
  return { date: '2026-10-19', title: `第${index}节 数据结构`, start_time: '08:05', end_time: '09:40',
    location: '第七教学楼北406', teacher: '陈老师' };
}
function timetable(count = 1) {
  return { baselineEntries: Array.from({ length: count }, (_, i) => entry(i)), expectedRevision: 'a'.repeat(64),
    draftEntries: Array.from({ length: count }, (_, i) => entry(i)),
    editor: { date: '2026-', title: '尚未写完', start_time: '25:', end_time: '', location: '', teacher: '' },
    editorOpen: true, editorDirty: true, editingIndex: -1, repeatWeeks: 4,
    sourceWarnings: [{ index: -1, relatedIndex: -1, field: 'source', message: '请核对原课表缺少的地点' }],
    anchorDate: '2026-10-18', timezone: 'Asia/Shanghai', submission: null };
}
function onboarding() {
  const base = timetable();
  return { school: '杭州电子科技大学', campus: '下沙校区', step: 1, semester: '2026秋',
    entries: base.draftEntries, editor: base.editor, editorOpen: true, editorDirty: true,
    editingIndex: -1, repeatWeeks: 4, sourceWarnings: base.sourceWarnings,
    anchorDate: base.anchorDate, timezone: base.timezone, baselineEntries: [], expectedRevision: '', submission: null };
}
function operation(localRevision, id = 'run-1') {
  return { kind: 'run', id, draftKind: 'assistant', ownerId: key.ownerId, localRevision, fingerprint: 'b'.repeat(64) };
}
async function setup(driver = new MemoryDriver()) {
  const clock = new Clock();
  const store = new DraftStore(driver, clock);
  await store.initialize();
  const lease = await store.activate(scopeA);
  return { store, driver, clock, lease };
}
async function cold(driver, scope = scopeA) {
  const store = new DraftStore(driver, new Clock());
  await store.initialize();
  assert.equal(store.list({ scope, generation: 0 }, 'assistant').length, 0, 'no body before authenticated lease');
  const lease = await store.activate(scope);
  return { store, lease };
}

test('adopted Unicode text preserves whitespace and is restored after a new store instance', async () => {
  const { store, driver, lease } = await setup();
  const value = assistant();
  const ticket = store.stage(lease, key, value);
  assert.equal(store.status(lease).phase, 'pending');
  await store.flush(lease);
  assert.equal(store.status(lease).phase, 'saved');
  value.text = 'mutated caller';
  const reopened = await cold(driver);
  assert.deepEqual(reopened.store.read(reopened.lease, key).payload, assistant());
  assert.equal(reopened.store.read(reopened.lease, key).localRevision, ticket.localRevision);
  const copy = reopened.store.read(reopened.lease, key);
  copy.payload.text = 'mutated reader';
  assert.equal(reopened.store.read(reopened.lease, key).payload.text, assistant().text);
});

test('300ms debounce restarts on each edit and flush persists before its deadline', async () => {
  const { store, driver, lease, clock } = await setup();
  const original = driver.writes;
  store.stage(lease, key, assistant('first'));
  clock.advance(200);
  store.stage(lease, key, assistant('last'));
  clock.advance(299);
  await Promise.resolve();
  assert.equal(driver.writes, original);
  await store.flush(lease);
  assert.equal(JSON.parse(driver.text).records[0].payload.text, 'last');
  clock.advance(1);
  await store.flush(lease);
  assert.equal(driver.writes, original + 1);
});

test('debounce writes actual last text when its timer fires', async () => {
  const { store, driver, lease, clock } = await setup();
  store.stage(lease, key, assistant('300ms'));
  clock.advance(300);
  await store.flush(lease);
  assert.equal(JSON.parse(driver.text).records[0].payload.text, '300ms');
});

test('new task concrete date, all-day, midnight and undated values are not reinterpreted', async () => {
  const { store, driver, lease } = await setup();
  for (const [index, date, time, dateChoice] of [[0, '2026-10-19', '00:00', 'tomorrow'],
    [1, '2026-10-19', '', 'calendar'], [2, '', '', 'none']]) {
    store.stage(lease, { kind: 'new-task', ownerId: `task-${index}` },
      { title: '  阅读  ', date, time, dateChoice, anchorDate: '2026-10-18', timezone: 'Asia/Shanghai' });
  }
  await store.flush(lease);
  const restored = await cold(driver);
  assert.equal(restored.store.read(restored.lease, { kind: 'new-task', ownerId: 'task-0' }).payload.date, '2026-10-19');
  assert.equal(restored.store.read(restored.lease, { kind: 'new-task', ownerId: 'task-0' }).payload.time, '00:00');
  assert.equal(restored.store.read(restored.lease, { kind: 'new-task', ownerId: 'task-2' }).payload.date, '');
});

test('500 complete baseline and edited courses, raw invalid editor and accepted warnings roundtrip', async () => {
  const { store, driver, lease } = await setup();
  const value = timetable(500);
  value.editingIndex = 499;
  store.stage(lease, timetableKey, value);
  await store.flush(lease);
  const restored = await cold(driver);
  assert.deepEqual(restored.store.read(restored.lease, timetableKey).payload, value);
  assert.equal(restored.store.read(restored.lease, timetableKey).payload.editor.start_time, '25:');
});

test('whitelist drops subscription URL, credentials, execution flags and unaccepted preview fields', async () => {
  const { store, driver, lease } = await setup();
  const value = onboarding();
  value.scheduleUrl = 'https://private.invalid/?token=secret';
  value.apiKey = 'secret';
  value.completed = true;
  value.importEntries = [entry(88)];
  value.editor.token = 'secret';
  store.stage(lease, onboardingKey, value);
  await store.flush(lease);
  assert.doesNotMatch(driver.text, /private\.invalid|secret|scheduleUrl|apiKey|completed|importEntries|token/);
  const result = store.read(lease, onboardingKey).payload;
  assert.equal(result.repeatWeeks, 4);
  assert.equal(result.sourceWarnings.length, 1);
  assert.equal(result.expectedRevision, '');
});

test('typed frozen timetable submission persists exact original CAS payload with an ID-only operation', async () => {
  const { store, driver, lease } = await setup();
  const value = timetable();
  value.submission = { operationId: 'id-original', expectedRevision: 'a'.repeat(64), entries: [entry()], confirmClear: false };
  const ticket = store.stage(lease, timetableKey, value);
  await store.beginOperation(lease, { kind: 'timetable', id: 'id-original', draftKind: 'timetable', ownerId: 'main', localRevision: ticket.localRevision });
  const restored = await cold(driver);
  assert.deepEqual(restored.store.read(restored.lease, timetableKey).payload.submission, value.submission);
  assert.equal(restored.store.isBlocked(restored.lease, timetableKey), true);
  assert.deepEqual(Object.keys(restored.store.operations(restored.lease)[0]),
    ['scope', 'kind', 'id', 'draftKind', 'ownerId', 'localRevision', 'fingerprint', 'runRequest']);
  assert.equal(restored.store.operations(restored.lease)[0].runRequest, null);
});

test('run request survives newer input and restart for explicit same-ID recovery without credentials', async () => {
  const { store, driver, lease } = await setup();
  const ticket = store.stage(lease, key, assistant('original'));
  const runRequest = { run_id: 'run-1', session_id: 'original-session', model: 'configured-model', message: 'original', token: 'private-secret' };
  await store.beginOperation(lease, { ...operation(ticket.localRevision), runRequest });
  store.stage(lease, key, assistant('new unsubmitted message')); await store.flush(lease);
  const restored = await cold(driver);
  assert.equal(restored.store.read(restored.lease, key).payload.text, 'new unsubmitted message');
  assert.deepEqual(restored.store.operations(restored.lease)[0].runRequest,
    { run_id: 'run-1', session_id: 'original-session', model: 'configured-model', message: 'original' });
  assert.doesNotMatch(driver.text, /private-secret|token/);
  const copy = restored.store.operations(restored.lease); copy[0].runRequest.message = 'changed';
  assert.equal(restored.store.operations(restored.lease)[0].runRequest.message, 'original');
});

test('frozen run requests enforce ID and kind and the backend 8000 Unicode character boundary', async () => {
  const { store, lease } = await setup();
  const ticket = store.stage(lease, key, assistant());
  const runRequest = { run_id: 'run-1', session_id: 'session-1', model: 'deepseek-v4-pro', message: '😀'.repeat(8000) };
  await store.beginOperation(lease, { ...operation(ticket.localRevision), runRequest });
  assert.equal(store.operations(lease)[0].runRequest.message.length, 16000);
  await assert.rejects(store.beginOperation(lease, { ...operation(ticket.localRevision, 'run-2'), runRequest }));
  await assert.rejects(store.beginOperation(lease, { ...operation(ticket.localRevision, 'run-3'),
    runRequest: { ...runRequest, run_id: 'run-3', message: '😀'.repeat(8001) } }));
  await assert.rejects(store.beginOperation(lease, { kind: 'proposal', id: 'proposal', draftKind: 'new-task', ownerId: 'main',
    localRevision: 1, runRequest: { ...runRequest, run_id: 'proposal' } }));
});

test('onboarding frozen campus map copies only bounded public fields', async () => {
  const { store, driver, lease } = await setup();
  const value = onboarding();
  value.submission = { operationId: 'onboard-original', expectedRevision: 'a'.repeat(64), school: value.school,
    campus: value.campus, semester: value.semester, timetable: value.entries,
    campusMap: { campus_name: value.campus, places: [{ name: '图书馆', category: 'library', zone: '北区', aliases: ['图文中心'], token: 'secret' }],
      warnings: ['来源为公开校园地图'], subscription_url: 'secret' } };
  store.stage(lease, onboardingKey, value);
  await store.flush(lease);
  assert.doesNotMatch(driver.text, /secret|token|subscription_url/);
  const restored = await cold(driver);
  assert.deepEqual(restored.store.read(restored.lease, onboardingKey).payload.submission.campusMap.places[0].aliases, ['图文中心']);
});

test('same scope retains drafts, different account or base URL clears and invalidates old lease synchronously', async () => {
  const { store, lease, driver } = await setup();
  store.stage(lease, key, assistant());
  const againPromise = store.activate(scopeA);
  assert.equal(store.valid(lease), false);
  assert.equal(store.read(lease, key), undefined);
  const again = await againPromise;
  assert.equal(store.read(again, key).payload.text, assistant().text);
  const other = await store.activate(scopeB);
  assert.equal(store.list(other, 'assistant').length, 0);
  assert.doesNotMatch(driver.text, /今晩|线性代数/);
  store.stage(other, key, assistant('B input'));
  const differentService = await store.activate(JSON.stringify(['https://different.invalid', 'account-b']));
  assert.equal(store.list(differentService, 'assistant').length, 0);
});

test('write failure retains prior disk and latest memory with safe error, then retry succeeds', async () => {
  const { store, driver, lease } = await setup();
  store.stage(lease, key, assistant('saved'));
  await store.flush(lease);
  const previous = driver.text;
  driver.failWrite = true;
  store.stage(lease, key, assistant('new unsaved'));
  await assert.rejects(store.flush(lease), /尚未保存/);
  assert.equal(driver.text, previous);
  assert.equal(store.read(lease, key).payload.text, 'new unsaved');
  assert.equal(store.status(lease).phase, 'error');
  assert.doesNotMatch(store.status(lease).message, /private|disk/);
  driver.failWrite = false;
  await store.flush(lease);
  assert.equal(store.status(lease).phase, 'saved');
});

test('in-flight write followed by newer input cannot report newer text saved', async () => {
  const { store, driver, lease } = await setup();
  store.stage(lease, key, assistant('old snapshot'));
  const gate = deferred(); driver.nextWrite = gate; driver.started = deferred();
  const oldFlush = store.flush(lease);
  await driver.started.promise;
  store.stage(lease, key, assistant('new characters'));
  gate.resolve(); await oldFlush;
  assert.equal(store.status(lease).phase, 'pending');
  assert.equal(store.read(lease, key).payload.text, 'new characters');
  assert.equal(JSON.parse(driver.text).records[0].payload.text, 'old snapshot');
  await store.flush(lease);
  assert.equal(JSON.parse(driver.text).records[0].payload.text, 'new characters');
});

test('rejected over-limit keystrokes during an earlier write cannot be reported saved by its late callback', async () => {
  const { store, driver, lease } = await setup();
  store.stage(lease, key, assistant('valid earlier input'));
  const gate = deferred(); driver.nextWrite = gate; driver.started = deferred();
  const saving = store.flush(lease); const rejected = assert.rejects(saving);
  await driver.started.promise;
  assert.throws(() => store.stage(lease, key, assistant('x'.repeat(32001))));
  gate.resolve(); await rejected;
  assert.equal(store.status(lease).phase, 'error');
  assert.equal(JSON.parse(driver.text).records[0].payload.text, 'valid earlier input');
});

test('same-revision removal never deletes newer input including input arriving during atomic remove', async () => {
  const { store, driver, lease } = await setup();
  const old = store.stage(lease, key, assistant('old'));
  store.stage(lease, key, assistant('new'));
  assert.equal(await store.remove(lease, key, old.localRevision), false);
  const current = store.read(lease, key);
  const gate = deferred(); driver.nextWrite = gate; driver.started = deferred();
  const removal = store.remove(lease, key, current.localRevision);
  await driver.started.promise;
  store.stage(lease, key, assistant('new during removal'));
  gate.resolve();
  assert.equal(await removal, true);
  assert.equal(store.read(lease, key).payload.text, 'new during removal');
  await store.flush(lease);
  assert.equal(JSON.parse(driver.text).records[0].payload.text, 'new during removal');
});

test('pending operation is durable before begin resolves and blocks removal or plain restoration', async () => {
  const { store, driver, lease } = await setup();
  const ticket = store.stage(lease, key, assistant());
  await store.beginOperation(lease, operation(ticket.localRevision));
  assert.equal(JSON.parse(driver.text).operations.length, 1);
  assert.equal(store.isBlocked(lease, key), true);
  assert.equal(await store.remove(lease, key, ticket.localRevision), false);
  const restored = await cold(driver);
  assert.equal(restored.store.isBlocked(restored.lease, key), true);
  await restored.store.resolveOperation(restored.lease, 'run', 'run-1');
  assert.equal(restored.store.isBlocked(restored.lease, key), false);
  assert.equal(await restored.store.remove(restored.lease, key, ticket.localRevision), true);
});

test('a new operation registered while removal writes retains the referenced draft before POST', async () => {
  const { store, driver, lease } = await setup();
  const ticket = store.stage(lease, key, assistant('to submit'));
  const gate = deferred(); driver.nextWrite = gate; driver.started = deferred();
  const removing = store.remove(lease, key, ticket.localRevision);
  await driver.started.promise;
  const registering = store.beginOperation(lease, operation(ticket.localRevision));
  gate.resolve();
  assert.equal(await removing, false);
  await registering;
  assert.equal(store.isBlocked(lease, key), true);
  assert.equal(JSON.parse(driver.text).records[0].payload.text, 'to submit');
  assert.equal(JSON.parse(driver.text).operations.length, 1);
});

test('resolving an operation cannot delete keystrokes entered during its write', async () => {
  const { store, driver, lease } = await setup();
  const ticket = store.stage(lease, key, assistant('submitted'));
  await store.beginOperation(lease, operation(ticket.localRevision));
  const gate = deferred(); driver.nextWrite = gate; driver.started = deferred();
  const resolving = store.resolveOperation(lease, 'run', 'run-1');
  await driver.started.promise;
  store.stage(lease, key, assistant('next question'));
  gate.resolve(); await resolving; await store.flush(lease);
  assert.equal(JSON.parse(driver.text).operations.length, 0);
  assert.equal(JSON.parse(driver.text).records[0].payload.text, 'next question');
});

test('successful resolution atomically removes exact consumed input before a simulated cold restart', async () => {
  const { store, driver, lease } = await setup();
  const ticket = store.stage(lease, key, assistant('already applied question'));
  await store.beginOperation(lease, operation(ticket.localRevision));
  const writes = driver.writes;
  await store.resolveOperation(lease, 'run', 'run-1', true);
  assert.equal(driver.writes, writes + 1, 'operation and exact input are removed in one replacement');
  const restarted = await cold(driver);
  assert.equal(restarted.store.read(restarted.lease, key), undefined);
  assert.equal(restarted.store.operations(restarted.lease).length, 0);
});

test('atomic success keeps a newer input across restart, including a revision staged while replacing', async () => {
  const { store, driver, lease } = await setup();
  const ticket = store.stage(lease, key, assistant('submitted'));
  await store.beginOperation(lease, operation(ticket.localRevision));
  const gate = deferred(); driver.nextWrite = gate; driver.started = deferred();
  const completing = store.resolveOperation(lease, 'run', 'run-1', true);
  await driver.started.promise;
  store.stage(lease, key, assistant('new unsent draft'));
  gate.resolve(); await completing; await store.flush(lease);
  const restarted = await cold(driver);
  assert.equal(restarted.store.read(restarted.lease, key).payload.text, 'new unsent draft');
  assert.equal(restarted.store.operations(restarted.lease).length, 0);
});

test('failed atomic completion retains both operation and consumed input for another status query', async () => {
  const { store, driver, lease } = await setup();
  const ticket = store.stage(lease, key, assistant('submitted'));
  await store.beginOperation(lease, operation(ticket.localRevision));
  driver.failWrite = true;
  await assert.rejects(store.resolveOperation(lease, 'run', 'run-1', true));
  assert.equal(store.isBlocked(lease, key), true);
  assert.equal(store.read(lease, key).payload.text, 'submitted');
  driver.failWrite = false;
  const restarted = await cold(driver);
  assert.equal(restarted.store.isBlocked(restarted.lease, key), true);
  assert.equal(restarted.store.read(restarted.lease, key).payload.text, 'submitted');
});

test('begin persistence failure rejects before caller POST; resolving failure retains operation block', async () => {
  const { store, driver, lease } = await setup();
  const ticket = store.stage(lease, key, assistant());
  driver.failWrite = true;
  let posts = 0;
  await assert.rejects((async () => { await store.beginOperation(lease, operation(ticket.localRevision)); posts++; })());
  assert.equal(posts, 0);
  assert.equal(store.isBlocked(lease, key), true);
  driver.failWrite = false;
  await store.beginOperation(lease, operation(ticket.localRevision));
  driver.failWrite = true;
  await assert.rejects(store.resolveOperation(lease, 'run', 'run-1'));
  assert.equal(store.isBlocked(lease, key), true);
  assert.equal(JSON.parse(driver.text).operations.length, 1);
  driver.failWrite = false;
  await store.resolveOperation(lease, 'run', 'run-1');
  assert.equal(store.isBlocked(lease, key), false);
});

test('operations reject raw submission fingerprints, wrong draft association and changed revision', async () => {
  const { store, lease } = await setup();
  const ticket = store.stage(lease, key, assistant());
  await assert.rejects(store.beginOperation(lease, { ...operation(ticket.localRevision), fingerprint: '{"key":"secret"}' }));
  await assert.rejects(store.beginOperation(lease, { ...operation(ticket.localRevision), kind: 'timetable' }));
  store.stage(lease, key, assistant('new'));
  await assert.rejects(store.beginOperation(lease, operation(ticket.localRevision)), /已经变化/);
});

test('unchecked original revision survives later draft edits and enforces fixed operation limit', async () => {
  const { store, lease } = await setup();
  const ticket = store.stage(lease, key, assistant());
  for (let i = 0; i < module.MAX_DRAFT_OPERATIONS; i++) await store.beginOperation(lease, operation(ticket.localRevision, `run-${i}`));
  await assert.rejects(store.beginOperation(lease, operation(ticket.localRevision, 'overflow')));
  assert.equal(store.operations(lease).length, module.MAX_DRAFT_OPERATIONS);
  const newer = store.stage(lease, key, assistant('newer draft'));
  assert.equal(store.isBlocked(lease, key), true);
  assert.equal(store.isBlocked(lease, key, newer.localRevision), false);
});

test('clear immediately hides and invalidates, then runs after in-flight write with no resurrection', async () => {
  const { store, driver, lease } = await setup();
  store.stage(lease, key, assistant());
  const gate = deferred(); driver.nextWrite = gate; driver.started = deferred();
  const saving = store.flush(lease);
  const rejected = assert.rejects(saving);
  await driver.started.promise;
  const clearing = store.clear();
  assert.equal(store.valid(lease), false);
  assert.equal(store.read(lease, key), undefined);
  assert.throws(() => store.stage(lease, key, assistant('late')));
  gate.resolve(); await rejected; await clearing;
  assert.equal(driver.text, undefined);
  const next = await store.activate(scopeA);
  assert.equal(store.list(next, 'assistant').length, 0);
});

test('account switch queues after old write and stale flush does not cancel new debounce', async () => {
  const { store, driver, lease, clock } = await setup();
  store.stage(lease, key, assistant('account A'));
  const gate = deferred(); driver.nextWrite = gate; driver.started = deferred();
  const saving = store.flush(lease); const rejected = assert.rejects(saving);
  await driver.started.promise;
  const switchAccount = store.activate(scopeB);
  assert.equal(store.valid(lease), false);
  gate.resolve(); await rejected;
  const next = await switchAccount;
  store.stage(next, key, assistant('account B'));
  await assert.rejects(store.flush(lease));
  assert.equal(clock.tasks.size, 1, 'stale flush cannot cancel a new account timer');
  clock.advance(300);
  await store.flush(next);
  assert.equal(JSON.parse(driver.text).scope, scopeB);
  assert.equal(JSON.parse(driver.text).records[0].payload.text, 'account B');
});

test('clear failure keeps old content inaccessible and permits an explicit retry', async () => {
  const { store, driver, lease } = await setup();
  store.stage(lease, key, assistant()); await store.flush(lease);
  driver.failRemove = true;
  await assert.rejects(store.clear());
  assert.equal(store.read(lease, key), undefined);
  assert.equal(store.operations(lease).length, 0);
  driver.failRemove = false;
  await store.clear();
  assert.equal(driver.text, undefined);
});

test('malformed JSON, unknown version, malformed fields and oversize never activate over the file', async () => {
  for (const raw of ['{broken', JSON.stringify({ version: 99, scope: scopeA, revision: 0, records: [], operations: [] }),
    JSON.stringify({ version: 1, scope: scopeA, revision: 1, records: [{ kind: 'assistant' }], operations: [] }),
    'x'.repeat(MAX_LOCAL_DRAFT_BYTES + 1)]) {
    const driver = new MemoryDriver(raw); const store = new DraftStore(driver, new Clock());
    await assert.rejects(store.initialize());
    await assert.rejects(store.activate(scopeA));
    assert.equal(driver.text, raw); assert.equal(driver.writes, 0);
    await store.clear();
    const lease = await store.activate(scopeA);
    assert.equal(store.list(lease, 'assistant').length, 0);
  }
});

test('read failure also blocks overwrite, even if activate follows initialization failure', async () => {
  const driver = new MemoryDriver('private content'); driver.failRead = true;
  const store = new DraftStore(driver, new Clock());
  await assert.rejects(store.initialize());
  await assert.rejects(store.activate(scopeA));
  assert.equal(driver.writes, 0); assert.equal(driver.text, 'private content');
});

test('record count and oversize input reject without truncation, eviction or false saved status', async () => {
  const { store, driver, lease } = await setup();
  for (let i = 0; i < 20; i++) store.stage(lease, { kind: 'assistant', ownerId: `s-${i}` }, assistant(`text ${i}`));
  await store.flush(lease); const previous = driver.text;
  assert.throws(() => store.stage(lease, { kind: 'assistant', ownerId: 'extra' }, assistant('extra')));
  await assert.rejects(store.flush(lease));
  assert.equal(store.status(lease).phase, 'error'); assert.equal(driver.text, previous);
  assert.equal(store.list(lease, 'assistant').length, 20);
  assert.throws(() => store.stage(lease, { kind: 'assistant', ownerId: 's-0' }, assistant('x'.repeat(32001))));
  assert.equal(store.read(lease, { kind: 'assistant', ownerId: 's-0' }).payload.text, 'text 0');
});

test('single-record and whole-file byte budgets allow normal 500-entry edits and reject huge drafts intact', async () => {
  const { store, lease } = await setup();
  const large = timetable(500);
  for (const item of [...large.baselineEntries, ...large.draftEntries]) item.location = '中'.repeat(1000);
  assert.ok(draftUtf8Bytes(JSON.stringify(large)) > MAX_DRAFT_RECORD_BYTES);
  assert.throws(() => store.stage(lease, timetableKey, large));
  assert.equal(store.read(lease, timetableKey), undefined);
  const medium = timetable(500);
  for (const item of [...medium.baselineEntries, ...medium.draftEntries]) item.location = 'x'.repeat(1400);
  store.stage(lease, { kind: 'timetable', ownerId: 'one' }, medium);
  store.stage(lease, { kind: 'timetable', ownerId: 'two' }, medium);
  assert.throws(() => store.stage(lease, { kind: 'timetable', ownerId: 'three' }, medium));
  assert.equal(store.list(lease, 'timetable').length, 2);
});

test('array limits and editor index pairing are validated without business-validating unfinished form', async () => {
  const { store, lease } = await setup();
  assert.throws(() => store.stage(lease, timetableKey, timetable(501)));
  const value = timetable(); value.editingIndex = 1;
  assert.throws(() => store.stage(lease, timetableKey, value));
  value.editingIndex = -1; value.editor.start_time = 'impossible';
  store.stage(lease, timetableKey, value);
  assert.equal(store.read(lease, timetableKey).payload.editor.start_time, 'impossible');
});

test('subscribers see truthful stages and their exceptions cannot prevent storage', async () => {
  const { store, lease } = await setup();
  const phases = [];
  const unsubscribe = store.subscribe((state) => { phases.push(state.phase); state.message = 'mutate copy'; });
  const bad = store.subscribe(() => { throw Error('view crash'); });
  store.stage(lease, key, assistant()); await store.flush(lease);
  assert.deepEqual(phases, ['idle', 'pending', 'saving', 'saved']);
  assert.notEqual(store.status(lease).message, 'mutate copy');
  unsubscribe(); bad();
});

function nativeError(error) { return { code: error.code === 'ENOENT' ? 13900002 : 13900013 }; }
function fsShim() {
  const handles = new Map();
  const faults = { short: false, fsync: false, rename: false, unlink: false };
  const calls = [];
  const fs = {
    OpenMode: { WRITE_ONLY: 1, CREATE: 2, TRUNC: 4 },
    async stat(path) { try { return await nodeFs.stat(path); } catch (error) { throw nativeError(error); } },
    async readText(path) { try { return await nodeFs.readFile(path, 'utf8'); } catch (error) { throw nativeError(error); } },
    async open(path) { const handle = await nodeFs.open(path, 'w'); handles.set(handle.fd, handle); calls.push('open'); return { fd: handle.fd }; },
    async write(fd, text) { calls.push('write'); const buffer = Buffer.from(text, 'utf8'); return (await handles.get(fd).write(buffer, 0, faults.short ? buffer.length - 1 : buffer.length)).bytesWritten; },
    async fsync(fd) { calls.push('fsync'); if (faults.fsync) throw Error('sync'); await handles.get(fd).sync(); },
    async close(file) { calls.push('close'); await handles.get(file.fd).close(); handles.delete(file.fd); },
    async rename(from, to) { calls.push('rename'); if (faults.rename) throw Error('rename'); await nodeFs.rename(from, to); },
    async unlink(path) { calls.push('unlink'); if (faults.unlink) throw { code: 13900013 }; try { await nodeFs.unlink(path); } catch (error) { throw nativeError(error); } }
  };
  return { fs, faults, calls, handles };
}
const fileSource = readFileSync(new URL('../entry/src/main/ets/services/LocalDrafts.ets', import.meta.url), 'utf8')
  .replace(/^import .*;\r?\n/gm, '').replace(/export /g, '');
function fileDriver(shim) {
  return new Function('fs', 'DraftStore', 'MAX_LOCAL_DRAFT_BYTES', 'draftUtf8Bytes',
    `${stripTypeScriptTypes(fileSource)}\nreturn FileDraftDriver;`)(shim.fs, DraftStore, MAX_LOCAL_DRAFT_BYTES, draftUtf8Bytes);
}
async function inDirectory(action) {
  const directory = await nodeFs.mkdtemp(join(tmpdir(), 'campusflow-drafts-'));
  try { await action(directory); } finally { await nodeFs.rm(directory, { recursive: true, force: true }); }
}

test('production FileDraftDriver uses real files for UTF-8, restart, fsync-before-rename and removal', async () => inDirectory(async (directory) => {
  const shim = fsShim(); const File = fileDriver(shim); const driver = new File(); driver.configure(directory);
  const { store, lease } = await setup(driver);
  const text = assistant('中文 😀𠮷\n独立行 \ud800');
  store.stage(lease, key, text); await store.flush(lease);
  assert.equal(draftUtf8Bytes(text.text), Buffer.byteLength(text.text, 'utf8'));
  const secondDriver = new File(); secondDriver.configure(directory);
  const reopened = await cold(secondDriver);
  assert.equal(reopened.store.read(reopened.lease, key).payload.text, text.text);
  assert.ok(shim.calls.indexOf('fsync') < shim.calls.indexOf('rename'));
  assert.equal(shim.handles.size, 0);
  await reopened.store.clear();
  await assert.rejects(nodeFs.stat(join(directory, 'campusflow-local-drafts-v1.json')), { code: 'ENOENT' });
}));

for (const fault of ['short', 'fsync', 'rename']) {
  test(`production file ${fault} failure preserves previous JSON and never reports saved`, async () => inDirectory(async (directory) => {
    const shim = fsShim(); const File = fileDriver(shim); const driver = new File(); driver.configure(directory);
    const { store, lease } = await setup(driver);
    store.stage(lease, key, assistant('previous')); await store.flush(lease);
    const path = join(directory, 'campusflow-local-drafts-v1.json'); const original = await nodeFs.readFile(path, 'utf8');
    shim.faults[fault] = true;
    store.stage(lease, key, assistant('new 中文😀'));
    await assert.rejects(store.flush(lease));
    assert.equal(await nodeFs.readFile(path, 'utf8'), original);
    assert.equal(store.status(lease).phase, 'error');
    assert.equal(shim.handles.size, 0);
    await assert.rejects(nodeFs.stat(`${path}.tmp`), { code: 'ENOENT' });
    shim.faults[fault] = false; await store.flush(lease);
    assert.equal(JSON.parse(await nodeFs.readFile(path, 'utf8')).records[0].payload.text, 'new 中文😀');
  }));
}

test('production file rejects oversize before readText and preserves malformed input until explicit clear', async () => inDirectory(async (directory) => {
  const shim = fsShim(); const File = fileDriver(shim); const path = join(directory, 'campusflow-local-drafts-v1.json');
  await nodeFs.writeFile(path, '{broken');
  const driver = new File(); driver.configure(directory);
  const store = new DraftStore(driver, new Clock());
  await assert.rejects(store.initialize()); await assert.rejects(store.activate(scopeA));
  assert.equal(await nodeFs.readFile(path, 'utf8'), '{broken');
  await store.clear();
  await nodeFs.writeFile(path, 'x'.repeat(MAX_LOCAL_DRAFT_BYTES + 1));
  let reads = 0; const original = shim.fs.readText; shim.fs.readText = async (target) => { reads++; return original(target); };
  await assert.rejects(driver.read()); assert.equal(reads, 0);
  assert.equal((await nodeFs.stat(path)).size, MAX_LOCAL_DRAFT_BYTES + 1);
}));

test('production real-file clear queued behind paused rename cannot resurrect previous account data', async () => inDirectory(async (directory) => {
  const shim = fsShim(); const File = fileDriver(shim); const driver = new File(); driver.configure(directory);
  const { store, lease } = await setup(driver);
  const entered = deferred(); const release = deferred(); const originalRename = shim.fs.rename;
  shim.fs.rename = async (from, to) => { entered.resolve(); await release.promise; await originalRename(from, to); };
  store.stage(lease, key, assistant('pending disk'));
  const saving = store.flush(lease); const rejected = assert.rejects(saving);
  await entered.promise;
  const clear = store.clear();
  assert.equal(store.read(lease, key), undefined);
  release.resolve(); await rejected; await clear;
  await assert.rejects(nodeFs.stat(join(directory, 'campusflow-local-drafts-v1.json')), { code: 'ENOENT' });
  assert.equal(shim.handles.size, 0);
}));
