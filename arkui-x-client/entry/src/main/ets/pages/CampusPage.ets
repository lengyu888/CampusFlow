import { UserProfile } from '../model/ApiModels';
import { AppIcon } from '../components/AppIcon';
import { AppTheme } from '../theme/AppTheme';

// Shared entry shell. Each entry opens the existing native feature page.
@Component
export struct CampusPage {
  @Prop user: UserProfile;
  onOpenTimetable: () => void = () => {};
  onOpenRoute: () => void = () => {};
  onOpenServices: () => void = () => {};
  onOpenSkills: () => void = () => {};
  onOpenProfile: () => void = () => {};
  onOpenAgent: (prompt: string) => void = () => {};
  private scroller: Scroller = new Scroller();

  @Builder
  private Entry(icon: string, title: string, description: string, action: () => void) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 14 }) {
        AppIcon({ name: icon, iconSize: 24, color: AppTheme.actionBlue })
        Column({ space: 5 }) {
          Text(title).fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium)
            .fontColor(AppTheme.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
          Text(description).fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet)
            .width('100%').wordBreak(WordBreak.BREAK_WORD)
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        AppIcon({ name: 'chevron', iconSize: 16, color: AppTheme.quiet })
      }.width('100%')
    }.width('100%').constraintSize({ minHeight: 84 }).padding(AppTheme.cardInset)
      .backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
      .accessibilityText(`${title}，${description}`).onClick(action)
  }

  build() {
    Scroll(this.scroller) {
      Column({ space: AppTheme.sectionGap }) {
        Row({ space: 12 }) {
          Column({ space: 6 }) {
            Text('校园').fontSize(AppTheme.pageTitle).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
            Text(`${this.user.school ?? '尚未配置学校'} · ${this.user.campus ?? '尚未配置校区'}`)
              .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
              .wordBreak(WordBreak.BREAK_WORD)
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Button({ type: ButtonType.Circle }) {
            Text(this.user.display_name.slice(0, 1)).fontSize(18).fontColor(AppTheme.actionBlue)
          }.width(48).height(48).backgroundColor(AppTheme.blueSoft)
            .accessibilityText('打开个人设置').onClick(() => this.onOpenProfile())
        }.width('100%')
        Column({ space: 12 }) {
          this.Entry('calendar', '我的课表', '手动维护、预览导入与检查变更', () => this.onOpenTimetable())
          this.Entry('route', '校园导航', '选择地点，查看路线和步行估算', () => this.onOpenRoute())
          this.Entry('classroom', '校园服务', '教室、借阅与个人校园信息', () => this.onOpenServices())
          this.Entry('skills', '能力管理', '查看权限，按需要启用或停用', () => this.onOpenSkills())
          this.Entry('calendar', '数据与连接', '管理课表订阅、校园账号和模型配置', () => this.onOpenProfile())
        }.width('100%')
        Button({ type: ButtonType.Normal }) {
          Row({ space: 12 }) {
            AppIcon({ name: 'agent', iconSize: 24, color: AppTheme.actionBlue })
            Column({ space: 5 }) {
              Text('让 Agent 帮你找').fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium)
                .fontColor(AppTheme.actionBlue).width('100%')
              Text('结合已有课表，先核对再安排').fontSize(AppTheme.metaSize)
                .fontColor(AppTheme.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          }.width('100%')
        }.width('100%').constraintSize({ minHeight: 80 }).padding(AppTheme.cardInset)
          .backgroundColor(AppTheme.blueSoft).borderRadius(AppTheme.cardRadius)
          .onClick(() => this.onOpenAgent('根据我的课表，帮我看看今天需要注意的校园安排。请说明信息来源。'))
        Text('校园信息的覆盖范围以连接的数据源为准。时间安排先预览，确认后再执行。')
          .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
          .wordBreak(WordBreak.BREAK_WORD)
      }.width('100%').alignItems(HorizontalAlign.Start)
        .padding({ left: AppTheme.pageInset, right: AppTheme.pageInset, top: 20, bottom: 32 })
    }.width('100%').height('100%').backgroundColor(AppTheme.canvas).scrollBar(BarState.Off)
  }
}
