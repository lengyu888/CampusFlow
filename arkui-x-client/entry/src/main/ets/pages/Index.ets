import { TaskCaptureIntent } from '../utils/TaskCaptureTypes';
import { CourseRouteIntent } from '../utils/CourseRouteIntent';
import { KeyboardAvoidMode } from '@ohos.arkui.UIContext';
import common from '@ohos.app.ability.common';
import { AuthResponse, UserProfile, PlanningTask, TaskStatusOperation, CourseAcknowledgement } from '../model/ApiModels';
import { CampusFlowApi } from '../services/CampusFlowApi';
import { localDrafts } from '../services/LocalDrafts';
import { DraftLease } from '../utils/DraftStore';
import { TaskStatusController, TaskStatusState } from '../utils/TaskStatusController';
import { timetableOperationId } from '../utils/TimetableMaintenance';
import { FocusController, FocusState, emptyFocusState } from '../utils/FocusController';
import { localFocus } from '../services/LocalFocus';
import { PlatformFocusClock } from '../services/PlatformFocusClock';
import { FocusPage } from './FocusPage';
import { TaskStatusPanel } from '../components/TaskStatusPanel';
import { localHistory } from '../services/LocalHistory';
import { historyScope } from '../utils/LocalHistoryStore';
import { AgentPage } from './AgentPage';
import { CampusServicesPage } from './CampusServicesPage';
import { HomePage } from './HomePage';
import { HistoryPage } from './HistoryPage';
import { LoginPage } from './LoginPage';
import { OnboardingPage } from './OnboardingPage';
import { PlanCenterPage } from './PlanCenterPage';
import { ProfilePage } from './ProfilePage';
import { RoutePage } from './RoutePage';
import { SkillsPage } from './SkillsPage';
import { AppIcon } from '../components/AppIcon';
import { AppTheme } from '../theme/AppTheme';
import { TimetablePage } from './TimetablePage';
import { CampusPage } from './CampusPage';
import { FeedbackPanel } from '../components/FeedbackPanel';
import { PlatformReminderDriver } from '../services/PlatformReminderDriver';
import { ReminderCoordinator, ReminderState } from '../utils/ReminderCoordinator';
import { AppNavigationState, createNavigation, currentRoute, selectRoot, openSecondary, backNavigation, isRootRoute, hasBack } from '../utils/AppNavigation';

interface RootCourseIntent { root: number; intent: CourseRouteIntent; }

@Entry
@Component
struct Index {
  @Watch('reminderAccountChanged') @StorageLink('apiBaseUrl') private baseUrl: string = 'http://127.0.0.1:8000';
  @Watch('reminderActivityChanged') @StorageLink('voiceForeground') private voiceForeground: boolean = true;
  @State private reminderState: ReminderState = { phase: 'disabled', message: '本机系统提醒尚未启用。', scheduled: 0, skipped: 0, limited: false, enabled: false };
  @State private reminderCleanupNotice: string = '';
  @State private reminderCleanupBusy: boolean = false;
  private reminders: ReminderCoordinator | null = null;
  private pageActive: boolean = true;
  @State private token: string = '';
  @State private cacheScope: string = '';
  @State private localHistoryCount: number = 0;
  @State private localDisplayName: string = '';
  @State private cacheNotice: string = '';
  @State private offlineHistory: boolean = false;
  @State private deletedSessionId: string = '';
  @State private deletionRevision: number = 0;
  @State private agentChatBusy: boolean = false;
  @State private historyDeleteBusy: boolean = false;
  @State private cleanupNeeded: boolean = false;
  private authRevision: number = 0;
  private authBaseUrl: string = '';
  private taskStatuses: TaskStatusController | null = null;
  @State private taskStatusState: TaskStatusState = { items: [], selectedId: '', lockedTaskIds: [], pendingCount: 0, message: '' };
  @State private taskStatusOpen: boolean = false;
  @State private pendingLogoutConfirm: boolean = false;
  @State private pendingServiceUrl: string = '';
  private focusManager: FocusController | null = null;
  @State private focusState: FocusState = emptyFocusState();
  @State private focusPageOpen: boolean = false;
  @State private focusEntryTaskId: string = '';
  @State private focusEntryTitle: string = '';
  @State private focusNotice: string = '';
  @State private focusCleanupNeeded: boolean = false;
  @State private focusCleanupBusy: boolean = false;
  @State private focusClearConfirm: boolean = false;
  @State private focusCompletingTask: boolean = false;
  private focusTaskRequestRevision: number = 0;
  @State private draftLease: DraftLease | null = null;
  @State private draftNotice: string = '';
  @State private draftCleanupNeeded: boolean = false;
  @State private draftCleanupBusy: boolean = false;
  @State private draftClearConfirm: boolean = false;
  @State private activeTab: number = 0;
  @State private quickCaptureOpen: boolean = false;
  @State private captureIntent: TaskCaptureIntent | null = null;
  @State private captureRevision: number = 0;
  @State private courseRouteIntents: RootCourseIntent[] = [];
  private courseRouteRevision: number = 0;
  @State private requestedSessionId: string = '';
  @State private sessionResumeRevision: number = 0;
  @State private agentPrompt: string = '';
  @State private promptRevision: number = 0;
  @State private homeRefresh: number = 0;
  @State private planRefresh: number = 0;
  @State private navigation: AppNavigationState = createNavigation();
  @State private focusTaskId: string = '';
  @State private focusPlanId: string = '';
  @State private focusRevision: number = 0;
  @State private planRequestedView: string = '';
  @State private planViewRevision: number = 0;
  @State private planBackRevision: number = 0;
  @State private profileBackRevision: number = 0;
  @State private profileInnerActive: boolean = false;
  @State private planInnerActive: boolean = false;
  private focusOrigin: AppNavigationState | null = null;
  @State private contentOpacity: number = 1;
  @State private contentOffset: number = 0;
  @State private user: UserProfile = {
    user_id: '', email: '', display_name: '', school: null, campus: null, semester: null,
    onboarding_complete: false, role: 'user', api_key_configured: false, api_key_hint: null
  };

  aboutToAppear(): void {
    this.pageActive = true;
    PersistentStorage.persistProp('reduceMotion', false);
    // Resize the flex layout so the composer remains above the system keyboard.
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    this.refreshLocalHistory();
    this.cacheNotice = AppStorage.get<string>('localHistoryError') ?? '';
    this.cleanupNeeded = this.cacheNotice.length > 0;
    this.draftNotice = AppStorage.get<string>('localDraftsError') ?? '';
    this.draftCleanupNeeded = this.draftNotice.length > 0;
    this.focusNotice = AppStorage.get<string>('localFocusError') ?? '';
    this.focusCleanupNeeded = this.focusNotice.length > 0;
  }

  aboutToDisappear(): void {
    this.flushDrafts();
    this.pageActive = false;
    this.authRevision++;
    this.resetTaskStatuses();
    this.resetFocus();
    this.reminders?.dispose();
    this.reminders = null;
  }

  private serviceBaseUrl(): string { return this.token.length > 0 && this.authBaseUrl.length > 0 ? this.authBaseUrl : this.baseUrl; }

  private resetFocus(): void {
    this.focusManager?.dispose(); this.focusManager = null;
    this.focusState = emptyFocusState(); this.focusPageOpen = false;
    this.focusEntryTaskId = ''; this.focusEntryTitle = ''; this.focusCompletingTask = false;
    this.focusTaskRequestRevision++; this.focusClearConfirm = false;
  }

  private async configureFocus(): Promise<void> {
    this.resetFocus();
    const revision = this.authRevision; const base = this.serviceBaseUrl(); const token = this.token;
    if (!this.pageActive || token.length === 0 || this.user.user_id.length === 0) { return; }
    const manager = new FocusController(localFocus, new PlatformFocusClock(), (state: FocusState) => {
      if (this.pageActive && this.authRevision === revision && this.focusManager === manager && this.token === token && this.serviceBaseUrl() === base) {
        this.focusState = state;
      }
    }, () => timetableOperationId());
    this.focusManager = manager;
    try {
      await manager.configure(historyScope(base, this.user.user_id), this.user.user_id, new CampusFlowApi(base, token));
      if (!this.pageActive || this.authRevision !== revision || this.focusManager !== manager) { return; }
      manager.setForeground(this.voiceForeground);
    } catch {
      if (this.pageActive && this.authRevision === revision && this.focusManager === manager) {
        this.focusCleanupNeeded = true;
        this.focusNotice = '本机专注记录尚未可靠读取，未覆盖旧文件。清除会丢失本机未同步内容。';
      }
    }
  }

  private hasLocalFocus(): boolean {
    return this.focusCleanupNeeded || this.focusState.phase === 'error' || this.focusState.localRecords.length > 0 || this.focusState.pendingOperations.length > 0;
  }

  private cancelFocusTaskRead(): void {
    this.focusTaskRequestRevision++;
    this.focusCompletingTask = false;
  }

  private closeFocus(): void {
    this.focusPageOpen = false;
    this.cancelFocusTaskRead();
  }

  private selectFocusRecord(id: string): void {
    this.cancelFocusTaskRead();
    this.focusManager?.selectRecord(id);
  }

  private openFocus(task: PlanningTask | null = null): void {
    if (!this.pageActive || this.token.length === 0) { return; }
    if (task !== null) { this.focusEntryTaskId = task.task_id; this.focusEntryTitle = task.title; }
    this.focusPageOpen = true; this.cancelFocusTaskRead();
    this.focusManager?.refreshHistory();
  }

  private async completeFocusTask(taskId: string): Promise<void> {
    if (!this.pageActive || !this.voiceForeground || this.focusCompletingTask || taskId.length === 0 || this.focusManager === null) { return; }
    const focus = this.focusManager.snapshot();
    const ended = focus.local?.localState === 'ended' && focus.local.taskId === taskId ||
      focus.record?.state === 'ended' && !focus.record.task_missing && focus.record.task_id === taskId;
    if (!ended) { this.focusNotice = '请先核对已结束的专注记录，再单独标记任务完成。'; return; }
    const revision = ++this.focusTaskRequestRevision; const auth = this.authRevision;
    const base = this.serviceBaseUrl(); const token = this.token;
    this.focusCompletingTask = true; this.focusNotice = '';
    try {
      const overview = await new CampusFlowApi(base, token).planning();
      if (!this.pageActive || !this.focusPageOpen || !this.voiceForeground || this.focusTaskRequestRevision !== revision || this.authRevision !== auth || this.token !== token || this.serviceBaseUrl() !== base) { return; }
      const task = overview.tasks.find((item: PlanningTask) => item.task_id === taskId);
      if (task === undefined) { this.focusNotice = '原任务已不存在或暂不可读取；专注记录仍保留，本次没有标记完成。'; return; }
      if (this.taskStatusState.lockedTaskIds.includes(taskId)) { this.openTaskStatus(taskId); return; }
      if (task.status === 'completed') { this.focusNotice = '最新任务已经完成，不重复提交，也不会把它恢复为未完成。'; return; }
      await this.changeTaskStatus(task);
    } catch {
      if (this.authRevision === auth && this.focusTaskRequestRevision === revision) { this.focusNotice = '最新任务尚未核对成功，本次未提交完成状态；请重试。'; }
    } finally { if (this.authRevision === auth && this.focusTaskRequestRevision === revision) { this.focusCompletingTask = false; } }
  }

  private async clearLocalFocus(confirmed: boolean = false): Promise<void> {
    if (this.focusCleanupBusy) { return; }
    if (!confirmed && !this.focusClearConfirm) { this.focusClearConfirm = true; return; }
    this.focusClearConfirm = false; this.focusCleanupBusy = true;
    const revision = this.authRevision;
    this.resetFocus();
    try {
      await localFocus.clear();
      if (revision !== this.authRevision) { return; }
      this.focusCleanupNeeded = false; this.focusNotice = '本机专注记录已清除，服务端已确认的记录不受影响。';
      AppStorage.setOrCreate<string>('localFocusError', '');
      if (this.token.length > 0) { await this.configureFocus(); }
    } catch {
      if (revision === this.authRevision) { this.focusCleanupNeeded = true; this.focusNotice = '本机专注记录尚未清理成功，旧文件保留，请重试清理。'; }
    } finally { if (revision === this.authRevision) { this.focusCleanupBusy = false; } }
  }

  private async confirmAccountExit(): Promise<void> {
    const nextUrl = this.pendingServiceUrl; this.pendingServiceUrl = '';
    const revision = this.authRevision + 1;
    await this.logout();
    if (this.authRevision === revision && this.token.length === 0 && nextUrl.length > 0) { this.baseUrl = nextUrl; }
  }

  private resetTaskStatuses(): void {
    this.taskStatuses?.dispose(); this.taskStatuses = null;
    this.taskStatusState = { items: [], selectedId: '', lockedTaskIds: [], pendingCount: 0, message: '' };
    this.taskStatusOpen = false; this.pendingLogoutConfirm = false;
  }

  private configureTaskStatuses(): void {
    this.resetTaskStatuses();
    const lease = this.draftLease; const revision = this.authRevision;
    if (!this.pageActive || this.token.length === 0 || this.user.user_id.length === 0 || lease === null || !localDrafts.valid(lease)) { return; }
    this.taskStatuses = new TaskStatusController(localDrafts, (state: TaskStatusState) => {
      if (this.pageActive && revision === this.authRevision && this.draftLease === lease) { this.taskStatusState = state; }
    }, (_operation: TaskStatusOperation) => {
      // A hidden page cannot erase a verified write. Refresh current data; never overlay an old receipt on it.
      if (this.pageActive && revision === this.authRevision && this.draftLease === lease) { this.timetableChanged(); }
    }, () => timetableOperationId());
    this.taskStatuses.configure(historyScope(this.baseUrl, this.user.user_id), this.user.user_id,
      new CampusFlowApi(this.baseUrl, this.token), lease);
    this.taskStatuses.setActive(this.voiceForeground);
  }

  private async changeTaskStatus(task: PlanningTask): Promise<void> {
    if (!this.pageActive || !this.voiceForeground || this.token.length === 0) { return; }
    this.taskStatusOpen = true;
    if (this.taskStatuses === null) { this.configureTaskStatuses(); this.taskStatusOpen = true; }
    if (this.taskStatuses === null) {
      this.taskStatusState = { items: [], selectedId: '', lockedTaskIds: [], pendingCount: 0,
        message: '本机恢复记录暂不可用，本次未提交。请先在个人设置恢复草稿保存。' }; return;
    }
    await this.taskStatuses.begin(task, task.status === 'completed' ? 'restore' : 'complete');
  }

  private openTaskStatus(taskId: string = ''): void {
    if (!this.pageActive || this.token.length === 0) { return; }
    const item = this.taskStatusState.items.find((item) => item.taskId === taskId && !['applied', 'cancelled', 'error'].includes(item.phase)) ??
      this.taskStatusState.items.find((item) => item.taskId === taskId);
    if (item !== undefined) { this.taskStatuses?.select(item.operationId); }
    this.taskStatusOpen = true;
  }

  private requestLogout(): void {
    const lease = this.draftLease;
    if (this.hasLocalFocus() || lease !== null && localDrafts.valid(lease) &&
      (localDrafts.operations(lease).length > 0 || localDrafts.hasPendingTaskStatus(lease))) {
      this.pendingLogoutConfirm = true; return;
    }
    this.logout();
  }

  private reminderManager(): ReminderCoordinator {
    if (this.reminders === null) {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.reminders = new ReminderCoordinator(new PlatformReminderDriver(context), (state: ReminderState) => {
        if (this.pageActive) { this.reminderState = state; }
      });
    }
    return this.reminders;
  }

  private reminderAccountChanged(): void {
    if (this.authBaseUrl.length > 0 && this.authBaseUrl !== this.baseUrl) {
      if (this.token.length === 0) {
        // A service edit during sign-in cancels that read; no focus account has been activated yet.
        const revision = ++this.authRevision; this.authBaseUrl = ''; this.draftLease = null;
        this.resetTaskStatuses();
        localDrafts.clear().catch(() => {
          if (this.pageActive && this.authRevision === revision) { this.draftCleanupNeeded = true; this.draftNotice = '登录前的本机草稿尚未清理，请重试清理。'; }
        });
        return;
      }
      // Authenticated children keep serviceBaseUrl(), so a setting change never retargets their token.
      this.pendingServiceUrl = this.baseUrl; this.baseUrl = this.authBaseUrl;
      this.pendingLogoutConfirm = true;
      return;
    }
    if (!this.pageActive || this.token.length === 0 || this.user.user_id.length === 0) { return; }
    const token = this.token; const baseUrl = this.baseUrl; const revision = this.authRevision;
    const manager = this.reminderManager();
    manager.setActive(this.voiceForeground);
    manager.configure(historyScope(baseUrl, this.user.user_id), async () => {
      const overview = await new CampusFlowApi(baseUrl, token).planning();
      if (!this.pageActive || revision !== this.authRevision || this.token !== token || this.baseUrl !== baseUrl) {
        throw new Error('REMINDER_ACCOUNT_CHANGED');
      }
      return overview;
    });
  }

  private reminderActivityChanged(): void {
    this.reminders?.setActive(this.voiceForeground);
    this.taskStatuses?.setActive(this.voiceForeground);
    this.focusManager?.setForeground(this.voiceForeground);
    if (!this.voiceForeground) { this.cancelFocusTaskRead(); this.flushDrafts(); }
  }

  private flushDrafts(): void {
    const lease = this.draftLease;
    if (lease === null || !localDrafts.valid(lease)) { return; }
    localDrafts.flush(lease).catch(() => {
      if (this.pageActive && this.draftLease === lease) {
        this.draftNotice = '部分输入尚未保存到本机，请回到原页面重试保存。';
      }
    });
  }

  private async clearLocalDrafts(): Promise<void> {
    if (this.draftCleanupBusy) { return; }
    if (this.draftLease !== null && (localDrafts.operations(this.draftLease).length > 0 || localDrafts.hasPendingTaskStatus(this.draftLease))) {
      this.draftNotice = '还有提交结果待核对，请先在助手、计划或课表页核对，保留原操作编号。';
      this.draftClearConfirm = false;
      return;
    }
    if (!this.draftClearConfirm) { this.draftClearConfirm = true; return; }
    this.draftClearConfirm = false;
    const revision = this.authRevision;
    this.resetTaskStatuses();
    const scope = this.token.length > 0 && this.user.user_id.length > 0 ?
      historyScope(this.authBaseUrl || this.baseUrl, this.user.user_id) : '';
    this.draftLease = null;
    this.draftCleanupBusy = true;
    try {
      await localDrafts.clear();
      if (revision !== this.authRevision) { return; }
      if (scope.length > 0 && this.token.length > 0) {
        const lease = await localDrafts.activate(scope);
        if (revision !== this.authRevision) { return; }
        this.draftLease = lease; this.configureTaskStatuses();
      }
      this.draftCleanupNeeded = false;
      this.draftNotice = '本机未提交草稿已清除，已保存到账号的安排不受影响。';
      AppStorage.setOrCreate<string>('localDraftsError', '');
    } catch {
      if (revision === this.authRevision) {
        this.draftCleanupNeeded = true;
        this.draftNotice = '本机草稿清理失败，旧内容未重新开放。请重试清理。';
      }
    } finally { if (revision === this.authRevision) { this.draftCleanupBusy = false; } }
  }

  private async enableReminders(): Promise<void> {
    if (!this.pageActive || this.token.length === 0) { return; }
    await this.reminderManager().enable();
  }

  private async disableReminders(): Promise<void> {
    if (!this.pageActive || this.reminderCleanupBusy) { return; }
    this.reminderCleanupBusy = true;
    try {
      await this.reminderManager().disable();
      if (this.pageActive) { this.reminderCleanupNotice = ''; }
    } catch {
      if (this.pageActive) { this.reminderCleanupNotice = '系统提醒尚未确认清理，旧提醒可能仍出现。请重试关闭或在系统设置中关闭通知。'; }
    } finally { if (this.pageActive) { this.reminderCleanupBusy = false; } }
  }

  onBackPress(): boolean {
    if (this.taskStatusOpen) { this.taskStatusOpen = false; return true; }
    if (this.focusPageOpen) { this.closeFocus(); return true; }
    if (this.pendingLogoutConfirm) { this.pendingLogoutConfirm = false; this.pendingServiceUrl = ''; return true; }
    if (this.quickCaptureOpen) { this.planBackRevision++; return true; }
    if (this.offlineHistory) {
      this.offlineHistory = false;
      this.refreshLocalHistory();
      return true;
    }
    if (this.activeTab === 2 && this.planInnerActive) {
      this.planBackRevision++;
      return true;
    }
    if (hasBack(this.navigation)) {
      this.goBack();
      return true;
    }
    return false;
  }

  private refreshLocalHistory(): void {
    const info = localHistory.info();
    this.cacheScope = info.scope;
    this.localDisplayName = info.displayName;
    this.localHistoryCount = info.count;
  }

  private async authenticated(auth: AuthResponse): Promise<void> {
    const revision = ++this.authRevision;
    this.resetTaskStatuses();
    this.resetFocus();
    this.offlineHistory = false;
    this.cacheNotice = '';
    this.authBaseUrl = this.baseUrl;
    this.draftLease = null;
    this.draftCleanupBusy = false;
    this.draftClearConfirm = false;
    // Invalidate the previous account synchronously; history failures do not disable drafts.
    const draftsReady = localDrafts.activate(historyScope(this.baseUrl, auth.user.user_id))
      .then((lease: DraftLease) => {
        if (revision === this.authRevision) { this.draftLease = lease; this.draftNotice = ''; this.draftCleanupNeeded = false; }
      }).catch(() => {
        if (revision === this.authRevision) {
          this.draftCleanupNeeded = true;
          this.draftNotice = '本机草稿暂不可用，已有文件未覆盖。联网查看仍可使用。';
        }
      });
    try {
      await localHistory.activate(historyScope(this.baseUrl, auth.user.user_id), auth.user.display_name);
      if (revision !== this.authRevision) { return; }
      this.refreshLocalHistory();
    } catch {
      if (revision !== this.authRevision) { return; }
      this.cacheScope = '';
      this.localHistoryCount = 0;
      this.cacheNotice = '本机保存暂不可用，当前可联网使用；新的对话尚不能离线回看。';
    }
    await draftsReady;
    if (revision !== this.authRevision) { return; }
    this.user = auth.user;
    this.resetNavigation();
    this.agentPrompt = '';
    this.token = auth.access_token;
    this.agentChatBusy = false;
    this.historyDeleteBusy = false;
    this.reminderAccountChanged();
    this.configureTaskStatuses();
    this.configureFocus();
  }

  private async clearLocalHistory(): Promise<void> {
    try {
      await localHistory.clear();
      this.refreshLocalHistory();
      this.cleanupNeeded = false;
      this.cacheNotice = '本机保存的对话已清除。';
      AppStorage.setOrCreate<string>('localHistoryError', '');
    } catch {
      this.cleanupNeeded = true;
      this.cacheNotice = '本机对话清理失败，请重试。';
    }
  }

  private async logout(): Promise<void> {
    const revision = ++this.authRevision;
    this.resetTaskStatuses();
    this.resetFocus();
    const api = new CampusFlowApi(this.authBaseUrl || this.baseUrl, this.token);
    this.authBaseUrl = '';
    this.draftLease = null;
    this.draftClearConfirm = false;
    this.draftCleanupBusy = false;
    const focusResult = localFocus.clear().then(() => {
      if (revision === this.authRevision) { this.focusCleanupNeeded = false; this.focusNotice = '退出后本机专注记录已清除。'; }
    }).catch(() => {
      if (revision === this.authRevision) { this.focusCleanupNeeded = true; this.focusNotice = '已退出，但本机专注记录尚未清理。未同步内容仍在旧文件，请重试清理后再使用。'; }
    });
    const draftResult = localDrafts.clear().then(() => {
      if (revision === this.authRevision) { this.draftNotice = '退出后本机草稿已清除。'; this.draftCleanupNeeded = false; }
    }).catch(() => {
      if (revision === this.authRevision) { this.draftNotice = '已退出，但本机草稿尚未清理，请重试。'; this.draftCleanupNeeded = true; }
    });
    this.token = '';
    this.cacheScope = '';
    this.localHistoryCount = 0;
    this.offlineHistory = false;
    this.resetNavigation();
    this.agentPrompt = '';
    this.agentChatBusy = false;
    this.historyDeleteBusy = false;
    // Invalidate reminder writes immediately; failed OS cleanup must never restore sign-in.
    const reminderCleanup = this.reminders === null ? Promise.resolve() : this.reminders.logout();
    const reminderResult = reminderCleanup.then(() => {
      if (this.pageActive && revision === this.authRevision) { this.reminderCleanupNotice = ''; }
    }).catch(() => {
      if (this.pageActive && revision === this.authRevision) {
        this.reminderCleanupNotice = '已退出，但系统提醒尚未确认清理，旧提醒可能仍出现。请重试关闭。';
      }
    });
    try {
      await localHistory.clear();
      if (revision === this.authRevision) {
        this.cleanupNeeded = false;
        this.cacheNotice = '已退出，并清除本机保存的对话。';
      }
    } catch {
      if (revision === this.authRevision) {
        this.cleanupNeeded = true;
        this.cacheNotice = '已退出，但本机对话清理失败。请重试清理本机记录。';
      }
    }
    try {
      await api.logout();
    } catch {
      // Never restore a local sign-in when remote token revocation fails.
    }
    await reminderResult;
    await draftResult;
    await focusResult;
  }

  private resetNavigation(): void {
    this.requestedSessionId = ''; this.sessionResumeRevision++;
    this.quickCaptureOpen = false; this.captureIntent = null; this.courseRouteIntents = [];
    this.navigation = createNavigation();
    this.activeTab = 0;
    this.focusTaskId = '';
    this.focusPlanId = '';
    this.focusRevision++;
    this.focusOrigin = null;
    this.planRequestedView = '';
    this.planViewRevision++;
    this.planInnerActive = false; this.profileInnerActive = false;
  }

  private applyNavigation(next: AppNavigationState): void {
    const previous = this.activeTab;
    this.navigation = next;
    this.activeTab = currentRoute(next);
    if (this.activeTab === previous) { return; }
    if (this.activeTab === 0) { this.homeRefresh++; }
    else if (this.activeTab === 2) { this.planRefresh++; }
    const duration = AppTheme.motion(180);
    this.contentOpacity = duration === 0 ? 1 : 0.65;
    this.contentOffset = duration === 0 ? 0 : 4;
    this.getUIContext().animateTo({ duration: duration, curve: Curve.EaseOut }, () => {
      this.contentOpacity = 1;
      this.contentOffset = 0;
    });
  }

  private openCapture(intent: TaskCaptureIntent): void {
    if (this.token.length === 0 || this.activeTab !== 0 || this.quickCaptureOpen) { return; }
    this.captureRevision++;
    const frozen = JSON.parse(JSON.stringify(intent)) as TaskCaptureIntent;
    frozen.requestRevision = this.captureRevision;
    this.captureIntent = frozen;
    this.quickCaptureOpen = true;
  }

  private closeCapture(): void {
    this.quickCaptureOpen = false;
    this.homeRefresh++;
  }

  private openCourseRoute(intent: CourseRouteIntent): void {
    if (this.token.length === 0) { return; }
    const frozen = JSON.parse(JSON.stringify(intent)) as CourseRouteIntent;
    frozen.requestId = ++this.courseRouteRevision;
    this.courseRouteIntents = this.courseRouteIntents.filter((item: RootCourseIntent) => item.root !== this.navigation.root)
      .concat([{ root: this.navigation.root, intent: frozen }]);
    this.applyNavigation(openSecondary(this.navigation, 6));
  }

  private currentCourseRoute(): CourseRouteIntent | null {
    return this.courseRouteIntents.find((item: RootCourseIntent) => item.root === this.navigation.root)?.intent ?? null;
  }

  private selectTab(tab: number): void {
    if (tab === 6) { this.courseRouteIntents = this.courseRouteIntents.filter((item: RootCourseIntent) => item.root !== this.navigation.root); }
    this.applyNavigation(isRootRoute(tab) ? selectRoot(this.navigation, tab) : openSecondary(this.navigation, tab));
  }

  private goBack(): void {
    if (this.activeTab === 4 && this.profileInnerActive) { this.profileBackRevision++; return; }
    this.applyNavigation(backNavigation(this.navigation));
  }

  private continueAgentSession(sessionId: string): void {
    if (sessionId.length === 0 || this.token.length === 0 || this.historyDeleteBusy) { return; }
    this.requestedSessionId = sessionId;
    this.sessionResumeRevision++;
    this.applyNavigation(selectRoot(this.navigation, 1, true));
  }

  private openAgentWithPrompt(prompt: string): void {
    this.agentPrompt = prompt;
    this.promptRevision++;
    this.applyNavigation(selectRoot(this.navigation, 1, true));
  }

  private openPlanList(view: string = 'goals'): void {
    this.planRequestedView = view;
    this.planViewRevision++;
    this.focusTaskId = '';
    this.focusPlanId = '';
    this.focusOrigin = null;
    this.focusRevision++;
    this.applyNavigation(selectRoot(this.navigation, 2, true));
  }

  private openPlanDetails(taskId: string, planId: string): void {
    if ((taskId.length === 0) === (planId.length === 0)) { return; }
    this.focusOrigin = this.navigation;
    this.focusTaskId = taskId;
    this.focusPlanId = planId;
    this.focusRevision++;
    this.applyNavigation(selectRoot(this.navigation, 2, true));
  }

  private closePlanFocus(): void {
    const origin = this.focusOrigin;
    this.focusTaskId = '';
    this.focusPlanId = '';
    this.focusOrigin = null;
    this.focusRevision++;
    if (origin !== null) { this.applyNavigation(origin); }
  }

  private timetableChanged(): void {
    this.homeRefresh++;
    this.planRefresh++;
    this.reminders?.refresh();
  }

  private sessionDeleted(id: string, revision: number): void {
    if (revision === this.authRevision && this.token.length > 0) {
      this.deletedSessionId = id;
      this.deletionRevision++;
    }
  }

  private deletionBusyChanged(busy: boolean, revision: number): void {
    if (revision === this.authRevision && this.token.length > 0) {
      this.historyDeleteBusy = busy;
    }
  }

  @Builder
  private pageContent() {
    Stack({ alignContent: Alignment.TopStart }) {
      HomePage({ onOpenFocus: (task: PlanningTask) => this.openFocus(task), onOpenFocusRecords: () => this.openFocus(), statusLockedTaskIds: this.taskStatusState.lockedTaskIds,
        onTaskStatus: (task: PlanningTask) => this.changeTaskStatus(task), onOpenStatus: (id: string) => this.openTaskStatus(id), baseUrl: this.serviceBaseUrl(), token: this.token, user: this.user,
        refreshKey: this.homeRefresh, active: this.activeTab === 0 && !this.quickCaptureOpen && !this.focusPageOpen && !this.taskStatusOpen && this.voiceForeground,
        onOpenCapture: (intent: TaskCaptureIntent) => this.openCapture(intent),
        onOpenCourseRoute: (intent: CourseRouteIntent) => this.openCourseRoute(intent),
        onOpenAgent: () => this.applyNavigation(selectRoot(this.navigation, 1, true)),
        onOpenPlan: (view) => this.openPlanList(view),
        onOpenTaskDetails: (id) => this.openPlanDetails(id, ''),
        onOpenPlanDetails: (id) => this.openPlanDetails('', id),
        onPlanningChanged: () => this.timetableChanged(),
        onOpenRoute: () => this.selectTab(6),
        onOpenServices: () => this.selectTab(7), onOpenProfile: () => this.selectTab(4) })
        .visibility(this.activeTab === 0 && !this.quickCaptureOpen ? Visibility.Visible : Visibility.Hidden)
      AgentPage({ statusLockedTaskIds: this.taskStatusState.lockedTaskIds, onOpenStatus: (id: string) => this.openTaskStatus(id), baseUrl: this.serviceBaseUrl(), token: this.token, userId: this.user.user_id,
        requestedSessionId: this.requestedSessionId, resumeRevision: this.sessionResumeRevision, draftLease: this.draftLease, initialPrompt: this.agentPrompt,
        voiceActive: this.activeTab === 1 && !this.focusPageOpen && !this.taskStatusOpen && this.voiceForeground,
        historyScope: this.cacheScope, deletedSessionId: this.deletedSessionId,
        deletionRevision: this.deletionRevision,
        deletionBusy: this.historyDeleteBusy,
        onChatBusyChange: (busy) => this.agentChatBusy = busy,
        onPlanningChanged: () => this.timetableChanged(),
        promptRevision: this.promptRevision,
        onOpenHistory: () => this.selectTab(5), onOpenRoute: () => this.selectTab(6),
        onOpenPlan: () => this.openPlanList(),
        onOpenTaskDetails: (id) => this.openPlanDetails(id, ''),
        onOpenPlanDetails: (id) => this.openPlanDetails('', id), onOpenProfile: () => this.selectTab(4) })
        .visibility(this.activeTab === 1 ? Visibility.Visible : Visibility.Hidden)
      PlanCenterPage({ onOpenFocus: (task: PlanningTask) => this.openFocus(task), statusLockedTaskIds: this.taskStatusState.lockedTaskIds,
        onTaskStatus: (task: PlanningTask) => this.changeTaskStatus(task), onOpenStatus: (id: string) => this.openTaskStatus(id), baseUrl: this.serviceBaseUrl(), token: this.token, draftLease: this.draftLease,
        refreshKey: this.planRefresh, active: (this.activeTab === 2 || this.quickCaptureOpen) && !this.focusPageOpen && !this.taskStatusOpen && this.voiceForeground,
        captureOnly: this.quickCaptureOpen, captureIntent: this.captureIntent, captureRevision: this.captureRevision,
        onCloseCapture: () => this.closeCapture(),
        focusTaskId: this.focusTaskId, focusPlanId: this.focusPlanId, focusRevision: this.focusRevision,
        requestedView: this.planRequestedView, viewRevision: this.planViewRevision,
        backRevision: this.planBackRevision, onInnerNavigationChanged: (active) => this.planInnerActive = active,
        onCloseFocus: () => this.closePlanFocus(),
        onPlanningChanged: () => this.timetableChanged(),
        onOpenTimetable: () => this.selectTab(9),
        onOpenAgent: (prompt) => this.openAgentWithPrompt(prompt) })
        .visibility(this.activeTab === 2 || this.quickCaptureOpen ? Visibility.Visible : Visibility.Hidden)
      CampusPage({ user: this.user, baseUrl: this.serviceBaseUrl(), token: this.token, active: this.activeTab === 8 && this.voiceForeground,
        onOpenTimetable: () => this.selectTab(9), onOpenRoute: () => this.selectTab(6),
        onOpenServices: () => this.selectTab(7), onOpenSkills: () => this.selectTab(3),
        onOpenProfile: () => this.selectTab(4), onOpenAgent: (prompt) => this.openAgentWithPrompt(prompt) })
        .visibility(this.activeTab === 8 ? Visibility.Visible : Visibility.Hidden)
      Column() {
        this.SecondaryHeader('能力管理')
        Column() { SkillsPage({ baseUrl: this.serviceBaseUrl(), token: this.token, active: this.activeTab === 3 && this.voiceForeground }) }.layoutWeight(1).width('100%')
      }.width('100%').height('100%').visibility(this.activeTab === 3 ? Visibility.Visible : Visibility.Hidden)
      Column() {
        this.SecondaryHeader('个人设置')
        Column() {
          ProfilePage({ baseUrl: this.serviceBaseUrl(), token: this.token, user: this.user,
            backRevision: this.profileBackRevision, onInnerNavigationChanged: (active) => this.profileInnerActive = active,
            onOpenHistory: () => this.selectTab(5),
            draftNotice: this.draftNotice, draftClearConfirm: this.draftClearConfirm,
            draftCleanupBusy: this.draftCleanupBusy, onClearDrafts: () => this.clearLocalDrafts(),
            onCancelClearDrafts: () => this.draftClearConfirm = false,
            reminderState: this.reminderState, reminderCleanupBusy: this.reminderCleanupBusy,
            onEnableReminders: () => this.enableReminders(), onDisableReminders: () => this.disableReminders(),
            onRefreshReminders: () => this.reminderAccountChanged(),
            active: this.activeTab === 4 && this.voiceForeground, onOpenTimetable: () => this.selectTab(9),
            onUserChanged: (updated) => this.user = updated, onLogout: () => this.requestLogout(),
            onTimetableChanged: () => this.timetableChanged(), onOpenPlan: () => this.openPlanList(),
            onOpenAgent: (prompt) => this.openAgentWithPrompt(prompt) })
        }.layoutWeight(1).width('100%')
      }.width('100%').height('100%').visibility(this.activeTab === 4 ? Visibility.Visible : Visibility.Hidden)
      if (this.activeTab === 5) {
        HistoryPage({ baseUrl: this.serviceBaseUrl(), token: this.token, historyScope: this.cacheScope,
          chatBusy: this.agentChatBusy,
          remoteDeleteBusy: this.historyDeleteBusy,
          accountRevision: this.authRevision,
          onContinueSession: (id: string) => this.continueAgentSession(id),
          onSessionDeleted: (id, revision) => this.sessionDeleted(id, revision),
          onDeleteBusyChange: (busy, revision) => this.deletionBusyChanged(busy, revision),
          onBack: () => this.goBack() })
      }
      RoutePage({ baseUrl: this.serviceBaseUrl(), token: this.token,
        routeScope: this.token.length > 0 ? historyScope(this.baseUrl, this.user.user_id) : '',
        routeContextKey: `${this.navigation.root}`, courseIntent: this.currentCourseRoute(), active: this.activeTab === 6 && this.voiceForeground,
        onBack: () => this.goBack() })
        .visibility(this.activeTab === 6 ? Visibility.Visible : Visibility.Hidden)
      CampusServicesPage({ baseUrl: this.serviceBaseUrl(), token: this.token, active: this.activeTab === 7 && this.voiceForeground,
        onBack: () => this.goBack(), onOpenProfile: () => this.selectTab(4),
        onOpenAgent: (prompt) => this.openAgentWithPrompt(prompt) })
        .visibility(this.activeTab === 7 ? Visibility.Visible : Visibility.Hidden)
      TimetablePage({ baseUrl: this.serviceBaseUrl(), token: this.token, draftLease: this.draftLease, active: this.activeTab === 9 && !this.focusPageOpen && !this.taskStatusOpen && this.voiceForeground,
        onBack: () => this.goBack(), onTimetableChanged: () => this.timetableChanged(),
        onOpenPlan: () => this.openPlanList('agenda') })
        .visibility(this.activeTab === 9 ? Visibility.Visible : Visibility.Hidden)
      if (this.focusPageOpen) {
        FocusPage({ state: this.focusState, active: this.voiceForeground && !this.taskStatusOpen,
          taskId: this.focusEntryTaskId, taskTitle: this.focusEntryTitle, notice: this.focusNotice, completingTask: this.focusCompletingTask,
          onBack: () => this.closeFocus(),
          onStart: (id: string, target: number | null, mode: 'online' | 'offline') => this.focusManager?.start(id, target, mode),
          onPause: () => this.focusManager?.pause(), onResume: () => this.focusManager?.resume(), onEnd: () => this.focusManager?.end(),
          onSync: () => this.focusManager?.sync(), onCheck: (id: string) => this.focusManager?.check(id), onRetry: (id: string) => this.focusManager?.retry(id),
          onSelect: (id: string) => this.selectFocusRecord(id),
          onRefresh: () => this.focusManager?.refreshHistory(), onLoadMore: () => this.focusManager?.loadMoreHistory(),
          onRemoteEnd: (id: string, revision: number) => this.focusManager?.remoteEnd(id, revision),
          onDelete: (id: string, revision: number) => this.focusManager?.deleteRecord(id, revision),
          onClearLocal: () => this.clearLocalFocus(true), onCompleteTask: (id: string) => this.completeFocusTask(id),
          onOpenTask: (id: string) => { this.closeFocus(); this.openPlanDetails(id, ''); } })
      }
      if (this.taskStatusOpen) {
        TaskStatusPanel({ state: this.taskStatusState, active: this.voiceForeground,
          onSelect: (id: string) => this.taskStatuses?.select(id),
          onCheck: (id: string) => this.taskStatuses?.check(id), onRetry: (id: string) => this.taskStatuses?.retry(id),
          onConfirm: (id: string, acks: CourseAcknowledgement[]) => this.taskStatuses?.confirm(acks, id),
          onCancel: (id: string) => this.taskStatuses?.cancel(id), onDismiss: (id: string) => this.taskStatuses?.dismiss(id),
          onClose: () => this.taskStatusOpen = false,
          onOpenTask: (id: string) => { this.taskStatusOpen = false; this.openPlanDetails(id, ''); } })
          .width('100%').height('100%').backgroundColor(AppTheme.bg)
      }
    }.width('100%').height('100%')
  }

  @Builder
  private SecondaryHeader(title: string) {
    Row({ space: 8 }) {
      Button({ type: ButtonType.Normal }) {
        AppIcon({ name: 'back', iconSize: 22, color: AppTheme.accent })
      }.width(48).height(48).backgroundColor(Color.Transparent).borderRadius(AppTheme.controlRadius)
        .accessibilityText('返回上一页').onClick(() => this.goBack())
      Text(title).fontSize(AppTheme.sectionTitle).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink)
        .layoutWeight(1).wordBreak(WordBreak.BREAK_WORD)
    }.width('100%').padding({ left: 8, right: 20, top: 4, bottom: 4 }).backgroundColor(AppTheme.surface)
      .border({ width: { bottom: 1 }, color: AppTheme.line })
  }

  @Builder
  private navItem(tab: number, icon: string, label: string) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 4 }) {
        AppIcon({ name: icon, iconSize: 23,
          color: this.selectedTab() === tab ? AppTheme.accent : AppTheme.secondary })
        Text(label).fontSize(AppTheme.metaSize).fontWeight(this.selectedTab() === tab ? FontWeight.Medium : FontWeight.Regular)
          .fontColor(this.selectedTab() === tab ? AppTheme.accent : AppTheme.secondary)
      }.constraintSize({ minHeight: 48 }).justifyContent(FlexAlign.Center)
    }.layoutWeight(1).constraintSize({ minHeight: 56 }).padding({ top: 4, bottom: 4 })
      .backgroundColor(this.selectedTab() === tab ? AppTheme.accentSoft : Color.Transparent).borderRadius(AppTheme.controlRadius)
      .accessibilityText(`${label}${this.selectedTab() === tab ? '，已选中' : ''}`)
      .onClick(() => this.selectTab(tab))
  }

  private selectedTab(): number {
    return this.navigation.root;
  }

  build() {
    if (this.token.length === 0 && this.offlineHistory) {
      HistoryPage({ baseUrl: '', token: '', historyScope: this.cacheScope, offlineOnly: true,
        onBack: () => { this.offlineHistory = false; this.refreshLocalHistory(); } })
    } else if (this.token.length === 0) {
      Column() {
      if (this.focusCleanupNeeded) {
        FeedbackPanel({ kind: 'error', title: '本机专注记录待处理', message: this.focusNotice,
          actionLabel: this.focusClearConfirm ? '确认丢弃本机未同步记录并清除' : '清除本机专注记录',
          busy: this.focusCleanupBusy, onAction: () => this.clearLocalFocus() })
        if (this.focusClearConfirm) { Button('保留记录').constraintSize({ minHeight: 48 }).onClick(() => this.focusClearConfirm = false) }
      }
      if (this.draftCleanupNeeded) {
        FeedbackPanel({ kind: 'error', title: '本机草稿待处理', message: this.draftNotice,
          actionLabel: this.draftClearConfirm ? '确认清除本机未提交草稿' : '清除本机草稿',
          busy: this.draftCleanupBusy, onAction: () => this.clearLocalDrafts() })
        if (this.draftClearConfirm) { Button('保留草稿').onClick(() => this.draftClearConfirm = false) }
      }
      if (this.reminderCleanupNotice.length > 0) {
        FeedbackPanel({ kind: 'error', title: '系统提醒待清理', message: this.reminderCleanupNotice,
          actionLabel: '重试关闭提醒', busy: this.reminderCleanupBusy, onAction: () => this.disableReminders() })
      }
      Column() {
      LoginPage({
        baseUrl: this.baseUrl,
        localHistoryCount: this.localHistoryCount, localDisplayName: this.localDisplayName,
        cacheNotice: this.cacheNotice,
        cleanupNeeded: this.cleanupNeeded, onClearLocalHistory: () => this.clearLocalHistory(),
        onOpenLocalHistory: () => this.offlineHistory = true,
        onBaseUrlChange: (value) => this.baseUrl = value,
        onAuthenticated: (auth) => this.authenticated(auth)
      })
      }.layoutWeight(1).width('100%')
      }.width('100%').height('100%')
    } else if (!this.user.onboarding_complete) {
      OnboardingPage({ baseUrl: this.serviceBaseUrl(), token: this.token, draftLease: this.draftLease,
        onCompleted: (updated) => this.user = updated, onReturnToLogin: () => this.logout() })
    } else {
      Column() {
        Column() {
          this.pageContent()
        }.layoutWeight(1).width('100%').clip(true)
          .opacity(this.contentOpacity).translate({ y: this.contentOffset })
        if (this.pendingLogoutConfirm) {
          Column({ space: 8 }) {
            Text(this.pendingServiceUrl.length > 0 ? '更换服务前，请核对本机内容' : '退出前，请核对本机内容').fontSize(AppTheme.sectionTitle).fontColor(AppTheme.warning).width('100%')
            Text('退出会清除本机未同步专注区间、草稿和恢复标识，清除后不能从本机找回。服务器已确认记录仍保留；已收到的操作仍可能生效，退出不等于取消。')
              .fontSize(AppTheme.bodySize).fontColor(AppTheme.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
            Button('保留登录，继续核对').constraintSize({ minHeight: 48 }).width('100%')
              .onClick(() => { this.pendingLogoutConfirm = false; this.pendingServiceUrl = ''; if (this.hasLocalFocus()) { this.openFocus(); } else if (this.taskStatusState.pendingCount > 0) { this.openTaskStatus(); } })
            Button('仍退出并清除本机记录').constraintSize({ minHeight: 48 }).width('100%').onClick(() => this.confirmAccountExit())
          }.padding(16).backgroundColor(AppTheme.warningSoft).width('100%')
        }
        if (!this.focusPageOpen && !this.taskStatusOpen && (this.focusState.localRecords.length > 0 || this.focusState.pendingOperations.length > 0 || this.focusState.activeRecord !== null || this.focusCleanupNeeded)) {
          Button(this.focusState.local?.localState === 'running' ? '专注正在记录 · 打开查看' : '专注记录与待同步内容 · 打开核对')
            .width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize).fontColor(AppTheme.accent)
            .backgroundColor(AppTheme.accentSoft).onClick(() => this.openFocus())
        }
        if (!this.focusPageOpen && !this.taskStatusOpen && this.taskStatusState.items.length > 0) {
          Button(this.taskStatusState.pendingCount > 0 ? `${this.taskStatusState.pendingCount} 项完成 / 恢复结果待核对` : '查看本次完成 / 恢复记录')
            .width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize).fontColor(AppTheme.accent)
            .backgroundColor(AppTheme.accentSoft).onClick(() => this.openTaskStatus())
        }
        if (!this.focusPageOpen && !this.taskStatusOpen && !this.quickCaptureOpen && isRootRoute(this.activeTab) && !(this.activeTab === 2 && this.planInnerActive)) {
          Row({ space: 4 }) {
            this.navItem(0, 'home', '今日')
            this.navItem(1, 'assistant', '助手')
            this.navItem(2, 'calendar', '计划')
            this.navItem(8, 'classroom', '校园')
          }.width('100%').constraintSize({ minHeight: 64 })
            .padding({ left: 10, right: 10, bottom: 4 }).backgroundColor(AppTheme.surface)
            .border({ width: { top: 1 }, color: AppTheme.line })
        }
      }.width('100%').height('100%').backgroundColor(AppTheme.bg)
    }
  }
}
