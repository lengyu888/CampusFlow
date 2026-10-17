import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';

const helperSource = readFileSync(new URL('../entry/src/main/ets/utils/AgentFeedback.ets', import.meta.url), 'utf8')
  .replace(/^import .*;\r?\n/gm, '');
const { CampusFlowRequestError } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(helperSource)).toString('base64')}`);
function component(name, api) {
  const source = readFileSync(new URL(`../entry/src/main/ets/pages/${name}.ets`, import.meta.url), 'utf8');
  const boundary = source.includes('\n  @Builder') ? source.indexOf('\n  @Builder') : source.indexOf('\n  build()');
  const controller = source.slice(0, boundary).replace(/^import[\s\S]*?;\r?\n/gm, '')
    .replace(/^@Component\r?\n/m, '').replace(/@(Prop|State)\s+|@(Watch|StorageLink)\('[^']+'\)\s*/g, '')
    .replace(`export struct ${name}`, `class ${name}`) + '\n}\n';
  const Page = new Function('CampusFlowApi', 'CampusFlowRequestError', 'AppTheme', 'Curve',
    stripTypeScriptTypes(controller) + `\nreturn ${name};`)(api, CampusFlowRequestError, { motion: n => n }, { EaseOut: 'ease' });
  const page = new Page();
  page.baseUrl = 'http://fixture.invalid'; page.token = 'fixture-token';
  page.getUIContext = () => ({ animateTo: (_options, callback) => callback() });
  return page;
}
function deferred() { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; }
const settle = () => new Promise(resolve => setImmediate(resolve));
const skill = (id = 'planner') => ({ skill_id: id, name: '课表规划', description: '安排课程之外的复习', category: '学习',
  version: '1.0', author: 'CampusFlow', official: true, permissions: [{ code: 'timetable.read', label: '读取课表', description: '用于查找空闲', access: 'read' }],
  capabilities: [], installed: false, enabled: false, installed_version: null, update_available: false });
function skillsFixture(handlers = {}) {
  const calls = [];
  class Api {
    skills() { calls.push(['read']); return handlers.read?.() ?? Promise.resolve([skill()]); }
    installSkill(value) { calls.push(['install', value]); return handlers.install(value); }
    setSkillEnabled(id, value) { calls.push(['toggle', id, value]); return handlers.toggle(id, value); }
  }
  return { page: component('SkillsPage', Api), calls };
}
test('capability permissions must be expanded before installation; duplicate submission sends once', async () => {
  const response = deferred(); const f = skillsFixture({ install: () => response.promise });
  f.page.skills = [skill()];
  await f.page.install(f.page.skills[0]); assert.equal(f.calls.length, 0);
  f.page.toggleDetails('planner'); const saving = f.page.install(f.page.skills[0]);
  await f.page.install(f.page.skills[0]); assert.equal(f.calls.length, 1);
  assert.equal(f.page.skills[0].installed, false);
  response.resolve({ ...skill(), installed: true, enabled: true }); await saving;
  assert.equal(f.page.skills[0].installed, true); assert.match(f.page.message, /已安装/);
});
test('capability activation requires permission preview and exact returned identity/state', async () => {
  const f = skillsFixture({ toggle: async () => ({ ...skill('wrong'), installed: true, enabled: true }) });
  f.page.skills = [{ ...skill(), installed: true }];
  await f.page.toggle(f.page.skills[0]); assert.equal(f.calls.length, 0);
  f.page.toggleDetails('planner'); await f.page.toggle(f.page.skills[0]);
  assert.equal(f.page.skills[0].enabled, false); assert.match(f.page.errorText, /不一致/);
  await f.page.toggle(f.page.skills[0]); assert.equal(f.calls.length, 1, 'must refresh before another write');
});
test('capability failure is distinct from empty success and explicit refresh unlocks retry', async () => {
  let fails = true;
  const f = skillsFixture({ read: async () => { if (fails) throw new Error('PRIVATE_TOKEN'); return []; } });
  await f.page.reload(); assert.equal(f.page.loaded, false); assert.notEqual(f.page.errorText, '');
  assert.doesNotMatch(f.page.errorText, /PRIVATE_TOKEN/);
  fails = false; await f.page.reload(); assert.equal(f.page.loaded, true); assert.deepEqual(f.page.skills, []); assert.equal(f.page.errorText, '');
});
test('hidden capability mutation stays locked until it settles, then returns through a fresh status read', async () => {
  const response = deferred(); const f = skillsFixture({ install: () => response.promise });
  f.page.skills = [skill()]; f.page.toggleDetails('planner'); const saving = f.page.install(f.page.skills[0]);
  f.page.active = false; f.page.activeChanged(); f.page.active = true; f.page.activeChanged();
  await f.page.install(f.page.skills[0]); assert.equal(f.calls.length, 1);
  response.resolve({ ...skill(), installed: true }); await saving; await settle();
  assert.deepEqual(f.calls.map(call => call[0]), ['install', 'read']);
  assert.equal(f.page.skills[0].installed, false, 'late mutation result is not applied over the fresh read');
});
const user = () => ({ user_id: 'u1', display_name: '已保存昵称', email: 'student@example.com', role: 'student',
  school: '已保存学校', campus: '已保存校区', semester: '已保存学期', api_key_hint: '••旧', onboarding_completed: true });
function profileFixture(handlers = {}) {
  const calls = [], updated = [];
  class Api {
    updateSettings(...args) { calls.push(['settings', ...args]); return handlers.settings?.(...args) ?? Promise.resolve(user()); }
    me() { calls.push(['me']); return handlers.me?.() ?? Promise.resolve(user()); }
    subscriptionStatus() { calls.push(['subscriptionStatus']); return Promise.resolve({ configured: false }); }
    hduHelpStatus() { calls.push(['hduHelpStatus']); return Promise.resolve({ configured: false, resources: [] }); }
    connectHduHelpPat(token) { calls.push(['pat', token]); return handlers.pat(token); }
    disconnectHduHelp() { calls.push(['disconnect']); return handlers.disconnect(); }
    hduHelpData() { calls.push(['data']); return handlers.data(); }
  }
  const page = component('ProfilePage', Api); page.user = user(); page.hduHelpLoaded = true; page.onUserChanged = value => updated.push(value);
  return { page, calls, updated };
}
test('profile groups preserve all unsaved inputs; account save never includes an unsubmitted model key', async () => {
  const f = profileFixture(); f.page.displayName = '未保存昵称'; f.page.school = '未保存学校'; f.page.newApiKey = 'PRIVATE_KEY';
  for (const group of ['account', 'model', 'connections', 'preferences']) { f.page.toggleGroup(group); f.page.toggleGroup(group); }
  await f.page.saveProfile();
  assert.equal(f.calls[0][1], '未保存昵称'); assert.equal(f.calls[0].at(-1), ''); assert.equal(f.page.newApiKey, 'PRIVATE_KEY');
});
test('model save uses persisted profile and does not submit account drafts', async () => {
  const f = profileFixture(); f.page.displayName = '未保存昵称'; f.page.school = '未保存学校'; f.page.newApiKey = 'PRIVATE_KEY';
  await f.page.saveModel();
  assert.deepEqual(f.calls[0], ['settings', '已保存昵称', '已保存学校', '已保存校区', '已保存学期', 'PRIVATE_KEY']);
  assert.equal(f.page.displayName, '未保存昵称'); assert.equal(f.page.newApiKey, ''); assert.equal(f.updated.length, 1);
});
test('profile writes serialize across groups, and leaving does not allow another write before the first settles', async () => {
  const response = deferred(); const f = profileFixture({ settings: () => response.promise });
  f.page.displayName = '草稿'; f.page.newApiKey = 'PRIVATE_KEY'; const saving = f.page.saveProfile(); await f.page.saveModel();
  assert.equal(f.calls.length, 1); f.page.active = false; f.page.activeChanged(); f.page.active = true; f.page.activeChanged();
  await f.page.saveModel(); assert.equal(f.calls.filter(call => call[0] === 'settings').length, 1);
  response.resolve(user()); await saving; assert.equal(f.updated.length, 0); assert.equal(f.page.settingsNeedsCheck, true);
  await f.page.checkSettings(); assert.equal(f.page.displayName, '草稿'); assert.equal(f.page.newApiKey, 'PRIVATE_KEY');
  assert.equal(f.page.settingsNeedsCheck, false);
});
test('profile failed writes retain drafts and safe errors until an explicit status check', async () => {
  const f = profileFixture({ settings: async () => { throw new Error('PRIVATE_KEY https://private.invalid'); } });
  f.page.newApiKey = 'PRIVATE_KEY'; await f.page.saveModel();
  assert.equal(f.page.newApiKey, 'PRIVATE_KEY'); assert.equal(f.page.settingsNeedsCheck, true);
  assert.doesNotMatch(f.page.modelMessage, /PRIVATE_KEY|private.invalid/);
  await f.page.saveModel(); assert.equal(f.calls.length, 1); await f.page.checkSettings(); assert.equal(f.page.settingsNeedsCheck, false);
});
test('campus token write keeps input on failure and suppresses duplicate requests', async () => {
  const response = deferred(); const f = profileFixture({ pat: () => response.promise });
  f.page.hduHelpPat = 'PRIVATE_PAT'; const saving = f.page.connectHduHelpPat(); await f.page.connectHduHelpPat();
  assert.equal(f.calls.length, 1); response.reject(new Error('PRIVATE_PAT')); await saving;
  assert.equal(f.page.hduHelpPat, 'PRIVATE_PAT'); assert.doesNotMatch(f.page.hduHelpMessage, /PRIVATE_PAT/);
});
test('disconnect requires explicit second confirmation and clears previously displayed campus data only on success', async () => {
  const f = profileFixture({ disconnect: async () => {} }); f.page.hduHelp.configured = true;
  f.page.hduHelpSections = [{ resource: 'identity' }]; await f.page.disconnectHduHelp();
  assert.equal(f.calls.length, 0); assert.equal(f.page.confirmDisconnect, true);
  await f.page.disconnectHduHelp(); assert.equal(f.calls.length, 1); assert.deepEqual(f.page.hduHelpSections, []);
});
test('old campus archive response cannot restore data after disconnect', async () => {
  const response = deferred(); const f = profileFixture({ data: () => response.promise, disconnect: async () => {} });
  const reading = f.page.openHduHelpData(); await f.page.disconnectHduHelp(); await f.page.disconnectHduHelp();
  response.resolve({ status: { configured: true }, sections: [{ resource: 'identity' }], suggested_prompts: [], sync_errors: {} });
  await reading; assert.equal(f.page.hduHelp.configured, false); assert.deepEqual(f.page.hduHelpSections, []);
});
test('login serialization and teardown guard do not invoke authentication for a late response', async () => {
  const response = deferred(); const calls = [], authenticated = [];
  const page = component('LoginPage', class { login(...args) { calls.push(args); return response.promise; } });
  page.email = 'student@example.com'; page.password = 'password-fixture'; page.onAuthenticated = async value => { authenticated.push(value); };
  const logging = page.submit(); await page.submit(); assert.equal(calls.length, 1); page.aboutToDisappear();
  response.resolve({ token: 'old-token' }); await logging; assert.deepEqual(authenticated, []);
});
test('login failure keeps credential drafts without displaying raw server errors', async () => {
  const page = component('LoginPage', class { async login() { throw new Error('PRIVATE_PASSWORD'); } });
  page.email = 'student@example.com'; page.password = 'PRIVATE_PASSWORD'; await page.submit();
  assert.equal(page.password, 'PRIVATE_PASSWORD'); assert.doesNotMatch(page.errorText, /PRIVATE_PASSWORD/); assert.equal(page.loading, false);
});
test('local cleanup needs confirmation and cannot run twice while pending', async () => {
  const response = deferred(); const page = component('LoginPage', class {}); let count = 0;
  page.onClearLocalHistory = () => { count++; return response.promise; };
  await page.clearLocalHistory(); assert.equal(count, 0); page.confirmCleanup = true; const clearing = page.clearLocalHistory();
  await page.clearLocalHistory(); assert.equal(count, 1); response.resolve(); await clearing; assert.equal(page.confirmCleanup, false);
});
