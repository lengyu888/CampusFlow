import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';

// Execute real entry/auth controller methods with synthetic storage and HTTP.
// This does not emulate ArkUI lifecycle scheduling or native file APIs.
const navigationSource = readFileSync(new URL('../entry/src/main/ets/utils/AppNavigation.ets', import.meta.url), 'utf8');
const navigation = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(navigationSource)).toString('base64')}`);
const navNames = ['createNavigation', 'currentRoute', 'selectRoot', 'openSecondary', 'backNavigation', 'isRootRoute', 'hasBack'];
const source = readFileSync(new URL('../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
const controller = source.slice(0, source.indexOf('\n  @Builder'))
  .replace(/^import [^\n]+;\r?\n/gm, '')
  .replace(/^@(Entry|Component)\r?\n/gm, '')
  .replace(/@(State|Prop)\s+|@StorageLink\('[^']+'\)\s*/g, '')
  .replace('struct Index', 'class Index') + '\n}\n';
const create = new Function('localHistory', 'historyScope', 'CampusFlowApi', 'AppStorage', 'AppTheme', 'Curve', ...navNames,
  stripTypeScriptTypes(controller) + '\nreturn Index;');
const auth = (name = 'a') => ({ access_token: `${name}-token`, user: { user_id: name, display_name: name } });
const deferred = () => {
  let resolve, reject;
  const promise = new Promise((ok, fail) => { resolve = ok; reject = fail; });
  return { promise, resolve, reject };
};
function setup(overrides = {}) {
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
  const Index = create(store, (base, id) => `${base}|${id}`, Api, { setOrCreate: () => {} },
    { motion: () => 0 }, { EaseOut: 0 }, ...navNames.map(name => navigation[name]));
  const page = new Index();
  page.getUIContext = () => ({ animateTo: (_options, update) => update() });
  return { page, calls, store };
}

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

test('logout immediately closes online/offline access before slow clearing and remote revocation', async () => {
  const clearing = deferred();
  const { page, calls } = setup({ clear: () => clearing.promise });
  page.token = 'old-token'; page.cacheScope = 'old-scope'; page.localHistoryCount = 2;
  page.offlineHistory = true; page.agentChatBusy = true;
  const signingOut = page.logout();
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
