import { PlanningTask, PlanningTaskDraft, TimetableEntry, TimetableSnapshot } from '../model/ApiModels';
import { AgendaRow, buildDailyAgenda, shanghaiDate, validDate, timestamp, courseTimestamp, allDayDate } from './DailyAgenda';

export interface TaskQuery {
  text: string;
  status: 'all' | 'pending' | 'completed';
  dateMode: 'all' | 'day' | 'range' | 'undated';
  fromDate: string;
  toDate: string;
  sort: 'schedule' | 'created';
}
export interface TaskQueryResult {
  tasks: PlanningTask[]; total: number; matched: number; invalidDateCount: number; valid: boolean; message: string;
}
export interface PlanningCourseRef {
  key: string; revision: string; course: TimetableEntry; occurrence: number;
}
export interface PlanningWeekRow extends AgendaRow {
  courseRef: PlanningCourseRef | null;
  displayDate: string;
  segmentStartMs: number;
  segmentEndMs: number | null;
}
export interface PlanningWeekDay { date: string; rows: PlanningWeekRow[]; allDay: PlanningTask[]; }
export interface PlanningWeek {
  startDate: string; endDate: string; days: PlanningWeekDay[]; undated: PlanningTask[];
  unplacedCourses: PlanningCourseRef[]; valid: boolean; message: string;
}
export interface PlanningDayLoad {
  date: string; valid: boolean; message: string;
  courseMinutes: number; taskMinutes: number; totalMinutes: number;
  timedCourseCount: number; timedTaskCount: number;
  allDayCount: number; undatedCount: number; incompleteTaskCount: number;
  invalidCourseCount: number; invalidTaskCount: number;
}
export interface PlanningLoadCandidate { task: PlanningTaskDraft; replaceTaskId: string | null; source: string; }
export interface PlanningCandidateProjection { tasks: PlanningTask[]; valid: boolean; message: string; }
interface Interval { start: number; end: number; }
interface TaskTime { start: number | null; end: number | null; allDay: string; invalidStart: boolean; invalidEnd: boolean; }

const DAY_MS: number = 86400000;
const OFFSET_MS: number = 28800000;

function timeOf(task: PlanningTask): TaskTime {
  const start = timestamp(task.start_at);
  const allDay = typeof task.start_at === 'string' || task.start_at === null ? allDayDate(task, start) : '';
  const rawEnd = timestamp(task.end_at);
  const end = start !== null && rawEnd !== null && rawEnd > start ? rawEnd : null;
  const missingStart = task.start_at === null || typeof task.start_at === 'string' && task.start_at.trim().length === 0;
  const missingEnd = task.end_at === null || typeof task.end_at === 'string' && task.end_at.trim().length === 0;
  return { start: start, end: end, allDay: allDay,
    invalidStart: !missingStart && start === null && allDay.length === 0,
    invalidEnd: allDay.length === 0 && !missingEnd && end === null };
}

function shownTask(task: PlanningTask): boolean { return task.status === 'pending' || task.status === 'completed'; }
function compareText(left: string, right: string): number { return left < right ? -1 : left > right ? 1 : 0; }
function dayStart(date: string): number | null { return typeof date === 'string' ? courseTimestamp(date, '00:00') : null; }
function sortStart(task: PlanningTask): number {
  const value = timeOf(task);
  return value.allDay.length > 0 ? dayStart(value.allDay) ?? Number.POSITIVE_INFINITY : value.start ?? Number.POSITIVE_INFINITY;
}
function compareTasks(left: PlanningTask, right: PlanningTask, sort: string): number {
  if (sort === 'schedule') {
    const a = sortStart(left); const b = sortStart(right);
    if (a !== b) { return a < b ? -1 : 1; }
  }
  const a = timestamp(left.created_at); const b = timestamp(right.created_at);
  if (a !== b) {
    if (a === null) { return 1; } if (b === null) { return -1; }
    return sort === 'created' ? b - a : a - b;
  }
  return compareText(left.task_id, right.task_id);
}

export function filterPlanningTasks(tasks: PlanningTask[], query: TaskQuery): TaskQueryResult {
  const result: TaskQueryResult = { tasks: [], total: tasks.length, matched: 0,
    invalidDateCount: tasks.filter((task: PlanningTask) => timeOf(task).invalidStart).length, valid: true, message: '' };
  const start = dayStart(query.fromDate);
  const finish = dayStart(query.dateMode === 'day' ? query.fromDate : query.toDate);
  if (!['all', 'pending', 'completed'].includes(query.status) || !['all', 'day', 'range', 'undated'].includes(query.dateMode) ||
    !['schedule', 'created'].includes(query.sort) || typeof query.text !== 'string' ||
    ['day', 'range'].includes(query.dateMode) && (start === null || finish === null || finish < start)) {
    result.valid = false; result.message = '筛选日期或条件无效，请重新选择。'; return result;
  }
  const search = query.text.trim().toLowerCase();
  result.tasks = tasks.filter((task: PlanningTask): boolean => {
    if (query.status !== 'all' && task.status !== query.status) { return false; }
    if (search.length > 0 && !task.title.toLowerCase().includes(search) && !(task.location ?? '').toLowerCase().includes(search)) { return false; }
    const value = timeOf(task);
    if (query.dateMode === 'all') { return true; }
    if (query.dateMode === 'undated') { return value.start === null && value.allDay.length === 0; }
    if (start === null || finish === null) { return false; }
    const rangeEnd = finish + DAY_MS;
    if (value.allDay.length > 0) {
      const date = dayStart(value.allDay); return date !== null && date >= start && date < rangeEnd;
    }
    if (value.start === null) { return false; }
    return value.end !== null ? value.start < rangeEnd && value.end > start : value.start >= start && value.start < rangeEnd;
  }).sort((left: PlanningTask, right: PlanningTask) => compareTasks(left, right, query.sort));
  result.matched = result.tasks.length;
  return result;
}

function courseFields(course: TimetableEntry): string {
  return JSON.stringify([course.date, course.title, course.start_time, course.end_time, course.location, course.teacher]);
}
function copyCourse(course: TimetableEntry): TimetableEntry {
  return { date: course.date, title: course.title, start_time: course.start_time, end_time: course.end_time,
    location: course.location, teacher: course.teacher };
}
function validCourse(course: TimetableEntry): boolean {
  if (course === null || typeof course !== 'object' || Array.isArray(course) ||
    typeof course.date !== 'string' || typeof course.title !== 'string' || course.title.trim().length === 0 ||
    typeof course.start_time !== 'string' || typeof course.end_time !== 'string' ||
    typeof course.location !== 'string' || typeof course.teacher !== 'string') { return false; }
  const start = courseTimestamp(course.date, course.start_time); const end = courseTimestamp(course.date, course.end_time);
  return start !== null && end !== null && end > start;
}

export function validPlanningTimetable(snapshot: TimetableSnapshot): boolean {
  return snapshot !== null && typeof snapshot === 'object' && !Array.isArray(snapshot) &&
    typeof snapshot.revision === 'string' && /^[a-f0-9]{64}$/.test(snapshot.revision) &&
    Array.isArray(snapshot.entries) && snapshot.entries.length <= 500 && snapshot.entries.every((course: TimetableEntry) => validCourse(course));
}

function courseReferences(courses: TimetableEntry[], revision: string): PlanningCourseRef[] {
  const seen: string[] = [];
  return courses.map((course: TimetableEntry): PlanningCourseRef => {
    const fields = courseFields(course);
    const occurrence = seen.filter((value: string) => value === fields).length + 1;
    seen.push(fields);
    return { key: JSON.stringify([revision, fields, occurrence]), revision: revision, course: copyCourse(course), occurrence: occurrence };
  });
}

export function resolvePlanningCourse(reference: PlanningCourseRef, courses: TimetableEntry[], currentRevision: string): TimetableEntry | null {
  if (reference === null || typeof reference !== 'object' || typeof currentRevision !== 'string' ||
    !/^[a-f0-9]{64}$/.test(currentRevision) || reference.revision !== currentRevision || !validCourse(reference.course) ||
    !Number.isInteger(reference.occurrence) || reference.occurrence < 1) { return null; }
  const fields = courseFields(reference.course);
  if (reference.key !== JSON.stringify([currentRevision, fields, reference.occurrence])) { return null; }
  const matches = courses.filter((course: TimetableEntry) => validCourse(course) && courseFields(course) === fields);
  const found = matches[reference.occurrence - 1];
  return found === undefined ? null : copyCourse(found);
}

function weekRow(row: AgendaRow, date: string, start: number, reference: PlanningCourseRef | null): PlanningWeekRow {
  return { id: reference === null ? `${row.id}-${date}` : reference.key, kind: row.kind, title: row.title, date: row.date,
    startTime: row.startTime, endTime: row.endTime, endDate: row.endDate, location: row.location,
    taskId: row.taskId, planId: row.planId, done: row.done, startMs: row.startMs, endMs: row.endMs,
    courseRef: reference, displayDate: date, segmentStartMs: Math.max(start, row.startMs),
    segmentEndMs: row.endMs === null ? null : Math.min(start + DAY_MS, row.endMs) };
}

export function buildPlanningWeek(courses: TimetableEntry[], revision: string, tasks: PlanningTask[], anchorDate: string): PlanningWeek {
  const result: PlanningWeek = { startDate: '', endDate: '', days: [], undated: [], unplacedCourses: [], valid: true, message: '' };
  const anchor = dayStart(anchorDate);
  if (anchor === null) { result.valid = false; result.message = '所选日期无效，尚未生成周总览。'; return result; }
  const weekday = new Date(anchor + OFFSET_MS).getUTCDay();
  const monday = anchor - ((weekday + 6) % 7) * DAY_MS;
  result.startDate = shanghaiDate(monday); result.endDate = shanghaiDate(monday + 6 * DAY_MS);
  if (!validDate(result.startDate) || !validDate(result.endDate)) {
    result.valid = false; result.message = '所选周超出支持的日期范围。'; return result;
  }
  const references = courseReferences(courses, revision);
  result.unplacedCourses = references.filter((reference: PlanningCourseRef) => !validCourse(reference.course));
  result.undated = tasks.filter((task: PlanningTask): boolean => {
    const value = timeOf(task); return shownTask(task) && value.start === null && value.allDay.length === 0;
  }).sort((left: PlanningTask, right: PlanningTask) => compareTasks(left, right, 'schedule'));
  for (let index = 0; index < 7; index++) {
    const start = monday + index * DAY_MS; const date = shanghaiDate(start);
    const agenda = buildDailyAgenda([], tasks, start);
    const rows = agenda.rows.map((row: AgendaRow) => weekRow(row, date, start, null));
    references.forEach((reference: PlanningCourseRef) => {
      if (!validCourse(reference.course)) { return; }
      const courseRows = buildDailyAgenda([reference.course], [], start).rows;
      if (courseRows.length > 0) { rows.push(weekRow(courseRows[0], date, start, reference)); }
    });
    rows.sort((left: PlanningWeekRow, right: PlanningWeekRow): number => {
      if (left.startMs !== right.startMs) { return left.startMs - right.startMs; }
      if (left.kind !== right.kind) { return left.kind === 'course' ? -1 : 1; }
      return compareText(left.id, right.id);
    });
    result.days.push({ date: date, rows: rows, allDay: agenda.allDay.slice().sort((left: PlanningTask, right: PlanningTask) => compareTasks(left, right, 'schedule')) });
  }
  return result;
}

function unionMinutes(intervals: Interval[]): number {
  const sorted = intervals.slice().sort((left: Interval, right: Interval) => left.start - right.start || left.end - right.end);
  let start = 0; let end = 0; let total = 0; let hasInterval = false;
  sorted.forEach((interval: Interval) => {
    if (!hasInterval) { start = interval.start; end = interval.end; hasInterval = true; }
    else if (interval.start <= end) { end = Math.max(end, interval.end); }
    else { total += end - start; start = interval.start; end = interval.end; }
  });
  if (hasInterval) { total += end - start; }
  return total / 60000;
}

// This measures scheduled occupancy, including completed scheduled tasks; never actual study time.
// A user-enabled daily_minutes goal should be compared with taskMinutes only, not totalMinutes.
export function dailyPlannedLoad(courses: TimetableEntry[], tasks: PlanningTask[], date: string): PlanningDayLoad {
  const result: PlanningDayLoad = { date: date, valid: true, message: '', courseMinutes: 0, taskMinutes: 0, totalMinutes: 0,
    timedCourseCount: 0, timedTaskCount: 0, allDayCount: 0, undatedCount: 0, incompleteTaskCount: 0,
    invalidCourseCount: 0, invalidTaskCount: 0 };
  const start = dayStart(date);
  if (start === null) { result.valid = false; result.message = '所选日期无效，尚未计算预计负荷。'; return result; }
  const end = start + DAY_MS; const courseIntervals: Interval[] = []; const taskIntervals: Interval[] = [];
  courses.forEach((course: TimetableEntry) => {
    if (!validCourse(course)) {
      if (!validDate(course.date) || course.date === date) { result.invalidCourseCount++; }
      return;
    }
    const from = courseTimestamp(course.date, course.start_time); const to = courseTimestamp(course.date, course.end_time);
    if (from !== null && to !== null && from < end && to > start) {
      courseIntervals.push({ start: Math.max(start, from), end: Math.min(end, to) }); result.timedCourseCount++;
    }
  });
  tasks.forEach((task: PlanningTask) => {
    if (!shownTask(task)) { return; }
    const value = timeOf(task);
    if (value.allDay.length > 0) { if (value.allDay === date) { result.allDayCount++; } return; }
    if (value.start === null) {
      if (value.invalidStart) { result.invalidTaskCount++; } else { result.undatedCount++; }
      return;
    }
    if (value.end === null) {
      if (value.start >= start && value.start < end) {
        if (value.invalidEnd) { result.invalidTaskCount++; } else { result.incompleteTaskCount++; }
      }
      return;
    }
    if (value.start < end && value.end > start) {
      taskIntervals.push({ start: Math.max(start, value.start), end: Math.min(end, value.end) }); result.timedTaskCount++;
    }
  });
  result.courseMinutes = unionMinutes(courseIntervals); result.taskMinutes = unionMinutes(taskIntervals);
  result.totalMinutes = unionMinutes(courseIntervals.concat(taskIntervals));
  if (result.invalidCourseCount + result.invalidTaskCount + result.incompleteTaskCount + result.allDayCount + result.undatedCount > 0) {
    result.message = '仅合计明确时段；全天、未定时及时间待核对事项未计入分钟。';
  }
  return result;
}

export function projectPlanningCandidate(tasks: PlanningTask[], candidate: PlanningLoadCandidate): PlanningCandidateProjection {
  const result: PlanningCandidateProjection = { tasks: tasks.slice(), valid: true, message: '' };
  const existing = candidate.replaceTaskId === null ? [] : tasks.filter((task: PlanningTask) => task.task_id === candidate.replaceTaskId);
  if (candidate.replaceTaskId !== null && (candidate.replaceTaskId.length === 0 || existing.length !== 1)) {
    result.valid = false; result.message = '原任务已变化或编号不唯一，未计算编辑后的负荷，请刷新。'; return result;
  }
  let localId = 'planning-preview';
  while (tasks.some((task: PlanningTask) => task.task_id === localId)) { localId += '-new'; }
  const old = existing[0]; const draft = candidate.task;
  const projected: PlanningTask = { task_id: old?.task_id ?? localId, plan_id: old?.plan_id ?? null,
    milestone_id: old?.milestone_id ?? null, title: draft.title, start_at: draft.start_at, end_at: draft.end_at,
    reminder_minutes: draft.reminder_minutes, location: draft.location, status: old?.status ?? 'pending',
    source: old?.source ?? candidate.source, created_at: old?.created_at ?? '', completed_at: old?.completed_at ?? null,
    allow_during_course: draft.allow_during_course ?? old?.allow_during_course ?? false };
  if (old === undefined) { result.tasks.push(projected); }
  else { result.tasks = tasks.map((task: PlanningTask) => task.task_id === old.task_id ? projected : task); }
  return result;
}
