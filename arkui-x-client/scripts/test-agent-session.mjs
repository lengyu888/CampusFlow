import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import test from 'node:test';
import { conversationDependencies } from './helpers/conversation-fixture.mjs';
import { reliability } from './helpers/course-review-fixture.mjs';
import { makeDraftFixture, makeRunController, runSnapshot, shanghaiDate } from './helpers/agent-run-ui-fixture.mjs';

const compilerSuffix = 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript';
const compilerPath = [process.env.CAMPUSFLOW_TYPESCRIPT_PATH,
  process.env.DEVECO_STUDIO_HOME && path.join(process.env.DEVECO_STUDIO_HOME, compilerSuffix),
  path.join('D:/DevEco Studio', compilerSuffix),
  path.join('C:/Program Files/Huawei/DevEco Studio', compilerSuffix)
].find(candidate => candidate && existsSync(candidate));
assert.ok(compilerPath, 'Set CAMPUSFLOW_TYPESCRIPT_PATH or DEVECO_STUDIO_HOME to the existing compiler.');
const ts = createRequire(import.meta.url)(compilerPath);
const source = readFileSync(process.env.CAMPUSFLOW_AGENT_SOURCE ??
  new URL('../entry/src/main/ets/pages/AgentPage.ets', import.meta.url), 'utf8');
assert.doesNotMatch(source, /^<<<<<<< /m, 'Resolve merge markers before testing the page.');
const boundary = source.indexOf('\n  @Builder');
assert.ok(boundary > 0, 'Agent page controller must precede its builders.');
const controller = source.slice(0, boundary).replace(/^import .*;\r?\n/gm, '')
  .replace(/@\w+(?:\('[^']*'\))?\s*/g, '')
  .replace('export struct AgentPage', 'class AgentPage') + '\n}\n';
const transpile = value => ts.transpileModule(value, {
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true
});
const compiled = transpile(controller);
assert.equal((compiled.diagnostics ?? []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
const helperSource = readFileSync(new URL('../entry/src/main/ets/utils/AgentFeedback.ets', import.meta.url), 'utf8')
  .replace(/^import .*;\r?\n/gm, '');
const helperModule = { exports: {} };
new Function('exports', transpile(helperSource).outputText)(helperModule.exports);
const helper = helperModule.exports;
const catalogSource = readFileSync(new URL('../entry/src/main/ets/utils/ModelCatalog.ets', import.meta.url), 'utf8')
  .replace(/^import .*;\r?\n/gm, '');
const catalogModule = { exports: {} };
new Function('exports', transpile(catalogSource).outputText)(catalogModule.exports);
const dependencies = { ...helper, ...catalogModule.exports, ...reliability, ...conversationDependencies,
  AgentRunController: makeRunController(helper.CampusFlowRequestError, helper.localRequestFailure),
  Edge: { Bottom: 'bottom' }, ScrollSource: { DRAG: 0, FLING: 1, EDGE_EFFECT: 2, OTHER_USER_INPUT: 3,
    SCROLL_BAR: 4, SCROLL_BAR_FLING: 5, SCROLLER: 6, SCROLLER_ANIMATION: 7 },
  AppTheme: {}, shanghaiDate };
const welcomeExpression = source.match(/if \((!this\.hasConversation\(\))\) \{/)?.[1];
const messagesExpression = source.match(/ForEach\((this\.messages\.filter\(.+\)), \(message: ConversationEntry\) => \{/)?.[1];
assert.ok(welcomeExpression && messagesExpression, 'Find the actual welcome and message visibility branches.');
const isWelcome = new Function(`return (${welcomeExpression});`);
const visibleMessages = new Function(transpile(`return (${messagesExpression});`).outputText);

const question = { role: 'user', content: '请安排明天的复习', created_at: '2026-10-17T10:00:00+08:00' };
const answer = { role: 'assistant', content: '|时间|安排|\n|---|---|\n|下午|复习|', created_at: '2026-10-17T10:01:00+08:00' };
const runId = '11111111-1111-4111-8111-111111111111';
const request = { run_id: runId, session_id: 'saved-session', model: 'deepseek-v4-pro', message: question.content };
function context(messages) {
  return { user_id: 'user-a', session_id: 'saved-session', context_revision: 'a'.repeat(64), active_run: null,
    messages, summary: { session_id: 'saved-session', title: '复习安排', model_name: 'deepseek-v4-pro',
      last_message: messages.at(-1)?.content ?? '', message_count: messages.length,
      created_at: question.created_at, updated_at: answer.created_at } };
}

async function setup() {
  const fixture = { history: [], scrolls: [], calls: [], offset: 0,
    run: runSnapshot(request, null, { status: 'running' }) };
  const drafts = await makeDraftFixture('session-regression-account');
  class Api {
    async agentRun(id) { fixture.calls.push(['agentRun', id]); return fixture.run; }
    async startAgentRun(value) {
      fixture.calls.push(['startAgentRun', value]);
      fixture.history = [question, answer];
      return runSnapshot(value, { message: '**安排完成**', tool_traces: [], pending_actions: [] });
    }
    async history() { return fixture.history; }
  }
  class Scroller {
    scrollEdge(edge) { fixture.scrolls.push({ kind: 'edge', edge }); }
    scrollTo(value) { fixture.scrolls.push({ kind: 'position', ...value }); }
    currentOffset() { return { xOffset: 0, yOffset: fixture.offset }; }
  }
  const values = { ...dependencies, CampusFlowApi: Api, Scroller, localDrafts: drafts.store, localHistory: {} };
  const Page = new Function(...Object.keys(values), compiled.outputText + '\nreturn AgentPage;')(...Object.values(values));
  const page = new Page();
  page.baseUrl = 'http://unit.test'; page.token = 'test-session-token'; page.voiceActive = true;
  page.sessionId = 'saved-session'; page.draftLease = drafts.lease; page.draftLeaseChanged();
  // Execute actual callbacks; rendering and native Scroller timing remain device checks.
  const viewEvent = (name, ...args) => {
    const marker = `.${name}(`;
    for (let start = source.indexOf(marker); start >= 0; start = source.indexOf(marker, start + marker.length)) {
      const file = ts.createSourceFile('callback.ts', `const callback = ${source.slice(start + marker.length)}`,
        ts.ScriptTarget.Latest, true);
      const callback = file.statements[0].declarationList.declarations[0].initializer;
      if (!ts.isArrowFunction(callback)) continue;
      const text = callback.getText(file);
      if (name === 'onAreaChange' && !text.includes('chatContentChanged')) continue;
      const executable = transpile(`return (${text});`).outputText;
      new Function(...Object.keys(values), executable).call(page, ...Object.values(values))(...args);
      return;
    }
  };
  const content = (oldHeight, newHeight, oldY = 0, newY = 0) => viewEvent('onAreaChange',
    { width: 360, height: oldHeight, position: { x: 0, y: oldY } },
    { width: 360, height: newHeight, position: { x: 0, y: newY } });
  return { page, fixture, viewEvent, content, sources: dependencies.ScrollSource };
}

test('an untouched conversation shows the welcome screen', async () => {
  const { page } = await setup();
  assert.equal(isWelcome.call(page), true); assert.equal(visibleMessages.call(page).length, 0);
});

test('a single recovered pending question is visible through the runtime controller', async () => {
  const { page, fixture } = await setup(); await page.recoverRun(runId);
  assert.equal(isWelcome.call(page), false);
  assert.equal(visibleMessages.call(page).find(item => item.role === 'user').content, question.content);
  assert.equal(page.loading, true); assert.deepEqual(fixture.calls, [['agentRun', runId]]);
});

test('a single saved assistant reply is visible', async () => {
  const { page } = await setup(); page.enterConversation('saved-session', context([answer]));
  assert.equal(isWelcome.call(page), false); assert.equal(visibleMessages.call(page)[0].content, answer.content);
});

test('a refreshed pending question stays visible without reviving cached proposals', async () => {
  const { page } = await setup(); page.applyContextMessages(context([question]));
  assert.equal(isWelcome.call(page), false); assert.equal(visibleMessages.call(page)[0].role, 'user');
  assert.deepEqual(page.pendingActions, []);
});

test('a recovered pending run receives the completed reply without resending its question', async () => {
  const { page, fixture } = await setup(); await page.recoverRun(runId);
  fixture.run = runSnapshot(request, { message: answer.content, tool_traces: [], pending_actions: [] });
  await page.refreshRun(); assert.equal(page.loading, false);
  assert.equal(visibleMessages.call(page).filter(item => item.role === 'user').length, 1);
  assert.equal(visibleMessages.call(page).find(item => item.role === 'assistant').content, answer.content);
  assert.deepEqual(fixture.calls, [['agentRun', runId], ['agentRun', runId]]);
});

test('sending a question leaves welcome mode and preserves the reply', async () => {
  const { page } = await setup(); page.prompt = question.content; await page.send();
  assert.equal(isWelcome.call(page), false); assert.equal(visibleMessages.call(page).at(-1).content, '**安排完成**');
});

test('a new conversation with no saved history keeps the welcome screen', async () => {
  const { page } = await setup(); page.enterConversation('new-session', null);
  assert.equal(isWelcome.call(page), true); assert.equal(visibleMessages.call(page).length, 0);
});

test('manual movement of unchanged content never consumes a pending bottom scroll', async () => {
  const { page, fixture, content } = await setup();
  page.contentHeight = 1200; page.appendMessage('assistant', '内容'); content(1200, 1200, -600, -400);
  assert.deepEqual(fixture.scrolls, []); content(1200, 1400);
  assert.deepEqual(fixture.scrolls, [{ kind: 'edge', edge: 'bottom' }]);
});

test('new content follows the latest reply without retriggering on position changes', async () => {
  const { page, fixture, content } = await setup();
  page.contentHeight = 1200; page.appendMessage('assistant', '回答');
  content(1200, 1400); content(1400, 1400, 0, -800);
  assert.deepEqual(fixture.scrolls, [{ kind: 'edge', edge: 'bottom' }]);
});

test('an arriving reply preserves position immediately after an upward drag', async () => {
  const { page, fixture, content, viewEvent, sources } = await setup();
  page.contentHeight = 1200; page.viewportHeight = 400;
  viewEvent('onWillScroll', 0, -1, 1, sources.DRAG);
  page.appendMessage('assistant', '新回答'); content(1200, 1400);
  assert.deepEqual(fixture.scrolls, []); assert.equal(page.unreadMessages, 1);
});

test('mouse wheel and inertial upward scrolling preserve the reading position', async () => {
  for (const sourceName of ['FLING', 'OTHER_USER_INPUT', 'SCROLL_BAR', 'SCROLL_BAR_FLING']) {
    const { page, fixture, content, viewEvent, sources } = await setup();
    page.contentHeight = 1200; page.viewportHeight = 400;
    viewEvent('onWillScroll', 0, -100, 1, sources[sourceName]);
    page.appendMessage('assistant', '新回答'); content(1200, 1400);
    assert.deepEqual(fixture.scrolls, [], sourceName);
  }
});

test('following resumes only when downward reading reaches the bottom', async () => {
  const { page, fixture, content, viewEvent, sources } = await setup();
  page.contentHeight = 2000; page.viewportHeight = 400;
  viewEvent('onWillScroll', 0, -100, 1, sources.DRAG);
  fixture.offset = 1590; viewEvent('onScroll');
  page.appendMessage('assistant', '暂不滚动'); content(2000, 2100);
  assert.deepEqual(fixture.scrolls, []); viewEvent('onReachEnd');
  page.appendMessage('assistant', '恢复跟随'); content(2100, 2200);
  assert.deepEqual(fixture.scrolls, [{ kind: 'edge', edge: 'bottom' }]); assert.equal(page.unreadMessages, 0);
});

test('controller scrolling does not disable following the latest reply', async () => {
  for (const sourceName of ['SCROLLER', 'SCROLLER_ANIMATION']) {
    const { page, fixture, content, viewEvent, sources } = await setup();
    page.contentHeight = 1200; viewEvent('onWillScroll', 0, -100, 1, sources[sourceName]);
    page.appendMessage('assistant', '新回答'); content(1200, 1400);
    assert.deepEqual(fixture.scrolls, [{ kind: 'edge', edge: 'bottom' }], sourceName);
  }
});

test('sending a new question resumes following after reading older messages', async () => {
  const { page, fixture, content, viewEvent, sources } = await setup();
  page.contentHeight = 1200; page.viewportHeight = 400;
  viewEvent('onWillScroll', 0, -200, 1, sources.DRAG);
  page.prompt = question.content; await page.send(); content(1200, 1400);
  assert.deepEqual(fixture.scrolls, [{ kind: 'edge', edge: 'bottom' }]);
});

test('the welcome screen never auto-scrolls when its content changes size', async () => {
  const { fixture, content } = await setup(); content(400, 600); assert.deepEqual(fixture.scrolls, []);
});
