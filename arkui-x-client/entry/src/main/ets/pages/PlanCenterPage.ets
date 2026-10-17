import {
  PlanMilestone,
  PlanSummary,
  PlanningOverview,
  PlanningTask,
  TimetableEntry,
  UserContextResponse
} from '../model/ApiModels';
import { CampusFlowApi } from '../services/CampusFlowApi';
import { AppTheme } from '../theme/AppTheme';
import { AppIcon } from '../components/AppIcon';
import { TaskScheduleDetails } from '../components/TaskScheduleDetails';
import { formatPlanDateTime } from '../utils/PlanPresentation';

interface CalendarDay {
  key: string;
  day: number;
  date: string;
  courseCount: number;
  taskCount: number;
}

@Component
export struct PlanCenterPage {
  @Prop baseUrl: string;
  @Prop token: string;
  @Watch('refreshPlanning') @Prop refreshKey: number = 0;
  onOpenAgent: (prompt: string) => void = () => {};
  @State private overview: PlanningOverview = {
    plans: [], tasks: [], total_tasks: 0, completed_tasks: 0, due_today: 0, overdue_tasks: 0, progress: 0
  };
  @State private title: string = '';
  @State private errorText: string = '';
  @State private timetable: TimetableEntry[] = [];
  @State private calendarMonth: number = new Date(new Date().getFullYear(), new Date().getMonth(), 1).getTime();
  @State private selectedDate: string = '';
  @State private draftTaskDate: string = '';
  @State private draftTaskTime: string = '';
  @State private deletePendingId: string = '';
  @State private expandedPlanIds: string[] = [];
  @State private planningRevision: number = 0;
  private taskInputController: TextInputController = new TextInputController();

  aboutToAppear(): void {
    this.selectedDate = this.dateKey(new Date());
    this.draftTaskDate = this.selectedDate;
    this.reload();
    this.loadTimetable();
  }

  private refreshPlanning(): void {
    this.reload();
    this.loadTimetable();
  }

  private dateKey(date: Date): string {
    const month = `${date.getMonth() + 1}`.padStart(2, '0');
    const day = `${date.getDate()}`.padStart(2, '0');
    return `${date.getFullYear()}-${month}-${day}`;
  }

  private monthLabel(): string {
    const date = new Date(this.calendarMonth);
    return `${date.getFullYear()} 年 ${date.getMonth() + 1} 月`;
  }

  private taskDate(task: PlanningTask): string {
    const start = formatPlanDateTime(task.start_at);
    return start.length === 16 ? start.substring(0, 10) : '';
  }

  private taskTime(task: PlanningTask): string {
    if (task.start_at === null) {
      return '待安排';
    }
    const startAt = formatPlanDateTime(task.start_at);
    if (startAt.length !== 16) {
      return '待安排';
    }
    const start = startAt.substring(11, 16);
    if (task.source === 'manual' && task.end_at === null) {
      return start === '23:59' ? '全天' : start;
    }
    if (task.end_at === null) {
      return start;
    }
    const endAt = formatPlanDateTime(task.end_at);
    return startAt.substring(0, 10) === endAt.substring(0, 10) ?
      `${start}–${endAt.substring(11, 16)}` : `${start}–${endAt}`;
  }

  private relativeDate(offset: number): string {
    const date = new Date();
    date.setDate(date.getDate() + offset);
    return this.dateKey(date);
  }

  private selectDraftTime(value: string): void {
    this.getUIContext().animateTo({ duration: AppTheme.motion(180), curve: Curve.EaseOut }, () => {
      if (value.length > 0 && this.draftTaskDate.length === 0) {
        this.draftTaskDate = this.relativeDate(0);
      }
      this.draftTaskTime = value;
    });
  }

  private selectDraftDate(value: string): void {
    this.getUIContext().animateTo({ duration: AppTheme.motion(180), curve: Curve.EaseOut }, () => {
      this.draftTaskDate = value;
      if (value.length === 0) {
        this.draftTaskTime = '';
      }
    });
  }

  private openTimePicker(): void {
    const selected = new Date();
    if (this.draftTaskDate.length > 0) {
      const dateParts = this.draftTaskDate.split('-');
      selected.setFullYear(Number(dateParts[0]), Number(dateParts[1]) - 1, Number(dateParts[2]));
    }
    if (this.draftTaskTime.length > 0) {
      const parts = this.draftTaskTime.split(':');
      selected.setHours(Number(parts[0]), Number(parts[1]), 0, 0);
    }
    this.getUIContext().showTimePickerDialog({
      selected: selected,
      useMilitaryTime: true,
      onAccept: (value: TimePickerResult) => {
        const hour = value.hour === undefined ? selected.getHours() : value.hour;
        const minute = value.minute === undefined ? selected.getMinutes() : value.minute;
        this.selectDraftTime(`${hour.toString().padStart(2, '0')}:${minute.toString().padStart(2, '0')}`);
      }
    });
  }

  private taskOverdue(task: PlanningTask): boolean {
    if (task.status === 'completed' || task.start_at === null) {
      return false;
    }
    return new Date(task.end_at ?? task.start_at).getTime() < Date.now();
  }

  private calendarDays(): CalendarDay[] {
    const month = new Date(this.calendarMonth);
    const year = month.getFullYear();
    const monthIndex = month.getMonth();
    const firstWeekday = new Date(year, monthIndex, 1).getDay();
    const count = new Date(year, monthIndex + 1, 0).getDate();
    const result: CalendarDay[] = [];
    for (let index = 0; index < firstWeekday; index++) {
      result.push({ key: `blank-${index}`, day: 0, date: '', courseCount: 0, taskCount: 0 });
    }
    for (let day = 1; day <= count; day++) {
      const key = this.dateKey(new Date(year, monthIndex, day));
      result.push({
        key: key,
        day: day,
        date: key,
        courseCount: this.timetable.filter((course: TimetableEntry) => course.date === key).length,
        taskCount: this.overview.tasks.filter((task: PlanningTask) => this.taskDate(task) === key).length
      });
    }
    return result;
  }

  private selectedCourses(): TimetableEntry[] {
    return this.timetable.filter((course: TimetableEntry) => course.date === this.selectedDate);
  }

  private selectedTasks(): PlanningTask[] {
    return this.overview.tasks.filter((task: PlanningTask) => this.taskDate(task) === this.selectedDate);
  }

  private unscheduledCount(): number {
    return this.overview.tasks.filter((task: PlanningTask) => task.start_at === null && task.status === 'pending').length;
  }

  private milestoneTasks(planId: string, milestoneId: string): PlanningTask[] {
    return this.overview.tasks.filter((task: PlanningTask) =>
      task.plan_id === planId && task.milestone_id === milestoneId);
  }

  private ungroupedPlanTasks(plan: PlanSummary): PlanningTask[] {
    return this.overview.tasks.filter((task: PlanningTask) => task.plan_id === plan.plan_id &&
      !plan.milestones.some((milestone: PlanMilestone) => milestone.milestone_id === task.milestone_id));
  }

  private togglePlan(planId: string): void {
    this.expandedPlanIds = this.expandedPlanIds.includes(planId)
      ? this.expandedPlanIds.filter((id: string) => id !== planId)
      : this.expandedPlanIds.concat([planId]);
  }

  private planStatus(plan: PlanSummary): string {
    if (plan.status === 'completed') {
      return '已完成';
    }
    return plan.status === 'overdue' ? '已逾期' : '进行中';
  }

  private moveMonth(offset: number): void {
    const month = new Date(this.calendarMonth);
    const next = new Date(month.getFullYear(), month.getMonth() + offset, 1);
    this.getUIContext().animateTo({ duration: AppTheme.motion(180), curve: Curve.EaseOut }, () => {
      this.calendarMonth = next.getTime();
      this.selectedDate = this.dateKey(next);
    });
  }

  private async loadTimetable(): Promise<void> {
    try {
      const context: UserContextResponse = await new CampusFlowApi(this.baseUrl, this.token).context();
      this.timetable = context.timetable;
    } catch (error) {
      this.errorText = `课表加载失败：${error}`;
    }
  }

  private async reload(): Promise<void> {
    try {
      const overview = await new CampusFlowApi(this.baseUrl, this.token).planning();
      this.getUIContext().animateTo({ duration: AppTheme.motion(180), curve: Curve.EaseOut }, () => {
        // 成功刷新后重建计划内容，避免 ForEach 复用旧对象；展开状态仍按计划 ID 保留。
        this.planningRevision++;
        this.overview = overview;
        this.expandedPlanIds = this.expandedPlanIds.filter((id: string) =>
          overview.plans.some((plan: PlanSummary) => plan.plan_id === id));
      });
      this.errorText = '';
    } catch (error) {
      this.errorText = `规划加载失败：${error}`;
    }
  }

  private async addTask(): Promise<void> {
    if (this.title.trim().length === 0) {
      return;
    }
    try {
      const taskTime = this.draftTaskTime.length === 0 ? '23:59' : this.draftTaskTime;
      const startAt = this.draftTaskDate.length === 0 ? null : `${this.draftTaskDate}T${taskTime}:00+08:00`;
      await new CampusFlowApi(this.baseUrl, this.token).createTask(this.title.trim(), startAt);
      this.title = '';
      this.taskInputController.stopEditing();
      await this.reload();
    } catch (error) {
      this.errorText = `创建失败：${error}`;
    }
  }

  private async toggle(task: PlanningTask): Promise<void> {
    try {
      await new CampusFlowApi(this.baseUrl, this.token).updateTask(task.task_id, task.status !== 'completed');
      this.deletePendingId = '';
      await this.reload();
    } catch (error) {
      this.errorText = `更新失败：${error}`;
    }
  }

  private async requestDelete(task: PlanningTask): Promise<void> {
    if (this.deletePendingId !== task.task_id) {
      this.deletePendingId = task.task_id;
      return;
    }
    try {
      await new CampusFlowApi(this.baseUrl, this.token).deleteTask(task.task_id);
      this.deletePendingId = '';
      await this.reload();
    } catch (error) {
      this.errorText = `删除失败：${error}`;
    }
  }

  private planPrompt(): string {
    return '请读取我的课表和未完成待办，为未来 7 天制定一份可执行的学习计划。要求避开课程冲突，拆分里程碑和具体任务，为每项任务设置明确时间、地点与提醒；先展示提案，等我确认后再写入规划。';
  }

  private reviewPrompt(): string {
    return '请结合我的近期课程和未完成任务，安排今天晚上的复习计划。先检查时间冲突，给出具体时间段和提醒，等待我确认后再写入。';
  }

  @Builder
  private DayTimeline() {
    Column({ space: 12 }) {
      Row() {
        Text(this.selectedDate).fontSize(16).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink)
        Blank()
        Text(`${this.selectedCourses().length} 节课 · ${this.selectedTasks().length} 项任务`)
          .fontSize(12).fontColor(AppTheme.secondary)
      }.width('100%')
      if (this.selectedCourses().length === 0 && this.selectedTasks().length === 0) {
        Column({ space: 7 }) {
          AppIcon({ name: 'calendar', iconSize: 28, color: AppTheme.muted })
          Text('这一天，留给你自由安排').fontSize(14).fontColor(AppTheme.secondary)
          Text('选择日期后，可以在下方添加待办').fontSize(12).fontColor(AppTheme.muted)
        }.width('100%').padding({ top: 20, bottom: 20 })
      }
      ForEach(this.selectedCourses(), (course: TimetableEntry) => {
        Row({ space: 12 }) {
          Text(course.start_time).fontSize(14).fontWeight(FontWeight.Medium).fontColor(AppTheme.blue).width(48)
          Column({ space: 5 }) {
            Text(course.title).fontSize(15).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink)
            Text(`${course.location}${course.teacher.length > 0 ? ` · ${course.teacher}` : ''}`)
              .fontSize(12).fontColor(AppTheme.secondary)
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Text('课程').fontSize(11).fontColor(AppTheme.blue).padding({ left: 8, right: 8, top: 5, bottom: 5 })
            .backgroundColor(AppTheme.blueSoft).borderRadius(7)
        }.width('100%').padding(14).backgroundColor(AppTheme.field).borderRadius(14)
      }, (course: TimetableEntry) => `${course.date}-${course.start_time}-${course.title}`)
      ForEach(this.selectedTasks(), (task: PlanningTask) => {
        Row({ space: 10 }) {
          Text(this.taskTime(task)).fontSize(12).fontWeight(FontWeight.Medium).fontColor(AppTheme.orange).width(68)
          Column({ space: 5 }) {
            Text(task.title).fontSize(15).fontWeight(FontWeight.Medium)
              .fontColor(task.status === 'completed' ? AppTheme.muted : AppTheme.ink)
              .decoration({ type: task.status === 'completed' ? TextDecorationType.LineThrough : TextDecorationType.None })
            Text(task.location ?? (task.source === 'agent' ? 'Agent 计划' : '手动创建'))
              .fontSize(12).fontColor(AppTheme.secondary)
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          this.TaskCheck(task)
        }.width('100%').padding(12).backgroundColor(AppTheme.field).borderRadius(14)
      }, (task: PlanningTask) => `${task.task_id}-${task.status}-${task.completed_at ?? ''}`)
    }.width('100%')
  }

  @Builder
  private TaskCheck(task: PlanningTask) {
    Button({ type: ButtonType.Circle }) {
      Stack() {
        Circle().width(25).height(25)
          .fill(task.status === 'completed' ? AppTheme.blue : AppTheme.surface)
          .stroke(task.status === 'completed' ? AppTheme.blue : '#C7C7CC').strokeWidth(1.5)
        if (task.status === 'completed') {
          AppIcon({ name: 'check', iconSize: 15, color: '#FFFFFF' })
        }
      }
    }.width(44).height(44).backgroundColor(Color.Transparent)
      .accessibilityText(task.status === 'completed' ? '标记为未完成' : '标记为完成')
      .onClick(() => this.toggle(task))
  }

  @Builder
  private PlanTask(task: PlanningTask) {
    Column({ space: 8 }) {
      Row({ space: 5 }) {
        this.TaskCheck(task)
        Text(task.title).fontSize(15).lineHeight(22).fontWeight(FontWeight.Medium)
          .fontColor(task.status === 'completed' ? AppTheme.muted : AppTheme.ink)
          .decoration({ type: task.status === 'completed' ?
            TextDecorationType.LineThrough : TextDecorationType.None })
          .layoutWeight(1)
      }.width('100%').alignItems(VerticalAlign.Top)
      TaskScheduleDetails({ startAt: task.start_at, endAt: task.end_at,
        location: task.location, reminderMinutes: task.reminder_minutes })
      if (task.status === 'completed') {
        Text('已完成').fontSize(12).fontColor(AppTheme.secondary).width('100%')
      } else if (this.taskOverdue(task)) {
        Text('已逾期').fontSize(12).fontColor(AppTheme.red).width('100%')
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(12)
      .backgroundColor(AppTheme.field).borderRadius(14)
  }

  @Builder
  private ConfirmedPlans() {
    Column({ space: 12 }) {
      Text('已确认的计划').fontSize(20).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink).width('100%')
      if (this.overview.plans.length === 0) {
        Text('确认 Agent 的计划提案后，可以在这里按里程碑查看全部任务。')
          .fontSize(14).lineHeight(22).fontColor(AppTheme.secondary).width('100%')
          .padding(18).backgroundColor(AppTheme.surface).borderRadius(20)
      }
      ForEach(this.overview.plans, (plan: PlanSummary) => {
        Column({ space: 12 }) {
          Text(plan.title).fontSize(18).lineHeight(26).fontWeight(FontWeight.Bold)
            .fontColor(AppTheme.ink).width('100%')
          Text(`${this.planStatus(plan)} · ${plan.milestones.length} 个里程碑 · ${plan.completed_count}/${plan.task_count} 项已完成`)
            .fontSize(12).lineHeight(19).fontColor(AppTheme.secondary).width('100%')
          Text(plan.target_date === null ? '未设截止日' : `截止 ${plan.target_date}`)
            .fontSize(12).fontColor(AppTheme.secondary).width('100%')
          Button({ type: ButtonType.Normal }) {
            Text(this.expandedPlanIds.includes(plan.plan_id) ? '收起计划详情' : '展开全部里程碑与任务')
              .fontSize(14).fontColor(AppTheme.blue).width('100%').textAlign(TextAlign.Start)
          }.width('100%').constraintSize({ minHeight: 48 }).padding(12)
            .backgroundColor(AppTheme.blueSoft).borderRadius(12)
            .accessibilityText(`${plan.title}，${this.expandedPlanIds.includes(plan.plan_id) ? '已展开，收起计划详情' : '已折叠，展开全部里程碑与任务'}`)
            .onClick(() => this.togglePlan(plan.plan_id))
          if (this.expandedPlanIds.includes(plan.plan_id)) {
            Text('以下时间均为北京时间').fontSize(12).fontColor(AppTheme.secondary).width('100%')
            if (plan.summary.length > 0) {
              Text(plan.summary).fontSize(14).lineHeight(22).fontColor(AppTheme.secondary).width('100%')
            }
            if (plan.milestones.length === 0) {
              Text('此计划尚未设置里程碑。').fontSize(13).fontColor(AppTheme.secondary).width('100%')
            }
            ForEach(plan.milestones, (milestone: PlanMilestone) => {
              Column({ space: 10 }) {
                Divider().color(AppTheme.separator)
                Text(milestone.title).fontSize(16).lineHeight(24).fontWeight(FontWeight.Medium)
                  .fontColor(AppTheme.ink).width('100%')
                Text(`截止：${formatPlanDateTime(milestone.due_at)} · ${milestone.completed_count}/${milestone.task_count} 项已完成`)
                  .fontSize(12).lineHeight(19).fontColor(AppTheme.secondary).width('100%')
                if (this.milestoneTasks(plan.plan_id, milestone.milestone_id).length === 0) {
                  Text('这个里程碑下暂无任务。').fontSize(13).fontColor(AppTheme.secondary).width('100%')
                }
                ForEach(this.milestoneTasks(plan.plan_id, milestone.milestone_id), (task: PlanningTask) => {
                  this.PlanTask(task)
                }, (task: PlanningTask) => `${task.task_id}-${task.status}-${task.completed_at ?? ''}`)
              }.width('100%').alignItems(HorizontalAlign.Start)
            }, (milestone: PlanMilestone) => `${plan.plan_id}-${milestone.milestone_id}`)
            if (this.ungroupedPlanTasks(plan).length > 0) {
              Column({ space: 10 }) {
                Divider().color(AppTheme.separator)
                Text('未归入里程碑的任务').fontSize(16).fontWeight(FontWeight.Medium)
                  .fontColor(AppTheme.ink).width('100%')
                ForEach(this.ungroupedPlanTasks(plan), (task: PlanningTask) => {
                  this.PlanTask(task)
                }, (task: PlanningTask) => `${task.task_id}-${task.status}-${task.completed_at ?? ''}`)
              }.width('100%').alignItems(HorizontalAlign.Start)
            } else if (plan.milestones.length === 0) {
              Text('此计划暂无任务。').fontSize(13).fontColor(AppTheme.secondary).width('100%')
            }
          }
        }.width('100%').alignItems(HorizontalAlign.Start).padding(18)
          .backgroundColor(AppTheme.surface).borderRadius(20)
      }, (plan: PlanSummary) => `${plan.plan_id}-${this.planningRevision}`)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private DateChoice(label: string, value: string) {
    Button(label).height(44).fontSize(12).layoutWeight(1)
      .fontWeight(this.draftTaskDate === value ? FontWeight.Medium : FontWeight.Regular)
      .fontColor(this.draftTaskDate === value ? '#FFFFFF' : AppTheme.secondary)
      .backgroundColor(this.draftTaskDate === value ? AppTheme.blue : AppTheme.field)
      .borderRadius(12).onClick(() => this.selectDraftDate(value))
  }

  @Builder
  private TimeChoice(label: string, value: string) {
    Button(label).height(44).fontSize(12).layoutWeight(1)
      .fontWeight(this.draftTaskTime === value ? FontWeight.Medium : FontWeight.Regular)
      .fontColor(this.draftTaskTime === value ? '#FFFFFF' : AppTheme.secondary)
      .backgroundColor(this.draftTaskTime === value ? AppTheme.blue : AppTheme.field)
      .borderRadius(12).onClick(() => this.selectDraftTime(value))
  }

  build() {
    Scroll() {
      Column({ space: 24 }) {
        Row() {
          Column({ space: 7 }) {
            Text('规划').fontSize(32).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
            Text('让每一天，都有从容的安排').fontSize(14).fontColor(AppTheme.secondary)
          }.alignItems(HorizontalAlign.Start)
          Blank()
          Button({ type: ButtonType.Circle }) {
            AppIcon({ name: 'agent', iconSize: 22, color: AppTheme.blue })
          }.width(46).height(46).backgroundColor(AppTheme.surface)
            .accessibilityText('智能规划').onClick(() => this.onOpenAgent(this.planPrompt()))
        }.width('100%')

        Column({ space: 15 }) {
          Column({ space: 6 }) {
            Text('一起安排下一步').fontSize(19).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
            Text('结合课表和待办，为你留出合适的时间。').fontSize(14).fontColor(AppTheme.secondary)
          }.width('100%').alignItems(HorizontalAlign.Start)
          Row({ space: 10 }) {
            Button('规划这一周').height(44).fontSize(14).fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF').backgroundColor(AppTheme.blue)
              .borderRadius(12).layoutWeight(1).onClick(() => this.onOpenAgent(this.planPrompt()))
            Button('安排今晚复习').height(44).fontSize(14).fontWeight(FontWeight.Medium)
              .fontColor(AppTheme.blue).backgroundColor(AppTheme.blueSoft)
              .borderRadius(12).layoutWeight(1).onClick(() => this.onOpenAgent(this.reviewPrompt()))
          }.width('100%')
          Text('先预览计划，确认后再添加。').fontSize(12).fontColor(AppTheme.muted).width('100%')
        }.width('100%').padding(20).backgroundColor(AppTheme.surface).borderRadius(22)

        this.ConfirmedPlans()

        Column({ space: 16 }) {
          Row() {
            Text(this.monthLabel()).fontSize(20).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
            Blank()
            Button({ type: ButtonType.Circle }) {
              AppIcon({ name: 'back', iconSize: 17, color: AppTheme.blue })
            }.width(44).height(44).backgroundColor(Color.Transparent).accessibilityText('上个月')
              .onClick(() => this.moveMonth(-1))
            Button({ type: ButtonType.Circle }) {
              AppIcon({ name: 'chevron', iconSize: 17, color: AppTheme.blue })
            }.width(44).height(44).backgroundColor(Color.Transparent).accessibilityText('下个月')
              .onClick(() => this.moveMonth(1))
          }.width('100%')
          Row() {
            ForEach(['日', '一', '二', '三', '四', '五', '六'], (label: string) => {
              Text(label).fontSize(12).fontColor(AppTheme.muted).textAlign(TextAlign.Center).layoutWeight(1)
            }, (label: string) => label)
          }.width('100%')
          Grid() {
            ForEach(this.calendarDays(), (item: CalendarDay) => {
              GridItem() {
                if (item.day === 0) {
                  Blank().height(44)
                } else {
                  Column({ space: 3 }) {
                    Text(`${item.day}`).fontSize(15)
                      .fontWeight(this.selectedDate === item.date ? FontWeight.Bold : FontWeight.Regular)
                      .fontColor(this.selectedDate === item.date ? '#FFFFFF' : AppTheme.ink)
                    Row({ space: 3 }) {
                      if (item.courseCount > 0) {
                        Circle().width(4).height(4).fill(this.selectedDate === item.date ? '#FFFFFF' : AppTheme.blue)
                      }
                      if (item.taskCount > 0) {
                        Circle().width(4).height(4).fill(this.selectedDate === item.date ? '#FFFFFF' : AppTheme.orange)
                      }
                    }.height(5)
                  }.width('100%').height(44).justifyContent(FlexAlign.Center)
                    .backgroundColor(this.selectedDate === item.date ? AppTheme.blue : Color.Transparent)
                    .borderRadius(24).onClick(() => {
                      this.getUIContext().animateTo({ duration: AppTheme.motion(180), curve: Curve.EaseOut }, () => {
                        this.selectedDate = item.date;
                      });
                    })
                }
              }
            }, (item: CalendarDay) =>
              `${item.key}-${item.courseCount}-${item.taskCount}-${this.selectedDate}`)
          }.columnsTemplate('repeat(7, 1fr)').columnsGap(1).rowsGap(2).width('100%')
            .height(this.calendarDays().length > 35 ? 274 : 228)
          Divider().color(AppTheme.separator)
          this.DayTimeline()
        }.width('100%').padding(18).backgroundColor(AppTheme.surface).borderRadius(22)

        Row() {
          Column({ space: 7 }) {
            Text(`${this.overview.progress}%`).fontSize(26).fontWeight(FontWeight.Bold).fontColor(AppTheme.blue)
            Text('总体完成进度').fontSize(13).fontColor(AppTheme.secondary)
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Divider().vertical(true).height(45).color(AppTheme.separator).margin({ left: 18, right: 18 })
          Column({ space: 7 }) {
            Text(`${this.overview.due_today}`).fontSize(26).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
            Text(this.overview.overdue_tasks > 0 ? `今日待执行 · ${this.overview.overdue_tasks} 项逾期` : '今日待执行')
              .fontSize(12).fontColor(this.overview.overdue_tasks > 0 ? AppTheme.red : AppTheme.secondary)
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        }.width('100%').padding(20).backgroundColor(AppTheme.surface).borderRadius(20)

        Column({ space: 16 }) {
          Row() {
            Column({ space: 6 }) {
              Text('添加待办').fontSize(20).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
              Text(`${this.unscheduledCount()} 项尚未安排时间`).fontSize(12).fontColor(AppTheme.secondary)
            }.alignItems(HorizontalAlign.Start)
            Blank()
            Text(`${this.overview.completed_tasks}/${this.overview.total_tasks} 已完成`)
              .fontSize(12).fontColor(AppTheme.muted)
          }.width('100%')
          Row({ space: 10 }) {
            TextInput({ text: this.title, placeholder: '快速记录一个待办', controller: this.taskInputController })
              .layoutWeight(1).height(48).fontSize(15).fontColor(AppTheme.ink)
              .backgroundColor(AppTheme.field).borderRadius(13).onChange((value) => this.title = value)
            Button({ type: ButtonType.Circle }) {
              AppIcon({ name: 'plus', iconSize: 22, color: '#FFFFFF' })
            }.width(46).height(46).backgroundColor(AppTheme.blue)
              .accessibilityText('添加待办').onClick(() => this.addTask())
          }.width('100%')
          Row() {
            Text('日期').fontSize(14).fontColor(AppTheme.secondary)
            Blank()
            Text(this.draftTaskDate.length === 0 ? '无日期' : this.draftTaskDate)
              .fontSize(14).fontWeight(FontWeight.Medium).fontColor(AppTheme.blue)
          }.width('100%')
          Row({ space: 6 }) {
            this.DateChoice('今天', this.relativeDate(0))
            this.DateChoice('明天', this.relativeDate(1))
            this.DateChoice('日历所选', this.selectedDate)
            this.DateChoice('无日期', '')
          }.width('100%')
          Row() {
            Text('时间').fontSize(14).fontColor(AppTheme.secondary)
            Blank()
            Text(this.draftTaskTime.length === 0 ? '全天' : this.draftTaskTime)
              .fontSize(14).fontWeight(FontWeight.Medium).fontColor(AppTheme.blue)
          }.width('100%')
          Row({ space: 6 }) {
            this.TimeChoice('全天', '')
            this.TimeChoice('08:00', '08:00')
            this.TimeChoice('14:00', '14:00')
            Button(this.draftTaskTime.length > 0 && this.draftTaskTime !== '08:00' &&
              this.draftTaskTime !== '14:00' ? this.draftTaskTime : '自定义')
              .height(44).fontSize(12).layoutWeight(1).fontColor(AppTheme.blue)
              .backgroundColor(AppTheme.blueSoft).borderRadius(12).onClick(() => this.openTimePicker())
          }.width('100%')
        }.width('100%').padding(18).backgroundColor(AppTheme.surface).borderRadius(22)

        if (this.errorText.length > 0) {
          Text(this.errorText).fontSize(14).fontColor(AppTheme.red).width('100%')
        }

        if (this.overview.tasks.length > 0) {
          Column({ space: 12 }) {
            Text('全部待办').fontSize(20).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink).width('100%')
            Column() {
              ForEach(this.overview.tasks, (task: PlanningTask, index: number) => {
                Row({ space: 8 }) {
                  this.TaskCheck(task)
                  Column({ space: 6 }) {
                    Text(task.title).fontSize(15).fontWeight(FontWeight.Medium)
                      .fontColor(task.status === 'completed' ? AppTheme.muted : AppTheme.ink)
                      .decoration({ type: task.status === 'completed' ?
                        TextDecorationType.LineThrough : TextDecorationType.None })
                    Text(`${this.taskDate(task).length > 0 ? this.taskDate(task) + ' · ' + this.taskTime(task) : '待安排时间'}${task.location === null ? '' : ' · ' + task.location}`)
                      .fontSize(12).fontColor(this.taskOverdue(task) ? AppTheme.red : AppTheme.secondary)
                    if (this.taskOverdue(task)) {
                      Text('已逾期').fontSize(11).fontColor(AppTheme.red)
                    }
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                  Button(this.deletePendingId === task.task_id ? '确认删除' : '删除').height(44).fontSize(12)
                    .fontColor(this.deletePendingId === task.task_id ? '#FFFFFF' : AppTheme.red)
                    .backgroundColor(this.deletePendingId === task.task_id ? AppTheme.red : Color.Transparent)
                    .borderRadius(12).onClick(() => this.requestDelete(task))
                }.width('100%').padding({ left: 8, right: 12, top: 12, bottom: 12 })
                if (index < this.overview.tasks.length - 1) {
                  Divider().color(AppTheme.separator).margin({ left: 60 })
                }
              }, (task: PlanningTask) => `${task.task_id}-${task.status}-${task.completed_at ?? ''}`)
            }.width('100%').backgroundColor(AppTheme.surface).borderRadius(20).clip(true)
          }.width('100%')
        }
      }.width('100%').padding({ left: 20, right: 20, top: 20, bottom: 32 })
    }.width('100%').height('100%').backgroundColor(AppTheme.bg)
  }
}
