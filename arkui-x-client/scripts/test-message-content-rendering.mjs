import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { resolve } from 'node:path';
import { test } from 'node:test';

// Replay actual native compiler callbacks; pixels and text scaling remain Phone QA.
const compiledPath = process.env.CAMPUSFLOW_COMPILED_MESSAGE_CONTENT;
const options = { skip: compiledPath ? false : 'requires an explicit, freshly compiled Hvigor MessageContent.ts artifact' };

function probe(content) {
  assert.ok(compiledPath && existsSync(compiledPath), 'explicit compiled MessageContent artifact must exist');
  const source = readFileSync(resolve(compiledPath), 'utf8');
  const start = source.indexOf('    initialRender()');
  const end = source.indexOf('\n    rerender()', start);
  assert.ok(start >= 0 && end > start);
  const texts = [], buttons = [], markdown = [];
  let current;
  const widget = name => new Proxy({}, { get(_target, key) { return (...args) => {
    if (key === 'create' && name === 'Text') { current = { kind: 'text', text: args[0] }; texts.push(current); }
    else if (key === 'createWithChild' && name === 'Button') { current = { kind: 'button' }; buttons.push(current); }
    else if (key === 'create' || key === 'createWithLabel') current = { kind: name };
    else if (key !== 'pop' && current) current[key] = args[0];
  }; } });
  const Page = new Function('Column', 'Row', 'If', 'Text', 'Button', 'ButtonType', 'Color', 'TextAlign',
    'HorizontalAlign', 'WordBreak', 'CopyOptions', 'MarkdownMessage', 'ViewPU',
    stripTypeScriptTypes(`class Probe { ${source.slice(start, end)} }`) + '\nreturn Probe;')(
      widget('Column'), widget('Row'), widget('If'), widget('Text'), widget('Button'), { Normal: '' },
      { Transparent: '' }, { Start: '' }, { Start: '' }, { BREAK_WORD: '' }, { InApp: 'copy-in-app' },
      class { constructor(_owner, props) { markdown.push(props.content); } }, { create() {} });
  const page = new Page();
  Object.assign(page, { content, isUser: false, showOriginal: true, hasFormatting: true, palette: { bodySize: 17, metaSize: 13 },
    observeComponentCreation2(callback) { callback(1, true); },
    ifElseBranchUpdateFunction(_branch, build) { build(); }, updateStateVarsOfChildByElmtId() {} });
  return { page, texts, buttons, markdown, mount() { texts.length = 0; buttons.length = 0; markdown.length = 0; page.initialRender(); } };
}

test('original reply mode keeps full copyable text and one compact switch instead of stacked helper rows', options, () => {
  const original = '# 一周安排\n\n' + '内容与长链接https://example.invalid/a_b__c '.repeat(1000);
  const p = probe(original); p.mount();
  assert.equal(p.texts.filter(item => item.text === original).length, 1);
  assert.equal(p.texts.find(item => item.text === original).copyOption, 'copy-in-app');
  assert.equal(p.texts.find(item => item.text === original).maxLines, undefined);
  assert.equal(p.texts.filter(item => item.text !== original).length, 1, 'copy help and formatting switch must not create stacked auxiliary rows');
  assert.equal(p.buttons.length, 1);
});

test('native formatting toggle keeps the entire answer in both directions without a request or edit', options, () => {
  const original = '# 安排\n\n**复习**\n\n```text\n  keep <raw>\n```';
  const p = probe(original); p.mount();
  p.buttons[0].onClick(); assert.equal(p.page.showOriginal, false); p.mount();
  assert.deepEqual(p.markdown, [original]);
  assert.equal(p.page.content, original);
  p.buttons[0].onClick(); assert.equal(p.page.showOriginal, true); p.mount();
  assert.equal(p.texts[0].text, original);
  p.page.hasFormatting = false; p.page.showOriginal = false; p.mount();
  assert.equal(p.buttons.length, 0);
});
