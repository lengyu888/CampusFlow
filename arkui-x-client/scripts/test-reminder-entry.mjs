import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';
const read = path => readFileSync(new URL(`../entry/src/main/ets/${path}.ets`,import.meta.url),'utf8');
const methods = (source,name) => stripTypeScriptTypes(source.slice(0,source.indexOf('\n  @Builder'))
  .replace(/^import [^\n]+;\r?\n/gm,'').replace(/^@(Entry|Component)\r?\n/gm,'')
  .replace(/@(State|Prop)\s+|@(Watch|StorageLink)\('[^']+'\)\s*/g,'').replace(`export struct ${name}`,`class ${name}`).replace(`struct ${name}`,`class ${name}`)+'\n}\n');
const navigation=await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(read('utils/AppNavigation'))).toString('base64')}`);
const names=['createNavigation','currentRoute','selectRoot','openSecondary','backNavigation','isRootRoute','hasBack'];
const {DraftStore}=await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(read('utils/DraftStore'))).toString('base64')}`);
const indexSource=read('pages/Index');
const create=new Function('localHistory','historyScope','CampusFlowApi','AppStorage','AppTheme','Curve','ReminderCoordinator','PlatformReminderDriver','localDrafts',...names,
  methods(indexSource,'Index')+'\nreturn Index;');
const deferred=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b;});return{promise,resolve,reject};};
function setup({activate=async()=>{},load=async()=>({tasks:[]}),cleanup=async()=>{},disable=async()=>{}}={}) {
 const calls=[];let manager;let published;
 class Coordinator {
  constructor(driver,notify){calls.push(['manager']);this.notify=notify;manager=this;published=notify;}
  configure(scope,loader){this.scope=scope;this.loader=loader;calls.push(['configure',scope]);}
  setActive(active){calls.push(['active',active]);}
  refresh(){calls.push(['refresh']);}
  async enable(){calls.push(['enable']);}
  async disable(){calls.push(['disable']);await disable();}
  async logout(){calls.push(['cleanup']);await cleanup();}
  dispose(){calls.push(['dispose']);}
 }
 class Driver{constructor(ctx){assert.equal(ctx,'context');}}
 class Api{constructor(base,token){this.base=base;this.token=token;}async planning(){calls.push(['planning',this.base,this.token]);return load();}async logout(){calls.push(['revoke',this.token]);}}
 const store={activate,clear:async()=>calls.push(['clear-cache']),info:()=>({scope:'cache',displayName:'a',count:0})};
 let draftText;const drafts=new DraftStore({read:async()=>draftText,write:async value=>{draftText=value;},remove:async()=>{draftText=undefined;}});drafts.initialize();
 const Index=create(store,(base,id)=>`${base}|${id}`,Api,{setOrCreate(){}},{motion:()=>0},{EaseOut:0},Coordinator,Driver,drafts,...names.map(n=>navigation[n]));
 const page=new Index();page.baseUrl='https://example.test';page.getUIContext=()=>({getHostContext:()=> 'context',animateTo:(_o,f)=>f()});
 return{page,calls,manager:()=>manager,publish:s=>published(s)};
}
const auth=id=>({access_token:`token-${id}`,user:{user_id:id,display_name:id}});
test('login configures account-scoped reminders even when local history fails, without authorizing permissions',async()=>{
 const f=setup({activate:async()=>{throw Error('disk');}});await f.page.authenticated(auth('a'));
 assert.equal(f.page.cacheScope,'');assert.equal(f.manager().scope,'https://example.test|a');
 assert.equal(f.calls.some(c=>c[0]==='enable'),false);assert.equal(f.calls.filter(c=>c[0]==='manager').length,1);
 await f.page.enableReminders();assert.equal(f.calls.filter(c=>c[0]==='enable').length,1);
});
test('foreground updates and authoritative planning callbacks refresh the one coordinator without clearing reminders',async()=>{
 const f=setup();await f.page.authenticated(auth('a'));f.calls.length=0;
 f.page.voiceForeground=false;f.page.reminderActivityChanged();f.page.voiceForeground=true;f.page.reminderActivityChanged();
 const home=f.page.homeRefresh,plan=f.page.planRefresh;f.page.timetableChanged();
 assert.deepEqual(f.calls,[['active',false],['active',true],['refresh']]);
 assert.equal(f.page.homeRefresh,home+1);assert.equal(f.page.planRefresh,plan+1);
});
test('service changes reject stale task reads and log out instead of forwarding old credentials',async()=>{
 const read=deferred(),f=setup({load:()=>read.promise});await f.page.authenticated(auth('a'));
 const old=f.manager().loader();f.page.baseUrl='https://other.test';f.page.reminderAccountChanged();
 read.resolve({tasks:[]});await assert.rejects(old,/ACCOUNT_CHANGED/);assert.equal(f.page.token,'');
 assert.equal(f.manager().scope,'https://example.test|a');
 assert.equal(f.calls.some(c=>c[0]==='configure'&&c[1]==='https://other.test|a'),false);
});
test('logout closes auth immediately, still clears cache/revokes token, and failed OS cleanup is explicit and retryable',async()=>{
 const pending=deferred();const f=setup({cleanup:()=>pending.promise});await f.page.authenticated(auth('a'));f.calls.length=0;
 const logout=f.page.logout();assert.equal(f.page.token,'');assert.equal(f.calls[0][0],'cleanup');
 pending.reject(Error('OS private error'));await logout;
 assert.match(f.page.reminderCleanupNotice,/旧提醒可能仍出现/);assert.doesNotMatch(f.page.reminderCleanupNotice,/private/);
 assert.ok(f.calls.some(c=>c[0]==='clear-cache'));assert.ok(f.calls.some(c=>c[0]==='revoke'&&c[1]==='token-a'));
 await f.page.disableReminders();assert.equal(f.page.reminderCleanupNotice,'');assert.equal(f.page.reminderCleanupBusy,false);
});
test('late old logout failure never overwrites a new account notice or login; repeated cleanup failure remains visible',async()=>{
 const pending=deferred();const f=setup({cleanup:()=>pending.promise,disable:async()=>{throw Error('failed');}});
 await f.page.authenticated(auth('a'));const logout=f.page.logout();await f.page.authenticated(auth('b'));
 pending.reject(Error('failed'));await logout;assert.equal(f.page.token,'token-b');assert.equal(f.page.reminderCleanupNotice,'');
 await f.page.disableReminders();assert.match(f.page.reminderCleanupNotice,/旧提醒可能仍出现/);assert.equal(f.page.reminderCleanupBusy,false);
});
test('entry teardown disposes its facade and drops late state updates without clearing scheduled reminders',async()=>{
 const f=setup();await f.page.authenticated(auth('a'));const before=f.page.reminderState;
 f.page.aboutToDisappear();f.publish({phase:'ready'});assert.equal(f.page.reminderState,before);
 assert.equal(f.calls.filter(c=>c[0]==='dispose').length,1);assert.equal(f.calls.some(c=>c[0]==='cleanup'),false);
});
const homeSource=read('pages/HomePage');
const Home=new Function('Scroller','CampusFlowApi','CampusFlowRequestError',methods(homeSource,'HomePage')+'\nreturn HomePage;');
test('Home completion success still refreshes reminders after a tab change; ambiguous writes never remove reminders optimistically',async()=>{
 for(const success of [true,false]){
  const pending=deferred();class Api{async updateTask(){return pending.promise;}}
  const Page=Home(class{},Api,class extends Error{});const page=new Page();page.baseUrl='server';page.token='token';
  let updates=0,reads=0;page.onPlanningChanged=()=>updates++;page.loadToday=async()=>reads++;
  const write=page.toggleTask({task_id:'task',status:'pending'});page.active=false;page.activityChanged();
  if(success)pending.resolve({});else pending.reject(Error('unknown'));
  await write;assert.equal(updates,success?1:0);assert.equal(reads,0);
 }
});
test('Home ignores a successful old-account write after teardown and Index wires all authoritative mutation sources',async()=>{
 const pending=deferred();class Api{async updateTask(){return pending.promise;}}
 const Page=Home(class{},Api,class extends Error{});const page=new Page();page.baseUrl='server';page.token='token';let changed=0;
 page.onPlanningChanged=()=>changed++;const write=page.toggleTask({task_id:'t',status:'pending'});page.aboutToDisappear();pending.resolve({});await write;assert.equal(changed,0);
 for(const component of ['HomePage','AgentPage','PlanCenterPage']){
  const chunk=indexSource.slice(indexSource.indexOf(`${component}({`));
  assert.match(chunk.slice(0,chunk.indexOf('.visibility')),/onPlanningChanged: \(\) => this.timetableChanged\(\)/);
 }
 assert.match(indexSource,/@Watch\('reminderActivityChanged'\) @StorageLink\('voiceForeground'\)/);
 assert.match(indexSource,/actionLabel: '重试关闭提醒'.*onAction: \(\) => this.disableReminders\(\)/);
});
