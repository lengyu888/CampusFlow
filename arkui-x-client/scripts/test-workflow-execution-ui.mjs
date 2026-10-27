import './helpers/theme-fixture.mjs';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { stripThemeTypeScriptTypes } from './helpers/theme-fixture.mjs';
import { emptyReviewState, time } from './helpers/review-fixture.mjs';
import { emptyFocusState } from './helpers/focus-fixture.mjs';

const source = readFileSync(new URL('../entry/src/main/ets/pages/ReviewPage.ets', import.meta.url), 'utf8');
const methods = source.slice(0, source.indexOf('\n  @Builder'))
  .replace(/^import [^\n]+;\r?\n/gm, '')
  .replace(/^@Component\r?\n/gm, '')
  .replace(/@(State|Prop)\s+|@(Watch|StorageLink)\('[^']+'\)\s*/g, '')
  .replace('export struct ReviewPage', 'class ReviewPage') + '\n}';
const ReviewPage = new Function('emptyReviewState', 'reviewRange', 'reviewShiftAnchor', stripThemeTypeScriptTypes(methods) + '\nreturn ReviewPage;')(emptyReviewState, time.reviewRange, time.reviewShiftAnchor);

test('collapsed review editor never conceals existing text, dirty state, save errors or discard confirmation', () => {
  const page = new ReviewPage();
  assert.equal(page.showNoteEditor(), false, 'an untouched optional note does not occupy the overview');
  page.noteEditorExpanded = true;
  assert.equal(page.showNoteEditor(), true, 'the user can explicitly start writing');
  page.noteEditorExpanded = false;
  for (const [field, value] of [['noteText', '保留本期笔记'], ['noteDirty', true], ['noteMessage', '保存失败，请重试'], ['discardNoteText', '待确认的输入']]) {
    const previous = page[field];
    page[field] = value;
    assert.equal(page.showNoteEditor(), true, `${field} must remain visible even with disclosure closed`);
    assert.equal(page[field], value, 'presentation must never clear the protected note state');
    page[field] = previous;
  }
  assert.equal(page.showNoteEditor(), false);
});

test('focus mode options can collapse while offline without changing mode, input or the always-present risk notice', () => {
  const focusSource = readFileSync(new URL('../entry/src/main/ets/pages/FocusPage.ets', import.meta.url), 'utf8');
  const focusMethods = focusSource.slice(0, focusSource.indexOf('\n  @Builder'))
    .replace(/^import [^\n]+;\r?\n/gm, '')
    .replace(/^@Component\r?\n/gm, '')
    .replace(/@(State|Prop)\s+|@(Watch|StorageLink)\('[^']+'\)\s*/g, '')
    .replace('export struct FocusPage', 'class FocusPage') + '\n}';
  const FocusPage = new Function('emptyFocusState', stripThemeTypeScriptTypes(focusMethods) + '\nreturn FocusPage;')(emptyFocusState);
  const page = new FocusPage();
  const calls = [];
  page.onStart = (...args) => calls.push(args);
  page.targetText = '25';
  assert.equal(page.optionsExpanded, false);
  assert.equal(page.recordingOptionsLabel(), '记录方式 · 联网');
  page.offline = true;
  const notice = page.recordingModeNotice();
  assert.match(notice, /需主动同步.*冲突不会覆盖/);
  assert.equal(page.recordingOptionsLabel(), '记录方式 · 仅本机');
  page.toggleOptions();
  assert.equal(page.optionsExpanded, true);
  assert.equal(page.recordingOptionsLabel(), '记录方式 · 收起');
  page.toggleOptions();
  assert.equal(page.optionsExpanded, false, 'offline mode must not force the options back open');
  assert.equal(page.recordingOptionsLabel(), '记录方式 · 仅本机');
  assert.equal(page.recordingModeNotice(), notice, 'closing options must not remove or soften the offline risk');
  assert.equal(page.offline, true);
  assert.equal(page.targetText, '25');
  assert.deepEqual(calls, [], 'presentational disclosure cannot start any recording');
});

test('review dates stay compact across months and explicit across years without changing the queried anchor or full accessible range', () => {
  const page = new ReviewPage();
  for (const [period, anchor, display, full] of [
    ['day', '2026-10-25', '2026年10月25日', '2026-10-25'],
    ['week', '2026-10-25', '10月19日–25日', '2026-10-19 — 2026-10-25'],
    ['week', '2026-11-01', '10月26日–11月1日', '2026-10-26 — 2026-11-01'],
    ['week', '2027-01-01', '2026年12月28日\n2027年1月3日', '2026-12-28 — 2027-01-03']
  ]) {
    page.state = { ...emptyReviewState(), period, anchor };
    const before = structuredClone(page.state);
    assert.equal(page.rangeDisplayLabel(), display);
    assert.equal(page.rangeLabel(), full);
    assert.deepEqual(page.state, before, 'formatting cannot select a different period or move the query boundaries');
  }
});
