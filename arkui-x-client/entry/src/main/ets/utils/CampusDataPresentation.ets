import { CampusDataIssue, CampusDataStatus, HDUHelpDisplaySection } from '../model/ApiModels';
import { CampusFlowRequestError } from './AgentFeedback';

interface CampusResourceTitle { key: string; title: string; }

const resourceTitles: CampusResourceTitle[] = [
  { key: 'identity', title: 'HDUHelp 身份' }, { key: 'person', title: '学籍信息' },
  { key: 'grades', title: '成绩' }, { key: 'exams', title: '考试安排' }, { key: 'card_balance', title: '校园卡余额' },
  { key: 'library_bookings', title: '图书馆预约' }, { key: 'library_attendance', title: '图书馆到馆' },
  { key: 'library_reading', title: '图书馆借阅' }, { key: 'library_seat_reservations', title: '图书馆座位记录' },
  { key: 'sunrun_overview', title: '阳光长跑' }, { key: 'sunrun_group', title: '长跑达标要求' },
  { key: 'sunrun_detail', title: '最近跑步记录' }, { key: 'subscriptions', title: '校园订阅' }
];

export function campusSectionsWithStatus(sections: HDUHelpDisplaySection[], statuses: Record<string, CampusDataStatus>): HDUHelpDisplaySection[] {
  const missing: HDUHelpDisplaySection[] = [];
  resourceTitles.forEach((resource: CampusResourceTitle) => {
    if (statuses[resource.key] !== undefined && !sections.some((section: HDUHelpDisplaySection) => section.resource === resource.key)) {
      missing.push({ resource: resource.key, title: resource.title, summary: '', items: [] });
    }
  });
  return sections.concat(missing);
}

export function campusStatusLabel(status: CampusDataStatus): string {
  if (status.state === 'live') { return '本次已更新'; }
  if (status.state === 'cached') { return '缓存数据'; }
  if (status.state === 'stale') { return '旧数据'; }
  if (status.state === 'unverified') { return '待核验'; }
  return '暂不可用';
}

export function currentCampusStatus(status: CampusDataStatus, now: number = Date.now()): CampusDataStatus {
  if ((status.state === 'live' || status.state === 'cached') && status.expires_at !== null &&
    Date.parse(status.expires_at) <= now) {
    return { state: 'stale', updated_at: status.updated_at, expires_at: status.expires_at, issue: status.issue,
      message: status.issue === null ? '这份数据已超过有效期。' : status.message, action: status.action };
  }
  return status;
}

export function campusStatusFailure(error: Error, fallback: string, previous: CampusDataStatus | null,
  hasPrevious: boolean): CampusDataStatus {
  const code = error instanceof CampusFlowRequestError ? error.code : '';
  let issue: CampusDataIssue = 'upstream_error';
  if (code === 'HDUHELP_NOT_CONNECTED') { issue = 'not_connected'; }
  else if (code === 'HDUHELP_AUTH_INVALID') { issue = 'auth_invalid'; }
  else if (code === 'HDUHELP_FORBIDDEN') { issue = 'forbidden'; }
  else if (code === 'HDUHELP_TIMEOUT') { issue = 'timeout'; }
  else if (code === 'HDUHELP_CONNECTION_CHANGED') { issue = 'connection_changed'; }
  else if (code === 'HDUHELP_CACHE_UNREADABLE') { issue = 'cache_unreadable'; }
  const keep = hasPrevious && issue !== 'not_connected' && issue !== 'connection_changed' && code !== 'LOGIN_REQUIRED';
  const message = code.startsWith('HDUHELP_') || code === 'LOGIN_REQUIRED' || code === 'NETWORK_ERROR' ? error.message : fallback;
  return { state: keep ? 'stale' : 'unavailable', updated_at: keep ? (previous?.updated_at ?? null) : null,
    expires_at: keep ? (previous?.expires_at ?? null) : null, issue: issue, message: message,
    action: code === 'LOGIN_REQUIRED' ? 'none' :
      (issue === 'not_connected' || issue === 'auth_invalid' || issue === 'forbidden') ? 'connect' : 'retry' };
}

export function replaceCampusResourceStatus(statuses: Record<string, CampusDataStatus>, resource: string,
  status: CampusDataStatus): Record<string, CampusDataStatus> {
  const next: Record<string, CampusDataStatus> = {};
  Object.keys(statuses).forEach((key: string) => { next[key] = statuses[key]; });
  next[resource] = status;
  return next;
}

export function previousCampusStatuses(statuses: Record<string, CampusDataStatus>, now: number = Date.now()): Record<string, CampusDataStatus> {
  const previous: Record<string, CampusDataStatus> = {};
  Object.keys(statuses).forEach((key: string) => {
    const status = currentCampusStatus(statuses[key], now);
    previous[key] = status.state === 'live' ? { state: 'cached', updated_at: status.updated_at, expires_at: status.expires_at,
      issue: status.issue, message: status.issue === null ? '显示上次获取的数据。' : status.message, action: status.action } : status;
  });
  return previous;
}
