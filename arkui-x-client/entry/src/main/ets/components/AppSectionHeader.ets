import { ThemePalette, themePalette } from '../theme/ThemePalette';

@Component
export struct AppSectionHeader {
  @StorageLink('campusflowThemePalette') private palette: ThemePalette = themePalette('paper-green');
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop actionLabel: string = '';
  @Prop actionEnabled: boolean = true;
  onAction: () => void = () => {};

  build() {
    Row({ space: 8 }) {
      Column({ space: 3 }) {
        Text(this.title).fontSize(this.palette.sectionTitle).fontWeight(FontWeight.Bold)
          .fontColor(this.palette.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
        if (this.subtitle.length > 0) {
          Text(this.subtitle).fontSize(this.palette.metaSize).fontColor(this.palette.secondary)
            .width('100%').wordBreak(WordBreak.BREAK_WORD)
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      if (this.actionLabel.length > 0) {
        Button(this.actionLabel).constraintSize({ minHeight: 44 }).fontSize(this.palette.metaSize)
          .fontColor(this.palette.accent).backgroundColor(Color.Transparent)
          .padding({ left: 8, right: 0 }).enabled(this.actionEnabled).onClick(() => this.onAction())
      }
    }.width('100%').constraintSize({ minHeight: 36 })
  }
}
