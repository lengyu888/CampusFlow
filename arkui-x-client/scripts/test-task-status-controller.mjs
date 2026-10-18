import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { TaskStatusController, DraftStore, DraftMemoryDriver, draftFixture, validation, CampusFlowRequestError,
  statusIds as ids, statusNow, statusTask, completedTask, completeOperation, restoreOperation, overlappingRestore,
  appliedRestore, deferred, tick } from './helpers/task-status-fixture.mjs';
const request=(kind='complete')=>kind==='complete'?{operation_id:ids.complete,kind,expected_revision:1}:{operation_id:ids.restore,kind,expected_revision:2,source_operation_id:ids.complete};
const pointer=(scope,kind='complete')=>({scope,taskId:'task-a',request:request(kind),intent:'start',acknowledgements:[]});
const notFound=()=>new CampusFlowRequestError(404,'TASK_STATUS_OPERATION_NOT_FOUND','未查到原操作。');
const offline=()=>new CampusFlowRequestError(0,'NETWORK_ERROR','连接失败');
async function fixture(options={}) {
 const data=options.data??await draftFixture(),changes=[],applied=[],calls=[];let serial=0,now=statusNow;
 const api={async startTaskStatus(taskId,body){calls.push(['start',taskId,structuredClone(body)]);return body.kind==='complete'?completeOperation(statusTask({task_id:taskId}),body):restoreOperation(completedTask({task_id:taskId}),body);},
 async taskStatusOperation(id){calls.push(['get',id]);if(id===ids.complete)return completeOperation();throw notFound();},
 async confirmTaskStatus(id,acks){calls.push(['confirm',id,structuredClone(acks)]);return appliedRestore(restoreOperation());},
 async cancelTaskStatus(id){calls.push(['cancel',id]);return {...restoreOperation(),state:'cancelled'};},...options.api};
 const controller=new TaskStatusController(data.store,s=>changes.push(s),o=>applied.push(o),options.idFactory??(()=>serial++===0?(options.restore?ids.restore:ids.complete):ids.other),()=>now);
 controller.configure(data.lease.scope,'account-a',api,data.lease);controller.setActive(true);await tick();
 return {...data,controller,api,calls,changes,applied,setNow:v=>{now=v;},state:()=>controller.snapshot(),item:()=>controller.snapshot().items.find(i=>i.operationId===controller.snapshot().selectedId)};
}

test('strict operation validation accepts complete/restore and fresh ACK with historical accepted course state',()=>{
 assert(validation.validTaskStatusOperation(completeOperation(),'account-a','task-a',request()));
 assert(validation.validTaskStatusOperation(restoreOperation(),'account-a','task-a',request('restore')));
 const operation=overlappingRestore();assert(validation.validTaskStatusOperation(operation,'account-a','task-a',request('restore')));
 assert.equal(validation.validTaskStatusAcknowledgements(operation,[]),false);
 const acks=validation.requiredTaskStatusAcknowledgements(operation);assert.equal(acks.length,1);assert(validation.validTaskStatusAcknowledgements(operation,acks));
 assert(validation.validTaskStatusOperation(appliedRestore(operation),'account-a','task-a',request('restore'),operation));
});
test('receipt cannot change identity, revision, statuses, source, candidate, or ACK attribution',()=>{
 const original=overlappingRestore(),valid=appliedRestore(original);
 const changes=[o=>o.user_id='other',o=>o.task_id='other',o=>o.operation_id=ids.other,o=>o.expected_revision=3,o=>o.source_operation_id=ids.other,
 o=>o.receipt.after_revision++,o=>o.receipt.task_id='other',o=>o.receipt.before_status='pending',o=>o.receipt.after_completed_at='2030-01-01T00:00:00Z',
 o=>o.receipt.candidate_id='wrong',o=>o.receipt.course_acknowledgements[0].candidate_id='wrong',o=>o.receipt.course_acknowledgement_ids=[],
 o=>o.receipt.course_acknowledgements[0].acknowledgement_id='wrong',o=>o.receipt.before_completed_at=null];
 for(const change of changes){const o=structuredClone(valid);change(o);assert.equal(validation.validTaskStatusOperation(o,'account-a','task-a',request('restore'),original),false);}
 assert.equal(validation.validTaskStatusRequest({...request(),source_operation_id:null}),false);
 for(const value of [0,1.2,true,Number.MAX_SAFE_INTEGER])assert.equal(validation.validTaskStatusRequest({...request(),expected_revision:value}),false);
});
test('restore review validates all source facts, actual intersections, versions and required fresh state',()=>{
 const valid=overlappingRestore();
 for(const change of [o=>o.preview.task.task_version++,o=>o.preview.task.completion_operation_id=ids.other,o=>o.preview.state_version.planning++,
 o=>o.preview.course_review.state='accepted',o=>o.preview.course_review.requires_acknowledgement=false,o=>o.preview.course_review.task_id='other',
 o=>o.preview.course_review.task_version++,o=>o.preview.course_review.overlaps[0].course.date='2030-02-30',
 o=>o.preview.course_review.overlaps[0].course.location=null,o=>o.preview.course_review.overlaps[0].overlap_end_at='2030-10-19T10:30:00+08:00',
 o=>o.preview.course_review.overlaps[0].course.start_time='10:00',o=>o.preview.course_review.revoke_only=true]){
  const value=structuredClone(valid);change(value);assert.equal(validation.validTaskStatusOperation(value,'account-a','task-a',request('restore')),false);
 }
 const missing=restoreOperation(completedTask({end_at:null}));missing.preview.course_review.state='unchecked';missing.preview.warnings=['缺少结束时间，未核对时长。'];
 assert(validation.validTaskStatusOperation(missing,'account-a','task-a',request('restore')));
 const changed=structuredClone(valid);changed.preview.task.title='后来改动';assert.equal(validation.validTaskStatusOperation(changed,'account-a','task-a',request('restore'),valid),false);
});
test('dedicated durable status pointer survives restart without occupying or changing any user draft',async()=>{
 const data=await draftFixture();const key={kind:'new-task',ownerId:'main'},draft={title:'我的原草稿',date:'2030-10-19',dateChoice:'today',time:'08:00',anchorDate:'2030-10-19',timezone:'Asia/Shanghai'};
 data.store.stage(data.lease,key,draft);await data.store.flush(data.lease);const before=data.store.read(data.lease,key);
 await data.store.beginTaskStatusOperation(data.lease,pointer(data.lease.scope));assert(data.store.hasPendingTaskStatus(data.lease));assert.deepEqual(data.store.read(data.lease,key),before);
 const fresh=await draftFixture(data.driver,data.lease.scope);assert.deepEqual(fresh.store.taskStatusOperations(fresh.lease),[pointer(data.lease.scope)]);assert.deepEqual(fresh.store.read(fresh.lease,key),before);
 await fresh.store.resolveTaskStatusOperation(fresh.lease,ids.complete);assert.equal(fresh.store.hasPendingTaskStatus(fresh.lease),false);assert.deepEqual(fresh.store.read(fresh.lease,key),before);
});
test('legacy documents omit the new ledger safely while corrupt status fields fail closed',async()=>{
 const data=await draftFixture();let doc=JSON.parse(data.driver.text);delete doc.taskStatusOperations;data.driver.text=JSON.stringify(doc);
 const legacy=await draftFixture(data.driver,data.lease.scope);assert.deepEqual(legacy.store.taskStatusOperations(legacy.lease),[]);
 for(const change of [p=>p.scope='other',p=>p.request.expected_revision=0,p=>p.request.source_operation_id=null,p=>p.intent='confirm',p=>p.acknowledgements=[{candidate_id:'x',review_digest:'a'.repeat(64)}]]){
  const driver=new DraftMemoryDriver(),p=pointer(data.lease.scope);change(p);driver.text=JSON.stringify({...doc,taskStatusOperations:[p]});const store=new DraftStore(driver);
  await assert.rejects(store.initialize());assert.equal(driver.text.includes('taskStatusOperations'),true);
 }
});
test('status ledger capacity is separate from 20 user draft slots and enforces unique task/operation identity',async()=>{
 const d=await draftFixture();for(let i=0;i<20;i++)d.store.stage(d.lease,{kind:'assistant',ownerId:String(i)},{text:'draft',sessionId:String(i),anchorDate:'2030-10-19',timezone:'Asia/Shanghai'});
 await d.store.flush(d.lease);await d.store.beginTaskStatusOperation(d.lease,pointer(d.lease.scope));
 await assert.rejects(d.store.beginTaskStatusOperation(d.lease,{...pointer(d.lease.scope),taskId:'other'}));
 await assert.rejects(d.store.beginTaskStatusOperation(d.lease,{...pointer(d.lease.scope),request:{...request(),operation_id:ids.other}}));assert.equal(d.store.list(d.lease,'assistant').length,20);
});
test('intent CAS preserves request, survives cold start, and refuses rollback from cancel to confirm',async()=>{
 const d=await draftFixture(),p=pointer(d.lease.scope,'restore');await d.store.beginTaskStatusOperation(d.lease,p);
 const acks=[{candidate_id:'status:'+ids.restore,review_digest:'a'.repeat(64)}];await d.store.replaceTaskStatusIntent(d.lease,ids.restore,p,'confirm',acks);
 let current=d.store.taskStatusOperations(d.lease)[0];assert.equal(current.intent,'confirm');assert.deepEqual(current.request,p.request);
 await assert.rejects(d.store.replaceTaskStatusIntent(d.lease,ids.restore,p,'cancel'));
 await d.store.replaceTaskStatusIntent(d.lease,ids.restore,current,'cancel');current=d.store.taskStatusOperations(d.lease)[0];assert.deepEqual(current.acknowledgements,[]);
 const fresh=await draftFixture(d.driver,d.lease.scope);assert.deepEqual(fresh.store.taskStatusOperations(fresh.lease)[0],current);
 await assert.rejects(fresh.store.replaceTaskStatusIntent(fresh.lease,ids.restore,current,'confirm',acks));
 await fresh.store.replaceTaskStatusIntent(fresh.lease,ids.restore,current,'cancel');
});
test('disk failure retains original intent and blocking ledger; clear invalidates leases and all status entries',async()=>{
 const d=await draftFixture(),p=pointer(d.lease.scope,'restore');await d.store.beginTaskStatusOperation(d.lease,p);const text=d.driver.text;d.driver.failWrite=true;
 await assert.rejects(d.store.replaceTaskStatusIntent(d.lease,ids.restore,p,'confirm',[]));assert.deepEqual(d.store.taskStatusOperations(d.lease),[p]);assert.equal(d.driver.text,text);
 await assert.rejects(d.store.resolveTaskStatusOperation(d.lease,ids.restore));assert(d.store.hasPendingTaskStatus(d.lease));d.driver.failWrite=false;
 await d.store.clear();assert.equal(d.store.valid(d.lease),false);const fresh=await draftFixture(d.driver,d.lease.scope);assert.deepEqual(fresh.store.taskStatusOperations(fresh.lease),[]);
});
test('complete posts only after pointer is durable then exact receipt settles and refreshes once',async()=>{
 const f=await fixture();f.api.startTaskStatus=async(task,body)=>{assert.equal(JSON.parse(f.driver.text).taskStatusOperations[0].request.operation_id,body.operation_id);f.calls.push(['start',task,body]);return completeOperation(statusTask(),body);};
 await f.controller.begin(statusTask(),'complete');assert.equal(f.item().phase,'applied');assert.equal(f.applied.length,1);assert.deepEqual(f.state().lockedTaskIds,[]);assert.equal(f.store.hasPendingTaskStatus(f.lease),false);
 await f.controller.check();assert.equal(f.calls.length,1);assert.equal(f.applied.length,1);
});
test('disk failure sends no POST; only GET404 enables explicit original-id/body retry',async()=>{
 const f=await fixture({api:{async taskStatusOperation(){throw notFound();}}});f.driver.failWrite=true;await f.controller.begin(statusTask(),'complete');assert.equal(f.calls.length,0);assert.equal(f.item().phase,'unknown');assert(f.store.hasPendingTaskStatus(f.lease));
 await f.controller.retry();assert.equal(f.calls.length,0);f.driver.failWrite=false;await f.controller.check();assert.equal(f.item().phase,'retryable');await f.controller.retry();
 assert.equal(f.calls.filter(c=>c[0]==='start').length,1);assert.deepEqual(f.calls.at(-1)[2],request());assert.equal(f.item().phase,'applied');
});
test('network unknown is not inferred from UI status and cold restart performs only GET',async()=>{
 const f=await fixture({api:{async startTaskStatus(){throw offline();},async taskStatusOperation(){throw offline();}}});await f.controller.begin(statusTask(),'complete');assert.equal(f.item().phase,'unknown');f.controller.dispose();
 const data=await draftFixture(f.driver,f.lease.scope),gets=[];const cold=await fixture({data,api:{async taskStatusOperation(id){gets.push(id);return completeOperation();}}});await tick();
 assert.deepEqual(gets,[ids.complete]);assert.equal(cold.calls.length,0);assert.equal(cold.item().phase,'applied');assert.equal(cold.applied.length,1);
});
test('wrong owner or malformed receipt retains unknown and original pointer',async()=>{
 const f=await fixture({api:{async startTaskStatus(){return completeOperation(statusTask(),request(),{user_id:'account-b'});}}});await f.controller.begin(statusTask(),'complete');assert.equal(f.item().phase,'unknown');assert.deepEqual(f.state().lockedTaskIds,['task-a']);assert.equal(f.applied.length,0);assert(f.store.hasPendingTaskStatus(f.lease));
});
test('same-task repeated click is blocked while other task can independently complete',async()=>{
 const delayed=deferred(),f=await fixture({api:{async startTaskStatus(task,body){if(task==='task-a')return delayed.promise;return completeOperation(statusTask({task_id:task}),body);}}});
 const first=f.controller.begin(statusTask(),'complete');await tick();await f.controller.begin(statusTask(),'complete');await f.controller.begin(statusTask({task_id:'task-b'}),'complete');
 assert.equal(f.state().items.length,2);assert.equal(f.state().items.find(i=>i.taskId==='task-b').phase,'applied');assert.deepEqual(f.state().lockedTaskIds,['task-a']);delayed.resolve(completeOperation());await first;assert.deepEqual(f.state().lockedTaskIds,[]);
});
test('restore first verifies original complete receipt and never invents legacy evidence',async()=>{
 const f=await fixture({restore:true});await f.controller.begin(completedTask({completion_operation_id:null}),'restore');assert.equal(f.calls.length,0);assert.equal(f.state().items.length,0);
 await f.controller.begin(completedTask(),'restore');assert.deepEqual(f.calls.map(c=>c[0]),['get','start']);assert.equal(f.item().phase,'review');assert.equal(f.item().canConfirm,true);assert.equal(f.applied.length,0);
});
test('unverified source or hidden source-read does not create a permanent lock or submit',async()=>{
 const delayed=deferred(),f=await fixture({restore:true,api:{async taskStatusOperation(){return delayed.promise;}}});const pending=f.controller.begin(completedTask(),'restore');await tick();f.controller.setActive(false);delayed.resolve(completeOperation());await pending;f.controller.setActive(true);await tick();
 assert.equal(f.item().phase,'error');assert.equal(f.store.hasPendingTaskStatus(f.lease),false);assert.deepEqual(f.state().lockedTaskIds,[]);assert.equal(f.calls.length,0);
});
test('fresh course ACK is required and persisted before confirm; source accepted does not bypass it',async()=>{
 const preview=overlappingRestore(),f=await fixture({restore:true,api:{async startTaskStatus(){return preview;},async confirmTaskStatus(id,acks){const saved=JSON.parse(f.driver.text).taskStatusOperations[0];assert.equal(saved.intent,'confirm');assert.deepEqual(saved.acknowledgements,acks);f.calls.push(['confirm',id,acks]);return appliedRestore(preview);}}});
 await f.controller.begin(preview.preview.task,'restore');assert(f.item().canConfirm);await f.controller.confirm([]);assert.equal(f.calls.filter(c=>c[0]==='confirm').length,0);
 await f.controller.confirm(validation.requiredTaskStatusAcknowledgements(preview));assert.equal(f.item().phase,'applied');assert.equal(f.applied.length,1);
});
test('expired preview gives explicit feedback and can still be cancelled after durable intent',async()=>{
 const f=await fixture({restore:true});await f.controller.begin(completedTask(),'restore');f.setNow(statusNow+16*60_000);assert.equal(f.item().canConfirm,false);
 await f.controller.confirm();assert.match(f.item().message,/过期/);assert.equal(f.calls.some(c=>c[0]==='confirm'),false);await f.controller.cancel();assert.equal(f.item().phase,'cancelled');assert.equal(f.store.hasPendingTaskStatus(f.lease),false);
});
test('confirm unknown must GET pending before explicit durable cancel; server applied wins race',async()=>{
 const preview=restoreOperation(),f=await fixture({restore:true,api:{async confirmTaskStatus(){throw offline();},async taskStatusOperation(id){return id===ids.complete?completeOperation():preview;},async cancelTaskStatus(){assert.equal(JSON.parse(f.driver.text).taskStatusOperations[0].intent,'cancel');return appliedRestore(preview);}}});
 await f.controller.begin(completedTask(),'restore');await f.controller.confirm();assert.equal(f.item().phase,'unknown');await f.controller.cancel();assert.equal(f.item().phase,'unknown');
 await f.controller.check();assert.equal(f.item().phase,'review');await f.controller.cancel();assert.equal(f.item().phase,'applied');assert.equal(f.applied.length,1);assert.equal(f.store.hasPendingTaskStatus(f.lease),false);
});
test('changing confirm intent on disk failure never sends cancel and preserves original pointer',async()=>{
 const f=await fixture({restore:true});await f.controller.begin(completedTask(),'restore');f.driver.failWrite=true;await f.controller.cancel();assert.equal(f.calls.some(c=>c[0]==='cancel'),false);assert.equal(f.item().phase,'unknown');assert.equal(f.store.taskStatusOperations(f.lease)[0].intent,'start');
});
test('successful receipt survives local cleanup failure and later check settles without duplicate refresh',async()=>{
 const f=await fixture();f.api.startTaskStatus=async()=>{f.driver.failWrite=true;return completeOperation();};await f.controller.begin(statusTask(),'complete');assert.equal(f.item().phase,'cleanup');assert.equal(f.item().operation.state,'applied');assert.deepEqual(f.state().lockedTaskIds,['task-a']);assert.equal(f.applied.length,1);
 f.driver.failWrite=false;await f.controller.check();assert.equal(f.item().phase,'applied');assert.equal(f.applied.length,1);assert.equal(f.store.hasPendingTaskStatus(f.lease),false);
});
test('account change, clear, background, and dispose block late replies from writing current UI',async()=>{
 for(const mode of ['account','clear','background','dispose']){
  const delayed=deferred(),f=await fixture({api:{async startTaskStatus(){return delayed.promise;}}}),pending=f.controller.begin(statusTask(),'complete');await tick();
  if(mode==='account'){const lease=await f.store.activate('other-scope');f.controller.configure('other-scope','account-b',f.api,lease);}else if(mode==='clear')await f.store.clear();else if(mode==='background')f.controller.setActive(false);else f.controller.dispose();
  delayed.resolve(completeOperation());await pending;assert.equal(f.applied.length,0,mode);if(mode==='account')assert.deepEqual(f.state().items,[]);
 }
});
test('only explicit known prewrite rejections release the pointer; HTTP500 remains unknown',async()=>{
 for(const [code,status,phase] of [['TASK_STALE',409,'error'],['TASK_STATUS_UNCHANGED',409,'error'],['LOGIN_REQUIRED',401,'error'],['TASK_STATUS_FAILED',500,'unknown']]){
  const f=await fixture({api:{async startTaskStatus(){throw new CampusFlowRequestError(status,code,'安全说明');}}});await f.controller.begin(statusTask(),'complete');assert.equal(f.item().phase,phase);assert.equal(f.store.hasPendingTaskStatus(f.lease),phase==='unknown');
 }
});

test('finishing durable cleanup while hidden cannot strand an acknowledged operation after foreground returns',async()=>{
 const f=await fixture(),blocked=deferred(),started=deferred();let writes=0;
 f.driver.beforeWrite=async()=>{if(++writes===2){started.resolve();await blocked.promise;}};
 const work=f.controller.begin(statusTask(),'complete');await started.promise;assert.equal(f.applied.length,1);f.controller.setActive(false);blocked.resolve();await work;
 assert.equal(f.store.hasPendingTaskStatus(f.lease),false);f.controller.setActive(true);await tick();assert.equal(f.item().phase,'applied');assert.deepEqual(f.state().lockedTaskIds,[]);assert.equal(f.applied.length,1);
});
test('late durable confirm intent after foreground recovery cannot strand explicit cancel',async()=>{
 const preview=restoreOperation(),f=await fixture({restore:true,api:{async taskStatusOperation(id){return id===ids.complete?completeOperation():preview;}}});
 await f.controller.begin(completedTask(),'restore');
 const blocked=deferred(),started=deferred();let held=false;
 f.driver.beforeWrite=async()=>{if(!held){held=true;started.resolve();await blocked.promise;}};
 const oldConfirm=f.controller.confirm();await started.promise;
 f.controller.setActive(false);f.controller.setActive(true);await tick();assert.equal(f.item().phase,'review');
 assert.equal(f.store.taskStatusOperations(f.lease)[0].intent,'start');
 blocked.resolve();await oldConfirm;f.driver.beforeWrite=null;
 assert.equal(f.store.taskStatusOperations(f.lease)[0].intent,'confirm');
 assert.equal(f.calls.filter(c=>c[0]==='confirm').length,0);
 await f.controller.cancel();assert.equal(f.item().phase,'cancelled');
 assert.equal(f.calls.filter(c=>c[0]==='cancel').length,1);assert.equal(f.store.hasPendingTaskStatus(f.lease),false);
});
test('intent CAS overtaken by an old durable write recovers through GET without automatically retrying',async()=>{
 const preview=restoreOperation(),f=await fixture({restore:true,api:{async taskStatusOperation(id){return id===ids.complete?completeOperation():preview;}}});
 await f.controller.begin(completedTask(),'restore');
 const blocked=deferred(),started=deferred();let held=false;
 f.driver.beforeWrite=async()=>{if(!held){held=true;started.resolve();await blocked.promise;}};
 const oldConfirm=f.controller.confirm();await started.promise;
 f.controller.setActive(false);f.controller.setActive(true);await tick();
 const earlyCancel=f.controller.cancel();blocked.resolve();await Promise.all([oldConfirm,earlyCancel]);f.driver.beforeWrite=null;
 assert.equal(f.item().phase,'unknown');assert.equal(f.calls.some(c=>c[0]==='confirm'||c[0]==='cancel'),false);
 await f.controller.check();assert.equal(f.item().phase,'review');await f.controller.cancel();
 assert.equal(f.item().phase,'cancelled');assert.equal(f.calls.filter(c=>c[0]==='cancel').length,1);
});
test('late durable cancel intent cannot be rolled back to confirm after foreground recovery',async()=>{
 const preview=restoreOperation(),f=await fixture({restore:true,api:{async taskStatusOperation(id){return id===ids.complete?completeOperation():preview;}}});
 await f.controller.begin(completedTask(),'restore');
 const blocked=deferred(),started=deferred();let held=false;
 f.driver.beforeWrite=async()=>{if(!held){held=true;started.resolve();await blocked.promise;}};
 const oldCancel=f.controller.cancel();await started.promise;f.controller.setActive(false);f.controller.setActive(true);await tick();
 blocked.resolve();await oldCancel;f.driver.beforeWrite=null;
 await f.controller.confirm();assert.equal(f.calls.some(c=>c[0]==='confirm'||c[0]==='cancel'),false);
 assert.equal(f.item().canConfirm,false);await f.controller.cancel();assert.equal(f.item().phase,'cancelled');
});
test('intent/cleanup writes preserve newer user keystrokes and clear cannot resurrect the status ledger',async()=>{
 for(const mode of ['intent','resolve']){
  const d=await draftFixture(),p=pointer(d.lease.scope,'restore');await d.store.beginTaskStatusOperation(d.lease,p);
  const paused=deferred(),started=deferred();d.driver.beforeWrite=async()=>{started.resolve();await paused.promise;};
  const work=mode==='intent'?d.store.replaceTaskStatusIntent(d.lease,ids.restore,p,'cancel'):d.store.resolveTaskStatusOperation(d.lease,ids.restore);
  await started.promise;d.store.stage(d.lease,{kind:'assistant',ownerId:'new'},{text:'后来输入',sessionId:'new',anchorDate:'2030-10-19',timezone:'Asia/Shanghai'});paused.resolve();await work;d.driver.beforeWrite=null;await d.store.flush(d.lease);
  const fresh=await draftFixture(d.driver,d.lease.scope);assert.equal(fresh.store.read(fresh.lease,{kind:'assistant',ownerId:'new'}).payload.text,'后来输入');assert.equal(fresh.store.taskStatusOperations(fresh.lease).length,mode==='intent'?1:0);
 }
 const d=await draftFixture(),p=pointer(d.lease.scope,'restore');await d.store.beginTaskStatusOperation(d.lease,p);const paused=deferred(),started=deferred();
 d.driver.beforeWrite=async()=>{started.resolve();await paused.promise;};const write=d.store.replaceTaskStatusIntent(d.lease,ids.restore,p,'cancel');await started.promise;const clearing=d.store.clear();paused.resolve();await assert.rejects(write);await clearing;assert.equal(d.driver.text,undefined);
});
test('ledger strictly limits 40 independent tasks without eviction or changing the rejected request',async()=>{
 const d=await draftFixture();for(let i=0;i<40;i++)await d.store.beginTaskStatusOperation(d.lease,{...pointer(d.lease.scope),taskId:`t${i}`,request:{...request(),operation_id:`20000000-0000-4000-8000-${String(i).padStart(12,'0')}`}});
 const original=d.driver.text;await assert.rejects(d.store.beginTaskStatusOperation(d.lease,{...pointer(d.lease.scope),taskId:'overflow'}));assert.equal(d.driver.text,original);assert.equal(d.store.taskStatusOperations(d.lease).length,40);
});

test('rejected legacy request clears selection instead of presenting an earlier task receipt as its result',async()=>{
 const f=await fixture();await f.controller.begin(statusTask(),'complete');assert.equal(f.item().phase,'applied');
 await f.controller.begin(completedTask({task_id:'legacy',completion_operation_id:null}),'restore');
 assert.equal(f.state().selectedId,'');assert.equal(f.state().items.length,1);assert.match(f.state().message,/未保留/);
});
test('known rejected write with failed local cleanup can resolve after GET404 without another POST',async()=>{
 const f=await fixture({api:{async taskStatusOperation(){throw notFound();}}});let sends=0;
 f.api.startTaskStatus=async()=>{sends++;f.driver.failWrite=true;throw new CampusFlowRequestError(409,'TASK_STALE','任务已变更。');};
 await f.controller.begin(statusTask(),'complete');assert.equal(f.item().phase,'cleanup');f.driver.failWrite=false;
 await f.controller.check();assert.equal(f.item().phase,'error');assert.equal(f.store.hasPendingTaskStatus(f.lease),false);await f.controller.retry();assert.equal(sends,1);
});

const realFixture=JSON.parse(readFileSync(new URL('./fixtures/task-status-asgi-v1.json',import.meta.url),'utf8'));
test('all eight real authenticated ASGI/SQLite status projections satisfy strict owner/request/receipt validation',()=>{
 assert.equal(realFixture.synthetic,true);assert.equal(realFixture.cases.length,8);
 for(const item of realFixture.cases){
  assert(validation.validTaskStatusOperation(item.response,realFixture.user_id,item.task_before.task_id,item.request),item.label);
  assert.equal(validation.validTaskStatusOperation(item.response,'other-account',item.task_before.task_id,item.request),false,item.label);
  if(item.confirm_request)assert(validation.validTaskStatusAcknowledgements(item.response,item.confirm_request.acknowledgements));
 }
 const pending=realFixture.cases.find(item=>item.label==='restore-6'),applied=realFixture.cases.find(item=>item.label==='restored-course-ack');
 assert(validation.validTaskStatusOperation(applied.response,realFixture.user_id,pending.task_before.task_id,pending.request,pending.response));
});
