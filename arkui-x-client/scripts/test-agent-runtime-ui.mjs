import './helpers/theme-fixture.mjs';
import { conversationDependencies, assistantDraftKey } from './helpers/conversation-fixture.mjs';
import { reliability } from './helpers/course-review-fixture.mjs';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripThemeTypeScriptTypes as stripTypeScriptTypes } from './helpers/theme-fixture.mjs';
import { test } from 'node:test';
import { makeDraftFixture, shanghaiDate, makeRunController, runSnapshot } from './helpers/agent-run-ui-fixture.mjs';

const load = async name => {
  const code = readFileSync(new URL(`../entry/src/main/ets/utils/${name}.ets`, import.meta.url), 'utf8')
    .replace(/^import \{[\s\S]*?\} from '[^']+';\r?\n/gm, '');
  return import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(code)).toString('base64')}`);
};
const feedback = await load('AgentFeedback');
const source = readFileSync(new URL('../entry/src/main/ets/pages/AgentPage.ets', import.meta.url), 'utf8');
const controllerSource = source.slice(0, source.indexOf('\n  @Builder')).replace(/^import [^\n]+;\r?\n/gm, '')
  .replace(/^@Component\r?\n/m, '').replace(/@(Prop|State)\s+|@Watch\('[^']+'\)\s*/g, '')
  .replace('export struct AgentPage', 'class AgentPage') + '\n}\n';
const makePage = new Function('CampusFlowApi', 'Scroller', 'CampusFlowRequestError', 'displayToolTraces', 'mergeActions',
  'restoreDraft', 'localRequestFailure', 'AppTheme', 'localHistory', 'AgentRunController', 'localDrafts', 'shanghaiDate', ...Object.keys(reliability), ...Object.keys(conversationDependencies),
  stripTypeScriptTypes(controllerSource) + '\nreturn AgentPage;');
const now = '2028-10-20T08:00:00+08:00';
const oldId = '11111111-1111-4111-8111-111111111111';
const history = (...contents) => contents.map((content, index) => ({ role: index % 2 === 0 ? 'user' : 'assistant', content, created_at: now }));
const turn = (message = '完整回答', actions = []) => ({ session_id: 'fixture', message, pending_actions: actions, tool_traces: [] });
const proposal = id => ({ proposal_id: id, action: 'create', kind: 'task', title: '复习', start_at: null, end_at: null,
  reminder_minutes: null, reason: null, payload: {}, conflicts: [], status: 'pending' });
const deferred = () => { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; };
const settle = async () => { for (let i = 0; i < 8; i++) await Promise.resolve(); };

test('running refresh phase is visible while terminal statuses retain their meaning', async () => {
  const { page } = await harness();
  const labels = { refreshing: '正在更新校园资料', reading: '正在读取资料', planning: '正在分析', proposal: '正在生成提案' };
  for (const [phase, label] of Object.entries(labels)) {
    assert.equal(page.runStatusLabel({ status: 'running', phase }), label);
  }
  assert.equal(page.runStatusLabel({ status: 'succeeded', phase: 'refreshing' }), '已完成');
  assert.equal(page.runStatusLabel({ status: 'cancelled', phase: 'refreshing' }), '已取消');
  assert.equal(page.runStatusLabel({ status: 'running' }), '正在运行');
});

test('conversation confirmation from a long reply scrolls into view without switching, sending or replacing drafts', async () => {
  for (const entry of ['new', 'run', 'draft']) {
    const { page, calls, saves, drafts } = await harness();
    const scrolls = [];
    page.chatScroller = { scrollTo: value => scrolls.push(value), scrollEdge: () => { throw Error('confirmation must not follow the old reply bottom'); } };
    page.appendMessage('assistant', '较长的既有回复'.repeat(500));
    page.prompt = '保留当前未发送草稿';
    page.scrollForNewMessage = true; page.restoreOptionsOffset = -1;
    page.contentHeight = 2500; page.followLatest = true;
    const session = page.sessionId;
    const key = assistantDraftKey('other-session');
    if (entry === 'draft') {
      drafts.store.stage(drafts.lease, key, { text: '另一段未发送草稿', sessionId: 'other-session', anchorDate: '2026-10-26', timezone: 'Asia/Shanghai' });
    }
    const record = drafts.store.read(drafts.lease, key);
    if (entry === 'new') page.requestConversation();
    else if (entry === 'run') page.requestRunConversation('other-session', oldId);
    else page.requestDraftConversation(record);
    assert.equal(page.switchConfirmOpen, true, entry);
    assert.equal(page.restoreOptionsOffset, 0, entry);
    assert.equal(page.scrollForNewMessage, false, entry);
    page.chatContentChanged(2800);
    assert.deepEqual(scrolls, [{ xOffset: 0, yOffset: 0, animation: false }], entry);
    assert.equal(page.restoreOptionsOffset, -1);
    assert.equal(page.sessionId, session);
    assert.equal(page.prompt, '保留当前未发送草稿');
    assert.deepEqual(drafts.store.read(drafts.lease, key), record);
    assert.deepEqual(calls, [], 'requesting confirmation cannot POST or query a different conversation');
    assert.deepEqual(saves, []);
  }
});

test('recent runs replace model options at the top and closing the list never submits or changes the draft', async () => {
  const { page, calls } = await harness({ recentAgentRuns: async () => ({ items: [] }) });
  page.prompt = '保留未发送的草稿'; page.optionsExpanded = true; page.scrollForNewMessage = true;
  await page.toggleRunRecords();
  assert.equal(page.runRecordsExpanded, true);
  assert.equal(page.optionsExpanded, false);
  assert.equal(page.restoreOptionsOffset, 0);
  assert.equal(page.scrollForNewMessage, false);
  await page.toggleRunRecords();
  assert.equal(page.runRecordsExpanded, false);
  assert.equal(page.prompt, '保留未发送的草稿');
  assert.deepEqual(calls.map(call => call.name), ['recentAgentRuns']);
});

test('recovered runs name their own untitled conversation without renaming another conversation', async () => {
  const { page } = await harness();
  const request = { run_id: oldId, session_id: page.sessionId, message: '结合课程安排一周复习', model: 'deepseek-v4-pro' };
  page.sessionTitle = '新对话';
  page.runChanged({ ...page.runState, runId: oldId, snapshot: runSnapshot(request, null, { status: 'running' }) });
  assert.equal(page.sessionTitle, request.message);
  page.sessionTitle = '本人设置的标题';
  page.runChanged({ ...page.runState, snapshot: runSnapshot({ ...request, message: '其他问题' }, null, { status: 'running' }) });
  assert.equal(page.sessionTitle, '本人设置的标题');
  page.sessionTitle = '新对话';
  page.runChanged({ ...page.runState, snapshot: runSnapshot({ ...request, session_id: 'different-conversation' }, null, { status: 'running' }) });
  assert.equal(page.sessionTitle, '新对话');
});

test('an incomplete run keeps the actual tool outcomes and failure identity without claiming success or replaying', async () => {
  let request;
  const tools = [
    { call_id: 'schedule-read', tool_name: 'get_schedule', label: '读取课表', state: 'success', summary: '已读取课程' },
    { call_id: 'plan-read', tool_name: 'get_planning', label: '读取待办', state: 'error', summary: '暂未读到最新任务' }
  ];
  const { page, calls, saves } = await harness({ startAgentRun: async value => {
    request = value;
    return runSnapshot(value, null, { status: 'budget_exceeded', seq: 6, partial_answer: '已收到的回答片段',
      model_calls: 3, tool_calls: 2, tool_progress: tools, error_code: 'RUN_BUDGET_EXCEEDED', error_message: '本轮未完成' });
  } });
  page.prompt = '结合近期课程安排复习'; await page.send();
  const answer = page.messages.find(message => message.id === `run-${request.run_id}-assistant`);
  assert.deepEqual(answer.tools.map(({ label, state, summary }) => ({ label, state, summary })),
    tools.map(({ label, state, summary }) => ({ label, state, summary })));
  assert.equal(answer.incomplete, true);
  assert.deepEqual(page.pendingActions, []);
  assert.equal(page.messages.find(message => message.role === 'feedback').failureCode, 'RUN_BUDGET_EXCEEDED');
  assert.equal(calls.filter(call => call.name === 'startAgentRun').length, 1);
  assert.deepEqual(saves, [], 'incomplete runs do not become committed chat history');
});

test('failure is presented with its partial reply once while standalone errors remain reachable', async () => {
  const { page } = await harness({ startAgentRun: async request => runSnapshot(request, null, {
    status: 'budget_exceeded', seq: 4, partial_answer: '仅收到这一段', error_code: 'RUN_BUDGET_EXCEEDED', error_message: '尚未完成'
  }) });
  page.prompt = '原问题'; await page.send();
  const feedbackMessage = page.messages.find(message => message.role === 'feedback');
  const reply = page.messages.find(message => message.role === 'assistant' && message.id !== 'welcome');
  assert.ok(feedbackMessage, 'the original failure remains in state');
  assert.ok(!page.visibleMessages().some(message => message.id === feedbackMessage.id));
  assert.deepEqual(page.failuresForReply(reply).map(message => message.id), [feedbackMessage.id]);
  const standalone = page.appendMessage('feedback', '独立提示');
  assert.ok(page.visibleMessages().some(message => message.id === standalone));
  const before = page.messages.length;
  page.visibleMessages(); page.failuresForReply(reply);
  assert.equal(page.messages.length, before, 'presentation cannot delete message state');
});

test('failure recovery exposes a long draft for editing and never replaces text written meanwhile', async () => {
  const text = '结合我的近期课程，帮我制定一周复习计划，分解为里程碑和待办，先生成提案。';
  const { page } = await harness({ startAgentRun: async request => runSnapshot(request, null, {
    status: 'failed', error_code: 'RUN_FAILED', error_message: '本次未完成'
  }) });
  page.prompt = text; page.suggestionNotice = '建议已填入，请检查后手动发送。'; await page.send();
  assert.equal(page.prompt, text);
  assert.equal(page.composerExpanded, true);
  assert.equal(page.suggestionNotice, '');
  const failure = page.messages.find(message => message.role === 'feedback');
  assert.ok(page.visibleMessages().some(message => message.id === failure.id), 'a failure with no partial reply stays visible');
  assert.ok(page.visibleMessages().every(message => message.role !== 'assistant'), 'empty placeholder is not a reply');
  page.prompt = '保留这段新草稿'; page.restoreFailedInput(failure); assert.equal(page.prompt, '保留这段新草稿');
  page.prompt = ''; page.composerExpanded = false; page.restoreFailedInput(failure);
  assert.equal(page.prompt, text); assert.equal(page.composerExpanded, true);
  page.voiceActive = false; page.prompt = ''; page.restoreFailedInput(failure); assert.equal(page.prompt, '');
});

async function harness(handlers = {}) {
  const calls = [], saves = [];
  class Api {
    invoke(name, args) { calls.push({ name, args }); assert.equal(typeof handlers[name], 'function', `unexpected ${name}`); return handlers[name](...args); }
    startAgentRun(...args) { return this.invoke('startAgentRun', args); }
    agentRun(...args) { return this.invoke('agentRun', args); }
    agentRunEvents(...args) { return this.invoke('agentRunEvents', args); }
    cancelAgentRun(...args) { return this.invoke('cancelAgentRun', args); }
    recentAgentRuns(...args) { return this.invoke('recentAgentRuns', args); }
    actionStatus(...args) { return this.invoke('actionStatus', args); }
    history(...args) { return this.invoke('history', args); }
  }
  const drafts = await makeDraftFixture();
  const Page = makePage(Api, class {}, feedback.CampusFlowRequestError, feedback.displayToolTraces, feedback.mergeActions,
    feedback.restoreDraft, feedback.localRequestFailure, {}, { save: async (...args) => { saves.push(args); return true; } },
    makeRunController(feedback.CampusFlowRequestError, feedback.localRequestFailure), drafts.store, shanghaiDate, ...Object.values(reliability), ...Object.values(conversationDependencies));
  const page = new Page(); page.baseUrl = 'https://fixture.invalid'; page.token = 'secret-token'; page.voiceActive = true;
  page.historyScope = 'account-a';
  page.draftLease = drafts.lease;
  page.draftLeaseChanged();
  return { page, calls, saves, drafts };
}

test('actual snapshots replace partial text after model reset and bind final proposals to the same run bubble', async () => {
  let request, next;
  const { page, saves } = await harness({ startAgentRun: async value => { request = value; return runSnapshot(value, null, { status: 'running', seq: 1 }); },
    agentRunEvents: async () => ({ run_id: request.run_id, events: [], snapshot: next }), history: async () => history('问题', '最终回答') });
  page.prompt = '问题'; await page.send();
  const id = `run-${request.run_id}-assistant`;
  next = runSnapshot(request, null, { status: 'running', seq: 3, partial_answer: '工具前的真实片段' });
  await page.runInteraction.pollEvents();
  assert.equal(page.messages.find(m => m.id === id).content, '工具前的真实片段');
  next = runSnapshot(request, null, { status: 'running', seq: 5, partial_answer: '重置后的片段', tool_calls: 1,
    tool_progress: [{ call_id: 'call-1', tool_name: 'schedule', label: '读取课表', state: 'success', summary: '查到两门课' }] });
  await page.runInteraction.pollEvents();
  assert.equal(page.messages.find(m => m.id === id).content, '重置后的片段', 'never concatenate answer_reset turns');
  page.appendMessage('assistant', '另一个位置的消息');
  next = runSnapshot(request, turn('最终回答', [proposal('proposal-a')]), { seq: 8 });
  await page.runInteraction.pollEvents(); await settle();
  assert.equal(page.messages.filter(m => m.id === id).length, 1);
  assert.equal(page.messages.find(m => m.id === id).incomplete, false);
  assert.equal(page.proposalOrigins.find(p => p.proposalId === 'proposal-a').messageId, id);
  assert.equal(page.loading, false);
  assert.deepEqual(saves[0][2], history('问题', '最终回答'));
});

test('cancelled runs keep real partial content, preserve a new draft, cannot speak incomplete text and are not cached', async () => {
  let request;
  const { page, saves, calls } = await harness({ startAgentRun: async value => { request = value; return runSnapshot(value, null,
    { status: 'running', seq: 4, partial_answer: '已收到的一段' }); },
    cancelAgentRun: async () => runSnapshot(request, null, { status: 'cancelled', seq: 5, partial_answer: '已收到的一段' }) });
  page.prompt = '原问题'; await page.send(); page.prompt = '新的草稿';
  await page.cancelRun();
  const answer = page.messages.find(m => m.id === `run-${request.run_id}-assistant`);
  assert.equal(answer.content, '已收到的一段'); assert.equal(answer.incomplete, true);
  assert.equal(page.prompt, '新的草稿'); assert.equal(page.loading, false);
  page.voiceController = () => { throw Error('incomplete answers must not start playback'); };
  await page.speakReply(answer);
  assert.equal(saves.length, 0); assert.deepEqual(calls.map(c => c.name), ['startAgentRun', 'cancelAgentRun']);
});

test('a cancellation race displaying succeeded does not invent cancellation and caches the committed result', async () => {
  let request;
  const { page, saves } = await harness({ startAgentRun: async value => { request = value; return runSnapshot(value, null, { status: 'running' }); },
    cancelAgentRun: async () => runSnapshot(request, turn(), { seq: 5 }), history: async () => history('问题', '完整回答') });
  page.prompt = '问题'; await page.send(); await page.cancelRun(); await settle();
  assert.equal(page.runState.snapshot.status, 'succeeded'); assert.equal(page.loading, false);
  assert.equal(page.messages.filter(m => m.incomplete).length, 0); assert.equal(saves.length, 1);
});

test('unknown creation never becomes another run; explicit retry keeps the complete frozen request', async () => {
  const requests = []; let created;
  const { page, calls } = await harness({ startAgentRun: async request => {
    requests.push(structuredClone(request)); if (requests.length === 1) throw feedback.localRequestFailure('NETWORK_ERROR');
    created = runSnapshot(request, turn()); return created;
  }, agentRun: async () => { throw new feedback.CampusFlowRequestError(404, 'RUN_NOT_FOUND', '未找到'); },
  history: async () => history('原问题', '完整回答') });
  page.prompt = '原问题'; await page.send(); const runId = page.runState.runId;
  page.prompt = '后写的草稿'; await page.send(); await page.refreshRun();
  assert.equal(requests.length, 1); assert.equal(page.loading, true);
  await page.retryRunStart(); await settle();
  assert.deepEqual(requests[1], requests[0]); assert.equal(page.runState.runId, runId);
  assert.equal(page.prompt, '后写的草稿'); assert.equal(page.messages.filter(m => m.role === 'user').length, 1);
  assert.ok(calls.every(c => c.name !== 'chat'));
});

test('hiding pauses reads without cancelling or restoring the submitted prompt; return recovers original identity', async () => {
  let request;
  const { page, calls } = await harness({ startAgentRun: async value => { request = value; return runSnapshot(value, null, { status: 'running' }); },
    agentRun: async () => runSnapshot(request, turn(), { seq: 4 }), history: async () => history('问题', '完整回答') });
  page.prompt = '问题'; await page.send();
  page.voiceActive = false; page.voiceActivityChanged();
  assert.equal(page.prompt, ''); assert.equal(page.messages.filter(m => m.role === 'feedback').length, 0);
  assert.equal(calls.filter(c => c.name === 'cancelAgentRun').length, 0);
  page.voiceActive = true; page.voiceActivityChanged(); await settle();
  assert.equal(page.runState.snapshot.status, 'succeeded');
  assert.equal(calls.filter(c => c.name === 'startAgentRun').length, 1);
});

test('recovering a recent old run keeps its bubble and full history read-only without reviving old proposals or replaying a POST', async () => {
  const request = { run_id: oldId, session_id: 'older-session', model: 'deepseek-flash', message: '旧问题' };
  const snapshot = runSnapshot(request, turn('旧回答', [proposal('older-proposal')]));
  const full = history('更早的问题', '更早的回答', '旧问题', '旧回答');
  const { page, calls, saves } = await harness({ recentAgentRuns: async limit => { assert.equal(limit, 20); return [snapshot]; },
    agentRun: async () => snapshot, history: async id => { assert.equal(id, request.session_id); return full; } });
  const originalSession = page.sessionId; page.prompt = '当前草稿';
  await page.toggleRunRecords(); await page.recoverRun(oldId); await settle(); await page.refreshRun(); await settle();
  assert.equal(page.sessionId, originalSession); assert.equal(page.prompt, '当前草稿');
  assert.equal(page.messages.filter(m => m.id === `run-${oldId}-assistant`).length, 1);
  assert.deepEqual(page.proposalOrigins, [], 'a saved old pending snapshot is not a current executable proposal');
  assert.deepEqual(page.pendingActions, []);
  assert.ok(page.messages.find(m => m.id === `run-${oldId}-user`).restored);
  assert.ok(saves.length >= 1); assert.ok(saves.every(save => save[1].session_id === request.session_id && save[2].length === 4));
  assert.ok(calls.every(c => c.name !== 'startAgentRun'));
});

test('out-of-order history reads cannot replace a newer complete session with an older pair', async () => {
  const oldRead = deferred(); let reads = 0;
  const full = history('一问', '一答', '二问', '二答');
  const { page, saves } = await harness({ startAgentRun: async request => runSnapshot(request, turn(request.message === '一问' ? '一答' : '二答')),
    history: async () => ++reads === 1 ? oldRead.promise : full });
  page.prompt = '一问'; await page.send(); page.prompt = '二问'; await page.send(); await settle();
  oldRead.resolve(history('一问', '一答')); await settle();
  assert.equal(saves.length, 1); assert.deepEqual(saves[0][2], full); assert.deepEqual(page.savedMessages, full);
});

test('failed history sync preserves succeeded state and can be retried; logout suppresses a late history write', async () => {
  let snapshot, reads = 0;
  const { page, saves } = await harness({ startAgentRun: async request => { snapshot = runSnapshot(request, turn()); return snapshot; },
    agentRun: async () => snapshot, history: async () => { if (++reads === 1) throw Error('private-secret'); return history('问题', '完整回答'); } });
  page.prompt = '问题'; await page.send(); await settle();
  assert.equal(page.runState.snapshot.status, 'succeeded'); assert.match(page.cacheNotice, /保存失败/);
  assert.doesNotMatch(page.cacheNotice, /private-secret/);
  await page.refreshRun(); assert.equal(saves.length, 1);
  const late = deferred();
  const second = await harness({ startAgentRun: async request => runSnapshot(request, turn()), history: () => late.promise });
  second.page.prompt = '问题'; await second.page.send(); second.page.aboutToDisappear();
  late.resolve(history('问题', '完整回答')); await settle(); assert.equal(second.saves.length, 0);
});

test('cache receives only white-listed history fields and hidden sends keep drafts untouched', async () => {
  const records = history('问题', '完整回答').map(item => ({ ...item, token: 'must-not-cache', raw_tools: [] }));
  const { page, saves, calls } = await harness({ startAgentRun: async request => runSnapshot(request, turn()), history: async () => records });
  page.voiceActive = false; page.prompt = '问题'; await page.send(); assert.equal(page.prompt, '问题'); assert.equal(calls.length, 0);
  page.voiceActive = true; await page.send(); await settle();
  assert.deepEqual(saves[0][2], history('问题', '完整回答')); assert.doesNotMatch(JSON.stringify(saves), /must-not-cache|raw_tools|secret-token/);
});

test('deleting a read-only recovered old session removes its run and pending cache read without touching current content', async () => {
  const request = { run_id: oldId, session_id: 'deleted-old-session', model: 'deepseek-flash', message: '旧问题' };
  const snapshot = runSnapshot(request, turn('旧回答', [proposal('delete-old-proposal')]));
  const reading = deferred();
  const { page, saves } = await harness({ agentRun: async () => snapshot, history: () => reading.promise });
  const currentSession = page.sessionId;
  page.prompt = '当前草稿'; const currentMessage = page.appendMessage('assistant', '当前会话内容');
  await page.recoverRun(oldId);
  assert.deepEqual(page.pendingActions, [], 'recovery never resurrects the old proposal snapshot');
  page.deletedSessionId = request.session_id; page.sessionDeleted();
  reading.resolve(history('旧问题', '旧回答')); await settle();
  assert.equal(page.sessionId, currentSession); assert.equal(page.prompt, '当前草稿');
  assert.ok(page.messages.some(m => m.id === currentMessage));
  assert.ok(page.messages.every(m => m.runId !== oldId)); assert.deepEqual(page.pendingActions, []);
  assert.deepEqual(page.proposalOrigins, []); assert.equal(page.runState.runId, ''); assert.equal(saves.length, 0);
});

test('a user can cancel a known active run while a manual status GET is still waiting', async () => {
  let request; const reading = deferred();
  const { page, calls } = await harness({ startAgentRun: async value => { request = value; return runSnapshot(value, null, { status: 'running' }); },
    agentRun: () => reading.promise, cancelAgentRun: async () => runSnapshot(request, null, { status: 'cancelled', seq: 3 }) });
  page.prompt = '问题'; await page.send(); const checking = page.refreshRun();
  assert.equal(page.runState.phase, 'checking'); assert.equal(page.canCancelRun(), true);
  await page.cancelRun();
  reading.resolve(runSnapshot(request, null, { status: 'running', seq: 2 })); await checking;
  assert.equal(page.runState.snapshot.status, 'cancelled'); assert.equal(page.loading, false);
  assert.deepEqual(calls.map(c => c.name), ['startAgentRun', 'agentRun', 'cancelAgentRun']);
});

test('a deleted run ID clears its current run content and starts a fresh session without restoring or replaying the old prompt', async () => {
  let request;
  const { page, calls } = await harness({ startAgentRun: async value => { request = value; return runSnapshot(value, null, { status: 'running' }); },
    agentRun: async () => { throw new feedback.CampusFlowRequestError(410, 'RUN_DELETED', '已删除'); } });
  const previous = page.sessionId; page.prompt = '被删除的原问题'; await page.send(); page.prompt = '新草稿';
  await page.refreshRun();
  assert.equal(page.prompt, '新草稿'); assert.notEqual(page.sessionId, previous); assert.equal(page.loading, false);
  assert.ok(page.messages.every(m => m.runId !== request.run_id)); assert.equal(page.runState.canRetryStart, false);
  assert.match(page.cacheNotice, /已.*删除/);
  await page.retryRunStart(); assert.equal(calls.filter(c => c.name === 'startAgentRun').length, 1);
});

test('a definitive model failure restores an empty draft, keeps only real fragments and displays a safe actionable reason', async () => {
  const { page, saves } = await harness({ startAgentRun: async request => runSnapshot(request, null, {
    status: 'failed', partial_answer: '', error_code: 'MODEL_KEY_REQUIRED', error_message: 'private-secret-provider-detail' }) });
  page.prompt = '保留问题'; await page.send();
  assert.equal(page.loading, false); assert.equal(page.prompt, '保留问题'); assert.equal(page.runState.snapshot.status, 'failed');
  assert.match(page.runState.message, /密钥|Key|凭据/);
  assert.doesNotMatch(JSON.stringify(page.messages), /private-secret-provider-detail/); assert.equal(saves.length, 0);
});

function preparedPlan(extra = {}) {
  const task = { candidate_id: 'candidate-prepared', allow_during_course: false, title: '复习课程',
    start_at: '2028-10-20T14:00:00+08:00', end_at: '2028-10-20T15:00:00+08:00', reminder_minutes: 15, location: '图书馆' };
  return { proposal_id: 'prepared-plan-a', contract_version: 2, action: 'create', kind: 'plan', title: '一周复习计划',
    start_at: null, end_at: null, reminder_minutes: null, reason: null, conflicts: [], warnings: [], status: 'pending',
    created_at: new Date().toISOString(), expires_at: new Date(Date.now() + 900000).toISOString(),
    target_task_id: null, target_plan_id: null, before_task: null, before_plan: null, receipt: null,
    payload: { summary: '按近期课程复习', target_date: '2028-10-26', milestones: [{ title: '基础复习', due_at: null, tasks: [task] }] },
    course_policy_version: 1, state_version: { timetable: 1, planning: 1 },
    course_reviews: [{ candidate_id: task.candidate_id, task_id: null, allow_during_course: false, state: 'none',
      review_digest: 'a'.repeat(64), candidate_digest: 'b'.repeat(64), requires_acknowledgement: false, revoke_only: false,
      school: '测试学校', campus: '测试校区', timezone: 'Asia/Shanghai', timetable_version: 1, planning_version: 1,
      task_version: null, overlaps: [] }], ...extra };
}

test('three successful tools followed by failed context recover only the canonical proposal with no resend, confirmation or history', async () => {
  const proposal = preparedPlan(); let request, next;
  assert.equal(reliability.canConfirmAction(proposal), true);
  const tools = ['get_schedule', 'get_planning', 'propose_plan'].map((tool_name, index) => ({
    call_id: `prepared-tool-${index}`, tool_name, label: tool_name, state: 'success', summary: '已完成' }));
  const { page, calls, saves } = await harness({ startAgentRun: async value => {
    request = value; return runSnapshot(value, null, { status: 'running', seq: 1 });
  }, agentRunEvents: async () => ({ run_id: request.run_id, events: [], snapshot: next }),
  actionStatus: async id => { assert.equal(id, proposal.proposal_id); return structuredClone(proposal); } });
  page.prompt = '结合近期课程制定一周复习计划'; await page.send();
  next = runSnapshot(request, null, { status: 'budget_exceeded', seq: 9, partial_answer: '', tool_calls: 3,
    tool_progress: tools, prepared_actions: [proposal], error_code: 'RUN_CONTEXT_LIMIT', error_message: '回复未完成' });
  await page.runInteraction.pollEvents(); await settle();
  assert.equal(page.runState.snapshot.status, 'budget_exceeded');
  assert.equal(page.runState.snapshot.result, null);
  assert.equal(calls.filter(call => call.name === 'actionStatus').length, 1);
  assert.deepEqual(page.pendingActions.map(action => action.proposal_id), [proposal.proposal_id]);
  const reply = page.visibleMessages().find(message => message.id === `run-${request.run_id}-assistant`);
  assert.ok(reply, 'a canonical proposal keeps its assistant anchor even without partial text');
  assert.equal(reply.incomplete, true);
  assert.deepEqual(page.actionsForMessage(reply.id).map(action => action.proposal_id), [proposal.proposal_id]);
  assert.equal(page.failuresForReply(reply).length, 1);
  assert.equal(calls.filter(call => call.name === 'startAgentRun').length, 1);
  assert.equal(calls.filter(call => call.name === 'history').length, 0);
  assert.equal(saves.length, 0);
  assert.equal(page.prompt, request.message);
});

test('failed preparation with no partial text or tool display still exposes the verified card, not an empty success', async () => {
  const proposal = preparedPlan(); let request;
  const { page, calls } = await harness({ startAgentRun: async value => {
    request = value; return runSnapshot(value, null, { status: 'failed', partial_answer: '', prepared_actions: [proposal],
      error_code: 'RUN_CONTEXT_LIMIT', error_message: '未完成' });
  }, actionStatus: async () => structuredClone(proposal) });
  page.prompt = '制定计划'; await page.send(); await settle();
  const reply = page.visibleMessages().find(message => message.id === `run-${request.run_id}-assistant`);
  assert.ok(reply); assert.equal(reply.content, ''); assert.equal(reply.incomplete, true);
  assert.equal(page.actionsForMessage(reply.id).length, 1);
  assert.equal(page.visibleMessages().filter(message => message.role === 'feedback').length, 0, 'failure stays with the recovered card');
  assert.ok(calls.every(call => ['startAgentRun', 'actionStatus'].includes(call.name)));
});

test('prepared candidates never reactivate confirmed, cancelled, expired or altered canonical proposals', async () => {
  for (const mutate of [value => ({ ...value, status: 'confirmed' }), value => ({ ...value, status: 'cancelled' }),
    value => ({ ...value, title: '另一份方案' }), value => ({ ...value, expires_at: '2000-01-01T00:00:00Z' })]) {
    const proposal = preparedPlan();
    const { page, calls, saves } = await harness({ startAgentRun: async request => runSnapshot(request, null, {
      status: 'failed', prepared_actions: [proposal], error_code: 'RUN_CONTEXT_LIMIT', error_message: '未完成' }),
    actionStatus: async () => mutate(structuredClone(proposal)) });
    page.prompt = '制定计划'; await page.send(); await settle();
    assert.deepEqual(page.pendingActions, []); assert.equal(saves.length, 0);
    assert.ok(calls.every(call => ['startAgentRun', 'actionStatus'].includes(call.name)));
  }
});

test('late prepared-proposal reads cannot attach cards after account, session, foreground or run identity changes', async () => {
  for (const change of [page => page.userId = 'another-account', page => page.sessionId = 'another-session',
    page => page.voiceActive = false, page => page.conversationRevision++, page => page.runState = { ...page.runState, runId: 'another-run', snapshot: null }]) {
    const proposal = preparedPlan(), d = deferred();
    const { page, calls } = await harness({ startAgentRun: async request => runSnapshot(request, null, {
      status: 'failed', prepared_actions: [proposal], error_code: 'RUN_CONTEXT_LIMIT', error_message: '未完成' }),
    actionStatus: () => d.promise });
    page.prompt = '制定计划'; await page.send(); await settle();
    assert.equal(calls.filter(call => call.name === 'actionStatus').length, 1);
    change(page); d.resolve(proposal); await settle(); assert.deepEqual(page.pendingActions, []);
  }
});

test('cross-session prepared snapshots are never read into the current conversation', async () => {
  const { page, calls } = await harness();
  page.runChanged({ ...page.runState, phase: 'terminal', runId: oldId,
    snapshot: runSnapshot({ run_id: oldId, session_id: 'other-session', model: 'model', message: '其他请求' }, null,
      { status: 'failed', prepared_actions: [preparedPlan()], error_code: 'RUN_CONTEXT_LIMIT', error_message: '未完成' }) });
  await settle(); assert.deepEqual(page.pendingActions, []); assert.deepEqual(calls, []);
});

test('refreshing a recovered prepared card cannot leave it executable after the canonical proposal was cancelled', async () => {
  const proposal = preparedPlan(); let request, canonical = structuredClone(proposal);
  const { page, calls, saves } = await harness({ startAgentRun: async value => {
    request = value; return runSnapshot(value, null, { status: 'failed', prepared_actions: [proposal], error_code: 'RUN_CONTEXT_LIMIT', error_message: '未完成' });
  }, actionStatus: async () => structuredClone(canonical),
  agentRun: async () => runSnapshot(request, null, { status: 'failed', prepared_actions: [proposal], error_code: 'RUN_CONTEXT_LIMIT', error_message: '未完成' }) });
  page.prompt = '制定计划'; await page.send(); await settle();
  assert.equal(page.pendingActions[0].status, 'pending');
  canonical.status = 'cancelled'; await page.refreshRun(); await settle();
  assert.equal(page.pendingActions[0].status, 'cancelled');
  assert.equal(reliability.canConfirmAction(page.pendingActions[0]), false);
  assert.equal(calls.filter(call => call.name === 'startAgentRun').length, 1); assert.equal(saves.length, 0);
});
