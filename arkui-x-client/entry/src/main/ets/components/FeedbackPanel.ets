import { AppIcon } from './AppIcon';
import { AppTheme } from '../theme/AppTheme';
import { ThemePalette, themePalette } from '../theme/ThemePalette';

// Unknown means the result needs checking; it must never look like confirmed success.
@Component
export struct FeedbackPanel {
  @StorageLink('campusflowThemePalette') private palette: ThemePalette = themePalette('paper-green');
  @Prop kind: string = 'info';
  @Prop title: string = '';
  @Prop message: string = '';
  @Prop actionLabel: string = '';
  @Prop busy: boolean = false;
  onAction: () => void = () => {};

  private color(): string {
    if (this.kind === 'error') { return this.palette.danger; }
    if (this.kind === 'success') { return this.palette.success; }
    if (this.kind === 'warning' || this.kind === 'unknown') { return this.palette.warning; }
    return this.palette.secondary;
  }

  private panelBackground(): string {
    if (this.kind === 'error') { return this.palette.dangerSoft; }
    if (this.kind === 'success') { return this.palette.successSoft; }
    if (this.kind === 'warning' || this.kind === 'unknown') { return this.palette.warningSoft; }
    return this.palette.surface;
  }

  private panelBorderColor(): string {
    if (this.kind === 'error') { return this.palette.dangerOutline; }
    if (this.kind === 'warning' || this.kind === 'unknown') { return this.palette.warningOutline; }
    return this.palette.line;
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
          LoadingProgress().width(22).height(22).color(this.palette.accent)
        } else {
          AppIcon({ name: this.icon(), iconSize: 22, color: this.color() })
        }
        Text(this.title).fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium)
          .fontColor(this.color()).layoutWeight(1).wordBreak(WordBreak.BREAK_WORD)
      }.width('100%').alignItems(VerticalAlign.Top)
      if (this.message.length > 0) {
        Text(this.message).fontSize(this.palette.metaSize).fontColor(this.color())
          .width('100%').wordBreak(WordBreak.BREAK_WORD)
      }
      if (this.actionLabel.length > 0) {
        Button(this.busy ? '处理中…' : this.actionLabel).width('100%').constraintSize({ minHeight: 48 })
          .fontSize(this.palette.bodySize).fontColor(this.busy ? this.palette.disabledContent :
            (this.kind === 'error' ? this.palette.danger : this.palette.accent))
          .backgroundColor(this.busy ? this.palette.disabledSurface :
            (this.kind === 'error' || this.kind === 'warning' || this.kind === 'unknown' ? this.palette.surface : this.palette.accentSoft))
          .borderRadius(this.palette.controlRadius).enabled(!this.busy).onClick(() => this.onAction())
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(this.palette.cardInset)
      .backgroundColor(this.panelBackground()).borderRadius(this.palette.cardRadius)
      .border({ width: 1, color: this.panelBorderColor() })
  }
}
