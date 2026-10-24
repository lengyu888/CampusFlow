import './helpers/theme-fixture.mjs';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripThemeTypeScriptTypes as stripTypeScriptTypes } from './helpers/theme-fixture.mjs';
import { test } from 'node:test';
const read=path=>readFileSync(new URL(`../entry/src/main/ets/${path}.ets`,import.meta.url),'utf8');
const strip=source=>source.replace(/^import [^\n]+;\r?\n/gm,'');
const evidence=await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(strip(read('utils/EvidencePresentation')))).toString('base64')}`);
const helpers=new Function('publicSourceUrl',stripTypeScriptTypes(strip(read('utils/KnowledgePresentation'))).replace(/^export /gm,'')+'\nreturn {validKnowledgeHit,validKnowledgeSearch,knowledgeEvidence};')(evidence.publicSourceUrl);
const source=read('components/CampusKnowledgePanel');
const code=strip(source.slice(0,source.indexOf('\n  @Builder'))).replace(/^@Component\r?\n/gm,'').replace(/@(State|Prop)\s+|@Watch\('[^']+'\)\s*/g,'').replace('export struct CampusKnowledgePanel','class CampusKnowledgePanel')+'\n}';
const make=new Function('CampusFlowApi',...Object.keys(helpers),stripTypeScriptTypes(code)+'\nreturn CampusKnowledgePanel;');
const hit=(extra={})=>({source_id:'hdu.library.remote',title:'校外访问',section:'数据库',url:'https://tsg.hdu.edu.cn/xwfw/list.htm',excerpt:'原文短摘录',summary:'介绍校外访问入口。',reviewed_at:'2026-10-18',school:'杭州电子科技大学',campus:'下沙校区',...extra});
const result=(query='图书馆',extra={})=>({query,status:'found',message:'已收录参考资料',hits:[hit()],evidence:helpers.knowledgeEvidence(hit()),...extra});
const deferred=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b;});return{promise,resolve,reject};};
function fixture(hooks={}){
 const calls=[];class Api{async searchKnowledge(q){calls.push(['search',q]);return hooks.search?hooks.search(q):result(q);}async knowledgeSource(id){calls.push(['source',id]);return hooks.source?hooks.source(id):hit({source_id:id});}}
 const Page=make(Api,...Object.values(helpers));const page=new Page();page.baseUrl='server';page.token='token';page.campusScope='a|school|campus';page.aboutToAppear();page.query='图书馆';return{page,calls};
}
test('knowledge validation rejects invented source shapes and renders curated references as unverified, never realtime',()=>{
 assert.equal(helpers.validKnowledgeSearch(result(),'图书馆'),true);
 for(const bad of [hit({url:'javascript:alert(1)'}),hit({url:'https://example.com/?token=x'}),hit({reviewed_at:'2026-02-30'}),hit({title:''})])assert.equal(helpers.validKnowledgeHit(bad),false);
 for(const bad of [result('wrong'),result('图书馆',{status:'missing'}),result('图书馆',{hits:[hit(),hit()]}),result('图书馆',{evidence:null})])assert.equal(helpers.validKnowledgeSearch(bad,'图书馆'),false);
 const sources=helpers.knowledgeEvidence(hit());assert.equal(sources[0].kind,'reference');assert.equal(evidence.hasFreshEvidence(sources),false);assert.match(sources[0].note,/核对日期不等于原文发布日期/);
});
test('direct knowledge query needs no model request and missing/unsupported are explicit empty results',async()=>{
 for(const status of ['found','missing','unsupported']){
 const f=fixture({search:q=>result(q,{status,hits:status==='found'?[hit()]:[]})});await f.page.search();
 assert.equal(f.page.result.status,status);assert.deepEqual(f.calls,[['search','图书馆']]);assert.equal(f.page.loading,false);
 }
});
test('blank and excessive Unicode queries retain the draft and never query; network failure is not no-hit',async()=>{
 const f=fixture({search:()=>{throw Error('raw private diagnostic');}});
 for(const text of ['   ','🙂'.repeat(201)]){f.page.query=text;await f.page.search();assert.equal(f.page.query,text);assert.equal(f.calls.length,0);}
 f.page.query='🙂'.repeat(200);await f.page.search();assert.equal(f.calls.length,1);assert.equal(f.page.result,null);assert.match(f.page.message,/不能当作没有/);assert.doesNotMatch(f.page.message,/private/);
});
test('hidden or changed-campus query response cannot reappear on return',async()=>{
 const old=deferred(),f=fixture({search:()=>old.promise});const query=f.page.search();f.page.active=false;f.page.activityChanged();f.page.active=true;
 old.resolve(result());await query;assert.equal(f.page.result,null);assert.equal(f.page.loading,false);
 const pending=deferred(),g=fixture({search:()=>pending.promise});const loading=g.page.search();g.page.campusScope='b';g.page.scopeChanged();pending.resolve(result());await loading;
 assert.equal(g.page.result,null);assert.equal(g.page.query,'');
});
test('source detail must match a current exact source ID; stale source fetch never replaces a later query',async()=>{
 const old=deferred(),f=fixture({source:()=>old.promise});await f.page.search();const detail=f.page.openSource(hit().source_id);
 f.page.query='新的查询';await f.page.search();old.resolve(hit());await detail;assert.equal(f.page.source,null);
 const wrong=fixture({source:()=>hit({source_id:'other'})});await wrong.page.search();await wrong.page.openSource(hit().source_id);
 assert.equal(wrong.page.source,null);assert.match(wrong.page.sourceMessage,/已收录的出处暂未读取/);
 const good=fixture();await good.page.search();await good.page.openSource(hit().source_id);assert.equal(good.page.source.source_id,hit().source_id);
 good.page.closeSource();assert.equal(good.page.source,null);await good.page.openSource('not-in-results');assert.equal(good.calls.length,2);
});
test('source lookup replacement, close and disposal invalidate in-flight reads while preserving query text',async()=>{
 const pending=deferred(),f=fixture({source:()=>pending.promise});await f.page.search();const loading=f.page.openSource(hit().source_id);f.page.closeSource();pending.resolve(hit());await loading;assert.equal(f.page.source,null);
 const read=deferred(),g=fixture({search:()=>read.promise});const search=g.page.search();g.page.aboutToDisappear();read.resolve(result());await search;assert.equal(g.page.result,null);assert.equal(g.page.query,'图书馆');
});
test('Campus and Agent use the shared evidence component without claiming live university page checks',()=>{
 assert.match(read('pages/CampusPage'),/CampusKnowledgePanel\(\{ baseUrl: this.baseUrl, token: this.token, campusScope: this.campusIdentity\(\), active: this.active && this.knowledgeExpanded \}\)/);
 assert.match(source,/查看摘录与出处/);assert.match(source,/EvidencePanel\(\{ evidence: this.result.evidence/);
 assert.match(read('pages/AgentPage'),/EvidencePanel\(\{ evidence: item.evidence \?\? \[\], active: this.voiceActive/);
});


test('examples never send automatically and preserve an existing query until explicit replacement',()=>{
 const f=fixture();f.page.query='我的原问题';f.page.chooseExample('校外怎么访问图书馆数据库');assert.equal(f.page.query,'我的原问题');assert.equal(f.calls.length,0);
 f.page.applyExample();assert.equal(f.page.query,'校外怎么访问图书馆数据库');assert.equal(f.calls.length,0);assert.equal(f.page.pendingExample,'');
 f.page.chooseExample('校园网络资源使用说明');f.page.scopeChanged();assert.equal(f.page.pendingExample,'');assert.equal(f.page.query,'');
});

test('source details distinguish reviewed date from unknown publication date and live validity',()=>{
 assert.match(source,/整理核对日期/);assert.match(source,/原文发布日期：资料未提供/);assert.match(source,/不代表实时状态/);
});
