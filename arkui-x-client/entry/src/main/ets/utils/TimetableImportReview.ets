import { ScheduleImportIssue, ScheduleImportRow, ScheduleImportSourceTime, ScheduleSubscriptionPreview, TimetableEntry } from '../model/ApiModels';
import { TimetableIssue, TimetableFieldErrors, normalizeTimetableEntry, validateTimetableEntry, validateTimetableList } from './OnboardingTimetable';

export interface ImportReviewParse {
  valid: boolean; message: string; rows: ScheduleImportRow[]; sourceWarnings: TimetableIssue[];
  calendarName: string; sourceCount: number;
}
export interface ImportRowChoice {
  sourceIndex: number;
  mode: 'default' | 'include' | 'exclude';
  edited: TimetableEntry | null;
  sourceIssuesReviewed: boolean;
  // Acknowledges this exact edited row and every currently relevant overlap, not a Boolean permission.
  overlapKey: string;
}
export interface ImportOverlap { kind: 'draft' | 'import'; index: number; entry: TimetableEntry; }
export interface ImportReviewRow {
  sourceIndex: number; original: ScheduleImportRow; input: TimetableEntry; entry: TimetableEntry | null;
  category: 'new' | 'duplicate' | 'overlap' | 'invalid'; selected: boolean; excluded: boolean;
  issues: TimetableIssue[]; sourceIssues: ScheduleImportIssue[]; overlaps: ImportOverlap[];
  overlapKey: string; needsSourceReview: boolean;
}
export interface ImportClassification {
  valid: boolean; message: string; rows: ImportReviewRow[];
  addCount: number; duplicateCount: number; overlapCount: number; invalidCount: number;
  excludedCount: number; unresolvedCount: number;
}
export interface ImportAssembly {
  valid: boolean; message: string; entries: TimetableEntry[]; addedEntries: TimetableEntry[];
  warnings: TimetableIssue[]; excludedCount: number; duplicateCount: number;
}

function rawEntry(value: TimetableEntry): boolean {
  return value !== null && typeof value === 'object' && !Array.isArray(value) &&
    typeof value.date === 'string' && typeof value.title === 'string' && typeof value.start_time === 'string' &&
    typeof value.end_time === 'string' && typeof value.location === 'string' && typeof value.teacher === 'string';
}
function copyEntry(value: TimetableEntry): TimetableEntry {
  return { date: value.date, title: value.title, start_time: value.start_time, end_time: value.end_time,
    location: value.location, teacher: value.teacher };
}
function identity(value: TimetableEntry): string {
  return JSON.stringify([value.date, value.title, value.start_time, value.end_time, value.location, value.teacher]);
}
function nullableString(value: string | null): boolean { return value === null || typeof value === 'string'; }
function sourceTime(value: ScheduleImportSourceTime): boolean {
  return value !== null && typeof value === 'object' && !Array.isArray(value) &&
    nullableString(value.start_value) && nullableString(value.end_value) && nullableString(value.start_tzid) &&
    nullableString(value.end_tzid) && nullableString(value.start_value_type) && nullableString(value.end_value_type);
}
function validIssue(value: ScheduleImportIssue): boolean {
  return value !== null && typeof value === 'object' && !Array.isArray(value) &&
    ['event', 'date', 'title', 'start_time', 'end_time', 'location', 'teacher'].includes(value.field) &&
    typeof value.code === 'string' && value.code.length > 0 && typeof value.message === 'string' &&
    value.message.trim().length > 0 && ['warning', 'error'].includes(value.severity);
}
function validSourceRow(row: ScheduleImportRow, index: number): boolean {
  if (row === null || typeof row !== 'object' || Array.isArray(row) || row.source_index !== index ||
    !['ready', 'invalid', 'unsupported'].includes(row.status) || !rawEntry(row.input) || !sourceTime(row.source_time) ||
    !Array.isArray(row.issues) || !row.issues.every((issue: ScheduleImportIssue) => validIssue(issue))) { return false; }
  const hasError = row.issues.some((issue: ScheduleImportIssue) => issue.severity === 'error');
  if (row.status !== 'ready') { return row.entry === null && hasError; }
  if (!rawEntry(row.entry) || hasError) { return false; }
  const checked = validateTimetableEntry(row.input);
  return checked.valid && identity(checked.entry) === identity(row.entry);
}
function copyIssue(issue: ScheduleImportIssue): ScheduleImportIssue {
  return { field: issue.field, code: issue.code, severity: issue.severity, message: issue.message };
}
function copyRow(row: ScheduleImportRow): ScheduleImportRow {
  const source = row.source_time;
  return { source_index: row.source_index, status: row.status, input: copyEntry(row.input),
    entry: row.entry === null ? null : copyEntry(row.entry),
    source_time: { start_value: source.start_value, end_value: source.end_value,
      start_tzid: source.start_tzid, end_tzid: source.end_tzid,
      start_value_type: source.start_value_type, end_value_type: source.end_value_type },
    issues: row.issues.map((issue: ScheduleImportIssue) => copyIssue(issue)) };
}
function parseFailure(message: string): ImportReviewParse {
  return { valid: false, message: message, rows: [], sourceWarnings: [], calendarName: '', sourceCount: 0 };
}

// Only a complete, versioned diagnostic response can introduce source rows. The legacy
// entries list cannot prove that malformed or unsupported calendar events were retained.
export function parseImportReview(json: string): ImportReviewParse {
  let value: ScheduleSubscriptionPreview | null = null;
  try { value = JSON.parse(json) as ScheduleSubscriptionPreview | null; }
  catch { return parseFailure('导入返回内容不是有效 JSON，原课表草稿未改变。'); }
  if (value === null || typeof value !== 'object' || Array.isArray(value) || value.diagnostics_version !== 1 ||
    value.timezone_policy !== 'campus-utc+08:00') {
    return parseFailure('服务端未提供受支持的完整行诊断，请更新或重试；没有采用旧列表替代核对。');
  }
  if (value.provider !== 'hduhelp' || typeof value.calendar_name !== 'string' || !Array.isArray(value.rows) ||
    !Number.isInteger(value.source_event_count) || value.source_event_count < 1 || value.source_event_count > 500 ||
    value.rows.length !== value.source_event_count || !value.rows.every((row: ScheduleImportRow, index: number) => validSourceRow(row, index)) ||
    !Array.isArray(value.entries) || !Number.isInteger(value.event_count) || value.event_count !== value.entries.length ||
    !Array.isArray(value.warnings) || value.warnings.length > 20 ||
    !value.warnings.every((warning: string) => typeof warning === 'string')) {
    return parseFailure('源事件数量、行编号或诊断内容不完整，原课表草稿未改变；请重新预览。');
  }
  const allReady = value.rows.every((row: ScheduleImportRow) => row.status === 'ready');
  if (!allReady && (value.event_count !== 0 || value.entries.length !== 0)) {
    return parseFailure('含待核对事件的返回同时声称兼容课表可用，已拒绝部分导入。');
  }
  if (allReady) {
    const expected: string[] = [];
    value.rows.forEach((row: ScheduleImportRow) => {
      if (row.entry !== null) { const key = identity(row.entry); if (!expected.includes(key)) { expected.push(key); } }
    });
    if (value.entries.length !== expected.length || !value.entries.every((entry: TimetableEntry) =>
      rawEntry(entry) && validateTimetableEntry(entry).valid && identity(normalizeTimetableEntry(entry)) === identity(entry)) ||
      new Set(value.entries.map((entry: TimetableEntry) => identity(entry))).size !== expected.length ||
      !value.entries.every((entry: TimetableEntry) => expected.includes(identity(entry)))) {
      return parseFailure('兼容课表与完整源行不一致，未采用截断、丢失或改写的课程。');
    }
  }
  const warnings = value.warnings.filter((warning: string) => warning.trim().length > 0)
    .map((warning: string): TimetableIssue => ({ index: -1, relatedIndex: -1, field: 'import', message: warning }));
  return { valid: true, message: '', rows: value.rows.map((row: ScheduleImportRow) => copyRow(row)),
    sourceWarnings: warnings, calendarName: value.calendar_name, sourceCount: value.source_event_count };
}

function emptyChoice(index: number): ImportRowChoice {
  return { sourceIndex: index, mode: 'default', edited: null, sourceIssuesReviewed: false, overlapKey: '' };
}
function choiceFor(choices: ImportRowChoice[], index: number): ImportRowChoice {
  return choices.find((choice: ImportRowChoice) => choice.sourceIndex === index) ?? emptyChoice(index);
}
function validChoices(choices: ImportRowChoice[], size: number): boolean {
  if (!Array.isArray(choices) || choices.length > size) { return false; }
  const indexes: number[] = [];
  for (const choice of choices) {
    if (choice === null || typeof choice !== 'object' || Array.isArray(choice) ||
      !Number.isInteger(choice.sourceIndex) || choice.sourceIndex < 0 || choice.sourceIndex >= size ||
      indexes.includes(choice.sourceIndex) || !['default', 'include', 'exclude'].includes(choice.mode) ||
      choice.edited !== null && !rawEntry(choice.edited) || typeof choice.sourceIssuesReviewed !== 'boolean' ||
      typeof choice.overlapKey !== 'string') { return false; }
    indexes.push(choice.sourceIndex);
  }
  return true;
}
function addFieldIssue(issues: TimetableIssue[], index: number, field: string, message: string): void {
  if (message.length > 0) { issues.push({ index: index, relatedIndex: -1, field: field, message: message }); }
}
function fieldIssues(errors: TimetableFieldErrors, index: number): TimetableIssue[] {
  const result: TimetableIssue[] = [];
  addFieldIssue(result, index, 'date', errors.date); addFieldIssue(result, index, 'title', errors.title);
  addFieldIssue(result, index, 'start_time', errors.start_time); addFieldIssue(result, index, 'end_time', errors.end_time);
  addFieldIssue(result, index, 'location', errors.location); addFieldIssue(result, index, 'teacher', errors.teacher);
  return result;
}
function overlaps(left: TimetableEntry, right: TimetableEntry): boolean {
  return left.date === right.date && left.start_time < right.end_time && right.start_time < left.end_time;
}
function classificationFailure(message: string): ImportClassification {
  return { valid: false, message: message, rows: [], addCount: 0, duplicateCount: 0, overlapCount: 0,
    invalidCount: 0, excludedCount: 0, unresolvedCount: 0 };
}

interface SourceWarningGroup { key: string; field: string; message: string; rows: number[]; count: number; }
function sourceFieldLabel(field: string): string {
  if (field === 'date') { return '日期'; }
  if (field === 'title') { return '课程名'; }
  if (field === 'start_time') { return '开始时间'; }
  if (field === 'end_time') { return '结束时间'; }
  if (field === 'location') { return '地点'; }
  if (field === 'teacher') { return '教师'; }
  return '源事件';
}
function sourceRowRanges(rows: number[]): string {
  const ranges: string[] = [];
  let first = rows[0]; let last = first;
  for (let index = 1; index < rows.length; index++) {
    const next = rows[index];
    if (next === last + 1) { last = next; continue; }
    ranges.push(first === last ? `${first}` : `${first}–${last}`); first = next; last = next;
  }
  ranges.push(first === last ? `${first}` : `${first}–${last}`);
  return ranges.join('、');
}
function appendSourceWarning(groups: SourceWarningGroup[], index: number, issue: ScheduleImportIssue): void {
  // Group only identical reasons. Fields/codes/severity are part of identity, so an
  // end-time interpretation or a different limitation never disappears into another.
  const key = JSON.stringify([issue.field, issue.code, issue.severity, issue.message]);
  let group = groups.find((value: SourceWarningGroup) => value.key === key);
  if (group === undefined) {
    group = { key: key, field: issue.field, message: issue.message, rows: [], count: 0 }; groups.push(group);
  }
  group.count++;
  if (!group.rows.includes(index + 1)) { group.rows.push(index + 1); }
}
function sourceWarnings(rows: ImportReviewRow[]): TimetableIssue[] {
  const groups: SourceWarningGroup[] = [];
  rows.forEach((row: ImportReviewRow) => {
    if (!row.selected) { return; }
    row.sourceIssues.forEach((issue: ScheduleImportIssue) => appendSourceWarning(groups, row.sourceIndex, issue));
    if (row.original.status !== 'ready') {
      // This preserves the manual reconstruction boundary, not an automated recovery claim.
      appendSourceWarning(groups, row.sourceIndex, { field: 'event', code: 'MANUALLY_REBUILT_SINGLE_EVENT',
        severity: 'warning', message: '已由用户核对为一门单次课程；没有自动展开或恢复源事件语义。' });
    }
  });
  return groups.map((group: SourceWarningGroup): TimetableIssue => ({ index: -1, relatedIndex: -1, field: 'import',
    message: `${sourceFieldLabel(group.field)}：${group.message}（源第 ${sourceRowRanges(group.rows)} 行，共 ${group.rows.length} 行、${group.count} 处）` }));
}

// Always reclassify against the current draft and current edits. No title-based update
// guessing, source-index rebinding, implicit overwrite, or partial acceptance occurs here.
export function classifyImportRows(rows: ScheduleImportRow[], currentDraft: TimetableEntry[],
  choices: ImportRowChoice[] = []): ImportClassification {
  if (!Array.isArray(rows) || rows.length < 1 || rows.length > 500 ||
    !rows.every((row: ScheduleImportRow, index: number) => validSourceRow(row, index)) || !validChoices(choices, rows.length)) {
    return classificationFailure('导入行或选择记录不完整，请重新核对；原草稿未改变。');
  }
  if (!Array.isArray(currentDraft) || !currentDraft.every((entry: TimetableEntry) => rawEntry(entry))) {
    return classificationFailure('当前草稿格式无效，请先修正现有课程。');
  }
  const current = validateTimetableList(currentDraft, true);
  if (!current.valid) { return classificationFailure('当前草稿有无效或重复课程，请先修正再合并导入。'); }
  const result: ImportClassification = { valid: true, message: '', rows: [], addCount: 0, duplicateCount: 0,
    overlapCount: 0, invalidCount: 0, excludedCount: 0, unresolvedCount: 0 };
  rows.forEach((original: ScheduleImportRow, index: number) => {
    const choice = choiceFor(choices, index);
    const input = copyEntry(choice.edited ?? original.input);
    const checked = validateTimetableEntry(input);
    const sourceReviewed = original.status === 'ready' || choice.edited !== null && choice.sourceIssuesReviewed;
    const issues = fieldIssues(checked.errors, index);
    if (!sourceReviewed) {
      issues.push({ index: index, relatedIndex: -1, field: 'event',
        message: '此源事件尚未被完整解释；修正六字段后，请明确核对为一门单次课程，或排除本行。' });
    }
    result.rows.push({ sourceIndex: index, original: copyRow(original), input: input,
      entry: checked.valid ? copyEntry(checked.entry) : null,
      category: checked.valid && sourceReviewed ? 'new' : 'invalid', selected: false, excluded: choice.mode === 'exclude',
      issues: issues, sourceIssues: original.issues.map((issue: ScheduleImportIssue) => copyIssue(issue)),
      overlaps: [], overlapKey: '', needsSourceReview: !sourceReviewed });
  });
  // Duplicates use all six normalized fields. Excluded/invalid earlier rows cannot
  // suppress a later usable row; the first eligible source row represents that value.
  const seen = current.entries.map((entry: TimetableEntry) => identity(entry));
  result.rows.forEach((row: ImportReviewRow) => {
    if (row.excluded || row.category === 'invalid' || row.entry === null) { return; }
    const key = identity(row.entry);
    if (seen.includes(key)) {
      row.category = 'duplicate'; row.issues.push({ index: row.sourceIndex, relatedIndex: -1, field: 'duplicate',
        message: '与当前草稿或本批前面的课程六字段完全相同，默认不重复加入；不会替换原课程。' });
    } else { seen.push(key); }
  });
  result.rows.forEach((row: ImportReviewRow) => {
    if (row.excluded || row.category === 'invalid' || row.category === 'duplicate' || row.entry === null) { return; }
    const entry = row.entry;
    current.entries.forEach((other: TimetableEntry, index: number) => {
      if (overlaps(entry, other)) { row.overlaps.push({ kind: 'draft', index: index, entry: copyEntry(other) }); }
    });
    result.rows.forEach((other: ImportReviewRow) => {
      if (other.sourceIndex !== row.sourceIndex && !other.excluded && other.category !== 'invalid' &&
        other.category !== 'duplicate' && other.entry !== null && overlaps(entry, other.entry)) {
        row.overlaps.push({ kind: 'import', index: other.sourceIndex, entry: copyEntry(other.entry) });
      }
    });
    if (row.overlaps.length > 0) {
      row.category = 'overlap';
      row.overlapKey = JSON.stringify([row.sourceIndex, identity(entry), row.overlaps.map((other: ImportOverlap) =>
        JSON.stringify([other.kind, other.index, identity(other.entry)]))]);
      row.issues.push({ index: row.sourceIndex, relatedIndex: -1, field: 'overlap',
        message: `与 ${row.overlaps.length} 条课程时间重叠，请展开完整双方，明确保留才会加入。` });
    }
  });
  result.rows.forEach((row: ImportReviewRow) => {
    const choice = choiceFor(choices, row.sourceIndex);
    if (row.excluded) { result.excludedCount++; return; }
    if (row.category === 'invalid') { result.invalidCount++; result.unresolvedCount++; return; }
    if (row.category === 'duplicate') {
      result.duplicateCount++;
      if (choice.mode === 'include') { result.unresolvedCount++; }
      return;
    }
    if (row.category === 'overlap') {
      result.overlapCount++;
      row.selected = choice.mode === 'include' && choice.overlapKey === row.overlapKey;
      if (!row.selected) { result.unresolvedCount++; }
    } else { row.selected = true; }
    if (row.selected) { result.addCount++; }
  });
  if (result.unresolvedCount > 0) { result.message = `还有 ${result.unresolvedCount} 行需要修正、确认重叠或明确排除；尚未加入草稿。`; }
  return result;
}

export function assembleSelectedImport(rows: ScheduleImportRow[], currentDraft: TimetableEntry[],
  choices: ImportRowChoice[] = []): ImportAssembly {
  const classified = classifyImportRows(rows, currentDraft, choices);
  const result: ImportAssembly = { valid: false, message: classified.message, entries: [], addedEntries: [],
    warnings: [], excludedCount: classified.excludedCount, duplicateCount: classified.duplicateCount };
  if (!classified.valid || classified.unresolvedCount > 0) { return result; }
  classified.rows.forEach((row: ImportReviewRow) => {
    if (row.selected && row.entry !== null) { result.addedEntries.push(copyEntry(row.entry)); }
  });
  if (result.addedEntries.length === 0) {
    result.message = '没有选中可新增的课程。重复与明确排除项仍可查看，原草稿未改变。'; return result;
  }
  const checked = validateTimetableList(currentDraft.concat(result.addedEntries));
  if (!checked.valid) {
    result.addedEntries = []; result.message = checked.errors[0]?.message ?? '合并后的课表未通过完整校验，原草稿未改变。'; return result;
  }
  result.warnings = checked.warnings.concat(sourceWarnings(classified.rows));
  if (result.excludedCount > 0 || result.duplicateCount > 0) {
    result.warnings.push({ index: -1, relatedIndex: -1, field: 'import',
      message: `本次明确排除 ${result.excludedCount} 行，按六字段完全重复未新增 ${result.duplicateCount} 行；没有覆盖原课程。` });
  }
  // Preserve every explanation, or refuse the merge before mutating the draft. The
  // reserved 20 slots cover the complete preview's top-level source warnings.
  if (result.warnings.length > 1980 || result.warnings.some((warning: TimetableIssue) => warning.message.length > 2048)) {
    result.addedEntries = []; result.warnings = [];
    result.message = '来源说明超出本地草稿的保存范围，请联系数据提供方精简重复诊断后重新预览；课程尚未加入草稿。';
    return result;
  }
  result.valid = true; result.entries = checked.entries;
  result.message = `已核对 ${rows.length} 个源事件，可向本地草稿新增 ${result.addedEntries.length} 门课程；尚未保存到账号。`;
  return result;
}
