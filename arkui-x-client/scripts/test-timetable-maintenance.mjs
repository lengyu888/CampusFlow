import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';

const read = path => readFileSync(new URL(`../entry/src/main/ets/${path}`, import.meta.url), 'utf8');
const noImports = source => source.replace(/^import \{[\s\S]*?\} from '[^']+';\r?\n/gm, '').replace(/^import [^\n]+;\r?\n/gm, '');
const utility = async name => import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(noImports(read(`utils/${name}.ets`)))).toString('base64')}`);
const validation = await utility('OnboardingTimetable');
const feedback = await utility('AgentFeedback');
const source = noImports(read('utils/TimetableMaintenance.ets')).replace(/export /g, '');
const { TimetableMaintenance, timetableOperationId } = new Function('CampusFlowRequestError', 'normalizeTimetableEntry', 'validateTimetableList',
  stripTypeScriptTypes(source) + '\nreturn { TimetableMaintenance, timetableOperationId };')(
    feedback.CampusFlowRequestError, validation.normalizeTimetableEntry, validation.validateTimetableList);
const a = 'a'.repeat(64), b = 'b'.repeat(64), c = 'c'.repeat(64);
const id = '01234567-89ab-4def-8abc-0123456789ab';
const row = (title = '操作系统', date = '2026-10-20') => ({ date, title, start_time: '08:05', end_time: '09:40', location: '教学楼', teacher: '教师' });
const clone = value => JSON.parse(JSON.stringify(value));
const receipt = (extra = {}) => ({ operation_id: id, status: 'applied', previous_revision: a, revision: b, entry_count: 1, applied_at: '2026-10-20T12:00:00+08:00', ...extra });
const error = (status, code) => new feedback.CampusFlowRequestError(status, code, 'do not expose https://private/?key=secret');
const tick = () => new Promise(resolve => setImmediate(resolve));
function deferred() { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; }
function fixture(handlers = {}) {
  const calls = [], updates = [], applied = [];
  let current = { revision: a, entries: [row()] };
  const api = {
    async timetable() { calls.push(['get']); return handlers.get ? handlers.get() : clone(current); },
    async saveTimetable(entries, revision, operation, clear) {
      calls.push(['put', clone(entries), revision, operation, clear]);
      if (handlers.save) { return handlers.save(entries, revision, operation, clear); }
      current = { revision: b, entries: clone(entries) };
      return receipt({ operation_id: operation, entry_count: entries.length });
    },
    async timetableOperation(operation) { calls.push(['lookup', operation]); return handlers.lookup ? handlers.lookup(operation) : receipt(); }
  };
  const store = new TimetableMaintenance(api, state => updates.push(state), () => applied.push(true), () => id);
  return { store, calls, updates, applied, setCurrent: next => current = clone(next) };
}
async function loaded(handlers = {}) { const f = fixture(handlers); f.store.setActive(true); await tick(); return f; }

test('initial snapshot and returned state are detached; UUIDs satisfy the operation API format', async () => {
  const { store } = await loaded(); const state = store.snapshot();
  assert.equal(state.phase, 'ready'); state.entries[0].title = 'tampered'; assert.equal(store.snapshot().entries[0].title, '操作系统');
  for (let i = 0; i < 20; i++) { assert.match(timetableOperationId(), /^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/); }
});

test('dirty refresh preserves draft and blocks stale writes until explicit successful reload', async () => {
  const { store, calls, setCurrent } = await loaded(); store.replaceDraft([row('本地修改')]);
  await store.refresh(); assert.equal(store.snapshot().entries[0].title, '本地修改'); assert.equal(store.snapshot().dirty, true);
  setCurrent({ revision: c, entries: [row('其他设备')] }); await store.refresh(); assert.equal(store.snapshot().phase, 'stale');
  await store.save(); assert.equal(calls.filter(call => call[0] === 'put').length, 0);
  await store.refresh(true); assert.equal(store.snapshot().entries[0].title, '其他设备'); assert.equal(store.snapshot().dirty, false);
});

test('source metadata belongs to accepted baseline, stays isolated, and never labels an unsaved or rejected draft as newly synced', async () => {
  const evidence = [{ source_id: 'timetable:user', label: '已确认课表', kind: 'user', status: 'fresh',
    updated_at: '2026-10-18T03:00:00Z', expires_at: null, url: null, note: '保存时间' }];
  const f = fixture(); f.setCurrent({ revision: a, entries: [row()], evidence }); f.store.setActive(true); await tick();
  const state = f.store.snapshot(); state.evidence[0].label = 'tampered';
  assert.equal(f.store.snapshot().evidence[0].label, '已确认课表'); f.store.replaceDraft([row('本地修改')]);
  f.setCurrent({ revision: c, entries: [row('远端')], evidence: [{ ...evidence[0], label: '新版本' }] });
  await f.store.refresh(); assert.equal(f.store.snapshot().evidence[0].label, '已确认课表');
  assert.equal(f.store.snapshot().entries[0].title, '本地修改');
  await f.store.refresh(true); assert.equal(f.store.snapshot().evidence[0].label, '新版本');
});

test('pending editor prevents auto refresh replacing the current draft and prevents save', async () => {
  const { store, calls, setCurrent } = await loaded(); store.setEditorPending(true);
  setCurrent({ revision: c, entries: [row('远端')] }); await store.refresh(); await store.save();
  assert.equal(store.snapshot().entries[0].title, '操作系统'); assert.equal(store.snapshot().phase, 'stale');
  assert.equal(calls.filter(call => call[0] === 'put').length, 0);
});

test('unknown result freezes original operation; only explicit lookup then same-ID retry may write again', async () => {
  let attempt = 0; const { store, calls, setCurrent, applied } = await loaded({ save: async () => {
    if (++attempt === 1) { throw error(0, 'NETWORK_ERROR'); } return receipt();
  }, lookup: async () => { throw error(404, 'TIMETABLE_OPERATION_NOT_FOUND'); } });
  store.replaceDraft([row('待保存')]); await store.save(); assert.equal(store.snapshot().phase, 'uncertain');
  assert.equal(store.replaceDraft([row('不可混入')]), false); await store.save(); await store.refresh(true); await store.retrySameOperation();
  assert.equal(calls.filter(call => call[0] === 'put').length, 1);
  await store.checkResult(); assert.equal(store.snapshot().phase, 'retryable');
  setCurrent({ revision: b, entries: [row('待保存')] }); await store.retrySameOperation();
  const puts = calls.filter(call => call[0] === 'put'); assert.deepEqual(puts[0], puts[1]);
  assert.equal(store.snapshot().phase, 'saved'); assert.equal(applied.length, 1); assert.doesNotMatch(store.snapshot().message, /secret|https:/);
});

test('double tap while PUT is in flight sends one request and valid receipt is verified by GET', async () => {
  const pending = deferred(); const { store, calls, setCurrent, applied } = await loaded({ save: () => pending.promise });
  store.replaceDraft([row('修改')]); const save = store.save(); await store.save();
  setCurrent({ revision: b, entries: [row('修改')] }); pending.resolve(receipt()); await save;
  assert.equal(calls.filter(call => call[0] === 'put').length, 1); assert.equal(store.snapshot().phase, 'saved'); assert.equal(applied.length, 1);
});

test('malformed or mismatched receipt remains query-only; arbitrary 404 does not unlock retry', async () => {
  const { store } = await loaded({ save: async () => receipt({ entry_count: 99 }), lookup: async () => { throw error(404, 'NOT_FOUND'); } });
  store.replaceDraft([row('修改')]); await store.save(); assert.equal(store.snapshot().phase, 'uncertain');
  await store.checkResult(); assert.equal(store.snapshot().phase, 'uncertain'); assert.equal(store.canEdit(), false);
});

test('409 never overwrites; failed reload keeps the stale guard; 422 permits correcting the original draft', async () => {
  let getFails = false;
  const f = await loaded({ get: async () => { if (getFails) throw error(0, 'NETWORK_ERROR'); return { revision: a, entries: [row()] }; },
    save: async () => { throw error(409, 'TIMETABLE_STALE'); } });
  f.store.replaceDraft([row('本地')]); await f.store.save(); getFails = true; await f.store.refresh(true); await f.store.save();
  assert.equal(f.store.snapshot().phase, 'stale'); assert.equal(f.calls.filter(call => call[0] === 'put').length, 1);
  const g = await loaded({ save: async () => { throw error(422, 'TIMETABLE_INVALID'); } });
  g.store.replaceDraft([row('修正')]); await g.store.save(); assert.equal(g.store.canEdit(), true); assert.equal(g.store.snapshot().dirty, true);
});

test('empty table requires explicit clear confirmation and is sent without inventing a placeholder row', async () => {
  const { store, calls } = await loaded(); store.replaceDraft([]); await store.save(false);
  assert.equal(calls.filter(call => call[0] === 'put').length, 0); await store.save(true);
  const put = calls.find(call => call[0] === 'put'); assert.deepEqual(put[1], []); assert.equal(put[4], true); assert.equal(store.snapshot().phase, 'saved');
});

test('receipt followed by a newer revision announces applied once but does not replace draft with an unrelated snapshot', async () => {
  const { store, setCurrent, applied } = await loaded({ save: async () => receipt() });
  store.replaceDraft([row('本次保存')]); setCurrent({ revision: c, entries: [row('后续更新')] }); await store.save();
  assert.equal(applied.length, 1); assert.equal(store.snapshot().phase, 'stale'); assert.equal(store.snapshot().entries[0].title, '本次保存');
  assert.match(store.snapshot().message, /随后又有更新/); await store.refresh(true); assert.equal(store.snapshot().entries[0].title, '后续更新');
});

test('known applied receipt plus GET failure retains read-only verification state across hiding', async () => {
  let fail = false; const f = await loaded({ get: async () => { if (fail) throw error(0, 'NETWORK_ERROR'); return { revision: a, entries: [row()] }; }, save: async () => receipt() });
  f.store.replaceDraft([row('更新')]); fail = true; await f.store.save(); assert.equal(f.store.snapshot().phase, 'applied');
  f.store.setActive(false); f.store.setActive(true); assert.equal(f.store.canEdit(), false); assert.equal(f.applied.length, 1);
});

test('hidden save is invalidated without claiming cancellation; late response cannot notify; reentry queries original ID', async () => {
  const pending = deferred(); const { store, calls, setCurrent, applied } = await loaded({ save: () => pending.promise });
  store.replaceDraft([row('更新')]); const save = store.save(); store.setActive(false); assert.equal(store.snapshot().phase, 'uncertain');
  pending.resolve(receipt()); await save; assert.equal(applied.length, 0);
  store.setActive(true); setCurrent({ revision: b, entries: [row('更新')] }); await store.checkResult();
  assert.equal(applied.length, 1); assert.equal(calls.filter(call => call[0] === 'put').length, 1);
  assert.deepEqual(calls.find(call => call[0] === 'lookup'), ['lookup', id]);
});

test('dispose and hidden initial reads block late account data and notifications', async () => {
  const pending = deferred(); const { store, updates } = fixture({ get: () => pending.promise });
  store.setActive(true); store.dispose(); const count = updates.length; pending.resolve({ revision: a, entries: [row()] }); await tick();
  assert.equal(updates.length, count); assert.deepEqual(store.snapshot().entries, []);
  const late = deferred(); const g = fixture({ get: () => late.promise }); g.store.setActive(true); g.store.setActive(false);
  late.resolve({ revision: a, entries: [row()] }); await tick(); assert.deepEqual(g.store.snapshot().entries, []);
});

test('malformed snapshot and over-limit edits preserve prior verified data', async () => {
  const { store, setCurrent } = await loaded(); const old = store.snapshot();
  assert.equal(store.replaceDraft(Array.from({ length: 501 }, (_, i) => row(`课${i}`))), false);
  assert.deepEqual(store.snapshot().entries, old.entries); setCurrent({ revision: 'bad', entries: [] }); await store.refresh();
  assert.deepEqual(store.snapshot().entries, old.entries); assert.equal(store.snapshot().revision, a);
});
