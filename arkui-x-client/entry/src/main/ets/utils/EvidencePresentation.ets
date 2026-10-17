import { DataEvidence, WeatherForecast, CampusDataPlace } from '../model/ApiModels';

function evidenceTimestamp(value: string | null): number {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?(Z|[+-]\d{2}:\d{2})$/.test(value)) { return NaN; }
  const year = Number(value.substring(0, 4));
  const month = Number(value.substring(5, 7));
  const day = Number(value.substring(8, 10));
  const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  if (year < 1 || month < 1 || month > 12 || day < 1 || day > days[month - 1] ||
    Number(value.substring(11, 13)) > 23 || Number(value.substring(14, 16)) > 59 || Number(value.substring(17, 19)) > 59) { return NaN; }
  return Date.parse(value);
}

// Public attribution only. Query strings, fragments, credentials and local addresses are never shown.
export function publicSourceUrl(value: string | null): string | null {
  if (typeof value !== 'string' || value.length > 1000 || /[\s\\?#@]/.test(value)) { return null; }
  const match = /^https:\/\/([a-zA-Z0-9.-]+)(\/[^\s]*)?$/.exec(value);
  if (match === null) { return null; }
  const host = match[1].toLowerCase();
  if (!host.includes('.') || host.endsWith('.') || host.endsWith('.local') || host.endsWith('.localhost') ||
    host.endsWith('.internal') || /^[0-9.]+$/.test(host) || !host.split('.').every((part: string) =>
      /^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$/.test(part))) { return null; }
  return value;
}

function unknownEvidence(note: string = '服务未提供可核验的来源及时间，不能据此判断信息仍然有效。'): DataEvidence {
  return { source_id: 'source-unverified', label: '来源待核验', kind: 'reference', status: 'unverified',
    updated_at: null, expires_at: null, url: null, note: note };
}

export function normalizeEvidence(items?: DataEvidence[]): DataEvidence[] {
  if (!Array.isArray(items) || items.length === 0) { return [unknownEvidence()]; }
  const result: DataEvidence[] = [];
  items.slice(0, 32).forEach((item: DataEvidence) => {
    if (item === null || typeof item !== 'object' || typeof item.source_id !== 'string' ||
      item.source_id.length === 0 || item.source_id.length > 256 || typeof item.label !== 'string' ||
      item.label.trim().length === 0 || item.label.length > 200 ||
      !['user', 'remote', 'reference', 'demo'].includes(item.kind) ||
      !['fresh', 'stale', 'unverified', 'missing', 'error'].includes(item.status)) {
      result.push(unknownEvidence('服务提供的来源格式无法核验。'));
      return;
    }
    result.push({ source_id: item.source_id, label: item.label.trim(), kind: item.kind, status: item.status,
      updated_at: Number.isFinite(evidenceTimestamp(item.updated_at)) ? item.updated_at : null,
      expires_at: Number.isFinite(evidenceTimestamp(item.expires_at)) ? item.expires_at : null,
      url: publicSourceUrl(item.url), note: typeof item.note === 'string' && item.note.length <= 4000 ? item.note : '来源说明缺失或无法展示。' });
    // A malformed expiry must not silently become a source with no expiry policy.
    if (item.expires_at !== null && !Number.isFinite(evidenceTimestamp(item.expires_at))) {
      result[result.length - 1].status = 'unverified';
    }
  });
  if (items.length > 32) { result.push(unknownEvidence('来源超过本页展示上限，其余来源尚未核验。')); }
  return result;
}

export function evidenceStatus(item: DataEvidence, now: number = Date.now()): string {
  if (item.kind === 'demo') { return 'demo'; }
  if (['missing', 'error', 'unverified', 'stale'].includes(item.status)) { return item.status; }
  const updated = evidenceTimestamp(item.updated_at);
  const expires = evidenceTimestamp(item.expires_at);
  if (item.status !== 'fresh' || !Number.isFinite(updated) || updated > now + 300000) { return 'unverified'; }
  if (item.expires_at !== null && (!Number.isFinite(expires) || expires <= updated)) { return 'unverified'; }
  if (Number.isFinite(expires) && expires <= now) { return 'stale'; }
  return 'fresh';
}

export function evidenceStatusLabel(status: string): string {
  if (status === 'fresh') { return '记录有效'; }
  if (status === 'stale') { return '已过期'; }
  if (status === 'missing') { return '尚无数据'; }
  if (status === 'error') { return '获取失败'; }
  if (status === 'demo') { return '演示数据'; }
  return '待核验';
}

export function evidenceKindLabel(kind: string): string {
  if (kind === 'user') { return '用户资料'; }
  if (kind === 'remote') { return '远端数据'; }
  if (kind === 'demo') { return '演示样例'; }
  return '参考资料';
}

export function evidenceSummary(items?: DataEvidence[], now: number = Date.now()): string {
  if (!Array.isArray(items) || items.length === 0) { return '来源未提供 · 待核验'; }
  const sources = normalizeEvidence(items);
  const statuses = sources.map((item: DataEvidence) => evidenceStatus(item, now));
  const priority = ['demo', 'error', 'missing', 'stale', 'unverified', 'fresh'];
  const status = priority.find((item: string) => statuses.includes(item)) ?? 'unverified';
  return `${sources.length} 项来源 · ${evidenceStatusLabel(status)}`;
}

export function evidenceTime(value: string | null): string {
  const timestamp = evidenceTimestamp(value);
  if (!Number.isFinite(timestamp)) { return '未提供'; }
  return `${new Date(timestamp + 8 * 3600000).toISOString().substring(0, 19).replace('T', ' ')}（上海）`;
}

export function hasFreshEvidence(items?: DataEvidence[], now: number = Date.now()): boolean {
  return Array.isArray(items) && items.length > 0 && normalizeEvidence(items).every((item: DataEvidence) =>
    evidenceStatus(item, now) === 'fresh' && item.kind !== 'demo');
}

export function openingStatus(place: CampusDataPlace, now: number = Date.now()): string {
  if (typeof place.open_now !== 'boolean' || !hasFreshEvidence(place.evidence, now)) { return '当前开放状态未知'; }
  return place.open_now ? '来源记录：开放中' : '来源记录：未开放';
}

export function validWeather(value: WeatherForecast, expectedDate: string): boolean {
  if (value === null || typeof value !== 'object' || value.date !== expectedDate || typeof value.available !== 'boolean' ||
    typeof value.location_label !== 'string' || value.location_label.trim().length === 0 || value.location_label.length > 300 ||
    !Array.isArray(value.evidence) || !(value.condition === null || typeof value.condition === 'string' && value.condition.length <= 100)) { return false; }
  const low = value.temperature_min_c;
  const high = value.temperature_max_c;
  const rain = value.precipitation_probability;
  if (!(low === null || typeof low === 'number' && Number.isFinite(low) && low >= -100 && low <= 70) ||
    !(high === null || typeof high === 'number' && Number.isFinite(high) && high >= -100 && high <= 70) ||
    !(rain === null || typeof rain === 'number' && Number.isFinite(rain) && rain >= 0 && rain <= 100) ||
    low !== null && high !== null && low > high) { return false; }
  return !value.available || (low !== null && high !== null && rain !== null &&
    typeof value.condition === 'string' && value.condition.trim().length > 0);
}

export function weatherUsable(value: WeatherForecast, now: number = Date.now()): boolean {
  return value !== null && typeof value === 'object' && validWeather(value, value.date) && value.available && hasFreshEvidence(value.evidence, now);
}
