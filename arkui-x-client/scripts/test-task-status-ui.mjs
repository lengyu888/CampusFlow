import { focusEntryFixture } from './helpers/focus-entry-fixture.mjs';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';
import { TaskStatusController, draftFixture, DraftMemoryDriver, CampusFlowRequestError,
  statusTask, completedTask, completeOperation, restoreOperation, appliedRestore, overlappingRestore,
  statusIds, statusNow, deferred, tick } from './helpers/task-status-fixture.mjs';
const read = path => readFileSync(new URL(`../entry/src/main/ets/${path}`, import.meta.url), 'utf8');
const clean = text => text.replace(/^import [^\n]+;\r?\n/gm, '');
const pure = async name => import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(clean(read(`utils/${name}.ets`)))).toString('base64')}`);
const navigation = await pure('AppNavigation'), history = await pure('LocalHistoryStore');
function component(path, name, dependencies) {
  const source = read(path); const end = source.indexOf('\n  @Builder');
  assert.ok(end > 0);
  const prefix = clean(source.slice(0, end)).replace(/^@(Entry|Component)\r?\n/gm, '')
    .replace(/@(State|Prop)\s+|@(StorageLink|Watch)\('[^']+'\)\s*/g, '')
    .replace(`export struct ${name}`, `class ${name}`).replace(`struct ${name}`, `class ${name}`) + '\n}';
  return new Function(...Object.keys(dependencies), stripTypeScriptTypes(prefix) + `\nreturn ${name};`)(...Object.values(dependencies));
}
async function fixture(handlers = {}, driver = new DraftMemoryDriver()) {
  const base = 'https://example.test', owner = 'account-a', calls = [], reminders = [];
  const drafts = await draftFixture(driver, history.historyScope(base, owner));
  let id = 0; const ids = handlers.ids ?? [statusIds.complete, statusIds.restore, statusIds.other]; const remote = new Map();
  class Api {
    constructor(base, token) { this.base = base; this.token = token; }
    async startTaskStatus(taskId, request) {
      calls.push(['start', taskId, structuredClone(request), this.token]);
      if (handlers.start) return handlers.start(taskId, request, this.token);
      const op = request.kind === 'complete' ? completeOperation(statusTask({task_id:taskId}), request) : restoreOperation(completedTask({task_id:taskId}), request);
      remote.set(op.operation_id, op); return structuredClone(op);
    }
    async taskStatusOperation(operationId) {
      calls.push(['get', operationId, this.token]);
      if (handlers.get) return handlers.get(operationId, this.token);
      if (remote.has(operationId)) return structuredClone(remote.get(operationId));
      if (operationId === statusIds.complete) return completeOperation();
      throw new CampusFlowRequestError(404, 'TASK_STATUS_OPERATION_NOT_FOUND', '原编号未查到');
    }
    async confirmTaskStatus(operationId, acks) {
      calls.push(['confirm', operationId, structuredClone(acks)]);
      const result = handlers.confirm ? await handlers.confirm(operationId, acks) : appliedRestore(remote.get(operationId));
      remote.set(operationId, result); return structuredClone(result);
    }
    async cancelTaskStatus(operationId) {
      calls.push(['cancel', operationId]); return { ...remote.get(operationId), state:'cancelled', receipt:null };
    }
    async logout() { calls.push(['logout']); }
  }
  class ClockedController {
    constructor(store, changed, applied, makeId) { return new TaskStatusController(store, changed, applied, makeId, () => statusNow); }
  }
  const Page = component('pages/Index.ets', 'Index', { ...navigation,
    historyScope: history.historyScope, localDrafts: drafts.store, ...focusEntryFixture().dependencies,
    localHistory: { clear: async () => {}, info: () => ({scope:'',count:0,displayName:''}) },
    TaskStatusController: ClockedController, timetableOperationId: () => ids[id++], CampusFlowApi: Api,
    AppStorage: {setOrCreate(){}}, AppTheme: {motion:()=>0}, Curve:{EaseOut:0} });
  const page = new Page(); page.baseUrl=base; page.authBaseUrl=base; page.token='token-a';page.user={user_id:owner,onboarding_complete:true};page.authRevision=1;page.draftLease=drafts.lease;
  page.reminders={refresh:()=>reminders.push('refresh'),setActive:v=>reminders.push(v),logout:async()=>{},dispose(){}};
  page.getUIContext=()=>({animateTo:(_,update)=>update()}); page.configureTaskStatuses(); await tick();
  return {page,calls,drafts,reminders,remote,handlers};
}
function panel(state) {
  const Panel = component('components/TaskStatusPanel.ets', 'TaskStatusPanel', {});
  const p = new Panel(); p.state=structuredClone(state); p.aboutToAppear(); return p;
}
function item(operation=overlappingRestore(), extra={}) {
  return {operationId:operation.operation_id,taskId:operation.task_id,kind:operation.kind,
    request:{operation_id:operation.operation_id,kind:operation.kind,expected_revision:operation.expected_revision,source_operation_id:operation.source_operation_id},
    phase:'review',operation,message:'',errorCode:'',busy:false,canRetry:false,canConfirm:true,canCancel:true,...extra};
}
function state(items) {return {items,selectedId:items[0]?.operationId??'',lockedTaskIds:items.map(i=>i.taskId),pendingCount:items.length,message:''};}

test('Index owns one coordinator: rapid Home/Plan intents for the same task share one durable operation and a receipt refreshes both pages/reminders',async()=>{
  const wait=deferred(); const f=await fixture({start:()=>wait.promise}); const original=statusTask();
  const first=f.page.changeTaskStatus(original); await tick(); const manager=f.page.taskStatuses;
  f.page.taskStatusOpen=false; f.page.activeTab=2; await f.page.changeTaskStatus(original);
  assert.equal(f.page.taskStatuses,manager); assert.equal(f.calls.filter(c=>c[0]==='start').length,1);
  assert.deepEqual(f.page.taskStatusState.lockedTaskIds,['task-a']);assert.equal(f.drafts.store.hasPendingTaskStatus(f.drafts.lease),true);
  wait.resolve(completeOperation()); await first;
  assert.equal(original.status,'pending','historical receipt must not overwrite task fields');
  assert.equal(f.page.homeRefresh,1);assert.equal(f.page.planRefresh,1);assert.deepEqual(f.reminders,['refresh']);
  assert.equal(f.page.taskStatusState.items[0].phase,'applied');assert.deepEqual(f.page.taskStatusState.lockedTaskIds,[]);
});

test('unknown task A does not prevent an unrelated B completion and closing the panel never means cancellation',async()=>{
  const f=await fixture({start:async(id,request)=>{if(id==='task-a')throw new Error('network');return completeOperation(statusTask({task_id:id}),request);}});
  await f.page.changeTaskStatus(statusTask()); assert.equal(f.page.taskStatusState.items[0].phase,'unknown');
  assert.equal(f.page.onBackPress(),true);assert.equal(f.page.taskStatusOpen,false);
  await f.page.changeTaskStatus(statusTask({task_id:'task-b'}));
  assert.deepEqual(f.page.taskStatusState.lockedTaskIds,['task-a']);assert.equal(f.calls.filter(c=>c[0]==='start').length,2);
  assert.equal(f.calls.some(c=>c[0]==='cancel'),false);f.page.openTaskStatus('task-a');assert.equal(f.page.taskStatusState.selectedId,statusIds.complete);
});

test('cold Index restores unknown status by original GET only; clear/logout require handling the separate ledger',async()=>{
  const first=await fixture({start:async()=>{throw Error('ambiguous');}});await first.page.changeTaskStatus(statusTask());first.page.aboutToDisappear();
  const f=await fixture({get:async()=>{throw new CampusFlowRequestError(404,'TASK_STATUS_OPERATION_NOT_FOUND','未查到');}},first.drafts.driver);
  assert.deepEqual(f.calls.map(c=>c[0]),['get']);assert.equal(f.calls[0][1],statusIds.complete);
  assert.equal(f.page.taskStatusState.items[0].canRetry,true);assert.equal(f.page.taskStatusState.pendingCount,1);
  f.page.draftClearConfirm=true;await f.page.clearLocalDrafts();assert.equal(f.drafts.store.hasPendingTaskStatus(f.drafts.lease),true);
  f.page.requestLogout();assert.equal(f.page.pendingLogoutConfirm,true);assert.equal(f.page.token,'token-a');
  assert.equal(f.page.onBackPress(),true);assert.equal(f.page.pendingLogoutConfirm,false);
  await f.page.logout();assert.equal(f.page.token,'');assert.deepEqual(f.page.taskStatusState.items,[]);assert.equal(f.calls.some(c=>c[0]==='start'),false);
});

test('background response is ignored; foreground reads original result and refreshes once without replay',async()=>{
  const wait=deferred();const f=await fixture({start:()=>wait.promise,get:async()=>completeOperation()});
  const first=f.page.changeTaskStatus(statusTask());await tick();f.page.voiceForeground=false;f.page.reminderActivityChanged();
  wait.resolve(completeOperation());await first;assert.equal(f.page.homeRefresh,0);
  f.page.voiceForeground=true;f.page.reminderActivityChanged();await tick();
  assert.equal(f.calls.filter(c=>c[0]==='start').length,1);assert.equal(f.calls.filter(c=>c[0]==='get').length,1);
  assert.equal(f.page.homeRefresh,1);assert.equal(f.page.taskStatusState.items[0].phase,'applied');
});

test('account/lease replacement invalidates late status callbacks and never refreshes the new account from an old receipt',async()=>{
  const wait=deferred();const f=await fixture({start:()=>wait.promise});const first=f.page.changeTaskStatus(statusTask());await tick();
  f.page.authRevision++;f.page.resetTaskStatuses();f.page.user={user_id:'account-b'};f.page.token='token-b';
  f.page.draftLease=await f.drafts.store.activate(history.historyScope(f.page.baseUrl,'account-b'));f.page.configureTaskStatuses();
  wait.resolve(completeOperation());await first;assert.equal(f.page.homeRefresh,0);assert.equal(f.page.planRefresh,0);assert.deepEqual(f.page.taskStatusState.items,[]);
});

test('restore only builds a preview; panel requires new exact ACK even if the task carried an old accepted overlap',async()=>{
  const f=await fixture({ids:[statusIds.restore],start:async()=>overlappingRestore()});await f.page.changeTaskStatus(completedTask({allow_during_course:true,course_overlap:{state:'accepted'}}));
  assert.deepEqual(f.calls.map(c=>c[0]),['get','start']);assert.equal(f.page.homeRefresh,0);
  const p=panel(f.page.taskStatusState),selected=p.selected(),confirmed=[];p.onConfirm=(id,acks)=>confirmed.push([id,acks]);
  p.confirm(selected);assert.deepEqual(confirmed,[]);p.toggleAck(selected);p.confirm(selected);
  assert.deepEqual(confirmed,[[statusIds.restore,[{candidate_id:overlappingRestore().preview.candidate_id,review_digest:'a'.repeat(64)}]]]);
  p.state.items[0].operation.preview.course_review.review_digest='d'.repeat(64);p.stateChanged();assert.deepEqual(p.selectedAcks,[]);
  p.confirm(p.selected());assert.equal(confirmed.length,1);
});

test('panel unknown/busy/hidden callbacks cannot confirm, while complete receipts remain historical and no fake cancel is offered',()=>{
  for(const phase of ['unknown','cleanup','checking']) {
    const p=panel(state([item(overlappingRestore(),{phase,canConfirm:false,busy:phase==='checking'})]));let calls=0;p.onConfirm=()=>calls++;
    p.toggleAck(p.selected());p.confirm(p.selected());assert.equal(calls,0);
  }
  const p=panel(state([item()]));p.active=false;p.toggleAck(p.selected());assert.deepEqual(p.selectedAcks,[]);
  const src=read('components/TaskStatusPanel.ets');assert.match(src,/这是该次操作的回执/);assert.match(src,/if \(item\.canCancel\)/);
});

test('all pending status records and all overlap courses remain reachable in six-item pages, using exact operation IDs',()=>{
  const items=Array.from({length:14},(_,i)=>item({...overlappingRestore(),operation_id:`item-${i}`},{operationId:`item-${i}`,taskId:`task-${i}`}));
  const p=panel(state(items));const found=[];for(let i=0;i<3;i++){p.pageIndex=i;found.push(...p.items().map(x=>x.operationId));}assert.deepEqual(found,items.map(x=>x.operationId));
  const preview=overlappingRestore().preview;preview.course_review.overlaps=Array.from({length:14},(_,i)=>({...preview.course_review.overlaps[0],course_key:`course-${i}`}));
  const overlaps=[];for(let i=0;i<3;i++){p.overlapPage=i;overlaps.push(...p.overlaps(preview).map(x=>x.course_key));}assert.equal(new Set(overlaps).size,14);
});


test('exact-task recovery opens its current unknown or cleanup operation before older receipts or errors',async()=>{
  const f=await fixture({start:async(_task,request)=>{if(request.kind==='complete')return completeOperation();throw Error('ambiguous restore');}});
  await f.page.changeTaskStatus(statusTask());await f.page.changeTaskStatus(completedTask());
  assert.deepEqual(f.page.taskStatusState.items.map(i=>i.phase),['applied','unknown']);
  f.page.openTaskStatus('task-a');assert.equal(f.page.taskStatusState.selectedId,statusIds.restore);
  for(const previousPhase of ['applied','cancelled','error']){
    f.page.taskStatusState.items[0].phase=previousPhase;
    f.page.taskStatusState.items[1].phase='cleanup';
    f.page.openTaskStatus('task-a');assert.equal(f.page.taskStatusState.selectedId,statusIds.restore);
  }
});

test('terminal preview copy distinguishes cancelled changes from historical applied snapshots',()=>{
  const p=panel(state([item()]));
  assert.match(p.previewContext(item({...overlappingRestore(),state:'cancelled'})),/已取消，未执行/);
  assert.match(p.previewContext(item(appliedRestore(overlappingRestore()))),/当时.*不是当前任务快照/);
  assert.match(p.previewContext(item()),/保留当前任务内容/);
});
