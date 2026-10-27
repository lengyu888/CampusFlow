import { AppIcon } from '../components/AppIcon';
import { InfoDisclosure } from '../components/InfoDisclosure';
import { ThemePalette, themePalette } from '../theme/ThemePalette';

// A navigation guide only: opening an entry never submits a task or a model request.
@Component
export struct UsageGuidePage {
  @StorageLink('campusflowThemePalette') private palette: ThemePalette = themePalette('paper-green');
  onBack: () => void = () => {};
  onOpen: (destination: string) => void = () => {};

  @Builder
  private Step(number: string, title: string, description: string, action: string, destination: string) {
    Row({ space: 12 }) {
      Text(number).fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.palette.accent)
        .width(28).height(28).textAlign(TextAlign.Center).backgroundColor(this.palette.accentSoft).borderRadius(14)
      Column({ space: 6 }) {
        Text(title).fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium).fontColor(this.palette.ink).width('100%')
        Text(description).fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
        Button(action).fontSize(this.palette.bodySize).fontColor(this.palette.accent).backgroundColor(Color.Transparent)
          .constraintSize({ minHeight: 44 }).padding({ left: 0, right: 12 }).onClick(() => this.onOpen(destination))
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
    }.width('100%').alignItems(VerticalAlign.Top).padding(16)
  }

  @Builder
  private Link(icon: string, title: string, destination: string) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        AppIcon({ name: icon, iconSize: 20, color: this.palette.accent })
        Text(title).fontSize(this.palette.bodySize).fontColor(this.palette.ink).layoutWeight(1).textAlign(TextAlign.Start)
        AppIcon({ name: 'chevron', iconSize: 14, color: this.palette.secondary })
      }.width('100%')
    }.width('100%').constraintSize({ minHeight: 52 }).padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .backgroundColor(Color.Transparent).borderRadius(0).onClick(() => this.onOpen(destination))
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Button({ type: ButtonType.Normal }) { AppIcon({ name: 'back', iconSize: 22, color: this.palette.accent }) }
          .width(44).height(44).backgroundColor(Color.Transparent).accessibilityText('返回上一页').onClick(() => this.onBack())
        Text('使用指南').fontSize(22).fontWeight(FontWeight.Medium).fontColor(this.palette.ink).layoutWeight(1)
      }.width('100%').padding({ left: 8, right: 20, top: 6, bottom: 6 }).backgroundColor(this.palette.surface)
      Scroll() {
        Column({ space: 20 }) {
          Column({ space: 8 }) {
            Text('安排好，再一步步完成').fontSize(22).fontWeight(FontWeight.Bold).fontColor(this.palette.ink).width('100%')
            Text('今日看接下来做什么，计划管理课程和待办，助手帮你整理安排，校园查询实时服务。')
              .fontSize(this.palette.bodySize).fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
          }.width('100%').alignItems(HorizontalAlign.Start)
          Column() {
            this.Step('1', '准备课表', '首次使用先录入至少一门真实课程。之后可通过订阅或手动编辑更新，核对后保存。', '管理课表', 'timetable')
            Divider().color(this.palette.line).margin({ left: 56, right: 16 })
            this.Step('2', '把目标变成待办', '待办是一件具体要做的事；目标计划把多项待办放在一起。可以手动添加，也可以请助手先生成方案，由你确认保存。', '打开计划', 'tasks')
            Divider().color(this.palette.line).margin({ left: 56, right: 16 })
            this.Step('3', '从今日开始执行', '查看课程与待办，打开任务核对时间和地点。做完后标记完成；想记录投入时间，可以选择开始专注。', '查看今日安排', 'today')
            Divider().color(this.palette.line).margin({ left: 56, right: 16 })
            this.Step('4', '专注计时（可选）', '从任务详情开始，可暂停、继续或结束。结束计时只保存专注记录，任务是否完成仍由你单独确认。', '查看专注记录', 'focus')
            Divider().color(this.palette.line).margin({ left: 56, right: 16 })
            this.Step('5', '回顾完成情况', '按日或周查看已确认的任务完成与专注记录，写下感受，再决定下一步安排。未同步的时间会单独提示。', '打开今日回顾', 'review')
          }.width('100%').backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius).clip(true)
          Column({ space: 8 }) {
            Text('按需开启').fontSize(this.palette.sectionTitle).fontWeight(FontWeight.Medium).fontColor(this.palette.ink).width('100%')
            Column() {
              this.Link('assistant', '助手：描述目标，核对方案', 'agent')
              Divider().color(this.palette.line).margin({ left: 48, right: 16 })
              this.Link('skills', '能力管理：查看用途与权限', 'skills')
              Divider().color(this.palette.line).margin({ left: 48, right: 16 })
              this.Link('classroom', '校园：查询教室、图书馆等服务', 'services')
              Divider().color(this.palette.line).margin({ left: 48, right: 16 })
              this.Link('person', '个人设置：模型、连接与提醒', 'profile')
            }.width('100%').backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius).clip(true)
            InfoDisclosure({ title: '需要先配置什么？', message: '手动管理课表与待办不需要模型 API Key。使用助手前，在个人设置配置模型，并按用途安装相关能力、阅读权限后确认。HDUHelp、系统提醒与语音按需开启；查询校园个人数据前需要连接账号。所有保存和删除仍按页面提示由你核对。' })
          }.width('100%').alignItems(HorizontalAlign.Start)
        }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: 20, right: 20, top: 20, bottom: 32 })
      }.layoutWeight(1).width('100%').align(Alignment.TopStart).scrollBar(BarState.Off)
    }.width('100%').height('100%').backgroundColor(this.palette.canvas)
  }
}
