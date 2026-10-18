import { CourseAcknowledgement, PlanningTask, TaskStatusOperation, TaskStatusStartRequest } from '../model/ApiModels';
import { DraftLease, DraftStore, DraftTaskStatusOperation } from './DraftStore';
import { CampusFlowRequestError } from './AgentFeedback';
import { taskStatusUuid, validTaskStatusRequest, validTaskStatusOperation, validTaskStatusAcknowledgements,
  taskStatusCanConfirm } from './TaskStatusValidation';

export interface TaskStatusGateway {
  startTaskStatus(taskId: string, request: TaskStatusStartRequest): Promise<TaskStatusOperation>;
  taskStatusOperation(id: string): Promise<TaskStatusOperation>;
  confirmTaskStatus(id: string, acknowledgements: CourseAcknowledgement[]): Promise<TaskStatusOperation>;
  cancelTaskStatus(id: string): Promise<TaskStatusOperation>;
}
export interface TaskStatusItem {
  operationId: string; taskId: string; kind: 'complete' | 'restore'; request: TaskStatusStartRequest;
  phase: string; operation: TaskStatusOperation | null; message: string; errorCode: string;
  busy: boolean; canRetry: boolean; canConfirm: boolean; canCancel: boolean;
}
export interface TaskStatusState {
  items: TaskStatusItem[]; selectedId: string; lockedTaskIds: string[]; pendingCount: number; message: string;
}
interface StatusItem extends TaskStatusItem { revision: number; pointer: DraftTaskStatusOperation; rejected: boolean; }
function busy(phase: string): boolean { return ['preparing', 'persisting', 'starting', 'checking', 'confirming', 'cancelling'].includes(phase); }
function settled(phase: string): boolean { return ['applied', 'cancelled', 'error'].includes(phase); }
function copyRequest(value: TaskStatusStartRequest): TaskStatusStartRequest {
  return value.kind === 'complete' ? { operation_id: value.operation_id, kind: 'complete', expected_revision: value.expected_revision } :
    { operation_id: value.operation_id, kind: 'restore', expected_revision: value.expected_revision, source_operation_id: value.source_operation_id };
}
function knownStartRejection(error: CampusFlowRequestError): boolean {
  return ['TASK_NOT_FOUND', 'TASK_STALE', 'TASK_STATUS_UNCHANGED', 'TASK_COMPLETION_NOT_TRACKED', 'TASK_COMPLETION_SUPERSEDED',
    'TASK_STATUS_OPERATION_REUSED', 'ACTION_INVALID', 'ACTION_CONFLICT', 'LOGIN_REQUIRED'].includes(error.code) ||
    [401, 403, 422].includes(error.statusCode);
}

// This account-level controller survives tab navigation. Only authenticated operation
// receipts settle writes; a task list's completed flag is never substituted as proof.
export class TaskStatusController {
  private store: DraftStore;
  private onChange: (state: TaskStatusState) => void;
  private onApplied: (operation: TaskStatusOperation) => void;
  private idFactory: () => string;
  private now: () => number;
  private api: TaskStatusGateway | null = null;
  private lease: DraftLease | null = null;
  private scope: string = '';
  private userId: string = '';
  private active: boolean = false;
  private disposed: boolean = false;
  private generation: number = 0;
  private items: StatusItem[] = [];
  private selectedId: string = '';
  private message: string = '';
  private notified: string[] = [];

  constructor(store: DraftStore, onChange: (state: TaskStatusState) => void,
    onApplied: (operation: TaskStatusOperation) => void, idFactory: () => string, now: () => number = Date.now) {
    this.store = store; this.onChange = onChange; this.onApplied = onApplied; this.idFactory = idFactory; this.now = now;
  }
  snapshot(): TaskStatusState {
    const items = this.items.map((item: StatusItem): TaskStatusItem => ({ operationId: item.operationId,
      taskId: item.taskId, kind: item.kind, request: copyRequest(item.request), phase: item.phase,
      operation: item.operation === null ? null : JSON.parse(JSON.stringify(item.operation)) as TaskStatusOperation,
      message: item.message, errorCode: item.errorCode, busy: busy(item.phase), canRetry: item.phase === 'retryable',
      canConfirm: item.phase === 'review' && item.pointer.intent !== 'cancel' && item.operation !== null && taskStatusCanConfirm(item.operation, this.now()),
      canCancel: item.phase === 'review' && item.kind === 'restore' && item.operation?.state === 'pending' }));
    const locked = this.items.filter((item: StatusItem) => !settled(item.phase)).map((item: StatusItem) => item.taskId);
    return { items: items, selectedId: this.selectedId, lockedTaskIds: Array.from(new Set<string>(locked)),
      pendingCount: locked.length, message: this.message };
  }
  private publish(): void { if (!this.disposed) { this.onChange(this.snapshot()); } }
  private ready(): boolean {
    return !this.disposed && this.active && this.userId.trim().length > 0 && this.scope.length > 0 && this.api !== null && this.lease !== null &&
      this.lease.scope === this.scope && this.store.valid(this.lease);
  }
  private current(item: StatusItem, generation: number, revision: number): boolean {
    return this.ready() && generation === this.generation && item.revision === revision && this.items.includes(item);
  }
  private find(id?: string): StatusItem | undefined { return this.items.find((item: StatusItem) => item.operationId === (id ?? this.selectedId)); }
  private refreshPointer(item: StatusItem): boolean {
    if (!this.ready() || this.lease === null) { return false; }
    const saved = this.store.taskStatusOperations(this.lease).find((value: DraftTaskStatusOperation) =>
      value.request.operation_id === item.operationId);
    if (saved === undefined || saved.scope !== this.scope || saved.taskId !== item.taskId ||
      JSON.stringify(copyRequest(saved.request as TaskStatusStartRequest)) !== JSON.stringify(item.request)) { return false; }
    // An earlier foreground generation may finish its atomic intent write after
    // recovery's GET. The durable intent, not that generation's UI copy, owns CAS.
    item.pointer = saved; return true;
  }
  configure(scope: string, userId: string, api: TaskStatusGateway, lease: DraftLease | null): void {
    if (this.disposed) { return; }
    const same = scope === this.scope && userId === this.userId && lease?.scope === this.lease?.scope && lease?.generation === this.lease?.generation;
    this.api = api;
    if (same) { return; }
    this.generation++; this.scope = scope; this.userId = userId; this.lease = lease;
    this.items = []; this.selectedId = ''; this.message = ''; this.notified = [];
    this.publish(); if (this.ready()) { this.recover(); }
  }
  setActive(active: boolean): void {
    if (this.disposed || active === this.active) { return; }
    this.active = active; this.generation++;
    if (!active) {
      this.items.forEach((item: StatusItem) => {
        if (item.phase === 'preparing') {
          item.phase = 'error'; item.message = '来源核对已中止，尚未创建恢复操作；返回后可重新核对。'; item.revision++;
        } else if (busy(item.phase)) { item.phase = 'unknown'; item.message = '返回后先核对这次操作的服务器记录。'; item.revision++; }
      });
    } else if (this.ready()) { this.recover(); }
    this.publish();
  }
  private item(pointer: DraftTaskStatusOperation): StatusItem {
    const request = copyRequest(pointer.request as TaskStatusStartRequest);
    return { operationId: request.operation_id, taskId: pointer.taskId, kind: request.kind, request: request,
      phase: 'unknown', operation: null, message: '这次状态操作尚待核对。', errorCode: '', revision: 0, pointer: pointer, rejected: false,
      busy: false, canRetry: false, canConfirm: false, canCancel: false };
  }
  private recover(): void {
    if (!this.ready() || this.lease === null) { return; }
    const saved = this.store.taskStatusOperations(this.lease);
    // A local resolution can finish while the foreground was paused. Reconcile its
    // durable removal before exposing locks; never leave a receipt permanently busy.
    this.items.forEach((item: StatusItem) => {
      if (!settled(item.phase) && !saved.some((value: DraftTaskStatusOperation) => value.request.operation_id === item.operationId)) {
        item.phase = item.operation?.state === 'applied' ? 'applied' : item.operation?.state === 'cancelled' ? 'cancelled' : 'error';
        item.message = item.operation === null ? '这次本机操作标识已结清，请读取最新任务后再操作。' : '这次操作的服务器回执与本机核对标识均已结清。';
      }
    });
    saved.forEach((pointer: DraftTaskStatusOperation) => {
      let item = this.find(pointer.request.operation_id);
      if (item === undefined) { item = this.item(pointer); this.items.push(item); }
      else { item.pointer = pointer; }
      if (this.selectedId.length === 0) { this.selectedId = item.operationId; }
      if (!busy(item.phase)) { this.check(item.operationId).catch((): void => {}); }
    });
    this.publish();
  }
  select(id: string): void { if (this.find(id) !== undefined) { this.selectedId = id; this.publish(); } }
  dismiss(id?: string): void {
    const item = this.find(id); if (item === undefined || !settled(item.phase)) { return; }
    this.items = this.items.filter((value: StatusItem) => value !== item);
    if (this.selectedId === item.operationId) { this.selectedId = this.items[0]?.operationId ?? ''; }
    this.publish();
  }
  dispose(): void { this.disposed = true; this.active = false; this.generation++; this.items = []; }

  async begin(task: PlanningTask, kind: 'complete' | 'restore'): Promise<void> {
    if (!this.ready() || this.lease === null || this.api === null) { return; }
    if (this.items.some((item: StatusItem) => item.taskId === task.task_id && !settled(item.phase))) {
      this.selectedId = this.items.find((item: StatusItem) => item.taskId === task.task_id && !settled(item.phase))?.operationId ?? '';
      this.message = '这项任务还有待核对操作，请先处理原编号。'; this.publish(); return;
    }
    if (typeof task.task_id !== 'string' || task.task_id.trim().length === 0 || task.task_id.length > 128 ||
      !Number.isSafeInteger(task.task_version) || (task.task_version ?? 0) < 1 ||
      task.status !== (kind === 'complete' ? 'pending' : 'completed') ||
      (kind === 'restore' && !taskStatusUuid(task.completion_operation_id ?? ''))) {
      this.message = kind === 'restore' ? '这次完成未保留可核验凭据，或任务版本已变化；请刷新后核对。' : '任务版本不可核验，请刷新后再标记完成。';
      this.selectedId = '';
      this.publish(); return;
    }
    const request: TaskStatusStartRequest = kind === 'complete' ? { operation_id: this.idFactory(), kind: 'complete', expected_revision: task.task_version ?? 0 } :
      { operation_id: this.idFactory(), kind: 'restore', expected_revision: task.task_version ?? 0, source_operation_id: task.completion_operation_id ?? '' };
    if (!validTaskStatusRequest(request) || this.find(request.operation_id) !== undefined ||
      this.store.taskStatusOperations(this.lease).some((value: DraftTaskStatusOperation) => value.request.operation_id === request.operation_id)) {
      this.selectedId = ''; this.message = '无法生成新的有效操作编号，本次未提交。'; this.publish(); return;
    }
    const item = this.item({ scope: this.scope, taskId: task.task_id, request: request, intent: 'start', acknowledgements: [] });
    item.phase = 'preparing'; this.items.push(item); this.selectedId = item.operationId; this.message = ''; this.publish();
    if (!this.ready() || !this.items.includes(item)) { return; }
    const generation = this.generation; const revision = ++item.revision; const api = this.api;
    if (request.kind === 'restore') {
      try {
        const source = await api.taskStatusOperation(request.source_operation_id);
        if (!this.current(item, generation, revision)) { return; }
        const sourceRequest: TaskStatusStartRequest = { operation_id: request.source_operation_id, kind: 'complete', expected_revision: source.expected_revision };
        if (!validTaskStatusOperation(source, this.userId, item.taskId, sourceRequest) || source.state !== 'applied' ||
          source.receipt === null || source.receipt.after_revision > request.expected_revision) { throw new Error('invalid completion receipt'); }
      } catch {
        if (!this.current(item, generation, revision)) { return; }
        item.phase = 'error'; item.message = '无法核验这次完成的原始回执，尚未创建恢复预览。请刷新任务与来源记录后再试。'; this.publish(); return;
      }
    }
    if (!this.current(item, generation, revision)) { return; }
    await this.start(item);
  }
  private async start(item: StatusItem): Promise<void> {
    if (!this.ready() || this.lease === null || this.api === null) { return; }
    const generation = this.generation; const revision = ++item.revision; const lease = this.lease; const api = this.api;
    item.phase = 'persisting'; item.message = '正在保存操作编号，完成后再提交。'; item.errorCode = ''; this.publish();
    let sent = false;
    try {
      await this.store.beginTaskStatusOperation(lease, item.pointer);
      if (!this.current(item, generation, revision)) { return; }
      item.phase = 'starting'; item.message = item.kind === 'complete' ? '正在记录这次完成…' : '正在生成恢复预览，任务尚未恢复。'; this.publish();
      sent = true; const result = await api.startTaskStatus(item.taskId, copyRequest(item.request));
      if (!this.current(item, generation, revision)) { return; }
      await this.accept(item, result, generation, revision);
    } catch (error) {
      if (!this.current(item, generation, revision)) { return; }
      if (sent && error instanceof CampusFlowRequestError && knownStartRejection(error)) {
        item.rejected = true; item.errorCode = error.code; item.message = error.message;
        await this.settle(item, 'error', generation, revision);
      } else {
        const retained = this.store.taskStatusOperations(lease).some((value: DraftTaskStatusOperation) => value.request.operation_id === item.operationId);
        item.phase = !sent && !retained ? 'error' : 'unknown';
        item.message = sent ? '尚未收到可核验结果，请先查询原操作；不会自动重新提交。' :
          retained ? '操作编号尚未可靠保存，本次没有发送。请先查询原编号后显式重试。' : '本机暂不能保存新的操作编号，本次没有提交；请先处理已有记录或检查本机存储。';
      }
    }
    if (this.current(item, generation, revision)) { this.publish(); }
  }
  private async settle(item: StatusItem, phase: string, generation: number, revision: number): Promise<void> {
    if (this.lease === null) { return; }
    try {
      await this.store.resolveTaskStatusOperation(this.lease, item.operationId);
      if (!this.current(item, generation, revision)) { return; }
      item.phase = phase;
    } catch {
      if (!this.current(item, generation, revision)) { return; }
      item.phase = 'cleanup'; item.message += ' 本机核对标识尚未结清，请再次查询；不会另发写入。';
    }
  }
  private async accept(item: StatusItem, value: TaskStatusOperation, generation: number, revision: number): Promise<void> {
    if (!validTaskStatusOperation(value, this.userId, item.taskId, item.request, item.operation)) { throw new Error('invalid status operation'); }
    item.operation = JSON.parse(JSON.stringify(value)) as TaskStatusOperation; item.errorCode = '';
    if (value.state === 'pending') {
      item.phase = 'review'; item.message = taskStatusCanConfirm(value, this.now()) ? '请核对完整恢复预览；确认只改变完成状态，保留当前其他字段。' :
        '预览存在冲突或已过期。可以取消本次预览，再读取最新任务重新核对。'; return;
    }
    item.message = value.state === 'applied' ? '服务器已核验这次操作的回执；当前任务以刷新后的列表为准。' : '本次恢复预览已取消。';
    if (value.state === 'applied' && !this.notified.includes(item.operationId)) {
      this.notified.push(item.operationId);
      try { this.onApplied(JSON.parse(JSON.stringify(value)) as TaskStatusOperation); } catch { /* A refresh cannot invalidate a server receipt. */ }
    }
    if (this.current(item, generation, revision)) { await this.settle(item, value.state, generation, revision); }
  }
  async check(id?: string): Promise<void> {
    const item = this.find(id); if (!this.ready() || this.api === null || item === undefined || busy(item.phase) || settled(item.phase)) { return; }
    this.refreshPointer(item);
    const generation = this.generation; const revision = ++item.revision; const api = this.api;
    item.phase = 'checking'; item.message = '正在查询原操作编号…'; this.publish();
    if (!this.current(item, generation, revision)) { return; }
    try {
      const result = await api.taskStatusOperation(item.operationId);
      if (!this.current(item, generation, revision)) { return; }
      this.refreshPointer(item);
      await this.accept(item, result, generation, revision);
    } catch (error) {
      if (!this.current(item, generation, revision)) { return; }
      this.refreshPointer(item);
      if (error instanceof CampusFlowRequestError && error.statusCode === 404 && error.code === 'TASK_STATUS_OPERATION_NOT_FOUND' &&
        item.pointer.intent === 'start' && item.operation === null) {
        if (item.rejected) {
          item.message = '已核对本次请求被拒绝，未创建新的任务状态操作。';
          await this.settle(item, 'error', generation, revision);
        } else {
          item.phase = 'retryable'; item.message = '服务器尚未查到原编号。可明确重试原编号和原请求，不会创建另一笔操作。'; item.errorCode = error.code;
        }
      } else {
        item.phase = 'unknown'; item.message = '还不能核验原操作。请保留编号稍后查询，不根据列表状态猜测结果。';
        item.errorCode = error instanceof CampusFlowRequestError ? error.code : '';
      }
    }
    if (this.current(item, generation, revision)) { this.publish(); }
  }
  async retry(id?: string): Promise<void> {
    const item = this.find(id); if (!this.ready() || item === undefined || item.phase !== 'retryable' ||
      !this.refreshPointer(item) || item.pointer.intent !== 'start') { return; }
    await this.start(item);
  }
  async confirm(acknowledgements: CourseAcknowledgement[] = [], id?: string): Promise<void> {
    const item = this.find(id); if (!this.ready() || item === undefined || item.phase !== 'review' ||
      item.operation === null || !this.refreshPointer(item) || item.pointer.intent === 'cancel') { return; }
    if (!taskStatusCanConfirm(item.operation, this.now())) {
      item.message = '这份恢复预览已过期或有冲突，请取消后读取最新任务再核对。'; this.publish(); return;
    }
    if (!validTaskStatusAcknowledgements(item.operation, acknowledgements)) {
      item.message = '请逐项核对这次恢复与课程的重叠，再明确确认。'; this.publish(); return;
    }
    await this.decide(item, 'confirm', acknowledgements);
  }
  async cancel(id?: string): Promise<void> {
    const item = this.find(id); if (!this.ready() || item === undefined || item.phase !== 'review' ||
      item.kind !== 'restore' || item.operation?.state !== 'pending') { return; }
    await this.decide(item, 'cancel', []);
  }
  private async decide(item: StatusItem, intent: 'confirm' | 'cancel', acknowledgements: CourseAcknowledgement[]): Promise<void> {
    if (this.lease === null || this.api === null) { return; }
    if (!this.refreshPointer(item)) {
      item.phase = 'unknown'; item.message = '本机原操作标识尚不能核对，请先查询同一编号；本次没有发送。'; this.publish(); return;
    }
    const generation = this.generation; const revision = ++item.revision; const lease = this.lease; const api = this.api;
    const frozen = acknowledgements.map((value: CourseAcknowledgement): CourseAcknowledgement =>
      ({ candidate_id: value.candidate_id, review_digest: value.review_digest }));
    item.phase = 'persisting'; item.message = '正在保存本次明确选择…'; this.publish();
    try {
      await this.store.replaceTaskStatusIntent(lease, item.operationId, item.pointer, intent, frozen);
      if (!this.current(item, generation, revision)) { return; }
      const saved = this.store.taskStatusOperations(lease).find((value: DraftTaskStatusOperation) => value.request.operation_id === item.operationId);
      if (saved === undefined) { throw new Error('missing pointer'); } item.pointer = saved;
      item.phase = intent === 'confirm' ? 'confirming' : 'cancelling'; item.message = intent === 'confirm' ? '正在确认恢复…' : '正在取消恢复预览…'; this.publish();
      const result = intent === 'confirm' ? await api.confirmTaskStatus(item.operationId, frozen) : await api.cancelTaskStatus(item.operationId);
      if (!this.current(item, generation, revision)) { return; }
      if (result.state === 'pending') { throw new Error('write remained pending'); }
      await this.accept(item, result, generation, revision);
    } catch {
      if (!this.current(item, generation, revision)) { return; }
      this.refreshPointer(item);
      item.phase = 'unknown'; item.message = '本次选择的结果尚待核对，请先查询同一操作编号；没有自动重发。';
    }
    if (this.current(item, generation, revision)) { this.publish(); }
  }
}
