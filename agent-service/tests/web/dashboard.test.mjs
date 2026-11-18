import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { JSDOM } from 'jsdom';

const root = new URL('../../src/campusflow_agent/web/', import.meta.url);
const read = file => readFileSync(new URL(file, root), 'utf8');
const settle = () => new Promise(resolve => setImmediate(resolve));

async function openApp(t, date = '2026-11-18T00:59:30Z') {
  const dom = new JSDOM(read('index.html'), {
    url: 'http://127.0.0.1:8000/', runScripts: 'outside-only', pretendToBeVisual: true,
  });
  t.after(() => dom.window.close());
  const { window } = dom;
  const calls = [];
  const timers = new Map();
  let tick = Date.parse(date);
  let timerId = 0;
  window.Date = class extends window.Date {
    constructor(...args) {
      super(...(args.length ? args : [tick]));
    }
    static now() { return tick; }
  };
  window.setTimeout = (callback, delay) => {
    const id = ++timerId;
    timers.set(id, { callback, time: tick + delay });
    return id;
  };
  window.clearTimeout = id => timers.delete(id);
  window.fetch = async (path, options) => {
    calls.push([path, options?.method ?? 'GET']);
    const responses = {
      '/health': { supported_models: [] },
      '/api/v1/me': { user_id: 'fixture', display_name: '验收', campus: '下沙校区', onboarding_complete: true },
      '/api/v1/me/context': {
        timetable: [
          { date: '2026-11-18', title: '操作系统', start_time: '09:00', end_time: '09:45' },
          { date: '2026-11-19', title: '编译原理', start_time: '14:00', end_time: '14:45' },
        ],
        campus_map: {},
      },
      '/api/v1/sessions': [],
      '/api/v1/auth/logout': null,
    };
    assert.ok(Object.hasOwn(responses, path), 'Unexpected fetch: ' + path);
    return { ok: true, status: path.endsWith('/logout') ? 204 : 200, json: async () => responses[path] };
  };
  window.eval(read('app.js'));
  await settle();
  const advanceTo = async target => {
    tick = Date.parse(target);
    for (const [id, { callback, time }] of timers) {
      if (time <= tick) {
        timers.delete(id);
        callback();
      }
    }
    await settle();
  };
  return { document: window.document, calls, timers, advanceTo };
}

test('Shanghai timetable moves through class times and midnight without fetching more data', async t => {
  const { document, calls, timers, advanceTo } = await openApp(t);
  const previous = calls.length;
  assert.equal(document.querySelector('#weekStrip .today').dataset.date, '2026-11-18');
  assert.match(document.querySelector('#todayDate').textContent, /11月18日/);
  assert.equal(document.querySelector('#nextCountdown').textContent, '1 分钟后开始');
  assert.equal(document.querySelector('#todayCourseList article').dataset.state, 'next');

  const tomorrow = document.querySelector('[data-date="2026-11-19"]');
  tomorrow.focus();
  tomorrow.click();
  assert.equal(document.activeElement, tomorrow);
  assert.equal(tomorrow.getAttribute('aria-pressed'), 'true');
  assert.match(document.querySelector('#todayCourseList').textContent, /编译原理/);

  await advanceTo('2026-11-18T01:00:00Z');
  assert.equal(document.querySelector('#nextCountdown').textContent, '');
  assert.equal(document.activeElement, tomorrow);
  assert.equal(tomorrow.getAttribute('aria-pressed'), 'true');
  document.querySelector('#weekStrip .today').click();
  assert.equal(document.querySelector('#todayCourseList article').dataset.state, 'now');

  await advanceTo('2026-11-18T01:45:00Z');
  assert.equal(document.querySelector('#todayCourseList article').dataset.state, 'past');
  await advanceTo('2026-11-18T16:00:00Z');
  assert.equal(document.querySelector('#weekStrip .today').dataset.date, '2026-11-19');
  assert.match(document.querySelector('#todayCourseList').textContent, /编译原理/);
  assert.equal(calls.length, previous);

  document.querySelector('[data-app-tab="agent"]').click();
  assert.equal(timers.size, 0);
});

test('assistant shortcuts preserve an existing draft and settings can sign out', async t => {
  const { document, calls } = await openApp(t);
  document.querySelector('[data-app-tab="agent"]').click();
  const composer = document.querySelector('#messageInput');
  const [first, second] = document.querySelectorAll('[data-starter]');
  first.click();
  assert.equal(composer.value, first.dataset.starter);
  second.click();
  assert.equal(composer.value, first.dataset.starter);
  assert.match(document.querySelector('#toast').textContent, /已保留未发送的草稿/);
  composer.value = '';
  second.click();
  assert.equal(composer.value, second.dataset.starter);

  document.querySelector('[data-app-action="settings"]').click();
  assert.equal(document.querySelector('#settingsView').hidden, false);
  document.querySelector('#settingsLogoutButton').click();
  await settle();
  assert.deepEqual(calls.at(-1), ['/api/v1/auth/logout', 'POST']);
  assert.equal(document.querySelector('#authView').hidden, false);
  assert.equal(composer.value, '');
});
