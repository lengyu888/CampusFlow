import './helpers/theme-fixture.mjs';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripThemeTypeScriptTypes as stripTypeScriptTypes } from './helpers/theme-fixture.mjs';
import { test } from 'node:test';
import { campusPresentation as presentation, requestFailure } from './helpers/campus-data-fixture.mjs';

// Executes production controller methods with controlled HTTP; does not render native ArkUI.
const source = readFileSync(new URL('../entry/src/main/ets/pages/CampusServicesPage.ets', import.meta.url), 'utf8');
const controller = source.slice(0, source.indexOf('\n  @Builder'))
  .replace(/^import [\s\S]*? from '[^']+';\r?\n/gm, '')
  .replace(/^@Component\r?\n/gm, '').replace(/@(State|Prop)\s+|@Watch\('[^']+'\)\s*/g, '')
  .replace('export struct CampusServicesPage', 'class CampusServicesPage') + '\n}';
const create = new Function('CampusFlowApi', 'Scroller', ...Object.keys(presentation),
  stripTypeScriptTypes(controller) + '\nreturn CampusServicesPage;');
const deferred = () => { let resolve, reject; const promise = new Promise((a,b) => {resolve=a;reject=b;}); return {resolve,reject,promise}; };
const flush = async () => { for (let i=0;i<8;i++) await Promise.resolve(); };
const rooms = (title='新教室') => ({items:[{location_id:title,location_name:title}],total:1,query_label:title});
function setup(override={}) {
  const calls=[]; const hooks={unusedClassrooms:async()=>rooms(),classroomUsage:async()=>({items:[]}),
    electricity:async()=>({bound:true,room_name:'寝室',balance:10,history:[]}),
    hduHelpData:async()=>({status:{configured:true},sections:[],suggested_prompts:[]}),...override};
  class Api { constructor(base,token){this.base=base;this.token=token;} }
  for(const name of Object.keys(hooks)) Api.prototype[name]=function(...args){calls.push([name,...args,this.token]);return hooks[name](...args);};
  const Page=create(Api,class Scroller{},...Object.values(presentation)); const page=new Page();
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
 assert.deepEqual(calls[1][2],[3,4,5]);assert.equal(page.classroomError,null);
});
test('classroom error preserves filters and distinguishes failed query from confirmed empty results',async()=>{
 const {page,hooks}=setup({unusedClassrooms:async()=>{throw Error('secret');}});
 page.selectedBuilding=3;page.classrooms=rooms('缓存').items;await page.loadClassrooms();
 assert.equal(page.selectedBuilding,3);assert.equal(page.classrooms[0].location_name,'缓存');
 assert.equal(page.classroomError.state,'unavailable');assert.doesNotMatch(page.classroomError.message,/secret/);
 hooks.unusedClassrooms=async()=>({items:[],total:0,query_label:'新查询'});await page.loadClassrooms();
 assert.deepEqual(page.classrooms,[]);assert.equal(page.classroomError,null);assert.equal(page.classroomTotal,0);
});
test('hiding invalidates every service read and does not display delayed responses or errors',async()=>{
 for(const method of ['loadClassrooms','loadElectricity','loadCampusInfo']) {
  const pending=deferred();const apiName={loadClassrooms:'unusedClassrooms',loadElectricity:'electricity',loadCampusInfo:'hduHelpData'}[method];
  const {page}=setup({[apiName]:()=>pending.promise});page.activeService={loadClassrooms:0,loadElectricity:1,loadCampusInfo:2}[method];
  const read=page[method]();page.active=false;page.activeChanged();pending.reject(Error('secret'));await read;
  assert.equal(page.classroomError,null);assert.equal(page.electricityError,null);assert.equal(page.campusInfoError,'');
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
 assert.equal(page.usageTitle,'选定教室');assert.ok(page.usageError);assert.equal(page.classroomError,null);
 hooks.classroomUsage=async()=>({items:[{course_name:'重试后'}]});page.retryUsage();await flush();
 assert.equal(page.usageError,null);assert.equal(page.usageItems[0].course_name,'重试后');assert.equal(calls[1][1],'r1');
});
test('switching service discards old reads; returning from profile refreshes connection data',async()=>{
 const pending=deferred();const {page,calls}=setup({hduHelpData:()=>pending.promise});
 page.activeService=2;const read=page.loadCampusInfo();page.selectService(0);await flush();
 pending.resolve({status:{configured:true},sections:[{title:'旧'}],suggested_prompts:[]});await read;
 assert.deepEqual(page.campusSections,[]);page.active=false;page.activeChanged();const length=calls.length;
 page.active=true;page.activeChanged();await flush();assert.equal(calls.length,length+1);
});

const snapshotTime = '2026-11-09T00:00:00Z';
const cachedStatus = { state: 'cached', updated_at: snapshotTime, expires_at: null, issue: null, message: '', action: 'retry' };
const unavailableStatus = { state: 'unavailable', updated_at: null, expires_at: null, issue: 'timeout', message: '读取超时', action: 'retry' };

test('an expired cache keeps its original timestamp and failure reason', () => {
  const expiresAt = '2026-11-09T00:05:00Z';
  const timedOut = { ...cachedStatus, expires_at: expiresAt, issue: 'timeout', message: '读取超时' };
  const status = presentation.previousCampusStatuses({ card_balance: timedOut }, Date.parse(expiresAt)).card_balance;
  assert.deepEqual(status, { ...timedOut, state: 'stale' });
});

test('expired authorization keeps only matching classroom results and offers connection repair', async () => {
  const { page, hooks } = setup({ unusedClassrooms: async () => ({ ...rooms(), data_status: cachedStatus }) });
  await page.loadClassrooms();
  hooks.unusedClassrooms = async () => { throw requestFailure(401, '{"code":"HDUHELP_AUTH_INVALID","detail":"private-token"}'); };
  await page.loadClassrooms();
  assert.equal(page.hasClassroomResult(), true);
  assert.equal(page.classroomError.state, 'stale');
  assert.equal(page.classroomError.updated_at, snapshotTime);
  assert.equal(page.classroomError.action, 'connect');
  assert.doesNotMatch(page.classroomError.message, /private-token/);
  page.chooseBuilding(2);
  await flush();
  assert.equal(page.hasClassroomResult(), false);
  assert.equal(page.classroomError.state, 'unavailable');
  assert.equal(page.classroomError.updated_at, null);
});

test('one resource can retry without cached data while unrelated cached sections stay visible', async () => {
  const card = { resource: 'card_balance', title: '校园卡', summary: '余额', items: [{ label: '余额', value: '10' }] };
  const input = { status: { configured: true }, sections: [card], suggested_prompts: [],
    resource_statuses: { card_balance: cachedStatus, library_reading: unavailableStatus } };
  const pending = deferred();
  const { page, calls } = setup({ hduHelpData: async () => input, refreshHduHelpResource: () => pending.promise });
  page.activeService = 2;
  await page.loadCampusInfo();
  assert.deepEqual(page.displayedSections().map(section => section.resource), ['card_balance', 'library_reading']);
  const refresh = page.refreshCampusResource('library_reading');
  await page.refreshCampusResource('library_reading');
  await page.refreshCampusResource('card_balance');
  assert.deepEqual(calls[1], ['refreshHduHelpResource', 'library_reading', 'account-a']);
  assert.equal(calls.length, 2);
  assert.deepEqual(page.campusSections, [card]);
  pending.reject(requestFailure(504, '{"code":"HDUHELP_TIMEOUT"}'));
  await refresh;
  assert.equal(page.campusStatuses.library_reading.issue, 'timeout');
  assert.deepEqual(page.campusStatuses.card_balance, cachedStatus);
  assert.deepEqual(page.campusSections, [card]);
  assert.equal(page.campusRefreshingResource, '');
});

test('switching accounts discards retained sections and ignores a previous resource refresh', async () => {
  const card = { resource: 'card_balance', title: '旧账号卡余额', summary: '余额', items: [] };
  const input = { status: { configured: true }, sections: [card], suggested_prompts: [], resource_statuses: { card_balance: cachedStatus } };
  const pending = deferred();
  const { page } = setup({ hduHelpData: async () => input, refreshHduHelpResource: () => pending.promise });
  page.activeService = 3;
  await page.loadCampusInfo();
  const refresh = page.refreshCampusResource('card_balance');
  page.token = 'account-b';
  page.scopeChanged();
  pending.resolve(input);
  await refresh;
  assert.deepEqual(page.displayedSections(), []);
  assert.equal(page.campusInfoLoaded, false);
  assert.equal(page.campusRefreshingResource, '');
});

test('replacing the campus authorization clears old cards before the next load', async () => {
  const oldCard = { resource: 'card_balance', title: '旧校园身份', summary: '', items: [] };
  const newCard = { ...oldCard, title: '新校园身份' };
  const payload = (card) => ({ status: { configured: true }, sections: [card],
    suggested_prompts: [], resource_statuses: { card_balance: cachedStatus } });
  const oldRefresh = deferred();
  const newRead = deferred();
  const { page, hooks } = setup({
    hduHelpData: async () => payload(oldCard), refreshHduHelpResource: () => oldRefresh.promise
  });
  page.activeService = 3;
  await page.loadCampusInfo();
  const refresh = page.refreshCampusResource('card_balance');
  hooks.hduHelpData = () => newRead.promise;
  page.connectionRevision++;
  page.bindingChanged();
  assert.equal(page.token, 'account-a');
  assert.deepEqual(page.displayedSections(), []);
  newRead.resolve(payload(newCard));
  await flush();
  oldRefresh.resolve(payload(oldCard));
  await refresh;
  assert.deepEqual(page.displayedSections(), [newCard]);
});
