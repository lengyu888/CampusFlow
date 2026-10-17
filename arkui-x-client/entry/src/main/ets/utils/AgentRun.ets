import { RunSnapshot, RunEvent, RunEventsPage, RunStartRequest } from '../model/ApiModels';
import { CampusFlowRequestError, localRequestFailure } from './AgentFeedback';

export interface AgentRunGateway {
  startAgentRun(request: RunStartRequest): Promise<RunSnapshot>;
  agentRun(id: string): Promise<RunSnapshot>;
  agentRunEvents(id: string, afterSeq: number): Promise<RunEventsPage>;
  cancelAgentRun(id: string): Promise<RunSnapshot>;
  recentAgentRuns(limit: number): Promise<RunSnapshot[]>;
}

export interface AgentRunScheduler {
  setTimeout(callback: () => void, delayMs: number): number;
  clearTimeout(id: number): void;
}

class SystemRunScheduler implements AgentRunScheduler {
  setTimeout(callback: () => void, delayMs: number): number { return setTimeout(callback, delayMs); }
  clearTimeout(id: number): void { clearTimeout(id); }
}

export interface AgentRunState {
  phase: string;
  runId: string;
  request: RunStartRequest | null;
  snapshot: RunSnapshot | null;
  events: RunEvent[];
  recent: RunSnapshot[];
  message: string;
  errorCode: string;
  listMessage: string;
  listLoading: boolean;
  lastAppliedSeq: number;
  canRetryStart: boolean;
}

function blankState(): AgentRunState {
  return { phase: 'idle', runId: '', request: null, snapshot: null, events: [], recent: [], message: '', errorCode: '',
    listMessage: '', listLoading: false, lastAppliedSeq: 0, canRetryStart: false };
}

function text(value: string): boolean { return typeof value === 'string' && value.trim().length > 0; }
function nullableText(value: string | null): boolean { return value === null || typeof value === 'string'; }
function stamp(value: string): boolean { return text(value) && Number.isFinite(Date.parse(value)); }
function count(value: number): boolean { return Number.isSafeInteger(value) && value >= 0; }
function uuid(value: string): boolean { return typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value); }

export function isRunTerminal(status: string): boolean {
  return ['succeeded', 'failed', 'cancelled', 'timed_out', 'budget_exceeded', 'interrupted'].includes(status);
}

export function validRunSnapshot(value: RunSnapshot): boolean {
  if (value === null || typeof value !== 'object' || Array.isArray(value) || !uuid(value.run_id) || !text(value.session_id) ||
    !text(value.model) || typeof value.message !== 'string' || !stamp(value.created_at) || !stamp(value.updated_at) ||
    !['queued', 'running', 'succeeded', 'failed', 'cancelled', 'timed_out', 'budget_exceeded', 'interrupted'].includes(value.status) ||
    !count(value.seq) || !count(value.model_calls) || !count(value.tool_calls) || typeof value.partial_answer !== 'string' ||
    !nullableText(value.error_code) || !nullableText(value.error_message) || !Array.isArray(value.tool_progress)) { return false; }
  const calls: string[] = [];
  for (const tool of value.tool_progress) {
    if (tool === null || typeof tool !== 'object' || Array.isArray(tool) || !text(tool.call_id) || calls.includes(tool.call_id) ||
      !text(tool.tool_name) || !text(tool.label) || !['running', 'success', 'error'].includes(tool.state) ||
      typeof tool.summary !== 'string') { return false; }
    calls.push(tool.call_id);
  }
  if (value.status !== 'succeeded') { return value.result === null; }
  const result = value.result;
  return result !== null && typeof result === 'object' && !Array.isArray(result) && result.session_id === value.session_id &&
    typeof result.message === 'string' && Array.isArray(result.pending_actions) &&
    (result.tool_traces === undefined || Array.isArray(result.tool_traces));
}

function validEvent(value: RunEvent, snapshotSeq: number): boolean {
  if (value === null || typeof value !== 'object' || Array.isArray(value) || !count(value.seq) || value.seq < 1 ||
    value.seq > snapshotSeq || !text(value.kind) || !stamp(value.at) || value.data === null ||
    typeof value.data !== 'object' || Array.isArray(value.data)) { return false; }
  const data = value.data;
  return (data.text === undefined || typeof data.text === 'string') &&
    (data.call_id === undefined || typeof data.call_id === 'string') &&
    (data.tool_name === undefined || typeof data.tool_name === 'string') &&
    (data.label === undefined || typeof data.label === 'string') &&
    (data.state === undefined || typeof data.state === 'string') &&
    (data.summary === undefined || typeof data.summary === 'string') &&
    (data.count === undefined || count(data.count)) && (data.status === undefined || typeof data.status === 'string');
}

// The current snapshot owns the answer. Events provide observed progress only: they are
// never concatenated into the answer, so replay, resets and page gaps cannot duplicate it.
export class AgentRunController {
  private api: AgentRunGateway;
  private onChange: (state: AgentRunState) => void;
  private onSucceeded: (run: RunSnapshot) => void;
  private makeRunId: () => string;
  private scheduler: AgentRunScheduler;
  private scope: string = '';
  private active: boolean = true;
  private disposed: boolean = false;
  private revision: number = 0;
  private listRevision: number = 0;
  private timer: number = -1;
  private inFlight: boolean = false;
  private failures: number = 0;
  private notified: string[] = [];
  private state: AgentRunState = blankState();

  constructor(api: AgentRunGateway, onChange: (state: AgentRunState) => void,
    onSucceeded: (run: RunSnapshot) => void, makeRunId: () => string,
    scheduler: AgentRunScheduler = new SystemRunScheduler()) {
    this.api = api; this.onChange = onChange; this.onSucceeded = onSucceeded;
    this.makeRunId = makeRunId; this.scheduler = scheduler;
  }

  snapshot(): AgentRunState { return JSON.parse(JSON.stringify(this.state)) as AgentRunState; }
  private publish(): void { if (!this.disposed) { this.onChange(this.snapshot()); } }
  private current(revision: number): boolean { return !this.disposed && this.active && revision === this.revision; }
  private available(): boolean { return !this.disposed && this.active && this.scope.length > 0; }
  private stopTimer(): void { if (this.timer >= 0) { this.scheduler.clearTimeout(this.timer); this.timer = -1; } }

  configure(scope: string, api: AgentRunGateway): void {
    if (this.disposed) { return; }
    this.api = api;
    if (scope === this.scope) { return; }
    this.stopTimer(); this.revision++; this.listRevision++; this.inFlight = false; this.failures = 0;
    this.scope = scope; this.notified = []; this.state = blankState(); this.publish();
  }

  blocksNewRun(): boolean {
    return ['creating', 'checking', 'cancelling'].includes(this.state.phase) || (this.state.runId.length > 0 && this.state.phase !== 'error' &&
      (this.state.snapshot === null || !isRunTerminal(this.state.snapshot.status)));
  }

  setActive(active: boolean): void {
    if (this.disposed || this.active === active) { return; }
    this.active = active; this.stopTimer(); this.revision++; this.listRevision++; this.inFlight = false;
    this.state.listLoading = false;
    if (!active) {
      if (this.state.phase !== 'error' && this.state.runId.length > 0 && (this.state.snapshot === null || !isRunTerminal(this.state.snapshot.status))) {
        this.state.phase = 'unknown'; this.state.canRetryStart = false;
        this.state.message = '后台运行未自动取消，返回后将核对当前状态。';
      }
      this.publish(); return;
    }
    this.failures = 0;
    if (this.state.phase !== 'error' && this.state.runId.length > 0) { this.refresh(); } else { this.publish(); }
  }

  dispose(): void {
    this.stopTimer(); this.disposed = true; this.active = false; this.revision++; this.listRevision++;
    this.inFlight = false; this.scope = ''; this.notified = []; this.state = blankState();
  }

  private schedule(): void {
    this.stopTimer();
    if (!this.available() || this.state.runId.length === 0 || this.state.phase === 'error' ||
      (this.state.snapshot !== null && isRunTerminal(this.state.snapshot.status)) || this.failures > 3) { return; }
    const revision = this.revision;
    const delay = this.failures === 0 ? 1000 : Math.min(8000, 1000 * Math.pow(2, this.failures));
    this.timer = this.scheduler.setTimeout(() => {
      this.timer = -1;
      if (!this.current(revision)) { return; }
      if (this.state.phase === 'unknown' || this.state.snapshot === null) { this.refresh(); }
      else { this.pollEvents(); }
    }, delay);
  }

  private failure(error: Error): string {
    if (error instanceof CampusFlowRequestError) {
      if (error.code === 'RUN_DELETED') { return '这次运行所属的会话已删除，不会重新执行或恢复已删除内容。'; }
      if (error.code === 'RUN_NOT_FOUND') { return '未找到服务器保留的这次运行，请刷新运行记录核对；不会自动另建任务。'; }
      if (error.code === 'RUN_SESSION_BUSY') { return '这个会话还有运行中的任务，请从运行记录中恢复或等待它结束。'; }
      if (error.code === 'RUN_ID_REUSED') { return '运行标识对应另一份请求，已停止提交。请核对服务器运行记录。'; }
      if (error.statusCode === 401 || error.statusCode === 403) { return '当前账号或权限不可用，请重新登录同一账号后核对运行记录。'; }
      if (error.statusCode === 404 || error.statusCode === 405) { return '服务暂不支持运行恢复，或记录已不可用。请核对服务版本；不会退回旧对话接口重发。'; }
    }
    return '连接中断或返回内容无法核验，已有片段仍保留。请查询同一次运行，勿另建重复请求。';
  }

  private failedRead(error: Error): void {
    this.failures++;
    this.state.errorCode = error instanceof CampusFlowRequestError ? error.code : '';
    const deleted = this.state.errorCode === 'RUN_DELETED';
    this.state.phase = deleted ? 'error' : 'unknown';
    this.state.canRetryStart = !deleted && this.state.snapshot === null && this.state.request !== null;
    this.state.message = this.failure(error) + (this.failures > 3 ? ' 自动查询已暂停，可手动重试查询。' : '');
    this.publish();
  }

  private accept(value: RunSnapshot, expectedId: string): void {
    if (!validRunSnapshot(value) || value.run_id !== expectedId) { throw new Error('invalid run snapshot'); }
    const request = this.state.request;
    if (request !== null && (value.model !== request.model || value.message !== request.message ||
      (request.session_id.length > 0 && value.session_id !== request.session_id))) { throw new Error('request mismatch'); }
    const previous = this.state.snapshot;
    if (previous !== null && (value.session_id !== previous.session_id || value.model !== previous.model ||
      value.message !== previous.message || value.created_at !== previous.created_at)) { throw new Error('identity mismatch'); }
    if (previous !== null && value.seq < previous.seq) { throw new Error('outdated run snapshot'); }
    if (previous !== null && isRunTerminal(previous.status) && value.status !== previous.status) { throw new Error('terminal regression'); }
    const revision = this.revision;
    this.state.snapshot = JSON.parse(JSON.stringify(value)) as RunSnapshot;
    this.state.lastAppliedSeq = value.seq;
    this.state.phase = isRunTerminal(value.status) ? 'terminal' : 'running';
    this.state.errorCode = '';
    this.state.canRetryStart = false; this.failures = 0;
    this.state.message = value.status === 'succeeded' ? '本次运行已完成，结果来自服务器。' :
      value.status === 'cancelled' ? '服务器已确认取消；已有片段保留为未完成内容。' :
      value.status === 'queued' ? '服务器已接收，正在等待执行。' :
      value.status === 'running' ? '正在执行；可离开页面，返回后继续核对。' :
      '本次运行已结束但未完成。已有片段保留，请查看运行状态后决定下一步。';
    if (isRunTerminal(value.status) && value.status !== 'succeeded' && value.error_code !== null &&
      ['RUN_TIMEOUT', 'RUN_BUDGET_EXCEEDED', 'RUN_INTERRUPTED', 'RUN_CANCELLED', 'RUN_FAILED',
        'MODEL_AUTH_INVALID', 'MODEL_KEY_REQUIRED', 'MODEL_UNAVAILABLE', 'MODEL_RATE_LIMITED',
        'MODEL_REQUEST_REJECTED', 'REQUEST_TIMEOUT'].includes(value.error_code)) {
      this.state.errorCode = value.error_code;
      this.state.message = localRequestFailure(value.error_code).message;
    }
    this.publish();
    if (this.current(revision) && value.status === 'succeeded' && !this.notified.includes(value.run_id)) {
      this.notified.push(value.run_id);
      try { this.onSucceeded(JSON.parse(JSON.stringify(value)) as RunSnapshot); }
      catch { /* UI/cache errors must never turn a confirmed successful run into a failed run. */ }
    }
  }

  async start(sessionId: string, model: string, message: string): Promise<void> {
    if (!this.available() || this.inFlight || this.blocksNewRun()) { return; }
    if (!text(sessionId) || Array.from(sessionId).length > 128 || !text(model) || !text(message) || Array.from(message).length > 8000) {
      this.state.message = '请检查会话、模型与输入内容：会话标识应为 1–128 字，消息应为 1–8000 字。'; this.publish(); return;
    }
    let id = '';
    try { id = this.makeRunId().toLowerCase(); } catch { id = ''; }
    if (!uuid(id)) { this.state.message = '未能生成有效运行标识，本次未发送。'; this.publish(); return; }
    this.stopTimer(); this.revision++; this.failures = 0;
    const recent = this.state.recent;
    this.state = blankState(); this.state.recent = recent;
    this.state.runId = id; this.state.request = { run_id: id, session_id: sessionId, model: model, message: message };
    await this.submit();
  }

  // Only an explicit user action can repeat the identical idempotent POST.
  async retryStart(): Promise<void> {
    if (!this.available() || this.inFlight || !this.state.canRetryStart || this.state.request === null || this.state.snapshot !== null) { return; }
    this.stopTimer(); this.revision++; this.failures = 0;
    await this.submit();
  }

  private async submit(): Promise<void> {
    const request = this.state.request;
    if (request === null) { return; }
    const frozen = JSON.parse(JSON.stringify(request)) as RunStartRequest;
    const revision = this.revision;
    this.inFlight = true; this.state.phase = 'creating'; this.state.canRetryStart = false;
    this.state.errorCode = '';
    this.state.message = '正在提交这次运行…'; this.publish();
    try {
      const snapshot = await this.api.startAgentRun(frozen);
      if (!this.current(revision)) { return; }
      this.accept(snapshot, frozen.run_id);
    } catch (error) {
      if (!this.current(revision)) { return; }
      if (error instanceof CampusFlowRequestError && error.code !== 'INVALID_RESPONSE' &&
        (['RUN_SESSION_BUSY', 'RUN_ID_REUSED', 'RUN_INVALID', 'RUN_DELETED', 'MODEL_KEY_REQUIRED', 'MODEL_NOT_FOUND', 'MODEL_CAPABILITY_UNSUPPORTED',
          'MODEL_PROVIDER_KEY_REQUIRED', 'MODEL_CONFIG_INVALID', 'LOGIN_REQUIRED',
          'RUN_LIMIT', 'RUN_WORKER_BUSY'].includes(error.code) || [401, 403, 422].includes(error.statusCode))) {
        this.state.phase = 'error'; this.state.canRetryStart = false; this.state.errorCode = error.code;
        this.state.message = error.code === 'RUN_DELETED' ? this.failure(error) : error.message; this.publish();
      } else { this.failedRead(error); }
    } finally {
      if (this.current(revision)) { this.inFlight = false; this.schedule(); }
    }
  }

  async recover(runId: string): Promise<void> {
    if (!this.available() || ['creating', 'cancelling'].includes(this.state.phase) || !uuid(runId)) { return; }
    if (this.state.runId === runId) { await this.refresh(); return; }
    // Switching records is read-only. The server continues any other run independently.
    this.stopTimer(); this.revision++; this.inFlight = false; this.failures = 0;
    const recent = this.state.recent;
    this.state = blankState(); this.state.recent = recent; this.state.runId = runId;
    await this.refresh();
  }

  async refresh(): Promise<void> {
    if (!this.available() || this.inFlight || this.state.runId.length === 0) { return; }
    this.stopTimer(); const revision = this.revision; const id = this.state.runId;
    this.inFlight = true; this.state.phase = 'checking'; this.state.canRetryStart = false;
    this.state.message = '正在核对服务器运行状态…'; this.publish();
    try {
      const snapshot = await this.api.agentRun(id);
      if (!this.current(revision)) { return; }
      this.accept(snapshot, id);
    } catch (error) {
      if (this.current(revision)) { this.failedRead(error); }
    } finally {
      if (this.current(revision)) { this.inFlight = false; this.schedule(); }
    }
  }

  private async pollEvents(): Promise<void> {
    if (!this.available() || this.inFlight || this.state.runId.length === 0) { return; }
    const revision = this.revision; const id = this.state.runId; const cursor = this.state.lastAppliedSeq;
    this.inFlight = true;
    try {
      const page = await this.api.agentRunEvents(id, cursor);
      if (!this.current(revision)) { return; }
      if (page === null || typeof page !== 'object' || page.run_id !== id || !validRunSnapshot(page.snapshot)) {
        throw new Error('invalid events page');
      }
      const events: RunEvent[] = [];
      let ordered = Array.isArray(page.events) && page.events.length <= 200;
      let last = cursor;
      if (ordered) {
        for (const event of page.events) {
          if (!validEvent(event, page.snapshot.seq) || event.seq <= last) { ordered = false; break; }
          events.push(event); last = event.seq;
        }
      }
      // A malformed or replayed event list cannot corrupt the atomically captured answer.
      // Even a valid 200-event page may end before snapshot.seq; the full snapshot covers that gap.
      this.accept(page.snapshot, id);
      if (!this.current(revision)) { return; }
      this.state.events = ordered ? JSON.parse(JSON.stringify(events)) as RunEvent[] : [];
      if (!ordered) { this.state.message = '已核对完整回答快照；部分进度事件无法核验，未据此拼接内容。'; }
      this.publish();
    } catch (error) {
      if (this.current(revision)) { this.failedRead(error); }
    } finally {
      if (this.current(revision)) { this.inFlight = false; this.schedule(); }
    }
  }

  async cancel(): Promise<void> {
    const snapshot = this.state.snapshot;
    if (!this.available() || this.state.phase === 'cancelling' || snapshot === null || isRunTerminal(snapshot.status)) { return; }
    // Cancellation may supersede an outstanding progress GET; a slow read must not delay stopping work.
    this.stopTimer(); const revision = ++this.revision; const id = this.state.runId;
    this.inFlight = true; this.state.phase = 'cancelling'; this.state.canRetryStart = false;
    this.state.message = '正在请求取消，等待服务器确认；此时还不能保证已停止。'; this.publish();
    try {
      const result = await this.api.cancelAgentRun(id);
      if (!this.current(revision)) { return; }
      this.accept(result, id);
      if (!this.current(revision)) { return; }
      if (!isRunTerminal(result.status)) {
        this.state.message = '服务器尚未确认结束，正在继续核对。'; this.publish();
      }
    } catch (error) {
      if (this.current(revision)) { this.failedRead(error); }
    } finally {
      if (this.current(revision)) { this.inFlight = false; this.schedule(); }
    }
  }

  async loadRecent(): Promise<void> {
    if (!this.available() || this.state.listLoading) { return; }
    const revision = ++this.listRevision; const scope = this.scope;
    this.state.listLoading = true; this.state.listMessage = '正在读取服务器近期运行记录…'; this.publish();
    try {
      const runs = await this.api.recentAgentRuns(20);
      if (!this.available() || revision !== this.listRevision || scope !== this.scope) { return; }
      if (!Array.isArray(runs) || runs.length > 50 || !runs.every((run: RunSnapshot) => validRunSnapshot(run)) ||
        new Set<string>(runs.map((run: RunSnapshot) => run.run_id)).size !== runs.length) { throw new Error('invalid run list'); }
      this.state.recent = JSON.parse(JSON.stringify(runs)) as RunSnapshot[];
      this.state.listMessage = runs.length === 0 ? '服务器近期没有保留的运行记录。' : '服务器运行记录 · 可打开核对，未在本机另存请求正文。';
    } catch (error) {
      if (this.available() && revision === this.listRevision && scope === this.scope) {
        this.state.listMessage = this.failure(error) + ' 运行列表暂未更新。';
      }
    } finally {
      if (this.available() && revision === this.listRevision && scope === this.scope) { this.state.listLoading = false; this.publish(); }
    }
  }
}
