import { ReviewPeriod } from '../model/ReviewModels';
import { validCourseAcknowledgements } from '../utils/CourseReview';
import { TaskCaptureIntent } from '../utils/TaskCaptureTypes';
import { QuickCaptureIssue, parseQuickCapture, captureEndAt } from '../utils/QuickCaptureParser';
import { CourseAcknowledgement, CourseOverlap } from '../model/ApiModels';
import {
  PendingAction,
  PlanningTaskDraft,
  PlanningActionRequest,
  PlanMilestone,
  PlanSummary,
  PlanningOverview,
  PlanningTask,
  TimetableEntry,
  DataEvidence,
  LearningPreferenceSnapshot
} from '../model/ApiModels';
import { localDrafts } from '../services/LocalDrafts';
import { DraftLease, DraftRecord, DraftOperation, DraftSaveState, NewTaskDraft } from '../utils/DraftStore';
import { FeedbackPanel } from '../components/FeedbackPanel';
import { CampusFlowApi } from '../services/CampusFlowApi';
import { AppTheme } from '../theme/AppTheme';
import { ThemePalette, themePalette } from '../theme/ThemePalette';
import { AppIcon } from '../components/AppIcon';
import { TaskScheduleDetails } from '../components/TaskScheduleDetails';
import { PlanningActionController, PlanningActionState, editedPlanningTime, validPlanningDate, planningTimestamp } from '../utils/PlanningAction';
import { PlanningActionPanel } from '../components/PlanningActionPanel';
import { PlanningConflictsPanel } from '../components/PlanningConflictsPanel';
import { CampusFlowRequestError } from '../utils/AgentFeedback';
import { formatPlanDateTime } from '../utils/PlanPresentation';
import { EvidencePanel } from '../components/EvidencePanel';
import { InfoDisclosure } from '../components/InfoDisclosure';
import { validPreferenceSnapshot } from '../utils/LearningPreferences';
import { TaskQuery, TaskQueryResult, PlanningCourseRef, PlanningWeek, PlanningWeekRow, PlanningWeekDay, PlanningDayLoad, filterPlanningTasks, buildPlanningWeek, resolvePlanningCourse, dailyPlannedLoad, projectPlanningCandidate, validPlanningTimetable } from '../utils/PlanningOverview';
import { DailyAgenda, AgendaRow, buildDailyAgenda, shanghaiDate } from '../utils/DailyAgenda';

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
  courseRef: PlanningCourseRef | null;
}

interface PlanningCourseDetail {
  reference: PlanningCourseRef;
  evidence: DataEvidence[];
}

interface PlanningDetailFrame {
  key: number;
  kind: string;
  id: string;
  external: boolean;
}

@Component
export struct PlanCenterPage {
  @StorageLink('campusflowThemePalette') private palette: ThemePalette = themePalette('paper-green');
  @Prop @Watch('connectionChanged') baseUrl: string;
  @Prop @Watch('captureRequested') captureOnly: boolean = false;
  @Prop @Watch('captureRequested') captureIntent: TaskCaptureIntent | null = null;
  @Prop @Watch('captureRequested') captureRevision: number = 0;
  onCloseCapture: () => void = () => {};
  @Prop @Watch('connectionChanged') token: string;
  @Prop @Watch('draftScopeChanged') draftLease: DraftLease | null = null;
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
  @Prop statusLockedTaskIds: string[] = [];
  onTaskStatus: (task: PlanningTask) => void = () => {};
  onOpenStatus: (taskId: string) => void = () => {};
  onOpenFocus: (task: PlanningTask) => void = () => {};
  onOpenReview: (period: ReviewPeriod, anchor: string) => void = () => {};
  onOpenTimetable: () => void = () => {};
  @State private overview: PlanningOverview = {
    plans: [], tasks: [], total_tasks: 0, completed_tasks: 0, due_today: 0, overdue_tasks: 0, progress: 0
  };
  @State private title: string = '';
  @State private durationText: string = '';
  @State private allowDuringCourse: boolean = false;
  @State private captureOriginalText: string = '';
  @State private captureIssues: QuickCaptureIssue[] = [];
  @State private captureTimeExpanded: boolean = false;
  @State private pendingCaptureIntent: TaskCaptureIntent | null = null;
  private appliedCaptureRevision: number = 0;
  private capturePreviousStack: PlanningDetailFrame[] = [];
  private captureOpened: boolean = false;
  @State private errorText: string = '';
  @State private timetable: TimetableEntry[] = [];
  @State private timetableRevision: string = '';
  @State private timetableEvidence: DataEvidence[] = [];
  @State private timetableState: string = 'idle';
  @State private planningState: string = 'idle';
  @State private preferencesState: string = 'idle';
  @State private preferences: LearningPreferenceSnapshot | null = null;
  @State private courseDetails: PlanningCourseDetail[] = [];
  @State private scheduleMode: string = 'day';
  @State private queryText: string = '';
  @State private queryDateMode: string = 'all';
  @State private queryFromDate: string = '';
  @State private queryToDate: string = '';
  @State private querySort: string = 'schedule';
  @State private queryPage: number = 0;
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
  @State private taskFiltersExpanded: boolean = false;
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
  @State private editTaskAllowDuringCourse: boolean = false;
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
  @State private recoveredDraft: DraftRecord | null = null;
  @State private draftMessage: string = '';
  @State private pendingProposals: DraftOperation[] = [];
  @State private draftStorageBusy: boolean = false;
  private draftAnchorDate: string = '';
  private draftUnsubscribe: (() => void) | null = null;
  private draftReady: boolean = false;
  private draftBoundGeneration: number = -1;
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
    this.draftScopeChanged();
    this.viewRequested();
    this.focusChanged();
    this.refreshPlanning();
    this.captureRequested();
  }

  aboutToDisappear(): void {
    this.flushTaskDraft();
    this.draftUnsubscribe?.();
    this.draftUnsubscribe = null;
    this.pageActive = false;
    this.lifecycleRevision++;
    this.requestRevision++;
    this.actionController?.dispose();
    this.actionController = null;
  }

  private activityChanged(): void {
    this.actionController?.setActive(this.active);
    if (!this.active) { this.flushTaskDraft(); this.requestRevision++; return; }
    this.refreshPlanning();
  }

  private draftScopeChanged(): void {
    this.draftUnsubscribe?.();
    this.draftUnsubscribe = null;
    this.draftReady = false;
    this.recoveredDraft = null;
    this.pendingProposals = [];
    const lease = this.draftLease;
    if (this.draftBoundGeneration !== (lease?.generation ?? -1)) {
      this.lifecycleRevision++; this.requestRevision++;
      this.clearQuery(); this.scheduleMode = 'day'; this.courseDetails = [];
      this.timetable = []; this.timetableRevision = ''; this.timetableEvidence = []; this.timetableState = 'idle';
      this.planningState = 'idle'; this.preferencesState = 'idle'; this.preferences = null; this.loaded = false;
      this.overview = { plans: [], tasks: [], total_tasks: 0, completed_tasks: 0, due_today: 0, overdue_tasks: 0, progress: 0 };
      this.clearDetails(); this.selectDay(shanghaiDate(Date.now()));
      this.title = ''; this.durationText = ''; this.allowDuringCourse = false; this.captureOriginalText = ''; this.captureIssues = [];
      this.captureOpened = false; this.capturePreviousStack = []; this.pendingCaptureIntent = null;
      this.draftTaskDate = shanghaiDate(Date.now()); this.draftDateChoice = 'today'; this.draftTaskTime = '';
      this.actionController?.dispose(); this.actionController = null;
      this.actionState = { phase: 'idle', action: null, message: '' };
      this.draftStorageBusy = false;
      this.draftBoundGeneration = lease?.generation ?? -1;
    }
    if (lease === null || !localDrafts.valid(lease)) {
      this.draftMessage = '本机草稿尚不可用，提交前需要先恢复本机保存。';
      return;
    }
    this.draftAnchorDate = shanghaiDate(Date.now());
    this.recoveredDraft = localDrafts.read(lease, { kind: 'new-task', ownerId: 'main' }) ?? null;
    this.pendingProposals = localDrafts.operations(lease).filter((item: DraftOperation) => item.kind === 'proposal');
    this.draftUnsubscribe = localDrafts.subscribe((state: DraftSaveState) => {
      if (!this.pageActive || this.draftLease !== lease || state.generation !== lease.generation) { return; }
      this.draftMessage = state.message;
      this.pendingProposals = localDrafts.operations(lease).filter((item: DraftOperation) => item.kind === 'proposal');
    });
    this.draftReady = true;
  }

  private taskDraftPayload(): NewTaskDraft {
    return { title: this.title, date: this.draftTaskDate, dateChoice: this.draftDateChoice,
      time: this.draftTaskTime, durationMinutes: /^\d+$/.test(this.durationText) && Number(this.durationText) >= 1 && Number(this.durationText) <= 1440 ? Number(this.durationText) : null,
      allowDuringCourse: this.allowDuringCourse, originalText: this.captureOriginalText, durationText: this.durationText, anchorDate: this.draftAnchorDate || shanghaiDate(Date.now()), timezone: 'Asia/Shanghai' };
  }

  private stageTaskDraft(): void {
    const lease = this.draftLease;
    if (!this.draftReady || this.recoveredDraft !== null || lease === null || !localDrafts.valid(lease)) { return; }
    try { localDrafts.stage(lease, { kind: 'new-task', ownerId: 'main' }, this.taskDraftPayload()); }
    catch { this.draftMessage = '输入尚未保存到本机，请保留页面并重试。'; }
  }

  private flushTaskDraft(): void {
    const lease = this.draftLease;
    if (lease !== null && localDrafts.valid(lease)) {
      localDrafts.flush(lease).catch(() => {
        if (this.pageActive && this.draftLease === lease) { this.draftMessage = '输入尚未保存到本机，请重试保存。'; }
      });
    }
  }

  private restoreTaskDraft(): void {
    const record = this.recoveredDraft;
    if (record === null || this.draftLease === null || !localDrafts.valid(this.draftLease)) { return; }
    const payload = record.payload as NewTaskDraft;
    this.title = payload.title; this.draftTaskDate = payload.date; this.draftTaskTime = payload.time;
    this.draftDateChoice = payload.dateChoice; this.draftAnchorDate = payload.anchorDate;
    this.durationText = payload.durationText ?? (payload.durationMinutes === undefined || payload.durationMinutes === null ? '' : `${payload.durationMinutes}`);
    this.allowDuringCourse = payload.allowDuringCourse ?? false;
    this.captureOriginalText = payload.originalText ?? '';
    this.captureIssues = this.captureOriginalText.length === 0 ? [] : parseQuickCapture(this.captureOriginalText, payload.anchorDate).issues;
    this.captureTimeExpanded = this.draftTaskTime.length > 0 || this.durationText.length > 0 || this.allowDuringCourse;
    this.recoveredDraft = null;
    this.draftMessage = payload.anchorDate === shanghaiDate(Date.now()) ? '已恢复输入，尚未提交。' :
      `已恢复 ${payload.anchorDate} 的输入，日期仍为 ${payload.date || '无日期'}，请重新核对。`;
    this.openDetails('draft');
  }

  private async discardTaskDraft(): Promise<void> {
    const record = this.recoveredDraft; const lease = this.draftLease;
    if (record === null || lease === null || this.draftStorageBusy) { return; }
    this.draftStorageBusy = true;
    try {
      const removed = await localDrafts.remove(lease, { kind: 'new-task', ownerId: 'main' }, record.localRevision);
      if (!this.pageActive || this.draftLease !== lease) { return; }
      if (removed) { this.recoveredDraft = null; this.draftMessage = '这份本机草稿已丢弃。'; }
      else { this.draftMessage = '草稿已变化或提交结果待核对，尚未丢弃。'; }
    } catch { if (this.draftLease === lease) { this.draftMessage = '丢弃未完成，草稿仍保留。'; } }
    finally { if (this.draftLease === lease) { this.draftStorageBusy = false; } }
  }

  private async recoverProposal(operation: DraftOperation): Promise<void> {
    if (this.draftStorageBusy || !this.active || !this.pageActive) { return; }
    this.openDetails('action');
    await this.actionManager().recover(operation.id);
    await this.settleProposal();
  }

  private async settleProposal(): Promise<void> {
    const lease = this.draftLease; const state = this.actionState;
    const action = state.action;
    if (lease === null || action === null || !['resolved', 'cancelled', 'invalidated'].includes(state.phase)) { return; }
    const operation = localDrafts.operations(lease).find((item: DraftOperation) => item.kind === 'proposal' && item.id === action.proposal_id);
    if (operation === undefined) { return; }
    try {
      await localDrafts.resolveOperation(lease, 'proposal', operation.id, state.phase === 'resolved' || operation.ownerId !== 'main');
      // The receipt pointer and its exact submitted revision settle in one atomic write.
      // A newer input remains available after a receipt.
      if (this.pageActive && this.draftLease === lease) {
        const latest = localDrafts.read(lease, { kind: 'new-task', ownerId: 'main' });
        if (this.recoveredDraft !== null && latest === undefined) { this.recoveredDraft = null; }
      }
    } catch {
      if (this.pageActive && this.draftLease === lease) { this.draftMessage = '服务器结果已查回，本机核对记录尚未保存。请再次核对。'; }
    }
  }

  private async writePlanningAction(cancel: boolean = false, acknowledgements: CourseAcknowledgement[] = []): Promise<void> {
    if (this.mutationBusy || this.replanWriteBlocked || this.draftStorageBusy || !this.active || !this.pageActive) { return; }
    const lease = this.draftLease; const action = this.actionState.action;
    if (lease === null || !localDrafts.valid(lease) || action === null || !['review', 'retryable'].includes(this.actionState.phase)) {
      this.errorText = '请先恢复本机草稿保存并核对原提案，再提交。'; return;
    }
    if (!cancel && this.statusBlocks(action.target_task_id ?? '', action.target_plan_id ?? '')) { return; }
    if (!cancel && !validCourseAcknowledgements(action, acknowledgements)) {
      this.errorText = '请核对重叠课程并选择仍这样安排，再确认这份变更。'; return;
    }
    this.draftStorageBusy = true;
    try {
      let operation = localDrafts.operations(lease).find((item: DraftOperation) => item.kind === 'proposal' && item.id === action.proposal_id);
      if (operation === undefined) {
        const owner = action.action === 'create' && action.kind === 'task' && this.createSnapshot() === this.submittedCreate ? 'main' : `proposal_${action.proposal_id}`;
        const payload: NewTaskDraft = owner === 'main' ? this.taskDraftPayload() :
          { title: '', date: '', dateChoice: 'none', time: '', anchorDate: shanghaiDate(Date.now()), timezone: 'Asia/Shanghai' };
        const ticket = localDrafts.stage(lease, { kind: 'new-task', ownerId: owner }, payload);
        await localDrafts.beginOperation(lease, { kind: 'proposal', id: action.proposal_id, draftKind: 'new-task',
          ownerId: owner, localRevision: ticket.localRevision });
      } else {
        await localDrafts.flush(lease);
      }
      if (!this.pageActive || !this.active || this.draftLease !== lease || !localDrafts.valid(lease) ||
        this.actionState.action?.proposal_id !== action.proposal_id) { return; }
      if (!cancel && this.statusBlocks(action.target_task_id ?? '', action.target_plan_id ?? '')) { return; }
      if (cancel) { await this.actionManager().cancel(); } else { await this.actionManager().confirm(acknowledgements); }
      await this.settleProposal();
    } catch {
      if (this.pageActive && this.draftLease === lease) { this.errorText = '恢复标识尚未保存，本次未提交。请先重试保存，再核对原提案。'; }
    } finally { if (this.draftLease === lease) { this.draftStorageBusy = false; } }
  }

  private async checkPlanningAction(): Promise<void> {
    await this.actionManager().check();
    await this.settleProposal();
  }

  // The home sheet uses this same form and controller; it never creates a second draft writer.
  private captureRequested(): void {
    if (this.captureRevision === this.appliedCaptureRevision || this.captureIntent === null || !this.captureOnly) { return; }
    if (this.captureIntent.requestRevision !== undefined && this.captureIntent.requestRevision !== this.captureRevision) { return; }
    this.appliedCaptureRevision = this.captureRevision;
    if (!this.captureOpened) {
      this.capturePreviousStack = this.detailStack.slice();
      this.captureOpened = true;
      // Preserve keyed Scroll nodes below the sheet so their scroll positions survive.
      this.detailKind = ''; this.detailId = ''; this.externalDetail = false;
      this.openDetails('draft');
    }
    const intent = this.captureIntent;
    if (intent.source === 'home') { this.pendingCaptureIntent = null; return; }
    this.pendingCaptureIntent = JSON.parse(JSON.stringify(intent)) as TaskCaptureIntent;
    if (this.title.trim().length === 0 && this.recoveredDraft === null && !this.actionBlocksWrites() && this.pendingProposals.length === 0) {
      this.applyCaptureSuggestion();
    }
  }

  private applyCaptureSuggestion(): void {
    const intent = this.pendingCaptureIntent;
    if (intent === null || this.writesBlocked()) { return; }
    // A gap suggestion only changes time after an explicit choice if a draft already exists.
    if (this.title.trim().length === 0) { this.title = intent.text; }
    this.draftTaskDate = intent.date; this.draftTaskTime = intent.time;
    this.draftDateChoice = intent.date.length > 0 ? 'capture' : 'none';
    this.durationText = intent.durationMinutes === null ? '' : `${intent.durationMinutes}`;
    this.draftAnchorDate = intent.anchorDate;
    this.captureTimeExpanded = true;
    this.pendingCaptureIntent = null;
    this.stageTaskDraft();
  }

  private finishCapture(): void {
    this.flushTaskDraft(); this.taskInputController.stopEditing();
    this.pendingCaptureIntent = null;
    this.detailStack = this.capturePreviousStack.slice(); this.capturePreviousStack = []; this.captureOpened = false;
    const previous = this.detailStack.length > 0 ? this.detailStack[this.detailStack.length - 1] : null;
    this.detailKind = previous?.kind ?? ''; this.detailId = previous?.id ?? ''; this.externalDetail = previous?.external ?? false;
    this.onInnerNavigationChanged(previous !== null);
    this.onCloseCapture();
  }

  private parseCapture(): void {
    if (this.writesBlocked() || this.title.trim().length === 0) { return; }
    const candidate = parseQuickCapture(this.title, this.draftAnchorDate || shanghaiDate(Date.now()));
    this.captureOriginalText = candidate.originalText;
    this.title = candidate.title || candidate.originalText;
    this.draftTaskDate = candidate.date; this.draftTaskTime = candidate.time;
    this.durationText = candidate.durationMinutes === null ? '' : `${candidate.durationMinutes}`;
    this.draftDateChoice = candidate.date.length === 0 ? 'none' : 'capture';
    this.captureIssues = candidate.issues;
    this.captureTimeExpanded = true;
    this.stageTaskDraft();
  }

  private captureToAssistant(): void {
    const original = this.captureOriginalText || this.title;
    const current = `当前标题：${this.title}；日期：${this.draftTaskDate || '无日期'}；时刻：${this.draftTaskTime || '尚未定时'}；时长：${this.durationText || '未设置'}分钟；课内设置：${this.allowDuringCourse ? '允许课内完成，仍需逐项确认重叠' : '未允许课内完成'}。`;
    this.flushTaskDraft();
    if (this.captureOpened) { this.finishCapture(); }
    this.onOpenAgent(`请以以下当前编辑值核对安排，原文仅供参考。${current}原始描述：${original}。输入基准日期 ${this.draftAnchorDate || shanghaiDate(Date.now())}，北京时间。先提出候选，暂不执行。`);
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
    if (!['task', 'plan', 'course', 'draft', 'conflicts', 'action', 'task-edit', 'plan-edit'].includes(kind)) { return; }
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
    if (this.captureOpened && this.detailStack.length <= this.capturePreviousStack.length + 1) { this.finishCapture(); return; }
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
    if (this.captureOpened && this.detailStack.length <= this.capturePreviousStack.length + 1) { return '返回今日'; }
    if (this.detailStack.length > 1) {
      const kind = this.detailStack[this.detailStack.length - 2].kind;
      return kind === 'task' ? '返回任务详情' : kind === 'plan' ? '返回目标计划' : '返回上一层';
    }
    return this.externalDetail ? '返回来源页面' : `返回${this.viewTitle()}`;
  }

  private detailTitle(): string {
    if (this.detailKind === 'course') { return '课程详情'; }
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

  private query(): TaskQuery {
    return { text: this.queryText, status: this.taskFilter === 'completed' ? 'completed' : this.taskFilter === 'pending' || this.taskFilter === 'undated' ? 'pending' : 'all',
      dateMode: this.taskFilter === 'undated' || this.queryDateMode === 'undated' ? 'undated' : this.queryDateMode === 'day' ? 'day' : this.queryDateMode === 'range' ? 'range' : 'all',
      fromDate: this.queryDateMode === 'day' ? this.selectedDate : this.queryFromDate,
      toDate: this.queryToDate, sort: this.querySort === 'created' ? 'created' : 'schedule' };
  }

  private queryResult(): TaskQueryResult { return filterPlanningTasks(this.overview.tasks, this.query()); }
  private querySummary(): string {
    const query = this.query();
    const status = query.status === 'pending' ? '待完成' : query.status === 'completed' ? '已完成' : '全部状态';
    const date = query.dateMode === 'day' ? this.selectedDate : query.dateMode === 'range' ?
      `${this.queryFromDate || '开始日期'} 至 ${this.queryToDate || '结束日期'}` : query.dateMode === 'undated' ? '待定日期' : '不限日期';
    return `${status} · ${date} · ${query.sort === 'created' ? '最近创建' : '按安排时间'}`;
  }
  private filteredTasks(): PlanningTask[] { return this.queryResult().tasks; }
  private visibleTasks(): PlanningTask[] {
    const page = Math.min(this.queryPage, Math.max(0, Math.ceil(this.filteredTasks().length / 20) - 1));
    return this.filteredTasks().slice(page * 20, page * 20 + 20);
  }
  private currentQueryPage(): number { return Math.min(this.queryPage, Math.max(0, Math.ceil(this.filteredTasks().length / 20) - 1)); }
  private moveQueryPage(offset: number): void {
    this.queryPage = Math.max(0, Math.min(this.currentQueryPage() + offset, Math.max(0, Math.ceil(this.filteredTasks().length / 20) - 1)));
    this.tasksScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: false });
  }
  private clearQuery(): void { this.taskFilter = 'all'; this.queryText = ''; this.queryDateMode = 'all'; this.queryFromDate = ''; this.queryToDate = ''; this.querySort = 'schedule'; this.queryPage = 0; }
  private selectTaskFilter(filter: string): void {
    if (!['all', 'pending', 'completed', 'undated'].includes(filter)) { return; }
    if (this.taskFilter === 'undated') { this.queryDateMode = 'all'; }
    this.taskFilter = filter; this.queryPage = 0;
  }
  private selectQueryDate(value: string): void {
    if (!['all', 'day', 'range', 'undated'].includes(value)) { return; }
    if (this.taskFilter === 'undated') { this.taskFilter = 'pending'; }
    this.queryDateMode = value; this.queryPage = 0;
    if (value === 'range' && this.queryFromDate.length === 0) { this.queryFromDate = this.selectedDate; this.queryToDate = this.selectedDate; }
  }

  private week(): PlanningWeek { return buildPlanningWeek(this.timetable, this.timetableRevision, this.overview.tasks, this.selectedDate); }
  private weekDays(): CalendarDay[] {
    return this.week().days.map((day: PlanningWeekDay): CalendarDay => ({ key: day.date, day: Number(day.date.substring(8)), date: day.date,
      courseCount: day.rows.filter((row: PlanningWeekRow) => row.kind === 'course').length,
      taskCount: day.rows.filter((row: PlanningWeekRow) => row.kind === 'task').length + day.allDay.length }));
  }
  private moveWeek(offset: number): void {
    const date = shanghaiDate(Date.parse(`${this.selectedDate}T12:00:00+08:00`) + offset * 7 * 86400000);
    if (validPlanningDate(date)) { this.selectDay(date); }
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

  private timelineFor(date: string): PlanningTimelineItem[] {
    return (this.week().days.find((day: PlanningWeekDay) => day.date === date)?.rows ?? []).map((row: PlanningWeekRow): PlanningTimelineItem => {
      const start = row.segmentStartMs > row.startMs ? '00:00' : row.startTime;
      const end = row.segmentEndMs === null ? '结束未设置' : shanghaiDate(row.segmentEndMs) !== date ? '24:00' : formatPlanDateTime(new Date(row.segmentEndMs).toISOString()).substring(11);
      const teacher = row.courseRef?.course.teacher ?? '';
      let detail = row.location + (teacher.length > 0 ? `${row.location.length > 0 ? ' · ' : ''}${teacher}` : '');
      if (row.endMs !== null && row.date !== row.endDate) {
        detail += `${detail.length > 0 ? ' · ' : ''}跨日完整时段 ${row.date} ${row.startTime} 至 ${row.endDate} ${row.endTime}`;
      }
      return { key: row.id, kind: row.kind === 'course' ? '课程' : '任务', time: `${start}–${end}`, title: row.title,
        detail: detail, taskId: row.taskId ?? '', completed: row.done, courseRef: row.courseRef };
    });
  }
  private dayTimeline(): PlanningTimelineItem[] { return this.timelineFor(this.selectedDate); }
  private openTimeline(item: PlanningTimelineItem): void {
    if (item.taskId.length > 0) { this.openDetails('task', item.taskId); }
    else if (item.courseRef !== null) { this.openCourse(item.courseRef); }
  }
  private openCourse(reference: PlanningCourseRef): void {
    this.courseDetails = this.courseDetails.filter((item: PlanningCourseDetail) => item.reference.key !== reference.key)
      .concat([{ reference: reference, evidence: this.timetableEvidence.slice() }]);
    this.openDetails('course', reference.key);
  }
  private courseFor(id: string): PlanningCourseDetail[] { return this.courseDetails.filter((item: PlanningCourseDetail) => item.reference.key === id); }
  private courseCurrent(reference: PlanningCourseRef): boolean { return resolvePlanningCourse(reference, this.timetable, this.timetableRevision) !== null; }
  private sourcesComplete(): boolean { return this.timetableState === 'ready' && this.planningState === 'ready'; }
  private sourceLabel(state: string, noun: string): string {
    return state === 'ready' ? `${noun}已读取` : state === 'loading' ? `正在核对${noun}` : state === 'error' ? `${noun}读取失败；已加载内容可能过时` : `${noun}尚未读取`;
  }
  private taskSource(task: PlanningTask): string { return task.source === 'manual' ? '手动记录' : task.source === 'agent' ? '助手安排' : '已保存任务'; }
  private overlapLabel(task: PlanningTask): string {
    if (task.course_overlap?.state === 'accepted') { return '已确认课内安排'; }
    if (task.course_overlap?.state === 'needs_review') { return '课程重叠需要重新核对'; }
    if (task.course_overlap?.state === 'blocked') { return '与课程冲突，请调整'; }
    if (task.course_overlap?.state === 'unchecked') { return '起止时段尚未完整核对'; }
    return task.allow_during_course === true ? (task.course_overlap?.state === 'none' ? '允许课内完成；当前没有课程重叠' : '允许课内完成；课程重叠尚未核对') : '';
  }
  private dayLoad(date: string): PlanningDayLoad { return dailyPlannedLoad(this.timetable, this.overview.tasks, date); }
  private previewLoadDate(): string {
    const action = this.actionState.action;
    const date = formatPlanDateTime(action?.payload.task?.start_at ?? action?.before_task?.start_at ?? null).substring(0, 10);
    return validPlanningDate(date) ? date : this.selectedDate;
  }
  private projectedTasks(): PlanningTask[] | null {
    const action = this.actionState.action;
    if (action === null || action.status !== 'pending' || action.kind !== 'task') { return null; }
    if (action.action === 'delete') { return this.overview.tasks.some((task: PlanningTask) => task.task_id === action.target_task_id) ? this.overview.tasks.filter((task: PlanningTask) => task.task_id !== action.target_task_id) : null; }
    if (action.payload.task === undefined) { return null; }
    // This page creates manual tasks; new servers also echo the exact source in the candidate.
    const source = action.payload.source ?? 'manual';
    if (!['manual', 'agent'].includes(source)) { return null; }
    const result = projectPlanningCandidate(this.overview.tasks, { task: action.payload.task,
      replaceTaskId: action.action === 'update' ? action.target_task_id ?? null : null, source: source });
    return result.valid ? result.tasks : null;
  }
  private candidateLoad(): PlanningDayLoad { return dailyPlannedLoad(this.timetable, this.projectedTasks() ?? this.overview.tasks, this.previewLoadDate()); }
  private loadTargetMessage(load: PlanningDayLoad): string {
    if (!this.sourcesComplete() || this.preferencesState !== 'ready' || this.preferences?.enabled !== true || this.preferences.updated_at === null) { return ''; }
    return load.taskMinutes > this.preferences.daily_minutes ?
      `已排任务 ${this.minutes(load.taskMinutes)} 分钟，高于你设置的每日 ${this.preferences.daily_minutes} 分钟学习偏好。可按实际精力调整；不会自动删改任务。` :
      `每日学习偏好 ${this.preferences.daily_minutes} 分钟；这里只比较已排任务，不计课程。`;
  }

  private minutes(value: number): string { return Number.isInteger(value) ? `${value}` : value.toFixed(1); }
  private loadExclusions(load: PlanningDayLoad): string {
    return `${load.allDayCount} 项全天、${load.undatedCount} 项无日期、${load.incompleteTaskCount} 项缺结束时间未计时长；${load.invalidCourseCount + load.invalidTaskCount} 项时间异常需核对。`;
  }
  private taskRowDate(task: PlanningTask): string {
    const date = this.taskDate(task);
    return date.length > 0 ? date : task.start_at === null || task.start_at === '' ? '无日期' : '日期需核对';
  }
  private openWeekDay(date: string): void { this.selectDay(date); this.scheduleMode = 'day'; }
  private openUndated(): void { this.taskFilter = 'pending'; this.queryDateMode = 'undated'; this.queryText = ''; this.queryPage = 0; this.selectView('tasks'); }

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
      if (value.length === 0) { this.durationText = ''; }
      this.stageTaskDraft();
    });
  }

  private selectDraftDate(value: string, choice: string): void {
    this.getUIContext().animateTo({ duration: AppTheme.motion(180), curve: Curve.EaseOut }, () => {
      this.draftTaskDate = value;
      this.draftDateChoice = choice;
      if (value.length === 0) {
        this.draftTaskTime = ''; this.durationText = '';
      }
      this.draftAnchorDate = shanghaiDate(Date.now());
      this.stageTaskDraft();
    });
  }

  private dateChoiceSelected(choice: string, value: string): boolean {
    // Equal dates may come from different controls; highlight only the choice the user applied.
    return this.draftDateChoice === choice && this.draftTaskDate === value;
  }

  private openTimePicker(): void {
    const lease = this.draftLease; const lifecycle = this.lifecycleRevision;
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
        if (!this.pageActive || !this.active || lifecycle !== this.lifecycleRevision || this.draftLease !== lease ||
          (lease !== null && !localDrafts.valid(lease))) { return; }
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

  private connectionChanged(): void {
    this.requestRevision++; this.lifecycleRevision++; this.clearQuery(); this.clearDetails(); this.courseDetails = [];
    this.actionController?.dispose(); this.actionController = null; this.actionState = { phase: 'idle', action: null, message: '' };
    this.timetable = []; this.timetableRevision = ''; this.timetableEvidence = []; this.timetableState = 'idle';
    this.overview = { plans: [], tasks: [], total_tasks: 0, completed_tasks: 0, due_today: 0, overdue_tasks: 0, progress: 0 };
    this.planningState = 'idle'; this.loaded = false; this.preferences = null; this.preferencesState = 'idle';
    if (this.active && this.pageActive) { this.reload(true); }
  }
  private readCurrent(revision: number, base: string, token: string): boolean {
    return this.pageActive && this.active && revision === this.requestRevision && base === this.baseUrl && token === this.token;
  }
  private async readPlanning(api: CampusFlowApi, revision: number, base: string, token: string): Promise<void> {
    this.planningState = 'loading';
    try {
      const overview = await api.planning();
      if (!this.readCurrent(revision, base, token)) { return; }
      if (overview === null || !Array.isArray(overview.tasks) || !Array.isArray(overview.plans)) { throw new Error('invalid planning'); }
      this.overview = overview; this.planningRevision++; this.loaded = true; this.planningState = 'ready'; this.errorText = '';
      this.expandedPlanIds = this.expandedPlanIds.filter((id: string) => overview.plans.some((plan: PlanSummary) => plan.plan_id === id));
    } catch { if (this.readCurrent(revision, base, token)) { this.planningState = 'error'; this.errorText = '计划读取失败，已有内容未清除；请重新核对。'; } }
  }
  private async readTimetable(api: CampusFlowApi, revision: number, base: string, token: string): Promise<void> {
    this.timetableState = 'loading';
    try {
      const snapshot = await api.timetable();
      if (!this.readCurrent(revision, base, token)) { return; }
      if (!validPlanningTimetable(snapshot)) { throw new Error('invalid timetable'); }
      this.timetable = snapshot.entries; this.timetableRevision = snapshot.revision;
      this.timetableEvidence = snapshot.evidence ?? []; this.timetableState = 'ready'; this.timetableNeedsRefresh = false;
    } catch { if (this.readCurrent(revision, base, token)) { this.timetableState = 'error'; } }
  }
  private async readPreferences(api: CampusFlowApi, revision: number, base: string, token: string): Promise<void> {
    this.preferencesState = 'loading';
    try {
      const value = await api.learningPreferences();
      if (!this.readCurrent(revision, base, token)) { return; }
      if (!validPreferenceSnapshot(value)) { throw new Error('invalid preferences'); }
      this.preferences = value; this.preferencesState = 'ready';
    } catch { if (this.readCurrent(revision, base, token)) { this.preferencesState = 'error'; } }
  }
  private async reload(includeTimetable: boolean = false): Promise<void> {
    if (!this.pageActive || !this.active) { return; }
    if (includeTimetable || this.timetableState !== 'ready') { this.timetableNeedsRefresh = true; }
    const revision = ++this.requestRevision; const base = this.baseUrl; const token = this.token;
    this.loading = true; const api = new CampusFlowApi(base, token);
    // Independent sources share a generation, not a false all-or-nothing freshness claim.
    const reads: Promise<void>[] = [this.readPlanning(api, revision, base, token), this.readPreferences(api, revision, base, token)];
    if (this.timetableNeedsRefresh) { reads.push(this.readTimetable(api, revision, base, token)); }
    await Promise.all(reads);
    if (this.readCurrent(revision, base, token)) { this.loading = false; }
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
    return this.draftStorageBusy || this.pendingProposals.length > 0 || this.recoveredDraft !== null || this.mutationBusy || this.replanWriteBlocked || this.actionBlocksWrites() || !this.active || !this.pageActive;
  }

  private createSnapshot(): string {
    return JSON.stringify([this.title, this.draftTaskDate, this.draftTaskTime, this.draftDateChoice, this.durationText, this.allowDuringCourse]);
  }

  private taskEditSnapshot(): string {
    return JSON.stringify([this.editTaskId, this.editTaskTitle, this.editTaskStart, this.editTaskEnd, this.editTaskLocation, this.editTaskReminder, this.editTaskAllowDuringCourse]);
  }

  private planEditSnapshot(): string {
    return JSON.stringify([this.editPlanId, this.editPlanTitle, this.editPlanSummary, this.editPlanDate]);
  }

  private actionApplied(action: PendingAction): void {
    if (!this.pageActive || !this.active) { return; }
    if (action.action === 'create' && action.kind === 'task' && this.createSnapshot() === this.submittedCreate) {
      this.title = ''; this.durationText = ''; this.allowDuringCourse = false; this.captureOriginalText = ''; this.captureIssues = [];
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
    if (this.writesBlocked() || this.statusBlocks(request.task_id ?? '', request.plan_id ?? '')) { return; }
    this.errorText = '';
    this.openDetails('action');
    await this.actionManager().preview(request);
  }

  private async confirmPlanningAction(acknowledgements: CourseAcknowledgement[] = []): Promise<void> {
    if (this.mutationBusy || this.replanWriteBlocked || !this.active || !this.pageActive) { return; }
    await this.writePlanningAction(false, acknowledgements);
  }

  private dismissAction(): void {
    if (this.actionBlocksWrites()) { return; }
    this.actionManager().dismiss();
    this.closeDetails();
  }

  private async addTask(): Promise<void> {
    if (this.title.trim().length === 0 || this.writesBlocked()) { return; }
    if (Array.from(this.title.trim()).length > 120) { this.errorText = '待办名称请控制在 120 字以内。'; return; }
    const duration = this.durationText.trim().length === 0 ? null : Number(this.durationText);
    if (duration !== null && (!/^\d+$/.test(this.durationText.trim()) || !Number.isInteger(duration) || duration < 1 || duration > 1440)) {
      this.errorText = '时长请填写 1–1440 的整数分钟，留空表示未定时长。'; return;
    }
    if ((this.draftTaskDate.length > 0 && !validPlanningDate(this.draftTaskDate)) ||
      (this.draftTaskTime.length > 0 && !/^([01]\d|2[0-3]):[0-5]\d$/.test(this.draftTaskTime)) ||
      (this.draftTaskTime.length > 0 && this.draftTaskDate.length === 0) ||
      (duration !== null && (this.draftTaskDate.length === 0 || this.draftTaskTime.length === 0))) {
      this.errorText = '请核对日期和时间；要保存时长，需要明确开始日期与时刻。'; return;
    }
    if (this.draftTaskTime === '23:59' && duration === null) {
      this.errorText = '23:59 需要填写时长，或明确选择全天，避免与全天事项混淆。'; return;
    }
    const taskTime = this.draftTaskTime.length === 0 ? '23:59' : this.draftTaskTime;
    const startAt = this.draftTaskDate.length === 0 ? null : `${this.draftTaskDate}T${taskTime}:00+08:00`;
    const endAt = captureEndAt(this.draftTaskDate, this.draftTaskTime, duration);
    if (duration !== null && endAt === null) { this.errorText = '结束时间超出支持范围，请调整日期或时长。'; return; }
    this.submittedCreate = this.createSnapshot();
    await this.previewAction({ operation: 'create_task', task: { title: this.title.trim(), start_at: startAt,
      end_at: endAt, reminder_minutes: null, location: null,
      allow_during_course: this.allowDuringCourse } });
  }

  private beginTaskEdit(task: PlanningTask): void {
    if (this.statusBlocks(task.task_id)) { return; }
    if (this.writesBlocked()) { return; }
    if (this.editTaskId.length > 0 && this.editTaskId !== task.task_id) {
      this.errorText = '还有另一条任务的编辑草稿。请先完成或明确放弃该草稿。';
      this.openDetails('task-edit', this.editTaskId); return;
    }
    if (this.editTaskId.length === 0) {
      this.editTaskId = task.task_id;
      this.editTaskOriginal = JSON.parse(JSON.stringify(task)) as PlanningTask;
      this.editTaskTitle = task.title;
      this.editTaskAllowDuringCourse = task.allow_during_course ?? false;
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
    const task: PlanningTaskDraft = { allow_during_course: this.editTaskAllowDuringCourse, title: this.editTaskTitle.trim(), start_at: start, end_at: end,
      reminder_minutes: reminder.length === 0 ? null : Number(reminder),
      location: this.editTaskLocation === (original.location ?? '') ? original.location : this.editTaskLocation.trim() || null };
    this.submittedTaskEdit = this.taskEditSnapshot();
    await this.previewAction({ operation: 'update_task', task_id: original.task_id, task: task });
  }

  private beginPlanEdit(plan: PlanSummary): void {
    if (this.statusBlocks('', plan.plan_id)) { return; }
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

  private focusRequested(task: PlanningTask): void {
    if (!this.active || !this.pageActive) { return; }
    const current = this.overview.tasks.find((item: PlanningTask) => item.task_id === task.task_id);
    if (current !== undefined) { this.onOpenFocus(current); }
  }

  private statusLabel(task: PlanningTask): string {
    if (this.statusLockedTaskIds.includes(task.task_id)) { return '状态结果待核对'; }
    if (task.status !== 'completed') { return '标记完成'; }
    return task.completion_operation_id ? '恢复未完成' : '这次完成未保留可恢复凭据';
  }

  private async toggle(task: PlanningTask): Promise<void> {
    if (!this.active || !this.pageActive) { return; }
    if (this.statusLockedTaskIds.includes(task.task_id)) { this.onOpenStatus(task.task_id); return; }
    if (this.writesBlocked()) { return; }
    this.onTaskStatus(task);
  }

  private statusBlocks(taskId: string = '', planId: string = ''): boolean {
    const locked = this.statusLockedTaskIds.find((id: string) => id === taskId ||
      planId.length > 0 && this.overview.tasks.some((task: PlanningTask) => task.task_id === id && task.plan_id === planId));
    if (locked === undefined) { return false; }
    this.errorText = '这项任务的完成或恢复结果尚待核对，请先处理原操作。其他任务仍可继续。';
    this.onOpenStatus(locked); return true;
  }

  private async requestDelete(task: PlanningTask): Promise<void> {
    await this.previewAction({ operation: 'delete_task', task_id: task.task_id });
  }

  private planPrompt(): string {
    return `请读取我的课表和未完成待办，为北京时间 ${this.week().startDate} 至 ${this.week().endDate} 制定一份可执行的学习计划。要求避开课程冲突，拆分里程碑和具体任务，为每项任务设置明确时间、地点与提醒；先展示提案，等我确认后再写入规划。`;
  }

  private reviewPrompt(): string {
    return `请根据北京时间 ${this.selectedDate} 这一天的课程和未完成任务安排学习。请先核对完整起止时间、课程重叠和已有待办，再给出待确认候选；不假定今天或今晚，不自动执行。`;
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

  private reviewRequested(): void {
    if (this.active && !this.mutationBusy && !this.captureOnly) { this.onOpenReview('week', this.selectedDate); }
  }

  @Builder
  private SourceStatus() {
    Column({ space: 8 }) {
      if (!this.sourcesComplete()) {
        Text(`${this.sourceLabel(this.timetableState, '课表')} · ${this.sourceLabel(this.planningState, '任务')}`)
          .fontSize(this.palette.metaSize).fontColor(this.palette.warning).width('100%').wordBreak(WordBreak.BREAK_WORD)
        Text('部分安排尚未读取，暂不能判断空档。').fontSize(this.palette.metaSize)
          .fontColor(this.palette.secondary).width('100%')
        Button('重新核对课表与任务').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
          .fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft).enabled(!this.loading).onClick(() => this.reload(true))
      }
      EvidencePanel({ evidence: this.timetableEvidence, active: this.active && this.detailKind.length === 0 && this.currentView === 'schedule' })
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private TimelineRow(item: PlanningTimelineItem) {
    Row({ space: 4 }) {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 12 }) {
          Text(item.time).fontSize(this.palette.metaSize).fontWeight(FontWeight.Medium).fontColor(this.palette.accent)
            .width(76).wordBreak(WordBreak.BREAK_WORD)
          Column({ space: 4 }) {
            Text(item.title).fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium).fontColor(this.palette.ink)
              .width('100%').wordBreak(WordBreak.BREAK_WORD)
              .decoration({ type: item.completed ? TextDecorationType.LineThrough : TextDecorationType.None })
            Text(`${item.kind}${item.completed ? ' · 已完成' : ''}${item.detail.length > 0 ? ` · ${item.detail}` : ' · 未设置地点'}`)
              .fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
            ForEach(this.tasksForId(item.taskId), (task: PlanningTask) => {
              if (this.overlapLabel(task).length > 0) {
                Text(this.overlapLabel(task)).fontSize(this.palette.metaSize).fontColor(this.palette.warning).width('100%').wordBreak(WordBreak.BREAK_WORD)
              }
              if (this.taskOverdue(task)) { Text('时间已过 · 尚待处理').fontSize(this.palette.metaSize).fontColor(this.palette.danger).width('100%') }
            }, (task: PlanningTask) => task.task_id)
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        }.width('100%').alignItems(VerticalAlign.Top)
      }.layoutWeight(1).constraintSize({ minHeight: 56 }).padding({ top: 12, bottom: 12 })
        .backgroundColor(Color.Transparent).borderRadius(this.palette.controlRadius)
        .accessibilityText(`${item.kind}详情：${item.title}，${item.time}`).onClick(() => this.openTimeline(item))
      ForEach(this.tasksForId(item.taskId), (task: PlanningTask) => { this.TaskCheck(task) }, (task: PlanningTask) => task.task_id)
    }.width('100%').alignItems(VerticalAlign.Top)
  }

  @Builder
  private DayTimeline() {
    Column({ space: 12 }) {
      Text(this.selectedDate).fontSize(this.palette.sectionTitle).fontWeight(FontWeight.Medium).fontColor(this.palette.ink).width('100%')
      Text('课程与定时待办').fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
      if (this.dayTimeline().length === 0 && this.sourcesComplete()) {
        Text('当天暂无已读取的定时安排。')
          .fontSize(this.palette.bodySize).fontColor(this.palette.secondary).width('100%')
      }
      Column() {
        ForEach(this.dayTimeline(), (item: PlanningTimelineItem) => {
          this.TimelineRow(item)
          Divider().color(this.palette.line)
        }, (item: PlanningTimelineItem) => `${item.key}-${this.planningRevision}`)
      }.width('100%')
      if (this.allDayTasks().length > 0) {
        Text('全天 · 未指定时段').fontSize(this.palette.sectionTitle).fontWeight(FontWeight.Medium).fontColor(this.palette.ink).width('100%')
        ForEach(this.allDayTasks(), (task: PlanningTask) => { this.TaskRow(task) }, (task: PlanningTask) => `${task.task_id}-${this.planningRevision}`)
      }
      Button('查看待安排事项').width('100%').constraintSize({ minHeight: 48 })
        .fontSize(this.palette.bodySize).fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft)
        .borderRadius(this.palette.controlRadius).onClick(() => this.openUndated())
    }.width('100%').alignItems(HorizontalAlign.Start).padding(this.palette.cardInset)
      .backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
      .border({ width: 1, color: this.palette.line })
  }

  @Builder
  private WeekOverview() {
    Column({ space: 16 }) {
      Text('本周安排').fontSize(this.palette.sectionTitle).fontWeight(FontWeight.Medium).fontColor(this.palette.ink).width('100%')
      if (!this.week().valid) { Text(this.week().message).fontSize(this.palette.bodySize).fontColor(this.palette.warning).width('100%') }
      ForEach(this.week().days, (day: PlanningWeekDay, index: number) => {
        Column({ space: 8 }) {
          Button({ type: ButtonType.Normal }) {
            Row({ space: 8 }) {
              Text(`周${['一', '二', '三', '四', '五', '六', '日'][index]} · ${day.date}`).fontSize(this.palette.bodySize)
                .fontWeight(FontWeight.Medium).fontColor(this.palette.ink).layoutWeight(1).wordBreak(WordBreak.BREAK_WORD)
              AppIcon({ name: 'chevron', iconSize: 16, color: this.palette.accent })
            }.width('100%')
          }.width('100%').constraintSize({ minHeight: 48 }).backgroundColor(Color.Transparent).padding(0)
            .accessibilityText(`打开 ${day.date} 日程`).onClick(() => this.openWeekDay(day.date))
          if (day.rows.length === 0 && day.allDay.length === 0) {
            Text(this.sourcesComplete() ? '暂无已排安排' : '尚无已读取安排，来源待核对').fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
          }
          ForEach(this.timelineFor(day.date), (item: PlanningTimelineItem) => {
            this.TimelineRow(item)
            Divider().color(this.palette.line)
          }, (item: PlanningTimelineItem) => `${item.key}-${this.planningRevision}`)
          if (day.allDay.length > 0) {
            Text('全天').fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
            ForEach(day.allDay, (task: PlanningTask) => { this.TaskRow(task) }, (task: PlanningTask) => `${task.task_id}-${this.planningRevision}`)
          }
        }.width('100%').padding(this.palette.cardInset).backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
          .border({ width: 1, color: this.palette.line })
      }, (day: PlanningWeekDay) => `${day.date}-${this.planningRevision}-${this.timetableRevision}`)
      if (this.week().undated.length > 0) {
        Text(`尚未归入日期 · ${this.week().undated.length} 项`).fontSize(this.palette.sectionTitle).fontColor(this.palette.ink).width('100%')
        Text('包含无日期与时间异常项目，可到全部待办逐项核对。').fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
        ForEach(this.week().undated, (task: PlanningTask) => { this.TaskRow(task) }, (task: PlanningTask) => `${task.task_id}-${this.planningRevision}`)
      }
      if (this.week().unplacedCourses.length > 0) {
        Text('部分课程时间异常，未纳入周时段，请在课表中核对。').fontSize(this.palette.bodySize).fontColor(this.palette.warning).width('100%')
        Button('打开课表核对').constraintSize({ minHeight: 44 }).fontSize(this.palette.bodySize)
          .fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft).borderRadius(this.palette.controlRadius)
          .onClick(() => this.onOpenTimetable())
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private LoadSummary(load: () => PlanningDayLoad, label: string) {
    // Read reactive inputs inside update callbacks, not once at Builder creation.
    Column({ space: 8 }) {
      Text(`${label} · ${load().date}`).fontSize(this.palette.sectionTitle).fontWeight(FontWeight.Medium).fontColor(this.palette.ink).width('100%')
      if (!this.sourcesComplete()) {
        Text('课表或任务尚未完整核对，暂不判断预计负荷。').fontSize(this.palette.bodySize).fontColor(this.palette.warning).width('100%')
      } else if (!load().valid) {
        Text(load().message).fontSize(this.palette.bodySize).fontColor(this.palette.warning).width('100%')
      } else {
        Text(`课程 ${this.minutes(load().courseMinutes)} 分钟 · 任务 ${this.minutes(load().taskMinutes)} 分钟`)
          .fontSize(this.palette.bodySize).fontColor(this.palette.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
        Text(`合计占用 ${this.minutes(load().totalMinutes)} 分钟 · 重叠时段只计一次`)
          .fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
        Text(this.loadExclusions(load())).fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
        if (this.loadTargetMessage(load()).length > 0) {
          Text(this.loadTargetMessage(load())).fontSize(this.palette.metaSize).fontColor(this.palette.warning).width('100%').wordBreak(WordBreak.BREAK_WORD)
        } else if (this.preferencesState !== 'ready') {
          Text('学习偏好尚未核对，不套用每日目标。').fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
        }
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(this.palette.cardInset)
      .backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
      .border({ width: 1, color: this.palette.line })
  }

  @Builder
  private TaskCheck(task: PlanningTask) {
    Button({ type: ButtonType.Normal }) {
      if (this.statusLockedTaskIds.includes(task.task_id)) {
        Text('核对结果').fontSize(this.palette.metaSize).fontColor(this.palette.accent).wordBreak(WordBreak.BREAK_WORD)
      } else {
      Stack() {
        Circle().width(22).height(22)
          .fill(task.status === 'completed' ? this.palette.accent : this.palette.surface)
          .stroke(task.status === 'completed' ? this.palette.accent : this.palette.quiet).strokeWidth(1.5)
        if (task.status === 'completed') {
          AppIcon({ name: 'check', iconSize: 14, color: this.palette.onAccent })
        }
      }.width(24).height(24)
      }
    }.width(this.statusLockedTaskIds.includes(task.task_id) ? 88 : 48).constraintSize({ minHeight: 48 }).backgroundColor(Color.Transparent)
      .enabled(this.statusLockedTaskIds.includes(task.task_id) || !this.writesBlocked()).accessibilityText(this.statusLabel(task))
      .onClick(() => this.toggle(task))
  }

  @Builder
  private PlanTask(task: PlanningTask) {
    Column({ space: 8 }) {
      Row({ space: 4 }) {
        this.TaskCheck(task)
        Text(task.title).fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium).wordBreak(WordBreak.BREAK_WORD)
          .fontColor(task.status === 'completed' ? this.palette.muted : this.palette.ink)
          .decoration({ type: task.status === 'completed' ?
            TextDecorationType.LineThrough : TextDecorationType.None })
          .layoutWeight(1)
      }.width('100%').alignItems(VerticalAlign.Top)
      if (this.scheduleTypesValid(task)) {
        TaskScheduleDetails({ startAt: task.start_at, endAt: task.end_at,
          location: task.location, reminderMinutes: task.reminder_minutes })
      } else {
        Text('时间格式异常，请核对后再安排。').fontSize(this.palette.metaSize).fontColor(this.palette.danger).width('100%')
      }
      if (task.status === 'completed') {
        Text(this.statusLabel(task)).fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
      } else if (this.taskOverdue(task)) {
        Text('已逾期').fontSize(this.palette.metaSize).fontColor(this.palette.danger).width('100%')
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(12)
      .backgroundColor(this.palette.canvas).borderRadius(this.palette.controlRadius)
  }

  @Builder
  private PlanBody(plan: PlanSummary) {
    Column({ space: 12 }) {
      Text('以下时间均为北京时间').fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
      if (plan.summary.length > 0) {
        Text(plan.summary).fontSize(this.palette.bodySize).fontColor(this.palette.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
      }
      if (plan.milestones.length === 0) {
        Text('此计划尚未设置里程碑。').fontSize(this.palette.bodySize).fontColor(this.palette.quiet).width('100%')
      }
      ForEach(plan.milestones, (milestone: PlanMilestone) => {
        Column({ space: 8 }) {
          Divider().color(this.palette.line)
          Text(milestone.title).fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium).wordBreak(WordBreak.BREAK_WORD)
            .fontColor(this.palette.ink).width('100%')
          Text(`截止：${formatPlanDateTime(milestone.due_at)} · ${milestone.completed_count}/${milestone.task_count} 项已完成`)
            .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
          if (this.milestoneTasks(plan.plan_id, milestone.milestone_id).length === 0) {
            Text('这个里程碑下暂无任务。').fontSize(this.palette.bodySize).fontColor(this.palette.quiet).width('100%')
          }
          ForEach(this.milestoneTasks(plan.plan_id, milestone.milestone_id), (task: PlanningTask) => {
            this.TaskRow(task)
          }, (task: PlanningTask) => `${task.task_id}-${this.planningRevision}`)
        }.width('100%').alignItems(HorizontalAlign.Start)
      }, (milestone: PlanMilestone) => `${plan.plan_id}-${milestone.milestone_id}`)
      if (this.ungroupedPlanTasks(plan).length > 0) {
        Column({ space: 8 }) {
          Divider().color(this.palette.line)
          Text('未归入里程碑的任务').fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium)
            .fontColor(this.palette.ink).width('100%')
          ForEach(this.ungroupedPlanTasks(plan), (task: PlanningTask) => {
            this.TaskRow(task)
          }, (task: PlanningTask) => `${task.task_id}-${task.status}-${task.completed_at ?? ''}`)
        }.width('100%').alignItems(HorizontalAlign.Start)
      } else if (plan.milestones.length === 0) {
        Text('此计划暂无任务。').fontSize(this.palette.bodySize).fontColor(this.palette.quiet).width('100%')
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private TaskDetailLink(task: PlanningTask) {
    Button('查看任务详情').width('100%').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
      .fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft).borderRadius(this.palette.controlRadius)
      .onClick(() => this.openDetails('task', task.task_id))
  }

  @Builder
  private ConfirmedPlans() {
    Column({ space: 16 }) {
      Text(`目标计划 · ${this.overview.plans.length} 个`).fontSize(this.palette.sectionTitle)
        .fontWeight(FontWeight.Bold).fontColor(this.palette.ink).width('100%')
      Text(`${this.overview.completed_tasks}/${this.overview.total_tasks} 项任务已完成`)
        .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
      if (this.overview.plans.length === 0 && !this.loading && this.loaded) {
        Text('还没有已确认的目标计划。向助手描述目标，确认提案后在这里推进。')
          .fontSize(this.palette.bodySize).fontColor(this.palette.quiet).width('100%')
      }
      Button('让助手规划这一周').width('100%').constraintSize({ minHeight: 48 })
        .fontSize(this.palette.bodySize).fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft)
        .borderRadius(this.palette.controlRadius).onClick(() => this.onOpenAgent(this.planPrompt()))
      ForEach(this.overview.plans, (plan: PlanSummary) => {
        Column({ space: 12 }) {
          Text(plan.title).fontSize(this.palette.sectionTitle).fontWeight(FontWeight.Bold).wordBreak(WordBreak.BREAK_WORD)
            .fontColor(this.palette.ink).width('100%')
          Text(`${this.planStatus(plan)} · ${plan.milestones.length} 个里程碑 · ${plan.completed_count}/${plan.task_count} 项已完成`)
            .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
          Text(plan.target_date === null ? '未设截止日' : `截止 ${plan.target_date}`)
            .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
          Button('打开完整计划').width('100%').constraintSize({ minHeight: 48 })
            .fontSize(this.palette.bodySize).fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft)
            .borderRadius(this.palette.controlRadius).onClick(() => this.openDetails('plan', plan.plan_id))
          Button(this.expandedPlanIds.includes(plan.plan_id) ? '收起里程碑与任务' : '在列表展开里程碑与任务')
            .width('100%').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
            .fontColor(this.palette.quiet).backgroundColor(Color.Transparent).borderRadius(this.palette.controlRadius)
            .accessibilityText(`${plan.title}，${this.expandedPlanIds.includes(plan.plan_id) ? '已展开，收起' : '已折叠，展开'}`)
            .onClick(() => this.togglePlan(plan.plan_id))
          if (this.expandedPlanIds.includes(plan.plan_id)) { this.PlanBody(plan) }
        }.width('100%').alignItems(HorizontalAlign.Start).padding(this.palette.cardInset)
          .backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
      }, (plan: PlanSummary) => `${plan.plan_id}-${this.planningRevision}`)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private DateChoice(label: string, value: string, choice: string) {
    Button({ type: ButtonType.Normal }) {
      Text(label).fontSize(this.palette.bodySize).width('100%').textAlign(TextAlign.Center)
        .fontWeight(this.dateChoiceSelected(choice, value) ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.dateChoiceSelected(choice, value) ? this.palette.onAccent : this.palette.quiet)
    }.constraintSize({ minHeight: 48 }).padding(10).layoutWeight(1)
      .backgroundColor(this.dateChoiceSelected(choice, value) ? this.palette.accent : this.palette.canvas)
      .accessibilityText(`${label}${this.dateChoiceSelected(choice, value) ? '，已选中' : ''}`)
      .borderRadius(this.palette.controlRadius).onClick(() => this.selectDraftDate(value, choice))
  }

  @Builder
  private TimeChoice(label: string, value: string) {
    Button({ type: ButtonType.Normal }) {
      Text(label).fontSize(this.palette.bodySize).width('100%').textAlign(TextAlign.Center)
        .fontWeight(this.draftTaskTime === value ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.draftTaskTime === value ? this.palette.onAccent : this.palette.quiet)
    }.constraintSize({ minHeight: 48 }).padding(10).layoutWeight(1)
      .backgroundColor(this.draftTaskTime === value ? this.palette.accent : this.palette.canvas)
      .accessibilityText(`${label}${this.draftTaskTime === value ? '，已选中' : ''}`)
      .borderRadius(this.palette.controlRadius).onClick(() => this.selectDraftTime(value))
  }

  @Builder
  private MonthCalendar() {
    Column({ space: 16 }) {
      Row() {
        Text(this.monthLabel()).fontSize(this.palette.sectionTitle).fontWeight(FontWeight.Bold).fontColor(this.palette.ink)
          .layoutWeight(1)
        Button({ type: ButtonType.Circle }) {
          AppIcon({ name: 'back', iconSize: 17, color: this.palette.accent })
        }.width(48).height(48).backgroundColor(Color.Transparent).accessibilityText('上个月')
          .onClick(() => this.moveMonth(-1))
        Button({ type: ButtonType.Circle }) {
          AppIcon({ name: 'chevron', iconSize: 17, color: this.palette.accent })
        }.width(48).height(48).backgroundColor(Color.Transparent).accessibilityText('下个月')
          .onClick(() => this.moveMonth(1))
      }.width('100%')
        Column({ space: 8 }) {
          Row() {
            ForEach(['日', '一', '二', '三', '四', '五', '六'], (label: string) => {
              Text(label).fontSize(this.palette.metaSize).fontColor(this.palette.quiet).textAlign(TextAlign.Center).layoutWeight(1)
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
                      Text(`${item.day}`).fontSize(this.palette.bodySize)
                        .fontWeight(this.selectedDate === item.date ? FontWeight.Bold : FontWeight.Regular)
                      Text(item.courseCount + item.taskCount > 0 ? '·' : ' ')
                        .fontSize(this.palette.metaSize)
                    }.width('100%').justifyContent(FlexAlign.Center)
                  }.width('100%').height(48).padding(0)
                    .fontColor(this.selectedDate === item.date ? this.palette.onAccent : this.palette.ink)
                    .backgroundColor(this.selectedDate === item.date ? this.palette.accent : Color.Transparent)
                    .borderRadius(this.palette.controlRadius)
                    .accessibilityText(`${item.date}，${item.courseCount} 节课，${item.taskCount} 项任务${this.selectedDate === item.date ? '，已选中' : ''}`)
                    .onClick(() => this.selectDay(item.date))
                }
              }
            }, (item: CalendarDay) => `${item.key}-${item.courseCount}-${item.taskCount}-${this.selectedDate}`)
          }.columnsTemplate('repeat(7, 1fr)').columnsGap(0).rowsGap(4).width('100%')
            .height(this.calendarDays().length > 35 ? 308 : 256)
        }.width('100%')
    }.width('100%')
  }

  @Builder
  private CoursePermission(value: boolean, change: (value: boolean) => void) {
    Column({ space: 8 }) {
      Button(value ? '已允许 · 可在上课时完成' : '可在上课时完成 · 未开启').width('100%').constraintSize({ minHeight: 48 })
        .fontSize(this.palette.bodySize).fontColor(value ? this.palette.onAccent : this.palette.accent)
        .backgroundColor(value ? this.palette.accent : this.palette.accentSoft).borderRadius(this.palette.controlRadius)
        .enabled(!this.writesBlocked()).onClick(() => change(!value))
      Text(value ? '若与课程重叠，预览会列出具体课程和时段，仍需你再次确认。' : '默认避开课程；适合课内完成的任务可以单独开启。')
        .fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private TaskForm() {
    Column({ space: 16 }) {
      Text(this.draftMessage).fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
      if (this.draftMessage.includes('尚未保存')) {
        Button('重试保存输入').constraintSize({ minHeight: 44 }).fontSize(this.palette.bodySize)
          .fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft).borderRadius(this.palette.controlRadius)
          .onClick(() => { this.stageTaskDraft(); this.flushTaskDraft(); })
      }
      if (this.pendingCaptureIntent !== null) {
        Text(`首页建议 ${this.pendingCaptureIntent.date} ${this.pendingCaptureIntent.time}，留 ${this.pendingCaptureIntent.durationMinutes ?? 0} 分钟。已有输入已保留。`)
          .fontSize(this.palette.bodySize).fontColor(this.palette.secondary).width('100%')
        Button('使用这个时段，保留标题').constraintSize({ minHeight: 44 }).fontSize(this.palette.bodySize)
          .fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft).borderRadius(this.palette.controlRadius).enabled(!this.writesBlocked())
          .onClick(() => this.applyCaptureSuggestion())
      }
      if (this.draftAnchorDate.length > 0 && this.draftAnchorDate !== this.relativeDate(0)) {
        Text(`输入时的日期是 ${this.draftAnchorDate}；当前仍按 ${this.draftTaskDate || '无日期'} 保存，请核对。`)
          .fontSize(this.palette.metaSize).fontColor(this.palette.warning).width('100%')
      }
      Text('记一件事').fontSize(this.palette.sectionTitle).fontColor(this.palette.ink).width('100%')
      TextInput({ text: this.title, placeholder: '例如：明晚八点复习一小时', controller: this.taskInputController })
        .width('100%').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize).fontColor(this.palette.ink)
        .backgroundColor(this.palette.surface).borderRadius(this.palette.controlRadius)
        .border({ width: 1, color: this.palette.outline }).enabled(this.recoveredDraft === null && !this.actionBlocksWrites())
        .onChange((value) => { this.title = value; this.stageTaskDraft(); })
      Button('从这句话提取时间').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
        .fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft).borderRadius(this.palette.controlRadius)
        .enabled(this.title.trim().length > 0 && !this.writesBlocked()).onClick(() => this.parseCapture())
      Text('支持明确日期、时刻和分钟/小时；“下午”“下课后”等不会猜一个时间。提取只填写草稿。')
        .fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
      if (this.captureOriginalText.length > 0) {
        Text(`解析原文：${this.captureOriginalText}`).fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
        ForEach(this.captureIssues, (issue: QuickCaptureIssue) => {
          Text(issue.message).fontSize(this.palette.bodySize).fontColor(this.palette.warning).width('100%').wordBreak(WordBreak.BREAK_WORD)
        }, (issue: QuickCaptureIssue, index: number) => `${index}-${issue.code}`)
        Button('交给助手进一步核对').constraintSize({ minHeight: 44 }).fontSize(this.palette.bodySize).fontColor(this.palette.accent)
          .backgroundColor(this.palette.accentSoft).borderRadius(this.palette.controlRadius).onClick(() => this.captureToAssistant())
      }
      this.EditField('日期 · 可留空', this.draftTaskDate, 'YYYY-MM-DD，留空即无日期', (value: string) => {
        this.draftTaskDate = value; this.draftDateChoice = value.length === 0 ? 'none' : 'capture'; this.stageTaskDraft();
      })
      Row({ space: 8 }) {
        this.DateChoice('今天', this.relativeDate(0), 'today')
        this.DateChoice('明天', this.relativeDate(1), 'tomorrow')
      }.width('100%')
      Row({ space: 8 }) {
        this.DateChoice('日历所选', this.selectedDate, 'calendar')
        this.DateChoice('无日期', '', 'none')
      }.width('100%')
      Button(this.captureTimeExpanded ? '收起时间与时长' : '再安排时间、时长').constraintSize({ minHeight: 48 })
        .fontSize(this.palette.bodySize).fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft)
        .onClick(() => this.captureTimeExpanded = !this.captureTimeExpanded)
      if (this.captureTimeExpanded) {
        Text(`时间：${this.draftTaskTime || '全天 / 尚未定时'} · 北京时间`).fontSize(this.palette.bodySize).fontColor(this.palette.secondary).width('100%')
        Row({ space: 8 }) {
          this.TimeChoice('全天', '')
          this.TimeChoice('08:00', '08:00')
        }.width('100%')
        Row({ space: 8 }) {
          this.TimeChoice('14:00', '14:00')
          Button('自定义时间').constraintSize({ minHeight: 48 }).layoutWeight(1).fontSize(this.palette.bodySize)
            .fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft).borderRadius(this.palette.controlRadius)
            .onClick(() => this.openTimePicker())
        }.width('100%')
        this.EditField('时长 · 分钟', this.durationText, '可留空，例如 25、60', (value: string) => { this.durationText = value; this.stageTaskDraft(); })
      }
      this.CoursePermission(this.allowDuringCourse, (value: boolean) => { this.allowDuringCourse = value; this.stageTaskDraft(); })
      Button(this.draftTaskDate.length === 0 ? '预览无日期待办' : '核对安排预览').width('100%').constraintSize({ minHeight: 48 })
        .fontSize(this.palette.bodySize).fontColor(this.palette.onAccent).backgroundColor(this.palette.accent).borderRadius(this.palette.controlRadius)
        .accessibilityText('预览添加待办').enabled(this.title.trim().length > 0 && !this.writesBlocked()).onClick(() => this.addTask())
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private EditField(label: string, value: string, placeholder: string, change: (value: string) => void) {
    Column({ space: 8 }) {
      Text(label).fontSize(this.palette.bodySize).fontColor(this.palette.quiet).width('100%')
      TextInput({ text: value, placeholder: placeholder }).constraintSize({ minHeight: 48 }).width('100%').fontSize(this.palette.bodySize)
        .fontColor(this.palette.ink).backgroundColor(this.palette.surface).borderRadius(this.palette.controlRadius)
        .border({ width: 1, color: this.palette.outline }).onChange(change)
    }.width('100%')
  }

  @Builder
  private TaskEditor() {
    Column({ space: 16 }) {
      if (this.editTaskId.length === 0) {
        Text('这份编辑已完成或已放弃，返回任务详情可重新编辑。').fontSize(this.palette.bodySize).fontColor(this.palette.quiet).width('100%')
      } else {
        Text('返回会保留草稿。时间使用北京时间；修改前后内容会在下一步完整展示。')
          .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
        this.EditField('任务名称', this.editTaskTitle, '1–120 字', (value: string) => this.editTaskTitle = value)
        this.EditField('开始时间', this.editTaskStart, '例如 2026-10-20 18:30，留空待安排', (value: string) => this.editTaskStart = value)
        this.EditField('结束时间', this.editTaskEnd, '例如 2026-10-20 19:30，可留空', (value: string) => this.editTaskEnd = value)
        this.EditField('地点', this.editTaskLocation, '可留空', (value: string) => this.editTaskLocation = value)
        this.CoursePermission(this.editTaskAllowDuringCourse, (value: boolean) => this.editTaskAllowDuringCourse = value)
        this.EditField('提前提醒（分钟）', this.editTaskReminder, '0 表示开始时；留空不设置', (value: string) => this.editTaskReminder = value)
        Text('这里保存提醒设置；系统通知实际送达仍取决于平台支持与通知权限。')
          .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
        Button('预览任务更改').width('100%').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
          .fontColor(this.palette.onAccent).backgroundColor(this.palette.accent).borderRadius(this.palette.controlRadius)
          .enabled(!this.writesBlocked()).onClick(() => this.previewTaskEdit())
        Button('放弃这份编辑草稿').width('100%').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
          .fontColor(this.palette.quiet).backgroundColor(this.palette.surface).borderRadius(this.palette.controlRadius)
          .enabled(!this.actionBlocksWrites()).onClick(() => this.discardTaskEdit())
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private PlanEditor() {
    Column({ space: 16 }) {
      if (this.editPlanId.length === 0) {
        Text('这份编辑已完成或已放弃，返回计划详情可重新编辑。').fontSize(this.palette.bodySize).fontColor(this.palette.quiet).width('100%')
      } else {
        Text('仅编辑计划信息，现有阶段与子任务不变。返回会保留草稿。')
          .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
        this.EditField('计划名称', this.editPlanTitle, '1–120 字', (value: string) => this.editPlanTitle = value)
        Text('计划说明').fontSize(this.palette.bodySize).fontColor(this.palette.quiet).width('100%')
        TextArea({ text: this.editPlanSummary, placeholder: '最多 500 字，可留空' }).width('100%').constraintSize({ minHeight: 120 })
          .fontSize(this.palette.bodySize).fontColor(this.palette.ink).backgroundColor(this.palette.surface).borderRadius(this.palette.controlRadius)
          .onChange((value: string) => this.editPlanSummary = value)
        this.EditField('截止日期', this.editPlanDate, 'YYYY-MM-DD，留空不设截止日', (value: string) => this.editPlanDate = value)
        Button('预览计划更改').width('100%').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
          .fontColor(this.palette.onAccent).backgroundColor(this.palette.accent).borderRadius(this.palette.controlRadius)
          .enabled(!this.writesBlocked()).onClick(() => this.previewPlanEdit())
        Button('放弃这份编辑草稿').width('100%').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
          .fontColor(this.palette.quiet).backgroundColor(this.palette.surface).borderRadius(this.palette.controlRadius)
          .enabled(!this.actionBlocksWrites()).onClick(() => this.discardPlanEdit())
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private TaskRow(task: PlanningTask) {
    Row({ space: 4 }) {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 12 }) {
          Column({ space: 4 }) {
            Text(this.taskRowDate(task)).fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
            Text(this.taskTime(task)).fontSize(this.palette.metaSize).fontWeight(FontWeight.Medium).fontColor(this.palette.accent).width('100%').wordBreak(WordBreak.BREAK_WORD)
          }.width(76).alignItems(HorizontalAlign.Start)
          Column({ space: 4 }) {
            Text(task.title).fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium).fontColor(this.palette.ink)
              .decoration({ type: task.status === 'completed' ? TextDecorationType.LineThrough : TextDecorationType.None })
              .width('100%').wordBreak(WordBreak.BREAK_WORD)
            Text(`${this.taskSource(task)} · ${task.status === 'completed' ? '已完成' : '待完成'}${task.location ? ` · ${task.location}` : ''}`)
              .fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
            if (this.overlapLabel(task).length > 0) { Text(this.overlapLabel(task)).fontSize(this.palette.metaSize).fontColor(this.palette.warning).width('100%').wordBreak(WordBreak.BREAK_WORD) }
            if (this.taskOverdue(task)) { Text('时间已过 · 尚待处理').fontSize(this.palette.metaSize).fontColor(this.palette.danger).width('100%') }
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        }.width('100%').alignItems(VerticalAlign.Top)
      }.layoutWeight(1).constraintSize({ minHeight: 56 }).padding({ top: 12, bottom: 12 })
        .backgroundColor(Color.Transparent).borderRadius(this.palette.controlRadius)
        .accessibilityText(`查看任务详情：${task.title}`).onClick(() => this.openDetails('task', task.task_id))
      this.TaskCheck(task)
    }.width('100%').alignItems(VerticalAlign.Top).padding({ left: 12, right: 8 })
      .backgroundColor(this.palette.surface).borderRadius(this.palette.controlRadius)
  }

  @Builder
  private TaskFilter(label: string, filter: string) {
    Button({ type: ButtonType.Normal }) {
      Text(label).fontSize(this.palette.bodySize).textAlign(TextAlign.Center).width('100%').wordBreak(WordBreak.BREAK_WORD)
        .fontWeight(this.taskFilter === filter ? FontWeight.Medium : FontWeight.Regular).fontColor(this.palette.ink)
    }.layoutWeight(1).constraintSize({ minHeight: 44 }).padding(8)
      .backgroundColor(this.taskFilter === filter ? this.palette.surface : Color.Transparent).borderRadius(9)
      .accessibilityText(`${label}${this.taskFilter === filter ? '，已选中' : ''}`).onClick(() => this.selectTaskFilter(filter))
  }

  @Builder
  private QueryDate(label: string, value: string) {
    Button({ type: ButtonType.Normal }) {
      Text(label).fontSize(this.palette.bodySize).textAlign(TextAlign.Center).width('100%').wordBreak(WordBreak.BREAK_WORD)
        .fontColor(this.query().dateMode === value ? this.palette.onAccent : this.palette.secondary)
    }.layoutWeight(1).constraintSize({ minHeight: 48 }).padding(8)
      .fontColor(this.query().dateMode === value ? this.palette.onAccent : this.palette.secondary)
      .backgroundColor(this.query().dateMode === value ? this.palette.accent : this.palette.surface).borderRadius(this.palette.controlRadius)
      .accessibilityText(`${label}${this.query().dateMode === value ? '，已选中' : ''}`).onClick(() => this.selectQueryDate(value))
  }

  @Builder
  private AllTasks() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
      TextInput({ text: this.queryText, placeholder: '搜索标题或地点' }).layoutWeight(1).height(44)
        .fontSize(this.palette.bodySize).fontColor(this.palette.ink).backgroundColor(this.palette.surface).borderRadius(this.palette.controlRadius)
        .onChange((value: string) => { this.queryText = value; this.queryPage = 0; })
      Button(this.taskFiltersExpanded ? '收起' : '筛选').constraintSize({ minWidth: 52, minHeight: 44 })
        .fontSize(this.palette.bodySize).fontColor(this.palette.accent).backgroundColor(Color.Transparent)
        .accessibilityText(this.taskFiltersExpanded ? '收起详细筛选，保留当前条件' : '展开详细筛选')
        .onClick(() => animateTo({ duration: AppTheme.motion(180), curve: Curve.EaseOut }, () => this.taskFiltersExpanded = !this.taskFiltersExpanded))
      }.width('100%')
      Text(`${this.queryResult().matched} 项待办 · ${this.querySummary()}`)
        .fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
      if (this.taskFiltersExpanded) {
      Column({ space: 12 }) {
      Row({ space: 8 }) { this.TaskFilter('全部', 'all')
        this.TaskFilter('待完成', 'pending')
        this.TaskFilter('已完成', 'completed') }.width('100%').padding(3).backgroundColor(this.palette.field).borderRadius(12)
      Text('日期条件 · 与状态、搜索同时生效').fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
      Row({ space: 8 }) { this.QueryDate('不限日期', 'all')
        this.QueryDate('日历所选', 'day') }.width('100%')
      Row({ space: 8 }) { this.QueryDate('日期范围', 'range')
        this.QueryDate('待定日期', 'undated') }.width('100%')
      if (this.query().dateMode === 'day') { Text(`所选日期 ${this.selectedDate} · 北京时间`).fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%') }
      if (this.query().dateMode === 'range') {
        this.EditField('从哪一天', this.queryFromDate, 'YYYY-MM-DD', (value: string) => { this.queryFromDate = value; this.queryPage = 0; })
        this.EditField('到哪一天（包含当天）', this.queryToDate, 'YYYY-MM-DD', (value: string) => { this.queryToDate = value; this.queryPage = 0; })
      }
      Row({ space: 8 }) {
        Button(this.querySort === 'schedule' ? '按安排时间 · 已选' : '按安排时间').layoutWeight(1).constraintSize({ minHeight: 48 })
          .fontSize(this.palette.metaSize).fontColor(this.palette.accent).backgroundColor(this.querySort === 'schedule' ? this.palette.accentSoft : this.palette.surface)
          .onClick(() => { this.querySort = 'schedule'; this.queryPage = 0; })
        Button(this.querySort === 'created' ? '最近创建 · 已选' : '最近创建').layoutWeight(1).constraintSize({ minHeight: 48 })
          .fontSize(this.palette.metaSize).fontColor(this.palette.accent).backgroundColor(this.querySort === 'created' ? this.palette.accentSoft : this.palette.surface)
          .onClick(() => { this.querySort = 'created'; this.queryPage = 0; })
      }.width('100%')
      InfoDisclosure({ title: '排序说明', message: this.querySort === 'created' ? '创建时间由近到远；相同时按稳定编号排序。' : '安排时间由早到晚；无日期与异常日期在末尾，同时间按创建时间与编号排序。' })
      Text(`匹配 ${this.queryResult().matched} 项 / 已读取 ${this.queryResult().total} 项 · 本页 ${this.visibleTasks().length} 项`)
        .fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
      Button('清除全部筛选').constraintSize({ minHeight: 44 }).fontSize(this.palette.bodySize).fontColor(this.palette.accent)
        .backgroundColor(Color.Transparent).onClick(() => this.clearQuery())
      }.width('100%').padding(16).backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
      }
      if (this.planningState !== 'ready') {
      Text(this.sourceLabel(this.planningState, '任务')).fontSize(this.palette.metaSize).fontColor(this.planningState === 'ready' ? this.palette.secondary : this.palette.warning).width('100%')
      }
      if (!this.queryResult().valid) { Text(this.queryResult().message).fontSize(this.palette.bodySize).fontColor(this.palette.warning).width('100%') }
      if (this.queryResult().invalidDateCount > 0) {
        Text(`${this.queryResult().invalidDateCount} 项日期格式需核对；可在“待定日期”中查看，不会计入指定日期。`)
          .fontSize(this.palette.metaSize).fontColor(this.palette.warning).width('100%').wordBreak(WordBreak.BREAK_WORD)
      }
      if (this.filteredTasks().length === 0 && this.planningState === 'ready' && this.queryResult().valid) {
        Text(this.overview.tasks.length === 0 ? '还没有保存的待办。记下第一件事，再慢慢安排时间。' : '没有同时符合这些条件的待办。原有任务未被删除。')
          .fontSize(this.palette.bodySize).fontColor(this.palette.secondary).width('100%')
      }
      ForEach(this.visibleTasks(), (task: PlanningTask) => { this.TaskRow(task) }, (task: PlanningTask) => `${task.task_id}-${this.planningRevision}`)
      if (this.filteredTasks().length > 20) {
        Text(`第 ${this.currentQueryPage() + 1} / ${Math.ceil(this.filteredTasks().length / 20)} 页`).fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
        Row({ space: 8 }) {
          Button('上一页').layoutWeight(1).constraintSize({ minHeight: 44 }).fontSize(this.palette.bodySize).fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft).borderRadius(this.palette.controlRadius).enabled(this.currentQueryPage() > 0).onClick(() => this.moveQueryPage(-1))
          Button('下一页').layoutWeight(1).constraintSize({ minHeight: 44 }).fontSize(this.palette.bodySize).fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft).borderRadius(this.palette.controlRadius).enabled((this.currentQueryPage() + 1) * 20 < this.filteredTasks().length).onClick(() => this.moveQueryPage(1))
        }.width('100%')
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private ViewTab(label: string, view: string) {
    Button({ type: ButtonType.Normal }) {
      Text(label).fontSize(15).fontWeight(this.currentView === view ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.palette.ink)
        .width('100%').textAlign(TextAlign.Center).wordBreak(WordBreak.BREAK_WORD)
    }.layoutWeight(1).constraintSize({ minHeight: 44 }).padding({ left: 4, right: 4, top: 6, bottom: 6 })
      .backgroundColor(this.currentView === view ? this.palette.surface : Color.Transparent)
      .borderRadius(9).accessibilityText(`${label}${this.currentView === view ? '，已选中' : ''}`)
      .onClick(() => this.selectView(view))
  }

  @Builder
  private WeekStrip() {
      Row({ space: 4 }) {
        ForEach(this.weekDays(), (day: CalendarDay, index: number) => {
          Button({ type: ButtonType.Normal }) {
            Column({ space: 4 }) {
              Text(['一', '二', '三', '四', '五', '六', '日'][index]).fontSize(this.palette.metaSize)
              Text(`${day.day}`).fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium)
              Text(day.courseCount + day.taskCount > 0 ? `${day.courseCount + day.taskCount}` : '—').fontSize(this.palette.metaSize)
            }.width('100%').alignItems(HorizontalAlign.Center)
          }.layoutWeight(1).constraintSize({ minHeight: 76 }).padding({ top: 8, bottom: 8, left: 2, right: 2 })
            .fontColor(this.selectedDate === day.date ? this.palette.onAccent : this.palette.ink)
            .backgroundColor(this.selectedDate === day.date ? this.palette.accent : this.palette.surface)
            .borderRadius(this.palette.controlRadius)
            .accessibilityText(`${day.date}，${day.courseCount} 节课，${day.taskCount} 项任务${this.selectedDate === day.date ? '，已选中' : ''}`)
            .onClick(() => this.selectDay(day.date))
        }, (day: CalendarDay) => `${day.key}-${day.courseCount}-${day.taskCount}-${this.selectedDate}`)
      }.width('100%')
  }

  @Builder
  private ScheduleView() {
    Column({ space: this.palette.sectionGap }) {
      Column({ space: 12 }) {
      Row({ space: 8 }) {
        Button('上一周').constraintSize({ minHeight: 44 }).fontSize(this.palette.metaSize).fontColor(this.palette.accent).backgroundColor(Color.Transparent).onClick(() => this.moveWeek(-1))
        Text(`${this.week().startDate.substring(5)} — ${this.week().endDate.substring(5)}`).layoutWeight(1).fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium).fontColor(this.palette.ink).textAlign(TextAlign.Center)
        Button('下一周').constraintSize({ minHeight: 44 }).fontSize(this.palette.metaSize).fontColor(this.palette.accent).backgroundColor(Color.Transparent).onClick(() => this.moveWeek(1))
      }.width('100%')
      this.WeekStrip()
      Row({ space: 8 }) {
        Row({ space: 2 }) {
          Button('当天').layoutWeight(1).constraintSize({ minHeight: 44 }).fontSize(this.palette.metaSize)
            .fontColor(this.palette.ink).backgroundColor(this.scheduleMode === 'day' ? this.palette.surface : Color.Transparent)
            .borderRadius(8).onClick(() => this.scheduleMode = 'day')
          Button('整周').layoutWeight(1).constraintSize({ minHeight: 44 }).fontSize(this.palette.metaSize)
            .fontColor(this.palette.ink).backgroundColor(this.scheduleMode === 'week' ? this.palette.surface : Color.Transparent)
            .borderRadius(8).onClick(() => this.scheduleMode = 'week')
        }.layoutWeight(1).padding(2).backgroundColor(this.palette.field).borderRadius(10)
        Button('今天').constraintSize({ minHeight: 44 }).fontSize(this.palette.metaSize)
          .fontColor(this.palette.accent).backgroundColor(Color.Transparent)
          .onClick(() => this.selectDay(this.relativeDate(0)))
        Button(this.calendarExpanded ? '收起月历' : '月历').constraintSize({ minHeight: 44 })
          .fontSize(this.palette.metaSize).fontColor(this.palette.accent).backgroundColor(Color.Transparent)
          .borderRadius(this.palette.controlRadius).onClick(() => this.toggleCalendar())
      }.width('100%')
      if (this.calendarExpanded) {
        Divider().color(this.palette.line)
        this.MonthCalendar()
      }
      }.width('100%').padding(12).backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
      if (!this.sourcesComplete()) { this.SourceStatus() }
      if (this.scheduleMode === 'week') { this.WeekOverview() } else { this.DayTimeline() }
      this.LoadSummary(() => this.dayLoad(this.selectedDate), '当前预计负荷')
      InfoDisclosure({ title: '负荷计算说明', message: '依据已排起止时段估算，重叠时段只计一次，包含已完成安排；不是实际学习时长。全天、无日期与缺少结束时间的事项不计时长，时间异常的事项需另行核对。' })
      Button('请助手安排这一天').width('100%').constraintSize({ minHeight: 48 })
        .fontSize(this.palette.bodySize).fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft)
        .borderRadius(this.palette.controlRadius).onClick(() => this.onOpenAgent(this.reviewPrompt()))
      if (!this.captureOnly) {
      Row({ space: 12 }) {
        Button('本周回顾').constraintSize({ minHeight: 48 }).layoutWeight(1).fontSize(this.palette.bodySize)
          .fontColor(this.palette.accent).backgroundColor(this.palette.surface).enabled(!this.mutationBusy)
          .onClick(() => this.reviewRequested())
        Button('课表维护').constraintSize({ minHeight: 48 }).layoutWeight(1).fontSize(this.palette.bodySize)
          .fontColor(this.palette.accent).backgroundColor(this.palette.surface).onClick(() => this.onOpenTimetable())
      }.width('100%')
      }
      if (this.sourcesComplete()) { this.SourceStatus() }
    }.width('100%').padding({ left: this.palette.pageInset, right: this.palette.pageInset, top: 12, bottom: 24 })
  }

  @Builder
  private TaskDetailSummary(task: PlanningTask) {
    Column({ space: 16 }) {
      Text(task.title).fontSize(24).fontWeight(FontWeight.Bold).fontColor(this.palette.ink)
        .width('100%').wordBreak(WordBreak.BREAK_WORD)
      Row({ space: 8 }) {
        Text(task.status === 'completed' ? '已完成' : this.taskOverdue(task) ? '已逾期' : '待完成')
          .fontSize(this.palette.metaSize).fontWeight(FontWeight.Medium)
          .fontColor(task.status === 'completed' ? this.palette.success : this.taskOverdue(task) ? this.palette.danger : this.palette.accent)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(task.status === 'completed' ? this.palette.successSoft : this.taskOverdue(task) ? this.palette.dangerSoft : this.palette.accentSoft)
          .borderRadius(8)
        if (task.plan_id !== null) {
          Text('计划内任务').fontSize(this.palette.metaSize).fontColor(this.palette.secondary)
        }
      }.width('100%')
      Divider().color(this.palette.line)
      if (this.scheduleTypesValid(task)) {
        TaskScheduleDetails({ startAt: task.start_at, endAt: task.end_at,
          location: task.location, reminderMinutes: task.reminder_minutes })
      } else {
        Text('时间格式异常，请编辑后重新安排。').fontSize(this.palette.metaSize).fontColor(this.palette.danger).width('100%')
      }
      Button(this.statusLockedTaskIds.includes(task.task_id) ? '核对完成结果' : task.status === 'completed' ? '恢复为未完成' : '标记完成')
        .width('100%').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
        .fontColor(task.status === 'completed' ? this.palette.accent : this.palette.onAccent)
        .backgroundColor(task.status === 'completed' ? this.palette.accentSoft : this.palette.accent)
        .borderRadius(this.palette.controlRadius)
        .enabled(this.statusLockedTaskIds.includes(task.task_id) || !this.writesBlocked())
        .accessibilityText(this.statusLabel(task)).onClick(() => this.toggle(task))
    }.width('100%').alignItems(HorizontalAlign.Start).padding(this.palette.cardInset)
      .backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
  }

  @Builder
  private DetailContent(frame: PlanningDetailFrame) {
    Column({ space: 16 }) {
      if (frame.kind === 'draft') {
        Text('先记下来，日期可以稍后安排。返回会保留输入；核对预览后才加入任务列表。')
          .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
        this.TaskForm()
      } else if (frame.kind === 'action') {
        if (this.projectedTasks() !== null) {
          this.LoadSummary(() => this.dayLoad(this.previewLoadDate()), '候选前')
          this.LoadSummary(() => this.candidateLoad(), '确认后预计')
          Text('以上只比较当前这份候选；预览不会改动任务，确认时仍会核对最新状态。').fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
        }
        PlanningActionPanel({ state: this.actionState, active: this.active && !this.mutationBusy && !this.replanWriteBlocked && !this.draftStorageBusy,
          retryIntent: this.actionController?.retryIntent() ?? '', onConfirm: (acks: CourseAcknowledgement[]) => this.confirmPlanningAction(acks),
          onCancel: () => this.writePlanningAction(true), onCheck: () => this.checkPlanningAction(),
          onDismiss: () => this.dismissAction(), onOpenTask: (id: string) => this.openDetails('task', id),
          onOpenPlan: (id: string) => this.openDetails('plan', id) })
      } else if (frame.kind === 'course') {
        ForEach(this.courseFor(frame.id), (detail: PlanningCourseDetail) => {
          Column({ space: 12 }) {
            Text(detail.reference.course.title).fontSize(this.palette.sectionTitle).fontWeight(FontWeight.Medium).fontColor(this.palette.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
            Text(`${detail.reference.course.date} · ${detail.reference.course.start_time}–${detail.reference.course.end_time} · 北京时间`).fontSize(this.palette.bodySize).fontColor(this.palette.accent).width('100%').wordBreak(WordBreak.BREAK_WORD)
            Text(`地点：${detail.reference.course.location || '未提供'}`).fontSize(this.palette.bodySize).fontColor(this.palette.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
            Text(`教师：${detail.reference.course.teacher || '未提供'}`).fontSize(this.palette.bodySize).fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
            Text(this.timetableState !== 'ready' ? '最新课表尚未核对；下方为打开时的只读快照。' : this.courseCurrent(detail.reference) ?
              '来自当前完整课表；此处只读，编辑请进入课表维护。' : '课表版本已变化；此处保留原课程供核对，请返回日程重新选择。')
              .fontSize(this.palette.bodySize).fontColor(this.timetableState === 'ready' && this.courseCurrent(detail.reference) ? this.palette.secondary : this.palette.warning).width('100%').wordBreak(WordBreak.BREAK_WORD)
            Text(`相同完整记录中的第 ${detail.reference.occurrence} 条`).fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
            EvidencePanel({ evidence: detail.evidence, active: this.active && frame.key === this.topDetailKey() })
            Button('打开课表维护').width('100%').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
              .fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft).onClick(() => this.onOpenTimetable())
          }.width('100%').alignItems(HorizontalAlign.Start).padding(this.palette.cardInset).backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
        }, (detail: PlanningCourseDetail) => detail.reference.key)
      } else if (frame.kind === 'task-edit') {
        this.TaskEditor()
      } else if (frame.kind === 'plan-edit') {
        this.PlanEditor()
      } else if (frame.kind === 'task') {
        ForEach(this.tasksForId(frame.id), (task: PlanningTask) => {
          Column({ space: 12 }) {
            this.TaskDetailSummary(task)
            if (this.overlapLabel(task).length > 0) {
              Text(this.overlapLabel(task)).fontSize(this.palette.bodySize).fontColor(this.palette.warning).width('100%')
              ForEach(task.course_overlap?.overlaps ?? [], (overlap: CourseOverlap) => {
                Text(`${overlap.course.title} · ${overlap.course.date} ${overlap.course.start_time}–${overlap.course.end_time}\n重叠：${formatPlanDateTime(overlap.overlap_start_at)} 至 ${formatPlanDateTime(overlap.overlap_end_at)}`)
                  .fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
              }, (overlap: CourseOverlap) => overlap.course_key)
            }
            if (task.status !== 'completed') {
              Column({ space: 8 }) {
                Text('需要专心做一会儿？').fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium).fontColor(this.palette.ink).width('100%')
                Text('可选计时；结束后再确认任务是否完成。').fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
                Button('开始专注').width('100%').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
                  .fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft).borderRadius(this.palette.controlRadius)
                  .enabled(this.active).onClick(() => this.focusRequested(task))
              }.width('100%').alignItems(HorizontalAlign.Start).padding(this.palette.cardInset)
                .backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
            }
            Column({ space: 0 }) {
              if (task.plan_id !== null) {
                Button('查看所属计划').width('100%').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
                  .fontColor(this.palette.accent).backgroundColor(Color.Transparent).borderRadius(0)
                  .onClick(() => this.openDetails('plan', task.plan_id ?? ''))
                Divider().color(this.palette.line)
              }
              Button('编辑任务与时间').width('100%').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
                .fontColor(this.palette.accent).backgroundColor(Color.Transparent).borderRadius(0)
                .enabled(!this.writesBlocked()).onClick(() => this.beginTaskEdit(task))
              Divider().color(this.palette.line)
              Button('删除任务…').width('100%').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
                .fontColor(this.palette.danger).backgroundColor(Color.Transparent).borderRadius(0)
                .enabled(!this.writesBlocked()).onClick(() => this.requestDelete(task))
            }.width('100%').backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius).clip(true)
          }.width('100%')
        }, (task: PlanningTask) => `${task.task_id}-${this.planningRevision}`)
      } else if (frame.kind === 'plan') {
        ForEach(this.plansForId(frame.id), (plan: PlanSummary) => {
          Column({ space: 12 }) {
            Text(plan.title).fontSize(this.palette.sectionTitle).fontWeight(FontWeight.Bold).fontColor(this.palette.ink)
              .width('100%').wordBreak(WordBreak.BREAK_WORD)
            Text(`${this.planStatus(plan)} · ${plan.completed_count}/${plan.task_count} 项已完成`)
              .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
            Text(plan.target_date === null ? '未设截止日' : `截止 ${plan.target_date}`)
              .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
            this.PlanBody(plan)
            Button('编辑计划信息').width('100%').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
              .fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft).borderRadius(this.palette.controlRadius)
              .enabled(!this.writesBlocked()).onClick(() => this.beginPlanEdit(plan))
            Button('预览删除计划').width('100%').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
              .fontColor(this.palette.danger).backgroundColor(this.palette.dangerSoft).borderRadius(this.palette.controlRadius)
              .enabled(!this.writesBlocked()).onClick(() => this.requestPlanDelete(plan))
          }.width('100%').padding(this.palette.cardInset).backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
        }, (plan: PlanSummary) => `${plan.plan_id}-${this.planningRevision}`)
      }
      if (frame.kind === 'invalid' ||
        (frame.kind === 'task' && this.tasksForId(frame.id).length === 0) ||
        (frame.kind === 'course' && this.courseFor(frame.id).length === 0) ||
        (frame.kind === 'plan' && this.plansForId(frame.id).length === 0)) {
        Text(this.loading ? '正在读取对应内容…' : this.errorText.length > 0 || !this.loaded ?
          '暂时无法读取对应内容，请重新加载。' : '此项目已不存在，或不属于当前账号。')
          .fontSize(this.palette.bodySize).fontColor(this.palette.quiet).width('100%')
        Button('重新加载计划').width('100%').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
          .fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft).borderRadius(this.palette.controlRadius)
          .enabled(!this.loading).onClick(() => this.reload(true))
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
      .padding({ left: this.palette.pageInset, right: this.palette.pageInset, top: 12, bottom: 24 })
  }

  build() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        if (this.detailKind.length > 0) {
          Button({ type: ButtonType.Circle }) {
            AppIcon({ name: 'back', iconSize: 22, color: this.palette.accent })
          }.width(44).height(44).backgroundColor(Color.Transparent)
            .accessibilityText(this.backLabel())
            .onClick(() => this.closeDetails())
        }
        Column({ space: 4 }) {
          Text(this.detailKind.length > 0 ? this.detailTitle() : '计划').fontSize(this.detailKind.length > 0 ? 22 : this.palette.pageTitle)
            .fontWeight(FontWeight.Bold).fontColor(this.palette.ink).width('100%')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        if (this.detailKind.length === 0) {
          Button({ type: ButtonType.Circle }) {
            AppIcon({ name: 'plus', iconSize: 24, color: this.palette.accent })
          }.width(44).height(44).backgroundColor(this.palette.accentSoft)
            .accessibilityText('添加待办')
            .onClick(() => this.openDetails('draft'))
        }
      }.width('100%').padding({ left: this.palette.pageInset, right: this.palette.pageInset, top: 16 })
      if (this.errorText.length > 0) {
        Row({ space: 8 }) {
          Text(this.errorText).fontSize(this.palette.metaSize).fontColor(this.palette.danger).layoutWeight(1)
            .wordBreak(WordBreak.BREAK_WORD)
          Button('刷新').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize).fontColor(this.palette.danger)
            .backgroundColor(Color.Transparent).enabled(!this.loading).onClick(() => this.reload(true))
        }.width('100%').padding({ left: this.palette.pageInset, right: this.palette.pageInset })
      }
      if (this.loading) {
        Row({ space: 8 }) {
          LoadingProgress().width(18).height(18).color(this.palette.accent)
          Text('正在更新计划…').fontSize(this.palette.metaSize).fontColor(this.palette.quiet)
        }.width('100%').padding({ left: this.palette.pageInset, right: this.palette.pageInset })
      }
      if (this.mutationBusy) {
        Text('正在保存任务更改…').fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
          .padding({ left: this.palette.pageInset, right: this.palette.pageInset })
      }
      if (this.recoveredDraft !== null) {
        Column({ space: 8 }) {
          Text('有一份未提交的待办草稿').fontSize(this.palette.bodySize).fontColor(this.palette.ink).width('100%')
          Text('恢复只填回输入；原日期保留，核对后再保存。').fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
          Row({ space: 8 }) {
            Button('恢复草稿').layoutWeight(1).constraintSize({ minHeight: 44 }).fontSize(this.palette.bodySize)
              .fontColor(this.palette.onAccent).backgroundColor(this.palette.accent).borderRadius(this.palette.controlRadius)
              .onClick(() => this.restoreTaskDraft())
            Button('丢弃这份草稿').layoutWeight(1).constraintSize({ minHeight: 44 }).fontSize(this.palette.bodySize)
              .fontColor(this.palette.danger).backgroundColor(this.palette.dangerSoft).borderRadius(this.palette.controlRadius)
              .enabled(!this.draftStorageBusy).onClick(() => this.discardTaskDraft())
          }.width('100%')
        }.width('100%').padding(this.palette.pageInset).backgroundColor(this.palette.accentSoft)
      }
      ForEach(this.pendingProposals, (operation: DraftOperation) => {
        FeedbackPanel({ kind: 'warning', title: '上次提交结果待核对',
          message: '保留了原提案编号。先查询服务器结果，避免重复安排。', actionLabel: '查询原提案',
          busy: this.draftStorageBusy || ['checking', 'confirming', 'cancelling'].includes(this.actionState.phase),
          onAction: () => this.recoverProposal(operation) })
      }, (operation: DraftOperation) => operation.id)
      if (this.actionState.phase !== 'idle' && this.detailKind !== 'action') {
        Button(this.actionBlocksWrites() ? '查看待处理变更 / 核对结果' : '查看上次变更结果').width('100%').constraintSize({ minHeight: 48 })
          .fontSize(this.palette.bodySize).fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft)
          .borderRadius(this.palette.controlRadius).onClick(() => this.openDetails('action'))
          .padding({ left: this.palette.pageInset, right: this.palette.pageInset })
      }
      PlanningConflictsPanel({ baseUrl: this.baseUrl, token: this.token,
        statusLockedTaskIds: this.statusLockedTaskIds, onOpenStatus: (id: string) => this.onOpenStatus(id),
        refreshKey: this.conflictRefresh, active: this.active && (this.detailKind.length === 0 || this.detailKind === 'conflicts'),
        compact: this.detailKind !== 'conflicts', onOpenDetails: () => this.openDetails('conflicts'),
        onOpenTask: (id: string) => this.openDetails('task', id),
        writeBlocked: this.mutationBusy || this.draftStorageBusy || this.pendingProposals.length > 0 || this.actionBlocksWrites(),
        onWriteStateChanged: (blocked: boolean) => this.replanWriteBlocked = blocked,
        onApplied: () => this.replanApplied() })
        .visibility(this.detailKind.length === 0 || this.detailKind === 'conflicts' ? Visibility.Visible : Visibility.None)
        .layoutWeight(this.detailKind === 'conflicts' ? 1 : 0)
        .padding({ left: this.palette.pageInset, right: this.palette.pageInset })
      if (this.detailKind.length === 0) {
        Column() {
          Row({ space: 2 }) {
            this.ViewTab('日程', 'schedule')
            this.ViewTab('目标计划', 'plans')
            this.ViewTab('全部待办', 'tasks')
          }.width('100%').padding(3).backgroundColor(this.palette.line).borderRadius(12)
        }.width('100%').padding({ left: this.palette.pageInset, right: this.palette.pageInset, bottom: 0 })
      }
      Stack({ alignContent: Alignment.TopStart }) {
        // Keep each list and Scroller mounted: opening details or switching views does not reset scroll.
        Scroll(this.scheduleScroller) { this.ScheduleView() }.width('100%').height('100%').align(Alignment.TopStart)
          .visibility(this.detailKind.length === 0 && this.currentView === 'schedule' ? Visibility.Visible : Visibility.Hidden)
        Scroll(this.plansScroller) {
          Column() { this.ConfirmedPlans() }.width('100%')
            .padding({ left: this.palette.pageInset, right: this.palette.pageInset, top: 12, bottom: 24 })
        }.width('100%').height('100%').align(Alignment.TopStart)
          .visibility(this.detailKind.length === 0 && this.currentView === 'plans' ? Visibility.Visible : Visibility.Hidden)
        Scroll(this.tasksScroller) {
          Column() { this.AllTasks() }.width('100%')
            .padding({ left: this.palette.pageInset, right: this.palette.pageInset, top: 12, bottom: 24 })
        }.width('100%').height('100%').align(Alignment.TopStart)
          .visibility(this.detailKind.length === 0 && this.currentView === 'tasks' ? Visibility.Visible : Visibility.Hidden)
        // Keep earlier detail Scroll nodes mounted while following a task/plan link.
        ForEach(this.detailStack, (frame: PlanningDetailFrame) => {
          if (frame.kind !== 'conflicts') {
            Scroll() { this.DetailContent(frame) }.width('100%').height('100%').backgroundColor(this.palette.canvas).align(Alignment.TopStart)
              .visibility(frame.key === this.topDetailKey() ? Visibility.Visible : Visibility.Hidden)
          }
        }, (frame: PlanningDetailFrame) => `${frame.key}`)
      }.width('100%').layoutWeight(1).visibility(this.detailKind === 'conflicts' ? Visibility.None : Visibility.Visible)
    }.width('100%').height('100%').backgroundColor(this.palette.canvas)
      .onAreaChange((_oldArea, newArea) => { this.pageWidth = Number(newArea.width); })
  }
}
