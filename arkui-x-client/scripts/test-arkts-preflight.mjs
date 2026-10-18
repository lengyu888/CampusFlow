import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';
import { checkArkUIXConfiguration } from './static-check.mjs';
import { CampusFlowRequestError, focusFixture } from './helpers/focus-fixture.mjs';

// These run the actual non-rendering methods and configuration preflight. They
// do not execute the ArkTS compiler, native APIs or a device.
const source = name => readFileSync(new URL(`../entry/src/main/ets/pages/${name}.ets`, import.meta.url), 'utf8');
function method(text, start, end) {
  const first = text.indexOf(start), last = text.indexOf(end, first + start.length);
  assert.ok(first >= 0 && last > first, `production method boundary: ${start}`);
  return text.slice(first, last);
}
const historyMethod = method(source('HistoryPage'), '  private async deleteSession(', '\n  private canContinue(');
const agentSource = source('AgentPage');
const switchMethod = method(agentSource, '  private async switchConversation(', '\n  private sessionRequestCurrent(');
const failureMethod = method(agentSource, '  private safeFailure(', '\n  private inputLength(');

function historyFixture(failure) {
  const calls = [], session = { session_id: 'owned-session' };
  class Api { async deleteSession(id) { calls.push(['delete', id]); if (failure !== undefined) throw failure; } }
  const localHistory = { epoch: () => 7, removeSession: async (...args) => calls.push(['remove', ...args]) };
  const Page = new Function('CampusFlowApi', 'localHistory', 'CampusFlowRequestError',
    stripTypeScriptTypes(`class HistoryHarness {${historyMethod}}`) + '\nreturn HistoryHarness;')(Api, localHistory, CampusFlowRequestError);
  const page = new Page();
  Object.assign(page, { deleting: false, chatBusy: false, remoteDeleteBusy: false, requestRevision: 0,
    historyScope: 'owner', accountRevision: 2, offlineOnly: false, baseUrl: 'https://example.test', token: 'synthetic',
    sessions: [session], selected: session, messages: ['saved'], pendingDeleteId: session.session_id,
    current: revision => revision === page.requestRevision,
    onSessionDeleted: (...args) => calls.push(['deleted', ...args]), onDeleteBusyChange: busy => calls.push(['busy', busy]) });
  return { page, calls, session };
}

test('history delete keeps exact authenticated 404 cleanup semantics', async () => {
  const f = historyFixture(new CampusFlowRequestError(404, 'SESSION_NOT_FOUND', 'gone'));
  await f.page.deleteSession(f.session);
  assert.deepEqual(f.calls.filter(x => x[0] === 'remove'), [['remove', 'owner', 'owned-session', true]]);
  assert.equal(f.page.selected, null); assert.deepEqual(f.page.sessions, []); assert.equal(f.page.errorText, '');
});
for (const [name, failure] of [
  ['server error', new CampusFlowRequestError(503, 'SERVER_UNAVAILABLE', 'unavailable')],
  ['arbitrary thrown string', 'disk or bridge failed'],
  ['lookalike 404 object', { statusCode: 404, code: 'SESSION_NOT_FOUND' }],
  ['null exception', null]
]) test(`history delete does not erase cache on ${name}`, async () => {
  const f = historyFixture(failure);
  await f.page.deleteSession(f.session);
  assert.equal(f.calls.some(x => ['remove', 'deleted'].includes(x[0])), false);
  assert.deepEqual(f.page.sessions, [f.session]); assert.deepEqual(f.page.messages, ['saved']);
  assert.equal(f.page.deleting, false); assert.match(f.page.errorText, /删除未完成/);
});

function switchFixture(failure, { draft = false, run = false } = {}) {
  const calls = [], lease = {};
  class Api {
    async sessionContext() { throw failure; }
    async agentRun(id) { calls.push(['run', id]); return { run_id: id, session_id: 'target', status: 'queued' }; }
  }
  const localDrafts = { valid: value => value === lease, flush: async () => calls.push(['flush']) };
  const Page = new Function('CampusFlowApi', 'localDrafts', 'CampusFlowRequestError',
    'validSessionContext', 'localRequestFailure',
    stripTypeScriptTypes(`class AgentHarness {${switchMethod}\n${failureMethod}}`) + '\nreturn AgentHarness;')(
    Api, localDrafts, CampusFlowRequestError, () => true, code => new CampusFlowRequestError(0, code, code));
  const page = new Page();
  Object.assign(page, { pageActive: true, voiceActive: true, sessionLoading: false, deletionBusy: false,
    decisionId: '', decisionOperations: [], pendingActions: [], capturePending: () => false, recoverableDraft: null,
    draftLease: lease, sessionRequestRevision: 0, switchTarget: 'target', switchDraftId: draft ? 'target' : '', switchRunId: run ? 'run-a' : '',
    userId: 'owner', historyScope: 'scope', stagePrompt: () => true, baseUrl: 'https://example.test', token: 'synthetic',
    prompt: '不要丢掉我的输入', sessionId: 'original', restoredRunIds: [], liveRecoveredRunIds: [],
    sessionRequestCurrent: revision => revision === page.sessionRequestRevision,
    enterConversation: (id, context) => { calls.push(['enter', id, context]); page.sessionId = id; },
    runController: () => ({ recover: async id => calls.push(['recover', id]) }) });
  return { page, calls };
}
for (const [name, failure] of [
  ['known API failure', new CampusFlowRequestError(503, 'SERVER_UNAVAILABLE', '服务暂不可用')],
  ['arbitrary object', { code: 'SESSION_NOT_FOUND' }], ['arbitrary string', 'failed'], ['null', null]
]) test(`conversation switch keeps original conversation and draft on ${name}`, async () => {
  const f = switchFixture(failure, { draft: true, run: true });
  await f.page.switchConversation();
  assert.equal(f.page.sessionId, 'original'); assert.equal(f.page.prompt, '不要丢掉我的输入');
  assert.equal(f.calls.some(x => ['run', 'enter', 'recover'].includes(x[0])), false);
  assert.equal(f.page.sessionLoading, false); assert.match(f.page.sessionNotice, /未切换会话/);
  if (failure instanceof CampusFlowRequestError) assert.ok(f.page.sessionNotice.includes(failure.message));
});
test('ordinary missing conversation cannot use queued-first-turn recovery', async () => {
  const f = switchFixture(new CampusFlowRequestError(404, 'SESSION_NOT_FOUND', '无此会话'));
  await f.page.switchConversation(); assert.equal(f.page.sessionId, 'original');
  assert.equal(f.calls.some(x => x[0] === 'enter'), false);
});
test('owned queued-first-turn 404 still recovers the original run', async () => {
  const f = switchFixture(new CampusFlowRequestError(404, 'SESSION_NOT_FOUND', '无此会话'), { run: true });
  await f.page.switchConversation(); assert.equal(f.page.sessionId, 'target');
  assert.deepEqual(f.calls.filter(x => x[0] === 'recover'), [['recover', 'run-a']]);
});
test('locally staged first-turn 404 can enter its unsent conversation', async () => {
  const f = switchFixture(new CampusFlowRequestError(404, 'SESSION_NOT_FOUND', '无此会话'), { draft: true });
  await f.page.switchConversation(); assert.equal(f.page.sessionId, 'target');
  assert.equal(f.calls.some(x => ['run', 'recover'].includes(x[0])), false);
});

for (const [name, failure] of [['known Error', new Error('remove failed')], ['arbitrary value', 'remove failed']]) {
  test(`focus cleanup remains rejected with Error on ${name}`, async () => {
    const f = await focusFixture(); f.store.clear = async () => { throw failure; };
    try {
      await assert.rejects(f.controller.clearLocal(), error => error instanceof Error &&
        (failure instanceof Error ? error === failure : error.message === 'FOCUS_LOCAL_CLEAR_FAILED'));
      assert.equal(f.state().phase, 'error'); assert.match(f.state().message, /不能切换账号/);
    } finally { f.controller.dispose(); }
  });
}

const validConfig = () => ({ crossplatform: true, modules: ['entry'], buildOption: { ignoreCrossPlatform: true } });
test('the published plugin layout preserves the cross-platform override under buildOption', () => {
  assert.deepEqual(checkArkUIXConfiguration(validConfig(), '4.24.2'), []);
  assert.deepEqual(checkArkUIXConfiguration({ crossplatform: true, modules: ['entry'] }, '4.24.2'), []);
});
test('old top-level override is rejected even though JSON.parse accepts it', () => {
  const config = JSON.parse('{"crossplatform":true,"modules":["entry"],"ignoreCrossPlatform":true}');
  assert.ok(checkArkUIXConfiguration(config, '4.24.2').some(x => x.includes('顶层配置')));
});
for (const [name, mutate] of [
  ['unsupported nested option', config => { config.buildOption.unknownOption = true; }],
  ['nonboolean override', config => { config.buildOption.ignoreCrossPlatform = 'true'; }],
  ['null options', config => { config.buildOption = null; }],
  ['nonstring resource filter', config => { config.buildOption.resConfigs = ['zh', 4]; }],
  ['empty modules', config => { config.modules = []; }],
  ['nonstring module', config => { config.modules = [4]; }],
  ['cross-platform disabled', config => { config.crossplatform = false; }]
]) test(`configuration preflight rejects ${name}`, () => {
  const config = validConfig(); mutate(config); assert.ok(checkArkUIXConfiguration(config, '4.24.2').length > 0);
});
test('plugin upgrades require renewing versioned schema evidence', () => {
  assert.ok(checkArkUIXConfiguration(validConfig(), '4.26.1').some(x => x.includes('版本已变化')));
});
