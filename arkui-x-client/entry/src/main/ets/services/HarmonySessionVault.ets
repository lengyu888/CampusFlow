import asset from '@ohos.security.asset';
import { BusinessError } from '@ohos.base';
import { MAX_SAVED_SESSION_BYTES, SessionStorageError, SessionVaultDriver } from '../utils/SessionPersistence';

const SESSION_ALIAS: string = 'campusflow-session-v1';

function bytes(value: string): Uint8Array {
  const result = new Uint8Array(value.length);
  for (let i = 0; i < value.length; i++) {
    const code = value.charCodeAt(i);
    if (code > 127) { throw new SessionStorageError('SESSION_INVALID'); }
    result[i] = code;
  }
  return result;
}

export class HarmonySessionVault implements SessionVaultDriver {
  private selector(): asset.AssetMap { return new Map<asset.Tag, asset.Value>([[asset.Tag.ALIAS, bytes(SESSION_ALIAS)]]); }

  async read(): Promise<string | null> {
    const query = this.selector(); query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const found = await asset.query(query);
      if (found.length === 0) { return null; }
      if (found.length !== 1) { throw new SessionStorageError('SESSION_INVALID'); }
      const secret = found[0].get(asset.Tag.SECRET);
      if (!(secret instanceof Uint8Array) || secret.length === 0 || secret.length > MAX_SAVED_SESSION_BYTES) {
        throw new SessionStorageError('SESSION_INVALID');
      }
      let text = '';
      for (let i = 0; i < secret.length; i++) {
        if (secret[i] > 127) { throw new SessionStorageError('SESSION_INVALID'); }
        text += String.fromCharCode(secret[i]);
      }
      return text;
    } catch (error) {
      if ((error as BusinessError).code === 24000002) { return null; }
      if (error instanceof SessionStorageError) { throw error; }
      throw new SessionStorageError();
    }
  }

  async write(value: string): Promise<void> {
    if (value.length === 0 || value.length > MAX_SAVED_SESSION_BYTES) { throw new SessionStorageError('SESSION_INVALID'); }
    const attributes = this.selector();
    attributes.set(asset.Tag.SECRET, bytes(value));
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_UNLOCKED);
    attributes.set(asset.Tag.AUTH_TYPE, asset.AuthType.NONE);
    attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
    attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
    // IS_PERSISTENT is deliberately absent: uninstall removes the token. No
    // credential or account metadata is placed in unencrypted custom labels.
    try { await asset.add(attributes); } catch { throw new SessionStorageError(); }
  }

  async remove(): Promise<void> {
    try { await asset.remove(this.selector()); } catch (error) {
      if ((error as BusinessError).code !== 24000002) { throw new SessionStorageError(); }
    }
  }
}
