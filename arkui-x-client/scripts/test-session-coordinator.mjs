import assert from 'node:assert/strict';
import test from 'node:test';
import { sessionHelpers } from './helpers/session-fixture.mjs';

const { SessionCoordinator, SessionStorageError } = sessionHelpers;
const record = { schemaVersion: 1, baseUrl: 'http://127.0.0.1:8001', userId: 'user-a',
  accessToken: 'synthetic-token-1234567890', savedAt: 1 };
const user = { user_id: 'user-a', email: 'test@example.invalid', display_name: '测试', role: 'user',
  school: null, campus: null, semester: null, api_key_hint: null, api_key_configured: false, onboarding_complete: true };
const online = { kind: 'online', statusCode: 200, elapsedMs: 1 };
function deferred() { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; }
function fixture(overrides = {}) {
  const calls = [];
  const vault = { async read() { calls.push(['read']); return record; },
    async clear() { calls.push(['clear']); }, async save(value) { calls.push(['save', value]); }, ...overrides.vault };
  const gateway = (base, token) => ({
    async probeHealth() { calls.push(['probe', base, token]); return overrides.probe ? overrides.probe() : online; },
    async verifySession() { calls.push(['verify', base, token]); return overrides.verify ? overrides.verify() : user; }
  });
  return { coordinator: new SessionCoordinator(vault, gateway), calls };
}

test('restore reads a candidate, checks the original service anonymously and verifies the same user before publishing', async () => {
  const f = fixture(); const restored = await f.coordinator.restore();
  assert.equal(restored.phase, 'ready'); assert.equal(restored.baseUrl, record.baseUrl);
  assert.deepEqual(restored.auth, { user, access_token: record.accessToken, token_type: 'bearer' });
  assert.deepEqual(f.calls, [['read'], ['probe', record.baseUrl, ''], ['verify', record.baseUrl, record.accessToken]]);
});

test('empty or unreadable secure storage never sends a token or publishes an authenticated user', async () => {
  for (const read of [async () => null, async () => { throw Error('PRIVATE_STORAGE_PATH'); }]) {
    const f = fixture({ vault: { read } }); const state = await f.coordinator.restore();
    assert.equal(state.auth, null); assert.deepEqual(f.calls, []);
    assert.doesNotMatch(state.message, /PRIVATE_STORAGE_PATH/);
  }
});

test('wrong service and unreachable health checks retain the candidate and never send its token', async () => {
  for (const kind of ['wrong_service', 'network_unreachable', 'http_error', 'invalid_url']) {
    const f = fixture({ probe: () => ({ ...online, kind }) }); const state = await f.coordinator.restore();
    assert.equal(state.auth, null); assert.equal(f.calls.some(call => call[0] === 'verify' || call[0] === 'clear'), false);
  }
});

test('expired or revoked sessions clear saved credentials, without accepting cached user metadata', async () => {
  for (const statusCode of [401, 403]) {
    const f = fixture({ verify: () => { throw { statusCode, message: 'PRIVATE_RESPONSE' }; } });
    const state = await f.coordinator.restore(); assert.equal(state.phase, 'expired'); assert.equal(state.auth, null);
    assert.equal(f.calls.at(-1)[0], 'clear'); assert.doesNotMatch(state.message, /PRIVATE_RESPONSE/);
  }
});

test('network failure during session verification preserves the candidate for an explicit retry', async () => {
  const f = fixture({ verify: () => { throw { statusCode: 0 }; } }); const state = await f.coordinator.restore();
  assert.equal(state.phase, 'offline'); assert.equal(state.auth, null); assert.equal(f.calls.some(c => c[0] === 'clear'), false);
});

test('mismatched account or malformed profile cannot restore access', async () => {
  for (const value of [{ ...user, user_id: 'user-b' }, { ...user, role: 'root' }, { ...user, onboarding_complete: undefined }, null]) {
    const f = fixture({ verify: () => value }); assert.equal((await f.coordinator.restore()).auth, null);
  }
});

test('service edit or logout cancels delayed successful verification', async () => {
  const wait = deferred(); const f = fixture({ verify: () => wait.promise });
  const pending = f.coordinator.restore(); await new Promise(resolve => setImmediate(resolve));
  f.coordinator.cancel(); wait.resolve(user); assert.equal((await pending).phase, 'cancelled');
});

test('a late 401 from an earlier restore cannot clear a newer manual login', async () => {
  const wait = deferred(); const f = fixture({ verify: () => wait.promise });
  const pending = f.coordinator.restore(); await new Promise(resolve => setImmediate(resolve));
  await f.coordinator.remember(record.baseUrl, { user, access_token: record.accessToken }, true);
  const clears = f.calls.filter(c => c[0] === 'clear').length;
  wait.reject({ statusCode: 401 }); assert.equal((await pending).phase, 'cancelled');
  assert.equal(f.calls.filter(c => c[0] === 'clear').length, clears);
});

test('manual remember and opt-out always disable old persistence before saving a new account', async () => {
  for (const enabled of [false, true]) {
    const f = fixture(); await f.coordinator.remember(record.baseUrl, { user, access_token: record.accessToken }, enabled);
    assert.equal(f.calls[0][0], 'clear'); assert.equal(f.calls.filter(c => c[0] === 'save').length, Number(enabled));
    if (enabled) { assert.equal(f.calls[1][1].baseUrl, record.baseUrl); assert.equal(f.calls[1][1].userId, user.user_id); }
  }
});

test('secure save failure after durable disable permits current login, but barrier failure cannot claim persistence was disabled', async () => {
  const f = fixture({ vault: { async save() { throw new SessionStorageError('SESSION_SAVE_FAILED'); } } });
  assert.match(await f.coordinator.remember(record.baseUrl, { user, access_token: record.accessToken }, true), /未|不可用/);
  const broken = fixture({ vault: { async clear() { throw new SessionStorageError(); } } });
  await assert.rejects(broken.coordinator.remember(record.baseUrl, { user, access_token: record.accessToken }, false), SessionStorageError);
  assert.equal(broken.calls.some(c => c[0] === 'save'), false);
});

test('durable logout veto permits safe manual opt-out even if asset physical removal is pending', async () => {
  const f = fixture({ vault: { async clear() { throw new SessionStorageError('SESSION_REMOVAL_PENDING'); } } });
  assert.match(await f.coordinator.remember(record.baseUrl, { user, access_token: record.accessToken }, false), /未启用/);
});
