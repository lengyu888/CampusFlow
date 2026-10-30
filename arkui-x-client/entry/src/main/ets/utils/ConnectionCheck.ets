export type ConnectionProbeKind = 'invalid_url' | 'network_unreachable' | 'wrong_service' | 'http_error' | 'online';
export type ConnectionCheckPhase = ConnectionProbeKind | 'idle' | 'checking';

export interface ConnectionProbe { kind: ConnectionProbeKind; statusCode: number; elapsedMs: number; }
export interface ConnectionCheckState { phase: ConnectionCheckPhase; statusCode: number; elapsedMs: number; checkedAt: number; }
export interface ConnectionCheckGateway { probeHealth(): Promise<ConnectionProbe>; }
interface HealthBody { status?: string; api_key_mode?: string; supported_models?: string[]; }

export function emptyConnectionCheck(): ConnectionCheckState {
  return { phase: 'idle', statusCode: 0, elapsedMs: 0, checkedAt: 0 };
}

// Only bounded status metadata leaves the transport boundary. Never retain a
// response body or native error text, even when the URL reaches another app.
export function classifyHealthProbe(statusCode: number, body: string, elapsedMs: number): ConnectionProbe {
  const elapsed = Number.isFinite(elapsedMs) ? Math.max(0, Math.round(elapsedMs)) : 0;
  const status = Number.isInteger(statusCode) && statusCode >= 100 && statusCode <= 599 ? statusCode : 0;
  if (status >= 300 && status < 400) { return { kind: 'wrong_service', statusCode: status, elapsedMs: elapsed }; }
  if (status < 200 || status >= 300) { return { kind: 'http_error', statusCode: status, elapsedMs: elapsed }; }
  try {
    if (body.length > 16384) { throw new Error('INVALID_HEALTH'); }
    const value = JSON.parse(body) as HealthBody;
    if (value === null || typeof value !== 'object' || Array.isArray(value) || value.status !== 'ok' ||
      value.api_key_mode !== 'encrypted_account' || !Array.isArray(value.supported_models) ||
      value.supported_models.length > 100 || value.supported_models.some((id: string) =>
        typeof id !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$/.test(id))) {
      throw new Error('INVALID_HEALTH');
    }
    return { kind: 'online', statusCode: status, elapsedMs: elapsed };
  } catch { return { kind: 'wrong_service', statusCode: status, elapsedMs: elapsed }; }
}

export function connectionCheckTitle(state: ConnectionCheckState): string {
  switch (state.phase) {
    case 'checking': return '正在检查连接';
    case 'online': return '服务连接正常';
    case 'invalid_url': return '服务地址格式不正确';
    case 'wrong_service': return '未确认行简服务';
    case 'http_error': return '服务暂不可用';
    case 'network_unreachable': return '暂时无法连接';
    default: return '';
  }
}

export function connectionCheckMessage(state: ConnectionCheckState): string {
  switch (state.phase) {
    case 'checking': return '仅核对服务状态，不提交密码或模型密钥。';
    case 'online': return '已确认兼容的行简服务；账号登录状态将单独校验。';
    case 'invalid_url': return '请填写 http:// 或 https:// 地址，不包含账号、查询参数或片段。';
    case 'wrong_service': return '请核对地址与端口。本次未接受跳转或不符合行简格式的响应。';
    case 'http_error': return state.statusCode > 0 ? `健康检查返回 HTTP ${state.statusCode}，请稍后重试或检查后端。` : '健康检查未完成，请检查后端服务。';
    case 'network_unreachable': return '请检查后端服务、网络或模拟器端口映射；本机无法单独判断是哪一项。';
    default: return '';
  }
}

export class ConnectionCheckController {
  private generation: number = 0;
  private active: boolean = true;
  private baseUrl: string = '';
  private current: ConnectionCheckState = emptyConnectionCheck();
  private makeGateway: (baseUrl: string) => ConnectionCheckGateway;
  private changed: (state: ConnectionCheckState) => void;
  private now: () => number;

  constructor(makeGateway: (baseUrl: string) => ConnectionCheckGateway,
    changed: (state: ConnectionCheckState) => void, now: () => number = () => Date.now()) {
    this.makeGateway = makeGateway; this.changed = changed; this.now = now;
  }

  configure(baseUrl: string, active: boolean = true): void {
    if (this.baseUrl === baseUrl && this.active === active) { return; }
    this.generation++; this.baseUrl = baseUrl; this.active = active;
    this.publish(emptyConnectionCheck());
  }

  dispose(): void { this.generation++; this.active = false; }

  private publish(state: ConnectionCheckState): void {
    this.current = { phase: state.phase, statusCode: state.statusCode, elapsedMs: state.elapsedMs, checkedAt: state.checkedAt };
    this.changed({ phase: state.phase, statusCode: state.statusCode, elapsedMs: state.elapsedMs, checkedAt: state.checkedAt });
  }

  async check(): Promise<void> {
    if (!this.active || this.current.phase === 'checking') { return; }
    const generation = ++this.generation; const base = this.baseUrl;
    this.publish({ phase: 'checking', statusCode: 0, elapsedMs: 0, checkedAt: 0 });
    let result: ConnectionProbe;
    try { result = await this.makeGateway(base).probeHealth(); }
    catch { result = { kind: 'network_unreachable', statusCode: 0, elapsedMs: 0 }; }
    if (!this.active || generation !== this.generation || base !== this.baseUrl) { return; }
    if (result === null || typeof result !== 'object' ||
      !['invalid_url', 'network_unreachable', 'wrong_service', 'http_error', 'online'].includes(result.kind) ||
      !Number.isInteger(result.statusCode) || result.statusCode < 0 || result.statusCode > 599 ||
      !Number.isFinite(result.elapsedMs) || result.elapsedMs < 0) {
      result = { kind: 'wrong_service', statusCode: 0, elapsedMs: 0 };
    }
    this.publish({ phase: result.kind, statusCode: result.statusCode, elapsedMs: result.elapsedMs, checkedAt: this.now() });
  }
}
