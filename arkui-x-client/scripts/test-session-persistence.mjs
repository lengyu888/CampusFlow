import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFileSync } from 'node:fs';
import * as fs from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { stripTypeScriptTypes } from 'node:module';

const read = file => readFileSync(new URL(`../entry/src/main/ets/${file}.ets`, import.meta.url), 'utf8');
const clean = file => stripTypeScriptTypes(read(file).replace(/^import [^\n]+;\r?\n/gm, '').replace(/^export /gm, ''));
const api = new Function(clean('utils/SessionPersistence') + '\nreturn { SessionPersistence, SessionStorageError, normalizeServiceBaseUrl, parseSavedSession, MAX_SAVED_SESSION_BYTES };')();
const { SessionPersistence, SessionStorageError, normalizeServiceBaseUrl, parseSavedSession, MAX_SAVED_SESSION_BYTES } = api;
const record = (extra = {}) => ({ schemaVersion: 1, baseUrl: 'http://127.0.0.1:8000', userId: 'synthetic-user',
  accessToken: 'synthetic-session-token-for-unit-tests', savedAt: 1793145600000, ...extra });
const tick = () => new Promise(resolve => setImmediate(resolve));

function persistenceFixture(options = {}) {
  let raw = options.raw ?? null, enabled = options.enabled ?? false;
  const calls = [];
  const vault = {
    async read() { calls.push('read'); if (options.failRead) throw Error('sensitive native details'); return raw; },
    async write(value) { calls.push('write'); if (options.failWrite) throw Error('native write'); raw = value; },
    async remove() { calls.push('remove'); if (options.failRemove) throw Error('native remove'); raw = null; }
  };
  const barrier = {
    async readEnabled() { calls.push('readEnabled'); if (options.failBarrierRead) throw Error('barrier'); return enabled; },
    async writeEnabled(value) { calls.push(`enabled:${value}`); if (options.failBarrierWrite) throw Error('barrier'); enabled = value; }
  };
  return { store: new SessionPersistence(vault, barrier), vault, barrier, calls, raw: () => raw, enabled: () => enabled };
}

test('service normalization binds scheme, host, port and path while accepting development loopback', () => {
  for (const [input, expected] of [
    [' HTTP://LOCALHOST:080/ ', 'http://localhost'], ['https://CampusFlow.EXAMPLE:443/mobile/', 'https://campusflow.example/mobile'],
    ['http://127.0.0.1:8001/', 'http://127.0.0.1:8001'], ['http://192.168.1.100:8000', 'http://192.168.1.100:8000'],
    ['http://[::1]:8000/', 'http://[::1]:8000'], ['https://[2001:DB8::1]/proxy', 'https://[2001:db8::1]/proxy']
  ]) { assert.equal(normalizeServiceBaseUrl(input), expected); }
  assert.notEqual(normalizeServiceBaseUrl('http://localhost:8000'), normalizeServiceBaseUrl('http://localhost:8001'));
  assert.notEqual(normalizeServiceBaseUrl('https://host/one'), normalizeServiceBaseUrl('https://host/two'));
});

test('service normalization rejects credentials, headers, queries, fragments and ambiguous URL forms', () => {
  for (const value of ['', 'file:///tmp', 'javascript:alert(1)', 'http://u:p@host', 'http://host?next=http://evil',
    'http://host/#x', 'http://host\\@evil', 'http://host/../other', 'http://host/%2e%2e', 'http://host/a//b',
    'http://host:0', 'http://host:65536', 'http://127.1', 'http://0177.0.0.1', 'http://0x7f000001',
    'http://256.0.0.1', 'http://host\nHeader: value', 'http://[:::1]', 'http://[1:2:3:4:5:6:7:8:9]',
    'http://.host', 'http://host.', 'http://bad_host', 'http://host/a b', null, 42]) {
    assert.equal(normalizeServiceBaseUrl(value), null, String(value));
  }
});

test('saved-session parser accepts only canonical bounded candidates without profile or password fields', () => {
  assert.deepEqual(parseSavedSession(JSON.stringify(record())), record());
  for (const extra of [{ schemaVersion: 2 }, { userId: '../x' }, { savedAt: NaN }, { savedAt: 0 },
    { baseUrl: 'HTTP://HOST/' }, { accessToken: 'short' }, { accessToken: 'header\r\ninjection' },
    { password: 'not-allowed' }, { user: { email: 'private@example.invalid' } }, { baseUrl: 'http://host/' + 'x'.repeat(1000) }]) {
    assert.equal(parseSavedSession(JSON.stringify(record(extra))), null);
  }
  for (const raw of ['null', '[]', '{}', 'invalid', JSON.stringify('text'), 'x'.repeat(1025), '中文']) {
    assert.equal(parseSavedSession(raw), null);
  }
});

test('missing enable marker never queries secure storage and does not invent a remembered user', async () => {
  const f = persistenceFixture({ raw: JSON.stringify(record()) });
  assert.equal(await f.store.read(), null);
  assert.deepEqual(f.calls, ['readEnabled']);
});

test('save disables recovery before replacing secure data and re-enables only after durable success', async () => {
  const f = persistenceFixture(); await f.store.save(record());
  assert.deepEqual(f.calls, ['enabled:false', 'write', 'enabled:true']);
  assert.equal(f.enabled(), true);
  assert.deepEqual(await new SessionPersistence(f.vault, f.barrier).read(), record());
});

test('save snapshots input so caller mutation cannot retarget an already queued token', async () => {
  const f = persistenceFixture(); const value = record(); const pending = f.store.save(value);
  value.baseUrl = 'https://other.example'; value.userId = 'other-user'; value.accessToken = 'other-synthetic-token';
  await pending; assert.deepEqual(await f.store.read(), record());
});

test('invalid record fails before any barrier or vault write', async () => {
  const f = persistenceFixture(); await assert.rejects(f.store.save(record({ password: 'forbidden' })), { code: 'SESSION_INVALID' });
  assert.deepEqual(f.calls, []);
});

test('failed secure replacement leaves a durable recovery veto, including a subsequent cold store', async () => {
  const f = persistenceFixture({ raw: JSON.stringify(record()), enabled: true, failWrite: true });
  await assert.rejects(f.store.save(record({ userId: 'new-user' })), { code: 'SESSION_SAVE_FAILED' });
  assert.equal(f.enabled(), false);
  assert.equal(JSON.parse(f.raw()).userId, 'synthetic-user');
  assert.equal(await f.store.read(), null);
  assert.equal(await new SessionPersistence(f.vault, f.barrier).read(), null);
});

test('failed logout secure removal is reported but durable veto prevents cold restoration of leftover token', async () => {
  const f = persistenceFixture({ raw: JSON.stringify(record()), enabled: true, failRemove: true });
  await assert.rejects(f.store.clear(), { code: 'SESSION_REMOVAL_PENDING' });
  assert.equal(f.enabled(), false); assert.notEqual(f.raw(), null);
  assert.equal(await new SessionPersistence(f.vault, f.barrier).read(), null);
  assert.equal(await f.store.read(), null);
});

test('barrier failure differs from safe removal pending and cannot claim a durable logout', async () => {
  const f = persistenceFixture({ raw: JSON.stringify(record()), enabled: true, failBarrierWrite: true });
  await assert.rejects(f.store.clear(), { code: 'SESSION_UNAVAILABLE' });
  assert.equal(f.enabled(), true); assert.equal(f.calls.includes('remove'), false);
  await assert.rejects(f.store.read(), { code: 'SESSION_UNAVAILABLE' });
  await assert.rejects(f.store.save(record({ userId: 'other-user' })), { code: 'SESSION_UNAVAILABLE' });
  assert.equal(f.calls.includes('write'), false);
});

test('unsupported platform may disable remembering without blocking ordinary manual logout', async () => {
  const f = persistenceFixture();
  f.vault.remove = async () => { throw new SessionStorageError('SESSION_UNSUPPORTED'); };
  f.vault.write = async () => { throw new SessionStorageError('SESSION_UNSUPPORTED'); };
  await f.store.clear(); assert.equal(await f.store.read(), null);
  await assert.rejects(f.store.save(record()), { code: 'SESSION_UNSUPPORTED' });
  assert.equal(f.enabled(), false); assert.equal(await f.store.read(), null);
});

test('clear invalidates an already pending secure read before it can return a saved candidate', async () => {
  const f = persistenceFixture({ raw: JSON.stringify(record()), enabled: true });
  let release; f.vault.read = () => new Promise(resolve => { release = () => resolve(JSON.stringify(record())); });
  const pendingRead = f.store.read(); await tick(); assert.equal(typeof release, 'function');
  const clear = f.store.clear(); release(); assert.equal(await pendingRead, null); await clear;
  assert.equal(await f.store.read(), null);
});

test('clear cancels queued saves and reads instead of allowing a late write to re-enable recovery', async () => {
  const f = persistenceFixture(); const save = f.store.save(record()); const read = f.store.read(); const clear = f.store.clear();
  await assert.rejects(save, { code: 'SESSION_STALE' }); assert.equal(await read, null); await clear;
  assert.deepEqual(f.calls, ['enabled:false', 'remove']); assert.equal(await f.store.read(), null);
});

test('save in flight cannot re-enable after a newer clear, and a later explicit save can recover', async () => {
  const f = persistenceFixture(); let release;
  const originalWrite = f.vault.write; f.vault.write = value => new Promise(resolve => { release = async () => { await originalWrite(value); resolve(); }; });
  const save = f.store.save(record()); await tick(); const clear = f.store.clear(); await release();
  await assert.rejects(save, { code: 'SESSION_STALE' }); await clear; assert.equal(f.enabled(), false);
  f.vault.write = originalWrite; await f.store.save(record({ userId: 'second-user' }));
  assert.equal((await f.store.read()).userId, 'second-user');
});

test('storage unavailable and invalid secure payload remain errors rather than absence or a valid sign-in', async () => {
  const failed = persistenceFixture({ enabled: true, failRead: true });
  await assert.rejects(failed.store.read(), error => error.code === 'SESSION_UNAVAILABLE' && !error.message.includes('sensitive'));
  await assert.rejects(persistenceFixture({ enabled: true, raw: '{}' }).store.read(), { code: 'SESSION_INVALID' });
  await assert.rejects(persistenceFixture({ enabled: true, failBarrierRead: true }).store.read(), { code: 'SESSION_UNAVAILABLE' });
  assert.equal(await persistenceFixture({ enabled: true }).store.read(), null);
});

function assetFixture() {
  const Tag = { ALIAS: 1, SECRET: 2, ACCESSIBILITY: 3, AUTH_TYPE: 4, SYNC_TYPE: 5, CONFLICT_RESOLUTION: 6, RETURN_TYPE: 7 };
  let saved = null, queryFailure = 0, removeFailure = 0; const calls = [];
  const asset = { Tag, Accessibility: { DEVICE_UNLOCKED: 2 }, AuthType: { NONE: 0 }, SyncType: { NEVER: 0 },
    ConflictResolution: { OVERWRITE: 0 }, ReturnType: { ALL: 0 },
    async add(attributes) { calls.push(['add', attributes]); saved = new Map(attributes); },
    async query(query) { calls.push(['query', query]); if (queryFailure) throw { code: queryFailure }; if (saved === null) throw { code: 24000002 }; return [new Map(saved)]; },
    async remove(query) { calls.push(['remove', query]); if (removeFailure) throw { code: removeFailure }; if (saved === null) throw { code: 24000002 }; saved = null; }
  };
  const Driver = new Function('asset', 'SessionStorageError', 'MAX_SAVED_SESSION_BYTES', clean('services/HarmonySessionVault') + '\nreturn HarmonySessionVault;')(asset, SessionStorageError, MAX_SAVED_SESSION_BYTES);
  return { driver: new Driver(), asset, calls, setQueryFailure(value) { queryFailure = value; },
    setRemoveFailure(value) { removeFailure = value; }, setSecret(value) { saved = new Map([[Tag.SECRET, value]]); } };
}

test('actual Harmony adapter uses AssetMap, a fixed alias, device-unlocked access and never-sync encrypted SECRET only', async () => {
  const f = assetFixture(), text = JSON.stringify(record()); await f.driver.write(text);
  const attrs = f.calls[0][1]; assert.ok(attrs instanceof Map);
  assert.equal(Buffer.from(attrs.get(f.asset.Tag.ALIAS)).toString('ascii'), 'campusflow-session-v1');
  assert.equal(Buffer.from(attrs.get(f.asset.Tag.SECRET)).toString('ascii'), text);
  for (const [tag, value] of [[f.asset.Tag.ACCESSIBILITY, 2], [f.asset.Tag.AUTH_TYPE, 0], [f.asset.Tag.SYNC_TYPE, 0], [f.asset.Tag.CONFLICT_RESOLUTION, 0]]) {
    assert.equal(attrs.get(tag), value);
  }
  assert.equal(attrs.size, 6, 'no custom plaintext labels, persistent-uninstall or cross-device sync tags');
  assert.equal(await f.driver.read(), text); await f.driver.write(JSON.stringify(record({ userId: 'second-user' })));
  assert.equal(JSON.parse(await f.driver.read()).userId, 'second-user'); await f.driver.remove(); assert.equal(await f.driver.read(), null);
});

test('actual Harmony adapter distinguishes asset-not-found from lock/service failure without leaking raw errors', async () => {
  const f = assetFixture(); assert.equal(await f.driver.read(), null);
  for (const code of [24000001, 24000004, 24000005, 24000007, 24000017]) {
    f.setQueryFailure(code); await assert.rejects(f.driver.read(), { code: 'SESSION_UNAVAILABLE' });
  }
  f.setQueryFailure(0); await f.driver.remove(); f.setRemoveFailure(24000008);
  await assert.rejects(f.driver.remove(), { code: 'SESSION_UNAVAILABLE' });
});

test('actual Harmony adapter bounds secret bytes and rejects non-byte or non-ASCII return values', async () => {
  const f = assetFixture();
  for (const value of ['', 'x'.repeat(1025), '中文']) { await assert.rejects(f.driver.write(value), { code: 'SESSION_INVALID' }); }
  assert.equal(f.calls.length, 0);
  for (const value of ['plain', new Uint8Array(), new Uint8Array([255]), new Uint8Array(1025)]) {
    f.setSecret(value); await assert.rejects(f.driver.read(), { code: 'SESSION_INVALID' });
  }
});

async function barrierFixture() {
  const directory = await fs.mkdtemp(path.join(tmpdir(), 'campusflow-session-')), handles = new Map(); let failRename = false;
  const wrap = async work => { try { return await work(); } catch (error) { if (error.code === 'ENOENT') throw { code: 13900002 }; throw error; } };
  const bridge = { OpenMode: { WRITE_ONLY: 1, CREATE: 2, TRUNC: 4 }, stat: p => wrap(() => fs.stat(p)), readText: p => wrap(() => fs.readFile(p, 'utf8')),
    open: async p => { const file = await fs.open(p, 'w'); handles.set(file.fd, file); return { fd: file.fd }; },
    write: async (fd, text) => (await handles.get(fd).write(Buffer.from(text))).bytesWritten, fsync: fd => handles.get(fd).sync(),
    close: async file => { await handles.get(file.fd).close(); handles.delete(file.fd); },
    rename: async (a, b) => { if (failRename) throw Error('rename'); await fs.rename(a, b); }, unlink: p => wrap(() => fs.unlink(p)) };
  const classes = new Function('fs', 'deviceInfo', 'SessionPersistence', 'SessionStorageError', clean('services/LocalSession') + '\nreturn { FileSessionBarrier, PlatformSessionVault };')(
    bridge, { osFullName: 'unsupported-test-host' }, SessionPersistence, SessionStorageError);
  const driver = new classes.FileSessionBarrier(); driver.configure(directory);
  return { driver, classes, directory, setFailure(value) { failRename = value; }, cleanup: () => fs.rm(directory, { recursive: true, force: true }) };
}

test('actual file barrier stores only two non-secret fields with durable atomic replacement', async () => {
  const f = await barrierFixture(); try {
    assert.equal(await f.driver.readEnabled(), false); await f.driver.writeEnabled(true);
    const target = path.join(f.directory, 'campusflow-session-enabled-v1.json');
    assert.deepEqual(JSON.parse(await fs.readFile(target, 'utf8')), { schemaVersion: 1, enabled: true });
    f.setFailure(true); await assert.rejects(f.driver.writeEnabled(false), { code: 'SESSION_UNAVAILABLE' });
    assert.equal(await f.driver.readEnabled(), true); assert.deepEqual(await fs.readdir(f.directory), [path.basename(target)]);
    f.setFailure(false); await f.driver.writeEnabled(false); assert.equal(await f.driver.readEnabled(), false);
  } finally { await f.cleanup(); }
});

test('actual file barrier fails closed on corrupt, oversized or extra-field state', async () => {
  const f = await barrierFixture(); try {
    const target = path.join(f.directory, 'campusflow-session-enabled-v1.json');
    for (const text of ['null', '{}', 'x'.repeat(129), JSON.stringify({ schemaVersion: 1, enabled: true, token: 'forbidden' })]) {
      await fs.writeFile(target, text); await assert.rejects(f.driver.readEnabled(), { code: 'SESSION_UNAVAILABLE' });
    }
  } finally { await f.cleanup(); }
});

test('unsupported native platform never silently falls back to plaintext session persistence', async () => {
  const f = await barrierFixture(); try {
    const platform = new f.classes.PlatformSessionVault();
    await assert.rejects(platform.read(), { code: 'SESSION_UNSUPPORTED' });
    await assert.rejects(platform.write(JSON.stringify(record())), { code: 'SESSION_UNSUPPORTED' });
    await assert.rejects(platform.remove(), { code: 'SESSION_UNSUPPORTED' });
    assert.deepEqual(await fs.readdir(f.directory), []);
  } finally { await f.cleanup(); }
});
