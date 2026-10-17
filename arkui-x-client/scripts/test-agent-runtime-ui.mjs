import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';
import { makeDraftFixture, shanghaiDate, makeRunController, runSnapshot } from './helpers/agent-run-ui-fixture.mjs';

const load = async name => {
  const code = readFileSync(new URL(`../entry/src/main/ets/utils/${name}.ets`, import.meta.url), 'utf8')
    .replace(/^import \{[\s\S]*?\} from '[^']+';\r?\n/gm, '');
  return import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(code)).toString('base64')}`);
};
const feedback = await load('AgentFeedback'), reliability = await load('ActionReliability');
const source = readFileSync(new URL('../entry/src/main/ets/pages/AgentPage.ets', import.meta.url), 'utf8');
const controllerSource = source.slice(0, source.indexOf('\n  @Builder')).replace(/^import [^\n]+;\r?\n/gm, '')
  .replace(/^@Component\r?\n/m, '').replace(/@(Prop|State)\s+|@Watch\('[^']+'\)\s*/g, '')
  .replace('export struct AgentPage', 'class AgentPage') + '\n}\n';
const makePage = new Function('CampusFlowApi', 'Scroller', 'CampusFlowRequestError', 'displayToolTraces', 'mergeActions',
  'restoreDraft', 'localRequestFailure', 'AppTheme', 'localHistory', 'AgentRunController', 'localDrafts', 'shanghaiDate', ...Object.keys(reliability),
  stripTypeScriptTypes(controllerSource) + '\nreturn AgentPage;');
const now = '2028-10-20T08:00:00+08:00';
const oldId = '11111111-1111-4111-8111-111111111111';
const history = (...contents) => contents.map((content, index) => ({ role: index % 2 === 0 ? 'user' : 'assistant', content, created_at: now }));
const turn = (message = '完整回答', actions = []) => ({ session_id: 'fixture', message, pending_actions: actions, tool_traces: [] });
const proposal = id => ({ proposal_id: id, action: 'create', kind: 'task', title: '复习', start_at: null, end_at: null,
  reminder_minutes: null, reason: null, payload: {}, conflicts: [], status: 'pending' });
const deferred = () => { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; };
const settle = async () => { for (let i = 0; i < 8; i++) await Promise.resolve(); };

async function harness(handlers = {}) {
  const calls = [], saves = [];
  class Api {
    invoke(name, args) { calls.push({ name, args }); assert.equal(typeof handlers[name], 'function', `unexpected ${name}`); return handlers[name](...args); }
    startAgentRun(...args) { return this.invoke('startAgentRun', args); }
    agentRun(...args) { return this.invoke('agentRun', args); }
    agentRunEvents(...args) { return this.invoke('agentRunEvents', args); }
    cancelAgentRun(...args) { return this.invoke('cancelAgentRun', args); }
    recentAgentRuns(...args) { return this.invoke('recentAgentRuns', args); }
    history(...args) { return this.invoke('history', args); }
  }
  const drafts = await makeDraftFixture();
  const Page = makePage(Api, class {}, feedback.CampusFlowRequestError, feedback.displayToolTraces, feedback.mergeActions,
    feedback.restoreDraft, feedback.localRequestFailure, {}, { save: async (...args) => { saves.push(args); return true; } },
    makeRunController(feedback.CampusFlowRequestError, feedback.localRequestFailure), drafts.store, shanghaiDate, ...Object.values(reliability));
  const page = new Page(); page.baseUrl = 'https://fixture.invalid'; page.token = 'secret-token'; page.voiceActive = true;
  page.historyScope = 'account-a';
  page.draftLease = drafts.lease;
  page.draftLeaseChanged();
  return { page, calls, saves };
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

test('recovering a recent old run uses its own bubble and full history without switching the current session or replaying a POST', async () => {
  const request = { run_id: oldId, session_id: 'older-session', model: 'deepseek-flash', message: '旧问题' };
  const snapshot = runSnapshot(request, turn('旧回答', [proposal('older-proposal')]));
  const full = history('更早的问题', '更早的回答', '旧问题', '旧回答');
  const { page, calls, saves } = await harness({ recentAgentRuns: async limit => { assert.equal(limit, 20); return [snapshot]; },
    agentRun: async () => snapshot, history: async id => { assert.equal(id, request.session_id); return full; } });
  const originalSession = page.sessionId; page.prompt = '当前草稿';
  await page.toggleRunRecords(); await page.recoverRun(oldId); await settle(); await page.refreshRun(); await settle();
  assert.equal(page.sessionId, originalSession); assert.equal(page.prompt, '当前草稿');
  assert.equal(page.messages.filter(m => m.id === `run-${oldId}-assistant`).length, 1);
  assert.equal(page.proposalOrigins[0].messageId, `run-${oldId}-assistant`);
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

test('deleting a recovered old session removes only its run, proposal and pending cache read', async () => {
  const request = { run_id: oldId, session_id: 'deleted-old-session', model: 'deepseek-flash', message: '旧问题' };
  const snapshot = runSnapshot(request, turn('旧回答', [proposal('delete-old-proposal')]));
  const reading = deferred();
  const { page, saves } = await harness({ agentRun: async () => snapshot, history: () => reading.promise });
  const currentSession = page.sessionId;
  page.prompt = '当前草稿'; const currentMessage = page.appendMessage('assistant', '当前会话内容');
  await page.recoverRun(oldId);
  assert.equal(page.pendingActions.length, 1);
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
