// The vault returns only a candidate. A live /me check must establish the account
// before any saved token is published to authenticated pages.
export interface SavedSession {
  schemaVersion: number;
  baseUrl: string;
  userId: string;
  accessToken: string;
  savedAt: number;
}

export interface SavedSessionPort {
  read(): Promise<SavedSession | null>;
  save(record: SavedSession): Promise<void>;
  clear(): Promise<void>;
}

export const MAX_SAVED_SESSION_BYTES: number = 1024;

export interface SessionVaultDriver {
  read(): Promise<string | null>;
  write(value: string): Promise<void>;
  remove(): Promise<void>;
}

export interface SessionBarrierDriver {
  readEnabled(): Promise<boolean>;
  writeEnabled(enabled: boolean): Promise<void>;
}

export class SessionSourceChangedError extends Error {
  constructor() { super('服务地址已变化，本次未登录。请核对后重试。'); }
}

export class SessionStorageError extends Error {
  code: string;
  constructor(code: string = 'SESSION_UNAVAILABLE') {
    super(code === 'SESSION_UNSUPPORTED' ? '当前设备暂不支持安全保持登录。' :
      (code === 'SESSION_INVALID' ? '保存的登录信息无法核对，请重新登录。' :
      (code === 'SESSION_REMOVAL_PENDING' ? '已停止保持登录，安全存储清理尚未完成。' :
      (code === 'SESSION_SAVE_FAILED' ? '本次未能保持登录，下次请重新登录。' : '安全登录存储暂不可用，请重试。'))));
    this.code = code;
  }
}

function validIpv6(host: string): boolean {
  const value = host.substring(1, host.length - 1);
  if (!/^[0-9a-f:]+$/i.test(value) || !value.includes(':') || value.includes(':::')) { return false; }
  const sides = value.split('::');
  if (sides.length > 2) { return false; }
  const groups = sides.join(':').split(':').filter((part: string) => part.length > 0);
  if (groups.some((part: string) => part.length > 4)) { return false; }
  return sides.length === 2 ? groups.length < 8 : groups.length === 8 && !value.startsWith(':') && !value.endsWith(':');
}

export function normalizeServiceBaseUrl(value: string): string | null {
  if (typeof value !== 'string' || value.length > 1024) { return null; }
  const input = value.trim();
  // Credentials, query strings, fragments, escapes and ambiguous path traversal
  // are never part of a service base. No token may be retargeted by URL parsing.
  if (/[\s\\%@?#]/.test(input)) { return null; }
  const match = /^(https?):\/\/(\[[0-9a-f:]+\]|[a-z0-9.-]+)(?::([0-9]{1,5}))?(\/[a-z0-9._~/-]*)?$/i.exec(input);
  if (match === null) { return null; }
  const scheme = match[1].toLowerCase(); const host = match[2].toLowerCase();
  if (host.startsWith('[')) {
    if (!validIpv6(host)) { return null; }
  } else {
    const labels = host.split('.');
    if (host.length > 253 || labels.some((part: string) => !/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(part))) { return null; }
    if (labels.every((part: string) => /^[0-9]+$/.test(part))) {
      if (labels.length !== 4 || labels.some((part: string) => Number(part) > 255 || part.length > 1 && part.startsWith('0'))) { return null; }
    } else if (labels.length === 1 && /^0x[0-9a-f]+$/.test(host)) { return null; }
  }
  const port = match[3] === undefined ? null : Number(match[3]);
  if (port !== null && (port < 1 || port > 65535)) { return null; }
  const path = (match[4] ?? '').replace(/\/+$/, '');
  if (path.includes('//') || path.split('/').some((part: string) => part === '.' || part === '..')) { return null; }
  const suffix = port === null || scheme === 'http' && port === 80 || scheme === 'https' && port === 443 ? '' : `:${port}`;
  return `${scheme}://${host}${suffix}${path}`;
}

export function parseSavedSession(raw: string): SavedSession | null {
  if (typeof raw !== 'string' || raw.length === 0 || raw.length > MAX_SAVED_SESSION_BYTES || /[^\x20-\x7e]/.test(raw)) { return null; }
  try {
    const value = JSON.parse(raw) as SavedSession;
    if (value === null || typeof value !== 'object' || Array.isArray(value) ||
      Object.keys(value).sort().join(',') !== 'accessToken,baseUrl,savedAt,schemaVersion,userId' || value.schemaVersion !== 1 ||
      typeof value.baseUrl !== 'string' || normalizeServiceBaseUrl(value.baseUrl) !== value.baseUrl ||
      typeof value.userId !== 'string' || !/^[a-zA-Z0-9_-]{1,128}$/.test(value.userId) ||
      typeof value.accessToken !== 'string' || !/^[-a-zA-Z0-9._~+/]{16,768}={0,2}$/.test(value.accessToken) ||
      !Number.isSafeInteger(value.savedAt) || value.savedAt <= 0) { return null; }
    return { schemaVersion: 1, baseUrl: value.baseUrl, userId: value.userId, accessToken: value.accessToken, savedAt: value.savedAt };
  } catch { return null; }
}

export class SessionPersistence implements SavedSessionPort {
  private vault: SessionVaultDriver;
  private barrier: SessionBarrierDriver;
  private tail: Promise<void> = Promise.resolve();
  private generation: number = 0;
  private blocked: boolean = false;

  constructor(vault: SessionVaultDriver, barrier: SessionBarrierDriver) { this.vault = vault; this.barrier = barrier; }

  private enqueue<T>(work: () => Promise<T>): Promise<T> {
    const next = this.tail.then(work);
    this.tail = next.then(() => {}, () => {});
    return next;
  }

  async read(): Promise<SavedSession | null> {
    const revision = this.generation;
    return this.enqueue(async () => {
      if (revision !== this.generation) { return null; }
      if (this.blocked) { throw new SessionStorageError(); }
      try {
        if (!await this.barrier.readEnabled()) { return null; }
        const raw = await this.vault.read();
        if (revision !== this.generation || this.blocked) { return null; }
        if (raw === null) { return null; }
        const value = parseSavedSession(raw);
        if (value === null) { throw new SessionStorageError('SESSION_INVALID'); }
        return value;
      } catch (error) {
        if (error instanceof SessionStorageError) { throw error; }
        throw new SessionStorageError();
      }
    });
  }

  async save(record: SavedSession): Promise<void> {
    const value = parseSavedSession(JSON.stringify(record));
    if (value === null) { throw new SessionStorageError('SESSION_INVALID'); }
    const revision = ++this.generation;
    return this.enqueue(async () => {
      if (revision !== this.generation) { throw new SessionStorageError('SESSION_STALE'); }
      this.blocked = true;
      let disabled = false;
      try {
        // A crash or failure during replacement must not restore the old account.
        await this.barrier.writeEnabled(false);
        disabled = true;
        await this.vault.write(JSON.stringify(value));
        if (revision !== this.generation) { throw new SessionStorageError('SESSION_STALE'); }
        await this.barrier.writeEnabled(true);
        if (revision !== this.generation) { throw new SessionStorageError('SESSION_STALE'); }
        this.blocked = false;
      } catch (error) {
        if (error instanceof SessionStorageError && error.code === 'SESSION_STALE') { throw error; }
        if (!disabled) { throw new SessionStorageError(); }
        if (revision === this.generation) { this.blocked = false; }
        if (error instanceof SessionStorageError && error.code === 'SESSION_UNSUPPORTED') { throw error; }
        throw new SessionStorageError('SESSION_SAVE_FAILED');
      }
    });
  }

  async clear(): Promise<void> {
    const revision = ++this.generation;
    this.blocked = true;
    return this.enqueue(async () => {
      let disabled = false;
      try {
        // Only a non-secret boolean is stored outside Asset. Keep disabled even
        // when secure removal fails, so the next cold start cannot revive it.
        await this.barrier.writeEnabled(false);
        disabled = true;
        await this.vault.remove();
        if (revision === this.generation) { this.blocked = false; }
      } catch (error) {
        if (!disabled) { throw new SessionStorageError(); }
        if (revision === this.generation) { this.blocked = false; }
        // Unsupported platforms have never persisted an Asset in this app.
        if (error instanceof SessionStorageError && error.code === 'SESSION_UNSUPPORTED') { return; }
        throw new SessionStorageError('SESSION_REMOVAL_PENDING');
      }
    });
  }
}
