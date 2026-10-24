import assert from 'node:assert/strict';
import { test } from 'node:test';
import { entryEditor } from './helpers/timetable-editor-fixture.mjs';

const course = (extra = {}) => ({ date: '2026-10-24', title: '原生选择器验收',
  start_time: '08:05', end_time: '09:40', location: '', teacher: '', ...extra });

test('native time-dialog selection carries the course date as well as the displayed start/end time', () => {
  const fixture = entryEditor(course());
  for (const [field, hour, minute] of [['start_time', 8, 5], ['end_time', 9, 40]]) {
    fixture.editor.openTimePicker(field);
    const options = fixture.timeDialogs.at(-1);
    assert.equal(options.selected.getFullYear(), 2026, 'native dialog title must not use the Unix epoch year');
    assert.equal(options.selected.getMonth(), 9);
    assert.equal(options.selected.getDate(), 24);
    assert.equal(options.selected.getHours(), hour);
    assert.equal(options.selected.getMinutes(), minute);
    assert.equal(options.useMilitaryTime, true);
    assert.deepEqual(fixture.changes, [], 'opening a picker is not a draft change');
  }
});

test('an empty time remains empty until accepted; the text-input placeholder is not a stored time', () => {
  const fixture = entryEditor(course({ start_time: '', end_time: '' }));
  fixture.editor.openTimePicker('start_time');
  const selected = fixture.timeDialogs[0].selected;
  assert.equal(selected.getFullYear(), 2026);
  assert.equal(selected.getDate(), 24);
  assert.equal(selected.getHours(), 0);
  assert.equal(selected.getMinutes(), 0);
  assert.equal(fixture.editor.entry.start_time, '');
  assert.deepEqual(fixture.changes, []);
  fixture.timeDialogs[0].onCancel();
  assert.deepEqual(fixture.changes, []);
});

test('an invalid course date uses the valid page anchor for the dialog title without overwriting raw input', () => {
  const original = course({ date: 'not-a-date', start_time: '23:59' });
  const fixture = entryEditor(original);
  fixture.editor.anchorDate = '2028-02-29';
  fixture.editor.openTimePicker('start_time');
  const selected = fixture.timeDialogs[0].selected;
  assert.equal(selected.getFullYear(), 2028);
  assert.equal(selected.getMonth(), 1);
  assert.equal(selected.getDate(), 29);
  assert.equal(selected.getHours(), 23);
  assert.equal(selected.getMinutes(), 59);
  assert.deepEqual(fixture.editor.entry, original);
});

test('midnight initialization and an accepted time never alter the course date or the other time field', () => {
  const fixture = entryEditor(course({ start_time: '00:00' }));
  fixture.editor.openTimePicker('start_time');
  const options = fixture.timeDialogs[0];
  assert.equal(options.selected.getHours(), 0);
  assert.equal(options.selected.getMinutes(), 0);
  options.onAccept({ hour: 8, minute: 5 });
  assert.equal(fixture.editor.entry.start_time, '08:05');
  assert.equal(fixture.editor.entry.end_time, '09:40');
  assert.equal(fixture.editor.entry.date, '2026-10-24');
  assert.deepEqual(fixture.changes, [['start_time', '08:05']]);
});
