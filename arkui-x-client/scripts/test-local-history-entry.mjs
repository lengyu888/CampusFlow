import './helpers/theme-fixture.mjs';
import { focusEntryFixture } from './helpers/focus-entry-fixture.mjs';
import { TaskStatusController, statusIds, statusTask, completeOperation, tick as statusTick } from './helpers/task-status-fixture.mjs';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripThemeTypeScriptTypes as stripTypeScriptTypes } from './helpers/theme-fixture.mjs';
import { test } from 'node:test';
import { sessionHelpers } from './helpers/session-fixture.mjs';

const draftSource = readFileSync(new URL('../entry/src/main/ets/utils/DraftStore.ets', import.meta.url), 'utf8')
  .replace(/^import \{[\s\S]*?\} from '(?:\.\.\/model\/ApiModels|\.\/OnboardingTimetable)';\r?\n/gm, '');
const { DraftStore } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(draftSource)).toString('base64')}`);

// Execute real entry/auth controller methods with synthetic storage and HTTP.
// This does not emulate ArkUI lifecycle scheduling or native file APIs.
const navigationSource = readFileSync(new URL('../entry/src/main/ets/utils/AppNavigation.ets', import.meta.url), 'utf8');
const navigation = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(navigationSource)).toString('base64')}`);
const navNames = ['createNavigation', 'currentRoute', 'selectRoot', 'openSecondary', 'backNavigation', 'isRootRoute', 'hasBack'];
const source = readFileSync(new URL('../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
const controller = source.slice(0, source.indexOf('\n  @Builder'))
  .replace(/^import [^\n]+;\r?\n/gm, '')
  .replace(/^@(Entry|Component)\r?\n/gm, '')
  .replace(/@(State|Prop)\s+|@(StorageLink|Watch)\('[^']+'\)\s*/g, '')
  .replace('struct Index', 'class Index') + '\n}\n';
const create = new Function('localHistory', 'historyScope', 'CampusFlowApi', 'AppStorage', 'AppTheme', 'Curve', 'localDrafts', 'TaskStatusController', 'timetableOperationId', 'FocusController', 'emptyFocusState', 'localFocus', 'PlatformFocusClock', ...navNames,
  stripTypeScriptTypes(controller) + '\nreturn Index;');
const auth = (name = 'a') => ({ access_token: `${name}-token`, user: { user_id: name, display_name: name } });
const deferred = () => {
  let resolve, reject;
  const promise = new Promise((ok, fail) => { resolve = ok; reject = fail; });
  return { promise, resolve, reject };
};
function setup(overrides = {}, draftOverrides = {}) {
  const calls = [];
  const store = {
    info: () => ({ scope: 'scope-a', displayName: 'a', count: 2 }),
    activate: async (...args) => { calls.push(['activate', ...args]); },
    clear: async () => { calls.push(['clear']); }, ...overrides
  };
  class Api {
    constructor(base, token) { this.token = token; }
    async logout() { calls.push(['logout', this.token]); }
  }
  const draftDriver = {
    text: undefined,
    async read() { return this.text; },
    async write(value) { this.text = value; },
    async remove() { this.text = undefined; },
    ...draftOverrides
  };
  const drafts = new DraftStore(draftDriver, { now: () => Date.UTC(2026, 9, 18), set: () => 1, clear() {} });
  const draftReady = drafts.initialize().catch(() => {});
  const Index = create(store, (base, id) => `${base}|${id}`, Api, { setOrCreate: () => {} },
    { motion: () => 0 }, { EaseOut: 0 }, drafts, TaskStatusController, () => statusIds.complete, ...Object.values(focusEntryFixture().dependencies), ...navNames.map(name => navigation[name]));
  const page = new Index();
  page.reminders = { configure() {}, setActive() {}, refresh() {}, async logout() {}, dispose() {} };
  page.getUIContext = () => ({ animateTo: (_options, update) => update() });
  return { page, calls, store, drafts, draftDriver, draftReady };
}

const restoredUser = { user_id: 'a', display_name: '测试', email: 'user@example.invalid', role: 'user',
  school: null, campus: null, semester: null, onboarding_complete: true, api_key_configured: false, api_key_hint: null };
const savedSession = { schemaVersion: 1, userId: 'a', baseUrl: 'http://127.0.0.1:8001',
  accessToken: 'synthetic-persisted-token', savedAt: 1 };
function savedLogin(page, options = {}) {
  const calls = [];
  const vault = { read: async () => savedSession, save: async () => {}, clear: async () => {}, ...options.vault };
  page.sessionCoordinator = new sessionHelpers.SessionCoordinator(vault, (base, token) => ({
    async probeHealth() { calls.push(['probe', base, token]); return options.probe ?? { kind: 'online', statusCode: 200, elapsedMs: 1 }; },
    async verifySession() { calls.push(['verify', base, token]); return options.verify ? options.verify() : restoredUser; }
  }));
  return calls;
}

test('actual root restores a saved custom-port session only after original-service user validation', async () => {
  const { page } = setup(); const calls = savedLogin(page);
  await page.restoreSavedLogin();
  assert.equal(page.token, savedSession.accessToken); assert.equal(page.authBaseUrl, savedSession.baseUrl);
  assert.equal(page.baseUrl, savedSession.baseUrl); assert.equal(page.sessionRestoring, false);
  assert.deepEqual(calls, [['probe', savedSession.baseUrl, ''], ['verify', savedSession.baseUrl, savedSession.accessToken]]);
});

test('actual root ignores a pending saved login after editing service, preserving the new target', async () => {
  const wait = deferred(); const { page } = setup(); savedLogin(page, { verify: () => wait.promise });
  const restore = page.restoreSavedLogin(); await statusTick();
  page.changeLoginBase('http://127.0.0.1:8002'); wait.resolve(restoredUser); await restore;
  assert.equal(page.token, ''); assert.equal(page.baseUrl, 'http://127.0.0.1:8002'); assert.equal(page.sessionRestoring, false);
});

test('native input initialization echoing the unchanged service must not cancel a saved-session restore', async () => {
  const wait = deferred(); const { page } = setup(); savedLogin(page, { verify: () => wait.promise });
  const restore = page.restoreSavedLogin(); await statusTick();
  const initial = page.baseUrl; page.changeLoginBase(initial);
  wait.resolve(restoredUser); await restore;
  assert.equal(page.token, savedSession.accessToken);
  assert.equal(page.baseUrl, savedSession.baseUrl);
});

test('actual root exposes retry without opening private pages or clearing data when original service is offline', async () => {
  const { page, calls } = setup(); savedLogin(page, { probe: { kind: 'network_unreachable', statusCode: 0, elapsedMs: 1 } });
  await page.restoreSavedLogin(); assert.equal(page.token, ''); assert.equal(page.sessionRetryAllowed, true);
  assert.match(page.sessionRestoreNotice, /仍保留/); assert.deepEqual(calls, []);
});

test('manual callback from a different service cannot activate caches or publish the response token', async () => {
  const { page, calls } = setup(); page.baseUrl = 'http://127.0.0.1:8000';
  await assert.rejects(page.authenticated({ user: restoredUser, access_token: savedSession.accessToken }, savedSession.baseUrl, true), /来源/);
  assert.equal(page.token, ''); assert.deepEqual(calls, []);
});

test('failed durable logout preserves the account and restores task, focus and reminder controllers', async () => {
  const { page, calls } = setup(); await page.authenticated(auth());
  const beforeStatus = page.taskStatuses, beforeFocus = page.focusManager; let reminderConfigurations = 0;
  page.reminders.configure = () => { reminderConfigurations++; };
  savedLogin(page, { vault: { async clear() { throw new sessionHelpers.SessionStorageError(); } } });
  await page.logout();
  assert.equal(page.token, 'a-token'); assert.equal(page.sessionLogoutBusy, false);
  assert.notEqual(page.taskStatuses, null); assert.notEqual(page.focusManager, null);
  assert.notEqual(page.taskStatuses, beforeStatus); assert.notEqual(page.focusManager, beforeFocus);
  assert.equal(reminderConfigurations, 1); assert.match(page.loginPersistenceNotice, /退出尚未完成/);
  assert.equal(calls.some(call => call[0] === 'logout'), false);
});

test('physical asset removal failure after durable veto still closes the root and revokes the original server session', async () => {
  const { page, calls } = setup(); await page.authenticated(auth());
  savedLogin(page, { vault: { async clear() { throw new sessionHelpers.SessionStorageError('SESSION_REMOVAL_PENDING'); } } });
  await page.logout(); assert.equal(page.token, ''); assert.equal(page.sessionLogoutBusy, false);
  assert.ok(calls.some(call => call[0] === 'logout' && call[1] === 'a-token'));
});

test('login awaits account-scoped cache activation before showing authenticated pages', async () => {
  const pending = deferred();
  const { page } = setup({ activate: () => pending.promise });
  const signingIn = page.authenticated(auth());
  assert.equal(page.token, '');
  pending.resolve();
  await signingIn;
  assert.equal(page.token, 'a-token');
  assert.equal(page.cacheScope, 'scope-a');
  assert.equal(page.localHistoryCount, 2);
});

test('cache failure does not prevent online login or expose the previous account cache', async () => {
  const { page } = setup({ activate: async () => { throw new Error('disk'); } });
  page.cacheScope = 'old-account';
  page.localHistoryCount = 5;
  await page.authenticated(auth('b'));
  assert.equal(page.token, 'b-token');
  assert.equal(page.cacheScope, '');
  assert.equal(page.localHistoryCount, 0);
  assert.match(page.cacheNotice, /暂不可用/);
});

test('logout gates access while disabling persistent sign-in, then closes auth before slow cache clearing', async () => {
  const clearing = deferred();
  const { page, calls } = setup({ clear: () => clearing.promise });
  page.token = 'old-token'; page.cacheScope = 'old-scope'; page.localHistoryCount = 2;
  page.offlineHistory = true; page.agentChatBusy = true;
  const signingOut = page.logout();
  assert.equal(page.sessionLogoutBusy, true);
  await statusTick();
  assert.equal(page.token, '');
  assert.equal(page.cacheScope, '');
  assert.equal(page.localHistoryCount, 0);
  assert.equal(page.offlineHistory, false);
  assert.equal(page.agentChatBusy, false);
  clearing.resolve();
  await signingOut;
  assert.deepEqual(calls, [['logout', 'old-token']]);
});

test('failed clearing remains retryable and remote logout is still attempted', async () => {
  const { page, calls, store } = setup({ clear: async () => { throw new Error('disk'); } });
  page.token = 'old-token';
  await page.logout();
  assert.equal(page.cleanupNeeded, true);
  assert.equal(page.token, '');
  assert.deepEqual(calls, [['logout', 'old-token']]);
  store.clear = async () => {};
  store.info = () => ({ scope: '', displayName: '', count: 0 });
  await page.clearLocalHistory();
  assert.equal(page.cleanupNeeded, false);
  assert.equal(page.localHistoryCount, 0);
});

test('a new login while old logout finishes keeps the new token and still revokes the old token', async () => {
  const clearing = deferred();
  const { page, calls } = setup({ clear: () => clearing.promise });
  page.token = 'old-token';
  const logout = page.logout();
  await statusTick();
  await page.authenticated(auth('b'));
  clearing.resolve();
  await logout;
  assert.equal(page.token, 'b-token');
  assert.equal(page.cacheScope, 'scope-a'); // fixture info, separate from the auth token
  assert.ok(calls.some((item) => item[0] === 'logout' && item[1] === 'old-token'));
  assert.doesNotMatch(page.cacheNotice, /已退出/);
});

test('a cancelled old login cannot reopen the app after logout', async () => {
  const pending = deferred();
  const { page } = setup({ activate: () => pending.promise });
  const login = page.authenticated(auth());
  await page.logout();
  pending.resolve();
  await login;
  assert.equal(page.token, '');
  assert.equal(page.localHistoryCount, 0);
});


test('nested routes return to their actual origin while each main tab retains its stack', () => {
  const { page } = setup();
  page.selectTab(8);
  page.selectTab(3);
  page.selectTab(4);
  assert.equal(page.activeTab, 4);
  assert.equal(page.onBackPress(), true);
  assert.equal(page.activeTab, 3);
  page.selectTab(1);
  page.selectTab(5);
  page.selectTab(8);
  assert.equal(page.activeTab, 3);
  page.goBack();
  assert.equal(page.activeTab, 8);
  page.selectTab(1);
  assert.equal(page.activeTab, 5);
  page.goBack();
  assert.equal(page.activeTab, 1);
});

test('external exact-ID details return to the source stack without guessing by title', () => {
  const { page } = setup();
  page.selectTab(8);page.selectTab(7);
  page.openPlanDetails('task-exact', '');
  assert.equal(page.activeTab, 2);
  assert.equal(page.focusTaskId, 'task-exact');
  assert.equal(page.focusPlanId, '');
  page.closePlanFocus();
  assert.equal(page.activeTab, 7);
  assert.equal(page.focusTaskId, '');
  page.goBack();
  assert.equal(page.activeTab, 8);
  const revision = page.focusRevision;
  page.openPlanDetails('task', 'plan');
  assert.equal(page.focusRevision, revision, 'ambiguous targets are rejected');
  page.openPlanDetails('', 'plan-exact');
  assert.equal(page.focusPlanId, 'plan-exact');
});

test('explicit plan links select a requested view while ordinary tab switching preserves it', () => {
  const { page } = setup();
  page.openPlanList('tasks');
  assert.equal(page.planRequestedView, 'tasks');
  const revision = page.planViewRevision;
  page.selectTab(0);page.selectTab(2);
  assert.equal(page.planViewRevision, revision);
  page.openPlanList('agenda');
  assert.equal(page.planRequestedView, 'agenda');
  assert.equal(page.planViewRevision, revision + 1);
});

test('explicit Agent suggestion reaches its composer instead of a retained history/settings page', () => {
  const { page } = setup();
  page.selectTab(1);page.selectTab(5);page.selectTab(8);
  page.openAgentWithPrompt('帮我安排复习');
  assert.equal(page.activeTab, 1);
  assert.equal(page.agentPrompt, '帮我安排复习');
  assert.equal(page.promptRevision, 1);
});

test('system back delegates a plan detail to its own close path and auth resets all navigation', () => {
  const { page } = setup();
  page.openPlanDetails('', 'plan-exact');
  page.planInnerActive = true;
  assert.equal(page.onBackPress(), true);
  assert.equal(page.planBackRevision, 1);
  assert.equal(page.focusPlanId, 'plan-exact', 'detail owns the actual close and source restoration');
  page.resetNavigation();
  assert.equal(page.activeTab, 0);
  assert.equal(page.planInnerActive, false);
  assert.equal(page.focusPlanId, '');
  assert.equal(page.focusTaskId, '');
  assert.equal(page.focusOrigin, null);
  assert.deepEqual(page.navigation, navigation.createNavigation());
});

const draftKey = { kind: 'assistant', ownerId: 'local-session' };
const draftText = (text = '未发送的文字') => ({ text, sessionId: 'local-session', anchorDate: '2026-10-18', timezone: 'Asia/Shanghai' });
const settle = () => new Promise(resolve => setImmediate(resolve));

test('drafts use their own authenticated lease when history storage is unavailable', async () => {
  const h = setup({ activate: async () => { throw Error('history disk'); } });
  await h.page.authenticated(auth('a'));
  assert.equal(h.page.cacheScope, '');
  assert.equal(h.drafts.valid(h.page.draftLease), true);
  h.drafts.stage(h.page.draftLease, draftKey, draftText());
  await h.drafts.flush(h.page.draftLease);
  assert.equal(h.drafts.read(h.page.draftLease, draftKey).payload.text, '未发送的文字');
});

test('bad draft file does not block online login or expose content and explicit reset reactivates the account', async () => {
  const h = setup({}, { text: '{broken' });
  await h.page.authenticated(auth('a'));
  assert.equal(h.page.token, 'a-token');
  assert.equal(h.page.draftLease, null);
  assert.equal(h.page.draftCleanupNeeded, true);
  assert.equal(h.draftDriver.text, '{broken');
  await h.page.clearLocalDrafts();
  assert.equal(h.page.draftClearConfirm, true);
  assert.equal(h.draftDriver.text, '{broken');
  await h.page.clearLocalDrafts();
  assert.equal(h.page.draftCleanupNeeded, false);
  assert.equal(h.drafts.valid(h.page.draftLease), true);
});

test('foreground loss flushes pending draft without altering account or remote history', async () => {
  const h = setup(); await h.page.authenticated(auth());
  h.drafts.stage(h.page.draftLease, draftKey, draftText('后台前最后输入'));
  assert.equal(h.drafts.status(h.page.draftLease).phase, 'pending');
  h.page.voiceForeground = false; h.page.reminderActivityChanged(); await settle();
  assert.equal(h.drafts.status(h.page.draftLease).phase, 'saved');
  assert.equal(JSON.parse(h.draftDriver.text).records[0].payload.text, '后台前最后输入');
  assert.equal(h.page.token, 'a-token');
  assert.equal(h.calls.some(call => call[0] === 'clear'), false);
});

test('logout invalidates draft lease synchronously and cleanup failure remains visible without restoring login', async () => {
  const pending = deferred();
  const h = setup({}, { remove: () => pending.promise }); await h.page.authenticated(auth());
  const lease = h.page.draftLease;
  h.drafts.stage(lease, draftKey, draftText()); await h.drafts.flush(lease);
  const logout = h.page.logout();
  assert.equal(h.page.sessionLogoutBusy, true);
  await statusTick();
  assert.equal(h.page.token, ''); assert.equal(h.page.draftLease, null);
  assert.equal(h.drafts.valid(lease), false);
  assert.throws(() => h.drafts.stage(lease, draftKey, draftText('迟到输入')));
  pending.reject(Error('private filesystem message')); await logout;
  assert.equal(h.page.draftCleanupNeeded, true);
  assert.match(h.page.draftNotice, /尚未清理/);
  assert.doesNotMatch(h.page.draftNotice, /private/);
});

test('draft cleanup from old logout cannot clear or alter a later account activation', async () => {
  const pending = deferred();
  const h = setup({}, { async remove() { await pending.promise; this.text = undefined; } });
  await h.page.authenticated(auth('a')); const old = h.page.draftLease;
  h.drafts.stage(old, draftKey, draftText('A')); await h.drafts.flush(old);
  const logout = h.page.logout();
  const login = h.page.authenticated(auth('b'));
  pending.resolve(); await logout; await login;
  assert.equal(h.page.token, 'b-token');
  assert.equal(h.drafts.valid(h.page.draftLease), true);
  assert.equal(h.drafts.list(h.page.draftLease, 'assistant').length, 0);
  h.drafts.stage(h.page.draftLease, draftKey, draftText('B')); await h.drafts.flush(h.page.draftLease);
  assert.equal(JSON.parse(h.draftDriver.text).records[0].payload.text, 'B');
  assert.doesNotMatch(h.page.draftNotice, /退出/);
});

test('changing service during sign-in invalidates its draft lease and never opens old authenticated pages', async () => {
  const pending = deferred();
  const h = setup({ activate: () => pending.promise });
  const login = h.page.authenticated(auth('a'));
  await settle(); const lease = h.page.draftLease;
  assert.equal(h.drafts.valid(lease), true);
  h.page.baseUrl = 'https://different-service.invalid';
  h.page.reminderAccountChanged();
  assert.equal(h.drafts.valid(lease), false);
  pending.resolve(); await login; await settle();
  assert.equal(h.page.token, ''); assert.equal(h.page.draftLease, null);
});

test('ordinary history clear does not clear drafts and explicit draft clear blocks unresolved operations', async () => {
  const h = setup(); await h.page.authenticated(auth());
  const lease = h.page.draftLease; const ticket = h.drafts.stage(lease, draftKey, draftText());
  await h.drafts.flush(lease); await h.page.clearLocalHistory();
  assert.equal(h.drafts.read(lease, draftKey).payload.text, '未发送的文字');
  await h.drafts.beginOperation(lease, { kind: 'run', id: 'run-1', draftKind: 'assistant', ownerId: draftKey.ownerId, localRevision: ticket.localRevision });
  await h.page.clearLocalDrafts();
  assert.equal(h.page.draftClearConfirm, false);
  assert.match(h.page.draftNotice, /待核对/);
  assert.equal(h.drafts.operations(lease).length, 1);
});

test('history continuation carries an exact session intent while Agent owns running-work checks', async () => {
  const {page,draftReady}=setup();await draftReady;page.token='token-a';
  page.continueAgentSession('session-a');assert.equal(page.requestedSessionId,'session-a');assert.equal(page.sessionResumeRevision,1);assert.equal(page.activeTab,1);
  page.historyDeleteBusy=true;page.continueAgentSession('session-b');assert.equal(page.requestedSessionId,'session-a');page.historyDeleteBusy=false;
  page.agentChatBusy=true;page.continueAgentSession('session-b');assert.equal(page.requestedSessionId,'session-b');assert.equal(page.sessionResumeRevision,2);
  page.resetNavigation();assert.equal(page.requestedSessionId,'');assert.equal(page.sessionResumeRevision,3);
  page.token='';page.continueAgentSession('session-b');assert.equal(page.requestedSessionId,'');
});
