import common from '@ohos.app.ability.common';
import fs from '@ohos.file.fs';
import { BusinessError } from '@ohos.base';
import { reminderAgentManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { ReminderDriver, ReminderItem, ReminderStatus } from '../utils/ReminderCoordinator';

function utf8Bytes(value: string): number {
  let bytes = 0;
  for (const character of value) { const code = character.codePointAt(0) as number; bytes += code < 128 ? 1 : code < 2048 ? 2 : code < 65536 ? 3 : 4; }
  return bytes;
}

interface SavedReminder { id: string; fire_at_ms: number; notificationId: number; reminderId: number; }
interface ReminderLedger { version: number; scope: string; nextId: number; limited: boolean; items: SavedReminder[]; }

// Harmony-only lazy adapter. Calendar reminders are owned by the system after app exit.
// The ledger contains IDs/timestamps and local account scope, never task text or access tokens.
export class HarmonyReminderDriver implements ReminderDriver {
  private context: common.UIAbilityContext | undefined;
  private ledger: ReminderLedger | null = null;
  private closed: boolean = false;
  constructor(context: common.UIAbilityContext | undefined) { this.context = context; }

  private path(): string {
    if (this.context === undefined || !this.context.filesDir) { throw new Error('UNAVAILABLE'); }
    return `${this.context.filesDir}/campusflow-reminders-v1.json`;
  }
  private async load(): Promise<ReminderLedger> {
    if (this.closed) { throw new Error('OPERATION_CANCELLED'); }
    if (this.ledger !== null) { return this.ledger; }
    const path = this.path();
    try {
      const stat = await fs.stat(path);
      if (stat.size > 65536) { throw new Error('INVALID_LEDGER'); }
      const value = JSON.parse(await fs.readText(path)) as ReminderLedger;
      if (value.version !== 1 || typeof value.scope !== 'string' || value.scope.length > 512 ||
        !Number.isInteger(value.nextId) || value.nextId < 600000 || value.nextId > 2000000000 ||
        !Array.isArray(value.items) || value.items.length > 60) { throw new Error('INVALID_LEDGER'); }
      const ids = new Set<string>(); const nativeIds = new Set<number>();
      for (const item of value.items) {
        if (!/^[A-Za-z0-9._-]{1,180}$/.test(item.id) || ids.has(item.id) ||
          !Number.isSafeInteger(item.fire_at_ms) || !Number.isInteger(item.notificationId) ||
          item.notificationId < 600000 || nativeIds.has(item.notificationId) || !Number.isInteger(item.reminderId) || item.reminderId < -1) {
          throw new Error('INVALID_LEDGER');
        }
        ids.add(item.id); nativeIds.add(item.notificationId);
      }
      value.limited = value.limited === true;
      this.ledger = value;
    } catch (error) {
      if ((error as BusinessError).code !== 13900002) { throw new Error('LEDGER_UNREADABLE'); }
      this.ledger = { version: 1, scope: '', nextId: 600000, limited: false, items: [] };
    }
    return this.ledger as ReminderLedger;
  }
  private async save(): Promise<void> {
    const path = this.path(); const temporary = `${path}.tmp`;
    let file: fs.File | null = null;
    try {
      const text = JSON.stringify(this.ledger);
      file = await fs.open(temporary, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      const written = await fs.write(file.fd, text);
      if (written !== utf8Bytes(text)) { throw new Error('LEDGER_INCOMPLETE_WRITE'); }
      await fs.fsync(file.fd); await fs.close(file); file = null;
      await fs.rename(temporary, path);
    } catch {
      this.ledger = null; // Reload durable ownership before any later system operation.
      throw new Error('LEDGER_WRITE_FAILED');
    } finally {
      if (file !== null) { try { await fs.close(file); } catch { /* Keep original error. */ } }
      try { await fs.unlink(temporary); } catch { /* A renamed file has no temporary path. */ }
    }
  }
  private async owned(): Promise<reminderAgentManager.ReminderInfo[]> {
    const ledger = await this.load();
    const all = await reminderAgentManager.getAllValidReminders();
    return all.filter((info: reminderAgentManager.ReminderInfo) =>
      ledger.items.some((item: SavedReminder) => item.notificationId === info.reminderReq.notificationId));
  }
  async status(): Promise<ReminderStatus> {
    if (!canIUse('SystemCapability.Notification.ReminderAgent')) {
      return { permission: 'unsupported', scope: '', scheduled: 0, mode: 'system', limited: false };
    }
    const ledger = await this.load();
    const allowed = await notificationManager.isNotificationEnabled();
    const reminders = await this.owned();
    return { permission: allowed ? 'granted' : 'denied', scope: ledger.scope,
      scheduled: reminders.length, mode: 'system', limited: ledger.limited };
  }
  async authorize(scope: string): Promise<ReminderStatus> {
    if (!scope || scope.length > 512 || this.context === undefined) { throw new Error('INVALID_REQUEST'); }
    const ledger = await this.load();
    if (ledger.scope && ledger.scope !== scope) { throw new Error('ACCOUNT_CLEANUP_REQUIRED'); }
    if (!await notificationManager.isNotificationEnabled()) {
      try { await notificationManager.requestEnableNotification(this.context); } catch { return this.status(); }
    }
    if (this.closed) { throw new Error('OPERATION_CANCELLED'); }
    if (await notificationManager.isNotificationEnabled()) {
      ledger.scope = scope; await this.save();
    }
    return this.status();
  }
  private async remove(item: SavedReminder): Promise<void> {
    // Recover a crash between system publish and ledger completion by the reserved notificationId.
    const reminders = await this.owned();
    for (const info of reminders) {
      if (info.reminderReq.notificationId === item.notificationId) { await reminderAgentManager.cancelReminder(info.reminderId); }
    }
    const active = await notificationManager.getActiveNotifications();
    for (const notification of active) {
      if (notification.id === item.notificationId) { await notificationManager.cancel(item.notificationId); }
    }
    const pending = await this.owned();
    const delivered = await notificationManager.getActiveNotifications();
    if (pending.some((info: reminderAgentManager.ReminderInfo) => info.reminderReq.notificationId === item.notificationId) ||
      delivered.some((value: notificationManager.NotificationRequest) => value.id === item.notificationId)) { throw new Error('CLEANUP_FAILED'); }
  }
  async replace(scope: string, items: ReminderItem[]): Promise<ReminderStatus> {
    const ledger = await this.load(); const now = Date.now(); const ids = new Set<string>();
    if (ledger.scope !== scope || !scope || !await notificationManager.isNotificationEnabled()) { throw new Error('PERMISSION_DENIED'); }
    if (!Array.isArray(items) || items.length > 60) { throw new Error('INVALID_REQUEST'); }
    for (const item of items) {
      if (!/^[A-Za-z0-9._-]{1,180}$/.test(item.id) || ids.has(item.id) || !Number.isSafeInteger(item.fire_at_ms) ||
        item.fire_at_ms <= now || item.fire_at_ms > now + 366 * 86400000) { throw new Error('INVALID_REQUEST'); }
      ids.add(item.id);
    }
    // API24 targets ordinary applications: at most 30 valid agent reminders.
    const desired = items.slice().sort((a: ReminderItem, b: ReminderItem) => a.fire_at_ms - b.fire_at_ms || a.id.localeCompare(b.id)).slice(0, 30);
    ledger.limited = items.length > 30;
    await reminderAgentManager.addNotificationSlot({ notificationType: notificationManager.SlotType.SERVICE_INFORMATION });
    // Cancel removed or retimed records before creating replacements; failures retain cleanup ownership.
    for (const old of ledger.items.slice()) {
      if (!desired.some((item: ReminderItem) => item.id === old.id && item.fire_at_ms === old.fire_at_ms)) {
        await this.remove(old); ledger.items = ledger.items.filter((item: SavedReminder) => item.id !== old.id); await this.save();
      }
    }
    for (const item of desired) {
      if (this.closed) { throw new Error('OPERATION_CANCELLED'); }
      let saved = ledger.items.find((value: SavedReminder) => value.id === item.id);
      if (saved === undefined) {
        if (ledger.nextId >= 2000000000) { throw new Error('ID_CAPACITY'); }
        saved = { id: item.id, fire_at_ms: item.fire_at_ms, notificationId: ledger.nextId++, reminderId: -1 };
        ledger.items.push(saved); await this.save(); // Write-ahead ownership before OS mutation.
      }
      const existing = (await this.owned()).find((info: reminderAgentManager.ReminderInfo) => info.reminderReq.notificationId === saved?.notificationId);
      if (existing !== undefined) { saved.reminderId = existing.reminderId; continue; }
      const date = new Date(item.fire_at_ms); // System calendar fields use device local time for this absolute instant.
      const request: reminderAgentManager.ReminderRequestCalendar = {
        reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_CALENDAR,
        dateTime: { year: date.getFullYear(), month: date.getMonth() + 1, day: date.getDate(), hour: date.getHours(), minute: date.getMinutes(), second: date.getSeconds() },
        title: '行简提醒', content: '你有一项安排即将开始，打开应用查看。',
        expiredContent: '有一项安排已到提醒时间，请打开应用核对。',
        notificationId: saved.notificationId, slotType: notificationManager.SlotType.SERVICE_INFORMATION,
        wantAgent: { pkgName: 'com.campusflow.agent', abilityName: 'EntryAbility' },
        ringDuration: 1, snoozeTimes: 0, tapDismissed: true
      };
      saved.reminderId = await reminderAgentManager.publishReminder(request); await this.save();
    }
    await this.save();
    return this.status();
  }
  async clear(scope: string): Promise<ReminderStatus> {
    const ledger = await this.load();
    if (ledger.scope && ledger.scope !== scope) { throw new Error('INVALID_REQUEST'); }
    for (const item of ledger.items.slice()) {
      await this.remove(item); ledger.items = ledger.items.filter((value: SavedReminder) => value.id !== item.id); await this.save();
    }
    ledger.scope = ''; ledger.limited = false; await this.save();
    return this.status();
  }
  dispose(): void { this.closed = true; }
}
