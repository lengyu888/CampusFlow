import { MarkdownBlock, MarkdownInline, parseInline, parseMarkdown } from '../utils/MarkdownParser';

interface MarkdownCell {
  inlines: MarkdownInline[];
  width: number;
  alignment: TextAlign;
}

interface MarkdownRow {
  cells: MarkdownCell[];
  header: boolean;
}

interface RenderBlock {
  id: string;
  source: MarkdownBlock;
  rows: MarkdownRow[];
  tableWidth: number;
  codeLines: string[];
  codeWidth: number;
}

@Component
export struct MarkdownMessage {
  @Prop @Watch('refreshBlocks') content: string = '';
  @State private blocks: RenderBlock[] = [];
  private renderVersion: number = 0;

  aboutToAppear(): void {
    this.refreshBlocks();
  }

  private textUnits(text: string): number {
    let units = 0;
    for (let index = 0; index < text.length; index += 1) {
      const code = text.charCodeAt(index);
      units += code === 9 ? 8 : (code > 255 ? 2 : 1);
    }
    return units;
  }

  private cellAlignment(value: string): TextAlign {
    if (value === 'center') {
      return TextAlign.Center;
    }
    if (value === 'right') {
      return TextAlign.End;
    }
    return TextAlign.Start;
  }

  private refreshBlocks(): void {
    this.renderVersion += 1;
    const next: RenderBlock[] = [];
    parseMarkdown(this.content).forEach((block: MarkdownBlock, blockIndex: number) => {
      const rendered: RenderBlock = {
        id: `${this.renderVersion}-${blockIndex}`,
        source: block,
        rows: [],
        tableWidth: 0,
        codeLines: [],
        codeWidth: 0
      };
      if (block.kind === 'table' && block.rows.length > 0) {
        const columnCount = block.rows[0].length;
        const widths: number[] = [];
        const parsedRows: MarkdownInline[][][] = [];
        for (let column = 0; column < columnCount; column += 1) {
          widths.push(120);
        }
        block.rows.forEach((row: string[]) => {
          const parsedCells: MarkdownInline[][] = [];
          for (let column = 0; column < columnCount; column += 1) {
            const inlines = parseInline(column < row.length ? row[column] : '');
            parsedCells.push(inlines);
            const plainText = inlines.map((inline: MarkdownInline) => inline.text).join('');
            widths[column] = Math.max(widths[column], Math.min(220, this.textUnits(plainText) * 7 + 20));
          }
          parsedRows.push(parsedCells);
        });
        widths.forEach((width: number) => rendered.tableWidth += width);
        parsedRows.forEach((row: MarkdownInline[][], rowIndex: number) => {
          const cells: MarkdownCell[] = [];
          row.forEach((inlines: MarkdownInline[], column: number) => {
            cells.push({
              inlines: inlines,
              width: widths[column],
              alignment: this.cellAlignment(column < block.alignments.length ? block.alignments[column] : 'left')
            });
          });
          rendered.rows.push({ cells: cells, header: rowIndex === 0 });
        });
      } else if (block.kind === 'code') {
        rendered.codeLines = block.text.split('\n');
        rendered.codeWidth = 80;
        rendered.codeLines.forEach((line: string) => {
          rendered.codeWidth = Math.max(rendered.codeWidth, this.textUnits(line) * 8 + 8);
        });
      }
      next.push(rendered);
    });
    this.blocks = next;
  }

  private headingSize(level: number): number {
    if (level === 1) {
      return 22;
    }
    if (level === 2) {
      return 19;
    }
    return level === 3 ? 17 : 15;
  }

  @Builder
  private inlineText(inlines: MarkdownInline[], size: number, forceBold: boolean, alignment: TextAlign) {
    Text() {
      ForEach(inlines, (inline: MarkdownInline) => {
        Span(inline.text)
          .fontWeight(inline.bold || forceBold ? FontWeight.Bold : FontWeight.Normal)
          .fontStyle(inline.italic ? FontStyle.Italic : FontStyle.Normal)
          .fontFamily(inline.code ? 'monospace' : 'sans-serif')
          .fontColor(inline.code ? '#A3422C' : '#272B34')
          .textBackgroundStyle({ color: inline.code ? '#F0F2F6' : Color.Transparent, radius: 3 })
      }, (inline: MarkdownInline, index: number) =>
        `${index}-${inline.text}-${inline.bold}-${inline.italic}-${inline.code}`)
    }
    .fontSize(size).lineHeight(size + 8).textAlign(alignment).width('100%')
      .wordBreak(WordBreak.BREAK_WORD).copyOption(CopyOptions.InApp)
  }

  @Builder
  private table(block: RenderBlock) {
    Scroll() {
      Column() {
        ForEach(block.rows, (row: MarkdownRow) => {
          Row() {
            ForEach(row.cells, (cell: MarkdownCell) => {
              Column() {
                this.inlineText(cell.inlines, 13, row.header, cell.alignment)
              }.width(cell.width).padding({ left: 10, right: 10, top: 9, bottom: 9 })
            }, (cell: MarkdownCell, column: number) => `${column}`)
          }.width(block.tableWidth).alignItems(VerticalAlign.Top)
            .backgroundColor(row.header ? '#EDF1F7' : '#FFFFFF')
            .border({ width: { bottom: 1 }, color: '#DFE5EE' })
        }, (row: MarkdownRow, index: number) => `${index}`)
      }.width(block.tableWidth)
    }
    .scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Auto).width('100%')
      .border({ width: 1, color: '#DFE5EE' }).borderRadius(8).clip(true)
  }

  @Builder
  private code(block: RenderBlock) {
    Column({ space: 5 }) {
      if (block.source.marker.length > 0) {
        Text(block.source.marker).fontSize(10).fontColor('#7B8292').width('100%')
      }
      Scroll() {
        Column() {
          ForEach(block.codeLines, (line: string) => {
            Text(line.length === 0 ? ' ' : line).fontSize(12).lineHeight(20)
              .fontFamily('monospace').fontColor('#272B34').maxLines(1).width('100%').copyOption(CopyOptions.InApp)
          }, (line: string, index: number) => `${index}-${line}`)
        }.width(block.codeWidth).alignItems(HorizontalAlign.Start)
      }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Auto).width('100%')
    }.width('100%').padding(10).backgroundColor('#F1F3F7').borderRadius(8)
  }

  build() {
    Column({ space: 10 }) {
      ForEach(this.blocks, (block: RenderBlock) => {
        if (block.source.kind === 'heading') {
          this.inlineText(block.source.inlines, this.headingSize(block.source.level), true, TextAlign.Start)
        } else if (block.source.kind === 'list') {
          Row({ space: 8 }) {
            Text(block.source.marker === '-' || block.source.marker === '*' || block.source.marker === '+'
              ? '•' : block.source.marker).fontSize(14).lineHeight(22).fontColor('#697083')
            Column() {
              this.inlineText(block.source.inlines, 14, false, TextAlign.Start)
            }.layoutWeight(1)
          }.width('100%').alignItems(VerticalAlign.Top)
            .padding({ left: Math.min(block.source.level, 6) * 12 })
        } else if (block.source.kind === 'quote') {
          Column() {
            this.inlineText(block.source.inlines, 14, false, TextAlign.Start)
          }.width('100%').padding({ left: 12, right: 8, top: 6, bottom: 6 })
            .border({ width: { left: 3 }, color: '#B6C5E5' }).backgroundColor('#F5F7FB')
        } else if (block.source.kind === 'table') {
          this.table(block)
        } else if (block.source.kind === 'code') {
          this.code(block)
        } else if (block.source.kind === 'divider') {
          Divider().color('#DFE5EE').margin({ top: 3, bottom: 3 })
        } else {
          this.inlineText(block.source.inlines, 14, false, TextAlign.Start)
        }
      }, (block: RenderBlock) => block.id)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
