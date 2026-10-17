import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';

const source = readFileSync(new URL('../entry/src/main/ets/pages/LoginPage.ets', import.meta.url), 'utf8');
const controller = source.slice(0, source.indexOf('\n  @Builder'))
  .replace(/^import .*;\r?\n/gm, '').replace(/^@Component\r?\n/m, '')
  .replace(/@(Prop|State)\s+/g, '').replace('export struct LoginPage', 'class LoginPage') + '\n}';
function fixture(response = async () => ({ user: { user_id: 'synthetic' }, access_token: 'test' })) {
  const calls = [], authenticated = [];
  class Api { async register(...args) { calls.push(args); return response(); } }
  const Page = new Function('CampusFlowApi', 'CampusFlowRequestError',
    stripTypeScriptTypes(controller) + ';return LoginPage;')(Api, class extends Error {});
  const page = new Page();
  page.baseUrl = 'http://synthetic.invalid'; page.registerMode = true;
  page.email = 'student@example.invalid'; page.password = 'synthetic-password'; page.displayName = '同学';
  page.onAuthenticated = async (auth) => authenticated.push(auth);
  return { page, calls, authenticated };
}

test('registration with omitted or whitespace-only model key authenticates normally', async () => {
  for (const key of ['', '   ']) {
    const f = fixture(); f.page.apiKey = key;
    await f.page.submit();
    assert.deepEqual(f.calls, [['student@example.invalid', 'synthetic-password', '同学', undefined]]);
    assert.equal(f.authenticated.length, 1);
    assert.equal(f.page.errorText, '');
  }
});
test('provided model key is still submitted even when optional section is collapsed', async () => {
  const f = fixture(); f.page.apiKey = 'sk-synthetic-key'; f.page.showModelConfig = false;
  await f.page.submit();
  assert.equal(f.calls[0][3], 'sk-synthetic-key');
  assert.equal(f.authenticated.length, 1);
});
test('nickname remains required and cannot be bypassed with whitespace or a supplied key', async () => {
  const f = fixture(); f.page.displayName = '   '; f.page.apiKey = 'sk-synthetic-key';
  await f.page.submit();
  assert.equal(f.calls.length, 0);
  assert.match(f.page.errorText, /昵称/);
});
test('failed no-key registration keeps account inputs and late success does not navigate', async () => {
  const failed = fixture(async () => { throw new Error('PRIVATE_RESPONSE'); });
  await failed.page.submit();
  assert.equal(failed.page.email, 'student@example.invalid');
  assert.equal(failed.page.password, 'synthetic-password');
  assert.doesNotMatch(failed.page.errorText, /PRIVATE_RESPONSE/);
  let resolve;
  const pending = new Promise(done => { resolve = done; });
  const f = fixture(() => pending);
  const first = f.page.submit(); await f.page.submit();
  assert.equal(f.calls.length, 1);
  f.page.aboutToDisappear(); resolve({ user: { user_id: 'late' }, access_token: 'late' });
  await first;
  assert.equal(f.authenticated.length, 0);
});
