import './helpers/theme-fixture.mjs';
import { conversationDependencies, assistantDraftKey } from './helpers/conversation-fixture.mjs';
import { reliability } from './helpers/course-review-fixture.mjs';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripThemeTypeScriptTypes as stripTypeScriptTypes } from './helpers/theme-fixture.mjs';
import { test } from 'node:test';
import { makeRunController, runSnapshot, shanghaiDate } from './helpers/agent-run-ui-fixture.mjs';

const load = async name => {
  const source = readFileSync(new URL(`../entry/src/main/ets/utils/${name}.ets`, import.meta.url), 'utf8')
    .replace(/^import \{[\s\S]*?\} from '[^']+';\r?\n/gm, '');
  return import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source)).toString('base64')}`);
};
const { DraftStore } = await load('DraftStore');
const feedback = await load('AgentFeedback');
const source = readFileSync(new URL('../entry/src/main/ets/pages/AgentPage.ets', import.meta.url), 'utf8');
const controller = source.slice(0, source.indexOf('\n  @Builder')).replace(/^import [^\n]+;\r?\n/gm, '')
  .replace(/^@Component\r?\n/m, '').replace(/@(Prop|State)\s+|@Watch\('[^']+'\)\s*/g, '')
  .replace('export struct AgentPage', 'class AgentPage') + '\n}\n';
const makePage = new Function('CampusFlowApi', 'Scroller', 'localDrafts', 'shanghaiDate', 'AgentRunController',
  'localHistory', 'AppTheme', ...Object.keys(feedback), ...Object.keys(reliability), ...Object.keys(conversationDependencies),
  stripTypeScriptTypes(controller) + '\nreturn AgentPage;');
const key = assistantDraftKey('old-session');
const legacyKey = { kind: 'assistant', ownerId: 'main' };
const id = '01234567-0123-4123-8123-012345678901';
const scope = JSON.stringify(['https://fixture.invalid', 'account-a']);
const deferred = () => { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; };
const settle = async () => { for (let i = 0; i < 40; i++) await Promise.resolve(); };
const payload = (text = '明天复习', anchorDate = '2026-10-17') => ({ text, anchorDate, sessionId: 'old-session', timezone: 'Asia/Shanghai' });
const request = (message = '原问题') => ({ run_id: id, session_id: 'old-session', model: 'deepseek-v4-pro', message });
class Disk {
  text; gate; started; fail = false;
  async read() { return this.text; }
  async write(text) { this.started?.resolve(); if (this.gate) await this.gate.promise; if (this.fail) throw Error('private disk failure'); this.text = text; }
  async remove() { this.text = undefined; }
}
async function storage(disk = new Disk(), account = scope) {
  const store = new DraftStore(disk, { now: () => Date.UTC(2026, 9, 18, 8), set: () => 1, clear() {} });
  await store.initialize(); const lease = await store.activate(account);
  return { store, lease, disk };
}
async function harness(handlers = {}, saved = null, bind = true) {
  const drafts = saved ?? await storage(); const calls = [];
  class Api {
    invoke(name, args) { calls.push({ name, args: structuredClone(args) }); assert.equal(typeof handlers[name], 'function', `unexpected ${name}`); return handlers[name](...args); }
    startAgentRun(...args) { return this.invoke('startAgentRun', args); }
    agentRun(...args) { return this.invoke('agentRun', args); }
    agentRunEvents(...args) { return this.invoke('agentRunEvents', args); }
    cancelAgentRun(...args) { return this.invoke('cancelAgentRun', args); }
    recentAgentRuns(...args) { return this.invoke('recentAgentRuns', args); }
    async history() { return []; }
  }
  const Page = makePage(Api, class {}, drafts.store, shanghaiDate,
    makeRunController(feedback.CampusFlowRequestError, feedback.localRequestFailure),
    { save: async () => true, isRemoved: () => false }, {}, ...Object.values(feedback), ...Object.values(reliability), ...Object.values(conversationDependencies));
  const page = new Page(); page.baseUrl = 'https://fixture.invalid'; page.token = 'never-persist-this-token';
  page.sessionId = 'old-session';
  page.voiceActive = true; page.historyScope = scope; page.draftLease = drafts.lease;
  page.newRunId = () => id;
  if (bind) page.draftLeaseChanged();
  return { ...drafts, page, calls };
}
async function pending(drafts, frozen = request()) {
  const ticket = drafts.store.stage(drafts.lease, key, payload(frozen.message));
  await drafts.store.beginOperation(drafts.lease, { kind: 'run', id: frozen.run_id, draftKind: 'assistant', ownerId: key.ownerId,
    localRevision: ticket.localRevision, runRequest: frozen });
  return ticket.localRevision;
}

// This executes production ArkTS controller logic under Node; it is not native UI/device evidence.
test('typed, suggested, appended and accepted voice input stage through the real store', async () => {
  const { page, store, lease } = await harness();
  page.changePrompt('先写一句'); assert.equal(store.read(lease, key).payload.text, '先写一句');
  page.offerPrompt('另一条建议'); assert.equal(store.read(lease, key).payload.text, '先写一句');
  page.applySuggestion(true); assert.equal(store.read(lease, key).payload.text, '先写一句\n另一条建议');
  page.voiceState = { phase: 'review', transcript: '语音补充', message: '', speakingMessageId: '' };
  page.voiceInteraction = { takeTranscript: () => '语音补充' }; page.useVoiceTranscript();
  assert.equal(store.read(lease, key).payload.text, '先写一句\n另一条建议\n语音补充');
  assert.match(source, /\.onChange\(\(value\) => this\.changePrompt\(value\)\)/);
  assert.match(source, /\.onClick\(\(\) => this\.changePrompt\(restoreDraft/);
});

test('legacy main restoration is explicit text only and retains the original Shanghai anchor without changing session or sending', async () => {
  const drafts = await storage(); drafts.store.stage(drafts.lease, legacyKey, payload()); await drafts.store.flush(drafts.lease);
  const { page, calls } = await harness({}, drafts); const session = page.sessionId;
  assert.equal(page.prompt, ''); assert.ok(page.recoverableDraft); assert.equal(calls.length, 0);
  assert.equal(drafts.store.read(drafts.lease, key), undefined, 'legacy input is not silently migrated');
  await page.restoreStoredDraft(); assert.equal(page.prompt, '明天复习'); assert.equal(page.draftAnchorDate, '2026-10-17');
  assert.equal(page.sessionId, session); assert.equal(calls.length, 0);
  assert.equal(drafts.store.read(drafts.lease, key).payload.anchorDate, '2026-10-17');
  assert.equal(drafts.store.read(drafts.lease, legacyKey), undefined, 'explicit restored migration removes only the old slot');
});

test('a pending restore cannot overwrite new input or the old durable draft; explicit discard preserves current text', async () => {
  const drafts = await storage(); drafts.store.stage(drafts.lease, key, payload('旧草稿')); await drafts.store.flush(drafts.lease);
  const { page, calls } = await harness({}, drafts);
  page.changePrompt('本次新输入'); page.restoreStoredDraft(); await page.send();
  assert.equal(page.prompt, '本次新输入'); assert.equal(drafts.store.read(drafts.lease, key).payload.text, '旧草稿'); assert.equal(calls.length, 0);
  await page.discardStoredDraft(); await page.flushDraft();
  assert.equal(drafts.store.read(drafts.lease, key).payload.text, '本次新输入'); assert.equal(page.recoverableDraft, null);
});

test('the durable operation write is a strict barrier before the first POST, and only its input is cleared', async () => {
  let frozen;
  const h = await harness({ startAgentRun: async value => { frozen = value; return runSnapshot(value, null, { status: 'running' }); } });
  h.disk.gate = deferred(); h.disk.started = deferred(); h.page.changePrompt('  原问题  ');
  const sending = h.page.send(); await h.disk.started.promise;
  assert.equal(h.calls.length, 0); assert.equal(h.page.prompt, '  原问题  ');
  h.disk.gate.resolve(); await sending;
  assert.equal(h.calls[0].name, 'startAgentRun'); assert.equal(frozen.message, '原问题'); assert.equal(h.page.prompt, '');
  const document = JSON.parse(h.disk.text); assert.equal(document.operations[0].runRequest.message, '原问题');
  assert.equal(document.operations[0].id, frozen.run_id); assert.ok(!h.disk.text.includes(h.page.token));
  assert.ok(!h.disk.text.includes('https://fixture.invalid/')); assert.equal(h.store.isBlocked(h.lease, key), true);
});

test('failed durable write never POSTs, retains input, and explicit retry uses the original ID', async () => {
  const h = await harness({ startAgentRun: async value => runSnapshot(value, null, { status: 'running' }) });
  h.disk.fail = true; h.page.changePrompt('不可丢失'); await h.page.send();
  assert.equal(h.calls.length, 0); assert.equal(h.page.prompt, '不可丢失'); assert.equal(h.page.runState.phase, 'local_error');
  assert.equal(h.page.runState.canRetryStart, true); assert.equal(h.store.isBlocked(h.lease, key), true);
  h.disk.fail = false; await h.page.retryRunStart();
  assert.equal(h.calls.length, 1); assert.equal(h.calls[0].args[0].run_id, id);
});

test('typing while durable storage is pending is retained, and terminal success atomically removes only the submitted revision', async () => {
  const h = await harness({ startAgentRun: async value => runSnapshot(value, { message: '完成', pending_actions: [], tool_traces: [] }) });
  h.page.changePrompt('原问题'); h.disk.gate = deferred(); h.disk.started = deferred();
  const sending = h.page.send(); await h.disk.started.promise; h.page.changePrompt('发送后的新想法');
  h.disk.gate.resolve(); await sending; await settle(); await h.page.flushDraft();
  assert.equal(h.page.prompt, '发送后的新想法'); assert.equal(h.store.operations(h.lease).length, 0);
  assert.equal(h.store.read(h.lease, key).payload.text, '发送后的新想法');
  const restarted = await storage(h.disk); assert.equal(restarted.store.read(restarted.lease, key).payload.text, '发送后的新想法');
});

test('completed original input and operation disappear together from restart storage', async () => {
  const h = await harness({ startAgentRun: async value => runSnapshot(value, { message: '完成', pending_actions: [], tool_traces: [] }) });
  h.page.changePrompt('已发送'); await h.page.send(); await settle();
  const restarted = await storage(h.disk); assert.equal(restarted.store.operations(restarted.lease).length, 0);
  assert.equal(restarted.store.read(restarted.lease, key), undefined);
});

test('restart restores a frozen pointer with GET only; 404 requires an explicit identical retry and preserves a newer draft', async () => {
  const disk = new Disk(); const original = await storage(disk); const frozen = request(); await pending(original, frozen);
  original.store.stage(original.lease, key, payload('新草稿', '2026-10-18')); await original.store.flush(original.lease);
  const restarted = await storage(disk);
  const h = await harness({ agentRun: async () => { throw new feedback.CampusFlowRequestError(404, 'RUN_NOT_FOUND', 'not found'); },
    startAgentRun: async value => runSnapshot(value, null, { status: 'running' }) }, restarted);
  await settle(); assert.deepEqual(h.calls.map(c => c.name), ['agentRun']);
  assert.equal(h.page.runState.canRetryStart, true); assert.equal(h.page.prompt, '');
  h.page.restoreStoredDraft(); h.page.model = 'different-model';
  await h.page.retryRunStart();
  assert.deepEqual(h.calls[1].args[0], frozen); assert.equal(h.page.prompt, '新草稿');
  assert.equal(h.page.sessionId, 'old-session', 'recovery remains in the explicitly selected owning conversation');
});

test('unknown response and request mismatch keep the pointer; they cannot unlock a fresh run', async () => {
  const original = await storage(); await pending(original);
  const h = await harness({ agentRun: async () => runSnapshot(request('他人的问题'), { message: '错误响应', pending_actions: [] }) }, original);
  await settle(); assert.equal(h.page.runState.phase, 'unknown'); assert.equal(h.store.operations(h.lease).length, 1);
  h.page.changePrompt('另一个问题'); await h.page.send(); assert.deepEqual(h.calls.map(c => c.name), ['agentRun']);
});

test('confirmed model-key rejection releases the pointer and restores the input without replacing newer text', async () => {
  const answer = deferred();
  const h = await harness({ startAgentRun: () => answer.promise });
  h.page.changePrompt('原问题'); const sending = h.page.send(); await settle(); h.page.changePrompt('新的草稿');
  answer.reject(new feedback.CampusFlowRequestError(409, 'MODEL_KEY_REQUIRED', '尚未配置')); await sending; await settle();
  assert.equal(h.page.runState.phase, 'error'); assert.equal(h.store.operations(h.lease).length, 0);
  assert.equal(h.page.prompt, '新的草稿'); assert.equal(h.store.read(h.lease, key).payload.text, '新的草稿');
});

test('no authenticated draft lease means no POST and no input clearing', async () => {
  const h = await harness(); h.page.draftLease = null; h.page.draftLeaseChanged(); h.page.changePrompt('留在本页');
  await h.page.send(); assert.equal(h.calls.length, 0); assert.equal(h.page.prompt, '留在本页');
});

test('hiding during durable write prevents a POST; the persisted pointer can later be queried', async () => {
  const h = await harness(); h.page.changePrompt('稍后发送'); h.disk.gate = deferred(); h.disk.started = deferred();
  const sending = h.page.send(); await h.disk.started.promise; h.page.voiceActive = false; h.page.voiceActivityChanged();
  h.disk.gate.resolve(); await sending; await settle(); assert.equal(h.calls.length, 0);
  assert.equal(h.page.prompt, '稍后发送'); assert.equal(h.store.operations(h.lease).length, 1);
});

test('a late GET after lease/account change cannot clear or restore the new account draft', async () => {
  const drafts = await storage(); await pending(drafts); const answer = deferred();
  const h = await harness({ agentRun: () => answer.promise }, drafts); await settle();
  const nextLease = await h.store.activate('another-account'); h.page.draftLease = nextLease; h.page.draftLeaseChanged();
  h.page.changePrompt('新账号草稿');
  answer.resolve(runSnapshot(request(), { message: '旧账号结果', pending_actions: [], tool_traces: [] })); await settle();
  assert.equal(h.page.prompt, '新账号草稿'); assert.equal(h.store.read(nextLease, key).payload.text, '新账号草稿');
  assert.equal(h.page.messages.some(value => value.content === '旧账号结果'), false);
});


test('a cancelled recovered run offers explicit input recovery, never automatically fills or changes session', async () => {
  const drafts = await storage(); await pending(drafts);
  const h = await harness({ agentRun: async () => runSnapshot(request(), null, { status: 'cancelled' }) }, drafts);
  const session = h.page.sessionId; await settle();
  assert.equal(h.store.operations(h.lease).length, 0); assert.equal(h.page.prompt, ''); assert.ok(h.page.recoverableDraft);
  h.page.restoreStoredDraft(); assert.equal(h.page.prompt, '原问题'); assert.equal(h.page.sessionId, session);
  assert.deepEqual(h.calls.map(c => c.name), ['agentRun']);
});

test('failed terminal cleanup remains recoverable after restart and succeeds on an explicit status query', async () => {
  const reply = deferred(); let frozen;
  const h = await harness({ startAgentRun: value => { frozen = value; return reply.promise; },
    agentRun: () => runSnapshot(frozen, { message: '完成', pending_actions: [], tool_traces: [] }) });
  h.page.changePrompt('一次输入'); const sending = h.page.send(); await settle();
  h.disk.fail = true; reply.resolve(runSnapshot(frozen, { message: '完成', pending_actions: [], tool_traces: [] }));
  await sending; await settle(); assert.equal(h.store.operations(h.lease).length, 1);
  h.disk.fail = false;
  const restarted = await storage(h.disk); assert.equal(restarted.store.operations(restarted.lease).length, 1);
  await h.page.refreshRun(); await settle();
  assert.equal(h.store.operations(h.lease).length, 0); assert.equal(h.store.read(h.lease, key), undefined);
});

test('a confirmed session deletion releases its pointer but keeps a newer input and ignores the late reply', async () => {
  const reply = deferred(); let frozen;
  const h = await harness({ startAgentRun: value => { frozen = value; return reply.promise; } });
  h.page.changePrompt('旧问题'); const sending = h.page.send(); await settle();
  h.page.changePrompt('新问题'); h.page.deletedSessionId = h.page.sessionId; h.page.sessionDeleted(); await settle();
  assert.equal(h.store.operations(h.lease).length, 0); assert.equal(h.store.read(h.lease, assistantDraftKey(h.page.sessionId)).payload.text, '新问题');
  reply.resolve(runSnapshot(frozen, { message: '旧回包', pending_actions: [], tool_traces: [] })); await sending; await settle();
  assert.equal(h.page.prompt, '新问题'); assert.equal(h.page.messages.some(value => value.content === '旧回包'), false);
});

test('connection change during preflight prevents POST and disposes the old credential controller', async () => {
  const h = await harness(); h.page.changePrompt('原输入'); h.disk.gate = deferred(); h.disk.started = deferred();
  const sending = h.page.send(); await h.disk.started.promise;
  h.page.token = 'replacement-token'; h.page.loadModels = () => {}; h.page.modelConnectionChanged();
  assert.equal(h.page.runInteraction, null);
  h.disk.gate.resolve(); await sending; await settle(); assert.equal(h.calls.length, 0);
  assert.equal(h.page.prompt, '原输入'); assert.equal(h.store.operations(h.lease).length, 1);
});
