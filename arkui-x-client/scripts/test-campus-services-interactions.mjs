import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';

// Executes production controller methods with controlled HTTP; does not render native ArkUI.
const source = readFileSync(new URL('../entry/src/main/ets/pages/CampusServicesPage.ets', import.meta.url), 'utf8');
const controller = source.slice(0, source.indexOf('\n  @Builder'))
  .replace(/^import [\s\S]*? from '[^']+';\r?\n/gm, '')
  .replace(/^@Component\r?\n/gm, '').replace(/@(State|Prop)\s+|@Watch\('[^']+'\)\s*/g, '')
  .replace('export struct CampusServicesPage', 'class CampusServicesPage') + '\n}';
const create = new Function('CampusFlowApi', 'Scroller', stripTypeScriptTypes(controller) + '\nreturn CampusServicesPage;');
const deferred = () => { let resolve, reject; const promise = new Promise((a,b) => {resolve=a;reject=b;}); return {resolve,reject,promise}; };
const flush = async () => { for (let i=0;i<8;i++) await Promise.resolve(); };
const rooms = (title='新教室') => ({items:[{location_id:title,location_name:title}],total:1,query_label:title});
function setup(override={}) {
  const calls=[]; const hooks={unusedClassrooms:async()=>rooms(),classroomUsage:async()=>({items:[]}),
    electricity:async()=>({bound:true,room_name:'寝室',balance:10,history:[]}),
    hduHelpData:async()=>({status:{configured:true},sections:[],suggested_prompts:[]}),...override};
  class Api { constructor(base,token){this.base=base;this.token=token;} }
  for(const name of Object.keys(hooks)) Api.prototype[name]=function(...args){calls.push([name,...args,this.token]);return hooks[name](...args);};
  const Page=create(Api,class Scroller{}); const page=new Page();
  page.baseUrl='https://fixture.invalid';page.token='account-a';page.classroomLoading=false;
  return {page,calls,hooks};
}

test('initial entry reads only selected service and changing service reads the actual destination',async()=>{
 const {page,calls}=setup();page.aboutToAppear();await flush();assert.deepEqual(calls.map(x=>x[0]),['unusedClassrooms']);
 page.selectService(1);await flush();assert.equal(page.electricityData.balance,10);
 page.selectService(2);await flush();assert.equal(page.campusConfigured,true);
 assert.deepEqual(calls.map(x=>x[0]),['unusedClassrooms','electricity','hduHelpData']);
 page.selectService(-1);page.selectService(4);page.selectService(NaN);assert.equal(page.activeService,2);
});
test('new building selection defeats late old response without resetting its selected filter',async()=>{
 const old=deferred();let count=0;const {page,calls}=setup({unusedClassrooms:()=>++count===1?old.promise:Promise.resolve(rooms('新筛选'))});
 const first=page.loadClassrooms();page.chooseBuilding(2);await flush();
 old.resolve(rooms('旧筛选'));await first;
 assert.equal(page.selectedBuilding,2);assert.equal(page.classrooms[0].location_name,'新筛选');
 assert.equal(calls[1][1],'2');assert.equal(page.classroomLoading,false);
 page.chooseBuilding(99);page.choosePeriod(-1);assert.equal(calls.length,2);
});
test('period query uses captured sections and changed request rejects stale errors',async()=>{
 const old=deferred();let count=0;const {page,calls}=setup({unusedClassrooms:()=>++count===1?old.promise:Promise.resolve(rooms())});
 const first=page.loadClassrooms();page.choosePeriod(2);await flush();old.reject(new Error('private-token'));await first;
 assert.deepEqual(calls[1][2],[3,4,5]);assert.equal(page.classroomError,'');
});
test('classroom error preserves filters and distinguishes failed query from confirmed empty results',async()=>{
 const {page,hooks}=setup({unusedClassrooms:async()=>{throw Error('secret');}});
 page.selectedBuilding=3;page.classrooms=rooms('缓存').items;await page.loadClassrooms();
 assert.equal(page.selectedBuilding,3);assert.equal(page.classrooms[0].location_name,'缓存');
 assert.ok(page.classroomError);assert.ok(!page.classroomError.includes('secret'));
 hooks.unusedClassrooms=async()=>({items:[],total:0,query_label:'新查询'});await page.loadClassrooms();
 assert.deepEqual(page.classrooms,[]);assert.equal(page.classroomError,'');assert.equal(page.classroomTotal,0);
});
test('hiding invalidates every service read and does not display delayed responses or errors',async()=>{
 for(const method of ['loadClassrooms','loadElectricity','loadCampusInfo']) {
  const pending=deferred();const apiName={loadClassrooms:'unusedClassrooms',loadElectricity:'electricity',loadCampusInfo:'hduHelpData'}[method];
  const {page}=setup({[apiName]:()=>pending.promise});page.activeService={loadClassrooms:0,loadElectricity:1,loadCampusInfo:2}[method];
  const read=page[method]();page.active=false;page.activeChanged();pending.reject(Error('secret'));await read;
  assert.equal(page.classroomError,'');assert.equal(page.electricityError,'');assert.equal(page.campusInfoError,'');
  assert.equal(page.classroomLoading||page.electricityLoading||page.campusInfoLoading,false);
 }
});
test('account or server changes block old service responses even before unmount',async()=>{
 for(const property of ['token','baseUrl']){
  const pending=deferred();const {page}=setup({unusedClassrooms:()=>pending.promise});const read=page.loadClassrooms();
  page[property]='other';pending.resolve(rooms('他人数据'));await read;assert.deepEqual(page.classrooms,[]);
 }
});
test('opening a new room, closing details or changing filter invalidates delayed room usage',async()=>{
 for(const action of ['close','filter','room']){
  const pending=deferred();let count=0;const {page}=setup({classroomUsage:()=>++count===1?pending.promise:Promise.resolve({items:[{course_name:'新占用'}]})});
  const read=page.loadUsage({location_id:'1',location_name:'旧教室'});
  if(action==='close')page.closeUsage();if(action==='filter')page.choosePeriod(1);
  if(action==='room')await page.loadUsage({location_id:'2',location_name:'新教室'});
  pending.resolve({items:[{course_name:'旧占用'}]});await read;await flush();
  assert.equal(page.usageItems.some(x=>x.course_name==='旧占用'),false);
  assert.equal(page.usageTitle,action==='room'?'新教室':'');
 }
});
test('room failure keeps its title and retry affects room state without corrupting search state',async()=>{
 const {page,hooks,calls}=setup({classroomUsage:async()=>{throw Error('private');}});
 page.classrooms=rooms().items;await page.loadUsage({location_id:'r1',location_name:'选定教室'});
 assert.equal(page.usageTitle,'选定教室');assert.ok(page.usageError);assert.equal(page.classroomError,'');
 hooks.classroomUsage=async()=>({items:[{course_name:'重试后'}]});page.retryUsage();await flush();
 assert.equal(page.usageError,'');assert.equal(page.usageItems[0].course_name,'重试后');assert.equal(calls[1][1],'r1');
});
test('switching service discards old reads; returning from profile refreshes connection data',async()=>{
 const pending=deferred();const {page,calls}=setup({hduHelpData:()=>pending.promise});
 page.activeService=2;const read=page.loadCampusInfo();page.selectService(0);await flush();
 pending.resolve({status:{configured:true},sections:[{title:'旧'}],suggested_prompts:[]});await read;
 assert.deepEqual(page.campusSections,[]);page.active=false;page.activeChanged();const length=calls.length;
 page.active=true;page.activeChanged();await flush();assert.equal(calls.length,length+1);
});
