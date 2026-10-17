import {
  PlanningOverview,
  PlanningTask,
  PlanSummary,
  TimetableEntry,
  UserContextResponse,
  UserProfile
} from '../model/ApiModels';
import { CampusFlowApi } from '../services/CampusFlowApi';
import { AppIcon } from '../components/AppIcon';
import { AppTheme } from '../theme/AppTheme';

@Component
export struct HomePage {
  @Prop baseUrl: string;
  @Prop token: string;
  @Prop user: UserProfile;
  @Watch('refreshToday') @Prop refreshKey: number = 0;
  onOpenAgent: () => void = () => {};
  onOpenPlan: () => void = () => {};
  onOpenRoute: () => void = () => {};
  onOpenServices: () => void = () => {};
  onOpenProfile: () => void = () => {};
  @State private courses: TimetableEntry[] = [];
  @State private overview: PlanningOverview = {
    plans: [], tasks: [], total_tasks: 0, completed_tasks: 0, due_today: 0, overdue_tasks: 0, progress: 0
  };
  @State private planDeletePendingId: string = '';
  @State private loading: boolean = true;
  @State private errorText: string = '';

  private refreshToday(): void {
    this.loadToday();
  }

  private dateLabel(): string {
    const now = new Date();
    return `${now.getMonth() + 1}月${now.getDate()}日  星期${['日', '一', '二', '三', '四', '五', '六'][now.getDay()]}`;
  }

  private greeting(): string {
    const hour = new Date().getHours();
    return `${hour < 12 ? '上午好' : (hour < 18 ? '下午好' : '晚上好')}，${this.user.display_name}`;
  }

  aboutToAppear(): void {
    this.loadToday();
  }

  private today(): string {
    const now = new Date();
    const month = `${now.getMonth() + 1}`.padStart(2, '0');
    const day = `${now.getDate()}`.padStart(2, '0');
    return `${now.getFullYear()}-${month}-${day}`;
  }

  private async loadToday(): Promise<void> {
    this.loading = true;
    try {
      const api = new CampusFlowApi(this.baseUrl, this.token);
      const context: UserContextResponse = await api.context();
      const today = this.today();
      this.courses = context.timetable.filter((course) => course.date === today);
      this.overview = await api.planning();
      this.errorText = '';
    } catch (error) {
      this.errorText = `今日数据加载失败：${error}`;
    } finally {
      this.loading = false;
    }
  }

  private activePlans(): PlanSummary[] {
    return this.overview.plans.filter((plan: PlanSummary) => plan.status !== 'completed');
  }

  private todayTasks(): PlanningTask[] {
    const today = this.today();
    return this.overview.tasks.filter((task: PlanningTask) =>
      task.status === 'pending' && (task.start_at === null || task.start_at.substring(0, 10) === today)
    ).slice(0, 5);
  }

  private taskSchedule(task: PlanningTask): string {
    if (task.start_at === null) {
      return '尚未安排日期';
    }
    if (task.source === 'manual' && task.end_at === null) {
      const time = task.start_at.substring(11, 16);
      return time === '23:59' ? task.start_at.substring(0, 10) :
        `${task.start_at.substring(0, 10)} · ${time}`;
    }
    return `${task.start_at.substring(0, 10)} · ${task.start_at.substring(11, 16)}`;
  }

  private async reloadPlanning(): Promise<void> {
    this.overview = await new CampusFlowApi(this.baseUrl, this.token).planning();
  }

  private async toggleTask(task: PlanningTask): Promise<void> {
    try {
      await new CampusFlowApi(this.baseUrl, this.token).updateTask(task.task_id, true);
      await this.reloadPlanning();
      this.errorText = '';
    } catch (error) {
      this.errorText = `待办更新失败：${error}`;
    }
  }

  private async requestDeletePlan(plan: PlanSummary): Promise<void> {
    if (this.planDeletePendingId !== plan.plan_id) {
      this.planDeletePendingId = plan.plan_id;
      return;
    }
    try {
      await new CampusFlowApi(this.baseUrl, this.token).deletePlan(plan.plan_id);
      this.planDeletePendingId = '';
      await this.reloadPlanning();
      this.errorText = '';
    } catch (error) {
      this.errorText = `计划删除失败：${error}`;
    }
  }

  @Builder
  private PlanProgressCard(plan: PlanSummary) {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text(plan.title).fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium)
            .fontColor(AppTheme.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
          Text(plan.target_date === null ? '持续计划' : `目标 ${plan.target_date}`)
            .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Column({ space: 4 }) {
          Text(`${plan.progress}%`).fontSize(24).fontWeight(FontWeight.Bold).fontColor(AppTheme.actionBlue)
          Text(plan.status === 'overdue' ? '已逾期' : '进行中').fontSize(AppTheme.metaSize)
            .fontColor(plan.status === 'overdue' ? AppTheme.red : AppTheme.quiet)
        }.alignItems(HorizontalAlign.End)
      }.width('100%').alignItems(VerticalAlign.Top)
      if (plan.summary.length > 0) {
        Text(plan.summary).fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet)
          .maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
          .wordBreak(WordBreak.BREAK_WORD)
      }
      Row() {
        Row().height(4).width(`${plan.progress}%`).backgroundColor(AppTheme.actionBlue).borderRadius(2)
      }.width('100%').height(4).backgroundColor(AppTheme.line).borderRadius(2)
      Row({ space: 12 }) {
        Text(`${plan.completed_count}/${plan.task_count} 项完成`)
          .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).layoutWeight(1)
        Button({ type: ButtonType.Normal }) {
          Text('查看计划').fontSize(14).fontColor(AppTheme.actionBlue).wordBreak(WordBreak.BREAK_WORD)
        }.constraintSize({ minHeight: 48, minWidth: 80 }).padding({ left: 8, right: 8, top: 8, bottom: 8 })
          .backgroundColor(Color.Transparent).borderRadius(AppTheme.controlRadius)
          .onClick(() => this.onOpenPlan())
      }.width('100%')
      if (plan.status === 'overdue') {
        Button({ type: ButtonType.Normal }) {
          Text(this.planDeletePendingId === plan.plan_id ? '确认删除' : '删除逾期计划')
            .fontSize(14).width('100%').textAlign(TextAlign.Center).wordBreak(WordBreak.BREAK_WORD)
            .fontColor(this.planDeletePendingId === plan.plan_id ? AppTheme.surface : AppTheme.red)
        }.width('100%').constraintSize({ minHeight: 48 }).padding(12)
          .backgroundColor(this.planDeletePendingId === plan.plan_id ? AppTheme.red : AppTheme.redSoft)
          .borderRadius(AppTheme.controlRadius).onClick(() => this.requestDeletePlan(plan))
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(AppTheme.cardInset)
      .backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
  }

  @Builder
  private TodayTaskCard(task: PlanningTask) {
    Row({ space: 8 }) {
      Button({ type: ButtonType.Circle }) {
        Circle().width(24).height(24).fill(Color.Transparent).stroke(AppTheme.quiet).strokeWidth(1.5)
      }.width(48).height(48).backgroundColor(Color.Transparent)
        .accessibilityText(`完成${task.title}`).onClick(() => this.toggleTask(task))
      Column({ space: 4 }) {
        Text(task.title).fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink)
          .width('100%').wordBreak(WordBreak.BREAK_WORD)
        Text(`${task.source === 'agent' ? '计划' : '待办'} · ${this.taskSchedule(task)}`)
          .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
          .wordBreak(WordBreak.BREAK_WORD)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
    }.width('100%').alignItems(VerticalAlign.Center)
      .padding({ left: 8, right: AppTheme.cardInset, top: 8, bottom: 8 })
  }

  @Builder
  private DailyShortcuts() {
    Column({ space: 12 }) {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 12 }) {
          AppIcon({ name: 'agent', iconSize: 24, color: AppTheme.actionBlue })
          Column({ space: 4 }) {
            Text('让 Agent 帮我安排').fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium)
              .fontColor(AppTheme.actionBlue).width('100%').wordBreak(WordBreak.BREAK_WORD)
            Text('结合课表和待办，先预览再确认').fontSize(AppTheme.metaSize)
              .fontColor(AppTheme.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          AppIcon({ name: 'chevron', iconSize: 16, color: AppTheme.actionBlue })
        }.width('100%')
      }.width('100%').constraintSize({ minHeight: 64 }).padding(AppTheme.cardInset)
        .backgroundColor(AppTheme.blueSoft).borderRadius(AppTheme.cardRadius)
        .onClick(() => this.onOpenAgent())
      Row({ space: 12 }) {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 8 }) {
            AppIcon({ name: 'route', iconSize: 20, color: AppTheme.actionBlue })
            Text('校园导航').fontSize(14).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink)
              .layoutWeight(1).wordBreak(WordBreak.BREAK_WORD)
          }.width('100%')
        }.layoutWeight(1).constraintSize({ minHeight: 56 }).padding(12)
          .backgroundColor(AppTheme.surface).borderRadius(AppTheme.controlRadius)
          .accessibilityText('校园导航，查看路线').onClick(() => this.onOpenRoute())
        Button({ type: ButtonType.Normal }) {
          Row({ space: 8 }) {
            AppIcon({ name: 'classroom', iconSize: 20, color: AppTheme.quiet })
            Text('校园服务').fontSize(14).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink)
              .layoutWeight(1).wordBreak(WordBreak.BREAK_WORD)
          }.width('100%')
        }.layoutWeight(1).constraintSize({ minHeight: 56 }).padding(12)
          .backgroundColor(AppTheme.surface).borderRadius(AppTheme.controlRadius)
          .accessibilityText('校园服务，查询教室与生活信息').onClick(() => this.onOpenServices())
      }.width('100%')
    }.width('100%')
  }

  build() {
    Scroll() {
      Column({ space: AppTheme.sectionGap }) {
        Row({ space: 12 }) {
          Column({ space: 4 }) {
            Text('今日').fontSize(AppTheme.pageTitle).fontWeight(FontWeight.Bold)
              .fontColor(AppTheme.ink).width('100%')
            Text(`${this.dateLabel()} · ${this.greeting()}`).fontSize(AppTheme.metaSize)
              .fontColor(AppTheme.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Button({ type: ButtonType.Circle }) {
            Text(this.user.display_name.slice(0, 1)).fontSize(18).fontWeight(FontWeight.Medium)
              .fontColor(AppTheme.actionBlue)
          }.width(48).height(48).backgroundColor(AppTheme.blueSoft)
            .accessibilityText('打开我的账户').onClick(() => this.onOpenProfile())
        }.width('100%').alignItems(VerticalAlign.Center)

        if (this.errorText.length > 0) {
          Column({ space: 8 }) {
            Text(this.errorText).fontSize(AppTheme.metaSize).fontColor(AppTheme.red)
              .width('100%').wordBreak(WordBreak.BREAK_WORD)
            Button({ type: ButtonType.Normal }) {
              Text(this.loading ? '正在更新…' : '重新加载今日数据').fontSize(14)
                .fontColor(AppTheme.red).width('100%').wordBreak(WordBreak.BREAK_WORD)
            }.width('100%').constraintSize({ minHeight: 48 }).padding({ top: 8, bottom: 8 })
              .backgroundColor(Color.Transparent).borderRadius(AppTheme.controlRadius)
              .enabled(!this.loading).onClick(() => this.loadToday())
          }.width('100%').alignItems(HorizontalAlign.Start).padding(AppTheme.cardInset)
            .backgroundColor(AppTheme.redSoft).borderRadius(AppTheme.cardRadius)
        }

        Column({ space: 12 }) {
          Row({ space: 12 }) {
            Text('今日课程').fontSize(AppTheme.sectionTitle).fontWeight(FontWeight.Bold)
              .fontColor(AppTheme.ink).layoutWeight(1)
            Text(this.loading ? '读取中' :
              (this.errorText.length > 0 && this.courses.length === 0 ? '待更新' : `${this.courses.length} 节课`))
              .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet)
          }.width('100%')
          if (this.loading && this.courses.length === 0) {
            Row({ space: 12 }) {
              LoadingProgress().width(20).height(20).color(AppTheme.actionBlue)
              Text('正在读取课程…').fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet).layoutWeight(1)
            }.width('100%').padding(AppTheme.cardInset).backgroundColor(AppTheme.surface)
              .borderRadius(AppTheme.cardRadius)
          } else if (this.courses.length === 0) {
            Text(this.errorText.length > 0 ? '课程暂未显示，请重试。' : '今天没有课程安排')
              .fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet).width('100%')
              .padding(AppTheme.cardInset).backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
          } else {
            Column() {
              ForEach(this.courses, (course: TimetableEntry, index: number) => {
                Column({ space: 4 }) {
                  Text(`${course.start_time} — ${course.end_time}`).fontSize(AppTheme.metaSize)
                    .fontWeight(FontWeight.Medium).fontColor(AppTheme.actionBlue).width('100%')
                  Text(course.title).fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium)
                    .fontColor(AppTheme.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
                  Text(`${course.location}${course.teacher.length > 0 ? ` · ${course.teacher}` : ''}`)
                    .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
                    .wordBreak(WordBreak.BREAK_WORD)
                }.width('100%').alignItems(HorizontalAlign.Start).padding(AppTheme.cardInset)
                if (index < this.courses.length - 1) {
                  Divider().color(AppTheme.line).margin({ left: AppTheme.cardInset, right: AppTheme.cardInset })
                }
              }, (course: TimetableEntry) => `${course.date}-${course.start_time}-${course.title}`)
            }.width('100%').backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius).clip(true)
          }
        }.width('100%')

        Column({ space: 12 }) {
          Row({ space: 12 }) {
            Column({ space: 4 }) {
              Text('待办事项').fontSize(AppTheme.sectionTitle).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
                .width('100%')
              Text('今日与未安排日期').fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Button({ type: ButtonType.Normal }) {
              Text('添加').fontSize(14).fontWeight(FontWeight.Medium).fontColor(AppTheme.actionBlue)
            }.constraintSize({ minHeight: 48, minWidth: 64 }).padding(8)
              .backgroundColor(Color.Transparent).borderRadius(AppTheme.controlRadius)
              .onClick(() => this.onOpenPlan())
          }.width('100%')
          if (this.loading && this.todayTasks().length === 0) {
            Text('正在读取待办…').fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet).width('100%')
              .padding(AppTheme.cardInset).backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
          } else if (this.todayTasks().length === 0) {
            Row({ space: 12 }) {
              AppIcon({ name: this.errorText.length > 0 ? 'calendar' : 'check', iconSize: 20,
                color: this.errorText.length > 0 ? AppTheme.quiet : AppTheme.green })
              Text(this.errorText.length > 0 ? '待办暂未显示，请重试。' : '今天没有待执行事项')
                .fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet).layoutWeight(1)
                .wordBreak(WordBreak.BREAK_WORD)
            }.width('100%').padding(AppTheme.cardInset).backgroundColor(AppTheme.surface)
              .borderRadius(AppTheme.cardRadius)
          } else {
            Column() {
              ForEach(this.todayTasks(), (task: PlanningTask, index: number) => {
                this.TodayTaskCard(task)
                if (index < this.todayTasks().length - 1) {
                  Divider().color(AppTheme.line).margin({ left: 64, right: AppTheme.cardInset })
                }
              }, (task: PlanningTask, index: number) =>
                `${task.task_id}-${task.status}-${task.completed_at ?? ''}-${index}-${this.todayTasks().length}`)
              if (this.todayTasks().length === 5) {
                Button({ type: ButtonType.Normal }) {
                  Text('查看全部待办').fontSize(14).fontColor(AppTheme.actionBlue).width('100%')
                }.width('100%').constraintSize({ minHeight: 48 }).padding(12)
                  .backgroundColor(Color.Transparent).onClick(() => this.onOpenPlan())
              }
            }.width('100%').backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius).clip(true)
          }
        }.width('100%')

        this.DailyShortcuts()

        Column({ space: 12 }) {
          Row({ space: 12 }) {
            Text('计划进展').fontSize(AppTheme.sectionTitle).fontWeight(FontWeight.Bold)
              .fontColor(AppTheme.ink).layoutWeight(1)
            Text(this.loading ? '读取中' :
              (this.errorText.length > 0 && this.activePlans().length === 0 ? '待更新' : `${this.activePlans().length} 个计划`))
              .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet)
          }.width('100%')
          if (this.loading && this.activePlans().length === 0) {
            Text('正在读取计划…').fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet).width('100%')
              .padding(AppTheme.cardInset).backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
          } else if (this.activePlans().length === 0) {
            Button({ type: ButtonType.Normal }) {
              Row({ space: 12 }) {
                AppIcon({ name: 'calendar', iconSize: 22, color: AppTheme.actionBlue })
                Column({ space: 4 }) {
                  Text(this.errorText.length > 0 ? '到规划查看安排' : '还没有进行中的计划')
                    .fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink)
                    .width('100%').wordBreak(WordBreak.BREAK_WORD)
                  Text('查看任务，或添加一个目标').fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet)
                    .width('100%').wordBreak(WordBreak.BREAK_WORD)
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                AppIcon({ name: 'chevron', iconSize: 16, color: AppTheme.quiet })
              }.width('100%')
            }.width('100%').constraintSize({ minHeight: 64 }).padding(AppTheme.cardInset)
              .backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
              .onClick(() => this.onOpenPlan())
          } else {
            ForEach(this.activePlans(), (plan: PlanSummary) => {
              this.PlanProgressCard(plan)
            }, (plan: PlanSummary) => `${plan.plan_id}-${plan.status}-${plan.progress}-${plan.completed_count}-${this.planDeletePendingId}`)
          }
        }.width('100%')
      }.width('100%').alignItems(HorizontalAlign.Start)
        .padding({ left: AppTheme.pageInset, right: AppTheme.pageInset, top: 16, bottom: 32 })
    }.width('100%').height('100%').backgroundColor(AppTheme.canvas).scrollBar(BarState.Off)
  }
}
