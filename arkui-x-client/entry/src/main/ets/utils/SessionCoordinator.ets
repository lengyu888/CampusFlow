import { AuthResponse, UserProfile } from '../model/ApiModels';
import { ConnectionProbe } from './ConnectionCheck';
import { SavedSession, SavedSessionPort, SessionStorageError, normalizeServiceBaseUrl } from './SessionPersistence';
export interface SessionVerificationPort {
  probeHealth(): Promise<ConnectionProbe>;
  verifySession(): Promise<UserProfile>;
}
export interface SessionRestoreResult {
  phase: string;
  baseUrl: string;
  auth: AuthResponse | null;
  message: string;
}
interface SessionFailure { statusCode?: number; }

function result(phase: string, message: string = '', baseUrl: string = '', auth: AuthResponse | null = null): SessionRestoreResult {
  return { phase: phase, message: message, baseUrl: baseUrl, auth: auth };
}

export function verifiedSessionUser(user: UserProfile, expectedId: string): boolean {
  return user !== null && typeof user === 'object' && !Array.isArray(user) && user.user_id === expectedId &&
    typeof user.email === 'string' && typeof user.display_name === 'string' &&
    ['user', 'admin'].includes(user.role) && typeof user.onboarding_complete === 'boolean' &&
    typeof user.api_key_configured === 'boolean' &&
    [user.school, user.campus, user.semester, user.api_key_hint].every((value: string | null) => value === null || typeof value === 'string');
}

// This controller never accepts a stored profile as authentication. The original
// service is checked anonymously before the candidate token is sent to /me.
export class SessionCoordinator {
  private generation: number = 0;
  private storage: SavedSessionPort;
  private makeApi: (baseUrl: string, token: string) => SessionVerificationPort;

  constructor(storage: SavedSessionPort, makeApi: (baseUrl: string, token: string) => SessionVerificationPort) {
    this.storage = storage; this.makeApi = makeApi;
  }
  cancel(): void { this.generation++; }

  async restore(): Promise<SessionRestoreResult> {
    const generation = ++this.generation;
    let record: SavedSession | null;
    try { record = await this.storage.read(); }
    catch { return generation === this.generation ? result('unavailable', '保存的登录暂未恢复，可重新登录或稍后重试。') : result('cancelled'); }
    if (generation !== this.generation) { return result('cancelled'); }
    if (record === null) { return result('empty'); }
    const base = normalizeServiceBaseUrl(record.baseUrl);
    if (base === null || base !== record.baseUrl) { return result('unavailable', '保存的服务地址无法核对，请重新登录。'); }
    let probe: ConnectionProbe;
    try { probe = await this.makeApi(base, '').probeHealth(); }
    catch { return generation === this.generation ? result('offline', '暂时无法连接原服务，登录信息仍保留。可检查连接后重试。', base) : result('cancelled'); }
    if (generation !== this.generation) { return result('cancelled'); }
    if (probe.kind !== 'online') {
      return result(probe.kind === 'network_unreachable' ? 'offline' : 'unavailable',
        probe.kind === 'network_unreachable' ? '暂时无法连接原服务，登录信息仍保留。可检查连接后重试。' :
          '原服务尚未通过连接检查，本次未发送保存的登录凭据。请检查服务地址与后端。', base);
    }
    try {
      const user = await this.makeApi(base, record.accessToken).verifySession();
      if (generation !== this.generation) { return result('cancelled'); }
      if (!verifiedSessionUser(user, record.userId)) {
        return result('unavailable', '保存的账号与服务返回不一致，本次未恢复登录。请重新登录。', base);
      }
      return result('ready', '已恢复登录，账号由原服务重新核验。', base,
        { user: user, access_token: record.accessToken, token_type: 'bearer' });
    } catch (error) {
      if (generation !== this.generation) { return result('cancelled'); }
      const status = (error as SessionFailure).statusCode ?? 0;
      if (status === 401 || status === 403) {
        try { await this.storage.clear(); }
        catch { /* The invalid server session is never published, even if cleanup needs retry. */ }
        if (generation !== this.generation) { return result('cancelled'); }
        return result('expired', '登录已过期或已撤销，请重新登录。', base);
      }
      return result('offline', '账号暂时无法核验，保存的登录仍保留。可检查连接后重试。', base);
    }
  }

  async clear(): Promise<void> { this.cancel(); await this.storage.clear(); }

  async remember(baseUrl: string, auth: AuthResponse, enabled: boolean): Promise<string> {
    const generation = ++this.generation;
    // Disable the previous credential first, including when the new account opts
    // out. A write failure must never silently restore the previous account.
    try { await this.storage.clear(); }
    catch (error) {
      if (!(error instanceof SessionStorageError) || error.code !== 'SESSION_REMOVAL_PENDING') { throw new SessionStorageError(); }
    }
    if (generation !== this.generation) { throw new SessionStorageError('SESSION_STALE'); }
    if (!enabled) { return '本次仅登录，未启用保持登录。'; }
    const base = normalizeServiceBaseUrl(baseUrl);
    if (base === null) { throw new SessionStorageError('SESSION_INVALID'); }
    try {
      await this.storage.save({ schemaVersion: 1, baseUrl: base, userId: auth.user.user_id,
        accessToken: auth.access_token, savedAt: Date.now() });
      if (generation !== this.generation) { throw new SessionStorageError('SESSION_STALE'); }
      return '已在系统安全存储中保持登录；不保存密码。';
    } catch {
      if (generation !== this.generation) { throw new SessionStorageError('SESSION_STALE'); }
      return '本次已登录，安全保持登录暂不可用；重开后需要重新登录。';
    }
  }
}
