import { importReview, diagnosticPreview, sourceRow, importPanel, maximumWarningPreview } from './helpers/timetable-editor-fixture.mjs';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';

async function helperModule(name) {
  const source = readFileSync(new URL(`../entry/src/main/ets/utils/${name}.ets`, import.meta.url), 'utf8')
    .replace(/^import \{[\s\S]*?\} from '(?:\.\.\/model\/ApiModels|\.\/OnboardingTimetable)';\r?\n/gm, '');
  return import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source)).toString('base64')}`);
}
const timetable = await helperModule('OnboardingTimetable');
const feedback = await helperModule('AgentFeedback');
const agenda = await helperModule('DailyAgenda');
const { historyScope } = await helperModule('LocalHistoryStore');
const { DraftStore } = await helperModule('DraftStore');
const operationId = '01234567-89ab-4def-8abc-0123456789ab';
const revisionA = 'a'.repeat(64), revisionB = 'b'.repeat(64);
const tick = () => new Promise(resolve => setImmediate(resolve));
const source = readFileSync(new URL('../entry/src/main/ets/pages/OnboardingPage.ets', import.meta.url), 'utf8');
const firstBuilder = source.indexOf('\n  @Builder');
assert.ok(firstBuilder > 0, 'the page non-UI method boundary must exist');
// Execute actual page methods plus the actual timetable validator. Network, scrolling
// and completion are mocked; these tests do not claim an ArkUI render or native build.
const pageSource = source.slice(0, firstBuilder)
  .replace(/^import [^\n]+;\r?\n/gm, '')
  .replace(/^@Component\r?\n/m, '')
  .replace(/@(Prop|State)\s+|@Watch\('[^']+'\)\s*/g, '')
  .replace('export struct OnboardingPage', 'class OnboardingPage') + '\n}\n';
const createPage = new Function('CampusFlowApi', 'CampusFlowRequestError', 'Scroller', 'Edge',
  'normalizeTimetableEntry', 'validateTimetableEntry', 'validateTimetableList', 'parseTimetablePreview',
  'expandWeeklyEntry', 'shanghaiDate', 'timetableOperationId', 'localDrafts', 'historyScope', 'parseImportReview', 'assembleSelectedImport', stripTypeScriptTypes(pageSource) + '\nreturn OnboardingPage;');

function course(overrides = {}) {
  return { date: '2026-10-19', title: '操作系统', start_time: '08:05', end_time: '09:40',
    location: '第7教研楼北406', teacher: '叶老师', ...overrides };
}
function preview(entries = [course()]) { return diagnosticPreview(entries); }
function onboardingCampusData() {
  return { package: { package_id: 'fixture-hdu', school: '杭州电子科技大学', campus: '下沙校区', version: 'fixture' },
    places: [{ place_id: 'fixture-library', name: '图书馆', category: '学习', zone: '中区', aliases: ['馆'],
      open_now: true, open_hours: '测试示例' }], notices: [], corrections: [] };
}
const user = { user_id: 'fixture-user', email: 'fixture@example.invalid', display_name: '测试同学',
  school: '杭州电子科技大学', campus: '下沙校区', semester: '2026-2027 第一学期', onboarding_complete: true,
  role: 'user', api_key_configured: false, api_key_hint: null };
function receipt(entries = [course()], map = { places: [{}] }) {
  return { user: { ...user }, timetable_count: entries.length, campus_place_count: map.places.length, receipt: { operation_id: operationId, status: 'applied', previous_revision: revisionA, revision: revisionB, timetable_count: entries.length, campus_place_count: map.places.length, applied_at: '2026-10-18T10:00:00Z' } };
}
function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
async function fixture(handlers = {}) {
  const calls = [], reads = [];
  let storedText = handlers.initialDraftText;
  const draftStore = handlers.draftStore ?? new DraftStore({ read: async () => storedText, write: async value => { if (handlers.diskFailure?.()) throw new Error('disk'); storedText = value; }, remove: async () => { storedText = undefined; } }, { now: () => Date.now(), set: () => 1, clear() {} });
  await draftStore.initialize();
  const lease = handlers.lease ?? await draftStore.activate(historyScope('http://fixture.invalid', 'fixture-user'));
  let snapshot = { revision: revisionA, user: { ...user, onboarding_complete: false }, timetable: [], campus_map: { campus_name: '', places: [], warnings: [] } };
  const completed = [];
  const scrolls = [];
  class Api {
    invoke(name, args) {
      (name === 'onboardingSnapshot' ? reads : calls).push({ name, args: structuredClone(args) });
      if (handlers[name]) return handlers[name](...args);
      if (name === 'onboardingCampusData') return Promise.resolve(onboardingCampusData());
      if (name === 'onboardingSnapshot') return Promise.resolve(structuredClone(snapshot));
      if (name === 'onboardingOperation') return Promise.resolve(receipt(snapshot.timetable, snapshot.campus_map).receipt);
      if (name === 'completeOnboarding') { snapshot = { revision: revisionB, user: { ...user }, timetable: structuredClone(args[3]), campus_map: structuredClone(args[4]) }; return Promise.resolve(receipt(args[3], args[4])); }
      throw new Error(`unexpected API: ${name}`);
    }
    onboardingSnapshot(...args) { return this.invoke('onboardingSnapshot', args); }
    onboardingOperation(...args) { return this.invoke('onboardingOperation', args); }
    previewSubscription(...args) { return this.invoke('previewSubscription', args); }
    onboardingCampusData(...args) { return this.invoke('onboardingCampusData', args); }
    completeOnboarding(...args) { return this.invoke('completeOnboarding', args); }
    saveSubscription(...args) { return this.invoke('saveSubscription', args); }
    syncSubscription(...args) { return this.invoke('syncSubscription', args); }
  }
  class Scroller { scrollEdge(edge) { scrolls.push(edge); } }
  const Page = createPage(Api, feedback.CampusFlowRequestError, Scroller, { Top: 'top' },
    timetable.normalizeTimetableEntry, timetable.validateTimetableEntry, timetable.validateTimetableList,
    timetable.parseTimetablePreview, timetable.expandWeeklyEntry, agenda.shanghaiDate, () => operationId, draftStore, historyScope, importReview.parseImportReview, importReview.assembleSelectedImport);
  const page = new Page();
  page.baseUrl = 'http://fixture.invalid';
  page.token = 'test-only'; page.draftLease = lease;
  page.onCompleted = value => completed.push(value);
  page.aboutToAppear(); await tick();
  return { page, calls, reads, completed, scrolls, draftStore, lease, stored: () => storedText, setSnapshot: value => { snapshot = structuredClone(value); } };
}
function fillEditor(page, entry = course()) {
  for (const [field, value] of Object.entries(entry)) page.updateEditor(field, value);
}
function readyToConfirm(f, entries = [course()]) {
  f.page.semester = '  2026-2027 第一学期  ';
  f.page.nextStep();
  f.page.refreshDraft(entries);
  f.page.nextStep();
  assert.equal(f.page.step, 2);
}
function prepareImport(f, url = 'https://neo.hduhelp.com/hduhelp-neo/feed/schedule?token=fixture-only-123456') {
  f.page.selectSource('subscription');
  f.page.updateScheduleUrl(url);
}

test('steps require a valid semester, at least one course and an explicitly resolved editor', async () => {
  const f = await fixture();
  f.page.semester = ' ';
  f.page.nextStep();
  assert.equal(f.page.step, 0);
  f.page.semester = '学'.repeat(81);
  f.page.nextStep();
  assert.equal(f.page.step, 0);
  f.page.semester = user.semester;
  f.page.nextStep();
  f.page.nextStep();
  assert.equal(f.page.step, 1);
  fillEditor(f.page);
  f.page.nextStep();
  assert.equal(f.page.step, 1);
  f.page.addEntry();
  f.page.nextStep();
  assert.equal(f.page.step, 2);
  assert.deepEqual(f.page.entries, [course()]);
  f.page.previousStep();
  assert.equal(f.page.step, 1);
  assert.deepEqual(f.page.entries, [course()]);
  assert.deepEqual(f.calls, []);
});

test('manual entry shows field errors without truncation and requires explicit weekly expansion', async () => {
  const f = await fixture();
  const invalid = course({ date: '2026-02-30', title: '😀'.repeat(101), end_time: '08:05' });
  fillEditor(f.page, invalid);
  f.page.addEntry();
  assert.deepEqual(f.page.entries, []);
  assert.equal(f.page.editor.title, invalid.title);
  for (const field of ['date', 'title', 'end_time']) assert.ok(f.page.fieldErrors[field].length > 0);
  fillEditor(f.page, course({ date: '2026-12-28' }));
  assert.equal(f.page.fieldErrors.date, '');
  f.page.setRepeatWeeks(3);
  f.page.addEntry();
  assert.deepEqual(f.page.entries.map(entry => entry.date), ['2026-12-28', '2027-01-04', '2027-01-11']);
  assert.equal(f.page.repeatWeeks, 1);
  assert.equal(f.page.editorDirty, false);
  assert.equal(f.page.editorOpen, false);
  assert.match(f.page.notice, /尚未保存/);
  assert.deepEqual(f.calls, []);
});

test('editing changes only one concrete course; dirty drafts cannot be replaced by another editor or source', async () => {
  const f = await fixture();
  const second = course({ date: '2026-10-26' });
  f.page.refreshDraft([course(), second]);
  f.page.editEntry(0);
  f.page.updateEditor('title', '  修改后的课程  ');
  f.page.editEntry(1);
  f.page.selectSource('subscription');
  f.page.newEntry();
  f.page.requestDelete(1);
  assert.equal(f.page.editingIndex, 0);
  assert.equal(f.page.editor.title, '  修改后的课程  ');
  assert.equal(f.page.source, 'manual');
  assert.equal(f.page.pendingDelete, -1);
  f.page.setRepeatWeeks(12);
  assert.equal(f.page.repeatWeeks, 1);
  f.page.addEntry();
  assert.deepEqual(f.page.entries, [course({ title: '修改后的课程' }), second]);
  f.page.editEntry(0);
  f.page.updateEditor('title', '随后放弃');
  f.page.cancelEdit();
  assert.equal(f.page.entries[0].title, '修改后的课程');
  assert.equal(f.page.editingIndex, -1);
  assert.deepEqual(f.calls, []);
});

test('removal needs the matching confirmation and duplicate courses preserve the current draft', async () => {
  const f = await fixture();
  const second = course({ date: '2026-10-26' });
  f.page.refreshDraft([course(), second]);
  f.page.removeEntry(0);
  assert.equal(f.page.entries.length, 2);
  f.page.requestDelete(0);
  f.page.removeEntry(1);
  assert.equal(f.page.entries.length, 2);
  f.page.removeEntry(0);
  f.page.removeEntry(0);
  assert.deepEqual(f.page.entries, [second], 'repeat deletion cannot remove the next row');
  fillEditor(f.page, second);
  f.page.addEntry();
  assert.deepEqual(f.page.entries, [second]);
  assert.equal(f.page.editor.title, second.title);
  assert.match(f.page.message, /完全相同/);
  assert.deepEqual(f.calls, []);
});

test('preview is read-only until explicit acceptance, which merges courses and discards the subscription URL', async () => {
  const imported = course({ date: '2026-10-20', title: '计算机网络' });
  const f = await fixture({ previewSubscription: async () => preview([imported]) });
  f.page.step = 1;
  f.page.refreshDraft([course()]);
  prepareImport(f);
  await f.page.previewImport();
  assert.deepEqual(f.page.entries, [course()]);
  assert.deepEqual(f.page.importRows.map(row => row.entry), [imported]);
  assert.deepEqual(f.calls.map(call => call.name), ['previewSubscription']);
  f.page.nextStep();
  assert.equal(f.page.step, 1, 'preview must be accepted or discarded first');
  f.page.acceptImport();
  f.page.acceptImport();
  assert.deepEqual(f.page.entries, [course(), imported]);
  assert.deepEqual(f.page.importRows, []);
  assert.equal(f.page.scheduleUrl, '');
  assert.match(f.page.importedNotice, /不保存订阅链接/);
  f.page.nextStep();
  await f.page.finish();
  assert.deepEqual(f.calls.map(call => call.name), ['previewSubscription', 'onboardingCampusData', 'completeOnboarding']);
  assert.deepEqual(f.calls.at(-1).args[3], [course(), imported]);
  assert.equal(f.completed.length, 1);
});

test('failed merges retain both the existing draft and preview so the user can correct them', async () => {
  const f = await fixture({ previewSubscription: async () => preview() });
  f.page.refreshDraft([course()]);
  prepareImport(f);
  await f.page.previewImport();
  f.page.acceptImport();
  assert.deepEqual(f.page.entries, [course()]);
  assert.deepEqual(f.page.importRows.map(row => row.entry), [course()]);
  assert.match(f.page.message, /均保留/);
  assert.notEqual(f.page.scheduleUrl, '');
  assert.deepEqual(f.calls.map(call => call.name), ['previewSubscription']);
});

test('accepted import source warnings survive editing, removal and repeated confirmation without keeping stale row warnings', async () => {
  const payload = preview([course(), course({ title: '时间重叠的课程', start_time: '09:00', end_time: '10:00' })]);
  payload.warnings = ['仅涵盖本学期。', '未声明时区的来源按北京时间解释。'];
  const f = await fixture({ previewSubscription: async () => payload });
  f.page.step = 1;
  prepareImport(f);
  await f.page.previewImport();
  const classification = importReview.classifyImportRows(f.page.importRows, f.page.entries);
  assert.equal(classification.overlapCount, 2);
  f.page.acceptImport(); assert.equal(f.page.entries.length, 0, 'overlap cannot auto-accept');
  f.page.changeImportChoices(classification.rows.map(row => ({ sourceIndex: row.sourceIndex, mode: 'include', edited: null, sourceIssuesReviewed: false, overlapKey: row.overlapKey })));
  f.page.acceptImport();
  const expected = payload.warnings.map(message => ({ index: -1, relatedIndex: -1, field: 'import', message }));
  assert.deepEqual(f.page.sourceWarnings, expected, 'only provenance warnings are persisted, not row-specific conflicts');
  assert.deepEqual(f.page.importWarnings, [], 'clearing the preview must not clear accepted source warnings');
  f.page.nextStep();
  assert.equal(f.page.step, 2);
  assert.deepEqual(f.page.sourceWarnings, expected);
  f.page.previousStep();
  f.page.editEntry(0);
  f.page.updateEditor('title', '已核对的操作系统课程');
  f.page.addEntry();
  assert.deepEqual(f.page.sourceWarnings, expected);
  f.page.requestDelete(1);
  f.page.removeEntry(1);
  assert.deepEqual(f.page.sourceWarnings, expected);
  assert.deepEqual(f.page.warnings, [], 'removing the overlapping row clears computed conflicts only');
  f.page.nextStep();
  assert.equal(f.page.step, 2);
  assert.deepEqual(f.page.sourceWarnings, expected);
  assert.equal(f.page.entries[0].title, '已核对的操作系统课程');
  assert.deepEqual(f.calls.map(call => call.name), ['previewSubscription']);
});

test('preview and draft pagination preserve every course and use global indexes, retreating after the last page is emptied', async () => {
  const entries = Array.from({ length: 21 }, (_, index) => course({
    date: `2026-10-${String(index + 1).padStart(2, '0')}`, title: `课程 ${index + 1}`
  }));
  const f = await fixture({ previewSubscription: async () => preview(entries) });
  prepareImport(f);
  await f.page.previewImport();
  const panel = importPanel(f.page.importRows, f.page.entries), previewRows = [];
  for (let page = 0; page < 4; page++) {
    panel.pageIndex = page;
    const rows = panel.pageRows();
    assert.equal(rows.length, page === 3 ? 3 : 6);
    previewRows.push(...rows);
  }
  assert.deepEqual(previewRows.map(row => row.sourceIndex), Array.from({ length: 21 }, (_, index) => index));
  assert.deepEqual(previewRows.map(row => row.entry), entries);
  assert.deepEqual(f.page.importRows.map(row => row.entry), entries, 'pagination never truncates preview data');
  f.page.acceptImport();
  assert.deepEqual(f.page.entries, entries, 'acceptance imports all pages, not just the visible rows');
  const draftRows = [];
  for (let page = 0; page < 3; page++) {
    f.page.pageIndex = page;
    draftRows.push(...f.page.draftRows());
  }
  assert.deepEqual(draftRows.map(row => row.index), Array.from({ length: 21 }, (_, index) => index));
  assert.deepEqual(draftRows.map(row => row.entry), entries);
  const last = f.page.draftRows()[0];
  assert.equal(last.index, 20);
  f.page.requestDelete(last.index);
  f.page.removeEntry(last.index);
  assert.equal(f.page.pageIndex, 1);
  assert.deepEqual(f.page.draftRows().map(row => row.index), [10, 11, 12, 13, 14, 15, 16, 17, 18, 19]);
  assert.deepEqual(f.page.entries, entries.slice(0, 20), 'only the explicitly removed course is dropped');
  assert.deepEqual(f.calls.map(call => call.name), ['previewSubscription']);
});

test('empty or malformed previews never replace an existing draft and never leak error diagnostics', async () => {
  for (const result of [null, {}, preview([]), { ...preview(), event_count: 8 },
    preview([course({ date: '2026-02-30' })])]) {
    const f = await fixture({ previewSubscription: async () => result });
    f.page.refreshDraft([course()]);
    prepareImport(f);
    await f.page.previewImport();
    assert.deepEqual(f.page.entries, [course()]);
    assert.deepEqual(f.page.importRows, []);
    assert.match(f.page.message, /预览未加入草稿/);
    assert.equal(f.page.loading, false);
  }
});

test('cancelled preview responses cannot overwrite a newer request, its loading state or a new source', async () => {
  const old = deferred();
  const fresh = deferred();
  let request = 0;
  const f = await fixture({ previewSubscription: () => (++request === 1 ? old.promise : fresh.promise) });
  prepareImport(f, 'https://fixture.invalid/old');
  const first = f.page.previewImport();
  await f.page.previewImport();
  assert.equal(f.calls.length, 1, 'repeated preview clicks share the pending operation');
  f.page.cancelPreview();
  f.page.updateScheduleUrl('https://fixture.invalid/new');
  const second = f.page.previewImport();
  old.resolve(preview([course({ title: '旧预览' })]));
  await first;
  assert.equal(f.page.loading, true);
  assert.deepEqual(f.page.importRows, []);
  fresh.resolve(preview([course({ title: '新预览' })]));
  await second;
  assert.equal(f.page.importRows[0].input.title, '新预览');
  assert.equal(f.page.loading, false);
  f.page.selectSource('manual');
  assert.equal(f.page.source, 'subscription', 'source switch cannot silently drop reviewed rows');
  f.page.cancelPreview(); f.page.selectSource('manual');
  assert.deepEqual(f.page.importRows, []);
  assert.deepEqual(f.page.entries, []);
});

test('URL edits invalidate an existing preview; old responses after leaving cannot update or navigate', async () => {
  const f = await fixture({ previewSubscription: async () => preview() });
  prepareImport(f);
  await f.page.previewImport();
  f.page.updateScheduleUrl('https://fixture.invalid/changed');
  f.page.acceptImport();
  assert.deepEqual(f.page.entries, []);
  assert.deepEqual(f.page.importRows, []);
  const pending = deferred();
  const leaving = await fixture({ previewSubscription: () => pending.promise });
  prepareImport(leaving);
  const request = leaving.page.previewImport();
  leaving.page.aboutToDisappear();
  pending.resolve(preview());
  await request;
  assert.equal(leaving.page.scheduleUrl, '');
  assert.deepEqual(leaving.page.importRows, []);
  assert.deepEqual(leaving.page.entries, []);
  assert.deepEqual(leaving.completed, []);
});

test('preview failures use safe status messages and only authentication failure requests login', async () => {
  const secret = 'PRIVATE_subscription_token_123456';
  for (const error of [new Error(secret), new feedback.CampusFlowRequestError(422, 'HTTP_ERROR', secret),
    new feedback.CampusFlowRequestError(401, 'HTTP_ERROR', secret), feedback.localRequestFailure('NETWORK_ERROR')]) {
    const f = await fixture({ previewSubscription: async () => { throw error; } });
    f.page.refreshDraft([course()]);
    prepareImport(f);
    await f.page.previewImport();
    assert.doesNotMatch(f.page.message, /PRIVATE|subscription_token/);
    assert.ok(f.page.message.length > 0);
    assert.equal(f.page.needsLogin, error.statusCode === 401);
    assert.equal(f.page.loading, false);
    assert.deepEqual(f.page.entries, [course()]);
  }
});

test('finish freezes confirmed courses and semester, blocks competing edits and submits exactly once', async () => {
  const data = deferred();
  const saved = deferred();
  const f = await fixture({ onboardingCampusData: () => data.promise, completeOnboarding: () => saved.promise });
  readyToConfirm(f);
  const finishing = f.page.finish();
  const revision = f.page.requestRevision;
  f.page.cancelPreview();
  f.page.previousStep();
  f.page.updateEditor('title', '不能更改');
  f.page.selectSource('subscription');
  f.page.requestDelete(0);
  await f.page.finish();
  assert.equal(f.page.step, 2);
  assert.equal(f.page.requestRevision, revision, 'saving cannot be cancelled as though it were a read-only preview');
  assert.equal(f.page.pendingDelete, -1);
  assert.deepEqual(f.calls.map(call => call.name), ['onboardingCampusData']);
  // Even mutations outside the disabled UI cannot change the captured request snapshot.
  f.page.entries[0].title = '较新的本地状态';
  f.page.semester = '较新的学期';
  data.resolve(onboardingCampusData());
  await tick();
  assert.deepEqual(f.calls.at(-1).args[3], [course()]);
  assert.equal(f.calls.at(-1).args[2], user.semester);
  assert.deepEqual(f.calls.at(-1).args[4].places,
    [{ name: '图书馆', category: '学习', zone: '中区', aliases: ['馆'] }]);
  f.setSnapshot({ revision: revisionB, user: { ...user }, timetable: [course()], campus_map: { campus_name: '杭电', places: [{}], warnings: [] } });
  saved.resolve(receipt());
  await finishing;
  await f.page.finish();
  assert.deepEqual(f.calls.map(call => call.name), ['onboardingCampusData', 'completeOnboarding']);
  assert.deepEqual(f.completed, [user]);
  assert.equal(f.page.completed, true);
  assert.equal(f.page.loading, false);
});

test('finish cannot submit before confirmation or with invalid courses or semester', async () => {
  for (const step of [0, 1]) {
    const f = await fixture();
    f.page.step = step;
    f.page.entries = [course()];
    await f.page.finish();
    assert.deepEqual(f.calls, []);
  }
  for (const change of [{ entries: [] }, { entries: [course({ end_time: '07:00' })] },
    { semester: ' ' }, { semester: '学'.repeat(81) }]) {
    const f = await fixture();
    readyToConfirm(f);
    Object.assign(f.page, change);
    await f.page.finish();
    assert.deepEqual(f.calls, []);
    assert.equal(f.completed.length, 0);
  }
});

test('missing, empty or mismatched campus data cannot be relabelled or submitted as the supplied campus', async () => {
  const wrong = onboardingCampusData();
  wrong.package.campus = '其他校区';
  for (const snapshot of [null, {}, { ...onboardingCampusData(), places: [] }, wrong,
    { ...onboardingCampusData(), places: [{ name: '图书馆', category: '学习', zone: '', aliases: [42] }] }]) {
    const f = await fixture({ onboardingCampusData: async () => snapshot });
    readyToConfirm(f);
    await f.page.finish();
    assert.deepEqual(f.calls.map(call => call.name), ['onboardingCampusData']);
    assert.match(f.page.message, /尚未提交/);
    assert.deepEqual(f.page.entries, [course()]);
    assert.equal(f.page.loading, false);
    assert.equal(f.completed.length, 0);
  }
});

test('ambiguous save blocks new writes and only exact not-found permits same-ID frozen retry', async () => {
  let saves = 0;
  const f = await fixture({ completeOnboarding: async (...args) => {
    if (++saves === 1) throw feedback.localRequestFailure('NETWORK_ERROR');
    return receipt(args[3], args[4]);
  }, onboardingOperation: async () => { throw new feedback.CampusFlowRequestError(404, 'ONBOARDING_OPERATION_NOT_FOUND', 'safe'); } });
  readyToConfirm(f);
  await f.page.finish();
  assert.match(f.page.message, /保存结果尚未确认/);
  assert.equal(f.page.completed, false);
  assert.equal(f.page.loading, false);
  assert.deepEqual(f.page.entries, [course()]);
  assert.equal(f.completed.length, 0);
  await f.page.finish();
  assert.equal(saves, 1); await f.page.retrySameSubmission(); assert.equal(saves, 1);
  await f.page.checkSaveResult();
  f.setSnapshot({ revision: revisionB, user: { ...user }, timetable: [course()], campus_map: { campus_name: '杭电', places: [{}], warnings: [] } });
  await f.page.retrySameSubmission();
  const writes = f.calls.filter(call => call.name === 'completeOnboarding');
  assert.equal(writes.length, 2);
  assert.deepEqual(writes[0].args, writes[1].args);
  assert.equal(f.completed.length, 1);
  assert.ok(f.calls.every(call => !['saveSubscription', 'syncSubscription'].includes(call.name)));
});

test('incomplete or mismatched save receipts do not announce onboarding completion', async () => {
  const invalid = [null, {}, { ...receipt(), user: null }, { ...receipt(), user: { ...user, onboarding_complete: false } },
    { ...receipt(), user: { ...user, onboarding_complete: 'false' } },
    { ...receipt(), timetable_count: 2 }, { ...receipt(), campus_place_count: 0 }];
  for (const result of invalid) {
    const f = await fixture({ completeOnboarding: async () => result });
    readyToConfirm(f);
    await f.page.finish();
    assert.equal(f.completed.length, 0, JSON.stringify(result));
    assert.equal(f.page.completed, false);
    assert.equal(f.page.loading, false);
    assert.match(f.page.message, /回执不完整/);
    assert.deepEqual(f.page.entries, [course()]);
  }
});

test('leaving during the campus read prevents a write; leaving during a write prevents late completion', async () => {
  const data = deferred();
  const f = await fixture({ onboardingCampusData: () => data.promise });
  readyToConfirm(f);
  const first = f.page.finish();
  f.page.aboutToDisappear();
  data.resolve(onboardingCampusData());
  await first;
  assert.deepEqual(f.calls.map(call => call.name), ['onboardingCampusData']);
  assert.deepEqual(f.completed, []);
  const saved = deferred();
  const saving = await fixture({ completeOnboarding: () => saved.promise });
  readyToConfirm(saving);
  const second = saving.page.finish();
  await tick();
  assert.equal(saving.calls.at(-1).name, 'completeOnboarding');
  saving.page.aboutToDisappear();
  saved.resolve(receipt());
  await second;
  assert.equal(saving.page.completed, false);
  assert.deepEqual(saving.completed, []);
});

const apiSource = readFileSync(new URL('../entry/src/main/ets/services/CampusFlowApi.ets', import.meta.url), 'utf8')
  .replace(/^import http from '@ohos.net.http';\r?\n/m, '')
  .replace(/^import \{[\s\S]*?\} from '\.\.\/model\/ApiModels';\r?\n/m, '')
  .replace(/^import \{[^\n]+\} from '\.\.\/utils\/AgentFeedback';\r?\n/m, '')
  .replace('export class CampusFlowApi', 'class CampusFlowApi');
const createApi = new Function('http', 'CampusFlowRequestError', 'localRequestFailure', 'requestFailure',
  stripTypeScriptTypes(apiSource) + '\nreturn CampusFlowApi;');

test('the actual previewSubscription method sends an authenticated POST preview, never a subscription PUT', async () => {
  const calls = [];
  let destroyed = 0;
  const payload = preview();
  const http = { RequestMethod: { GET: 'GET', POST: 'POST', PUT: 'PUT', DELETE: 'DELETE' },
    HttpDataType: { STRING: 'STRING' }, createHttp: () => ({
      request: async (url, options) => { calls.push({ url, options }); return { responseCode: 200, result: JSON.stringify(payload) }; },
      destroy: () => { destroyed++; }
    }) };
  const Api = createApi(http, feedback.CampusFlowRequestError, feedback.localRequestFailure, feedback.requestFailure);
  const client = new Api('http://fixture.invalid/', 'fixture-auth');
  const url = 'https://neo.hduhelp.com/hduhelp-neo/feed/schedule?token=fixture-only-123456';
  assert.deepEqual(await client.previewSubscription(url), payload);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, 'http://fixture.invalid/api/v1/schedule-subscriptions/preview');
  assert.equal(calls[0].options.method, 'POST');
  assert.equal(calls[0].options.header.Authorization, 'Bearer fixture-auth');
  assert.equal(calls[0].options.header['Content-Type'], 'application/json');
  assert.deepEqual(JSON.parse(calls[0].options.extraData), { url });
  assert.equal(destroyed, 1);
});

test('partial onboarding form survives restart with original date and explicit restoration; URLs and unaccepted previews never persist', async () => {
  const first = await fixture(); first.page.anchorDate = '2026-10-18';
  first.page.updateSemester('尚未填完'); first.page.updateEditor('title', '  草稿  ');
  first.page.updateEditor('date', '2026-'); first.page.updateEditor('end_time', '0');
  first.page.scheduleUrl = 'https://private/?token=secret'; first.page.importRows = [sourceRow(0, course({ title: '未接受候选' }))];
  await first.page.flushDraft(); const disk = first.stored();
  assert.doesNotMatch(disk, /private|secret|未接受候选|scheduleUrl|importRows/);
  first.page.aboutToDisappear();
  const second = await fixture({ initialDraftText: disk });
  assert.ok(second.page.recoverableDraft); assert.equal(second.page.editor.title, '');
  second.page.updateEditor('title', '不可覆盖恢复候选'); assert.equal(second.page.editor.title, '');
  second.page.restoreStoredDraft(); await tick();
  assert.equal(second.page.editor.title, '  草稿  '); assert.equal(second.page.editor.date, '2026-');
  assert.equal(second.page.editor.end_time, '0'); assert.equal(second.page.anchorDate, '2026-10-18');
  assert.equal(second.page.expectedRevision, revisionA); assert.equal(second.page.submission, null);
  assert.equal(second.calls.some(call => call.name === 'completeOnboarding'), false);
});

test('restored onboarding baseline never rebinds to a changed account; full latest courses remain inspectable', async () => {
  const first = await fixture(); first.page.refreshDraft([course({ title: '我的旧草稿' })]); await first.page.flushDraft();
  const latest = Array.from({ length: 12 }, (_, i) => course({ title: `新课${i}`, date: `2026-11-${String(i + 1).padStart(2, '0')}` }));
  const second = await fixture({ initialDraftText: first.stored(), onboardingSnapshot: async () => ({ revision: revisionB,
    user: { ...user }, timetable: latest, campus_map: { campus_name: '新地图', places: [], warnings: [] } }) });
  second.page.restoreStoredDraft(); await tick();
  assert.equal(second.page.expectedRevision, revisionA); assert.equal(second.page.baselineStale, true);
  assert.equal(second.page.entries[0].title, '我的旧草稿'); second.page.latestPage = 1;
  assert.deepEqual(second.page.latestRows().map(item => item.index), [10, 11]);
  second.page.step = 2; await second.page.finish(); assert.equal(second.calls.some(call => call.name === 'completeOnboarding'), false);
  await second.page.discardStoredDraft(); await tick();
  assert.equal(second.page.expectedRevision, revisionB); assert.deepEqual(second.page.entries, []);
});

test('onboarding unknown write survives process restart and queries original ID before a frozen same-ID retry', async () => {
  const first = await fixture({ completeOnboarding: async () => { throw feedback.localRequestFailure('NETWORK_ERROR'); } });
  readyToConfirm(first); await first.page.finish(); const sent = first.calls.find(call => call.name === 'completeOnboarding').args;
  const second = await fixture({ initialDraftText: first.stored(), onboardingOperation: async () => {
    throw new feedback.CampusFlowRequestError(404, 'ONBOARDING_OPERATION_NOT_FOUND', 'safe');
  } });
  assert.ok(second.page.recoverableDraft); await second.page.discardStoredDraft(); assert.ok(second.page.recoverableDraft);
  second.page.restoreStoredDraft(); await tick();
  assert.equal(second.page.savePhase, 'retryable'); assert.deepEqual(second.calls.map(call => call.name), ['onboardingOperation']);
  assert.equal(second.calls[0].args[0], sent[5]); second.page.updateEditor('title', '不能改变冻结课程');
  await second.page.retrySameSubmission();
  assert.deepEqual(second.calls.find(call => call.name === 'completeOnboarding').args, sent);
  assert.equal(second.calls.some(call => call.name === 'onboardingCampusData'), false, 'retry uses the original reviewed map');
  assert.equal(second.completed.length, 1); assert.equal(second.draftStore.read(second.lease, { kind: 'onboarding', ownerId: 'main' }), undefined);
});

test('onboarding disk failure prevents PUT and exposes a recoverable local failure without raw diagnostics', async () => {
  let fail = false; const f = await fixture({ diskFailure: () => fail }); readyToConfirm(f); fail = true;
  await f.page.finish(); assert.equal(f.calls.some(call => call.name === 'completeOnboarding'), false);
  assert.equal(f.page.savePhase, 'uncertain'); assert.ok(f.page.draftMessage); assert.doesNotMatch(f.page.message, /disk|secret/);
  assert.deepEqual(f.page.entries, [course()]);
});

test('logout invalidates a late onboarding write callback and cannot resurrect cleared local drafts', async () => {
  const pending = deferred(); const f = await fixture({ completeOnboarding: () => pending.promise }); readyToConfirm(f);
  const saving = f.page.finish(); await tick(); assert.equal(f.calls.at(-1).name, 'completeOnboarding');
  await f.draftStore.clear(); pending.resolve(receipt()); await saving;
  assert.equal(f.completed.length, 0); const other = await f.draftStore.activate('fixture-service::other-user');
  assert.deepEqual(f.draftStore.list(other, 'onboarding'), []); assert.deepEqual(f.draftStore.operations(other), []);
});

test('onboarding confirmed stale rejection retains original baseline and reveals latest account differences', async () => {
  const f = await fixture({ completeOnboarding: async () => { throw new feedback.CampusFlowRequestError(409, 'ONBOARDING_STALE', 'safe'); } });
  readyToConfirm(f); f.setSnapshot({ revision: revisionB, user: { ...user }, timetable: [course({ title: '远端课程' })], campus_map: {} });
  await f.page.finish(); await tick();
  assert.equal(f.page.expectedRevision, revisionA); assert.equal(f.page.baselineStale, true);
  assert.equal(f.page.submission, null); assert.equal(f.page.latestSnapshot.timetable[0].title, '远端课程');
  assert.equal(f.draftStore.operations(f.lease).length, 0);
  await f.page.finish(); assert.equal(f.calls.filter(call => call.name === 'completeOnboarding').length, 1);
});


test('expired authentication during receipt recovery offers re-login and never infers a missing operation', async () => {
  const first = await fixture({ completeOnboarding: async () => { throw feedback.localRequestFailure('NETWORK_ERROR'); } });
  readyToConfirm(first); await first.page.finish();
  const next = await fixture({ initialDraftText: first.stored(), onboardingOperation: async () => {
    throw new feedback.CampusFlowRequestError(401, 'LOGIN_REQUIRED', 'safe');
  } });
  next.page.restoreStoredDraft(); await tick();
  assert.equal(next.page.needsLogin, true); assert.equal(next.page.savePhase, 'uncertain');
  await next.page.retrySameSubmission(); assert.equal(next.calls.some(call => call.name === 'completeOnboarding'), false);
});

test('a mismatched user in the latest onboarding snapshot cannot switch the authenticated account', async () => {
  const f = await fixture(); readyToConfirm(f);
  const good = f.page.validSnapshot({ revision: revisionA, user, timetable: [course()], campus_map: {} });
  assert.equal(good, true);
  assert.equal(f.page.validSnapshot({ revision: revisionA, user: { ...user, user_id: 'other-user' }, timetable: [course()], campus_map: {} }), false);
});

test('UX07 five-course continuous entry, explicit reuse and failed duplicate preserve independent drafts', async () => {
  const f=await fixture(); f.page.step=1;
  for(let index=0;index<5;index++) {fillEditor(f.page,course({title:`第 ${index+1} 门`,date:`2026-10-${19+index}`}));f.page.addEntry(true);assert.equal(f.page.entries.length,index+1);assert.equal(f.page.editorOpen,true);assert.equal(f.page.editor.title,'');}
  const saved=structuredClone(f.page.entries);f.page.reuseLastEntry();assert.equal(f.page.editor.title,'第 5 门');assert.equal(f.page.editorDirty,true);assert.deepEqual(f.page.entries,saved);
  f.page.updateEditor('title','新名称');f.page.reuseLastEntry();assert.equal(f.page.editor.title,'新名称','reuse never overwrites existing input');
  f.page.cancelEdit();f.page.newEntry();f.page.reuseLastEntry();f.page.addEntry(true);assert.equal(f.page.entries.length,5);assert.equal(f.page.editor.title,'第 5 门');assert.equal(f.page.editorOpen,true);assert.equal(f.page.editorDirty,true);
  assert.deepEqual(f.calls,[]);await f.page.flushDraft();assert.equal((f.draftStore.read(f.lease,{kind:'onboarding',ownerId:'main'}).payload).editor.title,'第 5 门');
});

test('UX07 first error requests focus without losing invalid text, and editing one occurrence cannot reuse another',async()=>{
 const f=await fixture();fillEditor(f.page,course({date:'2026-02-30',title:'   '}));f.page.addEntry(true);assert.equal(f.page.focusRevision,1);assert.equal(f.page.editor.title,'   ');assert.ok(f.page.fieldErrors.title.length>0);assert.equal(f.page.editorOpen,true);
 f.page.cancelEdit();f.page.refreshDraft([course()]);f.page.editEntry(0);f.page.lastEntry=course({title:'其他课'});f.page.reuseLastEntry();assert.equal(f.page.editor.title,'操作系统');f.page.updateEditor('title','这一次');f.page.addEntry(true);assert.equal(f.page.editorOpen,false);assert.equal(f.page.entries.length,1);assert.equal(f.page.entries[0].title,'这一次');
});

test('UX07 mixed import rows block advancement until invalid source is explicitly excluded; accepted data alone persists',async()=>{
 const payload=preview([course({date:'2026-10-20'})]);payload.rows.push(sourceRow(1,course({date:'2026-02-30'}),{status:'invalid',entry:null,issues:[{field:'date',code:'INVALID_DATE',severity:'error',message:'日期无效'}]}));payload.source_event_count=2;payload.entries=[];payload.event_count=0;
 const f=await fixture({previewSubscription:async()=>payload});f.page.step=1;f.page.refreshDraft([course()]);prepareImport(f);await f.page.previewImport();assert.equal(f.page.importRows.length,2);
 f.page.acceptImport();f.page.nextStep();assert.equal(f.page.entries.length,1);assert.equal(f.page.step,1);assert.equal(f.page.importRows.length,2);
 f.page.changeImportChoices([{sourceIndex:1,mode:'exclude',edited:null,sourceIssuesReviewed:false,overlapKey:''}]);f.page.acceptImport();assert.equal(f.page.entries.length,2);assert.equal(f.page.importRows.length,0);assert.ok(f.page.sourceWarnings.some(w=>/排除 1/.test(w.message)));await f.page.flushDraft();assert.doesNotMatch(f.stored(),/source_time|INVALID_DATE|importRows|scheduleUrl/);f.page.nextStep();assert.equal(f.page.step,2);
});

test('UX07 a token change cancels read-only preview and invalidates picker context without accepting late data',async()=>{
 const pending=deferred();const f=await fixture({previewSubscription:()=>pending.promise});prepareImport(f);const generation=f.page.editorGeneration;const task=f.page.previewImport();f.page.token='replacement';f.page.editorConnectionChanged();pending.resolve(preview());await task;
 assert.equal(f.page.loading,false);assert.equal(f.page.importRows.length,0);assert.equal(f.page.entries.length,0);assert.ok(f.page.editorGeneration>generation);assert.deepEqual(f.calls.map(c=>c.name),['previewSubscription']);
});

test('UX07 account switch while finish awaits baseline cannot submit the old courses using the new identity or clear its busy state',async()=>{
 const late=deferred();let reads=0;const secondUser={...user,user_id:'second-user',onboarding_complete:false};
 const f=await fixture({onboardingSnapshot:async()=>{reads++;if(reads===2)return late.promise;return {revision:reads===1?revisionA:revisionB,user:reads===1?{...user,onboarding_complete:false}:secondUser,timetable:[],campus_map:{campus_name:'',places:[],warnings:[]}};}});
 readyToConfirm(f,[course({title:'A账号原课程'})]);f.page.expectedRevision='';const pending=f.page.finish();await tick();
 const lease=await f.draftStore.activate(historyScope('http://fixture.invalid','second-user'));f.page.token='second-only';f.page.draftLease=lease;f.page.draftLeaseChanged();await tick();
 assert.equal(f.page.step,0);assert.deepEqual(f.page.entries,[]);assert.equal(f.page.expectedRevision,revisionB);f.page.loading=true;f.page.busyLabel='B账号自己的操作';
 late.resolve({revision:revisionA,user:{...user,onboarding_complete:false},timetable:[],campus_map:{campus_name:'',places:[],warnings:[]}});await pending;
 assert.deepEqual(f.calls,[],'neither campus fetch nor onboarding PUT may run for the discarded caller');assert.equal(f.page.loading,true);assert.equal(f.page.busyLabel,'B账号自己的操作');assert.equal(f.page.submission,null);assert.deepEqual(f.page.entries,[]);
});

test('UX07 token-only change during baseline preflight aborts without freezing old content under new credentials',async()=>{
 const late=deferred();let reads=0;const f=await fixture({onboardingSnapshot:async()=>{reads++;if(reads===2)return late.promise;return {revision:revisionA,user:{...user,onboarding_complete:false},timetable:[],campus_map:{campus_name:'',places:[],warnings:[]}};}});
 readyToConfirm(f);f.page.expectedRevision='';const request=f.page.finish();await tick();f.page.token='changed';f.page.editorConnectionChanged();
 late.resolve({revision:revisionA,user:{...user,onboarding_complete:false},timetable:[],campus_map:{campus_name:'',places:[],warnings:[]}});await request;assert.deepEqual(f.calls,[]);assert.equal(f.page.loading,false);assert.equal(f.page.submission,null);
});

test('UX07 editing an existing onboarding course cannot silently discard reviewed import rows or choices',async()=>{
 const f=await fixture({previewSubscription:async()=>preview([course({date:'2026-10-20'})])});f.page.refreshDraft([course()]);prepareImport(f);await f.page.previewImport();
 f.page.changeImportChoices([{sourceIndex:0,mode:'exclude',edited:course({title:'已核对的修改',date:'2026-10-20'}),sourceIssuesReviewed:true,overlapKey:'frozen-review'}]);
 const rows=structuredClone(f.page.importRows),choices=structuredClone(f.page.importChoices);f.page.editEntry(0);assert.deepEqual(f.page.importRows,rows);assert.deepEqual(f.page.importChoices,choices);assert.equal(f.page.source,'subscription');assert.equal(f.page.editingIndex,-1);assert.match(f.page.message,/先加入所选课程或明确放弃/);
 f.page.cancelPreview();f.page.editEntry(0);assert.equal(f.page.editingIndex,0);assert.equal(f.page.source,'manual');
});

test('UX07 all 500 diagnostic courses persist through the real draft store and onboarding durable submit', async () => {
  const result = maximumWarningPreview();
  const f = await fixture({ previewSubscription: async () => result });
  f.page.updateSemester(user.semester); f.page.nextStep(); prepareImport(f);
  await f.page.previewImport(); assert.equal(f.page.importRows.length, 500);
  f.page.acceptImport(); assert.deepEqual(f.page.entries, result.entries);
  assert.equal(f.page.draftMessage, '');
  await f.page.flushDraft();
  const restarted = new DraftStore({ read: async () => f.stored(), write: async () => {}, remove: async () => {} });
  await restarted.initialize(); const restoredLease = await restarted.activate(f.lease.scope);
  const restored = restarted.read(restoredLease, { kind: 'onboarding', ownerId: 'main' });
  assert.deepEqual(restored.payload.entries, result.entries, 'all courses must survive actual serialization and fresh-store validation');
  assert.equal(restored.payload.sourceWarnings.length, 6, 'four repeated row reasons plus two source-wide notices remain bounded');
  for (const warning of restored.payload.sourceWarnings.slice(2)) assert.match(warning.message, /500/);
  const persistedWarnings = restored.payload.sourceWarnings.map(warning => warning.message).join('\n');
  assert.match(persistedWarnings, /时区/); assert.match(persistedWarnings, /分钟精度/);
  f.page.nextStep(); await f.page.finish();
  const writes = f.calls.filter(call => call.name === 'completeOnboarding');
  assert.equal(writes.length, 1); assert.deepEqual(writes[0].args[3], result.entries);
  assert.equal(f.page.completed, true); assert.equal(f.completed.length, 1);
});
test('UX11 initial campus lookup uses selected fixed scope without requiring a previously saved profile',async()=>{
 const f=await fixture();readyToConfirm(f);await f.page.finish();const read=f.calls.find(c=>c.name==='onboardingCampusData');assert.deepEqual(read.args,['杭州电子科技大学','下沙校区']);assert.equal(f.completed.length,1);
 const bad=await fixture({onboardingCampusData:async()=>{throw new feedback.CampusFlowRequestError(404,'DATA_SCOPE_UNSUPPORTED','当前校区暂不支持。');}});readyToConfirm(bad);await bad.page.finish();assert.equal(bad.calls.some(c=>c.name==='completeOnboarding'),false);assert.match(bad.page.message,/校区.*草稿仍保留/);assert.deepEqual(bad.page.entries,[course()]);
});

test('campus lookup authentication and unknown failures preserve drafts without freezing or posting onboarding',async()=>{
  for(const failure of [new feedback.CampusFlowRequestError(401,'LOGIN_REQUIRED','private diagnostic'),
    new Error('private diagnostic'),{statusCode:401,code:'LOGIN_REQUIRED',message:'private diagnostic'}]) {
    const f=await fixture({onboardingCampusData:async()=>{throw failure;}});
    readyToConfirm(f);
    const original=structuredClone(f.page.entries);
    await f.page.finish();
    assert.equal(f.page.needsLogin,failure instanceof feedback.CampusFlowRequestError);
    assert.match(f.page.message,f.page.needsLogin ? /登录已失效/ : /校园地点暂时无法读取/);
    assert.doesNotMatch(f.page.message,/private diagnostic/);
    assert.deepEqual(f.page.entries,original);
    assert.equal(f.page.submission,null);
    assert.equal(f.page.loading,false);
    assert.equal(f.calls.some(call=>call.name==='completeOnboarding'),false);
    assert.deepEqual(f.completed,[]);
  }
});
