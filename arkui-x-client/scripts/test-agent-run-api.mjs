import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';

const feedbackSource = readFileSync(new URL('../entry/src/main/ets/utils/AgentFeedback.ets', import.meta.url), 'utf8')
  .replace(/^import[^\n]+;\r?\n/gm, '');
const feedback = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(feedbackSource)).toString('base64')}`);
const source = readFileSync(new URL('../entry/src/main/ets/services/CampusFlowApi.ets', import.meta.url), 'utf8')
  .replace(/^import http from '@ohos.net.http';\r?\n/m, '')
  .replace(/^import \{[\s\S]*?\} from '\.\.\/model\/ApiModels';\r?\n/m, '')
  .replace(/^import \{[^\n]+\} from '\.\.\/utils\/AgentFeedback';\r?\n/m, '')
  .replace('export class CampusFlowApi', 'class CampusFlowApi');
const make = new Function('http', 'CampusFlowRequestError', 'localRequestFailure', 'requestFailure',
  stripTypeScriptTypes(source) + '\nreturn CampusFlowApi;');
function setup(response = { responseCode: 200, result: '{}' }) {
  const calls = []; let destroyed = 0;
  const http = { RequestMethod: { GET: 'GET', POST: 'POST' }, HttpDataType: { STRING: 'STRING' },
    createHttp: () => ({ request: async (url, options) => { calls.push({ url, options }); if (response instanceof Error) throw response; return response; },
      destroy: () => destroyed++ }) };
  const Api = make(http, feedback.CampusFlowRequestError, feedback.localRequestFailure, feedback.requestFailure);
  return { client: new Api('https://fixture.invalid/', 'test-token'), calls, destroyed: () => destroyed };
}

test('run API uses the frozen request, cursor and escaped paths with explicit empty JSON cancellation', async () => {
  const { client, calls, destroyed } = setup();
  const request = { run_id: '11111111-1111-4111-8111-111111111111', session_id: 'session-a', model: 'deepseek-flash', message: '原问题' };
  await client.startAgentRun(request); await client.agentRun('a/b?c'); await client.agentRunEvents('a/b?c', 27);
  await client.cancelAgentRun('a/b?c'); await client.recentAgentRuns();
  assert.deepEqual(calls.map(c => [c.url.replace('https://fixture.invalid', ''), c.options.method]), [
    ['/api/v1/agent-runs', 'POST'], ['/api/v1/agent-runs/a%2Fb%3Fc', 'GET'],
    ['/api/v1/agent-runs/a%2Fb%3Fc/events?after_seq=27', 'GET'], ['/api/v1/agent-runs/a%2Fb%3Fc/cancel', 'POST'],
    ['/api/v1/agent-runs?limit=20', 'GET']]);
  assert.deepEqual(JSON.parse(calls[0].options.extraData), request); assert.equal(calls[3].options.extraData, '{}');
  assert.ok(calls.every(c => c.options.header.Authorization === 'Bearer test-token')); assert.equal(destroyed(), 5);
});

test('run failures keep typed safe codes including deleted IDs without exposing provider/server details', async () => {
  for (const [status, code] of [[409, 'RUN_SESSION_BUSY'], [409, 'RUN_ID_REUSED'], [404, 'RUN_NOT_FOUND'], [410, 'RUN_DELETED']]) {
    const { client, destroyed } = setup({ responseCode: status, result: JSON.stringify({ code, detail: 'private-secret-url' }) });
    await assert.rejects(client.agentRun('id'), error => error.code === code && error.statusCode === status && !error.message.includes('private-secret-url'));
    assert.equal(destroyed(), 1);
  }
});

test('an unavailable run route stays a safe failure and never falls back to the old chat POST', async () => {
  const { client, calls } = setup({ responseCode: 404, result: '<html>private-proxy-detail</html>' });
  await assert.rejects(client.startAgentRun({ run_id: 'id', session_id: 's', model: 'm', message: 'q' }),
    error => error instanceof feedback.CampusFlowRequestError && !error.message.includes('private-proxy-detail'));
  assert.equal(calls.length, 1); assert.equal(calls[0].url, 'https://fixture.invalid/api/v1/agent-runs');
});

test('network and invalid JSON are typed, safely worded and always release the native HTTP request', async () => {
  for (const response of [Error('secret-network-details'), { responseCode: 200, result: 'private-invalid-json' }]) {
    const { client, destroyed } = setup(response);
    await assert.rejects(client.agentRun('id'), error => ['NETWORK_ERROR', 'INVALID_RESPONSE'].includes(error.code) &&
      !/secret-network-details|private-invalid-json/.test(error.message));
    assert.equal(destroyed(), 1);
  }
});
