import { ReviewPeriod } from '../model/ReviewModels';
import { PlanningOverview, PlanningTask, PlanSummary, TimetableEntry, UserProfile, DataEvidence } from '../model/ApiModels';
import { CampusFlowApi } from '../services/CampusFlowApi';
import { CampusFlowRequestError } from '../utils/AgentFeedback';
import { AppIcon } from '../components/AppIcon';
import { AppIllustration } from '../components/AppIllustration';
import { EvidencePanel } from '../components/EvidencePanel';
import { hasFreshEvidence, evidenceSummary } from '../utils/EvidencePresentation';
import { validateTimetableEntry } from '../utils/OnboardingTimetable';
import { TaskCaptureIntent } from '../utils/TaskCaptureTypes';
import { CourseRouteIntent } from '../utils/CourseRouteIntent';
import { TodayGroups, FreeWindowResult, partitionToday, findFreeWindow } from '../utils/FreeWindows';
import { AppTheme } from '../theme/AppTheme';
import { ThemePalette, themePalette } from '../theme/ThemePalette';
import { AgendaRow, DailyAgenda, buildDailyAgenda, labelNext, shanghaiDate, shanghaiTime } from '../utils/DailyAgenda';

@Component
export struct HomePage {
  @StorageLink('campusflowThemePalette') private palette: ThemePalette = themePalette('paper-green');
  @Watch('connectionChanged') @Prop baseUrl: string;
  @Watch('connectionChanged') @Prop token: string;
  @Prop user: UserProfile;
  @Watch('refreshToday') @Prop refreshKey: number = 0;
  @Watch('activityChanged') @Prop active: boolean = true;
  onOpenAgent: () => void = () => {};
  onOpenPlan: (view: string) => void = () => {};
  onOpenTaskDetails: (id: string) => void = () => {};
  onOpenPlanDetails: (id: string) => void = () => {};
  onOpenRoute: () => void = () => {};
  onOpenCapture: (intent: TaskCaptureIntent) => void = () => {};
  onOpenCourseRoute: (intent: CourseRouteIntent) => void = () => {};
  onOpenServices: () => void = () => {};
  onOpenProfile: () => void = () => {};
  onPlanningChanged: () => void = () => {};
  @Prop statusLockedTaskIds: string[] = [];
  onTaskStatus: (task: PlanningTask) => void = () => {};
  onOpenStatus: (taskId: string) => void = () => {};
  onOpenFocus: (task: PlanningTask) => void = () => {};
  onOpenReview: (period: ReviewPeriod, anchor: string) => void = () => {};
  onOpenFocusRecords: () => void = () => {};
  @State private courses: TimetableEntry[] = [];
  @State private overview: PlanningOverview = {
    plans: [], tasks: [], total_tasks: 0, completed_tasks: 0, due_today: 0, overdue_tasks: 0, progress: 0
  };
  @State private loading: boolean = true;
  @State private errorText: string = '';
  @State private busyTaskId: string = '';
  @State private nowMs: number = Date.now();
  @State private coursePhase: string = 'idle';
  @State private taskPhase: string = 'idle';
  @State private courseReadAt: number = 0;
  @State private taskReadAt: number = 0;
  @State private timetableRevision: string = '';
  @State private courseEvidence: DataEvidence[] = [];
  @State private sourceExpanded: boolean = false;
  @State private earlierExpanded: boolean = false;
  @State private bufferMinutes: number = 0;
  @State private bufferExpanded: boolean = false;
  @State private gapDismissedDate: string = '';
  @State private dataRevision: number = 0;
  private routeRequest: number = 0;
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

  private connectionChanged(): void {
    this.requestRevision++; this.taskOperationRevision++; this.busyTaskId = '';
    this.courses = []; this.overview = { plans: [], tasks: [], total_tasks: 0, completed_tasks: 0,
      due_today: 0, overdue_tasks: 0, progress: 0 };
    this.coursePhase = 'idle'; this.taskPhase = 'idle'; this.courseReadAt = 0; this.taskReadAt = 0;
    this.courseEvidence = []; this.timetableRevision = ''; this.errorText = '';
    this.sourceExpanded = false; this.earlierExpanded = false; this.gapDismissedDate = ''; this.bufferMinutes = 0; this.bufferExpanded = false;
    this.dataRevision++; this.activityChanged();
  }

  private async loadToday(): Promise<void> {
    if (!this.pageActive || !this.active || this.token.length === 0) { return; }
    const revision = ++this.requestRevision;
    const token = this.token; const baseUrl = this.baseUrl;
    this.loading = true; this.coursePhase = 'loading'; this.taskPhase = 'loading'; this.errorText = '';
    const api = new CampusFlowApi(baseUrl, token);
    // Each source settles independently within the same account/read generation.
    await Promise.all([this.loadCourses(api, revision, token, baseUrl), this.loadTasks(api, revision, token, baseUrl)]);
    if (this.isCurrent(revision, token, baseUrl)) {
      this.loading = false; this.nowMs = Date.now();
      if (this.coursePhase !== 'ready' || this.taskPhase !== 'ready') {
        this.errorText = '部分安排未能更新，标注为旧记录的内容可能不是最新。请重试读取。';
      }
    }
  }

  private async loadCourses(api: CampusFlowApi, revision: number, token: string, baseUrl: string): Promise<void> {
    try {
      const snapshot = await api.timetable();
      if (!this.isCurrent(revision, token, baseUrl)) { return; }
      if (snapshot === null || !Array.isArray(snapshot.entries) || snapshot.entries.length > 500 ||
        !/^[0-9a-f]{64}$/.test(snapshot.revision) || !snapshot.entries.every((course: TimetableEntry) =>
          validateTimetableEntry(course).valid && course.date === course.date.trim() && course.start_time === course.start_time.trim() &&
          course.end_time === course.end_time.trim() && typeof course.location === 'string' && typeof course.teacher === 'string')) {
        throw new Error('invalid timetable');
      }
      this.courses = snapshot.entries; this.timetableRevision = snapshot.revision;
      this.courseEvidence = snapshot.evidence ?? []; this.courseReadAt = Date.now();
      this.coursePhase = 'ready'; this.dataRevision++;
    } catch {
      if (this.isCurrent(revision, token, baseUrl)) { this.coursePhase = this.courseReadAt > 0 ? 'stale' : 'error'; }
    }
  }

  private async loadTasks(api: CampusFlowApi, revision: number, token: string, baseUrl: string): Promise<void> {
    try {
      const overview = await api.planning();
      if (!this.isCurrent(revision, token, baseUrl)) { return; }
      if (overview === null || !Array.isArray(overview.tasks) || !Array.isArray(overview.plans)) { throw new Error('invalid planning'); }
      this.overview = overview; this.taskReadAt = Date.now(); this.taskPhase = 'ready'; this.dataRevision++;
    } catch {
      if (this.isCurrent(revision, token, baseUrl)) { this.taskPhase = this.taskReadAt > 0 ? 'stale' : 'error'; }
    }
  }

  private groups(): TodayGroups { return partitionToday(this.agenda().rows, this.nowMs); }

  private sourceLabel(kind: string): string {
    const phase = kind === 'course' ? this.coursePhase : this.taskPhase;
    const time = kind === 'course' ? this.courseReadAt : this.taskReadAt;
    const name = kind === 'course' ? '课表' : '待办';
    if (phase === 'ready') { return `${name}已读取`; }
    if (phase === 'loading') { return `${name}更新中${time > 0 ? '（显示旧记录）' : ''}`; }
    if (phase === 'stale') { return `${name}未更新（显示旧记录）`; }
    return `${name}尚未读取`;
  }

  private readTime(value: number): string {
    return value > 0 ? `${shanghaiDate(value)} ${shanghaiTime(value)}（北京时间）` : '尚无成功读取';
  }

  private sourcesReady(): boolean {
    return this.active && this.pageActive && !this.loading && this.busyTaskId.length === 0 &&
      this.coursePhase === 'ready' && this.taskPhase === 'ready' && hasFreshEvidence(this.courseEvidence, this.nowMs);
  }

  private freeTime(): FreeWindowResult {
    return findFreeWindow(this.courses, this.overview.tasks, this.nowMs, this.bufferMinutes, this.sourcesReady());
  }

  private openCapture(): void {
    if (!this.active || !this.pageActive || this.token.length === 0) { return; }
    this.nowMs = Date.now();
    this.onOpenCapture({ text: '', date: '', time: '', durationMinutes: null,
      anchorDate: shanghaiDate(this.nowMs), timezone: 'Asia/Shanghai', source: 'home' });
  }

  private useFreeTime(): void {
    this.nowMs = Date.now();
    const window = this.freeTime().window;
    if (window === null || this.gapDismissedDate === window.date) { return; }
    this.gapDismissedDate = window.date;
    this.onOpenCapture({ text: '复习', date: window.date, time: window.startTime,
      durationMinutes: 25, anchorDate: window.date, timezone: 'Asia/Shanghai', source: 'gap' });
  }

  private setBuffer(value: number): void {
    if ([0, 5, 10, 15].includes(value)) { this.bufferMinutes = value; }
  }

  private courseFor(row: AgendaRow): TimetableEntry | null {
    if (row.kind !== 'course') { return null; }
    // Resolve the row's source index only within this current snapshot, then verify all displayed facts.
    // The navigation payload is the complete course plus revision; this index is never an identity/ACK.
    const course = this.courses.find((item: TimetableEntry, index: number) =>
      row.id === `course-${index}-${item.date}-${item.start_time}` && row.title === item.title &&
      row.location === item.location && row.startTime === item.start_time && row.endTime === item.end_time);
    return course === undefined ? null : course;
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

  private focusCandidates(): PlanningTask[] {
    return this.taskPhase === 'ready' ? this.overview.tasks.filter((task: PlanningTask) => task.status === 'pending').slice(0, 3) : [];
  }
  private focusRequested(task: PlanningTask): void {
    if (!this.active || !this.pageActive || this.taskPhase !== 'ready') { return; }
    const current = this.overview.tasks.find((item: PlanningTask) => item.task_id === task.task_id);
    if (current !== undefined) { this.onOpenFocus(current); }
  }

  private statusLabel(task: PlanningTask): string {
    if (this.statusLockedTaskIds.includes(task.task_id)) { return '状态结果待核对'; }
    if (task.status !== 'completed') { return '标记完成'; }
    return task.completion_operation_id ? '恢复未完成' : '这次完成未保留可恢复凭据';
  }

  private async toggleTask(task: PlanningTask): Promise<void> {
    if (!this.active || !this.pageActive || this.token.length === 0) { return; }
    if (this.statusLockedTaskIds.includes(task.task_id)) { this.onOpenStatus(task.task_id); return; }
    this.onTaskStatus(task);
  }

  private toggleAgendaTask(row: AgendaRow): void {
    const task = this.overview.tasks.find((item: PlanningTask) => item.task_id === row.taskId);
    if (task !== undefined) { this.toggleTask(task); }
  }

  private nextAction(row: AgendaRow): void {
    if (!this.active || !this.pageActive || this.token.length === 0) { return; }
    if (row.taskId !== null) { this.onOpenTaskDetails(row.taskId); }
    else {
      const course = this.courseFor(row);
      if (course === null) { this.errorText = '这节课已变化，请更新日程后再打开路线。'; return; }
      const evidence = JSON.parse(JSON.stringify(this.courseEvidence)) as DataEvidence[];
      if (this.coursePhase !== 'ready') {
        evidence.push({ source_id: 'home-timetable-read', label: '本次课表读取尚未完成', kind: 'reference', status: 'unverified',
          updated_at: null, expires_at: null, url: null, note: '课程来自上次成功读取的记录；当前地点是否变化仍需核对。' });
      }
      this.onOpenCourseRoute({ requestId: ++this.routeRequest, school: this.user.school ?? '', campus: this.user.campus ?? '',
        course: { date: course.date, title: course.title, start_time: course.start_time, end_time: course.end_time,
          location: course.location, teacher: course.teacher }, timetableRevision: this.timetableRevision,
        evidence: evidence });
    }
  }

  private reviewRequested(): void {
    if (this.active) { this.onOpenReview('day', shanghaiDate(this.nowMs)); }
  }

  @Builder
  private PlanProgressCard(plan: PlanSummary) {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text(plan.title).fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium)
            .fontColor(this.palette.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
          Text(plan.target_date === null ? '持续计划' : `目标 ${plan.target_date}`)
            .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Column({ space: 4 }) {
          Text(`${plan.progress}%`).fontSize(24).fontWeight(FontWeight.Bold).fontColor(this.palette.accent)
          Text(plan.status === 'overdue' ? '已逾期' : '进行中').fontSize(this.palette.metaSize)
            .fontColor(plan.status === 'overdue' ? this.palette.danger : this.palette.quiet)
        }.alignItems(HorizontalAlign.End)
      }.width('100%').alignItems(VerticalAlign.Top)
      if (plan.summary.length > 0) {
        Text(plan.summary).fontSize(this.palette.bodySize).fontColor(this.palette.quiet)
          .maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
          .wordBreak(WordBreak.BREAK_WORD)
      }
      Row() {
        Row().height(4).width(`${plan.progress}%`).backgroundColor(this.palette.accent).borderRadius(2)
      }.width('100%').height(4).backgroundColor(this.palette.line).borderRadius(2)
      Row({ space: 12 }) {
        Text(`${plan.completed_count}/${plan.task_count} 项完成`)
          .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).layoutWeight(1)
        Button({ type: ButtonType.Normal }) {
          Text('查看计划').fontSize(this.palette.metaSize).fontColor(this.palette.accent).wordBreak(WordBreak.BREAK_WORD)
        }.constraintSize({ minHeight: 48, minWidth: 80 }).padding({ left: 8, right: 8, top: 8, bottom: 8 })
          .backgroundColor(Color.Transparent).borderRadius(this.palette.controlRadius)
          .onClick(() => this.onOpenPlanDetails(plan.plan_id))
      }.width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start).padding(this.palette.cardInset)
      .backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
  }

  @Builder
  private TaskRow(task: PlanningTask, subtitle: string) {
    Row({ space: 4 }) {
      Button({ type: ButtonType.Normal }) {
        if (task.status === 'completed') {
          AppIcon({ name: 'check', iconSize: 22, color: this.palette.success })
        } else {
          Circle().width(20).height(20).fill(Color.Transparent).stroke(this.palette.quiet).strokeWidth(1.5)
        }
      }.width(48).height(48).backgroundColor(Color.Transparent).enabled(this.active && this.pageActive)
        .accessibilityText(`${this.statusLabel(task)}：${task.title}`)
        .onClick(() => this.toggleTask(task))
      Button({ type: ButtonType.Normal }) {
        Column({ space: 5 }) {
          Text(task.title).fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium)
            .fontColor(task.status === 'completed' ? this.palette.quiet : this.palette.ink)
            .width('100%').wordBreak(WordBreak.BREAK_WORD)
          Text(subtitle).fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
            .wordBreak(WordBreak.BREAK_WORD)
          if (task.status === 'completed' || this.statusLockedTaskIds.includes(task.task_id)) {
            Text(this.statusLabel(task)).fontSize(this.palette.metaSize).fontColor(this.palette.accent).width('100%')
              .wordBreak(WordBreak.BREAK_WORD)
          }
        }.width('100%').alignItems(HorizontalAlign.Start)
      }.layoutWeight(1).constraintSize({ minHeight: 60 }).padding({ top: 12, bottom: 12, right: 12 })
        .backgroundColor(Color.Transparent).onClick(() => this.onOpenTaskDetails(task.task_id))
    }.width('100%').padding({ left: 4 })
  }

  @Builder
  private NextCard(row: AgendaRow) {
    Column({ space: 16 }) {
      Row({ space: 12 }) {
        Text(row.startMs <= this.nowMs && row.endMs !== null && row.endMs > this.nowMs ? '正在进行' : '接下来').fontSize(this.palette.metaSize)
          .fontWeight(FontWeight.Medium).fontColor(this.palette.quiet).layoutWeight(1)
        Text(labelNext(row, this.nowMs)).fontSize(this.palette.metaSize).fontColor(this.palette.accent)
          .padding({ top: 5, bottom: 5, left: 8, right: 8 }).backgroundColor(this.palette.accentSoft).borderRadius(6)
      }.width('100%')
      Row({ space: 16 }) {
        Column({ space: 6 }) {
          Text(row.startTime).fontSize(this.palette.pageTitle).fontWeight(FontWeight.Bold).fontColor(this.palette.ink)
          if (row.date !== this.agenda().today) {
            Text(row.date.substring(5)).fontSize(this.palette.metaSize).fontColor(this.palette.quiet)
          }
          if (row.endTime.length > 0) {
            Text(`— ${row.endDate !== row.date ? row.endDate.substring(5) + ' ' : ''}${row.endTime}`)
              .fontSize(this.palette.metaSize).fontColor(this.palette.quiet)
          }
        }.alignItems(HorizontalAlign.Start)
        Column({ space: 6 }) {
          Text(row.title).fontSize(this.palette.sectionTitle).fontWeight(FontWeight.Bold).fontColor(this.palette.ink)
            .width('100%').wordBreak(WordBreak.BREAK_WORD)
          Text(row.location.length > 0 ? row.location : (row.kind === 'course' ? '地点未填写' : '待办事项'))
            .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
        }.layoutWeight(1).alignItems(HorizontalAlign.Start).padding({ left: 16 })
          .border({ width: { left: 1 }, color: this.palette.line })
      }.width('100%').alignItems(VerticalAlign.Top)
      Button({ type: ButtonType.Normal }) {
        Row({ space: 8 }) {
          AppIcon({ name: row.kind === 'course' ? 'route' : 'calendar', iconSize: 19, color: this.palette.accent })
          Text(row.kind === 'course' ? '上课路线' : '查看任务详情').fontSize(this.palette.metaSize)
            .fontColor(this.palette.accent).layoutWeight(1).wordBreak(WordBreak.BREAK_WORD)
          AppIcon({ name: 'chevron', iconSize: 16, color: this.palette.accent })
        }.width('100%')
      }.width('100%').constraintSize({ minHeight: 48 }).padding(12)
        .backgroundColor(this.palette.accentSoft).borderRadius(this.palette.controlRadius).onClick(() => this.nextAction(row))
    }.width('100%').padding(this.palette.cardInset).backgroundColor(this.palette.surface)
      .borderRadius(this.palette.cardRadius).border({ width: { left: 3 }, color: this.palette.accent })
  }

  @Builder
  private TimelineRow(row: AgendaRow) {
    Row({ space: 10 }) {
      Column({ space: 5 }) {
        Text(row.startTime).fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium).fontColor(this.palette.ink)
        if (row.date !== this.agenda().today) {
          Text(row.date.substring(5)).fontSize(this.palette.metaSize).fontColor(this.palette.quiet)
        }
        if (row.endTime.length > 0) {
          Text(`${row.endDate !== row.date ? row.endDate.substring(5) + ' ' : ''}${row.endTime}`)
            .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).wordBreak(WordBreak.BREAK_WORD)
        }
      }.width(54).alignItems(HorizontalAlign.Start).padding({ top: 14 })
      Circle().width(6).height(6).fill(row.done ? this.palette.success : this.palette.accent).margin({ top: 19 })
      if (row.taskId !== null) {
        Button({ type: ButtonType.Normal }) {
          Column({ space: 5 }) {
            Text(row.title).fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium)
              .fontColor(row.done ? this.palette.quiet : this.palette.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
            Text(row.done ? '已完成' : (row.endMs === null ? '结束时间待核对' : (row.planId !== null ? '来自目标计划' : '待办事项')))
              .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
            if (row.location.length > 0) {
              Text(row.location).fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
                .wordBreak(WordBreak.BREAK_WORD)
            }
          }.width('100%').alignItems(HorizontalAlign.Start)
        }.layoutWeight(1).constraintSize({ minHeight: 64 }).padding({ top: 12, bottom: 12 })
          .backgroundColor(Color.Transparent).onClick(() => this.onOpenTaskDetails(row.taskId ?? ''))
        Button({ type: ButtonType.Normal }) {
          if (row.done) { Text('恢复未完成').fontSize(this.palette.metaSize).fontColor(this.palette.accent).wordBreak(WordBreak.BREAK_WORD) }
          else { Circle().width(20).height(20).fill(Color.Transparent).stroke(this.palette.quiet).strokeWidth(1.5) }
        }.width(row.done ? 88 : 48).constraintSize({ minHeight: 48 }).backgroundColor(Color.Transparent).enabled(this.active && this.pageActive)
          .accessibilityText(`${row.done ? '核对恢复未完成' : '标记完成'}：${row.title}`).onClick(() => this.toggleAgendaTask(row))
      } else {
        Button({ type: ButtonType.Normal }) {
        Column({ space: 5 }) {
          Text(row.title).fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium).fontColor(this.palette.ink)
            .width('100%').wordBreak(WordBreak.BREAK_WORD)
          Text(row.location.length > 0 ? row.location : '课程 · 地点未填写').fontSize(this.palette.metaSize)
            .fontColor(this.palette.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
          Text('课程 · 查看上课路线').fontSize(this.palette.metaSize).fontColor(this.palette.accent).width('100%')
        }.width('100%').alignItems(HorizontalAlign.Start)
        }.layoutWeight(1).constraintSize({ minHeight: 64 }).padding({ top: 12, bottom: 12, right: 8 })
          .backgroundColor(Color.Transparent).onClick(() => this.nextAction(row))
      }
    }.width('100%').alignItems(VerticalAlign.Top).padding({ left: 16, right: 8 })
  }

  @Builder
  private TimelineList(rows: AgendaRow[]) {
    Column() {
      ForEach(rows, (row: AgendaRow, index: number) => {
        this.TimelineRow(row)
        if (index < rows.length - 1) { Divider().color(this.palette.line).margin({ left: 86, right: 16 }) }
      }, (row: AgendaRow) => `${row.id}-${row.done}-${this.dataRevision}`)
    }.width('100%').backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
  }

  @Builder
  private Sources() {
    Column({ space: 8 }) {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 8 }) {
          Text(`${this.sourceLabel('course')} · ${this.sourceLabel('task')}`)
            .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).layoutWeight(1).wordBreak(WordBreak.BREAK_WORD)
          Text(this.sourceExpanded ? '收起' : '来源').fontSize(this.palette.metaSize).fontColor(this.palette.accent)
        }.width('100%')
      }.width('100%').constraintSize({ minHeight: 48 }).padding(0).backgroundColor(Color.Transparent)
        .accessibilityText('展开或收起今日安排的数据来源').onClick(() => this.sourceExpanded = !this.sourceExpanded)
      if (this.sourceExpanded) {
        Text(`课表读取：${this.readTime(this.courseReadAt)}\n待办读取：${this.readTime(this.taskReadAt)}`)
          .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
        Text('读取时间不等于原始资料更新时间。两项分别读取，最终保存仍会核对最新安排。')
          .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
        EvidencePanel({ evidence: this.courseEvidence, active: this.active && this.sourceExpanded })
      } else if (this.courseReadAt > 0 && !hasFreshEvidence(this.courseEvidence, this.nowMs)) {
        Text(`课表${evidenceSummary(this.courseEvidence, this.nowMs)}；暂不建议空档。`)
          .fontSize(this.palette.metaSize).fontColor(this.palette.warning).width('100%').wordBreak(WordBreak.BREAK_WORD)
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private BufferChoice(value: number) {
    Button(`${value} 分钟`).constraintSize({ minHeight: 48 }).layoutWeight(1).padding(10)
      .fontSize(this.palette.metaSize).fontColor(this.bufferMinutes === value ? this.palette.onAccent : this.palette.accent)
      .backgroundColor(this.bufferMinutes === value ? this.palette.accent : this.palette.surface)
      .borderRadius(this.palette.controlRadius).accessibilityText(`在定时安排前后预留 ${value} 分钟${this.bufferMinutes === value ? '，已选中' : ''}`)
      .onClick(() => this.setBuffer(value))
  }

  @Builder
  private FreeTimeHint() {
    if (this.sourcesReady() && this.gapDismissedDate !== this.agenda().today) {
      Column({ space: 12 }) {
        Row({ space: 8 }) {
          Text('留一小段时间').fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium).fontColor(this.palette.ink).layoutWeight(1)
          Button('今天先不提示').fontSize(this.palette.metaSize).fontColor(this.palette.quiet).backgroundColor(Color.Transparent)
            .constraintSize({ minHeight: 48 }).padding(8).onClick(() => this.gapDismissedDate = this.agenda().today)
        }.width('100%')
        if (this.freeTime().window !== null) {
          Text(`${this.agenda().today} ${this.freeTime().window!.startTime}–${this.freeTime().window!.endTime}`)
            .fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium).fontColor(this.palette.accent).width('100%')
          Text(`按最近读取的定时安排找到这段空档，另有 ${this.freeTime().untimedCount} 项未指定时刻；未包含临时安排。`)
            .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
        } else {
          Text(this.freeTime().reason).fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
        }
        Text(this.bufferMinutes === 0 ? '未预留额外缓冲。可自行选择，不代表通勤时间估算。' :
          `已选择在定时安排前后各留 ${this.bufferMinutes} 分钟；这不是通勤时间估算。`)
          .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
        Button(this.bufferExpanded ? '收起缓冲选项' : '调整预留缓冲').constraintSize({ minHeight: 48 })
          .fontSize(this.palette.metaSize).fontColor(this.palette.accent).backgroundColor(Color.Transparent).padding(8)
          .onClick(() => this.bufferExpanded = !this.bufferExpanded)
        if (this.bufferExpanded) {
          Row({ space: 8 }) { this.BufferChoice(0); this.BufferChoice(5) }.width('100%')
          Row({ space: 8 }) { this.BufferChoice(10); this.BufferChoice(15) }.width('100%')
        }
        if (this.freeTime().window !== null) {
          Button('留 25 分钟复习').width('100%').constraintSize({ minHeight: 48 }).padding(12)
            .fontSize(this.palette.bodySize).fontColor(this.palette.accent).backgroundColor(this.palette.surface)
            .borderRadius(this.palette.controlRadius).onClick(() => this.useFreeTime())
          Text('先填入可改草稿，确认前还会核对最新安排。').fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
        }
      }.width('100%').padding(this.palette.cardInset).alignItems(HorizontalAlign.Start)
        .backgroundColor(this.palette.accentSoft).borderRadius(this.palette.cardRadius)
    }
  }

  @Builder
  private SectionTitle(title: string, link: string = '', view: string = 'agenda') {
    Row({ space: 8 }) {
      Text(title).fontSize(this.palette.sectionTitle).fontWeight(FontWeight.Bold).fontColor(this.palette.ink).layoutWeight(1)
      if (link.length > 0) {
        Button(link).fontSize(this.palette.metaSize).fontColor(this.palette.accent).backgroundColor(Color.Transparent)
          .constraintSize({ minHeight: 48 }).padding(8).onClick(() => this.onOpenPlan(view))
      }
    }.width('100%')
  }

  @Builder
  private FocusEntry() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Text('专注一件事').fontSize(this.palette.sectionTitle).fontWeight(FontWeight.Medium).fontColor(this.palette.ink).layoutWeight(1)
        Button('查看记录').constraintSize({ minHeight: 48 }).fontColor(this.palette.accent).backgroundColor(Color.Transparent)
          .onClick(() => this.onOpenFocusRecords())
      }.width('100%')
      ForEach(this.focusCandidates(), (task: PlanningTask) => {
        Button({ type: ButtonType.Normal }) {
          Column({ space: 5 }) {
            Text(task.title).fontSize(this.palette.bodySize).fontColor(this.palette.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
            Text('为这项待办开始专注记录').fontSize(this.palette.metaSize).fontColor(this.palette.accent).width('100%')
          }.width('100%').alignItems(HorizontalAlign.Start)
        }.width('100%').constraintSize({ minHeight: 64 }).padding(14).backgroundColor(this.palette.surface).borderRadius(this.palette.controlRadius)
          .onClick(() => this.focusRequested(task))
      }, (task: PlanningTask) => `${task.task_id}-${this.refreshKey}`)
      Text(this.focusCandidates().length > 0 ? '先列出 3 项以内的待办；其他任务可从计划详情开始。记录结束后，再决定是否标记完成。' :
        this.taskPhase === 'ready' ? '当前没有未完成待办。可从计划中选择具体任务，或回看专注记录。' : '任务尚未核对成功，先查看已有记录或重试读取任务。')
        .fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  build() {
    Scroll(this.scroller) {
      Column({ space: this.palette.sectionGap }) {
        Row({ space: 12 }) {
          Column({ space: 6 }) {
            Text('今日').fontSize(this.palette.pageTitle).fontWeight(FontWeight.Bold).fontColor(this.palette.ink).width('100%')
            Text(`${this.dateLabel()} · ${this.greeting()}`).fontSize(this.palette.metaSize).fontColor(this.palette.quiet)
              .width('100%').wordBreak(WordBreak.BREAK_WORD)
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Button({ type: ButtonType.Circle }) {
            Text(this.user.display_name.slice(0, 1)).fontSize(this.palette.sectionTitle).fontWeight(FontWeight.Medium).fontColor(this.palette.accent)
          }.width(48).height(48).backgroundColor(this.palette.accentSoft)
            .accessibilityText('打开个人设置').onClick(() => this.onOpenProfile())
        }.width('100%')
        this.Sources()
        if (this.errorText.length > 0) {
          Column({ space: 8 }) {
            Text(this.errorText).fontSize(this.palette.metaSize).fontColor(this.palette.danger).width('100%')
              .wordBreak(WordBreak.BREAK_WORD)
            Button(this.loading ? '正在更新…' : '重新加载').fontSize(this.palette.metaSize).fontColor(this.palette.danger)
              .width('100%').constraintSize({ minHeight: 48 }).backgroundColor(Color.Transparent)
              .enabled(!this.loading).onClick(() => this.loadToday())
          }.width('100%').padding(this.palette.cardInset).backgroundColor(this.palette.dangerSoft).borderRadius(this.palette.cardRadius)
        }
        if (this.loading && this.courses.length === 0 && this.overview.tasks.length === 0) {
          Row({ space: 12 }) {
            LoadingProgress().width(22).height(22).color(this.palette.accent)
            Text('正在读取今日安排…').fontSize(this.palette.bodySize).fontColor(this.palette.quiet).layoutWeight(1)
          }.width('100%').padding(this.palette.cardInset).backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
        } else if (this.agenda().next !== null) {
          this.NextCard(this.agenda().next!)
        } else if (!this.loading && this.coursePhase === 'ready' && this.taskPhase === 'ready') {
          Column({ space: 8 }) {
            if (this.agenda().rows.length === 0 && this.agenda().allDay.length === 0 && this.agenda().unscheduled.length === 0) {
              AppIllustration({ source: $r('app.media.xj_empty_day'), imageWidth: 128, imageHeight: 96,
                fallbackIcon: 'calendar' })
            }
            Text(this.groups().upcoming.length > 0 ? '还有事项需要核对时间' : '接下来暂无明确的定时安排').fontSize(this.palette.sectionTitle).fontWeight(FontWeight.Medium).fontColor(this.palette.ink).width('100%')
            Text('可查看待处理与待安排事项；这不代表当前完全有空。').fontSize(this.palette.metaSize)
              .fontColor(this.palette.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
          }.width('100%').alignItems(HorizontalAlign.Start).padding(this.palette.cardInset)
            .backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
        }
        Button({ type: ButtonType.Normal }) {
          Row({ space: 12 }) {
            AppIcon({ name: 'plus', iconSize: 21, color: this.palette.onAccent })
            Text('记一件事').fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium)
              .fontColor(this.palette.onAccent).layoutWeight(1).textAlign(TextAlign.Start)
            Text('日期可不选').fontSize(this.palette.metaSize).fontColor(this.palette.onAccent)
          }.width('100%')
        }.width('100%').constraintSize({ minHeight: 52 }).padding(16).backgroundColor(this.palette.accent)
          .borderRadius(this.palette.controlRadius).onClick(() => this.openCapture())
        Column({ space: 12 }) {
          this.SectionTitle('今天的时间线', '查看日程')
          if (this.groups().upcoming.length > 0) {
            this.TimelineList(this.groups().upcoming)
          } else {
            Text(this.loading ? '正在更新日程…' : (this.coursePhase !== 'ready' || this.taskPhase !== 'ready' ?
              '日程尚未完整读取，请重试。' : '接下来暂无明确的定时条目'))
              .fontSize(this.palette.bodySize).fontColor(this.palette.quiet).width('100%').padding(this.palette.cardInset)
              .backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius).wordBreak(WordBreak.BREAK_WORD)
          }
          if (this.groups().overdue.length > 0) {
            Text(`待处理 · ${this.groups().overdue.length} 项`).fontSize(this.palette.bodySize)
              .fontWeight(FontWeight.Medium).fontColor(this.palette.warning).width('100%')
            Text('原定结束时间已过，仍未完成。').fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
            this.TimelineList(this.groups().overdue)
          }
          if (this.groups().earlier.length > 0) {
            Button({ type: ButtonType.Normal }) {
              Row({ space: 8 }) {
                Text(`早些时候 · ${this.groups().earlier.length} 项`).fontSize(this.palette.bodySize).fontColor(this.palette.quiet).layoutWeight(1)
                Text(this.earlierExpanded ? '收起' : '展开').fontSize(this.palette.metaSize).fontColor(this.palette.accent)
              }.width('100%')
            }.width('100%').constraintSize({ minHeight: 48 }).padding(12).backgroundColor(this.palette.surface)
              .borderRadius(this.palette.controlRadius).onClick(() => this.earlierExpanded = !this.earlierExpanded)
            if (this.earlierExpanded) { this.TimelineList(this.groups().earlier) }
          }
          if (this.agenda().allDay.length > 0) {
            Text('今天 · 未指定时刻').fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
            Column() {
              ForEach(this.agenda().allDay, (task: PlanningTask) => {
                this.TaskRow(task, '全天事项，未占用具体时段')
              }, (task: PlanningTask) => `${task.task_id}-${task.status}`)
            }.width('100%').backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
          }
        }.width('100%')
        this.FreeTimeHint()
        Column({ space: 12 }) {
          this.SectionTitle('待安排', '全部待办', 'tasks')
          if (this.agenda().unscheduled.length > 0) {
            Column() {
              ForEach(this.agenda().unscheduled.slice(0, 5), (task: PlanningTask) => {
                this.TaskRow(task, this.taskUnscheduledLabel(task))
              }, (task: PlanningTask) => `${task.task_id}-${task.status}`)
            }.width('100%').backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
            if (this.agenda().unscheduled.length > 5) {
              Text(`还有 ${this.agenda().unscheduled.length - 5} 项，可在全部待办中查看`)
                .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
            }
          } else {
            Text(this.loading ? '正在读取待办…' : (this.taskPhase !== 'ready' ? '待办尚未完整读取，请重试。' : '暂无待安排事项'))
              .fontSize(this.palette.bodySize).fontColor(this.palette.quiet).width('100%').padding(this.palette.cardInset)
              .backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
          }
        }.width('100%')
        Button({ type: ButtonType.Normal }) {
          Row({ space: 12 }) {
            AppIcon({ name: 'assistant', iconSize: 24, color: this.palette.accent })
            Column({ space: 5 }) {
              Text('让助手帮我安排').fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium)
                .fontColor(this.palette.accent).width('100%')
              Text('结合课表和待办，先预览再确认').fontSize(this.palette.metaSize).fontColor(this.palette.quiet)
                .width('100%').wordBreak(WordBreak.BREAK_WORD)
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            AppIcon({ name: 'chevron', iconSize: 16, color: this.palette.accent })
          }.width('100%')
        }.width('100%').constraintSize({ minHeight: 76 }).padding(this.palette.cardInset)
          .backgroundColor(this.palette.accentSoft).borderRadius(this.palette.cardRadius).onClick(() => this.onOpenAgent())
        this.FocusEntry()
        Button('回看这一天').width('100%').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
          .fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft).borderRadius(this.palette.controlRadius).onClick(() => this.reviewRequested())
        Column({ space: 12 }) {
          this.SectionTitle('目标进展', '查看全部', 'goals')
          if (this.activePlans().length > 0) {
            ForEach(this.activePlans().slice(0, 3), (plan: PlanSummary) => {
              this.PlanProgressCard(plan)
            }, (plan: PlanSummary) => `${plan.plan_id}-${plan.status}-${plan.progress}-${plan.completed_count}`)
          } else {
            Text(this.loading ? '正在读取计划…' : (this.taskPhase !== 'ready' ? '计划尚未完整读取，请重试。' : '还没有进行中的目标，可以请助手从一个小目标开始。'))
              .fontSize(this.palette.bodySize).fontColor(this.palette.quiet).width('100%').padding(this.palette.cardInset)
              .backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius).wordBreak(WordBreak.BREAK_WORD)
          }
        }.width('100%')
      }.width('100%').alignItems(HorizontalAlign.Start)
        .padding({ left: this.palette.pageInset, right: this.palette.pageInset, top: 20, bottom: 32 })
    }.width('100%').height('100%').backgroundColor(this.palette.canvas).scrollBar(BarState.Off)
  }
}
