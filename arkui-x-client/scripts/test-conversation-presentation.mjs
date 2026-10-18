import assert from 'node:assert/strict';
import { test } from 'node:test';
import { presentation as p } from './helpers/conversation-fixture.mjs';
const clone = value => structuredClone(value);
const date = '2028-10-20T08:00:00+08:00';
function task(title = '复习') { return { title, candidate_id: 'candidate-a', allow_during_course: false,
  start_at: '2028-10-20T14:00:00+08:00', end_at: '2028-10-20T15:00:00+08:00', reminder_minutes: null, location: null }; }
function action() { const item = task(); return { proposal_id:'proposal-a',action:'create',kind:'task',title:item.title,
 start_at:item.start_at,end_at:item.end_at,reminder_minutes:null,reason:null,payload:{task:item},conflicts:[],warnings:[],status:'pending',
 contract_version:2,created_at:date,expires_at:'2028-10-20T08:15:00+08:00',target_task_id:null,target_plan_id:null,before_task:null,before_plan:null,receipt:null,
 course_policy_version:1,state_version:{timetable:1,planning:1},course_reviews:[{candidate_id:'candidate-a',task_id:null,
 allow_during_course:false,state:'none',review_digest:'a'.repeat(64),candidate_digest:'b'.repeat(64),requires_acknowledgement:false,revoke_only:false,
 school:'学校',campus:'校区',timezone:'Asia/Shanghai',timetable_version:1,planning_version:1,task_version:null,overlaps:[]}] }; }
function context() { const messages=[{role:'user',content:'原问题',created_at:date},{role:'assistant',content:'原回答',created_at:date}];
 return {user_id:'account-a',session_id:'session-a',summary:{session_id:'session-a',title:'复习安排',model_name:'model',
  last_message:'原回答',message_count:2,created_at:date,updated_at:date},messages,context_revision:'a'.repeat(64),active_run:null}; }

test('session context requires exact owner, session, nonempty complete message list and revision',()=>{
 assert.equal(p.validSessionContext(context(),'account-a','session-a'),true);
 for(const mutate of [x=>x.user_id='other',x=>x.session_id='other',x=>x.summary.session_id='other',x=>x.context_revision='short',
 x=>{x.messages=[];x.summary.message_count=0},x=>x.messages[0].role='tool',x=>x.summary.message_count=1,
 x=>x.summary.created_at='bad',x=>x.summary.updated_at=null,x=>x.messages[0].created_at='bad']) {
  const value=context();mutate(value);assert.equal(p.validSessionContext(value,'account-a','session-a'),false);
 }
});
test('context active run must belong to the same session and be active',()=>{
 const value=context();value.active_run={session_id:'session-a',run_id:'01234567-0123-4123-8123-012345678901',status:'running'};
 assert.equal(p.validSessionContext(value,'account-a','session-a'),true);
 value.active_run.session_id='other';assert.equal(p.validSessionContext(value,'account-a','session-a'),false);
 value.active_run.session_id='session-a';value.active_run.status='succeeded';assert.equal(p.validSessionContext(value,'account-a','session-a'),false);
});
test('overview distinguishes complete time envelope from missing times and counts every milestone task',()=>{
 const value=action();value.kind='plan';value.title='两天计划';value.start_at=null;value.end_at=null;
 value.payload={summary:'学习',target_date:'2028-10-21',milestones:[{title:'阶段一',due_at:null,tasks:[task(),{...task('未定'),start_at:null,end_at:null}]},
 {title:'阶段二',due_at:null,tasks:[{...task('第二天'),start_at:'2028-10-21T10:00:00+08:00',end_at:'2028-10-21T11:00:00+08:00'}]}]};
 const summary=p.proposalOverview(value);assert.equal(summary.taskCount,3);assert.equal(summary.milestoneCount,2);
 assert.equal(summary.completeTimeCount,2);assert.equal(summary.incompleteTimeCount,1);assert.equal(summary.deadline,'2028-10-21');
 assert.match(summary.timeRange,/最早开始 2028-10-20 14:00/);assert.match(summary.timeRange,/最晚结束 2028-10-21 11:00/);
});
test('invalid or reversed times remain incomplete, not an invented scheduled duration',()=>{
 for(const values of [[null,null],['bad','bad'],['2028-10-20T15:00:00+08:00','2028-10-20T14:00:00+08:00']]) {
 const value=action();[value.payload.task.start_at,value.payload.task.end_at]=values;
 assert.equal(p.proposalOverview(value).completeTimeCount,0);assert.equal(p.proposalOverview(value).incompleteTimeCount,1);
 }
});
test('a permission replacement permits only selected flags plus regenerated policy, not changed content or IDs',()=>{
 const original=action();const replacement=clone(original);replacement.proposal_id='replacement-a';replacement.payload.task.allow_during_course=true;
 replacement.course_reviews[0].allow_during_course=true;replacement.course_reviews[0].review_digest='c'.repeat(64);
 const choices=[{candidate_id:'candidate-a',allow_during_course:true}];assert.equal(p.samePermissionReplacement(original,replacement,choices),true);
 for(const mutate of [x=>x.payload.task.title='偷偷改名',x=>x.payload.task.location='别处',x=>x.payload.task.candidate_id='other',
 x=>{x.payload.task.start_at='2028-10-20T13:00:00+08:00';x.start_at=x.payload.task.start_at}]) {
 const changed=clone(replacement);mutate(changed);assert.equal(p.samePermissionReplacement(original,changed,choices),false);
 }
 assert.equal(p.samePermissionReplacement(original,replacement,[null]),false);
 assert.equal(p.samePermissionReplacement(original,replacement,[...choices,...choices]),false);
 assert.equal(p.samePermissionReplacement(original,replacement,[{candidate_id:'unknown',allow_during_course:true}]),false);
});
test('proposal evidence is from actual tool records and preserves unknown freshness',()=>{
 assert.deepEqual(p.proposalSources([]),[]);
 const evidence={source_id:'school-page',kind:'reference',label:'学校资料',status:'unverified',updated_at:null,expires_at:null,url:null,note:'静态核对'};
 const result=p.proposalSources([{label:'查询',state:'success',summary:'完成',evidence:[evidence,evidence]}]);
 assert.equal(result.length,1);assert.equal(result[0].status,'unverified');assert.equal(result[0].expires_at,null);
});
