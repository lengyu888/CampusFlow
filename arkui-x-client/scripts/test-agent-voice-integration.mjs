import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';
import { makeRunController, runSnapshot, rememberHistory } from './helpers/agent-run-ui-fixture.mjs';

const voiceSource = readFileSync(new URL('../entry/src/main/ets/utils/VoiceInteraction.ets', import.meta.url), 'utf8');
const { VoiceInteraction } = await import(
  `data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(voiceSource)).toString('base64')}`);
const helperSource = readFileSync(new URL('../entry/src/main/ets/utils/AgentFeedback.ets', import.meta.url), 'utf8')
  .replace(/^import \{[^\n]+\} from '\.\.\/model\/ApiModels';\r?\n/, '');
const helper = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(helperSource)).toString('base64')}`);
const reliabilitySource = readFileSync(new URL('../entry/src/main/ets/utils/ActionReliability.ets', import.meta.url), 'utf8')
  .replace(/^import \{[\s\S]*?\} from '[^']+';\r?\n/gm, '');
const reliability = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(reliabilitySource)).toString('base64')}`);
const source = readFileSync(new URL('../entry/src/main/ets/pages/AgentPage.ets', import.meta.url), 'utf8');
const firstBuilder = source.indexOf('\n  @Builder');
assert.ok(firstBuilder > 0, 'the non-UI method boundary must exist');
// Run the production page methods and voice controller. Only ArkUI, platform audio,
// the clock and network/storage are replaced; this does not validate native UI or audio.
const pageSource = source.slice(0, firstBuilder)
  .replace(/^import [^\n]+;\r?\n/gm, '')
  .replace(/^@Component\r?\n/m, '')
  .replace(/@(Prop|State)\s+|@Watch\('[^']+'\)\s*/g, '')
  .replace('export struct AgentPage', 'class AgentPage') + '\n}\n';
const createPage = new Function('CampusFlowApi', 'Scroller', 'CampusFlowRequestError',
  'displayToolTraces', 'mergeActions', 'restoreDraft', 'localRequestFailure', 'AppTheme', 'localHistory',
  'PlatformVoiceDriver', 'VoiceInteraction', 'AgentRunController', ...Object.keys(reliability), stripTypeScriptTypes(pageSource) + '\nreturn AgentPage;');

function fixture({ chat = null, probe = null } = {}) {
  const calls = [];
  const drivers = [];
  const context = { fixtureContext: true };
  let nextTimer = 0;
  const timers = new Map();
  const clock = {
    setTimeout(callback, delay) { const id = ++nextTimer; timers.set(id, { callback, delay }); return id; },
    clearTimeout(id) { timers.delete(id); }
  };
  class Driver {
    recognition = [];
    speech = [];
    constructor(receivedContext) { assert.equal(receivedContext, context); drivers.push(this); }
    capabilities() { return { recognition: true, synthesis: true }; }
    async probe() { return probe ? probe() : this.capabilities(); }
    async startListening(id, events) { this.recognition.push({ id, events }); calls.push(['record', id]); }
    finishListening(id) { calls.push(['finish', id]); }
    cancelListening(id) { calls.push(['cancel-record', id]); }
    async speak(id, text, events) { this.speech.push({ id, text, events }); calls.push(['speak', id, text]); }
    stopSpeaking() { calls.push(['stop-speech']); }
    dispose() { calls.push(['dispose']); }
  }
  class Controller extends VoiceInteraction {
    constructor(driver, onChange) { super(driver, onChange, clock); }
  }
  class Api {
    async startAgentRun(request) {
      const args = [request.session_id, request.model, request.message];
      calls.push(['chat', ...args]);
      const response = chat ? await chat(...args) : { session_id: request.session_id, message: '文字回答', pending_actions: [] };
      return runSnapshot(request, response);
    }
    async confirmAction(...args) { calls.push(['confirm', ...args]); throw new Error('unexpected confirm'); }
    async cancelAction(...args) { calls.push(['reject', ...args]); throw new Error('unexpected rejection'); }
  }
  const Page = createPage(Api, class Scroller {}, helper.CampusFlowRequestError, helper.displayToolTraces,
    helper.mergeActions, helper.restoreDraft, helper.localRequestFailure, {}, {}, Driver, Controller, makeRunController(helper.CampusFlowRequestError, helper.localRequestFailure), ...Object.values(reliability));
  const page = new Page();
  page.baseUrl = 'http://fixture.invalid';
  page.token = 'test-only';
  page.voiceActive = true;
  page.getUIContext = () => ({ getHostContext: () => context });
  return { page, calls, drivers, timers,
    apiCalls: () => calls.filter(([name]) => ['chat', 'confirm', 'reject'].includes(name)),
    recognition: () => drivers.at(-1).recognition.at(-1).events,
    speech: () => drivers.at(-1).speech.at(-1).events };
}

async function capture(f, phase = 'review', transcript = '安排明天复习') {
  await f.page.startVoice();
  if (phase === 'starting') return;
  f.recognition().onStart();
  f.recognition().onResult(transcript);
  if (phase === 'listening') return;
  f.page.voiceInteraction.finishListening();
  if (phase === 'recognizing') return;
  f.recognition().onComplete();
  assert.equal(f.page.voiceState.phase, 'review');
}

function reply(f, role = 'assistant', content = '请先复习操作系统。') {
  f.page.appendMessage(role, content);
  return f.page.messages.at(-1);
}

test('microphone guards prevent driver creation while hidden, inactive or busy', async () => {
  for (const blocked of [{ pageActive: false }, { voiceActive: false }, { loading: true },
    { deletionBusy: true }, { decisionId: 'pending-write' }]) {
    const f = fixture();
    Object.assign(f.page, blocked);
    await f.page.startVoice();
    assert.equal(f.drivers.length, 0, JSON.stringify(blocked));
    assert.deepEqual(f.calls, []);
  }
});

test('every capture phase prevents a second recording and a send without changing the draft', async () => {
  for (const phase of ['starting', 'listening', 'recognizing', 'review']) {
    const f = fixture();
    f.page.prompt = '尚未发送的草稿';
    await capture(f, phase);
    assert.equal(f.page.capturePending(), true, phase);
    await f.page.startVoice();
    await f.page.send();
    assert.equal(f.drivers[0].recognition.length, 1);
    assert.equal(f.page.prompt, '尚未发送的草稿');
    assert.equal(f.page.voiceState.phase, phase);
    assert.equal(f.page.messages.length, 1, 'no user message is appended while capturing or reviewing');
    assert.deepEqual(f.apiCalls(), []);
    f.page.cancelVoice();
  }
});

test('recognition and explicit transcript acceptance only fill the draft, never send or confirm', async () => {
  const f = fixture();
  f.page.prompt = '  原有草稿  ';
  f.page.pendingActions = [{ proposal_id: 'proposal-1', status: 'pending' }];
  await capture(f, 'review', '  识别的文字  ');
  assert.equal(f.page.prompt, '  原有草稿  ');
  assert.deepEqual(f.apiCalls(), []);
  f.page.editVoiceTranscript('  用户编辑后的语音文字  ');
  f.page.useVoiceTranscript();
  assert.equal(f.page.prompt, '原有草稿\n用户编辑后的语音文字');
  assert.equal(f.page.voiceState.phase, 'idle');
  assert.match(f.page.voiceNotice, /手动发送/);
  assert.deepEqual(f.page.pendingActions, [{ proposal_id: 'proposal-1', status: 'pending' }]);
  assert.equal(f.page.messages.length, 1);
  assert.deepEqual(f.apiCalls(), []);
  await f.page.send();
  assert.equal(f.apiCalls().length, 1);
  assert.equal(f.apiCalls()[0][0], 'chat');
  assert.equal(f.apiCalls()[0][3], '原有草稿\n用户编辑后的语音文字');
});

test('combined Unicode length accepts exactly 8000 characters and keeps both drafts when over the limit', async () => {
  const f = fixture();
  f.page.prompt = '  原  ';
  const originalTranscript = `  ${'😀'.repeat(7999)}  `;
  await capture(f, 'review', originalTranscript);
  f.page.useVoiceTranscript();
  assert.equal(f.page.prompt, '  原  ');
  assert.equal(f.page.voiceState.transcript, originalTranscript);
  assert.equal(f.page.voiceState.phase, 'review');
  assert.match(f.page.voiceNotice, /两份文字均已保留/);
  assert.deepEqual(f.apiCalls(), []);
  f.page.editVoiceTranscript('😀'.repeat(7998));
  f.page.useVoiceTranscript();
  assert.equal(Array.from(f.page.prompt).length, 8000, 'one draft character plus newline plus 7998 emoji');
  assert.equal(f.page.prompt, `原\n${'😀'.repeat(7998)}`);
  assert.equal(f.page.voiceState.phase, 'idle');
  assert.deepEqual(f.apiCalls(), []);
});

test('empty input receives a complete transcript without a leading newline; blank review remains editable', async () => {
  const f = fixture();
  f.page.prompt = '   ';
  await capture(f);
  f.page.editVoiceTranscript('   ');
  f.page.useVoiceTranscript();
  assert.equal(f.page.prompt, '   ');
  assert.equal(f.page.voiceState.phase, 'review');
  assert.match(f.page.voiceState.message, /请先填写文字/);
  f.page.editVoiceTranscript('😀'.repeat(8000));
  f.page.useVoiceTranscript();
  assert.equal(f.page.prompt, '😀'.repeat(8000));
  assert.equal(f.page.voiceState.phase, 'idle');
  assert.deepEqual(f.apiCalls(), []);
});

test('hiding or backgrounding the mounted page stops capture and preserves received text without resuming', async () => {
  for (const phase of ['starting', 'listening', 'recognizing', 'review']) {
    const f = fixture();
    f.page.prompt = '输入框草稿';
    await capture(f, phase, '已识别文字');
    const oldEvents = f.recognition();
    f.page.voiceActive = false;
    f.page.voiceActivityChanged();
    const suspended = { ...f.page.voiceState };
    assert.equal(suspended.phase, phase === 'starting' ? 'idle' : 'review');
    assert.equal(suspended.transcript, phase === 'starting' ? '' : '已识别文字');
    assert.equal(f.page.prompt, '输入框草稿');
    assert.equal(f.timers.size, 0);
    if (phase !== 'review') assert.ok(f.calls.some(([name]) => name === 'cancel-record'));
    oldEvents.onStart(); oldEvents.onResult('迟到覆盖'); oldEvents.onComplete(); oldEvents.onError('迟到错误');
    assert.deepEqual(f.page.voiceState, suspended);
    f.page.voiceActive = true;
    f.page.voiceActivityChanged();
    assert.deepEqual(f.page.voiceState, suspended);
    assert.equal(f.drivers[0].recognition.length, 1);
    assert.deepEqual(f.apiCalls(), []);
  }
});

test('hiding retains an intentionally cleared review and returning does not send it', async () => {
  const f = fixture();
  await capture(f);
  f.page.editVoiceTranscript('');
  f.page.voiceActive = false;
  f.page.voiceActivityChanged();
  f.page.voiceActive = true;
  f.page.voiceActivityChanged();
  assert.equal(f.page.voiceState.phase, 'review');
  assert.equal(f.page.voiceState.transcript, '');
  assert.deepEqual(f.apiCalls(), []);
});

test('speech is restricted to an existing assistant answer and respects activity and busy guards', async () => {
  const f = fixture();
  for (const message of [f.page.messages[0], reply(f, 'user'), reply(f, 'feedback'),
    { id: 'removed-answer', role: 'assistant', content: '已删除回答' }]) {
    await f.page.speakReply(message);
  }
  assert.equal(f.drivers.length, 0);
  for (const blocked of [{ pageActive: false }, { voiceActive: false }, { loading: true },
    { deletionBusy: true }, { decisionId: 'pending-write' }]) {
    const guarded = fixture();
    const message = reply(guarded);
    Object.assign(guarded.page, blocked);
    await guarded.page.speakReply(message);
    assert.equal(guarded.drivers.length, 0, JSON.stringify(blocked));
  }
  for (const phase of ['starting', 'listening', 'recognizing', 'review']) {
    const guarded = fixture();
    await capture(guarded, phase);
    await guarded.page.speakReply(reply(guarded));
    assert.equal(guarded.drivers[0].speech.length, 0);
    assert.equal(guarded.page.voiceState.phase, phase);
    guarded.page.cancelVoice();
  }
});

test('tapping the current answer stops preparation or playback; a different answer starts explicitly', async () => {
  for (const started of [false, true]) {
    const f = fixture();
    const first = reply(f);
    await f.page.speakReply(first);
    if (started) f.speech().onStart();
    assert.equal(f.page.speechPending(), true);
    await f.page.speakReply(first);
    assert.equal(f.page.voiceState.phase, 'idle');
    assert.equal(f.calls.filter(([name]) => name === 'stop-speech').length, 1);
    assert.equal(f.drivers[0].speech.length, 1);
    const second = reply(f, 'assistant', '另一条回答');
    await f.page.speakReply(second);
    assert.equal(f.page.voiceState.speakingMessageId, second.id);
    assert.equal(f.drivers[0].speech.length, 2);
    assert.deepEqual(f.apiCalls(), []);
    f.page.cancelVoice();
  }
});

test('manual send stops pending or active playback before the API call and does not auto-read the answer', async () => {
  for (const started of [false, true]) {
    const f = fixture();
    await f.page.speakReply(reply(f));
    if (started) f.speech().onStart();
    const oldSpeech = f.speech();
    f.page.prompt = '下一轮手动问题';
    await f.page.send();
    const stopIndex = f.calls.findIndex(([name]) => name === 'stop-speech');
    const chatIndex = f.calls.findIndex(([name]) => name === 'chat');
    assert.ok(stopIndex >= 0 && stopIndex < chatIndex);
    assert.equal(f.drivers[0].speech.length, 1, 'the new assistant answer never auto-starts playback');
    assert.equal(f.page.voiceState.phase, 'idle');
    oldSpeech.onStart(); oldSpeech.onComplete(); oldSpeech.onError('旧播报错误');
    assert.equal(f.page.voiceState.phase, 'idle');
    assert.equal(f.page.messages.at(-1).content, '文字回答');
    assert.equal(f.apiCalls().length, 1);
  }
});

test('hiding stops playback and a new suggested prompt suspends recording without losing received text', async () => {
  const speaking = fixture();
  await speaking.page.speakReply(reply(speaking));
  speaking.speech().onStart();
  speaking.page.voiceActive = false;
  speaking.page.voiceActivityChanged();
  assert.equal(speaking.page.voiceState.phase, 'idle');
  assert.ok(speaking.calls.some(([name]) => name === 'stop-speech'));
  assert.equal(speaking.timers.size, 0);
  const recording = fixture();
  await capture(recording, 'listening', '需要保留的识别文字');
  recording.page.initialPrompt = '规划页传来的新草稿';
  recording.page.initialPromptChanged();
  assert.equal(recording.page.prompt, '规划页传来的新草稿');
  assert.equal(recording.page.voiceState.phase, 'review');
  assert.equal(recording.page.voiceState.transcript, '需要保留的识别文字');
  assert.deepEqual(recording.apiCalls(), []);
});

test('page teardown disposes audio and rejects all late native callbacks without recreating a controller', async () => {
  for (const kind of ['recording', 'speech']) {
    const f = fixture();
    if (kind === 'recording') await capture(f, 'listening');
    else await f.page.speakReply(reply(f));
    const events = kind === 'recording' ? f.recognition() : f.speech();
    f.page.aboutToDisappear();
    const state = { ...f.page.voiceState };
    events.onStart(); events.onResult?.('迟到文字'); events.onComplete(); events.onError('迟到错误');
    await f.page.startVoice();
    await f.page.speakReply(reply(f));
    assert.equal(f.page.voiceInteraction, null);
    assert.equal(f.drivers.length, 1);
    assert.deepEqual(f.page.voiceState, state);
    assert.equal(f.calls.filter(([name]) => name === 'dispose').length, 1);
    assert.equal(f.timers.size, 0);
    assert.deepEqual(f.apiCalls(), []);
  }
});

test('leaving during native capability probe prevents late microphone startup and permits a new explicit probe', async () => {
  let resolve; let count = 0;
  const waiting = new Promise(ok => resolve = ok);
  const f = fixture({ probe: () => ++count === 1 ? waiting : Promise.resolve({ recognition: true, synthesis: true }) });
  const starting = f.page.startVoice();
  assert.equal(f.page.voiceProbeBusy, true);
  f.page.voiceActive = false; f.page.voiceActivityChanged();
  resolve({ recognition: true, synthesis: true }); await starting;
  assert.equal(f.page.voiceProbeBusy, false); assert.equal(f.calls.some(([name]) => name === 'record'), false);
  f.page.voiceActive = true; f.page.voiceActivityChanged(); await f.page.startVoice();
  assert.equal(f.calls.filter(([name]) => name === 'record').length, 1);
  f.page.cancelVoice();
});
test('sending while native capabilities are pending invalidates the old probe and preserves text as the only request', async () => {
  let resolve; const waiting = new Promise(ok => resolve = ok);
  const f = fixture({ probe: () => waiting });
  f.page.prompt = '仅发送这条文字'; const starting = f.page.startVoice();
  await f.page.send(); resolve({ recognition: true, synthesis: true }); await starting;
  assert.equal(f.calls.some(([name]) => name === 'record'), false);
  assert.equal(f.apiCalls().length, 1); assert.equal(f.apiCalls()[0][3], '仅发送这条文字');
});
test('capability probe failure keeps text usable and never exposes raw device diagnostics', async () => {
  const f = fixture({ probe: async () => { throw Error('secret device path'); } });
  await f.page.startVoice(); assert.equal(f.page.voiceProbeBusy, false);
  assert.doesNotMatch(f.page.voiceNotice, /secret|path/);
  assert.equal(f.calls.some(([name]) => name === 'record'), false);
  f.page.prompt = '仍可发送'; await f.page.send(); assert.equal(f.apiCalls().length, 1);
});
