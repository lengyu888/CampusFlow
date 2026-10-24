import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';

// Preserve each existing harness's compiler behavior, erasing only the newly introduced
// native decorator that cannot be parsed as JavaScript by Node's type-only stripper.
export function stripThemeTypeScriptTypes(source, options) {
  return stripTypeScriptTypes(source.replace(/@StorageLink\('campusflowThemePalette'\)\s*/g, ''), options);
}

// The real production palette code, with an explicit, controllable native-storage boundary.
export function createThemeFixture(seed = {}, options = {}) {
  const values = new Map(), persisted = new Map(Object.entries(seed)), registered = new Set(), listeners = new Set();
  const writes = [], persistenceAttempts = [];
  const AppStorage = {
    get(key) { return values.get(key); },
    setOrCreate(key, value) {
      values.set(key, value); writes.push({ key, value });
      if (registered.has(key)) persisted.set(key, value);
      for (const listener of listeners) listener(key, value);
    }
  };
  const PersistentStorage = {
    persistProp(key, initial) {
      const ready = options.canPersist ? options.canPersist() : true;
      persistenceAttempts.push({ key, ready });
      // Native PersistentStorage requires a successfully initialized UI instance.
      // This controllable boundary deliberately does not assume every startup
      // call can read disk (unlike the original always-ready test adapter).
      if (!ready) return;
      registered.add(key);
      if (!values.has(key)) values.set(key, persisted.has(key) ? persisted.get(key) : initial);
      persisted.set(key, values.get(key));
    }
  };
  const read = file => readFileSync(new URL(`../../entry/src/main/ets/theme/${file}.ets`, import.meta.url), 'utf8');
  const clean = source => stripTypeScriptTypes(source.replace(/^import[^\n]+\r?\n/gm, '').replace(/^export /gm, ''));
  const AppTheme = new Function('AppStorage', clean(read('AppTheme')) + '\nreturn AppTheme;')(AppStorage);
  const source = read('ThemePalette');
  const names = [...source.matchAll(/^export\s+(?:function|const)\s+(\w+)/gm)].map(match => match[1]);
  const api = new Function('AppTheme', 'AppStorage', 'PersistentStorage', clean(source) + `\nreturn {${names.join(',')}};`)(AppTheme, AppStorage, PersistentStorage);
  return { ...api, AppTheme, AppStorage, PersistentStorage, values, persisted, writes, persistenceAttempts,
    subscribe(listener) { listeners.add(listener); return () => listeners.delete(listener); } };
}

// Older controller-only harnesses intentionally erase imports/decorators. Supplying the new
// imported functions explicitly keeps those harnesses executable without weakening assertions.
const controllerThemes = createThemeFixture();
globalThis.themePalette = controllerThemes.themePalette;
globalThis.initializeAppTheme = controllerThemes.initializeAppTheme;
globalThis.selectAppTheme = controllerThemes.selectAppTheme;
