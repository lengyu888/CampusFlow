import { PlanningTask, TimetableEntry } from '../model/ApiModels';

export interface AgendaRow {
  id: string;
  kind: 'course' | 'task';
  title: string;
  date: string;
  startTime: string;
  endTime: string;
  endDate: string;
  location: string;
  taskId: string | null;
  planId: string | null;
  done: boolean;
  startMs: number;
  endMs: number | null;
}

export interface DailyAgenda {
  today: string;
  rows: AgendaRow[];
  allDay: PlanningTask[];
  unscheduled: PlanningTask[];
  next: AgendaRow | null;
}

const SHANGHAI_OFFSET_MS: number = 8 * 60 * 60 * 1000;
const DAY_MS: number = 24 * 60 * 60 * 1000;

// Campus timetable dates use Asia/Shanghai, independently of the device timezone.
export function shanghaiDate(nowMs: number): string {
  const shifted = new Date(nowMs + SHANGHAI_OFFSET_MS);
  const year = `${shifted.getUTCFullYear()}`.padStart(4, '0');
  const month = `${shifted.getUTCMonth() + 1}`.padStart(2, '0');
  const day = `${shifted.getUTCDate()}`.padStart(2, '0');
  return `${year}-${month}-${day}`;
}

export function shanghaiTime(nowMs: number): string {
  const shifted = new Date(nowMs + SHANGHAI_OFFSET_MS);
  return `${shifted.getUTCHours()}`.padStart(2, '0') + ':' + `${shifted.getUTCMinutes()}`.padStart(2, '0');
}

function validDate(value: string): boolean {
  if (!new RegExp('^[0-9]{4}-[0-9]{2}-[0-9]{2}$').test(value)) { return false; }
  const year = Number(value.substring(0, 4));
  const month = Number(value.substring(5, 7));
  const day = Number(value.substring(8, 10));
  if (year < 1 || year > 9999 || month < 1 || month > 12 || day < 1) { return false; }
  const leap = year % 400 === 0 || (year % 4 === 0 && year % 100 !== 0);
  const lengths: number[] = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  return day <= lengths[month - 1];
}

function timestamp(value: string | null): number | null {
  if (value === null || typeof value !== 'string') { return null; }
  const match = new RegExp('^([0-9]{4}-[0-9]{2}-[0-9]{2})[Tt ]([01][0-9]|2[0-3]):([0-5][0-9])' +
    '(:[0-5][0-9](\\.[0-9]+)?)?([Zz]|[+-]([01][0-9]|2[0-3]):[0-5][0-9])?$').exec(value);
  if (match === null || !validDate(match[1])) { return null; }
  // Naive legacy timestamps follow the same campus timezone as timetable rows.
  const seconds = match[4] === undefined ? '00' : match[4].substring(1, 3);
  const fraction = match[5] === undefined ? '000' : match[5].substring(1, 4).padEnd(3, '0');
  const zone = match[6] === undefined ? '+08:00' : match[6].toUpperCase();
  const normalized = `${match[1]}T${match[2]}:${match[3]}:${seconds}.${fraction}${zone}`;
  const parsed = Date.parse(normalized);
  return Number.isFinite(parsed) ? parsed : null;
}

function courseTimestamp(date: string, time: string): number | null {
  if (!validDate(date) || !new RegExp('^([01][0-9]|2[0-3]):[0-5][0-9]$').test(time)) { return null; }
  return timestamp(`${date}T${time}:00+08:00`);
}

function overlapsDay(start: number, end: number | null, dayStart: number): boolean {
  const dayEnd = dayStart + DAY_MS;
  return end !== null && end > start ? start < dayEnd && end > dayStart : start >= dayStart && start < dayEnd;
}

function allDayDate(task: PlanningTask, start: number | null): string {
  if (task.start_at !== null && validDate(task.start_at)) { return task.start_at; }
  if (task.source === 'manual' && task.end_at === null && start !== null && shanghaiTime(start) === '23:59') {
    return shanghaiDate(start);
  }
  return '';
}

function taskRow(task: PlanningTask, start: number, end: number | null): AgendaRow {
  return {
    id: `task-${task.task_id}`, kind: 'task', title: task.title,
    date: shanghaiDate(start), startTime: shanghaiTime(start),
    endTime: end === null ? '' : shanghaiTime(end), endDate: end === null ? '' : shanghaiDate(end),
    location: task.location ?? '', taskId: task.task_id, planId: task.plan_id,
    done: task.status === 'completed', startMs: start, endMs: end
  };
}

export function buildDailyAgenda(courses: TimetableEntry[], tasks: PlanningTask[], nowMs: number): DailyAgenda {
  const today = shanghaiDate(nowMs);
  const dayStart = Date.parse(`${today}T00:00:00+08:00`);
  const rows: AgendaRow[] = [];
  const allDay: PlanningTask[] = [];
  const unscheduled: PlanningTask[] = [];
  courses.forEach((course: TimetableEntry, index: number) => {
    const start = courseTimestamp(course.date, course.start_time);
    const end = courseTimestamp(course.date, course.end_time);
    if (start === null || end === null || end <= start || !overlapsDay(start, end, dayStart)) { return; }
    rows.push({
      id: `course-${index}-${course.date}-${course.start_time}`, kind: 'course', title: course.title,
      date: course.date, startTime: course.start_time, endTime: course.end_time, endDate: course.date,
      location: course.location, taskId: null, planId: null, done: false, startMs: start, endMs: end
    });
  });
  tasks.forEach((task: PlanningTask) => {
    if (task.status !== 'pending' && task.status !== 'completed') { return; }
    if (task.start_at === null || (typeof task.start_at === 'string' && task.start_at.trim().length === 0)) {
      if (task.status === 'pending') { unscheduled.push(task); }
      return;
    }
    if (typeof task.start_at !== 'string') {
      if (task.status === 'pending') { unscheduled.push(task); }
      return;
    }
    const start = timestamp(task.start_at);
    const dateOnly = allDayDate(task, start);
    if (dateOnly.length > 0) {
      if (dateOnly === today) { allDay.push(task); }
      return;
    }
    if (start === null) {
      // Preserve pending items with malformed legacy dates for explicit time review.
      if (task.status === 'pending') { unscheduled.push(task); }
      return;
    }
    const parsedEnd = timestamp(task.end_at);
    const end = parsedEnd !== null && parsedEnd > start ? parsedEnd : null;
    if (overlapsDay(start, end, dayStart)) { rows.push(taskRow(task, start, end)); }
  });
  rows.sort((left: AgendaRow, right: AgendaRow) => {
    if (left.startMs !== right.startMs) { return left.startMs - right.startMs; }
    if (left.kind !== right.kind) { return left.kind === 'course' ? -1 : 1; }
    return left.id < right.id ? -1 : (left.id > right.id ? 1 : 0);
  });
  const next = rows.find((row: AgendaRow) => !row.done &&
    (row.startMs >= nowMs || (row.endMs !== null && row.endMs > nowMs)));
  return { today: today, rows: rows, allDay: allDay, unscheduled: unscheduled, next: next ?? null };
}

export function labelNext(row: AgendaRow, nowMs: number): string {
  if (row.done) { return '已完成'; }
  if (row.endMs !== null && row.endMs <= nowMs) { return '已结束'; }
  if (row.startMs <= nowMs) {
    return row.endMs !== null ? '正在进行' : (row.startMs === nowMs ? '现在开始' : '已到开始时间');
  }
  const minutes = Math.ceil((row.startMs - nowMs) / 60000);
  if (minutes < 60) { return `${minutes} 分钟后开始`; }
  const hours = Math.floor(minutes / 60);
  const remainder = minutes % 60;
  return remainder === 0 ? `${hours} 小时后开始` : `${hours} 小时 ${remainder} 分钟后开始`;
}
