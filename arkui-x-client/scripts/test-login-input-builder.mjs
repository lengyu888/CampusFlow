import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';

const compiledPath = process.env.CAMPUSFLOW_COMPILED_LOGIN_PAGE;
test('actual compiled login input callback follows a changed service without recreating the Builder', {
  skip: compiledPath ? false : 'requires an explicit, freshly compiled Hvigor LoginPage.ts artifact'
}, () => {
  const compiled = readFileSync(compiledPath, 'utf8');
  const start = compiled.indexOf('    private inputField(');
  const end = compiled.indexOf('\n    initialRender()', start);
  assert.ok(start >= 0 && end > start);
  const method = compiled.slice(start, end).replace('    private inputField(', 'function inputField(');
  // Evaluate the actual compiler-emitted third argument, so the old code is
  // tested with its original string argument, not an incompatible fake getter.
  const binding = /inputField\.bind\(this\)\('服务地址',\s*'[^']*',\s*(\(\) => this\.baseUrl|this\.baseUrl),/.exec(compiled);
  assert.ok(binding, 'actual service-field call site is required');
  const callbacks = [];
  let text;
  const widget = name => new Proxy({}, { get(_target, key) {
    return (...args) => { if (name === 'TextInput' && key === 'create') text = args[0].text; };
  } });
  const builder = new Function('Column', 'Text', 'TextInput', 'InputType', 'HorizontalAlign', 'FontWeight',
    stripTypeScriptTypes(method) + '\nreturn inputField;')(
      widget('Column'), widget('Text'), widget('TextInput'), { Normal: 0 }, { Start: 0 }, { Medium: 0 });
  const page = { baseUrl: 'http://127.0.0.1:8000', loading: false, restoreBusy: false, palette: {},
    observeComponentCreation2(callback) { callbacks.push(callback); callback(1, true); } };
  const argument = new Function(`return ${binding[1]};`).call(page);
  builder.call(page, '服务地址', 'service', argument, () => {});
  assert.equal(text, 'http://127.0.0.1:8000');
  page.baseUrl = 'http://203.0.113.20:8000';
  for (const callback of callbacks) callback(1, false);
  assert.equal(text, page.baseUrl);
});
