import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';
import { createThemeFixture } from './helpers/theme-fixture.mjs';

test('palettes preserve main iOS blue and paper green, with every static token represented', () => {
  const fixture = createThemeFixture(), paper = fixture.themePalette('paper-green'), blue = fixture.themePalette('ios-blue');
  assert.equal(paper.accent, '#416454'); assert.equal(paper.canvas, '#F6F4EF');
  assert.equal(blue.accent, '#007AFF'); assert.equal(blue.canvas, '#F2F2F7'); assert.equal(blue.ink, '#1C1C1E');
  for (const key of Object.keys(fixture.AppTheme)) assert.ok(key in paper && key in blue, `missing token ${key}`);
  assert.equal(fixture.validThemeId('untrusted-id'), 'ios-blue');
  assert.equal(fixture.validThemeId('paper-green'), 'paper-green');
});

test('switch publishes fresh observable values to every subscriber and persists only the theme id', () => {
  const fixture = createThemeFixture({ campusflowThemeId: 'paper-green' }); fixture.initializeAppTheme();
  const business = { account: 'account-a', draft: '未保存草稿', route: 'planning', selectedDate: '2030-10-23' };
  fixture.AppStorage.setOrCreate('business', business);
  fixture.AppStorage.setOrCreate('reduceMotion', true);
  const received = [], receivedAgain = [];
  fixture.subscribe((key, value) => { if (key === fixture.THEME_PALETTE_KEY) received.push(value); });
  fixture.subscribe((key, value) => { if (key === fixture.THEME_PALETTE_KEY) receivedAgain.push(value); });
  const old = fixture.AppStorage.get(fixture.THEME_PALETTE_KEY);
  fixture.selectAppTheme('ios-blue');
  assert.equal(received.length, 1); assert.equal(receivedAgain.length, 1); assert.notEqual(received[0], old);
  assert.equal(received[0].accent, '#007AFF'); assert.equal(fixture.persisted.get(fixture.THEME_ID_KEY), 'ios-blue');
  assert.deepEqual([...fixture.persisted.keys()], [fixture.THEME_ID_KEY]);
  assert.equal(fixture.AppStorage.get('business'), business); assert.equal(fixture.AppTheme.motion(220), 0);
  fixture.selectAppTheme('ios-blue'); assert.equal(received.length, 1, 'same theme is a no-op');
  fixture.selectAppTheme('paper-green'); assert.equal(received.length, 2); assert.equal(received[1].accent, '#416454');
});

test('a fresh process restores a saved id before pages appear without persisting palette or account data', () => {
  const first = createThemeFixture(); first.initializeAppTheme(); first.selectAppTheme('ios-blue');
  const restarted = createThemeFixture(Object.fromEntries(first.persisted)); restarted.initializeAppTheme();
  assert.equal(restarted.AppStorage.get(restarted.THEME_PALETTE_KEY).id, 'ios-blue');
  assert.equal(restarted.AppStorage.get(restarted.THEME_PALETTE_KEY).canvas, '#F2F2F7');
  const invalid = createThemeFixture({ campusflowThemeId: 'deleted-theme' }); invalid.initializeAppTheme();
  assert.equal(invalid.AppStorage.get(invalid.THEME_PALETTE_KEY).id, 'ios-blue');
});

test('Profile theme action does not change account form, inner navigation, model input or user', () => {
  const fixture = createThemeFixture(); fixture.initializeAppTheme();
  const source = readFileSync(new URL('../entry/src/main/ets/pages/ProfilePage.ets', import.meta.url), 'utf8');
  const match = source.match(/private changeTheme\(id: AppThemeId\): void \{([\s\S]*?)\n  \}/);
  assert.ok(match);
  const change = new Function('selectAppTheme', stripTypeScriptTypes(`function change(id: string) {${match[1]}\n}`) + '\nreturn change;')(fixture.selectAppTheme);
  const state = { displayName: '未保存昵称', school: '未保存学校', newApiKey: 'synthetic-only', section: 'appearance',
    user: { user_id: 'account-a' }, draftNotice: '保持草稿' };
  const before = structuredClone(state); change.call(state, 'ios-blue'); assert.deepEqual(state, before);
  assert.equal(fixture.AppStorage.get(fixture.THEME_PALETTE_KEY).id, 'ios-blue');
});

test('every live color consumer observes palette, and Canvas explicitly redraws on theme changes', () => {
  for (const directory of ['pages', 'components']) {
    for (const file of readdirSync(new URL(`../entry/src/main/ets/${directory}/`, import.meta.url)).filter(name => name.endsWith('.ets'))) {
      const source = readFileSync(new URL(`../entry/src/main/ets/${directory}/${file}`, import.meta.url), 'utf8');
      assert.doesNotMatch(source, /AppTheme\.(?!motion\b)\w+/, `${file} must not read static colors`);
      if (source.includes('this.palette.')) assert.match(source, /@StorageLink\('campusflowThemePalette'\)/, `${file} must subscribe`);
    }
  }
  const icon = readFileSync(new URL('../entry/src/main/ets/components/AppIcon.ets', import.meta.url), 'utf8');
  const route = readFileSync(new URL('../entry/src/main/ets/components/RouteMap.ets', import.meta.url), 'utf8');
  assert.match(icon, /@Watch\('redraw'\) @StorageLink\('campusflowThemePalette'\)/);
  assert.match(route, /@Watch\('drawRoute'\) @StorageLink\('campusflowThemePalette'\)/);
});
