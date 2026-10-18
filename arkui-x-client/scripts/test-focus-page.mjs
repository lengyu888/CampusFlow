import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';
import { focusEntryFixture } from './helpers/focus-entry-fixture.mjs';
import { emptyFocusState, FocusApi, focusRecord, uuid, deferred, tick, FocusMemoryDriver } from './helpers/focus-fixture.mjs';
import { TaskStatusController, draftFixture, statusTask, completeOperation, statusNow } from './helpers/task-status-fixture.mjs';
const read=p=>readFileSync(new URL(`../entry/src/main/ets/${p}.ets`,import.meta.url),'utf8');
const clean=s=>s.replace(/^import [^\n]+;\r?\n/gm,'');
const loadPure=async n=>import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(clean(read('utils/'+n)))).toString('base64')}`);
const navigation=await loadPure('AppNavigation'),history=await loadPure('LocalHistoryStore');
function component(name,deps){const src=read('pages/'+name),end=src.indexOf('\n  @Builder');assert.ok(end>0);
 const js=stripTypeScriptTypes(clean(src.slice(0,end)).replace(/^@(Entry|Component)\r?\n/gm,'').replace(/@(State|Prop)\s+|@(Watch|StorageLink)\('[^']+'\)\s*/g,'').replace(`export struct ${name}`,`class ${name}`).replace(`struct ${name}`,`class ${name}`)+'\n}');
 return new Function(...Object.keys(deps),js+`\nreturn ${name}`)(...Object.values(deps));}
function panel(state={...emptyFocusState(),phase:'ready'}){const Page=component('FocusPage',{emptyFocusState}),p=new Page();p.state=structuredClone(state);p.taskId='task-a';p.taskTitle='核对这项真实任务';p.aboutToAppear();return p;}
function local(extra={}){return {recordId:uuid(20),taskId:'task-a',mode:'online',localState:'paused',elapsedMs:1000,targetMs:null,confirmedElapsedMs:0,unknownGapCount:0,saveState:'saved',canPause:false,canResume:true,canEnd:true,...extra};}
async function entry(options={}){
 const f=focusEntryFixture(options.driver??new FocusMemoryDriver());await f.ready;
 const drafts=await draftFixture(undefined,history.historyScope('https://example.test','account-a'));
 const remote=options.api??new FocusApi(),calls=[];let sequence=100;const task=options.task??statusTask();
 class Api extends FocusApi {
  constructor(base,token){super();this.base=base;this.token=token;}
  submitFocusOperation(...args){return remote.submitFocusOperation(...args);}focusOperation(...args){return remote.focusOperation(...args);}
  focusActive(...args){return remote.focusActive(...args);}focusDetail(...args){return remote.focusDetail(...args);}focusList(...args){return remote.focusList(...args);}
  async planning(){calls.push(['planning',this.base,this.token]);return options.planning?options.planning():{tasks:[task],plans:[]};}
  async startTaskStatus(id,request){calls.push(['task-status',id,structuredClone(request)]);return completeOperation(task,request);}
  async logout(){calls.push(['logout',this.base,this.token]);if(options.logout)await options.logout();}
 }
 class Status {constructor(store,changed,applied,id){return new TaskStatusController(store,changed,applied,id,()=>statusNow);}}
 const Page=component('Index',{...navigation,...f.dependencies,localDrafts:drafts.store,TaskStatusController:Status,
  timetableOperationId:()=>uuid(++sequence),historyScope:history.historyScope,CampusFlowApi:Api,
  localHistory:{activate:async()=>{},clear:async()=>{},info:()=>({scope:'account',count:0,displayName:''})},
  AppStorage:{setOrCreate(){}},AppTheme:{motion:()=>0},Curve:{EaseOut:0}});
 const page=new Page();page.baseUrl='https://example.test';page.authBaseUrl=page.baseUrl;page.token='token-a';page.user={user_id:'account-a',display_name:'同学',onboarding_complete:true};page.authRevision=1;page.draftLease=drafts.lease;
 page.reminders={refresh(){calls.push(['reminder-refresh']);},setActive(){},dispose(){},logout:async()=>{},configure(){}};
 page.getUIContext=()=>({animateTo:(_,fn)=>fn()});page.configureTaskStatuses();await page.configureFocus();await tick();
 return {...f,page,remote,calls,drafts,task};
}

test('optional goal and explicit local mode: zero, fractions and over-limit values never start; clock unprobed can retry',()=>{
 const p=panel(),calls=[];p.onStart=(...a)=>calls.push(a);assert.equal(p.state.clockAvailable,false);assert.equal(p.startAllowed(),true);
 p.startRequested();assert.deepEqual(calls,[['task-a',null,'online']]);
 for(const text of ['0','1.5','241','-1','abc']){p.targetText=text;p.startRequested();assert.equal(p.targetText,text);assert.match(p.inputMessage,/1–240/);}
 assert.equal(calls.length,1);p.targetText=' 25 ';p.offline=true;p.startRequested();assert.deepEqual(calls[1],['task-a',1500000,'offline']);
 p.active=false;p.startRequested();assert.equal(calls.length,2);
});
test('goal reached is only a label at exact/over target; duration is forward elapsed and no end/completion callback fires',()=>{
 const p=panel(),calls=[];p.onEnd=()=>calls.push('end');p.onCompleteTask=()=>calls.push('complete');
 assert.equal(p.targetReached(local({targetMs:null,elapsedMs:999999})),false);
 assert.equal(p.targetReached(local({targetMs:60000,elapsedMs:59999})),false);
 assert.equal(p.targetReached(local({targetMs:60000,elapsedMs:60000})),true);
 assert.equal(p.targetReached(local({targetMs:60000,elapsedMs:62000})),true);assert.equal(p.duration(62000),'1:02');assert.deepEqual(calls,[]);
});
test('end, remote end and delete require explicit confirmation of exact currently displayed ID/revision',()=>{
 const rec=focusRecord(uuid(20),{state:'paused',revision:2,segment_id:null,clock_session_id:null});const p=panel({...emptyFocusState(),phase:'ready',local:local(),record:rec,selectedRecordId:rec.record_id,activeRecord:rec});const calls=[];
 p.onEnd=()=>calls.push('end');p.onRemoteEnd=(...a)=>calls.push(a);p.onDelete=(...a)=>calls.push(a);
 p.askEnd();assert.deepEqual(calls,[]);p.confirmAction();assert.deepEqual(calls,['end']);
 p.askRemoteEnd(rec);p.state.activeRecord={...rec,revision:3};p.stateChanged();p.confirmAction();assert.equal(calls.length,1);
 p.askDelete(rec);p.state.record={...rec,revision:3};p.confirmAction();assert.equal(calls.length,1);
 p.state.record=rec;p.askDelete(rec);p.confirmAction();assert.deepEqual(calls[1],[rec.record_id,2]);
});
test('selected record owns completion and remote pause resume; missing tasks never offer completion',()=>{
 const p=panel({...emptyFocusState(),phase:'ready',selectedRecordId:uuid(22),record:focusRecord(uuid(22),{task_id:'task-b',state:'ended',ended_at:new Date().toISOString()})});const calls=[];p.onCompleteTask=id=>calls.push(id);p.completeRequested();assert.deepEqual(calls,['task-b']);
 p.state.record.task_missing=true;assert.equal(p.completionTaskId(),'');
 p.state.record={...p.state.record,task_missing:false,state:'paused',revision:4};p.onResume=()=>calls.push('resume');p.resumeRemoteRecord(p.state.record);assert.equal(calls.at(-1),'resume');
 p.state.pendingOperations=[{operationId:uuid(99)}];p.resumeRemoteRecord(p.state.record);assert.equal(calls.filter(x=>x==='resume').length,1);
});
test('full interval and gap pagination remains reachable, and operation IDs are only revealed by explicit details',()=>{
 const p=panel();p.state.intervals=Array.from({length:43},(_,i)=>({interval_id:uuid(i+1)}));p.state.unknownGaps=Array.from({length:22},(_,i)=>({gap_id:uuid(i+1)}));
 const seen=[];for(let i=0;i<3;i++){p.intervalPage=i;seen.push(...p.visibleIntervals());}assert.equal(new Set(seen.map(x=>x.interval_id)).size,43);
 p.gapPage=1;assert.equal(p.visibleGaps().length,2);assert.deepEqual(p.expandedOperations,[]);p.toggleOperationDetails(uuid(1));assert.deepEqual(p.expandedOperations,[uuid(1)]);p.toggleOperationDetails(uuid(1));assert.deepEqual(p.expandedOperations,[]);
});
test('Index owns a single focus controller while tabs change; foreground pause uses monotonic prefix without completing a task',async()=>{
 const f=await entry();try{f.page.openFocus(f.task);const manager=f.page.focusManager;await manager.start(f.task.task_id,null,'offline');await f.scheduler.step(f.clock,5000);
 f.page.closeFocus();f.page.selectTab(2);assert.equal(f.page.focusManager,manager);assert.equal(manager.snapshot().local.elapsedMs,5000);
 f.page.voiceForeground=false;f.page.reminderActivityChanged();await tick();assert.equal(manager.snapshot().local.localState,'paused');assert.equal(manager.snapshot().local.elapsedMs,5000);
 assert.equal(f.calls.some(c=>c[0]==='task-status'),false);assert.equal(f.remote.calls.some(c=>c[0]==='post'),false);
 }finally{f.page.aboutToDisappear();}
});
test('ending focus never completes a task; explicit complete reads latest version then uses the existing durable UX08 controller',async()=>{
 const latest=statusTask({title:'后来修改的标题',task_version:7,start_at:'2030-10-19T12:00:00+08:00'}),f=await entry({task:latest});
 try{f.page.openFocus(latest);await f.page.focusManager.start(latest.task_id,null,'offline');await f.scheduler.step(f.clock,4000);await f.page.focusManager.end();assert.equal(f.calls.some(c=>c[0]==='task-status'),false);
 await f.page.completeFocusTask(latest.task_id);const write=f.calls.find(c=>c[0]==='task-status');assert.equal(write[1],latest.task_id);assert.equal(write[2].expected_revision,7);assert.equal(write[2].kind,'complete');assert.ok(f.calls.findIndex(c=>c[0]==='planning')<f.calls.findIndex(c=>c[0]==='task-status'));assert.equal(f.page.taskStatusState.items[0].phase,'applied');
 assert.equal(f.page.focusManager.snapshot().local.localState,'ended');
 }finally{f.page.aboutToDisappear();}
});
test('latest completed/missing/unreadable task does not trigger restore or any state write',async()=>{
 for(const mode of ['completed','missing','error']){const f=await entry({planning:async()=>{if(mode==='error')throw Error('private');return{tasks:mode==='missing'?[]:[statusTask({status:'completed'})]};}});
 try{f.page.openFocus(f.task);await f.page.focusManager.start('task-a',null,'offline');await f.page.focusManager.end();await f.page.completeFocusTask('task-a');assert.equal(f.calls.some(c=>c[0]==='task-status'),false);assert.match(f.page.focusNotice,mode==='completed'?/已经完成/:mode==='missing'?/不存在/:/尚未核对成功/);}finally{f.page.aboutToDisappear();}}
});
test('a task read abandoned by focus navigation cannot submit late or leave the next view busy forever',async()=>{
 const wait=deferred(),f=await entry({planning:()=>wait.promise});try{f.page.openFocus(f.task);await f.page.focusManager.start('task-a',null,'offline');await f.page.focusManager.end();const reading=f.page.completeFocusTask('task-a');assert.equal(f.page.focusCompletingTask,true);
 f.page.closeFocus();f.page.openFocus(f.task);assert.equal(f.page.focusCompletingTask,false);wait.resolve({tasks:[f.task]});await reading;assert.equal(f.calls.some(c=>c[0]==='task-status'),false);
 }finally{f.page.aboutToDisappear();}
});
test('unknown focus submit remains exact-ID query and crossing tabs never creates another operation',async()=>{
 const f=await entry();try{f.remote.submitHook=async()=>{throw Error('ambiguous')};f.page.openFocus(f.task);await f.page.focusManager.start('task-a',null,'online');const original=f.page.focusState.pendingOperations[0];assert.equal(original.phase,'unknown');
 f.page.closeFocus();f.page.selectTab(2);f.page.openFocus();await f.page.focusManager.check(original.operationId);assert.equal(f.remote.calls.filter(c=>c[0]==='post').length,1);assert.equal(f.page.focusState.pendingOperations[0].operationId,original.operationId);assert.equal(f.page.focusState.pendingOperations[0].canRetry,true);
 }finally{f.page.aboutToDisappear();}
});
test('logout warns for local unsynced focus, closes auth immediately on confirmation, and cleanup failure remains retryable',async()=>{
 const f=await entry();try{await f.page.focusManager.start('task-a',null,'offline');f.page.requestLogout();assert.equal(f.page.pendingLogoutConfirm,true);assert.equal(f.page.token,'token-a');
 f.driver.failRemove=true;const leaving=f.page.confirmAccountExit();assert.equal(f.page.token,'');await leaving;assert.equal(f.page.focusCleanupNeeded,true);assert.match(f.page.focusNotice,/尚未清理/);
 f.driver.failRemove=false;await f.page.clearLocalFocus();assert.equal(f.page.focusClearConfirm,true);await f.page.clearLocalFocus();assert.equal(f.page.focusCleanupNeeded,false);assert.equal(f.driver.text,undefined);
 }finally{f.page.aboutToDisappear();}
});
test('service edit retains authenticated URL until explicit cleanup; an older exit cannot overwrite a new sign-in URL',async()=>{
 const wait=deferred(),f=await entry({logout:()=>wait.promise});try{f.page.baseUrl='https://new.test';f.page.reminderAccountChanged();assert.equal(f.page.serviceBaseUrl(),'https://example.test');assert.equal(f.page.pendingServiceUrl,'https://new.test');const leaving=f.page.confirmAccountExit();
 f.page.authRevision++;f.page.baseUrl='https://newer.test';f.page.token='newer-token';f.page.authBaseUrl=f.page.baseUrl;wait.resolve();await leaving;assert.equal(f.page.baseUrl,'https://newer.test');assert.equal(f.page.token,'newer-token');
 }finally{f.page.aboutToDisappear();}
});
test('Entry initialization waits for focus file read and reports failure without hiding online login',async()=>{
 const source=read('entryability/EntryAbility').replace(/^import [^\n]+;\r?\n/gm,'').replace('export default class','class');const pending=deferred(),loaded=[],stored=new Map();
 const Ability=new Function('UIAbility','initializeLocalFocus','initializeLocalDrafts','initializeLocalHistory','AppStorage',stripTypeScriptTypes(source)+'\nreturn EntryAbility;')(class{},()=>pending.promise,async()=>{},async()=>{}, {setOrCreate:(key,value)=>stored.set(key,value)});
 const ability=new Ability();ability.context={filesDir:'/app-private'};ability.onWindowStageCreate({loadContent:v=>loaded.push(v)});await tick();assert.deepEqual(loaded,[]);pending.reject(Error('privatepath'));await tick();assert.deepEqual(loaded,['pages/Index']);assert.match(stored.get('localFocusError'),/原文件保留/);assert.doesNotMatch(stored.get('localFocusError'),/privatepath/);
});
