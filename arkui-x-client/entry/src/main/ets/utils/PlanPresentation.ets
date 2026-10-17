// Campus schedules use Asia/Shanghai. Keep preview and saved task details consistent.
export function formatPlanDateTime(value: string | null): string {
  if (value === null || value.trim().length === 0) {
    return '未设置时间';
  }
  const text = value.trim();
  if (/^\d{4}-\d{2}-\d{2}$/.test(text)) {
    return text;
  }
  const zoned = /Z$|[+-]\d{2}:\d{2}$/.test(text) ? text : `${text}+08:00`;
  const timestamp = new Date(zoned).getTime();
  if (!Number.isFinite(timestamp)) {
    return '时间格式异常';
  }
  return new Date(timestamp + 8 * 60 * 60 * 1000).toISOString().substring(0, 16).replace('T', ' ');
}

export function formatPlanTimeRange(startAt: string | null, endAt: string | null): string {
  const hasStart = startAt !== null && startAt.trim().length > 0;
  const hasEnd = endAt !== null && endAt.trim().length > 0;
  if (!hasStart && !hasEnd) {
    return '待安排时间';
  }
  if (!hasStart) {
    return `开始未设置 · 结束 ${formatPlanDateTime(endAt)}`;
  }
  if (!hasEnd) {
    return `${formatPlanDateTime(startAt)} · 结束未设置`;
  }
  const start = formatPlanDateTime(startAt);
  const end = formatPlanDateTime(endAt);
  if (start.length === 16 && end.length === 16 && start.substring(0, 10) === end.substring(0, 10)) {
    return `${start}–${end.substring(11, 16)}`;
  }
  return `${start} 至 ${end}`;
}

export function formatPlanReminder(minutes: number | null): string {
  if (minutes === null) {
    return '未设置';
  }
  return minutes === 0 ? '任务开始时' : `提前 ${minutes} 分钟`;
}
