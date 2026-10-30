import fs from '@ohos.file.fs';
import deviceInfo from '@ohos.deviceInfo';
import { BusinessError } from '@ohos.base';
import { SessionBarrierDriver, SessionPersistence, SessionStorageError, SessionVaultDriver } from '../utils/SessionPersistence';

interface SessionBarrier { schemaVersion: number; enabled: boolean; }

// This file is a logout/replacement veto only. It never contains an endpoint,
// account, token, password, API key or cached profile.
export class FileSessionBarrier implements SessionBarrierDriver {
  private path: string = '';
  configure(filesDir: string): void {
    if (filesDir.length === 0) { throw new SessionStorageError(); }
    const path = `${filesDir.replace(/\/$/, '')}/campusflow-session-enabled-v1.json`;
    if (this.path.length > 0 && this.path !== path) { throw new SessionStorageError(); }
    this.path = path;
  }
  private filePath(): string {
    if (this.path.length === 0) { throw new SessionStorageError(); }
    return this.path;
  }
  async readEnabled(): Promise<boolean> {
    try {
      const path = this.filePath(); const stat = await fs.stat(path);
      if (stat.size > 128) { throw new SessionStorageError(); }
      const value = JSON.parse(await fs.readText(path)) as SessionBarrier;
      if (value === null || typeof value !== 'object' || Array.isArray(value) || value.schemaVersion !== 1 ||
        typeof value.enabled !== 'boolean' || Object.keys(value).sort().join(',') !== 'enabled,schemaVersion') { throw new SessionStorageError(); }
      return value.enabled;
    } catch (error) {
      if ((error as BusinessError).code === 13900002) { return false; }
      throw new SessionStorageError();
    }
  }
  async writeEnabled(enabled: boolean): Promise<void> {
    const path = this.filePath(); const temporary = `${path}.tmp`;
    const text = JSON.stringify({ schemaVersion: 1, enabled: enabled } as SessionBarrier);
    let file: fs.File | null = null;
    try {
      file = await fs.open(temporary, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      if (await fs.write(file.fd, text) !== text.length) { throw new SessionStorageError(); }
      await fs.fsync(file.fd); await fs.close(file); file = null;
      await fs.rename(temporary, path);
    } catch { throw new SessionStorageError(); }
    finally {
      if (file !== null) { try { await fs.close(file); } catch { /* Keep original failure. */ } }
      try { await fs.unlink(temporary); } catch { /* Atomic replacement consumed it. */ }
    }
  }
}

export class PlatformSessionVault implements SessionVaultDriver {
  private harmony: Promise<SessionVaultDriver> | null = null;
  private async driver(): Promise<SessionVaultDriver> {
    let os = '';
    try { os = deviceInfo.osFullName; } catch { throw new SessionStorageError('SESSION_UNSUPPORTED'); }
    if (!os.startsWith('HarmonyOS') && !os.startsWith('OpenHarmony')) { throw new SessionStorageError('SESSION_UNSUPPORTED'); }
    if (this.harmony === null) { this.harmony = import('./HarmonySessionVault').then((module) => new module.HarmonySessionVault()); }
    try { return await this.harmony; } catch { this.harmony = null; throw new SessionStorageError(); }
  }
  async read(): Promise<string | null> { return (await this.driver()).read(); }
  async write(value: string): Promise<void> { await (await this.driver()).write(value); }
  async remove(): Promise<void> { await (await this.driver()).remove(); }
}

const barrier: FileSessionBarrier = new FileSessionBarrier();
export const localSession: SessionPersistence = new SessionPersistence(new PlatformSessionVault(), barrier);

export async function initializeLocalSession(filesDir: string): Promise<void> { barrier.configure(filesDir); }
