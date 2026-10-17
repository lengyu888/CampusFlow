import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {stripTypeScriptTypes} from 'node:module';
import {test} from 'node:test';
const feedbackSource=readFileSync(new URL('../entry/src/main/ets/utils/AgentFeedback.ets',import.meta.url),'utf8').replace(/^import[^\n]+;\r?\n/gm,'');
const feedback=await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(feedbackSource)).toString('base64')}`);
const apiSource=readFileSync(new URL('../entry/src/main/ets/services/CampusFlowApi.ets',import.meta.url),'utf8')
 .replace(/^import http from '@ohos.net.http';\r?\n/m,'')
 .replace(/^import \{[\s\S]*?\} from '\.\.\/model\/ApiModels';\r?\n/m,'')
 .replace(/^import \{[^\n]+\} from '\.\.\/utils\/AgentFeedback';\r?\n/m,'')
 .replace('export class CampusFlowApi','class CampusFlowApi');
const create=new Function('http','CampusFlowRequestError','localRequestFailure','requestFailure',stripTypeScriptTypes(apiSource)+'\nreturn CampusFlowApi;');
function setup(response={responseCode:200,result:'{}'}){
 const calls=[];let destroyed=0;const http={RequestMethod:{GET:'GET',PUT:'PUT'},HttpDataType:{STRING:'STRING'},
 createHttp:()=>({request:async(url,options)=>{calls.push({url,options});if(response instanceof Error)throw response;return response;},destroy:()=>destroyed++})};
 const Api=create(http,feedback.CampusFlowRequestError,feedback.localRequestFailure,feedback.requestFailure);
 return {client:new Api('https://fixture.invalid/','token-a'),calls,destroyed:()=>destroyed};
}
test('timetable API reads, writes exact reviewed entries and escapes operation path, without re-importing',async()=>{
 const {client,calls,destroyed}=setup();const entries=[{date:'2026-10-19',title:'已编辑课程',start_time:'09:00',end_time:'10:00',location:'教室',teacher:''}];
 await client.timetable();await client.saveTimetable(entries,'a'.repeat(64),'operation-1');await client.timetableOperation('a/b?c');
 assert.deepEqual(calls.map(c=>[c.url.replace('https://fixture.invalid',''),c.options.method]),[
 ['/api/v1/me/timetable','GET'],['/api/v1/me/timetable','PUT'],['/api/v1/me/timetable/operations/a%2Fb%3Fc','GET']]);
 assert.deepEqual(JSON.parse(calls[1].options.extraData),{entries,expected_revision:'a'.repeat(64),operation_id:'operation-1',confirm_clear:false});
 assert.ok(calls.every(c=>c.options.header.Authorization==='Bearer token-a'));assert.equal(destroyed(),3);
});
test('clear carries explicit confirmation and same operation is preserved for manual retries',async()=>{
 const {client,calls}=setup();await client.saveTimetable([],'b'.repeat(64),'same-op',true);await client.saveTimetable([],'b'.repeat(64),'same-op',true);
 assert.equal(calls[0].options.extraData,calls[1].options.extraData);assert.equal(JSON.parse(calls[1].options.extraData).confirm_clear,true);
});
test('structured timetable errors survive API boundary with no raw server detail disclosure',async()=>{
 for(const [status,code] of [[409,'TIMETABLE_STALE'],[409,'TIMETABLE_OPERATION_CONFLICT'],[404,'TIMETABLE_OPERATION_NOT_FOUND'],[422,'TIMETABLE_CLEAR_CONFIRMATION_REQUIRED'],[500,'TIMETABLE_SAVE_FAILED']]){
  const {client,destroyed}=setup({responseCode:status,result:JSON.stringify({code,detail:'private-secret'})});
  await assert.rejects(client.timetableOperation('id'),error=>error.code===code&&error.statusCode===status&&!error.message.includes('private-secret'));
  assert.equal(destroyed(),1);
 }
});
test('network failure is typed as uncertain and the native request is destroyed',async()=>{
 const {client,destroyed}=setup(Error('private-secret'));
 await assert.rejects(client.saveTimetable([],'a'.repeat(64),'op',true),error=>error instanceof feedback.CampusFlowRequestError&&!error.message.includes('private-secret'));
 assert.equal(destroyed(),1);
});
