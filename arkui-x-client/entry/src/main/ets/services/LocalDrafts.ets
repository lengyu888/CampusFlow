import fs from '@ohos.file.fs';
import { BusinessError } from '@ohos.base';
import { DraftDriver, DraftStore, MAX_LOCAL_DRAFT_BYTES, draftUtf8Bytes } from '../utils/DraftStore';

export class FileDraftDriver implements DraftDriver {
  private path: string = '';

  configure(filesDir: string): void {
    if (filesDir.length === 0) { throw new Error('本机草稿目录不可用。'); }
    const path = `${filesDir.replace(/\/$/, '')}/campusflow-local-drafts-v1.json`;
    if (this.path.length > 0 && this.path !== path) { throw new Error('本机草稿目录已初始化。'); }
    this.path = path;
  }

  private filePath(): string {
    if (this.path.length === 0) { throw new Error('本机草稿尚未初始化。'); }
    return this.path;
  }

  async read(): Promise<string | undefined> {
    try {
      const path = this.filePath();
      const stat = await fs.stat(path);
      if (stat.size > MAX_LOCAL_DRAFT_BYTES) { throw new Error('容量超限'); }
      return await fs.readText(path);
    } catch (error) {
      if ((error as BusinessError).code === 13900002) { return undefined; }
      throw new Error('本机草稿读取失败，未覆盖原文件。');
    }
  }

  async write(value: string): Promise<void> {
    if (draftUtf8Bytes(value) > MAX_LOCAL_DRAFT_BYTES) { throw new Error('草稿超过本机容量限制。'); }
    const path = this.filePath();
    const temporary = `${path}.tmp`;
    let file: fs.File | null = null;
    try {
      file = await fs.open(temporary, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      const written = await fs.write(file.fd, value);
      if (written !== draftUtf8Bytes(value)) { throw new Error('写入不完整'); }
      await fs.fsync(file.fd);
      await fs.close(file);
      file = null;
      // Same-directory replacement only after complete UTF-8 write + fsync. Never unlink old first.
      await fs.rename(temporary, path);
    } catch {
      throw new Error('本机草稿保存失败，原有文件未被主动删除。');
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
        if ((error as BusinessError).code !== 13900002) { throw new Error('本机草稿清理失败，请重试。'); }
      }
    }
  }
}

const driver: FileDraftDriver = new FileDraftDriver();
export const localDrafts: DraftStore = new DraftStore(driver);

export async function initializeLocalDrafts(filesDir: string): Promise<void> {
  driver.configure(filesDir);
  await localDrafts.initialize();
}
