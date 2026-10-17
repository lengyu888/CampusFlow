import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';

// Exercise production pure helpers. Native form layout and date widgets are not tested here.
const source = readFileSync(new URL('../entry/src/main/ets/utils/OnboardingTimetable.ets', import.meta.url), 'utf8')
  .replace(/^import \{ TimetableEntry \} from '\.\.\/model\/ApiModels';\r?\n/, '');
const { normalizeTimetableEntry, validateTimetableEntry, validateTimetableList,
  parseTimetablePreview, expandWeeklyEntry } = await import(
  `data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source)).toString('base64')}`);

function entry(overrides = {}) {
  return { date: '2026-10-19', title: '操作系统', start_time: '08:05', end_time: '09:40',
    location: '第7教研楼北406', teacher: '叶老师', ...overrides };
}

function preview(entries, overrides = {}) {
  return JSON.stringify({ provider: 'hduhelp', calendar_name: '课表', event_count: entries.length,
    entries, warnings: [], ...overrides });
}

test('normalization trims without truncation and returns independent whitelisted rows', () => {
  const input = entry({ title: '  操作系统  ', location: ' 教研楼\n', teacher: '  叶老师 ',
    date: ' 2026-10-19 ', start_time: ' 08:05 ', end_time: '09:40 ', token: 'private', actions: ['do-not-copy'] });
  const before = JSON.stringify(input);
  const normalized = normalizeTimetableEntry(input);
  assert.deepEqual(normalized, entry({ location: '教研楼' }));
  assert.equal(JSON.stringify(input), before);
  assert.notEqual(normalized, input);
  normalized.title = '修改';
  assert.equal(input.title, '  操作系统  ');
  assert.deepEqual(Object.keys(normalized).sort(), ['date', 'end_time', 'location', 'start_time', 'teacher', 'title']);
  const long = '😀'.repeat(101);
  assert.equal(normalizeTimetableEntry(entry({ title: long })).title, long);
});

test('strict Gregorian date validation handles leap years, range and format without Date rollover', () => {
  for (const date of ['0001-01-01', '0099-12-31', '1000-01-01', '2000-02-29', '2024-02-29', '9999-12-31']) {
    assert.equal(validateTimetableEntry(entry({ date })).valid, true, date);
  }
  for (const date of ['0000-01-01', '10000-01-01', '1900-02-29', '2100-02-29', '2026-02-29',
    '2026-04-31', '2026-00-01', '2026-13-01', '2026-01-00', '2026-01-32', '2026-1-01',
    '2026-01-1', '２０２６-01-01', '2026-10-19T00:00:00Z', '2026/10/19', '']) {
    const result = validateTimetableEntry(entry({ date }));
    assert.equal(result.valid, false, date);
    assert.ok(result.errors.date, date);
  }
});

test('time validation requires exact HH:mm and an increasing same-day interval', () => {
  assert.equal(validateTimetableEntry(entry({ start_time: '00:00', end_time: '23:59' })).valid, true);
  for (const time of ['24:00', '08:60', '8:05', '08:5', '08:05:00', '-1:00', '０８:05', '']) {
    assert.ok(validateTimetableEntry(entry({ start_time: time })).errors.start_time, time);
    assert.ok(validateTimetableEntry(entry({ end_time: time })).errors.end_time, time);
  }
  for (const times of [['09:40', '09:40'], ['23:00', '01:00'], ['10:00', '09:00']]) {
    const result = validateTimetableEntry(entry({ start_time: times[0], end_time: times[1] }));
    assert.equal(result.valid, false);
    assert.match(result.errors.end_time, /晚于.*同一天/);
  }
});

test('field limits match backend Unicode lengths and do not alter over-limit input', () => {
  assert.equal(validateTimetableEntry(entry({ title: '😀'.repeat(100), location: '地'.repeat(120), teacher: '师'.repeat(80) })).valid, true);
  const input = entry({ title: '😀'.repeat(101), location: '地'.repeat(121), teacher: '师'.repeat(81) });
  const result = validateTimetableEntry(input);
  assert.equal(result.valid, false);
  assert.match(result.errors.title, /100/); assert.match(result.errors.location, /120/); assert.match(result.errors.teacher, /80/);
  assert.deepEqual(result.entry, input);
  assert.ok(validateTimetableEntry(entry({ title: ' \t\n ' })).errors.title);
  assert.equal(validateTimetableEntry(entry({ location: '', teacher: '' })).valid, true);
  const optionalMissing = entry(); delete optionalMissing.location; delete optionalMissing.teacher;
  assert.equal(validateTimetableEntry(optionalMissing).valid, true, 'backend defaults for optional fields are respected');
});

test('malformed rows/types receive usable field errors instead of becoming valid empty strings', () => {
  for (const input of [null, undefined, 5, true, 'course', [], {},
    entry({ date: 20261019 }), entry({ title: 5 }), entry({ start_time: null }),
    entry({ end_time: {} }), entry({ location: null }), entry({ teacher: ['name'] })]) {
    const result = validateTimetableEntry(input);
    assert.equal(result.valid, false);
    assert.ok(Object.values(result.errors).some(Boolean));
  }
  assert.equal(validateTimetableEntry(entry({ location: null })).errors.location.length > 0, true);
  assert.equal(validateTimetableEntry(entry({ teacher: 1 })).errors.teacher.length > 0, true);
});

test('list bounds reject empty imports or more than 500 courses without truncation', () => {
  assert.equal(validateTimetableList([]).valid, false);
  assert.deepEqual(validateTimetableList([], true), { valid: true, entries: [], errors: [], warnings: [] });
  const full = Array.from({ length: 500 }, (_, index) => entry({ title: `课程 ${index}` }));
  const result = validateTimetableList(full);
  assert.equal(result.valid, true);
  assert.equal(result.entries.length, 500);
  assert.equal(result.warnings.length, 500, 'dense overlap warnings are bounded to one per affected row');
  const over = validateTimetableList(full.concat(entry({ title: '第 501 项' })));
  assert.equal(over.valid, false);
  assert.deepEqual(over.entries, []);
  assert.match(over.errors[0].message, /500/);
  assert.equal(over.errors[0].index, -1);
  for (const input of [null, {}, 'bad']) assert.equal(validateTimetableList(input).valid, false);
});

test('exact duplicates include all six normalized fields, remain present and map to original row indices', () => {
  const rows = [entry(), entry({ title: ' 操作系统 ' }), entry({ teacher: '另一位教师' }), entry({ date: '2026-10-26' })];
  const result = validateTimetableList(rows);
  assert.equal(result.valid, false);
  assert.equal(result.entries.length, rows.length, 'nothing is silently deduplicated');
  assert.deepEqual(result.errors.map(({ index, relatedIndex, field }) => ({ index, relatedIndex, field })),
    [{ index: 1, relatedIndex: 0, field: 'duplicate' }]);
  assert.ok(result.warnings.some((warning) => warning.index === 2));
  const repeatDifferentDay = validateTimetableList([entry(), entry({ date: '2026-10-26' })]);
  assert.equal(repeatDifferentDay.valid, true);
  assert.equal(repeatDifferentDay.warnings.length, 0);
});

test('overlap is a warning: adjacent lessons, other days and invalid rows do not create false conflicts', () => {
  const rows = [entry({ title: 'A', start_time: '08:00', end_time: '09:00' }),
    entry({ title: 'B', start_time: '09:00', end_time: '10:00' }),
    entry({ title: 'C', date: '2026-10-20', start_time: '08:15', end_time: '08:45' })];
  assert.equal(validateTimetableList(rows).warnings.length, 0);
  rows.push(entry({ title: 'D', start_time: '08:30', end_time: '09:30' }));
  const result = validateTimetableList(rows);
  assert.equal(result.valid, true);
  assert.equal(result.entries.length, 4);
  assert.deepEqual(result.warnings.map((item) => item.index), [0, 1, 3]);
  assert.equal(result.errors.length, 0);
  const invalid = validateTimetableList([entry(), entry({ start_time: 'wrong' })]);
  assert.equal(invalid.warnings.length, 0);
  assert.deepEqual(invalid.errors.map((issue) => [issue.index, issue.field]), [[1, 'start_time']]);
});

test('list validation and preview cloning cannot mutate the original editable draft', () => {
  const draft = [entry()]; const before = JSON.stringify(draft);
  const checked = validateTimetableList(draft);
  checked.entries[0].title = '候选更改';
  assert.equal(JSON.stringify(draft), before);
  const imported = parseTimetablePreview(preview(draft));
  imported.entries[0].location = '新位置';
  assert.equal(JSON.stringify(draft), before);
});

test('preview parsing keeps only safe row fields and preserves server import warnings', () => {
  const result = parseTimetablePreview(preview([entry({ credential: 'private', pending_actions: ['old-action'] })],
    { warnings: [' 已跳过 1 条无效事件。 ', ''] }));
  assert.equal(result.valid, true);
  assert.equal(result.entries.length, 1);
  assert.doesNotMatch(JSON.stringify(result.entries), /credential|private|pending_actions|old-action/);
  assert.deepEqual(result.warnings, [{ index: -1, relatedIndex: -1, field: 'import', message: '已跳过 1 条无效事件。' }]);
});

test('malformed/empty/over-limit previews never produce candidate rows that could replace a draft', () => {
  const malformed = ['not-json', 'null', '5', 'true', '"text"', '[]', '{}',
    JSON.stringify({ entries: [entry()] }), preview([entry()], { event_count: 0 }),
    preview([entry()], { event_count: '1' }), preview([entry()], { event_count: 1.5 }),
    preview([]), preview([null]), preview([entry({ date: '2026-02-30' })]),
    preview(Array.from({ length: 501 }, (_, index) => entry({ title: String(index) }))),
    preview([entry(), entry()]), preview([entry()], { warnings: 'bad' }),
    preview([entry()], { warnings: [null] }), preview([entry()], { warnings: Array(21).fill('warning') })];
  let draft = [entry({ title: '原草稿' })]; const original = draft;
  for (const json of malformed) {
    const result = parseTimetablePreview(json);
    assert.equal(result.valid, false, json.slice(0, 80));
    assert.equal(result.entries.length, 0);
    assert.ok(result.errors.length > 0);
    if (result.valid) draft = result.entries;
    assert.equal(draft, original);
  }
});

test('weekly expansion uses Gregorian UTC dates, retains time/metadata and produces independent rows', () => {
  const input = entry({ date: '2024-02-23' });
  const result = expandWeeklyEntry(input, 4);
  assert.equal(result.valid, true);
  assert.deepEqual(result.entries.map((item) => item.date), ['2024-02-23', '2024-03-01', '2024-03-08', '2024-03-15']);
  assert.ok(result.entries.every((item) => item.start_time === '08:05' && item.end_time === '09:40' && item.teacher === '叶老师'));
  result.entries[0].title = '单条修改';
  assert.equal(result.entries[1].title, '操作系统');
  assert.equal(input.title, '操作系统');
  assert.deepEqual(expandWeeklyEntry(entry({ date: '2026-12-28' }), 2).entries.map((item) => item.date),
    ['2026-12-28', '2027-01-04']);
  assert.deepEqual(expandWeeklyEntry(entry({ date: '0099-12-28' }), 2).entries.map((item) => item.date),
    ['0099-12-28', '0100-01-04']);
  assert.deepEqual(expandWeeklyEntry(entry({ date: '0001-01-01' }), 2).entries.map((item) => item.date),
    ['0001-01-01', '0001-01-08']);
});

test('weekly expansion remains date-identical across time zones and daylight-saving transitions', () => {
  const previous = process.env.TZ;
  try {
    for (const timezone of ['UTC', 'Asia/Shanghai', 'America/New_York', 'Pacific/Apia']) {
      process.env.TZ = timezone;
      assert.deepEqual(expandWeeklyEntry(entry({ date: '2026-03-01' }), 4).entries.map((item) => item.date),
        ['2026-03-01', '2026-03-08', '2026-03-15', '2026-03-22'], timezone);
      assert.deepEqual(expandWeeklyEntry(entry({ date: '2011-12-23' }), 3).entries.map((item) => item.date),
        ['2011-12-23', '2011-12-30', '2012-01-06'], timezone);
    }
  } finally {
    if (previous === undefined) delete process.env.TZ;
    else process.env.TZ = previous;
  }
});

test('weekly expansion rejects invalid count/date and year overflow as a whole, not a partial result', () => {
  for (const weeks of [0, -1, 25, 1.5, NaN, Infinity, '4', null]) {
    const result = expandWeeklyEntry(entry(), weeks);
    assert.equal(result.valid, false);
    assert.deepEqual(result.entries, []);
    assert.equal(result.errors[0].field, 'weeks');
  }
  assert.equal(expandWeeklyEntry(entry(), 1).entries.length, 1);
  assert.equal(expandWeeklyEntry(entry(), 24).entries.length, 24);
  assert.equal(expandWeeklyEntry(entry({ date: '9999-12-31' }), 1).valid, true);
  const overflow = expandWeeklyEntry(entry({ date: '9999-12-25' }), 2);
  assert.equal(overflow.valid, false);
  assert.deepEqual(overflow.entries, []);
  assert.match(overflow.errors[0].message, /9999.*未生成部分/);
  assert.equal(expandWeeklyEntry(entry({ date: '2026-02-30' }), 4).valid, false);
});

test('expanded rows still require combined-draft duplicate and capacity validation', () => {
  const expanded = expandWeeklyEntry(entry(), 4);
  const duplicate = validateTimetableList([entry()].concat(expanded.entries));
  assert.equal(duplicate.valid, false);
  assert.ok(duplicate.errors.some((issue) => issue.field === 'duplicate'));
  const existing = Array.from({ length: 499 }, (_, index) => entry({ title: `已有课程 ${index}` }));
  assert.equal(validateTimetableList(existing.concat(expanded.entries)).valid, false);
});
