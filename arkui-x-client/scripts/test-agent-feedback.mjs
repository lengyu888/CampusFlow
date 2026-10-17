import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';

// Run the production pure helper; its model import is used only for type annotations.
const source = readFileSync(new URL('../entry/src/main/ets/utils/AgentFeedback.ets', import.meta.url), 'utf8')
  .replace(/^import \{[^\n]+\} from '\.\.\/model\/ApiModels';\r?\n/, '');
const helper = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source)).toString('base64')}`);
const { CampusFlowRequestError, requestFailure, localRequestFailure,
  displayToolTraces, mergeActions, restoreDraft } = helper;

const apiSource = readFileSync(new URL('../entry/src/main/ets/services/CampusFlowApi.ets', import.meta.url), 'utf8')
  .replace(/^import http from '@ohos.net.http';\r?\n/m, '')
  .replace(/^import \{[\s\S]*?\} from '\.\.\/model\/ApiModels';\r?\n/m, '')
  .replace(/^import \{[^\n]+\} from '\.\.\/utils\/AgentFeedback';\r?\n/m, '')
  .replace('export class CampusFlowApi', 'class CampusFlowApi');
const createApiClass = new Function('http', 'CampusFlowRequestError', 'localRequestFailure', 'requestFailure',
  stripTypeScriptTypes(apiSource) + '\nreturn CampusFlowApi;');

function mockApi(respond) {
  const calls = [];
  let destroyCount = 0;
  const http = {
    RequestMethod: { GET: 'GET', POST: 'POST', PUT: 'PUT', DELETE: 'DELETE' },
    HttpDataType: { STRING: 'STRING' },
    createHttp: () => ({
      request: async (url, options) => {
        calls.push({ url, options });
        return respond(url, options);
      },
      destroy: () => { destroyCount++; }
    })
  };
  const Api = createApiClass(http, CampusFlowRequestError, localRequestFailure, requestFailure);
  return { api: new Api('http://fixture.invalid', 'test-only'), calls, destroyed: () => destroyCount };
}

function action(id, status = 'pending', title = '复习操作系统') {
  return { proposal_id: id, action: 'create', kind: 'task', title, start_at: null,
    end_at: null, reminder_minutes: null, reason: null, payload: {}, conflicts: [], status };
}

test('server error codes give actionable safe messages and retain typed identity', () => {
  const codes = ['LOGIN_REQUIRED', 'MODEL_AUTH_INVALID', 'MODEL_KEY_REQUIRED', 'MODEL_UNAVAILABLE',
    'MODEL_RATE_LIMITED', 'MODEL_REQUEST_REJECTED',
    'ACTION_EXPIRED', 'ACTION_LEGACY_UNVERIFIED', 'ACTION_STALE', 'ACTION_CONFLICT', 'ACTION_INVALID',
    'REQUEST_TIMEOUT', 'ACTION_NOT_FOUND', 'ACTION_RESOLVED', 'ACTION_FAILED', 'ACTION_UNSUPPORTED'];
  for (const code of codes) {
    const error = requestFailure(503, JSON.stringify({ code, detail: 'private-provider-diagnostics' }));
    assert.ok(error instanceof CampusFlowRequestError);
    assert.ok(error instanceof Error);
    assert.equal(error.statusCode, 503);
    assert.equal(error.code, code);
    assert.ok(error.message.length > 0);
    assert.doesNotMatch(error.message, /private-provider|diagnostics/);
  }
  assert.match(requestFailure(401, '{"code":"LOGIN_REQUIRED"}').message, /重新登录行简/);
  assert.match(requestFailure(503, '{"code":"MODEL_KEY_REQUIRED"}').message, /API Key/);
  assert.match(requestFailure(504, '{"code":"REQUEST_TIMEOUT"}').message, /先核对/);
});

test('a model authentication failure or an old unclassified 401 never implies app login expiry', () => {
  const model = requestFailure(401, '{"code":"MODEL_AUTH_INVALID","detail":"wrong upstream key"}');
  assert.equal(model.code, 'MODEL_AUTH_INVALID');
  assert.doesNotMatch(model.message, /重新登录/);
  for (const body of ['', '{"detail":"Unauthorized"}', '{"detail":{"code":"LOGIN_REQUIRED"}}',
    '{"code":"NEW_PROVIDER_FAILURE"}', 'not-json']) {
    const oldServer = requestFailure(401, body);
    assert.equal(oldServer.code, 'HTTP_ERROR');
    assert.doesNotMatch(oldServer.message, /登录|过期/);
  }
});

test('raw HTML, sensitive fields, unknown codes and non-object JSON cannot leak through errors', () => {
  const marker = 'sensitive-token-123456';
  const bodies = [`<html>${marker}</html>`, JSON.stringify({ detail: marker, message: marker }),
    JSON.stringify({ code: marker, detail: { authorization: marker } }), 'null', '42', '[]',
    JSON.stringify(marker), '{"code":{}}'];
  for (const status of [400, 401, 403, 404, 409, 422, 429, 500, 503, 504]) {
    for (const body of bodies) {
      const error = requestFailure(status, body);
      assert.equal(error.code, 'HTTP_ERROR');
      assert.equal(error.statusCode, status);
      assert.ok(error.message.length > 0);
      assert.equal(`${error.code} ${error.message}`.includes(marker), false);
    }
  }
  assert.match(requestFailure(409, '').message, /状态已变化/);
  assert.match(requestFailure(429, '').message, /过于频繁/);
});

test('transport and invalid JSON failures have safe distinct local codes', () => {
  assert.equal(localRequestFailure('NETWORK_ERROR').code, 'NETWORK_ERROR');
  assert.match(localRequestFailure('NETWORK_ERROR').message, /网络和服务地址/);
  assert.equal(localRequestFailure('INVALID_RESPONSE').code, 'INVALID_RESPONSE');
  assert.match(localRequestFailure('INVALID_RESPONSE').message, /无法识别/);
  assert.equal(localRequestFailure('raw secret from transport').code, 'NETWORK_ERROR');
  assert.doesNotMatch(localRequestFailure('raw secret from transport').message, /secret/);
});

test('tool display uses only the explicit display projection and supports all server states', () => {
  for (const state of ['success', 'empty', 'error', 'unavailable', 'pending', 'unverified', 'demo']) {
    const display = { label: '课表查询', state, summary: '本次找到 2 节课程。' };
    const result = displayToolTraces([{ tool_call_id: 'call-1', tool_name: 'private-function',
      arguments: { token: 'secret-argument' }, result: { token: 'secret-result' }, display }]);
    assert.deepEqual(result, [display]);
    assert.deepEqual(Object.keys(result[0]).sort(), ['label', 'state', 'summary']);
    assert.equal(JSON.stringify(result).includes('secret'), false);
    assert.equal(JSON.stringify(result).includes('private-function'), false);
  }
});

test('missing, malformed or legacy tool traces do not invent success or expose raw diagnostics', () => {
  assert.deepEqual(displayToolTraces(), []);
  assert.deepEqual(displayToolTraces([]), []);
  assert.deepEqual(displayToolTraces(null), []);
  const traces = [
    { tool_call_id: 'legacy', tool_name: 'SECRET_TOOL', status: 'success', result: 'SECRET_RESULT' },
    { tool_call_id: 'null', tool_name: 'SECRET_TOOL', display: null },
    { tool_call_id: 'bad-state', tool_name: 'SECRET_TOOL', display: { label: '查询', state: 'future', summary: 'ok' } },
    { tool_call_id: 'blank', tool_name: 'SECRET_TOOL', display: { label: ' ', state: 'success', summary: 'ok' } },
    null
  ];
  const result = displayToolTraces(traces);
  assert.equal(result.length, traces.length);
  assert.ok(result.every((item) => item.state === 'unverified'));
  assert.ok(result.every((item) => item.label === '工具调用'));
  assert.doesNotMatch(JSON.stringify(result), /SECRET|future/);
});

test('new turns keep earlier unresolved proposals and merge by ID instead of title', () => {
  const earlier = action('old');
  const next = action('new');
  assert.deepEqual(mergeActions([earlier], []), [earlier]);
  assert.deepEqual(mergeActions([earlier], [next]), [earlier, next]);
  const updated = action('old', 'pending', '补充时间后的提案');
  assert.deepEqual(mergeActions([earlier], [updated, next]), [updated, next]);
});

test('confirmed and cancelled local states survive delayed pending responses and duplicate IDs', () => {
  const confirmed = action('done', 'confirmed');
  const cancelled = action('cancelled', 'cancelled');
  const current = [confirmed, cancelled, action('waiting')];
  const incoming = [action('done'), action('cancelled'), action('waiting', 'confirmed'),
    action('new'), action('new')];
  const before = JSON.stringify([current, incoming]);
  const merged = mergeActions(current, incoming);
  assert.deepEqual(merged.map((item) => [item.proposal_id, item.status]),
    [['done', 'confirmed'], ['cancelled', 'cancelled'], ['waiting', 'confirmed'], ['new', 'pending']]);
  assert.equal(JSON.stringify([current, incoming]), before, 'inputs must not be mutated');
});

test('retry recovery restores an empty draft without discarding text typed during a slow request', () => {
  assert.equal(restoreDraft('', '安排明天复习'), '安排明天复习');
  assert.equal(restoreDraft('   ', '安排明天复习'), '安排明天复习');
  assert.equal(restoreDraft('新的问题', '安排明天复习'), '新的问题');
  assert.equal(restoreDraft(' 新草稿\n', '旧消息'), ' 新草稿\n');
});

test('the real API request path sanitizes Agent errors while retaining unrelated validation wording', async () => {
  const client = mockApi(async () => ({ responseCode: 401,
    result: '{"code":"MODEL_AUTH_INVALID","detail":"PRIVATE_PROVIDER_DIAGNOSTICS"}' }));
  await assert.rejects(client.api.chat('session', 'deepseek-flash', 'test'), (error) => {
    assert.equal(error.code, 'MODEL_AUTH_INVALID');
    assert.doesNotMatch(error.message, /PRIVATE_PROVIDER_DIAGNOSTICS/);
    return true;
  });
  const login = mockApi(async () => ({ responseCode: 401, result: '{"detail":"邮箱或密码错误"}' }));
  await assert.rejects(login.api.login('user@example.test', 'incorrect'), (error) => {
    assert.ok(error instanceof CampusFlowRequestError);
    assert.equal(error.message, '请求失败（401）：邮箱或密码错误');
    return true;
  });
  assert.equal(client.destroyed(), 1);
  assert.equal(login.destroyed(), 1);
});

test('the real API request path emits distinct safe network/JSON failures and destroys each client', async () => {
  const network = mockApi(async () => { throw new Error('PRIVATE_TRANSPORT_URL'); });
  await assert.rejects(network.api.chat('session', 'deepseek-flash', 'test'), (error) => {
    assert.equal(error.code, 'NETWORK_ERROR');
    assert.doesNotMatch(error.message, /PRIVATE_TRANSPORT_URL/);
    return true;
  });
  for (const result of ['', '<html>PRIVATE_RESPONSE</html>']) {
    const malformed = mockApi(async () => ({ responseCode: 200, result }));
    await assert.rejects(malformed.api.chat('session', 'deepseek-flash', 'test'), (error) => {
      assert.equal(error.code, 'INVALID_RESPONSE');
      assert.equal(error.statusCode, 200);
      assert.doesNotMatch(error.message, /PRIVATE_RESPONSE/);
      return true;
    });
    assert.equal(malformed.destroyed(), 1);
  }
  assert.equal(network.calls.length, 1, 'network failures must not be automatically retried');
  assert.equal(network.destroyed(), 1);
});

test('actionStatus is an encoded read-only GET and uses the safe Agent error boundary', async () => {
  const client = mockApi(async () => ({ responseCode: 404,
    result: '{"code":"ACTION_NOT_FOUND","detail":"PRIVATE_DATABASE_DIAGNOSTICS"}' }));
  await assert.rejects(client.api.actionStatus('proposal/with space'), (error) => {
    assert.equal(error.code, 'ACTION_NOT_FOUND');
    assert.doesNotMatch(error.message, /PRIVATE_DATABASE_DIAGNOSTICS/);
    return true;
  });
  assert.equal(client.calls[0].url, 'http://fixture.invalid/api/v1/actions/proposal%2Fwith%20space');
  assert.equal(client.calls[0].options.method, 'GET');
  assert.equal(client.calls.length, 1);
});

test('planning action previews send exact task or plan IDs and full reviewed values without mutation', async () => {
  const client = mockApi(async () => ({ responseCode: 200, result: '{"proposal_id":"preview-only"}' }));
  const requests = [
    { operation: 'create_task', task: { title: '新待办', start_at: null, end_at: null, reminder_minutes: null, location: null } },
    { operation: 'update_task', task_id: 'task/a', task: { title: '同名任务', start_at: '2026-10-20T10:00:00+08:00', end_at: '2026-10-20T11:00:00+08:00', reminder_minutes: 15, location: '教室' } },
    { operation: 'delete_task', task_id: 'task/a' },
    { operation: 'update_plan', plan_id: 'plan/b', plan: { title: '同名计划', summary: '只改元信息', target_date: null } },
    { operation: 'delete_plan', plan_id: 'plan/b' }
  ];
  for (const payload of requests) {
    const before = JSON.stringify(payload); const result = await client.api.previewPlanningAction(payload);
    assert.equal(result.proposal_id, 'preview-only'); assert.equal(JSON.stringify(payload), before);
  }
  assert.deepEqual(client.calls.map(call => JSON.parse(call.options.extraData)), requests);
  assert.ok(client.calls.every(call => call.url === 'http://fixture.invalid/api/v1/planning/actions' && call.options.method === 'POST'));
  assert.equal(client.destroyed(), 5);
});
