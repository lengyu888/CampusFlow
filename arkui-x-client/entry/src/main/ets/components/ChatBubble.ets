import { MarkdownMessage } from './MarkdownMessage';

@Component
export struct ChatBubble {
  @Prop role: string = 'assistant';
  @Prop content: string = '';
  @Prop uniformCorners: boolean = false;

  build() {
    Row() {
      if (this.role === 'user') {
        Blank()
        Text(this.content).fontSize(14).fontColor('#FFFFFF').lineHeight(22).copyOption(CopyOptions.InApp)
          .padding(15).constraintSize({ maxWidth: '86%' }).backgroundColor('#315BFF')
          .borderRadius(this.uniformCorners ? { topLeft: 18, topRight: 18, bottomLeft: 18, bottomRight: 18 }
            : { topLeft: 18, topRight: 5, bottomLeft: 18, bottomRight: 18 })
      } else {
        Column() {
          MarkdownMessage({ content: this.content })
        }.width('86%').padding(15).backgroundColor('#FFFFFF')
          .borderRadius(this.uniformCorners ? { topLeft: 18, topRight: 18, bottomLeft: 18, bottomRight: 18 }
            : { topLeft: 5, topRight: 18, bottomLeft: 18, bottomRight: 18 })
        Blank()
      }
    }.width('100%').alignItems(VerticalAlign.Top)
  }
}
