import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { resolve } from 'node:path';
import { test } from 'node:test';

const read = file => readFileSync(new URL(`../entry/src/main/ets/${file}.ets`, import.meta.url), 'utf8');
const clean = source => source.replace(/^import [^\n]+;\r?\n/gm, '');
const agenda = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(clean(read('utils/DailyAgenda')))).toString('base64')}`);
const { partitionToday } = new Function(stripTypeScriptTypes(clean(read('utils/FreeWindows')).replace(/^export /gm, '')) + '\nreturn {partitionToday};')();
const compiledPath = process.env.CAMPUSFLOW_COMPILED_HOME_PAGE;
const compiledOptions = { skip: compiledPath ? false : 'requires a freshly compiled Hvigor HomePage.ts artifact' };

function method(source, name) {
  const start = source.indexOf(`    private ${name}(`), end = source.indexOf('\n    private ', start + 1);
  assert.ok(start >= 0 && end > start, `actual compiled ${name} is required`);
  return source.slice(start, end);
}

function probe(builder, group = '') {
  assert.ok(compiledPath && existsSync(compiledPath));
  const source = readFileSync(resolve(compiledPath), 'utf8');
  const callbacks = [], texts = new Map(), actions = new Map(), branches = new Map();
  let active = -1, rows = [];
  const widget = name => new Proxy({}, { get(_target, key) { return (...args) => {
    if (name === 'Text' && key === 'create') texts.set(active, args[0]);
    if (name === 'Button' && key === 'onClick') actions.set(active, args[0]);
  }; } });
  const names = ['Column', 'Row', 'Text', 'If', 'Button', 'ForEach', 'Divider'];
  const deps = { ...Object.fromEntries(names.map(name => [name, widget(name)])),
    HorizontalAlign: { Start: '' }, VerticalAlign: { Top: '' }, FontWeight: { Medium: '', Bold: '' },
    WordBreak: { BREAK_WORD: '' }, ButtonType: { Normal: '' }, Color: { Transparent: '' },
    AppIcon: class {}, ViewPU: { create() {} }, labelNext: agenda.labelNext };
  const Page = new Function(...Object.keys(deps), stripTypeScriptTypes(`class NativeProbe { ${method(source, builder)} }`) + '\nreturn NativeProbe;')(...Object.values(deps));
  const page = new Page();
  const invoke = (index, initial) => {
    if (!callbacks[index].alive) return;
    const prior = active; active = index;
    try { callbacks[index].callback(index, initial); } finally { active = prior; }
  };
  const removeChildren = parent => callbacks.forEach((callback, index) => {
    if (callback.alive && callback.parent === parent) {
      callback.alive = false; texts.delete(index); actions.delete(index); removeChildren(index);
    }
  });
  Object.assign(page, { palette: {}, nowMs: Date.parse('2030-10-19T19:30:00+08:00'), dataRevision: 1,
    tasks: [task()], courses: [course()], clicked: [],
    agenda() { return agenda.buildDailyAgenda(this.courses, this.tasks, this.nowMs); },
    groups() { return partitionToday(this.agenda().rows, this.nowMs); },
    nextAction(row) { this.clicked.push(row.id); },
    observeComponentCreation2(callback) { const index = callbacks.push({ callback, parent: active, alive: true }) - 1; invoke(index, true); },
    forEachUpdateFunction(_id, values) { rows = values.map(row => structuredClone(row)); },
    ifElseBranchUpdateFunction(branch, create) {
      if (branches.get(active) !== branch) { removeChildren(active); branches.set(active, branch); create(); }
    },
    updateStateVarsOfChildByElmtId() {}
  });
  return { page,
    mount() {
      const calls = source.split(/\r?\n/).filter(line => line.includes(`this.${builder}.bind(this)(`) && (!group || line.includes(`this.groups().${group}`)));
      assert.equal(calls.length, 1, 'mount through the actual compiled call site');
      new Function(stripTypeScriptTypes(calls[0])).call(page);
    },
    refresh() { callbacks.slice().forEach((_value, index) => invoke(index, false)); },
    rows() { return rows; }, text() { return [...texts.values()]; },
    click() { [...actions.values()].at(-1)?.(); }
  };
}

const task = (extra = {}) => ({ task_id: 'task-a', plan_id: null, milestone_id: null, title: '本轮待办',
  start_at: '2030-10-19T20:05:00+08:00', end_at: '2030-10-19T21:30:00+08:00', location: '自习室',
  status: 'pending', source: 'agent', reminder_minutes: null, created_at: '', completed_at: null, ...extra });
const course = () => ({ date: '2030-10-19', title: '后续课程', start_time: '21:40', end_time: '22:30', location: '六教', teacher: '' });

test('actual native upcoming callbacks drop a completed task without remounting or switching tabs', compiledOptions, () => {
  const p = probe('TimelineList', 'upcoming'); p.mount();
  assert.ok(p.rows().some(row => row.taskId === 'task-a'));
  p.page.tasks = [task({ status: 'completed' })]; p.page.dataRevision++; p.refresh();
  assert.equal(p.rows().some(row => row.taskId === 'task-a'), false);
  assert.equal(p.page.groups().earlier.filter(row => row.taskId === 'task-a').length, 1);
});
test('actual native earlier callbacks include completion and remove restoration in the same view', compiledOptions, () => {
  const p = probe('TimelineList', 'earlier'); p.page.courses = [{ ...course(), start_time: '08:05', end_time: '09:40' }]; p.mount();
  p.page.tasks = [task({ status: 'completed' })]; p.page.dataRevision++; p.refresh();
  assert.equal(p.rows().filter(row => row.taskId === 'task-a' && row.done).length, 1);
  p.page.tasks = [task()]; p.page.dataRevision++; p.refresh();
  assert.equal(p.rows().some(row => row.taskId === 'task-a'), false);
});
test('actual native next card follows the current item and its click after task completion', compiledOptions, () => {
  const p = probe('NextCard'); p.mount(); assert.ok(p.text().includes('本轮待办'));
  p.page.tasks = [task({ status: 'completed' })]; p.refresh();
  assert.ok(p.text().includes('后续课程')); assert.ok(!p.text().includes('本轮待办'));
  p.click(); assert.deepEqual(p.page.clicked, [p.page.agenda().next.id]);
});
test('actual native next card removes its last item and action when no pending item remains', compiledOptions, () => {
  const p = probe('NextCard'); p.page.courses = []; p.mount();
  p.page.tasks = [task({ status: 'completed' })]; p.refresh();
  assert.equal(p.page.agenda().next, null); assert.deepEqual(p.text(), []);
  p.click(); assert.deepEqual(p.page.clicked, []);
});

// Only replays the genuine compiler callbacks and their branch lifetime. This is
// not native rendering, dependency scheduling, or a substitute for Phone tests.
