import { MarkdownInline, parseMarkdown } from '../utils/MarkdownParser';
import { MarkdownMessage } from './MarkdownMessage';
import { AppTheme } from '../theme/AppTheme';

@Component
export struct MessageContent {
  @Prop @Watch('contentChanged') content: string = '';
  @Prop @Watch('contentChanged') isUser: boolean = false;
  @State private hasFormatting: boolean = false;
  @State private showOriginal: boolean = false;

  aboutToAppear(): void {
    this.contentChanged();
  }

  private contentChanged(): void {
    const blocks = this.isUser ? [] : parseMarkdown(this.content);
    this.hasFormatting = !this.isUser && this.content.length > 0 && (blocks.length !== 1 ||
      blocks[0].kind !== 'paragraph' || blocks[0].text !== this.content ||
      blocks[0].inlines.some((inline: MarkdownInline) => inline.bold || inline.italic || inline.code));
    this.showOriginal = false;
  }

  build() {
    Column({ space: 12 }) {
      if (this.isUser || this.showOriginal) {
        Text(this.content).fontSize(16).fontColor(this.isUser ? AppTheme.onAccent : AppTheme.ink)
          .width('100%').wordBreak(WordBreak.BREAK_WORD).copyOption(CopyOptions.InApp)
      } else {
        MarkdownMessage({ content: this.content })
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
