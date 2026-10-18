import { PlanningOverview } from '../model/ApiModels';
import { PlatformReminderItem } from '../model/PlatformServiceTypes';

export type ReminderItem = PlatformReminderItem;
export interface ReminderStatus { permission: string; scope: string; scheduled: number; mode: string; limited: boolean; cleanup_required?: boolean; }
export interface ReminderDriver {
  status(): Promise<ReminderStatus>;
  authorize(scope: string): Promise<ReminderStatus>;
  replace(scope: string, items: ReminderItem[]): Promise<ReminderStatus>;
  clear(scope: string): Promise<ReminderStatus>;
  dispose(): void;
}
export interface ReminderState {
  phase: string; message: string; scheduled: number; skipped: number; limited: boolean; enabled: boolean;
}
export interface ReminderPlan { items: ReminderItem[]; skipped: number; limited: boolean; }

function timestamp(value: string): number {
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?(Z|[+-]\d{2}:\d{2})$/.test(value)) { return NaN; }
  const y = Number(value.substring(0, 4)); const m = Number(value.substring(5, 7)); const d = Number(value.substring(8, 10));
  const days = [31, y % 4 === 0 && (y % 100 !== 0 || y % 400 === 0) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  if (y < 1 || m < 1 || m > 12 || d < 1 || d > days[m - 1] || Number(value.substring(11, 13)) > 23 ||
    Number(value.substring(14, 16)) > 59 || Number(value.substring(17, 19)) > 59) { return NaN; }
  return Date.parse(value);
}

export function buildReminderPlan(value: PlanningOverview, now: number): ReminderPlan {
  if (value === null || typeof value !== 'object' || !Array.isArray(value.tasks) ||
    !Number.isInteger(value.total_tasks) || value.total_tasks !== value.tasks.length || value.tasks.length > 20000 || !Number.isFinite(now)) {
    throw new Error('INCOMPLETE_TASK_SNAPSHOT');
  }
  const ids = new Set<string>(); const items: ReminderItem[] = []; let skipped = 0;
  for (const task of value.tasks) {
    if (task === null || typeof task !== 'object' || typeof task.task_id !== 'string' ||
      !/^[A-Za-z0-9._-]{1,170}$/.test(task.task_id) || ids.has(task.task_id) || !['pending', 'completed'].includes(task.status) ||
      !(task.start_at === null || typeof task.start_at === 'string') ||
      !(task.reminder_minutes === null || Number.isInteger(task.reminder_minutes) && task.reminder_minutes >= 0 && task.reminder_minutes <= 10080)) {
      throw new Error('INVALID_TASK_SNAPSHOT');
    }
    ids.add(task.task_id);
    if (task.status === 'completed') { continue; }
    if (task.start_at === null || task.reminder_minutes === null) { skipped++; continue; }
    if (/^\d{4}-\d{2}-\d{2}$/.test(task.start_at) && Number.isFinite(timestamp(`${task.start_at}T00:00:00Z`))) { skipped++; continue; }
    const start = timestamp(task.start_at);
    if (!Number.isFinite(start)) { throw new Error('INVALID_TASK_TIME'); }
    if (task.source === 'manual' && task.end_at === null && new Date(start + 8 * 3600000).toISOString().substring(11, 16) === '23:59') { skipped++; continue; }
    const fire = start - task.reminder_minutes * 60000;
    if (fire <= now || fire > now + 366 * 86400000) { skipped++; continue; }
    items.push({ id: `cf_${task.task_id}`, fire_at_ms: fire });
  }
  items.sort((a: ReminderItem, b: ReminderItem) => a.fire_at_ms - b.fire_at_ms || a.id.localeCompare(b.id));
  return { items: items.slice(0, 60), skipped: skipped, limited: items.length > 60 };
}

export function validReminderStatus(value: ReminderStatus): boolean {
  return value !== null && typeof value === 'object' && ['granted', 'denied', 'unknown', 'unsupported'].includes(value.permission) &&
    typeof value.scope === 'string' && value.scope.length <= 512 && Number.isInteger(value.scheduled) && value.scheduled >= 0 && value.scheduled <= 60 &&
    ['system', 'inexact'].includes(value.mode) && typeof value.limited === 'boolean' &&
    (value.cleanup_required === undefined || typeof value.cleanup_required === 'boolean') && (!value.cleanup_required || value.scope.length > 0);
}

// One queue owns all native writes. A late read never overwrites a newer task mutation or login.
export class ReminderCoordinator {
  private driver: ReminderDriver;
  private notify: (state: ReminderState) => void;
  private clock: () => number;
  private scope: string = '';
  private loader: (() => Promise<PlanningOverview>) | null = null;
  private revision: number = 0;
  private refreshRevision: number = 0;
  private active: boolean = true;
  private disposed: boolean = false;
  private enabled: boolean = false;
  private queue: Promise<void> = Promise.resolve();
  private current: ReminderState = { phase: 'disabled', message: '本机系统提醒尚未启用。', scheduled: 0, skipped: 0, limited: false, enabled: false };

  constructor(driver: ReminderDriver, onChange: (state: ReminderState) => void, clock: () => number = Date.now) {
    this.driver = driver; this.notify = onChange; this.clock = clock;
  }
  private publish(phase: string, message: string, scheduled: number = this.current.scheduled,
    skipped: number = this.current.skipped, limited: boolean = this.current.limited): void {
    this.current = { phase: phase, message: message, scheduled: scheduled, skipped: skipped, limited: limited, enabled: this.enabled };
    if (!this.disposed) {
      const snapshot: ReminderState = { phase: this.current.phase, message: this.current.message,
        scheduled: this.current.scheduled, skipped: this.current.skipped, limited: this.current.limited, enabled: this.current.enabled };
      this.notify(snapshot);
    }
  }
  private live(revision: number): boolean { return !this.disposed && revision === this.revision; }
  private run(work: () => Promise<void>): Promise<void> {
    const next = this.queue.then(work);
    this.queue = next.catch(() => {});
    return next;
  }
  configure(scope: string, load: () => Promise<PlanningOverview>): void {
    if (this.disposed || !scope || scope.length > 512) { return; }
    this.scope = scope; this.loader = load; this.enabled = false;
    const revision = ++this.revision; this.refreshRevision++;
    this.publish('checking', '正在核对本机提醒权限与账号。', 0, 0, false);
    this.run(async () => {
      if (!this.live(revision)) { return; }
      try {
        const status = await this.driver.status();
        if (!this.live(revision)) { return; }
        if (!validReminderStatus(status)) { throw new Error('INVALID_STATUS'); }
        if (status.scope && (status.scope !== scope || status.cleanup_required === true)) {
          const cleared = await this.driver.clear(status.scope);
          if (!validReminderStatus(cleared) || cleared.scope || cleared.scheduled !== 0 || cleared.cleanup_required === true) { throw new Error('CLEANUP_FAILED'); }
          if (!this.live(revision)) { return; }
          this.publish('disabled', status.cleanup_required === true ? '未完成的提醒已清理；可重新启用本机提醒。' : '旧账号提醒已清理；可为当前账号启用本机提醒。', 0, 0, false);
          return;
        }
        this.enabled = status.permission === 'granted' && status.scope === scope && status.cleanup_required !== true;
        this.publish(this.enabled ? 'ready' : 'disabled', status.permission === 'unsupported' ?
          '此设备暂不支持系统提醒，仍可在应用中查看安排。' : this.enabled ? '正在核对已确认任务。' : '点击启用后，才会申请系统通知权限。', status.scheduled, 0, status.limited);
        if (this.enabled && this.active) { this.refresh(); }
      } catch {
        if (this.live(revision)) { this.publish('error', '本机提醒状态核对失败；旧提醒可能仍存在，请重试核对或关闭提醒。'); }
      }
    });
  }
  setActive(active: boolean): void {
    this.active = active;
    if (!active) { this.refreshRevision++; }
    else { this.refresh(); }
  }
  refresh(): void {
    if (this.disposed || !this.active || !this.enabled || this.loader === null) { return; }
    const revision = this.revision; const refresh = ++this.refreshRevision; const load = this.loader; const scope = this.scope;
    this.run(async () => {
      if (!this.live(revision) || !this.active || refresh !== this.refreshRevision) { return; }
      this.publish('checking', '正在把已确认任务同步到本机提醒。');
      try {
        const overview = await load();
        if (!this.live(revision) || !this.active || refresh !== this.refreshRevision) { return; }
        const plan = buildReminderPlan(overview, this.clock());
        const result = await this.driver.replace(scope, plan.items);
        if (!this.live(revision) || refresh !== this.refreshRevision) { return; }
        if (!validReminderStatus(result) || result.scope !== scope || result.permission !== 'granted' || result.cleanup_required === true || result.scheduled !== plan.items.length && !(result.limited && result.scheduled > 0 && result.scheduled < plan.items.length)) { throw new Error('SCHEDULE_NOT_CONFIRMED'); }
        this.publish('ready', `系统已接受 ${result.scheduled} 项提醒。${result.mode === 'inexact' ? '系统可能延迟提醒。' : '实际送达受系统设置影响。'}${plan.limited || result.limited ? '仅安排系统容量内的近期提醒，重新打开应用会继续核对。' : ''}`,
          result.scheduled, plan.skipped, plan.limited || result.limited);
      } catch {
        if (this.live(revision) && refresh === this.refreshRevision) {
          this.publish('error', '提醒同步未确认，系统安排可能不完整；请联网重试核对。查询失败不会被当作空任务。');
        }
      }
    });
  }
  async enable(): Promise<void> {
    if (this.disposed || !this.scope || !this.active) { return; }
    const revision = this.revision; const scope = this.scope;
    await this.run(async () => {
      if (!this.live(revision) || !this.active) { return; }
      this.publish('requesting', '请在系统弹窗中选择是否允许通知。');
      try {
        const previous = await this.driver.status();
        if (!this.live(revision)) { return; }
        if (!validReminderStatus(previous)) { throw new Error('INVALID_STATUS'); }
        if (previous.scope && (previous.scope !== scope || previous.cleanup_required === true)) {
          const cleared = await this.driver.clear(previous.scope);
          if (!validReminderStatus(cleared) || cleared.scope || cleared.scheduled !== 0 || cleared.cleanup_required === true) { throw new Error('CLEANUP_FAILED'); }
        }
        if (!this.live(revision) || !this.active) { return; }
        const status = await this.driver.authorize(scope);
        if (!this.live(revision)) { return; }
        if (!validReminderStatus(status)) { throw new Error('INVALID_STATUS'); }
        this.enabled = status.permission === 'granted' && status.scope === scope && status.cleanup_required !== true;
        this.publish(this.enabled ? 'ready' : 'disabled', this.enabled ? '已启用，正在核对任务。' : '系统未允许通知；可在系统设置中开启，文字功能仍可用。', status.scheduled, 0, false);
        if (this.enabled) { this.refresh(); }
      } catch {
        if (this.live(revision)) { this.publish('error', '启用提醒未完成，请重试；不要把此状态当作已安排。'); }
      }
    });
  }
  async disable(): Promise<void> {
    if (this.disposed) { return; }
    const scope = this.scope; const revision = ++this.revision;
    this.refreshRevision++; this.enabled = false;
    this.publish('clearing', '正在取消本账号的系统提醒。');
    await this.run(async () => {
      try {
        const status = await this.driver.status();
        if (!validReminderStatus(status)) { throw new Error('INVALID_STATUS'); }
        // A failed account switch may still own the previous account's consent/ledger.
        const target = status.scope || scope;
        const result = target ? await this.driver.clear(target) : status;
        if (!validReminderStatus(result) || result.scope || result.scheduled !== 0 || result.cleanup_required === true) { throw new Error('CLEANUP_FAILED'); }
        if (this.live(revision)) { this.publish('disabled', '本机系统提醒已关闭。', 0, 0, false); }
      } catch {
        if (this.live(revision)) { this.publish('error', '系统提醒未能确认清理，旧提醒可能仍出现。请重试关闭或在系统中关闭通知。'); }
        throw new Error('REMINDER_CLEANUP_FAILED');
      }
    });
  }
  async logout(): Promise<void> {
    const scope = this.scope;
    const pending = this.disable(); const revision = this.revision;
    try { await pending; } finally { if (this.scope === scope && this.revision === revision) { this.scope = ''; this.loader = null; } }
  }
  dispose(): void {
    this.disposed = true; this.revision++; this.refreshRevision++; this.driver.dispose();
  }
}
