import { AppIcon } from './AppIcon';
import { AppTheme } from '../theme/AppTheme';
import { ThemePalette, themePalette } from '../theme/ThemePalette';

@Component
export struct InfoDisclosure {
  @StorageLink('campusflowThemePalette') private palette: ThemePalette = themePalette('paper-green');
  @Prop title: string = '说明';
  @Prop message: string = '';
  @State private expanded: boolean = false;

  build() {
    Column({ space: 0 }) {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 8 }) {
          AppIcon({ name: 'info', iconSize: 16, color: this.palette.quiet })
          Text(this.title).fontSize(this.palette.metaSize).fontColor(this.palette.quiet)
            .layoutWeight(1).textAlign(TextAlign.Start).wordBreak(WordBreak.BREAK_WORD)
          AppIcon({ name: 'chevron', iconSize: 14, color: this.palette.quiet })
            .rotate({ angle: this.expanded ? 90 : 0 })
        }.width('100%')
      }.width('100%').constraintSize({ minHeight: 44 }).padding({ left: 0, right: 0 })
        .backgroundColor(Color.Transparent).borderRadius(8)
        .accessibilityText(`${this.title}，${this.expanded ? '已展开' : '已收起'}`)
        .onClick(() => animateTo({ duration: AppTheme.motion(160), curve: Curve.EaseInOut }, () => {
          this.expanded = !this.expanded;
        }))
      if (this.expanded && this.message.length > 0) {
        Text(this.message).fontSize(this.palette.metaSize).lineHeight(21)
          .fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
          .padding({ left: 24, right: 8, bottom: 12 })
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
