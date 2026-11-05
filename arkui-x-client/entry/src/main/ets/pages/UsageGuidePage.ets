import { AppPageHeader } from '../components/AppPageHeader';
import { AppActionRow } from '../components/AppActionRow';
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
    AppActionRow({ title: `${number}  ${title}`, subtitle: description, detail: action, onAction: () => this.onOpen(destination) })
  }

  @Builder
  private Link(icon: string, title: string, destination: string) {
    AppActionRow({ title: title, icon: icon, onAction: () => this.onOpen(destination) })
  }

  build() {
    Column() {
      AppPageHeader({ title: '使用指南', onBack: () => this.onBack() })
      Scroll() {
        Column({ space: 20 }) {
          Column({ space: 8 }) {
            Text('安排好，再一步步完成').fontSize(22).fontWeight(FontWeight.Bold).fontColor(this.palette.ink).width('100%')
            Text('课表 → 计划 → 执行 → 回顾')
              .fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
          }.width('100%').alignItems(HorizontalAlign.Start)
          Column() {
            this.Step('1', '准备课表', '手动录入或订阅导入，核对后保存。', '管理课表', 'timetable')
            Divider().color(this.palette.line).margin({ left: 56, right: 16 })
            this.Step('2', '安排待办', '手动添加，或请助手生成方案后确认。', '打开计划', 'tasks')
            Divider().color(this.palette.line).margin({ left: 56, right: 16 })
            this.Step('3', '开始执行', '看时间与地点，做完后标记完成。', '今日安排', 'today')
            Divider().color(this.palette.line).margin({ left: 56, right: 16 })
            this.Step('4', '记录专注', '计时可选；结束计时不会自动完成任务。', '专注记录', 'focus')
            Divider().color(this.palette.line).margin({ left: 56, right: 16 })
            this.Step('5', '回顾与调整', '按日或周查看完成情况与已同步时长。', '今日回顾', 'review')
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
