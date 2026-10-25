import './helpers/theme-fixture.mjs';
import { conversationDependencies } from './helpers/conversation-fixture.mjs';
import { reliability } from './helpers/course-review-fixture.mjs';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripThemeTypeScriptTypes as stripTypeScriptTypes } from './helpers/theme-fixture.mjs';
import { test } from 'node:test';
import { makeDraftFixture, shanghaiDate, makeRunController, runSnapshot, rememberHistory } from './helpers/agent-run-ui-fixture.mjs';

const helperSource = readFileSync(new URL('../entry/src/main/ets/utils/AgentFeedback.ets', import.meta.url), 'utf8')
  .replace(/^import \{[^\n]+\} from '\.\.\/model\/ApiModels';\r?\n/, '');
const helper = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(helperSource)).toString('base64')}`);
const catalogSource = readFileSync(new URL('../entry/src/main/ets/utils/ModelCatalog.ets', import.meta.url), 'utf8').replace(/^import [^\n]+;\r?\n/gm, '');
const catalog = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(catalogSource)).toString('base64')}`);
const source = readFileSync(new URL('../entry/src/main/ets/pages/AgentPage.ets', import.meta.url), 'utf8');
const boundary = source.indexOf('\n  @Builder');
assert.ok(boundary > 0);
// Execute production state and async methods. UI layout, ArkTS compilation and native
// Scroller behavior still require the team's device environment.
const controllerSource = source.slice(0, boundary)
  .replace(/^import [^\n]+;\r?\n/gm, '')
  .replace(/^@Component\r?\n/m, '')
  .replace(/@(Prop|State)\s+|@Watch\('[^']+'\)\s*/g, '')
  .replace('export struct AgentPage', 'class AgentPage') + '\n}\n';
const create = new Function('CampusFlowApi', 'Scroller', 'CampusFlowRequestError', 'displayToolTraces',
  'mergeActions', 'restoreDraft', 'localRequestFailure', 'AppTheme', 'localHistory', 'Edge',
  'AgentRunController', 'localDrafts', 'shanghaiDate', ...Object.keys(catalog), ...Object.keys(reliability), ...Object.keys(conversationDependencies), stripTypeScriptTypes(controllerSource) + '\nreturn AgentPage;');

function pending(id, title = '相同标题') {
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
  const promise = new Promise((done) => { resolve = done; });
  return { promise, resolve };
}

async function harness(handlers = {}) {
  const calls = [], scroll = [];
  class Api {
    call(method, args) { calls.push({ method, args }); assert.equal(typeof handlers[method], 'function'); return handlers[method](...args); }
    async startAgentRun(request) {
      const response = await this.call('chat', [request.session_id, request.model, request.message]);
      return runSnapshot(request, response);
    }
    confirmAction(...args) { return this.call('confirmAction', args); }
    cancelAction(...args) { return this.call('cancelAction', args); }
    actionStatus(...args) { return this.call('actionStatus', args); }
    async models() { return { default_model: 'deepseek-v4-pro', models: ['deepseek-v4-pro', 'deepseek-flash'].map(id => ({ id, label: id, provider: 'DeepSeek', supports_tools: true, supports_streaming: true, supports_reasoning: true, available: true, unavailable_reason: '' })) }; }
  }
  class Scroller {
    scrollTo(value) { scroll.push({ kind: 'position', ...value }); }
    scrollEdge(edge) { scroll.push({ kind: 'edge', edge }); }
  }
  const drafts = await makeDraftFixture();
  const Page = create(Api, Scroller, helper.CampusFlowRequestError, helper.displayToolTraces,
    helper.mergeActions, helper.restoreDraft, helper.localRequestFailure, {}, {}, { Bottom: 'bottom' }, makeRunController(helper.CampusFlowRequestError, helper.localRequestFailure), drafts.store, shanghaiDate, ...Object.values(catalog), ...Object.values(reliability), ...Object.values(conversationDependencies));
  const page = new Page();
  page.baseUrl = 'http://fixture.invalid';
  page.token = 'fixture-token';
  page.voiceActive = true;
  page.draftLease = drafts.lease;
  page.draftLeaseChanged();
  return { page, calls, scroll };
}

test('external prompts preserve a typed draft and require explicit append or empty-input adoption', async () => {
  const { page, calls } = await harness();
  page.prompt = '我正在编辑的草稿';
  page.initialPrompt = '从计划页带来的建议';
  page.promptRevision = 1;
  page.initialPromptChanged();
  assert.equal(page.prompt, '我正在编辑的草稿');
  assert.deepEqual(page.promptSuggestions, ['从计划页带来的建议']);
  page.applySuggestion(false);
  assert.equal(page.prompt, '我正在编辑的草稿');
  assert.equal(page.promptSuggestions.length, 1);
  page.applySuggestion(true);
  assert.equal(page.prompt, '我正在编辑的草稿\n从计划页带来的建议');
  assert.deepEqual(page.promptSuggestions, []);
  assert.equal(calls.length, 0, 'adopting a suggestion never sends or confirms');
  page.offerPrompt('下一条');
  page.prompt = '';
  page.applySuggestion(false);
  assert.equal(page.prompt, '下一条');
});

test('suggestions retain arrival order and do not silently replace an earlier unhandled suggestion', async () => {
  const { page } = await harness();
  page.prompt = '原稿';
  page.choosePrompt('建议一');
  page.choosePrompt('建议二');
  page.choosePrompt('建议一');
  assert.deepEqual(page.promptSuggestions, ['建议一', '建议二']);
  page.dismissSuggestion();
  assert.equal(page.prompt, '原稿');
  assert.deepEqual(page.promptSuggestions, ['建议二']);
});

test('returning to an already initialized page does not replay its consumed initial prompt', async () => {
  const { page } = await harness();
  page.initialPrompt = '首次建议';
  page.promptRevision = 3;
  page.aboutToAppear();
  assert.equal(page.prompt, '首次建议');
  page.prompt = '已经改写的输入';
  page.aboutToAppear();
  assert.equal(page.prompt, '已经改写的输入');
  assert.deepEqual(page.promptSuggestions, []);
});

test('Unicode suggestion overflow preserves both texts and never truncates the draft', async () => {
  const { page, calls } = await harness();
  page.prompt = '🌱'.repeat(7999);
  page.offerPrompt('安排');
  page.applySuggestion(true);
  assert.equal(Array.from(page.prompt).length, 7999);
  assert.deepEqual(page.promptSuggestions, ['安排']);
  assert.match(page.suggestionNotice, /8000/);
  page.prompt = '';
  page.applySuggestion(false);
  assert.equal(page.prompt, '安排');
  page.prompt = '';
  page.offerPrompt('🌱'.repeat(8001));
  assert.equal(page.prompt, '');
  assert.equal(Array.from(page.promptSuggestions[0]).length, 8001);
  assert.equal(calls.length, 0);
});

test('each proposal stays with the first answer returning its ID, including duplicate IDs and equal titles', async () => {
  const responses = [[pending('a'), pending('b')], [], [pending('a'), pending('c')]];
  const { page } = await harness({ chat: async () => ({ session_id: 's', message: '本轮回答', pending_actions: responses.shift() }) });
  for (const prompt of ['第一轮', '无提案追问', '新的目标']) { page.prompt = prompt; await page.send(); }
  const answers = page.messages.filter(m => m.id !== 'welcome' && m.role === 'assistant');
  assert.deepEqual(page.actionsForMessage(answers[0].id).map(a => a.proposal_id), ['a', 'b']);
  assert.deepEqual(page.actionsForMessage(answers[1].id), []);
  assert.deepEqual(page.actionsForMessage(answers[2].id).map(a => a.proposal_id), ['c']);
  assert.equal(page.proposalOrigins.length, 3);
  page.replaceAction({ ...pending('a'), status: 'confirmed' });
  assert.equal(page.actionsForMessage(answers[0].id)[0].status, 'confirmed');
  assert.ok(answers.every(m => page.collapsedToolIds.includes(m.id)), 'tool evidence starts compact');
});

test('attention summary distinguishes pending decisions from uncertain writes even after a terminal status read', async () => {
  const { page } = await harness();
  const a = pending('a'), b = { ...pending('b'), status: 'confirmed' }, c = { ...pending('c'), status: 'cancelled' };
  page.pendingActions = [a, b, c];
  page.setFeedback('b', '服务端已确认，实际写入仍需核对', true);
  assert.equal(page.attentionLabel(), '1 份待确认 · 1 份结果待核对');
  assert.deepEqual(page.attentionActions().map(a => a.proposal_id), ['a', 'b']);
  assert.equal(page.receiptCollapsed(b), false, 'an uncertain write cannot become a success receipt');
  assert.equal(page.receiptCollapsed(c), true);
  page.toggleReceipt('c');
  assert.equal(page.receiptCollapsed(c), false);
  assert.equal(c.status, 'cancelled');
});

test('attention navigation waits for measured message and proposal anchors then cycles by proposal identity', async () => {
  const { page, scroll } = await harness();
  page.pendingActions = [pending('a'), pending('b')];
  page.linkProposals('answer-a', [page.pendingActions[0]]);
  page.linkProposals('answer-b', [page.pendingActions[1]]);
  page.jumpToNextProposal();
  assert.equal(scroll.length, 0, 'no guessed fallback position before layout');
  page.rememberProposalAnchor('a', 180);
  page.rememberMessageAnchor('answer-a', 420);
  assert.deepEqual(scroll[0], { kind: 'position', xOffset: 0, yOffset: 592, animation: false });
  page.rememberMessageAnchor('answer-b', 970);
  page.rememberProposalAnchor('b', 140);
  page.jumpToNextProposal();
  assert.equal(scroll.at(-1).yOffset, 1102);
  page.jumpToNextProposal();
  assert.equal(scroll.at(-1).yOffset, 592);
  assert.equal(page.scrollForNewMessage, false);
});

test('reading an older answer preserves scroll when a new response arrives and exposes an explicit latest action', async () => {
  const response = deferred();
  const { page, scroll } = await harness({ chat: () => response.promise });
  page.prompt = '正在等待的请求';
  const sending = page.send();
  page.contentHeight = 2000;
  page.viewportHeight = 400;
  page.recordScrollOffset(100);
  page.chatContentChanged(2050);
  assert.equal(scroll.length, 0, 'manual upward scrolling cancels a pending user-message auto-scroll');
  response.resolve({ session_id: 's', message: '新回答', pending_actions: [] });
  await sending;
  page.chatContentChanged(2200);
  assert.equal(page.unreadMessages, 1);
  assert.equal(scroll.length, 0);
  page.viewLatest();
  assert.deepEqual(scroll, [{ kind: 'edge', edge: 'bottom' }]);
  assert.equal(page.unreadMessages, 0);
});

test('chat viewport shrink follows the latest answer without needing content growth or a new-message flag', async () => {
  const { page, scroll, calls } = await harness();
  page.appendMessage('assistant', '已显示的长回答');
  page.contentHeight = 1800; page.viewportHeight = 400; page.scrollOffset = 1400;
  page.followLatest = true; page.scrollForNewMessage = false; page.unreadMessages = 2;
  page.prompt = '尚未发送的草稿';
  page.chatViewportChanged(220);
  assert.equal(page.viewportHeight, 220);
  assert.equal(page.contentHeight, 1800, 'keyboard or composer growth does not require a content-size event');
  assert.deepEqual(scroll, [{ kind: 'edge', edge: 'bottom' }]);
  assert.equal(page.unreadMessages, 0);
  assert.equal(page.followLatest, true);
  assert.equal(page.scrollOffset, 1400, 'only measured scroll callbacks update the recorded offset');
  assert.equal(page.prompt, '尚未发送的草稿');
  assert.deepEqual(calls, [], 'a viewport change never sends or writes');
});

test('chat viewport changes preserve a reader of older messages and their unsent draft', async () => {
  const { page, scroll } = await harness();
  page.appendMessage('assistant', '正在阅读的旧回答');
  page.contentHeight = 1800; page.viewportHeight = 400; page.scrollOffset = 120;
  page.followLatest = false; page.scrollForNewMessage = false; page.unreadMessages = 3;
  page.prompt = '编辑中的多行\n草稿';
  page.chatViewportChanged(220);
  page.chatViewportChanged(480);
  assert.equal(page.viewportHeight, 480);
  assert.deepEqual(scroll, []);
  assert.equal(page.followLatest, false);
  assert.equal(page.scrollForNewMessage, false);
  assert.equal(page.scrollOffset, 120);
  assert.equal(page.unreadMessages, 3);
  assert.equal(page.prompt, '编辑中的多行\n草稿');
});

test('chat viewport changes do not scroll a hidden conversation or the empty welcome page', async () => {
  for (const state of ['hidden', 'welcome']) {
    const { page, scroll } = await harness();
    if (state === 'hidden') { page.appendMessage('assistant', '隐藏会话的回答'); page.voiceActive = false; }
    page.viewportHeight = 400; page.followLatest = true; page.unreadMessages = 1;
    page.chatViewportChanged(220);
    assert.equal(page.viewportHeight, 220);
    assert.deepEqual(scroll, [], state);
    assert.equal(page.unreadMessages, 1, state);
  }
});

test('chat viewport ignores unmeasured, non-finite and repeated heights without issuing scroll commands', async () => {
  const { page, scroll } = await harness();
  page.appendMessage('assistant', '当前回答');
  page.viewportHeight = 400; page.followLatest = true; page.unreadMessages = 2;
  for (const height of [0, -1, NaN, Infinity, -Infinity, 400]) { page.chatViewportChanged(height); }
  assert.equal(page.viewportHeight, 400);
  assert.deepEqual(scroll, []);
  assert.equal(page.unreadMessages, 2);
});

test('chat viewport resize does not steal an options restoration or pending proposal jump', async () => {
  for (const guarded of ['restore', 'jump', 'options']) {
    const { page, scroll } = await harness();
    page.appendMessage('assistant', '包含提案的回答');
    page.viewportHeight = 400; page.followLatest = true; page.unreadMessages = 2;
    page.scrollOffset = 840; page.restoreOptionsOffset = guarded === 'restore' ? 840 : -1;
    page.pendingJumpId = guarded === 'jump' ? 'pending-proposal' : '';
    page.optionsExpanded = guarded === 'options';
    page.messageAnchors = [{ id: 'answer', y: 420 }];
    page.proposalAnchors = [{ id: 'pending-proposal', y: 180 }];
    page.chatViewportChanged(220);
    assert.equal(page.viewportHeight, 220);
    assert.deepEqual(scroll, [], guarded);
    assert.equal(page.scrollOffset, 840, guarded);
    assert.equal(page.restoreOptionsOffset, guarded === 'restore' ? 840 : -1, guarded);
    assert.equal(page.pendingJumpId, guarded === 'jump' ? 'pending-proposal' : '', guarded);
    assert.equal(page.optionsExpanded, guarded === 'options', guarded);
    assert.equal(page.unreadMessages, 2, guarded);
    assert.deepEqual(page.messageAnchors, [{ id: 'answer', y: 420 }], guarded);
    assert.deepEqual(page.proposalAnchors, [{ id: 'pending-proposal', y: 180 }], guarded);
  }
});

test('hidden-page responses do not move its scroll or replace the draft on return', async () => {
  const { page, scroll } = await harness();
  let suspended = 0;
  page.voiceInteraction = { suspend: () => { suspended++; } };
  page.prompt = '返回后继续写的草稿';
  page.voiceActive = false;
  page.voiceActivityChanged();
  page.appendMessage('assistant', '隐藏期间收到的回答');
  page.chatContentChanged(1800);
  page.voiceActive = true;
  page.chatContentChanged(1800);
  assert.equal(suspended, 1);
  assert.equal(scroll.length, 0);
  assert.equal(page.unreadMessages, 1);
  assert.equal(page.prompt, '返回后继续写的草稿');
});

test('model options restore the previous reading position and busy requests keep their original model', async () => {
  const { page, scroll, calls } = await harness();
  page.scrollOffset = 840;
  page.toggleOptions();
  assert.equal(page.optionsExpanded, true);
  assert.equal(scroll.at(-1).yOffset, 0);
  await Promise.resolve(); await Promise.resolve();
  await page.loadModels();
  page.selectModel('deepseek-flash');
  assert.equal(page.model, 'deepseek-flash');
  page.loading = true;
  page.selectModel('deepseek-v4-pro');
  assert.equal(page.model, 'deepseek-flash');
  page.toggleOptions();
  page.chatContentChanged(2000);
  assert.equal(scroll.at(-1).yOffset, 840);
  assert.equal(page.optionsExpanded, false);
  assert.equal(calls.length, 0);
});

test('late confirmation and status responses cannot recreate feedback after teardown or deletion', async () => {
  for (const method of ['confirmAction', 'actionStatus']) {
    for (const teardown of ['dispose', 'delete']) {
      const response = deferred(), action = pending('a');
      const { page } = await harness({ [method]: () => response.promise });
      page.pendingActions = [action];
      const request = method === 'confirmAction' ? page.decide(action, true) : page.checkDecision(action);
      if (teardown === 'dispose') page.aboutToDisappear();
      else { page.deletedSessionId = page.sessionId; page.sessionDeleted(); }
      response.resolve(method === 'confirmAction' ? confirmed(action) : confirmed(action).action);
      await request;
      assert.deepEqual(page.decisionFeedback, []);
      assert.ok(!page.pendingActions.some(a => a.status === 'confirmed'));
    }
  }
});

test('deletion clears proposal associations but an old request cannot clear a newer request loading state', async () => {
  const oldResponse = deferred(), newResponse = deferred();
  const oldStarted = deferred();
  const responses = [oldResponse, newResponse];
  const { page } = await harness({ chat: () => { oldStarted.resolve(); return responses.shift().promise; } });
  page.pendingActions = [pending('old')];
  page.linkProposals('old-answer', page.pendingActions);
  page.rememberMessageAnchor('old-answer', 100);
  page.rememberProposalAnchor('old', 50);
  page.prompt = '旧请求';
  const oldSend = page.send();
  await oldStarted.promise;
  page.deletedSessionId = page.sessionId;
  page.sessionDeleted();
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(page.proposalOrigins, []);
  assert.deepEqual(page.messageAnchors, []);
  page.prompt = '新会话请求';
  const newSend = page.send();
  oldResponse.resolve({ session_id: 'old', message: '迟到', pending_actions: [pending('late')] });
  await oldSend;
  assert.equal(page.loading, true);
  assert.deepEqual(page.proposalOrigins, []);
  newResponse.resolve({ session_id: 'new', message: '当前回答', pending_actions: [pending('current')] });
  await newSend;
  assert.equal(page.loading, false);
  assert.deepEqual(page.pendingActions.map(a => a.proposal_id), ['current']);
});
