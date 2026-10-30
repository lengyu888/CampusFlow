import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';

const read = file => readFileSync(new URL(`../entry/src/main/ets/${file}.ets`, import.meta.url), 'utf8');
const clean = source => stripTypeScriptTypes(source.replace(/^import[\s\S]*?;\r?\n/gm, '').replace(/^export /gm, ''));
const helperPath = new URL('../entry/src/main/ets/utils/ConnectionCheck.ets', import.meta.url);
const helpers = existsSync(helperPath) ? new Function(clean(read('utils/ConnectionCheck')) +
  '\nreturn { classifyHealthProbe, ConnectionCheckController };')() : {};
const sessionPath = new URL('../entry/src/main/ets/utils/SessionPersistence.ets', import.meta.url);
const normalizeServiceBaseUrl = existsSync(sessionPath) ? new Function(clean(read('utils/SessionPersistence')) +
  '\nreturn normalizeServiceBaseUrl;')() : undefined;
const errorSource = clean(read('utils/AgentFeedback'));
const { CampusFlowRequestError, localRequestFailure, requestFailure } = new Function(errorSource +
  '\nreturn { CampusFlowRequestError, localRequestFailure, requestFailure };')();
const Api = new Function('http', 'CampusFlowRequestError', 'localRequestFailure', 'requestFailure',
  'normalizeServiceBaseUrl', 'classifyHealthProbe', clean(read('services/CampusFlowApi')) + '\nreturn CampusFlowApi;');
const health = { status: 'ok', api_key_mode: 'encrypted_account', supported_models: ['deepseek-v4-pro'] };

function makeApi(reply, base = 'http://fixture.invalid:8001', token = 'test-only-session') {
  const calls = []; let destroyed = 0;
  const http = { RequestMethod: { GET: 'GET' }, HttpDataType: { STRING: 'STRING' },
    createHttp: () => ({ request: async (url, options) => { calls.push({ url, options }); return reply(url, options); },
      destroy: () => { destroyed++; } }) };
  const Class = Api(http, CampusFlowRequestError, localRequestFailure, requestFailure,
    normalizeServiceBaseUrl, helpers.classifyHealthProbe);
  return { api: new Class(base, token), calls, destroyed: () => destroyed };
}

test('real API health probe is unauthenticated, bounded and refuses redirects even when constructed with a token', async () => {
  const f = makeApi(() => ({ responseCode: 200, result: JSON.stringify(health) }));
  const result = await f.api.probeHealth();
  assert.equal(result.kind, 'online'); assert.equal(result.statusCode, 200);
  assert.equal(f.calls[0].url, 'http://fixture.invalid:8001/health');
  const options = f.calls[0].options;
  assert.equal(options.header.Authorization, undefined);
  assert.equal(options.extraData, undefined);
  assert.equal(options.maxRedirects, 0); assert.equal(options.usingCache, false);
  assert.ok(options.connectTimeout <= 5000 && options.readTimeout <= 5000);
  assert.ok(options.maxLimit <= 16384); assert.equal(f.destroyed(), 1);
});

test('real API probe does not expose arbitrary response bodies or confuse another service with CampusFlow', async () => {
  const body = '<html>private diagnostic api-key-test-only</html>';
  for (const responseCode of [200, 302, 401, 503]) {
    const f = makeApi(() => ({ responseCode, result: body }));
    const result = await f.api.probeHealth();
    assert.equal(result.kind, responseCode === 200 || responseCode === 302 ? 'wrong_service' : 'http_error');
    assert.equal(JSON.stringify(result).includes('private diagnostic'), false);
    assert.equal(f.destroyed(), 1);
  }
});

test('real API session verification remains bound to its original service and preserves typed expiry without body disclosure', async () => {
  const f = makeApi(() => ({ responseCode: 401, result: '{"detail":"private-diagnostic"}' }));
  await assert.rejects(f.api.verifySession(), error => error instanceof CampusFlowRequestError &&
    error.statusCode === 401 && !error.message.includes('private-diagnostic'));
  assert.equal(f.calls[0].url, 'http://fixture.invalid:8001/api/v1/me');
  const options = f.calls[0].options;
  assert.equal(options.header.Authorization, 'Bearer test-only-session');
  assert.equal(options.maxRedirects, 0); assert.equal(options.maxLimit, 65536);
  assert.ok(options.connectTimeout <= 5000 && options.readTimeout <= 5000);
  assert.equal(f.destroyed(), 1);
});

test('real API probe classifies transport failure without claiming the backend or mapping is definitively broken', async () => {
  const f = makeApi(() => { throw new Error('private transport details'); });
  const result = await f.api.probeHealth();
  assert.equal(result.kind, 'network_unreachable'); assert.equal(result.statusCode, 0);
  assert.equal(JSON.stringify(result).includes('private transport details'), false);
  assert.equal(f.destroyed(), 1);
});

test('invalid or credential-bearing service addresses fail before creating a native request', async () => {
  for (const base of ['ftp://fixture.invalid', 'http://a:b@fixture.invalid', 'http://fixture.invalid?token=private',
    'http://fixture.invalid/#private', '', 'http://fixture.invalid/../api']) {
    const f = makeApi(() => { throw new Error('must not request'); }, base);
    assert.equal((await f.api.probeHealth()).kind, 'invalid_url');
    assert.equal(f.calls.length, 0); assert.equal(f.destroyed(), 0);
    await assert.rejects(f.api.verifySession(), error => error.code === 'INVALID_SERVICE_URL');
    assert.equal(f.calls.length, 0);
  }
});

test('health recognition rejects malformed, large or unrelated 2xx responses and keeps no response data', () => {
  for (const value of [null, [], {}, { status: 'ok' }, { ...health, api_key_mode: 'plaintext' },
    { ...health, supported_models: [null] }, { ...health, supported_models: ['private\nvalue'] },
    { ...health, supported_models: Array.from({ length: 101 }, () => 'test-model') }]) {
    const result = helpers.classifyHealthProbe(200, JSON.stringify(value), 3.4);
    assert.deepEqual(result, { kind: 'wrong_service', statusCode: 200, elapsedMs: 3 });
  }
  assert.equal(helpers.classifyHealthProbe(200, 'x'.repeat(16385), 0).kind, 'wrong_service');
  assert.equal(helpers.classifyHealthProbe(204, '', 0).kind, 'wrong_service');
  assert.equal(helpers.classifyHealthProbe(200, JSON.stringify(health), Number.NaN).elapsedMs, 0);
});

test('redirect refusal has an explicit safe result and does not attempt another request', async () => {
  const f = makeApi(() => { throw Object.assign(new Error('private redirected URL'), { code: 2300047 }); });
  assert.equal((await f.api.probeHealth()).kind, 'wrong_service');
  assert.equal(f.calls.length, 1); assert.equal(f.destroyed(), 1);
});

test('session verification returns the original profile and rejects missing tokens or malformed JSON safely', async () => {
  const profile = { user_id: 'test-user', display_name: '验收用户' };
  const valid = makeApi(() => ({ responseCode: 200, result: JSON.stringify(profile) }));
  assert.deepEqual(await valid.api.verifySession(), profile); assert.equal(valid.destroyed(), 1);
  const empty = makeApi(() => { throw new Error('must not request'); }, undefined, '');
  await assert.rejects(empty.api.verifySession(), error => error.statusCode === 401);
  assert.equal(empty.calls.length, 0);
  const malformed = makeApi(() => ({ responseCode: 200, result: 'private not JSON' }));
  await assert.rejects(malformed.api.verifySession(), error => error.code === 'INVALID_RESPONSE' && !error.message.includes('private'));
  assert.equal(malformed.destroyed(), 1);
});

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

test('real connection controller ignores the old service response after editing its address', async () => {
  const old = deferred(); const states = []; const queried = [];
  const controller = new helpers.ConnectionCheckController(base => ({ probeHealth: () => {
    queried.push(base); return base.endsWith('8000') ? old.promise : Promise.resolve({ kind: 'online', statusCode: 200, elapsedMs: 4 });
  } }), value => states.push(value), () => 123);
  controller.configure('http://fixture.invalid:8000'); const pending = controller.check();
  controller.configure('http://fixture.invalid:8001'); await controller.check();
  old.resolve({ kind: 'http_error', statusCode: 503, elapsedMs: 6 }); await pending;
  assert.deepEqual(queried, ['http://fixture.invalid:8000', 'http://fixture.invalid:8001']);
  assert.deepEqual(states.at(-1), { phase: 'online', statusCode: 200, elapsedMs: 4, checkedAt: 123 });
});

test('inactive or disposed connection controllers suppress all late response publication', async () => {
  for (const action of ['inactive', 'dispose']) {
    const request = deferred(); const states = [];
    const controller = new helpers.ConnectionCheckController(() => ({ probeHealth: () => request.promise }), state => states.push(state));
    controller.configure('http://fixture.invalid:8000'); const pending = controller.check();
    if (action === 'dispose') controller.dispose(); else controller.configure('http://fixture.invalid:8000', false);
    const count = states.length; request.resolve({ kind: 'online', statusCode: 200, elapsedMs: 1 }); await pending;
    assert.equal(states.length, count); await controller.check(); assert.equal(states.length, count);
  }
});

test('repeated taps produce one request, safe errors permit retry and published state is independent', async () => {
  const request = deferred(); const states = []; let calls = 0;
  const controller = new helpers.ConnectionCheckController(() => ({ probeHealth: () => {
    calls++; return calls === 1 ? request.promise : Promise.resolve({ kind: 'online', statusCode: 200, elapsedMs: 2 });
  } }), state => { states.push(state); state.phase = 'arbitrary mutation'; });
  controller.configure('http://fixture.invalid'); const pending = controller.check();
  await controller.check(); assert.equal(calls, 1);
  request.reject(new Error('private network failure')); await pending;
  await controller.check(); assert.equal(calls, 2);
  assert.equal(JSON.stringify(states).includes('private network failure'), false);
});

// These tests execute production helpers and HTTP method bodies with only the
// native HTTP boundary replaced. They do not prove Phone rendering or reachability.
