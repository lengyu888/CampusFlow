import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';
import { time } from './helpers/review-fixture.mjs';
import { emptyFocusState } from './helpers/focus-fixture.mjs';
const read=p=>readFileSync(new URL(`../entry/src/main/ets/${p}.ets`,import.meta.url),'utf8');
const clean=s=>s.replace(/^import \{[\s\S]*?\} from '[^']+';\r?\n/gm,'').replace(/^import [^\n]+;\r?\n/gm,'');
const pure=async p=>import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(clean(read(p)))).toString('base64')}`);
const feedback=await pure('utils/AgentFeedback'),navigation=await pure('utils/AppNavigation');
function page(){
 const src=read('pages/Index'),end=src.indexOf('\n  @Builder');
 const js=stripTypeScriptTypes(clean(src.slice(0,end)).replace(/^@(Entry|Component)\r?\n/gm,'').replace(/@(State|Prop)\s+|@(Watch|StorageLink)\('[^']+'\)\s*/g,'').replace('struct Index','class Index')+'\n}');
 const deps={...navigation,...time,emptyFocusState};const Index=new Function(...Object.keys(deps),js+'\nreturn Index;')(...Object.values(deps));
 const p=new Index();p.token='synthetic';p.authRevision=7;p.applyNavigation=n=>{p.navigation=n;p.activeTab=n.root;};return p;
}
function api(response={responseCode:200,result:'{}'}){
 const calls=[];let disposed=0;
 const http={RequestMethod:{GET:'GET'},HttpDataType:{STRING:'STRING'},createHttp:()=>({async request(url,options){calls.push({url,options});if(response instanceof Error)throw response;return response;},destroy(){disposed++;}})};
 const js=stripTypeScriptTypes(clean(read('services/CampusFlowApi'))).replace(/^export /gm,'');
 const Api=new Function('http',...Object.keys(feedback),js+'\nreturn CampusFlowApi;')(http,...Object.values(feedback));
 return {api:new Api('https://fixture.invalid','synthetic'),calls,disposed:()=>disposed};
}
test('review API is authenticated GET with independently encoded selectors and no body or model action',async()=>{
 const f=api();await f.api.review('week','2030-10-19');await f.api.review('day&private=1','2030-10-19&x=y');
 assert.deepEqual(f.calls.map(c=>c.url),['https://fixture.invalid/api/v1/reviews?period=week&anchor=2030-10-19','https://fixture.invalid/api/v1/reviews?period=day%26private%3D1&anchor=2030-10-19%26x%3Dy']);
 for(const c of f.calls){assert.equal(c.options.method,'GET');assert.equal(c.options.extraData,'');assert.equal(c.options.header.Authorization,'Bearer synthetic');}assert.equal(f.disposed(),2);
});
test('review errors preserve safe codes and never expose server diagnostics or retry implicitly',async()=>{
 for(const [code,status] of [['REVIEW_INVALID',422],['REVIEW_LIMIT',413],['REVIEW_DATA_INVALID',500],['REVIEW_FAILED',500]]){
  const f=api({responseCode:status,result:JSON.stringify({code,detail:'SQL secret private pathname'})});
  await assert.rejects(f.api.review('day','2030-10-19'),e=>e.code===code&&e.statusCode===status&&!/SQL|secret|private|pathname/.test(e.message));assert.equal(f.calls.length,1);assert.equal(f.disposed(),1);
 }
 const f=api(new Error('private transport'));await assert.rejects(f.api.review('week','2030-10-19'),e=>e.code==='NETWORK_ERROR');assert.equal(f.calls.length,1);
});
test('open review validates range and foreground; system back waits for page note protection callback',()=>{
 const p=page();p.openReview('day','2030-02-30');assert.equal(p.reviewPageOpen,false);p.voiceForeground=false;p.openReview('day','2030-10-19');assert.equal(p.reviewPageOpen,false);
 p.voiceForeground=true;p.focusPageOpen=true;p.openReview('week','2030-10-19');assert.equal(p.reviewPageOpen,true);assert.equal(p.focusPageOpen,false);assert.equal(p.reviewAnchor,'2030-10-19');
 const before=p.reviewBackRevision;assert.equal(p.onBackPress(),true);assert.equal(p.reviewBackRevision,before+1);assert.equal(p.reviewPageOpen,true);
 p.closeReview(6);assert.equal(p.reviewPageOpen,true);p.closeReview(7);assert.equal(p.reviewPageOpen,false);
 const entry=p.reviewEntryRevision;p.openReview('week','2030-10-19');assert.equal(p.reviewEntryRevision,entry+1);assert.equal(p.reviewAnchor,'2030-10-19');
});
test('review exact task and focus navigation cannot mutate tasks or accept an old account callback',()=>{
 const p=page(),calls=[];p.openReview('day','2030-10-19');p.reviewTaskRequested('task-a',6);assert.equal(p.reviewPageOpen,true);assert.equal(p.focusTaskId,'');
 p.reviewTaskRequested('task-a',7);assert.equal(p.reviewPageOpen,false);assert.equal(p.focusTaskId,'task-a');assert.equal(p.focusPlanId,'');
 p.focusManager={refreshHistory(){calls.push(['refresh']);},selectRecord(id){calls.push(['record',id]);}};
 p.openReview('day','2030-10-19');p.reviewFocusRequested('record-a',7);assert.equal(p.focusPageOpen,true);assert.deepEqual(calls,[['refresh'],['record','record-a']]);
 p.openReview('day','2030-10-19');p.authRevision++;p.reviewFocusRequested('record-old',7);assert.equal(calls.length,2);assert.equal(p.reviewPageOpen,true);
});
test('review summary uses existing assistant suggestion intent once and never sends',()=>{
 const p=page();p.openReview('day','2030-10-19');p.reviewSummaryRequested('',7);assert.equal(p.reviewPageOpen,true);
 p.reviewSummaryRequested('x'.repeat(8001),7);assert.equal(p.promptRevision,0);p.reviewSummaryRequested('核对后的摘要',7);assert.equal(p.agentPrompt,'核对后的摘要');assert.equal(p.promptRevision,1);assert.equal(p.reviewPageOpen,false);
 p.reviewSummaryRequested('迟到的旧摘要',7);assert.equal(p.agentPrompt,'核对后的摘要');assert.equal(p.promptRevision,1);
});
test('global unsynced count deduplicates operations and local records without counting fully synced offline rows',()=>{
 const p=page();p.focusState.pendingOperations=[{recordId:'a'},{recordId:'a'},{recordId:'b'}];p.focusState.localRecords=[
 {recordId:'a',elapsedMs:1000,confirmedElapsedMs:0,saveState:'saved'},
 {recordId:'c',elapsedMs:0,confirmedElapsedMs:0,saveState:'error'},
 {recordId:'d',elapsedMs:1000,confirmedElapsedMs:1000,saveState:'saved',mode:'offline'},
 {recordId:'e',elapsedMs:0,confirmedElapsedMs:0,saveState:'pending'}];assert.equal(p.reviewPendingRecordCount(),4);
});
