import { MarkdownInline, parseMarkdown } from '../utils/MarkdownParser';
import { MarkdownMessage } from './MarkdownMessage';
import { AppTheme } from '../theme/AppTheme';
import { ThemePalette, themePalette } from '../theme/ThemePalette';

@Component
export struct MessageContent {
  @StorageLink('campusflowThemePalette') private palette: ThemePalette = themePalette('paper-green');
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
    Column({ space: 4 }) {
      if (this.isUser || this.showOriginal) {
        Text(this.content).fontSize(this.palette.bodySize).lineHeight(25)
          .fontColor(this.isUser ? this.palette.onAccent : this.palette.ink)
          .width('100%').wordBreak(WordBreak.BREAK_WORD).copyOption(CopyOptions.InApp)
      } else {
        MarkdownMessage({ content: this.content })
      }
      if (this.hasFormatting) {
        Button({ type: ButtonType.Normal }) {
          Text(this.showOriginal ? '查看排版' : '查看原文').fontSize(this.palette.metaSize).fontColor(this.palette.accent)
            .textAlign(TextAlign.Start)
        }.backgroundColor(Color.Transparent)
          .constraintSize({ minHeight: 44, minWidth: 72 }).padding({ top: 6, bottom: 6, left: 0, right: 12 })
          .accessibilityText(this.showOriginal ? '查看排版；当前原文可长按复制完整内容' : '查看原文，可长按复制完整内容')
          .onClick(() => this.showOriginal = !this.showOriginal)
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
