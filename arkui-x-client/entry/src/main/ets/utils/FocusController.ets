import { FocusClock, FocusClockSample, FocusGateway, FocusRequest, FocusRecord, FocusOperation, FocusInterval, FocusGap } from '../model/FocusModels';
import { FocusStore, FocusScopeError, FocusLease, FocusDocument, LocalFocusRecord, LocalFocusOperation, FocusLocalState } from './FocusStore';
import { FocusAnchor, FocusTimer, FocusGapReason, validFocusSample, FOCUS_SAMPLE_MS, FOCUS_CHECKPOINT_MS } from './FocusTimer';
import { focusUuid, focusTarget, validFocusRequest, validFocusOperation, validFocusActive, validFocusDetail, validFocusList } from './FocusValidation';
import { CampusFlowRequestError } from './AgentFeedback';

export interface FocusScheduler { setTimeout(callback: () => void, delayMs: number): number; clearTimeout(id: number): void; }
class FocusTimeouts implements FocusScheduler {
  setTimeout(callback: () => void, delayMs: number): number { return setTimeout(callback, delayMs); }
  clearTimeout(id: number): void { clearTimeout(id); }
}
export interface FocusLocalView {
  recordId: string; taskId: string; mode: 'online' | 'offline'; localState: FocusLocalState; elapsedMs: number;
  targetMs: number | null; confirmedElapsedMs: number; unknownGapCount: number; saveState: string;
  canPause: boolean; canResume: boolean; canEnd: boolean;
}
export interface FocusPendingView {
  operationId: string; recordId: string; kind: string; phase: string; message: string; canCheck: boolean; canRetry: boolean;
}
export interface FocusState {
  phase: string; foreground: boolean; clockAvailable: boolean; message: string; errorCode: string;
  selectedRecordId: string; local: FocusLocalView | null; localRecords: FocusLocalView[]; record: FocusRecord | null;
  activeRecord: FocusRecord | null; pendingOperations: FocusPendingView[]; history: FocusRecord[];
  historyLoading: boolean; historyHasMore: boolean; historyError: string;
  intervals: FocusInterval[]; unknownGaps: FocusGap[]; intervalLoading: boolean; intervalError: string;
}
export function emptyFocusState(): FocusState {
  return { phase: 'loading', foreground: false, clockAvailable: false, message: '', errorCode: '', selectedRecordId: '', local: null,
    localRecords: [], record: null, activeRecord: null, pendingOperations: [], history: [], historyLoading: false, historyHasMore: false,
    historyError: '', intervals: [], unknownGaps: [], intervalLoading: false, intervalError: '' };
}
function safeCode(error: Error): string { return error instanceof FocusScopeError ? 'FOCUS_SCOPE_MISMATCH' : error instanceof CampusFlowRequestError ? error.code : ''; }
function definitive(error: Error): boolean {
  return error instanceof CampusFlowRequestError && [400,401,403,404,409,410,422].includes(error.statusCode) && error.code !== 'INVALID_RESPONSE';
}
function copyRequest(request: FocusRequest): FocusRequest { return JSON.parse(JSON.stringify(request)) as FocusRequest; }
export class FocusController {
  private store: FocusStore; private clock: FocusClock; private onChange: (state: FocusState) => void;
  private idFactory: () => string; private scheduler: FocusScheduler; private api: FocusGateway | null = null;
  private lease: FocusLease | null = null; private scope: string = ''; private userId: string = '';
  private activeRevision: number = 0; private generation: number = 0; private activityRevision: number = 0; private detailRevision: number = 0; private historyRevision: number = 0;
  private disposed: boolean = false; private state: FocusState = emptyFocusState(); private localBusy: boolean = false;
  private networkBusy: boolean = false; private sendingId: string = ''; private mutationTail: Promise<void> = Promise.resolve();
  private timer: FocusTimer | null = null; private timerRunning: boolean = false; private timerId: number = -1;
  private lastCheckpoint: number = 0; private saveState: string = 'saved';
  private historyCursor: string = ''; private historyToken: string = '';
  constructor(store: FocusStore, clock: FocusClock, onChange: (state: FocusState) => void, idFactory: () => string,
    scheduler: FocusScheduler = new FocusTimeouts()) {
    this.store = store; this.clock = clock; this.onChange = onChange; this.idFactory = idFactory; this.scheduler = scheduler;
  }
  private valid(generation: number = this.generation): boolean {
    return !this.disposed && generation === this.generation && this.lease !== null && this.store.valid(this.lease) && this.api !== null;
  }
  private document(): FocusDocument {
    if (this.lease === null) { throw new Error('专注存储尚未可用。'); } return this.store.snapshot(this.lease);
  }
  private localRecord(id: string = this.state.selectedRecordId): LocalFocusRecord | undefined {
    return this.valid() ? this.document().records.find((record: LocalFocusRecord) => record.recordId === id) : undefined;
  }
  private uuid(): string { const value = this.idFactory(); if (!focusUuid(value)) { throw new Error('无法生成记录编号。'); } return value; }
  private time(): string { return new Date().toISOString(); } // Event label only; never used for elapsed time.
  private queue(work: () => Promise<void>): Promise<void> {
    const result = this.mutationTail.then(work); this.mutationTail = result.catch(() => {}); return result;
  }
  private async commit(document: FocusDocument, generation: number): Promise<void> {
    if (!this.valid(generation) || this.lease === null) { throw new Error('记录作用域已变化。'); }
    const revision = document.revision; document.revision++;
    await this.store.commit(this.lease, revision, document);
    if (!this.valid(generation)) { throw new Error('记录作用域已变化。'); }
    this.saveState = 'saved';
  }
  private view(record: LocalFocusRecord): FocusLocalView {
    const anchor = this.timer?.snapshot(); const ownTimer = anchor?.recordId === record.recordId;
    const elapsed = record.baseElapsedMs + record.intervals.reduce((sum: number, value: FocusInterval) => sum + value.elapsed_ms, 0) +
      (ownTimer ? anchor?.elapsedMs ?? 0 : record.anchor?.elapsedMs ?? 0);
    const localState = ownTimer && !this.timerRunning ? 'interrupted' : record.localState;
    const pending = this.document().operations.some((operation: LocalFocusOperation) => operation.recordId === record.recordId);
    return { recordId: record.recordId, taskId: record.taskId, mode: record.mode, localState: localState, elapsedMs: elapsed,
      targetMs: record.targetMs, confirmedElapsedMs: record.confirmedElapsedMs, unknownGapCount: record.gaps.length,
      saveState: ownTimer ? this.saveState : 'saved', canPause: !this.localBusy && record.anchor !== null,
      canResume: !this.localBusy && this.state.foreground && localState === 'paused' && (!pending || record.mode === 'offline'),
      canEnd: !this.localBusy && localState !== 'ended' && localState !== 'starting' &&
        (!pending || record.mode === 'offline' || record.anchor !== null) };
  }
  snapshot(): FocusState {
    if (this.valid()) {
      const doc = this.document(); this.state.localRecords = doc.records.map((record: LocalFocusRecord) => this.view(record));
      this.state.local = this.state.localRecords.find((record: FocusLocalView) => record.recordId === this.state.selectedRecordId) ?? null;
      this.state.pendingOperations = doc.operations.map((operation: LocalFocusOperation): FocusPendingView => ({ operationId: operation.request.operation_id,
        recordId: operation.recordId, kind: operation.request.kind, phase: operation.request.operation_id === this.sendingId ? 'sending' : operation.dispatchState,
        message: operation.dispatchState === 'unknown' ? '结果尚待核对，请查询原编号。' : operation.dispatchState === 'not_found' ? '尚未查到原编号，可明确重试原请求。' :
          operation.dispatchState === 'conflict' ? '服务器未接受这笔请求，本机片段仍保留；不能自动改版本同步。' : '本机待同步，尚未声称服务器已记录。',
        canCheck: !this.networkBusy && ['unknown','not_found'].includes(operation.dispatchState),
        canRetry: !this.networkBusy && operation.dispatchState === 'not_found' }));
    }
    return JSON.parse(JSON.stringify(this.state)) as FocusState;
  }
  private publish(): void { if (!this.disposed) { this.onChange(this.snapshot()); } }
  private fail(error: Error, fallback: string): void { this.state.message = fallback; this.state.errorCode = safeCode(error); this.publish(); }
  async configure(scope: string, userId: string, api: FocusGateway): Promise<void> {
    if (this.disposed) { return; }
    if (scope === this.scope && userId === this.userId && this.valid()) { this.api = api; return; }
    this.stopSamples(); this.timer = null; this.generation++; const generation = this.generation;
    this.scope = scope; this.userId = userId; this.api = api; this.lease = null;
    const foreground = this.state.foreground; this.state = emptyFocusState(); this.state.foreground = foreground; this.publish();
    try {
      await this.store.initialize();
      if (this.disposed || generation !== this.generation) { return; }
      const lease = await this.store.activate(scope, this.uuid()); if (this.disposed || generation !== this.generation) { return; }
      this.lease = lease;
      await this.queue(async () => {
        if (!this.valid(generation)) { return; }
        const doc = this.document(); let changed = false;
        for (const record of doc.records) {
          if (record.anchor !== null) {
            this.sealInto(doc, record, new FocusTimer(record.anchor), 'pause', 'process_interrupted'); changed = true;
          } else if (record.localState === 'running' || record.localState === 'starting') { record.localState = 'interrupted'; changed = true; }
        }
        if (changed) { await this.commit(doc, generation); }
      });
      if (!this.valid(generation)) { return; }
      this.state.phase = 'ready'; this.state.selectedRecordId = this.document().records[0]?.recordId ?? ''; this.publish();
      if (this.state.foreground) { await this.readCurrent(); }
    } catch (error) {
      if (generation === this.generation && !this.disposed) {
        this.state.phase = 'error';
        this.fail(error as Error, error instanceof FocusScopeError ?
          '另一账号或服务地址仍有本机记录或待同步操作。请返回原账号处理；也可查看清理提示，自行确认是否清除。原记录已保留，尚未计时。' :
          '本机记录暂时无法读取，尚未计时。请先重试；清理前请确认记录已同步。原文件已保留。');
      }
    }
  }
  setForeground(active: boolean): void {
    if (this.disposed || active === this.state.foreground) { return; }
    this.state.foreground = active; this.activityRevision++;
    if (!active) {
      this.stopSamples();
      if (this.timer !== null) { this.seal('pause', null, null, true).catch(() => {}); }
    } else if (this.valid()) { this.readCurrent().catch(() => {}); }
    this.publish();
  }
  private stopSamples(): void {
    this.timerRunning = false; this.activityRevision++;
    if (this.timerId !== -1) { this.scheduler.clearTimeout(this.timerId); this.timerId = -1; }
  }
  private schedule(): void {
    if (!this.valid() || !this.timerRunning || !this.state.foreground) { return; }
    const activity = this.activityRevision; const generation = this.generation;
    this.timerId = this.scheduler.setTimeout(() => { this.timerId = -1; this.sample(generation, activity).catch(() => {}); }, FOCUS_SAMPLE_MS);
  }
  private async sample(generation: number, activity: number): Promise<void> {
    const timer = this.timer; if (timer === null || !this.timerRunning || !this.valid(generation)) { return; }
    try {
      const sample = await this.clock.sample();
      if (!this.valid(generation) || activity !== this.activityRevision || timer !== this.timer || !this.timerRunning) { return; }
      const result = timer.accept(sample);
      if (!result.accepted) { this.stopSamples(); await this.seal('pause', result.reason as FocusGapReason, validFocusSample(sample) ? sample.wallMs : null, true); return; }
      if (sample.monotonicMs - this.lastCheckpoint >= FOCUS_CHECKPOINT_MS) {
        const anchor = timer.snapshot();
        await this.queue(async () => {
          if (!this.valid(generation) || timer !== this.timer || !this.timerRunning) { return; }
          const doc = this.document(); const record = doc.records.find((value: LocalFocusRecord) => value.recordId === anchor.recordId);
          if (record === undefined || record.anchor === null || record.anchor.segmentId !== anchor.segmentId) { return; }
          record.anchor = anchor; this.saveState = 'pending'; await this.commit(doc, generation); this.lastCheckpoint = anchor.lastAcceptedSample.monotonicMs;
        });
      }
      if (this.valid(generation) && timer === this.timer) { this.publish(); this.schedule(); }
    } catch (error) {
      if (!this.valid(generation) || timer !== this.timer) { return; }
      this.stopSamples(); this.saveState = 'error'; this.state.clockAvailable = false;
      this.fail(error as Error, '计时或本机检查点暂不可用，已停止累计；可证前缀仍保留，请重试暂停或结束保存。');
    }
  }
  private newAnchor(recordId: string, segmentId: string, sample: FocusClockSample): FocusAnchor {
    return { recordId: recordId, segmentId: segmentId, intervalId: this.uuid(), clockSessionId: sample.clockSessionId, sequence: 1,
      firstSample: sample, lastAcceptedSample: sample, elapsedMs: 0 };
  }
  private async settleDormantAnchor(recordId: string, generation: number): Promise<void> {
    if (!this.valid(generation) || this.timer?.snapshot().recordId === recordId) { return; }
    await this.queue(async () => {
      if (!this.valid(generation)) { return; }
      const doc = this.document(); const record = doc.records.find((value: LocalFocusRecord) => value.recordId === recordId);
      if (record?.anchor === null || record === undefined) { return; }
      this.sealInto(doc, record, new FocusTimer(record.anchor), 'pause', 'process_interrupted');
      await this.commit(doc, generation);
    });
  }
  private async beginTimer(recordId: string, generation: number): Promise<void> {
    if (!this.valid(generation) || !this.state.foreground) { return; }
    const activity = this.activityRevision;
    try {
      const sample = await this.clock.sample();
      if (!this.valid(generation) || activity !== this.activityRevision || !this.state.foreground || !validFocusSample(sample)) { return; }
      await this.queue(async () => {
        if (!this.valid(generation) || activity !== this.activityRevision) { return; }
        const doc = this.document(); const record = doc.records.find((value: LocalFocusRecord) => value.recordId === recordId);
        if (record === undefined || record.segmentId === null || record.clockSessionId !== sample.clockSessionId || record.localState !== 'starting') { return; }
        const anchor = this.newAnchor(recordId, record.segmentId, sample); record.anchor = anchor; record.localState = 'running';
        await this.commit(doc, generation);
        if (!this.valid(generation) || activity !== this.activityRevision || !this.state.foreground) { return; }
        this.timer = new FocusTimer(anchor); this.timerRunning = true; this.lastCheckpoint = sample.monotonicMs; this.state.clockAvailable = true; this.schedule();
      });
    } catch (error) { if (this.valid(generation)) { this.fail(error as Error, '服务器已记录开始，但本机时钟暂不能启动；请核对原记录后结束，未补算等待时间。'); } }
    if (this.valid(generation)) { await this.settleDormantAnchor(recordId, generation); }
    this.publish();
  }
  async start(taskId: string, targetMs: number | null, mode: 'online' | 'offline'): Promise<void> {
    if (!this.valid() || !this.state.foreground || this.localBusy || this.networkBusy || !focusTarget(targetMs) ||
      typeof taskId !== 'string' || taskId.trim().length === 0 || taskId.length > 128 || !['online','offline'].includes(mode)) { return; }
    const doc = this.document();
    if (doc.records.some((record: LocalFocusRecord) => record.localState !== 'ended') || doc.operations.length >= 98 || doc.records.length >= 20) {
      this.state.message = '请先处理本机已有记录或待同步操作，再开始新的专注。'; this.publish(); return;
    }
    this.localBusy = true; const generation = this.generation; const activity = this.activityRevision;
    try {
      const sample = await this.clock.sample(); if (!validFocusSample(sample)) { throw new Error('时钟不可用'); }
      if (!this.valid(generation) || activity !== this.activityRevision || !this.state.foreground) { return; }
      const recordId = this.uuid(); const operationId = this.uuid();
      await this.queue(async () => {
        if (!this.valid(generation) || activity !== this.activityRevision) { return; }
        const current = this.document();
        const request: FocusRequest = { operation_id: operationId, kind: 'start', expected_revision: 0, device_id: current.deviceId,
          occurred_at: new Date(sample.wallMs).toISOString(), task_id: taskId, clock_session_id: sample.clockSessionId, target_ms: targetMs };
        const anchor = mode === 'offline' ? this.newAnchor(recordId, operationId, sample) : null;
        const record: LocalFocusRecord = { recordId: recordId, taskId: taskId, mode: mode, localState: mode === 'offline' ? 'running' : 'starting',
          revision: 1, confirmedRevision: 0, confirmedState: null, targetMs: targetMs, baseElapsedMs: 0, confirmedElapsedMs: 0,
          segmentId: operationId, clockSessionId: sample.clockSessionId, anchor: anchor, intervals: [], gaps: [] };
        current.records.push(record); current.operations.push({ recordId: recordId, request: request, dispatchState: 'queued', receipt: null, errorCode: '' });
        await this.commit(current, generation); this.state.selectedRecordId = recordId; this.state.clockAvailable = true;
        if (anchor !== null && this.state.foreground && activity === this.activityRevision) {
          this.timer = new FocusTimer(anchor); this.timerRunning = true; this.lastCheckpoint = sample.monotonicMs; this.schedule();
        }
      });
      if (this.valid(generation)) { await this.settleDormantAnchor(recordId, generation); }
      if (mode === 'online' && this.valid(generation)) { await this.sync(); }
    } catch (error) { if (this.valid(generation)) { this.state.clockAvailable = false; this.fail(error as Error, '本机时钟或记录保存不可用，本次未开始可靠计时。'); } }
    finally { if (generation === this.generation) { this.localBusy = false; this.publish(); } }
  }
  private sealInto(doc: FocusDocument, record: LocalFocusRecord, timer: FocusTimer | null,
    kind: 'pause' | 'end', reason: FocusGapReason | null = null, observedEnd: number | null = null): void {
    const interval = timer?.interval() ?? null;
    const intervals: FocusInterval[] = interval === null ? [] : [interval];
    const gaps: FocusGap[] = reason === null || timer === null ? [] : [timer.gap(this.uuid(), reason, observedEnd)];
    if (record.segmentId === null && kind === 'pause') { throw new Error('没有待暂停的计时段。'); }
    const request: FocusRequest = kind === 'pause' ? { operation_id: this.uuid(), kind: 'pause', expected_revision: record.revision,
      device_id: doc.deviceId, occurred_at: this.time(), segment_id: record.segmentId ?? '', clock_session_id: record.clockSessionId ?? '', intervals: intervals, unknown_gaps: gaps } :
      { operation_id: this.uuid(), kind: 'end', expected_revision: record.revision, device_id: doc.deviceId, occurred_at: this.time(), reason: 'local_end',
        segment_id: record.segmentId, clock_session_id: record.clockSessionId, intervals: intervals, unknown_gaps: gaps };
    if (!validFocusRequest(request) || doc.operations.length >= 100) { throw new Error('待同步容量不足，请先处理原记录。'); }
    record.intervals = record.intervals.concat(intervals); record.gaps = record.gaps.concat(gaps); record.anchor = null;
    record.segmentId = null; record.clockSessionId = null; record.revision++; record.localState = kind === 'pause' ? 'paused' : 'ended';
    doc.operations.push({ recordId: record.recordId, request: request, dispatchState: 'queued', receipt: null, errorCode: '' });
  }
  private async seal(kind: 'pause' | 'end', reason: FocusGapReason | null = null, observedEnd: number | null = null, automatic: boolean = false): Promise<void> {
    if (!this.valid() || this.localBusy) { return; }
    const timer = this.timer; const recordId = timer?.snapshot().recordId ?? this.state.selectedRecordId;
    if (!automatic && recordId !== this.state.selectedRecordId) { return; }
    const record = this.localRecord(recordId);
    if (record === undefined || record.localState === 'ended' || kind === 'pause' && record.segmentId === null) { return; }
    if (record.mode === 'online' && this.document().operations.some((operation: LocalFocusOperation) => operation.recordId === recordId) && timer === null) {
      this.state.message = '请先核对这条记录的原操作，不能在未知版本上结束。'; this.publish(); return;
    }
    this.stopSamples(); this.localBusy = true; const generation = this.generation;
    try {
      await this.queue(async () => {
        if (!this.valid(generation)) { return; }
        const doc = this.document(); const current = doc.records.find((value: LocalFocusRecord) => value.recordId === recordId);
        if (current === undefined || current.localState === 'ended') { return; }
        this.sealInto(doc, current, timer ?? (current.anchor === null ? null : new FocusTimer(current.anchor)), kind, reason, observedEnd);
        await this.commit(doc, generation); if (this.timer === timer) { this.timer = null; }
      });
      if (record.mode === 'online' && this.state.foreground && this.valid(generation)) { await this.sync(); }
      if (this.valid(generation)) { this.state.message = kind === 'pause' ? '本机已暂停；服务器是否已记录以同步结果为准。' : '本机已结束计时；记录保存与任务完成分别核对。'; }
    } catch (error) { if (this.valid(generation)) { this.saveState = 'error'; this.fail(error as Error, '已停止累计，但封存尚未保存；可证前缀仍在本页，请重试暂停或结束。'); } }
    finally { if (generation === this.generation) { this.localBusy = false; this.publish(); } }
  }
  async pause(): Promise<void> { await this.seal('pause'); }
  async end(): Promise<void> { await this.seal('end'); }
  private adopt(doc: FocusDocument, record: FocusRecord): LocalFocusRecord {
    const existing = doc.records.find((value: LocalFocusRecord) => value.recordId === record.record_id);
    if (existing !== undefined) { return existing; }
    if (doc.records.length >= 20) { throw new Error('本机记录容量已满。'); }
    const local: LocalFocusRecord = { recordId: record.record_id, taskId: record.task_id, mode: 'online', localState: record.state === 'running' ? 'interrupted' : record.state,
      revision: record.revision, confirmedRevision: record.revision, confirmedState: record.state, targetMs: record.target_ms,
      baseElapsedMs: record.confirmed_elapsed_ms, confirmedElapsedMs: record.confirmed_elapsed_ms,
      segmentId: record.segment_id, clockSessionId: record.clock_session_id, anchor: null, intervals: [], gaps: [] };
    doc.records.push(local); return local;
  }
  async resume(): Promise<void> {
    if (!this.valid() || !this.state.foreground || this.localBusy || this.networkBusy) { return; }
    const recordId = this.state.selectedRecordId;
    let record = this.localRecord(recordId); const authoritative = this.state.record;
    const expectedRevision = record?.revision ?? authoritative?.revision ?? 0;
    if (record === undefined && (authoritative === null || authoritative.record_id !== this.state.selectedRecordId || authoritative.state !== 'paused')) { return; }
    if (record !== undefined && record.localState !== 'paused') { return; }
    const current = this.document();
    if (current.operations.length >= 98 || (record?.revision ?? authoritative?.revision ?? 0) >= 500 ||
      (record === undefined ? (authoritative?.interval_count ?? 0) + (authoritative?.unknown_gap_count ?? 0) : record.intervals.length + record.gaps.length) >= 1999 ||
      record?.mode !== 'offline' && current.operations.length > 0 || current.records.some((value: LocalFocusRecord) => value.recordId !== this.state.selectedRecordId && value.localState !== 'ended')) {
      this.state.message = '请先处理原记录或同步容量；不能在未知版本上继续。'; this.publish(); return;
    }
    this.localBusy = true; const generation = this.generation; const activity = this.activityRevision;
    try {
      const sample = await this.clock.sample(); if (!validFocusSample(sample)) { throw new Error('时钟不可用'); }
      if (!this.valid(generation) || activity !== this.activityRevision || recordId !== this.state.selectedRecordId) { return; }
      await this.queue(async () => {
        if (!this.valid(generation) || activity !== this.activityRevision || recordId !== this.state.selectedRecordId) { return; }
        const doc = this.document(); record = doc.records.find((value: LocalFocusRecord) => value.recordId === recordId);
        if (record === undefined && authoritative !== null) { record = this.adopt(doc, authoritative); }
        if (record === undefined || record.localState !== 'paused' || record.revision !== expectedRevision) { return; }
        const operationId = this.uuid(); const request: FocusRequest = { operation_id: operationId, kind: 'resume', expected_revision: record.revision,
          device_id: doc.deviceId, occurred_at: new Date(sample.wallMs).toISOString(), clock_session_id: sample.clockSessionId };
        record.revision++; record.segmentId = operationId; record.clockSessionId = sample.clockSessionId;
        record.localState = record.mode === 'offline' ? 'running' : 'starting';
        record.anchor = record.mode === 'offline' ? this.newAnchor(record.recordId, operationId, sample) : null;
        doc.operations.push({ recordId: record.recordId, request: request, dispatchState: 'queued', receipt: null, errorCode: '' });
        await this.commit(doc, generation);
        if (record.anchor !== null && this.state.foreground && activity === this.activityRevision) {
          this.timer = new FocusTimer(record.anchor); this.timerRunning = true; this.lastCheckpoint = sample.monotonicMs; this.schedule();
        }
      });
      if (this.valid(generation)) { await this.settleDormantAnchor(recordId, generation); }
      if (record?.mode === 'online' && this.valid(generation)) { await this.sync(); }
    } catch (error) { if (this.valid(generation)) { this.fail(error as Error, '本次未能可靠继续计时，请核对时钟和本机保存后重试。'); } }
    finally { if (generation === this.generation) { this.localBusy = false; this.publish(); } }
  }
  private async saveDispatch(id: string, dispatch: 'unknown' | 'not_found' | 'conflict', code: string, generation: number): Promise<LocalFocusOperation | null> {
    let frozen: LocalFocusOperation | null = null;
    await this.queue(async () => {
      if (!this.valid(generation)) { return; }
      const doc = this.document(); const operation = doc.operations.find((value: LocalFocusOperation) => value.request.operation_id === id);
      if (operation === undefined) { return; }
      operation.dispatchState = dispatch; operation.errorCode = /^[A-Z_]{0,80}$/.test(code) ? code : '';
      await this.commit(doc, generation); frozen = operation;
    });
    return frozen;
  }
  private async apply(operation: LocalFocusOperation, result: FocusOperation, generation: number): Promise<void> {
    if (!validFocusOperation(result, this.userId, operation.recordId, operation.request)) { throw new Error('回执不匹配'); }
    await this.queue(async () => {
      if (!this.valid(generation)) { return; }
      const doc = this.document(); const saved = doc.operations.find((value: LocalFocusOperation) => value.request.operation_id === operation.request.operation_id);
      const record = doc.records.find((value: LocalFocusRecord) => value.recordId === operation.recordId);
      if (saved === undefined || record === undefined || JSON.stringify(saved.request) !== JSON.stringify(operation.request)) { throw new Error('本机原请求已变化'); }
      record.confirmedRevision = Math.max(record.confirmedRevision, result.receipt.after_revision);
      record.confirmedElapsedMs += result.receipt.added_elapsed_ms;
      record.confirmedState = result.receipt.after_state === 'deleted' ? 'ended' : result.receipt.after_state;
      doc.operations = doc.operations.filter((value: LocalFocusOperation) => value !== saved);
      if (result.receipt.after_state === 'deleted' || record.localState === 'ended' && !doc.operations.some((value: LocalFocusOperation) => value.recordId === record.recordId)) {
        doc.records = doc.records.filter((value: LocalFocusRecord) => value !== record);
      }
      await this.commit(doc, generation);
    });
    if (!this.valid(generation)) { return; }
    // A successful mutation changes the list snapshot. Never splice a detail row
    // into an older token or retain deleted content as if it were current history.
    this.historyRevision++; this.historyCursor = ''; this.historyToken = '';
    this.state.history = []; this.state.historyLoading = false; this.state.historyHasMore = false;
    this.state.historyError = '记录已有变化，请刷新已同步记录。';
    const request = operation.request;
    if ((request.kind === 'start' || request.kind === 'resume') && this.localRecord(operation.recordId)?.localState === 'starting') {
      if (this.state.foreground && this.api !== null) {
        try {
          const current = await this.api.focusDetail(operation.recordId);
          if (!this.valid(generation)) { return; }
          if (!validFocusDetail(current, this.userId, operation.recordId) || current.record.revision !== result.receipt.after_revision ||
            current.record.state !== 'running' || current.record.current_device_id !== request.device_id ||
            current.record.segment_id !== request.operation_id || current.record.clock_session_id !== request.clock_session_id) {
            throw new Error('原开始回执已不是当前运行状态。');
          }
          await this.beginTimer(operation.recordId, generation);
        } catch {
          if (this.valid(generation)) { this.state.message = '原操作已有回执，但当前运行状态未核实，未重新开始计时；请读取当前记录。'; }
        }
      }
      if (this.localRecord(operation.recordId)?.localState === 'starting') {
        await this.queue(async () => {
          if (!this.valid(generation)) { return; }
          const doc = this.document(); const local = doc.records.find((value: LocalFocusRecord) => value.recordId === operation.recordId);
          if (local !== undefined && local.localState === 'starting') { local.localState = 'interrupted'; await this.commit(doc, generation); }
        });
      }
    }
  }
  private async send(operation: LocalFocusOperation, generation: number): Promise<boolean> {
    if (!this.valid(generation) || this.api === null) { return false; }
    let sent = false;
    try {
      const frozen = await this.saveDispatch(operation.request.operation_id, 'unknown', '', generation);
      if (frozen === null || !this.valid(generation) || !this.state.foreground) { return false; }
      this.sendingId = frozen.request.operation_id; this.publish(); sent = true;
      const result = await this.api.submitFocusOperation(frozen.recordId, copyRequest(frozen.request));
      if (!this.valid(generation)) { return false; }
      await this.apply(frozen, result, generation); this.state.message = '这次记录操作已取得回执，当前记录将单独读取。'; return true;
    } catch (error) {
      if (!this.valid(generation)) { return false; }
      if (sent && definitive(error as Error)) {
        try { await this.saveDispatch(operation.request.operation_id, 'conflict', safeCode(error as Error), generation); } catch { /* Keep unknown if rejection cannot be persisted. */ }
      }
      this.fail(error as Error, sent ? '本次同步未完成，请保留原编号核对；没有自动改版本或重发。' : '操作尚未可靠保存，本次没有发送；本机内容仍保留。'); return false;
    } finally { if (generation === this.generation) { this.sendingId = ''; } }
  }
  async sync(): Promise<void> {
    if (!this.valid() || !this.state.foreground || this.networkBusy) { return; }
    this.networkBusy = true; const generation = this.generation;
    try {
      while (this.valid(generation) && this.state.foreground) {
        const first = this.document().operations[0]; if (first === undefined || first.dispatchState !== 'queued') { break; }
        if (!await this.send(first, generation)) { break; }
      }
      if (this.valid(generation)) { await this.readCurrent(); }
    } finally { if (generation === this.generation) { this.networkBusy = false; this.publish(); } }
  }
  async check(operationId: string): Promise<void> {
    if (!this.valid() || !this.state.foreground || this.networkBusy || this.api === null) { return; }
    const operation = this.document().operations.find((value: LocalFocusOperation) => value.request.operation_id === operationId);
    if (operation === undefined || !['unknown','not_found'].includes(operation.dispatchState)) { return; }
    this.networkBusy = true; const generation = this.generation; this.publish();
    try {
      const result = await this.api.focusOperation(operationId); if (!this.valid(generation)) { return; }
      await this.apply(operation, result, generation); await this.readCurrent();
    } catch (error) {
      if (!this.valid(generation)) { return; }
      if (error instanceof CampusFlowRequestError && error.statusCode === 404 && error.code === 'FOCUS_OPERATION_NOT_FOUND') {
        try { await this.saveDispatch(operationId, 'not_found', error.code, generation); } catch { this.state.message = '查询结果未保存，请再次核对；尚未重试。'; }
      } else { this.fail(error as Error, '原操作结果仍未核实，请稍后查询；不会自动重发。'); }
    } finally { if (generation === this.generation) { this.networkBusy = false; this.publish(); } }
  }
  async retry(operationId: string): Promise<void> {
    if (!this.valid() || !this.state.foreground || this.networkBusy) { return; }
    const operation = this.document().operations[0];
    if (operation === undefined || operation.request.operation_id !== operationId || operation.dispatchState !== 'not_found') { return; }
    this.networkBusy = true; const generation = this.generation;
    try { await this.send(operation, generation); if (this.valid(generation)) { await this.readCurrent(); } }
    finally { if (generation === this.generation) { this.networkBusy = false; this.publish(); } }
  }
  private async readCurrent(): Promise<void> {
    if (!this.valid() || this.api === null || !this.state.foreground) { return; }
    const generation = this.generation; const activity = this.activityRevision; const revision = ++this.activeRevision;
    try {
      const active = await this.api.focusActive();
      if (!this.valid(generation) || activity !== this.activityRevision || revision !== this.activeRevision) { return; }
      if (!validFocusActive(active, this.userId)) { throw new Error('活动记录不可核验'); }
      this.state.activeRecord = active.record;
    } catch (error) { if (this.valid(generation)) { this.state.message = '服务器当前记录暂未读取，本机计时与待同步内容仍保留。'; this.state.errorCode = safeCode(error as Error); } }
    if (this.valid(generation) && activity === this.activityRevision && this.state.selectedRecordId !== '') { await this.selectRecord(this.state.selectedRecordId); }
    this.publish();
  }
  async selectRecord(recordId: string): Promise<void> {
    if (!this.valid() || !focusUuid(recordId) || this.api === null) { return; }
    this.state.selectedRecordId = recordId; this.state.record = null; this.state.intervals = []; this.state.unknownGaps = [];
    this.state.intervalLoading = true; this.state.intervalError = ''; const revision = ++this.detailRevision; const generation = this.generation; this.publish();
    try {
      const detail = await this.api.focusDetail(recordId);
      if (!this.valid(generation) || revision !== this.detailRevision) { return; }
      if (!validFocusDetail(detail, this.userId, recordId)) { throw new Error('详情不可核验'); }
      this.state.record = detail.record; this.state.intervals = detail.intervals; this.state.unknownGaps = detail.unknown_gaps;
    } catch (error) { if (this.valid(generation) && revision === this.detailRevision) { this.state.intervalError = safeCode(error as Error) === 'FOCUS_DELETED' ? '该服务器记录已删除，本机未同步片段不会据旧回执复活。' : '服务器详情未读取；本机待同步内容不是服务器回执。'; } }
    finally { if (this.valid(generation) && revision === this.detailRevision) { this.state.intervalLoading = false; this.publish(); } }
  }
  async refreshHistory(): Promise<void> {
    if (!this.valid() || this.api === null) { return; }
    this.historyCursor = ''; this.historyToken = ''; this.state.history = []; this.state.historyHasMore = false; await this.historyPage(true);
  }
  async loadMoreHistory(): Promise<void> {
    if (!this.valid() || this.state.historyLoading || !this.state.historyHasMore) { return; } await this.historyPage(false);
  }
  private async historyPage(reset: boolean): Promise<void> {
    if (!this.valid() || this.api === null) { return; }
    const revision = ++this.historyRevision; const generation = this.generation;
    this.state.historyLoading = true; this.state.historyError = ''; this.publish();
    try {
      const page = await this.api.focusList(reset ? '' : this.historyCursor, reset ? '' : this.historyToken, 20);
      if (!this.valid(generation) || revision !== this.historyRevision) { return; }
      if (!validFocusList(page, this.userId) || !reset && (page.snapshot_token !== this.historyToken ||
        page.records.some((record: FocusRecord) => this.state.history.some((existing: FocusRecord) => existing.record_id === record.record_id)))) { throw new Error('列表快照已变化'); }
      this.state.history = reset ? page.records : this.state.history.concat(page.records); this.historyToken = page.snapshot_token;
      this.historyCursor = page.next_cursor ?? ''; this.state.historyHasMore = page.next_cursor !== null;
    } catch { if (this.valid(generation) && revision === this.historyRevision) { this.state.historyError = '记录列表未能完整核对，请刷新；没有拼接不同版本的数据。'; this.state.historyHasMore = false; } }
    finally { if (this.valid(generation) && revision === this.historyRevision) { this.state.historyLoading = false; this.publish(); } }
  }
  private async remoteOperation(recordId: string, revision: number, kind: 'end' | 'delete'): Promise<void> {
    if (!this.valid() || !this.state.foreground || this.localBusy || this.networkBusy || this.api === null || !focusUuid(recordId)) { return; }
    if (this.document().operations.length > 0 || this.timer !== null) { this.state.message = '请先处理本机计时与原操作，再明确处理服务器记录。'; this.publish(); return; }
    this.localBusy = true; const generation = this.generation;
    try {
      const detail = await this.api.focusDetail(recordId); if (!this.valid(generation)) { return; }
      if (!validFocusDetail(detail, this.userId, recordId) || detail.record.revision !== revision ||
        kind === 'delete' && detail.record.state === 'running' || kind === 'end' && detail.record.state === 'ended') { throw new Error('服务器记录已变化'); }
      await this.queue(async () => {
        if (!this.valid(generation)) { return; }
        const doc = this.document(); const local = this.adopt(doc, detail.record);
        const request: FocusRequest = kind === 'delete' ? { operation_id: this.uuid(), kind: 'delete', expected_revision: revision,
          device_id: doc.deviceId, occurred_at: this.time() } : { operation_id: this.uuid(), kind: 'end', expected_revision: revision,
          device_id: doc.deviceId, occurred_at: this.time(), reason: 'remote_end', segment_id: null, clock_session_id: null, intervals: [], unknown_gaps: [] };
        local.revision = revision + 1; local.localState = 'ended'; local.segmentId = null; local.clockSessionId = null; local.anchor = null;
        doc.operations.push({ recordId: recordId, request: request, dispatchState: 'queued', receipt: null, errorCode: '' });
        await this.commit(doc, generation); this.state.selectedRecordId = recordId;
      });
      if (this.valid(generation)) { await this.sync(); }
    } catch (error) { if (this.valid(generation)) { this.fail(error as Error, '这条记录已变化或本机保存失败，请读取最新记录后重新明确选择。'); } }
    finally { if (generation === this.generation) { this.localBusy = false; this.publish(); } }
  }
  async remoteEnd(recordId: string, revision: number): Promise<void> { await this.remoteOperation(recordId, revision, 'end'); }
  async deleteRecord(recordId: string, revision: number): Promise<void> { await this.remoteOperation(recordId, revision, 'delete'); }
  async clearLocal(): Promise<void> {
    this.stopSamples(); this.timer = null; this.generation++; this.detailRevision++; this.historyRevision++; this.lease = null;
    this.networkBusy = false; this.localBusy = false; const generation = this.generation; const foreground = this.state.foreground;
    this.state = emptyFocusState(); this.state.foreground = foreground; this.publish();
    try { await this.store.clear(); if (generation === this.generation) { this.state.phase = 'ready'; this.state.message = '本机专注缓存已清理；这不取消已发往服务器的操作。'; this.publish(); } }
    catch (error) {
      const failure: Error = error instanceof Error ? error : new Error('FOCUS_LOCAL_CLEAR_FAILED');
      if (generation === this.generation) { this.state.phase = 'error'; this.fail(failure, '本机清理未完成，不能切换账号继续写入，请重试清理。'); }
      throw failure;
    }
  }
  dispose(): void { this.stopSamples(); this.disposed = true; this.generation++; this.lease = null; this.timer = null; }
}
