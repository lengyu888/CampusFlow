import { CourseAcknowledgement } from '../model/ApiModels';
import { validCourseAcknowledgements } from './CourseReview';
import { PendingAction, PlanningActionRequest, ConfirmActionResponse, PlanningTaskDraft } from '../model/ApiModels';
import { CampusFlowRequestError } from './AgentFeedback';
import { validReliableAction, validatedActionReceipt, sameActionCandidate, sameActionReceipt, decisionDisposition } from './ActionReliability';
import { formatPlanDateTime } from './PlanPresentation';

export interface PlanningActionGateway {
  previewPlanningAction(request: PlanningActionRequest): Promise<PendingAction>;
  confirmAction(id: string, acknowledgements?: CourseAcknowledgement[]): Promise<ConfirmActionResponse>;
  cancelAction(id: string): Promise<ConfirmActionResponse>;
  actionStatus(id: string): Promise<PendingAction>;
}

export interface PlanningActionState {
  phase: string;
  action: PendingAction | null;
  message: string;
}

// Unedited values retain their exact original timestamps (including seconds and offsets).
export function editedPlanningTime(text: string, original: string | null): string | null {
  const value = text.trim();
  if (original !== null && value === formatPlanDateTime(original)) { return original; }
  if (value.length === 0) { return null; }
  if (!/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$/.test(value)) { return 'invalid'; }
  const result = `${value.replace(' ', 'T')}:00+08:00`;
  return formatPlanDateTime(result) === value ? result : 'invalid';
}

export function validPlanningDate(value: string): boolean {
  return /^\d{4}-\d{2}-\d{2}$/.test(value) && Number.isFinite(Date.parse(`${value}T00:00:00Z`)) &&
    new Date(`${value}T00:00:00Z`).toISOString().substring(0, 10) === value;
}

// Historical campus timestamps without a zone are Shanghai wall time, never device-local time.
export function planningTimestamp(value: string): number {
  const text = value.trim();
  const dated = /^\d{4}-\d{2}-\d{2}$/.test(text) ? `${text}T00:00:00` : text;
  return Date.parse(/Z$|[+-]\d{2}:\d{2}$/.test(dated) ? dated : `${dated}+08:00`);
}

function sameTime(a: string | null, b: string | null): boolean {
  return a === b || (a !== null && b !== null && planningTimestamp(a) === planningTimestamp(b));
}

function sameTask(a: PlanningTaskDraft, b: PlanningTaskDraft): boolean {
  return a.title === b.title && sameTime(a.start_at, b.start_at) && sameTime(a.end_at, b.end_at) &&
    a.reminder_minutes === b.reminder_minutes && a.location === b.location &&
    (a.allow_during_course === undefined || a.allow_during_course === (b.allow_during_course ?? false));
}

function matchesRequest(request: PlanningActionRequest, action: PendingAction): boolean {
  const parts = request.operation.split('_');
  if (!validReliableAction(action) || action.status !== 'pending' || action.receipt !== null ||
    action.action !== parts[0] || action.kind !== parts[1]) { return false; }
  if ((request.task_id ?? null) !== action.target_task_id || (request.plan_id ?? null) !== action.target_plan_id) { return false; }
  if (request.task !== undefined && (action.payload.task === undefined || !sameTask(request.task, action.payload.task))) { return false; }
  if (request.plan !== undefined && (action.payload.plan === undefined || request.plan.title !== action.payload.plan.title ||
    request.plan.summary !== action.payload.plan.summary || request.plan.target_date !== action.payload.plan.target_date)) { return false; }
  return true;
}

// A single proposal owns its write until a matching server receipt or cancellation is observed.
// Reads never infer success from an updated list, a matching title, or a target ID.
export class PlanningActionController {
  private api: PlanningActionGateway;
  private onChange: (state: PlanningActionState) => void;
  private onApplied: (action: PendingAction) => void;
  private state: PlanningActionState = { phase: 'idle', action: null, message: '' };
  private active: boolean = true;
  private disposed: boolean = false;
  private revision: number = 0;
  private notifiedReceipts: string[] = [];
  private intent: string = '';

  constructor(api: PlanningActionGateway, onChange: (state: PlanningActionState) => void,
    onApplied: (action: PendingAction) => void) {
    this.api = api;
    this.onChange = onChange;
    this.onApplied = onApplied;
  }

  snapshot(): PlanningActionState { return JSON.parse(JSON.stringify(this.state)) as PlanningActionState; }
  private publish(): void { if (!this.disposed) { this.onChange(this.snapshot()); } }
  private current(revision: number): boolean { return !this.disposed && this.active && revision === this.revision; }
  private busy(): boolean { return ['previewing', 'confirming', 'cancelling', 'checking'].includes(this.state.phase); }
  blocksNewWrites(): boolean {
    return this.busy() || (this.state.action !== null && !['resolved', 'cancelled', 'invalidated'].includes(this.state.phase));
  }

  setActive(active: boolean): void {
    if (this.disposed || active === this.active) { return; }
    this.active = active;
    this.revision++;
    if (!active && ['confirming', 'cancelling', 'checking'].includes(this.state.phase)) {
      this.state.phase = 'uncertain';
      this.state.message = '这笔变更尚待核对，返回后请先查询结果。';
    } else if (!active && this.state.phase === 'previewing') {
      this.state = { phase: 'idle', action: null, message: '预览已中止，草稿保留；返回后可重新预览。' };
    }
    this.publish();
  }

  dispose(): void { this.disposed = true; this.active = false; this.revision++; }

  dismiss(): void {
    if (this.blocksNewWrites()) { return; }
    this.state = { phase: 'idle', action: null, message: '' };
    this.intent = '';
    this.publish();
  }

  async preview(request: PlanningActionRequest): Promise<void> {
    if (!this.active || this.disposed || this.blocksNewWrites()) { return; }
    const frozen = JSON.parse(JSON.stringify(request)) as PlanningActionRequest;
    const revision = ++this.revision;
    this.intent = '';
    this.state = { phase: 'previewing', action: null, message: '正在生成预览，尚未提交执行。' };
    this.publish();
    try {
      const action = await this.api.previewPlanningAction(frozen);
      if (!this.current(revision)) { return; }
      if (!matchesRequest(frozen, action)) { throw new Error('invalid preview'); }
      this.state = { phase: 'review', action: JSON.parse(JSON.stringify(action)) as PendingAction,
        message: '请核对完整前后内容，确认后才执行。' };
    } catch (error) {
      if (!this.current(revision)) { return; }
      this.state = { phase: 'error', action: null, message: '无法生成可核验的预览，请检查网络、输入与后端版本；草稿已保留。' };
    }
    if (this.current(revision)) { this.publish(); }
  }

  private accept(latest: PendingAction): void {
    const original = this.state.action;
    if (original === null || !validReliableAction(latest) || !sameActionCandidate(original, latest)) {
      throw new Error('mismatched action');
    }
    const disposition = decisionDisposition(latest);
    if (disposition === 'confirmed') {
      const receipt = validatedActionReceipt(latest);
      if (receipt === null) { throw new Error('unverified receipt'); }
      this.state = { phase: 'resolved', action: JSON.parse(JSON.stringify(latest)) as PendingAction, message: '已核对服务器执行回执。' };
      if (!this.notifiedReceipts.includes(receipt.receipt_id)) {
        this.notifiedReceipts.push(receipt.receipt_id);
        this.onApplied(JSON.parse(JSON.stringify(latest)) as PendingAction);
      }
    } else if (disposition === 'cancelled') {
      this.state = { phase: 'cancelled', action: latest, message: '提案已取消。' };
    } else if (['ready', 'conflict', 'expired'].includes(disposition)) {
      this.state = { phase: 'retryable', action: latest,
        message: '服务器仍记录为待处理。可继续核对，或明确重试同一笔操作；不会生成新的变更。' };
    } else { throw new Error('unverified status'); }
  }

  async confirm(acknowledgements: CourseAcknowledgement[] = []): Promise<void> {
    const action = this.state.action;
    if (!this.active || this.disposed || action === null || !['review', 'retryable'].includes(this.state.phase) ||
      (this.intent.length > 0 && this.intent !== 'confirm')) { return; }
    if (decisionDisposition(action) !== 'ready') {
      this.state.message = '这份预览存在冲突或已过期。请取消本提案，再根据保留的草稿重新预览。';
      this.publish(); return;
    }
    if (!validCourseAcknowledgements(action, acknowledgements)) {
      this.state.message = '请先核对每项任务与课程重叠的时段，并明确选择仍这样安排。';
      this.publish(); return;
    }
    await this.write('confirm', acknowledgements);
  }

  async cancel(): Promise<void> {
    if (!this.active || this.disposed || this.state.action === null || !['review', 'retryable'].includes(this.state.phase)) { return; }
    await this.write('cancel');
  }

  private async write(intent: string, acknowledgements: CourseAcknowledgement[] = []): Promise<void> {
    const action = this.state.action;
    if (action === null) { return; }
    const revision = ++this.revision;
    this.intent = intent;
    this.state.phase = intent === 'confirm' ? 'confirming' : 'cancelling';
    this.state.message = intent === 'confirm' ? '正在确认，请勿重复提交。' : '正在取消提案。';
    this.publish();
    try {
      const response = intent === 'confirm' ? await this.api.confirmAction(action.proposal_id, acknowledgements) :
        await this.api.cancelAction(action.proposal_id);
      if (!this.current(revision)) { return; }
      const latest = response.action;
      if (latest === null || typeof latest !== 'object' ||
        (intent === 'confirm' && (response.applied !== true || latest.status !== 'confirmed' || validatedActionReceipt(latest) === null)) ||
        (intent === 'cancel' && (response.applied !== false || latest.status !== 'cancelled' || response.receipt !== null)) ||
        !sameActionReceipt(latest.receipt, response.receipt)) { throw new Error('invalid response envelope'); }
      this.accept(latest);
      if (this.state.phase === 'retryable') { throw new Error('write response remains pending'); }
    } catch (error) {
      if (!this.current(revision)) { return; }
      if (intent === 'confirm' && error instanceof CampusFlowRequestError &&
        ['ACTION_STALE', 'ACTION_EXPIRED', 'ACTION_CONFLICT', 'ACTION_INVALID', 'COURSE_PERMISSION_PREVIEW_REQUIRED', 'COURSE_ACK_STALE', 'COURSE_ACK_INVALID'].includes(error.code)) {
        this.state.phase = 'invalidated';
        this.state.message = '服务器拒绝了这份过期、冲突或已变化的候选。本次未执行；保留草稿，返回调整后重新预览。';
      } else {
        this.state.phase = 'uncertain';
        this.state.message = '尚未收到可核验的结果，请先查询本次状态；新的写操作已暂停。';
      }
    }
    if (this.current(revision)) { this.publish(); }
  }

  // A saved ID grants read access only. The full authenticated candidate is shown again;
  // this method never confirms, cancels, or creates a replacement proposal.
  async recover(proposalId: string): Promise<void> {
    if (!this.active || this.disposed || this.busy() || proposalId.length === 0) { return; }
    const revision = ++this.revision;
    this.state = { phase: 'checking', action: null, message: '正在查询上次提交的原提案…' };
    this.intent = '';
    this.publish();
    try {
      const latest = await this.api.actionStatus(proposalId);
      if (!this.current(revision)) { return; }
      if (!validReliableAction(latest) || latest.proposal_id !== proposalId) { throw new Error('mismatched recovery'); }
      this.state.action = JSON.parse(JSON.stringify(latest)) as PendingAction;
      this.accept(latest);
      if (this.state.phase === 'retryable') {
        this.state.message = '原提案仍待处理，请重新核对下方完整内容。仅在明确确认后执行同一提案。';
      }
    } catch {
      if (!this.current(revision)) { return; }
      this.state = { phase: 'uncertain', action: null,
        message: '未查到可核验的原提案，保留提交编号。请稍后再查，不另建重复安排。' };
    }
    if (this.current(revision)) { this.publish(); }
  }

  async check(): Promise<void> {
    const action = this.state.action;
    if (!this.active || this.disposed || action === null || !['uncertain', 'retryable'].includes(this.state.phase)) { return; }
    const revision = ++this.revision;
    this.state.phase = 'checking'; this.state.message = '正在核对同一笔变更的回执…'; this.publish();
    try {
      const latest = await this.api.actionStatus(action.proposal_id);
      if (!this.current(revision)) { return; }
      this.accept(latest);
    } catch (error) {
      if (!this.current(revision)) { return; }
      this.state.phase = 'uncertain';
      this.state.message = '仍无法核对结果。请检查网络或重新登录同一账号后核对；请勿另建重复操作。';
    }
    if (this.current(revision)) { this.publish(); }
  }

  retryIntent(): string { return this.state.phase === 'retryable' ? this.intent : ''; }
}
