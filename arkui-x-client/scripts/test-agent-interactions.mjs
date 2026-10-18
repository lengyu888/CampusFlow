import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';

const helperSource = readFileSync(new URL('../entry/src/main/ets/utils/AgentFeedback.ets', import.meta.url), 'utf8')
  .replace(/^import \{[^\n]+\} from '\.\.\/model\/ApiModels';\r?\n/, '');
const helper = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(helperSource)).toString('base64')}`);
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
  'displayToolTraces', 'mergeActions', 'restoreDraft', 'localRequestFailure', 'AppTheme',
  stripTypeScriptTypes(controllerSource) + '\nreturn AgentPage;');

function pending(id = 'proposal-1') {
  return { proposal_id: id, action: 'create', kind: 'task', title: '复习', start_at: null,
    end_at: null, reminder_minutes: null, reason: null, payload: {}, conflicts: [], status: 'pending' };
}

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((ok, fail) => { resolve = ok; reject = fail; });
  return { promise, resolve, reject };
}

function harness(handlers = {}) {
  const calls = [];
  class Api {
    invoke(method, args) {
      calls.push({ method, args });
      assert.equal(typeof handlers[method], 'function', `unexpected API call: ${method}`);
      return handlers[method](...args);
    }
    chat(...args) { return this.invoke('chat', args); }
    confirmAction(...args) { return this.invoke('confirmAction', args); }
    cancelAction(...args) { return this.invoke('cancelAction', args); }
    actionStatus(...args) { return this.invoke('actionStatus', args); }
  }
  const Controller = createController(Api, class Scroller {}, helper.CampusFlowRequestError,
    helper.displayToolTraces, helper.mergeActions, helper.restoreDraft, helper.localRequestFailure, {});
  const page = new Controller();
  page.baseUrl = 'http://fixture.invalid';
  page.token = 'test-only';
  return { page, calls };
}

test('a slow failed send preserves a newer draft and keeps the original message available', async () => {
  const response = deferred();
  const { page, calls } = harness({ chat: () => response.promise });
  page.prompt = '原来的规划请求';
  const sending = page.send();
  assert.equal(page.loading, true);
  page.prompt = '等待时新写的草稿';
  response.reject(helper.localRequestFailure('NETWORK_ERROR'));
  await sending;
  assert.equal(page.loading, false);
  assert.equal(page.prompt, '等待时新写的草稿');
  assert.equal(page.messages.find((item) => item.role === 'user').content, '原来的规划请求');
  assert.equal(page.messages.at(-1).failedPrompt, '原来的规划请求');
  assert.equal(calls.length, 1);
});

test('failed sends restore an empty draft and conceal unknown exception diagnostics', async () => {
  const { page } = harness({ chat: async () => { throw new Error('PRIVATE_KEY_OR_URL'); } });
  page.prompt = '今晚复习';
  await page.send();
  assert.equal(page.prompt, '今晚复习');
  assert.equal(page.messages.at(-1).failureCode, 'UNKNOWN');
  assert.doesNotMatch(page.messages.at(-1).content, /PRIVATE_KEY_OR_URL/);
});

test('a second send cannot run during an outstanding request', async () => {
  const response = deferred();
  const { page, calls } = harness({ chat: () => response.promise });
  page.prompt = '第一条';
  const first = page.send();
  page.prompt = '第二条草稿';
  await page.send();
  assert.equal(calls.length, 1);
  response.resolve({ session_id: 'session-1', message: '完成', pending_actions: [] });
  await first;
  assert.equal(page.prompt, '第二条草稿');
  assert.equal(page.sessionId, 'session-1');
});

test('later turns keep unresolved proposals and cannot revive resolved ones', async () => {
  const firstAction = pending('first');
  const secondAction = pending('second');
  const responses = [[firstAction], [], [pending('first'), secondAction]];
  const { page } = harness({ chat: async () => ({ session_id: 'session-1', message: '结果',
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
  const { page, calls } = harness({ confirmAction: () => response.promise });
  const action = pending();
  page.pendingActions = [action];
  const first = page.decide(action, true);
  await page.decide(action, true);
  page.prompt = '执行时写下的问题';
  await page.send();
  assert.deepEqual(calls.map((item) => item.method), ['confirmAction']);
  response.resolve({ applied: true, message: 'ignored', action: { ...action, status: 'confirmed' } });
  await first;
  assert.equal(page.pendingActions[0].status, 'confirmed');
  assert.equal(page.needsReview(action.proposal_id), false);
  assert.equal(page.prompt, '执行时写下的问题');
});

test('a false applied flag or a mismatched proposal ID never reports successful confirmation', async () => {
  for (const change of [{ applied: false }, { action: { ...pending('another'), status: 'confirmed' } }]) {
    const action = pending();
    const result = { applied: true, message: 'DO_NOT_TRUST_ME', action: { ...action, status: 'confirmed' }, ...change };
    const { page } = harness({ confirmAction: async () => result });
    page.pendingActions = [action];
    await page.decide(action, true);
    assert.equal(page.pendingActions[0].status, 'pending');
    assert.equal(page.needsReview(action.proposal_id), true);
    assert.doesNotMatch(page.feedbackFor(action.proposal_id).message, /DO_NOT_TRUST_ME/);
  }
});

test('after an ambiguous write failure, recovery reads status and never retries the write', async () => {
  const action = pending();
  const { page, calls } = harness({
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
  assert.equal(page.pendingActions[0].status, 'confirmed');
  assert.equal(page.needsReview(action.proposal_id), true);
});

test('a valid cancellation is terminal and cannot subsequently trigger confirmation', async () => {
  const action = pending();
  const { page, calls } = harness({ cancelAction: async () => ({ applied: false,
    message: 'cancelled', action: { ...action, status: 'cancelled' } }) });
  page.pendingActions = [action];
  await page.decide(action, false);
  await page.decide(action, true);
  assert.equal(page.pendingActions[0].status, 'cancelled');
  assert.deepEqual(calls.map((item) => item.method), ['cancelAction']);
});

test('a stale create callback cannot confirm a proposal whose current action is unsupported', async () => {
  const stale = pending();
  const { page, calls } = harness();
  page.pendingActions = [{ ...stale, action: 'update' }];
  await page.decide(stale, true);
  assert.equal(calls.length, 0);
});


test('a malformed chat envelope does not replace the session or append a broken assistant entry', async () => {
  for (const result of [null, {}, { session_id: 'new', message: null, pending_actions: [] },
    { session_id: 'new', message: 'bad contract', pending_actions: null }]) {
    const { page } = harness({ chat: async () => result });
    const originalSession = page.sessionId;
    page.prompt = '保留这条问题';
    await page.send();
    assert.equal(page.sessionId, originalSession);
    assert.equal(page.prompt, '保留这条问题');
    assert.equal(page.messages.at(-1).failureCode, 'INVALID_RESPONSE');
    assert.equal(page.messages.filter((item) => item.role === 'assistant').length, 1);
  }
});


test('an over-limit draft is retained without making a request', async () => {
  const { page, calls } = harness();
  page.prompt = '字'.repeat(8001);
  await page.send();
  assert.equal(calls.length, 0);
  assert.equal(page.prompt.length, 8001);
  assert.equal(page.messages.length, 1);
});


test('the input limit counts Unicode characters consistently with the API, not UTF-16 units', async () => {
  const { page, calls } = harness({ chat: async () => ({ session_id: 'unicode-session',
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
