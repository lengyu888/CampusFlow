import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

// Use the compiler already shipped with DevEco; no dependency installation or output files.
const compilerRelativePath = 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript';
const compilerCandidates = [
  process.env.CAMPUSFLOW_TYPESCRIPT_PATH,
  process.env.DEVECO_STUDIO_HOME ? path.join(process.env.DEVECO_STUDIO_HOME, compilerRelativePath) : undefined,
  path.join('C:/Program Files/Huawei/DevEco Studio', compilerRelativePath),
  path.join('D:/DevEco Studio', compilerRelativePath)
];
const compilerPath = compilerCandidates.find(candidate => candidate && existsSync(candidate));
assert.ok(compilerPath,
  'DevEco TypeScript compiler missing; set CAMPUSFLOW_TYPESCRIPT_PATH to its existing directory ' +
  'or DEVECO_STUDIO_HOME to your DevEco Studio installation.');
const require = createRequire(import.meta.url);
const ts = require(compilerPath);
const parserPath = path.resolve(path.dirname(fileURLToPath(import.meta.url)),
  '../entry/src/main/ets/utils/MarkdownParser.ets');
const parserSource = readFileSync(parserPath, 'utf8');
const virtualPath = parserPath.replace(/\.ets$/, '.ts').replaceAll('\\', '/');
const compilerOptions = {
  target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.ES2020, strict: true, noEmit: true
};
const host = ts.createCompilerHost(compilerOptions);
const originalSource = host.getSourceFile;
const originalExists = host.fileExists;
const originalRead = host.readFile;
const isVirtual = file => file.replaceAll('\\', '/') === virtualPath;
host.getSourceFile = (file, version, onError, shouldCreate) => isVirtual(file)
  ? ts.createSourceFile(virtualPath, parserSource, version, true, ts.ScriptKind.TS)
  : originalSource(file, version, onError, shouldCreate);
host.fileExists = file => isVirtual(file) || originalExists(file);
host.readFile = file => isVirtual(file) ? parserSource : originalRead(file);
const typeErrors = ts.getPreEmitDiagnostics(ts.createProgram([virtualPath], compilerOptions, host));
assert.equal(typeErrors.length, 0,
  typeErrors.map(item => ts.flattenDiagnosticMessageText(item.messageText, '\n')).join('\n'));
const compiled = ts.transpileModule(parserSource, {
  fileName: 'MarkdownParser.ts',
  reportDiagnostics: true,
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.ES2020, strict: true }
});
const errors = (compiled.diagnostics ?? []).filter(item => item.category === ts.DiagnosticCategory.Error);
assert.equal(errors.length, 0,
  errors.map(item => ts.flattenDiagnosticMessageText(item.messageText, '\n')).join('\n'));
const { parseMarkdown, parseInline } = await import(
  `data:text/javascript;base64,${Buffer.from(compiled.outputText).toString('base64')}`);

function textOf(items) {
  return items.map(item => item.text).join('');
}

test('empty content and CRLF produce predictable paragraphs', () => {
  assert.deepEqual(parseMarkdown(''), []);
  assert.deepEqual(parseMarkdown(' \r\n\r\n'), []);
  const blocks = parseMarkdown('第一行\r\n第二行\r\n\r\n另一段');
  assert.deepEqual(blocks.map(item => [item.kind, item.text]),
    [['paragraph', '第一行\n第二行'], ['paragraph', '另一段']]);
});

test('headings, ordered and indented lists, quotes and dividers remain distinct', () => {
  const blocks = parseMarkdown('# 课程 **规划**\n\n- 一级\n  2. 二级\n\t3) 三级\n> 提醒\n>> 深层\n---');
  assert.deepEqual(blocks.map(item => item.kind),
    ['heading', 'list', 'list', 'list', 'quote', 'quote', 'divider']);
  assert.equal(blocks[0].level, 1);
  assert.equal(textOf(blocks[0].inlines), '课程 规划');
  assert.deepEqual(blocks.slice(1, 4).map(item => [item.marker, item.level]),
    [['-', 0], ['2.', 1], ['3)', 2]]);
  assert.deepEqual(blocks.slice(4, 6).map(item => item.level), [1, 2]);
});

test('inline emphasis retains nested styles and literal text', () => {
  const items = parseInline('普通 **粗体 *斜体*** 和 ***两者*** 与 _斜体_');
  assert.equal(textOf(items), '普通 粗体 斜体 和 两者 与 斜体');
  assert.ok(items.some(item => item.text === '粗体 ' && item.bold && !item.italic));
  assert.ok(items.some(item => item.text === '斜体' && item.bold && item.italic));
  assert.ok(items.some(item => item.text === '两者' && item.bold && item.italic));
  assert.ok(items.some(item => item.text === '斜体' && !item.bold && item.italic));
  assert.equal(textOf(parseInline('*斜体 **粗体***')), '斜体 粗体');
});

test('escapes, unmatched markers and identifiers are readable', () => {
  const source = 'student_id \\*literal\\* and **unfinished [link](https://example.com)';
  assert.equal(textOf(parseInline(source)),
    'student_id *literal* and **unfinished [link](https://example.com)');
  assert.ok(parseInline('student_id').every(item => !item.italic));
});

test('inline code protects symbols and accepts matching multi-backtick delimiters', () => {
  const items = parseInline('运行 `**a|b**` 或 `` a ` b ``');
  assert.equal(textOf(items), '运行 **a|b** 或 a ` b');
  assert.deepEqual(items.filter(item => item.code).map(item => item.text), ['**a|b**', 'a ` b']);
  assert.equal(textOf(parseInline('`unfinished | text')), '`unfinished | text');
});

test('fenced code keeps indentation, empty lines and Markdown punctuation', () => {
  const blocks = parseMarkdown('前言\n\n```ts\n  const x = "**bold** | value";\n\n\t// # heading\n```\n\n结尾');
  assert.deepEqual(blocks.map(item => item.kind), ['paragraph', 'code', 'paragraph']);
  assert.equal(blocks[1].marker, 'ts');
  assert.equal(blocks[1].text, '  const x = "**bold** | value";\n\n\t// # heading');
  assert.deepEqual(blocks[1].inlines, []);
});

test('fences match their own character and length, including unclosed code', () => {
  const code = parseMarkdown('~~~~text\n~~~\n```\n~~~~~')[0];
  assert.equal(code.kind, 'code');
  assert.equal(code.text, '~~~\n```');
  assert.equal(parseMarkdown('```\n  未闭合\n')[0].text, '  未闭合\n');
  assert.equal(parseMarkdown('```\n```')[0].text, '');
});

test('GFM table recognizes optional outer pipes and per-column alignment', () => {
  const blocks = parseMarkdown('课程 | 教室 | 时间\n:--- | :---: | ---:\n数学 | 101 | 08:00\n英语 | 202 | 10:00');
  assert.equal(blocks.length, 1);
  assert.equal(blocks[0].kind, 'table');
  assert.deepEqual(blocks[0].rows,
    [['课程', '教室', '时间'], ['数学', '101', '08:00'], ['英语', '202', '10:00']]);
  assert.deepEqual(blocks[0].alignments, ['left', 'center', 'right']);
  assert.equal(parseMarkdown('| 单列 |\n| - |')[0].kind, 'table');
});

test('escaped pipes and pipes inside code spans do not create extra columns', () => {
  const table = parseMarkdown('| 表达式 | 说明 |\n| --- | --- |\n| A\\|B | `x|y` |\n| ``a`|b`` | 末尾\\| |\n| escaped | `x\\|y` |')[0];
  assert.equal(table.kind, 'table');
  assert.deepEqual(table.rows[1], ['A|B', '`x|y`']);
  assert.deepEqual(table.rows[2], ['``a`|b``', '末尾|']);
  assert.deepEqual(table.rows[3], ['escaped', '`x|y`']);
  assert.equal(parseInline(table.rows[1][1])[0].code, true);
  assert.equal(parseInline(table.rows[3][1])[0].text, 'x|y');
});

test('even backslashes leave a structural pipe and missing cells are padded', () => {
  const table = parseMarkdown('| A | B |\n| --- | --- |\n| one |\n| slash\\\\| value |\nonly one cell')[0];
  assert.equal(table.kind, 'table');
  assert.deepEqual(table.rows[1], ['one', '']);
  assert.equal(textOf(parseInline(table.rows[2][0])), 'slash\\');
  assert.equal(table.rows[2][1], 'value');
  assert.deepEqual(table.rows[3], ['only one cell', '']);
  assert.ok(table.rows.every(row => row.length === table.alignments.length));
});

test('extra table cells use a complete readable fallback instead of truncation', () => {
  const source = '| A | B |\n| --- | --- |\n| one | two | three |';
  const result = parseMarkdown(source);
  assert.equal(result[0].kind, 'paragraph');
  assert.equal(result[0].text, source);
  assert.equal(textOf(result[0].inlines), source);
  assert.deepEqual(result[0].rows, []);
});

test('ordinary pipe text and malformed delimiter rows are not tables', () => {
  for (const source of ['路径 A | B\n继续说明', 'A | B\n---', '| A | B |\n| --- | nope |']) {
    const result = parseMarkdown(source);
    assert.ok(result.every(item => item.kind !== 'table'));
    assert.equal(result.map(item => item.text).join('\n'), source);
  }
});

test('table stops before a new block or paragraph without swallowing it', () => {
  const blocks = parseMarkdown('| A | B |\n| --- | --- |\n| 1 | 2 |\n## 后续\n说明 | 内容');
  assert.deepEqual(blocks.map(item => item.kind), ['table', 'heading', 'paragraph']);
  assert.equal(blocks[2].text, '说明 | 内容');
});

test('length and complexity fallbacks preserve all content', () => {
  const longInline = '**' + '字'.repeat(12001) + '**';
  assert.equal(textOf(parseInline(longInline)), longInline);
  const longMessage = '字'.repeat(100001);
  assert.equal(parseMarkdown(longMessage)[0].text, longMessage);
  const manyLines = Array(2001).fill('line').join('\n');
  assert.equal(parseMarkdown(manyLines)[0].text, manyLines);
  const manySpans = Array(300).fill('**b** plain ').join('');
  assert.equal(textOf(parseInline(manySpans)), manySpans);
});

test('oversized table fallback preserves columns and every row', () => {
  const header = '| ' + Array(25).fill('列').join(' | ') + ' |';
  const separator = '| ' + Array(25).fill('---').join(' | ') + ' |';
  const wide = header + '\n' + separator;
  assert.equal(parseMarkdown(wide)[0].text, wide);
  assert.equal(parseMarkdown(wide)[0].kind, 'paragraph');
  const tall = '| A | B |\n| --- | --- |\n' + Array(201).fill('| a | b |').join('\n');
  assert.equal(parseMarkdown(tall)[0].text, tall);
  assert.equal(parseMarkdown(tall)[0].kind, 'paragraph');
});
