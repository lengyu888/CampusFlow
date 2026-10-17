import { AppIcon } from './AppIcon';
import { AppTheme } from '../theme/AppTheme';

// Unknown means the result needs checking; it must never look like confirmed success.
@Component
export struct FeedbackPanel {
  @Prop kind: string = 'info';
  @Prop title: string = '';
  @Prop message: string = '';
  @Prop actionLabel: string = '';
  @Prop busy: boolean = false;
  onAction: () => void = () => {};

  private color(): string {
    if (this.kind === 'error') { return AppTheme.danger; }
    if (this.kind === 'success') { return AppTheme.success; }
    if (this.kind === 'warning' || this.kind === 'unknown') { return AppTheme.warning; }
    return AppTheme.secondary;
  }

  private background(): string {
    if (this.kind === 'error') { return AppTheme.dangerSoft; }
    if (this.kind === 'success') { return AppTheme.successSoft; }
    if (this.kind === 'warning' || this.kind === 'unknown') { return AppTheme.warningSoft; }
    return AppTheme.surface;
  }

  private borderColor(): string {
    if (this.kind === 'error') { return AppTheme.dangerOutline; }
    if (this.kind === 'warning' || this.kind === 'unknown') { return AppTheme.warningOutline; }
    return AppTheme.line;
  }

  private icon(): string {
    if (this.kind === 'success') { return 'check'; }
    if (this.kind === 'error' || this.kind === 'warning' || this.kind === 'unknown') { return 'warning'; }
    return 'info';
  }

  build() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        if (this.kind === 'loading') {
          LoadingProgress().width(22).height(22).color(AppTheme.accent)
        } else {
          AppIcon({ name: this.icon(), iconSize: 22, color: this.color() })
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
          .fontSize(AppTheme.bodySize).fontColor(this.busy ? AppTheme.disabledContent :
            (this.kind === 'error' ? AppTheme.danger : AppTheme.accent))
          .backgroundColor(this.busy ? AppTheme.disabledSurface :
            (this.kind === 'error' || this.kind === 'warning' || this.kind === 'unknown' ? AppTheme.surface : AppTheme.accentSoft))
          .borderRadius(AppTheme.controlRadius).enabled(!this.busy).onClick(() => this.onAction())
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(AppTheme.cardInset)
      .backgroundColor(this.background()).borderRadius(AppTheme.cardRadius)
      .border({ width: 1, color: this.borderColor() })
  }
}
