import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {stripTypeScriptTypes} from 'node:module';
import {test} from 'node:test';
const read=name=>readFileSync(new URL(`../entry/src/main/ets/${name}`,import.meta.url),'utf8');
const strip=s=>s.replace(/^import \{[\s\S]*?\} from '[^']+';\r?\n/gm,'').replace(/^import [^\n]+;\r?\n/gm,'');
const feedback=await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(strip(read('utils/AgentFeedback.ets')))).toString('base64')}`);
const factory=new Function('http','CampusFlowRequestError','localRequestFailure','requestFailure',
 stripTypeScriptTypes(strip(read('services/CampusFlowApi.ets')).replace('export class CampusFlowApi','class CampusFlowApi'))+'\nreturn CampusFlowApi;');
function setup(response={responseCode:200,result:'{}'}){
 const calls=[];let destroyed=0;
 const http={RequestMethod:{GET:'GET',PUT:'PUT',POST:'POST',DELETE:'DELETE'},HttpDataType:{STRING:'STRING'},
 createHttp:()=>({request:async(url,options)=>{calls.push({url,options});if(response instanceof Error)throw response;return response;},destroy:()=>destroyed++})};
 const Api=factory(http,feedback.CampusFlowRequestError,feedback.localRequestFailure,feedback.requestFailure);
 return {api:new Api('https://fixture.invalid','fixture-only'),calls,destroyed:()=>destroyed};
}
const operation='7bf5f1af-7a7d-4d67-93d3-3bfabff28001';
const source='7bf5f1af-7a7d-4d67-93d3-3bfabff28002';
test('task status start sends exact fixed operation/version without a phantom complete source',async()=>{
 const f=setup();const request={operation_id:operation,kind:'complete',expected_revision:9};
 await f.api.startTaskStatus('task/a?b',request);await f.api.startTaskStatus('task/a?b',request);
 assert.deepEqual(f.calls.map(c=>[c.url,c.options.method]),Array(2).fill(['https://fixture.invalid/api/v1/tasks/task%2Fa%3Fb/status-operations','POST']));
 assert.equal(f.calls[0].options.extraData,JSON.stringify(request));assert.equal(f.calls[1].options.extraData,f.calls[0].options.extraData);
 assert.ok(!Object.hasOwn(JSON.parse(f.calls[0].options.extraData),'source_operation_id'));
 assert.ok(f.calls.every(c=>c.options.header.Authorization==='Bearer fixture-only'));assert.equal(f.destroyed(),2);
});
test('restore preview, result query, exact acknowledgements and cancellation use separate requests',async()=>{
 const f=setup(),request={operation_id:operation,kind:'restore',expected_revision:10,source_operation_id:source};
 const acks=[{candidate_id:`status:${operation}`,review_digest:'a'.repeat(64)}];
 await f.api.startTaskStatus('task',request);await f.api.taskStatusOperation('op/a');await f.api.confirmTaskStatus('op/a',acks);await f.api.cancelTaskStatus('op/a');
 assert.deepEqual(JSON.parse(f.calls[0].options.extraData),request);
 assert.deepEqual(f.calls.slice(1).map(c=>[c.url,c.options.method,c.options.extraData]),[
 ['https://fixture.invalid/api/v1/task-status-operations/op%2Fa','GET',''],
 ['https://fixture.invalid/api/v1/task-status-operations/op%2Fa/confirm','POST',JSON.stringify({acknowledgements:acks})],
 ['https://fixture.invalid/api/v1/task-status-operations/op%2Fa/cancel','POST','{}']]);
 assert.equal(f.destroyed(),4);assert.deepEqual(acks,[{candidate_id:`status:${operation}`,review_digest:'a'.repeat(64)}]);
});
test('all status routes preserve controlled typed codes without showing private response bodies',async()=>{
 const codes=['TASK_NOT_FOUND','TASK_STATUS_OPERATION_NOT_FOUND','TASK_STATUS_OPERATION_REUSED','TASK_STALE','TASK_STATUS_UNCHANGED','TASK_COMPLETION_NOT_TRACKED','TASK_COMPLETION_SUPERSEDED','TASK_RECOVERY_PREVIEW_REQUIRED','TASK_RECOVERY_EXPIRED','TASK_RECOVERY_CANCELLED','TASK_STATUS_FAILED'];
 for(const code of codes){
  const response={responseCode:code==='TASK_STATUS_FAILED'?500:409,result:JSON.stringify({code,detail:'private SQL owner/token'})};
  for(const invoke of [api=>api.startTaskStatus('task',{operation_id:operation,kind:'complete',expected_revision:1}),api=>api.taskStatusOperation(operation),api=>api.confirmTaskStatus(operation,[]),api=>api.cancelTaskStatus(operation)]){
   const f=setup(response);await assert.rejects(invoke(f.api),e=>e instanceof feedback.CampusFlowRequestError&&e.code===code&&!/private|SQL|token/.test(e.message));
   assert.equal(f.calls.length,1);assert.equal(f.destroyed(),1);
  }
 }
});
test('transport interruption has no implicit POST retry or reverse task write',async()=>{
 const f=setup(new Error('transport private detail'));
 await assert.rejects(f.api.startTaskStatus('task',{operation_id:operation,kind:'complete',expected_revision:1}),e=>e.code==='NETWORK_ERROR'&&!e.message.includes('private'));
 assert.equal(f.calls.length,1);assert.equal(f.destroyed(),1);
});
