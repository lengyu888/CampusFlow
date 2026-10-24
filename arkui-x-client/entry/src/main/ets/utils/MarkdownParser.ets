export interface MarkdownInline {
  text: string;
  bold: boolean;
  italic: boolean;
  code: boolean;
}

export interface MarkdownBlock {
  kind: string;
  text: string;
  level: number;
  marker: string;
  inlines: MarkdownInline[];
  rows: string[][];
  alignments: string[];
}

interface TableRow {
  cells: string[];
  hasPipe: boolean;
}

interface TableResult {
  block: MarkdownBlock;
  nextLine: number;
}

const MAX_SOURCE_LENGTH: number = 100000;
const MAX_LINES: number = 2000;
const MAX_BLOCKS: number = 300;
const MAX_INLINE_LENGTH: number = 12000;
const MAX_INLINE_SEGMENTS: number = 200;
const MAX_TABLE_COLUMNS: number = 24;
const MAX_TABLE_ROWS: number = 200;
const MAX_INLINE_DEPTH: number = 12;

function rawInline(text: string): MarkdownInline {
  return { text: text, bold: false, italic: false, code: false };
}

function block(kind: string, text: string, level: number = 0,
  marker: string = ''): MarkdownBlock {
  return {
    kind: kind,
    text: text,
    level: level,
    marker: marker,
    inlines: kind === 'code' || kind === 'divider' ? [] : parseInline(text),
    rows: [],
    alignments: []
  };
}

function fallback(text: string): MarkdownBlock {
  return {
    kind: 'paragraph', text: text, level: 0, marker: '',
    inlines: [rawInline(text)], rows: [], alignments: []
  };
}

function runLength(source: string, start: number, character: string): number {
  let end = start;
  while (end < source.length && source.charAt(end) === character) end += 1;
  return end - start;
}

function codeEnd(source: string, start: number, length: number): number {
  let position = start;
  while (position < source.length) {
    const next = source.indexOf('`', position);
    if (next < 0) return -1;
    const count = runLength(source, next, '`');
    if (count === length) return next;
    position = next + count;
  }
  return -1;
}

function wordCharacter(value: string): boolean {
  return value.length > 0 && /[a-zA-Z0-9\u00c0-\uffff]/.test(value);
}

function emphasisEnd(source: string, start: number, character: string,
  length: number): number {
  let position = start;
  while (position < source.length) {
    const current = source.charAt(position);
    if (current === '\\') {
      position += 2;
      continue;
    }
    if (current === '`') {
      const count = runLength(source, position, '`');
      const end = codeEnd(source, position + count, count);
      position = end < 0 ? position + count : end + count;
      continue;
    }
    if (current !== character) {
      position += 1;
      continue;
    }
    const count = runLength(source, position, character);
    // A closing triple may finish nested bold and italic spans together.
    if (count === length || (count === 3 && length < 3)) {
      const candidate = position + count - length;
      const before = source.charAt(candidate - 1);
      const after = source.charAt(position + count);
      if (before.length > 0 && !/\s/.test(before) &&
        !(character === '_' && wordCharacter(after))) return candidate;
    }
    position += count;
  }
  return -1;
}

function appendInline(items: MarkdownInline[], text: string, bold: boolean,
  italic: boolean, code: boolean): void {
  if (!text) return;
  const previous = items.length > 0 ? items[items.length - 1] : undefined;
  if (previous && previous.bold === bold && previous.italic === italic &&
    previous.code === code) {
    previous.text += text;
    return;
  }
  const item: MarkdownInline = { text: text, bold: bold, italic: italic, code: code };
  items.push(item);
}

function inlineParts(source: string, bold: boolean, italic: boolean,
  depth: number, items: MarkdownInline[]): void {
  if (depth >= MAX_INLINE_DEPTH) {
    appendInline(items, source, bold, italic, false);
    return;
  }
  let position = 0;
  let plain = '';
  while (position < source.length && items.length <= MAX_INLINE_SEGMENTS) {
    const current = source.charAt(position);
    if (current === '\\' && position + 1 < source.length &&
      /[\\`*{}\[\]()#+\-.!_|>~]/.test(source.charAt(position + 1))) {
      plain += source.charAt(position + 1);
      position += 2;
      continue;
    }
    if (current === '`') {
      const length = runLength(source, position, '`');
      const end = codeEnd(source, position + length, length);
      if (end >= 0) {
        appendInline(items, plain, bold, italic, false);
        plain = '';
        let content = source.substring(position + length, end).replace(/\n/g, ' ');
        if (content.startsWith(' ') && content.endsWith(' ') && /[^ ]/.test(content)) {
          content = content.substring(1, content.length - 1);
        }
        appendInline(items, content, bold, italic, true);
        position = end + length;
        continue;
      }
      plain += source.substring(position, position + length);
      position += length;
      continue;
    }
    if (current === '*' || current === '_') {
      const length = runLength(source, position, current);
      const after = source.charAt(position + length);
      const before = position > 0 ? source.charAt(position - 1) : '';
      const canOpen = length <= 3 && after.length > 0 && !/\s/.test(after) &&
        !(current === '_' && wordCharacter(before));
      const end = canOpen ? emphasisEnd(source, position + length, current, length) : -1;
      if (end >= 0) {
        appendInline(items, plain, bold, italic, false);
        plain = '';
        inlineParts(source.substring(position + length, end),
          bold || length >= 2, italic || length === 1 || length === 3,
          depth + 1, items);
        position = end + length;
        continue;
      }
      plain += source.substring(position, position + length);
      position += length;
      continue;
    }
    plain += current;
    position += 1;
  }
  // The public entry point replaces excessive segment output with the entire source.
  appendInline(items, plain + source.substring(position), bold, italic, false);
}

export function parseInline(source: string): MarkdownInline[] {
  if (!source) return [];
  if (source.length > MAX_INLINE_LENGTH) return [rawInline(source)];
  const items: MarkdownInline[] = [];
  inlineParts(source, false, false, 0, items);
  return items.length > MAX_INLINE_SEGMENTS ? [rawInline(source)] : items;
}

function tableRow(line: string): TableRow {
  const source = line.trim();
  const cells: string[] = [];
  let content = '';
  let position = 0;
  let hasPipe = false;
  let lastPipe = -1;
  while (position < source.length) {
    const current = source.charAt(position);
    if (current === '\\' && position + 1 < source.length) {
      const next = source.charAt(position + 1);
      content += next === '|' ? '|' : current + next;
      position += 2;
      continue;
    }
    if (current === '`') {
      const length = runLength(source, position, '`');
      const end = codeEnd(source, position + length, length);
      if (end >= 0) {
        // GFM table pipe escapes also apply inside inline code spans.
        content += source.substring(position, end + length).replace(/\\\|/g, '|');
        position = end + length;
        continue;
      }
      content += source.substring(position, position + length);
      position += length;
      continue;
    }
    if (current === '|') {
      cells.push(content.trim());
      content = '';
      hasPipe = true;
      lastPipe = position;
    } else {
      content += current;
    }
    position += 1;
  }
  cells.push(content.trim());
  if (source.startsWith('|')) cells.shift();
  if (lastPipe === source.length - 1) cells.pop();
  return { cells: cells, hasPipe: hasPipe };
}

function divider(line: string): boolean {
  return /^ {0,3}(?:(?:\*\s*){3,}|(?:-\s*){3,}|(?:_\s*){3,})$/.test(line);
}

function specialLine(line: string): boolean {
  return /^ {0,3}(?:#{1,6}\s|>|`{3,}|~{3,})/.test(line) ||
    /^\s*(?:[-+*]|\d+[.)])\s+/.test(line) || divider(line);
}

function tryTable(lines: string[], start: number): TableResult | undefined {
  if (start + 1 >= lines.length || lines[start].length > MAX_INLINE_LENGTH ||
    lines[start + 1].length > MAX_INLINE_LENGTH) return undefined;
  const header = tableRow(lines[start]);
  const separator = tableRow(lines[start + 1]);
  if ((!header.hasPipe && !separator.hasPipe) || header.cells.length === 0 ||
    header.cells.length !== separator.cells.length) return undefined;
  const alignments: string[] = [];
  for (let index = 0; index < separator.cells.length; index += 1) {
    const cell = separator.cells[index];
    if (!/^:?-+:?$/.test(cell)) return undefined;
    alignments.push(cell.startsWith(':') && cell.endsWith(':') ? 'center' :
      cell.endsWith(':') ? 'right' : 'left');
  }
  const rows: string[][] = [header.cells];
  let position = start + 2;
  let oversized = header.cells.length > MAX_TABLE_COLUMNS;
  while (position < lines.length && lines[position].trim() && !specialLine(lines[position])) {
    if (lines[position].length > MAX_INLINE_LENGTH) {
      // Keep long body rows in the fallback rather than dropping their content.
      oversized = true;
      position += 1;
      continue;
    }
    const row = tableRow(lines[position]);
    if (row.cells.length > header.cells.length) oversized = true;
    while (row.cells.length < header.cells.length) row.cells.push('');
    if (rows.length < MAX_TABLE_ROWS) rows.push(row.cells);
    else oversized = true;
    position += 1;
  }
  const original = lines.slice(start, position).join('\n');
  if (oversized) return { block: fallback(original), nextLine: position };
  const result = block('table', original);
  result.inlines = [];
  result.rows = rows;
  result.alignments = alignments;
  return { block: result, nextLine: position };
}

function indentation(value: string): number {
  let width = 0;
  for (let index = 0; index < value.length; index += 1) {
    width += value.charAt(index) === '\t' ? 4 : 1;
  }
  return Math.floor(width / 2);
}

export function parseMarkdown(source: string): MarkdownBlock[] {
  if (!source) return [];
  if (source.length > MAX_SOURCE_LENGTH) return [fallback(source)];
  const normalized = source.replace(/\r\n?/g, '\n');
  const lines = normalized.split('\n');
  if (lines.length > MAX_LINES) return [fallback(normalized)];
  const blocks: MarkdownBlock[] = [];
  let position = 0;
  while (position < lines.length) {
    const line = lines[position];
    if (!line.trim()) {
      position += 1;
      continue;
    }
    if (blocks.length >= MAX_BLOCKS) {
      blocks.push(fallback(lines.slice(position).join('\n')));
      break;
    }
    const fence = /^ {0,3}(`{3,}|~{3,})(.*)$/.exec(line);
    if (fence && !(fence[1].charAt(0) === '`' && fence[2].indexOf('`') >= 0)) {
      const character = fence[1].charAt(0);
      const length = fence[1].length;
      const language = fence[2].trim();
      const content: string[] = [];
      position += 1;
      while (position < lines.length) {
        const closing = /^ {0,3}(`+|~+)\s*$/.exec(lines[position]);
        if (closing && closing[1].charAt(0) === character && closing[1].length >= length) {
          position += 1;
          break;
        }
        content.push(lines[position]);
        position += 1;
      }
      blocks.push(block('code', content.join('\n'), 0, language));
      continue;
    }
    const table = tryTable(lines, position);
    if (table) {
      blocks.push(table.block);
      position = table.nextLine;
      continue;
    }
    const heading = /^ {0,3}(#{1,6})\s+(.*)$/.exec(line);
    if (heading) {
      blocks.push(block('heading', heading[2].replace(/\s+#+\s*$/, ''), heading[1].length));
      position += 1;
      continue;
    }
    if (divider(line)) {
      blocks.push(block('divider', line));
      position += 1;
      continue;
    }
    const list = /^(\s*)([-+*]|\d+[.)])\s+(.*)$/.exec(line);
    if (list) {
      blocks.push(block('list', list[3], indentation(list[1]), list[2]));
      position += 1;
      continue;
    }
    const quote = /^ {0,3}((?:>\s*)+)(.*)$/.exec(line);
    if (quote) {
      const level = quote[1].replace(/[^>]/g, '').length;
      blocks.push(block('quote', quote[2], level, '>'));
      position += 1;
      continue;
    }
    const paragraph: string[] = [line];
    position += 1;
    while (position < lines.length && lines[position].trim() && !specialLine(lines[position])) {
      if (tryTable(lines, position)) break;
      paragraph.push(lines[position]);
      position += 1;
    }
    blocks.push(block('paragraph', paragraph.join('\n')));
  }
  return blocks;
}
