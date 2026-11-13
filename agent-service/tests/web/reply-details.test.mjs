import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { JSDOM } from 'jsdom';

const app = readFileSync(new URL('../../src/campusflow_agent/web/app.js', import.meta.url), 'utf8');
const part = (start, end) => app.slice(app.indexOf(start), app.indexOf(end));
const trace = (label, summary, evidence = []) => ({
  tool_name: 'private_tool_id',
  tool_call_id: 'private-call-id',
  arguments: { token: 'private-argument' },
  result: { account_data: 'private-result' },
  display: { label, summary, state: 'success', evidence },
});

function setup(responses) {
  const dom = new JSDOM('<main id="messages"></main><textarea></textarea><button id="send"></button>',
    {runScripts: 'outside-only', pretendToBeVisual: true});
  const {window} = dom;
  window.HTMLDialogElement.prototype.showModal = function () { this.open = true; };
  window.HTMLDialogElement.prototype.close = function () {
    this.open = false;
    this.dispatchEvent(new window.Event('close'));
  };
  window.fixtureApi = async () => responses.shift();
  window.eval(`
    const state = {user: {user_id: 'owner'}, sessionId: 'session', appTab: 'agent', sessions: [], historyReadRevision: 0};
    const elements = {messages: document.querySelector('#messages'), messageInput: document.querySelector('textarea'),
      sendButton: document.querySelector('#send')};
    const api = window.fixtureApi;
    function clearEmptyState() {} function scrollMessages() {} function upsertSession() {} function refreshSessions() {}
    function selectedModel() { return 'deepseek-v4-pro'; } function setServiceState() {} function showToast() {}
    function confirmAction() {}
    function syncCampusPlaceSelection() {} function setSessionId() {} function clearCampusRouteMaps() {}
    function closeHistory() {} function switchAppTab(tab) { state.appTab = tab; }
    function renderCampusRoute(route, context, container) {
      const card = document.createElement('div'); card.className = 'campus-route-card';
      card.textContent = route.destination.name; container.append(card);
    }
    ${part('function appendMessage(', 'function campusRouteMapAllowed(')}
    ${part('const replyToolStates', 'async function confirmAction(')}
    ${part('async function sendMessage(', 'function resetSession(')}
    ${part('async function openSession(', 'function showRenameSession(')}
    window.changeSession = () => { state.sessionId = 'changed'; };
  `);
  return { dom, window, document: window.document };
}

test('each assistant reply opens only its own tool summaries and sources', async t => {
  const {dom, window, document} = setup([
    {message: '今天有课。', tool_traces: [trace('读取课表', '找到 1 节课。', [
      {label: '已导入课表', status: 'fresh', updated_at: '2026-11-12T01:00:00Z', note: '<img src=x>'},
    ])], pending_actions: []},
    {message: '今日安排已核对。', tool_traces: [trace('读取待办', '找到 2 条待办。')],
      pending_actions: [{proposal_id: 'p', kind: 'task', title: '添加复习待办'}]},
  ]);
  t.after(() => dom.window.close());
  await window.sendMessage('今天有课吗？');
  await window.sendMessage('看看待办。');
  const roles = [...document.querySelectorAll('#messages article.message')];
  assert.deepEqual(roles.map(row => row.querySelector('.meta').textContent), ['你', '助手', '你', '助手']);
  assert.equal(document.querySelector('dialog'), null);
  assert.equal(document.querySelectorAll('.reply-details-button').length, 2);
  assert.doesNotMatch(document.querySelector('#messages').textContent, /读取课表|已导入课表|读取待办/);
  assert.equal(roles[3].querySelector('.action-card button').textContent, '确认执行此操作');

  const first = roles[1].querySelector('.reply-details-button');
  assert.equal(first.getAttribute('aria-haspopup'), 'dialog');
  first.click();
  const dialog = document.querySelector('dialog[open]');
  assert.match(dialog.textContent, /读取课表.*找到 1 节课.*已导入课表/s);
  assert.doesNotMatch(dialog.textContent, /读取待办|private-/);
  assert.equal(dialog.querySelector('img'), null);
  dialog.querySelector('button').click();
  assert.equal(document.querySelector('dialog'), null);
  assert.equal(document.activeElement, first);

  roles[3].querySelector('.reply-details-button').click();
  assert.match(document.querySelector('dialog[open]').textContent, /读取待办/);
  assert.doesNotMatch(document.querySelector('dialog[open]').textContent, /读取课表/);
});

test('a reply with no tool data has no entry, and a route opens from its matching reply', async t => {
  const {dom, window, document} = setup([
    {message: '你好。', tool_traces: []},
    {message: '已查询步行路线。', tool_traces: [{
      tool_name: 'plan_campus_route', result: {origin: {}, destination: {name: '图书馆'}},
    }]},
  ]);
  t.after(() => dom.window.close());
  await window.sendMessage('你好');
  assert.equal(document.querySelector('.reply-details-button'), null);
  await window.sendMessage('去图书馆怎么走？');
  assert.equal(document.querySelector('.campus-route-card'), null);
  const entry = document.querySelector('.reply-details-button');
  assert.match(entry.textContent, /步行路线与来源/);
  entry.click();
  assert.match(document.querySelector('dialog .campus-route-card').textContent, /图书馆/);
  assert.match(document.querySelector('dialog').textContent, /服务未提供可核验的工具摘要/);
});

test('reply details distinguish expired, demonstration and malformed source evidence', async t => {
  const {dom, window, document} = setup([{
    message: '已核对资料。', tool_traces: [trace('读取资料', '找到 3 条。', [
      {label: '过期资料', kind: 'remote', status: 'fresh', updated_at: '2025-01-01T16:00:00Z',
        expires_at: '2025-01-02T00:00:00Z'},
      {label: '示例资料', kind: 'demo', status: 'fresh', updated_at: '2025-01-01T16:00:00Z'},
      {label: '格式异常', kind: 'remote', status: 'fresh', updated_at: '2025-02-30T00:00:00Z'},
    ])],
  }]);
  t.after(() => dom.window.close());
  await window.sendMessage('核对资料');
  document.querySelector('.reply-details-button').click();
  const details = [...document.querySelectorAll('.reply-tool-sources li')].map(item => item.textContent);
  assert.match(details[0], /已过期.*2025年1月2日.*上海/);
  assert.match(details[1], /演示数据/);
  assert.match(details[2], /未核验/);
});

test('a response from the previous session cannot attach tool details to the new conversation', async t => {
  let resolve;
  const response = new Promise(done => { resolve = done; });
  const {dom, window, document} = setup([response]);
  t.after(() => dom.window.close());
  const sending = window.sendMessage('旧会话');
  window.changeSession();
  document.querySelector('#messages').replaceChildren();
  document.querySelector('textarea').value = '新会话草稿';
  resolve({message: '旧会话答复', tool_traces: [trace('读取课表', '旧会话摘要')]});
  await sending;
  assert.equal(document.querySelector('#messages').childElementCount, 0);
  assert.equal(document.querySelector('textarea').value, '新会话草稿');
  assert.equal(document.querySelector('#send').disabled, false);
});

test('restored answers with equal text open their own saved sources and legacy messages still render', async t => {
  const source = (label) => ({label, status: 'fresh', updated_at: '2026-11-12T01:00:00Z'});
  const schedule = trace('读取课表', '找到 1 节课。', [source('课程表')]).display;
  const route = trace('查询步行路线', '已查询校园步行路线。', [source('百度地图')]).display;
  const {dom, window, document} = setup([[
    {role: 'user', content: '第一次查询', tools: [route]},
    {role: 'assistant', content: '已核对。', tools: [schedule]},
    {role: 'user', content: '第二次查询'},
    {role: 'assistant', content: '已核对。', tools: [route], pending_actions: [{title: '旧提案'}]},
    {role: 'assistant', content: '旧会话中的普通回复'},
  ]]);
  t.after(() => dom.window.close());
  await window.openSession('saved');

  const messages = [...document.querySelectorAll('#messages article')];
  assert.equal(messages.length, 5);
  assert.equal(document.querySelectorAll('.reply-details-button').length, 2);
  assert.equal(messages[0].querySelector('.reply-details-button'), null);
  assert.equal(messages[4].querySelector('.reply-details-button'), null);
  assert.match(messages[4].textContent, /旧会话中的普通回复/);
  assert.equal(document.querySelector('.action-card'), null);

  messages[1].querySelector('.reply-details-button').click();
  const firstDetails = document.querySelector('dialog[open]');
  assert.match(firstDetails.textContent, /读取课表.*课程表/s);
  assert.doesNotMatch(firstDetails.textContent, /百度地图/);
  firstDetails.querySelector('button').click();

  messages[3].querySelector('.reply-details-button').click();
  const secondDetails = document.querySelector('dialog[open]');
  assert.match(secondDetails.textContent, /查询步行路线.*百度地图/s);
  assert.doesNotMatch(secondDetails.textContent, /课程表/);
  assert.equal(secondDetails.querySelector('.campus-route-card'), null);
});

test('an earlier history response cannot replace the selected conversation and its tool details', async t => {
  let resolveEarlier;
  const earlier = new Promise(resolve => { resolveEarlier = resolve; });
  const selected = [{role: 'assistant', content: '当前历史回复',
    tools: [trace('读取图书馆', '当前会话来源').display]}];
  const {dom, window, document} = setup([earlier, selected]);
  t.after(() => dom.window.close());

  const previous = window.openSession('earlier');
  await window.openSession('selected');
  resolveEarlier([{role: 'assistant', content: '旧历史回复', tools: [trace('读取课表', '旧会话来源').display]}]);
  await previous;

  assert.match(document.querySelector('#messages').textContent, /当前历史回复/);
  assert.doesNotMatch(document.querySelector('#messages').textContent, /旧历史回复/);
  document.querySelector('.reply-details-button').click();
  assert.match(document.querySelector('dialog[open]').textContent, /当前会话来源/);
});
