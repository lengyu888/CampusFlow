import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';

// Exercise the production state machine with a fake clock/driver. This is not native SDK acceptance.
const source = readFileSync(new URL('../entry/src/main/ets/utils/VoiceInteraction.ets', import.meta.url), 'utf8');
const { VoiceInteraction, VoiceInteractionError, speechText } = await import(
  `data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source)).toString('base64')}`);

class FakeClock {
  time = 0;
  next = 0;
  jobs = new Map();
  setTimeout(callback, delay) {
    const id = ++this.next;
    this.jobs.set(id, { callback, at: this.time + delay });
    return id;
  }
  clearTimeout(id) { this.jobs.delete(id); }
  advance(ms) {
    const target = this.time + ms;
    while (true) {
      const next = [...this.jobs].sort((a, b) => a[1].at - b[1].at).find((entry) => entry[1].at <= target);
      if (!next) break;
      this.jobs.delete(next[0]);
      this.time = next[1].at;
      next[1].callback();
    }
    this.time = target;
  }
}

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

function fixture(capabilities = { recognition: true, synthesis: true }) {
  const clock = new FakeClock();
  const states = [];
  const driver = {
    recognition: [], speech: [], finished: [], cancelled: [], stopped: 0, disposed: 0,
    recognitionStart: undefined, speechStart: undefined,
    capabilities: () => capabilities,
    startListening(id, events) {
      this.recognition.push({ id, events });
      return this.recognitionStart ? this.recognitionStart(id, events) : Promise.resolve();
    },
    finishListening(id) { this.finished.push(id); },
    cancelListening(id) { this.cancelled.push(id); },
    speak(id, text, events) {
      this.speech.push({ id, text, events });
      return this.speechStart ? this.speechStart(id, text, events) : Promise.resolve();
    },
    stopSpeaking() { this.stopped++; },
    dispose() { this.disposed++; }
  };
  const controller = new VoiceInteraction(driver, (state) => states.push(state), clock);
  return { controller, driver, clock, states, state: () => states.at(-1),
    recognition: () => driver.recognition.at(-1).events,
    speech: () => driver.speech.at(-1).events };
}

async function review(f, text) {
  await f.controller.startListening();
  f.recognition().onStart();
  f.recognition().onResult(text);
  f.recognition().onComplete();
}

test('recognition is reviewed and explicitly consumed; partial results replace accumulated text', async () => {
  const f = fixture();
  assert.equal(f.state().phase, 'idle');
  await f.controller.startListening();
  assert.equal(f.state().phase, 'starting');
  assert.equal(f.controller.takeTranscript(), '');
  f.recognition().onStart();
  f.recognition().onResult('安排');
  f.recognition().onResult('安排明天复习');
  assert.equal(f.state().phase, 'listening');
  assert.equal(f.state().transcript, '安排明天复习');
  f.controller.finishListening();
  f.controller.finishListening();
  assert.equal(f.state().phase, 'recognizing');
  assert.equal(f.driver.finished.length, 1);
  f.recognition().onResult('安排明天复习操作系统');
  f.recognition().onComplete();
  assert.equal(f.state().phase, 'review');
  assert.equal(f.clock.jobs.size, 0);
  f.controller.editTranscript('  安排后天复习操作系统  ');
  assert.equal(f.controller.takeTranscript(), '安排后天复习操作系统');
  assert.equal(f.state().phase, 'idle');
  assert.equal(f.state().transcript, '');
  assert.equal(f.controller.takeTranscript(), '');
  assert.equal(f.driver.speech.length, 0, 'recognition never auto-starts another operation');
});

test('double start is one native request, and pending permission cancellation invalidates late callbacks', async () => {
  const f = fixture();
  const start = deferred();
  f.driver.recognitionStart = () => start.promise;
  const pending = f.controller.startListening();
  await f.controller.startListening();
  assert.equal(f.driver.recognition.length, 1);
  const old = f.recognition();
  f.controller.cancel();
  const afterCancel = f.states.length;
  old.onStart(); old.onResult('不该进入输入框'); old.onComplete(); old.onError('旧错误');
  assert.equal(f.states.length, afterCancel);
  start.resolve();
  await pending;
  assert.equal(f.state().phase, 'idle');
  assert.deepEqual(f.driver.cancelled, [f.driver.recognition[0].id, f.driver.recognition[0].id],
    'cancel is asserted again by old ID after delayed permission settles');
  assert.equal(f.clock.jobs.size, 0);
});

test('old recognition cannot overwrite a newer operation or a completed editable review', async () => {
  const f = fixture();
  await f.controller.startListening();
  const old = f.recognition();
  f.controller.cancel();
  await f.controller.startListening();
  assert.notEqual(f.driver.recognition[0].id, f.driver.recognition[1].id);
  old.onStart(); old.onResult('旧文字'); old.onComplete(); old.onError('旧错误');
  assert.equal(f.state().phase, 'starting');
  f.recognition().onStart(); f.recognition().onResult('新文字'); f.recognition().onComplete();
  f.controller.editTranscript('已编辑');
  f.recognition().onResult('迟到的最终结果'); f.recognition().onError('迟到错误');
  assert.equal(f.state().phase, 'review');
  assert.equal(f.state().transcript, '已编辑');
});

test('preparation timeout includes permission wait and explicit retry creates a fresh session', async () => {
  const f = fixture();
  const start = deferred();
  f.driver.recognitionStart = () => start.promise;
  const pending = f.controller.startListening();
  f.clock.advance(29999);
  assert.equal(f.state().phase, 'starting');
  f.clock.advance(1);
  assert.equal(f.state().phase, 'error');
  assert.match(f.state().message, /准备超时.*权限/);
  f.driver.recognitionStart = undefined;
  await f.controller.startListening();
  f.recognition().onStart();
  start.resolve(); await pending;
  assert.equal(f.state().phase, 'listening');
  assert.equal(f.driver.cancelled.at(-1), f.driver.recognition[0].id);
  f.controller.cancel();
});

test('60-second recording limit finishes once; final-result timeout preserves partial text', async () => {
  const f = fixture();
  await f.controller.startListening(); f.recognition().onStart(); f.recognition().onResult('已听到的内容');
  f.clock.advance(60000);
  assert.equal(f.state().phase, 'recognizing');
  assert.equal(f.driver.finished.length, 1);
  f.clock.advance(15000);
  assert.equal(f.state().phase, 'review');
  assert.equal(f.state().transcript, '已听到的内容');
  assert.match(f.state().message, /超时.*仅为已识别/);
  assert.equal(f.clock.jobs.size, 0);
});

test('empty completion, result timeout and native failures are distinguishable, with no thrown diagnostic leak', async () => {
  const f = fixture();
  await review(f, '   ');
  assert.equal(f.state().phase, 'error');
  assert.match(f.state().message, /没有识别到文字/);
  await f.controller.startListening(); f.recognition().onStart(); f.controller.finishListening();
  f.clock.advance(15000);
  assert.equal(f.state().phase, 'error');
  assert.match(f.state().message, /等待识别结果超时/);
  await f.controller.startListening();
  f.recognition().onError('麦克风权限未获允许。');
  assert.match(f.state().message, /麦克风权限/);
  f.driver.recognitionStart = () => Promise.reject(new Error('private native diagnostics'));
  await f.controller.startListening();
  assert.match(f.state().message, /启动失败/);
  assert.doesNotMatch(f.state().message, /private/);
});

test('partial failure is an explicit review, and recognition can be deliberately restarted', async () => {
  const f = fixture();
  await f.controller.startListening(); f.recognition().onStart(); f.recognition().onResult('部分文字');
  f.recognition().onError('识别中断。');
  assert.equal(f.state().phase, 'review');
  assert.equal(f.state().transcript, '部分文字');
  assert.match(f.state().message, /仅为已识别/);
  await f.controller.startListening();
  assert.equal(f.state().phase, 'starting');
  assert.equal(f.state().transcript, '');
  f.controller.finishListening();
  assert.equal(f.state().phase, 'idle', 'finish during preparation cancels permission wait');
});

test('only typed, deliberately user-facing startup/finish errors retain their message', async () => {
  for (const operation of ['start', 'finish', 'speak']) {
    for (const safe of [true, false]) {
      const f = fixture();
      const message = safe ? '麦克风权限未获允许，请到系统设置中开启。' : 'private native diagnostic';
      const error = safe ? new VoiceInteractionError(message) : new Error(message);
      if (safe) {
        assert.ok(error instanceof Error);
        assert.equal(error.name, 'VoiceInteractionError');
      }
      if (operation === 'start') {
        f.driver.recognitionStart = () => Promise.reject(error);
        await f.controller.startListening();
      } else if (operation === 'speak') {
        f.driver.speechStart = () => Promise.reject(error);
        await f.controller.speak('a', '正文');
      } else {
        await f.controller.startListening(); f.recognition().onStart();
        f.driver.finishListening = () => { throw error; };
        f.controller.finishListening();
      }
      assert.equal(f.state().phase, 'error');
      if (safe) assert.equal(f.state().message, message);
      else assert.doesNotMatch(f.state().message, /private|diagnostic/);
      assert.equal(f.clock.jobs.size, 0);
    }
  }
  const f = fixture();
  f.driver.recognitionStart = () => Promise.reject({ name: 'VoiceInteractionError', message: 'raw object diagnostic' });
  await f.controller.startListening();
  assert.doesNotMatch(f.state().message, /raw object/);
  f.driver.recognitionStart = () => Promise.reject(new VoiceInteractionError('   '));
  await f.controller.startListening();
  assert.match(f.state().message, /启动失败/);
});

test('suspending active recognition preserves accumulated text for review and ignores late final results', async () => {
  for (const phase of ['starting', 'listening', 'recognizing']) {
    const f = fixture();
    await f.controller.startListening();
    if (phase !== 'starting') f.recognition().onStart();
    f.recognition().onResult('  回页后继续编辑😀  ');
    if (phase === 'recognizing') f.controller.finishListening();
    assert.equal(f.state().phase, phase);
    const old = f.recognition();
    f.controller.suspend();
    assert.equal(f.state().phase, 'review');
    assert.equal(f.state().transcript, '  回页后继续编辑😀  ');
    assert.match(f.state().message, /录音已停止.*保留/);
    assert.equal(f.driver.cancelled.length, 1);
    assert.equal(f.clock.jobs.size, 0);
    old.onResult('迟到结果'); old.onError('迟到错误'); old.onComplete(); old.onStart();
    assert.equal(f.state().transcript, '  回页后继续编辑😀  ');
    f.controller.editTranscript('回到页面后的修改');
    assert.equal(f.controller.takeTranscript(), '回到页面后的修改');
  }
});

test('suspension keeps completed/edited review including empty and over-limit content', async () => {
  const f = fixture();
  await review(f, '最初内容');
  for (const text of ['新的编辑内容', '', '😀'.repeat(8001)]) {
    f.controller.editTranscript(text);
    const before = { ...f.state() };
    f.controller.suspend();
    assert.deepEqual(f.state(), before);
    assert.equal(f.driver.cancelled.length, 0, 'completed recognition is already released');
  }
  assert.equal(f.controller.takeTranscript(), '');
  assert.match(f.state().message, /8000/);
  f.controller.dispose();
  const count = f.states.length;
  f.controller.suspend();
  assert.equal(f.states.length, count);
  assert.equal(f.controller.takeTranscript(), '');
});

test('suspension without recognised text cancels permission wait and stops preparing/playing speech', async () => {
  const f = fixture();
  const start = deferred();
  f.driver.recognitionStart = () => start.promise;
  const pending = f.controller.startListening();
  const old = f.recognition();
  f.controller.suspend();
  assert.equal(f.state().phase, 'idle');
  old.onStart(); old.onResult('后台迟到文字'); old.onComplete();
  start.resolve(); await pending;
  assert.equal(f.state().phase, 'idle');
  assert.equal(f.state().transcript, '');
  assert.equal(f.clock.jobs.size, 0);
  for (const phase of ['preparingSpeech', 'speaking']) {
    await f.controller.speak(phase, '回答');
    const events = f.speech();
    if (phase === 'speaking') events.onStart();
    f.controller.suspend();
    assert.equal(f.state().phase, 'idle');
    assert.equal(f.state().speakingMessageId, '');
    events.onStart(); events.onComplete(); events.onError('旧朗读错误');
    assert.equal(f.state().phase, 'idle');
    assert.equal(f.clock.jobs.size, 0);
  }
  assert.equal(f.driver.stopped, 2);
});

test('over-limit recognition is retained whole; Unicode code points count once and edits can recover', async () => {
  const f = fixture();
  const oversized = '😀'.repeat(8001);
  await review(f, oversized);
  assert.equal(f.state().transcript, oversized);
  assert.match(f.state().message, /8000/);
  assert.equal(f.controller.takeTranscript(), '');
  assert.equal(f.state().phase, 'review');
  assert.equal(f.state().transcript, oversized);
  const boundary = '😀'.repeat(8000);
  f.controller.editTranscript(boundary);
  assert.equal(f.controller.takeTranscript(), boundary);
  await review(f, '内容');
  f.controller.editTranscript('  ');
  assert.equal(f.controller.takeTranscript(), '');
  assert.equal(f.state().phase, 'review');
  assert.match(f.state().message, /先填写/);
});

test('speaking cannot discard active recognition or text awaiting review', async () => {
  const f = fixture();
  await f.controller.startListening();
  await f.controller.speak('reply', '一个回答');
  assert.equal(f.state().phase, 'starting');
  assert.equal(f.driver.speech.length, 0);
  f.recognition().onStart(); f.recognition().onResult('我的草稿'); f.recognition().onComplete();
  await f.controller.speak('reply', '一个回答');
  assert.equal(f.state().phase, 'review');
  assert.equal(f.state().transcript, '我的草稿');
  assert.equal(f.driver.speech.length, 0);
  assert.match(f.state().message, /先使用或取消/);
});

test('speech remains preparing after driver promise resolves and completes only on playback callback', async () => {
  const f = fixture();
  await f.controller.speak('reply-1', '**复习**操作系统');
  assert.equal(f.driver.speech[0].text, '复习操作系统');
  assert.equal(f.state().phase, 'preparingSpeech');
  assert.equal(f.state().speakingMessageId, 'reply-1');
  await f.controller.speak('reply-1', '不要重复启动');
  assert.equal(f.driver.speech.length, 1);
  f.speech().onStart();
  f.clock.advance(60000);
  assert.equal(f.state().phase, 'speaking', 'playback is not incorrectly limited to 30 or 60 seconds');
  f.speech().onComplete();
  assert.equal(f.state().phase, 'idle');
  assert.equal(f.state().speakingMessageId, '');
  assert.equal(f.clock.jobs.size, 0);
});

test('stop/replacement invalidates old speech callbacks; switching to recognition stops speech first', async () => {
  const f = fixture();
  await f.controller.speak('a', '第一条'); const old = f.speech(); old.onStart();
  await f.controller.speak('b', '第二条');
  assert.equal(f.driver.stopped, 1);
  old.onComplete(); old.onError('旧错误'); old.onStart();
  assert.equal(f.state().speakingMessageId, 'b');
  assert.equal(f.state().phase, 'preparingSpeech');
  const second = f.speech();
  await f.controller.startListening();
  assert.equal(f.driver.stopped, 2);
  second.onStart(); second.onComplete();
  assert.equal(f.state().phase, 'starting');
  f.controller.cancel();
});

test('delayed speech startup after cancellation cannot revive UI or stop a newer playback', async () => {
  const f = fixture();
  const start = deferred();
  f.driver.speechStart = () => start.promise;
  const pending = f.controller.speak('old', '旧回答'); const old = f.speech();
  f.controller.cancel();
  f.driver.speechStart = undefined;
  await f.controller.speak('new', '新回答'); f.speech().onStart();
  start.resolve(); await pending;
  old.onStart(); old.onComplete(); old.onError('迟到错误');
  assert.equal(f.state().phase, 'speaking');
  assert.equal(f.state().speakingMessageId, 'new');
  assert.equal(f.driver.stopped, 1, 'the native driver must guard its own async startup by operation ID');
  f.controller.cancel();
});

test('speech has separate initialization and generous playback watchdogs with explicit failure', async () => {
  const f = fixture();
  await f.controller.speak('first', '准备超时示例');
  f.clock.advance(30000);
  assert.equal(f.state().phase, 'error');
  assert.match(f.state().message, /准备超时/);
  await f.controller.speak('second', '长回答'); f.speech().onStart();
  f.clock.advance(15 * 60 * 1000);
  assert.equal(f.state().phase, 'error');
  assert.match(f.state().message, /时间过长.*已停止/);
  assert.equal(f.driver.stopped, 2);
  assert.equal(f.clock.jobs.size, 0);
});

test('unsupported capabilities, empty spoken text and speech errors have explicit fallbacks', async () => {
  const unsupported = fixture({ recognition: false, synthesis: false });
  await unsupported.controller.startListening();
  assert.match(unsupported.state().message, /不支持语音输入/);
  await unsupported.controller.speak('a', '回答');
  assert.match(unsupported.state().message, /不支持朗读/);
  assert.equal(unsupported.driver.recognition.length + unsupported.driver.speech.length, 0);
  const f = fixture();
  await f.controller.speak('a', '```js\nconst x = 1;\n``` https://example.invalid');
  assert.match(f.state().message, /没有可朗读/);
  assert.equal(f.driver.speech.length, 0);
  f.driver.speechStart = () => Promise.reject(new Error('private synthesis diagnostic'));
  await f.controller.speak('b', '正文');
  assert.match(f.state().message, /启动失败/);
  assert.doesNotMatch(f.state().message, /private/);
  f.driver.speechStart = undefined;
  await f.controller.speak('c', '正文'); f.speech().onError('朗读引擎不可用。');
  assert.match(f.state().message, /引擎不可用/);
});

test('dispose during permission wait and playback is idempotent and permanently silences callbacks/timers', async () => {
  for (const mode of ['recognition', 'speech']) {
    const f = fixture(); const start = deferred();
    let pending;
    let events;
    if (mode === 'recognition') {
      f.driver.recognitionStart = () => start.promise;
      pending = f.controller.startListening(); events = f.recognition();
    } else {
      f.driver.speechStart = () => start.promise;
      pending = f.controller.speak('a', '回答'); events = f.speech(); events.onStart();
    }
    const count = f.states.length;
    f.controller.dispose(); f.controller.dispose();
    events.onStart(); events.onComplete(); events.onError('迟到错误');
    if (mode === 'recognition') events.onResult('迟到文字');
    start.resolve(); await pending;
    f.clock.advance(60 * 60 * 1000);
    await f.controller.startListening(); await f.controller.speak('b', '新请求');
    f.controller.editTranscript('编辑'); f.controller.cancel();
    assert.equal(f.controller.takeTranscript(), '');
    assert.equal(f.states.length, count);
    assert.equal(f.driver.disposed, 1);
    assert.equal(f.clock.jobs.size, 0);
  }
});

test('published state is a copy and cancellation guards synchronous stop callbacks', async () => {
  const f = fixture();
  await review(f, '保留文字');
  f.state().transcript = '外部篡改';
  assert.equal(f.controller.takeTranscript(), '保留文字');
  await f.controller.startListening();
  f.driver.cancelListening = (id) => {
    f.driver.cancelled.push(id);
    f.recognition().onError('取消时同步回调');
    throw new Error('cleanup diagnostic');
  };
  f.controller.cancel();
  assert.equal(f.state().phase, 'idle');
  assert.equal(f.state().message, '');
});

test('a previously queued stale timeout cannot lose the current operation timer', async () => {
  const f = fixture();
  await f.controller.startListening();
  const staleTimer = [...f.clock.jobs.values()][0].callback;
  f.controller.cancel();
  await f.controller.startListening();
  staleTimer();
  assert.equal(f.state().phase, 'starting');
  f.controller.dispose();
  assert.equal(f.clock.jobs.size, 0, 'the active timer remains tracked and can be cleared');
});

test('a synchronous state subscriber may cancel preparation without starting the native operation', async () => {
  const f = fixture();
  let controller;
  controller = new VoiceInteraction(f.driver, (state) => {
    if (state.phase === 'starting' || state.phase === 'preparingSpeech') controller.cancel();
  }, f.clock);
  await controller.startListening();
  await controller.speak('a', '正文');
  assert.equal(f.driver.recognition.length + f.driver.speech.length, 0);
  assert.equal(f.clock.jobs.size, 0);
  controller.dispose();
});

test('spoken text strips code, images and URL destinations while retaining readable labels and all long prose', () => {
  const text = '# 复习安排\n\n**先读课本**，再做练习。\n- 查看[课表](https://example.invalid/timetable)\n'
    + '![示意图](https://example.invalid/image.png)\n`console.log(secret)`\n'
    + '```ts\nconst token = "secret";\n```\n~~~\n不应朗读代码\n~~~\n'
    + '> 最后回顾错题。\nhttps://example.invalid/path，请稍后查看。\n';
  const result = speechText(text);
  assert.match(result, /复习安排/); assert.match(result, /先读课本，再做练习/);
  assert.match(result, /查看课表/); assert.match(result, /最后回顾错题/); assert.match(result, /请稍后查看/);
  assert.doesNotMatch(result, /secret|console|token|https:|example|不应朗读代码|示意图/);
  const long = '完整中文回答😀'.repeat(2000);
  assert.equal(speechText(long), long, 'no 4000-character or native chunk limit may silently drop answer text');
  assert.equal(speechText('只保留这句\n```没有关闭的代码围栏'), '只保留这句');
});
