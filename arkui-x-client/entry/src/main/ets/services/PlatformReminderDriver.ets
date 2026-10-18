import common from '@ohos.app.ability.common';
import deviceInfo from '@ohos.deviceInfo';
import { ReminderDriver, ReminderItem, ReminderStatus, validReminderStatus } from '../utils/ReminderCoordinator';
import { PlatformServicePort, PlatformServiceResult } from '../model/PlatformServiceTypes';

type ReminderNativeResult = PlatformServiceResult;
type ReminderNativePort = PlatformServicePort;

export class PlatformReminderDriver implements ReminderDriver {
  private context: common.UIAbilityContext | undefined;
  private harmony: Promise<ReminderDriver> | null = null;
  private native: Promise<ReminderNativePort> | null = null;
  private disposed: boolean = false;

  constructor(context: common.UIAbilityContext | undefined) { this.context = context; }
  private platform(): string {
    try {
      const os = deviceInfo.osFullName;
      if (os.startsWith('HarmonyOS') || os.startsWith('OpenHarmony')) { return 'harmony'; }
      if (os.startsWith('Android') || os.startsWith('iOS') || os.startsWith('iPadOS')) { return 'native'; }
    } catch { /* Unknown hosts must not claim native scheduling capability. */ }
    return 'unsupported';
  }
  private async harmonyDriver(): Promise<ReminderDriver> {
    if (this.disposed) { throw new Error('REMINDER_DISPOSED'); }
    if (this.harmony === null) {
      this.harmony = import('./HarmonyReminderDriver').then((module) => new module.HarmonyReminderDriver(this.context));
    }
    const driver = await this.harmony;
    if (this.disposed) { driver.dispose(); throw new Error('REMINDER_DISPOSED'); }
    return driver;
  }
  private async nativeDriver(): Promise<ReminderNativePort> {
    if (this.disposed) { throw new Error('REMINDER_DISPOSED'); }
    if (this.native === null) { this.native = import('./NativePlatformBridge').then((module) => module.nativePlatformBridge()); }
    const driver = await this.native;
    if (this.disposed) { throw new Error('REMINDER_DISPOSED'); }
    return driver;
  }
  private parseStatus(value: ReminderNativeResult): ReminderStatus {
    if (value === null || typeof value !== 'object' || Array.isArray(value)) { throw new Error('INVALID_REMINDER_RESPONSE'); }
    const status: ReminderStatus = { permission: value.permission ?? '', scope: value.scope ?? '', scheduled: value.scheduled ?? -1,
      mode: value.mode ?? '', limited: value.limited ?? false };
    if (value.cleanup_required !== undefined) { status.cleanup_required = value.cleanup_required; }
    if (!validReminderStatus(status) || typeof value.limited !== 'boolean' || typeof value.scope !== 'string' ||
      value.cleanup_required !== undefined && typeof value.cleanup_required !== 'boolean') {
      throw new Error('INVALID_REMINDER_RESPONSE');
    }
    return status;
  }
  async status(): Promise<ReminderStatus> {
    if (this.disposed) { throw new Error('REMINDER_DISPOSED'); }
    if (this.platform() === 'harmony') { return (await this.harmonyDriver()).status(); }
    if (this.platform() === 'native') { return this.parseStatus(await (await this.nativeDriver()).request('reminders.status')); }
    return { permission: 'unsupported', scope: '', scheduled: 0, mode: 'system', limited: false };
  }
  async authorize(scope: string): Promise<ReminderStatus> {
    if (this.platform() === 'harmony') { return (await this.harmonyDriver()).authorize(scope); }
    if (this.platform() === 'native') { return this.parseStatus(await (await this.nativeDriver()).request('reminders.authorize', { scope: scope })); }
    return this.status();
  }
  async replace(scope: string, items: ReminderItem[]): Promise<ReminderStatus> {
    if (this.platform() === 'harmony') { return (await this.harmonyDriver()).replace(scope, items); }
    if (this.platform() !== 'native') { throw new Error('REMINDER_UNSUPPORTED'); }
    const result = await (await this.nativeDriver()).request('reminders.replace', { scope: scope, reminders: items });
    const status = this.parseStatus({ permission: 'granted', scope: scope, scheduled: result.scheduled, mode: result.mode, limited: result.limited });
    if (status.scheduled > items.length || status.scheduled !== items.length && !(status.limited && status.scheduled > 0)) { throw new Error('INVALID_REMINDER_RESPONSE'); }
    return status;
  }
  async clear(scope: string): Promise<ReminderStatus> {
    if (this.platform() === 'harmony') { return (await this.harmonyDriver()).clear(scope); }
    if (this.platform() === 'native') { return this.parseStatus(await (await this.nativeDriver()).request('reminders.clear', { scope: scope })); }
    throw new Error('REMINDER_UNSUPPORTED');
  }
  dispose(): void {
    this.disposed = true;
    this.harmony?.then((driver: ReminderDriver) => driver.dispose()).catch(() => {});
    // The shared bridge also owns voice; disposing this facade never destroys that singleton or OS reminders.
  }
}
