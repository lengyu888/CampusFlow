import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';

const source = readFileSync(new URL('../../entry/src/main/ets/utils/AgentRun.ets', import.meta.url), 'utf8')
  .replace(/^import [^\n]+;\r?\n/gm, '').replace(/^export /gm, '');
const make = new Function('CampusFlowRequestError', 'localRequestFailure', stripTypeScriptTypes(source) + '\nreturn AgentRunController;');

// The real controller is used. Only scheduled wall-clock polling is disabled; tests
// explicitly call refresh/pollEvents when they need the next observed server state.
export function makeRunController(errorType, localRequestFailure) {
  const Controller = make(errorType, localRequestFailure);
  return class extends Controller {
    constructor(api, changed, succeeded, makeId) {
      super(api, changed, succeeded, makeId, { setTimeout: () => 1, clearTimeout: () => {} });
    }
  };
}

export function runSnapshot(request, result, extra = {}) {
  const now = '2028-10-20T08:00:00+08:00';
  return { ...request, status: 'succeeded', created_at: now, updated_at: now, seq: 2,
    partial_answer: '', tool_progress: [], model_calls: 1, tool_calls: 0,
    result: result === null || typeof result !== 'object' ? result : { ...result, session_id: request.session_id },
    error_code: null, error_message: null, ...extra };
}

// Existing conversation/voice tests still provide complete-response fixtures. Adapt
// those fixture values to the new run transport; production never falls back to /chat.
export function rememberHistory(history, request, response) {
  if (response === null || typeof response?.message !== 'string') return;
  const current = history.get(request.session_id) ?? [];
  history.set(request.session_id, current.concat([
    { role: 'user', content: request.message, created_at: '2028-10-20T08:00:00+08:00' },
    { role: 'assistant', content: response.message, created_at: '2028-10-20T08:00:01+08:00' }
  ]));
}
