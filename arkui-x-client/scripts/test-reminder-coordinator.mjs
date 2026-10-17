import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';
const source = readFileSync(new URL('../entry/src/main/ets/utils/ReminderCoordinator.ets', import.meta.url), 'utf8').replace(/^import .*;\n/gm, '');
const { ReminderCoordinator, buildReminderPlan } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source)).toString('base64')}`);
const now = Date.parse('2026-10-18T04:00:00Z');
const task = (overrides = {}) => ({ task_id: 't1', status: 'pending', start_at: '2026-10-18T13:00:00+08:00', reminder_minutes: 0, ...overrides });
const overview = tasks => ({ tasks, total_tasks: tasks.length });
const tick = async () => { for (let n = 0; n < 50; n++) await Promise.resolve(); };
const deferred = () => { let resolve, reject; const promise = new Promise((a,b) => {resolve=a;reject=b;}); return {promise,resolve,reject}; };
class Driver {
  calls = []; state = {permission:'granted',scope:'A',scheduled:0,mode:'system',limited:false};
  async status() { this.calls.push('status'); return {...this.state}; }
  async authorize(scope) { this.calls.push(['authorize',scope]); this.state.scope=scope; return {...this.state}; }
  async replace(scope,items) { this.calls.push(['replace',scope,structuredClone(items)]); this.state={...this.state,scope,scheduled:items.length}; return {...this.state}; }
  async clear(scope) { this.calls.push(['clear',scope]); if(this.state.scope === scope) this.state={...this.state,scope:'',scheduled:0}; return {...this.state}; }
  dispose() { this.calls.push('dispose'); }
}
function setup(driver = new Driver()) { const states=[]; const coordinator=new ReminderCoordinator(driver,s=>states.push(s),()=>now); return {driver,states,coordinator}; }

test('zero-minute is valid; completed, timeless, no reminder and expired tasks excluded',()=>{
  const result=buildReminderPlan(overview([task(),task({task_id:'complete',status:'completed'}),task({task_id:'none',reminder_minutes:null}),task({task_id:'all-day',start_at:null}),task({task_id:'past',start_at:'2026-10-17T13:00:00+08:00'})]),now);
  assert.deepEqual(result,{items:[{id:'cf_t1',fire_at_ms:now+3600000}],skipped:3,limited:false});
});
test('explicit offsets honored; missing zone and impossible date reject whole snapshot',()=>{
  assert.equal(buildReminderPlan(overview([task({start_at:'2026-10-18T05:00:00Z'})]),now).items[0].fire_at_ms,now+3600000);
  for(const start_at of ['2026-02-30T13:00:00Z','2026-10-18T24:00:00Z','2026-10-18T13:00:00','bad']) assert.throws(()=>buildReminderPlan(overview([task({start_at})]),now));
});
test('partial duplicate malformed snapshots cannot partially replace reminders',()=>{
  for(const value of [{},null,{tasks:[],total_tasks:1},overview([task(),task()]),overview([task({task_id:'../x'})]),overview([task({status:'unknown'})]),overview([task({reminder_minutes:0.5})]),overview([task({reminder_minutes:-1})]),overview([task({start_at:undefined})])]) assert.throws(()=>buildReminderPlan(value,now));
});
test('nearest sixty are deterministic and beyond a year is explicitly deferred',()=>{
  const tasks=Array.from({length:70},(_,n)=>task({task_id:`task${n}`,start_at:new Date(now+(n+1)*60000).toISOString()}));tasks.push(task({task_id:'far',start_at:new Date(now+367*86400000).toISOString()}));
  const result=buildReminderPlan(overview(tasks.reverse()),now);assert.equal(result.items.length,60);assert.equal(result.items[0].id,'cf_task0');assert.equal(result.items.at(-1).id,'cf_task59');assert.equal(result.limited,true);assert.equal(result.skipped,1);
});
test('configure never prompts and authorized account reconciles full list',async()=>{
  const {driver,states,coordinator}=setup();coordinator.configure('A',async()=>overview([task()]));await tick();assert.equal(driver.calls.some(c=>c[0]==='authorize'),false);assert.equal(driver.calls.find(c=>c[0]==='replace')[2][0].id,'cf_t1');assert.equal(states.at(-1).scheduled,1);assert.match(states.at(-1).message,/系统已接受/);
});
test('unauthorized account waits for explicit enable and OS acceptance',async()=>{
  const driver=new Driver();driver.state={...driver.state,scope:'',permission:'unknown'};const {coordinator,states}=setup(driver);let loads=0;coordinator.configure('A',async()=>{loads++;return overview([task()]);});await tick();assert.equal(loads,0);driver.authorize=async scope=>{driver.state={...driver.state,scope,permission:'granted'};return {...driver.state};};await coordinator.enable();await tick();assert.equal(loads,1);assert.equal(states.at(-1).enabled,true);
});
test('permission denial never schedules or claims enabled',async()=>{
  const driver=new Driver();driver.state={...driver.state,scope:'',permission:'denied'};const {coordinator,states}=setup(driver);coordinator.configure('A',async()=>overview([task()]));await tick();await coordinator.enable();await tick();assert.equal(states.at(-1).enabled,false);assert.equal(driver.calls.some(c=>c[0]==='replace'),false);
});
test('incomplete response and network failure retain existing reminders',async()=>{
  for(const load of [async()=>({tasks:[],total_tasks:1}),async()=>{throw new Error('offline');}]){const {driver,states,coordinator}=setup();driver.state.scheduled=2;coordinator.configure('A',load);await tick();assert.equal(driver.calls.some(c=>c[0]==='replace'||c[0]==='clear'),false);assert.equal(states.at(-1).phase,'error');assert.equal(driver.state.scheduled,2);}
});
test('new mutation invalidates old in-flight read',async()=>{
  const old=deferred();const {driver,coordinator}=setup();let calls=0;coordinator.configure('A',async()=>++calls===1?old.promise:overview([task({task_id:'new'})]));await tick();coordinator.refresh();old.resolve(overview([task({task_id:'old'})]));await tick();const writes=driver.calls.filter(c=>c[0]==='replace');assert.equal(writes.length,1);assert.equal(writes[0][2][0].id,'cf_new');
});
test('background invalidates read but retains reminders; foreground refreshes',async()=>{
  const old=deferred();const {driver,coordinator}=setup();let n=0;coordinator.configure('A',async()=>++n===1?old.promise:overview([task()]));await tick();coordinator.setActive(false);old.resolve(overview([]));await tick();assert.equal(driver.calls.some(c=>c[0]==='replace'||c[0]==='clear'),false);coordinator.setActive(true);await tick();assert.equal(driver.calls.filter(c=>c[0]==='replace').length,1);
});
test('account switch clears previous consent without silently authorizing new account',async()=>{
  const {driver,coordinator,states}=setup();driver.state.scheduled=2;coordinator.configure('B',async()=>overview([task()]));await tick();assert.deepEqual(driver.calls,['status',['clear','A']]);assert.equal(states.at(-1).enabled,false);assert.equal(driver.state.scope,'');
});
test('logout during permission wait clears late consent before completion',async()=>{
  const driver=new Driver();driver.state.scope='';const wait=deferred();driver.authorize=async scope=>{await wait.promise;driver.state.scope=scope;return {...driver.state};};const {coordinator}=setup(driver);coordinator.configure('A',async()=>overview([task()]));await tick();const enabling=coordinator.enable();await tick();const leaving=coordinator.logout();wait.resolve();await enabling;await leaving;await tick();assert.equal(driver.state.scope,'');assert.equal(driver.calls.some(c=>c[0]==='replace'),false);
});
test('cleanup failure remains explicit and retryable without losing ownership',async()=>{
  const {driver,coordinator,states}=setup();coordinator.configure('A',async()=>overview([task()]));await tick();const clear=driver.clear.bind(driver);driver.clear=async()=>{throw new Error('OS denied');};await assert.rejects(coordinator.disable(),/REMINDER_CLEANUP_FAILED/);assert.equal(driver.state.scope,'A');assert.equal(states.at(-1).phase,'error');assert.match(states.at(-1).message,/旧提醒可能仍出现/);driver.clear=clear;await coordinator.disable();assert.equal(driver.state.scope,'');assert.equal(states.at(-1).phase,'disabled');
});
test('completion/deletion cancel; retained tasks after plan deletion stay scheduled',async()=>{
  const {driver,coordinator}=setup();let tasks=[task()];coordinator.configure('A',async()=>overview(tasks));await tick();tasks=[task({status:'completed'})];coordinator.refresh();await tick();assert.equal(driver.state.scheduled,0);tasks=[task({plan_id:null})];coordinator.refresh();await tick();assert.equal(driver.state.scheduled,1);tasks=[];coordinator.refresh();await tick();assert.equal(driver.state.scheduled,0);
});
test('partial acknowledgement never claims all accepted',async()=>{
  const driver=new Driver();driver.replace=async()=>({...driver.state,scheduled:0});const {coordinator,states}=setup(driver);coordinator.configure('A',async()=>overview([task()]));await tick();assert.equal(states.at(-1).phase,'error');
});
test('disposed coordinator ignores late data and never deletes system schedule',async()=>{
  const wait=deferred();const {driver,coordinator,states}=setup();coordinator.configure('A',()=>wait.promise);await tick();coordinator.dispose();const count=states.length;wait.resolve(overview([task()]));await tick();assert.equal(states.length,count);assert.equal(driver.calls.some(c=>c[0]==='clear'||c[0]==='replace'),false);
});
test('legacy date-only and manual Shanghai 23:59 all-day convention never become timed alerts',()=>{
  const result=buildReminderPlan(overview([task({task_id:'day',start_at:'2026-10-19'}),task({task_id:'manual',source:'manual',end_at:null,start_at:'2026-10-19T15:59:00Z'})]),now);
  assert.deepEqual(result,{items:[],skipped:2,limited:false});
});
test('failed old-account cleanup cannot authorize new account',async()=>{
  const driver=new Driver();driver.clear=async()=>({...driver.state});const {coordinator,states}=setup(driver);coordinator.configure('B',async()=>overview([task()]));await tick();await coordinator.enable();await tick();assert.equal(driver.calls.some(c=>c[0]==='authorize'),false);assert.equal(states.at(-1).phase,'error');
});
test('native capacity limitation reports accepted subset explicitly',async()=>{const driver=new Driver();driver.replace=async()=>({...driver.state,scheduled:30,limited:true});const {coordinator,states}=setup(driver);coordinator.configure('A',async()=>overview(Array.from({length:40},(_,n)=>task({task_id:`t${n}`}))));await tick();assert.equal(states.at(-1).phase,'ready');assert.equal(states.at(-1).scheduled,30);assert.equal(states.at(-1).limited,true);assert.match(states.at(-1).message,/系统容量/);});
test('late logout completion cannot wipe same-account immediate re-login loader',async()=>{const driver=new Driver();const wait=deferred();const old=driver.clear.bind(driver);driver.clear=async scope=>{await wait.promise;return old(scope);};const {coordinator}=setup(driver);coordinator.configure('A',async()=>overview([]));await tick();const leaving=coordinator.logout();await tick();coordinator.configure('A',async()=>overview([task()]));wait.resolve();await leaving;await tick();await coordinator.enable();await tick();assert.equal(driver.state.scheduled,1);});

test('recoverable ledger is cleared before any automatic restore or new permission',async()=>{
  for(const path of ['configure','enable','disable']){
    const driver=new Driver(); const clear=driver.clear.bind(driver);
    driver.clear=async scope=>{const result=await clear(scope);driver.state.cleanup_required=false;return {...result,cleanup_required:false};};
    const {coordinator,states}=setup(driver);
    if(path==='configure'){driver.state.cleanup_required=true;coordinator.configure('A',async()=>overview([task()]));await tick();assert.equal(states.at(-1).enabled,false);}
    else {coordinator.configure('A',async()=>overview([]));await tick();driver.calls=[];driver.state.cleanup_required=true;await coordinator[path]();await tick();}
    const cleanup=driver.calls.findIndex(c=>c[0]==='clear'); assert.ok(cleanup>=0);
    const authorize=driver.calls.findIndex(c=>c[0]==='authorize'); assert.ok(authorize===-1||authorize>cleanup);
    assert.equal(driver.state.cleanup_required,false);
  }
});
test('unacknowledged recovery clear never claims disabled or authorizes',async()=>{
  const driver=new Driver();driver.state.cleanup_required=true;driver.clear=async()=>({...driver.state,scope:'',scheduled:0});
  const {coordinator,states}=setup(driver);coordinator.configure('A',async()=>overview([]));await tick();assert.equal(states.at(-1).phase,'error');
  await coordinator.enable();await assert.rejects(coordinator.disable(),/REMINDER_CLEANUP_FAILED/);assert.equal(driver.calls.some(c=>c[0]==='authorize'),false);
});
