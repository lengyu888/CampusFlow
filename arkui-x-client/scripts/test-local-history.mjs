import './helpers/theme-fixture.mjs';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import * as nodeFs from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { stripThemeTypeScriptTypes as stripTypeScriptTypes } from './helpers/theme-fixture.mjs';
import { test } from 'node:test';

// Exercise production ArkTS logic with injected storage, not copied cache logic.
const storeSource = readFileSync(new URL('../entry/src/main/ets/utils/LocalHistoryStore.ets', import.meta.url), 'utf8')
  .replace(/^import .* from '\.\.\/model\/ApiModels';\r?\n/m, '');
const { LocalHistoryStore, historyScope, MAX_LOCAL_HISTORY_BYTES } =
  await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(storeSource)).toString('base64')}`);
const scopeA = historyScope('http://campus.invalid:8000', 'account-a');
const scopeB = historyScope('http://campus.invalid:8000', 'account-b');

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
  async read() {
    if (this.failRead) throw new Error('permission denied');
    return this.text;
  }
  async write(text) {
    this.writes++;
    const block = this.nextWrite;
    this.nextWrite = undefined;
    this.started?.resolve();
    if (block) await block.promise;
    if (this.failWrite) throw new Error('disk full');
    this.text = text;
  }
  async remove() {
    if (this.failRemove) throw new Error('permission denied');
    this.text = undefined;
  }
}

function conversation(id = 'session-1', order = 1, content = '安排一次复习') {
  const first = new Date(Date.UTC(2026, 0, 1, 0, order, 0)).toISOString();
  const last = new Date(Date.UTC(2026, 0, 1, 0, order, 1)).toISOString();
  return {
    summary: { session_id: id, title: content, model_name: 'deepseek-v4-pro', last_message: '已整理',
      message_count: 2, created_at: first, updated_at: last },
    messages: [{ role: 'user', content, created_at: first },
      { role: 'assistant', content: '已整理', created_at: last }]
  };
}

async function setup(driver = new MemoryDriver()) {
  const store = new LocalHistoryStore(driver);
  await store.initialize();
  await store.activate(scopeA, '测试账号');
  return { store, driver };
}

function save(store, item) { return store.save(scopeA, item.summary, item.messages); }

test('account scope normalizes trailing slash and cannot collide through separators', () => {
  assert.equal(historyScope(' http://campus.invalid:8000/// ', 'account-a'), scopeA);
  assert.notEqual(historyScope('https://a/b', 'c'), historyScope('https://a', 'b/c'));
  assert.notEqual(scopeA, scopeB);
  assert.notEqual(scopeA, historyScope('https://campus.invalid:8000', 'account-a'));
  assert.equal(historyScope('http://campus.invalid', ''), '');
});

test('a cold restart restores complete text snapshots and defensive copies only', async () => {
  const { store, driver } = await setup();
  const item = conversation();
  assert.equal(await save(store, item), true);
  const restarted = new LocalHistoryStore(driver);
  await restarted.initialize();
  assert.deepEqual(restarted.info(), { scope: scopeA, displayName: '测试账号', count: 1 });
  assert.deepEqual(restarted.messages(scopeA, item.summary.session_id), item.messages);
  const copy = restarted.messages(scopeA, item.summary.session_id);
  copy[0].content = '外部修改';
  restarted.list(scopeA)[0].title = '外部修改';
  assert.equal(restarted.messages(scopeA, item.summary.session_id)[0].content, item.messages[0].content);
  assert.equal(restarted.list(scopeA)[0].title, item.summary.title);
  assert.deepEqual(restarted.list(scopeB), []);
  assert.equal(restarted.messages(scopeB, item.summary.session_id), undefined);
});

test('same-account activation preserves history; switching accounts removes it durably', async () => {
  const { store, driver } = await setup();
  await save(store, conversation());
  await store.activate(scopeA, '新昵称');
  assert.equal(store.info().count, 1);
  await store.activate(scopeB, '另一个账号');
  assert.equal(store.info().scope, scopeB);
  assert.equal(store.info().count, 0);
  assert.doesNotMatch(driver.text, /安排一次复习|account-a/);
  assert.equal(await save(store, conversation()), false);
});

test('structured credentials, tool traces, actions and extra fields never enter the cache', async () => {
  const { store, driver } = await setup();
  const item = conversation();
  item.summary.access_token = 'private-token';
  item.summary.api_key = 'private-key';
  item.messages[0].tool_traces = [{ raw: 'private-tool-result' }];
  item.messages[1].pending_actions = [{ proposal_id: 'executable-proposal' }];
  assert.equal(await save(store, item), true);
  assert.doesNotMatch(driver.text, /private-token|private-key|private-tool-result|executable-proposal|pending_actions/);
  assert.deepEqual(Object.keys(JSON.parse(driver.text).sessions[0].messages[0]).sort(),
    ['content', 'created_at', 'role']);
});

test('invalid messages reject the entire snapshot rather than silently deleting content', async () => {
  const { store, driver } = await setup();
  const before = driver.text;
  for (const change of [null, { role: 'tool', content: '{}', created_at: new Date().toISOString() },
    { role: 'user', content: 42, created_at: new Date().toISOString() },
    { role: 'assistant', content: '内容', created_at: 'not-a-date' }]) {
    const item = conversation();
    item.messages.push(change);
    assert.equal(await save(store, item), false);
  }
  assert.equal(driver.text, before);
});

test('malformed, future-version and inaccessible files are preserved until explicit clearing', async () => {
  for (const text of ['invalid JSON', 'null', '{"version":999}',
    JSON.stringify({ version: 1, scope: scopeA, displayName: '', sessions: [null], tombstones: [] })]) {
    const driver = new MemoryDriver(text);
    const store = new LocalHistoryStore(driver);
    await assert.rejects(store.initialize());
    await assert.rejects(store.activate(scopeA, '测试账号'));
    assert.equal(driver.writes, 0);
    assert.equal(driver.text, text);
    await store.clear();
    await store.activate(scopeA, '测试账号');
    assert.equal(store.info().count, 0);
  }
  const denied = new MemoryDriver('untouched');
  denied.failRead = true;
  const store = new LocalHistoryStore(denied);
  await assert.rejects(store.initialize());
  await assert.rejects(store.activate(scopeB, '其他账号'));
  assert.equal(denied.text, 'untouched');
  assert.equal(denied.writes, 0);
});

test('failed writes never report durable success or mutate the previous snapshot', async () => {
  const { store, driver } = await setup();
  await save(store, conversation('saved'));
  const before = driver.text;
  driver.failWrite = true;
  assert.equal(await save(store, conversation('new')), false);
  assert.equal(driver.text, before);
  assert.deepEqual(store.list(scopeA).map((item) => item.session_id), ['saved']);
  driver.failRemove = true;
  await assert.rejects(store.clear());
  assert.equal(store.info().scope, '');
  assert.equal(driver.text, before);
});

test('account replacement failure attempts to remove the old account and reports failure', async () => {
  const { store, driver } = await setup();
  await save(store, conversation());
  driver.failWrite = true;
  await assert.rejects(store.activate(scopeB, '其他账号'));
  assert.equal(driver.text, undefined);
  assert.equal(store.info().scope, '');
});

test('clear invalidates an already-running save immediately and wins the final disk state', async () => {
  const { store, driver } = await setup();
  driver.nextWrite = deferred();
  driver.started = deferred();
  const gate = driver.nextWrite;
  const saving = save(store, conversation());
  await driver.started.promise;
  const clearing = store.clear();
  assert.equal(store.info().count, 0);
  assert.deepEqual(store.list(scopeA), []);
  assert.equal(await save(store, conversation('late')), false);
  gate.resolve();
  assert.equal(await saving, false);
  await clearing;
  assert.equal(driver.text, undefined);
});

test('account switching serializes behind writes and cannot admit a previous-scope response', async () => {
  const { store, driver } = await setup();
  const accountEpoch = store.epoch();
  driver.nextWrite = deferred();
  driver.started = deferred();
  const gate = driver.nextWrite;
  const saving = save(store, conversation());
  await driver.started.promise;
  const switching = store.activate(scopeB, '其他账号');
  assert.notEqual(store.epoch(), accountEpoch);
  assert.equal(store.info().scope, '');
  gate.resolve();
  assert.equal(await saving, false);
  await switching;
  assert.equal(JSON.parse(driver.text).scope, scopeB);
  assert.equal(store.info().count, 0);
});

test('remote deletion survives restart and rejects a late response with the same session ID', async () => {
  const { store, driver } = await setup();
  const item = conversation();
  await save(store, item);
  const deleting = store.removeSession(scopeA, item.summary.session_id);
  assert.equal(store.isRemoved(scopeA, item.summary.session_id), true);
  assert.equal(await save(store, item), false);
  await deleting;
  const restarted = new LocalHistoryStore(driver);
  await restarted.initialize();
  assert.equal(restarted.isRemoved(scopeA, item.summary.session_id), true);
  assert.equal(await save(restarted, item), false);
  assert.deepEqual(restarted.list(scopeA), []);
});

test('removing a conversation does not invalidate another request from the same account', async () => {
  const { store } = await setup();
  const accountEpoch = store.epoch();
  const deleting = store.removeSession(scopeA, 'another-session');
  assert.equal(store.epoch(), accountEpoch);
  await deleting;
  assert.equal(store.epoch(), accountEpoch);
  const clearing = store.clear();
  assert.notEqual(store.epoch(), accountEpoch);
  await clearing;
});

test('local-only removal permits a later online download and does not create a remote tombstone', async () => {
  const { store, driver } = await setup();
  const item = conversation();
  await save(store, item);
  await store.removeSession(scopeA, item.summary.session_id, false);
  assert.equal(store.isRemoved(scopeA, item.summary.session_id), false);
  assert.deepEqual(JSON.parse(driver.text).tombstones, []);
  assert.equal(await save(store, item), true);
});

test('a queued same-account activation cannot resurrect an in-flight remote deletion', async () => {
  const { store, driver } = await setup();
  const item = conversation();
  await save(store, item);
  driver.nextWrite = deferred();
  driver.started = deferred();
  const gate = driver.nextWrite;
  const deleting = store.removeSession(scopeA, item.summary.session_id);
  await driver.started.promise;
  const activating = store.activate(scopeA, '新昵称');
  gate.resolve();
  await deleting;
  await activating;
  assert.equal(store.isRemoved(scopeA, item.summary.session_id), true);
  assert.equal(store.info().count, 0);
});

test('retain at most 20 recent whole conversations, refusing an older displaced snapshot', async () => {
  const { store } = await setup();
  for (let i = 1; i <= 21; i++) assert.equal(await save(store, conversation(`session-${i}`, i)), true);
  const ids = store.list(scopeA).map((item) => item.session_id);
  assert.equal(ids.length, 20);
  assert.equal(ids[0], 'session-21');
  assert.equal(ids.includes('session-1'), false);
  assert.equal(await save(store, conversation('older', 0)), false);
  assert.deepEqual(store.list(scopeA).map((item) => item.session_id), ids);
});

test('oversized conversations are refused intact; capacity eviction never truncates messages', async () => {
  const { store, driver } = await setup();
  await save(store, conversation('small'));
  const before = driver.text;
  assert.equal(await save(store, conversation('huge', 2, '中'.repeat(MAX_LOCAL_HISTORY_BYTES))), false);
  assert.equal(driver.text, before);
  for (let i = 2; i <= 5; i++) await save(store, conversation(`large-${i}`, i, '文'.repeat(120000)));
  assert.ok(driver.text.length * 3 <= MAX_LOCAL_HISTORY_BYTES);
  for (const item of store.list(scopeA)) {
    const messages = store.messages(scopeA, item.session_id);
    assert.equal(messages.length, 2);
    if (item.session_id.startsWith('large-')) assert.equal(messages[0].content.length, 120000);
  }
});

test('an older, shorter history read cannot replace a newer complete snapshot', async () => {
  const { store } = await setup();
  const item = conversation();
  await save(store, item);
  assert.equal(await store.save(scopeA, item.summary, item.messages.slice(0, 1)), false);
  assert.equal(store.messages(scopeA, item.summary.session_id).length, 2);
});

test('tombstones are never silently evicted when their own capacity is exhausted', async () => {
  const document = { version: 1, scope: scopeA, displayName: '测试账号', sessions: [], tombstones: [] };
  const available = Math.floor(MAX_LOCAL_HISTORY_BYTES / 3) - JSON.stringify(document).length;
  const count = Math.floor((available + 1) / 515); // 512 chars plus JSON quotes/comma.
  document.tombstones = Array.from({ length: count }, (_, index) => String(index).padStart(12, '0') + 'x'.repeat(500));
  const original = JSON.stringify(document);
  assert.ok(original.length * 3 <= MAX_LOCAL_HISTORY_BYTES);
  const driver = new MemoryDriver(original);
  const store = new LocalHistoryStore(driver);
  await store.initialize();
  await assert.rejects(store.removeSession(scopeA, 'y'.repeat(512)), /容量上限/);
  assert.equal(driver.text, original);
  const restarted = new LocalHistoryStore(driver);
  await restarted.initialize();
  assert.equal(restarted.isRemoved(scopeA, document.tombstones[0]), true);
  assert.equal(restarted.isRemoved(scopeA, document.tombstones[count - 1]), true);
});

// The native adapter itself is also executed, with only the platform FS injected.
// This verifies ordering/error handling, not ArkUI-X compilation or device storage.
const nativeSource = readFileSync(new URL('../entry/src/main/ets/services/LocalHistory.ets', import.meta.url), 'utf8')
  .replace(/^import .*;\r?\n/gm, '').replace(/export /g, '');
const makeNative = new Function('fs', 'LocalHistoryStore', 'MAX_LOCAL_HISTORY_BYTES',
  stripTypeScriptTypes(nativeSource) + '\nreturn { FileHistoryDriver, utf8Length };');

function nativeFixture() {
  const files = new Map();
  const handles = new Map();
  const calls = [];
  const path = '/app/private/campusflow-local-history-v1.json';
  let nextFd = 1;
  const fs = {
    OpenMode: { WRITE_ONLY: 1, CREATE: 2, TRUNC: 4 },
    readError: undefined, shortWrite: false, renameError: false,
    async stat(name) {
      if (this.readError) throw { code: this.readError };
      if (!files.has(name)) throw { code: 13900002 };
      return { size: Buffer.byteLength(files.get(name)) };
    },
    async readText(name) { return files.get(name); },
    async open(name, flags) {
      calls.push('open');
      assert.equal(flags, 7);
      const fd = nextFd++;
      files.set(name, ''); handles.set(fd, name);
      return { fd };
    },
    async write(fd, value) {
      calls.push('write');
      files.set(handles.get(fd), value);
      return Buffer.byteLength(value) - (this.shortWrite ? 1 : 0);
    },
    async fsync() { calls.push('fsync'); },
    async close(file) { calls.push('close'); handles.delete(file.fd); },
    async rename(from, to) {
      calls.push('rename');
      if (this.renameError) throw { code: 13900028 };
      files.set(to, files.get(from)); files.delete(from);
    },
    async unlink(name) {
      calls.push('unlink');
      if (!files.delete(name)) throw { code: 13900002 };
    }
  };
  const { FileHistoryDriver, utf8Length } = makeNative(fs, LocalHistoryStore, MAX_LOCAL_HISTORY_BYTES);
  const driver = new FileHistoryDriver();
  driver.configure('/app/private');
  return { driver, fs, files, path, calls, utf8Length };
}

test('native adapter treats only a missing file as empty and preserves other read failures', async () => {
  const { driver, fs, files, path } = nativeFixture();
  assert.equal(await driver.read(), undefined);
  fs.readError = 13900013;
  await assert.rejects(driver.read());
  fs.readError = undefined;
  files.set(path, 'x'.repeat(MAX_LOCAL_HISTORY_BYTES + 1));
  await assert.rejects(driver.read());
});

test('native write syncs/closes complete UTF-8 before replacing and preserves originals on short writes', async () => {
  const { driver, fs, files, path, calls, utf8Length } = nativeFixture();
  const text = JSON.stringify({ message: '校园 😀 é \u0000' });
  assert.equal(utf8Length(text), Buffer.byteLength(text));
  await driver.write(text);
  assert.equal(files.get(path), text);
  assert.deepEqual(calls.slice(0, 5), ['open', 'write', 'fsync', 'close', 'rename']);
  fs.shortWrite = true;
  await assert.rejects(driver.write('replacement'));
  assert.equal(files.get(path), text);
  assert.equal(files.has(`${path}.tmp`), false);
  fs.shortWrite = false;
  fs.renameError = true;
  await assert.rejects(driver.write('replacement'));
  assert.equal(files.get(path), text);
  await driver.remove();
  assert.equal(files.size, 0);
});

test('production file adapter round-trips on real temporary files via a Node FS shim', async () => {
  const directory = await nodeFs.mkdtemp(join(tmpdir(), 'campusflow-history-'));
  const handles = new Map();
  const shim = {
    OpenMode: { WRITE_ONLY: 1, CREATE: 2, TRUNC: 4 },
    shortWrite: false, renameError: false,
    async stat(path) {
      try { return await nodeFs.stat(path); }
      catch (error) { throw { code: error.code === 'ENOENT' ? 13900002 : 13900013 }; }
    },
    async readText(path) { return nodeFs.readFile(path, 'utf8'); },
    async open(path, flags) {
      assert.equal(flags, 7);
      const handle = await nodeFs.open(path, 'w');
      handles.set(handle.fd, handle);
      return { fd: handle.fd };
    },
    async write(fd, text) {
      const bytes = Buffer.from(text, 'utf8');
      const length = bytes.length - (this.shortWrite ? 1 : 0);
      return (await handles.get(fd).write(bytes, 0, length, null)).bytesWritten;
    },
    async fsync(fd) { await handles.get(fd).sync(); },
    async close(file) {
      const handle = handles.get(file.fd);
      await handle.close(); handles.delete(file.fd);
    },
    async rename(from, to) {
      if (this.renameError) throw { code: 13900013 };
      await nodeFs.rename(from, to);
    },
    async unlink(path) {
      try { await nodeFs.unlink(path); }
      catch (error) { throw { code: error.code === 'ENOENT' ? 13900002 : 13900013 }; }
    }
  };
  try {
    const { FileHistoryDriver } = makeNative(shim, LocalHistoryStore, MAX_LOCAL_HISTORY_BYTES);
    const driver = new FileHistoryDriver();
    driver.configure(directory);
    assert.equal(await driver.read(), undefined);
    const store = new LocalHistoryStore(driver);
    await store.initialize();
    await store.activate(scopeA, '临时目录测试');
    const item = conversation('native-shim', 1, '杭州校园 😀 中文换行\n第二行');
    assert.equal(await save(store, item), true);
    const restarted = new LocalHistoryStore(driver);
    await restarted.initialize();
    assert.deepEqual(restarted.messages(scopeA, 'native-shim'), item.messages);
    const path = join(directory, 'campusflow-local-history-v1.json');
    const original = await nodeFs.readFile(path, 'utf8');
    shim.shortWrite = true;
    assert.equal(await save(store, conversation('short-write')), false);
    assert.equal(await nodeFs.readFile(path, 'utf8'), original);
    shim.shortWrite = false;
    shim.renameError = true;
    assert.equal(await save(store, conversation('rename-failure')), false);
    assert.equal(await nodeFs.readFile(path, 'utf8'), original);
    assert.deepEqual(await nodeFs.readdir(directory), ['campusflow-local-history-v1.json']);
    await store.clear();
    assert.deepEqual(await nodeFs.readdir(directory), []);
  } finally {
    for (const handle of handles.values()) await handle.close().catch(() => {});
    await nodeFs.rm(directory, { recursive: true, force: true });
  }
});
