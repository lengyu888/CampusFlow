import assert from 'node:assert/strict';
import { test } from 'node:test';
import { DraftStore, DraftMemoryDriver, reviewNoteKey, time, deferred, tick } from './helpers/review-fixture.mjs';
const scope = 'https://example.test|account-a';
const clock = { now: () => Date.parse('2030-10-19T00:00:00Z'), set: () => 1, clear() {} };
async function fixture(driver = new DraftMemoryDriver(), account = scope) {
  const store = new DraftStore(driver, clock); await store.initialize(); const lease = await store.activate(account);
  return { store, driver, lease };
}
const note = (text = '  今天先做好一件事 🙂\n', period = 'day', anchor = '2030-10-19') => ({ period, anchor, timezone: 'Asia/Shanghai', text });

test('note keys match review day/week ranges including leap/year boundaries', () => {
  for (const date of ['2030-10-19','2024-02-29','2030-01-01','0099-12-31','9999-12-20']) {
    for (const period of ['day','week']) assert.equal(reviewNoteKey(period,date).ownerId, `${period}:${time.reviewRange(period,date).noteAnchor}`);
  }
  for (const date of ['2023-02-29','0001-01-01','9999-12-31','2030-01-01 private']) assert.throws(()=>reviewNoteKey('day',date));
});
test('500 Unicode codepoints and blank text persist exactly and survive real store restart', async () => {
  const {store,driver,lease}=await fixture(),key=reviewNoteKey('day','2030-10-19');
  const value=note('🙂'.repeat(498)+'\n ');const saved=store.stage(lease,key,value);await store.flush(lease);value.text='mutated';
  const cold=await fixture(driver);assert.equal(cold.store.read(cold.lease,key).payload.text,'🙂'.repeat(498)+'\n ');
  assert.equal(cold.store.read(cold.lease,key).localRevision,saved.localRevision);
  cold.store.stage(cold.lease,key,note(''));await cold.store.flush(cold.lease);assert.equal(cold.store.read(cold.lease,key).payload.text,'');
});
test('note payload rejects private extras, wrong owner, non-Monday week and overlong input without overwrite', async () => {
  const {store,driver,lease}=await fixture(),key=reviewNoteKey('day','2030-10-19');
  store.stage(lease,key,note());await store.flush(lease);const before=driver.text;
  for(const payload of [note('🙂'.repeat(501)),{...note(),token:'private'},{...note(),timezone:'UTC'},note('same','week','2030-10-19')]) {
    assert.throws(()=>store.stage(lease,key,payload));assert.equal(driver.text,before);assert.equal(store.read(lease,key).payload.text,note().text);
  }
  assert.throws(()=>store.stage(lease,{kind:'review-note',ownerId:'day:2030-10-20'},note()));
});
test('notes share the existing 20 slots and never evict assistant or task drafts; explicit delete frees one', async () => {
  const {store,lease}=await fixture();
  const assistant={kind:'assistant',ownerId:'main'};store.stage(lease,assistant,{text:'不能被感受驱逐',sessionId:'s',anchorDate:'2030-10-19',timezone:'Asia/Shanghai'});
  for(let i=0;i<19;i++){const anchor=time.reviewShiftAnchor('2030-10-01',i);store.stage(lease,reviewNoteKey('day',anchor),note(`感受${i}`,'day',anchor));}
  await store.flush(lease);assert.equal(store.list(lease,'review-note').length,19);
  const extra=reviewNoteKey('day','2030-11-01');assert.throws(()=>store.stage(lease,extra,note('新感受','day','2030-11-01')));
  assert.equal(store.read(lease,assistant).payload.text,'不能被感受驱逐');
  const old=store.list(lease,'review-note')[0];assert.equal(await store.remove(lease,{kind:old.kind,ownerId:old.ownerId},old.localRevision),true);
  store.stage(lease,extra,note('新感受','day','2030-11-01'));await store.flush(lease);assert.equal(store.list(lease,'review-note').length,19);
});
test('exact revision deletion cannot erase a newer note and write failures preserve retryable input', async () => {
  const {store,driver,lease}=await fixture(),key=reviewNoteKey('day','2030-10-19');
  const old=store.stage(lease,key,note('old'));await store.flush(lease);
  const newer=store.stage(lease,key,note('new'));assert.equal(await store.remove(lease,key,old.localRevision),false);
  driver.failWrite=true;await assert.rejects(store.flush(lease));assert.equal(store.status(lease).phase,'error');assert.equal(store.read(lease,key).payload.text,'new');
  driver.failWrite=false;await store.flush(lease);assert.equal(store.read(lease,key).localRevision,newer.localRevision);
  driver.failWrite=true;await assert.rejects(store.remove(lease,key,newer.localRevision));assert.equal(store.read(lease,key).payload.text,'new');
});
test('delayed save followed by clear and another account cannot resurrect the previous personal note', async () => {
  const {store,driver,lease}=await fixture(),key=reviewNoteKey('day','2030-10-19'),blocked=deferred(),started=deferred();
  driver.beforeWrite=async()=>{started.resolve();await blocked.promise;};store.stage(lease,key,note('仅原账号可见'));
  const write=store.flush(lease);await started.promise;const clear=store.clear();assert.equal(store.valid(lease),false);
  blocked.resolve();await assert.rejects(write);await clear;driver.beforeWrite=null;
  const next=await store.activate('https://example.test|account-b');assert.equal(store.list(next,'review-note').length,0);assert.equal(store.read(lease,key),undefined);
  assert.throws(()=>store.stage(lease,key,note('迟到')));await tick();assert.equal(JSON.parse(driver.text).records.length,0);
});
test('legacy schema without review notes remains readable; corrupted note data blocks instead of silently dropping', async () => {
  const {store,driver,lease}=await fixture();store.stage(lease,{kind:'assistant',ownerId:'main'},{text:'旧草稿',sessionId:'s',anchorDate:'2030-10-19',timezone:'Asia/Shanghai'});await store.flush(lease);
  const legacy=JSON.parse(driver.text);delete legacy.taskStatusOperations;driver.text=JSON.stringify(legacy);
  const cold=await fixture(driver);assert.equal(cold.store.read(cold.lease,{kind:'assistant',ownerId:'main'}).payload.text,'旧草稿');
  cold.store.stage(cold.lease,reviewNoteKey('day','2030-10-19'),note());await cold.store.flush(cold.lease);
  const bad=JSON.parse(driver.text);bad.records.find(r=>r.kind==='review-note').payload.token='private';driver.text=JSON.stringify(bad);
  const broken=new DraftStore(driver,clock);await assert.rejects(broken.initialize());assert.equal(driver.text,JSON.stringify(bad));
});
test('note deletion during delayed persistence preserves later input after another flush', async () => {
  const {store,driver,lease}=await fixture(),key=reviewNoteKey('day','2030-10-19');
  const initial=store.stage(lease,key,note('original'));await store.flush(lease);
  const blocked=deferred(),started=deferred();driver.beforeWrite=async()=>{started.resolve();await blocked.promise;};
  const removing=store.remove(lease,key,initial.localRevision);await started.promise;
  const latest=store.stage(lease,key,note('之后输入的感受'));blocked.resolve();await removing;driver.beforeWrite=null;
  assert.equal(store.read(lease,key).localRevision,latest.localRevision);await store.flush(lease);
  const cold=await fixture(driver);assert.equal(cold.store.read(cold.lease,key).payload.text,'之后输入的感受');
});
