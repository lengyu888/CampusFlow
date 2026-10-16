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
    Column({ space: 10 }) {
      Row() {
        Column({ space: 3 }) {
          Text(plan.title).fontSize(16).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink)
          Text(plan.target_date === null ? '持续计划' : `目标 ${plan.target_date}`)
            .fontSize(12).fontColor(AppTheme.secondary)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Column({ space: 3 }) {
          Text(`${plan.progress}%`).fontSize(22).fontWeight(FontWeight.Bold).fontColor(AppTheme.blue)
          Text(plan.status === 'overdue' ? '已逾期' : '进行中').fontSize(12)
            .fontColor(plan.status === 'overdue' ? AppTheme.red : AppTheme.secondary)
        }.alignItems(HorizontalAlign.End)
      }.width('100%')
      if (plan.summary.length > 0) {
        Text(plan.summary).fontSize(14).lineHeight(21).fontColor(AppTheme.secondary).maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      }
      Row() {
        Row().height(5).width(`${plan.progress}%`).backgroundColor(AppTheme.blue).borderRadius(3)
      }.width('100%').height(5).backgroundColor(AppTheme.field).borderRadius(3)
      Row() {
        Text(`${plan.completed_count}/${plan.task_count} 项完成`).fontSize(12).fontColor(AppTheme.secondary)
        Blank()
        if (plan.status === 'overdue') {
          Button(this.planDeletePendingId === plan.plan_id ? '确认删除' : '删除逾期计划')
            .height(44).fontSize(12)
            .fontColor(this.planDeletePendingId === plan.plan_id ? AppTheme.surface : AppTheme.red)
            .backgroundColor(this.planDeletePendingId === plan.plan_id ? AppTheme.red : '#FFF0EE')
            .borderRadius(10).onClick(() => this.requestDeletePlan(plan))
        }
      }.width('100%')
    }.width('100%').padding(18).backgroundColor(AppTheme.surface).borderRadius(18)
  }

  @Builder
  private TodayTaskCard(task: PlanningTask) {
    Row({ space: 12 }) {
      Button({ type: ButtonType.Circle }) {
        Circle().width(24).height(24).fill(Color.Transparent).stroke('#AEAEB2').strokeWidth(1.5)
      }.width(44).height(44).backgroundColor(Color.Transparent)
        .accessibilityText(`完成${task.title}`).onClick(() => this.toggleTask(task))
      Column({ space: 4 }) {
        Text(task.title).fontSize(15).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink)
        Text(this.taskSchedule(task)).fontSize(12).fontColor(AppTheme.secondary)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Text(task.source === 'agent' ? '计划' : '待办').fontSize(11).fontColor(AppTheme.blue)
        .padding({ left: 7, right: 7, top: 3, bottom: 3 }).backgroundColor(AppTheme.blueSoft).borderRadius(8)
    }.width('100%').padding(12).backgroundColor(AppTheme.surface).borderRadius(18)
  }

  build() {
    Scroll() {
      Column({ space: 24 }) {
        Row() {
          Column({ space: 4 }) {
            Text(this.dateLabel()).fontSize(13).fontWeight(FontWeight.Medium).fontColor(AppTheme.secondary)
            Text('今日').fontSize(34).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Button({ type: ButtonType.Circle }) {
            Text(this.user.display_name.slice(0, 1)).fontSize(20).fontWeight(FontWeight.Medium)
              .fontColor(AppTheme.blue)
          }.width(46).height(46).backgroundColor(AppTheme.blueSoft)
            .accessibilityText('打开我的账户').onClick(() => this.onOpenProfile())
        }.width('100%')

        Column({ space: 16 }) {
          Row({ space: 12 }) {
            AppIcon({ name: 'agent', iconSize: 28 })
            Column({ space: 4 }) {
              Text(this.greeting()).fontSize(13).fontColor(AppTheme.secondary)
              Text('把想法变成安排').fontSize(21).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          }.width('100%')
          Text('结合课表和待办，为重要的事留出时间。').fontSize(14).lineHeight(21)
            .fontColor(AppTheme.secondary).width('100%')
          Button('让 Agent 帮我规划').height(46).width('100%').fontSize(15)
            .fontWeight(FontWeight.Medium).fontColor(AppTheme.surface).backgroundColor(AppTheme.blue)
            .borderRadius(14).onClick(() => this.onOpenAgent())
        }.width('100%').padding(20).backgroundColor(AppTheme.surface).borderRadius(22)

        Row({ space: 1 }) {
          Button({ type: ButtonType.Normal }) {
            Row({ space: 10 }) {
              AppIcon({ name: 'route', iconSize: 23 })
              Column({ space: 3 }) {
                Text('校园导航').fontSize(14).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink)
                Text('沿路找到目的地').fontSize(11).fontColor(AppTheme.secondary)
              }.alignItems(HorizontalAlign.Start)
            }
          }.layoutWeight(1).height(78).backgroundColor(AppTheme.surface).borderRadius({ topLeft: 18, bottomLeft: 18 })
            .onClick(() => this.onOpenRoute())
          Divider().vertical(true).height(34).color(AppTheme.separator)
          Button({ type: ButtonType.Normal }) {
            Row({ space: 10 }) {
              AppIcon({ name: 'classroom', iconSize: 23, color: AppTheme.green })
              Column({ space: 3 }) {
                Text('校园服务').fontSize(14).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink)
                Text('教室与生活查询').fontSize(11).fontColor(AppTheme.secondary)
              }.alignItems(HorizontalAlign.Start)
            }
          }.layoutWeight(1).height(78).backgroundColor(AppTheme.surface).borderRadius({ topRight: 18, bottomRight: 18 })
            .onClick(() => this.onOpenServices())
        }.width('100%').backgroundColor(AppTheme.surface).borderRadius(18)

        Column({ space: 12 }) {
          Row() {
            Text('今日课程').fontSize(21).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink).layoutWeight(1)
            Text(`${this.courses.length} 节课`).fontSize(12).fontColor(AppTheme.secondary)
          }.width('100%')
          if (this.loading) {
            Row({ space: 10 }) {
              LoadingProgress().width(22).height(22).color(AppTheme.blue)
              Text('正在同步课程…').fontSize(14).fontColor(AppTheme.secondary)
            }.width('100%').padding(20).backgroundColor(AppTheme.surface).borderRadius(18)
          } else if (this.errorText.length > 0) {
            Text(this.errorText).fontSize(14).fontColor(AppTheme.red).width('100%')
          } else if (this.courses.length === 0) {
            Column({ space: 6 }) {
              Text('今天没有课程').fontSize(16).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink)
              Text('留一段完整时间，做你想做的事。').fontSize(14).fontColor(AppTheme.secondary)
            }.width('100%').alignItems(HorizontalAlign.Start).padding(20)
              .backgroundColor(AppTheme.surface).borderRadius(18)
          } else {
            Column() {
              ForEach(this.courses, (course: TimetableEntry, index: number) => {
                Row({ space: 14 }) {
                  Column({ space: 4 }) {
                    Text(course.start_time).fontSize(16).fontWeight(FontWeight.Medium).fontColor(AppTheme.blue)
                    Text(course.end_time).fontSize(12).fontColor(AppTheme.secondary)
                  }.width(52).alignItems(HorizontalAlign.Start)
                  Column({ space: 5 }) {
                    Text(course.title).fontSize(16).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink)
                    Text(`${course.location}${course.teacher.length > 0 ? ` · ${course.teacher}` : ''}`)
                      .fontSize(12).fontColor(AppTheme.secondary)
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                }.width('100%').padding(18)
                if (index < this.courses.length - 1) {
                  Divider().color(AppTheme.separator).margin({ left: 84 })
                }
              }, (course: TimetableEntry) => `${course.date}-${course.start_time}-${course.title}`)
            }.width('100%').backgroundColor(AppTheme.surface).borderRadius(18).clip(true)
          }
        }.width('100%')

        Column({ space: 12 }) {
          Row() {
            Text('待办事项').fontSize(21).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink).layoutWeight(1)
            Button('添加').height(44).fontSize(14).fontColor(AppTheme.blue)
              .backgroundColor(Color.Transparent).onClick(() => this.onOpenPlan())
          }.width('100%')
          if (this.todayTasks().length === 0) {
            Row({ space: 12 }) {
              AppIcon({ name: 'check', iconSize: 24, color: AppTheme.green })
              Column({ space: 4 }) {
                Text('今天没有待执行事项').fontSize(15).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink)
                Text('新的想法，随时记下来。').fontSize(13).fontColor(AppTheme.secondary)
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            }.width('100%').padding(20).backgroundColor(AppTheme.surface).borderRadius(18)
          } else {
            ForEach(this.todayTasks(), (task: PlanningTask) => {
              this.TodayTaskCard(task)
            }, (task: PlanningTask) => `${task.task_id}-${task.status}-${task.completed_at ?? ''}`)
          }
        }.width('100%')

        Column({ space: 12 }) {
          Row() {
            Text('计划进展').fontSize(21).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink).layoutWeight(1)
            Text(`${this.activePlans().length} 个计划`).fontSize(12).fontColor(AppTheme.secondary)
          }.width('100%')
          if (this.activePlans().length === 0) {
            Button({ type: ButtonType.Normal }) {
              Row({ space: 12 }) {
                AppIcon({ name: 'calendar', iconSize: 25 })
                Column({ space: 5 }) {
                  Text('开始一个小目标').fontSize(16).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink)
                  Text('去规划，把目标拆成下一步。').fontSize(13).fontColor(AppTheme.secondary)
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                AppIcon({ name: 'chevron', iconSize: 16, color: AppTheme.muted })
              }.width('100%')
            }.width('100%').padding(18).backgroundColor(AppTheme.surface).borderRadius(18)
              .onClick(() => this.onOpenPlan())
          } else {
            ForEach(this.activePlans(), (plan: PlanSummary) => {
              this.PlanProgressCard(plan)
            }, (plan: PlanSummary) => `${plan.plan_id}-${plan.status}-${plan.progress}-${plan.completed_count}-${this.planDeletePendingId}`)
          }
        }.width('100%')
      }.width('100%').alignItems(HorizontalAlign.Start)
        .padding({ left: 20, right: 20, top: 16, bottom: 32 })
    }.width('100%').height('100%').backgroundColor(AppTheme.bg).scrollBar(BarState.Off)
  }

}
