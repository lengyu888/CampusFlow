import { MarkdownMessage } from './MarkdownMessage';
import { ThemePalette, themePalette } from '../theme/ThemePalette';

@Component
export struct ChatBubble {
  @StorageLink('campusflowThemePalette') private palette: ThemePalette = themePalette('paper-green');
  @Prop role: string = 'assistant';
  @Prop content: string = '';
  @Prop uniformCorners: boolean = false;

  build() {
    Row() {
      if (this.role === 'user') {
        Blank()
        Text(this.content).fontSize(14).fontColor(this.palette.onAccent).lineHeight(22).copyOption(CopyOptions.InApp)
          .padding(15).constraintSize({ maxWidth: '86%' }).backgroundColor(this.palette.accent)
          .borderRadius(this.uniformCorners ? { topLeft: 18, topRight: 18, bottomLeft: 18, bottomRight: 18 }
            : { topLeft: 18, topRight: 5, bottomLeft: 18, bottomRight: 18 })
      } else {
        Column() {
          MarkdownMessage({ content: this.content })
        }.width('86%').padding(15).backgroundColor(this.palette.surface)
          .borderRadius(this.uniformCorners ? { topLeft: 18, topRight: 18, bottomLeft: 18, bottomRight: 18 }
            : { topLeft: 5, topRight: 18, bottomLeft: 18, bottomRight: 18 })
        Blank()
      }
    }.width('100%').alignItems(VerticalAlign.Top)
  }
}
