import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {stripTypeScriptTypes} from 'node:module';
import {test} from 'node:test';
const read=name=>readFileSync(new URL(`../entry/src/main/ets/${name}.ets`,import.meta.url),'utf8');
const plain=s=>stripTypeScriptTypes(s.replace(/^import \{[\s\S]*?\} from '[^']+';\r?\n/gm,'').replace(/^import [^\n]+;\r?\n/gm,''));
const module=async name=>import(`data:text/javascript;base64,${Buffer.from(plain(read(name))).toString('base64')}`);
const feedback=await module('utils/AgentFeedback'),agenda=await module('utils/DailyAgenda');
const {validFocusRequest}=new Function('timestamp',plain(read('utils/FocusValidation')).replace(/^export /gm,'')+'\nreturn {validFocusRequest};')(agenda.timestamp);
const create=new Function('http','CampusFlowRequestError','localRequestFailure','requestFailure','validFocusRequest',plain(read('services/CampusFlowApi')).replace(/^export /gm,'')+'\nreturn CampusFlowApi;');
function fixture(response={responseCode:200,result:'{}'}){
 const calls=[];let disposed=0;
 const http={RequestMethod:{GET:'GET',POST:'POST'},HttpDataType:{STRING:'STRING'},createHttp:()=>({async request(url,options){calls.push({url,options});if(response instanceof Error)throw response;return response;},destroy(){disposed++;}})};
 const Api=create(http,feedback.CampusFlowRequestError,feedback.localRequestFailure,feedback.requestFailure,validFocusRequest);
 return{api:new Api('https://fixture.invalid','synthetic-token'),calls,disposed:()=>disposed};
}
const id=n=>`10000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
const common={operation_id:id(1),device_id:id(2),occurred_at:'2030-10-19T09:00:00+08:00'};
const start={...common,kind:'start',expected_revision:0,task_id:'task-a',clock_session_id:id(3),target_ms:null};
const interval={interval_id:id(4),segment_id:id(1),clock_session_id:id(3),sequence:1,started_at:'2030-10-19T09:00:00+08:00',ended_at:'2030-10-19T09:01:00+08:00',elapsed_ms:60000};
test('focus HTTP adapter preserves exact operation identities and bodies for all five mutations',async()=>{
 const f=fixture();const requests=[start,{...common,kind:'pause',expected_revision:1,segment_id:id(1),clock_session_id:id(3),intervals:[interval],unknown_gaps:[]},
 {...common,kind:'resume',expected_revision:2,clock_session_id:id(3)},
 {...common,kind:'end',expected_revision:3,reason:'remote_end',segment_id:null,clock_session_id:null,intervals:[],unknown_gaps:[]},
 {...common,kind:'delete',expected_revision:4}];
 for(const request of requests)await f.api.submitFocusOperation('record/a?b',request);
 assert.equal(f.calls.length,5);for(let i=0;i<5;i++){assert.equal(f.calls[i].url,'https://fixture.invalid/api/v1/focus-records/record%2Fa%3Fb/operations');assert.equal(f.calls[i].options.method,'POST');assert.equal(f.calls[i].options.extraData,JSON.stringify(requests[i]));assert.equal(f.calls[i].options.header.Authorization,'Bearer synthetic-token');}
 assert.equal(f.disposed(),5);
});
test('raw uptime and unexpected checkpoint fields are rejected before any HTTP request is created',async()=>{
 const f=fixture();const pause={...common,kind:'pause',expected_revision:1,segment_id:id(1),clock_session_id:id(3),intervals:[interval],unknown_gaps:[]};
 for(const request of [{...start,monotonic_ms:12345},{...start,checkpoint:{mono_start:123}},{...pause,intervals:[{...interval,mono_end:123456}]},
 {...pause,unknown_gaps:[{gap_id:id(5),segment_id:id(1),reason:'sample_gap',observed_start_at:common.occurred_at,observed_end_at:null,raw:'private'}]},
 {...start,task_title:'private'}, {...start,expected_revision:1}])await assert.rejects(f.api.submitFocusOperation(id(9),request),e=>e.code==='FOCUS_INVALID'&&e.statusCode===422);
 assert.equal(f.calls.length,0);assert.equal(f.disposed(),0);
});
test('focus reads are GET-only and encode cursor and frozen snapshot token separately',async()=>{
 const f=fixture();await f.api.focusOperation('op/a');await f.api.focusActive();await f.api.focusDetail('record/a');await f.api.focusList();await f.api.focusList('next+/=&','snap?/+',37);
 assert.deepEqual(f.calls.map(c=>[c.url,c.options.method,c.options.extraData]),[
 ['https://fixture.invalid/api/v1/focus-operations/op%2Fa','GET',''],['https://fixture.invalid/api/v1/focus-records/active','GET',''],
 ['https://fixture.invalid/api/v1/focus-records/record%2Fa','GET',''],['https://fixture.invalid/api/v1/focus-records?limit=20','GET',''],
 ['https://fixture.invalid/api/v1/focus-records?limit=37&cursor=next%2B%2F%3D%26&snapshot_token=snap%3F%2F%2B','GET','']]);
});
test('all focus paths retain controlled errors without raw private provider or database diagnostics',async()=>{
 const codes=['FOCUS_NOT_FOUND','FOCUS_OPERATION_NOT_FOUND','FOCUS_TASK_NOT_FOUND','FOCUS_DELETED','FOCUS_OPERATION_REUSED','FOCUS_STALE','FOCUS_ACTIVE_EXISTS','FOCUS_STATE_INVALID','FOCUS_SEGMENT_MISMATCH','FOCUS_INTERVAL_REUSED','FOCUS_LIMIT_REACHED','FOCUS_SNAPSHOT_STALE','FOCUS_INVALID','FOCUS_FAILED'];
 for(const code of codes)for(const invoke of [a=>a.submitFocusOperation(id(9),start),a=>a.focusOperation(id(1)),a=>a.focusActive(),a=>a.focusDetail(id(9)),a=>a.focusList()]){
  const f=fixture({responseCode:code==='FOCUS_FAILED'?500:409,result:JSON.stringify({code,detail:'private SQL/token/mono'})});
  await assert.rejects(invoke(f.api),e=>e.code===code&&!/private|SQL|token|mono/.test(e.message));assert.equal(f.calls.length,1);assert.equal(f.disposed(),1);
 }
});
test('unknown write transport never retries automatically or substitutes an offline operation ID',async()=>{
 const f=fixture(new Error('private transport'));await assert.rejects(f.api.submitFocusOperation(id(9),start),e=>e.code==='NETWORK_ERROR');
 assert.equal(f.calls.length,1);assert.equal(JSON.parse(f.calls[0].options.extraData).operation_id,start.operation_id);assert.equal(f.disposed(),1);
});
