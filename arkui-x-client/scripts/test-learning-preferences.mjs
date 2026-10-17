import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';
const read=name=>readFileSync(new URL(`../entry/src/main/ets/utils/${name}.ets`,import.meta.url),'utf8').replace(/^import [^\n]+;\r?\n/gm,'');
const feedback=await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(read('AgentFeedback'))).toString('base64')}`);
const names=['LearningPreferencesController','validPreferenceSnapshot','defaultPreferenceDraft','preferenceIssues','preferenceOperationId'];
const code=stripTypeScriptTypes(read('LearningPreferences')).replace(/^export /gm,'');
const api=new Function('CampusFlowRequestError',code+`\nreturn {${names.join(',')}};`)(feedback.CampusFlowRequestError);
const value=(extra={})=>({revision:0,enabled:false,session_minutes:50,break_minutes:10,preferred_period:'any',daily_minutes:120,updated_at:null,...extra});
const uuid='11111111-1111-4111-8111-111111111111';
const tick=()=>new Promise(ok=>setImmediate(ok));
const deferred=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b;});return{promise,resolve,reject};};
function setup(hooks={}){
 const calls=[],states=[];let latest=value(),ids=0;
 const gateway={async learningPreferences(){calls.push(['get']);return hooks.get?hooks.get():latest;},
  async saveLearningPreferences(payload){calls.push(['save',structuredClone(payload)]); if(hooks.save)return hooks.save(payload);latest=value({...payload,revision:payload.base_revision+1,updated_at:'2026-10-18T08:00:00Z'});return latest;},
  async clearLearningPreferences(payload){calls.push(['clear',structuredClone(payload)]);if(hooks.clear)return hooks.clear(payload);latest=value({revision:payload.base_revision+1,updated_at:'2026-10-18T08:00:00Z'});return latest;}};
 const c=new api.LearningPreferencesController(gateway,s=>states.push(s),()=>{ids++;return uuid;});c.configure('server|a',gateway);c.setActive(true);
 return{c,calls,states,gateway,ids:()=>ids,setLatest:v=>latest=v};
}
const edit=c=>c.edit({...c.snapshot().draft,enabled:true,session:'60',period:'evening'});
test('preference form validates exact integer ranges and all controlled periods without truncation',()=>{
 assert.equal(api.preferenceIssues(api.defaultPreferenceDraft()).length,0);
 for(const change of [{session:''},{session:'14'},{session:'121'},{session:'50.5'},{rest:'31'},{rest:'-1'},{daily:'29'},{daily:'481'},{period:'guess'}])assert.ok(api.preferenceIssues({...api.defaultPreferenceDraft(),...change}).length>0);
 assert.equal(api.preferenceIssues({...api.defaultPreferenceDraft(),session:'120',rest:'0',daily:'480',period:'morning'}).length,0);
 assert.match(api.preferenceOperationId(),/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
 for(const bad of [null,value({revision:-1}),value({session_minutes:'50'}),value({updated_at:'bad'}),value({revision:1})])assert.equal(api.validPreferenceSnapshot(bad),false);
});
test('draft refresh preserves unsaved values; explicit discard only replaces after successful read',async()=>{
 const f=setup();await tick();edit(f.c);f.setLatest(value({revision:1,session_minutes:30,updated_at:'2026-10-18T08:00:00Z'}));
 await f.c.load();assert.equal(f.c.snapshot().draft.session,'60');assert.equal(f.c.snapshot().snapshot.session_minutes,30);assert.equal(f.c.snapshot().dirty,true);
 f.gateway.learningPreferences=async()=>{throw Error('raw');};await f.c.load(true);assert.equal(f.c.snapshot().draft.session,'60');
 f.gateway.learningPreferences=async()=>value();await f.c.load(true);assert.equal(f.c.snapshot().dirty,false);assert.equal(f.c.snapshot().draft.session,'50');
});
test('save is CAS-bound and double taps create only one UUID/write; published snapshots cannot alias the draft',async()=>{
 const waiting=deferred(),f=setup({save:()=>waiting.promise});await tick();edit(f.c);const write=f.c.save();await f.c.save();
 assert.equal(f.ids(),1);assert.equal(f.calls.filter(c=>c[0]==='save').length,1);assert.equal(f.calls.at(-1)[1].base_revision,0);
 f.states.at(-1).draft.session='100';assert.equal(f.c.snapshot().draft.session,'60');
 waiting.resolve(value({revision:1,enabled:true,session_minutes:60,preferred_period:'evening',updated_at:'2026-10-18T08:00:00Z'}));await write;
 assert.equal(f.c.snapshot().phase,'applied');assert.equal(f.c.snapshot().dirty,false);
});
test('unknown write freezes payload/UUID and only explicit retry replays that same operation',async()=>{
 let attempt=0;const f=setup({save:p=>{if(++attempt===1)throw Error('secret transport');return value({...p,revision:1,updated_at:'2026-10-18T08:00:00Z'});}});await tick();edit(f.c);await f.c.save();
 assert.equal(f.c.snapshot().phase,'unknown');assert.equal(f.c.snapshot().canRetry,true);assert.doesNotMatch(f.c.snapshot().message,/secret/);
 f.c.edit({...f.c.snapshot().draft,session:'80'});await f.c.save();f.c.askClear();await f.c.clear();assert.equal(f.c.snapshot().draft.session,'60');assert.equal(f.ids(),1);
 await f.c.load();assert.equal(f.c.snapshot().phase,'unknown');assert.equal(f.c.snapshot().canRetry,true);
 await f.c.retry();assert.deepEqual(f.calls.filter(c=>c[0]==='save').map(c=>c[1]),[f.calls[1][1],f.calls[1][1]]);assert.equal(f.ids(),1);assert.equal(f.c.snapshot().phase,'applied');
});
test('stale/retired/reused operation requires reading current revision before a newly explicit write',async()=>{
 for(const code of ['PREFERENCES_CHANGED','OPERATION_RETIRED','OPERATION_ID_REUSED']){
 const f=setup({save:()=>{throw new feedback.CampusFlowRequestError(409,code,'重新核对');}});await tick();edit(f.c);await f.c.save();assert.equal(f.c.snapshot().phase,'stale');
 await f.c.save();assert.equal(f.ids(),1);assert.equal(f.c.snapshot().draft.session,'60');
 f.setLatest(value({revision:5,updated_at:'2026-10-18T08:00:00Z'}));await f.c.load();assert.equal(f.c.snapshot().snapshot.revision,5);assert.equal(f.c.snapshot().draft.session,'60');
 await f.c.save();assert.equal(f.calls.filter(c=>c[0]==='save').at(-1)[1].base_revision,5);
 }
});
test('clear requires a separate confirmation, invalidates it on edits, and resets only after accepted result',async()=>{
 const f=setup();await tick();await f.c.clear();assert.equal(f.calls.filter(c=>c[0]==='clear').length,0);
 f.c.askClear();edit(f.c);await f.c.clear();assert.equal(f.calls.filter(c=>c[0]==='clear').length,0);
 f.c.askClear();await f.c.clear();assert.deepEqual(f.calls.at(-1),['clear',{base_revision:0,operation_id:uuid}]);
 assert.equal(f.c.snapshot().snapshot.revision,1);assert.equal(f.c.snapshot().draft.enabled,false);assert.match(f.c.snapshot().message,/已开始的运行和历史记录不会撤回/);
});
test('hiding pending write preserves unknown operation and old callbacks cannot replace newer account data',async()=>{
 const pending=deferred(),f=setup({save:()=>pending.promise});await tick();edit(f.c);const write=f.c.save();f.c.setActive(false);f.c.setActive(true);
 assert.equal(f.c.snapshot().phase,'unknown');assert.equal(f.c.snapshot().canRetry,false);
 pending.resolve(value({revision:1,session_minutes:60,updated_at:'2026-10-18T08:00:00Z'}));await write;assert.equal(f.c.snapshot().phase,'unknown');assert.equal(f.c.snapshot().canRetry,true);
 const read=deferred();f.gateway.learningPreferences=()=>read.promise;const loading=f.c.load();f.c.configure('server|b',{learningPreferences:async()=>value(),saveLearningPreferences:async()=>value(),clearLearningPreferences:async()=>value()});
 read.resolve(value({revision:99,updated_at:'2026-10-18T08:00:00Z'}));await loading;await tick();assert.equal(f.c.snapshot().snapshot.revision,0);assert.equal(f.c.snapshot().draft.enabled,false);
});
test('same-operation retry returning a newer current snapshot never pretends the old draft is still saved',async()=>{
 const f=setup({save:()=>value({revision:4,session_minutes:25,updated_at:'2026-10-18T08:00:00Z'})});await tick();edit(f.c);await f.c.save();
 assert.equal(f.c.snapshot().snapshot.session_minutes,25);assert.equal(f.c.snapshot().draft.session,'60');assert.equal(f.c.snapshot().dirty,true);assert.match(f.c.snapshot().message,/随后已有其他修改/);
});
test('invalid success remains unknown while explicit validation rejection keeps an editable draft',async()=>{
 for(const response of [value(),null,value({revision:1,session_minutes:500,updated_at:'2026-10-18T08:00:00Z'})]){
 const f=setup({save:()=>response});await tick();edit(f.c);await f.c.save();assert.equal(f.c.snapshot().phase,'unknown');assert.equal(f.c.snapshot().draft.session,'60');}
 const f=setup({save:()=>{throw new feedback.CampusFlowRequestError(422,'HTTP_ERROR','bad');}});await tick();edit(f.c);await f.c.save();assert.equal(f.c.editable(),true);
});
test('disposal silences a pending read and erases permission to reuse its operation',async()=>{
 const pending=deferred(),f=setup({get:()=>pending.promise});const count=f.states.length;f.c.dispose();pending.resolve(value());await tick();assert.equal(f.states.length,count);assert.equal(f.c.editable(),false);
});
test('failed refresh after a stale write never re-enables a new write based on the old revision',async()=>{
 const f=setup({save:()=>{throw new feedback.CampusFlowRequestError(409,'PREFERENCES_CHANGED','changed');}});await tick();edit(f.c);await f.c.save();
 f.gateway.learningPreferences=async()=>{throw Error('offline');};await f.c.load();assert.equal(f.c.snapshot().phase,'stale');assert.equal(f.c.editable(),false);await f.c.save();assert.equal(f.ids(),1);
});

// Exercise the actual component's pre-Builder methods with the real controller.
const panelSource=readFileSync(new URL('../entry/src/main/ets/components/LearningPreferencesPanel.ets',import.meta.url),'utf8');
const panelCode=panelSource.slice(0,panelSource.indexOf('\n  @Builder')).replace(/^import [^\n]+;\r?\n/gm,'')
 .replace(/^@Component\r?\n/gm,'').replace(/@(State|Prop)\s+|@Watch\('[^']+'\)\s*/g,'')
 .replace('export struct LearningPreferencesPanel','class LearningPreferencesPanel')+'\n}';
function panelFixture(){
 const calls=[];class Gateway{async learningPreferences(){calls.push(['read']);return value();}
 async saveLearningPreferences(p){calls.push(['save',p]);return value({...p,revision:1,updated_at:'2026-10-18T08:00:00Z'});}
 async clearLearningPreferences(p){calls.push(['clear',p]);return value({revision:1,updated_at:'2026-10-18T08:00:00Z'});}}
 const Panel=new Function('CampusFlowApi',...Object.keys(api),stripTypeScriptTypes(panelCode)+'\nreturn LearningPreferencesPanel;')(Gateway,...Object.values(api));
 const page=new Panel();page.baseUrl='server';page.token='token';page.userId='a';page.aboutToAppear();return{page,calls};
}
test('real preference panel keeps raw numeric draft and toggle local until explicit save, including hidden settings routes',async()=>{
 const f=panelFixture();await tick();f.page.setEnabled(true);f.page.editField('session','');assert.equal(f.page.state.draft.session,'');
 await f.page.instance().save();assert.match(f.page.fieldError('session'),/15–120/);assert.equal(f.calls.filter(x=>x[0]==='save').length,0);
 f.page.editField('session','60');f.page.active=false;f.page.activityChanged();f.page.active=true;f.page.activityChanged();assert.equal(f.page.state.draft.session,'60');
 await f.page.instance().save();const save=f.calls.find(x=>x[0]==='save')[1];assert.equal(save.enabled,true);assert.equal(save.session_minutes,60);assert.equal(save.base_revision,0);
});
test('real panel resets drafts for changed accounts and Profile keeps it mounted while campus detail is open',async()=>{
 const f=panelFixture();await tick();f.page.editField('session','100');f.page.userId='b';f.page.token='other';f.page.connectionChanged();await tick();assert.equal(f.page.state.draft.session,'50');assert.equal(f.page.state.dirty,false);
 f.page.aboutToDisappear();assert.equal(f.page.controller,null);
 const profile=readFileSync(new URL('../entry/src/main/ets/pages/ProfilePage.ets',import.meta.url),'utf8');
 assert.match(profile,/LearningPreferencesPanel\(\{ baseUrl: this.baseUrl, token: this.token, userId: this.user.user_id, active: this.active && !this.showHduHelpData \}\)/);
 assert.match(profile,/\.visibility\(this.showHduHelpData \? Visibility.Hidden : Visibility.Visible\)/);
});
