'use strict';
// Offline browser approximation only. Uses existing Node 24 / Playwright / Chrome; installs nothing.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { stripTypeScriptTypes } = require('node:module');
const repo = path.resolve(__dirname, '../..');
const htmlPath = path.join(__dirname, 'ux-06-planning.html');
const names = {
  DailyAgenda: ['buildDailyAgenda','shanghaiDate','shanghaiTime','validDate','timestamp','courseTimestamp','allDayDate'],
  PlanningOverview: ['filterPlanningTasks','buildPlanningWeek','resolvePlanningCourse','validPlanningTimetable','dailyPlannedLoad','projectPlanningCandidate']
};
const source = name => fs.readFileSync(path.join(repo, 'arkui-x-client/entry/src/main/ets/utils', name+'.ets'), 'utf8');
const hash = text => crypto.createHash('sha256').update(text).digest('hex');
const sourceHashes = Object.fromEntries(Object.keys(names).map(name => [name, hash(source(name))]));
const strip = name => stripTypeScriptTypes(source(name).replace(/^import [^\n]+;\r?\n/gm, '')).replace(/^export /gm, '').replace(/[ \t]+$/gm, '');
const generated = `/* BEGIN PRODUCTION HELPERS */\n/* Generated from the actual pure helpers. Do not edit this block by hand.\n * DailyAgenda SHA256 ${sourceHashes.DailyAgenda}\n * PlanningOverview SHA256 ${sourceHashes.PlanningOverview}\n * No UI / network / native capability is included. */\nconst Daily = (() => {\n${strip('DailyAgenda')}\nreturn {${names.DailyAgenda.join(',')}};\n})();\nconst Overview = (() => {\nconst {buildDailyAgenda,shanghaiDate,validDate,timestamp,courseTimestamp,allDayDate} = Daily;\n${strip('PlanningOverview')}\nreturn {${names.PlanningOverview.join(',')}};\n})();\n/* END PRODUCTION HELPERS */`;
let html = fs.readFileSync(htmlPath, 'utf8');
const pattern = /\/\* BEGIN PRODUCTION HELPERS \*\/[\s\S]*?\/\* END PRODUCTION HELPERS \*\//;
assert(pattern.test(html), 'Production helper marker is missing');
if (process.argv.includes('--refresh-helpers')) {
  html = html.replace(pattern, () => generated);
  fs.writeFileSync(htmlPath, html);
  console.log('Updated the offline helper bundle from the current production sources.');
  if (!process.argv.includes('--check')) process.exit(0);
}
assert.equal(html.match(pattern)[0], generated, 'Offline helpers have drifted. Review and run --refresh-helpers.');
for (const script of html.matchAll(/<script>([\s\S]*?)<\/script>/g)) new Function(script[1]);
const moduleName = process.env.PLAYWRIGHT_MODULE || 'playwright';
let chromium;
try { ({chromium} = require(moduleName)); }
catch { throw new Error('Playwright is not available at PLAYWRIGHT_MODULE (or Node resolution). Use the already-installed module; this script does not install dependencies.'); }
(async () => {
  const out = path.resolve(process.env.PREVIEW_OUTPUT || path.join(repo, '../ux06-visual'));
  fs.mkdirSync(out, { recursive:true });
  const browser = await chromium.launch({ executablePath:process.env.CHROME_EXECUTABLE || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless:true });
  const page = await browser.newPage({ viewport:{ width:1280, height:1100 }, reducedMotion:'reduce' });
  const errors=[], externalRequests=[], checks=[];
  page.on('pageerror', e => errors.push(e.message));
  page.on('request', req => { if (/^https?:/i.test(req.url())) externalRequests.push(req.url()); });
  const check = async (name,fn) => { await fn(); checks.push(name); };
  const url = 'file://' + htmlPath;
  const app = () => page.evaluate(() => ({ state:__ux06.getState(), tasks:__ux06.getTasks() }));
  const close = () => page.click('#close-dialog');
  try {
    await page.goto(url);
    await check('Offline production helper bundle matches both current sources and all inline scripts parse', async () => assert(await page.locator('#week-days').isVisible()));
    await check('Prototype and synthetic / nonnative boundary are visible', async () => assert.match(await page.locator('.intro').innerText(), /合成示例.*不连接账户.*浏览器画面不代表 ArkUI 原生/s));
    await check('Natural week contains all seven Monday–Sunday dates, not seven navigation buttons only', async () => assert.deepEqual(await page.locator('.day-block').evaluateAll(nodes=>nodes.map(n=>n.dataset.date)), ['2026-10-19','2026-10-20','2026-10-21','2026-10-22','2026-10-23','2026-10-24','2026-10-25']));
    await check('Union load is 240, not 190 + 125 = 315 minutes; incomplete / all-day / undated remain separate', async () => {
      const load=page.locator('.load').first(); assert.equal(await load.getAttribute('data-total'),'240'); assert.equal(await load.getAttribute('data-task-minutes'),'125'); assert.match(await load.innerText(),/课程 190 分钟/); assert.match(await load.innerText(),/1 项全天 · 1 项结束未定 · 1 项无日期/);
    });
    await check('Enabled goal compares only task minutes and may be switched off', async () => { assert.match(await page.locator('.goal-note').innerText(), /当前任务 125 分钟.*多出 5 分钟/); await page.uncheck('#goal'); assert.equal(await page.locator('.goal-note').count(),0); await page.check('#goal'); });
    await check('Missing end remains explicitly unknown, while cross-day task appears on both intersecting dates', async () => {
      assert.match(await page.locator('[data-date="2026-10-19"]').innerText(), /16:00\s*未定/);
      for(const date of ['2026-10-24','2026-10-25']) assert.match(await page.locator(`[data-date="${date}"]`).innerText(), /整理参考资料（跨日示例）/);
      assert.match(await page.locator('[data-date="2026-10-25"]').innerText(), /00:00\s*00:20/);
    });
    await check('Current selected date may change without hiding the other six day lists', async () => { await page.click('[data-select-date="2026-10-20"]'); assert.equal(await page.locator('#selected-date').innerText(),'2026-10-20'); assert.equal(await page.locator('.day-block').count(),7); });
    await check('Date-to-assistant includes the full selected date and never sends', async () => {
      await page.click('#date-to-assistant'); assert.match(await page.inputValue('#assistant-draft'),/2026-10-20/); await page.fill('#assistant-draft','先保留我自己写的草稿'); await page.click('#save-draft'); await page.click('[data-select-date="2026-10-21"]'); await page.click('#date-to-assistant'); assert.equal(await page.inputValue('#assistant-draft'),'先保留我自己写的草稿'); assert.match(await page.locator('#detail-content').innerText(),/新建议.*2026-10-21/s); await page.click('#append-date'); assert.match(await page.inputValue('#assistant-draft'),/^先保留我自己写的草稿\n.*2026-10-21/); await page.click('#save-draft');
    });
    await check('Capture draft date survives browsing to another selected day', async () => {
      await page.click('#new-task'); await page.fill('#capture-title','尚未提交的输入'); await page.fill('#capture-date','2026-10-23'); await page.click('#keep-capture'); await page.click('[data-select-date="2026-10-22"]'); await page.click('#new-task'); assert.equal(await page.inputValue('#capture-date'),'2026-10-23'); assert.equal(await page.inputValue('#capture-title'),'尚未提交的输入'); await close();
    });
    await check('Week navigation projects the actual next natural week and supports explicit return', async () => { await page.click('#next-week'); assert.equal(await page.locator('.day-block').first().getAttribute('data-date'),'2026-10-26'); assert.equal(await page.locator('.day-block').last().getAttribute('data-date'),'2026-11-01'); await page.click('#this-week'); });
    await check('Selected-day view can return to the complete week', async () => { await page.click('[data-view="day"]'); assert.equal(await page.locator('.day-block').count(),1); await page.click('[data-view="week"]'); assert.equal(await page.locator('.day-block').count(),7); });
    // A clean reload removes transient operation toasts from the reference screenshot.
    await page.reload();
    await page.screenshot({ path:path.join(out,'wide.png'), fullPage:true });
    await check('All 100 stable task IDs are reachable across five pages without truncation', async () => {
      await page.click('[data-tab="tasks"]'); assert.equal(await page.locator('#result-count').innerText(),'100 / 100 项'); const ids=[];
      for(let i=0;i<5;i++){ ids.push(...await page.locator('#task-results [data-task-id]').evaluateAll(ns=>ns.map(n=>n.dataset.taskId))); if(i<4)await page.click('#next-page'); }
      assert.equal(ids.length,100);assert.equal(new Set(ids).size,100);assert.equal(await page.locator('#next-page').isDisabled(),true);
    });
    await check('Title / place, status and range filtering combine with AND and match actual helper output', async () => {
      await page.fill('#search','图书馆');await page.selectOption('#filter-status','pending');await page.selectOption('#filter-date','range');await page.fill('#filter-from','2026-10-19');await page.fill('#filter-to','2026-10-25');
      const expected=await page.evaluate(()=>__ux06.overview.filterPlanningTasks(__ux06.getTasks(),__ux06.getState().query).tasks.map(t=>t.task_id));
      const actual=await page.locator('#task-results [data-task-id]').evaluateAll(ns=>ns.map(n=>n.dataset.taskId)); assert.deepEqual(actual,expected);assert.deepEqual(actual,['demo-001','demo-006','demo-011','demo-008','demo-009','demo-010']);
    });
    await check('No-result filters offer a clear recovery without claiming data are empty', async () => { await page.fill('#search','并不存在的检索词');assert.match(await page.locator('.no-results').innerText(),/没有符合条件的事项/);assert.equal(await page.locator('#result-count').innerText(),'0 / 100 项');await page.click('[data-clear-filters]');assert.equal(await page.locator('#result-count').innerText(),'100 / 100 项'); });
    await check('Task details return to the same search and page, with full text and exact identity', async () => { await page.fill('#search','英语阅读'); const before=await app(); const id=await page.locator('#task-results [data-task]').first().getAttribute('data-task'); await page.locator('#task-results [data-task]').first().click();assert.match(await page.locator('#detail-content').innerText(),new RegExp(id));await close(); assert.equal(await page.inputValue('#search'),'英语阅读');assert.equal((await app()).state.page,before.state.page); });
    await check('Completion is its own touch target and does not open task details', async () => {
      await page.click('#clear-filters');const before=(await app()).tasks.find(t=>t.task_id==='demo-004').status;await page.click('#task-results [data-complete="demo-004"]');assert.equal(await page.locator('#detail').isVisible(),false);assert.notEqual((await app()).tasks.find(t=>t.task_id==='demo-004').status,before);
    });
    await check('Creation-time sorting and undated filtering remain functional', async () => { await page.selectOption('#filter-sort','created');const expected=await page.evaluate(()=>__ux06.overview.filterPlanningTasks(__ux06.getTasks(),__ux06.getState().query).tasks[0].task_id);assert.equal(await page.locator('#task-results [data-task]').first().getAttribute('data-task'),expected);await page.selectOption('#filter-date','undated');assert.equal(await page.locator('#result-count').innerText(),'1 / 100 项');assert.equal(await page.locator('#task-results [data-task]').getAttribute('data-task'),'demo-007'); });
    await check('Editing projects an exact task replacement without mutating or saving before confirmation', async () => {
      await page.click('#clear-filters');await page.click('#task-results [data-task="demo-001"]');await page.click('#edit-task');const before=await app();await page.fill('#edit-start','2026-10-19T10:10');await page.fill('#edit-end','2026-10-19T11:10');await page.click('#preview-edit');assert.match(await page.locator('#detail-content').innerText(),/未执行服务端冲突检查/);assert.equal(await page.locator('#detail-content .load').count(),2);assert.deepEqual((await app()).tasks,before.tasks);await close();
    });
    await check('Goal plan retains all milestones and opens exact linked tasks', async () => { await page.click('[data-tab="plans"]');await page.locator('.plan-sheet summary').click();assert.equal(await page.locator('.plan-sheet li').count(),3);await page.click('.plan-sheet [data-task="demo-009"]');assert.match(await page.locator('#detail-content').innerText(),/demo-009/);await close(); });
    await check('Ordinary conflict preview cancels without writes and accepted in-class task is preserved', async () => { const before=await app();await page.click('[data-open-conflict]');assert.match(await page.locator('#detail-content').innerText(),/重叠 55 分钟/);await page.click('#cancel-demo');assert.deepEqual((await app()).tasks,before.tasks); });
    await check('Explicit demo confirmation updates only the target ID and shows a clearly local receipt', async () => { const old=(await app()).tasks.find(t=>t.task_id==='demo-002');await page.click('[data-open-conflict]');await page.click('#apply-demo-replan');assert.match(await page.locator('#detail-content').innerText(),/没有提交到服务器/);const now=await app();assert.equal(now.tasks.length,100);assert.equal(now.tasks.find(t=>t.task_id==='demo-001').start_at,'2026-10-19T10:10:00+08:00');assert.deepEqual(now.tasks.find(t=>t.task_id==='demo-002'),old);await close(); });
    await check('Needs-review flow requires explicit checkbox and preserves its original time', async () => { const before=(await app()).tasks.find(t=>t.task_id==='demo-003');await page.click('[data-review]');assert(await page.locator('#confirm-review').isDisabled());await page.check('#review-ack');assert(await page.locator('#confirm-review').isEnabled());await page.click('#confirm-review');assert.deepEqual((await app()).tasks.find(t=>t.task_id==='demo-003'),before);assert.match(await page.locator('#detail-content').innerText(),/未改期/);await close(); });
    await check('Course reference uses the full facts and revision, and refuses rebinding after a version change', async () => { await page.click('[data-tab="schedule"]');await page.locator('[data-course]').first().click();assert.match(await page.locator('#detail-content').innerText(),/操作系统/);assert.match(await page.locator('#detail-content').innerText(),/陈老师/);await page.click('#change-course-version');assert.match(await page.locator('#detail-content').innerText(),/旧课程引用已失效/);await close(); });
    await check('Course failure is independent: keeps task rows and does not label unknown data as an empty timetable', async () => { await page.selectOption('#course-source','missing');assert.match(await page.locator('[data-source-notice="courseSource"]').innerText(),/不表示没有课程/);assert.equal(await page.locator('[data-course]').count(),0);assert(await page.locator('[data-date="2026-10-19"] [data-task]').count()>0);assert.match(await page.locator('.load').first().innerText(),/来源不完整/);assert(await page.locator('[data-open-conflict]').isDisabled()); });
    await check('Task failure is independent: restores course rows and offers explicit local retry', async () => { await page.selectOption('#course-source','fresh');await page.selectOption('#task-source','missing');assert.equal(await page.locator('#week-days [data-task]').count(),0);assert(await page.locator('[data-course]').count()>0);assert.match(await page.locator('[data-source-notice="taskSource"]').innerText(),/不表示没有任务/);await page.click('[data-retry-source="taskSource"]');assert(await page.locator('#week-days [data-task]').count()>0); });
    await check('Stale snapshot is visibly labeled and mutation previews stay disabled until refreshed', async () => { await page.selectOption('#course-source','stale');assert.match(await page.locator('[data-source-notice="courseSource"]').innerText(),/保留旧快照/);assert(await page.locator('[data-course]').count()>0);assert(await page.locator('[data-review]').isDisabled());await page.selectOption('#course-source','fresh'); });
    await page.reload();
    await page.setViewportSize({width:360,height:900});await page.click('#large');
    await check('360-pixel large-text natural week has no horizontal overflow and all seven dates remain', async () => { assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);assert.equal(await page.locator('.day-block').count(),7);assert.equal(await page.locator('[data-date="2026-10-19"] [data-task="demo-006"]').evaluate(el=>el.scrollWidth<=el.clientWidth),true); });
    await check('Visible active touch buttons have at least 48px height and completion targets are 48×48', async () => { const invalid=await page.locator('button:visible:not([disabled])').evaluateAll(ns=>ns.filter(n=>n.getBoundingClientRect().height<47.9).map(n=>({text:n.textContent,height:n.getBoundingClientRect().height})));assert.deepEqual(invalid,[]);const complete=await page.locator('.complete').first().boundingBox();assert(complete.width>=48&&complete.height>=48); });
    await page.screenshot({path:path.join(out,'narrow-large.png'),fullPage:true});
    await page.click('[data-tab="tasks"]');await page.fill('#search','没有这种课程');
    await check('Large-text no-results layout stays within the viewport and remains recoverable', async () => { assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);assert(await page.locator('[data-clear-filters]').isVisible()); });
    await page.screenshot({path:path.join(out,'narrow-search-empty.png'),fullPage:true});
    await page.click('[data-clear-filters]');await page.click('#task-results [data-task="demo-006"]');
    await check('Large-text long-title detail dialog stays within the viewport with reachable close', async () => { const b=await page.locator('#detail').boundingBox();assert(b.x>=0&&b.x+b.width<=360);assert(await page.locator('#close-dialog').isVisible());assert.equal(await page.locator('#detail').evaluate(n=>n.scrollWidth<=n.clientWidth),true); });
    await page.screenshot({path:path.join(out,'narrow-detail.png'),fullPage:true});await close();
    await page.setViewportSize({width:760,height:420});
    await check('Landscape and reduced-motion presentation do not introduce horizontal overflow', async () => { assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);assert(await page.evaluate(()=>matchMedia('(prefers-reduced-motion: reduce)').matches)); });
    await check('No page errors and no HTTP requests for the entire interaction run', async () => { assert.deepEqual(errors,[]);assert.deepEqual(externalRequests,[]); });
    fs.writeFileSync(path.join(out,'checks.json'),JSON.stringify({checks:checks.length,passed:checks,errors,externalRequests,sourceHashes,nativeValidation:false,browserApproximation:true,syntheticData:true,screenshots:['wide.png','narrow-large.png','narrow-search-empty.png','narrow-detail.png']},null,2)+'\n');
    console.log(JSON.stringify({checks:checks.length,errors,externalRequests,out}));
  } finally { await browser.close(); }
})().catch(error=>{console.error(error);process.exitCode=1;});
