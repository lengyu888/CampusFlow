import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { createRequire, stripTypeScriptTypes } from 'node:module';
import { fileURLToPath } from 'node:url';
const require=createRequire(import.meta.url),directory=path.dirname(fileURLToPath(import.meta.url)),repo=path.resolve(directory,'../..'),file=path.join(directory,'ux08-task-recovery.html');
const sha=text=>crypto.createHash('sha256').update(text).digest('hex');
const source=name=>fs.readFileSync(path.join(repo,'arkui-x-client/entry/src/main/ets/utils',name+'.ets'),'utf8');
const names=['DraftStore','DailyAgenda','AgentFeedback','TaskStatusValidation','TaskStatusController'];
const sourceHashes=Object.fromEntries(names.map(name=>[name,sha(source(name))]));
const strip=name=>stripTypeScriptTypes(source(name).replace(/^import \{[\s\S]*?\} from '[^']+';\r?\n/gm,'').replace(/^import [^\n]+;\r?\n/gm,'')).replace(/^export /gm,'').replace(/[ \t]+$/gm,'');
const wrap=(global,name,inject,exports)=>`const ${global}=(()=>{\n${inject}\n${strip(name)}\nreturn {${exports}};\n})();`;
const validationExports='taskStatusUuid,validTaskStatusRequest,validTaskStatusOperation,sameTaskStatusCandidate,requiredTaskStatusAcknowledgements,validTaskStatusAcknowledgements,taskStatusCanConfirm';
const bundle='/* BEGIN PRODUCTION HELPERS */\n'+`const SourceHashes=${JSON.stringify(sourceHashes)};\n`+
 wrap('Store','DraftStore','','DraftStore')+'\n'+wrap('Agenda','DailyAgenda','','timestamp,courseTimestamp')+'\n'+
 wrap('Feedback','AgentFeedback','','CampusFlowRequestError')+'\n'+
 wrap('Validation','TaskStatusValidation','const {timestamp,courseTimestamp}=Agenda;',validationExports)+'\n'+
 wrap('Runtime','TaskStatusController',`const {${validationExports}}=Validation; const {CampusFlowRequestError}=Feedback;`,'TaskStatusController')+'\n/* END PRODUCTION HELPERS */';
const fixtureText=fs.readFileSync(path.join(repo,'arkui-x-client/scripts/fixtures/task-status-asgi-v1.json'),'utf8');
const fixture='/* BEGIN ASGI FIXTURE */\nconst Fixture='+JSON.stringify(JSON.parse(fixtureText)).replace(/</g,'\\u003c')+';\n/* END ASGI FIXTURE */';
const productionPattern=/\/\* BEGIN PRODUCTION HELPERS \*\/[\s\S]*?\/\* END PRODUCTION HELPERS \*\//,fixturePattern=/\/\* BEGIN ASGI FIXTURE \*\/[\s\S]*?\/\* END ASGI FIXTURE \*\//;
let html=fs.readFileSync(file,'utf8');
if(process.argv.includes('--refresh-helpers')){html=html.replace(productionPattern,()=>bundle).replace(fixturePattern,()=>fixture);fs.writeFileSync(file,html);console.log('Embedded actual production controller/store/validation and eight ASGI fixture responses.');if(!process.argv.includes('--check'))process.exit(0);}
assert.equal(html.match(productionPattern)?.[0],bundle,'Production helper drift: review then --refresh-helpers.');assert.equal(html.match(fixturePattern)?.[0],fixture,'ASGI fixture drift.');
for(const s of html.matchAll(/<script>([\s\S]*?)<\/script>/g))new Function(s[1]);
let chromium;try{({chromium}=require(process.env.PLAYWRIGHT_MODULE||'/Users/nihaoyunihaoyu/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright'))}catch{throw Error('Use an already installed Playwright; this script never installs dependencies.');}
const out=path.resolve(process.env.PREVIEW_OUTPUT||path.join(repo,'../ux08-browser-review'));fs.mkdirSync(out,{recursive:true});
const browser=await chromium.launch({executablePath:process.env.CHROME_EXECUTABLE||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true});
const page=await browser.newPage({viewport:{width:1280,height:1060},reducedMotion:'reduce'}),errors=[],requests=[],checks=[],screenshots=[];
page.on('pageerror',e=>errors.push(e.message));page.on('request',r=>{if(/^https?:/i.test(r.url()))requests.push(r.url())});
const check=async(name,fn)=>{await fn();checks.push(name)};
const state=()=>page.evaluate(()=>__ux08.getState());
const waitPhase=phase=>page.waitForFunction(p=>__ux08.getState().status.items.some(i=>i.phase===p),phase);
const choose=async mode=>{await page.selectOption('#scenario',mode);await page.waitForFunction(m=>__ux08.getState().mode===m&&__ux08.getState().status.items.length===0,mode);};
const start=async phase=>{await page.click('#task-status');await waitPhase(phase)};
const capture=async name=>{
 await page.waitForFunction(()=>!__ux08.getState().status.items.some(i=>i.busy));
 await page.evaluate(async()=>{await document.fonts.ready;window.scrollTo(0,0);await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))});
 await page.waitForTimeout(180);
 await page.screenshot({path:path.join(out,name),fullPage:true,animations:'disabled'});screenshots.push(name);
};
try{
 await page.goto('file://'+file);await page.waitForFunction(()=>window.__ux08?.ready);
 await check('Eight actual ASGI/SQLite synthetic projections pass the unmodified production validator',async()=>{const s=await state();assert.equal(s.fixtureChecks.length,8);assert(s.fixtureChecks.every(c=>c.valid));assert.match(await page.locator('.intro').innerText(),/不是 ArkUI 原生截图/)});
 await capture('01-wide-web-prototype.png');
 await check('Completion waits for a verified receipt, then refreshes once and clears its durable pointer',async()=>{await page.click('#task-status');assert.equal((await state()).task.status,'pending');await waitPhase('applied');const s=await state();assert.equal(s.task.status,'completed');assert.equal(s.refreshes,1);assert.equal(s.status.pendingCount,0);assert.equal(s.calls.filter(c=>c.method==='POST').length,1);assert(await page.locator('#receipt').isVisible())});
 await page.setViewportSize({width:390,height:900});await capture('02-390-complete-receipt.png');
 await check('Closing and switching Today/Plan retain one coordinator and the original receipt without extra writes',async()=>{await page.click('#back');await page.click('[data-tab="plan"]');assert.equal((await state()).tab,'plan');await page.click('#open-records');assert.equal((await state()).calls.filter(c=>c.method==='POST').length,1);assert(await page.locator('#receipt').isVisible())});
 await choose('unknown');
 await check('An ambiguous completion cannot show confirm/cancel/retry before original-ID GET',async()=>{await start('unknown');const s=await state();assert.equal(s.task.status,'pending');assert.equal(s.status.pendingCount,1);assert.equal(await page.locator('#confirm').count(),0);assert.equal(await page.locator('#cancel').count(),0);assert.equal(await page.locator('#retry').count(),0);assert.equal(s.calls.filter(c=>c.method==='POST').length,1)});
 await page.setViewportSize({width:430,height:920});await capture('03-430-unknown-result.png');
 await check('Read-only original-ID recovery obtains the receipt without retransmitting the write',async()=>{const before=(await state()).calls[0].id;await page.click('#check-result');await waitPhase('applied');const s=await state();assert.equal(s.calls.filter(c=>c.method==='POST').length,1);assert.equal(s.calls.filter(c=>c.method==='GET').length,1);assert.equal(s.calls.at(-1).id,before);assert.equal(s.task.status,'completed')});
 await choose('retry');
 await check('Definite original-ID 404 enables only an explicit replay with exactly the frozen body',async()=>{await start('unknown');await page.click('#check-result');await waitPhase('retryable');const before=(await state()).calls.find(c=>c.method==='POST');assert(await page.locator('#retry').isVisible());await page.click('#retry');await waitPhase('applied');const posts=(await state()).calls.filter(c=>c.method==='POST');assert.equal(posts.length,2);assert.deepEqual(posts[1],before)});
 await choose('unknown');
 await check('Reconstructed controller/store reads its retained original ID after a simulated restart; no automatic POST',async()=>{await start('unknown');await page.click('#restart');await waitPhase('applied');const s=await state();assert.equal(s.calls.filter(c=>c.method==='POST').length,1);assert.equal(s.calls.filter(c=>c.method==='GET').length,1);assert.match(await page.locator('#content').innerText(),/只查询原操作编号/)});
 await choose('restore');
 await check('Restore first reads the original completion receipt, then presents a preview without changing the task',async()=>{await start('review');const s=await state();assert.deepEqual(s.calls.map(c=>c.method),['GET','POST']);assert.equal(s.task.status,'completed');assert.equal(s.refreshes,0);assert.match(await page.locator('#restore-preview').innerText(),/未提供完整起止时间/)});
 await check('Confirming a valid non-overlap restore changes only status and preserves current task fields',async()=>{const before=(await state()).task;await page.click('#confirm');await waitPhase('applied');const after=(await state()).task;assert.equal(after.status,'pending');for(const key of ['title','start_at','end_at','location'])assert.equal(after[key],before[key]);assert.match(await page.locator('#receipt').innerText(),/不会删除专注记录/);assert.match(await page.locator('#restore-preview').innerText(),/不是当前任务快照/)});
 await capture('09-restored-historical-preview.png');
 await choose('course');await page.setViewportSize({width:320,height:900});await page.click('#large');
 await check('Course-overlap restore shows full course/task dates and requires a new independent ACK',async()=>{await start('review');assert(await page.locator('#confirm').isDisabled());const text=await page.locator('#restore-preview').innerText();assert.match(text,/2030-10-19/);assert.match(text,/09:00–11:00/);assert.match(text,/09:30.*10:00/s);assert.match(text,/原来的课内许可不代替本次确认/);assert.equal((await state()).calls.some(c=>c.method==='CONFIRM'),false)});
 await check('320px large type keeps complete facts and every active control at least 48px without horizontal overflow',async()=>{assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));const small=await page.locator('button:visible:not([disabled])').evaluateAll(ns=>ns.filter(n=>n.getBoundingClientRect().height<47.9).map(n=>n.textContent));assert.deepEqual(small,[])});
 await capture('04-320-large-course-ack.png');
 await check('Explicit ACK is bound to the precise candidate and digest before confirmation produces an actual fixture receipt',async()=>{await page.check('#ack');assert(await page.locator('#confirm').isEnabled());const operation=(await state()).status.items[0].operation;await page.click('#confirm');await waitPhase('applied');const call=(await state()).calls.find(c=>c.method==='CONFIRM');assert.deepEqual(call.payload,[{candidate_id:operation.preview.candidate_id,review_digest:operation.preview.course_review.review_digest}]);assert.equal((await state()).task.status,'pending')});
 await choose('cancel');
 await check('Explicit cancellation resolves only the restore preview and leaves the task completed',async()=>{await start('review');await page.click('#cancel');await waitPhase('cancelled');const s=await state();assert.equal(s.task.status,'completed');assert.equal(s.refreshes,0);assert.equal(s.calls.at(-1).method,'CANCEL');assert.equal(s.status.pendingCount,0);assert.equal(await page.locator('#receipt').count(),0);assert.match(await page.locator('#restore-preview').innerText(),/已取消.*未执行/s)});
 await capture('05-320-large-cancelled.png');
 await choose('later');await page.setViewportSize({width:390,height:920});
 await check('A historical receipt cannot overwrite a later title/time/location update',async()=>{await start('applied');await page.click('#open-current');const s=await state();assert.match(s.task.title,/后来修改/);assert.equal(s.task.start_at,'2030-10-20T14:00:00+08:00');assert.equal(s.task.location,'图书馆二楼');await page.click('#open-records');assert.match(await page.locator('#receipt').innerText(),/历史回执/);await page.click('#open-current');assert.equal((await state()).task.title,s.task.title);assert.match(await page.locator('#current-task').innerText(),/2030-10-20/)});
 await capture('06-390-later-current-task.png');
 await choose('legacy');
 await check('Legacy completion without a source receipt is explained, not forged or sent as a write',async()=>{await page.click('#task-status');await page.waitForFunction(()=>__ux08.getState().status.message.length>0);assert.equal((await state()).calls.length,0);assert.match(await page.locator('#global-message').innerText(),/未保留可核验凭据/);assert.equal(await page.locator('#confirm').count(),0)});
 await capture('07-390-legacy-no-receipt.png');
 await choose('course');await page.setViewportSize({width:430,height:920});await page.click('#dark');await start('review');
 await check('Dark preview and reduced-motion media retain readable recovery controls without horizontal overflow',async()=>{assert(await page.evaluate(()=>matchMedia('(prefers-reduced-motion: reduce)').matches));assert(await page.locator('body').evaluate(n=>n.classList.contains('dark')));assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));assert(await page.locator('#ack').isVisible())});
 await capture('08-430-dark-reduced-motion.png');
 await check('Offline prototype emits no HTTP requests or browser runtime errors',async()=>{assert.deepEqual(requests,[]);assert.deepEqual(errors,[])});
 fs.writeFileSync(path.join(out,'checks.json'),JSON.stringify({checks:checks.length,passed:checks,errors,httpRequests:requests,sourceHashes,fixtureSHA256:sha(fixtureText),fixtureCount:8,syntheticData:true,actualProductionController:true,nativeValidation:false,browserApproximation:true,memoryDriverOnly:true,screenshots},null,2)+'\n');console.log(JSON.stringify({checks:checks.length,out,errors,httpRequests:requests}));
}finally{await browser.close()}
