// Browser prototype checks only. Uses an existing Playwright + Chrome installation.
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { pathToFileURL } = require('node:url');
(async () => {
 if (!process.argv[2] || !process.argv[3]) throw new Error('Usage: node check-stage-9.cjs prototype.html output-directory');
 const out = path.resolve(process.argv[3]); fs.mkdirSync(out,{recursive:true});
 const browser = await chromium.launch({headless:true,executablePath:process.env.CHROME_EXECUTABLE});
 const page = await browser.newPage({viewport:{width:1440,height:1050},locale:'zh-CN',timezoneId:'Asia/Shanghai'});
 const errors=[], network=[], passed=[];
 page.on('pageerror',e=>errors.push(e.message));
 await page.route(/^https?:/,r=>{network.push(r.request().url());return r.abort();});
 await page.goto(pathToFileURL(path.resolve(process.argv[2])).href);
 const action=(a,v)=>page.locator('#after [data-act="'+a+'"]'+(v!==undefined?'[data-value="'+v+'"]':'')).first().click();
 const field=(name)=>page.locator('#after [data-field="'+name+'"]');
 const reset=()=>page.locator('[data-work="reset"]').click();
 const root=async name=>{await page.locator('[data-work="page"][data-value="'+name+'"]').click();};
 const state=fn=>page.evaluate(fn);
 const test=async(name,fn)=>{await reset();await fn();passed.push(name);};
 await test('同一示例数据与首页下一安排',async()=>{
   assert.equal(await state(()=>states.before.courses.length),await state(()=>states.after.courses.length));
   assert.match(await page.locator('#after .next-card').innerText(),/14:30[\s\S]*高等数学/);
   await page.screenshot({path:path.join(out,'01-today-comparison.png'),fullPage:true});
 });
 await test('独立草稿、主页面切换与建议不覆盖',async()=>{
   await root('agent');await field('prompt').fill('保留我的原始目标');
   await action('tab','plan');await action('plan-section','goals');
   await action('suggest');
   assert.match(await field('prompt').inputValue(),/保留我的原始目标/);
   assert.equal(await state(()=>states.before.prompt),'');
 });
 await test('计划三个视图与待办详情返回',async()=>{
   await root('plan');await action('plan-section','tasks');await action('task','lab');
   assert.equal(await page.locator('#after .nav').count(),0);
   assert.match(await page.locator('#after').innerText(),/完成操作系统实验/);
   await action('back');assert.equal(await state(()=>states.after.planView),'tasks');
   await action('plan-section','goals');await action('goal','goal1');
   assert.match(await page.locator('#after').innerText(),/阶段与任务/);await action('back');
   await action('plan-section','agenda');
   await page.screenshot({path:path.join(out,'03-plan-comparison.png'),fullPage:true});
 });
 await test('日历浏览不改变待办草稿，返回后输入保留',async()=>{
   await root('plan');await action('open','add-task');await field('task-title').fill('新的待办草稿');
   const date=await state(()=>states.after.taskDraft.date);await action('back');
   await action('calendar');await action('date','2026-10-22');await action('open','add-task');
   assert.equal(await field('task-title').inputValue(),'新的待办草稿');
   assert.equal(await state(()=>states.after.taskDraft.date),date);
 });
 await test('提案确认一次与关联计划直达',async()=>{
   await root('agent');await action('proposal-expand','p1');
   await page.screenshot({path:path.join(out,'02-agent-comparison.png'),fullPage:true});
   await action('proposal-confirm','p1');
   assert.equal(await state(()=>states.after.tasks.length),8);
   assert.equal(await page.locator('#after [data-act="proposal-confirm"][data-value="p1"]').count(),0);
   await action('goal','p1');assert.match(await page.locator('#after').innerText(),/阶段与任务/);
 });
 await test('语音识别可编辑并拼接草稿，未自动发出',async()=>{
   await root('agent');await field('prompt').fill('原始草稿');await action('voice-toggle');
   await action('voice-result');await action('voice-use');
   assert.match(await field('prompt').inputValue(),/原始草稿[\s\S]*帮我安排/);
   assert.equal(await state(()=>states.after.messages.length),2);
   await action('send');await page.waitForFunction(()=>states.after.messages.length===4);
   assert.equal(await state(()=>states.after.extraProposals.length),1);
 });
 await test('改期预览不写入，旧快照不能确认',async()=>{
   await root('plan');await action('open','conflicts');
   const before=await state(()=>JSON.stringify(states.after.tasks));
   await action('replan-preview');assert.equal(await state(()=>JSON.stringify(states.after.tasks)),before);
   await action('replan-stale');assert.equal(await page.locator('#after [data-act="replan-confirm"]').isDisabled(),true);
   assert.equal(await state(()=>JSON.stringify(states.after.tasks)),before);
 });
 await test('确认改期更新已有事项，未复制任务',async()=>{
   await root('plan');await action('open','conflicts');await action('replan-preview');await action('replan-confirm');
   assert.equal(await state(()=>states.after.tasks.length),5);
   assert.equal(await state(()=>conflictTasks(states.after).length),0);
 });
 await test('课表导入先预览，放弃不写数据',async()=>{
   await action('tab','campus');await action('open','timetable');await action('import-open');await action('import-read');
   assert.equal(await state(()=>states.after.courses.length),2);await action('import-cancel');
   assert.equal(await state(()=>states.after.courses.length),2);await action('import-read');await action('import-accept');
   assert.equal(await state(()=>states.after.courses.length),3);
 });
 await test('首次引导手动录课、核对、确认',async()=>{
   await page.locator('[data-work="onboarding"]').click();await action('walk-next');await action('walk-course');
   await field('course-title').fill('线性代数');await action('course-save');
   assert.equal(await state(()=>states.after.courses.length),2);await action('walk-next');
   assert.equal(await state(()=>states.after.courses.length),2);await action('walk-next');
   assert.equal(await state(()=>states.after.courses.length),1);assert.equal(await state(()=>states.after.tasks.length),5);
 });
 await test('离线可编辑草稿但不可发送',async()=>{
   await root('agent');await page.locator('#scenario').selectOption('offline');await field('prompt').fill('断网时的草稿');
   assert.equal(await page.locator('#after [data-act="send"]').isDisabled(),true);
   assert.equal(await state(()=>states.after.messages.length),2);
 });
 await test('窄屏、大字号与键盘占位无页面横向溢出',async()=>{
   await page.setViewportSize({width:375,height:812});await page.locator('[data-work="view"][data-value="new"]').click();
   await page.locator('#width-select').selectOption('320');await root('agent');
   await page.locator('[data-work="font"]').click();await page.locator('[data-work="keyboard"]').click();
   assert.equal(await state(()=>document.documentElement.scrollWidth<=innerWidth),true);
   assert.equal(await state(()=>document.querySelector('#after .app').scrollWidth<=document.querySelector('#after .app').clientWidth+1),true);
   await page.screenshot({path:path.join(out,'04-narrow-large-text-keyboard.png'),fullPage:true});
 });
 assert.deepEqual(errors,[]);assert.deepEqual(network,[]);
 fs.writeFileSync(path.join(out,'journeys.json'),JSON.stringify({passed,errors,network},null,2));
 console.log(JSON.stringify({passed:passed.length,checks:passed,errors,network},null,2));
 await browser.close();
})().catch(e=>{console.error(e);process.exit(1);});
