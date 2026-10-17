import fs from '@ohos.file.fs';
import { BusinessError } from '@ohos.base';
import { LocalHistoryDriver, LocalHistoryStore, MAX_LOCAL_HISTORY_BYTES } from '../utils/LocalHistoryStore';

function missingFile(error: BusinessError): boolean {
  return error.code === 13900002;
}

function utf8Length(value: string): number {
  let length = 0;
  for (let index = 0; index < value.length; index++) {
    const unit = value.charCodeAt(index);
    if (unit < 0x80) {
      length++;
    } else if (unit < 0x800) {
      length += 2;
    } else if (unit >= 0xD800 && unit <= 0xDBFF && index + 1 < value.length &&
      value.charCodeAt(index + 1) >= 0xDC00 && value.charCodeAt(index + 1) <= 0xDFFF) {
      length += 4;
      index++;
    } else {
      length += 3;
    }
  }
  return length;
}

class FileHistoryDriver implements LocalHistoryDriver {
  private path: string = '';

  configure(filesDir: string): void {
    if (filesDir.length === 0) {
      throw new Error('本机存储目录不可用。');
    }
    const path = `${filesDir.replace(/\/$/, '')}/campusflow-local-history-v1.json`;
    if (this.path.length > 0 && this.path !== path) {
      throw new Error('本机会话存储目录已初始化。');
    }
    this.path = path;
  }

  private filePath(): string {
    if (this.path.length === 0) {
      throw new Error('本机会话存储尚未初始化。');
    }
    return this.path;
  }

  async read(): Promise<string | undefined> {
    const path = this.filePath();
    try {
      const stat = await fs.stat(path);
      if (stat.size > MAX_LOCAL_HISTORY_BYTES) {
        throw new Error('本机会话文件超过容量限制，未覆盖原文件。');
      }
      return await fs.readText(path);
    } catch (error) {
      if (missingFile(error as BusinessError)) {
        return undefined;
      }
      throw new Error('本机会话文件读取失败，未覆盖原文件。');
    }
  }

  async write(text: string): Promise<void> {
    const path = this.filePath();
    const temporaryPath = `${path}.tmp`;
    let file: fs.File | null = null;
    try {
      file = await fs.open(temporaryPath, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      const written = await fs.write(file.fd, text);
      if (written !== utf8Length(text)) {
        throw new Error('本机会话未完整写入。');
      }
      await fs.fsync(file.fd);
      await fs.close(file);
      file = null;
      // Replace only after a complete write; never delete the previous file first.
      await fs.rename(temporaryPath, path);
    } catch {
      throw new Error('本机会话保存失败，原有记录未被主动删除。');
    } finally {
      if (file !== null) {
        try {
          await fs.close(file);
        } catch {
          // Retain the original write error; no message content is logged.
        }
      }
      try {
        await fs.unlink(temporaryPath);
      } catch {
        // A renamed file no longer has a temporary path.
      }
    }
  }

  async remove(): Promise<void> {
    const path = this.filePath();
    for (const target of [path, `${path}.tmp`]) {
      try {
        await fs.unlink(target);
      } catch (error) {
        if (!missingFile(error as BusinessError)) {
          throw new Error('本机会话清理失败，请在系统应用设置中清除应用数据。');
        }
      }
    }
  }
}

const driver: FileHistoryDriver = new FileHistoryDriver();
export const localHistory: LocalHistoryStore = new LocalHistoryStore(driver);

export async function initializeLocalHistory(filesDir: string): Promise<void> {
  driver.configure(filesDir);
  await localHistory.initialize();
}
