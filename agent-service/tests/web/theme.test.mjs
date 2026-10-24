import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { JSDOM } from 'jsdom';

const root = new URL('../../src/campusflow_agent/web/', import.meta.url);
const read = file => readFileSync(new URL(file, root), 'utf8');
function environment(saved) {
  const dom = new JSDOM(read('index.html'), { url: 'http://127.0.0.1:8000/', runScripts: 'outside-only' });
  if (saved !== undefined) dom.window.localStorage.setItem('campusflow.theme', saved);
  dom.window.eval(read('theme.js'));
  dom.window.document.dispatchEvent(new dom.window.Event('DOMContentLoaded'));
  return dom;
}

test('theme startup restores only a supported local preference before app initialization', () => {
  for (const [saved, wanted] of [[undefined, 'paper-green'], ['ios-blue', 'ios-blue'], ['unknown', 'paper-green']]) {
    const dom = environment(saved);
    assert.equal(dom.window.document.documentElement.dataset.theme, wanted);
    assert.equal(dom.window.document.querySelector(`[data-theme-choice="${wanted}"]`).getAttribute('aria-pressed'), 'true');
    dom.window.close();
  }
});

test('actual theme buttons switch immediately and persist without replacing forms or app navigation', () => {
  const dom = environment(); const { document } = dom.window;
  const form = document.getElementById('settingsForm'), input = document.getElementById('settingsDisplayName');
  const prompt = document.getElementById('messageInput'), app = document.getElementById('appView');
  input.value = '未保存昵称'; prompt.value = '未发送的规划'; app.dataset.currentRoute = 'planning';
  dom.window.fixtureAccount = { user_id: 'synthetic-account' }; const account = dom.window.fixtureAccount;
  document.querySelector('[data-theme-choice="ios-blue"]').click();
  assert.equal(document.documentElement.dataset.theme, 'ios-blue');
  assert.equal(dom.window.localStorage.getItem('campusflow.theme'), 'ios-blue');
  assert.equal(document.getElementById('settingsForm'), form); assert.equal(document.getElementById('settingsDisplayName'), input);
  assert.equal(input.value, '未保存昵称'); assert.equal(prompt.value, '未发送的规划');
  assert.equal(app.dataset.currentRoute, 'planning'); assert.equal(dom.window.fixtureAccount, account);
  document.querySelector('[data-theme-choice="paper-green"]').click();
  assert.equal(document.documentElement.dataset.theme, 'paper-green'); assert.equal(prompt.value, '未发送的规划');
  const restarted = environment(dom.window.localStorage.getItem('campusflow.theme'));
  assert.equal(restarted.window.document.documentElement.dataset.theme, 'paper-green');
  dom.window.close(); restarted.window.close();
});

test('blocked localStorage leaves a working theme and explicit nonpersistent feedback', () => {
  const dom = environment();
  Object.defineProperty(dom.window.Storage.prototype, 'setItem', { value() { throw new Error('blocked'); } });
  assert.equal(dom.window.CampusFlowTheme.select('ios-blue'), true);
  assert.equal(dom.window.document.documentElement.dataset.theme, 'ios-blue');
  assert.match(dom.window.document.getElementById('themeStatus').textContent, /暂不允许保存/);
  assert.equal(dom.window.CampusFlowTheme.select('invalid'), false);
  dom.window.close();
});

test('cross-tab preference updates the same DOM and reduction of motion remains explicit', () => {
  const dom = environment(); const input = dom.window.document.getElementById('settingsSchool'); input.value = '草稿学校';
  dom.window.dispatchEvent(new dom.window.StorageEvent('storage', { key: 'campusflow.theme', newValue: 'ios-blue' }));
  assert.equal(dom.window.document.documentElement.dataset.theme, 'ios-blue'); assert.equal(input.value, '草稿学校');
  assert.match(read('themes.css'), /@media\s*\(prefers-reduced-motion:\s*reduce\)/);
  assert.match(read('themes.css'), /scroll-behavior:\s*auto\s*!important/);
  dom.window.close();
});

test('registration makes the model key optional and omits blank values from the real submit path', async () => {
  const dom = environment(); const form = dom.window.document.getElementById('registerForm');
  assert.equal(form.elements.api_key.required, false);
  const app = read('app.js'), start = app.indexOf('async function submitAuth('), end = app.indexOf('async function logout(');
  dom.window.eval(`const state = {}; function setButtonBusy() {} function showApp() {} function showOnboarding() {}
    function showToast(message) { throw Error(message); }
    async function api(endpoint, options) { window.fixtureRequest = { endpoint, body: JSON.parse(options.body) }; return { user: { onboarding_complete: true } }; }
    ${app.slice(start, end)}`);
  form.elements.email.value = 'synthetic@example.invalid'; form.elements.password.value = 'synthetic-password';
  for (const value of ['', '   ']) {
    form.elements.api_key.value = value; await dom.window.submitAuth(form, '/api/v1/auth/register');
    assert.equal(Object.hasOwn(dom.window.fixtureRequest.body, 'api_key'), false);
    assert.equal(dom.window.fixtureRequest.body.email, 'synthetic@example.invalid');
  }
  form.elements.api_key.value = '  synthetic-only-model-key  ';
  await dom.window.submitAuth(form, '/api/v1/auth/register');
  assert.equal(dom.window.fixtureRequest.body.api_key, 'synthetic-only-model-key');
  dom.window.close();
});
