import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';
const read=path=>readFileSync(new URL(`../entry/src/main/ets/${path}.ets`,import.meta.url),'utf8');
const strip=source=>source.replace(/^import [\s\S]*? from '[^']+';\r?\n/gm,'');
const feedback=await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(strip(read('utils/AgentFeedback')))).toString('base64')}`);
const make=new Function('http',...Object.keys(feedback),stripTypeScriptTypes(strip(read('services/CampusFlowApi'))).replace('export class CampusFlowApi','class CampusFlowApi')+'\nreturn CampusFlowApi;');
function fixture(response={responseCode:200,result:'{}'}){
 const calls=[];let destroyed=0;const http={RequestMethod:{GET:'GET',PUT:'PUT',DELETE:'DELETE'},HttpDataType:{STRING:'STRING'},createHttp:()=>({async request(url,options){calls.push({url,options});return response;},destroy(){destroyed++;}})};
 const Api=make(http,...Object.values(feedback));return{api:new Api('https://fixture.invalid/','test-token'),calls,closed:()=>destroyed};
}
test('models/preferences/knowledge use scoped authenticated routes and exact CAS bodies with escaped query/id',async()=>{
 const f=fixture(),payload={base_revision:7,operation_id:'11111111-1111-4111-8111-111111111111',enabled:true,session_minutes:45,break_minutes:5,preferred_period:'morning',daily_minutes:90};
 await f.api.models();await f.api.learningPreferences();await f.api.saveLearningPreferences(payload);
 await f.api.clearLearningPreferences({base_revision:8,operation_id:payload.operation_id});
 await f.api.searchKnowledge('数据库 & 校外?');await f.api.knowledgeSource('source/a?b');
 assert.deepEqual(f.calls.map(c=>[c.url.replace('https://fixture.invalid',''),c.options.method]),[
 ['/api/v1/models','GET'],['/api/v1/learning-preferences','GET'],['/api/v1/learning-preferences','PUT'],['/api/v1/learning-preferences','DELETE'],
 ['/api/v1/knowledge/search?q='+encodeURIComponent('数据库 & 校外?'),'GET'],['/api/v1/knowledge/sources/source%2Fa%3Fb','GET']]);
 assert.deepEqual(JSON.parse(f.calls[2].options.extraData),payload);assert.deepEqual(JSON.parse(f.calls[3].options.extraData),{base_revision:8,operation_id:payload.operation_id});
 assert.ok(f.calls.every(c=>c.options.header.Authorization==='Bearer test-token'));assert.equal(f.closed(),6);
});
test('new error codes remain safely typed and none of these endpoints expose raw server diagnostics',async()=>{
 for(const code of ['MODEL_NOT_FOUND','MODEL_CAPABILITY_UNSUPPORTED','MODEL_PROVIDER_KEY_REQUIRED','MODEL_CONFIG_INVALID','PREFERENCES_CHANGED','OPERATION_ID_REUSED','OPERATION_RETIRED']){
 const f=fixture({responseCode:409,result:JSON.stringify({code,detail:'private-token-url'})});
 await assert.rejects(f.api.saveLearningPreferences({}),e=>e.code===code&&!e.message.includes('private'));assert.equal(f.closed(),1);
 }
 for(const call of [a=>a.models(),a=>a.learningPreferences(),a=>a.searchKnowledge('query'),a=>a.knowledgeSource('id')]){
 await assert.rejects(call(fixture({responseCode:500,result:'raw internal stack'}).api),e=>e.code==='HTTP_ERROR'&&!e.message.includes('raw'));
 }
});
