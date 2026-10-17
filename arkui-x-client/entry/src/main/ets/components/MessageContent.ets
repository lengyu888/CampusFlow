import { MessageBlock, MessageTableRow, parseMessageBlocks } from '../utils/MessageBlocks';
import { AppTheme } from '../theme/AppTheme';

@Component
export struct MessageContent {
  @Prop @Watch('contentChanged') content: string = '';
  @Prop @Watch('contentChanged') isUser: boolean = false;
  @State private blocks: MessageBlock[] = [];
  @State private hasFormatting: boolean = false;
  @State private contentRevision: number = 0;
  @State private showOriginal: boolean = false;

  aboutToAppear(): void {
    this.contentChanged();
  }

  private contentChanged(): void {
    this.blocks = this.isUser ? [] : parseMessageBlocks(this.content);
    this.hasFormatting = !this.isUser && (this.blocks.length !== 1 ||
      this.blocks[0].kind !== 'paragraph' || this.blocks[0].text !== this.content);
    this.contentRevision++;
    this.showOriginal = false;
  }

  @Builder
  private TableBlock(item: MessageBlock) {
    Column({ space: 8 }) {
      Text(`表格 · ${item.rows.length} 行`).fontSize(12).fontColor(AppTheme.secondary).width('100%')
      ForEach(item.rows, (row: MessageTableRow, rowIndex: number) => {
        Column({ space: 10 }) {
          ForEach(row.cells, (cell: string, column: number) => {
            Column({ space: 3 }) {
              Text(item.headers[column]).fontSize(12).fontColor(AppTheme.secondary)
                .width('100%').wordBreak(WordBreak.BREAK_WORD)
              Text(cell.length > 0 ? cell : '—').fontSize(16).fontColor(AppTheme.ink)
                .width('100%').wordBreak(WordBreak.BREAK_WORD).copyOption(CopyOptions.InApp)
            }.width('100%').alignItems(HorizontalAlign.Start)
          }, (_cell: string, column: number) => `${rowIndex}-${column}`)
        }.width('100%').padding(12).backgroundColor(AppTheme.field).borderRadius(12)
      }, (_row: MessageTableRow, rowIndex: number) => `${rowIndex}`)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  build() {
    Column({ space: 12 }) {
      if (this.isUser || this.showOriginal) {
        Text(this.content).fontSize(16).fontColor(this.isUser ? AppTheme.onAccent : AppTheme.ink)
          .width('100%').wordBreak(WordBreak.BREAK_WORD).copyOption(CopyOptions.InApp)
      } else {
        ForEach(this.blocks, (item: MessageBlock) => {
          if (item.kind === 'table') {
            this.TableBlock(item)
          } else if (item.kind === 'code') {
            Column({ space: 8 }) {
              Text(item.marker.length > 0 ? `代码 · ${item.marker}` : '代码')
                .fontSize(12).fontColor(AppTheme.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
              Text(item.text).fontSize(14).fontFamily('monospace').fontColor(AppTheme.ink)
                .width('100%').wordBreak(WordBreak.BREAK_WORD).copyOption(CopyOptions.InApp)
            }.width('100%').alignItems(HorizontalAlign.Start).padding(12)
              .backgroundColor(AppTheme.field).borderRadius(12)
          } else if (item.kind === 'list') {
            Row({ space: 8 }) {
              Text(item.marker).fontSize(16).fontColor(AppTheme.ink)
                .constraintSize({ maxWidth: '25%' }).wordBreak(WordBreak.BREAK_ALL)
              Text(item.text).fontSize(16).fontColor(AppTheme.ink).layoutWeight(1)
                .wordBreak(WordBreak.BREAK_WORD).copyOption(CopyOptions.InApp)
            }.width('100%').alignItems(VerticalAlign.Top)
          } else {
            Text(item.text).fontSize(item.kind === 'heading' ? 18 : 16)
              .fontWeight(item.kind === 'heading' ? FontWeight.Bold : FontWeight.Normal)
              .fontColor(AppTheme.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
              .copyOption(CopyOptions.InApp)
          }
        }, (_item: MessageBlock, index: number) => `${this.contentRevision}-${index}`)
      }
      if (this.hasFormatting) {
        if (this.showOriginal) {
          Text('长按上方原文可复制完整回答').fontSize(12).fontColor(AppTheme.secondary).width('100%')
        }
        Button({ type: ButtonType.Normal }) {
          Text(this.showOriginal ? '返回排版' : '查看完整原文').fontSize(12).fontColor(AppTheme.accent)
            .width('100%').textAlign(TextAlign.Start)
        }.backgroundColor(Color.Transparent)
          .constraintSize({ minHeight: 48 }).padding({ top: 10, bottom: 10, left: 0, right: 0 })
          .width('100%').onClick(() => this.showOriginal = !this.showOriginal)
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
