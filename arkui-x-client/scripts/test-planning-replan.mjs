import './helpers/theme-fixture.mjs';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripThemeTypeScriptTypes as stripTypeScriptTypes } from './helpers/theme-fixture.mjs';
import { test } from 'node:test';

async function loadUtility(name) {
  const source = readFileSync(new URL(`../entry/src/main/ets/utils/${name}.ets`, import.meta.url), 'utf8')
    .replace(/^import \{[^\n]+\} from '\.\.\/model\/ApiModels';\r?\n/gm, '');
  return import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source)).toString('base64')}`);
}
const feedback = await loadUtility('AgentFeedback');
const timetable = await loadUtility('OnboardingTimetable');
const agenda = await loadUtility('DailyAgenda');
const source = readFileSync(new URL('../entry/src/main/ets/utils/PlanningReplan.ets', import.meta.url), 'utf8')
  .replace(/^import [^\n]+;\r?\n/gm, '').replace(/^export /gm, '');
const { PlanningReplanController, validConflictReport, validReplanPreview, hasCourseClassification, conflictCourseOverlap } = new Function(
  'CampusFlowRequestError', 'validateTimetableEntry', 'timestamp', 'courseTimestamp', stripTypeScriptTypes(source) +
  '\nreturn {PlanningReplanController,validConflictReport,validReplanPreview,hasCourseClassification,conflictCourseOverlap};'
)(feedback.CampusFlowRequestError, timetable.validateTimetableEntry, agenda.timestamp, agenda.courseTimestamp);

const now = Date.parse('2026-10-20T08:00:00+08:00');
function candidate() {
  return { replan_id: 'fixture-replan', status: 'pending', created_at: '2026-10-20T08:00:00+08:00',
    expires_at: '2026-10-20T08:15:00+08:00', policy: '合成规则说明，仅核对明确时段',
    changes: [{ task_id: 'task-1', title: '复习操作系统', old_start_at: '2026-10-20T10:00:00+08:00',
      old_end_at: '2026-10-20T11:00:00+08:00', new_start_at: '2026-10-20T12:00:00+08:00',
      new_end_at: '2026-10-20T13:00:00+08:00' }], unresolved: [] };
}
function report() {
  return { checked_at: '2026-10-20T08:00:00+08:00', policy: '合成规则说明，仅核对明确时段',
    conflicts: [{ task_id: 'task-1', title: '复习操作系统', start_at: '2026-10-20T10:00:00+08:00',
      end_at: '2026-10-20T11:00:00+08:00', courses: [{ date: '2026-10-20', title: '软件工程',
        start_time: '10:00', end_time: '11:30', location: '', teacher: '' }] }], unchecked: [] };
}
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
const tick = () => new Promise(resolve => setImmediate(resolve));
function fixture(handlers = {}) {
  const calls = [], states = [], applied = [];
  let time = now;
  const gateway = {};
  for (const name of ['planningConflicts', 'previewReplan', 'confirmReplan', 'replanStatus']) {
    gateway[name] = async (...args) => {
      calls.push({ name, args });
      if (handlers[name]) return handlers[name](...args);
      if (name === 'planningConflicts') return report();
      const value = candidate();
      if (name === 'confirmReplan') value.status = 'confirmed';
      return value;
    };
  }
  const controller = new PlanningReplanController(gateway, value => states.push(value), () => applied.push(true), () => time);
  return { controller, calls, states, applied, state: () => controller.snapshot(), setTime: value => time = value };
}
async function ready(f) { f.controller.setActive(true); await tick(); await f.controller.preview(); }

test('report and preview are reads; only explicit confirmation updates existing task IDs', async () => {
  const f = fixture();
  await ready(f);
  assert.equal(f.state().phase, 'review');
  assert.deepEqual(f.calls.map(x => x.name), ['planningConflicts', 'previewReplan']);
  assert.equal(f.applied.length, 0);
  await f.controller.confirm();
  assert.equal(f.state().phase, 'applied');
  assert.deepEqual(f.calls.at(-1), { name: 'confirmReplan', args: ['fixture-replan'] });
  assert.equal(f.applied.length, 1);
  await f.controller.confirm();
  assert.equal(f.calls.filter(x => x.name === 'confirmReplan').length, 1);
});

test('double preview and double confirm clicks are guarded while pending', async () => {
  const pending = deferred(), confirmation = deferred();
  const f = fixture({ previewReplan: () => pending.promise, confirmReplan: () => confirmation.promise });
  f.controller.setActive(true); await tick();
  const reading = f.controller.preview();
  await f.controller.preview();
  assert.equal(f.calls.filter(x => x.name === 'previewReplan').length, 1);
  pending.resolve(candidate()); await reading;
  const saving = f.controller.confirm();
  await f.controller.confirm(); await f.controller.refresh(); await f.controller.preview(); f.controller.dismiss();
  assert.equal(f.state().phase, 'confirming');
  assert.equal(f.calls.filter(x => x.name === 'confirmReplan').length, 1);
  confirmation.resolve({ ...candidate(), status: 'confirmed' }); await saving;
  assert.equal(f.applied.length, 1);
});

test('discarding a preview and hiding during a read never writes or accepts a late preview', async () => {
  const pending = deferred();
  const f = fixture({ previewReplan: () => pending.promise });
  f.controller.setActive(true); await tick();
  const reading = f.controller.preview();
  f.controller.dismiss();
  pending.resolve(candidate()); await reading;
  assert.equal(f.state().preview, null);
  assert.equal(f.state().phase, 'idle');
  assert.equal(f.applied.length, 0);
  const late = deferred();
  const hidden = fixture({ previewReplan: () => late.promise });
  hidden.controller.setActive(true); await tick();
  const next = hidden.controller.preview();
  hidden.controller.setActive(false);
  late.resolve(candidate()); await next;
  assert.equal(hidden.state().preview, null);
  assert.equal(hidden.calls.some(x => x.name === 'confirmReplan'), false);
});

test('newest conflict read wins and failed refresh clears old no-conflict evidence', async () => {
  const old = deferred(), fresh = deferred();
  let reads = 0;
  const f = fixture({ planningConflicts: () => ++reads === 1 ? old.promise : fresh.promise });
  f.controller.setActive(true);
  const newer = f.controller.refresh();
  const empty = report(); empty.conflicts = [];
  fresh.resolve(empty); await newer;
  old.resolve(report()); await tick();
  assert.equal(f.state().report.conflicts.length, 0);
  const failing = fixture({ planningConflicts: async () => { throw new Error('private token=secret'); } });
  failing.controller.setActive(true); await tick();
  assert.equal(failing.state().report, null);
  assert.equal(failing.state().phase, 'error');
  assert.doesNotMatch(failing.state().message, /private|secret/);
});

test('expired preview and a newly started suggested slot cannot be confirmed', async () => {
  for (const current of ['2026-10-20T08:16:00+08:00', '2026-10-20T12:01:00+08:00']) {
    const f = fixture(); await ready(f); f.setTime(Date.parse(current));
    await f.controller.confirm();
    assert.equal(f.state().phase, 'stale');
    assert.equal(f.calls.some(x => x.name === 'confirmReplan'), false);
  }
});

test('an original task that has started is not moved even when the preview and suggested slot are still future', async () => {
  const result = candidate();
  result.changes[0].old_start_at = '2026-10-20T08:05:00+08:00';
  result.changes[0].old_end_at = '2026-10-20T09:05:00+08:00';
  const f = fixture({ previewReplan: async () => result }); await ready(f);
  f.setTime(Date.parse('2026-10-20T08:06:00+08:00'));
  await f.controller.confirm();
  assert.equal(f.state().phase, 'stale');
  assert.match(f.state().message, /原任务/);
  assert.equal(f.calls.some(x => x.name === 'confirmReplan'), false);
});

test('known stale or expired server rejection retains the preview but prevents repeated confirmation', async () => {
  for (const status of [409, 410, 401, 403, 404, 422]) {
    const f = fixture({ confirmReplan: async () => { throw new feedback.CampusFlowRequestError(status, 'HTTP_ERROR', 'private-diagnostic'); } });
    await ready(f); await f.controller.confirm(); await f.controller.confirm();
    assert.equal(f.state().phase, 'stale');
    assert.equal(f.state().preview.replan_id, 'fixture-replan');
    assert.doesNotMatch(f.state().message, /private/);
    assert.equal(f.calls.filter(x => x.name === 'confirmReplan').length, 1);
  }
});

test('ambiguous write failures require a status read; there is no implicit retry, regeneration or discard', async () => {
  for (const error of [new Error('socket reset secret'), new feedback.CampusFlowRequestError(500, 'HTTP_ERROR', 'secret')]) {
    const f = fixture({ confirmReplan: async () => { throw error; },
      replanStatus: async () => ({ ...candidate(), status: 'confirmed' }) });
    await ready(f); await f.controller.confirm();
    assert.equal(f.state().phase, 'uncertain');
    const before = f.calls.length;
    await f.controller.confirm(); await f.controller.preview(); await f.controller.refresh(); f.controller.dismiss();
    assert.equal(f.calls.length, before);
    assert.equal(f.state().phase, 'uncertain');
    await f.controller.checkResult();
    assert.equal(f.state().phase, 'applied');
    assert.equal(f.calls.filter(x => x.name === 'confirmReplan').length, 1);
    assert.equal(f.applied.length, 1);
  }
});

test('status pending requires another explicit confirmation; failed status reads remain uncertain', async () => {
  let confirmed = 0, checked = 0;
  const f = fixture({ confirmReplan: async () => { if (++confirmed === 1) throw new Error('lost'); return { ...candidate(), status: 'confirmed' }; },
    replanStatus: async () => { if (++checked === 1) throw new Error('offline'); return candidate(); } });
  await ready(f); await f.controller.confirm(); await f.controller.checkResult();
  assert.equal(f.state().phase, 'uncertain');
  await f.controller.checkResult();
  assert.equal(f.state().phase, 'review');
  assert.equal(confirmed, 1);
  await f.controller.confirm();
  assert.equal(confirmed, 2);
  assert.equal(f.applied.length, 1);
});

test('hiding during confirmation retains only the pending receipt identity for later read recovery', async () => {
  const saving = deferred();
  const f = fixture({ confirmReplan: () => saving.promise, replanStatus: async () => ({ ...candidate(), status: 'confirmed' }) });
  await ready(f); const request = f.controller.confirm(); f.controller.setActive(false);
  saving.resolve({ ...candidate(), status: 'confirmed' }); await request;
  assert.equal(f.state().phase, 'uncertain');
  assert.equal(f.applied.length, 0);
  f.controller.setActive(true); await tick();
  assert.equal(f.state().phase, 'uncertain');
  await f.controller.checkResult();
  assert.equal(f.applied.length, 1);
});

test('disposing an account scope prevents late confirmation callbacks and clears private contents', async () => {
  const pending = deferred();
  const f = fixture({ confirmReplan: () => pending.promise });
  await ready(f); const request = f.controller.confirm(); f.controller.dispose();
  const count = f.states.length;
  pending.resolve({ ...candidate(), status: 'confirmed' }); await request;
  assert.equal(f.applied.length, 0);
  assert.equal(f.state().preview, null);
  assert.equal(f.state().report, null);
  assert.equal(f.states.length, count);
});

test('UI snapshots cannot mutate the reviewed proposal or task identity used for confirmation', async () => {
  const f = fixture(); await ready(f);
  const snapshot = f.controller.snapshot(); snapshot.preview.replan_id = 'another-user';
  f.states.at(-1).preview.changes[0].new_start_at = 'broken';
  await f.controller.confirm();
  assert.deepEqual(f.calls.at(-1).args, ['fixture-replan']);
  assert.equal(f.state().phase, 'applied');
});

test('malformed reports and proposals cannot display success or enable writes', async () => {
  assert.equal(validConflictReport(report()), true);
  assert.equal(validReplanPreview(candidate()), true);
  const missingLocation = report(); delete missingLocation.conflicts[0].courses[0].location;
  for (const bad of [null, {}, missingLocation, { ...report(), conflicts: null }, { ...report(), checked_at: '2026-10-20' }]) {
    assert.equal(validConflictReport(bad), false);
  }
  const duplicate = candidate(); duplicate.changes.push({ ...duplicate.changes[0] });
  const shortened = candidate(); shortened.changes[0].new_end_at = '2026-10-20T12:30:00+08:00';
  const earlier = candidate(); earlier.changes[0].new_start_at = '2026-10-20T09:00:00+08:00'; earlier.changes[0].new_end_at = '2026-10-20T10:00:00+08:00';
  for (const bad of [null, {}, duplicate, shortened, earlier, { ...candidate(), status: 'confirmed' }]) {
    const f = fixture({ previewReplan: async () => bad }); await ready(f);
    assert.equal(f.state().phase, 'error');
    await f.controller.confirm();
    assert.equal(f.calls.some(x => x.name === 'confirmReplan'), false);
  }
});

test('a mismatched or incomplete success receipt remains uncertain until verified', async () => {
  const altered = candidate(); altered.changes[0].title = 'unreviewed';
  for (const value of [null, candidate(), { ...candidate(), status: 'confirmed', replan_id: 'another' }, { ...altered, status: 'confirmed' }]) {
    const f = fixture({ confirmReplan: async () => value }); await ready(f); await f.controller.confirm();
    assert.equal(f.state().phase, 'uncertain'); assert.equal(f.applied.length, 0);
  }
});

test('no available slots remains a useful preview with reasons and no confirmation request', async () => {
  const empty = candidate(); empty.changes = [];
  empty.unresolved = [{ task_id: 'task-1', title: '复习', reason: '截止时间前无完整空档' }];
  const f = fixture({ previewReplan: async () => empty }); await ready(f);
  assert.equal(f.state().phase, 'review');
  assert.equal(f.state().preview.unresolved.length, 1);
  await f.controller.confirm(); assert.equal(f.calls.some(x => x.name === 'confirmReplan'), false);
});

const apiSource = readFileSync(new URL('../entry/src/main/ets/services/CampusFlowApi.ets', import.meta.url), 'utf8')
  .replace(/^import http from '@ohos.net.http';\r?\n/m, '')
  .replace(/^import \{[\s\S]*?\} from '\.\.\/model\/ApiModels';\r?\n/m, '')
  .replace(/^import \{[^\n]+\} from '\.\.\/utils\/AgentFeedback';\r?\n/m, '')
  .replace('export class CampusFlowApi', 'class CampusFlowApi');
const createApi = new Function('http', 'CampusFlowRequestError', 'localRequestFailure', 'requestFailure',
  stripTypeScriptTypes(apiSource) + '\nreturn CampusFlowApi;');

test('actual API uses dedicated endpoints, escapes proposal IDs and preserves read versus confirm methods', async () => {
  const calls = []; let destroyed = 0;
  const http = { RequestMethod: { GET: 'GET', POST: 'POST' }, HttpDataType: { STRING: 'STRING' },
    createHttp: () => ({ request: async (url, options) => { calls.push({ url, options }); return { responseCode: 200, result: '{}' }; },
      destroy: () => destroyed++ }) };
  const Api = createApi(http, feedback.CampusFlowRequestError, feedback.localRequestFailure, feedback.requestFailure);
  const client = new Api('http://fixture.invalid/', 'test-token');
  await client.planningConflicts(); await client.previewReplan(); await client.replanStatus('a/b'); await client.confirmReplan('a/b');
  assert.deepEqual(calls.map(x => [x.url.replace('http://fixture.invalid', ''), x.options.method]), [
    ['/api/v1/planning/conflicts', 'GET'], ['/api/v1/planning/replans', 'POST'],
    ['/api/v1/planning/replans/a%2Fb', 'GET'], ['/api/v1/planning/replans/a%2Fb/confirm', 'POST']]);
  assert.equal(calls[1].options.extraData, '{}'); assert.equal(calls[3].options.extraData, '{}');
  assert.ok(calls.every(x => x.options.header.Authorization === 'Bearer test-token'));
  assert.equal(destroyed, 4);
});

test('course classification distinguishes legacy omission, accepted, changed and ordinary overlaps', () => {
  const legacy=report();assert.equal(validConflictReport(legacy),true);assert.equal(hasCourseClassification(legacy),false);
  const complete={...report(),accepted_course_overlaps:[{...report().conflicts[0],task_id:'accepted-id'}],
    course_overlap_reviews:[{...report().conflicts[0],task_id:'changed-id'}],unchecked:[{task_id:'untimed-id',title:'同名安排',reason:'没有结束时间'}]};
  assert.equal(validConflictReport(complete),true);assert.equal(hasCourseClassification(complete),true);
  const copy=structuredClone(complete);copy.course_overlap_reviews[0].task_id='accepted-id';assert.equal(validConflictReport(copy),false,'one task cannot be in contradictory groups');
  for(const value of [null,{},'none'])assert.equal(validConflictReport({...complete,accepted_course_overlaps:value}),false);
  const partial={...legacy,accepted_course_overlaps:[]};assert.equal(validConflictReport(partial),false);
  const duplicate=report();duplicate.unchecked=[{task_id:'task-1',title:'复习',reason:'另一个分类'}];assert.equal(validConflictReport(duplicate),false);
});

test('overlap uses the report own dated intervals, handles offsets and rejects touching or invalid courses', () => {
  const item={...report().conflicts[0],start_at:'2026-10-20T01:45:00Z',end_at:'2026-10-20T02:15:00Z'};
  const course={date:'2026-10-20',title:'同名课',start_time:'10:00',end_time:'11:30',location:'不同教室',teacher:'教师'};
  assert.deepEqual(conflictCourseOverlap(item,course),{start_at:'2026-10-20T02:00:00.000Z',end_at:'2026-10-20T02:15:00.000Z'});
  assert.equal(conflictCourseOverlap({...item,end_at:'2026-10-20T02:00:00Z'},course),null);
  assert.equal(conflictCourseOverlap({...item,start_at:'2026-02-30T10:00:00+08:00'},course),null);
  assert.equal(conflictCourseOverlap(item,{...course,date:'2026-02-30'}),null);
  const wrong=report();wrong.conflicts[0].courses[0]={...course,start_time:'15:00',end_time:'16:00'};
  assert.equal(validConflictReport(wrong),false,'unrelated same-title course is not a verified overlap');
});

test('invalid calendar dates in server reports never become successful scan evidence', async () => {
  const wrong=report();wrong.checked_at='2026-02-30T10:00:00+08:00';
  const f=fixture({planningConflicts:async()=>wrong});f.controller.setActive(true);await tick();
  assert.equal(f.state().phase,'error');assert.equal(f.state().report,null);
});
