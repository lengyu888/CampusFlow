import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';

// Execute the shipped adapter with native APIs substituted. This verifies callback
// and cleanup contracts; it does not compile ArkTS or prove microphone/playback support.
const source = readFileSync(new URL('../entry/src/main/ets/services/HarmonyVoiceDriver.ets', import.meta.url), 'utf8')
  .replace(/^import [^\n]+;\r?\n/gm, '')
  .replace('export class HarmonyVoiceDriver', 'class HarmonyVoiceDriver');
const voiceSource = readFileSync(new URL('../entry/src/main/ets/utils/VoiceInteraction.ets', import.meta.url), 'utf8');
const voiceRuntime = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(voiceSource,
  { mode: 'transform' })).toString('base64')}`);
const makeClass = new Function('speechRecognizer', 'textToSpeech', 'abilityAccessCtrl', 'canIUse', 'VoiceInteractionError',
  stripTypeScriptTypes(source, { mode: 'transform' }) + '\nreturn HarmonyVoiceDriver;');

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((ok, fail) => { resolve = ok; reject = fail; });
  return { promise, resolve, reject };
}

function nativeEngine(overrides = {}) {
  return {
    listener: undefined,
    calls: [],
    setListener(listener) { this.listener = listener; this.calls.push(['setListener']); },
    startListening(params) { this.calls.push(['startListening', params]); },
    finish(id) { this.calls.push(['finish', id]); },
    cancel(id) { this.calls.push(['cancel', id]); },
    speak(text, params) { this.calls.push(['speak', text, params]); },
    stop() { this.calls.push(['stop']); },
    shutdown() { this.calls.push(['shutdown']); },
    ...overrides
  };
}

function callbacks() {
  const calls = [];
  return {
    calls,
    onStart: () => { calls.push(['start']); },
    onResult: (text) => { calls.push(['result', text]); },
    onComplete: () => { calls.push(['complete']); },
    onError: (message) => { calls.push(['error', message]); }
  };
}

function harness(options = {}) {
  const asr = nativeEngine(options.asrOverrides);
  const tts = nativeEngine(options.ttsOverrides);
  const calls = [];
  const context = { marker: 'fixture-context' };
  const Driver = makeClass({
    createEngine: async (params) => {
      calls.push(['createAsr', params]);
      return options.createAsr ? options.createAsr(params) : asr;
    }
  }, {
    createEngine: async (params) => {
      calls.push(['createTts', params]);
      return options.createTts ? options.createTts(params) : tts;
    }
  }, {
    GrantStatus: { PERMISSION_GRANTED: 0 },
    createAtManager: () => ({
      requestPermissionsFromUser: async (actualContext, permissions) => {
        calls.push(['permission', actualContext, permissions]);
        return options.permission ? options.permission() : { authResults: [0] };
      }
    })
  }, (capability) => {
    calls.push(['capability', capability]);
    return options.capabilities?.includes(capability) ?? true;
  }, voiceRuntime.VoiceInteractionError);
  return { driver: new Driver(options.noContext ? undefined : context), asr, tts, calls, context };
}

function callCount(engine, method) {
  return engine.calls.filter(([name]) => name === method).length;
}

test('capabilities use the documented ASR and TTS system capability identifiers', () => {
  const { driver, calls } = harness({ capabilities: ['SystemCapability.AI.SpeechRecognizer'] });
  assert.deepEqual(driver.capabilities(), { recognition: true, synthesis: false });
  assert.deepEqual(calls, [
    ['capability', 'SystemCapability.AI.SpeechRecognizer'],
    ['capability', 'SystemCapability.AI.TextToSpeech']
  ]);
});

test('denied or missing microphone permission never initializes or starts an engine', async () => {
  for (const authResults of [[-1], []]) {
    const { driver, calls, asr, context } = harness({ permission: async () => ({ authResults }) });
    await assert.rejects(driver.startListening('denied', callbacks()), /麦克风权限/);
    assert.deepEqual(calls, [['permission', context, ['ohos.permission.MICROPHONE']]]);
    assert.equal(asr.calls.length, 0);
  }
  const missing = harness({ noContext: true });
  await assert.rejects(missing.driver.startListening('no-context', callbacks()), /麦克风权限/);
  assert.equal(missing.calls.length, 0);
});

test('permission failures expose a usable message without native diagnostic contents', async () => {
  const { driver, calls } = harness({ permission: async () => { throw new Error('PRIVATE_NATIVE_DETAILS'); } });
  await assert.rejects(driver.startListening('permission-error', callbacks()), (error) => {
    assert.match(error.message, /麦克风授权未完成/);
    assert.doesNotMatch(error.message, /PRIVATE_NATIVE_DETAILS/);
    return true;
  });
  assert.equal(calls.filter(([name]) => name === 'createAsr').length, 0);
});

test('cancel while permission is pending prevents even a late grant from creating the engine', async () => {
  const permission = deferred();
  const { driver, calls } = harness({ permission: () => permission.promise });
  const events = callbacks();
  const starting = driver.startListening('grant-late', events);
  driver.cancelListening('grant-late');
  permission.resolve({ authResults: [0] });
  await starting;
  assert.equal(calls.filter(([name]) => name === 'createAsr').length, 0);
  assert.deepEqual(events.calls, []);
});

test('a recognizer created after cancellation is shut down without starting or notifying UI', async () => {
  const creating = deferred();
  const entered = deferred();
  const { driver, asr } = harness({ createAsr: () => { entered.resolve(); return creating.promise; } });
  const events = callbacks();
  const starting = driver.startListening('engine-late', events);
  await entered.promise;
  driver.cancelListening('engine-late');
  creating.resolve(asr);
  await starting;
  assert.deepEqual(asr.calls, [['shutdown']]);
  assert.deepEqual(events.calls, []);
});

test('ASR uses offline Chinese microphone mode and replaces partials while accumulating final clauses', async () => {
  const { driver, asr, calls } = harness();
  const events = callbacks();
  await driver.startListening('asr-1', events);
  assert.deepEqual(calls.find(([name]) => name === 'createAsr')[1], {
    language: 'zh-CN', online: 1, extraParams: { locate: 'CN', recognizerMode: 'short' }
  });
  assert.deepEqual(asr.calls.find(([name]) => name === 'startListening')[1], {
    sessionId: 'asr-1',
    audioInfo: { audioType: 'pcm', sampleRate: 16000, sampleBit: 16, soundChannel: 1 },
    extraParams: { recognitionMode: 0 }
  });
  asr.listener.onStart('other-session', '');
  asr.listener.onResult('other-session', { result: '不属于当前会话', isFinal: true, isLast: true });
  asr.listener.onStart('asr-1', '');
  asr.listener.onResult('asr-1', { result: '安排', isFinal: false, isLast: false });
  asr.listener.onResult('asr-1', { result: '安排复习。', isFinal: true, isLast: false });
  asr.listener.onResult('asr-1', { result: '今晚', isFinal: false, isLast: false });
  asr.listener.onResult('asr-1', { result: '今晚八点。', isFinal: true, isLast: true });
  asr.listener.onComplete('asr-1', '');
  asr.listener.onError('asr-1', 123, 'late error');
  assert.deepEqual(events.calls, [
    ['start'], ['result', '安排'], ['result', '安排复习。'],
    ['result', '安排复习。今晚'], ['result', '安排复习。今晚八点。'], ['complete']
  ]);
  assert.equal(callCount(asr, 'shutdown'), 1);
});

test('the last sentence partial does not end recognition before its final result', async () => {
  const { driver, asr } = harness();
  const events = callbacks();
  await driver.startListening('last-partial', events);
  asr.listener.onResult('last-partial', { result: '明天', isFinal: false, isLast: true });
  assert.equal(callCount(asr, 'shutdown'), 0);
  assert.deepEqual(events.calls, [['result', '明天']]);
  asr.listener.onResult('last-partial', { result: '明天下午复习。', isFinal: true, isLast: true });
  assert.deepEqual(events.calls, [['result', '明天'], ['result', '明天下午复习。'], ['complete']]);
});

test('finish waits for the result callback, and cancel drops all later callbacks', async () => {
  const { driver, asr } = harness();
  const events = callbacks();
  await driver.startListening('finish-1', events);
  driver.finishListening('wrong-id');
  assert.equal(callCount(asr, 'finish'), 0);
  driver.finishListening('finish-1');
  assert.equal(callCount(asr, 'finish'), 1);
  assert.equal(callCount(asr, 'shutdown'), 0);
  asr.listener.onResult('finish-1', { result: '保留完整结果', isFinal: true, isLast: false });
  asr.listener.onComplete('finish-1', '');
  assert.deepEqual(events.calls, [['result', '保留完整结果'], ['complete']]);

  const cancelled = harness();
  const cancelledEvents = callbacks();
  await cancelled.driver.startListening('cancel-1', cancelledEvents);
  cancelled.driver.cancelListening('cancel-1');
  cancelled.asr.listener.onStart('cancel-1', '');
  cancelled.asr.listener.onResult('cancel-1', { result: '不应写回草稿', isFinal: true, isLast: true });
  cancelled.asr.listener.onComplete('cancel-1', '');
  cancelled.asr.listener.onError('cancel-1', 1, 'late');
  assert.deepEqual(cancelledEvents.calls, []);
  assert.equal(callCount(cancelled.asr, 'cancel'), 1);
  assert.equal(callCount(cancelled.asr, 'shutdown'), 1);
});

test('ASR start or finish failure releases its engine and invalidates pending callbacks', async () => {
  const failingStart = harness({ asrOverrides: { startListening() { throw new Error('PRIVATE_START'); } } });
  await assert.rejects(failingStart.driver.startListening('start-fail', callbacks()), /无法开始录音/);
  assert.equal(callCount(failingStart.asr, 'cancel'), 1);
  assert.equal(callCount(failingStart.asr, 'shutdown'), 1);

  const failingFinish = harness({ asrOverrides: { finish() { throw new Error('PRIVATE_FINISH'); } } });
  const events = callbacks();
  await failingFinish.driver.startListening('finish-fail', events);
  assert.throws(() => failingFinish.driver.finishListening('finish-fail'), /未取得完整识别结果/);
  failingFinish.asr.listener.onComplete('finish-fail', '');
  assert.equal(callCount(failingFinish.asr, 'cancel'), 1);
  assert.equal(callCount(failingFinish.asr, 'shutdown'), 1);
  assert.deepEqual(events.calls, []);
});

test('ASR native errors report once and release the recognizer without leaking native detail', async () => {
  const { driver, asr } = harness();
  const events = callbacks();
  await driver.startListening('error-1', events);
  asr.listener.onError('error-1', 1002200002, 'PRIVATE_NATIVE_DETAILS');
  asr.listener.onError('error-1', 1002200002, 'PRIVATE_NATIVE_DETAILS');
  assert.equal(events.calls.length, 1);
  assert.equal(events.calls[0][0], 'error');
  assert.doesNotMatch(events.calls[0][1], /PRIVATE_NATIVE_DETAILS/);
  assert.equal(callCount(asr, 'shutdown'), 1);
});

test('TTS preserves all Unicode text and advances chunks only on playback completion', async () => {
  const { driver, tts, calls } = harness();
  const events = callbacks();
  const text = '学'.repeat(499) + '🧑🏽‍💻' + '习'.repeat(507) + '\n最后一句。';
  await driver.speak('read-1', text, events);
  const params = calls.find(([name]) => name === 'createTts')[1];
  assert.equal(params.language, 'zh-CN');
  assert.equal(params.person, 0);
  assert.equal(params.online, 1);
  assert.equal(callCount(tts, 'speak'), 1);
  const play = (index) => {
    const id = `read-1-${index}`;
    tts.listener.onStart(id, {});
    tts.listener.onComplete(id, { type: 0, message: 'synthesized' });
    assert.equal(callCount(tts, 'speak'), index + 1);
    tts.listener.onComplete(id, { type: 1, message: 'played' });
    tts.listener.onComplete(id, { type: 1, message: 'duplicate old completion' });
  };
  play(0);
  play(1);
  play(2);
  const spoken = tts.calls.filter(([name]) => name === 'speak');
  assert.equal(spoken.length, 3);
  assert.equal(spoken.map(([, chunk]) => chunk).join(''), text);
  assert.ok(spoken.every(([, chunk]) => Array.from(chunk).length <= 500));
  assert.ok(spoken.every(([, , params]) => params.extraParams.playType === 1 && params.extraParams.queueMode === 0));
  assert.deepEqual(spoken.map(([, , params]) => params.requestId), ['read-1-0', 'read-1-1', 'read-1-2']);
  assert.deepEqual(events.calls, [['start'], ['complete']]);
  assert.equal(callCount(tts, 'stop'), 1);
  assert.equal(callCount(tts, 'shutdown'), 1);
});

test('stopping and replacing playback isolates every old request callback', async () => {
  const first = nativeEngine();
  const second = nativeEngine();
  let count = 0;
  const { driver } = harness({ createTts: () => ++count === 1 ? first : second });
  const oldEvents = callbacks();
  const newEvents = callbacks();
  await driver.speak('old', '旧回答', oldEvents);
  await driver.speak('new', '新回答', newEvents);
  first.listener.onStart('old-0', {});
  first.listener.onComplete('old-0', { type: 1 });
  first.listener.onStop('old-0', { type: 0 });
  first.listener.onError('old-0', 1, 'old failure');
  second.listener.onComplete('wrong-id', { type: 1 });
  assert.deepEqual(oldEvents.calls, []);
  assert.deepEqual(newEvents.calls, []);
  second.listener.onStart('new-0', {});
  second.listener.onComplete('new-0', { type: 1 });
  assert.deepEqual(newEvents.calls, [['start'], ['complete']]);
  assert.equal(callCount(first, 'stop'), 1);
  assert.equal(callCount(first, 'shutdown'), 1);
});

test('a synthesizer created after stop or disposal is shut down without speaking', async () => {
  for (const action of ['stopSpeaking', 'dispose']) {
    const creating = deferred();
    const { driver, tts } = harness({ createTts: () => creating.promise });
    const events = callbacks();
    const speaking = driver.speak(`late-${action}`, '迟到回答', events);
    driver[action]();
    creating.resolve(tts);
    await speaking;
    assert.deepEqual(tts.calls, [['shutdown']]);
    assert.deepEqual(events.calls, []);
  }
});

test('TTS synchronous and asynchronous native failures release resources and notify once', async () => {
  const synchronous = harness({ ttsOverrides: { speak() { throw new Error('PRIVATE_SPEAK'); } } });
  const syncEvents = callbacks();
  await synchronous.driver.speak('sync-error', '文本', syncEvents);
  assert.equal(syncEvents.calls.length, 1);
  assert.equal(syncEvents.calls[0][0], 'error');
  assert.doesNotMatch(syncEvents.calls[0][1], /PRIVATE_SPEAK/);
  assert.equal(callCount(synchronous.tts, 'stop'), 1);
  assert.equal(callCount(synchronous.tts, 'shutdown'), 1);
  for (const callback of ['onError', 'onStop']) {
    const { driver, tts } = harness();
    const events = callbacks();
    await driver.speak(callback, '文本', events);
    if (callback === 'onError') { tts.listener.onError(`${callback}-0`, 1, 'PRIVATE_DETAIL'); }
    else { tts.listener.onStop(`${callback}-0`, { type: 0, message: 'PRIVATE_DETAIL' }); }
    tts.listener.onComplete(`${callback}-0`, { type: 1 });
    assert.equal(events.calls.length, 1);
    assert.equal(events.calls[0][0], 'error');
    assert.doesNotMatch(events.calls[0][1], /PRIVATE_DETAIL/);
    assert.equal(callCount(tts, 'stop'), 1);
    assert.equal(callCount(tts, 'shutdown'), 1);
  }
});

test('dispose is idempotent, stops active speech and rejects further native work', async () => {
  const { driver, asr, tts, calls } = harness();
  await driver.startListening('record', callbacks());
  await driver.speak('read', '朗读时先停录音', callbacks());
  assert.equal(callCount(asr, 'cancel'), 1);
  assert.equal(callCount(asr, 'shutdown'), 1);
  driver.dispose();
  driver.dispose();
  assert.equal(callCount(tts, 'stop'), 1);
  assert.equal(callCount(tts, 'shutdown'), 1);
  const before = calls.length;
  await assert.rejects(driver.startListening('after', callbacks()), /已停止/);
  await assert.rejects(driver.speak('after', '正文', callbacks()), /已停止/);
  assert.equal(calls.length, before);
});

test('synchronous callbacks and native exceptions during cancellation cannot revive a stopped operation', async () => {
  const { driver, asr, tts } = harness({
    asrOverrides: {
      cancel(id) {
        this.calls.push(['cancel', id]);
        this.listener.onError(id, 1, 'cancel callback');
        throw new Error('native cancel already finished');
      },
      shutdown() { this.calls.push(['shutdown']); throw new Error('already shut down'); }
    },
    ttsOverrides: {
      stop() {
        this.calls.push(['stop']);
        this.listener.onStop('speech-0', { type: 0, message: 'stop callback' });
        throw new Error('native stop already finished');
      },
      shutdown() { this.calls.push(['shutdown']); throw new Error('already shut down'); }
    }
  });
  const recognition = callbacks();
  const speech = callbacks();
  await driver.startListening('recognition', recognition);
  await driver.speak('speech', '回答', speech);
  assert.doesNotThrow(() => driver.dispose());
  assert.doesNotThrow(() => driver.dispose());
  assert.deepEqual(recognition.calls, []);
  assert.deepEqual(speech.calls, []);
  assert.equal(callCount(asr, 'cancel'), 1);
  assert.equal(callCount(asr, 'shutdown'), 1);
  assert.equal(callCount(tts, 'stop'), 1);
  assert.equal(callCount(tts, 'shutdown'), 1);
});
