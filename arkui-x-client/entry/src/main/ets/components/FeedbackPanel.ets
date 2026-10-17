import { AppIcon } from './AppIcon';
import { AppTheme } from '../theme/AppTheme';

// Shared status semantics: loading never masquerades as an empty successful result.
@Component
export struct FeedbackPanel {
  @Prop kind: string = 'info';
  @Prop title: string = '';
  @Prop message: string = '';
  @Prop actionLabel: string = '';
  @Prop busy: boolean = false;
  onAction: () => void = () => {};

  private color(): string {
    if (this.kind === 'error') { return AppTheme.red; }
    if (this.kind === 'success') { return AppTheme.green; }
    return AppTheme.quiet;
  }

  private background(): string {
    if (this.kind === 'error') { return AppTheme.redSoft; }
    if (this.kind === 'success') { return AppTheme.greenSoft; }
    return AppTheme.surface;
  }

  build() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        if (this.kind === 'loading') {
          LoadingProgress().width(22).height(22).color(AppTheme.actionBlue)
        } else {
          AppIcon({ name: this.kind === 'success' ? 'check' : (this.kind === 'error' ? 'warning' : 'info'),
            iconSize: 22, color: this.color() })
        }
        Text(this.title).fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium)
          .fontColor(this.color()).layoutWeight(1).wordBreak(WordBreak.BREAK_WORD)
      }.width('100%').alignItems(VerticalAlign.Top)
      if (this.message.length > 0) {
        Text(this.message).fontSize(AppTheme.metaSize).fontColor(this.color())
          .width('100%').wordBreak(WordBreak.BREAK_WORD)
      }
      if (this.actionLabel.length > 0) {
        Button(this.busy ? '处理中…' : this.actionLabel).width('100%').constraintSize({ minHeight: 48 })
          .fontSize(AppTheme.bodySize).fontColor(this.kind === 'error' ? AppTheme.red : AppTheme.actionBlue)
          .backgroundColor(this.kind === 'error' ? AppTheme.surface : AppTheme.blueSoft)
          .borderRadius(AppTheme.controlRadius).enabled(!this.busy).onClick(() => this.onAction())
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(AppTheme.cardInset)
      .backgroundColor(this.background()).borderRadius(AppTheme.cardRadius)
      .border({ width: 1, color: this.kind === 'error' ? '#F1D5D1' : AppTheme.line })
  }
}
