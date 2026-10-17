// A deliberately small text renderer: unsupported Markdown remains readable text.
// No HTML, remote images, scripts or navigation are executed from model output.
export interface MessageTableRow {
  cells: string[];
}

export interface MessageBlock {
  kind: string;
  text: string;
  marker: string;
  level: number;
  headers: string[];
  rows: MessageTableRow[];
}

function block(kind: string, text: string = '', marker: string = '', level: number = 0): MessageBlock {
  return { kind: kind, text: text, marker: marker, level: level, headers: [], rows: [] };
}

// Only unambiguous bold-star markers are removed. Underscores may belong to
// identifiers or URLs, so they remain literal. Inline code preserves every byte.
function readableProse(value: string): string {
  return value.replace(/(^|[^A-Za-z0-9_/:])\*\*([^\s*](?:[^*\n]*[^\s*])?)\*\*(?=$|[^A-Za-z0-9_])/g, '$1$2');
}

export function readableInline(value: string): string {
  let result = '';
  let offset = 0;
  while (offset < value.length) {
    const opening = value.indexOf('`', offset);
    if (opening < 0) {
      result += readableProse(value.substring(offset));
      break;
    }
    result += readableProse(value.substring(offset, opening));
    let ticks = 1;
    while (value[opening + ticks] === '`') {
      ticks++;
    }
    let closing = opening + ticks;
    let found = false;
    while (closing < value.length) {
      closing = value.indexOf('`', closing);
      if (closing < 0) {
        break;
      }
      let closingTicks = 1;
      while (value[closing + closingTicks] === '`') {
        closingTicks++;
      }
      if (closingTicks === ticks) {
        found = true;
        break;
      }
      closing += closingTicks;
    }
    if (!found) {
      result += value.substring(opening);
      break;
    }
    result += value.substring(opening + ticks, closing);
    offset = closing + ticks;
  }
  return result;
}

export function tableCells(line: string): string[] {
  let text = line.trim();
  if (text.startsWith('|')) {
    text = text.substring(1);
  }
  if (text.endsWith('|') && !text.endsWith('\\|')) {
    text = text.substring(0, text.length - 1);
  }
  const cells: string[] = [];
  let current = '';
  let inlineTicks = 0;
  for (let index = 0; index < text.length; index++) {
    const char = text[index];
    if (char === '\\' && text[index + 1] === '|') {
      current += '|';
      index++;
    } else if (char === '`') {
      let ticks = 1;
      while (text[index + ticks] === '`') {
        ticks++;
      }
      current += text.substring(index, index + ticks);
      index += ticks - 1;
      inlineTicks = inlineTicks === ticks ? 0 : inlineTicks === 0 ? ticks : inlineTicks;
    } else if (char === '|' && inlineTicks === 0) {
      cells.push(current.trim());
      current = '';
    } else {
      current += char;
    }
  }
  cells.push(current.trim());
  return cells;
}

function isTableStart(lines: string[], index: number): boolean {
  if (index + 1 >= lines.length || !lines[index].includes('|')) {
    return false;
  }
  const headers = tableCells(lines[index]);
  const separators = tableCells(lines[index + 1]);
  return headers.length > 1 && headers.length === separators.length &&
    separators.every((cell: string) => /^:?-{3,}:?$/.test(cell));
}

export function parseMessageBlocks(value: string): MessageBlock[] {
  const lines = value.replace(/\r\n?/g, '\n').split('\n');
  const blocks: MessageBlock[] = [];
  let paragraphs: string[] = [];
  let index = 0;
  while (index < lines.length) {
    const line = lines[index];
    const candidateFence = line.match(/^ {0,3}(`{3,}|~{3,})(.*)$/);
    const fence = candidateFence !== null &&
      (candidateFence[1][0] !== '`' || !candidateFence[2].includes('`')) ? candidateFence : null;
    const heading = line.match(/^\s{0,3}(#{1,6})\s+(.+)$/);
    const list = line.match(/^\s{0,6}([-+*]|\d{1,9}[.)])\s+(.+)$/);
    const table = isTableStart(lines, index);
    const blank = line.trim().length === 0;
    if ((fence !== null || heading !== null || list !== null || table || blank) && paragraphs.length > 0) {
      blocks.push(block('paragraph', readableInline(paragraphs.join('\n'))));
      paragraphs = [];
    }
    if (fence !== null) {
      const content: string[] = [];
      const delimiter = fence[1];
      index++;
      while (index < lines.length) {
        const closing = lines[index].match(/^ {0,3}(`+|~+)[ \t]*$/);
        if (closing !== null && closing[1].length >= delimiter.length && closing[1][0] === delimiter[0]) {
          index++;
          break;
        }
        content.push(lines[index]);
        index++;
      }
      blocks.push(block('code', content.join('\n'), fence[2].trim()));
      continue;
    }
    if (table) {
      const start = index;
      const headers = tableCells(line);
      const rows: MessageTableRow[] = [];
      let valid = true;
      index += 2;
      while (index < lines.length && lines[index].trim().length > 0 && lines[index].includes('|') &&
        !/^\s{0,3}(`{3,}|~{3,})/.test(lines[index])) {
        const cells = tableCells(lines[index]);
        if (cells.length !== headers.length) {
          valid = false;
        }
        rows.push({ cells: cells.map((cell: string) => readableInline(cell)) });
        index++;
      }
      if (valid && rows.length > 0) {
        const tableBlock = block('table');
        tableBlock.headers = headers.map((header: string, column: number) =>
          header.length > 0 ? readableInline(header) : `第 ${column + 1} 列`);
        tableBlock.rows = rows;
        blocks.push(tableBlock);
      } else {
        // Never discard cells from an irregular or incomplete table.
        blocks.push(block('paragraph', lines.slice(start, index).join('\n')));
      }
      continue;
    }
    if (heading !== null) {
      blocks.push(block('heading', readableInline(heading[2]), '', heading[1].length));
    } else if (list !== null) {
      blocks.push(block('list', readableInline(list[2]), /^\d/.test(list[1]) ? list[1] : '•'));
    } else if (!blank) {
      paragraphs.push(line);
    }
    index++;
  }
  if (paragraphs.length > 0) {
    blocks.push(block('paragraph', readableInline(paragraphs.join('\n'))));
  }
  return blocks;
}
