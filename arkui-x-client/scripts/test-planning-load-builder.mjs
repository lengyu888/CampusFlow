import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { resolve } from 'node:path';
import { test } from 'node:test';
import { overview } from './helpers/planning-overview-fixture.mjs';

const pageSource = readFileSync(new URL('../entry/src/main/ets/pages/PlanCenterPage.ets', import.meta.url), 'utf8');
// Native acceptance supplies the actual, freshly compiled Hvigor output. A clean
// checkout without the SDK must not silently substitute a handwritten Builder.
const compiledPath = process.env.CAMPUSFLOW_COMPILED_PLAN_PAGE;
const compiledOptions = { skip: compiledPath ? false : 'requires an explicit, freshly compiled Hvigor PlanCenterPage.ts artifact' };

test('all load-card call sites pass lazy readers instead of an initial computed snapshot', () => {
  const builder = pageSource.slice(pageSource.indexOf('  private LoadSummary('), pageSource.indexOf('  private TaskCheck('));
  assert.match(builder, /LoadSummary\(load: \(\) => PlanningDayLoad, label: string\)/);
  assert.doesNotMatch(builder, /\bload\./);
  assert.match(builder, /this\.loadExclusions\(load\(\)\)/);
  assert.match(builder, /this\.loadTargetMessage\(load\(\)\)/);
  assert.match(pageSource, /this\.LoadSummary\(\(\) => this\.dayLoad\(this\.selectedDate\), '当前预计负荷'\)/);
  assert.match(pageSource, /this\.LoadSummary\(\(\) => this\.dayLoad\(this\.previewLoadDate\(\)\), '候选前'\)/);
  assert.match(pageSource, /this\.LoadSummary\(\(\) => this\.candidateLoad\(\), '确认后预计'\)/);
  assert.equal((pageSource.match(/this\.LoadSummary\(/g) ?? []).length, 3);
});

function compiledMethod(source, name) {
  const start = source.indexOf(`    private ${name}(`);
  assert.ok(start >= 0, `actual compiled method ${name} is required`);
  const end = source.indexOf('\n    private ', start + 1);
  assert.ok(end > start, `compiled method ${name} must have a following method boundary`);
  return source.slice(start, end);
}

function nativeCallbacks() {
  assert.ok(compiledPath && existsSync(compiledPath), 'explicit compiled artifact must exist');
  const compiled = readFileSync(resolve(compiledPath), 'utf8');
  const methods = ['LoadSummary', 'dayLoad', 'sourcesComplete', 'minutes', 'loadExclusions', 'loadTargetMessage']
    .map(name => compiledMethod(compiled, name)).join('\n');
  const callbacks = [];
  const displayed = new Map();
  const branches = new Map();
  let active = -1;
  const widget = name => new Proxy({}, { get(_target, method) {
    return (...args) => { if (name === 'Text' && method === 'create') displayed.set(active, args[0]); };
  } });
  const Page = new Function('Text', 'Column', 'If', 'HorizontalAlign', 'FontWeight', 'WordBreak', 'dailyPlannedLoad',
    stripTypeScriptTypes(`class CompiledLoadProbe { ${methods} }`) + '\nreturn CompiledLoadProbe;')(
      widget('Text'), widget('Column'), widget('If'), { Start: '' }, { Medium: '' }, { BREAK_WORD: '' }, overview.dailyPlannedLoad);
  const page = new Page();
  const invoke = (index, initial) => {
    const previous = active; active = index;
    try { callbacks[index](index, initial); } finally { active = previous; }
  };
  Object.assign(page, {
    palette: {}, selectedDate: '2026-10-24', timetable: [], overview: { tasks: [] },
    timetableState: 'loading', planningState: 'loading', preferencesState: 'ready', preferences: { enabled: false },
    observeComponentCreation2(callback) { const index = callbacks.push(callback) - 1; invoke(index, true); },
    ifElseBranchUpdateFunction(branch, create) {
      if (branches.get(active) !== branch) { branches.set(active, branch); create(); }
    }
  });
  return {
    page,
    mount(label) {
      const calls = compiled.split(/\r?\n/).filter(line => line.includes('this.LoadSummary.bind(this)(') && line.includes(`'${label}'`));
      assert.equal(calls.length, 1, 'load reader must come from the actual compiled call site');
      new Function(calls[0]).call(page);
    },
    // Only replays the callbacks emitted by the native compiler. It never calls
    // LoadSummary again on update, which would hide the captured-snapshot bug.
    refresh() { callbacks.slice().forEach((_callback, index) => invoke(index, false)); return [...displayed.values()]; },
    text() { return [...displayed.values()]; }
  };
}

const course = { date: '2026-10-24', title: 'Integration course', start_time: '01:00', end_time: '02:00', location: '', teacher: '' };
const task = (extra = {}) => ({ task_id: 'offline-task', plan_id: null, milestone_id: null, title: '离线验收·复习任务',
  start_at: '2026-10-24T19:00:00+08:00', end_at: '2026-10-24T19:30:00+08:00', reminder_minutes: null,
  status: 'pending', source: 'agent', created_at: '', completed_at: null, location: '', ...extra });
function ready(page) {
  page.timetable = [{ ...course }]; page.overview = { tasks: [task()] };
  page.timetableState = 'ready'; page.planningState = 'ready';
}

test('actual compiled load callbacks update empty loading data to 60 course + 30 task = 90 minutes', compiledOptions, () => {
  const { page, mount, refresh, text } = nativeCallbacks();
  mount('当前预计负荷');
  assert.ok(text().includes('课表或任务尚未完整核对，暂不判断预计负荷。'));
  ready(page);
  assert.deepEqual([page.dayLoad(page.selectedDate).courseMinutes, page.dayLoad(page.selectedDate).taskMinutes], [60, 30]);
  const result = refresh();
  assert.ok(result.includes('课程 60 分钟 · 任务 30 分钟'));
  assert.ok(result.includes('合计占用 90 分钟 · 重叠时段只计一次'));
});

test('actual compiled load callbacks follow selected date and restore prior occupancy without rebuilding the Builder', compiledOptions, () => {
  const { page, mount, refresh } = nativeCallbacks(); ready(page);
  mount('当前预计负荷');
  page.selectedDate = '2026-10-25'; let result = refresh();
  assert.ok(result.includes('当前预计负荷 · 2026-10-25'));
  assert.ok(result.includes('课程 0 分钟 · 任务 0 分钟'));
  page.selectedDate = '2026-10-24'; result = refresh();
  assert.ok(result.includes('当前预计负荷 · 2026-10-24'));
  assert.ok(result.includes('合计占用 90 分钟 · 重叠时段只计一次'));
});

test('actual compiled candidate load reader updates projected times rather than retaining the old proposal', compiledOptions, () => {
  const { page, mount, refresh } = nativeCallbacks(); ready(page);
  let projected = [task()];
  page.candidateLoad = () => overview.dailyPlannedLoad(page.timetable, projected, page.selectedDate);
  mount('确认后预计');
  projected = [task({ end_at: '2026-10-24T20:00:00+08:00' })];
  const result = refresh();
  assert.ok(result.includes('课程 60 分钟 · 任务 60 分钟'));
  assert.ok(result.includes('合计占用 120 分钟 · 重叠时段只计一次'));
  assert.equal(page.overview.tasks[0].end_at, '2026-10-24T19:30:00+08:00');
});

test('actual compiled exclusions follow later all-day, undated, missing-end and invalid tasks', compiledOptions, () => {
  const { page, mount, refresh } = nativeCallbacks(); ready(page);
  mount('当前预计负荷');
  page.overview = { tasks: [task(), task({ task_id: 'all', start_at: '2026-10-24', end_at: null }),
    task({ task_id: 'undated', start_at: null, end_at: null }), task({ task_id: 'incomplete', end_at: null }),
    task({ task_id: 'invalid', start_at: 'not-a-date', end_at: null })] };
  assert.ok(refresh().includes('1 项全天、1 项无日期、1 项缺结束时间未计时长；1 项时间异常需核对。'));
});

// This seam replays real native-compiler callbacks with only widget scheduling
// adapted. It is not ArkUI rendering, dependency tracking, or Phone acceptance.
