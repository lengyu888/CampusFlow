import { LearningPreferenceValues, LearningPreferenceSnapshot, LearningPreferenceWrite, LearningPreferenceDelete } from '../model/ApiModels';
import { CampusFlowRequestError } from './AgentFeedback';

export interface PreferenceDraft { enabled: boolean; session: string; rest: string; period: string; daily: string; }
export interface PreferenceIssue { field: string; message: string; }
export interface PreferenceState {
  phase: string; snapshot: LearningPreferenceSnapshot | null; draft: PreferenceDraft; dirty: boolean;
  message: string; issues: PreferenceIssue[]; confirmClear: boolean; canRetry: boolean;
}
export interface PreferenceGateway {
  learningPreferences(): Promise<LearningPreferenceSnapshot>;
  saveLearningPreferences(value: LearningPreferenceWrite): Promise<LearningPreferenceSnapshot>;
  clearLearningPreferences(value: LearningPreferenceDelete): Promise<LearningPreferenceSnapshot>;
}
interface PreferenceOperation { kind: string; payload: LearningPreferenceWrite; }
export function defaultPreferenceDraft(): PreferenceDraft { return { enabled: false, session: '50', rest: '10', period: 'any', daily: '120' }; }
export function copyPreferenceDraft(value: PreferenceDraft): PreferenceDraft {
  return { enabled: value.enabled, session: value.session, rest: value.rest, period: value.period, daily: value.daily };
}
function copyPreferenceSnapshot(value: LearningPreferenceSnapshot): LearningPreferenceSnapshot {
  return { revision: value.revision, updated_at: value.updated_at, enabled: value.enabled,
    session_minutes: value.session_minutes, break_minutes: value.break_minutes,
    preferred_period: value.preferred_period, daily_minutes: value.daily_minutes };
}
function copyPreferenceWrite(value: LearningPreferenceWrite): LearningPreferenceWrite {
  return { base_revision: value.base_revision, operation_id: value.operation_id, enabled: value.enabled,
    session_minutes: value.session_minutes, break_minutes: value.break_minutes,
    preferred_period: value.preferred_period, daily_minutes: value.daily_minutes };
}
export function preferenceIssues(draft: PreferenceDraft): PreferenceIssue[] {
  const issues: PreferenceIssue[] = [];
  if (typeof draft.enabled !== 'boolean') { issues.push({ field: 'enabled', message: '请选择是否启用学习偏好。' }); }
  if (!/^\d{1,3}$/.test(draft.session) || Number(draft.session) < 15 || Number(draft.session) > 120) { issues.push({ field: 'session', message: '单次学习为 15–120 分钟的整数。' }); }
  if (!/^\d{1,2}$/.test(draft.rest) || Number(draft.rest) > 30) { issues.push({ field: 'rest', message: '休息为 0–30 分钟的整数。' }); }
  if (!['any', 'morning', 'afternoon', 'evening'].includes(draft.period)) { issues.push({ field: 'period', message: '请选择有效的偏好时段。' }); }
  if (!/^\d{1,3}$/.test(draft.daily) || Number(draft.daily) < 30 || Number(draft.daily) > 480) { issues.push({ field: 'daily', message: '每日学习为 30–480 分钟的整数。' }); }
  return issues;
}
export function validPreferenceSnapshot(value: LearningPreferenceSnapshot): boolean {
  return value !== null && typeof value === 'object' && Number.isSafeInteger(value.revision) && value.revision >= 0 &&
    typeof value.enabled === 'boolean' && Number.isInteger(value.session_minutes) && value.session_minutes >= 15 && value.session_minutes <= 120 &&
    Number.isInteger(value.break_minutes) && value.break_minutes >= 0 && value.break_minutes <= 30 &&
    ['any', 'morning', 'afternoon', 'evening'].includes(value.preferred_period) &&
    Number.isInteger(value.daily_minutes) && value.daily_minutes >= 30 && value.daily_minutes <= 480 &&
    (value.updated_at === null && value.revision === 0 || typeof value.updated_at === 'string' &&
      /^\d{4}-\d{2}-\d{2}T/.test(value.updated_at) && Number.isFinite(Date.parse(value.updated_at)));
}
function draftFrom(value: LearningPreferenceValues): PreferenceDraft {
  return { enabled: value.enabled, session: String(value.session_minutes), rest: String(value.break_minutes), period: value.preferred_period, daily: String(value.daily_minutes) };
}
function sameDraft(a: PreferenceDraft, b: PreferenceDraft): boolean {
  return a.enabled === b.enabled && a.session === b.session && a.rest === b.rest && a.period === b.period && a.daily === b.daily;
}
export function preferenceOperationId(): string {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (character: string) => {
    const random = Math.floor(Math.random() * 16); return (character === 'x' ? random : (random & 3) | 8).toString(16);
  });
}
export class LearningPreferencesController {
  private api: PreferenceGateway;
  private notify: (state: PreferenceState) => void;
  private idFactory: () => string;
  private state: PreferenceState = { phase: 'idle', snapshot: null, draft: defaultPreferenceDraft(), dirty: false, message: '', issues: [], confirmClear: false, canRetry: false };
  private operation: PreferenceOperation | null = null;
  private generation: number = 0;
  private request: number = 0;
  private scope: string = '';
  private active: boolean = false;
  private disposed: boolean = false;
  private writing: boolean = false;
  constructor(api: PreferenceGateway, onChange: (state: PreferenceState) => void, idFactory: () => string = preferenceOperationId) {
    this.api = api; this.notify = onChange; this.idFactory = idFactory;
  }
  snapshot(): PreferenceState {
    return { phase: this.state.phase, snapshot: this.state.snapshot === null ? null : copyPreferenceSnapshot(this.state.snapshot),
      draft: copyPreferenceDraft(this.state.draft), dirty: this.state.dirty, message: this.state.message,
      issues: this.state.issues.map((item: PreferenceIssue): PreferenceIssue => ({ field: item.field, message: item.message })),
      confirmClear: this.state.confirmClear, canRetry: this.state.canRetry };
  }
  private publish(): void { this.state.canRetry = this.operation !== null && !this.writing; if (!this.disposed) { this.notify(this.snapshot()); } }
  configure(scope: string, api: PreferenceGateway): void {
    if (this.disposed) { return; }
    if (scope === this.scope) { this.api = api; return; }
    this.generation++; this.request++; this.scope = scope; this.api = api; this.operation = null; this.writing = false;
    this.state = { phase: 'idle', snapshot: null, draft: defaultPreferenceDraft(), dirty: false, message: '', issues: [], confirmClear: false, canRetry: false };
    this.publish(); if (this.active) { this.load(); }
  }
  setActive(active: boolean): void {
    this.active = active; this.request++;
    if (!active) {
      if (this.operation !== null) { this.state.phase = 'unknown'; this.state.message = this.writing ? '原请求仍在等待，完成或超时后可核对；操作标识和内容已保留。' : '本次操作结果尚待核对，原操作标识和内容已保留。'; }
      else if (this.state.phase === 'loading') { this.state.phase = 'idle'; }
      this.publish();
    } else if (this.state.snapshot === null && this.operation === null) { this.load(); }
  }
  editable(): boolean { return !this.disposed && this.active && this.operation === null && !this.writing && this.state.snapshot !== null && !['loading', 'stale'].includes(this.state.phase); }
  edit(draft: PreferenceDraft): void {
    if (!this.editable()) { return; }
    this.state.draft = copyPreferenceDraft(draft); this.state.issues = []; this.state.confirmClear = false;
    this.state.dirty = !sameDraft(draft, draftFrom(this.state.snapshot as LearningPreferenceSnapshot));
    this.state.phase = 'editing'; this.state.message = ''; this.publish();
  }
  async load(discard: boolean = false): Promise<void> {
    if (this.disposed || !this.active || this.writing || this.state.phase === 'loading') { return; }
    const previousPhase = this.state.phase;
    const revision = ++this.request; const generation = this.generation; const keep = this.state.dirty && !discard || this.operation !== null;
    this.state.phase = 'loading'; this.state.message = '正在读取当前学习偏好。'; this.publish();
    try {
      const result = await this.api.learningPreferences();
      if (!this.current(revision, generation)) { return; }
      if (!validPreferenceSnapshot(result)) { throw new Error('INVALID_PREFERENCES'); }
      this.state.snapshot = copyPreferenceSnapshot(result);
      if (!keep) { this.state.draft = draftFrom(result); }
      this.state.dirty = !sameDraft(this.state.draft, draftFrom(result));
      this.state.phase = this.operation === null ? 'editing' : 'unknown';
      this.state.message = this.operation !== null ? '已读到当前值，但不能据此证明原操作的结果。可使用原标识和原内容重试核对，服务不会重复执行。' :
        this.state.dirty ? '已读到最新值，未保存草稿仍保留；请对照当前值后决定是否保存。' : '已读取当前学习偏好。';
      this.state.confirmClear = false;
    } catch {
      if (this.current(revision, generation)) { this.state.phase = this.operation === null ? previousPhase === 'stale' ? 'stale' : 'error' : 'unknown'; this.state.message = '学习偏好读取未完成，当前草稿未改变，请检查连接后重试。'; }
    } finally { if (this.current(revision, generation)) { this.publish(); } }
  }
  askClear(): void { if (this.editable()) { this.state.confirmClear = true; this.publish(); } }
  cancelClear(): void { this.state.confirmClear = false; this.publish(); }
  async save(): Promise<void> {
    if (!this.editable() || !this.state.dirty) { return; }
    this.state.issues = preferenceIssues(this.state.draft);
    if (this.state.issues.length > 0) { this.publish(); return; }
    this.begin('save'); await this.execute();
  }
  async clear(): Promise<void> { if (!this.editable() || !this.state.confirmClear) { return; } this.begin('clear'); await this.execute(); }
  async retry(): Promise<void> { if (this.active && this.operation !== null && !this.writing) { await this.execute(); } }
  private begin(kind: string): void {
    const draft = this.state.draft; const snapshot = this.state.snapshot as LearningPreferenceSnapshot;
    this.operation = { kind: kind, payload: { base_revision: snapshot.revision, operation_id: this.idFactory(), enabled: draft.enabled,
      session_minutes: Number(draft.session), break_minutes: Number(draft.rest), preferred_period: draft.period, daily_minutes: Number(draft.daily) } };
    this.state.confirmClear = false;
  }
  private current(request: number, generation: number): boolean { return !this.disposed && this.active && request === this.request && generation === this.generation; }
  private async execute(): Promise<void> {
    if (this.operation === null || this.writing || this.disposed || !this.active) { return; }
    const operation = this.operation; const request = ++this.request; const generation = this.generation;
    this.writing = true; this.state.phase = 'saving'; this.state.message = operation.kind === 'clear' ? '正在清除学习偏好。' : '正在保存学习偏好。'; this.publish();
    try {
      const result = operation.kind === 'clear' ? await this.api.clearLearningPreferences({ base_revision: operation.payload.base_revision, operation_id: operation.payload.operation_id }) :
        await this.api.saveLearningPreferences(copyPreferenceWrite(operation.payload));
      if (!this.current(request, generation)) { return; }
      if (!validPreferenceSnapshot(result) || result.revision <= operation.payload.base_revision) { throw new Error('INVALID_PREFERENCE_RECEIPT'); }
      const expected = operation.kind === 'clear' ? defaultPreferenceDraft() : draftFrom(operation.payload);
      const matches = sameDraft(expected, draftFrom(result));
      this.state.snapshot = copyPreferenceSnapshot(result); this.operation = null;
      if (matches) { this.state.draft = draftFrom(result); this.state.issues = []; }
      this.state.dirty = !sameDraft(this.state.draft, draftFrom(result)); this.state.phase = 'applied';
      this.state.message = matches ? operation.kind === 'clear' ? '当前偏好已清除并停用。只影响后续请求；已开始的运行和历史记录不会撤回。' :
        '已核对保存后的学习偏好，从下一次请求生效。' : '原操作已核对，但偏好随后已有其他修改。下方显示当前值，原草稿仍保留，请重新比较。';
    } catch (error) {
      if (!this.current(request, generation)) { return; }
      const known = error instanceof CampusFlowRequestError;
      if (known && ['PREFERENCES_CHANGED', 'OPERATION_ID_REUSED', 'OPERATION_RETIRED'].includes(error.code)) {
        this.operation = null; this.state.phase = 'stale'; this.state.message = `${error.message} 读取最新值不会丢弃草稿。`;
      } else if (known && [400, 401, 403, 422].includes(error.statusCode)) {
        this.operation = null; this.state.phase = 'error'; this.state.message = '本次内容未被接受，请检查登录与输入。草稿仍保留。';
      } else {
        this.state.phase = 'unknown'; this.state.message = '未能确认本次操作结果。只能核对当前值或使用原标识和原内容重试，暂不创建新操作。';
      }
    } finally {
      if (generation === this.generation) { this.writing = false; if (!this.disposed) { this.publish(); } }
    }
  }
  dispose(): void { this.disposed = true; this.generation++; this.request++; this.operation = null; }
}
