import { TimetableEntry } from '../model/ApiModels';

export interface TimetableFieldErrors {
  date: string;
  title: string;
  start_time: string;
  end_time: string;
  location: string;
  teacher: string;
}

export interface TimetableEntryValidation {
  valid: boolean;
  entry: TimetableEntry;
  errors: TimetableFieldErrors;
}

export interface TimetableIssue {
  // Zero-based row indexes; -1 denotes the whole list or an import warning.
  index: number;
  relatedIndex: number;
  field: string;
  message: string;
}

export interface TimetableValidation {
  valid: boolean;
  entries: TimetableEntry[];
  errors: TimetableIssue[];
  warnings: TimetableIssue[];
}

interface TimetablePreviewPayload {
  event_count: number;
  entries: TimetableEntry[];
  warnings?: string[];
}

function textValue(value: string): string {
  return typeof value === 'string' ? value.trim() : '';
}

function emptyEntry(): TimetableEntry {
  return { date: '', title: '', start_time: '', end_time: '', location: '', teacher: '' };
}

// Explicitly copy the public fields. Normalization never truncates content or mutates its source.
export function normalizeTimetableEntry(entry: TimetableEntry): TimetableEntry {
  if (entry === null || typeof entry !== 'object' || Array.isArray(entry)) {
    return emptyEntry();
  }
  return {
    date: textValue(entry.date),
    title: textValue(entry.title),
    start_time: textValue(entry.start_time),
    end_time: textValue(entry.end_time),
    location: textValue(entry.location),
    teacher: textValue(entry.teacher)
  };
}

function validDate(value: string): boolean {
  if (!new RegExp('^[0-9]{4}-[0-9]{2}-[0-9]{2}$').test(value)) {
    return false;
  }
  const year = Number(value.substring(0, 4));
  const month = Number(value.substring(5, 7));
  const day = Number(value.substring(8, 10));
  // Python's date schema accepts years 0001..9999; do not impose a different client range.
  if (year < 1 || year > 9999 || month < 1 || month > 12 || day < 1) {
    return false;
  }
  const leap = year % 400 === 0 || (year % 4 === 0 && year % 100 !== 0);
  const monthDays: number[] = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  return day <= monthDays[month - 1];
}

function validTime(value: string): boolean {
  return new RegExp('^([01][0-9]|2[0-3]):[0-5][0-9]$').test(value);
}

export function validateTimetableEntry(entry: TimetableEntry): TimetableEntryValidation {
  const normalized = normalizeTimetableEntry(entry);
  const errors: TimetableFieldErrors = {
    date: '', title: '', start_time: '', end_time: '', location: '', teacher: ''
  };
  if (entry === null || typeof entry !== 'object' || Array.isArray(entry)) {
    errors.title = '课程数据格式无效，请重新填写或导入。';
    return { valid: false, entry: normalized, errors: errors };
  }
  if (!validDate(normalized.date)) {
    errors.date = '请填写真实日期，格式为 YYYY-MM-DD（年份 0001–9999）。';
  }
  if (normalized.title.length === 0) {
    errors.title = '请填写课程名称。';
  } else if (Array.from(normalized.title).length > 100) {
    errors.title = '课程名称最多 100 字，原文已保留，请编辑缩短。';
  }
  if (!validTime(normalized.start_time)) {
    errors.start_time = '开始时间须为 HH:mm，例如 08:05。';
  }
  if (!validTime(normalized.end_time)) {
    errors.end_time = '结束时间须为 HH:mm，例如 09:40。';
  } else if (errors.start_time.length === 0 && normalized.end_time <= normalized.start_time) {
    errors.end_time = '结束时间须晚于开始时间，且在同一天。';
  }
  if (entry.location !== undefined && typeof entry.location !== 'string') {
    errors.location = '上课地点须为文字，可留空。';
  } else if (Array.from(normalized.location).length > 120) {
    errors.location = '上课地点最多 120 字，原文已保留，请编辑缩短。';
  }
  if (entry.teacher !== undefined && typeof entry.teacher !== 'string') {
    errors.teacher = '教师姓名须为文字，可留空。';
  } else if (Array.from(normalized.teacher).length > 80) {
    errors.teacher = '教师姓名最多 80 字，原文已保留，请编辑缩短。';
  }
  const valid = errors.date.length === 0 && errors.title.length === 0 && errors.start_time.length === 0 &&
    errors.end_time.length === 0 && errors.location.length === 0 && errors.teacher.length === 0;
  return { valid: valid, entry: normalized, errors: errors };
}

function listFailure(field: string, message: string): TimetableValidation {
  const issue: TimetableIssue = { index: -1, relatedIndex: -1, field: field, message: message };
  return { valid: false, entries: [], errors: [issue], warnings: [] };
}

function appendFieldError(issues: TimetableIssue[], index: number, field: string, message: string): void {
  if (message.length > 0) {
    issues.push({ index: index, relatedIndex: -1, field: field, message: message });
  }
}

function entryIdentity(entry: TimetableEntry): string {
  // JSON encoding keeps separators inside titles/locations from producing false duplicates.
  return JSON.stringify([entry.date, entry.title, entry.start_time, entry.end_time, entry.location, entry.teacher]);
}

export function validateTimetableList(entries: TimetableEntry[], allowEmpty: boolean = false): TimetableValidation {
  if (!Array.isArray(entries)) {
    return listFailure('entries', '课表数据格式无效，原课表草稿未替换。');
  }
  if (entries.length > 500) {
    return listFailure('entries', '课表最多 500 项，请减少课程后重试；未截取或替换原草稿。');
  }
  if (entries.length === 0 && !allowEmpty) {
    return listFailure('entries', '没有可确认的课程，请先添加或导入；原课表草稿未替换。');
  }
  const normalized: TimetableEntry[] = [];
  const errors: TimetableIssue[] = [];
  const warnings: TimetableIssue[] = [];
  const validRows: boolean[] = [];
  const identities: string[] = [];
  const seen = new Map<string, number>();
  const overlapWith: number[] = [];
  for (let index = 0; index < entries.length; index++) {
    const checked = validateTimetableEntry(entries[index]);
    normalized.push(checked.entry);
    validRows.push(checked.valid);
    overlapWith.push(-1);
    const fields = checked.errors;
    appendFieldError(errors, index, 'date', fields.date);
    appendFieldError(errors, index, 'title', fields.title);
    appendFieldError(errors, index, 'start_time', fields.start_time);
    appendFieldError(errors, index, 'end_time', fields.end_time);
    appendFieldError(errors, index, 'location', fields.location);
    appendFieldError(errors, index, 'teacher', fields.teacher);
    const identity = entryIdentity(checked.entry);
    identities.push(identity);
    if (checked.valid) {
      const first = seen.get(identity);
      if (first !== undefined) {
        errors.push({ index: index, relatedIndex: first, field: 'duplicate',
          message: `第 ${index + 1} 项与第 ${first + 1} 项课程完全相同，请编辑或删除重复项。` });
      } else {
        seen.set(identity, index);
      }
    }
  }
  for (let left = 0; left < normalized.length; left++) {
    if (!validRows[left]) { continue; }
    for (let right = left + 1; right < normalized.length; right++) {
      if (!validRows[right] || identities[left] === identities[right]) { continue; }
      const a = normalized[left];
      const b = normalized[right];
      if (a.date === b.date && a.start_time < b.end_time && b.start_time < a.end_time) {
        if (overlapWith[left] < 0) { overlapWith[left] = right; }
        if (overlapWith[right] < 0) { overlapWith[right] = left; }
      }
    }
  }
  // One warning per affected row bounds the UI output even for 500 overlapping courses.
  for (let index = 0; index < overlapWith.length; index++) {
    const other = overlapWith[index];
    if (other >= 0) {
      warnings.push({ index: index, relatedIndex: other, field: 'overlap',
        message: `第 ${index + 1} 项与第 ${other + 1} 项课程时间重叠，请核对；未自动删除。` });
    }
  }
  return { valid: errors.length === 0, entries: normalized, errors: errors, warnings: warnings };
}

// Parse an API JSON projection without trusting its compile-time type. Callers may
// replace the editable draft only when valid is true; failures return no candidate rows.
export function parseTimetablePreview(json: string): TimetableValidation {
  let preview: TimetablePreviewPayload | null;
  try {
    preview = JSON.parse(json) as TimetablePreviewPayload | null;
  } catch {
    return listFailure('preview', '课表预览格式无效，请重新导入；原草稿未替换。');
  }
  if (preview === null || typeof preview !== 'object' || Array.isArray(preview) ||
    !Array.isArray(preview.entries) || typeof preview.event_count !== 'number' ||
    !Number.isInteger(preview.event_count) || preview.event_count !== preview.entries.length) {
    return listFailure('preview', '课表预览结构或课程数量不一致，请重新导入；原草稿未替换。');
  }
  const result = validateTimetableList(preview.entries);
  if (!result.valid) {
    return { valid: false, entries: [], errors: result.errors, warnings: result.warnings };
  }
  if (preview.warnings !== undefined) {
    if (!Array.isArray(preview.warnings) || preview.warnings.length > 20) {
      return listFailure('preview', '课表预览提示格式无效，请重新导入；原草稿未替换。');
    }
    for (const warning of preview.warnings) {
      if (typeof warning !== 'string') {
        return listFailure('preview', '课表预览提示格式无效，请重新导入；原草稿未替换。');
      }
      if (warning.trim().length > 0) {
        result.warnings.push({ index: -1, relatedIndex: -1, field: 'import', message: warning.trim() });
      }
    }
  }
  return result;
}

export function expandWeeklyEntry(entry: TimetableEntry, weeks: number): TimetableValidation {
  if (!Number.isInteger(weeks) || weeks < 1 || weeks > 24) {
    return listFailure('weeks', '重复周数须为 1 至 24 的整数，原课表草稿未替换。');
  }
  const initial = validateTimetableList([entry]);
  if (!initial.valid) { return initial; }
  const normalized = initial.entries[0];
  // Avoid Date.UTC's special 1900 offset for years 00..99 and all local DST transitions.
  const date = new Date(0);
  date.setUTCFullYear(Number(normalized.date.substring(0, 4)), Number(normalized.date.substring(5, 7)) - 1,
    Number(normalized.date.substring(8, 10)));
  date.setUTCHours(0, 0, 0, 0);
  const entries: TimetableEntry[] = [];
  for (let week = 0; week < weeks; week++) {
    if (date.getUTCFullYear() > 9999) {
      return listFailure('date', '重复课程超出 9999 年，未生成部分课表；请减少周数。');
    }
    const item = normalizeTimetableEntry(normalized);
    item.date = `${String(date.getUTCFullYear()).padStart(4, '0')}-${String(date.getUTCMonth() + 1).padStart(2, '0')}-${String(date.getUTCDate()).padStart(2, '0')}`;
    entries.push(item);
    date.setUTCDate(date.getUTCDate() + 7);
  }
  return validateTimetableList(entries);
}
