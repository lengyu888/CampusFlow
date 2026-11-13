import { AppIcon } from './AppIcon';
import { ThemePalette, themePalette } from '../theme/ThemePalette';

// Shared secondary navigation. Page content owns scrolling and its safe-area inset.
@Component
export struct AppPageHeader {
  @StorageLink('campusflowThemePalette') private palette: ThemePalette = themePalette('paper-green');
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop showBack: boolean = true;
  @Prop backLabel: string = '返回上一页';
  @Prop backEnabled: boolean = true;
  @Prop actionLabel: string = '';
  @Prop actionIcon: string = '';
  @Prop busy: boolean = false;
  onBack: () => void = () => {};
  onAction: () => void = () => {};

  build() {
    Row({ space: 4 }) {
      if (this.showBack) {
        Button({ type: ButtonType.Normal }) {
          AppIcon({ name: 'back', iconSize: 22, color: this.palette.accent })
        }.width(44).height(44).padding(0).backgroundColor(Color.Transparent).borderRadius(12)
          .accessibilityText(this.backLabel).enabled(this.backEnabled).onClick(() => this.onBack())
      }
      Column({ space: 2 }) {
        Text(this.title).fontSize(21).fontWeight(FontWeight.Bold).fontColor(this.palette.ink)
          .width('100%').wordBreak(WordBreak.BREAK_WORD)
        if (this.subtitle.length > 0) {
          Text(this.subtitle).fontSize(this.palette.metaSize).fontColor(this.palette.secondary)
            .width('100%').wordBreak(WordBreak.BREAK_WORD)
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      if (this.actionLabel.length > 0 || this.actionIcon.length > 0) {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 6 }) {
            if (this.busy) {
              LoadingProgress().width(18).height(18).color(this.palette.accent)
            } else if (this.actionIcon.length > 0) {
              AppIcon({ name: this.actionIcon, iconSize: 21, color: this.palette.accent })
            }
            if (this.actionLabel.length > 0) {
              Text(this.actionLabel).fontSize(this.palette.metaSize).fontWeight(FontWeight.Medium).fontColor(this.palette.accent)
            }
          }
        }.constraintSize({ minWidth: 44, minHeight: 44 }).padding({ left: 10, right: 10 })
          .backgroundColor(Color.Transparent).borderRadius(12).enabled(!this.busy)
          .accessibilityText(this.busy ? `${this.actionLabel}，处理中` : this.actionLabel)
          .onClick(() => this.onAction())
      }
    }.width('100%').constraintSize({ minHeight: 56 })
      .padding({ left: this.showBack ? 4 : this.palette.pageInset, right: 10, top: 4, bottom: 4 })
      .backgroundColor(this.palette.surface)
      .border({ width: { bottom: 0.5 }, color: this.palette.line })
  }
}
