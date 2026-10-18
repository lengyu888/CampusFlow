import { focusEntryFixture } from './helpers/focus-entry-fixture.mjs';
import { TaskStatusController, statusIds, statusTask, completeOperation, tick as statusTick } from './helpers/task-status-fixture.mjs';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';

const helperSource = readFileSync(new URL('../entry/src/main/ets/utils/AgentFeedback.ets', import.meta.url), 'utf8')
  .replace(/^import \{[^\n]+\} from '\.\.\/model\/ApiModels';\r?\n/, '');
const { CampusFlowRequestError } =
  await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(helperSource)).toString('base64')}`);
const source = readFileSync(new URL('../entry/src/main/ets/pages/HistoryPage.ets', import.meta.url), 'utf8');
const buildStart = source.indexOf('\n  build()');
assert.ok(buildStart > 0, 'the non-UI method boundary must exist');
// Run the actual production state and async methods, without rendering ArkUI.
// These behavior tests do not replace ArkTS compilation or device acceptance.
const controllerSource = source.slice(0, buildStart)
  .replace(/^import [^\n]+;\r?\n/gm, '')
  .replace(/^@Component\r?\n/m, '')
  .replace(/@(Prop|State)\s+|@Watch\('[^']+'\)\s*/g, '')
  .replace('export struct HistoryPage', 'class HistoryPage') + '\n}\n';
const createController = new Function('CampusFlowApi', 'localHistory', 'CampusFlowRequestError', 'AppTheme', 'Curve', 'Scroller',
  stripTypeScriptTypes(controllerSource) + '\nreturn HistoryPage;');
const navigationSource = readFileSync(new URL('../entry/src/main/ets/utils/AppNavigation.ets', import.meta.url), 'utf8');
const navigation = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(navigationSource)).toString('base64')}`);
const navNames = ['createNavigation', 'currentRoute', 'selectRoot', 'openSecondary', 'backNavigation', 'isRootRoute', 'hasBack'];
const indexSource = readFileSync(new URL('../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
const indexController = indexSource.slice(0, indexSource.indexOf('\n  @Builder'))
  .replace(/^import [^\n]+;\r?\n/gm, '')
  .replace(/^@(Entry|Component)\r?\n/gm, '')
  .replace(/@(State|Prop)\s+|@(StorageLink|Watch)\('[^']+'\)\s*/g, '')
  .replace('struct Index', 'class Index') + '\n}\n';
const draftSource = readFileSync(new URL('../entry/src/main/ets/utils/DraftStore.ets', import.meta.url), 'utf8');
const { DraftStore } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(draftSource)).toString('base64')}`);
const createIndexFactory = new Function('localHistory', 'historyScope', 'CampusFlowApi', 'AppStorage', 'localDrafts', 'TaskStatusController', 'timetableOperationId', 'FocusController', 'emptyFocusState', 'localFocus', 'PlatformFocusClock', ...navNames,
  stripTypeScriptTypes(indexController) + '\nreturn Index;');
const createIndex = (...args) => {
  let text;
  const drafts = new DraftStore({ read: async () => text, write: async value => { text = value; }, remove: async () => { text = undefined; } });
  drafts.initialize();
  return createIndexFactory(...args, drafts, TaskStatusController, () => statusIds.complete, ...Object.values(focusEntryFixture().dependencies), ...navNames.map(name => navigation[name]));
};
const storeSource = readFileSync(new URL('../entry/src/main/ets/utils/LocalHistoryStore.ets', import.meta.url), 'utf8')
  .replace(/^import .* from '\.\.\/model\/ApiModels';\r?\n/m, '');
const { LocalHistoryStore, historyScope } =
  await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(storeSource)).toString('base64')}`);

function session(id) {
  return { session_id: id, title: `会话 ${id}`, model_name: 'deepseek-flash', last_message: '已保存的回答',
    message_count: 2, created_at: '2026-10-17T09:00:00+08:00', updated_at: '2026-10-17T09:01:00+08:00' };
}

function messages(text = '完整回答') {
  return [{ role: 'user', content: '原始问题', created_at: '2026-10-17T09:00:00+08:00' },
    { role: 'assistant', content: text, created_at: '2026-10-17T09:01:00+08:00' }];
}

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((ok, fail) => { resolve = ok; reject = fail; });
  return { promise, resolve, reject };
}

const settle = () => new Promise((resolve) => setImmediate(resolve));

function harness({ handlers = {}, cached = [], removed = [], local = {} } = {}) {
  const apiCalls = [];
  const localCalls = [];
  const deleted = [];
  const creations = [];
  const entries = new Map(cached.map(({ summary, history }) => [summary.session_id,
    { summary: structuredClone(summary), history: structuredClone(history) }]));
  const scope = 'fixture-account-scope';
  class Api {
    constructor(baseUrl, token) { creations.push({ baseUrl, token }); }
    invoke(method, args) {
      apiCalls.push({ method, args });
      assert.equal(typeof handlers[method], 'function', `unexpected API call: ${method}`);
      return handlers[method](...args);
    }
    sessions(...args) { return this.invoke('sessions', args); }
    history(...args) { return this.invoke('history', args); }
    deleteSession(...args) { return this.invoke('deleteSession', args); }
  }
  const store = {
    epoch: () => local.epoch ? local.epoch() : 1,
    list(currentScope) {
      return currentScope === scope ? [...entries.values()].map((entry) => structuredClone(entry.summary)) : [];
    },
    messages(currentScope, id) {
      return currentScope === scope && entries.has(id) ? structuredClone(entries.get(id).history) : undefined;
    },
    isRemoved(currentScope, id) { return currentScope === scope && removed.includes(id); },
    async save(currentScope, summary, history) {
      localCalls.push({ method: 'save', args: [currentScope, summary, history] });
      if (local.save) return local.save(currentScope, summary, history);
      if (currentScope !== scope) return false;
      entries.set(summary.session_id, { summary: structuredClone(summary), history: structuredClone(history) });
      return true;
    },
    async removeSession(currentScope, id, deletedRemotely = true) {
      localCalls.push({ method: 'removeSession', args: [currentScope, id, deletedRemotely] });
      if (local.removeSession) await local.removeSession(currentScope, id, deletedRemotely);
      if (currentScope === scope) entries.delete(id);
    }
  };
  const Controller = createController(Api, store, CampusFlowRequestError,
    { motion: (duration) => duration }, { EaseOut: 'fixture-ease-out' },
    class { scrollTo(value) { this.position = value; } currentOffset() { return { yOffset: 0 }; } });
  const page = new Controller();
  page.baseUrl = 'http://fixture.invalid';
  page.token = 'test-only';
  page.historyScope = scope;
  page.onSessionDeleted = (id) => deleted.push(id);
  page.getUIContext = () => ({ animateTo: (_options, callback) => callback() });
  return { page, apiCalls, localCalls, creations, deleted, entries, scope };
}

test('offline reload, open and removal never construct an API and remove only the local copy', async () => {
  const summary = session('cached');
  const history = messages();
  const h = harness({ cached: [{ summary, history }] });
  h.page.offlineOnly = true;
  await h.page.reload();
  assert.deepEqual(h.page.sessions, [summary]);
  await h.page.openSession(summary);
  assert.deepEqual(h.page.messages, history);
  assert.equal(h.page.selected.session_id, summary.session_id);
  await h.page.deleteSession(summary);
  assert.deepEqual(h.localCalls, [{ method: 'removeSession', args: [h.scope, summary.session_id, false] }]);
  assert.deepEqual(h.creations, []);
  assert.deepEqual(h.apiCalls, []);
  assert.deepEqual(h.deleted, []);
  assert.deepEqual(h.page.sessions, []);
  assert.deepEqual(h.page.messages, []);
  assert.equal(h.page.selected, null);
});

test('offline opening an uncached session reports missing content without fetching it', async () => {
  const h = harness();
  h.page.offlineOnly = true;
  await h.page.openSession(session('uncached'));
  assert.equal(h.page.selected, null);
  assert.deepEqual(h.page.messages, []);
  assert.match(h.page.errorText, /本机没有.*完整内容/);
  assert.equal(h.page.loading, false);
  assert.deepEqual(h.creations, []);
  assert.deepEqual(h.localCalls, []);
});

test('network failures fall back only to saved sessions and complete cached messages', async () => {
  const summary = session('cached');
  const history = messages('本机完整回答');
  const unavailable = async () => { throw new Error('PRIVATE_SERVER_DETAIL'); };
  const h = harness({ cached: [{ summary, history }], handlers: { sessions: unavailable, history: unavailable } });
  h.page.sessions = [session('old-server-only')];
  await h.page.reload();
  assert.deepEqual(h.page.sessions, [summary]);
  await h.page.openSession(summary);
  assert.deepEqual(h.page.messages, history);
  assert.equal(h.page.selected.session_id, summary.session_id);
  assert.match(h.page.errorText, /上次保存的本机副本/);
  h.page.goBack();
  await h.page.openSession(session('never-saved'));
  assert.equal(h.page.selected, null);
  assert.deepEqual(h.page.messages, []);
  assert.match(h.page.errorText, /尚未保存到本机/);
  assert.doesNotMatch(h.page.errorText, /PRIVATE_SERVER_DETAIL/);
  assert.deepEqual(h.localCalls, []);
});

test('online reload excludes sessions already removed locally from the server response', async () => {
  const keep = session('keep');
  const h = harness({ removed: ['removed'], handlers: { sessions: async () => [session('removed'), keep] } });
  await h.page.reload();
  assert.deepEqual(h.page.sessions, [keep]);
});

test('two opened sessions resolving in reverse order cannot change the current page or cache the stale one', async () => {
  const first = deferred();
  const second = deferred();
  const h = harness({ handlers: { history: (id) => id === 'first' ? first.promise : second.promise } });
  const openingFirst = h.page.openSession(session('first'));
  const openingSecond = h.page.openSession(session('second'));
  second.resolve(messages('第二个会话'));
  await openingSecond;
  first.resolve(messages('过期的第一个会话'));
  await openingFirst;
  assert.equal(h.page.selected.session_id, 'second');
  assert.deepEqual(h.page.messages, messages('第二个会话'));
  assert.deepEqual(h.localCalls.map((call) => call.args[1].session_id), ['second']);
  assert.equal(h.entries.has('first'), false);
  assert.equal(h.page.loading, false);
});

test('returning to the list invalidates an in-flight cached session refresh before it writes', async () => {
  const response = deferred();
  const summary = session('cached');
  const original = messages('旧的本机副本');
  const h = harness({ cached: [{ summary, history: original }], handlers: { history: () => response.promise } });
  const opening = h.page.openSession(summary);
  h.page.goBack();
  response.resolve(messages('返回后才到达的内容'));
  await opening;
  assert.equal(h.page.selected, null);
  assert.deepEqual(h.page.messages, []);
  assert.deepEqual(h.localCalls, []);
  assert.deepEqual(h.entries.get(summary.session_id).history, original);
});

test('leaving and reappearing cannot revive an old history response or write it to cache', async () => {
  const oldResponse = deferred();
  const latest = session('current-list');
  const h = harness({ handlers: { history: () => oldResponse.promise, sessions: async () => [latest] } });
  const oldOpening = h.page.openSession(session('before-leave'));
  h.page.aboutToDisappear();
  h.page.aboutToAppear();
  await settle();
  oldResponse.resolve(messages('离开前请求的回答'));
  await oldOpening;
  assert.deepEqual(h.page.sessions, [latest]);
  assert.equal(h.page.selected, null);
  assert.deepEqual(h.page.messages, []);
  assert.deepEqual(h.localCalls, []);
  assert.equal(h.page.loading, false);
});

test('chat busy prevents both remote deletion and local removal', async () => {
  for (const offlineOnly of [false, true]) {
    const h = harness();
    h.page.offlineOnly = offlineOnly;
    h.page.chatBusy = true;
    await h.page.deleteSession(session('busy'));
    assert.deepEqual(h.apiCalls, []);
    assert.deepEqual(h.localCalls, []);
    assert.equal(h.page.deleting, false);
  }
});

test('repeated deletion and opening are blocked through the remote and local deletion stages', async () => {
  const remote = deferred();
  const local = deferred();
  const summary = session('delete-once');
  const h = harness({ cached: [{ summary, history: messages() }],
    handlers: { deleteSession: () => remote.promise }, local: { removeSession: () => local.promise } });
  h.page.sessions = [summary];
  const deleting = h.page.deleteSession(summary);
  await h.page.deleteSession(summary);
  await h.page.openSession(summary);
  assert.equal(h.page.deleting, true);
  remote.resolve();
  await settle();
  await h.page.deleteSession(summary);
  assert.equal(h.page.deleting, true);
  assert.deepEqual(h.apiCalls.map((call) => call.method), ['deleteSession']);
  assert.equal(h.localCalls.length, 1);
  local.resolve();
  await deleting;
  assert.equal(h.page.deleting, false);
  assert.deepEqual(h.page.sessions, []);
});

test('an authenticated 404 during deletion still clears the local copy', async () => {
  const summary = session('already-gone');
  const h = harness({ cached: [{ summary, history: messages() }], handlers: { deleteSession: async () => {
    throw new CampusFlowRequestError(404, 'HTTP_ERROR', 'already deleted');
  } } });
  h.page.sessions = [summary];
  await h.page.deleteSession(summary);
  assert.deepEqual(h.localCalls, [{ method: 'removeSession', args: [h.scope, summary.session_id, true] }]);
  assert.deepEqual(h.deleted, [summary.session_id]);
  assert.equal(h.page.errorText, '');
  assert.deepEqual(h.page.sessions, []);
  assert.equal(h.entries.has(summary.session_id), false);
});

test('leaving History during deletion still clears the captured cache and notifies the same-account Index', async () => {
  const remote = deferred();
  const summary = session('delete-after-tab-change');
  const h = harness({ cached: [{ summary, history: messages() }],
    handlers: { deleteSession: () => remote.promise } });
  const Index = createIndex({}, historyScope, class {}, { setOrCreate: () => {} });
  const index = new Index();
  index.reminders = { configure() {}, setActive() {}, refresh() {}, async logout() {}, dispose() {} };
  index.token = 'same-account-token';
  index.authRevision = 7;
  index.activeTab = 5;
  h.page.accountRevision = index.authRevision;
  h.page.sessions = [summary];
  h.page.onSessionDeleted = (id, revision) => index.sessionDeleted(id, revision);
  h.page.onDeleteBusyChange = (busy, revision) => index.deletionBusyChanged(busy, revision);

  const deleting = h.page.deleteSession(summary);
  assert.equal(index.historyDeleteBusy, true);
  // Model the observed lifecycle boundary when Index switches away from tab 5.
  index.activeTab = 1;
  h.page.aboutToDisappear();
  assert.equal(index.historyDeleteBusy, true, 'deletion remains busy across navigation');
  remote.resolve();
  await deleting;

  assert.deepEqual(h.localCalls, [{ method: 'removeSession', args: [h.scope, summary.session_id, true] }]);
  assert.equal(h.entries.has(summary.session_id), false);
  assert.equal(index.deletedSessionId, summary.session_id);
  assert.equal(index.deletionRevision, 1);
  assert.equal(index.historyDeleteBusy, false);
  assert.deepEqual(h.page.sessions, [summary], 'an inactive page does not receive UI updates');
});

test('logout and another login invalidate an old deletion without touching the new account or its busy state', async () => {
  const remote = deferred();
  const summary = session('same-session-id');
  let disk;
  const store = new LocalHistoryStore({
    read: async () => disk,
    write: async (text) => { disk = text; },
    remove: async () => { disk = undefined; }
  });
  await store.initialize();
  const h = harness({ handlers: { deleteSession: () => remote.promise },
    local: { epoch: () => store.epoch(), removeSession: (...args) => store.removeSession(...args) } });
  await store.activate(h.scope, 'old-account');
  await store.save(h.scope, summary, messages('旧账号的回答'));
  const revokedTokens = [];
  class Api {
    constructor(_baseUrl, token) { this.token = token; }
    async logout() { revokedTokens.push(this.token); }
  }
  const Index = createIndex(store, historyScope, Api, { setOrCreate: () => {} });
  const index = new Index();
  index.reminders = { configure() {}, setActive() {}, refresh() {}, async logout() {}, dispose() {} };
  index.token = 'old-account-token';
  index.authRevision = 4;
  index.cacheScope = h.scope;
  h.page.accountRevision = index.authRevision;
  h.page.onSessionDeleted = (id, revision) => index.sessionDeleted(id, revision);
  h.page.onDeleteBusyChange = (busy, revision) => index.deletionBusyChanged(busy, revision);

  const deleting = h.page.deleteSession(summary);
  h.page.aboutToDisappear();
  await index.logout();
  await index.authenticated({ access_token: 'new-account-token',
    user: { user_id: 'new-account', display_name: '新账号' } });
  const newScope = index.cacheScope;
  const newMessages = messages('新账号同名会话必须保留');
  assert.equal(await store.save(newScope, summary, newMessages), true);
  index.deletionBusyChanged(true, index.authRevision);
  remote.resolve();
  await deleting;

  assert.deepEqual(revokedTokens, ['old-account-token']);
  assert.deepEqual(h.localCalls, [], 'the old account response must not remove any current snapshot');
  assert.deepEqual(store.messages(newScope, summary.session_id), newMessages);
  assert.equal(index.token, 'new-account-token');
  assert.equal(index.cacheScope, newScope);
  assert.equal(index.deletedSessionId, '');
  assert.equal(index.deletionRevision, 0);
  assert.equal(index.historyDeleteBusy, true, 'the old completion cannot release the new account busy state');
});

test('other deletion failures retain local content and never expose server diagnostics', async () => {
  const summary = session('keep-on-error');
  const h = harness({ cached: [{ summary, history: messages() }], handlers: { deleteSession: async () => {
    throw new CampusFlowRequestError(500, 'HTTP_ERROR', 'PRIVATE_SERVER_DETAIL');
  } } });
  h.page.sessions = [summary];
  await h.page.deleteSession(summary);
  assert.deepEqual(h.localCalls, []);
  assert.deepEqual(h.deleted, []);
  assert.equal(h.entries.has(summary.session_id), true);
  assert.deepEqual(h.page.sessions, [summary]);
  assert.match(h.page.errorText, /删除未完成/);
  assert.doesNotMatch(h.page.errorText, /PRIVATE_SERVER_DETAIL/);
  assert.equal(h.page.deleting, false);
});

test('a remote deletion followed by local failure can be retried, including a subsequent 404', async () => {
  let remoteAttempts = 0;
  let localAttempts = 0;
  const summary = session('cleanup-retry');
  const h = harness({ cached: [{ summary, history: messages() }], handlers: { deleteSession: async () => {
    if (++remoteAttempts > 1) throw new CampusFlowRequestError(404, 'HTTP_ERROR', 'already gone');
  } }, local: { removeSession: async () => {
    if (++localAttempts === 1) throw new Error('PRIVATE_DISK_PATH');
  } } });
  h.page.sessions = [summary];
  h.page.pendingDeleteId = summary.session_id;
  await h.page.deleteSession(summary);
  assert.equal(h.page.deleting, false);
  assert.match(h.page.errorText, /服务端已删除.*本机副本移除失败/);
  assert.doesNotMatch(h.page.errorText, /PRIVATE_DISK_PATH/);
  assert.equal(h.page.pendingDeleteId, summary.session_id);
  assert.equal(h.entries.has(summary.session_id), true);
  await h.page.deleteSession(summary);
  assert.equal(remoteAttempts, 2);
  assert.equal(localAttempts, 2);
  assert.equal(h.page.deleting, false);
  assert.equal(h.page.errorText, '');
  assert.equal(h.page.pendingDeleteId, '');
  assert.deepEqual(h.page.sessions, []);
  assert.equal(h.entries.has(summary.session_id), false);
});

test('offline local removal failure remains retryable and never marks a remote deletion', async () => {
  let attempts = 0;
  const summary = session('offline-retry');
  const h = harness({ cached: [{ summary, history: messages() }], local: { removeSession: async () => {
    if (++attempts === 1) throw new Error('PRIVATE_DISK_PATH');
  } } });
  h.page.offlineOnly = true;
  await h.page.reload();
  await h.page.deleteSession(summary);
  assert.match(h.page.errorText, /本机副本移除失败/);
  assert.equal(h.page.deleting, false);
  await h.page.deleteSession(summary);
  assert.equal(h.page.errorText, '');
  assert.deepEqual(h.page.sessions, []);
  assert.deepEqual(h.localCalls.map((call) => call.args[2]), [false, false]);
  assert.deepEqual(h.creations, []);
  assert.deepEqual(h.deleted, []);
});

test('unavailable or failing local storage cannot turn a valid online history into a failed read', async () => {
  for (const save of [async () => false, async () => { throw new Error('PRIVATE_DISK_PATH'); }]) {
    const summary = session('online-without-store');
    const history = messages('有效的在线回答');
    const h = harness({ handlers: { history: async () => history }, local: { save } });
    h.page.historyScope = '';
    await h.page.openSession(summary);
    assert.deepEqual(h.page.messages, history);
    assert.equal(h.page.selected.session_id, summary.session_id);
    assert.equal(h.page.loading, false);
    assert.doesNotMatch(h.page.errorText, /PRIVATE_DISK_PATH|请联网后重试|暂时无法同步/);
    assert.doesNotMatch(h.page.sourceText, /已保存到本机/);
  }
});

test('an empty server history removes the stale local copy instead of persisting empty content', async () => {
  const summary = session('empty-on-server');
  const h = harness({ cached: [{ summary, history: messages() }], handlers: { history: async () => [] } });
  h.page.sessions = [summary];
  await h.page.openSession(summary);
  assert.deepEqual(h.page.messages, []);
  assert.deepEqual(h.page.sessions, []);
  assert.deepEqual(h.localCalls, [{ method: 'removeSession', args: [h.scope, summary.session_id, true] }]);
  assert.deepEqual(h.deleted, [summary.session_id]);
  assert.equal(h.page.loading, false);
});

test('failed uncached history can be retried explicitly without inventing a local copy', async () => {
  let unavailable = true;
  const summary = session('retry');
  const h = harness({ handlers: { history: async () => {
    if (unavailable) throw new Error('temporary');
    return messages('重试得到的完整回答');
  } } });
  await h.page.openSession(summary);
  assert.equal(h.page.selected, null);
  assert.equal(h.localCalls.length, 0);
  unavailable = false;
  await h.page.retryRead();
  assert.equal(h.page.selected.session_id, 'retry');
  assert.equal(h.page.messages[1].content, '重试得到的完整回答');
});

test('return from detail restores the list source and saved reading position', async () => {
  const summary = session('cached');
  const h = harness({ cached: [{ summary, history: messages() }] });
  h.page.offlineOnly = true;
  await h.page.reload();
  const listSource = h.page.sourceText;
  h.page.listOffset = 620;
  await h.page.openSession(summary);
  h.page.goBack();
  h.page.restoreListPosition();
  assert.equal(h.page.sourceText, listSource);
  assert.deepEqual(h.page.listScroller.position, { xOffset: 0, yOffset: 620, animation: false });
  assert.equal(h.apiCalls.length, 0);
});

test('continue is offered only for a successfully read remote conversation and emits only its ID', async () => {
  const h=harness({handlers:{history:async()=>messages()}}),continued=[];
  h.page.onContinueSession=id=>continued.push(id);
  await h.page.openSession(session('remote-a'));
  assert.equal(h.page.canContinue(),true);h.page.continueSession();
  assert.deepEqual(continued,['remote-a']);
  assert.deepEqual(h.apiCalls.map(c=>c.method),['history'],'history page does not execute or restore any proposal');
  h.page.chatBusy=true;assert.equal(h.page.canContinue(),true,'Agent handles draft flush and pending-write protection before switching');h.page.chatBusy=false;
  for(const flag of ['loading','deleting','remoteDeleteBusy','offlineOnly']){
    h.page[flag]=true;assert.equal(h.page.canContinue(),false);h.page.continueSession();h.page[flag]=false;
  }
  assert.deepEqual(continued,['remote-a']);
});

test('cached, failed, empty and obsolete remote reads cannot become a continue-session intent', async () => {
  for(const response of ['failed','empty']){
    const h=harness({cached:[{summary:session('a'),history:messages('old cache')}],handlers:{history:async()=>{if(response==='failed')throw Error('offline');return [];}}});
    await h.page.openSession(session('a'));assert.equal(h.page.canContinue(),false);
  }
  const wait=deferred(),h=harness({handlers:{history:()=>wait.promise}});
  const reading=h.page.openSession(session('a'));h.page.aboutToDisappear();wait.resolve(messages());await reading;
  assert.equal(h.page.verifiedRemoteSessionId,'');assert.equal(h.page.canContinue(),false);
});

test('switching history selection immediately revokes the previous successful continue target', async () => {
  const wait=deferred(),h=harness({handlers:{history:id=>id==='a'?Promise.resolve(messages('a')):wait.promise}});
  await h.page.openSession(session('a'));assert.equal(h.page.canContinue(),true);
  const reading=h.page.openSession(session('b'));assert.equal(h.page.canContinue(),false);
  wait.resolve(messages('b'));await reading;assert.equal(h.page.verifiedRemoteSessionId,'b');
  h.page.goBack();assert.equal(h.page.canContinue(),false);
});


test('Index routes back through the personal-settings inner page before popping its root route',()=>{
 const Index=createIndex({},historyScope,class {},{setOrCreate(){}}),index=new Index();
 index.navigation=navigation.openSecondary(navigation.createNavigation(),4);index.activeTab=4;index.profileInnerActive=true;
 const before=structuredClone(index.navigation);index.goBack();assert.equal(index.profileBackRevision,1);assert.deepEqual(index.navigation,before);
 index.applyNavigation=next=>{index.navigation=next;index.activeTab=navigation.currentRoute(next);};
 index.profileInnerActive=false;index.goBack();assert.equal(index.activeTab,0);
 index.profileInnerActive=true;index.resetNavigation();assert.equal(index.profileInnerActive,false);
});
