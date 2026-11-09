import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';
const read=name=>readFileSync(new URL(`../entry/src/main/ets/${name}.ets`,import.meta.url),'utf8');
const clean=text=>text.replace(/^import [\s\S]*? from '[^']+';\r?\n/gm,'');
const feedback=await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(clean(read('utils/AgentFeedback')))).toString('base64')}`);
const make=new Function('http',...Object.keys(feedback),stripTypeScriptTypes(clean(read('services/CampusFlowApi'))).replace('export class CampusFlowApi','class CampusFlowApi')+'\nreturn CampusFlowApi;');
function fixture(response={responseCode:200,result:'{}'}) {
 const calls=[];let closed=0;
 const http={RequestMethod:{GET:'GET',PUT:'PUT'},HttpDataType:{STRING:'STRING'},createHttp:()=>({async request(url,options){
  calls.push({url,options});return Array.isArray(response)?response[calls.length-1]:response;
 },destroy(){closed++;}})};
 const Api=make(http,...Object.values(feedback));return{api:new Api('https://fixture.invalid/','private-fixture'),calls,closed:()=>closed};
}
test('route API authenticates only its native request and has a bounded map-specific transport budget',async()=>{
 const f=fixture();await f.api.campusRoute('a&token=bad','b?key=bad');
 assert.equal(f.calls[0].url,'https://fixture.invalid/api/v1/campus-data/route?origin=a%26token%3Dbad&destination=b%3Fkey%3Dbad');
 assert.equal(f.calls[0].options.header.Authorization,'Bearer private-fixture');
 assert.equal(f.calls[0].options.connectTimeout,5000);assert.equal(f.calls[0].options.readTimeout,20000);
 assert.equal(f.calls[0].options.maxRedirects,0);assert.equal(f.closed(),1);
});

test('place candidate pages encode search and place ID and only explicit confirmation sends the private token',async()=>{
 const f=fixture();await f.api.campusPlaceCandidates('a/b',2,'图书馆 & 北门');
 assert.equal(f.calls[0].url,'https://fixture.invalid/api/v1/campus-data/places/a%2Fb/candidates?page=2&query=%E5%9B%BE%E4%B9%A6%E9%A6%86%20%26%20%E5%8C%97%E9%97%A8');
 assert.equal(f.calls[0].options.method,'GET');assert.equal(f.calls[0].options.readTimeout,20000);assert.equal(f.calls[0].options.connectTimeout,5000);
 await f.api.confirmCampusPlaceSelection('a/b','private-candidate');
 assert.equal(f.calls[1].url,'https://fixture.invalid/api/v1/campus-data/places/a%2Fb/selection');
 assert.equal(f.calls[1].options.method,'PUT');assert.deepEqual(JSON.parse(f.calls[1].options.extraData),{selection_token:'private-candidate'});
 assert.equal(f.calls[1].options.usingCache,false);assert.equal(f.closed(),2);
});

test('place candidate search keeps a safe structured upstream error', async () => {
  const search = fixture({responseCode: 504, result: JSON.stringify({code: 'MAP_UPSTREAM_TIMEOUT', detail: 'SECRET'})});
  await assert.rejects(search.api.campusPlaceCandidates('a'), error =>
    error.code === 'MAP_UPSTREAM_TIMEOUT' && /超时/.test(error.message) && !error.message.includes('SECRET'));
});

test('place confirmation keeps safe structured expired and invalid candidate errors', async () => {
  for (const code of ['MAP_SELECTION_EXPIRED', 'MAP_SELECTION_INVALID']) {
    const confirmation = fixture({responseCode: 422, result: JSON.stringify({code, detail: 'SECRET'})});
    await assert.rejects(confirmation.api.confirmCampusPlaceSelection('a', 'private-candidate'), error =>
      error.code === code && /重新检索/.test(error.message) && !error.message.includes('SECRET'));
  }
});

test('selection errors use safe actionable messages and preserve stable error codes',async()=>{
 for(const code of ['MAP_PLACE_SELECTION_REQUIRED','MAP_SELECTION_EXPIRED','MAP_SELECTION_INVALID']){
 const f=fixture({responseCode:409,result:JSON.stringify({code,detail:'SECRET'})});
 await assert.rejects(f.api.campusRoute('a','b'),error=>error.code===code&&!error.message.includes('SECRET')&&/确认|检索/.test(error.message));}
});
test('all map failures preserve their stable code while ignoring upstream body and credentials',async()=>{
 for(const code of ['MAP_NOT_CONFIGURED','MAP_UPSTREAM_TIMEOUT','MAP_UPSTREAM_ERROR','MAP_NO_ROUTE','MAP_PLACE_UNRESOLVED','MAP_PLACE_AMBIGUOUS']) {
  const f=fixture({responseCode:503,result:JSON.stringify({code,detail:'SECRET https://baidu/?ak=SECRET'})});
  await assert.rejects(f.api.campusRoute('a','b'),error=>error.code===code&&!error.message.includes('SECRET')&&!error.message.includes('https:'));
  assert.equal(f.closed(),1);
 }
});

test('map configuration uses an authenticated request and only falls back anonymously for a missing endpoint',async()=>{
 const config={configured:true,browser_ak:'FIXTURE_BROWSER',route_configured:true,campus_query:'校区',city:'杭州'};
 const response={responseCode:200,result:JSON.stringify(config)};
 const current=fixture(response);
 assert.deepEqual(await current.api.baiduMapConfig(),config);
 assert.deepEqual(current.calls.map(call=>[call.url,call.options.header.Authorization]),[
  ['https://fixture.invalid/api/v1/me/baidu-maps/config','Bearer private-fixture']
 ]);
 const legacy=fixture([{responseCode:404,result:'{}'},response]);
 assert.deepEqual(await legacy.api.baiduMapConfig(),config);
 assert.deepEqual(legacy.calls.map(call=>[call.url,call.options.header.Authorization]),[
  ['https://fixture.invalid/api/v1/me/baidu-maps/config','Bearer private-fixture'],
  ['https://fixture.invalid/api/v1/maps/baidu/config','']
 ]);
 assert.ok(legacy.calls.every(call=>!call.options.usingCache&&call.options.maxRedirects===0));
 assert.equal(legacy.closed(),2);
 for(const responseCode of [401,403,500,503]){
  const blocked=fixture({responseCode,result:JSON.stringify({detail:'PRIVATE_ERROR'})});
  await assert.rejects(blocked.api.baiduMapConfig(),error=>error.statusCode===responseCode&&!error.message.includes('PRIVATE_ERROR'));
  assert.equal(blocked.calls.length,1);assert.equal(blocked.closed(),1);
 }
});

test('credential transport sends explicit fields only and returns masked status data',async()=>{
 const data={browser:{configured:true,source:'account',hint:'••••1234',browser_ak:'RAW_BROWSER'},
  server:{configured:true,source:'server',hint:'RAW_SERVER',server_ak:'RAW_SERVER'},server_ak:'RAW_SERVER'};
 const f=fixture({responseCode:200,result:JSON.stringify(data)});
 const expected={browser:{configured:true,source:'account',hint:'••••1234'},server:{configured:true,source:'server',hint:null}};
 assert.deepEqual(await f.api.baiduMapSettings(),expected);
 assert.deepEqual(await f.api.updateBaiduMapSettings({browser_ak:undefined,server_ak:null,api_key:'OTHER_SECRET'}),expected);
 assert.equal(f.calls[1].options.method,'PUT');assert.equal(f.calls[1].url,'https://fixture.invalid/api/v1/me/baidu-maps');
 assert.equal(f.calls[1].options.header.Authorization,'Bearer private-fixture');
 assert.deepEqual(JSON.parse(f.calls[1].options.extraData),{server_ak:null});
});
