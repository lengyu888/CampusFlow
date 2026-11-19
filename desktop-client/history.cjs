const { mkdir, readFile, rename, rm, stat, writeFile } = require('node:fs/promises');
const path = require('node:path');
const { createHash, randomUUID } = require('node:crypto');

const maxSessions = 20;
const maxBytes = 1024 * 1024;
const maxMessages = 160;
const maxMessageChars = 24000;

function isHistoryId(value) {
  return typeof value === 'string' && value.trim().length > 0 && value.length <= 128 && !/[\x00-\x1f\x7f]/.test(value);
}

function text(value, limit) { return typeof value === 'string' ? value.slice(0, limit) : ''; }

function evidenceUrl(value) {
  if (typeof value !== 'string' || value.length > 2048) return null;
  try {
    const parsed = new URL(value);
    return ['http:', 'https:'].includes(parsed.protocol) && !parsed.username && !parsed.password ? parsed.href : null;
  } catch { return null; }
}

function toolDisplay(tool) {
  if (!tool || typeof tool !== 'object') return null;
  return {
    label: text(tool.label, 160), state: text(tool.state, 32), summary: text(tool.summary, 2000),
    evidence: (Array.isArray(tool.evidence) ? tool.evidence : []).slice(0, 12).filter(item => item && typeof item === 'object').map(item => ({
      source_id: text(item.source_id, 160), label: text(item.label, 160), kind: text(item.kind, 32), status: text(item.status, 32),
      updated_at: text(item.updated_at, 80) || null, expires_at: text(item.expires_at, 80) || null,
      url: evidenceUrl(item.url), note: text(item.note, 1500),
    })),
  };
}

function prepareHistorySession(input, now = () => new Date().toISOString()) {
  if (!input || !isHistoryId(input.sessionId) || !Array.isArray(input.messages) || input.messages.length === 0 || input.messages.length > maxMessages) {
    return null;
  }
  const messages = [];
  for (const item of input.messages) {
    if (!item || !['user', 'assistant'].includes(item.role) || typeof item.content !== 'string' || item.content.length > maxMessageChars) return null;
    const data = { role: item.role, content: item.content, created_at: text(item.created_at, 80) || null };
    if (item.role === 'assistant' && Array.isArray(item.tools)) data.tools = item.tools.slice(0, 24).map(toolDisplay).filter(Boolean);
    messages.push(data);
  }
  const result = { sessionId: input.sessionId, title: text(input.title, 120).trim() || '历史会话', updatedAt: now(), messages };
  return Buffer.byteLength(JSON.stringify(result), 'utf8') <= maxBytes / 2 ? result : null;
}

function createOfflineHistory(directory, encryption) {
  const jobs = new Map();
  const cachePath = (origin) => path.join(directory, `${createHash('sha256').update(origin).digest('hex')}.bin`);

  function enqueue(origin, run) {
    const next = (jobs.get(origin) ?? Promise.resolve()).catch(() => {}).then(() => run(cachePath(origin)));
    jobs.set(origin, next);
    const release = () => { if (jobs.get(origin) === next) jobs.delete(origin); };
    next.then(release, release);
    return next;
  }

  async function read(file) {
    if (!encryption.available()) return null;
    try {
      if ((await stat(file)).size > maxBytes * 2) return null;
      const value = JSON.parse(encryption.decrypt(await readFile(file)));
      if (value.version !== 1 || !isHistoryId(value.owner) || !Array.isArray(value.sessions) || value.sessions.length > maxSessions) return null;
      const sessions = value.sessions.map((item) => prepareHistorySession(item, () => text(item.updatedAt, 80)));
      return sessions.every(Boolean) ? { ...value, sessions } : null;
    } catch { return null; }
  }

  async function write(file, owner, sessions) {
    if (!encryption.available()) return false;
    const pending = `${file}.${randomUUID()}.tmp`;
    const data = { version: 1, owner, sessions: sessions.slice(0, maxSessions) };
    while (Buffer.byteLength(JSON.stringify(data), 'utf8') > maxBytes) data.sessions.pop();
    await mkdir(directory, { recursive: true });
    try {
      await writeFile(pending, encryption.encrypt(JSON.stringify(data)));
      await rename(pending, file);
    } finally { await rm(pending, { force: true }); }
    return true;
  }

  return {
    useOwner(origin, owner) {
      return enqueue(origin, async (file) => {
        if (!encryption.available()) return false;
        const previous = await read(file);
        if (previous?.owner === owner) return true;
        await rm(file, { force: true });
        return write(file, owner, []);
      });
    },
    list(origin, owner) {
      return enqueue(origin, async (file) => {
        const cache = await read(file);
        if (!cache?.sessions.length || (owner && owner !== cache.owner)) return null;
        return { owner: cache.owner, sessions: cache.sessions.map(({ sessionId, title, updatedAt }) => ({ sessionId, title, updatedAt })) };
      });
    },
    get(origin, owner, sessionId) {
      return enqueue(origin, async (file) => {
        const cache = await read(file);
        if (cache?.owner !== owner) return null;
        return cache.sessions.find((item) => item.sessionId === sessionId) ?? null;
      });
    },
    save(origin, owner, session) {
      return enqueue(origin, async (file) => {
        const next = prepareHistorySession(session);
        const cache = await read(file);
        if (!next || cache?.owner !== owner) return false;
        return write(file, owner, [next, ...cache.sessions.filter((item) => item.sessionId !== next.sessionId)]);
      });
    },
    delete(origin, owner, sessionId) {
      return enqueue(origin, async (file) => {
        const cache = await read(file);
        if (cache?.owner !== owner) return false;
        return write(file, owner, cache.sessions.filter((item) => item.sessionId !== sessionId));
      });
    },
    clear(origin) { return enqueue(origin, (file) => rm(file, { force: true })); },
  };
}

module.exports = { createOfflineHistory, isHistoryId, prepareHistorySession };
