// Self-contained UX01 browser prototype only; no ArkUI/native or live API claims.
// Reuses installed Playwright/Chrome. Never installs a browser or dependency.
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { pathToFileURL } = require('node:url');

(async () => {
  const file = path.resolve(process.argv[2] || path.join(__dirname, 'ux-01-xingjian.html'));
  const out = process.argv[3] ? path.resolve(process.argv[3]) : null;
  if (out) fs.mkdirSync(out, { recursive: true });
  const browser = await chromium.launch({ headless: true, executablePath: process.env.CHROME_EXECUTABLE });
  const page = await browser.newPage({ viewport: { width: 1440, height: 1080 }, locale: 'zh-CN', timezoneId: 'Asia/Shanghai' });
  const errors = [], network = [], passed = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.route(/^https?:/, route => { network.push(route.request().url()); return route.abort(); });
  const goto = () => page.goto(pathToFileURL(file).href);
  const work = (name, value) => page.locator(`[data-work="${name}"]${value ? `[data-value="${value}"]` : ''}`).click();
  const app = (dir = 'paper') => page.locator(`[data-app="${dir}"]`);
  const action = (name, value, dir = 'paper') => app(dir).locator(`[data-act="${name}"]${value !== undefined ? `[data-value="${value}"]` : ''}`).first().click();
  const field = (name, dir = 'paper') => app(dir).locator(`[data-field="${name}"]`);
  const state = async (dir = 'paper') => page.evaluate(dir => window.prototypeState().states[dir], dir);
  const shot = async name => { if (out) await page.screenshot({ path: path.join(out, name + '.png'), fullPage: true, animations: 'disabled' }); };
  const test = async (name, fn) => {
    await page.setViewportSize({ width: 1440, height: 1080 });
    await goto();
    await fn();
    passed.push(name);
  };
  try {
    await test('三方向同一份8条日程，骨架不同且明确原型边界', async () => {
      assert.match(await page.locator('.lab-note').innerText(), /合成数据.*非原生截图/);
      const source = await page.evaluate(() => window.prototypeState().states);
      assert.deepEqual(source.paper.events, source.handbook.events);
      assert.deepEqual(source.paper.events, source.checklist.events);
      assert.equal(await app().locator('[data-event]').count(), 6);
      for (const dir of ['handbook', 'checklist']) assert.equal(await app(dir).locator('[data-event]').count(), 10);
      assert.equal(await app().locator('.timeline').count(), 1);
      assert.equal(await app('handbook').locator('.chapter-heading').count(), 3);
      assert.equal(await app('checklist').locator('.timeline').count(), 0);
      assert.match(await app().locator('.next').innerText(), /14:30[\s\S]*高等数学/);
      await shot('01-three-directions-390');
      await action('earlier');
      assert.equal(await app().locator('[data-event]').count(), 10);
      assert.equal(await app().locator('[data-event="c-software"] .row-title').textContent(), '软件工程：需求分析与面向对象系统设计专题');
      await app().locator('[data-event="c-software"]').scrollIntoViewIfNeeded();
      await shot('01b-earlier-long-title');
    });
    await test('早些时候仅折叠已结束课程或已完成任务，未完成旧任务仍显著', async () => {
      assert.equal(await app().locator('[data-event="t-reading"]').count(), 0);
      await action('earlier');
      await action('toggle', 't-reading');
      assert.match(await app().locator('.pending-heading').innerText(), /待处理 · 1 项/);
      await action('earlier');
      assert.equal(await app().locator('[data-event="t-reading"]').count(), 1);
      assert.equal(await app().locator('[data-event="c-os"]').count(), 0);
      assert.match(await app().locator('[data-act="earlier"]').innerText(), /早些时候 · 3 项/);
    });
    await test('过去开始但未设置结束的待办不会被折叠或认定结束', async () => {
      await action('add');
      await field('task-title').fill('尚未确定结束的实验');
      await field('task-time').fill('09:00');
      await app().locator('[type="submit"]').click();
      await action('close-sheet');
      assert.match(await app().locator('.pending-heading').innerText(), /待处理 · 1 项/);
      assert.equal(await app().locator('[data-event="added-1"]').count(), 1);
      assert.match(await app().locator('[data-event="added-1"]').innerText(), /未设结束/);
      assert.equal(await app().locator('.earlier-list').count(), 0);
    });
    await test('完成控件与详情分离，三方向状态独立', async () => {
      await action('toggle', 't-lab');
      assert.equal((await state()).events.find(x => x.id === 't-lab').done, true);
      assert.equal((await state('handbook')).events.find(x => x.id === 't-lab').done, undefined);
      assert.equal(await app().locator('[role="dialog"]').count(), 0);
      await action('detail', 't-lab');
      assert.match(await app().locator('.sheet').innerText(), /完成操作系统实验，整理进程同步结果/);
      await action('close-sheet');
      assert.equal((await state()).events.length, 8);
    });
    await test('课程地点带入目的地，起点不伪装为定位', async () => {
      await action('route', 'c-math');
      assert.match(await app().locator('.sheet').innerText(), /第3教学楼215/);
      assert.equal(await field('origin').inputValue(), '请选择起点');
      assert.equal(await field('origin').locator('option').count(), 3);
    });
    await test('快速记事验证与取消保留草稿，日期浏览不改草稿', async () => {
      await action('add');
      await app().locator('[type="submit"]').click();
      assert.match(await app().locator('.field-error').innerText(), /请写下/);
      await field('task-title').fill('暂时没想好时间的作业');
      await action('close-sheet');
      await action('tab', 'plan');
      await action('date', '2026-10-22');
      await action('add');
      assert.equal(await field('task-title').inputValue(), '暂时没想好时间的作业');
      assert.equal(await field('task-date').inputValue(), '2026-10-19');
    });
    await test('无日期保存回执语义正确，重复提交不增加第二项', async () => {
      await action('add');
      await field('task-title').fill('查找补充材料');
      await field('task-date').fill('');
      await app().locator('[type="submit"]').click();
      assert.match(await app().locator('.sheet').innerText(), /已留在待安排，没有指定日期或时刻/);
      assert.equal((await state()).untimed.filter(x => x.title === '查找补充材料').length, 1);
      assert.equal((await state()).receipts.length, 1);
      assert.equal(await app().locator('[type="submit"]').count(), 0);
    });
    await test('有时刻无日期拒绝，不擅自补今天', async () => {
      await action('add');
      await field('task-title').fill('准备汇报');
      await field('task-date').fill('');
      await field('task-time').fill('20:00');
      await app().locator('[type="submit"]').click();
      assert.match(await app().locator('.field-error').innerText(), /请补一个日期/);
      assert.equal((await state()).events.length, 8);
      assert.equal(await field('task-title').inputValue(), '准备汇报');
    });
    await test('新增定时任务后日程计数与实际项目一致', async () => {
      await action('add');
      await field('task-title').fill('明天的答疑');
      await field('task-date').fill('2026-10-20');
      await field('task-time').fill('20:30');
      await app().locator('[type="submit"]').click();
      assert.match(await app().locator('.sheet').innerText(), /2026-10-20 20:30/);
      await action('close-sheet');
      await action('tab', 'plan');
      await action('date', '2026-10-20');
      assert.match(await app().locator('.app-scroll').innerText(), /0 节课 · 1 项定时任务/);
      assert.equal(await app().locator('[data-event^="added-"]').count(), 1);
      await action('plan-view', 'tasks');
      assert.match(await app().locator('.app-scroll').innerText(), /明天的答疑/);
    });
    await test('未来全天事项在对应日期与全部待办中可见', async () => {
      await action('add');
      await field('task-title').fill('周二归还绘图工具');
      await field('task-date').fill('2026-10-20');
      await app().locator('[type="submit"]').click();
      assert.match(await app().locator('.sheet').innerText(), /全天/);
      await action('close-sheet');
      await action('tab', 'plan');
      await action('date', '2026-10-20');
      assert.match(await app().locator('.app-scroll').innerText(), /周二归还绘图工具/);
      await action('plan-view', 'tasks');
      assert.match(await app().locator('.app-scroll').innerText(), /周二归还绘图工具/);
    });
    await test('完整42格月历日期定位，不改变待办草稿', async () => {
      await work('page', 'plan');
      await action('calendar');
      assert.equal(await app().locator('.calendar-month button').count(), 42);
      assert.equal(await app().locator('.calendar-month button').first().getAttribute('data-value'), '2026-09-28');
      assert.equal(await app().locator('.calendar-month button').last().getAttribute('data-value'), '2026-11-08');
      await app().locator('.calendar-month [data-value="2026-10-31"]').click();
      assert.equal((await state()).selectedDate, '2026-10-31');
      assert.equal((await state()).draft.date, '2026-10-19');
    });
    await test('待办搜索和筛选按真实项目，空结果可恢复', async () => {
      await work('page', 'plan');
      await action('plan-view', 'tasks');
      await field('query').fill('操作系统实验');
      assert.equal(await app().locator('[data-event]').count(), 1);
      await field('query').fill('不存在的任务');
      assert.equal(await app().locator('[data-event]').count(), 0);
      await action('clear-filter');
      assert.equal(await field('query').inputValue(), '');
      assert.equal(await app().locator('[data-event]').count(), 7);
    });
    await test('选择日期传入建议，保留现有输入且不自动发送', async () => {
      await work('page', 'agent');
      await field('prompt').fill('我原来写好的目标');
      await action('tab', 'plan');
      await action('date', '2026-10-22');
      await action('suggest', 'selected-date');
      assert.match(await field('prompt').inputValue(), /我原来写好的目标[\s\S]*2026-10-22/);
      assert.equal((await state()).messages.length, 0);
    });
    await test('提案展开、确认回执与确切三项写入', async () => {
      await work('page', 'agent');
      await action('proposal-expand');
      assert.equal(await app().locator('.proposal-line').count(), 3);
      await app().locator('.proposal').scrollIntoViewIfNeeded();
      await shot('02-agent-pending');
      await action('proposal-confirm');
      const data = await state();
      assert.equal(data.proposal, 'confirmed');
      assert.equal(data.untimed.filter(x => x.id.startsWith('proposal-task-')).length, 3);
      assert.equal(data.receipts.filter(x => x.id === 'XJ-DEMO-001').length, 1);
      assert.equal(await app().locator('[data-act="proposal-confirm"]').count(), 0);
      await action('tab', 'plan');
      await action('date', '2026-10-20');
      assert.match(await app().locator('.app-scroll').innerText(), /0 节课 · 1 项定时任务/);
    });
    await test('未知结果不能确认或放弃，核对后只落一次回执', async () => {
      await work('page', 'agent');
      await page.locator('#scenario').selectOption('unknown');
      assert.equal(await app().locator('[data-act="proposal-confirm"]').count(), 0);
      assert.equal(await app().locator('[data-act="proposal-cancel"]').count(), 0);
      assert.equal(await app().locator('.pending-strip.uncertain').count(), 1);
      await app().locator('.proposal').scrollIntoViewIfNeeded();
      await shot('03-agent-unknown');
      await action('proposal-check');
      assert.equal((await state()).receipts.filter(x => x.id === 'XJ-DEMO-001').length, 1);
      assert.equal(await app().locator('[data-act="proposal-check"]').count(), 0);
    });
    await test('改期先预览，确认后仍是同一个任务', async () => {
      await action('conflict');
      const original = (await state()).events;
      await action('replan-preview');
      assert.deepEqual((await state()).events, original);
      await action('replan-confirm');
      const data = await state();
      assert.equal(data.events.length, 8);
      assert.equal(data.events.find(x => x.id === 't-algorithm').start, '17:35');
      assert.equal(data.events.some(x => x.conflict), false);
    });
    await test('课内安排默认关闭，取消不改，二次确认保留课程重叠事实', async () => {
      await work('direction', 'paper');
      await action('detail', 't-algorithm');
      assert.equal(await app().locator('[data-act="inclass-toggle"]').getAttribute('aria-checked'), 'false');
      await action('inclass-toggle', 't-algorithm');
      assert.match(await app().locator('.sheet').innerText(), /高等数学[\s\S]*15:30–16:05/);
      assert.match(await app().locator('.sheet .detail-field').nth(0).innerText(), /2026-10-19 14:30–16:05/);
      assert.match(await app().locator('.sheet .detail-field').nth(1).innerText(), /2026-10-19 15:30–16:15/);
      assert.match(await app().locator('.sheet .notice').innerText(), /2026-10-19 15:30–16:05/);
      await action('inclass-cancel');
      assert.equal((await state()).events.find(x => x.id === 't-algorithm').inClassAllowed, undefined);
      await action('inclass-toggle', 't-algorithm');
      await shot('08-inclass-overlap-confirmation');
      await action('inclass-confirm', 't-algorithm');
      const item = (await state()).events.find(x => x.id === 't-algorithm');
      assert.equal(item.inClassAllowed, true);
      assert.equal(item.conflict, true);
      assert.equal(item.start, '15:30');
      assert.match(await app().locator('.sheet').innerText(), /已确认课内安排.*重叠事实仍保留/);
      await action('close-sheet');
      assert.match(await app().locator('[data-event="t-algorithm"]').innerText(), /已确认课内安排/);
    });
    await test('课内例外不能放行与另一个任务的明确时段冲突', async () => {
      // Supply one extra collision fixture; execute the real rendered UI guard.
      await page.evaluate(() => {
        states.paper.events.push({ id: 'collision-task', type: 'task', title: '已约好的答疑', start: '15:40', end: '16:00', location: '办公室' });
        render();
      });
      await action('detail', 't-algorithm');
      await action('inclass-toggle', 't-algorithm');
      assert.match(await app().locator('.sheet').innerText(), /课内设置不能绕过任务冲突/);
      assert.equal(await app().locator('[data-act="inclass-confirm"]').isDisabled(), true);
      assert.equal((await state()).events.find(x => x.id === 't-algorithm').inClassAllowed, undefined);
    });
    await test('语音草稿追加、可编辑且不自动发送', async () => {
      await work('page', 'agent');
      await field('prompt').fill('我原有的草稿');
      await action('voice');
      assert.match(await app().locator('.sheet').innerText(), /不会访问麦克风/);
      await field('voice-text').fill('我修改过的转写文字');
      await action('voice-use');
      assert.equal(await field('prompt').inputValue(), '我原有的草稿\n我修改过的转写文字');
      assert.equal((await state()).messages.length, 0);
      await action('send');
      assert.equal((await state()).messages.length, 1);
    });
    await test('新会话前保存原草稿，历史可继续原会话', async () => {
      await work('page', 'agent');
      await field('prompt').fill('原会话还没发出的内容');
      await action('new-chat');
      await action('confirm-new');
      assert.equal(await field('prompt').inputValue(), '');
      await action('open-history');
      await action('history-view', 'initial');
      assert.match(await app().locator('.sheet').innerText(), /原会话还没发出的内容/);
      await action('continue-chat');
      assert.equal(await field('prompt').inputValue(), '原会话还没发出的内容');
    });
    await test('页面关键空、加载和失败状态明确且可操作', async () => {
      await work('direction', 'paper');
      for (const name of ['agent', 'plan']) {
        await work('page', name);
        await page.locator('#scenario').selectOption('empty');
        assert.ok(await app().locator('.empty-state').count() > 0);
        await page.locator('#scenario').selectOption('loading');
        assert.equal(await app().locator('.loading-state').count(), 1);
        await page.locator('#scenario').selectOption('error');
        assert.ok(await app().locator('.notice.error').count() > 0);
        await action('retry');
        assert.equal(await app().locator('.notice.error').count(), 0);
      }
      await work('page', 'plan');
      await shot('04-planning-390');
      await page.locator('#scenario').selectOption('empty');
      await shot('05-planning-empty');
      await page.locator('#scenario').selectOption('error');
      await shot('06-planning-error');
    });
    await test('弹层键盘焦点限制与Escape收起保留输入', async () => {
      await action('add');
      await field('task-title').fill('键盘填写草稿');
      await page.keyboard.press('Escape');
      assert.equal(await app().locator('.sheet').count(), 0);
      await action('add');
      assert.equal(await field('task-title').inputValue(), '键盘填写草稿');
      const controls = app().locator('.sheet button:not(:disabled),.sheet input,.sheet select,.sheet textarea');
      await controls.last().focus();
      await page.keyboard.press('Tab');
      assert.equal(await controls.first().evaluate(el => el === document.activeElement), true);
    });
    await test('320/360/390、大字、键盘和月历不造成整页或手机横向溢出', async () => {
      await page.setViewportSize({ width: 390, height: 844 });
      await work('direction', 'paper');
      for (const width of [320, 360, 390]) {
        await page.locator('#width').selectOption(String(width));
        for (const name of ['home', 'agent', 'plan']) {
          await work('page', name);
          for (const large of [false, true]) {
            if ((await page.locator('[data-work="large"]').getAttribute('aria-pressed')) !== String(large)) await work('large');
            if (name === 'agent' && (await page.locator('[data-work="keyboard"]').getAttribute('aria-pressed')) !== 'true') await work('keyboard');
            const overflow = await page.evaluate(() => ({
              outer: document.documentElement.scrollWidth > innerWidth + 1,
              app: Array.from(document.querySelectorAll('.app')).some(el => el.scrollWidth > el.clientWidth + 1),
              body: Array.from(document.querySelectorAll('.app-scroll')).some(el => el.scrollWidth > el.clientWidth + 1)
            }));
            assert.deepEqual(overflow, { outer: false, app: false, body: false }, `${width}/${name}/large:${large}`);
            if (name === 'agent') {
              const usable = await app().locator('.app-scroll').evaluate(el => el.clientHeight);
              assert.ok(usable >= 120, `remaining chat height ${usable}`);
            }
          }
        }
      }
      await page.locator('#width').selectOption('360');
      await work('page', 'agent');
      await shot('07-agent-360-large-keyboard');
      await work('page', 'plan');
      await action('calendar');
      assert.equal(await app().locator('.calendar-month button').count(), 42);
    });
    await test('刷新明确重置内存演示，不伪装持久化', async () => {
      await action('toggle', 't-lab');
      assert.equal((await state()).events.find(x => x.id === 't-lab').done, true);
      await page.reload();
      assert.equal((await state()).events.find(x => x.id === 't-lab').done, undefined);
      assert.match(await page.locator('.lab-note').innerText(), /刷新即重置/);
    });
    assert.deepEqual(errors, []);
    assert.deepEqual(network, []);
    const result = { type: 'HTML prototype only; not native acceptance', passed: passed.length, checks: passed, errors, externalRequests: network };
    if (out) fs.writeFileSync(path.join(out, 'checks.json'), JSON.stringify(result, null, 2) + '\n');
    console.log(JSON.stringify(result, null, 2));
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
