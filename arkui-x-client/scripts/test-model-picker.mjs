import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';
const read=path=>readFileSync(new URL(`../entry/src/main/ets/${path}.ets`,import.meta.url),'utf8');
const strip=source=>source.replace(/^import [^\n]+;\r?\n/gm,'');
const helper=await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(strip(read('utils/ModelCatalog')))).toString('base64')}`);
const source=read('pages/AgentPage'),boundary=source.indexOf('\n  @Builder');
const code=strip(source.slice(0,boundary)).replace(/^@Component\r?\n/gm,'').replace(/@(State|Prop)\s+|@Watch\('[^']+'\)\s*/g,'').replace('export struct AgentPage','class AgentPage')+'\n}';
const create=new Function('CampusFlowApi','Scroller',...Object.keys(helper),stripTypeScriptTypes(code)+'\nreturn AgentPage;');
const option=(id='open-model',extra={})=>({id,label:'供应商模型',provider:'兼容服务',supports_tools:true,supports_streaming:true,supports_reasoning:false,available:true,unavailable_reason:'',...extra});
const catalog=(models=[option()],default_model=models[0]?.id??'')=>({models,default_model});
const deferred=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b;});return{promise,resolve,reject};};
function fixture(load=async()=>catalog()){
 let calls=0;class Api{models(){calls++;return load();}}class Scroller{scrollTo(){}}
 const Page=create(Api,Scroller,...Object.values(helper));const page=new Page();page.baseUrl='server';page.token='a';page.voiceActive=true;
 return{page,calls:()=>calls};
}
test('model catalog validates IDs, duplicate entries, bounded labels, capability types and declared default',()=>{
 assert.equal(helper.validModelCatalog(catalog()),true);assert.equal(helper.validModelCatalog(catalog([])),true);
 for(const value of [null,catalog([option(),option()]),catalog([option('bad id')]),catalog([option('a',{available:'yes'})]),catalog([option('a',{label:''})]),catalog([option()], 'missing')])assert.equal(helper.validModelCatalog(value),false);
 assert.match(helper.modelUnavailableReason(option('a',{available:false,unavailable_reason:'缺少服务端凭据'})),/凭据/);
 assert.match(helper.modelUnavailableReason(option('a',{supports_tools:false})),/工具调用/);
 assert.match(helper.modelLabel('old-history-id',[]),/old-history-id/);
});
test('real picker selects actual available IDs, refuses disabled or incapable choices and keeps history/current selection separate',async()=>{
 const f=fixture(async()=>catalog([option('deepseek-v4-pro'),option('other-provider'),option('disabled',{available:false,unavailable_reason:'未配置凭据'}),option('no-tools',{supports_tools:false})]));
 await f.page.loadModels();f.page.selectModel('other-provider');assert.equal(f.page.model,'other-provider');
 for(const id of ['disabled','no-tools','missing']){f.page.selectModel(id);assert.equal(f.page.model,'other-provider');}
 f.page.loading=true;f.page.selectModel('deepseek-v4-pro');assert.equal(f.page.model,'other-provider');
 assert.equal(f.page.messages.length,1);assert.equal(f.page.selectedModelBlocked(),false);
});
test('catalog failures preserve exact user choice and old-server compatibility without inventing entries',async()=>{
 const f=fixture(async()=>{throw Error('private env key');});f.page.model='historical-unknown';await f.page.loadModels();
 assert.equal(f.page.model,'historical-unknown');assert.equal(f.page.modelCatalog,null);assert.equal(f.page.selectedModelBlocked(),false);
 assert.match(f.page.modelsMessage,/原选择仍保留/);assert.doesNotMatch(f.page.modelsMessage,/private/);
 f.page.selectModel('invented');assert.equal(f.page.model,'historical-unknown');
});
test('hidden or service-switched catalog reads cannot overwrite current choices or available entries',async()=>{
 const old=deferred(),f=fixture(()=>old.promise);const loading=f.page.loadModels();f.page.voiceActive=false;f.page.voiceActivityChanged();
 old.resolve(catalog());await loading;assert.equal(f.page.modelCatalog,null);assert.equal(f.page.modelsLoading,false);
 const first=deferred();let count=0;const g=fixture(()=>++count===1?first.promise:Promise.resolve(catalog([option('new')])));
 const prior=g.page.loadModels();g.page.baseUrl='other';g.page.modelConnectionChanged();await Promise.resolve();await Promise.resolve();first.resolve(catalog([option('old')]));await prior;
 assert.equal(g.page.modelCatalog.models[0].id,'new');assert.equal(g.page.model,'deepseek-v4-pro');
});
test('catalog refresh never changes explicit selection; removed/disabled current choice blocks a send with its exact reason',async()=>{
 const f=fixture(async()=>catalog([option('deepseek-v4-pro',{available:false,unavailable_reason:'模型密钥未配置'})]));
 f.page.prompt='保留草稿';await f.page.loadModels();assert.equal(f.page.modelsDataRevision,1);assert.equal(f.page.selectedModelBlocked(),true);assert.equal(f.page.selectedModelReason(),'模型密钥未配置');
 await f.page.send();assert.equal(f.page.prompt,'保留草稿');assert.equal(f.page.optionsExpanded,true);assert.equal(f.page.runInteraction,null);
 f.page.model='removed';assert.match(f.page.selectedModelReason(),/已不在/);
 assert.match(source,/Button\('选择可用模型'\)/);assert.match(source,/Text\(this.selectedModelReason\(\)\)/);assert.match(source,/服务推荐/);assert.match(source,/`\$\{option.id\}-\$\{this.modelsDataRevision\}`/);
});
