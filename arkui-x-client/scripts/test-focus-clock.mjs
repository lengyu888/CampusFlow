import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {stripTypeScriptTypes} from 'node:module';
import {test} from 'node:test';
const read=p=>readFileSync(new URL(`../${p}`,import.meta.url),'utf8');
const plain=s=>stripTypeScriptTypes(s.replace(/^import [^\n]+;\r?\n/gm,''));
const source=plain(read('entry/src/main/ets/services/PlatformFocusClock.ets')).replace(/^export /gm,'').replace("import('./HarmonyFocusClock')",'loadHarmony()').replace("import('./NativePlatformBridge')",'loadNative()');
const create=new Function('deviceInfo','timetableOperationId','loadHarmony','loadNative',source+'\nreturn {PlatformFocusClock,FocusClockError};');
const id='10000000-0000-4000-8000-000000000001';
const reading={wall_ms:1918592400000,monotonic_ms:4000};
function fixture(os,result=reading){
 let harmony=0,native=0,reads=0;const calls=[];
 class HarmonyFocusClock {async read(){reads++;return typeof result==='function'?result():result;}}
 const mod=create({osFullName:os},()=>id,async()=>{harmony++;return{HarmonyFocusClock};},async()=>{native++;return{nativePlatformBridge:()=>({async request(op){calls.push(op);reads++;return typeof result==='function'?result():result;}})};});
 return {...mod,clock:new mod.PlatformFocusClock(),calls,loads:()=>({harmony,native,reads})};
}
test('native clocks share the existing native port, request only a clock sample, and preserve one random session',async()=>{
 for(const os of ['Android 15','iOS 18','iPadOS 18']){
  const f=fixture(os);for(let i=0;i<2;i++)assert.deepEqual(await f.clock.sample(),{wallMs:reading.wall_ms,monotonicMs:reading.monotonic_ms,clockSessionId:id});
  assert.deepEqual(f.calls,['clock.sample','clock.sample']);assert.deepEqual(f.loads(),{harmony:0,native:1,reads:2});
 }
});
test('Harmony clock is lazy and isolated from native bridge initialization',async()=>{
 for(const os of ['HarmonyOS 6','OpenHarmony 5']){
  const f=fixture(os);assert.deepEqual(f.loads(),{harmony:0,native:0,reads:0});await f.clock.sample();await f.clock.sample();
  assert.deepEqual(f.loads(),{harmony:1,native:0,reads:2});assert.deepEqual(f.calls,[]);
 }
});
test('unsupported clocks never fall back to wall time or load the wrong platform',async()=>{
 const f=fixture('Unknown');await assert.rejects(f.clock.sample(),e=>e.code==='FOCUS_CLOCK_UNAVAILABLE');assert.deepEqual(f.loads(),{harmony:0,native:0,reads:0});
});
test('malformed native clock samples cannot silently turn into a timer',async()=>{
 for(const bad of [null,[],{}, {...reading,monotonic_ms:-1},{...reading,monotonic_ms:1.2},{...reading,wall_ms:Infinity},{...reading,wall_ms:0},{...reading,wall_ms:8640000000000001}, {...reading,monotonic_ms:'42'}]){
  const f=fixture('Android 15',bad);await assert.rejects(f.clock.sample(),e=>e.code==='FOCUS_CLOCK_INVALID_RESPONSE');
 }
 const good=fixture('Android 15',{...reading,monotonic_ms:0,private:'ignored'});assert.deepEqual(Object.keys(await good.clock.sample()).sort(),['clockSessionId','monotonicMs','wallMs']);
});
test('failed clock access stays safe and can be explicitly sampled again without losing session identity',async()=>{
 let fail=true;const f=fixture('iOS 18',()=>{if(fail)throw Error('private native exception');return reading;});
 await assert.rejects(f.clock.sample(),e=>e.code==='FOCUS_CLOCK_UNAVAILABLE'&&!e.message.includes('private'));fail=false;
 assert.equal((await f.clock.sample()).clockSessionId,id);assert.equal(f.loads().native,2);
});
test('invalid process identity is refused before platform access',async()=>{
 const {PlatformFocusClock}=create({},()=>'',()=>{},()=>{});const clock=new PlatformFocusClock();await assert.rejects(clock.sample(),e=>e.code==='FOCUS_CLOCK_INVALID_RESPONSE');
});
test('actual Harmony adapter uses API10 monotonic uptime in milliseconds and keeps wall time separate',async()=>{
 const source=plain(read('entry/src/main/ets/services/HarmonyFocusClock.ets')).replace(/^export /gm,'');const calls=[];
 const Adapter=new Function('systemDateTime','Date',source+'\nreturn HarmonyFocusClock;')({TimeType:{STARTUP:0},getUptime(...args){calls.push(args);return 3456;}},{now:()=>1918592400000});
 assert.deepEqual(await new Adapter().read(),{wall_ms:1918592400000,monotonic_ms:3456});assert.deepEqual(calls,[[0,false]]);
});
test('actual shared bridge carries clock replies without interrupting voice listeners and rejects extra clock arguments',async()=>{
 const mod=await import(`data:text/javascript;base64,${Buffer.from(plain(read('entry/src/main/ets/services/NativePlatformBridge.ets'))).toString('base64')}`);
 let receiver;const calls=[],voice=[];const bridge=new mod.NativePlatformBridge({async register(r){receiver=r;},async dispatch(json){const cmd=JSON.parse(json);calls.push(cmd);receiver(JSON.stringify({v:1,kind:'reply',request_id:cmd.request_id,ok:true,code:'',result:reading}));return'accepted';}});
 bridge.subscribeVoice(e=>voice.push(e));assert.deepEqual(await bridge.request('clock.sample'),reading);
 receiver(JSON.stringify({v:1,kind:'voice',operation_id:'voice',event:'speech_complete'}));assert.equal(voice.length,1);
 assert.deepEqual(Object.keys(calls[0]).sort(),['op','request_id','v']);
 for(const args of [{scope:'private'},{operation_id:'x'},{raw_uptime:12}])await assert.rejects(bridge.request('clock.sample',args),e=>e.code==='INVALID_REQUEST');assert.equal(calls.length,1);
});
test('native source contracts use platform elapsed clocks and include the boot-time reason resource',()=>{
 const android=read('.arkui-x/android/app/src/main/java/com/campusflow/agent/CampusFlowPlatformBridge.java');
 const ios=read('.arkui-x/ios/app/CFPlatformBridge.m'),codec=read('.arkui-x/ios/app/CFNativeProtocol.m');
 assert.match(android,/case "clock\.sample":[\s\S]*?SystemClock\.elapsedRealtime\(\)/);assert.match(android,/op\.equals\("clock\.sample"\) && json\.length\(\) != 3/);
 assert.match(ios,/floor\(NSProcessInfo\.processInfo\.systemUptime \* 1000\.0\)/);assert.match(codec,/@"clock\.sample"/);
 const privacy=read('.arkui-x/ios/app/PrivacyInfo.xcprivacy'),project=read('.arkui-x/ios/app.xcodeproj/project.pbxproj');
 assert.match(privacy,/<string>NSPrivacyAccessedAPICategorySystemBootTime<\/string>/);assert.match(privacy,/<string>35F9\.1<\/string>/);
 assert.match(project,/PBXResourcesBuildPhase[\s\S]*?PrivacyInfo\.xcprivacy in Resources/);
});
