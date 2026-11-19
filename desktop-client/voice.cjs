const { spawn } = require('node:child_process');
const { readFile } = require('node:fs/promises');
const path = require('node:path');
const { createInterface } = require('node:readline');

const phases = new Set(['listening', 'phrase', 'complete', 'unavailable', 'microphone', 'failed']);
const endPhases = new Set(['complete', 'unavailable', 'microphone', 'failed']);

function createVoiceCapture(scriptPath) {
  let active;

  async function start(owner, emit) {
    if (process.platform !== 'win32' || !process.env.SystemRoot) return 'unavailable';
    if (active) return 'busy';
    const operation = { owner, cancelled: false };
    active = operation;

    function release() {
      clearTimeout(operation.timer);
      if (active === operation) active = undefined;
    }

    try {
      // The fixed bundled code can run from app.asar and accepts no renderer arguments.
      const source = await readFile(scriptPath, 'utf8');
      if (operation.cancelled) { release(); return 'cancelled'; }
      const script = Buffer.from(source, 'utf16le').toString('base64');
      const powershell = path.join(process.env.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
      const child = spawn(powershell, ['-NoProfile', '-NonInteractive', '-EncodedCommand', script], {
        windowsHide: true, stdio: ['pipe', 'pipe', 'ignore'],
      });
      operation.child = child;
      let ended = false;
      let length = 0;
      const lines = createInterface({ input: child.stdout });
      lines.on('line', line => {
        if (ended || operation.cancelled || line.length > 24032) return;
        let value;
        try { value = JSON.parse(line); } catch { return; }
        if (!value || !phases.has(value.phase)) return;
        let phrase = '';
        if (value.phase === 'phrase' && typeof value.text === 'string') {
          phrase = value.text.slice(0, 4000 - length);
          if (!phrase.trim()) return;
          length += phrase.length;
        } else if (value.phase === 'phrase') return;
        if (endPhases.has(value.phase)) ended = true;
        emit(value.phase, phrase);
      });
      child.stdin.on('error', () => {});
      child.on('error', () => {});
      child.on('close', () => {
        release();
        if (!ended && !operation.cancelled) emit('failed', '');
      });
      operation.timer = setTimeout(() => {
        if (!ended && !operation.cancelled) emit('failed', '');
        operation.cancelled = true;
        child.kill();
      }, 68000);
      return 'started';
    } catch {
      release();
      return operation.cancelled ? 'cancelled' : 'unavailable';
    }
  }

  function stop(owner) {
    if (active?.owner !== owner || active.cancelled || !active.child) return false;
    active.child.stdin.end('stop\n');
    return true;
  }

  function cancel(owner) {
    if (active?.owner !== owner) return false;
    active.cancelled = true;
    active.child?.kill();
    return true;
  }

  return { start, stop, cancel };
}

module.exports = { createVoiceCapture };
