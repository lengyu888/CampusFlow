import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';

const read = path => readFileSync(new URL(`../entry/src/main/ets/${path}`, import.meta.url), 'utf8');
const noImports = source => source.replace(/^import \{[\s\S]*?\} from '[^']+';\r?\n/gm, '').replace(/^import [^\n]+;\r?\n/gm, '');
const utility = async name => import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(noImports(read(`utils/${name}.ets`)))).toString('base64')}`);
const validation = await utility('OnboardingTimetable'), feedback = await utility('AgentFeedback'), agenda = await utility('DailyAgenda');
const maintenance = noImports(read('utils/TimetableMaintenance.ets')).replace(/export /g, '');
const TimetableMaintenance = new Function('CampusFlowRequestError', 'normalizeTimetableEntry', 'validateTimetableList',
  stripTypeScriptTypes(maintenance) + '\nreturn TimetableMaintenance;')(feedback.CampusFlowRequestError,
    validation.normalizeTimetableEntry, validation.validateTimetableList);
const source = read('pages/TimetablePage.ets');
const prefix = noImports(source.slice(0, source.indexOf('\n  @Builder')))
  .replace(/^@Component\r?\n/m, '').replace(/@(Prop|State)\s+|@Watch\('[^']+'\)\s*/g, '')
  .replace('export struct TimetablePage', 'class TimetablePage') + '\n}\n';
const factory = new Function('CampusFlowApi', 'TimetableMaintenance', 'normalizeTimetableEntry', 'validateTimetableEntry',
  'validateTimetableList', 'parseTimetablePreview', 'expandWeeklyEntry', 'shanghaiDate', 'Scroller', 'Edge',
  stripTypeScriptTypes(prefix) + '\nreturn TimetablePage;');
const row = (title = '操作系统', date = '2026-10-20') => ({ date, title, start_time: '08:05', end_time: '09:40', location: '教学楼', teacher: '教师' });
const clone = value => JSON.parse(JSON.stringify(value));
const tick = () => new Promise(resolve => setImmediate(resolve));
function deferred() { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; }
async function fixture(handlers = {}) {
  const calls = [], notifications = [];
  let snapshot = { revision: 'a'.repeat(64), entries: [row()] };
  class Api {
    async timetable() { calls.push(['get']); return handlers.get ? handlers.get() : clone(snapshot); }
    async saveTimetable(entries, revision, operationId, clear) {
      calls.push(['put', clone(entries), revision, operationId, clear]);
      if (handlers.save) { return handlers.save(entries, revision, operationId, clear); }
      snapshot = { revision: 'b'.repeat(64), entries: clone(entries) };
      return { operation_id: operationId, status: 'applied', previous_revision: revision,
        revision: snapshot.revision, entry_count: entries.length, applied_at: new Date().toISOString() };
    }
    async timetableOperation(id) { calls.push(['lookup', id]); return handlers.lookup?.(id); }
    async previewSubscription(url) { calls.push(['preview', url]); return handlers.preview?.(url); }
  }
  class Scroller { scrollEdge() {} }
  const Page = factory(Api, TimetableMaintenance, validation.normalizeTimetableEntry, validation.validateTimetableEntry,
    validation.validateTimetableList, validation.parseTimetablePreview, validation.expandWeeklyEntry, agenda.shanghaiDate, Scroller, { Top: 'top' });
  const page = new Page(); page.onTimetableChanged = () => notifications.push(true); page.aboutToAppear(); await tick();
  return { page, calls, notifications, setSnapshot: value => snapshot = clone(value) };
}

test('unsubmitted form survives route hide and blocks whole-table review or remote replacement', async () => {
  const { page, setSnapshot, calls } = await fixture(); page.newEntry(); page.updateEditor('title', '  草稿标题  ');
  page.updateEditor('location', '新地点'); assert.equal(page.editor.title, '  草稿标题  ', 'typing another field does not trim earlier raw input');
  page.reviewSave(); assert.equal(page.reviewOpen, false); assert.match(page.message, /表单/);
  page.active = false; page.activityChanged(); setSnapshot({ revision: 'c'.repeat(64), entries: [row('新账号快照')] });
  page.active = true; page.activityChanged(); await tick();
  assert.equal(page.editor.title, '  草稿标题  '); assert.equal(page.entries[0].title, '操作系统'); assert.equal(page.view.phase, 'stale');
  assert.equal(calls.filter(call => call[0] === 'put').length, 0);
});

test('weekly manual entry, edit and pending delete use exact indexes without aliasing another week', async () => {
  const { page } = await fixture(); page.newEntry(); page.editor = row('编译原理', '2026-10-21'); page.editorDirty = true;
  page.setRepeatWeeks(4); page.addEntry(); assert.equal(page.entries.length, 5);
  page.editEntry(2); page.updateEditor('title', '仅本周改名'); assert.equal(page.entries[2].title, '编译原理');
  page.addEntry(); assert.equal(page.entries[2].title, '仅本周改名'); assert.equal(page.entries[3].title, '编译原理');
  page.requestDelete(3); page.removeEntry(2); assert.equal(page.entries.length, 5);
  page.removeEntry(3); assert.equal(page.entries.length, 4); assert.equal(page.pendingDelete, -1);
  page.removeEntry(3); assert.equal(page.entries.length, 4, 'old confirmation cannot remove the next row');
});

test('empty or duplicate import cannot overwrite draft; accepted warnings survive review and URL is cleared', async () => {
  let result = { event_count: 0, entries: [] };
  const { page } = await fixture({ preview: async () => result }); page.selectSource('subscription'); page.updateScheduleUrl('https://private/?key=secret');
  await page.previewImport(); assert.equal(page.importEntries.length, 0); assert.equal(page.entries.length, 1);
  result = { event_count: 1, entries: [row()] }; await page.previewImport(); page.acceptImport();
  assert.equal(page.entries.length, 1); assert.equal(page.importEntries.length, 1); assert.match(page.message, /完全相同/);
  page.cancelPreview(); result = { event_count: 1, entries: [row('新课程', '2026-10-21')], warnings: ['来源仅涵盖本学期'] };
  await page.previewImport(); page.reviewSave(); assert.equal(page.reviewOpen, false);
  page.acceptImport(); assert.equal(page.entries.length, 2); assert.equal(page.scheduleUrl, '');
  page.reviewSave(); assert.equal(page.reviewOpen, true); assert.equal(page.sourceWarnings[0].message, '来源仅涵盖本学期');
});

test('cancelled or hidden import ignores late response and never exposes private URL in failure copy', async () => {
  const late = deferred(); const { page } = await fixture({ preview: () => late.promise });
  page.selectSource('subscription'); page.updateScheduleUrl('https://private/?secret=123'); const read = page.previewImport();
  page.active = false; page.activityChanged(); late.resolve({ event_count: 1, entries: [row('晚到')] }); await read;
  assert.equal(page.scheduleUrl, ''); assert.equal(page.importEntries.length, 0); assert.equal(page.entries.length, 1);
  const g = await fixture({ preview: async () => { throw new Error('https://private/?secret=123'); } });
  g.page.selectSource('subscription'); g.page.updateScheduleUrl('https://private/?secret=123'); await g.page.previewImport();
  assert.doesNotMatch(g.page.message, /https:|secret|123/);
});

test('confirmed clear updates only the timetable and success callback fires once', async () => {
  const { page, calls, notifications } = await fixture(); page.clearDraft(); assert.equal(page.entries.length, 1);
  page.requestClear(); page.clearDraft(); assert.equal(page.entries.length, 0); assert.equal(calls.filter(call => call[0] === 'put').length, 0);
  page.reviewSave(); assert.equal(page.reviewOpen, true); await page.save(); await page.save();
  const puts = calls.filter(call => call[0] === 'put'); assert.equal(puts.length, 1); assert.deepEqual(puts[0][1], []);
  assert.equal(puts[0][4], true); assert.equal(notifications.length, 1); assert.equal(page.reviewOpen, false); assert.equal(page.view.phase, 'saved');
  assert.equal(page.notice, '', 'successful receipt must remove the earlier not-yet-saved draft copy');
});

test('clear confirmation is rechecked after a user starts a new unsaved editor', async () => {
  const { page } = await fixture(); page.requestClear(); page.newEntry(); page.updateEditor('title', '不可丢失');
  page.clearDraft(); assert.equal(page.entries.length, 1); assert.equal(page.editorOpen, true); assert.equal(page.editor.title, '不可丢失');
  assert.match(page.message, /先处理/);
});

test('failed discard reload retains raw editor, draft and candidates; successful reload clears them explicitly', async () => {
  let fail = false; const { page } = await fixture({ get: async () => {
    if (fail) throw new Error('offline'); return { revision: 'a'.repeat(64), entries: [row()] };
  } });
  page.newEntry(); page.updateEditor('title', '未加入表单'); await page.requestRefresh(); assert.equal(page.reloadRequested, true);
  fail = true; await page.discardAndReload(); assert.equal(page.editor.title, '未加入表单'); assert.equal(page.entries.length, 1);
  fail = false; await page.discardAndReload(); assert.equal(page.editor.title, ''); assert.equal(page.reloadRequested, false); assert.equal(page.view.dirty, false);
});

test('complete 500-row table stays paged and review blocks accidental direct edits', async () => {
  const { page } = await fixture(); const many = Array.from({ length: 500 }, (_, i) => row(`课程 ${i}`));
  assert.equal(page.controller.replaceDraft(many), true); const found = [];
  for (let p = 0; p < 50; p++) { page.pageIndex = p; found.push(...page.draftRows().map(item => item.index)); }
  assert.deepEqual(found, Array.from({ length: 500 }, (_, i) => i));
  page.reviewSave(); assert.equal(page.reviewOpen, true); assert.equal(page.entries.length, 500);
});

test('unknown save disables editor mutations and route hide keeps query-only state instead of repeating PUT', async () => {
  const { page, calls } = await fixture({ save: async () => { throw new feedback.CampusFlowRequestError(0, 'NETWORK_ERROR', 'private'); } });
  page.newEntry(); page.editor = row('新课', '2026-10-21'); page.addEntry(); page.reviewSave(); await page.save();
  assert.equal(page.view.phase, 'uncertain'); assert.equal(page.editable(), false);
  page.newEntry(); page.requestClear(); page.updateEditor('title', '不得修改'); await page.save();
  page.active = false; page.activityChanged(); page.active = true; page.activityChanged(); await tick();
  assert.equal(page.view.phase, 'uncertain'); assert.equal(page.entries.length, 2); assert.equal(calls.filter(call => call[0] === 'put').length, 1);
});

// Pure Node execution of actual ArkTS controller/page methods with mocked transport.
// Does not validate ArkUI rendering, IME, focus, accessibility or native builds.
