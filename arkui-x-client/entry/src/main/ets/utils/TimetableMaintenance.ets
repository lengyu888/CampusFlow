import { TimetableEntry, TimetableSnapshot, TimetableSaveReceipt, DataEvidence } from '../model/ApiModels';
import { CampusFlowRequestError } from './AgentFeedback';
import { normalizeTimetableEntry, validateTimetableList, TimetableIssue } from './OnboardingTimetable';

export interface TimetableGateway {
  timetable(): Promise<TimetableSnapshot>;
  saveTimetable(entries: TimetableEntry[], expectedRevision: string, operationId: string, confirmClear: boolean): Promise<TimetableSaveReceipt>;
  timetableOperation(operationId: string): Promise<TimetableSaveReceipt>;
}

export interface TimetableMaintenanceState {
  phase: string;
  entries: TimetableEntry[];
  revision: string;
  dirty: boolean;
  warnings: TimetableIssue[];
  message: string;
  notice: string;
  evidence?: DataEvidence[];
}

interface TimetableOperation {
  id: string;
  entries: TimetableEntry[];
  revision: string;
  confirmClear: boolean;
}

// Request identity only, never an authentication secret. Injection makes replay tests deterministic.
export function timetableOperationId(): string {
  let id = '';
  for (let index = 0; index < 32; index++) {
    let digit = Math.floor(Math.random() * 16);
    if (index === 12) { digit = 4; }
    if (index === 16) { digit = (digit & 3) | 8; }
    id += digit.toString(16);
  }
  return `${id.substring(0, 8)}-${id.substring(8, 12)}-${id.substring(12, 16)}-${id.substring(16, 20)}-${id.substring(20)}`;
}

function entriesCopy(entries: TimetableEntry[]): TimetableEntry[] {
  return entries.map((entry: TimetableEntry) => normalizeTimetableEntry(entry));
}

function validRevision(value: string): boolean {
  return typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
}

function validSnapshot(value: TimetableSnapshot): boolean {
  return value !== null && typeof value === 'object' && validRevision(value.revision) &&
    validateTimetableList(value.entries, true).valid;
}

export class TimetableMaintenance {
  private api: TimetableGateway;
  private onChange: (state: TimetableMaintenanceState) => void;
  private onApplied: () => void;
  private idFactory: () => string;
  private state: TimetableMaintenanceState = { phase: 'idle', entries: [], revision: '', dirty: false,
    warnings: [], message: '', notice: '' };
  private baseline: TimetableEntry[] = [];
  private operation: TimetableOperation | null = null;
  private receipt: TimetableSaveReceipt | null = null;
  private editorPending: boolean = false;
  private active: boolean = false;
  private disposed: boolean = false;
  private generation: number = 0;
  private notifiedId: string = '';
  private staleRevision: boolean = false;

  constructor(api: TimetableGateway, onChange: (state: TimetableMaintenanceState) => void,
    onApplied: () => void = () => {}, idFactory: () => string = timetableOperationId) {
    this.api = api;
    this.onChange = onChange;
    this.onApplied = onApplied;
    this.idFactory = idFactory;
  }

  snapshot(): TimetableMaintenanceState {
    return { phase: this.state.phase, entries: entriesCopy(this.state.entries), revision: this.state.revision,
      dirty: this.state.dirty, message: this.state.message, notice: this.state.notice,
      evidence: JSON.parse(JSON.stringify(this.state.evidence ?? [])) as DataEvidence[],
      warnings: this.state.warnings.map((issue: TimetableIssue): TimetableIssue => ({ index: issue.index,
        relatedIndex: issue.relatedIndex, field: issue.field, message: issue.message })) };
  }

  private emit(): void {
    if (!this.disposed) { this.onChange(this.snapshot()); }
  }

  private current(generation: number): boolean {
    return !this.disposed && this.active && generation === this.generation;
  }

  setActive(active: boolean): void {
    if (this.disposed || active === this.active) { return; }
    this.active = active;
    if (!active) {
      this.generation++;
      if (this.state.phase === 'saving' || this.state.phase === 'checking') {
        this.state.phase = this.receipt === null ? 'uncertain' : 'applied';
        this.state.message = this.receipt === null ? '保存结果尚未确认，请返回后核对这笔操作。' : '保存已收到回执，请返回后读取最新课表。';
      } else if (this.state.phase === 'loading') {
        this.state.phase = this.receipt !== null ? 'applied' : this.staleRevision ? 'stale' :
          (this.state.revision.length > 0 ? 'ready' : 'idle');
      }
      this.emit();
      return;
    }
    if (this.operation === null && this.receipt === null) { this.refresh(); }
  }

  canEdit(): boolean {
    return !this.disposed && this.active && this.state.revision.length > 0 && this.operation === null &&
      this.receipt === null && this.state.phase !== 'loading';
  }

  setEditorPending(pending: boolean): void {
    this.editorPending = pending;
    this.updateDirty();
    this.emit();
  }

  private updateDirty(): void {
    this.state.dirty = this.editorPending || JSON.stringify(this.state.entries) !== JSON.stringify(this.baseline);
  }

  replaceDraft(entries: TimetableEntry[]): boolean {
    if (!this.canEdit()) { return false; }
    const checked = validateTimetableList(entries, true);
    if (!checked.valid) { this.state.message = checked.errors[0].message; this.emit(); return false; }
    this.state.entries = checked.entries;
    this.state.warnings = checked.warnings;
    this.updateDirty();
    this.state.message = '';
    this.state.notice = '当前修改仅在本页草稿中，确认保存后才更新账号课表。';
    this.emit();
    return true;
  }

  async refresh(discardDraft: boolean = false): Promise<boolean> {
    if (this.disposed || !this.active || ['loading', 'saving', 'checking', 'uncertain', 'retryable'].includes(this.state.phase)) { return false; }
    const generation = ++this.generation;
    this.state.phase = 'loading';
    this.state.message = '';
    this.emit();
    try {
      const snapshot = await this.api.timetable();
      if (!this.current(generation)) { return false; }
      if (!validSnapshot(snapshot)) { throw new Error('invalid snapshot'); }
      if (this.receipt !== null) {
        if (snapshot.revision !== this.receipt.revision) {
          this.staleRevision = true;
          this.state.phase = 'stale';
          this.state.message = '本次保存已完成，但课表随后又有更新。草稿保留；请重新载入并核对最新课表。';
          this.receipt = null;
          this.operation = null;
          this.emit();
          return false;
        }
      } else if (!discardDraft && this.state.dirty) {
        this.staleRevision = snapshot.revision !== this.state.revision;
        this.state.phase = snapshot.revision === this.state.revision ? 'ready' : 'stale';
        this.state.message = snapshot.revision === this.state.revision ? '账号课表版本未变，当前未保存草稿已保留。'
          : '账号课表已有新版本，当前草稿已保留。请先核对并重新载入，再修改保存。';
        this.emit();
        return false;
      }
      const applied = this.receipt !== null;
      const checked = validateTimetableList(snapshot.entries, true);
      this.baseline = entriesCopy(checked.entries);
      this.state.entries = checked.entries;
      this.state.revision = snapshot.revision;
      // Provenance belongs to the accepted server baseline, never to an unsaved draft or a rejected newer version.
      this.state.evidence = Array.isArray(snapshot.evidence) ? JSON.parse(JSON.stringify(snapshot.evidence)) as DataEvidence[] : [];
      this.state.warnings = checked.warnings;
      this.editorPending = false;
      this.staleRevision = false;
      this.state.dirty = false;
      this.state.phase = applied ? 'saved' : 'ready';
      this.state.notice = applied ? '课表已更新。建议去计划核对已有任务与新课表的冲突。' : '已载入账号中的最新课表。';
      this.receipt = null;
      this.operation = null;
      this.emit();
      return true;
    } catch {
      if (this.current(generation)) {
        this.state.phase = this.receipt !== null ? 'applied' : this.staleRevision ? 'stale' : 'error';
        this.state.message = this.receipt === null ? '课表读取失败，现有草稿未改动。请检查连接后重试。'
          : '本次保存已有成功回执，但最新课表暂未读到；请读取核对后再继续修改。';
        this.emit();
      }
      return false;
    }
  }

  async save(confirmClear: boolean = false): Promise<void> {
    if (!this.canEdit() || this.staleRevision || this.editorPending) { return; }
    const checked = validateTimetableList(this.state.entries, true);
    if (!checked.valid) { this.state.message = checked.errors[0].message; this.emit(); return; }
    if (checked.entries.length === 0 && !confirmClear) {
      this.state.message = '清空会移除账号中的全部课程，请明确确认清空后再保存。'; this.emit(); return;
    }
    if (!this.state.dirty) { this.state.message = '课表没有未保存的修改。'; this.emit(); return; }
    const id = this.idFactory();
    if (!/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/.test(id)) {
      this.state.message = '无法生成本次保存标识，请稍后重试。'; this.emit(); return;
    }
    this.operation = { id: id, entries: entriesCopy(checked.entries), revision: this.state.revision, confirmClear: confirmClear };
    await this.submit();
  }

  private validReceipt(value: TimetableSaveReceipt, operation: TimetableOperation): boolean {
    return value !== null && typeof value === 'object' && value.operation_id === operation.id && value.status === 'applied' &&
      value.previous_revision === operation.revision && validRevision(value.revision) &&
      value.entry_count === operation.entries.length && typeof value.applied_at === 'string' &&
      Number.isFinite(Date.parse(value.applied_at));
  }

  private async acceptReceipt(receipt: TimetableSaveReceipt, operation: TimetableOperation): Promise<void> {
    if (!this.validReceipt(receipt, operation)) {
      this.state.phase = 'uncertain';
      this.state.message = '保存回执不完整，尚不能确认结果。请核对这笔操作，暂勿重复提交。';
      this.emit();
      return;
    }
    this.receipt = receipt;
    this.state.phase = 'applied';
    this.state.message = '';
    this.state.notice = '已收到保存回执，正在读取最新课表。';
    if (this.notifiedId !== operation.id) { this.notifiedId = operation.id; this.onApplied(); }
    this.emit();
    await this.refresh();
  }

  private async submit(): Promise<void> {
    if (this.operation === null || !this.active || this.disposed) { return; }
    const operation = this.operation;
    const generation = ++this.generation;
    this.state.phase = 'saving';
    this.state.message = '';
    this.emit();
    try {
      const receipt = await this.api.saveTimetable(entriesCopy(operation.entries), operation.revision, operation.id, operation.confirmClear);
      if (!this.current(generation)) { return; }
      await this.acceptReceipt(receipt, operation);
    } catch (error) {
      if (!this.current(generation)) { return; }
      if (error instanceof CampusFlowRequestError && error.code === 'TIMETABLE_STALE') {
        this.operation = null;
        this.staleRevision = true;
        this.state.phase = 'stale';
        this.state.message = '保存前课表已变化，本次未覆盖。草稿仍保留，请重新载入并核对最新版本。';
      } else if (error instanceof CampusFlowRequestError && (error.statusCode === 401 || error.statusCode === 422)) {
        this.operation = null;
        this.state.phase = 'error';
        this.state.message = error.statusCode === 401 ? '登录已失效，请重新登录后继续。当前草稿仅保留在本页。'
          : '课表未通过保存校验。请检查课程、重复项及清空确认；草稿已保留。';
      } else {
        this.state.phase = 'uncertain';
        this.state.message = '保存结果尚未确认，可能已经生效。请先核对这笔操作，暂勿再次保存。';
      }
      this.emit();
    }
  }

  async checkResult(): Promise<void> {
    if (this.disposed || !this.active || this.operation === null || !['uncertain', 'retryable'].includes(this.state.phase)) { return; }
    const operation = this.operation;
    const generation = ++this.generation;
    this.state.phase = 'checking';
    this.state.message = '';
    this.emit();
    try {
      const receipt = await this.api.timetableOperation(operation.id);
      if (!this.current(generation)) { return; }
      await this.acceptReceipt(receipt, operation);
    } catch (error) {
      if (!this.current(generation)) { return; }
      if (error instanceof CampusFlowRequestError && error.statusCode === 404 && error.code === 'TIMETABLE_OPERATION_NOT_FOUND') {
        this.state.phase = 'retryable';
        this.state.message = '暂未查到这笔保存记录。可再次核对，或使用相同标识与原课表重试；不会新建一笔操作。';
      } else {
        this.state.phase = 'uncertain';
        this.state.message = '暂时无法核对保存结果，原提交仍保留。请稍后再次核对。';
      }
      this.emit();
    }
  }

  async retrySameOperation(): Promise<void> {
    if (this.state.phase !== 'retryable' || this.operation === null || !this.active || this.disposed) { return; }
    await this.submit();
  }

  dispose(): void {
    this.disposed = true;
    this.active = false;
    this.generation++;
    this.operation = null;
    this.receipt = null;
    this.baseline = [];
    this.state.entries = [];
  }
}
