import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';
import { createThemeFixture } from './helpers/theme-fixture.mjs';

const read = file => readFileSync(new URL(`../entry/src/main/ets/${file}.ets`, import.meta.url), 'utf8');
const tick = () => new Promise(resolve => setImmediate(resolve));

function startup(seed = { campusflowThemeId: 'ios-blue' }) {
  let uiReady = false;
  const theme = createThemeFixture(seed, { canPersist: () => uiReady });
  const source = read('entryability/EntryAbility').replace(/^import [^\n]+;\r?\n/gm, '').replace('export default class', 'class');
  const EntryAbility = new Function('UIAbility', 'initializeAppTheme', 'initializeLocalFocus', 'initializeLocalDrafts',
    'initializeLocalHistory', 'AppStorage', 'console', stripTypeScriptTypes(source) + '\nreturn EntryAbility;')(
      class {}, theme.initializeAppTheme, async () => {}, async () => {}, async () => {}, theme.AppStorage,
      { error() {} });
  const ability = new EntryAbility(); ability.context = { filesDir: '/test-private' };
  const loads = [];
  const windowStage = { loadContent(path, callback) { loads.push({ path, callback }); } };
  return {
    ability, theme, loads,
    async createStage() { ability.onWindowStageCreate(windowStage); await tick(); },
    finish(code = 0) {
      const load = loads.at(-1); assert.ok(load && load.path === 'pages/Index');
      assert.equal(typeof load.callback, 'function', 'native loadContent success callback is the persistence readiness boundary');
      uiReady = code === 0; load.callback({ code, message: code ? 'load failed' : '' });
    }
  };
}

test('actual EntryAbility cold start leaves persisted theme untouched until loadContent success restores blue', async () => {
  const { ability, theme, createStage, finish } = startup();
  ability.onCreate({}, {});
  assert.equal(theme.values.has(theme.THEME_ID_KEY), false, 'onCreate must not create a default ID before native persistence is available');
  assert.equal(theme.persistenceAttempts.length, 0);
  await createStage();
  assert.equal(theme.values.has(theme.THEME_ID_KEY), false, 'waiting for the load callback must not consume or overwrite the disk preference');
  assert.equal(theme.persisted.get(theme.THEME_ID_KEY), 'ios-blue');
  finish();
  assert.equal(theme.AppStorage.get(theme.THEME_ID_KEY), 'ios-blue');
  assert.equal(theme.AppStorage.get(theme.THEME_PALETTE_KEY).id, 'ios-blue');
  assert.deepEqual(theme.persistenceAttempts, [{ key: theme.THEME_ID_KEY, ready: true }]);
  assert.equal(theme.persisted.get(theme.THEME_ID_KEY), 'ios-blue');
});

test('failed load does not lock theme initialization or overwrite disk; a later successful stage restores blue', async () => {
  const { ability, theme, createStage, finish } = startup(); ability.onCreate({}, {});
  await createStage(); finish(1001);
  assert.equal(theme.values.has(theme.THEME_ID_KEY), false);
  assert.equal(theme.persistenceAttempts.length, 0);
  assert.equal(theme.persisted.get(theme.THEME_ID_KEY), 'ios-blue');
  await createStage(); finish();
  assert.equal(theme.AppStorage.get(theme.THEME_PALETTE_KEY).id, 'ios-blue');
  assert.equal(theme.persistenceAttempts.length, 1);
});

test('first install defaults only after UI success and later theme selection still persists the small preference', async () => {
  const { ability, theme, createStage, finish } = startup({}); ability.onCreate({}, {});
  assert.equal(theme.values.has(theme.THEME_ID_KEY), false);
  await createStage(); finish();
  assert.equal(theme.AppStorage.get(theme.THEME_PALETTE_KEY).id, 'paper-green');
  theme.selectAppTheme('ios-blue');
  assert.equal(theme.persisted.get(theme.THEME_ID_KEY), 'ios-blue');
  assert.equal(theme.AppStorage.get(theme.THEME_PALETTE_KEY).accent, '#007AFF');
  theme.selectAppTheme('paper-green');
  assert.equal(theme.persisted.get(theme.THEME_ID_KEY), 'paper-green');
  assert.deepEqual([...theme.persisted.keys()], [theme.THEME_ID_KEY]);
});

test('pages cannot reintroduce early theme initialization before native content-load completion', () => {
  for (const file of ['pages/Index', 'pages/ProfilePage']) {
    assert.equal(/\binitializeAppTheme\b/.test(read(file)), false, `${file} must rely on the successful UIAbility load callback`);
  }
});

// Runs real production EntryAbility and ThemePalette code with a controllable
// documented native readiness boundary. It is not the native storage runtime or
// proof of Phone cold-start persistence; real restart testing remains required.
