import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';
import { conversationDependencies, assistantDraftKey } from './helpers/conversation-fixture.mjs';
import { reliability } from './helpers/course-review-fixture.mjs';
import { makeRunController, runSnapshot, shanghaiDate } from './helpers/agent-run-ui-fixture.mjs';
const load = async name => import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(readFileSync(new URL(`../entry/src/main/ets/utils/${name}.ets`,import.meta.url),'utf8').replace(/^import [^\n]+;\r?\n/gm,''))).toString('base64')}`);
const feedback=await load('AgentFeedback'); const {DraftStore}=await load('DraftStore');
const source=readFileSync(new URL('../entry/src/main/ets/pages/AgentPage.ets',import.meta.url),'utf8');
const methods=source.slice(0,source.indexOf('\n  @Builder')).replace(/^import [^\n]+;\r?\n/gm,'').replace(/^@Component\r?\n/m,'')
 .replace(/@(Prop|State)\s+|@Watch\('[^']+'\)\s*/g,'').replace('export struct AgentPage','class AgentPage')+'\n}';
const factory=new Function('CampusFlowApi','Scroller','localDrafts','shanghaiDate','AgentRunController','localHistory','AppTheme',
 ...Object.keys(feedback),...Object.keys(reliability),...Object.keys(conversationDependencies),stripTypeScriptTypes(methods)+'\nreturn AgentPage;');
const copy=value=>structuredClone(value);const now='2028-10-20T08:00:00+08:00';
const id='01234567-0123-4123-8123-012345678901';
const deferred=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b});return{promise,resolve,reject}};
const tick=async()=>{for(let i=0;i<60;i++)await Promise.resolve()};
class Disk {text;fail=false;gate=null;async read(){return this.text}async write(value){if(this.gate)await this.gate.promise;if(this.fail)throw Error('disk');this.text=value}async remove(){this.text=undefined}}
async function fixture(handlers={},disk=new Disk()){
 const store=new DraftStore(disk,{now:()=>Date.now(),set:()=>1,clear(){}});await store.initialize();const lease=await store.activate('account-a@service-a');const calls=[];
 class Api {invoke(name,args){calls.push({name,args:copy(args)});assert.equal(typeof handlers[name],'function',`unexpected ${name}`);return handlers[name](...args)}
 sessionContext(...a){return this.invoke('sessionContext',a)} startAgentRun(...a){return this.invoke('startAgentRun',a)}
 agentRun(...a){return this.invoke('agentRun',a)} agentRunEvents(...a){return this.invoke('agentRunEvents',a)}
 confirmAction(...a){return this.invoke('confirmAction',a)}cancelAction(...a){return this.invoke('cancelAction',a)}
 actionStatus(...a){return this.invoke('actionStatus',a)}coursePermissions(...a){return this.invoke('coursePermissions',a)}
 history(...a){return this.invoke('history',a)} models(){return Promise.resolve({models:[],default_model:''})}}
 const Page=factory(Api,class{scrollTo(){}scrollEdge(){}},store,shanghaiDate,makeRunController(feedback.CampusFlowRequestError,feedback.localRequestFailure),
 {save:async()=>true},{},...Object.values(feedback),...Object.values(reliability),...Object.values(conversationDependencies));
 const page=new Page();page.baseUrl='https://service.invalid';page.token='secret';page.userId='account-a';page.historyScope=lease.scope;
 page.sessionId='session-a';page.voiceActive=true;page.draftLease=lease;page.newRunId=()=>id;page.bindDraftLease();
 return{page,store,lease,disk,calls};
}
function context(session='session-b',revision='b'.repeat(64),extra=[]){const messages=[{role:'user',content:'原问题',created_at:now},{role:'assistant',content:'原回答',created_at:now},...extra];return{
 user_id:'account-a',session_id:session,summary:{session_id:session,title:`主题-${session}`,model_name:'deepseek-v4-pro',last_message:messages.at(-1).content,
 message_count:messages.length,created_at:now,updated_at:now},messages,context_revision:revision,active_run:null}}
function pending(){const task={title:'阅读资料',candidate_id:'candidate-a',allow_during_course:false,start_at:'2028-10-20T14:00:00+08:00',
 end_at:'2028-10-20T15:00:00+08:00',reminder_minutes:null,location:null};return{proposal_id:'proposal-a',action:'create',kind:'task',title:task.title,
 start_at:task.start_at,end_at:task.end_at,reminder_minutes:null,reason:null,payload:{task},conflicts:[],warnings:[],status:'pending',contract_version:2,
 created_at:new Date().toISOString(),expires_at:new Date(Date.now()+900000).toISOString(),target_task_id:null,target_plan_id:null,before_task:null,before_plan:null,receipt:null,
 course_policy_version:1,state_version:{timetable:1,planning:1},course_reviews:[{candidate_id:'candidate-a',task_id:null,allow_during_course:false,state:'none',
 review_digest:'a'.repeat(64),candidate_digest:'b'.repeat(64),requires_acknowledgement:false,revoke_only:false,school:'学校',campus:'校区',timezone:'Asia/Shanghai',
 timetable_version:1,planning_version:1,task_version:null,overlaps:[]}]}}
function replacement(action){const result=copy(action);result.proposal_id='replacement-a';result.payload.task.allow_during_course=true;
 result.course_reviews[0].allow_during_course=true;result.course_reviews[0].review_digest='c'.repeat(64);return result}
function cancelled(action){return{applied:false,receipt:null,action:{...copy(action),status:'cancelled'},message:''}}
function select(h,action=pending()){h.page.pendingActions=[action];return action}
function error(code,status=409){return new feedback.CampusFlowRequestError(status,code,'固定安全提示')}

// Production non-Builder methods and actual store/run controller. These are not native rendering tests.
test('new conversation saves original draft by session and stops local polling without cancelling the server run',async()=>{
 const h=await fixture();h.page.changePrompt('原会话未发');h.page.loading=true;let disposed=0;
 h.page.runInteraction={dispose(){disposed++}};h.page.requestConversation();assert.equal(h.page.switchConfirmOpen,true);
 await h.page.switchConversation();assert.notEqual(h.page.sessionId,'session-a');assert.equal(h.page.prompt,'');assert.equal(disposed,1);
 assert.equal(h.store.read(h.lease,assistantDraftKey('session-a')).payload.text,'原会话未发');assert.equal(h.calls.length,0);
});
test('failed draft flush never changes the conversation or clears text',async()=>{
 const h=await fixture();h.page.changePrompt('保留');h.disk.fail=true;h.page.requestConversation();await h.page.switchConversation();
 assert.equal(h.page.sessionId,'session-a');assert.equal(h.page.prompt,'保留');assert.equal(h.calls.length,0);
});
test('authoritative continue validates account/context and restores text only, never cached actions',async()=>{
 const h=await fixture({sessionContext:async()=>context()});h.page.pendingActions=[pending()];h.page.requestConversation('session-b');await h.page.switchConversation();
 assert.equal(h.page.sessionId,'session-b');assert.equal(h.page.contextRevision,'b'.repeat(64));assert.equal(h.page.sessionMode,'continue');
 assert.deepEqual(h.page.messages.map(x=>x.content),['原问题','原回答']);assert.deepEqual(h.page.pendingActions,[]);
});
test('wrong owner, empty history and context errors cannot replace current conversation',async()=>{
 for(const mode of ['owner','empty','failure']){
 const h=await fixture({sessionContext:async()=>{if(mode==='failure')throw error('SESSION_NOT_FOUND',404);const c=context();if(mode==='owner')c.user_id='other';else{c.messages=[];c.summary.message_count=0}return c}});
 h.page.changePrompt('当前输入');h.page.requestConversation('session-b');await h.page.switchConversation();assert.equal(h.page.sessionId,'session-a');assert.equal(h.page.prompt,'当前输入');
 }
});
test('latest requested session supersedes an outstanding read and either prop order is coalesced',async()=>{
 const a=deferred();const h=await fixture({sessionContext:async value=>value==='session-b'?a.promise:context(value)});
 h.page.requestedSessionId='session-b';h.page.sessionRequested();h.page.resumeRevision=1;h.page.sessionRequested();await tick();assert.equal(h.page.sessionLoading,true);
 h.page.resumeRevision=2;h.page.sessionRequested();h.page.requestedSessionId='session-c';h.page.sessionRequested();await tick();
 assert.equal(h.page.sessionId,'session-c');a.resolve(context('session-b'));await tick();assert.equal(h.page.sessionId,'session-c');
});
test('hide or credential change discards a late context response',async()=>{
 for(const mode of ['hide','connection']){const gate=deferred();const h=await fixture({sessionContext:()=>gate.promise});
 h.page.requestConversation('session-b');await tick();if(mode==='hide'){h.page.voiceActive=false;h.page.voiceActivityChanged()}else{h.page.token='changed';h.page.modelConnectionChanged()}
 gate.resolve(context());await tick();assert.equal(h.page.sessionId,'session-a');assert.equal(h.page.contextRevision,'');}
});
test('context refresh adopts authoritative new turns without overwriting prompt or recreating proposals',async()=>{
 const next=context('session-a','c'.repeat(64),[{role:'user',content:'另一端新增',created_at:now},{role:'assistant',content:'新答案',created_at:now}]);
 const h=await fixture({sessionContext:async()=>next});h.page.enterConversation('session-a',context('session-a'));h.page.changePrompt('当前新草稿');
 const original=pending();h.page.pendingActions=[original];h.page.linkProposals(h.page.messages[1].id,[original]);const anchor=h.page.messages[1].id;
 await h.page.refreshSessionContext();assert.equal(h.page.prompt,'当前新草稿');assert.equal(h.page.contextRevision,'c'.repeat(64));
 assert.deepEqual(h.page.messages.map(x=>x.content),next.messages.map(x=>x.content));assert.equal(h.page.proposalOrigins[0].messageId,anchor);assert.equal(h.page.pendingActions.length,1);
});
test('two refreshes cannot roll the context revision backward',async()=>{
 const first=deferred();let count=0;const h=await fixture({sessionContext:()=>++count===1?first.promise:Promise.resolve(context('session-a','d'.repeat(64)))});
 const old=h.page.refreshSessionContext();await h.page.refreshSessionContext();first.resolve(context('session-a','c'.repeat(64)));await old;
 assert.equal(h.page.contextRevision,'d'.repeat(64));
});
test('continue send persists exact mode/revision; success obtains the next authoritative revision',async()=>{
 let request;const next=context('session-a','e'.repeat(64));const h=await fixture({startAgentRun:async value=>{request=value;return runSnapshot(value,{message:'完成',pending_actions:[]})},
 sessionContext:async()=>next,history:async()=>next.messages});h.page.enterConversation('session-a',context('session-a','d'.repeat(64)));h.page.changePrompt('下一轮');await h.page.send();await tick();
 assert.equal(request.session_mode,'continue');assert.equal(request.expected_context_revision,'d'.repeat(64));assert.equal(h.page.contextRevision,'e'.repeat(64));
 assert.equal(h.page.sessionMode,'continue');
});
test('first-turn running recovery uses owned run when context is not yet created; no new POST',async()=>{
 const req={run_id:id,session_id:'session-b',model:'deepseek-v4-pro',message:'首轮',session_mode:'new',expected_context_revision:null};
 const h=await fixture({sessionContext:async()=>{throw error('SESSION_NOT_FOUND',404)},agentRun:async()=>runSnapshot(req,null,{status:'running'})});
 h.page.requestRunConversation('session-b',id);await h.page.switchConversation();assert.equal(h.page.sessionId,'session-b');assert.equal(h.page.runState.snapshot.run_id,id);
 assert.equal(h.calls.some(x=>x.name==='startAgentRun'),false);assert.equal(h.page.loading,true);
});
test('unknown proposal blocks switching and survives restart for GET-only recovery',async()=>{
 const a=pending();const h=await fixture({confirmAction:async()=>{throw error('REQUEST_TIMEOUT',504)}});select(h,a);await h.page.decide(a,true);
 assert.equal(h.store.operations(h.lease).length,1);h.page.requestConversation();await h.page.switchConversation();assert.equal(h.page.sessionId,'session-a');
 const restarted=await fixture({actionStatus:async()=>a},h.disk);assert.equal(restarted.page.decisionOperations.length,1);
 await restarted.page.recoverDecisionOperation(restarted.page.decisionOperations[0]);assert.deepEqual(restarted.calls.map(x=>x.name),['actionStatus']);
 assert.equal(restarted.page.feedbackFor(a.proposal_id).code,'ACTION_RETRY');assert.equal(restarted.store.operations(restarted.lease).length,1);
});
test('a disk failure is a barrier before confirm and token change while waiting cannot POST to new credentials',async()=>{
 const h=await fixture();const a=select(h);h.disk.fail=true;await h.page.decide(a,true);assert.equal(h.calls.length,0);assert.equal(h.page.needsReview(a.proposal_id),true);
 const other=await fixture();const b=select(other);other.disk.gate=deferred();const deciding=other.page.decide(b,true);await tick();
 other.page.token='changed';other.page.modelConnectionChanged();other.disk.gate.resolve();await deciding;assert.equal(other.calls.length,0);
});
test('changing course permissions yields an explicit new preview and never confirms either candidate',async()=>{
 const a=pending();const h=await fixture({coursePermissions:async()=>replacement(a)});select(h,a);h.page.togglePermissionEditor(a);h.page.togglePermission(a.payload.task);
 await h.page.previewCoursePermissions(a);assert.deepEqual(h.calls.map(x=>x.name),['coursePermissions']);assert.equal(h.page.pendingActions[0].status,'cancelled');
 assert.equal(h.page.pendingActions[1].proposal_id,'replacement-a');assert.equal(h.page.pendingActions[1].status,'pending');assert.equal(h.store.operations(h.lease).length,0);
});
test('unknown permission replacement first queries original and follows only its exact replacement ID',async()=>{
 const a=pending();const next=replacement(a);let original={...copy(a),status:'cancelled',replacement_proposal_id:next.proposal_id};
 const h=await fixture({coursePermissions:async()=>{throw error('REQUEST_TIMEOUT',504)},actionStatus:async value=>value===a.proposal_id?original:next});select(h,a);
 h.page.togglePermissionEditor(a);h.page.togglePermission(a.payload.task);await h.page.previewCoursePermissions(a);assert.equal(h.store.operations(h.lease).length,1);
 await h.page.recoverDecisionOperation(h.page.decisionOperations[0]);assert.deepEqual(h.calls.map(x=>x.name),['coursePermissions','actionStatus','actionStatus']);
 assert.equal(h.store.operations(h.lease).length,0);assert.equal(h.page.pendingActions.find(x=>x.proposal_id==='replacement-a').status,'pending');
});
test('permission replacement cannot hide changed content or a mismatched returned replacement ID',async()=>{
 const a=pending();const changed=replacement(a);changed.payload.task.location='偷偷改地点';
 const h=await fixture({coursePermissions:async()=>changed});select(h,a);h.page.togglePermissionEditor(a);h.page.togglePermission(a.payload.task);await h.page.previewCoursePermissions(a);
 assert.equal(h.page.needsReview(a.proposal_id),true);assert.equal(h.page.pendingActions.length,1);assert.equal(h.store.operations(h.lease).length,1);
});
test('definite stale permission rejection clears the operation but does not replace old preview',async()=>{
 const h=await fixture({coursePermissions:async()=>{throw error('ACTION_STALE')}});const a=select(h);h.page.togglePermissionEditor(a);await h.page.previewCoursePermissions(a);
 assert.equal(h.store.operations(h.lease).length,0);assert.equal(h.page.requiresNewPreview(a),true);assert.equal(h.page.pendingActions.length,1);
});
test('adjustment waits for cancelled receipt then durably appends to existing text without auto run',async()=>{
 const a=pending();const h=await fixture({cancelAction:async()=>cancelled(a)});select(h,a);h.page.changePrompt('保留原输入');h.page.beginAdjustment(a);h.page.changeAdjustment('改到周五，持续25分钟');
 await h.page.decide(a,false);assert.equal(h.page.adjustmentReady,true);assert.equal(h.page.prompt,'保留原输入');
 await h.page.adoptAdjustment(true);assert.equal(h.page.prompt,'保留原输入\n改到周五，持续25分钟');assert.equal(h.page.adjustingProposalId,'');
 assert.deepEqual(h.calls.map(x=>x.name),['cancelAction']);assert.equal(h.store.read(h.lease,assistantDraftKey('session-a')).payload.text,h.page.prompt);
});
test('unknown adjustment cancellation retains the text and cannot generate a replacement until GET cancelled',async()=>{
 const a=pending();const h=await fixture({cancelAction:async()=>{throw error('REQUEST_TIMEOUT',504)},actionStatus:async()=>cancelled(a).action});select(h,a);
 h.page.beginAdjustment(a);h.page.changeAdjustment('明天30分钟');await h.page.decide(a,false);await h.page.adoptAdjustment(false);
 assert.equal(h.page.prompt,'');assert.equal(h.page.adjustmentReady,false);assert.equal(h.store.read(h.lease,{kind:'assistant',ownerId:'agent-adjustment:proposal-a'}).payload.text,'明天30分钟');
 await h.page.queryAdjustment();assert.equal(h.page.adjustmentReady,true);await h.page.adoptAdjustment(false);assert.equal(h.page.prompt,'明天30分钟');
});
test('a receipt cleanup failure retains both the unknown marker and adjustment lock',async()=>{
 const a=pending();const h=await fixture({cancelAction:async()=>{h.disk.fail=true;return cancelled(a)}});select(h,a);h.page.beginAdjustment(a);await h.page.decide(a,false);
 assert.equal(h.page.needsReview(a.proposal_id),true);assert.equal(h.page.adjustmentReady,false);assert.equal(h.store.operations(h.lease).length,1);
});
test('first voice interaction explains before probing and later explicit acceptance starts exactly once',async()=>{
 const h=await fixture();let probes=0,starts=0;h.page.probeVoice=async()=>{probes++;return true};h.page.voiceController=()=>({startListening:async()=>{starts++}});
 await h.page.startVoice();assert.equal(h.page.voiceExplanationOpen,true);assert.equal(probes,0);await h.page.acceptVoiceExplanation();
 assert.equal(probes,1);assert.equal(starts,1);assert.equal(h.page.prompt,'');
});
test('switching conversation cancels voice and a late capability check cannot start recording in the new session',async()=>{
 const h=await fixture();h.page.voiceExplanationAccepted=true;const gate=deferred();let starts=0,cancels=0;
 h.page.probeVoice=()=>gate.promise;h.page.voiceInteraction={cancel(){cancels++}};h.page.voiceController=()=>({startListening:async()=>starts++});
 const starting=h.page.startVoice();h.page.enterConversation('session-b',context());gate.resolve(true);await starting;assert.equal(starts,0);assert.equal(cancels,1);
});

test('unknown confirm then authoritative expired pending allows explicit same-ID cancel with an atomic intent replacement',async()=>{
 const a=pending();a.created_at=new Date(Date.now()-60000).toISOString();a.expires_at=new Date(Date.now()-1000).toISOString();const h=await fixture({actionStatus:async()=>a,cancelAction:async()=>cancelled(a)});select(h,a);
 await h.page.prepareDecision(a,true);assert.equal(h.store.operations(h.lease)[0].proposalRequest.intent,'confirm');
 await h.page.recoverDecisionOperation(h.page.decisionOperations[0]);assert.equal(h.page.feedbackFor(a.proposal_id).code,'ACTION_RETRY');
 await h.page.decide(a,false);assert.deepEqual(h.calls.map(x=>x.name),['actionStatus','cancelAction']);assert.equal(h.page.pendingActions[0].status,'cancelled');assert.equal(h.store.operations(h.lease).length,0);
});
test('intent replacement disk failure never sends cancel and keeps original confirmation pointer',async()=>{
 const a=pending();const h=await fixture({actionStatus:async()=>a});select(h,a);await h.page.prepareDecision(a,true);await h.page.recoverDecisionOperation(h.page.decisionOperations[0]);
 h.disk.fail=true;await h.page.decide(a,false);assert.deepEqual(h.calls.map(x=>x.name),['actionStatus']);
 assert.equal(h.store.operations(h.lease)[0].proposalRequest.intent,'confirm');assert.equal(h.page.needsReview(a.proposal_id),true);
});
test('explicit course overlap acknowledgements are exact and persist with the confirmation request',async()=>{
 const a=pending();a.payload.task.allow_during_course=true;const review=a.course_reviews[0];review.allow_during_course=true;review.state='needs_review';review.requires_acknowledgement=true;
 review.overlaps=[{course_key:'c'.repeat(64),course:{date:'2028-10-20',title:'软件工程',start_time:'14:30',end_time:'16:00',location:'311',teacher:'老师'},
 overlap_start_at:'2028-10-20T14:30:00+08:00',overlap_end_at:'2028-10-20T15:00:00+08:00'}];
 const h=await fixture({confirmAction:async()=>{throw error('REQUEST_TIMEOUT',504)}});select(h,a);await h.page.decide(a,true);assert.equal(h.calls.length,0);assert.equal(h.store.operations(h.lease).length,0);
 h.page.toggleCourseAck(a,review);await h.page.decide(a,true);assert.deepEqual(h.calls[0].args[1],[{candidate_id:'candidate-a',review_digest:'a'.repeat(64)}]);
 assert.deepEqual(h.store.operations(h.lease)[0].proposalRequest.course_acknowledgements,h.calls[0].args[1]);
});
test('restart retains adjustment description but requires original cancellation proof again',async()=>{
 const a=pending();const h=await fixture({cancelAction:async()=>cancelled(a)});select(h,a);h.page.beginAdjustment(a);h.page.changeAdjustment('新日期与时长');await h.page.decide(a,false);
 assert.equal(h.page.adjustmentReady,true);const restored=await fixture({actionStatus:async()=>cancelled(a).action},h.disk);
 assert.equal(restored.page.adjustmentText,'新日期与时长');assert.equal(restored.page.adjustmentReady,false);await restored.page.adoptAdjustment(false);assert.equal(restored.page.prompt,'');
 await restored.page.queryAdjustment();await restored.page.adoptAdjustment(false);assert.equal(restored.page.prompt,'新日期与时长');
});

test('permission query accepts an authoritative terminal result without fabricating a replacement',async()=>{
 const a=pending();const h=await fixture({coursePermissions:async()=>{throw error('REQUEST_TIMEOUT',504)},actionStatus:async()=>cancelled(a).action});select(h,a);
 h.page.togglePermissionEditor(a);await h.page.previewCoursePermissions(a);await h.page.recoverDecisionOperation(h.page.decisionOperations[0]);
 assert.equal(h.page.pendingActions[0].status,'cancelled');assert.equal(h.store.operations(h.lease).length,0);assert.equal(h.page.needsReview(a.proposal_id),false);
 assert.equal(h.page.pendingActions.length,1);
});

test('past terminal run is read-only and cannot revive its saved pending proposal',async()=>{
 const a=pending();const request={run_id:id,session_id:'session-a',model:'deepseek-v4-pro',message:'过去的问题'};
 const run=runSnapshot(request,{message:'过去的回答',pending_actions:[a]});const completed=context('session-a');completed.messages[0].content='过去的问题';completed.messages[1].content='过去的回答';completed.summary.last_message='过去的回答';
 const h=await fixture({agentRun:async()=>run,history:async()=>completed.messages,sessionContext:async()=>completed});
 h.page.runState.recent=[run];await h.page.recoverRun(id);await tick();assert.deepEqual(h.page.pendingActions,[]);assert.deepEqual(h.page.proposalOrigins,[]);
 assert.equal(h.page.messages.some(x=>x.content==='过去的回答'),true);assert.equal(h.calls.some(x=>x.name==='confirmAction'),false);
});
test('an unfinished recovered run reads each latest proposal state before exposing it',async()=>{
 const a=pending();const h=await fixture({actionStatus:async()=>cancelled(a).action,history:async()=>context('session-a').messages,sessionContext:async()=>context('session-a')});
 const run=runSnapshot({run_id:id,session_id:'session-a',model:'deepseek-v4-pro',message:'原问题'},{message:'回答',pending_actions:[a]});
 h.page.restoredRunIds=[id];h.page.liveRecoveredRunIds=[id];h.page.runState.snapshot=run;h.page.runSucceeded(run);assert.equal(h.page.pendingActions.length,0);await tick();
 assert.equal(h.page.pendingActions[0].status,'cancelled');assert.equal(h.calls.filter(x=>x.name==='actionStatus').length,1);
});
test('latest proposal read failure keeps a recovered result visibly read-only',async()=>{
 const a=pending();const h=await fixture({actionStatus:async()=>{throw error('REQUEST_TIMEOUT',504)},history:async()=>context('session-a').messages,sessionContext:async()=>context('session-a')});
 const run=runSnapshot({run_id:id,session_id:'session-a',model:'deepseek-v4-pro',message:'原问题'},{message:'回答',pending_actions:[a]});
 h.page.restoredRunIds=[id];h.page.liveRecoveredRunIds=[id];h.page.runSucceeded(run);await tick();assert.equal(h.page.pendingActions.length,0);
 assert.ok(h.page.messages.some(x=>x.content.includes('最新提案状态尚未核实')));
});
