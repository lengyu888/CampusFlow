import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';
import { reliability } from './helpers/course-review-fixture.mjs';
const read = name => readFileSync(new URL(`../entry/src/main/ets/utils/${name}.ets`, import.meta.url), 'utf8');
const noImports = source => source.replace(/^import \{[\s\S]*?\} from '[^']+';\r?\n/gm, '').replace(/^import [^\n]+;\r?\n/gm, '');
const feedback = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(noImports(read('AgentFeedback')))).toString('base64')}`);
const { CampusFlowRequestError, localRequestFailure } = feedback;
const actual = noImports(read('AgentRun')).replace(/^export /gm, '');
const { AgentRunController, validRunSnapshot, isRunTerminal } = new Function('CampusFlowRequestError', 'localRequestFailure', 'validActionPreview', stripTypeScriptTypes(actual) +
  '\nreturn { AgentRunController, validRunSnapshot, isRunTerminal };')(CampusFlowRequestError, localRequestFailure, reliability.validActionPreview);
const firstId = '11111111-1111-4111-8111-111111111111';
const secondId = '22222222-2222-4222-8222-222222222222';
const when = '2026-10-18T08:00:00+08:00';
const clone = value => JSON.parse(JSON.stringify(value));
const tick = () => new Promise(resolve => setImmediate(resolve));
function deferred() { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; }
function run(extra = {}) {
  return { run_id: firstId, session_id: 'session-a', model: 'deepseek-flash', message: '安排复习', status: 'running',
    created_at: when, updated_at: when, seq: 1, partial_answer: '', tool_progress: [], model_calls: 1, tool_calls: 0,
    result: null, error_code: null, error_message: null, ...extra };
}
function succeeded(extra = {}) {
  return run({ status: 'succeeded', seq: 10, partial_answer: '完整回答',
    result: { session_id: 'session-a', message: '完整回答', pending_actions: [], tool_traces: [] }, ...extra });
}
function event(seq, text = `片段${seq}`) { return { seq, kind: 'answer_delta', at: when, data: { text } }; }
class Clock {
  nextId = 0; jobs = new Map(); delays = [];
  setTimeout(callback, delay) { const id = ++this.nextId; this.jobs.set(id, callback); this.delays.push(delay); return id; }
  clearTimeout(id) { this.jobs.delete(id); }
  async next() { const job = this.jobs.entries().next().value; assert.ok(job, 'a timer should exist'); this.jobs.delete(job[0]); job[1](); await tick(); }
}
function fixture(handlers = {}) {
  const calls = [], states = [], completed = [], busyAtSuccess = []; const clock = new Clock(); let idCalls = 0, controller;
  const api = {
    async startAgentRun(request) { calls.push(['start', clone(request)]); return handlers.start ? handlers.start(request) : run({ run_id: request.run_id, message: request.message, model: request.model, session_id: request.session_id }); },
    async agentRun(id) { calls.push(['status', id]); return handlers.status ? handlers.status(id) : run({ run_id: id }); },
    async agentRunEvents(id, cursor) { calls.push(['events', id, cursor]); return handlers.events ? handlers.events(id, cursor) : { run_id: id, events: [], snapshot: run({ run_id: id }) }; },
    async cancelAgentRun(id) { calls.push(['cancel', id]); return handlers.cancel ? handlers.cancel(id) : run({ run_id: id, status: 'cancelled', seq: 4, partial_answer: '未完成片段' }); },
    async recentAgentRuns(limit) { calls.push(['list', limit]); return handlers.list ? handlers.list() : [run()]; }
  };
  controller = new AgentRunController(api, state => { states.push(state); handlers.changed?.(state, controller); }, snapshot => {
    completed.push(snapshot); busyAtSuccess.push(controller.blocksNewRun()); handlers.completed?.(snapshot, controller);
  }, () => { idCalls++; return handlers.id ? handlers.id() : idCalls === 1 ? firstId : secondId; }, clock);
  controller.configure('server/account-a', api);
  return { controller, api, calls, states, completed, busyAtSuccess, clock, idCalls: () => idCalls };
}

test('publishes immutable UUID request before POST, guards double taps and retains the requested session', async () => {
  const d = deferred(); const f = fixture({ start: request => {
    assert.equal(f.states.at(-1).runId, request.run_id); assert.equal(f.states.at(-1).phase, 'creating'); return d.promise;
  } });
  const start = f.controller.start('session-a', 'deepseek-flash', '安排复习'); await f.controller.start('session-a', 'deepseek-flash', '第二次');
  assert.equal(f.idCalls(), 1); assert.equal(f.calls.length, 1);
  f.states.at(-1).request.message = '外部改动'; d.resolve(run()); await start;
  assert.equal(f.controller.snapshot().request.message, '安排复习'); assert.equal(f.controller.snapshot().snapshot.session_id, 'session-a');
  assert.equal(f.clock.jobs.size, 1);
});

test('authoritative snapshots replace partial answer, including answer_reset, without concatenating event deltas', async () => {
  let step = 0; const f = fixture({ events: () => {
    step++; return { run_id: firstId, events: [event(step + 1, '不得追加')], snapshot: run({ seq: step + 1, partial_answer: step === 1 ? '第一轮片段' : '最终轮重新开始' }) };
  } });
  await f.controller.start('session-a', 'deepseek-flash', '安排复习'); await f.clock.next();
  assert.equal(f.controller.snapshot().snapshot.partial_answer, '第一轮片段'); await f.clock.next();
  assert.equal(f.controller.snapshot().snapshot.partial_answer, '最终轮重新开始');
  assert.deepEqual(f.calls.filter(x => x[0] === 'events').map(x => x[2]), [1, 2]);
});

test('gapped or truncated events advance to the atomically captured full snapshot sequence', async () => {
  const f = fixture({ events: () => ({ run_id: firstId, events: [event(4), event(7)], snapshot: run({ seq: 250, partial_answer: '完整组装文本' }) }) });
  await f.controller.start('session-a', 'deepseek-flash', '安排复习'); await f.clock.next();
  assert.equal(f.controller.snapshot().lastAppliedSeq, 250); assert.equal(f.controller.snapshot().snapshot.partial_answer, '完整组装文本');
  assert.deepEqual(f.controller.snapshot().events.map(x => x.seq), [4, 7]);
});

test('replayed, reverse and malformed event lists cannot corrupt a valid full snapshot', async () => {
  for (const events of [[event(2), event(2)], [event(3), event(2)], [event(1)], [{ ...event(2), data: null }], [event(999)]]) {
    const f = fixture({ events: () => ({ run_id: firstId, events, snapshot: run({ seq: 5, partial_answer: '权威快照' }) }) });
    await f.controller.start('session-a', 'deepseek-flash', '安排复习'); await f.clock.next();
    assert.equal(f.controller.snapshot().snapshot.partial_answer, '权威快照'); assert.equal(f.controller.snapshot().lastAppliedSeq, 5);
    assert.deepEqual(f.controller.snapshot().events, []); assert.match(f.controller.snapshot().message, /部分进度事件/);
  }
});

test('wrong run/session/input or regressing snapshots preserve previous text and cursor', async () => {
  for (const mutate of [s => ({ ...s, run_id: secondId }), s => ({ ...s, session_id: 'other' }),
    s => ({ ...s, message: '别人请求' }), s => ({ ...s, model: 'different' }), s => ({ ...s, seq: 0 })]) {
    const f = fixture({ start: () => run({ partial_answer: '保留原文' }), status: () => mutate(run({ seq: 2, partial_answer: '错内容' })) });
    await f.controller.start('session-a', 'deepseek-flash', '安排复习'); await f.controller.refresh();
    assert.equal(f.controller.snapshot().snapshot.partial_answer, '保留原文'); assert.equal(f.controller.snapshot().lastAppliedSeq, 1);
    assert.equal(f.controller.snapshot().phase, 'unknown'); assert.equal(f.completed.length, 0);
  }
});

test('succeeded result notifies once per run, releases busy before callback, and repeat GET does not duplicate it', async () => {
  const f = fixture({ start: () => succeeded(), status: id => succeeded({ run_id: id }) });
  await f.controller.start('session-a', 'deepseek-flash', '安排复习'); await f.controller.refresh();
  await f.controller.recover(secondId); await f.controller.recover(firstId);
  assert.deepEqual(f.completed.map(x => x.run_id), [firstId, secondId]); assert.deepEqual(f.busyAtSuccess, [false, false]);
  assert.equal(f.clock.jobs.size, 0);
});

test('malformed terminal result cannot announce success or erase the last partial answer', async () => {
  for (const result of [null, { session_id: 'other', message: '错误会话', pending_actions: [] }, { session_id: 'session-a', message: '不完整' }]) {
    const f = fixture({ start: () => run({ partial_answer: '原片段' }), status: () => succeeded({ result }) });
    await f.controller.start('session-a', 'deepseek-flash', '安排复习'); await f.controller.refresh();
    assert.equal(f.completed.length, 0); assert.equal(f.controller.snapshot().snapshot.partial_answer, '原片段');
    assert.equal(f.controller.snapshot().phase, 'unknown');
  }
});

test('failure, timeout, budget stop, cancellation and interruption retain partial text without final-answer callbacks', async () => {
  for (const status of ['failed', 'timed_out', 'budget_exceeded', 'cancelled', 'interrupted']) {
    const f = fixture({ start: () => run({ status, partial_answer: '未完成文字', error_code: 'SAFE_CODE', error_message: '安全错误说明' }) });
    await f.controller.start('session-a', 'deepseek-flash', '安排复习'); assert.equal(f.controller.snapshot().phase, 'terminal');
    assert.equal(f.controller.snapshot().snapshot.partial_answer, '未完成文字'); assert.equal(f.completed.length, 0);
    assert.equal(f.controller.blocksNewRun(), false); assert.equal(f.clock.jobs.size, 0);
  }
});

test('prepared proposal snapshots are optional for old servers but malformed or repeated candidates are rejected', () => {
  const proposal = { proposal_id: 'prepared-a', action: 'create', kind: 'task', title: '复习', start_at: null,
    end_at: null, reminder_minutes: null, reason: null, payload: {}, conflicts: [], status: 'pending' };
  assert.equal(validRunSnapshot(run({ status: 'failed' })), true);
  assert.equal(validRunSnapshot(run({ status: 'failed', prepared_actions: [] })), true);
  assert.equal(validRunSnapshot(run({ status: 'failed', prepared_actions: [proposal] })), true);
  for (const prepared_actions of [null, {}, [null], ['prepared-a'], [proposal, proposal],
    [{ ...proposal, status: 'execute-now' }], Array.from({ length: 51 }, (_, index) => ({ ...proposal, proposal_id: `p-${index}` }))]) {
    assert.equal(validRunSnapshot(run({ status: 'failed', prepared_actions })), false);
  }
});

test('cancel versus completion race reports the actual server terminal state', async () => {
  for (const status of ['cancelled', 'succeeded', 'running']) {
    const f = fixture({ cancel: () => status === 'succeeded' ? succeeded() : run({ status, seq: 5, partial_answer: '保留' }) });
    await f.controller.start('session-a', 'deepseek-flash', '安排复习'); await f.controller.cancel();
    assert.equal(f.controller.snapshot().snapshot.status, status);
    assert.equal(f.completed.length, status === 'succeeded' ? 1 : 0);
    assert.equal(f.controller.snapshot().message.includes('已确认取消'), status === 'cancelled');
    assert.equal(f.clock.jobs.size, status === 'running' ? 1 : 0);
  }
});

test('a slow progress GET does not delay cancel and its late result cannot undo cancellation', async () => {
  const d = deferred(); const f = fixture({ events: () => d.promise });
  await f.controller.start('session-a', 'deepseek-flash', '安排复习'); await f.clock.next(); await f.controller.cancel();
  assert.deepEqual(f.calls.map(x => x[0]), ['start', 'events', 'cancel']);
  d.resolve({ run_id: firstId, events: [event(2)], snapshot: run({ seq: 2, partial_answer: '旧片段' }) }); await tick();
  assert.equal(f.controller.snapshot().snapshot.status, 'cancelled'); assert.equal(f.clock.jobs.size, 0);
});

test('lost cancel response retains the run and polls status without automatically resending cancellation', async () => {
  const f = fixture({ cancel: () => { throw new Error('raw token'); }, status: () => succeeded() });
  await f.controller.start('session-a', 'deepseek-flash', '安排复习'); await f.controller.cancel();
  assert.equal(f.controller.snapshot().phase, 'unknown'); assert.doesNotMatch(f.controller.snapshot().message, /raw token/);
  await f.clock.next(); assert.equal(f.controller.snapshot().snapshot.status, 'succeeded');
  assert.deepEqual(f.calls.map(x => x[0]), ['start', 'cancel', 'status']);
});

test('hidden creation and progress pause polling, ignore late data and restore by GET without cancelling', async () => {
  const d = deferred(); const f = fixture({ start: () => d.promise, status: () => succeeded() });
  const pending = f.controller.start('session-a', 'deepseek-flash', '安排复习'); f.controller.setActive(false);
  assert.equal(f.clock.jobs.size, 0); d.resolve(run({ partial_answer: '迟到' })); await pending;
  assert.equal(f.controller.snapshot().snapshot, null); assert.equal(f.completed.length, 0);
  f.controller.setActive(true); await tick(); assert.equal(f.completed.length, 1);
  assert.deepEqual(f.calls.map(x => x[0]), ['start', 'status']);
});

test('different account and disposal suppress late run/list data and wipe the in-memory request', async () => {
  for (const operation of ['account', 'dispose']) {
    const create = deferred(), list = deferred(); const f = fixture({ start: () => create.promise, list: () => list.promise });
    const p = f.controller.start('session-a', 'deepseek-flash', '安排复习'); const recent = f.controller.loadRecent();
    if (operation === 'account') f.controller.configure('server/account-b', f.api); else f.controller.dispose();
    const length = f.states.length; create.resolve(succeeded()); list.resolve([run()]); await Promise.all([p, recent]);
    assert.equal(f.completed.length, 0); assert.equal(f.states.length, length);
    assert.equal(f.controller.snapshot().request, null); assert.deepEqual(f.controller.snapshot().recent, []);
  }
});

test('unknown create is never automatically posted again; explicit retry reuses identical ID and body', async () => {
  let attempts = 0; const f = fixture({ start: request => { if (++attempts === 1) throw new Error('lost'); return run({ run_id: request.run_id }); },
    status: () => { throw new CampusFlowRequestError(404, 'RUN_NOT_FOUND', 'not found'); } });
  await f.controller.start('session-a', 'deepseek-flash', '安排复习'); await f.clock.next();
  await f.controller.start('session-a', 'deepseek-flash', '新请求不允许'); assert.equal(f.idCalls(), 1);
  assert.equal(f.controller.snapshot().canRetryStart, true); await f.controller.retryStart();
  const posts = f.calls.filter(x => x[0] === 'start'); assert.equal(posts.length, 2); assert.deepEqual(posts[0][1], posts[1][1]);
  assert.equal(f.idCalls(), 1); assert.equal(f.controller.snapshot().phase, 'running');
});

test('retry GET backoff is bounded, preserves partials, and manual recovery works after automatic pause', async () => {
  let online = false; const f = fixture({ start: () => run({ partial_answer: '已看到的部分' }),
    events: () => { throw new Error('offline'); }, status: () => { if (!online) throw new Error('offline'); return succeeded(); } });
  await f.controller.start('session-a', 'deepseek-flash', '安排复习');
  for (let i = 0; i < 4; i++) await f.clock.next();
  assert.equal(f.clock.jobs.size, 0); assert.equal(f.controller.snapshot().snapshot.partial_answer, '已看到的部分');
  assert.deepEqual(f.clock.delays, [1000, 2000, 4000, 8000]); assert.match(f.controller.snapshot().message, /自动查询已暂停/);
  online = true; await f.controller.refresh(); assert.equal(f.completed.length, 1);
});

test('known rejected creation remains an error, cannot be silently retried and keeps its request for review', async () => {
  for (const [status, code] of [[409, 'RUN_SESSION_BUSY'], [409, 'RUN_ID_REUSED'], [422, 'RUN_INVALID'],
    [400, 'MODEL_KEY_REQUIRED'], [400, 'MODEL_NOT_FOUND'], [409, 'MODEL_CAPABILITY_UNSUPPORTED'],
    [503, 'MODEL_PROVIDER_KEY_REQUIRED'], [503, 'MODEL_CONFIG_INVALID'], [401, 'LOGIN_REQUIRED'], [401, 'HTTP_ERROR'], [403, 'HTTP_ERROR'],
    [422, 'HTTP_ERROR'], [429, 'RUN_LIMIT'], [503, 'RUN_WORKER_BUSY']]) {
    const f = fixture({ start: () => { throw new CampusFlowRequestError(status, code, '已映射的安全提示'); } });
    await f.controller.start('session-a', 'deepseek-flash', '安排复习'); await f.controller.retryStart();
    assert.equal(f.controller.snapshot().phase, 'error'); assert.equal(f.controller.snapshot().request.message, '安排复习');
    assert.equal(f.controller.snapshot().message, '已映射的安全提示'); assert.equal(f.controller.snapshot().errorCode, code);
    assert.equal(f.controller.blocksNewRun(), false); f.controller.setActive(false); f.controller.setActive(true); await tick();
    assert.equal(f.controller.snapshot().phase, 'error'); assert.equal(f.calls.length, 1); assert.equal(f.clock.jobs.size, 0);
  }
});

test('network, 500 and malformed-response creation remain unknown and preserve same-ID recovery', async () => {
  for (const error of [new Error('sensitive transport'), localRequestFailure('NETWORK_ERROR'),
    new CampusFlowRequestError(500, 'HTTP_ERROR', '安全服务错误'), new CampusFlowRequestError(503, 'HTTP_ERROR', '安全服务错误'),
    new CampusFlowRequestError(422, 'INVALID_RESPONSE', '无法核验')]) {
    const f = fixture({ start: () => { throw error; } }); await f.controller.start('session-a', 'deepseek-flash', '安排复习');
    assert.equal(f.controller.snapshot().phase, 'unknown'); assert.equal(f.controller.snapshot().canRetryStart, true);
    assert.equal(f.controller.blocksNewRun(), true); assert.equal(f.clock.jobs.size, 1);
    assert.doesNotMatch(f.controller.snapshot().message, /sensitive transport/);
  }
});

test('deleted run stops polling and replay for both unknown create and previously known run', async () => {
  for (const source of ['start', 'status', 'events', 'cancel']) {
    const deleted = () => { throw new CampusFlowRequestError(410, 'RUN_DELETED', 'safe deleted'); };
    const f = fixture({ [source]: deleted }); await f.controller.start('session-a', 'deepseek-flash', '安排复习');
    if (source === 'status') await f.controller.refresh();
    if (source === 'events') await f.clock.next();
    if (source === 'cancel') await f.controller.cancel();
    assert.equal(f.controller.snapshot().phase, 'error'); assert.equal(f.controller.snapshot().errorCode, 'RUN_DELETED');
    assert.equal(f.controller.snapshot().canRetryStart, false); assert.equal(f.controller.blocksNewRun(), false);
    assert.equal(f.clock.jobs.size, 0); const calls = f.calls.length;
    await f.controller.retryStart(); f.controller.setActive(false); f.controller.setActive(true); await tick();
    assert.equal(f.calls.length, calls); assert.match(f.controller.snapshot().message, /已删除/);
  }
});

test('terminal error codes use known safe messages and never render provider error text', async () => {
  for (const code of ['RUN_TIMEOUT', 'RUN_BUDGET_EXCEEDED', 'RUN_INTERRUPTED', 'RUN_CANCELLED', 'RUN_FAILED',
    'RUN_INPUT_LIMIT', 'RUN_CONTEXT_LIMIT', 'RUN_OUTPUT_LIMIT', 'RUN_MODEL_CALL_LIMIT', 'RUN_TOOL_CALL_LIMIT', 'MODEL_OUTPUT_LIMIT', 'MODEL_RESPONSE_LIMIT',
    'MODEL_AUTH_INVALID', 'MODEL_KEY_REQUIRED', 'MODEL_UNAVAILABLE', 'MODEL_RATE_LIMITED', 'MODEL_REQUEST_REJECTED', 'REQUEST_TIMEOUT']) {
    const f = fixture({ start: () => run({ status: 'failed', error_code: code, error_message: 'private-provider-token' }) });
    await f.controller.start('session-a', 'deepseek-flash', '安排复习');
    assert.equal(f.controller.snapshot().message, localRequestFailure(code).message); assert.equal(f.controller.snapshot().errorCode, code);
    assert.doesNotMatch(f.controller.snapshot().message, /private-provider-token/);
  }
  const unknown = fixture({ start: () => run({ status: 'failed', error_code: 'private-code', error_message: 'private-provider-token' }) });
  await unknown.controller.start('session-a', 'deepseek-flash', '安排复习'); assert.equal(unknown.controller.snapshot().errorCode, '');
  assert.match(unknown.controller.snapshot().message, /未完成/); assert.doesNotMatch(unknown.controller.snapshot().message, /private/);
});

test('recent list is server-owned and read-only; malformed refresh preserves the last list', async () => {
  let bad = false; const f = fixture({ list: () => bad ? [run(), run()] : [run(), succeeded({ run_id: secondId })] });
  await f.controller.loadRecent(); assert.equal(f.controller.snapshot().recent.length, 2); assert.equal(f.completed.length, 0);
  bad = true; await f.controller.loadRecent(); assert.equal(f.controller.snapshot().recent.length, 2);
  assert.match(f.controller.snapshot().listMessage, /暂未更新/); assert.equal(f.controller.snapshot().listLoading, false);
});

test('restoring a server record uses snapshots only, with no request replay or new UUID', async () => {
  const f = fixture({ status: id => succeeded({ run_id: id }) }); await f.controller.recover(secondId);
  assert.equal(f.idCalls(), 0); assert.equal(f.controller.snapshot().request, null);
  assert.deepEqual(f.calls, [['status', secondId]]); assert.equal(f.completed[0].run_id, secondId);
});

test('observer cache errors do not change confirmed success, and account changes inside onChange suppress old success callback', async () => {
  const cache = fixture({ start: () => succeeded(), completed: () => { throw new Error('disk failed'); } });
  await cache.controller.start('session-a', 'deepseek-flash', '安排复习'); assert.equal(cache.controller.snapshot().phase, 'terminal');
  let switched = false; const scoped = fixture({ start: () => succeeded(), changed: (state, controller) => {
    if (state.phase === 'terminal' && !switched) { switched = true; controller.configure('new-account', scoped.api); }
  } });
  await scoped.controller.start('session-a', 'deepseek-flash', '安排复习'); assert.equal(scoped.completed.length, 0);
  assert.equal(scoped.controller.snapshot().snapshot, null);
});

test('invalid IDs, inputs and malformed snapshot shapes do not send or promote a result', async () => {
  const f = fixture({ id: () => 'not-a-uuid' }); await f.controller.start('session-a', 'deepseek-flash', '安排复习'); assert.deepEqual(f.calls, []);
  const g = fixture(); await g.controller.start('session-a', '', '安排复习'); await g.controller.start('session-a', 'deepseek-flash', '字'.repeat(8001));
  for (const session of ['', '  ', 's'.repeat(129), null]) { await g.controller.start(session, 'deepseek-flash', '安排复习'); }
  await g.controller.recover('not-a-uuid'); assert.deepEqual(g.calls, []);
  const max = fixture(); await max.controller.start('s'.repeat(128), 'deepseek-flash', '安排复习'); assert.equal(max.calls.length, 1);
  for (const bad of [null, {}, run({ seq: -1 }), run({ tool_progress: [null] }), run({ status: 'finished' }), run({ result: succeeded().result }), succeeded({ result: null })]) {
    assert.equal(validRunSnapshot(bad), false);
  }
  assert.equal(isRunTerminal('queued'), false); assert.equal(isRunTerminal('interrupted'), true);
});

test('new and continued runs freeze explicit context conditions while omitted legacy conditions remain absent', async () => {
  for (const conditions of [[], [null], [null, null], ['new'], ['new', null], ['continue', 'a'.repeat(64)]]) {
    const f = fixture({ start: request => run({ session_mode: request.session_mode ?? null,
      input_context_revision: request.session_mode ? 'a'.repeat(64) : null }) });
    let saved;
    f.controller.setBeforeSubmit(async request => { saved = clone(request); });
    await f.controller.start('session-a', 'deepseek-flash', '安排复习', ...conditions);
    assert.equal(f.controller.snapshot().phase, 'running');
    const expected = { run_id: firstId, session_id: 'session-a', model: 'deepseek-flash', message: '安排复习' };
    if (conditions.length > 0) expected.session_mode = conditions[0];
    if (conditions.length > 1) expected.expected_context_revision = conditions[1];
    assert.deepEqual(f.calls[0][1], expected);
    assert.deepEqual(saved, expected);
    if (conditions.length === 0) assert.deepEqual(Object.keys(saved), ['run_id', 'session_id', 'model', 'message']);
  }
});

test('invalid continuation conditions never allocate an ID, save a pointer or contact the API', async () => {
  for (const conditions of [['continue'], ['continue', null], ['continue', 'bad'], ['continue', 'A'.repeat(64)],
    ['new', 'a'.repeat(64)], [undefined, 'a'.repeat(64)], [null, 'a'.repeat(64)], ['resume'], [3]]) {
    const f = fixture(); let saved = 0;
    f.controller.setBeforeSubmit(async () => { saved++; });
    await f.controller.start('session-a', 'deepseek-flash', '安排复习', ...conditions);
    assert.equal(f.idCalls(), 0); assert.equal(saved, 0); assert.deepEqual(f.calls, []);
    assert.equal(f.controller.snapshot().errorCode, 'SESSION_MODE_INVALID');
  }
});

test('unknown continuation and cold recovery retain the identical original UUID and context revision on explicit retry only', async () => {
  const revision = 'a'.repeat(64); let attempts = 0;
  const f = fixture({ start: request => {
    if (++attempts === 1) throw new CampusFlowRequestError(500, 'RUN_FAILED', 'safe');
    return run({ session_mode: request.session_mode, input_context_revision: request.expected_context_revision });
  } });
  await f.controller.start('session-a', 'deepseek-flash', '安排复习', 'continue', revision);
  assert.equal(f.controller.snapshot().phase, 'unknown');
  await f.controller.retryStart();
  assert.deepEqual(f.calls[0][1], f.calls[1][1]); assert.equal(f.idCalls(), 1);
  const request = clone(f.calls[0][1]);
  const cold = fixture({ status: () => { throw new CampusFlowRequestError(404, 'RUN_NOT_FOUND', 'missing'); },
    start: value => run({ session_mode: value.session_mode, input_context_revision: value.expected_context_revision }) });
  await cold.controller.recoverRequest({ ...request, token: 'must-not-post', arbitrary: { payload: 'not-allowed' } });
  assert.deepEqual(cold.calls, [['status', firstId]]); assert.equal(cold.idCalls(), 0);
  request.expected_context_revision = 'b'.repeat(64);
  await cold.controller.retryStart();
  assert.deepEqual(cold.calls[1][1], f.calls[0][1]);
  assert.equal(cold.controller.snapshot().phase, 'running');
});

test('malformed durable continuation cannot be turned into an unguarded legacy replay', async () => {
  for (const request of [null, [], { run_id: firstId, session_id: 'session-a', model: 'deepseek-flash', message: '安排复习', session_mode: 'continue' },
    { run_id: firstId, session_id: 'session-a', model: 'deepseek-flash', message: '安排复习', session_mode: 'new', expected_context_revision: 'a'.repeat(64) }]) {
    const f = fixture(); await f.controller.recoverRequest(request); await f.controller.retryStart();
    assert.deepEqual(f.calls, []); assert.equal(f.controller.snapshot().runId, '');
  }
});

test('run snapshots must preserve accepted session mode and exact input context through polling', async () => {
  for (const values of [
    { session_mode: null, input_context_revision: null },
    { session_mode: 'new', input_context_revision: 'a'.repeat(64) },
    { session_mode: 'continue', input_context_revision: 'b'.repeat(64) },
    { session_mode: 'continue', input_context_revision: 'bad' },
  ]) {
    const f = fixture({ start: () => run({ session_mode: 'continue', input_context_revision: 'a'.repeat(64), partial_answer: '保留片段' }),
      status: () => run({ ...values, seq: 2, partial_answer: '不该接受' }) });
    await f.controller.start('session-a', 'deepseek-flash', '安排复习', 'continue', 'a'.repeat(64));
    await f.controller.refresh();
    assert.equal(f.controller.snapshot().phase, 'unknown');
    assert.equal(f.controller.snapshot().snapshot.partial_answer, '保留片段');
    assert.equal(f.completed.length, 0);
  }
  for (const bad of [run({ session_mode: 'continue' }), run({ session_mode: 'new', input_context_revision: null }),
    run({ session_mode: 'resume', input_context_revision: 'a'.repeat(64) }), run({ input_context_revision: 'bad' })]) {
    assert.equal(validRunSnapshot(bad), false);
  }
  assert.equal(validRunSnapshot(run()), true);
  assert.equal(validRunSnapshot(run({ session_mode: null, input_context_revision: null })), true);
});

test('authoritative session rejection stops retries and keeps the request for explicit user handling', async () => {
  for (const code of ['SESSION_NOT_FOUND', 'SESSION_DELETED', 'SESSION_CONTEXT_CHANGED', 'SESSION_EXISTS', 'SESSION_MODE_INVALID']) {
    const f = fixture({ start: () => { throw new CampusFlowRequestError(code === 'SESSION_DELETED' ? 410 : 409, code, localRequestFailure(code).message); } });
    await f.controller.start('session-a', 'deepseek-flash', '安排复习', 'continue', 'a'.repeat(64));
    assert.equal(f.controller.snapshot().phase, 'error'); assert.equal(f.controller.snapshot().errorCode, code);
    assert.equal(f.controller.snapshot().request.expected_context_revision, 'a'.repeat(64));
    assert.equal(f.controller.snapshot().canRetryStart, false); assert.equal(f.controller.blocksNewRun(), false);
    assert.equal(f.clock.jobs.size, 0); await f.controller.retryStart(); assert.equal(f.calls.length, 1);
  }
});

test('a deleted session during status recovery cannot schedule or retry and contextual terminal errors use safe messages', async () => {
  const f = fixture({ status: () => { throw new CampusFlowRequestError(410, 'SESSION_DELETED', 'private data'); } });
  await f.controller.start('session-a', 'deepseek-flash', '安排复习'); await f.controller.refresh();
  assert.equal(f.controller.snapshot().phase, 'error'); assert.equal(f.clock.jobs.size, 0);
  assert.equal(f.controller.snapshot().canRetryStart, false); assert.doesNotMatch(f.controller.snapshot().message, /private/);
  const failed = fixture({ start: () => run({ status: 'failed', session_mode: 'continue', input_context_revision: 'a'.repeat(64),
    error_code: 'SESSION_CONTEXT_CHANGED', error_message: 'private raw exception' }) });
  await failed.controller.start('session-a', 'deepseek-flash', '安排复习', 'continue', 'a'.repeat(64));
  assert.equal(failed.controller.snapshot().message, localRequestFailure('SESSION_CONTEXT_CHANGED').message);
  assert.equal(failed.completed.length, 0);
});
