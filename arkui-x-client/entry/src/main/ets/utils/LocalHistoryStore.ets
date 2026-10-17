import { HistoryMessage, SessionSummary } from '../model/ApiModels';

export const MAX_LOCAL_HISTORY_BYTES: number = 2 * 1024 * 1024;
export const MAX_LOCAL_HISTORY_SESSIONS: number = 20;

export interface LocalHistoryDriver {
  read(): Promise<string | undefined>;
  write(text: string): Promise<void>;
  remove(): Promise<void>;
}

export interface LocalHistoryInfo {
  scope: string;
  displayName: string;
  count: number;
}

interface LocalSession {
  summary: SessionSummary;
  messages: HistoryMessage[];
}

interface LocalHistoryDocument {
  version: number;
  scope: string;
  displayName: string;
  sessions: LocalSession[];
  tombstones: string[];
}

export function historyScope(baseUrl: string, userId: string): string {
  const base = baseUrl.trim().replace(/\/+$/, '');
  if (base.length === 0 || userId.trim().length === 0) {
    return '';
  }
  // Encode a tuple: neither separators inside a URL nor user IDs can collide.
  return JSON.stringify([base, userId]);
}

function emptyDocument(scope: string = '', displayName: string = ''): LocalHistoryDocument {
  return { version: 1, scope: scope, displayName: displayName, sessions: [], tombstones: [] };
}

function validDate(value: string): boolean {
  return typeof value === 'string' && value.length > 0 && Number.isFinite(Date.parse(value));
}

function cleanSummary(value: SessionSummary): SessionSummary | undefined {
  if (value === null || typeof value !== 'object' || Array.isArray(value) ||
    typeof value.session_id !== 'string' || value.session_id.length === 0 || value.session_id.length > 512 ||
    typeof value.title !== 'string' || typeof value.model_name !== 'string' ||
    typeof value.last_message !== 'string' || !Number.isInteger(value.message_count) || value.message_count < 0 ||
    !validDate(value.created_at) || !validDate(value.updated_at)) {
    return undefined;
  }
  return { session_id: value.session_id, title: value.title, model_name: value.model_name,
    last_message: value.last_message, message_count: value.message_count,
    created_at: value.created_at, updated_at: value.updated_at };
}

function cleanMessages(values: HistoryMessage[]): HistoryMessage[] | undefined {
  if (!Array.isArray(values)) {
    return undefined;
  }
  const messages: HistoryMessage[] = [];
  for (const value of values) {
    if (value === null || typeof value !== 'object' || Array.isArray(value) ||
      (value.role !== 'user' && value.role !== 'assistant') || typeof value.content !== 'string' ||
      !validDate(value.created_at)) {
      return undefined;
    }
    // Do not serialize tokens, raw tools, proposals or arbitrary response properties.
    messages.push({ role: value.role, content: value.content, created_at: value.created_at });
  }
  return messages;
}

function cleanSession(summary: SessionSummary, messages: HistoryMessage[]): LocalSession | undefined {
  const safeSummary = cleanSummary(summary);
  const safeMessages = cleanMessages(messages);
  if (safeSummary === undefined || safeMessages === undefined) {
    return undefined;
  }
  safeSummary.message_count = safeMessages.length;
  if (safeMessages.length > 0) {
    safeSummary.last_message = safeMessages[safeMessages.length - 1].content;
    safeSummary.updated_at = safeMessages[safeMessages.length - 1].created_at;
  }
  return { summary: safeSummary, messages: safeMessages };
}

function withinBudget(document: LocalHistoryDocument): boolean {
  // Three bytes per UTF-16 unit conservatively bounds UTF-8, including Chinese.
  return JSON.stringify(document).length * 3 <= MAX_LOCAL_HISTORY_BYTES;
}

function readDocument(text: string): LocalHistoryDocument {
  if (text.length * 3 > MAX_LOCAL_HISTORY_BYTES) {
    throw new Error('本机会话文件超过容量限制，未覆盖原文件。');
  }
  let value: LocalHistoryDocument;
  try {
    value = JSON.parse(text) as LocalHistoryDocument;
  } catch {
    throw new Error('本机会话文件无法读取，未覆盖原文件。');
  }
  if (value === null || typeof value !== 'object' || Array.isArray(value) || value.version !== 1 ||
    typeof value.scope !== 'string' || typeof value.displayName !== 'string' ||
    !Array.isArray(value.sessions) || value.sessions.length > MAX_LOCAL_HISTORY_SESSIONS ||
    !Array.isArray(value.tombstones) ||
    (value.scope.length === 0 && (value.sessions.length > 0 || value.tombstones.length > 0))) {
    throw new Error('本机会话格式或版本不兼容，未覆盖原文件。');
  }
  const document = emptyDocument(value.scope, value.displayName);
  for (const id of value.tombstones) {
    if (typeof id !== 'string' || id.length === 0 || id.length > 512 || document.tombstones.includes(id)) {
      throw new Error('本机会话删除记录不完整，未覆盖原文件。');
    }
    document.tombstones.push(id);
  }
  for (const item of value.sessions) {
    if (item === null || typeof item !== 'object' || Array.isArray(item)) {
      throw new Error('本机会话内容不完整，未覆盖原文件。');
    }
    const session = cleanSession(item.summary, item.messages);
    if (session === undefined || document.sessions.some((saved: LocalSession) =>
      saved.summary.session_id === session.summary.session_id)) {
      throw new Error('本机会话内容不完整，未覆盖原文件。');
    }
    if (!document.tombstones.includes(session.summary.session_id)) {
      document.sessions.push(session);
    }
  }
  return document;
}

export class LocalHistoryStore {
  private driver: LocalHistoryDriver;
  private document: LocalHistoryDocument = emptyDocument();
  private initialized: boolean = false;
  private initialization: Promise<void> | undefined = undefined;
  private visible: boolean = false;
  private revision: number = 0;
  private accountEpoch: number = 0;
  private removedIds: string[] = [];
  private pendingTombstones: string[] = [];
  private queueTail: Promise<void> = Promise.resolve();

  constructor(driver: LocalHistoryDriver) {
    this.driver = driver;
  }

  private enqueue<T>(operation: () => Promise<T>): Promise<T> {
    const result = this.queueTail.then(operation);
    this.queueTail = result.then(() => {}, () => {});
    return result;
  }

  initialize(): Promise<void> {
    if (this.initialization !== undefined) {
      return this.initialization;
    }
    const revision = this.revision;
    this.initialization = this.enqueue(async () => {
      const text = await this.driver.read();
      this.document = text === undefined ? emptyDocument() : readDocument(text);
      this.initialized = true;
      this.visible = revision === this.revision;
    });
    return this.initialization;
  }

  private requireInitialized(): void {
    if (!this.initialized) {
      throw new Error('本机会话存储尚未就绪，未覆盖已有文件。');
    }
  }

  epoch(): number {
    return this.accountEpoch;
  }

  activate(scope: string, displayName: string): Promise<void> {
    this.accountEpoch++;
    const revision = ++this.revision;
    this.visible = false;
    this.removedIds = [];
    this.pendingTombstones = [];
    return this.enqueue(async () => {
      this.requireInitialized();
      if (scope.length === 0 || typeof displayName !== 'string') {
        throw new Error('本机会话缺少账号范围。');
      }
      if (revision !== this.revision) {
        return;
      }
      const next: LocalHistoryDocument = scope === this.document.scope ?
        { version: 1, scope: scope, displayName: displayName, sessions: this.document.sessions,
          tombstones: this.document.tombstones } :
        emptyDocument(scope, displayName);
      if (!withinBudget(next)) {
        throw new Error('本机会话信息超过容量限制。');
      }
      try {
        await this.driver.write(JSON.stringify(next));
      } catch {
        if (scope !== this.document.scope) {
          // Account switching must not leave the previous account available at
          // the next cold start when replacing its cache failed.
          try {
            await this.driver.remove();
            this.document = emptyDocument();
          } catch {
            throw new Error('本机旧账号记录清理失败，请在系统应用设置中清除应用数据。');
          }
        }
        throw new Error('本机会话存储启用失败，本次未保存新记录。');
      }
      this.document = next;
      if (revision === this.revision) {
        this.visible = true;
      }
    });
  }

  info(): LocalHistoryInfo {
    if (!this.initialized || !this.visible) {
      return { scope: '', displayName: '', count: 0 };
    }
    return { scope: this.document.scope, displayName: this.document.displayName,
      count: this.document.sessions.filter((item: LocalSession) =>
        !this.removedIds.includes(item.summary.session_id)).length };
  }

  list(scope: string): SessionSummary[] {
    if (scope.length === 0 || scope !== this.info().scope) {
      return [];
    }
    return this.document.sessions.filter((item: LocalSession) =>
      !this.removedIds.includes(item.summary.session_id)).map((item: LocalSession) =>
      cleanSummary(item.summary) as SessionSummary);
  }

  messages(scope: string, sessionId: string): HistoryMessage[] | undefined {
    if (scope.length === 0 || scope !== this.info().scope || this.isRemoved(scope, sessionId)) {
      return undefined;
    }
    const item = this.document.sessions.find((session: LocalSession) => session.summary.session_id === sessionId);
    return item === undefined ? undefined : cleanMessages(item.messages);
  }

  isRemoved(scope: string, sessionId: string): boolean {
    return scope.length > 0 && scope === this.info().scope &&
      (this.removedIds.includes(sessionId) || this.document.tombstones.includes(sessionId));
  }

  save(scope: string, summary: SessionSummary, messages: HistoryMessage[]): Promise<boolean> {
    const revision = this.revision;
    // Copy and validate before queueing: caller mutations must not enter the snapshot.
    const session = cleanSession(summary, messages);
    if (session === undefined || scope.length === 0 || scope !== this.info().scope ||
      this.isRemoved(scope, session.summary.session_id)) {
      return Promise.resolve(false);
    }
    return this.enqueue(async () => {
      if (revision !== this.revision || scope !== this.info().scope ||
        this.isRemoved(scope, session.summary.session_id)) {
        return false;
      }
      const previous = this.document.sessions.find((item: LocalSession) =>
        item.summary.session_id === session.summary.session_id);
      if (previous !== undefined && previous.messages.length > session.messages.length &&
        Date.parse(previous.summary.updated_at) >= Date.parse(session.summary.updated_at)) {
        return false;
      }
      const next = emptyDocument(scope, this.document.displayName);
      next.tombstones = this.document.tombstones.slice();
      for (const id of this.pendingTombstones) {
        if (!next.tombstones.includes(id)) {
          next.tombstones.push(id);
        }
      }
      // Never truncate a conversation to fit the budget. Evict whole older sessions.
      next.sessions = [session];
      if (!withinBudget(next)) {
        return false;
      }
      const others = this.document.sessions.filter((item: LocalSession) =>
        item.summary.session_id !== session.summary.session_id && !this.removedIds.includes(item.summary.session_id));
      const candidates = others.concat([session]);
      candidates.sort((left: LocalSession, right: LocalSession) =>
        Date.parse(right.summary.updated_at) - Date.parse(left.summary.updated_at));
      next.sessions = [];
      for (const item of candidates) {
        if (next.sessions.length >= MAX_LOCAL_HISTORY_SESSIONS) {
          break;
        }
        next.sessions.push(item);
        if (!withinBudget(next)) {
          next.sessions.pop();
        }
      }
      if (!next.sessions.some((item: LocalSession) => item.summary.session_id === session.summary.session_id)) {
        return false;
      }
      try {
        await this.driver.write(JSON.stringify(next));
      } catch {
        return false;
      }
      // Keep the serialized state accurate for the next queued operation, even if
      // a clear/activation has already hidden this scope from every reader.
      this.document = next;
      return revision === this.revision;
    });
  }

  removeSession(scope: string, sessionId: string, deletedRemotely: boolean = true): Promise<void> {
    if (scope.length === 0 || scope !== this.info().scope) {
      return Promise.resolve();
    }
    if (sessionId.length === 0 || sessionId.length > 512) {
      return Promise.reject(new Error('会话标识无效，未修改本机记录。'));
    }
    // A late history response must not resurrect a just-deleted conversation.
    this.removedIds = this.removedIds.concat([sessionId]);
    if (deletedRemotely) {
      this.pendingTombstones = this.pendingTombstones.concat([sessionId]);
    }
    const removedIds = this.removedIds.slice();
    const tombstones = this.pendingTombstones.slice();
    const revision = ++this.revision;
    return this.enqueue(async () => {
      if (scope !== this.document.scope) {
        return;
      }
      const next = emptyDocument(scope, this.document.displayName);
      next.tombstones = this.document.tombstones.slice();
      for (const id of tombstones) {
        if (!next.tombstones.includes(id)) {
          next.tombstones.push(id);
        }
      }
      next.sessions = this.document.sessions.filter((item: LocalSession) =>
        !next.tombstones.includes(item.summary.session_id) && !removedIds.includes(item.summary.session_id));
      while (!withinBudget(next) && next.sessions.length > 0) {
        next.sessions.pop();
      }
      if (!withinBudget(next)) {
        throw new Error('本机删除记录已达到容量上限，请清除本机会话后重试。');
      }
      await this.driver.write(JSON.stringify(next));
      this.document = next;
      if (revision === this.revision) {
        this.removedIds = [];
        this.pendingTombstones = [];
      }
    });
  }

  clear(): Promise<void> {
    this.accountEpoch++;
    const revision = ++this.revision;
    this.visible = false;
    this.removedIds = [];
    this.pendingTombstones = [];
    return this.enqueue(async () => {
      // Explicit clearing is allowed even after corrupt-file initialization failed.
      await this.driver.remove();
      this.document = emptyDocument();
      this.initialized = true;
      this.initialization = Promise.resolve();
      this.visible = revision === this.revision;
    });
  }
}
