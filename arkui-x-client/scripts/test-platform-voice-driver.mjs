import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';

const voiceSource = readFileSync(new URL('../entry/src/main/ets/utils/VoiceInteraction.ets', import.meta.url), 'utf8');
const { VoiceInteractionError } = await import(
  `data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(voiceSource)).toString('base64')}`);
const source = readFileSync(new URL('../entry/src/main/ets/services/PlatformVoiceDriver.ets', import.meta.url), 'utf8');
const loadExpression = "import('./HarmonyVoiceDriver')";
assert.equal(source.split(loadExpression).length, 2, 'the native module loading boundary must be injectable');
// Execute the real adapter with only its platform APIs and native module loader replaced.
// This is an async/platform contract test, not a native SDK build or microphone test.
const adapterSource = source.replace(/^import [^\n]+;\r?\n/gm, '')
  .replace(loadExpression, 'loadProvider()').replace('export class PlatformVoiceDriver', 'class PlatformVoiceDriver');
const createAdapter = new Function('VoiceInteractionError', 'deviceInfo', 'canIUse', 'loadProvider',
  stripTypeScriptTypes(adapterSource, { mode: 'transform' }) + '\nreturn PlatformVoiceDriver;').bind(null, VoiceInteractionError);

const abilitySource = readFileSync(new URL('../entry/src/main/ets/entryability/EntryAbility.ets', import.meta.url), 'utf8')
  .replace(/^import [^\n]+;\r?\n/gm, '').replace('export default class EntryAbility', 'class EntryAbility');
const createAbility = new Function('UIAbility', 'AppStorage',
  stripTypeScriptTypes(abilitySource) + '\nreturn EntryAbility;');

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

const recognitionEvents = { onStart() {}, onResult() {}, onComplete() {}, onError() {} };
const speechEvents = { onStart() {}, onComplete() {}, onError() {} };

function fixture({ os = 'HarmonyOS 6.1.1', recognition = true, synthesis = true,
  loader = null, nativeStart = null, nativeSpeech = null } = {}) {
  const calls = [];
  const capabilityQueries = [];
  const providers = [];
  const context = { fixtureContext: true };
  let loads = 0;
  class Provider {
    constructor(receivedContext) {
      assert.equal(receivedContext, context);
      providers.push(this);
    }
    capabilities() { return { recognition, synthesis }; }
    async startListening(id, events) {
      calls.push(['start', id, events]);
      if (nativeStart) await nativeStart(id, events);
    }
    finishListening(id) { calls.push(['finish', id]); }
    cancelListening(id) { calls.push(['cancel', id]); }
    async speak(id, text, events) {
      calls.push(['speak', id, text, events]);
      if (nativeSpeech) await nativeSpeech(id, text, events);
    }
    stopSpeaking() { calls.push(['stop']); }
    dispose() { calls.push(['dispose']); }
  }
  const module = { HarmonyVoiceDriver: Provider };
  const loadProvider = () => {
    loads++;
    return loader ? loader(module, loads) : Promise.resolve(module);
  };
  const capabilities = name => {
    capabilityQueries.push(name);
    if (name === 'SystemCapability.AI.SpeechRecognizer') return recognition;
    if (name === 'SystemCapability.AI.TextToSpeech') return synthesis;
    throw new Error('unexpected capability');
  };
  const Adapter = createAdapter({ osFullName: os }, capabilities, loadProvider);
  return { driver: new Adapter(context), calls, capabilityQueries, providers, module, loads: () => loads };
}

test('Android, iOS and unknown platforms cannot load Harmony APIs even when capability probes would return true', async () => {
  for (const os of ['Android 14', 'iOS 17.0', 'iPadOS 17.0', 'macOS Version 17.0', 'Unknown', '']) {
    const f = fixture({ os });
    assert.deepEqual(f.driver.capabilities(), { recognition: false, synthesis: false });
    await assert.rejects(f.driver.startListening('r', recognitionEvents), /不支持语音识别/);
    await assert.rejects(f.driver.speak('s', '回答', speechEvents), /不支持回答播报/);
    assert.equal(f.loads(), 0, os);
    assert.equal(f.providers.length, 0);
    assert.deepEqual(f.capabilityQueries, [], 'OS is checked before querying Harmony system capabilities');
  }
});

test('Harmony capability checks are independent and missing capabilities block provider loading', async () => {
  const missing = fixture({ recognition: false, synthesis: false });
  await assert.rejects(missing.driver.startListening('r', recognitionEvents), /不支持语音识别/);
  await assert.rejects(missing.driver.speak('s', '回答', speechEvents), /不支持回答播报/);
  assert.equal(missing.loads(), 0);
  const recognitionOnly = fixture({ os: 'OpenHarmony 5.0', synthesis: false });
  assert.deepEqual(recognitionOnly.driver.capabilities(), { recognition: true, synthesis: false });
  await recognitionOnly.driver.startListening('r', recognitionEvents);
  await assert.rejects(recognitionOnly.driver.speak('s', '回答', speechEvents), /不支持回答播报/);
  assert.equal(recognitionOnly.loads(), 1);
  assert.deepEqual(recognitionOnly.calls, [['start', 'r', recognitionEvents]]);
});

test('platform or capability lookup failures safely report unavailable without importing native code', () => {
  for (const platform of [
    { get osFullName() { throw new Error('platform unavailable'); } },
    { osFullName: 'HarmonyOS 6.1.1' }
  ]) {
    let loads = 0;
    const Adapter = createAdapter(platform, () => { throw new Error('capability unavailable'); }, () => { loads++; });
    assert.deepEqual(new Adapter(undefined).capabilities(), { recognition: false, synthesis: false });
    assert.equal(loads, 0);
  }
});

test('cancelling recognition before import resolves prevents native startup, with the loaded provider reusable', async () => {
  const loading = deferred();
  const f = fixture({ loader: () => loading.promise });
  const start = f.driver.startListening('old', recognitionEvents);
  assert.equal(f.loads(), 1);
  f.driver.cancelListening('old');
  loading.resolve(f.module);
  await start;
  assert.deepEqual(f.calls, []);
  await f.driver.startListening('new', recognitionEvents);
  assert.deepEqual(f.calls, [['start', 'new', recognitionEvents]]);
  assert.equal(f.loads(), 1);
});

test('a new recognition supersedes an old pending import and late old cancellation cannot cancel the new request', async () => {
  const loading = deferred();
  const f = fixture({ loader: () => loading.promise });
  const old = f.driver.startListening('old', recognitionEvents);
  const current = f.driver.startListening('new', recognitionEvents);
  f.driver.cancelListening('old');
  loading.resolve(f.module);
  await Promise.all([old, current]);
  assert.equal(f.loads(), 1, 'overlapping requests share only the native module loading promise');
  assert.deepEqual(f.calls, [['start', 'new', recognitionEvents]]);
  f.driver.finishListening('old');
  f.driver.cancelListening('old');
  assert.deepEqual(f.calls, [['start', 'new', recognitionEvents]]);
  f.driver.finishListening('new');
  assert.deepEqual(f.calls.at(-1), ['finish', 'new']);
});

test('late completion of an old native start cannot make an old-ID cleanup cancel a newer recognition', async () => {
  const oldNativeStart = deferred();
  const started = deferred();
  const f = fixture({ nativeStart: id => {
    if (id === 'old') { started.resolve(); return oldNativeStart.promise; }
  } });
  const old = f.driver.startListening('old', recognitionEvents);
  await started.promise;
  f.driver.cancelListening('old');
  await f.driver.startListening('new', recognitionEvents);
  oldNativeStart.resolve();
  await old;
  f.driver.cancelListening('old'); // VoiceInteraction repeats old-ID cleanup after a delayed start settles.
  assert.deepEqual(f.calls, [
    ['start', 'old', recognitionEvents], ['cancel', 'old'], ['start', 'new', recognitionEvents]
  ]);
});

test('dispose while the module imports disposes the late provider and never starts recognition or speech', async () => {
  for (const mode of ['recognition', 'speech']) {
    const loading = deferred();
    const f = fixture({ loader: () => loading.promise });
    const pending = mode === 'recognition' ? f.driver.startListening('r', recognitionEvents)
      : f.driver.speak('s', '回答', speechEvents);
    const rejected = assert.rejects(pending, /暂不可用/);
    f.driver.dispose();
    loading.resolve(f.module);
    await rejected;
    assert.equal(f.providers.length, 1);
    assert.deepEqual(f.calls, [['dispose']]);
    await assert.rejects(f.driver.startListening('retry', recognitionEvents), /语音已停止/);
    assert.equal(f.loads(), 1);
  }
});

test('failed module loading can be explicitly retried without exposing its raw diagnostic', async () => {
  const f = fixture({ loader: (module, count) => count === 1
    ? Promise.reject(new Error('private module diagnostic')) : Promise.resolve(module) });
  await assert.rejects(f.driver.startListening('first', recognitionEvents), error => {
    assert.match(error.message, /此设备的语音服务暂不可用/);
    assert.doesNotMatch(error.message, /private|diagnostic/);
    return true;
  });
  await f.driver.startListening('retry', recognitionEvents);
  assert.equal(f.loads(), 2);
  assert.equal(f.providers.length, 1);
  assert.deepEqual(f.calls, [['start', 'retry', recognitionEvents]]);
});

test('stopping speech before import settles prevents native playback', async () => {
  const loading = deferred();
  const f = fixture({ loader: () => loading.promise });
  const pending = f.driver.speak('old', '不会播出的回答', speechEvents);
  f.driver.stopSpeaking();
  loading.resolve(f.module);
  await pending;
  assert.deepEqual(f.calls, []);
  await f.driver.speak('new', '完整的新回答', speechEvents);
  assert.deepEqual(f.calls, [['speak', 'new', '完整的新回答', speechEvents]]);
  assert.equal(f.loads(), 1);
});

test('replacing pending speech starts only the current answer and disposing a loaded provider is idempotent', async () => {
  const loading = deferred();
  const f = fixture({ loader: () => loading.promise });
  const old = f.driver.speak('old', '旧回答', speechEvents);
  f.driver.stopSpeaking();
  const current = f.driver.speak('new', '新回答', speechEvents);
  loading.resolve(f.module);
  await Promise.all([old, current]);
  assert.deepEqual(f.calls, [['speak', 'new', '新回答', speechEvents]]);
  f.driver.stopSpeaking();
  f.driver.dispose();
  f.driver.dispose();
  assert.deepEqual(f.calls.slice(1), [['stop'], ['dispose']]);
});

test('EntryAbility lifecycle writes actual foreground state and clears stale true state on creation', () => {
  const values = new Map([['voiceForeground', true]]);
  const changes = [];
  const Ability = createAbility(class UIAbility {}, {
    setOrCreate(key, value) { values.set(key, value); changes.push([key, value]); }
  });
  const ability = new Ability();
  ability.onCreate({}, {});
  assert.equal(values.get('voiceForeground'), false);
  assert.equal(values.get('apiBaseUrl'), 'http://127.0.0.1:8000');
  ability.onForeground();
  assert.equal(values.get('voiceForeground'), true);
  ability.onBackground();
  assert.equal(values.get('voiceForeground'), false);
  ability.onForeground();
  ability.onDestroy();
  assert.equal(values.get('voiceForeground'), false);
  assert.deepEqual(changes.filter(([key]) => key === 'voiceForeground').map(([, value]) => value),
    [false, true, false, true, false]);
});
