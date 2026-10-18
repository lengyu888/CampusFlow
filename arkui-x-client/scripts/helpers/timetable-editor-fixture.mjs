import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { importReview, timetableRules } from './timetable-import-fixture.mjs';
export { importReview };
export function diagnosticPreview(entries, warnings = []) {
  const unique = [...new Map(entries.map(entry => [JSON.stringify(entry), entry])).values()];
  return { provider: 'hduhelp', calendar_name: '合成测试课表', event_count: unique.length,
    entries: structuredClone(unique), warnings, diagnostics_version: 1, source_event_count: entries.length,
    timezone_policy: 'campus-utc+08:00', rows: entries.map((entry, index) => sourceRow(index, entry)) };
}
export function sourceRow(index, entry, extra = {}) {
  return { source_index: index, status: 'ready', input: structuredClone(entry), entry: structuredClone(entry),
    source_time: { start_value: null, end_value: null, start_tzid: null, end_tzid: null, start_value_type: null, end_value_type: null }, issues: [], ...extra };
}
export function maximumWarningPreview() {
  const entries = Array.from({ length: 500 }, (_, index) => ({
    date: new Date(Date.UTC(2027, 0, 1 + index)).toISOString().slice(0, 10),
    title: `满容量课程 ${index + 1}`, start_time: '08:05', end_time: '09:40', location: '教学楼', teacher: '教师'
  }));
  const result = diagnosticPreview(entries, ['来源未声明时区，按北京时间解释。', '来源含分钟精度时间，保留分钟。']);
  result.rows = entries.map((entry, index) => sourceRow(index, entry, {
    source_time: { start_value: `${entry.date.replaceAll('-', '')}T0805`, end_value: `${entry.date.replaceAll('-', '')}T0940`,
      start_tzid: null, end_tzid: null, start_value_type: null, end_value_type: null },
    issues: ['start_time', 'end_time'].flatMap(field => [
      { field, code: 'FLOATING_CAMPUS_TIME', severity: 'warning', message: '来源未声明时区，按北京时间解释。' },
      { field, code: 'MINUTE_PRECISION_INPUT', severity: 'warning', message: '来源含分钟精度时间，保留分钟。' }
    ])
  }));
  return result;
}
function component(name, dependencies) {
  let source = readFileSync(new URL(`../../entry/src/main/ets/components/${name}.ets`, import.meta.url), 'utf8');
  source = source.slice(0, source.indexOf('\n  @Builder')).replace(/^import [^\n]+;\r?\n/gm, '')
    .replace(/^@Component\r?\n/m, '').replace(/@(Prop|State)\s+|@Watch\('[^']+'\)\s*/g, '')
    .replace(`export struct ${name}`, `class ${name}`) + '\n}\n';
  return new Function(...Object.keys(dependencies), stripTypeScriptTypes(source) + `\nreturn ${name};`)(...Object.values(dependencies));
}
export function importPanel(rows, currentDraft = []) {
  const Panel = component('TimetableImportPanel', { classifyImportRows: importReview.classifyImportRows,
    validateTimetableEntry: timetableRules.validateTimetableEntry });
  const panel = new Panel(); panel.rows = structuredClone(rows); panel.currentDraft = structuredClone(currentDraft);
  panel.onChoicesChanged = choices => { panel.choices = choices; panel.reclassify(); };
  panel.aboutToAppear(); return panel;
}
export function entryEditor(entry, options = {}) {
  const focusCalls = [], changes = [], dateDialogs = [], timeDialogs = [];
  const Editor = component('TimetableEntryEditor', { validateTimetableEntry: timetableRules.validateTimetableEntry,
    focusControl: { requestFocus: id => { focusCalls.push(id); return options.focusSuccess ?? true; } } });
  const editor = new Editor(); editor.entry = structuredClone(entry); editor.anchorDate = '2026-10-19'; editor.idPrefix = 'fixture';
  editor.getUIContext = () => ({ showDatePickerDialog: value => { if (options.pickerFailure) throw Error('native unavailable'); dateDialogs.push(value); },
    showTimePickerDialog: value => { if (options.pickerFailure) throw Error('native unavailable'); timeDialogs.push(value); } });
  editor.onFieldChange = (field, value) => { changes.push([field, value]); editor.entry = { ...editor.entry, [field]: value }; };
  editor.aboutToAppear(); return { editor, focusCalls, changes, dateDialogs, timeDialogs };
}
