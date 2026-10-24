import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { resolve } from 'node:path';
import { test } from 'node:test';
import { focusRecord } from './helpers/focus-fixture.mjs';

const pageSource = readFileSync(new URL('../entry/src/main/ets/pages/FocusPage.ets', import.meta.url), 'utf8');
const compiledPath = process.env.CAMPUSFLOW_COMPILED_FOCUS_PAGE;
const compiledOptions = { skip: compiledPath ? false : 'requires an explicit, freshly compiled Hvigor FocusPage.ts artifact' };

function method(source, name) {
  const start = source.indexOf(`    private ${name}(`);
  const nextPrivate = source.indexOf('\n    private ', start + 1);
  const end = nextPrivate >= 0 ? nextPrivate : source.indexOf('\n    initialRender()', start + 1);
  assert.ok(start >= 0 && end > start, `actual compiled method ${name} is required`);
  return source.slice(start, end);
}

function probe(builder) {
  assert.ok(compiledPath && existsSync(compiledPath), 'explicit compiled artifact must exist');
  const source = readFileSync(resolve(compiledPath), 'utf8');
  const names = [builder, 'localTitle', 'localLabel', 'duration', 'targetReached', 'synchronizedLabel', 'recordTitle',
    'recordLabel', 'visibleIntervals', 'visibleGaps', 'gapReason'];
  const callbacks = [], displayed = new Map(), buttons = new Map(), branches = new Map();
  let active = -1;
  const widget = name => new Proxy({}, { get(_target, key) {
    return (...args) => {
      if (name === 'Text' && key === 'create') displayed.set(active, args[0]);
      if (name === 'Button' && key === 'createWithLabel') buttons.set(active, { label: args[0] });
      if (name === 'Button' && key === 'onClick') buttons.get(active).click = args[0];
    };
  } });
  const Page = new Function('Text', 'Column', 'Row', 'If', 'Button', 'HorizontalAlign', 'FontWeight', 'WordBreak',
    'AppIllustration', 'ViewPU', 'formatPlanDateTime', stripTypeScriptTypes(`class Probe { ${names.map(name => method(source, name)).join('\n')} }`) + ';return Probe;')(
      widget('Text'), widget('Column'), widget('Row'), widget('If'), widget('Button'), { Start: '' }, { Medium: '' },
      { BREAK_WORD: '' }, class {}, { create() {} }, value => value);
  const page = new Page();
  const invoke = (index, initial) => {
    if (!callbacks[index].alive) return;
    const prior = active; active = index;
    try { callbacks[index].callback(index, initial); } finally { active = prior; }
  };
  const removeChildren = parent => callbacks.forEach((callback, index) => {
    if (callback.parent === parent && callback.alive) {
      callback.alive = false; displayed.delete(index); buttons.delete(index); removeChildren(index);
    }
  });
  Object.assign(page, {
    palette: {}, active: true, taskId: 'task-a', taskTitle: 'Synthetic focus task', detailExpanded: false,
    state: { local: null, record: null, activeRecord: null, pendingOperations: [], intervals: [], unknownGaps: [], intervalError: '' },
    observeComponentCreation2(callback) { const index = callbacks.push({ callback, parent: active, alive: true }) - 1; invoke(index, true); },
    ifElseBranchUpdateFunction(branch, create) {
      if (branches.get(active) !== branch) { removeChildren(active); branches.set(active, branch); create(); }
    },
    updateStateVarsOfChildByElmtId() {},
    forEachUpdateFunction() { throw new Error('interval pagination is not part of this callback seam'); }
  });
  return {
    page,
    mount() {
      const calls = source.split(/\r?\n/).filter(line => line.includes(`this.${builder}.bind(this)(`));
      assert.equal(calls.length, 1, 'use the actual compiled call site, not a handwritten substitute');
      new Function(calls[0]).call(page);
    },
    refresh() { callbacks.slice().forEach((_callback, index) => invoke(index, false)); },
    text() { return [...displayed.values()]; },
    buttonLabels() { return [...buttons.values()].map(button => button.label); },
    click(label) {
      const found = [...buttons.values()].find(button => button.label === label);
      assert.ok(found?.click, `current native button ${label} is required`); found.click();
    }
  };
}

const local = (extra = {}) => ({ recordId: 'synthetic-record', taskId: 'task-a', mode: 'online', localState: 'preparing',
  elapsedMs: 0, targetMs: null, confirmedElapsedMs: 0, unknownGapCount: 0, saveState: 'saved',
  canPause: false, canResume: false, canEnd: false, ...extra });

test('focus cards read fresh native state rather than capturing a single initial snapshot', () => {
  assert.match(pageSource, /private Current\(\)/);
  assert.match(pageSource, /private Detail\(\)/);
  assert.match(pageSource, /this\.Current\(\)/);
  assert.match(pageSource, /this\.Detail\(\)/);
});

test('actual compiled focus callbacks replace preparing/0:00 with running/0:05 and pause/end controls', compiledOptions, () => {
  const p = probe('Current'); p.page.state.local = local(); p.mount();
  p.page.state = { ...p.page.state, local: local({ localState: 'running', elapsedMs: 5000, canPause: true, canEnd: true }) };
  p.refresh();
  assert.ok(p.text().includes('正在记录前台经过时间'));
  assert.ok(p.text().includes('0:05'));
  assert.ok(p.buttonLabels().includes('暂停'));
  assert.ok(p.buttonLabels().includes('结束本次记录'));
});

test('actual compiled focus callbacks follow ticking, pause, resume, target and final confirmation without remount', compiledOptions, () => {
  const p = probe('Current'); p.page.state.local = local(); p.mount();
  const update = extra => { p.page.state = { ...p.page.state, local: local(extra) }; p.refresh(); };
  update({ localState: 'running', elapsedMs: 5000, canPause: true, canEnd: true });
  update({ localState: 'running', elapsedMs: 60000, targetMs: 60000, canPause: true, canEnd: true });
  assert.ok(p.text().includes('1:00')); assert.ok(p.text().includes('已到设定时长，计时继续；何时结束由你决定。'));
  update({ localState: 'paused', elapsedMs: 60000, canResume: true, canEnd: true });
  assert.ok(p.text().includes('已暂停 · 暂停期间不累计')); assert.ok(!p.buttonLabels().includes('暂停'));
  assert.ok(p.buttonLabels().includes('继续这条记录'));
  update({ localState: 'running', elapsedMs: 61000, canPause: true, canEnd: true });
  assert.ok(p.text().includes('1:01')); assert.ok(!p.buttonLabels().includes('继续这条记录'));
  update({ localState: 'ended', elapsedMs: 62000, confirmedElapsedMs: 62000, unknownGapCount: 1 });
  assert.ok(p.text().includes('1:02')); assert.ok(p.text().some(text => text.includes('已确认片段 1:02')));
  assert.ok(p.text().includes('还有 1 段无法核实时长，不作补算。'));
  assert.ok(!p.buttonLabels().includes('暂停')); assert.ok(!p.buttonLabels().includes('结束本次记录'));
});

test('actual compiled detail callbacks follow running to paused/ended and delete action uses latest revision', compiledOptions, () => {
  const p = probe('Detail'); p.page.state.record = focusRecord(); p.mount();
  const selected = []; p.page.askDelete = record => selected.push(record.revision);
  p.page.state = { ...p.page.state, record: focusRecord(undefined, { state: 'paused', revision: 2, confirmed_elapsed_ms: 5000 }) };
  p.refresh(); assert.ok(p.text().includes('0:05')); assert.ok(p.text().includes('已同步 · 已暂停 · 已确认片段，不代表有效学习时长'));
  assert.ok(p.buttonLabels().includes('继续这条已暂停记录')); p.click('删除这条已同步记录');
  p.page.state = { ...p.page.state, record: focusRecord(undefined, { state: 'ended', revision: 3, confirmed_elapsed_ms: 9000 }) };
  p.refresh(); assert.ok(p.text().includes('0:09')); assert.ok(!p.buttonLabels().includes('继续这条已暂停记录'));
  p.click('删除这条已同步记录'); assert.deepEqual(selected, [2, 3]);
});

test('actual compiled focus cards remove old content safely when their current state becomes null', compiledOptions, () => {
  for (const builder of ['Current', 'Detail']) {
    const p = probe(builder);
    if (builder === 'Current') p.page.state.local = local({ localState: 'running', elapsedMs: 5000, canPause: true, canEnd: true });
    else p.page.state.record = focusRecord();
    p.mount(); assert.ok(p.text().length > 0);
    p.page.state = { ...p.page.state, local: null, record: null };
    p.refresh(); assert.deepEqual(p.text(), []); assert.deepEqual(p.buttonLabels(), []);
  }
});

// Replays genuine native compiler callbacks and their branch lifetime only.
// Does not simulate ArkUI dependency tracking, rendering, platform clocks or Phone acceptance.
