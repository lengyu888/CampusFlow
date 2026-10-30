import './helpers/theme-fixture.mjs';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';
import { sessionHelpers } from './helpers/session-fixture.mjs';

const source = readFileSync(new URL('../entry/src/main/ets/pages/LoginPage.ets', import.meta.url), 'utf8');
const controller = source.slice(0, source.indexOf('\n  @Builder'))
  .replace(/^import .*;\r?\n/gm, '').replace(/^@Component\r?\n/m, '')
  .replace(/@(Prop|State)\s+|@(Watch|StorageLink)\('[^']+'\)\s*/g, '')
  .replace('export struct LoginPage', 'class LoginPage') + '\n}';
const user = { user_id: 'synthetic', display_name: '测试', email: 'test@example.invalid',
  role: 'user', school: null, campus: null, semester: null, onboarding_complete: true,
  api_key_configured: false, api_key_hint: null };
const auth = { access_token: 'synthetic-test-token', token_type: 'bearer', user };
function fixture() {
  let resolve;
  const response = new Promise(done => { resolve = done; });
  const calls = [], accepted = [], started = [], edited = [];
  class Api {
    constructor(base) { this.base = base; }
    async login() { calls.push(this.base); return response; }
    async register() { calls.push(this.base); return response; }
  }
  // Execute the real child controller with the real URL normalizer. Parent
  // authority and delayed Prop delivery are covered in test-local-history-entry.
  const Page = new Function('CampusFlowApi', 'CampusFlowRequestError', 'normalizeServiceBaseUrl',
    stripTypeScriptTypes(controller) + '\nreturn LoginPage;')(Api, class extends Error {}, sessionHelpers.normalizeServiceBaseUrl);
  const page = new Page();
  page.baseUrl = 'http://127.0.0.1:8001'; page.email = user.email; page.password = 'synthetic-password';
  page.onAuthenticated = (...args) => { accepted.push(args); };
  page.onAuthenticationStarted = (...args) => { started.push(args); };
  page.onBaseUrlChange = value => { edited.push(value); };
  return { page, calls, accepted, started, edited, resolve };
}

test('manual sign-in passes the immutable request service and remember choice to the root', async () => {
  const f = fixture(); f.page.rememberLogin = true;
  const pending = f.page.submit(); f.resolve(auth); await pending;
  assert.deepEqual(f.calls, ['http://127.0.0.1:8001']);
  assert.equal(f.accepted.length, 1);
  assert.equal(f.accepted[0][1], 'http://127.0.0.1:8001');
  assert.equal(f.accepted[0][2], true);
  assert.deepEqual(f.started, [['http://127.0.0.1:8001']]);
});

test('a successful response keeps its captured source when a stale child Prop arrives', async () => {
  const f = fixture(); const pending = f.page.submit();
  f.page.baseUrl = 'http://127.0.0.1:8002'; f.resolve(auth); await pending;
  assert.equal(f.accepted.length, 1);
  assert.equal(f.accepted[0][1], 'http://127.0.0.1:8001');
  assert.equal(f.page.errorText, '');
  assert.equal(f.page.password, 'synthetic-password');
});

test('manual service editing synchronizes the visible child value before notifying the parent', async () => {
  const f = fixture();
  f.page.onBaseUrlChange = value => { assert.equal(f.page.baseUrl, value); f.edited.push(value); };
  f.page.changeServiceBase('http://203.0.113.20:8000');
  const pending = f.page.submit(); f.resolve(auth); await pending;
  assert.deepEqual(f.edited, ['http://203.0.113.20:8000']);
  assert.deepEqual(f.calls, ['http://203.0.113.20:8000']);
});

test('disabled, restoring and inactive service inputs cannot forward delayed native echoes', async () => {
  for (const state of ['loading', 'restoreBusy', 'inactive']) {
    const f = fixture();
    if (state === 'inactive') { f.page.aboutToDisappear(); } else { f.page[state] = true; }
    f.page.changeServiceBase('http://203.0.113.20:8000');
    assert.equal(f.page.baseUrl, 'http://127.0.0.1:8001');
    assert.deepEqual(f.edited, []);
  }
});

test('invalid service input never starts authentication or sends credentials', async () => {
  const f = fixture(); f.page.baseUrl = 'http://user:password@example.invalid';
  await f.page.submit();
  assert.deepEqual(f.calls, []); assert.deepEqual(f.started, []); assert.deepEqual(f.accepted, []);
  assert.match(f.page.errorText, /地址格式/); assert.equal(f.page.loading, false);
});

test('registration uses the same captured public-service callback and remember choice', async () => {
  const f = fixture(); f.page.registerMode = true; f.page.displayName = '测试';
  f.page.baseUrl = 'http://203.0.113.20:8000'; f.page.rememberLogin = false;
  const pending = f.page.submit(); f.page.baseUrl = 'http://127.0.0.1:8000';
  f.resolve(auth); await pending;
  assert.deepEqual(f.calls, ['http://203.0.113.20:8000']);
  assert.deepEqual(f.started, [['http://203.0.113.20:8000']]);
  assert.equal(f.accepted[0][1], 'http://203.0.113.20:8000');
  assert.equal(f.accepted[0][2], false);
});

test('pending automatic session restore prevents submitting a second manual authentication', async () => {
  const f = fixture(); f.page.restoreBusy = true;
  const pending = f.page.submit(); f.resolve(auth); await pending;
  assert.deepEqual(f.calls, []); assert.deepEqual(f.accepted, []);
});
