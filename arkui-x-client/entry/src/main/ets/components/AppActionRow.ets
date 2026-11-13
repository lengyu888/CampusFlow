import { AppIcon } from './AppIcon';
import { ThemePalette, themePalette } from '../theme/ThemePalette';

// Use inside a shared surface group; the row does not create another card.
@Component
export struct AppActionRow {
  @StorageLink('campusflowThemePalette') private palette: ThemePalette = themePalette('paper-green');
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop icon: string = '';
  @Prop detail: string = '';
  @Prop divider: boolean = false;
  @Prop chevron: boolean = true;
  @Prop danger: boolean = false;
  @Prop actionEnabled: boolean = true;
  onAction: () => void = () => {};

  build() {
    Column() {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 10 }) {
          if (this.icon.length > 0) {
            AppIcon({ name: this.icon, iconSize: 21, color: this.danger ? this.palette.danger : this.palette.accent })
              .width(28).height(28)
          }
          Column({ space: 4 }) {
            Text(this.title).fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium)
              .fontColor(this.danger ? this.palette.danger : this.palette.ink)
              .width('100%').textAlign(TextAlign.Start).wordBreak(WordBreak.BREAK_WORD)
            if (this.subtitle.length > 0) {
              Text(this.subtitle).fontSize(this.palette.metaSize).lineHeight(20).fontColor(this.palette.secondary)
                .width('100%').textAlign(TextAlign.Start).wordBreak(WordBreak.BREAK_WORD)
            }
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          if (this.detail.length > 0) {
            Text(this.detail).fontSize(this.palette.metaSize).fontColor(this.palette.secondary)
              .constraintSize({ maxWidth: '30%' }).wordBreak(WordBreak.BREAK_WORD).textAlign(TextAlign.End)
          }
          if (this.chevron) {
            AppIcon({ name: 'chevron', iconSize: 13, color: this.palette.muted })
          }
        }.width('100%')
      }.width('100%').constraintSize({ minHeight: this.subtitle.length > 0 ? 62 : 48 })
        .padding({ left: 16, right: 16, top: 10, bottom: 10 }).backgroundColor(Color.Transparent)
        .borderRadius(0).enabled(this.actionEnabled).accessibilityText(`${this.title}${this.subtitle.length > 0 ? `，${this.subtitle}` : ''}${this.detail.length > 0 ? `，${this.detail}` : ''}`)
        .onClick(() => this.onAction())
      if (this.divider) {
        Divider().color(this.palette.line).strokeWidth(0.5).margin({ left: this.icon.length > 0 ? 56 : 16, right: 16 })
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
