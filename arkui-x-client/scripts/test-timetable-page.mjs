import './helpers/theme-fixture.mjs';
import { importReview, diagnosticPreview, sourceRow, maximumWarningPreview } from './helpers/timetable-editor-fixture.mjs';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripThemeTypeScriptTypes as stripTypeScriptTypes } from './helpers/theme-fixture.mjs';
import { test } from 'node:test';

const read = path => readFileSync(new URL(`../entry/src/main/ets/${path}`, import.meta.url), 'utf8');
const noImports = source => source.replace(/^import \{[\s\S]*?\} from '[^']+';\r?\n/gm, '').replace(/^import [^\n]+;\r?\n/gm, '');
const utility = async name => import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(noImports(read(`utils/${name}.ets`)))).toString('base64')}`);
const { DraftStore } = await utility('DraftStore');
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
  'validateTimetableList', 'parseTimetablePreview', 'expandWeeklyEntry', 'shanghaiDate', 'Scroller', 'Edge', 'timetableOperationId', 'localDrafts', 'parseImportReview', 'assembleSelectedImport', 'CampusFlowRequestError',
  stripTypeScriptTypes(prefix) + '\nreturn TimetablePage;');
const row = (title = '操作系统', date = '2026-10-20') => ({ date, title, start_time: '08:05', end_time: '09:40', location: '教学楼', teacher: '教师' });
const clone = value => JSON.parse(JSON.stringify(value));
const tick = () => new Promise(resolve => setImmediate(resolve));
function deferred() { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; }
async function fixture(handlers = {}) {
  const calls = [], notifications = [];
  let storedText = handlers.initialDraftText;
  const draftStore = handlers.draftStore ?? new DraftStore({ read: async () => storedText, write: async value => { if (handlers.diskFailure?.()) throw new Error('disk'); storedText = value; }, remove: async () => { storedText = undefined; } }, { now: () => Date.now(), set: () => 1, clear() {} });
  await draftStore.initialize();
  const lease = handlers.lease ?? await draftStore.activate('fixture-service::fixture-user');
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
    validation.validateTimetableList, validation.parseTimetablePreview, validation.expandWeeklyEntry, agenda.shanghaiDate, Scroller, { Top: 'top' }, () => '01234567-89ab-4def-8abc-0123456789ab', draftStore, importReview.parseImportReview, importReview.assembleSelectedImport, feedback.CampusFlowRequestError);
  const page = new Page(); page.draftLease = lease; page.onTimetableChanged = () => notifications.push(true); page.aboutToAppear(); await tick();
  return { page, calls, notifications, draftStore, lease, stored: () => storedText, setSnapshot: value => snapshot = clone(value) };
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
  await page.previewImport(); assert.equal(page.importRows.length, 0); assert.equal(page.entries.length, 1);
  result = diagnosticPreview([row()]); await page.previewImport(); page.acceptImport();
  assert.equal(page.entries.length, 1); assert.equal(page.importRows.length, 1); assert.match(page.message, /没有选中可新增/);
  page.cancelPreview(); result = diagnosticPreview([row('新课程', '2026-10-21')], ['来源仅涵盖本学期']);
  await page.previewImport(); page.reviewSave(); assert.equal(page.reviewOpen, false);
  page.acceptImport(); assert.equal(page.entries.length, 2); assert.equal(page.scheduleUrl, '');
  page.reviewSave(); assert.equal(page.reviewOpen, true); assert.equal(page.sourceWarnings[0].message, '来源仅涵盖本学期');
});

test('cancelled or hidden import ignores late response and never exposes private URL in failure copy', async () => {
  const late = deferred(); const { page } = await fixture({ preview: () => late.promise });
  page.selectSource('subscription'); page.updateScheduleUrl('https://private/?secret=123'); const read = page.previewImport();
  page.active = false; page.activityChanged(); late.resolve({ event_count: 1, entries: [row('晚到')] }); await read;
  assert.equal(page.scheduleUrl, ''); assert.equal(page.importRows.length, 0); assert.equal(page.entries.length, 1);
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

test('course draft and invalid editor restore explicitly after restart without rebinding original revision or date', async () => {
  const first = await fixture(); first.page.anchorDate = '2026-10-18'; first.page.newEntry();
  first.page.updateEditor('title', '  未完成  '); first.page.updateEditor('date', '2026-');
  first.page.updateEditor('end_time', ''); first.page.scheduleUrl = 'https://private/?token=secret';
  first.page.importRows = [sourceRow(0, row('未接受候选'))]; await first.page.flushDraft();
  const disk = first.stored(); assert.doesNotMatch(disk, /private|secret|未接受候选|scheduleUrl|importRows/);
  const second = await fixture({ initialDraftText: disk }); second.setSnapshot({ revision: 'c'.repeat(64), entries: [row('远端')] });
  assert.ok(second.page.recoverableDraft); second.page.restoreStoredDraft(); await tick();
  assert.equal(second.page.editor.title, '  未完成  '); assert.equal(second.page.editor.date, '2026-');
  assert.equal(second.page.anchorDate, '2026-10-18'); assert.equal(second.page.view.revision, 'a'.repeat(64));
  assert.equal(second.page.view.phase, 'stale'); assert.equal(second.page.view.latestEntries[0].title, '远端');
  assert.equal(second.page.entries[0].title, '操作系统'); assert.equal(second.calls.some(call => call[0] === 'put'), false);
});

test('timetable unknown write is restored through GET and same-ID frozen retry across process restart', async () => {
  const first = await fixture({ save: async () => { throw new feedback.CampusFlowRequestError(0, 'NETWORK_ERROR', 'safe'); } });
  first.page.editEntry(0); first.page.updateEditor('title', '冻结修改'); first.page.addEntry(); first.page.reviewSave();
  await first.page.save(); const sent = first.calls.find(call => call[0] === 'put');
  const second = await fixture({ initialDraftText: first.stored(), lookup: async () => {
    throw new feedback.CampusFlowRequestError(404, 'TIMETABLE_OPERATION_NOT_FOUND', 'safe');
  } });
  await second.page.discardStoredDraft(); assert.ok(second.page.recoverableDraft);
  second.page.restoreStoredDraft(); await tick(); assert.equal(second.page.view.phase, 'retryable');
  assert.equal(second.calls.some(call => call[0] === 'put'), false);
  second.page.updateEditor('title', '不可混入'); await second.page.controller.retrySameOperation(); await tick();
  assert.deepEqual(second.calls.find(call => call[0] === 'put'), sent);
  assert.equal(second.draftStore.read(second.lease, { kind: 'timetable', ownerId: 'main' }), undefined);
});

test('timetable disk failure blocks the network write but retains editable course content', async () => {
  let fail = false; const f = await fixture({ diskFailure: () => fail });
  f.page.editEntry(0); f.page.updateEditor('title', '本地保留'); f.page.addEntry(); f.page.reviewSave(); fail = true;
  await f.page.save(); assert.equal(f.calls.some(call => call[0] === 'put'), false);
  assert.equal(f.page.entries[0].title, '本地保留'); assert.ok(f.page.draftMessage); assert.equal(f.page.view.phase, 'error');
});

test('operation pointer write failure preserves its referenced draft until known-unsent cleanup succeeds', async () => {
  let armed = false, writes = 0;
  const f = await fixture({ diskFailure: () => armed && ++writes >= 2 });
  f.page.editEntry(0); f.page.updateEditor('title', '原冻结内容'); f.page.addEntry(); f.page.reviewSave();
  armed = true; await f.page.save(); await tick();
  assert.equal(f.calls.some(call => call[0] === 'put'), false);
  const operation = f.draftStore.operations(f.lease)[0];
  assert.ok(operation); assert.equal(f.page.trackedOperationId, operation.id);
  const frozen = f.draftStore.read(f.lease, { kind: 'timetable', ownerId: 'main' });
  assert.equal(frozen.localRevision, operation.localRevision);
  assert.equal(frozen.payload.submission.operationId, operation.id);
  assert.equal(frozen.payload.submission.entries[0].title, '原冻结内容');
  f.page.returnFromReview(); f.page.editEntry(0); f.page.updateEditor('title', '后续仍可编辑'); f.page.addEntry();
  assert.equal(f.page.entries[0].title, '后续仍可编辑');
  assert.equal(f.draftStore.read(f.lease, { kind: 'timetable', ownerId: 'main' }).localRevision, operation.localRevision,
    'new input cannot replace the frozen revision while cleanup remains blocked');
  armed = false; await f.page.flushDraft();
  assert.deepEqual(f.draftStore.operations(f.lease), []); assert.equal(f.page.trackedOperationId, '');
  const recovered = f.draftStore.read(f.lease, { kind: 'timetable', ownerId: 'main' });
  assert.equal(recovered.payload.submission, null); assert.equal(recovered.payload.draftEntries[0].title, '后续仍可编辑');
  assert.equal(f.calls.some(call => call[0] === 'put'), false);
});

test('account switch invalidates hidden course callbacks and clears raw editor and imported URL', async () => {
  const pending = deferred(); const f = await fixture({ save: () => pending.promise });
  f.page.editEntry(0); f.page.updateEditor('title', '旧账号草稿'); f.page.addEntry(); f.page.reviewSave(); const saving = f.page.save(); await tick();
  await f.draftStore.clear(); f.page.draftLease = null; f.page.draftLeaseChanged();
  pending.resolve({ operation_id: '01234567-89ab-4def-8abc-0123456789ab', status: 'applied', previous_revision: 'a'.repeat(64),
    revision: 'b'.repeat(64), entry_count: 1, applied_at: new Date().toISOString() }); await saving;
  assert.deepEqual(f.notifications, []); assert.deepEqual(f.page.entries, []); assert.equal(f.page.controller, null);
});

test('UX07 continuous five-course entry reuses only explicit last course and never writes remotely',async()=>{
 const f=await fixture();f.page.newEntry();
 for(let i=0;i<5;i++){const entry=row(`新课 ${i}`,`2026-10-${21+i}`);for(const [field,value] of Object.entries(entry))f.page.updateEditor(field,value);f.page.addEntry(true);assert.equal(f.page.entries.length,i+2);assert.equal(f.page.editorOpen,true);}
 const old=clone(f.page.entries);f.page.reuseLastEntry();assert.equal(f.page.editor.title,'新课 4');assert.deepEqual(f.page.entries,old);f.page.updateEditor('date','2026-10-29');f.page.reuseLastEntry();assert.equal(f.page.editor.date,'2026-10-29');assert.match(f.page.message,/先加入或取消/);
 f.page.addEntry(false);assert.equal(f.page.entries.length,7);assert.equal(f.page.editorOpen,false);assert.equal(f.calls.filter(c=>c[0]==='put').length,0);
});

test('UX07 invalid manual fields request first-error focus, preserve verbatim input and keep correction feedback',async()=>{
 const f=await fixture();f.page.newEntry();f.page.updateEditor('title','😀'.repeat(101));f.page.updateEditor('date','2026-02-30');f.page.addEntry(true);assert.equal(f.page.focusRevision,1);assert.equal(f.page.entries.length,1);assert.equal(f.page.editor.title,'😀'.repeat(101));
 f.page.updateEditor('title','修正标题');assert.equal(f.page.fieldErrors.title,'');assert.notEqual(f.page.fieldErrors.date,'');assert.equal(f.page.editorOpen,true);
});

test('UX07 a wholly invalid diagnostic preview still blocks save and clear until explicitly handled',async()=>{
 const payload=diagnosticPreview([row('坏课')]);payload.rows[0]={...payload.rows[0],status:'invalid',input:{...row('坏课'),end_time:'00:00'},entry:null,issues:[{field:'end_time',code:'BAD_TIME',severity:'error',message:'结束早于开始'}]};payload.entries=[];payload.event_count=0;
 const f=await fixture({preview:async()=>payload});f.page.selectSource('subscription');f.page.updateScheduleUrl('https://private/?token=secret');await f.page.previewImport();assert.equal(f.page.importRows.length,1);assert.equal(f.page.view.dirty,true,'unaccepted source review is pending');
 f.page.reviewSave();assert.equal(f.page.reviewOpen,false);f.page.requestClear();assert.equal(f.page.clearRequested,false);f.page.acceptImport();assert.equal(f.page.entries.length,1);
 f.page.changeImportChoices([{sourceIndex:0,mode:'exclude',edited:null,sourceIssuesReviewed:false,overlapKey:''}]);f.page.acceptImport();assert.equal(f.page.entries.length,1,'empty selection never clears existing timetable');assert.equal(f.page.importRows.length,1);f.page.cancelPreview();assert.equal(f.page.importRows.length,0);assert.equal(f.calls.filter(c=>c[0]==='put').length,0);
});

test('UX07 hidden maintenance retains in-memory review identity while account switch invalidates it',async()=>{
 const f=await fixture({preview:async()=>diagnosticPreview([row('新课','2026-10-29')])});f.page.selectSource('subscription');f.page.updateScheduleUrl('https://private/');await f.page.previewImport();const generation=f.page.importGeneration;
 f.page.active=false;f.page.activityChanged();assert.equal(f.page.importGeneration,generation,'hide is not a new source review');assert.equal(f.page.importRows.length,1);assert.equal(f.page.scheduleUrl,'');
 f.page.draftLease=await f.draftStore.activate('other-service::other-user');f.page.draftLeaseChanged();assert.ok(f.page.importGeneration>generation);assert.equal(f.page.importRows.length,0);assert.equal(f.page.lastEntry,null);
});

test('UX07 editing an existing maintained course preserves all unaccepted import edits and exclusions until explicit discard',async()=>{
 const f=await fixture({preview:async()=>diagnosticPreview([row('候选','2026-10-21')])});f.page.selectSource('subscription');f.page.updateScheduleUrl('https://private/');await f.page.previewImport();
 f.page.changeImportChoices([{sourceIndex:0,mode:'exclude',edited:row('逐行修正','2026-10-21'),sourceIssuesReviewed:true,overlapKey:'current-facts'}]);const rows=clone(f.page.importRows),choices=clone(f.page.importChoices);
 f.page.editEntry(0);assert.deepEqual(f.page.importRows,rows);assert.deepEqual(f.page.importChoices,choices);assert.equal(f.page.source,'subscription');assert.equal(f.page.editingIndex,-1);assert.match(f.page.message,/先加入所选课程或明确放弃/);
 f.page.cancelPreview();f.page.editEntry(0);assert.equal(f.page.editingIndex,0);assert.equal(f.page.source,'manual');
});

test('UX07 all 500 diagnostic courses survive durable maintenance storage and complete-table save', async () => {
  const result = maximumWarningPreview();
  const f = await fixture({ get: async () => ({ revision: 'a'.repeat(64), entries: [] }), preview: async () => result });
  f.page.selectSource('subscription'); f.page.updateScheduleUrl('https://fixture.invalid/private-subscription');
  await f.page.previewImport(); assert.equal(f.page.importRows.length, 500);
  f.page.acceptImport(); assert.deepEqual(f.page.entries, result.entries); assert.equal(f.page.draftMessage, '');
  await f.page.flushDraft();
  const restarted = new DraftStore({ read: async () => f.stored(), write: async () => {}, remove: async () => {} });
  await restarted.initialize(); const restoredLease = await restarted.activate(f.lease.scope);
  const restored = restarted.read(restoredLease, { kind: 'timetable', ownerId: 'main' });
  assert.deepEqual(restored.payload.draftEntries, result.entries);
  assert.equal(restored.payload.sourceWarnings.length, 6);
  for (const warning of restored.payload.sourceWarnings.slice(2)) assert.match(warning.message, /500/);
  f.page.reviewSave(); assert.equal(f.page.reviewOpen, true); await f.page.save();
  const writes = f.calls.filter(call => call[0] === 'put');
  assert.equal(writes.length, 1); assert.deepEqual(writes[0][1], result.entries);
  assert.equal(f.notifications.length, 1);
});
