(() => {
  const native = window.campusFlowDesktop;
  if (document.documentElement.dataset.platform !== 'windows' || !native?.voiceStart) return;
  const input = document.getElementById('messageInput');
  const submit = document.getElementById('sendButton');
  const session = document.getElementById('sessionId');
  const app = document.getElementById('appView');
  const agent = document.querySelector('[data-app-surface="agent"]');
  const trigger = document.createElement('button');
  trigger.type = 'button';
  trigger.className = 'desktop-voice-trigger';
  trigger.setAttribute('aria-haspopup', 'dialog');
  trigger.textContent = '语音输入';
  submit.before(trigger);

  const dialog = document.createElement('dialog');
  dialog.className = 'windows-voice-dialog';
  dialog.setAttribute('aria-labelledby', 'windowsVoiceTitle');
  dialog.innerHTML = `
    <h2 id="windowsVoiceTitle">语音输入</h2>
    <p class="windows-voice-status" role="status"></p>
    <textarea rows="4" maxlength="4000" aria-label="识别文字" hidden></textarea>
    <div class="windows-voice-actions">
      <button type="button" class="line-button" data-voice="close">关闭</button>
      <button type="button" class="line-button" data-voice="typing" hidden>返回输入框</button>
      <button type="button" class="primary-action" data-voice="start">开始录音</button>
      <button type="button" class="primary-action" data-voice="stop" hidden>结束录音</button>
      <button type="button" class="primary-action" data-voice="use" hidden>加入草稿</button>
    </div>`;
  agent.append(dialog);
  const status = dialog.querySelector('[role="status"]');
  const transcript = dialog.querySelector('textarea');
  const close = dialog.querySelector('[data-voice="close"]');
  const typing = dialog.querySelector('[data-voice="typing"]');
  const start = dialog.querySelector('[data-voice="start"]');
  const stop = dialog.querySelector('[data-voice="stop"]');
  const use = dialog.querySelector('[data-voice="use"]');
  const failureMessages = {
    unavailable: '未找到可用的 Windows 听写语音包。可以返回输入框按 Win + H，或继续打字。',
    microphone: 'Windows 无法使用默认麦克风。请检查麦克风连接和系统权限，或继续打字。',
    failed: '听写未完成。可以重新录音、使用系统听写，或继续打字。',
    busy: '上次录音正在结束，请稍后重试。',
  };
  let phase = 'idle';
  let operation = 0;
  let dialogSession = '';

  function show(next, message) {
    phase = next;
    status.textContent = message;
    const capturing = ['starting', 'listening', 'stopping'].includes(next);
    close.textContent = capturing ? '取消录音' : '关闭';
    typing.hidden = next !== 'error';
    start.hidden = capturing || next === 'review';
    start.textContent = next === 'error' ? '重新录音' : '开始录音';
    stop.hidden = !['listening', 'stopping'].includes(next);
    stop.disabled = next === 'stopping';
    transcript.hidden = !['listening', 'stopping', 'review'].includes(next);
    transcript.readOnly = next !== 'review';
    use.hidden = next !== 'review';
    use.disabled = !transcript.value.trim();
  }

  function finishWithoutResult(code) {
    const message = failureMessages[code] ?? failureMessages.failed;
    if (transcript.value.trim()) show('review', '录音已停止。可以核对并使用已识别的部分。');
    else show('error', message);
  }

  trigger.addEventListener('click', () => {
    transcript.value = '';
    dialogSession = session.textContent;
    show('idle', 'Windows 在本机识别语音。录音最长 60 秒，文字可编辑后加入草稿。');
    dialog.showModal();
    start.focus();
  });
  start.addEventListener('click', async () => {
    window.speechSynthesis?.cancel();
    transcript.value = '';
    const id = ++operation;
    show('starting', '正在准备麦克风…');
    close.focus();
    const result = await native.voiceStart(id).catch(() => 'failed');
    if (dialog.open && operation === id && phase === 'starting' && result !== 'started') finishWithoutResult(result);
  });
  stop.addEventListener('click', async () => {
    const id = operation;
    show('stopping', '正在整理识别文字…');
    const stopped = await native.voiceStop().catch(() => false);
    if (!stopped && dialog.open && operation === id && phase === 'stopping') finishWithoutResult('failed');
  });
  native.onVoiceEvent(({ operation: id, phase: event, text }) => {
    if (!dialog.open || operation !== id || !['starting', 'listening', 'stopping'].includes(phase)) return;
    if (event === 'listening') show('listening', '正在聆听。说完后选择「结束录音」。');
    else if (event === 'phrase') {
      const separator = /[a-z0-9]$/i.test(transcript.value) && /^[a-z0-9]/i.test(text) ? ' ' : '';
      transcript.value = `${transcript.value}${separator}${text}`.slice(0, 4000);
    } else if (event === 'complete' && transcript.value.trim()) {
      show('review', '核对识别文字，再加入当前草稿。');
      transcript.focus();
    } else if (event === 'complete') show('error', '暂未识别到语音。请靠近麦克风重新录音。');
    else finishWithoutResult(event);
  });

  function closeVoice() {
    if (!dialog.open) return;
    if (['starting', 'listening', 'stopping'].includes(phase)) void native.voiceCancel().catch(() => {});
    ++operation;
    transcript.value = '';
    show('idle', '');
    dialog.close();
  }

  function syncContext() {
    trigger.disabled = input.disabled;
    if (dialog.open && (app.hidden || agent.hidden || input.disabled || session.textContent !== dialogSession)) closeVoice();
  }

  close.addEventListener('click', closeVoice);
  typing.addEventListener('click', () => { closeVoice(); input.focus(); });
  dialog.addEventListener('cancel', event => { event.preventDefault(); closeVoice(); });
  transcript.addEventListener('input', () => { use.disabled = !transcript.value.trim(); });
  use.addEventListener('click', () => {
    const text = transcript.value.trim();
    if (!text || input.disabled || input.closest('[hidden]') || session.textContent !== dialogSession) return;
    const existing = input.value;
    const result = existing ? `${existing}\n${text}` : text;
    if (result.length > input.maxLength) {
      status.textContent = '草稿过长。请缩短识别文字，再加入草稿。';
      return;
    }
    input.value = result;
    input.dispatchEvent(new Event('input', { bubbles: true }));
    closeVoice();
    input.focus();
  });
  const observer = new MutationObserver(syncContext);
  for (const element of [input, app, agent]) observer.observe(element, { attributes: true, attributeFilter: ['disabled', 'hidden'] });
  observer.observe(session, { childList: true });
  document.addEventListener('visibilitychange', () => { if (document.hidden) closeVoice(); });
  window.addEventListener('blur', () => {
    if (['starting', 'listening', 'stopping'].includes(phase)) closeVoice();
  });
})();
