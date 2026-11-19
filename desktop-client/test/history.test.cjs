const { test } = require('node:test');
const assert = require('node:assert/strict');
const { mkdtemp, readFile, readdir, rm } = require('node:fs/promises');
const { tmpdir } = require('node:os');
const path = require('node:path');
const { createCipheriv, createDecipheriv, randomBytes } = require('node:crypto');
const { createOfflineHistory, prepareHistorySession } = require('../history.cjs');

const origin = 'http://example.test:8000';
const makeSession = (sessionId) => ({ sessionId, title: '机密测试话题', messages: [
  { role: 'user', content: '你好', private: 'must not be copied' },
  { role: 'assistant', content: '回复', tools: [{ label: '来源', state: 'success', summary: '已读取', raw: 'private-arguments',
    evidence: [{ label: '课表', note: '证明', url: 'https://example.test/' }] }] },
] });

async function fixture(t, available = true) {
  const directory = await mkdtemp(path.join(tmpdir(), 'campusflow-offline-history-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const key = randomBytes(32);
  const encryption = {
    available: () => available,
    encrypt(value) {
      const iv = randomBytes(16);
      const encrypt = createCipheriv('aes-256-ctr', key, iv);
      return Buffer.concat([iv, encrypt.update(value), encrypt.final()]);
    },
    decrypt(value) {
      const decrypt = createDecipheriv('aes-256-ctr', key, value.subarray(0, 16));
      return Buffer.concat([decrypt.update(value.subarray(16)), decrypt.final()]).toString('utf8');
    },
  };
  return { directory, encryption, history: createOfflineHistory(directory, encryption) };
}

test('cached history contains display-only fields and round trips across instances', async (t) => {
  const { directory, encryption, history } = await fixture(t);
  assert.equal(await history.useOwner(origin, 'owner'), true);
  assert.equal(await history.save(origin, 'owner', makeSession('one')), true);
  const otherInstance = createOfflineHistory(directory, encryption);
  const listing = await otherInstance.list(origin);
  assert.deepEqual(listing.sessions.map(item => Object.keys(item)), [['sessionId', 'title', 'updatedAt']]);
  const session = await otherInstance.get(origin, 'owner', 'one');
  assert.equal(session.messages[1].tools[0].evidence[0].label, '课表');
  assert.doesNotMatch(JSON.stringify(session), /private|must not be copied/);
  const file = (await readdir(directory))[0];
  assert.equal((await readFile(path.join(directory, file))).includes(Buffer.from('机密测试话题')), false);
});

test('cache replacement, origin scope and logout prevent cross-account exposure', async (t) => {
  const { history } = await fixture(t);
  await history.useOwner(origin, 'first');
  await history.save(origin, 'first', makeSession('one'));
  assert.equal(await history.get(origin, 'second', 'one'), null);
  assert.equal(await history.list('https://example.test:8000'), null);
  assert.equal(await history.save(origin, 'second', makeSession('two')), false);
  await history.useOwner(origin, 'second');
  assert.equal(await history.list(origin), null);
  assert.equal(await history.get(origin, 'first', 'one'), null);
  await history.save(origin, 'second', makeSession('two'));
  await history.clear(origin);
  assert.equal(await history.list(origin), null);
});

test('parallel writes are bounded, newest first, and deleting is durable', async (t) => {
  const { history } = await fixture(t);
  await history.useOwner(origin, 'owner');
  const writes = Array.from({ length: 22 }, (_, index) => history.save(origin, 'owner', makeSession(String(index))));
  assert.ok((await Promise.all(writes)).every(Boolean));
  assert.deepEqual((await history.list(origin)).sessions.map(item => item.sessionId), Array.from({ length: 20 }, (_, index) => String(21 - index)));
  assert.equal(await history.delete(origin, 'owner', '21'), true);
  assert.equal(await history.get(origin, 'owner', '21'), null);
});

test('unavailable encryption skips disk persistence and oversized conversations are rejected', async (t) => {
  const { directory, history } = await fixture(t, false);
  assert.equal(await history.useOwner(origin, 'owner'), false);
  assert.equal(await history.save(origin, 'owner', makeSession('one')), false);
  assert.deepEqual(await readdir(directory), []);
  assert.equal(prepareHistorySession({ sessionId: 'huge', messages: [{ role: 'user', content: 'a'.repeat(25000) }] }), null);
});
