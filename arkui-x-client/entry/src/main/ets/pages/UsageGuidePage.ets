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
  private Step(number: string, title: string, description: string, destination: string) {
    AppActionRow({ title: `${number}  ${title}`, subtitle: description, onAction: () => this.onOpen(destination) })
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
          Column() {
            this.Step('1', '准备课表', '录入或导入课程后核对。', 'timetable')
            Divider().color(this.palette.line).margin({ left: 56, right: 16 })
            this.Step('2', '安排待办', '手动添加，或确认助手的方案。', 'tasks')
            Divider().color(this.palette.line).margin({ left: 56, right: 16 })
            this.Step('3', '开始执行', '查看时间和地点，做完后标记。', 'today')
            Divider().color(this.palette.line).margin({ left: 56, right: 16 })
            this.Step('4', '记录专注', '按需计时，任务完成另行确认。', 'focus')
            Divider().color(this.palette.line).margin({ left: 56, right: 16 })
            this.Step('5', '回顾与调整', '按日或周查看完成情况与专注时长。', 'review')
          }.width('100%').backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius).clip(true)
          Column({ space: 8 }) {
            Text('按需开启').fontSize(this.palette.sectionTitle).fontWeight(FontWeight.Medium).fontColor(this.palette.ink).width('100%')
            Column() {
              this.Link('assistant', '助手', 'agent')
              Divider().color(this.palette.line).margin({ left: 48, right: 16 })
              this.Link('skills', '能力管理', 'skills')
              Divider().color(this.palette.line).margin({ left: 48, right: 16 })
              this.Link('classroom', '校园服务', 'services')
              Divider().color(this.palette.line).margin({ left: 48, right: 16 })
              this.Link('person', '个人设置', 'profile')
            }.width('100%').backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius).clip(true)
            InfoDisclosure({ title: '配置与权限', message: '在个人设置配置模型，按用途安装助手能力。连接 HDUHelp 后可查询个人校园数据。提醒和语音可按需开启。' })
          }.width('100%').alignItems(HorizontalAlign.Start)
        }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: 20, right: 20, top: 20, bottom: 32 })
      }.layoutWeight(1).width('100%').align(Alignment.TopStart).scrollBar(BarState.Off)
    }.width('100%').height('100%').backgroundColor(this.palette.canvas)
  }
}
