import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { resolve } from 'node:path';
import { test } from 'node:test';

const compiledPath = process.env.CAMPUSFLOW_COMPILED_PLAN_PAGE;
const options = { skip: compiledPath ? false : 'requires an explicit, freshly compiled Hvigor PlanCenterPage.ts artifact' };

function method(source, name) {
  const start = source.indexOf(`    private ${name}(`);
  const end = source.indexOf('\n    private ', start + 1);
  assert.ok(start >= 0 && end > start, `actual compiled ${name} method is required`);
  return source.slice(start, end);
}

// Executes the genuine compiler-emitted TaskCheck branches. It checks native
// drawing arguments/click wiring, not layout, native hit testing or Phone pixels.
function render(task, { locked = false, blocked = false } = {}) {
  assert.ok(compiledPath && existsSync(compiledPath));
  const source = readFileSync(resolve(compiledPath), 'utf8');
  const drawing = [], clicks = [];
  let handler;
  const widget = name => new Proxy({}, { get(_target, key) { return (...args) => {
    drawing.push({ name, key, args });
    if (name === 'Button' && key === 'onClick') handler = args[0];
  }; } });
  class AppIcon { constructor(_parent, parameters) { drawing.push({ name: 'AppIcon', key: 'parameters', args: [parameters] }); } }
  const Page = new Function('Button', 'If', 'Text', 'Stack', 'Circle', 'ButtonType', 'Color', 'WordBreak', 'AppIcon', 'ViewPU',
    stripTypeScriptTypes(`class Probe { ${method(source, 'TaskCheck')}\n${method(source, 'statusLabel')} }`) + '\nreturn Probe;')(
      ...['Button', 'If', 'Text', 'Stack', 'Circle'].map(widget), { Normal: 'normal' }, { Transparent: 'transparent' },
      { BREAK_WORD: 'break-word' }, AppIcon, { create() {} });
  const page = new Page();
  Object.assign(page, {
    palette: { accent: 'accent', surface: 'surface', quiet: 'quiet', onAccent: 'on-accent' },
    statusLockedTaskIds: locked ? [task.task_id] : [], writesBlocked: () => blocked,
    toggle: value => clicks.push(value), observeComponentCreation2: callback => callback(1, true),
    ifElseBranchUpdateFunction: (_branch, create) => create(), updateStateVarsOfChildByElmtId() {}
  });
  page.TaskCheck(task);
  return { drawing, calls: (name, key) => drawing.filter(call => call.name === name && call.key === key).map(call => call.args[0]),
    click() { assert.equal(typeof handler, 'function'); handler(); return clicks; } };
}

test('compiled pending check is an empty circle in a 48vp target and uses the original action task', options, () => {
  const task = { task_id: 'pending-task', status: 'pending' }, p = render(task);
  assert.deepEqual(p.calls('Circle', 'fill'), ['surface']);
  assert.deepEqual(p.calls('Circle', 'stroke'), ['quiet']);
  assert.deepEqual(p.calls('Button', 'width'), [48]);
  assert.deepEqual(p.calls('Button', 'constraintSize'), [{ minHeight: 48 }]);
  assert.deepEqual(p.calls('AppIcon', 'parameters'), []);
  assert.deepEqual(p.calls('Button', 'accessibilityText'), ['标记完成']);
  assert.equal(p.click()[0], task);
});

test('compiled completed check is a filled circle with checkmark instead of the restore text', options, () => {
  for (const receipt of ['confirmed-operation', null]) {
    const task = { task_id: 'completed-task', status: 'completed', completion_operation_id: receipt }, p = render(task);
    assert.deepEqual(p.calls('Circle', 'fill'), ['accent']);
    assert.deepEqual(p.calls('Circle', 'stroke'), ['accent']);
    assert.deepEqual(p.calls('Button', 'width'), [48]);
    assert.equal(p.calls('AppIcon', 'parameters')[0]?.name, 'check');
    assert.equal(p.calls('AppIcon', 'parameters')[0]?.color, 'on-accent');
    assert.deepEqual(p.calls('Text', 'create'), []);
    assert.deepEqual(p.calls('Button', 'accessibilityText'), [receipt ? '恢复未完成' : '这次完成未保留可恢复凭据']);
    assert.equal(p.click()[0], task, 'the icon must retain the existing restore/receipt guard path');
  }
});

test('compiled locked task remains an operable result-check entry even when writes are blocked', options, () => {
  const task = { task_id: 'locked-task', status: 'completed' }, p = render(task, { locked: true, blocked: true });
  assert.deepEqual(p.calls('Text', 'create'), ['核对结果']);
  assert.deepEqual(p.calls('Circle', 'fill'), []);
  assert.deepEqual(p.calls('Button', 'enabled'), [true]);
  assert.deepEqual(p.calls('Button', 'accessibilityText'), ['状态结果待核对']);
  assert.equal(p.click()[0], task);
});
