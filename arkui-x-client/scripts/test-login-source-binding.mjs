import './helpers/theme-fixture.mjs';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';

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
  const calls = [], accepted = [];
  class Api {
    constructor(base) { this.base = base; }
    async login() { calls.push(this.base); return response; }
  }
  // The actual LoginPage async path is executed; URL normalization and native UI
  // are separate boundaries, not replacements for the source-binding assertion.
  const Page = new Function('CampusFlowApi', 'CampusFlowRequestError', 'normalizeServiceBaseUrl',
    stripTypeScriptTypes(controller) + '\nreturn LoginPage;')(Api, class extends Error {}, value => value);
  const page = new Page();
  page.baseUrl = 'http://127.0.0.1:8001'; page.email = user.email; page.password = 'synthetic-password';
  page.onAuthenticated = (...args) => { accepted.push(args); };
  return { page, calls, accepted, resolve };
}

test('manual sign-in passes the immutable request service and remember choice to the root', async () => {
  const f = fixture(); f.page.rememberLogin = true;
  const pending = f.page.submit(); f.resolve(auth); await pending;
  assert.deepEqual(f.calls, ['http://127.0.0.1:8001']);
  assert.equal(f.accepted.length, 1);
  assert.equal(f.accepted[0][1], 'http://127.0.0.1:8001');
  assert.equal(f.accepted[0][2], true);
});

test('a successful response for an edited service never activates the new target', async () => {
  const f = fixture(); const pending = f.page.submit();
  f.page.baseUrl = 'http://127.0.0.1:8002'; f.resolve(auth); await pending;
  assert.equal(f.accepted.length, 0);
  assert.match(f.page.errorText, /地址.*变|服务.*变/);
  assert.equal(f.page.password, 'synthetic-password');
});

test('pending automatic session restore prevents submitting a second manual authentication', async () => {
  const f = fixture(); f.page.restoreBusy = true;
  const pending = f.page.submit(); f.resolve(auth); await pending;
  assert.deepEqual(f.calls, []); assert.deepEqual(f.accepted, []);
});
