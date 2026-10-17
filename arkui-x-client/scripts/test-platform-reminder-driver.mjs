import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';
const read = path => readFileSync(new URL(`../entry/src/main/ets/${path}.ets`,import.meta.url),'utf8');
const plain = source => stripTypeScriptTypes(source.replace(/^import [^\n]+;\r?\n/gm,''));
const helper=await import(`data:text/javascript;base64,${Buffer.from(plain(read('utils/ReminderCoordinator'))).toString('base64')}`);
const source=plain(read('services/PlatformReminderDriver')).replace("import('./HarmonyReminderDriver')",'loadHarmony()')
  .replace("import('./NativePlatformBridge')",'loadNative()').replace('export class PlatformReminderDriver','class PlatformReminderDriver');
const create=new Function('deviceInfo','validReminderStatus','loadHarmony','loadNative',source+'\nreturn PlatformReminderDriver;');
const status=(overrides={})=>({permission:'granted',scope:'server|a',scheduled:0,mode:'system',limited:false,...overrides});
function setup(os,result=status()) {
 const calls=[]; let harmony=0,native=0;
 const facade={async request(op,args){calls.push([op,args]);return typeof result==='function'?result(op,args):result;}};
 class Harmony { constructor(ctx){assert.equal(ctx,'ctx');} async status(){calls.push(['harmony.status']);return status();} dispose(){calls.push(['dispose']);} }
 const Adapter=create({osFullName:os},helper.validReminderStatus,async()=>{harmony++;return{HarmonyReminderDriver:Harmony};},async()=>{native++;return{nativePlatformBridge:()=>facade};});
 return {driver:new Adapter('ctx'),calls,loads:()=>({harmony,native})};
}
test('native status reads without permission prompts, and explicit authorization shares one bridge loader',async()=>{
 for(const os of ['Android 15','iOS 18','iPadOS 18']){
  const f=setup(os);assert.deepEqual(await f.driver.status(),status());assert.deepEqual(f.calls,[['reminders.status',undefined]]);
  await f.driver.authorize('server|a');assert.deepEqual(f.calls.at(-1),['reminders.authorize',{scope:'server|a'}]);
  assert.deepEqual(f.loads(),{harmony:0,native:1});
 }
});
test('native replace maps only an acknowledged count/mode and rejects malformed or impossible counts',async()=>{
 const items=[{id:'cf_task',fire_at_ms:Date.now()+60000}];
 const f=setup('Android 15',{scheduled:1,mode:'inexact',limited:false});
 assert.deepEqual(await f.driver.replace('server|a',items),status({scheduled:1,mode:'inexact'}));
 assert.deepEqual(f.calls[0],['reminders.replace',{scope:'server|a',reminders:items}]);
 for(const bad of [{scheduled:2,mode:'system',limited:false},{scheduled:0,mode:'system',limited:false},{scheduled:1,mode:'invented',limited:false},{scheduled:1,mode:'system'}]){
  await assert.rejects(setup('Android 15',bad).driver.replace('server|a',items),/INVALID_REMINDER_RESPONSE/);
 }
});
test('clear propagates exact scope and no facade disposal silently clears OS reminders',async()=>{
 const f=setup('iOS 18',status({scope:'',scheduled:0}));
 await f.driver.clear('server|a');f.driver.dispose();await Promise.resolve();
 assert.deepEqual(f.calls,[['reminders.clear',{scope:'server|a'}]]);await assert.rejects(f.driver.status(),/DISPOSED/);
});
test('Harmony dynamically selects its adapter while unknown platforms never claim scheduling support',async()=>{
 const h=setup('HarmonyOS 6');await h.driver.status();assert.deepEqual(h.loads(),{harmony:1,native:0});
 const u=setup('Unknown');assert.equal((await u.driver.status()).permission,'unsupported');
 await assert.rejects(u.driver.clear('server|a'),/UNSUPPORTED/);assert.deepEqual(u.loads(),{harmony:0,native:0});
});
test('a disposed facade rejects a late native load without dispatching or destroying the shared port',async()=>{
 let resolve;const pending=new Promise(ok=>resolve=ok);const calls=[];
 const Adapter=create({osFullName:'Android 15'},helper.validReminderStatus,()=>{},()=>pending);const driver=new Adapter('ctx');
 const request=driver.status();driver.dispose();resolve({nativePlatformBridge:()=>({request(){calls.push('dispatch');}})});
 await assert.rejects(request,/DISPOSED/);assert.deepEqual(calls,[]);
});
test('cleanup-required ledger state survives projection and malformed cleanup flags are rejected', async()=>{
 const pending=setup('iOS 18',status({cleanup_required:true}));assert.equal((await pending.driver.status()).cleanup_required,true);
 await assert.rejects(setup('iOS 18',status({cleanup_required:'true'})).driver.status(),/INVALID_REMINDER_RESPONSE/);
 const items=Array.from({length:40},(_,i)=>({id:`t${i}`,fire_at_ms:Date.now()+3600000}));
 const limited=setup('Android 15',{scheduled:30,mode:'system',limited:true});assert.equal((await limited.driver.replace('server|a',items)).scheduled,30);
 await assert.rejects(setup('iOS 18',{scheduled:0,mode:'system',limited:true}).driver.replace('server|a',items),/INVALID_REMINDER_RESPONSE/);
});
