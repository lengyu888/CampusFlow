import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';
import { makeDraftFixture, shanghaiDate, makeRunController, runSnapshot, rememberHistory } from './helpers/agent-run-ui-fixture.mjs';

const helperSource = readFileSync(new URL('../entry/src/main/ets/utils/AgentFeedback.ets', import.meta.url), 'utf8')
  .replace(/^import \{[^\n]+\} from '\.\.\/model\/ApiModels';\r?\n/, '');
const helper = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(helperSource)).toString('base64')}`);
const reliabilitySource = readFileSync(new URL('../entry/src/main/ets/utils/ActionReliability.ets', import.meta.url), 'utf8')
  .replace(/^import \{[\s\S]*?\} from '[^']+';\r?\n/gm, '');
const reliability = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(reliabilitySource)).toString('base64')}`);
const source = readFileSync(new URL('../entry/src/main/ets/pages/AgentPage.ets', import.meta.url), 'utf8');
const firstBuilder = source.indexOf('\n  @Builder');
assert.ok(firstBuilder > 0, 'the non-UI method boundary must exist');
// Execute the actual production state/async methods. This is not ArkUI compilation or device testing.
const controllerSource = source.slice(0, firstBuilder)
  .replace(/^import [^\n]+;\r?\n/gm, '')
  .replace(/^@Component\r?\n/m, '')
  .replace(/@(Prop|State)\s+|@Watch\('[^']+'\)\s*/g, '')
  .replace('export struct AgentPage', 'class AgentPage') + '\n}\n';
const createController = new Function('CampusFlowApi', 'Scroller', 'CampusFlowRequestError',
  'displayToolTraces', 'mergeActions', 'restoreDraft', 'localRequestFailure', 'AppTheme', 'localHistory',
  'AgentRunController', 'localDrafts', 'shanghaiDate', ...Object.keys(reliability), stripTypeScriptTypes(controllerSource) + '\nreturn AgentPage;');

function pending(id = 'proposal-1', title = '复习') {
  return { proposal_id: id, action: 'create', kind: 'task', title, start_at: null, end_at: null,
    reminder_minutes: null, reason: null, payload: { task: { title, start_at: null, end_at: null, reminder_minutes: null, location: null } },
    conflicts: [], warnings: [], status: 'pending', contract_version: 2,
    created_at: new Date().toISOString(), expires_at: new Date(Date.now() + 900000).toISOString(),
    target_task_id: null, target_plan_id: null, before_task: null, before_plan: null, receipt: null };
}
function confirmed(action) {
  const receipt = { receipt_id: `receipt-${action.proposal_id}`, proposal_id: action.proposal_id, action: action.action,
    kind: action.kind, applied_at: new Date().toISOString(), task_ids: [`task-${action.proposal_id}`],
    plan_ids: [], milestone_ids: [], retained_task_ids: [] };
  return { applied: true, message: '', action: { ...action, status: 'confirmed', receipt }, receipt };
}

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((ok, fail) => { resolve = ok; reject = fail; });
  return { promise, resolve, reject };
}

async function harness(handlers = {}, localHistory = {}) {
  const calls = [];
  const histories = new Map();
  class Api {
    invoke(method, args) {
      calls.push({ method, args });
      assert.equal(typeof handlers[method], 'function', `unexpected API call: ${method}`);
      return handlers[method](...args);
    }
    async startAgentRun(request) {
      const response = await this.invoke('chat', [request.session_id, request.model, request.message]);
      rememberHistory(histories, request, response);
      return runSnapshot(request, response);
    }
    async history(sessionId) { return histories.get(sessionId) ?? []; }
    confirmAction(...args) { return this.invoke('confirmAction', args); }
    cancelAction(...args) { return this.invoke('cancelAction', args); }
    actionStatus(...args) { return this.invoke('actionStatus', args); }
  }
  const drafts = await makeDraftFixture();
  const Controller = createController(Api, class Scroller {}, helper.CampusFlowRequestError,
    helper.displayToolTraces, helper.mergeActions, helper.restoreDraft, helper.localRequestFailure, {}, localHistory, makeRunController(helper.CampusFlowRequestError, helper.localRequestFailure), drafts.store, shanghaiDate, ...Object.values(reliability));
  const page = new Controller();
  page.baseUrl = 'http://fixture.invalid';
  page.token = 'test-only';
  page.voiceActive = true;
  page.draftLease = drafts.lease;
  page.draftLeaseChanged();
  return { page, calls };
}

test('completed turns persist only user/assistant text without tools, credentials or proposals', async () => {
  const saved = [];
  const { page } = await harness({ chat: async () => ({ session_id: 'local-session', message: '完整回答',
    pending_actions: [pending()], tool_traces: [] }) }, {
    save: async (...args) => { saved.push(args); return true; }
  });
  page.historyScope = 'account-scope';
  const busy = [];
  page.onChatBusyChange = (value) => busy.push(value);
  page.prompt = '问题';
  await page.send();
  assert.equal(saved.length, 1);
  assert.equal(saved[0][0], 'account-scope');
  assert.deepEqual(saved[0][2].map(({ role, content }) => ({ role, content })),
    [{ role: 'user', content: '问题' }, { role: 'assistant', content: '完整回答' }]);
  assert.doesNotMatch(JSON.stringify(saved), /test-only|proposal-1|tool_traces|access_token/);
  assert.match(page.cacheNotice, /已保存/);
  assert.deepEqual(busy, [true, false]);
});

test('local persistence failure does not turn a successful chat into a failed send', async () => {
  const { page, calls } = await harness({ chat: async () => ({ session_id: 'local-session', message: '真实回答',
    pending_actions: [] }) }, { save: async () => { throw new Error('disk failure'); } });
  page.historyScope = 'account-scope';
  page.prompt = '问题';
  await page.send();
  assert.equal(calls.length, 1);
  assert.equal(page.messages.at(-1).role, 'assistant');
  assert.equal(page.messages.at(-1).content, '真实回答');
  assert.equal(page.prompt, '');
  assert.match(page.cacheNotice, /保存失败/);
});

test('logout/disposal blocks a late answer from recreating local history', async () => {
  const response = deferred();
  const saved = [];
  const { page } = await harness({ chat: () => response.promise }, { save: async (...args) => { saved.push(args); return true; } });
  page.historyScope = 'account-scope';
  page.prompt = '问题';
  const sending = page.send();
  page.aboutToDisappear();
  response.resolve({ session_id: 'late', message: '旧账号回答', pending_actions: [] });
  await sending;
  assert.equal(saved.length, 0);
  assert.ok(!page.messages.some((message) => message.content === '旧账号回答'));
});

test('deleting the active session starts a new ID and prevents late response resurrection', async () => {
  const response = deferred();
  const saved = [];
  const { page } = await harness({ chat: () => response.promise }, { save: async (...args) => { saved.push(args); return true; } });
  page.historyScope = 'account-scope';
  page.prompt = '问题';
  page.pendingActions = [pending()];
  const oldId = page.sessionId;
  const sending = page.send();
  page.deletedSessionId = oldId;
  page.sessionDeleted();
  response.resolve({ session_id: oldId, message: '已删除会话的旧回答', pending_actions: [pending()] });
  await sending;
  assert.notEqual(page.sessionId, oldId);
  assert.deepEqual(page.messages, []);
  assert.deepEqual(page.savedMessages, []);
  assert.deepEqual(page.pendingActions, []);
  assert.equal(saved.length, 0);
});

test('the first user message after deletion leaves the welcome state while the answer is still pending', async () => {
  const response = deferred();
  const { page } = await harness({ chat: () => response.promise });
  assert.equal(page.messages.length, 1);
  assert.equal(page.messages[0].id, 'welcome');
  assert.equal(page.hasConversation(), false, 'the initial welcome is not a conversation');

  page.deletedSessionId = page.sessionId;
  page.sessionDeleted();
  assert.deepEqual(page.messages, []);
  assert.equal(page.hasConversation(), false, 'a deleted conversation returns to the empty state');

  page.prompt = '删除后重新开始的第一条消息';
  const sending = page.send();
  assert.equal(page.messages.length, 1);
  assert.equal(page.messages[0].role, 'user');
  assert.equal(page.hasConversation(), true, 'one real user message must not be hidden as welcome content');
  response.resolve({ session_id: page.sessionId, message: '新会话的真实回答', pending_actions: [] });
  await sending;
  assert.equal(page.hasConversation(), true);
  assert.deepEqual(page.messages.map(({ role, content }) => ({ role, content })), [
    { role: 'user', content: '删除后重新开始的第一条消息' },
    { role: 'assistant', content: '新会话的真实回答' }
  ]);
});

test('one real assistant message is conversation content even without a welcome or user entry', async () => {
  const { page } = await harness();
  page.deletedSessionId = page.sessionId;
  page.sessionDeleted();
  page.appendMessage('assistant', '需要完整展示的助手消息');
  assert.equal(page.messages.length, 1);
  assert.equal(page.hasConversation(), true);
});

test('a slow failed send preserves a newer draft and keeps the original message available', async () => {
  const response = deferred();
  const { page, calls } = await harness({ chat: () => response.promise });
  page.prompt = '原来的规划请求';
  const sending = page.send();
  assert.equal(page.loading, true);
  page.prompt = '等待时新写的草稿';
  response.reject(helper.localRequestFailure('NETWORK_ERROR'));
  await sending;
  assert.equal(page.loading, true, 'an unknown create result keeps new writes blocked until checked');
  assert.equal(page.runState.phase, 'unknown');
  assert.equal(page.prompt, '等待时新写的草稿');
  assert.equal(page.messages.find((item) => item.role === 'user').content, '原来的规划请求');
  assert.equal(page.runState.request.message, '原来的规划请求');
  assert.equal(page.messages.filter(item => item.role === 'feedback').length, 0, 'unknown is not a definitive failure');
  assert.equal(calls.length, 1);
});

test('unknown sends preserve their original request without refilling an empty draft or exposing diagnostics', async () => {
  const { page } = await harness({ chat: async () => { throw new Error('PRIVATE_KEY_OR_URL'); } });
  page.prompt = '今晚复习';
  await page.send();
  assert.equal(page.prompt, '');
  assert.equal(page.runState.request.message, '今晚复习');
  assert.equal(page.runState.phase, 'unknown');
  assert.doesNotMatch(page.messages.at(-1).content, /PRIVATE_KEY_OR_URL/);
  assert.doesNotMatch(page.runState.message, /PRIVATE_KEY_OR_URL/);
});

test('a second send cannot run during an outstanding request', async () => {
  const response = deferred();
  const started = deferred();
  const { page, calls } = await harness({ chat: () => { started.resolve(); return response.promise; } });
  const sessionId = page.sessionId;
  page.prompt = '第一条';
  const first = page.send();
  page.prompt = '第二条草稿';
  await page.send();
  await started.promise; // The production durable-before-POST barrier is asynchronous.
  assert.equal(calls.length, 1);
  response.resolve({ session_id: 'session-1', message: '完成', pending_actions: [] });
  await first;
  assert.equal(page.prompt, '第二条草稿');
  assert.equal(page.sessionId, sessionId, 'the run is bound to its original requested session');
});

test('later turns keep unresolved proposals and cannot revive resolved ones', async () => {
  const firstAction = pending('first');
  const secondAction = pending('second');
  const responses = [[firstAction], [], [pending('first'), secondAction]];
  const { page } = await harness({ chat: async () => ({ session_id: 'session-1', message: '结果',
    pending_actions: responses.shift(), tool_traces: [] }) });
  page.prompt = '第一轮';
  await page.send();
  page.prompt = '追问';
  await page.send();
  assert.deepEqual(page.pendingActions.map((item) => item.proposal_id), ['first']);
  page.pendingActions = [{ ...firstAction, status: 'confirmed' }];
  page.prompt = '下一目标';
  await page.send();
  assert.deepEqual(page.pendingActions.map((item) => [item.proposal_id, item.status]),
    [['first', 'confirmed'], ['second', 'pending']]);
});

test('rapid confirm taps issue exactly one POST and block simultaneous chat sends', async () => {
  const response = deferred();
  const { page, calls } = await harness({ confirmAction: () => response.promise });
  const action = pending();
  page.pendingActions = [action];
  const first = page.decide(action, true);
  await page.decide(action, true);
  page.prompt = '执行时写下的问题';
  await page.send();
  assert.deepEqual(calls.map((item) => item.method), ['confirmAction']);
  response.resolve(confirmed(action));
  await first;
  assert.equal(page.pendingActions[0].status, 'confirmed');
  assert.equal(page.needsReview(action.proposal_id), false);
  assert.equal(page.prompt, '执行时写下的问题');
});

test('a false applied flag or a mismatched proposal ID never reports successful confirmation', async () => {
  for (const change of [{ applied: false }, { action: { ...pending('another'), status: 'confirmed' } }]) {
    const action = pending();
    const result = { ...confirmed(action), message: 'DO_NOT_TRUST_ME', ...change };
    const { page } = await harness({ confirmAction: async () => result });
    page.pendingActions = [action];
    await page.decide(action, true);
    assert.equal(page.pendingActions[0].status, 'pending');
    assert.equal(page.needsReview(action.proposal_id), true);
    assert.doesNotMatch(page.feedbackFor(action.proposal_id).message, /DO_NOT_TRUST_ME/);
  }
});

test('after an ambiguous write failure, an unreceipted confirmed label cannot authorize another write', async () => {
  const action = pending();
  const { page, calls } = await harness({
    confirmAction: async () => { throw helper.localRequestFailure('NETWORK_ERROR'); },
    actionStatus: async () => ({ ...action, status: 'confirmed' })
  });
  page.pendingActions = [action];
  await page.decide(action, true);
  assert.equal(page.needsReview(action.proposal_id), true);
  await page.decide(action, true);
  await page.checkDecision(action);
  await page.decide(action, true);
  assert.deepEqual(calls.map((item) => item.method), ['confirmAction', 'actionStatus']);
  assert.equal(page.pendingActions[0].status, 'pending');
  assert.equal(page.needsReview(action.proposal_id), true);
});

test('a valid cancellation is terminal and cannot subsequently trigger confirmation', async () => {
  const action = pending();
  const { page, calls } = await harness({ cancelAction: async () => ({ applied: false,
    message: 'cancelled', action: { ...action, status: 'cancelled' }, receipt: null }) });
  page.pendingActions = [action];
  await page.decide(action, false);
  await page.decide(action, true);
  assert.equal(page.pendingActions[0].status, 'cancelled');
  assert.deepEqual(calls.map((item) => item.method), ['cancelAction']);
});

test('a stale create callback cannot confirm a proposal whose current action is unsupported', async () => {
  const stale = pending();
  const { page, calls } = await harness();
  page.pendingActions = [{ ...stale, action: 'update' }];
  await page.decide(stale, true);
  assert.equal(calls.length, 0);
});


test('a malformed chat envelope does not replace the session or append a broken assistant entry', async () => {
  for (const result of [null, {}, { session_id: 'new', message: null, pending_actions: [] },
    { session_id: 'new', message: 'bad contract', pending_actions: null }]) {
    const { page } = await harness({ chat: async () => result });
    const originalSession = page.sessionId;
    page.prompt = '保留这条问题';
    await page.send();
    assert.equal(page.sessionId, originalSession);
    assert.equal(page.prompt, '');
    assert.equal(page.runState.request.message, '保留这条问题');
    assert.equal(page.runState.phase, 'unknown', 'a broken run result must be queried instead of resubmitted');
    assert.equal(page.messages.filter((item) => item.role === 'assistant').length, 1);
  }
});


test('an over-limit draft is retained without making a request', async () => {
  const { page, calls } = await harness();
  page.prompt = '字'.repeat(8001);
  await page.send();
  assert.equal(calls.length, 0);
  assert.equal(page.prompt.length, 8001);
  assert.equal(page.messages.length, 1);
});


test('the input limit counts Unicode characters consistently with the API, not UTF-16 units', async () => {
  const { page, calls } = await harness({ chat: async () => ({ session_id: 'unicode-session',
    message: '已收到', pending_actions: [] }) });
  page.prompt = '🌱'.repeat(8000);
  assert.equal(page.inputLength(page.prompt), 8000);
  await page.send();
  assert.equal(calls.length, 1);
  page.prompt = '🌱'.repeat(8001);
  await page.send();
  assert.equal(calls.length, 1);
  assert.equal(Array.from(page.prompt).length, 8001);
});

test('an unknown confirm resolves only through a matching durable receipt, refreshes once and opens its exact task', async () => {
  const action = pending();
  const result = confirmed(action);
  const { page, calls } = await harness({
    confirmAction: async () => { throw helper.localRequestFailure('NETWORK_ERROR'); },
    actionStatus: async () => result.action
  });
  let refreshes = 0;
  const opened = [];
  page.onPlanningChanged = () => refreshes++;
  page.onOpenTaskDetails = id => opened.push(id);
  page.pendingActions = [action];
  await page.decide(action, true);
  page.openReceipt(result.action);
  assert.deepEqual(opened, [], 'caller-supplied receipt is not the current verified state');
  await page.checkDecision(action);
  await page.checkDecision(action);
  page.openReceipt(action);
  assert.equal(refreshes, 1);
  assert.equal(page.pendingActions[0].status, 'confirmed');
  assert.equal(page.needsReview(action.proposal_id), false);
  assert.deepEqual(opened, [result.receipt.task_ids[0]]);
  assert.deepEqual(calls.map(c => c.method), ['confirmAction', 'actionStatus', 'actionStatus']);
});

test('v2 pending after an unknown result enables only an explicit same-ID retry, never an automatic write', async () => {
  const action = pending(); let writes = 0;
  const { page, calls } = await harness({
    confirmAction: async id => { assert.equal(id, action.proposal_id); if (++writes === 1) throw helper.localRequestFailure('NETWORK_ERROR'); return confirmed(action); },
    actionStatus: async () => ({ ...action })
  });
  page.pendingActions = [action];
  await page.decide(action, true);
  await page.decide(action, true);
  assert.equal(writes, 1);
  await page.checkDecision(action);
  assert.equal(writes, 1, 'GET does not silently resubmit');
  assert.equal(page.needsReview(action.proposal_id), false);
  await page.decide(action, true);
  assert.equal(writes, 2);
  assert.equal(page.pendingActions[0].status, 'confirmed');
  assert.deepEqual(calls.map(c => c.method), ['confirmAction', 'actionStatus', 'confirmAction']);
});

test('a known stale rejection remains blocked after repeated handlers, failed reads and a later pending status', async () => {
  const action = pending(); let reads = 0;
  const { page, calls } = await harness({
    confirmAction: async () => { throw new helper.CampusFlowRequestError(409, 'ACTION_STALE', '安排已变化'); },
    actionStatus: async () => { if (++reads === 1) throw helper.localRequestFailure('NETWORK_ERROR'); return { ...action }; },
    cancelAction: async () => ({ applied: false, action: { ...action, status: 'cancelled' }, receipt: null })
  });
  page.pendingActions = [action];
  await page.decide(action, true);
  await page.decide(action, true);
  await page.decide(action, true);
  assert.equal(page.requiresNewPreview(action), true);
  await page.checkDecision(action);
  await page.checkDecision(action);
  await page.decide(action, true);
  assert.equal(calls.filter(c => c.method === 'confirmAction').length, 1);
  assert.equal(page.requiresNewPreview(action), true);
  await page.decide(action, false);
  assert.equal(page.pendingActions[0].status, 'cancelled', 'an invalidated v2 preview can still be explicitly cancelled');
});

test('legacy proposals remain readable but neither raw terminal labels nor same-ID reads authorize execution', async () => {
  const action = pending(); delete action.contract_version;
  const { page, calls } = await harness({ actionStatus: async () => ({ ...action, status: 'confirmed' }) });
  page.pendingActions = [action];
  await page.decide(action, true);
  await page.checkDecision(action);
  await page.decide(action, true);
  assert.deepEqual(calls.map(c => c.method), ['actionStatus']);
  assert.equal(page.pendingActions[0].status, 'pending');
  assert.equal(page.needsReview(action.proposal_id), true);
});

test('a changed payload, before snapshot or receipt envelope cannot replace the reviewed candidate', async () => {
  for (const mutate of [r => { r.action.payload.task.location = '未经预览的新地点'; },
    r => { r.action.before_task = { title: 'bad snapshot' }; },
    r => { r.receipt = { ...r.receipt, receipt_id: 'different-envelope' }; }]) {
    const action = pending(); const result = confirmed(action); result.action = structuredClone(result.action); mutate(result);
    const { page } = await harness({ confirmAction: async () => result });
    page.pendingActions = [action];
    await page.decide(action, true);
    assert.equal(page.pendingActions[0], action);
    assert.equal(page.needsReview(action.proposal_id), true);
  }
});

test('a cancel/confirm race is resolved to the actual receipt instead of reporting a false cancellation', async () => {
  const action = pending(); const result = confirmed(action);
  const { page, calls } = await harness({ cancelAction: async () => result, actionStatus: async () => result.action });
  page.pendingActions = [action];
  await page.decide(action, false);
  assert.equal(page.pendingActions[0].status, 'pending');
  assert.equal(page.needsReview(action.proposal_id), true);
  await page.checkDecision(action);
  assert.equal(page.pendingActions[0].status, 'confirmed');
  assert.match(page.feedbackFor(action.proposal_id).message, /已创建/);
  assert.deepEqual(calls.map(c => c.method), ['cancelAction', 'actionStatus']);
});

test('update/delete preserve complete before/after data and deletion never links to a removed entity', async () => {
  for (const operation of ['update', 'delete']) {
    const action = pending();
    action.action = operation;
    action.target_task_id = 'existing-task';
    action.before_task = { ...action.payload.task, task_id: 'existing-task', plan_id: 'owner-plan', milestone_id: 'owner-milestone',
      status: 'pending', source: 'agent', created_at: action.created_at, completed_at: null };
    if (operation === 'delete') action.payload = {};
    else action.payload.task.location = '新的教室';
    const result = confirmed(action); result.receipt.task_ids = ['existing-task'];
    const { page } = await harness({ confirmAction: async () => result });
    const opened = []; page.onOpenTaskDetails = id => opened.push(id);
    page.pendingActions = [action];
    assert.equal(page.beforeTasks(action)[0], action.before_task);
    assert.equal(page.afterTasks(action).length, operation === 'delete' ? 0 : 1);
    await page.decide(action, true);
    assert.equal(page.pendingActions[0].status, 'confirmed');
    page.openReceipt(action);
    assert.deepEqual(opened, operation === 'delete' ? [] : ['existing-task']);
  }
});

test('new preview suggestions preserve an existing draft and are never sent automatically', async () => {
  const { page, calls } = await harness();
  page.prompt = '尚未发送的原草稿';
  page.regenerateProposal(pending());
  assert.equal(page.prompt, '尚未发送的原草稿');
  assert.equal(page.promptSuggestions.length, 1);
  assert.match(page.promptSuggestions[0], /读取最新课表/);
  assert.equal(calls.length, 0);
});

test('malformed proposals are excluded without dropping the assistant answer or other valid proposals', async () => {
  const action = pending();
  const { page } = await harness({ chat: async () => ({ session_id: 'session-1', message: '仍可阅读的完整回答',
    pending_actions: [null, { ...action, proposal_id: 'bad', warnings: [null] }, action] }) });
  page.prompt = '帮我规划'; await page.send();
  assert.deepEqual(page.pendingActions.map(a => a.proposal_id), [action.proposal_id]);
  assert.ok(page.messages.some(m => m.content === '仍可阅读的完整回答'));
  assert.ok(page.messages.some(m => /部分提案内容不完整/.test(m.content)));
});

test('late confirmation after session removal does not publish a receipt or refresh the next conversation', async () => {
  const action = pending(); const request = deferred();
  const { page } = await harness({ confirmAction: () => request.promise });
  let refreshes = 0; page.onPlanningChanged = () => refreshes++;
  page.pendingActions = [action]; const confirming = page.decide(action, true);
  page.deletedSessionId = page.sessionId; page.sessionDeleted();
  request.resolve(confirmed(action)); await confirming;
  assert.deepEqual(page.pendingActions, []);
  assert.equal(refreshes, 0);
});

test('one unknown proposal pauses other confirmations but permits chat, status reads and explicit cancellation', async () => {
  const first = pending('first'); const second = pending('second'); const third = pending('third');
  const { page, calls } = await harness({
    confirmAction: async id => { if (id === first.proposal_id) throw helper.localRequestFailure('NETWORK_ERROR'); return confirmed(third); },
    chat: async () => ({ session_id: 'session-1', message: '只读说明', pending_actions: [] }),
    cancelAction: async () => ({ applied: false, action: { ...second, status: 'cancelled' }, receipt: null }),
    actionStatus: async () => confirmed(first).action
  });
  page.pendingActions = [first, second, third];
  await page.decide(first, true);
  await page.decide(second, true);
  await page.decide(third, true);
  assert.equal(calls.filter(c => c.method === 'confirmAction').length, 1);
  page.prompt = '说明当前安排，不要写入'; await page.send();
  assert.equal(calls.filter(c => c.method === 'chat').length, 1);
  await page.decide(second, false);
  assert.equal(page.pendingActions.find(a => a.proposal_id === second.proposal_id).status, 'cancelled');
  await page.checkDecision(first);
  await page.decide(third, true);
  assert.equal(page.pendingActions.find(a => a.proposal_id === third.proposal_id).status, 'confirmed');
  assert.deepEqual(calls.map(c => c.method), ['confirmAction', 'chat', 'cancelAction', 'actionStatus', 'confirmAction']);
});
