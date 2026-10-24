import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createHash} from 'node:crypto';
import {readFileSync} from 'node:fs';
import {digests,timers,validation,FocusStore,FocusMemoryDriver,focusFixture,FakeFocusClock,FocusApi,focusRecord,focusReceipt,uuid,wall,tick,deferred,CampusFlowRequestError} from './helpers/focus-fixture.mjs';
const anchor=()=>({recordId:uuid(2),segmentId:uuid(3),intervalId:uuid(4),clockSessionId:uuid(9000),sequence:1,firstSample:{wallMs:wall,monotonicMs:1000,clockSessionId:uuid(9000)},lastAcceptedSample:{wallMs:wall,monotonicMs:1000,clockSessionId:uuid(9000)},elapsedMs:0});
const start=()=>({operation_id:uuid(3),kind:'start',expected_revision:0,device_id:uuid(1),occurred_at:new Date(wall).toISOString(),task_id:'task-a',clock_session_id:uuid(9000),target_ms:null});
const posts=f=>f.api.calls.filter(c=>c[0]==='post');
test('timer measures real monotonic deltas; checkpoint is one stable interval, not ticks',()=>{
 const t=new timers.FocusTimer(anchor());assert(t.accept({wallMs:wall+3700,monotonicMs:4700,clockSessionId:uuid(9000)}).accepted);assert.equal(t.interval().elapsed_ms,3700);assert.equal(t.interval().interval_id,uuid(4));
 assert(t.accept({wallMs:wall+5000,monotonicMs:6000,clockSessionId:uuid(9000)}).accepted);assert.equal(t.interval().elapsed_ms,5000);assert.equal(t.snapshot().elapsedMs,5000);
});
test('wall jumps, backward mono, long gaps, and clock-session change preserve last known prefix',()=>{
 for(const sample of [{wallMs:wall+20000,monotonicMs:2000,clockSessionId:uuid(9000)},{wallMs:wall-10000,monotonicMs:2000,clockSessionId:uuid(9000)},
 {wallMs:wall+1000,monotonicMs:0,clockSessionId:uuid(9000)},{wallMs:wall+11000,monotonicMs:12000,clockSessionId:uuid(9000)},{wallMs:wall+1000,monotonicMs:2000,clockSessionId:uuid(9001)}]){
 const t=new timers.FocusTimer(anchor());assert.equal(t.accept(sample).accepted,false);assert.equal(t.snapshot().elapsedMs,0);
 }
});
test('strict request projection rejects raw mono, extra nested fields, nonfinite and cross-array UUID duplicates',()=>{
 assert(validation.validFocusRequest(start()));for(const change of [r=>r.monotonicMs=42,r=>r.target_ms=Infinity,r=>r.clock_session_id='bad']){const r=start();change(r);assert.equal(validation.validFocusRequest(r),false);}
 const timer=new timers.FocusTimer(anchor());timer.accept({wallMs:wall+1000,monotonicMs:2000,clockSessionId:uuid(9000)});
 const r={operation_id:uuid(5),kind:'pause',expected_revision:1,device_id:uuid(1),occurred_at:new Date(wall).toISOString(),segment_id:uuid(3),clock_session_id:uuid(9000),intervals:[timer.interval()],unknown_gaps:[]};
 assert(validation.validFocusRequest(r));r.intervals[0].mono_start=1000;assert.equal(validation.validFocusRequest(r),false);delete r.intervals[0].mono_start;
 r.unknown_gaps=[timer.gap(uuid(4),'sample_gap')];assert.equal(validation.validFocusRequest(r),false);
});
test('operation owner, record, state, revision and accepted fragment identities are strict',()=>{
 const request=start(),receipt=focusReceipt(uuid(2),request);assert(validation.validFocusOperation(receipt,'account-a',uuid(2),request));
 for(const change of [r=>r.user_id='b',r=>r.record_id=uuid(9),r=>r.receipt.before_state='paused',r=>r.receipt.after_revision=3,r=>r.receipt.accepted_interval_ids=[uuid(9)],r=>r.receipt.added_elapsed_ms=1]){
 const r=structuredClone(receipt);change(r);assert.equal(validation.validFocusOperation(r,'account-a',uuid(2),request),false);
 }
});
test('store rejects corrupt/unknown document and scope switch without overwriting original',async()=>{
 for(const raw of ['{broken',JSON.stringify({schemaVersion:2})]){const driver=new FocusMemoryDriver();driver.text=raw;const store=new FocusStore(driver);await assert.rejects(store.initialize());assert.equal(driver.text,raw);}
 const f=await focusFixture();const original=f.driver.text;await assert.rejects(f.store.activate('other',uuid(44)));assert.equal(f.driver.text,original);
});
test('controller reports owner mismatch without leaking identity and a retry never overwrites the retained file',async()=>{
 const driver=new FocusMemoryDriver(),old=await focusFixture({driver,scope:'private-old-owner'}),original=driver.text;old.controller.dispose();
 const current=await focusFixture({driver,scope:'current-owner',firstId:100});
 assert.equal(current.state().phase,'error');assert.equal(current.state().errorCode,'FOCUS_SCOPE_MISMATCH');assert.match(current.state().message,/另一账号或服务地址/);
 assert.doesNotMatch(current.state().message,/private-old-owner|current-owner/);await current.controller.configure('current-owner','account-a',current.api);
 await current.controller.start('task-a',null,'offline');assert.equal(driver.text,original);assert.equal(current.state().local,null);assert.equal(posts(current).length,0);
});
test('explicit configure retry rereads a transiently unavailable file without clearing data',async()=>{
 const driver=new FocusMemoryDriver();let unavailable=true;driver.read=async()=>{if(unavailable)throw Error('private-path');return driver.text;};
 const store=new FocusStore(driver);await assert.rejects(store.initialize());
 const {FocusController}=await import('./helpers/focus-fixture.mjs');const controller=new FocusController(store,new FakeFocusClock(),()=>{},()=>uuid(1));
 await controller.configure('current-owner','account-a',new FocusApi());assert.equal(controller.snapshot().phase,'error');assert.equal(driver.writes,0);
 unavailable=false;await controller.configure('current-owner','account-a',new FocusApi());assert.equal(controller.snapshot().phase,'ready');assert.equal(driver.writes,1);
 controller.dispose();
});
test('online starts timer only after receipt and durable anchor, with no latency included',async()=>{
 const f=await focusFixture(),wait=deferred();f.api.submitHook=async(id,request)=>{assert.equal(f.doc().operations[0].dispatchState,'unknown');return wait.promise;};
 const work=f.controller.start('task-a',null,'online');await tick();assert.equal(f.state().local.localState,'starting');f.clock.advance(15000);assert.equal(f.state().local.elapsedMs,0);
 const p=posts(f)[0];f.api.records.set(p[1],focusRecord(p[1],{segment_id:p[2].operation_id,current_device_id:p[2].device_id}));wait.resolve(focusReceipt(p[1],p[2]));await work;assert.equal(f.state().local.localState,'running');assert.equal(f.state().local.elapsedMs,0);
 await f.scheduler.step(f.clock);assert.equal(f.state().local.elapsedMs,1000);
});
test('pause does not accumulate, resume starts a new segment, end is never task completion',async()=>{
 const f=await focusFixture();await f.controller.start('task-a',60000,'online');await f.scheduler.step(f.clock,2500);await f.controller.pause();
 assert.equal(f.state().local.elapsedMs,2500);assert.equal(f.state().local.localState,'paused');f.clock.advance(120000);await f.controller.resume();await f.scheduler.step(f.clock,1000);await f.controller.end();
 assert.equal(f.state().record.state,'ended');assert.equal(f.state().record.confirmed_elapsed_ms,3500);assert.equal(f.state().localRecords.length,0);assert.deepEqual(posts(f).map(p=>p[2].kind),['start','pause','resume','end']);
 await f.controller.end();assert.equal(posts(f).length,4);assert.equal(f.state().intervals.length,2);
});
test('explicit offline sequence survives cold load with frozen IDs and versions then syncs exactly once',async()=>{
 const f=await focusFixture();await f.controller.start('task-a',null,'offline');await f.scheduler.step(f.clock,2000);await f.controller.pause();f.clock.advance(20000);await f.controller.resume();await f.scheduler.step(f.clock,3000);await f.controller.end();
 assert.equal(posts(f).length,0);const requests=f.doc().operations.map(o=>o.request);assert.deepEqual(requests.map(r=>r.expected_revision),[0,1,2,3]);f.controller.dispose();
 const cold=await focusFixture({driver:f.driver,api:f.api,firstId:100});assert.equal(posts(cold).length,0);await cold.controller.sync();assert.deepEqual(posts(cold).map(p=>p[2]),requests);assert.equal(cold.state().record.confirmed_elapsed_ms,5000);
 await cold.controller.sync();assert.equal(posts(cold).length,4);
});
test('clock unavailable can be explicitly reprobed and never falls back to wall time',async()=>{
 const f=await focusFixture();f.clock.failure=true;await f.controller.start('task-a',null,'online');assert.equal(posts(f).length,0);assert.equal(f.state().localRecords.length,0);
 f.clock.failure=false;await f.controller.start('task-a',null,'online');assert.equal(f.state().local.localState,'running');
});
test('malformed receipt cannot start timer, retry requires exact GET404, same request is preserved',async()=>{
 const f=await focusFixture();f.api.submitHook=async(id,request)=>({...focusReceipt(id,request),user_id:'other'});await f.controller.start('task-a',null,'online');
 assert.equal(f.state().pendingOperations[0].phase,'unknown');assert.notEqual(f.state().local.localState,'running');const original=posts(f)[0];
 await f.controller.sync();await f.controller.retry(original[2].operation_id);assert.equal(posts(f).length,1);
 await f.controller.check(original[2].operation_id);assert.equal(f.state().pendingOperations[0].phase,'not_found');f.api.submitHook=null;
 await f.controller.retry(original[2].operation_id);assert.deepEqual(posts(f)[1],original);assert.equal(f.state().local.localState,'running');
});
test('crash restores only the durable prefix, seals it once and marks unknown interruption',async()=>{
 const f=await focusFixture();await f.controller.start('task-a',null,'offline');for(let i=0;i<7;i++)await f.scheduler.step(f.clock);
 assert.equal(f.state().local.elapsedMs,7000);assert.equal(f.doc().records[0].anchor.elapsedMs,5000);f.controller.dispose();
 const clock=new FakeFocusClock();clock.clockSessionId=uuid(9001);clock.wallMs+=3*3600_000;const cold=await focusFixture({driver:f.driver,api:f.api,clock,firstId:100});
 assert.equal(cold.state().local.localState,'paused');assert.equal(cold.state().local.elapsedMs,5000);assert.equal(cold.state().local.unknownGapCount,1);assert.equal(posts(cold).length,0);
 await cold.controller.sync();assert.equal(cold.state().record.confirmed_elapsed_ms,5000);assert.equal(cold.state().unknownGaps[0].reason,'process_interrupted');
});
test('wall change automatically seals prefix with gap and pauses without counting discontinuity',async()=>{
 const f=await focusFixture();await f.controller.start('task-a',null,'offline');await f.scheduler.step(f.clock,2000);f.clock.wallMs+=100000;await f.scheduler.step(f.clock,1000);
 assert.equal(f.state().local.localState,'paused');assert.equal(f.state().local.elapsedMs,2000);assert.equal(f.state().local.unknownGapCount,1);assert.equal(f.doc().operations.at(-1).request.unknown_gaps[0].reason,'clock_changed');
});
test('background pauses locally, no background POST and no late sample enters sealed interval',async()=>{
 const f=await focusFixture();await f.controller.start('task-a',null,'online');await f.scheduler.step(f.clock,1000);
 const wait=deferred();f.clock.pending=wait.promise;const tickWork=f.scheduler.step(f.clock);await tick();f.controller.setForeground(false);await tick();
 wait.resolve({wallMs:f.clock.wallMs,monotonicMs:f.clock.monotonicMs,clockSessionId:f.clock.clockSessionId});await tickWork;await tick();
 assert.equal(f.state().local.localState,'paused');assert.equal(f.state().local.elapsedMs,1000);assert.equal(posts(f).length,1);f.clock.pending=null;f.controller.setForeground(true);await tick();assert.equal(posts(f).length,1);await f.controller.sync();assert.equal(posts(f).length,2);
});
test('record cleanup after receipt is atomic; disk failure preserves original operation for GET',async()=>{
 const f=await focusFixture();await f.controller.start('task-a',null,'offline');await f.scheduler.step(f.clock,1000);await f.controller.end();
 const originalSubmit=f.api.submitFocusOperation.bind(f.api);f.api.submitFocusOperation=async(id,r)=>{const result=await originalSubmit(id,r);f.driver.failWrite=true;return result;};
 await f.controller.sync();assert.equal(f.state().pendingOperations[0].phase,'unknown');const id=f.state().pendingOperations[0].operationId;f.driver.failWrite=false;f.api.submitFocusOperation=originalSubmit;
 await f.controller.check(id);assert.equal(posts(f).length,1);await f.controller.sync();assert.equal(f.state().record.confirmed_elapsed_ms,1000);assert.equal(f.state().localRecords.length,0);
});
test('version conflict retains local evidence and never rebases or skips first queued record',async()=>{
 const f=await focusFixture();await f.controller.start('task-a',null,'offline');await f.scheduler.step(f.clock,1000);await f.controller.end();
 f.api.submitHook=async()=>{throw new CampusFlowRequestError(409,'FOCUS_ACTIVE_EXISTS','其他端存在记录');};await f.controller.sync();assert.equal(posts(f).length,1);assert.equal(f.state().pendingOperations[0].phase,'conflict');
 const original=f.doc().operations[0].request;await f.controller.sync();assert.equal(posts(f).length,1);assert.deepEqual(f.doc().operations[0].request,original);assert.equal(f.state().local.elapsedMs,1000);
});
test('clearing while durable write is delayed cannot resurrect old scope or dispatch network',async()=>{
 const f=await focusFixture(),started=deferred(),blocked=deferred();f.driver.beforeWrite=async()=>{started.resolve();await blocked.promise;};
 const work=f.controller.start('task-a',null,'online');await started.promise;const clear=f.controller.clearLocal();blocked.resolve();await Promise.all([work,clear]);assert.equal(posts(f).length,0);assert.equal(f.driver.text,undefined);assert.equal(f.state().localRecords.length,0);
});
test('failed clear blocks new scope and old reply never enters a new account',async()=>{
 const f=await focusFixture(),wait=deferred();f.api.submitHook=async()=>wait.promise;const work=f.controller.start('task-a',null,'online');await tick();const post=posts(f)[0];
 f.driver.failRemove=true;await assert.rejects(f.controller.clearLocal());await f.controller.configure('other','account-b',new FocusApi());assert.equal(f.state().phase,'error');wait.resolve(focusReceipt(post[1],post[2]));await work;assert.equal(f.state().localRecords.length,0);
});
test('canonical SHA256 binds full typed request and matches independent standard hash vectors',()=>{
 for(const input of ['', 'abc', '校园专注 📚', 'a'.repeat(100000)])assert.equal(digests.focusSha256(input),createHash('sha256').update(input).digest('hex'));
 const request=start();const normalized={...request,occurred_at:'2030-10-19T01:00:00Z'};
 const canonical=v=>Array.isArray(v)?'['+v.map(canonical).join(',')+']':v!==null&&typeof v==='object'?'{'+Object.keys(v).sort().map(k=>JSON.stringify(k)+':'+canonical(v[k])).join(',')+'}':JSON.stringify(v);
 assert.equal(digests.focusRequestDigest('account-a',uuid(2),request),createHash('sha256').update(canonical({user_id:'account-a',record_id:uuid(2),request:normalized})).digest('hex'));
 const receipt=focusReceipt(uuid(2),request);const different={...request,task_id:'task-b'};assert.equal(validation.validFocusOperation(receipt,'account-a',uuid(2),different),false);
 const micro={...request,occurred_at:'2030-10-19T09:00:00.123456+08:00'};
 assert.equal(digests.focusRequestDigest('account-a',uuid(2),micro),createHash('sha256').update(canonical({user_id:'account-a',record_id:uuid(2),request:{...micro,occurred_at:'2030-10-19T01:00:00.123456Z'}})).digest('hex'));
});
test('old start receipt after remote end or deletion cannot restart local timer',async()=>{
 for(const mode of ['ended','deleted']){
  const f=await focusFixture();f.api.submitHook=async()=>{throw new CampusFlowRequestError(0,'NETWORK_ERROR','未知');};await f.controller.start('task-a',null,'online');const post=posts(f)[0];
  f.api.receipts.set(post[2].operation_id,focusReceipt(post[1],post[2]));if(mode==='ended')f.api.records.set(post[1],focusRecord(post[1],{state:'ended',revision:2,segment_id:null,clock_session_id:null,ended_at:new Date(wall).toISOString()}));
  await f.controller.check(post[2].operation_id);assert.equal(f.state().local.localState,'interrupted');assert.equal(f.scheduler.jobs.size,0);assert.equal(f.state().local.elapsedMs,0);
 }
});
test('resume freezes selected identity across a delayed clock probe and never writes to newly selected record',async()=>{
 const f=await focusFixture();await f.controller.start('task-a',null,'online');await f.controller.pause();const a=f.state().selectedRecordId;
 const b=uuid(7000);f.api.records.set(b,focusRecord(b,{task_id:'task-b',state:'ended',revision:2,segment_id:null,clock_session_id:null,ended_at:new Date(wall).toISOString()}));
 const wait=deferred();f.clock.pending=wait.promise;const pending=f.controller.resume();await tick();await f.controller.selectRecord(b);wait.resolve({wallMs:f.clock.wallMs,monotonicMs:f.clock.monotonicMs,clockSessionId:f.clock.clockSessionId});await pending;
 assert.equal(posts(f).filter(p=>p[2].kind==='resume').length,0);assert.equal(f.state().selectedRecordId,b);assert.equal(f.doc().records.find(r=>r.recordId===a).localState,'paused');
});
test('background during initial anchor durable write seals dormant prefix instead of leaving phantom running',async()=>{
 for(const mode of ['online','offline']){
  const f=await focusFixture(),blocked=deferred(),started=deferred();let held=false;
  f.driver.beforeWrite=async raw=>{const d=JSON.parse(raw);if(!held&&d.records.some(r=>r.anchor!==null)){held=true;started.resolve();await blocked.promise;}};
  const work=f.controller.start('task-a',null,mode);await started.promise;f.controller.setForeground(false);blocked.resolve();await work;await tick();
  assert.equal(f.state().local.localState,'paused',mode);assert.equal(f.doc().records[0].anchor,null);assert.equal(f.state().local.elapsedMs,0);assert.equal(f.scheduler.jobs.size,0);assert.equal(f.state().local.unknownGapCount,1);
 }
});
test('selecting history does not let end or pause silently affect another active local record',async()=>{
 const f=await focusFixture();await f.controller.start('task-a',null,'online');const a=f.state().selectedRecordId;await f.controller.selectRecord(uuid(7000));
 await f.controller.end();await f.controller.pause();assert.equal(posts(f).length,1);assert.equal(f.doc().records[0].localState,'running');
 f.controller.setForeground(false);await tick();assert.equal(f.doc().records[0].recordId,a);assert.equal(f.doc().records[0].localState,'paused');
});
test('checkpoint write finishing after background seal cannot overwrite paused state or double the interval',async()=>{
 const f=await focusFixture();await f.controller.start('task-a',null,'offline');const blocked=deferred(),started=deferred();let held=false;
 f.driver.beforeWrite=async raw=>{if(!held&&JSON.parse(raw).records[0]?.anchor?.elapsedMs===5000){held=true;started.resolve();await blocked.promise;}};
 const sampling=f.scheduler.step(f.clock,5000);await started.promise;f.controller.setForeground(false);blocked.resolve();await sampling;await tick();
 assert.equal(f.doc().records[0].localState,'paused');assert.equal(f.doc().records[0].anchor,null);assert.equal(f.doc().records[0].intervals.length,1);assert.equal(f.state().local.elapsedMs,5000);
});
test('all 22 real authenticated ASGI/SQLite projections including UTC microseconds validate against frozen requests',()=>{
 const fixture=JSON.parse(readFileSync(new URL('./fixtures/focus-asgi-v1.json',import.meta.url),'utf8'));assert.equal(fixture.synthetic,true);assert.equal(fixture.cases.length,22);
 for(const c of fixture.cases){
  const r=c.response;let valid=false;
  if(c.type==='operation'){const request=c.request??fixture.cases.find(x=>x.request?.operation_id===r.operation_id)?.request;assert(request,c.label);valid=validation.validFocusOperation(r,fixture.user_id,r.record_id,request);assert.equal(digests.focusRequestDigest(fixture.user_id,r.record_id,request),r.request_digest,c.label);}
  else if(c.type==='detail')valid=validation.validFocusDetail(r,fixture.user_id,r.record.record_id);
  else if(c.type==='list')valid=validation.validFocusList(r,fixture.user_id);
  else valid=validation.validFocusActive(r,fixture.user_id);
  assert(valid,c.label);
 }
});
test('unknown survives cold restart without POST and cannot start a different online record',async()=>{
 const f=await focusFixture();f.api.submitHook=async()=>{throw new CampusFlowRequestError(0,'NETWORK_ERROR','未知');};await f.controller.start('task-a',null,'online');const original=posts(f)[0];f.controller.dispose();
 const cold=await focusFixture({driver:f.driver,api:f.api,firstId:100});assert.equal(posts(cold).length,1);await cold.controller.start('task-b',null,'online');assert.equal(posts(cold).length,1);assert.deepEqual(cold.doc().operations[0].request,original[2]);
});
test('storage failure halts sampling and user can explicitly persist the retained prefix by ending',async()=>{
 const f=await focusFixture();await f.controller.start('task-a',null,'offline');f.driver.failWrite=true;await f.scheduler.step(f.clock,5000);
 assert.equal(f.state().local.localState,'interrupted');assert.equal(f.state().local.elapsedMs,5000);assert.equal(f.state().local.saveState,'error');assert.equal(f.scheduler.jobs.size,0);
 f.driver.failWrite=false;await f.controller.end();assert.equal(f.state().local.localState,'ended');assert.equal(f.state().local.elapsedMs,5000);assert.equal(f.doc().records[0].anchor,null);
});
test('operation capacity reserves pause and end rather than trapping a running record',async()=>{
 const f=await focusFixture();await f.controller.start('task-a',null,'offline');
 for(let i=0;i<48;i++){await f.controller.pause();await f.controller.resume();}
 assert.equal(f.doc().operations.length,97);await f.controller.pause();assert.equal(f.doc().operations.length,98);
 await f.controller.resume();assert.equal(f.doc().operations.length,98);assert.equal(f.state().local.localState,'paused');await f.controller.end();assert.equal(f.doc().operations.length,99);assert.equal(f.state().local.localState,'ended');
});
test('local record capacity never evicts unsynced records or silently changes a frozen request',async()=>{
 const f=await focusFixture();for(let i=0;i<20;i++){await f.controller.start('task-'+i,null,'offline');await f.controller.end();}
 assert.equal(f.state().localRecords.length,20);const original=f.driver.text;await f.controller.start('overflow',null,'offline');assert.equal(f.driver.text,original);
 const lease=await f.store.activate('https://example.test|account-a',uuid(1)),doc=f.store.snapshot(lease),revision=doc.revision;doc.revision++;doc.operations[0].request.task_id='changed';
 await assert.rejects(f.store.commit(lease,revision,doc));assert.equal(f.driver.text,original);
});
test('out-of-order detail and list reads cannot select another record or append a stale snapshot',async()=>{
 const f=await focusFixture(),a=uuid(8000),b=uuid(8001),wait=deferred();f.api.records.set(b,focusRecord(b));const original=f.api.focusDetail.bind(f.api);
 f.api.focusDetail=async id=>id===a?wait.promise:original(id);const first=f.controller.selectRecord(a);await f.controller.selectRecord(b);wait.resolve({contract_version:1,user_id:'account-a',record:focusRecord(a),record_revision:1,intervals:[],unknown_gaps:[]});await first;assert.equal(f.state().record.record_id,b);
 let count=0;f.api.focusList=async()=>({contract_version:1,user_id:'account-a',records:[focusRecord(count++===0?a:b,{state:'ended',segment_id:null,clock_session_id:null,ended_at:new Date(wall).toISOString()})],next_cursor:count===1?'next':null,snapshot_token:(count===1?'a':'b').repeat(64)});
 await f.controller.refreshHistory();await f.controller.loadMoreHistory();assert.equal(f.state().history.length,1);assert.equal(f.state().history[0].record_id,a);assert.match(f.state().historyError,/刷新/);
});
test('history accepts ended records only and mutation invalidates the whole old snapshot without mixing detail rows',async()=>{
 const f=await focusFixture();await f.controller.start('task-a',null,'online');await f.controller.refreshHistory();assert.deepEqual(f.state().history,[]);
 const invalid={contract_version:1,user_id:'account-a',records:[focusRecord()],next_cursor:null,snapshot_token:'a'.repeat(64)};assert.equal(validation.validFocusList(invalid,'account-a'),false);
 await f.controller.end();await f.controller.refreshHistory();assert.equal(f.state().history.length,1);const record=f.state().history[0];
 await f.controller.deleteRecord(record.record_id,record.revision);assert.equal(f.state().history.length,0);assert.equal(f.state().historyHasMore,false);assert.match(f.state().historyError,/刷新/);assert.equal(f.state().record,null);
 await f.controller.refreshHistory();assert.deepEqual(f.state().history,[]);assert.equal(f.state().historyError,'');
});
