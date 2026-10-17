import {
  PendingAction,
  PlanningTaskDraft,
  PlanningActionRequest,
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
import { PlanningActionController, PlanningActionState, editedPlanningTime, validPlanningDate, planningTimestamp } from '../utils/PlanningAction';
import { PlanningActionPanel } from '../components/PlanningActionPanel';
import { PlanningConflictsPanel } from '../components/PlanningConflictsPanel';
import { CampusFlowRequestError } from '../utils/AgentFeedback';
import { formatPlanDateTime } from '../utils/PlanPresentation';
import { AgendaRow, DailyAgenda, buildDailyAgenda, shanghaiDate } from '../utils/DailyAgenda';

interface CalendarDay {
  key: string;
  day: number;
  date: string;
  courseCount: number;
  taskCount: number;
}

interface PlanningTimelineItem {
  key: string;
  kind: string;
  time: string;
  title: string;
  detail: string;
  taskId: string;
  completed: boolean;
}

interface PlanningDetailFrame {
  key: number;
  kind: string;
  id: string;
  external: boolean;
}

@Component
export struct PlanCenterPage {
  @Prop baseUrl: string;
  @Prop token: string;
  @Watch('refreshPlanning') @Prop refreshKey: number = 0;
  @Watch('activityChanged') @Prop active: boolean = true;
  @Prop focusTaskId: string = '';
  @Prop focusPlanId: string = '';
  @Watch('focusChanged') @Prop focusRevision: number = 0;
  @Watch('backRequested') @Prop backRevision: number = 0;
  @Prop requestedView: string = '';
  @Watch('viewRequested') @Prop viewRevision: number = 0;
  onCloseFocus: () => void = () => {};
  onInnerNavigationChanged: (active: boolean) => void = () => {};
  onOpenAgent: (prompt: string) => void = () => {};
  onPlanningChanged: () => void = () => {};
  @State private overview: PlanningOverview = {
    plans: [], tasks: [], total_tasks: 0, completed_tasks: 0, due_today: 0, overdue_tasks: 0, progress: 0
  };
  @State private title: string = '';
  @State private errorText: string = '';
  @State private timetable: TimetableEntry[] = [];
  @State private calendarMonth: number = new Date(new Date().getFullYear(), new Date().getMonth(), 1).getTime();
  @State private selectedDate: string = '';
  @State private draftTaskDate: string = '';
  @State private draftDateChoice: string = 'today';
  @State private draftTaskTime: string = '';
  @State private calendarExpanded: boolean = false;
  @State private taskFormExpanded: boolean = false;
  @State private deletePendingId: string = '';
  @State private expandedPlanIds: string[] = [];
  @State private planningRevision: number = 0;
  @State private conflictRefresh: number = 0;
  @State private currentView: string = 'schedule';
  @State private taskFilter: string = 'all';
  @State private detailKind: string = '';
  @State private detailId: string = '';
  @State private detailRevision: number = 0;
  @State private detailStack: PlanningDetailFrame[] = [];
  @State private loading: boolean = false;
  @State private loaded: boolean = false;
  @State private mutationBusy: boolean = false;
  @State private pageWidth: number = 360;
  @State private actionState: PlanningActionState = { phase: 'idle', action: null, message: '' };
  @State private replanWriteBlocked: boolean = false;
  @State private editTaskId: string = '';
  @State private editTaskTitle: string = '';
  @State private editTaskStart: string = '';
  @State private editTaskEnd: string = '';
  @State private editTaskLocation: string = '';
  @State private editTaskReminder: string = '';
  @State private editPlanId: string = '';
  @State private editPlanTitle: string = '';
  @State private editPlanSummary: string = '';
  @State private editPlanDate: string = '';
  private editTaskOriginal: PlanningTask | null = null;
  private actionController: PlanningActionController | null = null;
  private submittedCreate: string = '';
  private submittedTaskEdit: string = '';
  private submittedPlanEdit: string = '';
  private externalDetail: boolean = false;
  private appliedFocusRevision: number = -1;
  private appliedViewRevision: number = -1;
  private initialized: boolean = false;
  private lifecycleRevision: number = 0;
  private requestRevision: number = 0;
  private pageActive: boolean = true;
  private timetableNeedsRefresh: boolean = false;
  private taskInputController: TextInputController = new TextInputController();
  private scheduleScroller: Scroller = new Scroller();
  private plansScroller: Scroller = new Scroller();
  private tasksScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.pageActive = true;
    if (!this.initialized) {
      this.initialized = true;
      this.selectDay(shanghaiDate(Date.now()));
      this.draftTaskDate = this.selectedDate;
      this.draftDateChoice = 'today';
    }
    this.viewRequested();
    this.focusChanged();
    this.refreshPlanning();
  }

  aboutToDisappear(): void {
    this.pageActive = false;
    this.lifecycleRevision++;
    this.requestRevision++;
    this.actionController?.dispose();
    this.actionController = null;
  }

  private activityChanged(): void {
    this.actionController?.setActive(this.active);
    if (!this.active) { this.requestRevision++; return; }
    this.refreshPlanning();
  }

  private refreshPlanning(): void {
    this.conflictRefresh++;
    if (this.active && this.pageActive) { this.reload(true); }
  }

  private replanApplied(): void {
    this.reload(true);
    this.onPlanningChanged();
  }

  private selectView(view: string): void {
    if (!['schedule', 'plans', 'tasks'].includes(view)) { return; }
    this.currentView = view;
  }

  private viewRequested(): void {
    if (this.appliedViewRevision === this.viewRevision) { return; }
    this.appliedViewRevision = this.viewRevision;
    if (!['agenda', 'goals', 'tasks'].includes(this.requestedView)) { return; }
    this.currentView = this.requestedView === 'agenda' ? 'schedule' : this.requestedView === 'goals' ? 'plans' : 'tasks';
    if (this.requestedView === 'agenda') { this.selectDay(shanghaiDate(Date.now())); }
    this.clearDetails();
  }

  private viewTitle(): string {
    if (this.currentView === 'plans') { return '目标计划'; }
    return this.currentView === 'tasks' ? '全部待办' : '日程';
  }

  private focusChanged(): void {
    if (this.appliedFocusRevision === this.focusRevision) { return; }
    this.appliedFocusRevision = this.focusRevision;
    if (this.focusTaskId.length === 0 && this.focusPlanId.length === 0) {
      if (this.detailStack.some((frame: PlanningDetailFrame) => frame.external)) { this.clearDetails(); }
      return;
    }
    if (this.detailStack.some((frame: PlanningDetailFrame) => frame.kind === 'draft')) {
      this.taskInputController.stopEditing();
      this.taskFormExpanded = false;
    }
    this.externalDetail = true;
    this.detailKind = this.focusTaskId.length > 0 && this.focusPlanId.length > 0 ? 'invalid' :
      (this.focusTaskId.length > 0 ? 'task' : 'plan');
    this.detailId = this.focusTaskId.length > 0 ? this.focusTaskId : this.focusPlanId;
    this.detailRevision++;
    this.detailStack = [{ key: this.detailRevision, kind: this.detailKind, id: this.detailId, external: true }];
    this.deletePendingId = '';
    this.onInnerNavigationChanged(true);
  }

  private openDetails(kind: string, id: string = ''): void {
    if (!['task', 'plan', 'draft', 'conflicts', 'action', 'task-edit', 'plan-edit'].includes(kind)) { return; }
    if (this.detailKind === kind && this.detailId === id) { return; }
    this.externalDetail = false;
    this.detailKind = kind;
    this.detailId = id;
    this.detailRevision++;
    this.detailStack = this.detailStack.concat([{ key: this.detailRevision, kind: kind, id: id, external: false }]);
    this.deletePendingId = '';
    if (kind === 'draft') { this.taskFormExpanded = true; }
    this.onInnerNavigationChanged(true);
  }

  private closeDetails(): void {
    if (this.detailStack.length === 0) { return; }
    const external = this.externalDetail;
    if (this.detailKind === 'draft') {
      this.taskInputController.stopEditing();
      this.taskFormExpanded = false;
    }
    this.detailStack = this.detailStack.slice(0, -1);
    const previous = this.detailStack.length > 0 ? this.detailStack[this.detailStack.length - 1] : null;
    this.detailKind = previous === null ? '' : previous.kind;
    this.detailId = previous === null ? '' : previous.id;
    this.externalDetail = previous === null ? false : previous.external;
    this.deletePendingId = '';
    this.onInnerNavigationChanged(previous !== null);
    if (previous === null && external) { this.onCloseFocus(); }
  }

  private clearDetails(): void {
    if (this.detailStack.length === 0) { return; }
    if (this.detailStack.some((frame: PlanningDetailFrame) => frame.kind === 'draft')) {
      this.taskInputController.stopEditing();
      this.taskFormExpanded = false;
    }
    this.detailStack = [];
    this.detailKind = '';
    this.detailId = '';
    this.externalDetail = false;
    this.deletePendingId = '';
    this.onInnerNavigationChanged(false);
  }

  private backRequested(): void {
    if (this.active && this.detailKind.length > 0) { this.closeDetails(); }
  }

  private topDetailKey(): number {
    return this.detailStack.length > 0 ? this.detailStack[this.detailStack.length - 1].key : -1;
  }

  private backLabel(): string {
    if (this.detailStack.length > 1) {
      const kind = this.detailStack[this.detailStack.length - 2].kind;
      return kind === 'task' ? '返回任务详情' : kind === 'plan' ? '返回目标计划' : '返回上一层';
    }
    return this.externalDetail ? '返回来源页面' : `返回${this.viewTitle()}`;
  }

  private detailTitle(): string {
    if (this.detailKind === 'action') { return '变更预览与回执'; }
    if (this.detailKind === 'task-edit') { return '编辑任务'; }
    if (this.detailKind === 'plan-edit') { return '编辑计划'; }
    if (this.detailKind === 'plan') { return '目标计划'; }
    if (this.detailKind === 'draft') { return '添加待办'; }
    if (this.detailKind === 'conflicts') { return '课表冲突核对'; }
    return '任务详情';
  }

  private focusedTasks(): PlanningTask[] {
    return this.tasksForId(this.detailId);
  }

  private focusedPlans(): PlanSummary[] {
    return this.plansForId(this.detailId);
  }

  private tasksForId(id: string): PlanningTask[] {
    return this.overview.tasks.filter((task: PlanningTask) => task.task_id === id);
  }

  private plansForId(id: string): PlanSummary[] {
    return this.overview.plans.filter((plan: PlanSummary) => plan.plan_id === id);
  }

  private filteredTasks(): PlanningTask[] {
    if (this.taskFilter === 'pending') {
      return this.overview.tasks.filter((task: PlanningTask) => task.status === 'pending');
    }
    if (this.taskFilter === 'completed') {
      return this.overview.tasks.filter((task: PlanningTask) => task.status === 'completed');
    }
    if (this.taskFilter === 'undated') {
      return this.overview.tasks.filter((task: PlanningTask) => task.start_at === null && task.status === 'pending');
    }
    return this.overview.tasks;
  }

  private selectTaskFilter(filter: string): void {
    if (['all', 'pending', 'completed', 'undated'].includes(filter)) { this.taskFilter = filter; }
  }

  private weekDays(): CalendarDay[] {
    const parts = this.selectedDate.split('-');
    const selected = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]));
    const result: CalendarDay[] = [];
    for (let offset = -3; offset <= 3; offset++) {
      const date = new Date(selected.getFullYear(), selected.getMonth(), selected.getDate() + offset);
      const key = this.dateKey(date);
      result.push({ key: key, day: date.getDate(), date: key,
        courseCount: this.timetable.filter((course: TimetableEntry) => course.date === key).length,
        taskCount: this.overview.tasks.filter((task: PlanningTask) => this.taskDate(task) === key).length });
    }
    return result;
  }

  private selectDay(date: string): void {
    this.selectedDate = date;
    const parts = date.split('-');
    this.calendarMonth = new Date(Number(parts[0]), Number(parts[1]) - 1, 1).getTime();
  }

  private allDayTasks(): PlanningTask[] {
    return this.agendaForDate().allDay;
  }

  private agendaForDate(): DailyAgenda {
    return buildDailyAgenda(this.timetable, this.overview.tasks.filter((task: PlanningTask) =>
      task.start_at === null || typeof task.start_at === 'string'), Date.parse(`${this.selectedDate}T12:00:00+08:00`));
  }

  private dayTimeline(): PlanningTimelineItem[] {
    return this.agendaForDate().rows.map((row: AgendaRow): PlanningTimelineItem => {
      const start = row.date === this.selectedDate ? row.startTime : `${row.date} ${row.startTime}`;
      const end = row.endTime.length === 0 ? '' : row.endDate === this.selectedDate ? row.endTime : `${row.endDate} ${row.endTime}`;
      const course = row.kind === 'course' ? this.timetable.find((item: TimetableEntry) =>
        item.date === row.date && item.start_time === row.startTime && item.title === row.title && item.location === row.location) : undefined;
      return { key: row.id, kind: row.kind === 'course' ? '课程' : '任务',
        time: end.length === 0 ? start : `${start}–${end}`, title: row.title,
        detail: `${row.location}${course !== undefined && course.teacher.length > 0 ? ` · ${course.teacher}` : ''}`,
        taskId: row.taskId ?? '', completed: row.done };
    });
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
    if (typeof task.start_at !== 'string') { return ''; }
    const start = formatPlanDateTime(task.start_at);
    return start.length === 16 || start.length === 10 ? start.substring(0, 10) : '';
  }

  private taskTime(task: PlanningTask): string {
    if (task.start_at === null) {
      return '待安排';
    }
    if (typeof task.start_at !== 'string') { return '时间格式异常，请核对'; }
    const startAt = formatPlanDateTime(task.start_at);
    if (startAt.length === 10) { return '全天'; }
    if (startAt.length !== 16) {
      return '时间格式异常，请核对';
    }
    const start = startAt.substring(11, 16);
    if (task.source === 'manual' && task.end_at === null) {
      return start === '23:59' ? '全天' : start;
    }
    if (task.end_at === null) {
      return start;
    }
    if (typeof task.end_at !== 'string') { return `${start} · 结束时间异常，请核对`; }
    const endAt = formatPlanDateTime(task.end_at);
    if (endAt.length !== 16 && endAt.length !== 10) { return `${start} · 结束时间异常，请核对`; }
    if (endAt.length === 10) { return `${start} · 结束 ${endAt}（未设时间）`; }
    return startAt.substring(0, 10) === endAt.substring(0, 10) ?
      `${start}–${endAt.substring(11, 16)}` : `${start}–${endAt}`;
  }

  private taskScheduleLabel(task: PlanningTask): string {
    if (task.start_at === null) { return '未安排日期'; }
    const date = this.taskDate(task);
    return date.length === 0 ? '时间格式异常，请核对' : `${date} · ${this.taskTime(task)}`;
  }

  private scheduleTypesValid(task: PlanningTask): boolean {
    return (task.start_at === null || typeof task.start_at === 'string') &&
      (task.end_at === null || typeof task.end_at === 'string');
  }

  private relativeDate(offset: number): string {
    const today = shanghaiDate(Date.now());
    const date = new Date(`${today}T00:00:00Z`);
    date.setUTCDate(date.getUTCDate() + offset);
    return date.toISOString().substring(0, 10);
  }

  private selectDraftTime(value: string): void {
    this.getUIContext().animateTo({ duration: AppTheme.motion(180), curve: Curve.EaseOut }, () => {
      if (value.length > 0 && this.draftTaskDate.length === 0) {
        this.draftTaskDate = this.relativeDate(0);
        this.draftDateChoice = 'today';
      }
      this.draftTaskTime = value;
    });
  }

  private selectDraftDate(value: string, choice: string): void {
    this.getUIContext().animateTo({ duration: AppTheme.motion(180), curve: Curve.EaseOut }, () => {
      this.draftTaskDate = value;
      this.draftDateChoice = choice;
      if (value.length === 0) {
        this.draftTaskTime = '';
      }
    });
  }

  private dateChoiceSelected(choice: string, value: string): boolean {
    // Equal dates may come from different controls; highlight only the choice the user applied.
    return this.draftDateChoice === choice && this.draftTaskDate === value;
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
    if (task.status === 'completed' || task.start_at === null || !this.scheduleTypesValid(task)) {
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
    const agenda = this.agendaForDate();
    return this.overview.tasks.filter((task: PlanningTask) =>
      agenda.rows.some((row: AgendaRow) => row.taskId === task.task_id) ||
      agenda.allDay.some((item: PlanningTask) => item.task_id === task.task_id));
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

  private async reload(includeTimetable: boolean = false): Promise<void> {
    if (!this.pageActive || !this.active) { return; }
    if (includeTimetable) { this.timetableNeedsRefresh = true; }
    const revision = ++this.requestRevision;
    this.loading = true;
    try {
      const api = new CampusFlowApi(this.baseUrl, this.token);
      // Apply a navigation refresh as one generation; a failed/older read keeps the previous snapshot.
      const context: UserContextResponse | null = this.timetableNeedsRefresh ? await api.context() : null;
      if (!this.pageActive || !this.active || revision !== this.requestRevision) { return; }
      const overview = await api.planning();
      if (!this.pageActive || !this.active || revision !== this.requestRevision) { return; }
      this.getUIContext().animateTo({ duration: AppTheme.motion(180), curve: Curve.EaseOut }, () => {
        if (!this.pageActive || !this.active || revision !== this.requestRevision) { return; }
        // 成功刷新后重建计划内容，避免 ForEach 复用旧对象；展开状态仍按计划 ID 保留。
        this.planningRevision++;
        this.overview = overview;
        this.loaded = true;
        if (context !== null) {
          this.timetable = context.timetable;
          this.timetableNeedsRefresh = false;
        }
        this.expandedPlanIds = this.expandedPlanIds.filter((id: string) =>
          overview.plans.some((plan: PlanSummary) => plan.plan_id === id));
      });
      this.errorText = '';
    } catch (error) {
      if (this.pageActive && this.active && revision === this.requestRevision) {
        this.errorText = '计划加载失败，请重试；已有内容未被清除。';
      }
    } finally {
      if (this.pageActive && this.active && revision === this.requestRevision) { this.loading = false; }
    }
  }

  private actionManager(): PlanningActionController {
    if (this.actionController === null) {
      this.actionController = new PlanningActionController(new CampusFlowApi(this.baseUrl, this.token),
        (state: PlanningActionState) => { if (this.pageActive) { this.actionState = state; } },
        (action: PendingAction) => this.actionApplied(action));
      this.actionController.setActive(this.active && this.pageActive);
    }
    return this.actionController;
  }

  private actionBlocksWrites(): boolean {
    return ['previewing', 'confirming', 'cancelling', 'checking'].includes(this.actionState.phase) ||
      (this.actionState.action !== null && !['resolved', 'cancelled', 'invalidated'].includes(this.actionState.phase));
  }

  private writesBlocked(): boolean {
    return this.mutationBusy || this.replanWriteBlocked || this.actionBlocksWrites() || !this.active || !this.pageActive;
  }

  private createSnapshot(): string {
    return JSON.stringify([this.title, this.draftTaskDate, this.draftTaskTime, this.draftDateChoice]);
  }

  private taskEditSnapshot(): string {
    return JSON.stringify([this.editTaskId, this.editTaskTitle, this.editTaskStart, this.editTaskEnd, this.editTaskLocation, this.editTaskReminder]);
  }

  private planEditSnapshot(): string {
    return JSON.stringify([this.editPlanId, this.editPlanTitle, this.editPlanSummary, this.editPlanDate]);
  }

  private actionApplied(action: PendingAction): void {
    if (!this.pageActive || !this.active) { return; }
    if (action.action === 'create' && action.kind === 'task' && this.createSnapshot() === this.submittedCreate) {
      this.title = '';
      this.taskInputController.stopEditing();
    }
    if (action.action === 'update' && action.kind === 'task' && this.taskEditSnapshot() === this.submittedTaskEdit) {
      this.editTaskId = ''; this.editTaskOriginal = null;
    }
    if (action.action === 'update' && action.kind === 'plan' && this.planEditSnapshot() === this.submittedPlanEdit) { this.editPlanId = ''; }
    this.deletePendingId = '';
    this.reload();
    this.conflictRefresh++;
    this.onPlanningChanged();
  }

  private async previewAction(request: PlanningActionRequest): Promise<void> {
    if (this.writesBlocked()) { return; }
    this.errorText = '';
    this.openDetails('action');
    await this.actionManager().preview(request);
  }

  private async confirmPlanningAction(): Promise<void> {
    if (this.mutationBusy || this.replanWriteBlocked || !this.active || !this.pageActive) { return; }
    await this.actionManager().confirm();
  }

  private dismissAction(): void {
    if (this.actionBlocksWrites()) { return; }
    this.actionManager().dismiss();
    this.closeDetails();
  }

  private async addTask(): Promise<void> {
    if (this.title.trim().length === 0 || this.writesBlocked()) { return; }
    if (Array.from(this.title.trim()).length > 120) { this.errorText = '待办名称请控制在 120 字以内。'; return; }
    const taskTime = this.draftTaskTime.length === 0 ? '23:59' : this.draftTaskTime;
    const startAt = this.draftTaskDate.length === 0 ? null : `${this.draftTaskDate}T${taskTime}:00+08:00`;
    this.submittedCreate = this.createSnapshot();
    await this.previewAction({ operation: 'create_task', task: { title: this.title.trim(), start_at: startAt,
      end_at: null, reminder_minutes: null, location: null } });
  }

  private beginTaskEdit(task: PlanningTask): void {
    if (this.writesBlocked()) { return; }
    if (this.editTaskId.length > 0 && this.editTaskId !== task.task_id) {
      this.errorText = '还有另一条任务的编辑草稿。请先完成或明确放弃该草稿。';
      this.openDetails('task-edit', this.editTaskId); return;
    }
    if (this.editTaskId.length === 0) {
      this.editTaskId = task.task_id;
      this.editTaskOriginal = JSON.parse(JSON.stringify(task)) as PlanningTask;
      this.editTaskTitle = task.title;
      this.editTaskStart = task.start_at === null ? '' : formatPlanDateTime(task.start_at);
      this.editTaskEnd = task.end_at === null ? '' : formatPlanDateTime(task.end_at);
      this.editTaskLocation = task.location ?? '';
      this.editTaskReminder = task.reminder_minutes === null ? '' : `${task.reminder_minutes}`;
    }
    this.openDetails('task-edit', task.task_id);
  }

  private discardTaskEdit(): void {
    if (this.actionBlocksWrites()) { return; }
    this.editTaskId = ''; this.editTaskOriginal = null; this.closeDetails();
  }

  private async previewTaskEdit(): Promise<void> {
    const original = this.editTaskOriginal;
    if (original === null || this.writesBlocked()) { return; }
    const start = editedPlanningTime(this.editTaskStart, original.start_at);
    const end = editedPlanningTime(this.editTaskEnd, original.end_at);
    const reminder = this.editTaskReminder.trim();
    if (this.editTaskTitle.trim().length === 0 || Array.from(this.editTaskTitle.trim()).length > 120 ||
      Array.from(this.editTaskLocation.trim()).length > 120) {
      this.errorText = '请填写 1–120 字的任务名称，地点不超过 120 字。'; return;
    }
    if (start === 'invalid' || end === 'invalid' || (start === null && end !== null) ||
      (start !== null && end !== null && planningTimestamp(end) <= planningTimestamp(start))) {
      this.errorText = '请使用有效的“年-月-日 时:分”，结束必须晚于开始；未安排时可将两项留空。'; return;
    }
    if (reminder.length > 0 && (!/^\d+$/.test(reminder) || Number(reminder) > 10080)) {
      this.errorText = '提醒请输入 0–10080 的整数分钟，留空表示不设置。'; return;
    }
    const task: PlanningTaskDraft = { title: this.editTaskTitle.trim(), start_at: start, end_at: end,
      reminder_minutes: reminder.length === 0 ? null : Number(reminder),
      location: this.editTaskLocation === (original.location ?? '') ? original.location : this.editTaskLocation.trim() || null };
    this.submittedTaskEdit = this.taskEditSnapshot();
    await this.previewAction({ operation: 'update_task', task_id: original.task_id, task: task });
  }

  private beginPlanEdit(plan: PlanSummary): void {
    if (this.writesBlocked()) { return; }
    if (this.editPlanId.length > 0 && this.editPlanId !== plan.plan_id) {
      this.errorText = '还有另一个计划的编辑草稿。请先完成或明确放弃该草稿。';
      this.openDetails('plan-edit', this.editPlanId); return;
    }
    if (this.editPlanId.length === 0) {
      this.editPlanId = plan.plan_id; this.editPlanTitle = plan.title;
      this.editPlanSummary = plan.summary; this.editPlanDate = plan.target_date ?? '';
    }
    this.openDetails('plan-edit', plan.plan_id);
  }

  private discardPlanEdit(): void {
    if (this.actionBlocksWrites()) { return; }
    this.editPlanId = ''; this.closeDetails();
  }

  private async previewPlanEdit(): Promise<void> {
    if (this.editPlanId.length === 0 || this.writesBlocked()) { return; }
    const date = this.editPlanDate.trim();
    if (this.editPlanTitle.trim().length === 0 || Array.from(this.editPlanTitle.trim()).length > 120 ||
      Array.from(this.editPlanSummary).length > 500 || (date.length > 0 && !validPlanningDate(date))) {
      this.errorText = '名称需 1–120 字，说明不超过 500 字；截止日请填有效的 YYYY-MM-DD 或留空。'; return;
    }
    this.submittedPlanEdit = this.planEditSnapshot();
    await this.previewAction({ operation: 'update_plan', plan_id: this.editPlanId,
      plan: { title: this.editPlanTitle.trim(), summary: this.editPlanSummary, target_date: date.length > 0 ? date : null } });
  }

  private async requestPlanDelete(plan: PlanSummary): Promise<void> {
    await this.previewAction({ operation: 'delete_plan', plan_id: plan.plan_id });
  }

  private async toggle(task: PlanningTask): Promise<void> {
    if (this.writesBlocked()) { return; }
    this.mutationBusy = true;
    const revision = this.lifecycleRevision;
    try {
      await new CampusFlowApi(this.baseUrl, this.token).updateTask(task.task_id, task.status !== 'completed');
      if (!this.pageActive || revision !== this.lifecycleRevision) { return; }
      this.deletePendingId = '';
      await this.reload();
      this.conflictRefresh++;
      this.onPlanningChanged();
    } catch (error) {
      if (this.pageActive && revision === this.lifecycleRevision) {
        this.errorText = error instanceof CampusFlowRequestError && error.statusCode === 409 && error.code === 'ACTION_CONFLICT' ?
          '恢复为待完成会产生时间冲突。请打开这条任务详情，调整时间并确认后再恢复。' :
          '更新失败：请刷新核对当前任务状态后再操作。';
      }
    } finally {
      this.mutationBusy = false;
    }
  }

  private async requestDelete(task: PlanningTask): Promise<void> {
    await this.previewAction({ operation: 'delete_task', task_id: task.task_id });
  }

  private planPrompt(): string {
    return '请读取我的课表和未完成待办，为未来 7 天制定一份可执行的学习计划。要求避开课程冲突，拆分里程碑和具体任务，为每项任务设置明确时间、地点与提醒；先展示提案，等我确认后再写入规划。';
  }

  private reviewPrompt(): string {
    return '请结合我的近期课程和未完成任务，安排今天晚上的复习计划。先检查时间冲突，给出具体时间段和提醒，等待我确认后再写入。';
  }

  private toggleCalendar(): void {
    this.calendarExpanded = !this.calendarExpanded;
  }

  private toggleTaskForm(): void {
    if (this.taskFormExpanded) {
      this.taskInputController.stopEditing();
    }
    this.taskFormExpanded = !this.taskFormExpanded;
  }

  private draftScheduleSummary(): string {
    if (this.draftTaskDate.length === 0) {
      return '未设日期 · 待安排时间';
    }
    return `${this.draftTaskDate} · ${this.draftTaskTime.length === 0 ? '全天' : this.draftTaskTime}`;
  }

  @Builder
  private DayTimeline() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Text(this.selectedDate).fontSize(AppTheme.sectionTitle).fontWeight(FontWeight.Medium)
          .fontColor(AppTheme.ink).layoutWeight(1)
        Text(`${this.selectedCourses().length} 节课 · ${this.selectedTasks().length} 项任务`)
          .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet)
      }.width('100%')
      Text('北京时间 · 课程与定时任务').fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
      if (this.dayTimeline().length === 0 && !this.loading && this.loaded) {
        Text('这一天还没有明确时段的安排。全天待办在下方单独列出。')
          .fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet).width('100%').padding(16)
          .backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
      }
      ForEach(this.dayTimeline(), (item: PlanningTimelineItem) => {
        Column({ space: 8 }) {
          Row({ space: 8 }) {
            Text(item.time).fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium).fontColor(AppTheme.actionBlue)
              .layoutWeight(1).wordBreak(WordBreak.BREAK_WORD)
            Text(item.completed ? '任务 · 已完成' : item.kind).fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet)
          }.width('100%')
          Text(item.title).fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink)
            .width('100%').wordBreak(WordBreak.BREAK_WORD)
            .decoration({ type: item.completed ? TextDecorationType.LineThrough : TextDecorationType.None })
          Text(item.detail.length > 0 ? item.detail : '未设置地点').fontSize(AppTheme.metaSize)
            .fontColor(AppTheme.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
          if (item.taskId.length > 0) {
            Button('查看任务详情').constraintSize({ minHeight: 48 }).width('100%')
              .fontSize(AppTheme.bodySize).fontColor(AppTheme.actionBlue).backgroundColor(AppTheme.blueSoft)
              .borderRadius(AppTheme.controlRadius).onClick(() => this.openDetails('task', item.taskId))
          }
        }.width('100%').alignItems(HorizontalAlign.Start).padding(AppTheme.cardInset)
          .backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
      }, (item: PlanningTimelineItem) => `${item.key}-${this.planningRevision}`)
      if (this.allDayTasks().length > 0) {
        Text('全天 · 未指定时段').fontSize(AppTheme.sectionTitle).fontWeight(FontWeight.Medium)
          .fontColor(AppTheme.ink).width('100%')
        ForEach(this.allDayTasks(), (task: PlanningTask) => {
          this.TaskRow(task)
        }, (task: PlanningTask) => `${task.task_id}-${this.planningRevision}`)
      }
      Button(`查看无日期待办（${this.unscheduledCount()} 项待完成）`).width('100%').constraintSize({ minHeight: 48 })
        .fontSize(AppTheme.bodySize).fontColor(AppTheme.actionBlue).backgroundColor(AppTheme.blueSoft)
        .borderRadius(AppTheme.controlRadius).onClick(() => {
          this.selectTaskFilter('undated');
          this.selectView('tasks');
        })
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private TaskCheck(task: PlanningTask) {
    Button({ type: ButtonType.Circle }) {
      Stack() {
        Circle().width(25).height(25)
          .fill(task.status === 'completed' ? AppTheme.actionBlue : AppTheme.surface)
          .stroke(task.status === 'completed' ? AppTheme.actionBlue : AppTheme.quiet).strokeWidth(1.5)
        if (task.status === 'completed') {
          AppIcon({ name: 'check', iconSize: 15, color: AppTheme.surface })
        }
      }
    }.width(48).height(48).backgroundColor(Color.Transparent)
      .enabled(!this.writesBlocked()).accessibilityText(task.status === 'completed' ? '标记为未完成' : '标记为完成')
      .onClick(() => this.toggle(task))
  }

  @Builder
  private PlanTask(task: PlanningTask) {
    Column({ space: 8 }) {
      Row({ space: 4 }) {
        this.TaskCheck(task)
        Text(task.title).fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium).wordBreak(WordBreak.BREAK_WORD)
          .fontColor(task.status === 'completed' ? AppTheme.muted : AppTheme.ink)
          .decoration({ type: task.status === 'completed' ?
            TextDecorationType.LineThrough : TextDecorationType.None })
          .layoutWeight(1)
      }.width('100%').alignItems(VerticalAlign.Top)
      if (this.scheduleTypesValid(task)) {
        TaskScheduleDetails({ startAt: task.start_at, endAt: task.end_at,
          location: task.location, reminderMinutes: task.reminder_minutes })
      } else {
        Text('时间格式异常，请核对后再安排。').fontSize(AppTheme.metaSize).fontColor(AppTheme.red).width('100%')
      }
      if (task.status === 'completed') {
        Text('已完成').fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
      } else if (this.taskOverdue(task)) {
        Text('已逾期').fontSize(AppTheme.metaSize).fontColor(AppTheme.red).width('100%')
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(12)
      .backgroundColor(AppTheme.canvas).borderRadius(AppTheme.controlRadius)
  }

  @Builder
  private PlanBody(plan: PlanSummary) {
    Column({ space: 12 }) {
      Text('以下时间均为北京时间').fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
      if (plan.summary.length > 0) {
        Text(plan.summary).fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
      }
      if (plan.milestones.length === 0) {
        Text('此计划尚未设置里程碑。').fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet).width('100%')
      }
      ForEach(plan.milestones, (milestone: PlanMilestone) => {
        Column({ space: 8 }) {
          Divider().color(AppTheme.line)
          Text(milestone.title).fontSize(16).fontWeight(FontWeight.Medium).wordBreak(WordBreak.BREAK_WORD)
            .fontColor(AppTheme.ink).width('100%')
          Text(`截止：${formatPlanDateTime(milestone.due_at)} · ${milestone.completed_count}/${milestone.task_count} 项已完成`)
            .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
          if (this.milestoneTasks(plan.plan_id, milestone.milestone_id).length === 0) {
            Text('这个里程碑下暂无任务。').fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet).width('100%')
          }
          ForEach(this.milestoneTasks(plan.plan_id, milestone.milestone_id), (task: PlanningTask) => {
            this.PlanTask(task)
            this.TaskDetailLink(task)
          }, (task: PlanningTask) => `${task.task_id}-${task.status}-${task.completed_at ?? ''}`)
        }.width('100%').alignItems(HorizontalAlign.Start)
      }, (milestone: PlanMilestone) => `${plan.plan_id}-${milestone.milestone_id}`)
      if (this.ungroupedPlanTasks(plan).length > 0) {
        Column({ space: 8 }) {
          Divider().color(AppTheme.line)
          Text('未归入里程碑的任务').fontSize(16).fontWeight(FontWeight.Medium)
            .fontColor(AppTheme.ink).width('100%')
          ForEach(this.ungroupedPlanTasks(plan), (task: PlanningTask) => {
            this.PlanTask(task)
            this.TaskDetailLink(task)
          }, (task: PlanningTask) => `${task.task_id}-${task.status}-${task.completed_at ?? ''}`)
        }.width('100%').alignItems(HorizontalAlign.Start)
      } else if (plan.milestones.length === 0) {
        Text('此计划暂无任务。').fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet).width('100%')
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private TaskDetailLink(task: PlanningTask) {
    Button('查看任务详情').width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
      .fontColor(AppTheme.actionBlue).backgroundColor(AppTheme.blueSoft).borderRadius(AppTheme.controlRadius)
      .onClick(() => this.openDetails('task', task.task_id))
  }

  @Builder
  private ConfirmedPlans() {
    Column({ space: 16 }) {
      Text(`目标计划 · ${this.overview.plans.length} 个`).fontSize(AppTheme.sectionTitle)
        .fontWeight(FontWeight.Bold).fontColor(AppTheme.ink).width('100%')
      Text(`${this.overview.completed_tasks}/${this.overview.total_tasks} 项任务已完成`)
        .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
      if (this.overview.plans.length === 0 && !this.loading && this.loaded) {
        Text('还没有已确认的目标计划。向 Agent 描述目标，确认提案后在这里推进。')
          .fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet).width('100%')
      }
      Button('让 Agent 规划这一周').width('100%').constraintSize({ minHeight: 48 })
        .fontSize(AppTheme.bodySize).fontColor(AppTheme.actionBlue).backgroundColor(AppTheme.blueSoft)
        .borderRadius(AppTheme.controlRadius).onClick(() => this.onOpenAgent(this.planPrompt()))
      ForEach(this.overview.plans, (plan: PlanSummary) => {
        Column({ space: 12 }) {
          Text(plan.title).fontSize(AppTheme.sectionTitle).fontWeight(FontWeight.Bold).wordBreak(WordBreak.BREAK_WORD)
            .fontColor(AppTheme.ink).width('100%')
          Text(`${this.planStatus(plan)} · ${plan.milestones.length} 个里程碑 · ${plan.completed_count}/${plan.task_count} 项已完成`)
            .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
          Text(plan.target_date === null ? '未设截止日' : `截止 ${plan.target_date}`)
            .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
          Button('打开完整计划').width('100%').constraintSize({ minHeight: 48 })
            .fontSize(AppTheme.bodySize).fontColor(AppTheme.actionBlue).backgroundColor(AppTheme.blueSoft)
            .borderRadius(AppTheme.controlRadius).onClick(() => this.openDetails('plan', plan.plan_id))
          Button(this.expandedPlanIds.includes(plan.plan_id) ? '收起里程碑与任务' : '在列表展开里程碑与任务')
            .width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
            .fontColor(AppTheme.quiet).backgroundColor(Color.Transparent).borderRadius(AppTheme.controlRadius)
            .accessibilityText(`${plan.title}，${this.expandedPlanIds.includes(plan.plan_id) ? '已展开，收起' : '已折叠，展开'}`)
            .onClick(() => this.togglePlan(plan.plan_id))
          if (this.expandedPlanIds.includes(plan.plan_id)) { this.PlanBody(plan) }
        }.width('100%').alignItems(HorizontalAlign.Start).padding(AppTheme.cardInset)
          .backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
      }, (plan: PlanSummary) => `${plan.plan_id}-${this.planningRevision}`)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private DateChoice(label: string, value: string, choice: string) {
    Button({ type: ButtonType.Normal }) {
      Text(label).fontSize(AppTheme.bodySize).width('100%').textAlign(TextAlign.Center)
        .fontWeight(this.dateChoiceSelected(choice, value) ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.dateChoiceSelected(choice, value) ? AppTheme.surface : AppTheme.quiet)
    }.constraintSize({ minHeight: 48 }).padding(10).layoutWeight(1)
      .backgroundColor(this.dateChoiceSelected(choice, value) ? AppTheme.actionBlue : AppTheme.canvas)
      .accessibilityText(`${label}${this.dateChoiceSelected(choice, value) ? '，已选中' : ''}`)
      .borderRadius(AppTheme.controlRadius).onClick(() => this.selectDraftDate(value, choice))
  }

  @Builder
  private TimeChoice(label: string, value: string) {
    Button({ type: ButtonType.Normal }) {
      Text(label).fontSize(AppTheme.bodySize).width('100%').textAlign(TextAlign.Center)
        .fontWeight(this.draftTaskTime === value ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.draftTaskTime === value ? AppTheme.surface : AppTheme.quiet)
    }.constraintSize({ minHeight: 48 }).padding(10).layoutWeight(1)
      .backgroundColor(this.draftTaskTime === value ? AppTheme.actionBlue : AppTheme.canvas)
      .accessibilityText(`${label}${this.draftTaskTime === value ? '，已选中' : ''}`)
      .borderRadius(AppTheme.controlRadius).onClick(() => this.selectDraftTime(value))
  }

  @Builder
  private MonthCalendar() {
    Column({ space: 16 }) {
      Row() {
        Text(this.monthLabel()).fontSize(AppTheme.sectionTitle).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
          .layoutWeight(1)
        Button({ type: ButtonType.Circle }) {
          AppIcon({ name: 'back', iconSize: 17, color: AppTheme.actionBlue })
        }.width(48).height(48).backgroundColor(Color.Transparent).accessibilityText('上个月')
          .onClick(() => this.moveMonth(-1))
        Button({ type: ButtonType.Circle }) {
          AppIcon({ name: 'chevron', iconSize: 17, color: AppTheme.actionBlue })
        }.width(48).height(48).backgroundColor(Color.Transparent).accessibilityText('下个月')
          .onClick(() => this.moveMonth(1))
      }.width('100%')
      Scroll() {
        Column({ space: 8 }) {
          Row() {
            ForEach(['日', '一', '二', '三', '四', '五', '六'], (label: string) => {
              Text(label).fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).textAlign(TextAlign.Center).layoutWeight(1)
            }, (label: string) => label)
          }.width('100%')
          Grid() {
            ForEach(this.calendarDays(), (item: CalendarDay) => {
              GridItem() {
                if (item.day === 0) {
                  Blank().height(48)
                } else {
                  Button({ type: ButtonType.Normal }) {
                    Column({ space: 3 }) {
                      Text(`${item.day}`).fontSize(AppTheme.bodySize)
                        .fontWeight(this.selectedDate === item.date ? FontWeight.Bold : FontWeight.Regular)
                      Text(item.courseCount + item.taskCount > 0 ? '·' : ' ')
                        .fontSize(AppTheme.metaSize)
                    }.width('100%').justifyContent(FlexAlign.Center)
                  }.width('100%').height(48).padding(0)
                    .fontColor(this.selectedDate === item.date ? AppTheme.surface : AppTheme.ink)
                    .backgroundColor(this.selectedDate === item.date ? AppTheme.actionBlue : Color.Transparent)
                    .borderRadius(AppTheme.controlRadius)
                    .accessibilityText(`${item.date}，${item.courseCount} 节课，${item.taskCount} 项任务${this.selectedDate === item.date ? '，已选中' : ''}`)
                    .onClick(() => this.selectDay(item.date))
                }
              }
            }, (item: CalendarDay) => `${item.key}-${item.courseCount}-${item.taskCount}-${this.selectedDate}`)
          }.columnsTemplate('repeat(7, 1fr)').columnsGap(0).rowsGap(4).width('100%')
            .height(this.calendarDays().length > 35 ? 308 : 256)
        }.width(Math.max(336, this.pageWidth - AppTheme.pageInset * 2 - 24))
      }.scrollable(ScrollDirection.Horizontal).width('100%').scrollBar(BarState.Auto)
    }.width('100%')
  }

  @Builder
  private TaskForm() {
    Column({ space: 16 }) {
      Text('待办内容').fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet).width('100%')
      Row({ space: 8 }) {
        TextInput({ text: this.title, placeholder: '快速记录一个待办', controller: this.taskInputController })
          .layoutWeight(1).height(48).fontSize(AppTheme.bodySize).fontColor(AppTheme.ink)
          .backgroundColor(AppTheme.canvas).borderRadius(AppTheme.controlRadius).onChange((value) => this.title = value)
        Button({ type: ButtonType.Circle }) {
          AppIcon({ name: 'plus', iconSize: 22, color: AppTheme.surface })
        }.width(48).height(48).backgroundColor(AppTheme.actionBlue)
          .accessibilityText('预览添加待办').enabled(this.title.trim().length > 0 && !this.writesBlocked()).onClick(() => this.addTask())
      }.width('100%')
      Row() {
        Text('日期').fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet)
        Text(this.draftTaskDate.length === 0 ? '无日期' : this.draftTaskDate)
          .fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium).fontColor(AppTheme.actionBlue)
          .layoutWeight(1).textAlign(TextAlign.End)
      }.width('100%')
      Row({ space: 8 }) {
        this.DateChoice('今天', this.relativeDate(0), 'today')
        this.DateChoice('明天', this.relativeDate(1), 'tomorrow')
      }.width('100%')
      Row({ space: 8 }) {
        this.DateChoice('日历所选', this.selectedDate, 'calendar')
        this.DateChoice('无日期', '', 'none')
      }.width('100%')
      Row() {
        Text('时间').fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet)
        Text(this.draftTaskTime.length === 0 ? '全天' : this.draftTaskTime)
          .fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium).fontColor(AppTheme.actionBlue)
          .layoutWeight(1).textAlign(TextAlign.End)
      }.width('100%')
      Row({ space: 8 }) {
        this.TimeChoice('全天', '')
        this.TimeChoice('08:00', '08:00')
      }.width('100%')
      Row({ space: 8 }) {
        this.TimeChoice('14:00', '14:00')
        Button({ type: ButtonType.Normal }) {
          Text(this.draftTaskTime.length > 0 && this.draftTaskTime !== '08:00' &&
            this.draftTaskTime !== '14:00' ? this.draftTaskTime : '自定义')
            .fontSize(AppTheme.bodySize).fontColor(AppTheme.actionBlue).width('100%').textAlign(TextAlign.Center)
        }.constraintSize({ minHeight: 48 }).padding(10).layoutWeight(1)
          .backgroundColor(AppTheme.blueSoft).borderRadius(AppTheme.controlRadius).accessibilityText('自定义时间')
          .onClick(() => this.openTimePicker())
      }.width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private EditField(label: string, value: string, placeholder: string, change: (value: string) => void) {
    Column({ space: 8 }) {
      Text(label).fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet).width('100%')
      TextInput({ text: value, placeholder: placeholder }).height(48).width('100%').fontSize(AppTheme.bodySize)
        .fontColor(AppTheme.ink).backgroundColor(AppTheme.surface).borderRadius(AppTheme.controlRadius).onChange(change)
    }.width('100%')
  }

  @Builder
  private TaskEditor() {
    Column({ space: 16 }) {
      if (this.editTaskId.length === 0) {
        Text('这份编辑已完成或已放弃，返回任务详情可重新编辑。').fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet).width('100%')
      } else {
        Text('返回会保留草稿。时间使用北京时间；修改前后内容会在下一步完整展示。')
          .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
        this.EditField('任务名称', this.editTaskTitle, '1–120 字', (value: string) => this.editTaskTitle = value)
        this.EditField('开始时间', this.editTaskStart, '例如 2026-10-20 18:30，留空待安排', (value: string) => this.editTaskStart = value)
        this.EditField('结束时间', this.editTaskEnd, '例如 2026-10-20 19:30，可留空', (value: string) => this.editTaskEnd = value)
        this.EditField('地点', this.editTaskLocation, '可留空', (value: string) => this.editTaskLocation = value)
        this.EditField('提前提醒（分钟）', this.editTaskReminder, '0 表示开始时；留空不设置', (value: string) => this.editTaskReminder = value)
        Text('这里保存提醒设置；系统通知实际送达仍取决于平台支持与通知权限。')
          .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
        Button('预览任务更改').width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
          .fontColor(AppTheme.surface).backgroundColor(AppTheme.actionBlue).borderRadius(AppTheme.controlRadius)
          .enabled(!this.writesBlocked()).onClick(() => this.previewTaskEdit())
        Button('放弃这份编辑草稿').width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
          .fontColor(AppTheme.quiet).backgroundColor(AppTheme.surface).borderRadius(AppTheme.controlRadius)
          .enabled(!this.actionBlocksWrites()).onClick(() => this.discardTaskEdit())
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private PlanEditor() {
    Column({ space: 16 }) {
      if (this.editPlanId.length === 0) {
        Text('这份编辑已完成或已放弃，返回计划详情可重新编辑。').fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet).width('100%')
      } else {
        Text('仅编辑计划信息，现有阶段与子任务不变。返回会保留草稿。')
          .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
        this.EditField('计划名称', this.editPlanTitle, '1–120 字', (value: string) => this.editPlanTitle = value)
        Text('计划说明').fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet).width('100%')
        TextArea({ text: this.editPlanSummary, placeholder: '最多 500 字，可留空' }).width('100%').constraintSize({ minHeight: 120 })
          .fontSize(AppTheme.bodySize).fontColor(AppTheme.ink).backgroundColor(AppTheme.surface).borderRadius(AppTheme.controlRadius)
          .onChange((value: string) => this.editPlanSummary = value)
        this.EditField('截止日期', this.editPlanDate, 'YYYY-MM-DD，留空不设截止日', (value: string) => this.editPlanDate = value)
        Button('预览计划更改').width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
          .fontColor(AppTheme.surface).backgroundColor(AppTheme.actionBlue).borderRadius(AppTheme.controlRadius)
          .enabled(!this.writesBlocked()).onClick(() => this.previewPlanEdit())
        Button('放弃这份编辑草稿').width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
          .fontColor(AppTheme.quiet).backgroundColor(AppTheme.surface).borderRadius(AppTheme.controlRadius)
          .enabled(!this.actionBlocksWrites()).onClick(() => this.discardPlanEdit())
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private TaskRow(task: PlanningTask) {
    Row({ space: 8 }) {
      this.TaskCheck(task)
      Button({ type: ButtonType.Normal }) {
        Column({ space: 8 }) {
          Text(task.title).fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink)
            .decoration({ type: task.status === 'completed' ? TextDecorationType.LineThrough : TextDecorationType.None })
            .width('100%').wordBreak(WordBreak.BREAK_WORD)
          Text(`${this.taskScheduleLabel(task)} · ${task.status === 'completed' ? '已完成' : '待完成'}`)
            .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
          if (this.taskOverdue(task)) {
            Text('已逾期').fontSize(AppTheme.metaSize).fontColor(AppTheme.red)
          }
        }.width('100%').alignItems(HorizontalAlign.Start)
      }.layoutWeight(1).constraintSize({ minHeight: 48 }).padding({ top: 8, bottom: 8 })
        .backgroundColor(Color.Transparent).borderRadius(AppTheme.controlRadius)
        .accessibilityText(`查看任务详情：${task.title}`).onClick(() => this.openDetails('task', task.task_id))
      AppIcon({ name: 'chevron', iconSize: 16, color: AppTheme.quiet })
    }.width('100%').alignItems(VerticalAlign.Top).padding(12)
      .backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
  }

  @Builder
  private TaskFilter(label: string, filter: string) {
    Button(label).layoutWeight(1).constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
      .fontColor(this.taskFilter === filter ? AppTheme.surface : AppTheme.quiet)
      .backgroundColor(this.taskFilter === filter ? AppTheme.actionBlue : AppTheme.surface)
      .borderRadius(AppTheme.controlRadius)
      .accessibilityText(`${label}${this.taskFilter === filter ? '，已选中' : ''}`)
      .onClick(() => this.selectTaskFilter(filter))
  }

  @Builder
  private AllTasks() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        this.TaskFilter('全部', 'all')
        this.TaskFilter('待完成', 'pending')
      }.width('100%')
      Row({ space: 8 }) {
        this.TaskFilter('已完成', 'completed')
        this.TaskFilter('无日期', 'undated')
      }.width('100%')
      Text(`当前显示 ${this.filteredTasks().length} 项 · 共 ${this.overview.tasks.length} 项`)
        .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
      if (this.filteredTasks().length === 0 && !this.loading && this.loaded) {
        Text('这个筛选下还没有待办。可以切换筛选，或添加一项新任务。')
          .fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet).width('100%').padding(16)
          .backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
      }
      ForEach(this.filteredTasks(), (task: PlanningTask) => {
        this.TaskRow(task)
      }, (task: PlanningTask) => `${task.task_id}-${this.planningRevision}`)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private ViewTab(label: string, view: string) {
    Button({ type: ButtonType.Normal }) {
      Text(label).fontSize(AppTheme.bodySize).fontWeight(this.currentView === view ? FontWeight.Bold : FontWeight.Regular)
        .fontColor(this.currentView === view ? AppTheme.actionBlue : AppTheme.quiet)
        .width('100%').textAlign(TextAlign.Center).wordBreak(WordBreak.BREAK_WORD)
    }.layoutWeight(1).constraintSize({ minHeight: 48 }).padding({ left: 4, right: 4, top: 8, bottom: 8 })
      .backgroundColor(this.currentView === view ? AppTheme.blueSoft : Color.Transparent)
      .borderRadius(AppTheme.controlRadius).accessibilityText(`${label}${this.currentView === view ? '，已选中' : ''}`)
      .onClick(() => this.selectView(view))
  }

  @Builder
  private WeekStrip() {
    Scroll() {
      Row({ space: 8 }) {
        ForEach(this.weekDays(), (day: CalendarDay) => {
          Button({ type: ButtonType.Normal }) {
            Column({ space: 4 }) {
              Text(day.date.substring(5)).fontSize(AppTheme.metaSize)
              Text(`${day.day}`).fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium)
              Text(`${day.courseCount + day.taskCount} 项`).fontSize(AppTheme.metaSize)
            }.width('100%').alignItems(HorizontalAlign.Center)
          }.width(56).constraintSize({ minHeight: 72 }).padding(8)
            .fontColor(this.selectedDate === day.date ? AppTheme.surface : AppTheme.ink)
            .backgroundColor(this.selectedDate === day.date ? AppTheme.actionBlue : AppTheme.surface)
            .borderRadius(AppTheme.controlRadius)
            .accessibilityText(`${day.date}，${day.courseCount} 节课，${day.taskCount} 项任务${this.selectedDate === day.date ? '，已选中' : ''}`)
            .onClick(() => this.selectDay(day.date))
        }, (day: CalendarDay) => `${day.key}-${day.courseCount}-${day.taskCount}-${this.selectedDate}`)
      }
    }.scrollable(ScrollDirection.Horizontal).width('100%').scrollBar(BarState.Off)
  }

  @Builder
  private ScheduleView() {
    Column({ space: AppTheme.sectionGap }) {
      this.WeekStrip()
      Row({ space: 8 }) {
        Button('回到今天').constraintSize({ minHeight: 48 }).layoutWeight(1).fontSize(AppTheme.bodySize)
          .fontColor(AppTheme.actionBlue).backgroundColor(AppTheme.surface).borderRadius(AppTheme.controlRadius)
          .onClick(() => this.selectDay(this.relativeDate(0)))
        Button(this.calendarExpanded ? '收起月历' : '展开月历').constraintSize({ minHeight: 48 }).layoutWeight(1)
          .fontSize(AppTheme.bodySize).fontColor(AppTheme.actionBlue).backgroundColor(AppTheme.blueSoft)
          .borderRadius(AppTheme.controlRadius).onClick(() => this.toggleCalendar())
      }.width('100%')
      if (this.calendarExpanded) {
        Column() { this.MonthCalendar() }.width('100%').padding(12)
          .backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
      }
      this.DayTimeline()
      Button('让 Agent 安排今晚复习').width('100%').constraintSize({ minHeight: 48 })
        .fontSize(AppTheme.bodySize).fontColor(AppTheme.actionBlue).backgroundColor(AppTheme.blueSoft)
        .borderRadius(AppTheme.controlRadius).onClick(() => this.onOpenAgent(this.reviewPrompt()))
    }.width('100%').padding({ left: AppTheme.pageInset, right: AppTheme.pageInset, top: 12, bottom: 24 })
  }

  @Builder
  private DetailContent(frame: PlanningDetailFrame) {
    Column({ space: 16 }) {
      if (frame.kind === 'draft') {
        Text('返回会保留草稿。点击加号先预览，明确确认后才加入任务列表。')
          .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
        this.TaskForm()
      } else if (frame.kind === 'action') {
        PlanningActionPanel({ state: this.actionState, active: this.active && !this.mutationBusy && !this.replanWriteBlocked,
          retryIntent: this.actionController?.retryIntent() ?? '', onConfirm: () => this.confirmPlanningAction(),
          onCancel: () => this.actionManager().cancel(), onCheck: () => this.actionManager().check(),
          onDismiss: () => this.dismissAction(), onOpenTask: (id: string) => this.openDetails('task', id),
          onOpenPlan: (id: string) => this.openDetails('plan', id) })
      } else if (frame.kind === 'task-edit') {
        this.TaskEditor()
      } else if (frame.kind === 'plan-edit') {
        this.PlanEditor()
      } else if (frame.kind === 'task') {
        ForEach(this.tasksForId(frame.id), (task: PlanningTask) => {
          Column({ space: 12 }) {
            this.PlanTask(task)
            if (task.plan_id !== null) {
              Text('属于已确认计划；完成状态会同步到目标进度。').fontSize(AppTheme.metaSize)
                .fontColor(AppTheme.quiet).width('100%')
              Button('查看所属计划').width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
                .fontColor(AppTheme.actionBlue).backgroundColor(AppTheme.blueSoft).borderRadius(AppTheme.controlRadius)
                .onClick(() => this.openDetails('plan', task.plan_id ?? ''))
            }
            Button('编辑任务与时间').width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
              .fontColor(AppTheme.actionBlue).backgroundColor(AppTheme.blueSoft).borderRadius(AppTheme.controlRadius)
              .enabled(!this.writesBlocked()).onClick(() => this.beginTaskEdit(task))
            Button('预览删除任务').width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
              .fontColor(AppTheme.red).backgroundColor(AppTheme.redSoft).borderRadius(AppTheme.controlRadius)
              .enabled(!this.writesBlocked()).onClick(() => this.requestDelete(task))
          }.width('100%')
        }, (task: PlanningTask) => `${task.task_id}-${this.planningRevision}`)
      } else if (frame.kind === 'plan') {
        ForEach(this.plansForId(frame.id), (plan: PlanSummary) => {
          Column({ space: 12 }) {
            Text(plan.title).fontSize(AppTheme.sectionTitle).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
              .width('100%').wordBreak(WordBreak.BREAK_WORD)
            Text(`${this.planStatus(plan)} · ${plan.completed_count}/${plan.task_count} 项已完成`)
              .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
            Text(plan.target_date === null ? '未设截止日' : `截止 ${plan.target_date}`)
              .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
            this.PlanBody(plan)
            Button('编辑计划信息').width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
              .fontColor(AppTheme.actionBlue).backgroundColor(AppTheme.blueSoft).borderRadius(AppTheme.controlRadius)
              .enabled(!this.writesBlocked()).onClick(() => this.beginPlanEdit(plan))
            Button('预览删除计划').width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
              .fontColor(AppTheme.red).backgroundColor(AppTheme.redSoft).borderRadius(AppTheme.controlRadius)
              .enabled(!this.writesBlocked()).onClick(() => this.requestPlanDelete(plan))
          }.width('100%').padding(AppTheme.cardInset).backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
        }, (plan: PlanSummary) => `${plan.plan_id}-${this.planningRevision}`)
      }
      if (frame.kind === 'invalid' ||
        (frame.kind === 'task' && this.tasksForId(frame.id).length === 0) ||
        (frame.kind === 'plan' && this.plansForId(frame.id).length === 0)) {
        Text(this.loading ? '正在读取对应内容…' : this.errorText.length > 0 || !this.loaded ?
          '暂时无法读取对应内容，请重新加载。' : '此项目已不存在，或不属于当前账号。')
          .fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet).width('100%')
        Button('重新加载计划').width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
          .fontColor(AppTheme.actionBlue).backgroundColor(AppTheme.blueSoft).borderRadius(AppTheme.controlRadius)
          .enabled(!this.loading).onClick(() => this.reload(true))
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
      .padding({ left: AppTheme.pageInset, right: AppTheme.pageInset, top: 12, bottom: 24 })
  }

  build() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        if (this.detailKind.length > 0) {
          Button({ type: ButtonType.Circle }) {
            AppIcon({ name: 'back', iconSize: 22, color: AppTheme.actionBlue })
          }.width(48).height(48).backgroundColor(AppTheme.surface)
            .accessibilityText(this.backLabel())
            .onClick(() => this.closeDetails())
        }
        Column({ space: 4 }) {
          Text(this.detailKind.length > 0 ? this.detailTitle() : '计划').fontSize(AppTheme.pageTitle)
            .fontWeight(FontWeight.Bold).fontColor(AppTheme.ink).width('100%')
          if (this.detailKind.length === 0) {
            Text('让每一步都有着落').fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
          }
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        if (this.detailKind.length === 0) {
          Button('添加待办').constraintSize({ minHeight: 48 }).padding(12).fontSize(AppTheme.bodySize)
            .fontColor(AppTheme.surface).backgroundColor(AppTheme.actionBlue).borderRadius(AppTheme.controlRadius)
            .onClick(() => this.openDetails('draft'))
        }
      }.width('100%').padding({ left: AppTheme.pageInset, right: AppTheme.pageInset, top: 16 })
      if (this.errorText.length > 0) {
        Row({ space: 8 }) {
          Text(this.errorText).fontSize(AppTheme.metaSize).fontColor(AppTheme.red).layoutWeight(1)
            .wordBreak(WordBreak.BREAK_WORD)
          Button('刷新').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize).fontColor(AppTheme.red)
            .backgroundColor(Color.Transparent).enabled(!this.loading).onClick(() => this.reload(true))
        }.width('100%').padding({ left: AppTheme.pageInset, right: AppTheme.pageInset })
      }
      if (this.loading) {
        Row({ space: 8 }) {
          LoadingProgress().width(18).height(18).color(AppTheme.actionBlue)
          Text('正在更新计划…').fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet)
        }.width('100%').padding({ left: AppTheme.pageInset, right: AppTheme.pageInset })
      }
      if (this.mutationBusy) {
        Text('正在保存任务更改…').fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
          .padding({ left: AppTheme.pageInset, right: AppTheme.pageInset })
      }
      if (this.actionState.phase !== 'idle' && this.detailKind !== 'action') {
        Button(this.actionBlocksWrites() ? '查看待处理变更 / 核对结果' : '查看上次变更结果').width('100%').constraintSize({ minHeight: 48 })
          .fontSize(AppTheme.bodySize).fontColor(AppTheme.actionBlue).backgroundColor(AppTheme.blueSoft)
          .borderRadius(AppTheme.controlRadius).onClick(() => this.openDetails('action'))
          .padding({ left: AppTheme.pageInset, right: AppTheme.pageInset })
      }
      PlanningConflictsPanel({ baseUrl: this.baseUrl, token: this.token,
        refreshKey: this.conflictRefresh, active: this.active && (this.detailKind.length === 0 || this.detailKind === 'conflicts'),
        compact: this.detailKind !== 'conflicts', onOpenDetails: () => this.openDetails('conflicts'),
        writeBlocked: this.mutationBusy || this.actionBlocksWrites(),
        onWriteStateChanged: (blocked: boolean) => this.replanWriteBlocked = blocked,
        onApplied: () => this.replanApplied() })
        .visibility(this.detailKind.length === 0 || this.detailKind === 'conflicts' ? Visibility.Visible : Visibility.None)
        .layoutWeight(this.detailKind === 'conflicts' ? 1 : 0)
        .padding({ left: AppTheme.pageInset, right: AppTheme.pageInset })
      if (this.detailKind.length === 0) {
        Row({ space: 4 }) {
          this.ViewTab('日程', 'schedule')
          this.ViewTab('目标计划', 'plans')
          this.ViewTab('全部待办', 'tasks')
        }.width('100%').padding({ left: AppTheme.pageInset, right: AppTheme.pageInset })
      }
      Stack({ alignContent: Alignment.TopStart }) {
        // Keep each list and Scroller mounted: opening details or switching views does not reset scroll.
        Scroll(this.scheduleScroller) { this.ScheduleView() }.width('100%').height('100%')
          .visibility(this.detailKind.length === 0 && this.currentView === 'schedule' ? Visibility.Visible : Visibility.Hidden)
        Scroll(this.plansScroller) {
          Column() { this.ConfirmedPlans() }.width('100%')
            .padding({ left: AppTheme.pageInset, right: AppTheme.pageInset, top: 12, bottom: 24 })
        }.width('100%').height('100%')
          .visibility(this.detailKind.length === 0 && this.currentView === 'plans' ? Visibility.Visible : Visibility.Hidden)
        Scroll(this.tasksScroller) {
          Column() { this.AllTasks() }.width('100%')
            .padding({ left: AppTheme.pageInset, right: AppTheme.pageInset, top: 12, bottom: 24 })
        }.width('100%').height('100%')
          .visibility(this.detailKind.length === 0 && this.currentView === 'tasks' ? Visibility.Visible : Visibility.Hidden)
        // Keep earlier detail Scroll nodes mounted while following a task/plan link.
        ForEach(this.detailStack, (frame: PlanningDetailFrame) => {
          if (frame.kind !== 'conflicts') {
            Scroll() { this.DetailContent(frame) }.width('100%').height('100%').backgroundColor(AppTheme.canvas)
              .visibility(frame.key === this.topDetailKey() ? Visibility.Visible : Visibility.Hidden)
          }
        }, (frame: PlanningDetailFrame) => `${frame.key}`)
      }.width('100%').layoutWeight(1).visibility(this.detailKind === 'conflicts' ? Visibility.None : Visibility.Visible)
    }.width('100%').height('100%').backgroundColor(AppTheme.canvas)
      .onAreaChange((_oldArea, newArea) => { this.pageWidth = Number(newArea.width); })
  }
}
