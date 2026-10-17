import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';

// Execute the production bridge and voice facade with simulated native dispatch/events.
// No microphone, OS permission prompt, native SDK compilation or notification delivery is emulated.
const read = path => readFileSync(new URL(`../entry/src/main/ets/${path}.ets`, import.meta.url), 'utf8');
const plain = source => stripTypeScriptTypes(source.replace(/^import [^\n]+;\r?\n/gm, ''), { mode: 'transform' });
const bridgeModule = await import(`data:text/javascript;base64,${Buffer.from(plain(read('services/NativePlatformBridge'))).toString('base64')}`);
const voiceModule = await import(`data:text/javascript;base64,${Buffer.from(plain(read('utils/VoiceInteraction'))).toString('base64')}`);
const createDriver = new Function('NativeBridgeError', 'VoiceInteractionError',
  plain(read('services/NativeBridgeVoiceDriver')).replace('export class NativeBridgeVoiceDriver', 'class NativeBridgeVoiceDriver') + '\nreturn NativeBridgeVoiceDriver;');
const Driver = createDriver(bridgeModule.NativeBridgeError, voiceModule.VoiceInteractionError);
const flush = async () => { for (let i = 0; i < 20; i++) await Promise.resolve(); };
const deferred = () => { let resolve, reject; const promise = new Promise((a,b) => { resolve=a;reject=b; }); return {promise,resolve,reject}; };
function fixture({ dispatch = null, registration = null } = {}) {
  const calls = [], commands = [], timers = new Map(); let receiver, sequence=0, now=0;
  const clock = { setTimeout(callback, delay) { const id=++sequence; timers.set(id,{callback,at:now+delay}); return id; }, clearTimeout(id){timers.delete(id);} };
  const transport = { async register(value){ calls.push('register'); receiver=value; if(registration) await registration; },
    async dispatch(text) { assert.ok(receiver); calls.push('dispatch'); const command=JSON.parse(text); commands.push(command); return dispatch ? dispatch(command, reply) : 'accepted'; } };
  const reply = (command, result={}, ok=true, code='') => receiver(JSON.stringify({v:1,kind:'reply',request_id:command.request_id,ok,code,result}));
  const instance = new bridgeModule.NativePlatformBridge(transport,clock);
  return { instance,calls,commands,timers,reply,
    event(event){receiver(JSON.stringify(event));}, raw(text){receiver(text);},
    async tick(ms){ now+=ms; for(const [id,timer] of [...timers]) if(timer.at<=now){timers.delete(id);timer.callback();} await flush();} };
}

test('callback registration precedes dispatch and a synchronous reply before ACK is retained exactly once', async () => {
  const f=fixture({dispatch(command,reply){reply(command,{recognition:true,synthesis:false});reply(command,{recognition:false});return 'accepted';}});
  assert.deepEqual(await f.instance.request('capabilities'),{recognition:true,synthesis:false});
  assert.deepEqual(f.calls,['register','dispatch']);
  assert.equal(f.commands[0].v,1); assert.match(f.commands[0].request_id,/^[A-Za-z0-9._-]{1,128}$/);
  await flush(); assert.equal(f.timers.size,0);
});
test('permission waiting does not block the immediate cancel command; result IDs remain independent', async () => {
  const f=fixture(); const starting=f.instance.request('recognition.start',{operation_id:'voice-a'}); await flush();
  const stopping=f.instance.request('recognition.cancel',{operation_id:'voice-a'}); await flush();
  assert.deepEqual(f.commands.map(c=>c.op),['recognition.start','recognition.cancel']);
  f.reply(f.commands[1]); await stopping;
  f.reply(f.commands[0],{},false,'OPERATION_CANCELLED');
  await assert.rejects(starting,error=>error.code==='OPERATION_CANCELLED');
});
test('normal/permission requests expire at 15/60 seconds and late replies cannot revive them', async () => {
  const f=fixture(); const short=f.instance.request('capabilities'), long=f.instance.request('recognition.start',{operation_id:'voice-a'});
  const shortRejected=assert.rejects(short,e=>e.code==='TIMEOUT'), longRejected=assert.rejects(long,e=>e.code==='TIMEOUT');
  await flush(); await f.tick(15000); await shortRejected;
  assert.equal(f.commands.length,2); await f.tick(44999); assert.equal(f.instance.pending.length,1);
  await f.tick(1); await longRejected;
  f.reply(f.commands[1],{recognition:true}); assert.equal(f.instance.pending.length,0);
});
test('hung dispatch ACK is bounded and cannot permanently block later cancellation', async () => {
  const hung=deferred(); const f=fixture({dispatch(c,reply){ if(c.op==='recognition.start')return hung.promise; reply(c);return'accepted'; }});
  const starting=f.instance.request('recognition.start',{operation_id:'a'}); const rejected=assert.rejects(starting);
  await flush(); await f.tick(14000);
  const cancel=f.instance.request('recognition.cancel',{operation_id:'a'}); await flush(); assert.equal(f.commands.length,1);
  await f.tick(1000); await rejected; await cancel; assert.equal(f.commands[1].op,'recognition.cancel');
  hung.resolve('accepted'); await flush(); assert.equal(f.instance.pending.length,0);
});
test('malformed commands are rejected before registering or dispatching, never partially scheduling', async () => {
  const f=fixture(); const future=Date.now()+3600000;
  for(const [op,args] of [['bogus',{}],['recognition.start',{}],['speech.start',{operation_id:'v',text:' '}],
    ['speech.start',{operation_id:'v',text:'x'.repeat(32001)}],['reminders.clear',{}],
    ['reminders.replace',{scope:'server|a',reminders:[{id:'x',fire_at_ms:future},{id:'x',fire_at_ms:future}]}],
    ['reminders.replace',{scope:'server|a',reminders:[{id:'x',fire_at_ms:Infinity}]}],
    ['reminders.replace',{scope:'server|a',reminders:Array.from({length:61},(_,i)=>({id:`x${i}`,fire_at_ms:future}))}]]) {
    await assert.rejects(f.instance.request(op,args),e=>e.code==='INVALID_REQUEST');
  }
  assert.deepEqual(f.calls,[]);
});
test('commands project only whitelisted scheduling fields and snapshot caller arrays', async () => {
  const f=fixture({dispatch(c,r){r(c);return'accepted';}}); const items=[{id:'task1',fire_at_ms:Date.now()+3600000,title:'private-title'}];
  const call=f.instance.request('reminders.replace',{scope:'server|a',reminders:items,token:'secret'});
  items[0].id='mutated'; await call;
  assert.equal(f.commands[0].reminders[0].id,'task1'); assert.equal('title' in f.commands[0].reminders[0],false); assert.equal('token'in f.commands[0],false);
});
test('untrusted replies/voice events are bounded and raw provider diagnostics never become error messages', async () => {
  const f=fixture(); const request=f.instance.request('capabilities'); await flush();
  f.raw('{bad json'); f.event({v:2,kind:'reply',request_id:f.commands[0].request_id,ok:true,code:''});
  assert.equal(f.instance.pending.length,1);
  f.reply(f.commands[0],{},false,'secret provider diagnostic');
  await assert.rejects(request,e=>e.code==='SYSTEM_ERROR'&&!e.message.includes('secret'));
  const received=[]; const unsub=f.instance.subscribeVoice(e=>received.push(e));
  f.event({v:1,kind:'voice',operation_id:'a',event:'recognition_result',text:'完整文字',raw:'private'});
  f.event({v:1,kind:'voice',operation_id:'a',event:'recognition_result',text:'x'.repeat(64001)});
  f.event({v:1,kind:'voice',operation_id:'a',event:'bogus'});
  assert.equal(received.length,1); assert.equal('raw'in received[0],false);
  unsub(); f.event({v:1,kind:'voice',operation_id:'a',event:'speech_complete'}); assert.equal(received.length,1);
});
test('cancel during permission wait invalidates late results and a new operation receives full accumulated text only', async () => {
  const f=fixture(); const driver=new Driver(f.instance), results=[];
  const events={onStart(){results.push('start');},onResult(t){results.push(t);},onComplete(){results.push('complete');},onError(t){results.push(t);}};
  const first=driver.startListening('r1',events); await flush(); const old=f.commands[0];
  driver.cancelListening('r1'); const second=driver.startListening('r2',events); await flush();
  assert.equal(f.commands[1].operation_id,old.operation_id); assert.notEqual(f.commands[2].operation_id,old.operation_id);
  f.event({v:1,kind:'voice',operation_id:old.operation_id,event:'recognition_result',text:'old'});
  const current=f.commands[2]; f.event({v:1,kind:'voice',operation_id:current.operation_id,event:'recognition_result',text:'新结果'});
  f.event({v:1,kind:'voice',operation_id:current.operation_id,event:'recognition_complete'});
  for(const c of f.commands)f.reply(c); await Promise.all([first,second]); assert.deepEqual(results,['新结果','complete']);
});
test('speech dispatch acceptance is not playback completion; stop carries the exact ID and drops late completion', async () => {
  const f=fixture({dispatch(c,r){r(c);return'accepted';}}), driver=new Driver(f.instance), observed=[];
  const events={onStart(){observed.push('start');},onComplete(){observed.push('done');},onError(t){observed.push(t);}};
  await driver.speak('s1','全文🙂',events); assert.deepEqual(observed,[]); const first=f.commands[0];
  f.event({v:1,kind:'voice',operation_id:first.operation_id,event:'speech_start'}); driver.stopSpeaking(); await flush();
  assert.equal(f.commands[1].operation_id,first.operation_id);
  f.event({v:1,kind:'voice',operation_id:first.operation_id,event:'speech_complete'}); assert.deepEqual(observed,['start']);
  await driver.speak('s2','下一条',events); f.event({v:1,kind:'voice',operation_id:f.commands.at(-1).operation_id,event:'speech_complete'});
  assert.deepEqual(observed,['start','done']);
});
test('voice disposal keeps the shared reminder channel alive and new drivers use distinct operation IDs', async () => {
  const f=fixture({dispatch(c,r){r(c,c.op==='capabilities'?{recognition:true,synthesis:true}:{});return'accepted';}});
  const a=new Driver(f.instance), b=new Driver(f.instance), calls=[];
  const events={onStart(){},onResult(){},onComplete(){calls.push('done');},onError(){}};
  assert.deepEqual(await a.probe(),{recognition:true,synthesis:true}); await a.startListening('r1',events); const old=f.commands.at(-1).operation_id;
  a.dispose(); await flush(); await b.startListening('r1',events); assert.notEqual(f.commands.at(-1).operation_id,old);
  f.event({v:1,kind:'voice',operation_id:old,event:'recognition_complete'}); assert.deepEqual(calls,[]);
  await f.instance.request('reminders.status'); assert.equal(f.commands.at(-1).op,'reminders.status');
  assert.equal(f.commands.filter(c=>c.op==='voice.dispose').length,0);
});
test('synchronous registration errors become safe unavailable results and malformed argument objects do not throw raw errors', async()=>{
 const clock={setTimeout:()=>1,clearTimeout(){}};
 const bridge=new bridgeModule.NativePlatformBridge({register(){throw Error('private path');},async dispatch(){throw Error('never');}},clock);
 await assert.rejects(bridge.request('capabilities'),e=>e.code==='UNAVAILABLE'&&!e.message.includes('private'));
 assert.equal(bridge.pending.length,0);
 for(const args of [null,[],{scope:'server|a',reminders:[undefined]}]){
  await assert.rejects(bridge.request('reminders.replace',args),e=>e.code==='INVALID_REQUEST');
 }
});
test('disposing an old unused facade cannot globally stop a newer facade sharing the same native plugin', async()=>{
 const f=fixture({dispatch(c,r){r(c);return'accepted';}}), old=new Driver(f.instance), current=new Driver(f.instance);
 const observed=[];await current.speak('s1','当前回答',{onStart(){},onComplete(){observed.push('complete');},onError(){}});
 const operation=f.commands.at(-1).operation_id;old.dispose();await flush();
 assert.deepEqual(f.commands.map(c=>c.op),['speech.start']);
 f.event({v:1,kind:'voice',operation_id:operation,event:'speech_complete'});assert.deepEqual(observed,['complete']);
});
