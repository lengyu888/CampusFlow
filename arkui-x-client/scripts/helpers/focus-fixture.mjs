import './theme-fixture.mjs';
import { readFileSync } from 'node:fs';
import { stripThemeTypeScriptTypes as stripTypeScriptTypes } from './theme-fixture.mjs';
const read=n=>readFileSync(new URL(`../../entry/src/main/ets/utils/${n}.ets`,import.meta.url),'utf8');
const clean=s=>s.replace(/^import \{[\s\S]*?\} from '[^']+';\r?\n/gm,'').replace(/^import [^\n]+;\r?\n/gm,'');
const load=(n,deps,names)=>new Function(...Object.keys(deps),stripTypeScriptTypes(clean(read(n)).replace(/^export /gm,''))+`\nreturn {${names.join(',')}}`)(...Object.values(deps));
const agenda=await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(clean(read('DailyAgenda')))).toString('base64')}`);
const feedback=await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(clean(read('AgentFeedback')))).toString('base64')}`);
export const {CampusFlowRequestError}=feedback;
export const digests=load('FocusDigest',agenda,['focusSha256','focusRequestDigest']);
export const validation=load('FocusValidation',{...agenda,...digests},['focusUuid','focusInteger','focusKeys','focusIso','focusTarget','validFocusInterval','validFocusGap','validFocusPieces','validFocusRequest','validFocusOperation','validFocusRecord','validFocusDetail','validFocusActive','validFocusList']);
export const timers=load('FocusTimer',{},['FocusTimer','validFocusSample','copyFocusAnchor','FOCUS_SAMPLE_MS','FOCUS_CHECKPOINT_MS','FOCUS_MAX_SAMPLE_MS','FOCUS_WALL_TOLERANCE_MS']);
export const stores=load('FocusStore',{...validation,...timers},['FocusStore','FocusScopeError','focusBytes','cloneFocusDocument','validFocusAnchor','MAX_FOCUS_BYTES']);
export const {FocusStore}=stores;
export const {FocusController,emptyFocusState}=load('FocusController',{...validation,...timers,...stores,...feedback},['FocusController','emptyFocusState']);
export const uuid=n=>`10000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
export const wall=Date.parse('2030-10-19T09:00:00+08:00');
export const tick=async()=>{for(let i=0;i<120;i++)await Promise.resolve();};
export const deferred=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b});return {promise,resolve,reject};};
export class FocusMemoryDriver {
 text; failWrite=false;failRemove=false;beforeWrite=null;writes=0;
 async read(){return this.text;}
 async write(text){this.writes++;if(this.beforeWrite)await this.beforeWrite(text);if(this.failWrite)throw Error('disk');this.text=text;}
 async remove(){if(this.failRemove)throw Error('remove');this.text=undefined;}
}
export class FakeFocusClock {
 wallMs=wall;monotonicMs=1000;clockSessionId=uuid(9000);failure=false;pending=null;
 async sample(){if(this.pending)return this.pending;if(this.failure)throw Error('clock');return {wallMs:this.wallMs,monotonicMs:this.monotonicMs,clockSessionId:this.clockSessionId};}
 advance(ms){this.wallMs+=ms;this.monotonicMs+=ms;}
}
export class FocusSchedule {
 jobs=new Map();sequence=0;
 setTimeout(callback){const id=++this.sequence;this.jobs.set(id,callback);return id;}
 clearTimeout(id){this.jobs.delete(id);}
 async step(clock,ms=1000){clock.advance(ms);const jobs=[...this.jobs.values()];this.jobs.clear();for(const job of jobs)job();await tick();}
}
export function focusRecord(id=uuid(2),extra={}){
 return {contract_version:1,user_id:'account-a',record_id:id,task_id:'task-a',task_title:'真实任务标题',task_missing:false,state:'running',revision:1,
 creator_device_id:uuid(1),current_device_id:uuid(1),clock_session_id:uuid(9000),segment_id:uuid(3),started_at:new Date(wall).toISOString(),ended_at:null,target_ms:null,
 confirmed_elapsed_ms:0,interval_count:0,unknown_gap_count:0,created_at:new Date(wall).toISOString(),updated_at:new Date(wall).toISOString(),...extra};
}
export function focusReceipt(recordId,request,before=null){
 const intervals=request.intervals??[],gaps=request.unknown_gaps??[];
 return {contract_version:1,user_id:'account-a',operation_id:request.operation_id,record_id:recordId,kind:request.kind,request_digest:digests.focusRequestDigest('account-a',recordId,request),receipt:{
 before_revision:request.expected_revision,after_revision:request.expected_revision+1,before_state:request.kind==='start'?null:(before??(request.kind==='resume'?'paused':request.kind==='pause'?'running':request.segment_id?'running':'paused')),
 after_state:request.kind==='start'||request.kind==='resume'?'running':request.kind==='pause'?'paused':request.kind==='delete'?'deleted':'ended',
 accepted_interval_ids:intervals.map(x=>x.interval_id),accepted_gap_ids:request.reason==='remote_end'&&before==='running'?[uuid(9990)]:gaps.map(x=>x.gap_id),
 added_elapsed_ms:intervals.reduce((a,b)=>a+b.elapsed_ms,0),applied_at:new Date(wall).toISOString()}};
}
export class FocusApi {
 calls=[];records=new Map();intervals=new Map();gaps=new Map();receipts=new Map();submitHook=null;
 async submitFocusOperation(recordId,request){
  this.calls.push(['post',recordId,structuredClone(request)]);if(this.submitHook)return this.submitHook(recordId,request);
  if(this.receipts.has(request.operation_id))return structuredClone(this.receipts.get(request.operation_id));
  const old=this.records.get(recordId);if(request.kind!=='start'&&(!old||old.revision!==request.expected_revision))throw new CampusFlowRequestError(409,'FOCUS_STALE','版本已变化');
  const receipt=focusReceipt(recordId,request,old?.state??null);this.receipts.set(request.operation_id,receipt);
  if(request.kind==='delete'){this.records.delete(recordId);this.intervals.delete(recordId);this.gaps.delete(recordId);return structuredClone(receipt);}
  const record=old??focusRecord(recordId,{task_id:request.task_id,creator_device_id:request.device_id,current_device_id:request.device_id,target_ms:request.target_ms});
  record.state=receipt.receipt.after_state;record.revision=receipt.receipt.after_revision;record.current_device_id=request.device_id;
  record.segment_id=record.state==='running'?request.operation_id:null;record.clock_session_id=record.state==='running'?request.clock_session_id:null;
  record.ended_at=record.state==='ended'?request.occurred_at:null;
  this.intervals.set(recordId,(this.intervals.get(recordId)??[]).concat(request.intervals??[]));this.gaps.set(recordId,(this.gaps.get(recordId)??[]).concat(request.unknown_gaps??[]));
  record.confirmed_elapsed_ms+=receipt.receipt.added_elapsed_ms;record.interval_count=this.intervals.get(recordId).length;record.unknown_gap_count=this.gaps.get(recordId).length;
  this.records.set(recordId,record);return structuredClone(receipt);
 }
 async focusOperation(id){this.calls.push(['get-op',id]);if(!this.receipts.has(id))throw new CampusFlowRequestError(404,'FOCUS_OPERATION_NOT_FOUND','未查到');return structuredClone(this.receipts.get(id));}
 async focusActive(){this.calls.push(['active']);return {contract_version:1,user_id:'account-a',record:structuredClone([...this.records.values()].find(r=>r.state!=='ended')??null)};}
 async focusDetail(id){this.calls.push(['detail',id]);const record=this.records.get(id);if(!record)throw new CampusFlowRequestError(404,'FOCUS_NOT_FOUND','无记录');return {contract_version:1,user_id:'account-a',record:structuredClone(record),record_revision:record.revision,intervals:structuredClone(this.intervals.get(id)??[]),unknown_gaps:structuredClone(this.gaps.get(id)??[])};}
 async focusList(cursor='',token='',limit=20){this.calls.push(['list',cursor,token,limit]);return {contract_version:1,user_id:'account-a',records:structuredClone([...this.records.values()].filter(record=>record.state==='ended')),next_cursor:null,snapshot_token:'a'.repeat(64)};}
}
export async function focusFixture(options={}){
 const driver=options.driver??new FocusMemoryDriver(),store=new FocusStore(driver);await store.initialize();
 const clock=options.clock??new FakeFocusClock(),scheduler=new FocusSchedule(),api=options.api??new FocusApi(),changes=[];let id=options.firstId??0;
 const controller=new FocusController(store,clock,s=>changes.push(s),()=>uuid(++id),scheduler);
 await controller.configure(options.scope??'https://example.test|account-a',options.userId??'account-a',api);controller.setForeground(true);await tick();
 return {driver,store,clock,scheduler,api,controller,changes,state:()=>controller.snapshot(),doc:()=>JSON.parse(driver.text)};
}
