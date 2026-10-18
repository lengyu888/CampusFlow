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
 createHttp:()=>({request:async(url,options)=>{calls.push({url,options});return response;},destroy:()=>destroyed++})};
 const Api=factory(http,feedback.CampusFlowRequestError,feedback.localRequestFailure,feedback.requestFailure);
 return {api:new Api('https://fixture.invalid','fixture-only'),calls,destroyed:()=>destroyed};
}
test('context reads and explicit rename use authenticated exact session IDs, with escaped paths',async()=>{
 const f=setup();await f.api.sessionContext('a/b?c');await f.api.renameSession('a/b?c','考试复习');
 assert.deepEqual(f.calls.map(c=>[c.url,c.options.method]),[
 ['https://fixture.invalid/api/v1/sessions/a%2Fb%3Fc/context','GET'],
 ['https://fixture.invalid/api/v1/sessions/a%2Fb%3Fc','PUT']]);
 assert.equal(f.calls[0].options.extraData,'');assert.deepEqual(JSON.parse(f.calls[1].options.extraData),{title:'考试复习'});
 assert.ok(f.calls.every(c=>c.options.header.Authorization==='Bearer fixture-only'));assert.equal(f.destroyed(),2);
});
test('continuing sends the reviewed context version while original four-field run retries remain byte-identical',async()=>{
 const f=setup(),old={run_id:'run-a',session_id:'session-a',model:'fixture-model',message:'继续'};
 await f.api.startAgentRun(old);await f.api.startAgentRun({...old,session_mode:'continue',expected_context_revision:'a'.repeat(64)});
 await f.api.startAgentRun(old);
 assert.equal(f.calls[0].options.extraData,JSON.stringify(old));assert.equal(f.calls[2].options.extraData,f.calls[0].options.extraData);
 assert.deepEqual(JSON.parse(f.calls[1].options.extraData),{...old,session_mode:'continue',expected_context_revision:'a'.repeat(64)});
 assert.equal(f.calls.length,3,'API adapter never implicitly refreshes context or retries a write');
});
test('course permission changes and confirmations send distinct precise user choices',async()=>{
 const f=setup();const choices=[{candidate_id:'candidate-a',allow_during_course:true},{candidate_id:'candidate-b',allow_during_course:false}];
 await f.api.coursePermissions('old/proposal',choices);
 await f.api.confirmAction('replacement',[{candidate_id:'candidate-a',review_digest:'b'.repeat(64)}]);
 assert.match(f.calls[0].url,/old%2Fproposal\/course-permissions$/);assert.deepEqual(JSON.parse(f.calls[0].options.extraData),{choices});
 assert.match(f.calls[1].url,/replacement\/confirm$/);assert.deepEqual(JSON.parse(f.calls[1].options.extraData),{course_acknowledgements:[{candidate_id:'candidate-a',review_digest:'b'.repeat(64)}]});
});
test('session errors retain stable codes and never echo raw provider or account details',async()=>{
 for(const code of ['SESSION_NOT_FOUND','SESSION_DELETED','SESSION_CONTEXT_CHANGED','SESSION_EXISTS','SESSION_MODE_INVALID']){
  const f=setup({responseCode:409,result:JSON.stringify({code,detail:'private-diagnostic'})});
  await assert.rejects(f.api.sessionContext('id'),error=>error instanceof feedback.CampusFlowRequestError&&error.code===code&&!error.message.includes('private-diagnostic'));
  assert.equal(f.calls.length,1);assert.equal(f.destroyed(),1);
 }
});
