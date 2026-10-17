// Browser approximation and local PNG/theme validation only. Never installs anything.
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const expected = ['xj_onboarding', 'xj_empty_day', 'xj_course_entry', 'xj_focus_entry', 'xj_campus_entry', 'xj_focus_end', 'xj_review_empty'];
const cssNames = { canvas:'canvas', surface:'surface', ink:'ink', secondary:'secondary', accent:'accent', accentSoft:'accent-soft',
  onAccent:'on-accent', line:'line', outline:'outline', terracotta:'terracotta', success:'success', successSoft:'success-soft',
  warning:'warning', warningSoft:'warning-soft', danger:'danger', dangerSoft:'danger-soft', dangerOutline:'danger-outline',
  warningOutline:'warning-outline', focus:'focus', pressed:'pressed', pressedSoft:'pressed-soft',
  disabledContent:'disabled-content', disabledSurface:'disabled-surface' };
function readTheme(file) {
  const source = fs.readFileSync(file, 'utf8'), values = {}, expressions = {};
  for (const m of source.matchAll(/static readonly (\w+): string = (?:'([^']+)'|AppTheme\.(\w+));/g)) expressions[m[1]] = m[2] || m[3];
  function get(key, seen = new Set()) {
    assert.ok(expressions[key], `missing theme token ${key}`);
    assert.ok(!seen.has(key), `circular theme alias ${key}`);
    if (values[key]) return values[key];
    const expression = expressions[key];
    return values[key] = expression.startsWith('#') ? expression.toUpperCase() : get(expression, new Set([...seen, key]));
  }
  Object.keys(expressions).forEach(key => get(key));
  return values;
}
function luminance(hex) {
  const channels = hex.slice(1).match(/../g).map(v => parseInt(v, 16) / 255).map(v => v <= .04045 ? v / 12.92 : ((v + .055) / 1.055) ** 2.4);
  return channels[0] * .2126 + channels[1] * .7152 + channels[2] * .0722;
}
function ratio(a, b) { const x = luminance(a), y = luminance(b); return (Math.max(x,y) + .05) / (Math.min(x,y) + .05); }
const rgb = hex => `rgb(${hex.slice(1).match(/../g).map(v => parseInt(v, 16)).join(', ')})`;
(async () => {
  const file = path.resolve(process.argv[2] || path.join(__dirname, 'ux-02-foundation.html'));
  const root = path.resolve(path.dirname(file), '../..');
  const media = path.join(root, 'arkui-x-client/entry/src/main/resources/base/media');
  const themeFile = path.join(root, 'arkui-x-client/entry/src/main/ets/theme/AppTheme.ets');
  const out = process.argv[3] ? path.resolve(process.argv[3]) : null;
  if (out) fs.mkdirSync(out, { recursive: true });
  const theme = readTheme(themeFile);
  const resources = expected.map(name => {
    const filePath = path.join(media, name + '.png');
    assert.ok(fs.existsSync(filePath), `Resource not ready: ${filePath}; wait until all seven actual images are written.`);
    const bytes = fs.readFileSync(filePath);
    assert.equal(bytes.subarray(0, 8).toString('hex'), '89504e470d0a1a0a', `${name} must be an actual PNG`);
    const item = { name, bytes: bytes.length, width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20), pngColorType: bytes[25] };
    assert.ok(item.width > 0 && item.height > 0, name);
    return item;
  });
  const browser = await chromium.launch({ headless: true, executablePath: process.env.CHROME_EXECUTABLE });
  const page = await browser.newPage({ viewport: { width: 1440, height: 1080 }, locale: 'zh-CN', timezoneId: 'Asia/Shanghai' });
  const errors = [], externalRequests = [], passed = [], contrasts = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.route(/^https?:/, route => { externalRequests.push(route.request().url()); return route.abort(); });
  const goto = async () => { await page.goto(pathToFileURL(file).href); await page.waitForFunction(() => Array.from(document.querySelectorAll('img[data-resource]')).every(img => img.complete && img.naturalWidth > 0)); };
  const shot = async name => { if (out) await page.screenshot({ path: path.join(out, name + '.png'), fullPage: true, animations: 'disabled' }); };
  const chooseView = view => page.locator(`[data-view="${view}"]`).click();
  const snapshot = () => page.evaluate(() => window.foundationSnapshot());
  const test = async (name, fn) => { await page.setViewportSize({ width: 1440, height: 1080 }); await goto(); await fn(); passed.push(name); };
  try {
    await test('浏览器边界与每个 CSS 颜色逐项匹配当前 AppTheme', async () => {
      assert.match(await page.locator('.boundary').innerText(), /浏览器近似.*非原生验收/);
      assert.match(await page.locator('.boundary').innerText(), /刷新即重置/);
      for (const [native, css] of Object.entries(cssNames)) {
        const actual = await page.evaluate(css => getComputedStyle(document.documentElement).getPropertyValue('--' + css).trim().toUpperCase(), css);
        assert.equal(actual, theme[native], native);
      }
      assert.equal(await page.evaluate(() => getComputedStyle(document.documentElement).getPropertyValue('--card-radius').trim()), '16px');
      assert.equal(await page.evaluate(() => getComputedStyle(document.documentElement).getPropertyValue('--control-radius').trim()), '12px');
      assert.equal(theme.blue, theme.accent); assert.equal(theme.actionBlue, theme.accent); assert.equal(theme.blueSoft, theme.accentSoft);
      assert.equal(theme.green, theme.success); assert.equal(theme.orange, theme.warning); assert.equal(theme.red, theme.danger);
      assert.equal(theme.bg, theme.canvas); assert.equal(theme.quiet, theme.secondary);
    });
    await test('实算实际 token 的正文、警告、错误、焦点及按压色对', async () => {
      const pairs = [['ink','surface',4.5],['secondary','surface',4.5],['secondary','canvas',4.5],['accent','surface',4.5],
        ['accent','accentSoft',4.5],['onAccent','accent',4.5],['outline','surface',3],['focus','surface',3],
        ['warning','warningSoft',4.5],['danger','dangerSoft',4.5],['success','successSoft',4.5],['onAccent','pressed',4.5],['accent','pressedSoft',4.5]];
      for (const [fg,bg,min] of pairs) { const actual = ratio(theme[fg],theme[bg]); contrasts.push({ foreground:fg, background:bg, ratio:+actual.toFixed(3), required:min }); assert.ok(actual >= min, `${fg}/${bg}: ${actual}`); }
      contrasts.push({ foreground:'disabledContent', background:'disabledSurface', ratio:+ratio(theme.disabledContent,theme.disabledSurface).toFixed(3), required:null, note:'Disabled controls only; not an ordinary text compliance claim.' });
      await chooseView('foundation');
      await shot('01-theme-and-states');
    });
    await test('七张真实本地 PNG 全部解码，40/48 缩图在双背景上尺寸准确', async () => {
      assert.deepEqual((await snapshot()).resources, expected);
      assert.equal(await page.locator('.asset-card').count(), 7);
      for (const resource of resources) {
        const card = page.locator(`[data-asset="${resource.name}"]`);
        assert.equal(await card.locator('.thumb-box').count(), 4);
        assert.equal(await card.locator('.asset-status').getAttribute('data-missing'), 'false');
        const natural = await card.locator('[data-primary]').evaluate(img => [img.naturalWidth,img.naturalHeight]);
        assert.deepEqual(natural, [resource.width,resource.height]);
        const dimensions = await card.locator('.thumb-box .art').evaluateAll(nodes => nodes.map(node => [node.clientWidth,node.clientHeight]));
        assert.deepEqual(dimensions, [[40,40],[40,40],[48,48],[48,48]]);
        assert.equal(await card.locator('.thumb-box.canvas').count(), 2);
        assert.equal(await card.locator('.thumb-box.surface-bg').count(), 2);
      }
      assert.equal(await page.locator('img:not([alt=""])').count(), 0, 'Decorative illustrations must not duplicate page text.');
      await chooseView('assets'); await shot('02-actual-assets-and-small-sizes');
    });
    await test('表单关联错误提示，模拟保存仍保留输入', async () => {
      await page.locator('#save-sample').click();
      assert.equal(await page.locator('#task-title').getAttribute('aria-invalid'), 'true');
      assert.equal(await page.locator('#task-title').getAttribute('aria-describedby'), 'task-help');
      assert.match(await page.locator('#task-help').innerText(), /先写下/);
      await page.locator('#task-title').fill('整理操作系统实验中的进程同步与死锁分析报告');
      await page.locator('#save-sample').click();
      assert.equal(await page.locator('#task-title').getAttribute('aria-invalid'), 'false');
      assert.equal(await page.locator('#task-title').inputValue(), '整理操作系统实验中的进程同步与死锁分析报告');
      assert.equal((await snapshot()).state, 'success');
      assert.match(await page.locator('#feedback').innerText(), /原型回执 XJ-UX02-001.*仅本页内存演示/);
    });
    await test('未知结果使用警告色且不能再次保存，只核对一次原型回执', async () => {
      await page.locator('#task-title').fill('尚未确定是否保存的草稿');
      await page.locator('#state').selectOption('unknown');
      assert.equal(await page.locator('#save-sample').isDisabled(), true);
      assert.equal(await page.locator('#feedback button').count(), 1);
      assert.equal(await page.locator('#feedback').evaluate(node => getComputedStyle(node).backgroundColor), rgb(theme.warningSoft));
      assert.match(await page.locator('#feedback').innerText(), /不再提交另一份/);
      await chooseView('foundation'); await shot('03-unknown-result');
      await page.locator('#check-result').click();
      assert.equal((await snapshot()).queryCount, 1);
      assert.equal((await snapshot()).state, 'success');
      assert.equal(await page.locator('#check-result').count(), 0);
      assert.equal(await page.locator('#task-title').inputValue(), '尚未确定是否保存的草稿');
    });
    await test('加载、空记录、警告、错误、成功的文字与视觉互不冒充', async () => {
      for (const [name,color,phrase] of [['loading',theme.surface,'正在读取安排'],['empty',theme.surface,'还没有记录'],
        ['warning',theme.warningSoft,'课程有重叠'],['error',theme.dangerSoft,'这次读取未完成'],['success',theme.successSoft,'明确回执']]) {
        await page.locator('#state').selectOption(name);
        assert.equal(await page.locator('#feedback').getAttribute('data-kind'), name);
        assert.equal(await page.locator('#feedback').evaluate(node => getComputedStyle(node).backgroundColor), rgb(color));
        assert.match(await page.locator('#feedback').innerText(), new RegExp(phrase));
      }
      await page.locator('#state').selectOption('error');
      await page.locator('#retry-read').click(); assert.equal((await snapshot()).state, 'info');
      assert.equal(await page.locator('#sample-disabled').isDisabled(), true);
      const color = await page.locator('#sample-disabled').evaluate(node => getComputedStyle(node).color);
      assert.equal(color, rgb(theme.disabledContent));
    });
    await test('图片失败保留所有文字路径，恢复后仍加载真实资源', async () => {
      await page.locator('#fail-images').click();
      await page.waitForFunction(() => Array.from(document.querySelectorAll('.art')).every(node => node.classList.contains('is-failed')));
      assert.equal(await page.locator('.asset-status[data-missing="true"]').count(), 7);
      await chooseView('mapping');
      await page.locator('[data-scene="timetable"]').click();
      assert.match(await page.locator('#campus-result').innerText(), /校园 → 我的课表/);
      await page.locator('[data-scene="route"]').click();
      assert.match(await page.locator('#campus-result').innerText(), /仍需要选择真实起点与目的地/);
      await shot('04-image-failure-keeps-actions');
      await page.locator('#fail-images').click();
      // Cached images may expose naturalWidth before their load event clears the fallback.
      await page.waitForFunction(() => Array.from(document.querySelectorAll('img[data-resource]')).every(img =>
        img.complete && img.naturalWidth > 0 && !img.parentElement.classList.contains('is-failed')));
      assert.equal(await page.locator('.art.is-failed').count(), 0);
    });
    await test('首步引导、空态与两个校园入口仅执行明确原型路径', async () => {
      await chooseView('mapping');
      await page.locator('#nickname').fill('小林');
      await page.locator('[data-scene="onboarding"]').click();
      assert.match(await page.locator('#onboarding-result').innerText(), /没有注册或保存/);
      assert.equal(await page.locator('#nickname').inputValue(), '小林');
      await page.locator('[data-scene="capture"]').click();
      assert.match(await page.locator('#capture-result').innerText(), /没有写入任何任务/);
      assert.match(await page.locator('#mapping').innerText(), /没有记录也不承诺用户确实有空/);
      assert.equal(await page.locator('.entry').count(), 2);
      await shot('05-onboarding-empty-and-entries');
    });
    await test('360/390 与大字下文字可换行、触区不缩小且无横向溢出', async () => {
      for (const width of [360,390]) {
        await page.setViewportSize({ width, height: 844 });
        await page.locator('#width').selectOption(String(width));
        for (const large of [false,true]) {
          if (await page.locator('#large').getAttribute('aria-pressed') !== String(large)) await page.locator('#large').click();
          for (const view of ['foundation','assets','mapping']) {
            await chooseView(view);
            const overflow = await page.evaluate(() => ({ outer:document.documentElement.scrollWidth > innerWidth + 1,
              phone:Array.from(document.querySelectorAll('.phone')).some(node => node.scrollWidth > node.clientWidth + 1),
              body:Array.from(document.querySelectorAll('.phone-body')).some(node => node.scrollWidth > node.clientWidth + 1) }));
            assert.deepEqual(overflow,{outer:false,phone:false,body:false},`${width}/${large}/${view}`);
            const targets = await page.locator('.specimen .btn:visible,.phone .btn:visible,.entry:visible').evaluateAll(nodes => nodes.map(node => node.getBoundingClientRect().height));
            assert.ok(targets.every(height => height >= 48), `${width}/${large}/${view} touch target`);
          }
        }
      }
      await page.setViewportSize({ width:360,height:844 }); await page.locator('#width').selectOption('360');
      await chooseView('mapping'); await shot('06-360-large-mapping');
    });
    await test('减少动态设置关闭动画，刷新重置演示且不产生外联', async () => {
      await page.emulateMedia({ reducedMotion:'reduce' });
      await page.locator('#state').selectOption('loading');
      assert.equal(await page.locator('.spinner').evaluate(node => getComputedStyle(node).animationName), 'none');
      await page.locator('#state').selectOption('unknown'); await page.locator('#check-result').click();
      await page.reload(); assert.equal((await snapshot()).queryCount, 0); assert.equal((await snapshot()).state, 'warning');
      assert.deepEqual(errors,[]); assert.deepEqual(externalRequests,[]);
    });
    const result = { type:'Browser approximation, local PNG and actual theme checks; not ArkUI/native acceptance', passed:passed.length,
      checks:passed, contrasts, resources, resourceBytes:resources.reduce((sum,item) => sum + item.bytes,0), errors, externalRequests };
    if(out) fs.writeFileSync(path.join(out,'checks.json'),JSON.stringify(result,null,2)+'\n');
    console.log(JSON.stringify(result,null,2));
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode=1; });
