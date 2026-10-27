import { ChatBubble } from './ChatBubble';
import { ThemePalette, themePalette } from '../theme/ThemePalette';

@Preview
@Component
struct MarkdownPreview {
  @StorageLink('campusflowThemePalette') private palette: ThemePalette = themePalette('paper-green');
  private reply: string = '# 校园安排\n\n' +
    '先到 **图书馆**，再去 *自习教室*。带上 `student_id`。\n\n' +
    '> 路线与时间仅用于演示排版，长文本应完整换行。\n\n' +
    '1. 准备资料\n2. 完成复习\n\n' +
    '| 地点 | 时间 |\n| --- | --- |\n| 图书馆 | 14:00–15:00 |\n| 六教 | 15:20–16:30 |\n\n' +
    '## 宽表，可左右滑动\n\n' +
    '| 阶段 | 内容 | 截止时间 | 备注 |\n| :--- | :---: | ---: | --- |\n' +
    '| 第一阶段 | **基础复习** | 10 月 16 日 | 这一格是需要自动换行的较长说明，表头和正文应始终对齐。 |\n' +
    '| 第二阶段 | 真题练习 | 10 月 20 日 | 包含转义竖线 a\\|b |\n\n' +
    '```ets\n# this stays inside code\n  const label = "**keep these symbols**";\n' +
    '  const route = "library -> classroom -> canteen -> dormitory";\n\n' +
    '  console.info(label);\n```\n\n---\n\n以上内容应与历史会话显示一致。';

  build() {
    Scroll() {
      Column({ space: 14 }) {
        Text('Markdown 气泡预览').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.palette.ink).width('100%')
        ChatBubble({ role: 'user', content: '我输入的 **符号**、`code` 和 | 分隔符应该原样保留。' })
        ChatBubble({ role: 'assistant', content: this.reply })
        ChatBubble({ role: 'assistant', content: '历史气泡：**同一渲染组件**。', uniformCorners: true })
      }.width('100%').padding(16)
    }.width('100%').height('100%').backgroundColor(this.palette.canvas)
  }
}
