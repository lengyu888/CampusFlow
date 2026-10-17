import { PlanningConflictReport, ReplanPreview, ReplanUnresolved, ReplanChange, PlanningCourseConflict, TimetableEntry } from '../model/ApiModels';
import { CampusFlowRequestError } from './AgentFeedback';
import { validateTimetableEntry } from './OnboardingTimetable';

export interface ReplanGateway {
  planningConflicts(): Promise<PlanningConflictReport>;
  previewReplan(): Promise<ReplanPreview>;
  replanStatus(id: string): Promise<ReplanPreview>;
  confirmReplan(id: string): Promise<ReplanPreview>;
}

export interface ReplanViewState {
  phase: string;
  report: PlanningConflictReport | null;
  preview: ReplanPreview | null;
  message: string;
  notice: string;
}

function text(value: string): boolean {
  return typeof value === 'string' && value.trim().length > 0;
}

function stamp(value: string): boolean {
  return text(value) && new RegExp('(Z|[+-][0-9]{2}:[0-9]{2})$').test(value) && Number.isFinite(Date.parse(value));
}

function validUnresolved(items: ReplanUnresolved[]): boolean {
  return Array.isArray(items) && items.every((item: ReplanUnresolved) => item !== null &&
    typeof item === 'object' && text(item.task_id) && text(item.title) && text(item.reason));
}

export function validConflictReport(data: PlanningConflictReport): boolean {
  return data !== null && typeof data === 'object' && stamp(data.checked_at) && text(data.policy) &&
    validUnresolved(data.unchecked) && Array.isArray(data.conflicts) &&
    data.conflicts.every((item: PlanningCourseConflict) => item !== null && typeof item === 'object' &&
      text(item.task_id) && text(item.title) && stamp(item.start_at) && stamp(item.end_at) &&
      Date.parse(item.end_at) > Date.parse(item.start_at) && Array.isArray(item.courses) && item.courses.length > 0 &&
      item.courses.every((course: TimetableEntry) => validateTimetableEntry(course).valid &&
        typeof course.location === 'string' && typeof course.teacher === 'string'));
}

export function validReplanPreview(data: ReplanPreview): boolean {
  if (data === null || typeof data !== 'object' || !text(data.replan_id) ||
    !['pending', 'confirmed'].includes(data.status) || !stamp(data.created_at) || !stamp(data.expires_at) ||
    Date.parse(data.expires_at) <= Date.parse(data.created_at) || !text(data.policy) ||
    !Array.isArray(data.changes) || !validUnresolved(data.unresolved)) { return false; }
  const ids: string[] = [];
  for (const item of data.changes) {
    if (item === null || typeof item !== 'object' || !text(item.task_id) || !text(item.title) ||
      ids.includes(item.task_id) || !stamp(item.old_start_at) || !stamp(item.old_end_at) ||
      !stamp(item.new_start_at) || !stamp(item.new_end_at)) { return false; }
    const duration = Date.parse(item.old_end_at) - Date.parse(item.old_start_at);
    if (duration <= 0 || Date.parse(item.new_end_at) - Date.parse(item.new_start_at) !== duration ||
      Date.parse(item.new_start_at) < Date.parse(item.old_start_at)) { return false; }
    ids.push(item.task_id);
  }
  return true;
}

function sameCandidate(a: ReplanPreview, b: ReplanPreview): boolean {
  if (a.replan_id !== b.replan_id || a.changes.length !== b.changes.length) { return false; }
  return a.changes.every((item: ReplanChange, index: number) => {
    const other = b.changes[index];
    return item.task_id === other.task_id && item.title === other.title && item.old_start_at === other.old_start_at &&
      item.old_end_at === other.old_end_at && item.new_start_at === other.new_start_at && item.new_end_at === other.new_end_at;
  });
}

// Coordinates only this user-visible operation. It never sends an Agent prompt,
// confirms automatically or retries a write after an ambiguous network failure.
export class PlanningReplanController {
  private api: ReplanGateway;
  private onChange: (state: ReplanViewState) => void;
  private onApplied: () => void;
  private now: () => number;
  private active: boolean = false;
  private disposed: boolean = false;
  private revision: number = 0;
  private state: ReplanViewState = { phase: 'idle', report: null, preview: null, message: '', notice: '' };

  constructor(api: ReplanGateway, onChange: (state: ReplanViewState) => void, onApplied: () => void,
    now: () => number = () => Date.now()) {
    this.api = api;
    this.onChange = onChange;
    this.onApplied = onApplied;
    this.now = now;
  }

  snapshot(): ReplanViewState {
    return JSON.parse(JSON.stringify(this.state)) as ReplanViewState;
  }

  private publish(): void {
    if (!this.disposed) { this.onChange(this.snapshot()); }
  }

  private current(revision: number): boolean {
    return !this.disposed && this.active && revision === this.revision;
  }

  private unresolvedWrite(): boolean {
    return ['confirming', 'uncertain', 'checking'].includes(this.state.phase);
  }

  setActive(active: boolean): void {
    if (this.disposed || this.active === active) { return; }
    this.active = active;
    this.revision++;
    if (!active) {
      if (this.unresolvedWrite()) {
        this.state.phase = 'uncertain';
        this.state.message = '改期结果尚待核对，返回后请先查询结果。';
      } else {
        this.state.phase = 'idle';
        this.state.preview = null;
        this.state.report = null;
        this.state.message = '';
      }
      this.publish();
      return;
    }
    if (this.state.phase === 'uncertain') { this.publish(); }
    else { this.refresh(); }
  }

  dispose(): void {
    this.disposed = true;
    this.active = false;
    this.revision++;
    this.state = { phase: 'idle', report: null, preview: null, message: '', notice: '' };
  }

  private failure(error: Error): string {
    if (error instanceof CampusFlowRequestError) {
      if (error.statusCode === 401 || error.statusCode === 403) { return '当前登录或权限已失效，请重新登录后核对规划。'; }
      if (error.statusCode === 404) { return '未找到改期功能或该方案，请核对后端版本并刷新规划。'; }
      if (error.statusCode === 409) { return '课表或任务已变化，这份方案已失效，请重新生成预览。'; }
      if (error.statusCode === 410) { return '这份方案已过期，请重新生成预览。'; }
      if (error.statusCode === 422) { return '方案暂不能执行，请重新核对课程与任务时间。'; }
    }
    return '暂时无法核对规划，请检查网络和服务后重试。';
  }

  async refresh(): Promise<void> {
    if (!this.active || this.disposed || this.unresolvedWrite()) { return; }
    const revision = ++this.revision;
    this.state.phase = 'loading';
    this.state.report = null;
    this.state.preview = null;
    this.state.message = '';
    this.publish();
    try {
      const report = await this.api.planningConflicts();
      if (!this.current(revision)) { return; }
      if (!validConflictReport(report)) { throw new Error('invalid report'); }
      this.state.report = JSON.parse(JSON.stringify(report)) as PlanningConflictReport;
      this.state.phase = 'idle';
    } catch (error) {
      if (!this.current(revision)) { return; }
      this.state.phase = 'error';
      this.state.message = this.failure(error);
    }
    if (this.current(revision)) { this.publish(); }
  }

  async preview(): Promise<void> {
    if (!this.active || this.disposed || ['loading', 'previewing'].includes(this.state.phase) || this.unresolvedWrite()) { return; }
    const revision = ++this.revision;
    this.state.phase = 'previewing';
    this.state.preview = null;
    this.state.message = '';
    this.state.notice = '正在寻找空档，原任务时间尚未改动。';
    this.publish();
    try {
      const candidate = await this.api.previewReplan();
      if (!this.current(revision)) { return; }
      if (!validReplanPreview(candidate) || candidate.status !== 'pending') { throw new Error('invalid preview'); }
      this.state.preview = JSON.parse(JSON.stringify(candidate)) as ReplanPreview;
      this.state.phase = 'review';
      this.state.notice = candidate.changes.length === 0 ? '没有可自动改期的任务，请查看下方原因；原安排保持不变。'
        : '请核对改期前后的时间，确认后才会调整原任务。';
    } catch (error) {
      if (!this.current(revision)) { return; }
      this.state.phase = 'error';
      this.state.message = this.failure(error);
      this.state.notice = '';
    }
    if (this.current(revision)) { this.publish(); }
  }

  dismiss(): void {
    if (!this.active || this.disposed || this.unresolvedWrite()) { return; }
    this.revision++;
    this.state.preview = null;
    this.state.phase = 'idle';
    this.state.message = '';
    this.state.notice = '已放弃本次预览，原任务时间未改动。';
    this.publish();
  }

  private expired(candidate: ReplanPreview): boolean {
    return Date.parse(candidate.expires_at) <= this.now() ||
      candidate.changes.some((change: ReplanChange) => Date.parse(change.old_start_at) <= this.now() ||
        Date.parse(change.new_start_at) <= this.now());
  }

  private accepted(result: ReplanPreview): void {
    this.state.preview = result;
    this.state.phase = 'applied';
    this.state.report = null;
    this.state.message = '';
    this.state.notice = `已调整 ${result.changes.length} 项原任务的时间，计划归属与完成记录保留。`;
    this.publish();
    this.onApplied();
  }

  async confirm(): Promise<void> {
    const candidate = this.state.preview;
    if (!this.active || this.disposed || this.state.phase !== 'review' || candidate === null || candidate.changes.length === 0) { return; }
    if (this.expired(candidate)) {
      this.state.phase = 'stale';
      this.state.message = '方案已过期，或原任务/建议时段已开始，请重新生成预览。';
      this.publish();
      return;
    }
    const revision = ++this.revision;
    this.state.phase = 'confirming';
    this.state.message = '';
    this.publish();
    try {
      const result = await this.api.confirmReplan(candidate.replan_id);
      if (!this.current(revision)) { return; }
      if (!validReplanPreview(result) || !sameCandidate(candidate, result) || result.status !== 'confirmed') {
        throw new Error('unverified receipt');
      }
      this.accepted(result);
    } catch (error) {
      if (!this.current(revision)) { return; }
      const rejected = error instanceof CampusFlowRequestError && [401, 403, 404, 409, 410, 422].includes(error.statusCode);
      this.state.phase = rejected ? 'stale' : 'uncertain';
      this.state.message = rejected ? this.failure(error) : '未收到明确的改期结果，请先查询结果。不会自动重复提交。';
      this.publish();
    }
  }

  async checkResult(): Promise<void> {
    const candidate = this.state.preview;
    if (!this.active || this.disposed || this.state.phase !== 'uncertain' || candidate === null) { return; }
    const revision = ++this.revision;
    this.state.phase = 'checking';
    this.state.message = '';
    this.publish();
    try {
      const result = await this.api.replanStatus(candidate.replan_id);
      if (!this.current(revision)) { return; }
      if (!validReplanPreview(result) || !sameCandidate(candidate, result)) { throw new Error('invalid status'); }
      if (result.status === 'confirmed') { this.accepted(result); return; }
      this.state.phase = this.expired(result) ? 'stale' : 'review';
      this.state.preview = result;
      this.state.message = this.state.phase === 'stale' ? '方案已过期，请重新生成预览。' : '';
      this.state.notice = '查询结果：本方案尚未执行。请重新核对后再决定是否确认。';
    } catch (error) {
      if (!this.current(revision)) { return; }
      if (error instanceof CampusFlowRequestError && [404, 410].includes(error.statusCode)) {
        this.state.phase = 'stale';
        this.state.message = '已无法查询该方案。请刷新规划核对实际任务，再决定是否生成新方案。';
      } else {
        this.state.phase = 'uncertain';
        this.state.message = '仍未能查询改期结果，请恢复连接后再查询；暂不发起新的改期。';
      }
    }
    if (this.current(revision)) { this.publish(); }
  }
}
