import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
const source = readFileSync(new URL('../../entry/src/main/ets/utils/DraftStore.ets', import.meta.url), 'utf8');
export const { DraftStore } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source)).toString('base64')}`);
export class DraftMemoryDriver {
  text; failWrite = false; failRemove = false; beforeWrite = null;
  async read() { return this.text; }
  async write(value) { if (this.beforeWrite) await this.beforeWrite(); if (this.failWrite) throw Error('disk'); this.text = value; }
  async remove() { if (this.failRemove) throw Error('disk'); this.text = undefined; }
}
export async function draftFixture(driver = new DraftMemoryDriver(), scope = 'https://example.test|account-a') {
  const store = new DraftStore(driver, { now: () => Date.now(), set: () => 1, clear() {} });
  await store.initialize();
  const lease = await store.activate(scope);
  return { store, lease, driver };
}
