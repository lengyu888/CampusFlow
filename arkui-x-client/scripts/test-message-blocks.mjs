import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';

const source = readFileSync(new URL('../entry/src/main/ets/utils/MessageBlocks.ets', import.meta.url), 'utf8');
const { parseMessageBlocks, readableInline, tableCells } = await import(
  `data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source)).toString('base64')}`);

test('headings, paragraphs and ordered/unordered tasks retain their content and order', () => {
  const blocks = parseMessageBlocks('# 今晚安排\n\n先看 **课程**。\n保留第二行。\n\n- 复习一章\n2. 完成练习\n+ 检查答案');
  assert.deepEqual(blocks.map((item) => item.kind), ['heading', 'paragraph', 'list', 'list', 'list']);
  assert.equal(blocks[0].text, '今晚安排');
  assert.equal(blocks[1].text, '先看 课程。\n保留第二行。');
  assert.deepEqual(blocks.slice(2).map((item) => item.marker), ['•', '2.', '•']);
});

test('fenced code stays literal, including indentation, operators, headings and blank lines', () => {
  const code = 'def __init__():\n    value = a ** b\n\n    # keep this\n    return "a|b"';
  const blocks = parseMessageBlocks(`说明\n\n\`\`\`python\n${code}\n\`\`\`\n完成`);
  assert.equal(blocks[1].kind, 'code');
  assert.equal(blocks[1].text, code);
  assert.equal(blocks[1].marker, 'python');
  assert.equal(blocks[2].text, '完成');
  assert.equal(readableInline('使用 `__init__` 与 ``a ** b``；**保留重点**'), '使用 __init__ 与 a ** b；保留重点');
});

test('unclosed fences retain the remaining code and longer fences can include shorter ones', () => {
  assert.equal(parseMessageBlocks('~~~txt\n原文\n# 标题')[0].text, '原文\n# 标题');
  assert.equal(parseMessageBlocks('````\n```\nbody\n```\n````')[0].text, '```\nbody\n```');
});

test('tables become rows of labelled values without discarding wide or empty columns', () => {
  const blocks = parseMessageBlocks('| 时间 | 任务 | 地点 |\n| :--- | ---: | --- |\n| 08:00 | 复习 | 图书馆 |\n| 09:00 | 练习 | |');
  assert.equal(blocks.length, 1);
  assert.equal(blocks[0].kind, 'table');
  assert.deepEqual(blocks[0].headers, ['时间', '任务', '地点']);
  assert.deepEqual(blocks[0].rows.map((row) => row.cells), [['08:00', '复习', '图书馆'], ['09:00', '练习', '']]);
});

test('escaped and inline-code pipes stay inside their cell', () => {
  assert.deepEqual(tableCells('| a\\|b | `a|b` | ``x|y`` |'), ['a|b', '`a|b`', '``x|y``']);
  const [block] = parseMessageBlocks('| 命令 | 注释 |\n| --- | --- |\n| `a|b` | x\\|y |');
  assert.deepEqual(block.rows[0].cells, ['a|b', 'x|y']);
});

test('irregular or header-only tables fall back to complete source rather than losing cells', () => {
  for (const text of ['| A | B |\n| --- | --- |\n| 1 | 2 | EXTRA |', '| A | B |\n| --- | --- |']) {
    const [block] = parseMessageBlocks(text);
    assert.equal(block.kind, 'paragraph');
    assert.equal(block.text, text);
  }
});

test('unsupported markup, long URLs, HTML and repeated blocks remain text, without network actions', () => {
  const link = 'https://example.invalid/' + 'longsegment'.repeat(100);
  const source = `[资料](${link})\n<img src="https://example.invalid/image.png">\n> 原文备注`;
  assert.equal(parseMessageBlocks(source)[0].text, source);
  assert.deepEqual(parseMessageBlocks('- 相同\n- 相同').map((item) => item.text), ['相同', '相同']);
});

test('large answers are not truncated and CRLF is normalized once', () => {
  const text = '内容'.repeat(10000);
  assert.equal(parseMessageBlocks(text)[0].text, text);
  assert.equal(parseMessageBlocks('第一行\r\n第二行\r第三行')[0].text, '第一行\n第二行\n第三行');
  assert.deepEqual(parseMessageBlocks(' \n\n'), []);
});


test('identifiers and URL underscores survive default formatting', () => {
  for (const text of ['user__name__field', 'https://example.invalid/__init__/value', '__name__',
    'Run ``a`__init__`b``']) {
    assert.equal(readableInline(text), text === 'Run ``a`__init__`b``' ? 'Run a`__init__`b' : text);
  }
});

test('same-line backticks are inline text and indented fence-like code cannot close a block', () => {
  const [inline] = parseMessageBlocks('```npm install```');
  assert.equal(inline.kind, 'paragraph');
  assert.equal(inline.text, 'npm install');
  const [code] = parseMessageBlocks('```text\n    ```\n    __name__\n```');
  assert.equal(code.kind, 'code');
  assert.equal(code.text, '    ```\n    __name__');
});


test('overlong numeric prefixes remain ordinary text rather than unbounded list markers', () => {
  const text = '123456789012345678901234567890. 内容';
  const [block] = parseMessageBlocks(text);
  assert.equal(block.kind, 'paragraph');
  assert.equal(block.text, text);
  assert.equal(parseMessageBlocks('123456789. 内容')[0].kind, 'list');
});
