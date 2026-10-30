import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';

const read = name => readFileSync(new URL(`../../entry/src/main/ets/utils/${name}.ets`, import.meta.url), 'utf8');
const persistence = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(read('SessionPersistence'))).toString('base64')}`);
const source = read('SessionCoordinator').replace(/^import .*;\r?\n/gm, '').replace(/^export /gm, '');
const coordinator = new Function('SessionStorageError', 'normalizeServiceBaseUrl',
  stripTypeScriptTypes(source) + '\nreturn { SessionCoordinator, verifiedSessionUser };')(
    persistence.SessionStorageError, persistence.normalizeServiceBaseUrl);
export const sessionHelpers = { ...persistence, ...coordinator };

// Existing page-controller harnesses erase native imports. Inject the real pure
// logic and only replace the Asset/filesystem boundary; no user vault is read.
globalThis.normalizeServiceBaseUrl = persistence.normalizeServiceBaseUrl;
globalThis.SessionStorageError = persistence.SessionStorageError;
globalThis.SessionSourceChangedError = persistence.SessionSourceChangedError;
globalThis.SessionCoordinator = coordinator.SessionCoordinator;
globalThis.localSession = { async read() { return null; }, async save() {}, async clear() {} };
globalThis.initializeLocalSession = async () => {};
