// Shared declarations only: importing these contracts never initializes a device service.
export interface PlatformClockReading { wall_ms?: number; monotonic_ms?: number; }
export interface PlatformClockSource { read(): Promise<PlatformClockReading>; }
export interface PlatformReminderItem { id: string; fire_at_ms: number; }
export interface PlatformCommandArguments {
  operation_id?: string;
  text?: string;
  scope?: string;
  reminders?: PlatformReminderItem[];
}
export interface PlatformServiceResult extends PlatformClockReading {
  recognition?: boolean;
  synthesis?: boolean;
  reminders?: boolean;
  permission?: string;
  scope?: string;
  scheduled?: number;
  mode?: string;
  limited?: boolean;
  cleanup_required?: boolean;
}
export interface PlatformServicePort {
  request(op: string, args?: PlatformCommandArguments): Promise<PlatformServiceResult>;
}
