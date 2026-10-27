import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';

const read = path => readFileSync(new URL(`../entry/src/main/ets/${path}`, import.meta.url), 'utf8');
const navigation = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(read('utils/AppNavigation.ets'))).toString('base64')}`);
const source = read('pages/Index.ets');
const method = source.slice(source.indexOf('  private guideDestination('), source.indexOf('  private continueAgentSession('));
assert.ok(method.startsWith('  private guideDestination('));
const Clock = class extends Date { static now() { return Date.parse('2026-10-25T17:00:00Z'); } };
const Probe = new Function('backNavigation', 'selectRoot', 'Date',
  stripTypeScriptTypes(`class Probe { ${method} }`) + '\nreturn Probe;')(navigation.backNavigation, navigation.selectRoot, Clock);

function fixture(root = 0, caller = null) {
  const page = new Probe(); const calls = [];
  page.navigation = navigation.selectRoot(navigation.createNavigation(), root);
  if (caller !== null) page.navigation = navigation.openSecondary(page.navigation, caller);
  page.navigation = navigation.openSecondary(page.navigation, 10);
  page.activeTab = 10; page.token = 'test-session'; page.voiceForeground = true;
  page.applyNavigation = next => { page.navigation = next; page.activeTab = navigation.currentRoute(next); };
  page.selectTab = route => page.applyNavigation(navigation.openSecondary(page.navigation, route));
  page.openPlanList = view => { calls.push(['plan', view]); page.applyNavigation(navigation.selectRoot(page.navigation, 2, true)); };
  page.openFocus = () => calls.push(['focus']);
  page.openReview = (period, anchor) => calls.push(['review', period, anchor]);
  return { page, calls };
}

test('guide opens once and Back restores each exact caller without mutating other root stacks', () => {
  for (const [root, caller] of [[0, null], [1, null], [8, 4]]) {
    const { page } = fixture(root, caller);
    assert.equal(navigation.currentRoute(page.navigation), 10);
    assert.deepEqual(navigation.openSecondary(page.navigation, 10), page.navigation);
    const back = navigation.backNavigation(page.navigation);
    assert.equal(navigation.currentRoute(back), caller ?? root);
    assert.equal(back.root, root);
  }
});

test('guide service links remove the guide frame while preserving the caller return path', () => {
  for (const [destination, route] of [['profile', 4], ['skills', 3], ['services', 7], ['timetable', 9]]) {
    const { page, calls } = fixture(8, 4);
    page.guideDestination(destination);
    assert.equal(navigation.currentRoute(page.navigation), route);
    assert.ok(page.navigation.stacks.every(stack => !stack.routes.includes(10)));
    assert.equal(page.navigation.root, 8);
    if (route !== 4) assert.equal(navigation.currentRoute(navigation.backNavigation(page.navigation)), 4);
    assert.deepEqual(calls, []);
  }
});

test('guide root links target today, task list or assistant without leaving hidden guide frames', () => {
  for (const [destination, root] of [['today', 0], ['tasks', 2], ['agent', 1]]) {
    const { page, calls } = fixture(8, 4);
    page.guideDestination(destination);
    assert.equal(navigation.currentRoute(page.navigation), root);
    assert.ok(page.navigation.stacks.every(stack => !stack.routes.includes(10)));
    assert.deepEqual(calls, destination === 'tasks' ? [['plan', 'tasks']] : []);
  }
});

test('guide focus is a record entry and review uses the current Shanghai date without creating anything', () => {
  const focus = fixture(); focus.page.guideDestination('focus');
  assert.deepEqual(focus.calls, [['focus']]);
  assert.equal(focus.page.activeTab, 0);
  const review = fixture(); review.page.guideDestination('review');
  assert.deepEqual(review.calls, [['review', 'day', '2026-10-26']]);
  assert.equal(review.page.activeTab, 0);
});

test('stale, background, logged-out and unsupported guide callbacks have no effect', () => {
  for (const patch of [{ activeTab: 0 }, { token: '' }, { voiceForeground: false }, {}]) {
    const { page, calls } = fixture(); Object.assign(page, patch);
    const before = JSON.stringify(page.navigation);
    page.guideDestination(Object.keys(patch).length ? 'tasks' : 'delete-account');
    assert.equal(JSON.stringify(page.navigation), before);
    assert.deepEqual(calls, []);
  }
});
