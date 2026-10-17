import { PlanningOverview, PlanningTask, PlanSummary, TimetableEntry, UserProfile } from '../model/ApiModels';
import { CampusFlowApi } from '../services/CampusFlowApi';
import { AppIcon } from '../components/AppIcon';
import { AppTheme } from '../theme/AppTheme';
import { AgendaRow, DailyAgenda, buildDailyAgenda, labelNext, shanghaiDate, shanghaiTime } from '../utils/DailyAgenda';

@Component
export struct HomePage {
  @Prop baseUrl: string;
  @Prop token: string;
  @Prop user: UserProfile;
  @Watch('refreshToday') @Prop refreshKey: number = 0;
  @Watch('activityChanged') @Prop active: boolean = true;
  onOpenAgent: () => void = () => {};
  onOpenPlan: (view: string) => void = () => {};
  onOpenTaskDetails: (id: string) => void = () => {};
  onOpenPlanDetails: (id: string) => void = () => {};
  onOpenRoute: () => void = () => {};
  onOpenServices: () => void = () => {};
  onOpenProfile: () => void = () => {};
  @State private courses: TimetableEntry[] = [];
  @State private overview: PlanningOverview = {
    plans: [], tasks: [], total_tasks: 0, completed_tasks: 0, due_today: 0, overdue_tasks: 0, progress: 0
  };
  @State private loading: boolean = true;
  @State private errorText: string = '';
  @State private busyTaskId: string = '';
  @State private nowMs: number = Date.now();
  private requestRevision: number = 0;
  private taskOperationRevision: number = 0;
  private pageActive: boolean = true;
  private clockTimer: number = -1;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.pageActive = true;
    this.activityChanged();
  }

  aboutToDisappear(): void {
    this.pageActive = false;
    this.requestRevision++;
    this.taskOperationRevision++;
    this.busyTaskId = '';
    this.stopClock();
  }

  private stopClock(): void {
    if (this.clockTimer !== -1) { clearInterval(this.clockTimer); this.clockTimer = -1; }
  }

  private activityChanged(): void {
    this.stopClock();
    this.requestRevision++;
    this.loading = false;
    if (!this.active || !this.pageActive) { return; }
    this.nowMs = Date.now();
    this.clockTimer = setInterval(() => { this.nowMs = Date.now(); }, 30000);
    this.loadToday();
  }

  private refreshToday(): void {
    if (this.active && this.pageActive) { this.loadToday(); }
  }

  private agenda(): DailyAgenda {
    return buildDailyAgenda(this.courses, this.overview.tasks, this.nowMs);
  }

  private dateLabel(): string {
    const date = shanghaiDate(this.nowMs);
    const day = new Date(`${date}T12:00:00+08:00`).getUTCDay();
    return `${Number(date.substring(5, 7))}月${Number(date.substring(8, 10))}日，周${['日', '一', '二', '三', '四', '五', '六'][day]}`;
  }

  private greeting(): string {
    const hour = Number(shanghaiTime(this.nowMs).substring(0, 2));
    return `${hour < 12 ? '上午好' : (hour < 18 ? '下午好' : '晚上好')}，${this.user.display_name}`;
  }

  private async loadToday(): Promise<void> {
    if (!this.pageActive || !this.active || this.token.length === 0) { return; }
    const revision = ++this.requestRevision;
    const token = this.token;
    const baseUrl = this.baseUrl;
    this.loading = true;
    try {
      const api = new CampusFlowApi(this.baseUrl, this.token);
      const context = await api.context();
      if (!this.isCurrent(revision, token, baseUrl)) { return; }
      const overview = await api.planning();
      if (!this.isCurrent(revision, token, baseUrl)) { return; }
      this.courses = context.timetable;
      this.overview = overview;
      this.nowMs = Date.now();
      this.errorText = '';
    } catch {
      if (this.isCurrent(revision, token, baseUrl)) {
        this.errorText = '暂时未能更新今日安排。已显示的内容可能不是最新，请重试。';
      }
    } finally {
      if (this.isCurrent(revision, token, baseUrl)) { this.loading = false; }
    }
  }

  private isCurrent(revision: number, token: string, baseUrl: string): boolean {
    return this.pageActive && this.active && token.length > 0 && this.token === token && this.baseUrl === baseUrl &&
      revision === this.requestRevision;
  }

  private activePlans(): PlanSummary[] {
    return this.overview.plans.filter((plan: PlanSummary) => plan.status !== 'completed');
  }

  private taskUnscheduledLabel(task: PlanningTask): string {
    if (task.start_at === null || (typeof task.start_at === 'string' && task.start_at.trim().length === 0)) {
      return '尚未安排日期';
    }
    if (typeof task.start_at !== 'string') { return '时间数据异常，请在详情核对。'; }
    return `待核对时间 · ${task.start_at}`;
  }

  private async toggleTask(task: PlanningTask): Promise<void> {
    if (this.busyTaskId.length > 0 || !this.active || !this.pageActive || this.token.length === 0) { return; }
    this.busyTaskId = task.task_id;
    const operation = ++this.taskOperationRevision;
    const token = this.token;
    const baseUrl = this.baseUrl;
    try {
      const api = new CampusFlowApi(this.baseUrl, this.token);
      await api.updateTask(task.task_id, task.status !== 'completed');
      if (this.pageActive && this.active && operation === this.taskOperationRevision &&
        this.token === token && this.baseUrl === baseUrl) {
        // The successful mutation supersedes reads that started before it committed.
        await this.loadToday();
      }
    } catch {
      if (this.pageActive && this.active && operation === this.taskOperationRevision &&
        this.token === token && this.baseUrl === baseUrl) {
        this.errorText = '未能核实待办状态，请重新加载后查看。';
      }
    } finally {
      if (operation === this.taskOperationRevision) { this.busyTaskId = ''; }
    }
  }

  private toggleAgendaTask(row: AgendaRow): void {
    const task = this.overview.tasks.find((item: PlanningTask) => item.task_id === row.taskId);
    if (task !== undefined) { this.toggleTask(task); }
  }

  private nextAction(row: AgendaRow): void {
    if (row.taskId !== null) { this.onOpenTaskDetails(row.taskId); }
    else { this.onOpenRoute(); }
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
          .onClick(() => this.onOpenPlanDetails(plan.plan_id))
      }.width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start).padding(AppTheme.cardInset)
      .backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
  }

  @Builder
  private TaskRow(task: PlanningTask, subtitle: string) {
    Row({ space: 4 }) {
      Button({ type: ButtonType.Normal }) {
        if (task.status === 'completed') {
          AppIcon({ name: 'check', iconSize: 22, color: AppTheme.green })
        } else {
          Circle().width(20).height(20).fill(Color.Transparent).stroke(AppTheme.quiet).strokeWidth(1.5)
        }
      }.width(48).height(48).backgroundColor(Color.Transparent).enabled(this.busyTaskId.length === 0)
        .accessibilityText(`${task.status === 'completed' ? '恢复待办' : '完成'}：${task.title}`)
        .onClick(() => this.toggleTask(task))
      Button({ type: ButtonType.Normal }) {
        Column({ space: 5 }) {
          Text(task.title).fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium)
            .fontColor(task.status === 'completed' ? AppTheme.quiet : AppTheme.ink)
            .width('100%').wordBreak(WordBreak.BREAK_WORD)
          Text(subtitle).fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
            .wordBreak(WordBreak.BREAK_WORD)
        }.width('100%').alignItems(HorizontalAlign.Start)
      }.layoutWeight(1).constraintSize({ minHeight: 60 }).padding({ top: 12, bottom: 12, right: 12 })
        .backgroundColor(Color.Transparent).onClick(() => this.onOpenTaskDetails(task.task_id))
    }.width('100%').padding({ left: 4 })
  }

  @Builder
  private NextCard(row: AgendaRow) {
    Column({ space: 16 }) {
      Row({ space: 12 }) {
        Text(row.startMs <= this.nowMs && row.endMs !== null && row.endMs > this.nowMs ? '正在进行' : '接下来').fontSize(AppTheme.metaSize)
          .fontWeight(FontWeight.Medium).fontColor(AppTheme.quiet).layoutWeight(1)
        Text(labelNext(row, this.nowMs)).fontSize(AppTheme.metaSize).fontColor(AppTheme.actionBlue)
          .padding({ top: 5, bottom: 5, left: 8, right: 8 }).backgroundColor(AppTheme.blueSoft).borderRadius(6)
      }.width('100%')
      Row({ space: 16 }) {
        Column({ space: 6 }) {
          Text(row.startTime).fontSize(28).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
          if (row.date !== this.agenda().today) {
            Text(row.date.substring(5)).fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet)
          }
          if (row.endTime.length > 0) {
            Text(`— ${row.endDate !== row.date ? row.endDate.substring(5) + ' ' : ''}${row.endTime}`)
              .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet)
          }
        }.alignItems(HorizontalAlign.Start)
        Column({ space: 6 }) {
          Text(row.title).fontSize(20).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
            .width('100%').wordBreak(WordBreak.BREAK_WORD)
          Text(row.location.length > 0 ? row.location : (row.kind === 'course' ? '地点未填写' : '待办事项'))
            .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
        }.layoutWeight(1).alignItems(HorizontalAlign.Start).padding({ left: 16 })
          .border({ width: { left: 1 }, color: AppTheme.line })
      }.width('100%').alignItems(VerticalAlign.Top)
      Button({ type: ButtonType.Normal }) {
        Row({ space: 8 }) {
          AppIcon({ name: row.kind === 'course' ? 'route' : 'calendar', iconSize: 19, color: AppTheme.actionBlue })
          Text(row.kind === 'course' ? '选择地点，查看到达路线' : '查看任务详情').fontSize(14)
            .fontColor(AppTheme.actionBlue).layoutWeight(1).wordBreak(WordBreak.BREAK_WORD)
          AppIcon({ name: 'chevron', iconSize: 16, color: AppTheme.actionBlue })
        }.width('100%')
      }.width('100%').constraintSize({ minHeight: 48 }).padding(12)
        .backgroundColor(AppTheme.blueSoft).borderRadius(AppTheme.controlRadius).onClick(() => this.nextAction(row))
    }.width('100%').padding(AppTheme.cardInset).backgroundColor(AppTheme.surface)
      .borderRadius(AppTheme.cardRadius).border({ width: 1, color: AppTheme.line })
  }

  @Builder
  private TimelineRow(row: AgendaRow) {
    Row({ space: 10 }) {
      Column({ space: 5 }) {
        Text(row.startTime).fontSize(14).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink)
        if (row.date !== this.agenda().today) {
          Text(row.date.substring(5)).fontSize(12).fontColor(AppTheme.quiet)
        }
        if (row.endTime.length > 0) {
          Text(`${row.endDate !== row.date ? row.endDate.substring(5) + ' ' : ''}${row.endTime}`)
            .fontSize(12).fontColor(AppTheme.quiet).wordBreak(WordBreak.BREAK_WORD)
        }
      }.width(54).alignItems(HorizontalAlign.Start).padding({ top: 14 })
      Circle().width(6).height(6).fill(row.done ? AppTheme.green : AppTheme.actionBlue).margin({ top: 19 })
      if (row.taskId !== null) {
        Button({ type: ButtonType.Normal }) {
          Column({ space: 5 }) {
            Text(row.title).fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium)
              .fontColor(row.done ? AppTheme.quiet : AppTheme.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
            Text(row.done ? '已完成' : (row.planId !== null ? '来自目标计划' : '待办事项'))
              .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
            if (row.location.length > 0) {
              Text(row.location).fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
                .wordBreak(WordBreak.BREAK_WORD)
            }
          }.width('100%').alignItems(HorizontalAlign.Start)
        }.layoutWeight(1).constraintSize({ minHeight: 64 }).padding({ top: 12, bottom: 12 })
          .backgroundColor(Color.Transparent).onClick(() => this.onOpenTaskDetails(row.taskId ?? ''))
        Button({ type: ButtonType.Normal }) {
          if (row.done) { AppIcon({ name: 'check', iconSize: 21, color: AppTheme.green }) }
          else { Circle().width(20).height(20).fill(Color.Transparent).stroke(AppTheme.quiet).strokeWidth(1.5) }
        }.width(48).height(48).backgroundColor(Color.Transparent).enabled(this.busyTaskId.length === 0)
          .accessibilityText(`${row.done ? '恢复待办' : '完成'}：${row.title}`).onClick(() => this.toggleAgendaTask(row))
      } else {
        Column({ space: 5 }) {
          Text(row.title).fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink)
            .width('100%').wordBreak(WordBreak.BREAK_WORD)
          Text(row.location.length > 0 ? row.location : '课程 · 地点未填写').fontSize(AppTheme.metaSize)
            .fontColor(AppTheme.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
        }.layoutWeight(1).alignItems(HorizontalAlign.Start).padding({ top: 12, bottom: 12 })
      }
    }.width('100%').alignItems(VerticalAlign.Top).padding({ left: 16, right: 8 })
  }

  @Builder
  private SectionTitle(title: string, link: string = '', view: string = 'agenda') {
    Row({ space: 8 }) {
      Text(title).fontSize(AppTheme.sectionTitle).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink).layoutWeight(1)
      if (link.length > 0) {
        Button(link).fontSize(14).fontColor(AppTheme.actionBlue).backgroundColor(Color.Transparent)
          .constraintSize({ minHeight: 48 }).padding(8).onClick(() => this.onOpenPlan(view))
      }
    }.width('100%')
  }

  build() {
    Scroll(this.scroller) {
      Column({ space: AppTheme.sectionGap }) {
        Row({ space: 12 }) {
          Column({ space: 6 }) {
            Text('今日').fontSize(AppTheme.pageTitle).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink).width('100%')
            Text(`${this.dateLabel()} · ${this.greeting()}`).fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet)
              .width('100%').wordBreak(WordBreak.BREAK_WORD)
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Button({ type: ButtonType.Circle }) {
            Text(this.user.display_name.slice(0, 1)).fontSize(18).fontWeight(FontWeight.Medium).fontColor(AppTheme.actionBlue)
          }.width(48).height(48).backgroundColor(AppTheme.blueSoft)
            .accessibilityText('打开个人设置').onClick(() => this.onOpenProfile())
        }.width('100%')
        if (this.errorText.length > 0) {
          Column({ space: 8 }) {
            Text(this.errorText).fontSize(AppTheme.metaSize).fontColor(AppTheme.red).width('100%')
              .wordBreak(WordBreak.BREAK_WORD)
            Button(this.loading ? '正在更新…' : '重新加载').fontSize(14).fontColor(AppTheme.red)
              .width('100%').constraintSize({ minHeight: 48 }).backgroundColor(Color.Transparent)
              .enabled(!this.loading).onClick(() => this.loadToday())
          }.width('100%').padding(AppTheme.cardInset).backgroundColor(AppTheme.redSoft).borderRadius(AppTheme.cardRadius)
        }
        if (this.loading && this.courses.length === 0 && this.overview.tasks.length === 0) {
          Row({ space: 12 }) {
            LoadingProgress().width(22).height(22).color(AppTheme.actionBlue)
            Text('正在读取今日安排…').fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet).layoutWeight(1)
          }.width('100%').padding(AppTheme.cardInset).backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
        } else if (this.agenda().next !== null) {
          this.NextCard(this.agenda().next!)
        } else if (!this.loading && this.errorText.length === 0) {
          Column({ space: 8 }) {
            Text('接下来没有定时安排').fontSize(20).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink).width('100%')
            Text('可以处理待安排事项，或给自己留一点空闲。').fontSize(AppTheme.metaSize)
              .fontColor(AppTheme.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
          }.width('100%').alignItems(HorizontalAlign.Start).padding(AppTheme.cardInset)
            .backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
        }
        Column({ space: 12 }) {
          this.SectionTitle('今天的时间线', '查看日程')
          if (this.agenda().rows.length > 0) {
            Column() {
              ForEach(this.agenda().rows, (row: AgendaRow, index: number) => {
                this.TimelineRow(row)
                if (index < this.agenda().rows.length - 1) {
                  Divider().color(AppTheme.line).margin({ left: 86, right: 16 })
                }
              }, (row: AgendaRow) => `${row.id}-${row.done}`)
            }.width('100%').backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius).clip(true)
          } else {
            Text(this.loading ? '正在更新日程…' : (this.errorText.length > 0 ? '日程暂不可用，请重试。' : '今天没有定时课程或任务'))
              .fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet).width('100%').padding(AppTheme.cardInset)
              .backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius).wordBreak(WordBreak.BREAK_WORD)
          }
          if (this.agenda().allDay.length > 0) {
            Text('今天 · 未指定时刻').fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
            Column() {
              ForEach(this.agenda().allDay, (task: PlanningTask) => {
                this.TaskRow(task, '全天事项，未占用具体时段')
              }, (task: PlanningTask) => `${task.task_id}-${task.status}`)
            }.width('100%').backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
          }
        }.width('100%')
        Column({ space: 12 }) {
          this.SectionTitle('待安排', '全部待办', 'tasks')
          if (this.agenda().unscheduled.length > 0) {
            Column() {
              ForEach(this.agenda().unscheduled.slice(0, 5), (task: PlanningTask) => {
                this.TaskRow(task, this.taskUnscheduledLabel(task))
              }, (task: PlanningTask) => `${task.task_id}-${task.status}`)
            }.width('100%').backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
            if (this.agenda().unscheduled.length > 5) {
              Text(`还有 ${this.agenda().unscheduled.length - 5} 项，可在全部待办中查看`)
                .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
            }
          } else {
            Text(this.loading ? '正在读取待办…' : (this.errorText.length > 0 ? '待办暂不可用，请重试。' : '暂无待安排事项'))
              .fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet).width('100%').padding(AppTheme.cardInset)
              .backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
          }
        }.width('100%')
        Button({ type: ButtonType.Normal }) {
          Row({ space: 12 }) {
            AppIcon({ name: 'agent', iconSize: 24, color: AppTheme.actionBlue })
            Column({ space: 5 }) {
              Text('让 Agent 帮我安排').fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium)
                .fontColor(AppTheme.actionBlue).width('100%')
              Text('结合课表和待办，先预览再确认').fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet)
                .width('100%').wordBreak(WordBreak.BREAK_WORD)
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            AppIcon({ name: 'chevron', iconSize: 16, color: AppTheme.actionBlue })
          }.width('100%')
        }.width('100%').constraintSize({ minHeight: 76 }).padding(AppTheme.cardInset)
          .backgroundColor(AppTheme.blueSoft).borderRadius(AppTheme.cardRadius).onClick(() => this.onOpenAgent())
        Column({ space: 12 }) {
          this.SectionTitle('目标进展', '查看全部', 'goals')
          if (this.activePlans().length > 0) {
            ForEach(this.activePlans().slice(0, 3), (plan: PlanSummary) => {
              this.PlanProgressCard(plan)
            }, (plan: PlanSummary) => `${plan.plan_id}-${plan.status}-${plan.progress}-${plan.completed_count}`)
          } else {
            Text(this.loading ? '正在读取计划…' : (this.errorText.length > 0 ? '计划暂不可用，请重试。' : '还没有进行中的目标，可让 Agent 从一个小目标开始。'))
              .fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet).width('100%').padding(AppTheme.cardInset)
              .backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius).wordBreak(WordBreak.BREAK_WORD)
          }
        }.width('100%')
      }.width('100%').alignItems(HorizontalAlign.Start)
        .padding({ left: AppTheme.pageInset, right: AppTheme.pageInset, top: 20, bottom: 32 })
    }.width('100%').height('100%').backgroundColor(AppTheme.canvas).scrollBar(BarState.Off)
  }
}
