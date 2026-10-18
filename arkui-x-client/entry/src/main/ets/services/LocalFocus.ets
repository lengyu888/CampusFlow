import fs from '@ohos.file.fs';
import { BusinessError } from '@ohos.base';
import { FocusDriver, FocusStore, MAX_FOCUS_BYTES, focusBytes } from '../utils/FocusStore';

export class FileFocusDriver implements FocusDriver {
  private path: string = '';

  configure(filesDir: string): void {
    if (filesDir.length === 0) { throw new Error('本机专注记录目录不可用。'); }
    const path = `${filesDir.replace(/\/$/, '')}/campusflow-local-focus-v1.json`;
    if (this.path.length > 0 && this.path !== path) { throw new Error('本机专注记录目录已初始化。'); }
    this.path = path;
  }

  private filePath(): string {
    if (this.path.length === 0) { throw new Error('本机专注记录尚未初始化。'); }
    return this.path;
  }

  async read(): Promise<string | undefined> {
    try {
      const path = this.filePath();
      const stat = await fs.stat(path);
      if (stat.size > MAX_FOCUS_BYTES) { throw new Error('容量超限'); }
      return await fs.readText(path);
    } catch (error) {
      if ((error as BusinessError).code === 13900002) { return undefined; }
      throw new Error('本机专注记录读取失败，未覆盖原文件。');
    }
  }

  async write(value: string): Promise<void> {
    if (focusBytes(value) > MAX_FOCUS_BYTES) { throw new Error('专注记录超过本机容量限制。'); }
    const path = this.filePath();
    const temporary = `${path}.tmp`;
    let file: fs.File | null = null;
    try {
      file = await fs.open(temporary, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      const written = await fs.write(file.fd, value);
      if (written !== focusBytes(value)) { throw new Error('写入不完整'); }
      await fs.fsync(file.fd);
      await fs.close(file);
      file = null;
      // Same-directory replacement only after complete UTF-8 write + fsync. Never unlink old first.
      await fs.rename(temporary, path);
    } catch {
      throw new Error('本机专注记录保存失败，原有文件未被主动删除。');
    } finally {
      if (file !== null) {
        try { await fs.close(file); } catch { /* Preserve the original failure. */ }
      }
      try { await fs.unlink(temporary); } catch { /* Rename already consumed temporary on success. */ }
    }
  }

  async remove(): Promise<void> {
    const path = this.filePath();
    for (const target of [path, `${path}.tmp`]) {
      try { await fs.unlink(target); } catch (error) {
        if ((error as BusinessError).code !== 13900002) { throw new Error('本机专注记录清理失败，请重试。'); }
      }
    }
  }
}

const driver: FileFocusDriver = new FileFocusDriver();
export const localFocus: FocusStore = new FocusStore(driver);

export async function initializeLocalFocus(filesDir: string): Promise<void> {
  driver.configure(filesDir);
  await localFocus.initialize();
}
