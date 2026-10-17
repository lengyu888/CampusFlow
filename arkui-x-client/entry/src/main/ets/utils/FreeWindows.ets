import { TimetableEntry, PlanningTask } from '../model/ApiModels';
import { AgendaRow, buildDailyAgenda, shanghaiDate, shanghaiTime } from './DailyAgenda';
import { validateTimetableEntry } from './OnboardingTimetable';

export interface TodayGroups {
  upcoming: AgendaRow[];
  overdue: AgendaRow[];
  earlier: AgendaRow[];
}

export interface FreeWindow {
  date: string;
  startTime: string;
  endTime: string;
  startMs: number;
  endMs: number;
  durationMinutes: number;
  bufferMinutes: number;
}

export interface FreeWindowResult {
  window: FreeWindow | null;
  reason: string;
  untimedCount: number;
}

interface BusyInterval { start: number; end: number; }

// Every displayed row belongs to exactly one group. A missing end never means finished.
export function partitionToday(rows: AgendaRow[], nowMs: number): TodayGroups {
  const result: TodayGroups = { upcoming: [], overdue: [], earlier: [] };
  rows.forEach((row: AgendaRow) => {
    if (row.done || row.kind === 'course' && row.endMs !== null && row.endMs <= nowMs) {
      result.earlier.push(row);
    } else if (row.kind === 'task' && row.endMs !== null && row.endMs <= nowMs) {
      result.overdue.push(row);
    } else { result.upcoming.push(row); }
  });
  return result;
}

// This is only a probe day for the existing strict agenda parser, never an accepted task timestamp.
function probeDay(start: string, nowMs: number): number {
  if (/^\d{4}-\d{2}-\d{2}$/.test(start)) { return Date.parse(`${start}T12:00:00+08:00`); }
  const probe = Date.parse(/[zZ]$|[+-]\d{2}:\d{2}$/.test(start) ? start : `${start}+08:00`);
  return Number.isFinite(probe) ? probe : nowMs;
}

export function findFreeWindow(courses: TimetableEntry[], tasks: PlanningTask[], nowMs: number,
  bufferMinutes: number, sourcesReady: boolean): FreeWindowResult {
  const none: FreeWindowResult = { window: null, reason: '', untimedCount: 0 };
  if (!sourcesReady) { none.reason = '课表与待办尚未完整核对，暂不建议空档。'; return none; }
  if (!Number.isFinite(nowMs) || ![0, 5, 10, 15].includes(bufferMinutes)) {
    none.reason = '请先核对当前时间与预留缓冲。'; return none;
  }
  const date = shanghaiDate(nowMs);
  const dayStart = Date.parse(`${date}T00:00:00+08:00`);
  const dayEnd = dayStart + 86400000;
  const intervals: BusyInterval[] = [];
  for (let index = 0; index < courses.length; index++) {
    const validation = validateTimetableEntry(courses[index]);
    if (!validation.valid || validation.entry.date !== courses[index].date ||
      validation.entry.start_time !== courses[index].start_time || validation.entry.end_time !== courses[index].end_time) {
      none.reason = '有课程时间尚待核对，暂不建议空档。'; return none;
    }
  }
  buildDailyAgenda(courses, [], nowMs).rows.forEach((row: AgendaRow) => {
    if (row.endMs !== null) { intervals.push({ start: row.startMs, end: row.endMs }); }
  });
  for (let index = 0; index < tasks.length; index++) {
    const task = tasks[index];
    if (task === null || typeof task !== 'object' || !['pending', 'completed', 'cancelled'].includes(task.status)) {
      none.reason = '有待办状态尚待核对，暂不建议空档。'; return none;
    }
    if (task.status !== 'pending') { continue; }
    if (task.start_at === null || typeof task.start_at === 'string' && task.start_at.trim().length === 0) {
      none.untimedCount++; continue;
    }
    if (typeof task.start_at !== 'string') {
      none.reason = '有待办日期尚待核对，暂不建议空档。'; return none;
    }
    const parsed = buildDailyAgenda([], [task], probeDay(task.start_at, nowMs));
    if (parsed.allDay.length > 0) {
      if (parsed.today === date) { none.untimedCount++; }
      continue;
    }
    const row = parsed.rows[0];
    if (row === undefined) { none.reason = '有待办日期尚待核对，暂不建议空档。'; return none; }
    if (row.endMs === null) {
      // An older start-only task may still be active. Do not invent an end at midnight or now.
      if (row.startMs < dayEnd) { none.reason = '有待办缺少有效结束时间，请先核对，暂不建议空档。'; return none; }
      continue;
    }
    if (row.startMs < dayEnd && row.endMs > dayStart) {
      intervals.push({ start: row.startMs, end: row.endMs });
    }
  }
  intervals.sort((left: BusyInterval, right: BusyInterval) => left.start - right.start);
  const buffer = bufferMinutes * 60000;
  const duration = 25 * 60000;
  // Explicit user buffer is reserved before and after existing timed entries, not estimated travel.
  let cursor = Math.ceil(nowMs / 60000) * 60000;
  for (let index = 0; index <= intervals.length; index++) {
    const interval = index < intervals.length ? intervals[index] : null;
    const end = interval === null ? dayEnd : Math.min(dayEnd, interval.start - buffer);
    if (end - cursor >= duration) {
      none.window = { date: date, startTime: shanghaiTime(cursor), endTime: end === dayEnd ? '24:00' : shanghaiTime(end),
        startMs: cursor, endMs: end, durationMinutes: 25, bufferMinutes: bufferMinutes };
      return none;
    }
    if (interval !== null) { cursor = Math.max(cursor, interval.end + buffer); }
    if (cursor >= dayEnd) { break; }
  }
  none.reason = '今日剩余时段中，未找到可放入 25 分钟的明确空档。';
  return none;
}
