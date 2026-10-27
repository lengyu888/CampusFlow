import {
  AdminUserSummary,
  HDUHelpConnectionStatus,
  HDUHelpDataResponse,
  HDUHelpDisplayItem,
  HDUHelpDisplaySection,
  HDUHelpSuggestedPrompt,
  ScheduleSubscriptionStatus,
  UserProfile
} from '../model/ApiModels';
import { CampusFlowApi } from '../services/CampusFlowApi';
import { AppTheme } from '../theme/AppTheme';
import { AppThemeId, ThemePalette, themePalette, selectAppTheme } from '../theme/ThemePalette';
import { AppIcon } from '../components/AppIcon';
import { FeedbackPanel } from '../components/FeedbackPanel';
import { CampusFlowRequestError } from '../utils/AgentFeedback';
import { LearningPreferencesPanel } from '../components/LearningPreferencesPanel';
import { ReminderState } from '../utils/ReminderCoordinator';
import { InfoDisclosure } from '../components/InfoDisclosure';

@Component
export struct ProfilePage {
  @StorageLink('campusflowThemePalette') private palette: ThemePalette = themePalette('paper-green');
  @StorageLink('reduceMotion') private reduceMotion: boolean = false;
  @Prop baseUrl: string;
  @Prop token: string;
  @Prop user: UserProfile;
  @Prop @Watch('activeChanged') active: boolean = true;
  onUserChanged: (user: UserProfile) => void = () => {};
  onLogout: () => void = () => {};
  onOpenAgent: (prompt: string) => void = () => {};
  onTimetableChanged: () => void = () => {};
  onOpenPlan: () => void = () => {};
  onOpenTimetable: () => void = () => {};
  onOpenHistory: () => void = () => {};
  onOpenGuide: () => void = () => {};
  onInnerNavigationChanged: (active: boolean) => void = () => {};
  @Watch('backRequested') @Prop backRevision: number = 0;
  @Prop reminderState: ReminderState = { phase: 'disabled', message: '本机系统提醒尚未启用。', scheduled: 0, skipped: 0, limited: false, enabled: false };
  @Prop reminderCleanupBusy: boolean = false;
  onEnableReminders: () => void = () => {};
  onDisableReminders: () => void = () => {};
  onRefreshReminders: () => void = () => {};
  @Prop draftNotice: string = '';
  @Prop draftClearConfirm: boolean = false;
  @Prop draftCleanupBusy: boolean = false;
  onClearDrafts: () => void = () => {};
  onCancelClearDrafts: () => void = () => {};
  @State private displayName: string = '';
  @State private school: string = '';
  @State private campus: string = '';
  @State private semester: string = '';
  @State private newApiKey: string = '';
  @State private scheduleUrl: string = '';
  @State private subscription: ScheduleSubscriptionStatus = {
    configured: false, provider: null, source_host: null, event_count: 0, last_synced_at: null
  };
  @State private message: string = '';
  @State private section: string = '';
  private connectionsReturnSection: string = '';
  private adminReturnSection: string = 'data';
  private pageScroller: Scroller = new Scroller();
  @State private profileMessage: string = '';
  @State private modelMessage: string = '';
  @State private profileError: boolean = false;
  @State private modelError: boolean = false;
  @State private settingsBusy: boolean = false;
  @State private settingsNeedsCheck: boolean = false;
  @State private hduHelpBusy: boolean = false;
  @State private hduHelpLoaded: boolean = false;
  @State private subscriptionLoaded: boolean = false;
  @State private subscriptionLoading: boolean = false;
  @State private subscriptionError: boolean = false;
  @State private adminMessage: string = '';
  @State private adminLoading: boolean = false;
  @State private confirmDisconnect: boolean = false;
  private initialized: boolean = false;
  private pageRevision: number = 0;
  private hduReadRevision: number = 0;
  private dataRevision: number = 0;
  private savedProfile: UserProfile | null = null;
  private hduMutationPending: boolean = false;
  private subscriptionWritePending: boolean = false;
  @State private timetableUpdated: boolean = false;
  @State private subscriptionBusy: boolean = false;
  @State private subscriptionNeedsCheck: boolean = false;
  private pageActive: boolean = true;
  private subscriptionRevision: number = 0;
  @State private adminUsers: AdminUserSummary[] = [];
  @State private hduHelp: HDUHelpConnectionStatus = {
    configured: false,
    provider: null,
    auth_mode: null,
    token_hint: null,
    scopes: [],
    external_name: null,
    identity_type: null,
    expires_at: null,
    connected_at: null,
    last_synced_at: null,
    last_error: null,
    resources: []
  };
  @State private hduHelpAuthorizeUrl: string = '';
  @State private hduHelpPat: string = '';
  @State private hduHelpMessage: string = '';
  @State private hduHelpMessageIsError: boolean = false;
  @State private showHduHelpData: boolean = false;
  @State private hduHelpDataLoading: boolean = false;
  @State private hduHelpSections: HDUHelpDisplaySection[] = [];
  @State private hduHelpPrompts: HDUHelpSuggestedPrompt[] = [];
  @State private hduHelpSyncErrors: string[] = [];
  @State private hduHelpDataError: string = '';

  aboutToAppear(): void {
    this.pageActive = true;
    if (!this.initialized) {
      this.displayName = this.user.display_name;
      this.school = this.user.school ?? '';
      this.campus = this.user.campus ?? '';
      this.semester = this.user.semester ?? '';
      this.initialized = true;
    }
    if (this.active) { this.loadStatuses(); }
  }
  aboutToDisappear(): void { this.pageActive = false; this.invalidate(); }
  private activeChanged(): void {
    this.invalidate();
    if (this.active && this.pageActive) { this.loadStatuses(); }
  }
  private invalidate(): void {
    this.pageRevision++;
    this.subscriptionRevision++;
    this.hduReadRevision++;
    this.dataRevision++;
    if (this.settingsBusy) { this.settingsNeedsCheck = true; }
    if (!this.hduMutationPending) { this.hduHelpBusy = false; }
    if (!this.subscriptionWritePending) { this.subscriptionBusy = false; }
    this.subscriptionLoading = false;
    this.hduHelpDataLoading = false;
    this.adminLoading = false;
  }
  private current(revision: number): boolean { return this.pageActive && this.active && revision === this.pageRevision; }
  private loadStatuses(): void {
    this.loadSubscription();
    this.loadHduHelp();
    if (this.user.role === 'admin') { this.loadAdminUsers(); }
  }
  private toggleGroup(group: string): void {
    const next = group === 'preferences' ? 'data' : group;
    if (!['account', 'learning', 'appearance', 'model', 'reminders', 'connections', 'data', 'admin'].includes(next) ||
      next === 'admin' && this.user.role !== 'admin') { return; }
    if (next === 'connections' && this.section !== 'connections') {
      this.connectionsReturnSection = this.section === 'account' ? 'account' : '';
    }
    if (next === 'admin' && this.section !== 'admin') {
      this.adminReturnSection = this.section === 'data' ? 'data' : '';
    }
    this.section = this.section === next ? '' : next;
    this.onInnerNavigationChanged(this.section.length > 0 || this.showHduHelpData);
    this.pageScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: false });
  }
  private backRequested(): void { if (this.active && this.pageActive) { this.sectionBack(); } }
  private sectionBack(): void {
    if (this.showHduHelpData) { this.closeHduHelpData(); return; }
    this.section = this.section === 'connections' ? this.connectionsReturnSection :
      this.section === 'admin' ? this.adminReturnSection : '';
    this.onInnerNavigationChanged(this.section.length > 0);
    this.pageScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: false });
  }
  private closeHduHelpData(): void {
    this.dataRevision++; this.hduHelpDataLoading = false; this.showHduHelpData = false;
    this.onInnerNavigationChanged(this.section.length > 0);
  }
  private sectionTitle(): string {
    if (this.section === 'account') { return '账号与校园'; }
    if (this.section === 'learning') { return '学习偏好'; }
    if (this.section === 'appearance') { return '外观与动效'; }
    if (this.section === 'model') { return '模型连接'; }
    if (this.section === 'reminders') { return '语音与提醒'; }
    if (this.section === 'connections') { return '校园数据连接'; }
    if (this.section === 'admin') { return '用户管理'; }
    return '历史与数据';
  }
  private accountDirty(): boolean {
    const saved = this.savedProfile ?? this.user;
    return this.displayName !== saved.display_name || this.school !== (saved.school ?? '') ||
      this.campus !== (saved.campus ?? '') || this.semester !== (saved.semester ?? '');
  }
  private sectionVisible(group: string): boolean {
    return this.section.length === 0 && !['connections', 'admin'].includes(group) ||
      this.section === 'account' && group === 'connections' || this.section === 'data' && group === 'admin';
  }
  private reminderBusy(): boolean {
    return this.reminderCleanupBusy || ['checking', 'requesting', 'clearing'].includes(this.reminderState.phase);
  }
  private safeFailure(error: Error, action: string): string {
    if (error instanceof CampusFlowRequestError && (error.statusCode === 401 || error.statusCode === 403)) {
      return '登录或权限已失效，请重新登录后核对状态。';
    }
    return `${action}未完成，请检查网络后刷新核对。输入内容已保留。`;
  }

  private async loadAdminUsers(): Promise<void> {
    if (!this.active || !this.pageActive || this.adminLoading) { return; }
    const revision = this.pageRevision;
    this.adminLoading = true;
    this.adminMessage = '';
    try {
      const users = await new CampusFlowApi(this.baseUrl, this.token).adminUsers();
      if (this.current(revision)) { this.adminUsers = users; }
    } catch (error) {
      if (this.current(revision)) { this.adminMessage = this.safeFailure(error, '用户列表读取'); }
    } finally { if (this.current(revision)) { this.adminLoading = false; } }
  }

  private async loadSubscription(): Promise<void> {
    if (!this.active || !this.pageActive || !this.active || this.subscriptionBusy || this.subscriptionLoading) { return; }
    const revision = ++this.subscriptionRevision;
    this.subscriptionLoading = true;
    this.message = '';
    this.subscriptionError = false;
    try {
      const status = await new CampusFlowApi(this.baseUrl, this.token).subscriptionStatus();
      if (!this.pageActive || !this.active || revision !== this.subscriptionRevision) { return; }
      this.subscription = status;
      this.subscriptionLoaded = true;
    } catch (error) {
      if (this.pageActive && this.active && revision === this.subscriptionRevision) {
        this.message = this.safeFailure(error, '订阅读取'); this.subscriptionError = true;
      }
    } finally {
      if (this.pageActive && this.active && revision === this.subscriptionRevision) { this.subscriptionLoading = false; }
    }
  }

  private async loadHduHelp(): Promise<void> {
    if (!this.active || !this.pageActive || this.hduHelpBusy) { return; }
    const revision = this.pageRevision;
    const request = ++this.hduReadRevision;
    this.hduHelpBusy = true;
    this.hduHelpMessage = '';
    this.hduHelpMessageIsError = false;
    try {
      const status = await new CampusFlowApi(this.baseUrl, this.token).hduHelpStatus();
      if (this.current(revision) && request === this.hduReadRevision) { this.hduHelp = status; this.hduHelpLoaded = true; }
    } catch (error) {
      if (this.current(revision) && request === this.hduReadRevision) {
        this.hduHelpMessage = this.safeFailure(error, '连接状态读取'); this.hduHelpMessageIsError = true;
      }
    } finally { if (this.current(revision) && request === this.hduReadRevision) { this.hduHelpBusy = false; } }
  }

  private async openHduHelpData(): Promise<void> {
    if (!this.active || !this.pageActive || this.hduHelpDataLoading) { return; }
    const revision = this.pageRevision;
    const request = ++this.dataRevision;
    this.getUIContext().animateTo({ duration: AppTheme.motion(200), curve: Curve.EaseOut }, () => {
      this.showHduHelpData = true;
      this.onInnerNavigationChanged(true);
    });
    this.hduHelpDataLoading = true;
    this.hduHelpDataError = '';
    try {
      const result: HDUHelpDataResponse = await new CampusFlowApi(this.baseUrl, this.token).hduHelpData();
      if (!this.current(revision) || request !== this.dataRevision) { return; }
      const archiveResources: string[] = ['identity', 'person', 'grades'];
      this.hduHelp = result.status;
      this.hduHelpSections = result.sections.filter((section: HDUHelpDisplaySection) =>
        archiveResources.includes(section.resource));
      this.hduHelpPrompts = result.suggested_prompts.filter((suggestion: HDUHelpSuggestedPrompt) =>
        suggestion.resource !== null && archiveResources.includes(suggestion.resource));
      this.hduHelpSyncErrors = Object.keys(result.sync_errors)
        .filter((resource: string) => archiveResources.includes(resource))
        .map((resource: string) => `${this.hduHelpResourceName(resource)}：${result.sync_errors[resource]}`);
    } catch (error) {
      if (this.current(revision) && request === this.dataRevision) { this.hduHelpDataError = this.safeFailure(error, '校园档案读取'); }
    } finally {
      if (this.current(revision) && request === this.dataRevision) { this.hduHelpDataLoading = false; }
    }
  }

  private hduHelpResourceName(resource: string): string {
    if (resource === 'library_bookings') {
      return '图书馆预约';
    }
    if (resource === 'sunrun_overview') {
      return '阳光长跑概览';
    }
    if (resource === 'sunrun_group') {
      return '阳光长跑达标要求';
    }
    if (resource === 'sunrun_detail') {
      return '阳光长跑记录';
    }
    return resource;
  }

  private async connectHduHelp(): Promise<void> {
    if (!this.active || !this.pageActive || !this.hduHelpLoaded || this.hduHelpBusy) { return; }
    const revision = this.pageRevision;
    this.hduHelpBusy = true;
    this.hduReadRevision++;
    this.dataRevision++;
    this.hduHelpDataLoading = false;
    this.hduMutationPending = true;
    try {
      const result = await new CampusFlowApi(this.baseUrl, this.token).connectHduHelp();
      if (!this.current(revision)) { return; }
      this.hduHelpAuthorizeUrl = result.authorize_url;
      this.hduHelpMessage = '授权链接已生成，请在 HDUHelp 官方页面确认后返回并检查连接。';
      this.hduHelpMessageIsError = false;
    } catch (error) {
      if (!this.current(revision)) { return; }
      this.hduHelpMessage = this.safeFailure(error, '校园连接操作');
      this.hduHelpMessageIsError = true;
    } finally { this.finishHduOperation(revision); }
  }

  private async connectHduHelpPat(): Promise<void> {
    if (!this.active || !this.pageActive || !this.hduHelpLoaded || this.hduHelpBusy) { return; }
    if (this.hduHelpPat.trim().length === 0) {
      this.hduHelpMessage = '请先填写 HDUHelp 个人访问令牌。';
      this.hduHelpMessageIsError = true;
      return;
    }
    const revision = this.pageRevision;
    this.hduHelpBusy = true;
    this.hduReadRevision++;
    this.dataRevision++;
    this.hduHelpDataLoading = false;
    this.hduMutationPending = true;
    try {
      const result = await new CampusFlowApi(this.baseUrl, this.token)
        .connectHduHelpPat(this.hduHelpPat.trim());
      if (!this.current(revision)) { return; }
      this.hduHelpPat = '';
      this.hduHelp = result.status;
      this.hduHelpLoaded = true;
      this.hduHelpMessage = `令牌已连接，已同步 ${result.synced_resources.length} 类 HDUHelp 数据。`;
      this.hduHelpMessageIsError = false;
    } catch (error) {
      if (!this.current(revision)) { return; }
      this.hduHelpMessage = this.safeFailure(error, '校园连接操作');
      this.hduHelpMessageIsError = true;
    } finally { this.finishHduOperation(revision); }
  }

  private async syncHduHelp(): Promise<void> {
    if (!this.active || !this.pageActive || !this.hduHelpLoaded || this.hduHelpBusy) { return; }
    const revision = this.pageRevision;
    this.hduHelpBusy = true;
    this.hduReadRevision++;
    this.dataRevision++;
    this.hduHelpDataLoading = false;
    this.hduMutationPending = true;
    try {
      const result = await new CampusFlowApi(this.baseUrl, this.token).syncHduHelp();
      if (!this.current(revision)) { return; }
      this.hduHelp = result.status;
      this.hduHelpLoaded = true;
      this.hduHelpMessage = `已同步 ${result.synced_resources.length} 类 HDUHelp 数据。`;
      this.hduHelpMessageIsError = false;
    } catch (error) {
      if (!this.current(revision)) { return; }
      this.hduHelpMessage = this.safeFailure(error, '校园连接操作');
      this.hduHelpMessageIsError = true;
    } finally { this.finishHduOperation(revision); }
  }

  private async disconnectHduHelp(): Promise<void> {
    if (!this.active || !this.pageActive || !this.hduHelpLoaded || this.hduHelpBusy) { return; }
    if (!this.confirmDisconnect) { this.confirmDisconnect = true; return; }
    const revision = this.pageRevision;
    this.hduHelpBusy = true;
    this.hduReadRevision++;
    this.dataRevision++;
    this.hduHelpDataLoading = false;
    this.hduMutationPending = true;
    try {
      await new CampusFlowApi(this.baseUrl, this.token).disconnectHduHelp();
      if (!this.current(revision)) { return; }
      this.hduHelp.configured = false;
      this.hduHelpSections = [];
      this.hduHelpPrompts = [];
      this.confirmDisconnect = false;
      this.hduHelp.resources = [];
      this.hduHelpAuthorizeUrl = '';
      this.hduHelpMessage = 'HDUHelp 已断开，服务端同步数据已删除。';
      this.hduHelpMessageIsError = false;
    } catch (error) {
      if (!this.current(revision)) { return; }
      this.hduHelpMessage = this.safeFailure(error, '校园连接操作');
      this.hduHelpMessageIsError = true;
    } finally { this.finishHduOperation(revision); }
  }

  private finishHduOperation(revision: number): void {
    this.hduMutationPending = false;
    if (!this.pageActive) { return; }
    this.hduHelpBusy = false;
    if (!this.current(revision) && this.active) { this.loadHduHelp(); }
  }

  private async saveProfile(): Promise<void> { await this.saveSettings(false); }
  private async saveModel(): Promise<void> { await this.saveSettings(true); }
  private async saveSettings(modelOnly: boolean): Promise<void> {
    if (!this.pageActive || !this.active || this.settingsBusy || this.settingsNeedsCheck) { return; }
    if (modelOnly && this.newApiKey.trim().length === 0) { this.modelMessage = '请先填写新的 API Key。'; this.modelError = true; return; }
    const revision = this.pageRevision;
    const saved = this.savedProfile ?? this.user;
    const submittedKey = this.newApiKey;
    this.settingsBusy = true;
    if (modelOnly) { this.modelMessage = ''; } else { this.profileMessage = ''; }
    try {
      const updated = await new CampusFlowApi(this.baseUrl, this.token).updateSettings(
        modelOnly ? saved.display_name : this.displayName, modelOnly ? saved.school ?? '' : this.school,
        modelOnly ? saved.campus ?? '' : this.campus, modelOnly ? saved.semester ?? '' : this.semester,
        modelOnly ? submittedKey : ''
      );
      if (!this.current(revision)) { return; }
      this.savedProfile = updated;
      if (modelOnly) {
        if (this.newApiKey === submittedKey) { this.newApiKey = ''; }
        this.modelMessage = this.newApiKey.length > 0 ? '本次模型配置已保存；后来填写的新密钥仍未提交。' : '模型配置已保存。'; this.modelError = false;
      }
      else { this.profileMessage = '账号与校园资料已保存；课程内容未改变。'; this.profileError = false; }
      this.onUserChanged(updated);
    } catch (error) {
      if (!this.current(revision)) { return; }
      this.settingsNeedsCheck = true;
      if (modelOnly) { this.modelMessage = this.safeFailure(error, '模型保存'); this.modelError = true; }
      else { this.profileMessage = this.safeFailure(error, '资料保存'); this.profileError = true; }
    } finally { if (this.pageActive) { this.settingsBusy = false; } }
  }
  private async checkSettings(): Promise<void> {
    if (!this.active || !this.pageActive || this.settingsBusy) { return; }
    const revision = this.pageRevision;
    this.settingsBusy = true;
    try {
      const updated = await new CampusFlowApi(this.baseUrl, this.token).me();
      if (!this.current(revision)) { return; }
      this.savedProfile = updated;
      this.settingsNeedsCheck = false;
      this.onUserChanged(updated);
      this.profileMessage = '已读取服务端资料。输入草稿保留，请核对后决定是否保存。';
      this.modelMessage = '已读取模型配置状态；密钥明文不可回读，请核对提示后决定是否更新。';
      this.profileError = false; this.modelError = false;
    } catch (error) {
      if (this.current(revision)) { this.profileMessage = this.safeFailure(error, '状态核对'); this.profileError = true; }
    } finally { if (this.pageActive) { this.settingsBusy = false; } }
  }

  private subscriptionFailure(error: Error): string {
    if (error instanceof CampusFlowRequestError) {
      if (error.statusCode === 401 || error.statusCode === 403) {
        return '当前登录或权限已失效，请重新登录后核对课表。';
      }
      if (error.code === 'IMPORT_REVIEW_REQUIRED') { return '订阅含有需要逐条核对的内容，当前课表未被替换。请到课表维护预览并处理这些课程。'; }
      if (error.statusCode === 422) {
        return '订阅未通过服务校验，请检查链接是否有效，或稍后重试。';
      }
    }
    this.subscriptionNeedsCheck = true;
    return '暂时无法确认课表同步结果；请先到课表维护核对课表，再决定是否重试。';
  }

  private async saveSubscription(): Promise<void> {
    if (!this.pageActive || !this.active || this.subscriptionBusy || this.subscriptionLoading || this.scheduleUrl.trim().length === 0) {
      return;
    }
    const revision = ++this.subscriptionRevision;
    this.subscriptionBusy = true;
    this.subscriptionWritePending = true;
    this.timetableUpdated = false;
    this.subscriptionNeedsCheck = false;
    this.message = '';
    this.subscriptionError = false;
    try {
      const result = await new CampusFlowApi(this.baseUrl, this.token).saveSubscription(this.scheduleUrl);
      if (!this.pageActive || revision !== this.subscriptionRevision) { return; }
      this.subscription = result.status;
      this.subscriptionLoaded = true;
      this.scheduleUrl = '';
      this.message = `已导入 ${result.imported_count} 节课程。${(result.warnings ?? []).join(' ')}`;
      this.timetableUpdated = true;
      this.onTimetableChanged();
    } catch (error) {
      if (this.pageActive && revision === this.subscriptionRevision) { this.message = this.subscriptionFailure(error); this.subscriptionError = true; }
    } finally {
      this.subscriptionWritePending = false;
      if (this.pageActive) {
        this.subscriptionBusy = false;
        if (this.active && revision !== this.subscriptionRevision) { this.loadSubscription(); }
      }
    }
  }

  private async syncSubscription(): Promise<void> {
    if (!this.pageActive || !this.active || this.subscriptionBusy || this.subscriptionLoading) { return; }
    const revision = ++this.subscriptionRevision;
    this.subscriptionBusy = true;
    this.subscriptionWritePending = true;
    this.timetableUpdated = false;
    this.subscriptionNeedsCheck = false;
    this.message = '';
    this.subscriptionError = false;
    try {
      const result = await new CampusFlowApi(this.baseUrl, this.token).syncSubscription();
      if (!this.pageActive || revision !== this.subscriptionRevision) { return; }
      this.subscription = result.status;
      this.subscriptionLoaded = true;
      this.message = `课表已同步，共 ${result.imported_count} 节。${(result.warnings ?? []).join(' ')}`;
      this.timetableUpdated = true;
      this.onTimetableChanged();
    } catch (error) {
      if (this.pageActive && revision === this.subscriptionRevision) { this.message = this.subscriptionFailure(error); this.subscriptionError = true; }
    } finally {
      this.subscriptionWritePending = false;
      if (this.pageActive) {
        this.subscriptionBusy = false;
        if (this.active && revision !== this.subscriptionRevision) { this.loadSubscription(); }
      }
    }
  }

  @Builder
  private field(label: string, value: string, onChange: (value: string) => void, secure: boolean = false) {
    Column({ space: 6 }) {
      Text(label).fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
      TextInput({ text: value }).type(secure ? InputType.Password : InputType.Normal)
        .constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize).backgroundColor(this.palette.field).borderRadius(this.palette.controlRadius).enabled(!this.settingsBusy).onChange(onChange)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private dataItem(item: HDUHelpDisplayItem) {
    if (item.label.length > 12 || item.value.length > 22) {
      Column({ space: 5 }) {
        Text(item.label).fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
        Text(item.value).fontSize(item.emphasis ? 17 : 15)
          .fontWeight(item.emphasis ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(item.emphasis ? this.palette.accent : this.palette.ink)
          .width('100%')
      }.width('100%').alignItems(HorizontalAlign.Start)
        .padding(11).backgroundColor(this.palette.field).borderRadius(this.palette.controlRadius)
    } else {
      Row() {
        Text(item.label).fontSize(this.palette.metaSize).fontColor(this.palette.secondary)
        Blank()
        Text(item.value).fontSize(item.emphasis ? 17 : 15)
          .fontWeight(item.emphasis ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(item.emphasis ? this.palette.accent : this.palette.ink)
          .constraintSize({ maxWidth: '68%' })

      }.width('100%')
    }
  }

  @Builder
  private hduHelpDataView() {
    Column() {
      Row({ space: 8 }) {
        Button({ type: ButtonType.Normal }) {
          AppIcon({ name: 'back', iconSize: 22, color: this.palette.accent })
        }.width(44).constraintSize({ minHeight: 44 })
          .backgroundColor(Color.Transparent).borderRadius(this.palette.controlRadius)
          .accessibilityText('返回校园数据连接').onClick(() => this.closeHduHelpData())
        Text('校园档案').fontSize(22).fontWeight(FontWeight.Bold).fontColor(this.palette.ink).layoutWeight(1)
        Button('刷新').constraintSize({ minHeight: 44 }).fontSize(this.palette.bodySize).fontColor(this.palette.accent)
          .backgroundColor(Color.Transparent).enabled(!this.hduHelpDataLoading).onClick(() => this.openHduHelpData())
      }.width('100%').padding({ left: 12, right: 16, top: 8, bottom: 8 })

      Scroll() {
        Column({ space: 14 }) {
          if (this.hduHelpDataLoading) {
            Text('正在整理校园数据…').fontSize(this.palette.bodySize).fontColor(this.palette.secondary).width('100%')
              .padding(this.palette.cardInset).backgroundColor(this.palette.surface).borderRadius(20)
          } else if (this.hduHelpDataError.length > 0) {
            FeedbackPanel({ kind: 'error', title: '校园档案未更新', message: this.hduHelpDataError,
              actionLabel: '重试读取', busy: this.hduHelpDataLoading, onAction: () => this.openHduHelpData() })
          } else {
            if (this.hduHelpSections.length === 0) {
              FeedbackPanel({ kind: 'info', title: '暂无可展示的校园档案', message: '可返回连接设置，检查 HDUHelp 授权与同步状态。' })
            }
            Text(`账户、学籍与成绩 · 已同步 ${this.hduHelpSections.length} 个分区`)
              .fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')

            ForEach(this.hduHelpSections, (section: HDUHelpDisplaySection) => {
              Column({ space: 10 }) {
                Row() {
                  Column({ space: 3 }) {
                    Text(section.title).fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.palette.ink)
                    Text(section.summary).fontSize(this.palette.metaSize).fontColor(this.palette.secondary)
                  }.alignItems(HorizontalAlign.Start)
                  Blank()
                  Row() {
                    AppIcon({ name: 'check', iconSize: 16, color: this.palette.success })
                  }.width(28).height(28).justifyContent(FlexAlign.Center)
                    .backgroundColor(this.palette.successSoft).borderRadius(10)
                }.width('100%')
                ForEach(section.items, (item: HDUHelpDisplayItem) => {
                  this.dataItem(item)
                }, (item: HDUHelpDisplayItem) => `${section.resource}-${item.label}`)
              }.width('100%').padding(this.palette.cardInset).backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
            }, (section: HDUHelpDisplaySection) => section.resource)

            if (this.hduHelpSyncErrors.length > 0) {
              Column({ space: 8 }) {
                Text('暂不可用的数据').fontSize(this.palette.bodySize).fontWeight(FontWeight.Bold)
                  .fontColor(this.palette.danger).width('100%')
                Text('以下项目需要在 HDUHelp 补充权限或服务授权，其余成功数据已全部展示。')
                  .fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
                ForEach(this.hduHelpSyncErrors, (message: string) => {
                  Text(message).fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%').maxLines(3)

                }, (message: string) => message)
              }.width('100%').padding(17).backgroundColor(this.palette.bg).borderRadius(18)
            }

            if (this.hduHelpPrompts.length > 0) {
              Column({ space: 11 }) {
                Text('问问助手').fontSize(this.palette.sectionTitle).fontWeight(FontWeight.Bold).fontColor(this.palette.ink).width('100%')
                Text('基于已连接的数据继续完成任务').fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
                ForEach(this.hduHelpPrompts, (suggestion: HDUHelpSuggestedPrompt) => {
                  Button() {
                    Row({ space: 10 }) {
                      Text(suggestion.title).fontSize(this.palette.bodySize).fontColor(this.palette.accent)
                        .layoutWeight(1)
                      AppIcon({ name: 'chevron', iconSize: 16, color: this.palette.accent })
                    }.width('100%')
                  }.width('100%').constraintSize({ minHeight: 48 }).padding({ left: 14, right: 14 })
                    .backgroundColor(this.palette.accentSoft).borderRadius(12)
                    .onClick(() => this.onOpenAgent(suggestion.prompt))
                }, (suggestion: HDUHelpSuggestedPrompt) => suggestion.prompt_id)
              }.width('100%').padding(this.palette.cardInset).backgroundColor(this.palette.surface).borderRadius(18)
            }
          }
        }.width('100%').padding({ left: 18, right: 18, bottom: 28 })
      }.layoutWeight(1).width('100%').align(Alignment.TopStart)
    }.width('100%').height('100%').alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Start).backgroundColor(this.palette.bg)
  }

  @Builder
  private groupHeader(group: string, title: string, summary: () => string, homeRow: boolean = false) {
    if (this.section.length === 0 ? homeRow : this.sectionVisible(group)) {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 12 }) {
          Stack() {
            AppIcon({ name: group === 'appearance' ? 'skills' : group === 'reminders' ? 'speaker' :
              group === 'connections' ? 'classroom' : group === 'data' ? 'history' : group === 'learning' ? 'book' : 'person',
              iconSize: 19, color: this.palette.accent })
          }.width(30).height(30).backgroundColor(this.palette.accentSoft).borderRadius(8)
          Column({ space: 3 }) {
            Text(title).fontSize(this.palette.bodySize).fontColor(this.palette.ink).width('100%')
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            if (group === 'appearance' || group === 'model' || group === 'connections' || group === 'account' && this.accountDirty()) {
              Text(summary()).fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          AppIcon({ name: 'chevron', iconSize: 16, color: this.palette.muted })
        }.width('100%')
      }.width('100%').constraintSize({ minHeight: 58 }).padding({ left: 16, right: 16, top: 11, bottom: 11 })
        .backgroundColor(this.palette.surface).borderRadius(this.section.length === 0 ? 0 : this.palette.cardRadius)
        .accessibilityText(`打开${title}，${summary()}`)
        .onClick(() => this.toggleGroup(group))
    }
  }

  @Builder
  private settingSeparator() {
    Divider().color(this.palette.line).strokeWidth(0.5).margin({ left: 58 })
  }

  @Builder
  private SettingsHome() {
    Column({ space: 12 }) {
      Text('资料与校园').fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%').padding({ left: 16, top: 8 })
      Column() {
        this.groupHeader('account', '账号与校园', () => this.accountDirty() ? '有未保存修改' : '昵称、学校与学期', true)
        this.settingSeparator()
        this.groupHeader('connections', '校园数据连接', () => !this.hduHelpLoaded ? '连接状态待核对' : this.hduHelp.configured ? 'HDUHelp 已连接' : 'HDUHelp 与课表订阅', true)
      }.width('100%').backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius).clip(true)
      Text('使用与偏好').fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%').padding({ left: 16, top: 8 })
      Column() {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 12 }) {
            Stack() {
              AppIcon({ name: 'info', iconSize: 19, color: this.palette.accent })
            }.width(30).height(30).backgroundColor(this.palette.accentSoft).borderRadius(8)
            Text('使用指南').fontSize(this.palette.bodySize).fontColor(this.palette.ink).layoutWeight(1).textAlign(TextAlign.Start)
            AppIcon({ name: 'chevron', iconSize: 16, color: this.palette.muted })
          }.width('100%')
        }.width('100%').constraintSize({ minHeight: 58 }).padding({ left: 16, right: 16, top: 11, bottom: 11 })
          .backgroundColor(this.palette.surface).accessibilityText('使用指南，了解安排、执行和回顾的完整流程')
          .onClick(() => { if (this.active && this.pageActive) { this.onOpenGuide(); } })
        this.settingSeparator()
        this.groupHeader('learning', '学习偏好', () => '单次时长、休息与每日安排目标', true)
        this.settingSeparator()
        this.groupHeader('appearance', '外观与动效', () => this.palette.name, true)
        this.settingSeparator()
        this.groupHeader('reminders', '语音与提醒', () => '语音使用方式与本机系统通知', true)
      }.width('100%').backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius).clip(true)
      Text('连接与数据').fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%').padding({ left: 16, top: 8 })
      Column() {
        this.groupHeader('model', '模型连接', () => this.newApiKey.length > 0 ? '有新密钥尚未保存' : `当前密钥 ${this.user.api_key_hint ?? '未配置'}`, true)
        this.settingSeparator()
        this.groupHeader('data', '历史与本机数据', () => '会话记录、草稿与服务地址', true)
        if (this.user.role === 'admin') {
          this.settingSeparator()
          this.groupHeader('admin', '用户管理', () => '管理员可查看的账号摘要', true)
        }
      }.width('100%').backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius).clip(true)
    }.width('100%')
  }

  private changeTheme(id: AppThemeId): void {
    // Appearance only: leave account drafts, selected settings section and navigation intact.
    selectAppTheme(id);
  }

  @Builder
  private themeChoice(id: AppThemeId, label: string, description: string) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 10 }) {
        Column({ space: 7 }) {
          Row() {
            Text('今日安排').fontSize(12).fontColor(themePalette(id).ink)
            Blank()
            Row().width(14).height(14).backgroundColor(themePalette(id).accent).borderRadius(7)
          }.width('100%')
          Row().width('100%').height(8).backgroundColor(themePalette(id).surface).borderRadius(4)
          Row().width('72%').height(8).backgroundColor(themePalette(id).accentSoft).borderRadius(4)
        }.width('100%').padding(12).backgroundColor(themePalette(id).canvas).borderRadius(10)
          .accessibilityLevel('no')
        Row({ space: 6 }) {
          Text(label).fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium).fontColor(this.palette.ink)
            .layoutWeight(1)
          if (this.palette.id === id) { AppIcon({ name: 'check', iconSize: 18, color: this.palette.accent }) }
        }.width('100%')
        Text(description).fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
          .wordBreak(WordBreak.BREAK_WORD)
      }.width('100%').alignItems(HorizontalAlign.Start)
    }.layoutWeight(1).padding(12).backgroundColor(this.palette.surface)
      .border({ width: this.palette.id === id ? 2 : 1, color: this.palette.id === id ? this.palette.accent : this.palette.line })
      .borderRadius(this.palette.cardRadius).accessibilityText(`${label}，${this.palette.id === id ? '当前主题' : '点击切换'}，${description}`)
      .onClick(() => this.changeTheme(id))
  }

  build() {
    Stack() {
      Scroll(this.pageScroller) {
        Column({ space: 12 }) {
          if (this.section.length === 0) {
          Row({ space: 12 }) {
            Text(this.user.display_name.slice(0, 1)).fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.palette.accent)
              .width(48).constraintSize({ minHeight: 48 }).textAlign(TextAlign.Center).backgroundColor(this.palette.accentSoft).borderRadius(24)
            Column({ space: 4 }) {
              Text(this.user.display_name).fontSize(this.palette.sectionTitle).fontWeight(FontWeight.Medium).fontColor(this.palette.ink).width('100%')
              Text(this.user.email).fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%').wordBreak(WordBreak.BREAK_ALL)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          }.width('100%').padding(16).backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
          this.SettingsHome()
          }
          if (this.section.length > 0) {
            Row({ space: 8 }) {
              Button({ type: ButtonType.Normal }) {
                AppIcon({ name: 'back', iconSize: 22, color: this.palette.accent })
              }.width(44).constraintSize({ minHeight: 44 }).backgroundColor(Color.Transparent)
                .accessibilityText('返回我的设置').onClick(() => this.sectionBack())
              Text(this.sectionTitle()).fontSize(22).fontWeight(FontWeight.Bold).fontColor(this.palette.ink).layoutWeight(1)
            }.width('100%')
          }
          if (this.settingsNeedsCheck) {
            FeedbackPanel({ kind: 'warning', title: '保存结果待核对', message: '输入草稿仍在。先读取服务端资料，再决定是否重新保存。',
              actionLabel: '核对已保存资料', busy: this.settingsBusy, onAction: () => this.checkSettings() })
          }
          this.groupHeader('account', '账号与校园', () => this.accountDirty() ? '有未保存修改' : '昵称、学校与学期')
          if (this.section === 'account') {
            Column({ space: 16 }) {
              if (this.accountDirty()) {
                Text('有未保存修改').fontSize(this.palette.metaSize).fontColor(this.palette.warning).width('100%')
              }
              this.field('昵称', this.displayName, (value) => this.displayName = value)
              this.field('学校', this.school, (value) => this.school = value)
              this.field('校区', this.campus, (value) => this.campus = value)
              this.field('学期', this.semester, (value) => this.semester = value)
              Text('课程与导入请进入课表维护。')
                .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
              if (this.profileMessage.length > 0) {
                FeedbackPanel({ kind: this.profileError ? 'error' : 'info', title: '账号资料', message: this.profileMessage })
              }
              Button(this.settingsBusy ? '正在保存…' : '保存账号与校园').width('100%').constraintSize({ minHeight: 48 })
                .fontSize(this.palette.bodySize).fontColor(this.palette.onAccent).backgroundColor(this.palette.accent).borderRadius(this.palette.controlRadius)
                .enabled(!this.settingsBusy && !this.settingsNeedsCheck).onClick(() => this.saveProfile())
              Button('课表维护').width('100%').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
                .fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft).borderRadius(this.palette.controlRadius)
                .onClick(() => this.onOpenTimetable())
            }.width('100%').padding(this.palette.cardInset).backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
              .border({ width: 1, color: this.palette.line })
          }
          this.groupHeader('learning', '学习偏好', () => '单次时长、休息与每日安排目标')
          LearningPreferencesPanel({ baseUrl: this.baseUrl, token: this.token, userId: this.user.user_id, active: this.active && this.section === 'learning' && !this.showHduHelpData })
            .visibility(this.section === 'learning' ? Visibility.Visible : Visibility.None)
          this.groupHeader('appearance', '外观与动效', () => `${this.palette.name} · 本机偏好`)
          if (this.section === 'appearance') {
            Column({ space: 16 }) {
              Text('选择喜欢的外观').fontSize(this.palette.sectionTitle).fontWeight(FontWeight.Medium)
                .fontColor(this.palette.ink).width('100%')
              Text('即时生效，保存在这台设备。')
                .fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
              Row({ space: 12 }) {
                this.themeChoice('ios-blue', '清透蓝', '轻盈明亮，清晰聚焦')
                this.themeChoice('paper-green', '纸页绿', '温和纸色，安静阅读')
              }.width('100%').alignItems(VerticalAlign.Top)
              Row({ space: 12 }) {
                Column({ space: 4 }) {
                  Text('减少动态效果').fontSize(this.palette.bodySize).fontColor(this.palette.ink)
                  Text('简化页面切换与交互动画').fontSize(this.palette.metaSize).fontColor(this.palette.secondary)
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.reduceMotion }).selectedColor(this.palette.success)
                  .onChange((value: boolean) => this.reduceMotion = value).accessibilityText('减少动态效果')
              }.width('100%').constraintSize({ minHeight: 48 })
            }.width('100%').padding(this.palette.cardInset).backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
              .border({ width: 1, color: this.palette.line })
          }
          this.groupHeader('reminders', '语音与提醒', () => '语音使用方式与本机系统通知')
          if (this.section === 'reminders') {
            Column({ space: 12 }) {
              Text('语音在助手中开启。识别文字先核对，再发送。')
                .fontSize(this.palette.bodySize).fontColor(this.palette.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
              Text('首次使用需麦克风和识别权限；播报可随时停止。').fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
              Text('提醒仅用于已确认的定时任务；锁屏不显示任务内容。')
                .fontSize(this.palette.bodySize).fontColor(this.palette.quiet).width('100%')
              FeedbackPanel({ kind: this.reminderState.phase === 'error' ? 'error' : this.reminderBusy() ? 'loading' : 'info',
                title: this.reminderState.enabled ? '本机提醒已启用' : '本机提醒状态', message: this.reminderState.message })
              Text(`已受理 ${this.reminderState.scheduled} 项，未安排 ${this.reminderState.skipped} 项。`)
                .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
              if (this.reminderState.limited) {
                Text('已达系统容量限制，后续提醒请刷新核对。')
                  .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
              }
              Text('系统受理不等于已送达。')
                .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
              InfoDisclosure({ title: '提醒与语音说明', message: '识别与播报取决于设备和权限。提醒只安排设置了具体时间及提前分钟数的未完成任务；无时间、已过期或超过一年范围的任务不安排。近期提醒最多60项，部分系统上限更低。重新打开应用或刷新时核对后续提醒。通知设置、省电及系统调度可能影响送达。退出账号会尝试清理本机提醒，切换到后台不会取消。' })
              if (!this.reminderState.enabled) {
                Button('请求通知权限并启用提醒').width('100%').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
                  .fontColor(this.palette.onAccent).backgroundColor(this.palette.accent).borderRadius(this.palette.controlRadius)
                  .enabled(!this.reminderBusy()).onClick(() => this.onEnableReminders())
              }
              Button('刷新核对').width('100%').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
                .fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft).borderRadius(this.palette.controlRadius)
                .enabled(!this.reminderBusy()).onClick(() => this.onRefreshReminders())
              Button('关闭并清理本机提醒').width('100%').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
                .fontColor(this.palette.danger).backgroundColor(this.palette.dangerSoft).borderRadius(this.palette.controlRadius)
                .enabled(!this.reminderBusy()).onClick(() => this.onDisableReminders())
            }.width('100%').padding(this.palette.cardInset).backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
              .border({ width: 1, color: this.palette.line })
          }
          this.groupHeader('model', '模型连接', () => this.newApiKey.length > 0 ? '有新密钥尚未保存' : `当前密钥 ${this.user.api_key_hint ?? '未配置'}`)
          if (this.section === 'model') {
            Column({ space: 16 }) {
              Text(this.newApiKey.length > 0 ? '新密钥尚未保存。' : '留空保留现有连接。').fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
              this.field('新的 DeepSeek API Key', this.newApiKey, (value) => this.newApiKey = value, true)
              Text('密钥加密保存；留空不更改现有密钥。')
                .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
              InfoDisclosure({ title: '密钥保存说明', message: '密钥只发送到当前配置的行简服务端并加密保存。这里只保存模型配置，不提交其他账号或校园草稿。' })
              if (this.modelMessage.length > 0) {
                FeedbackPanel({ kind: this.modelError ? 'error' : 'info', title: '模型配置', message: this.modelMessage })
              }
              Button(this.settingsBusy ? '正在保存…' : '保存新密钥').width('100%').constraintSize({ minHeight: 48 })
                .fontSize(this.palette.bodySize).fontColor(this.palette.onAccent).backgroundColor(this.palette.accent).borderRadius(this.palette.controlRadius)
                .enabled(!this.settingsBusy && !this.settingsNeedsCheck).onClick(() => this.saveModel())
            }.width('100%').padding(this.palette.cardInset).backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
              .border({ width: 1, color: this.palette.line })
          }
          this.groupHeader('connections', '校园数据连接', () => !this.hduHelpLoaded ? '连接状态待核对' : this.hduHelp.configured ? 'HDUHelp 已连接' : 'HDUHelp 与课表订阅')
          if (this.section === 'connections') {
        Column({ space: 12 }) {
          Row() {
            Column({ space: 4 }) {
              Text('HDUHelp').fontSize(this.palette.sectionTitle).fontWeight(FontWeight.Bold).fontColor(this.palette.ink)
              Text('个人令牌或官方授权').fontSize(this.palette.metaSize).fontColor(this.palette.secondary)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Blank()
            Text(!this.hduHelpLoaded ? '状态待核对' : this.hduHelp.configured ? '已连接' : '未连接').fontSize(this.palette.metaSize)
              .fontColor(this.hduHelp.configured ? this.palette.success : this.palette.muted)
          }.width('100%')
          if (this.hduHelpBusy) {
            FeedbackPanel({ kind: 'loading', title: '正在核对校园连接', message: '请稍候，连接操作不会重复提交。' })
          }
          Button('刷新连接状态').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
            .fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft).enabled(!this.hduHelpBusy)
            .onClick(() => this.loadHduHelp())
          if (this.confirmDisconnect) {
            Text('确认断开后，将删除服务端同步的校园数据。').fontSize(this.palette.metaSize).fontColor(this.palette.danger).width('100%')
            Button('保留连接').constraintSize({ minHeight: 48 }).fontColor(this.palette.accent)
              .backgroundColor(this.palette.accentSoft).enabled(!this.hduHelpBusy).onClick(() => this.confirmDisconnect = false)
          }
          if (this.hduHelpMessage.length > 0) {
            Text(this.hduHelpMessage).fontSize(this.palette.metaSize)
              .fontColor(this.hduHelpMessageIsError ? this.palette.danger : this.palette.accent)
              .width('100%').padding(11)
              .backgroundColor(this.hduHelpMessageIsError ? this.palette.bg : this.palette.accentSoft)
              .borderRadius(12)
          }
          if (this.hduHelp.configured) {
            Column({ space: 3 }) {
              Text(`${this.hduHelp.auth_mode === 'pat' ? `个人令牌 ${this.hduHelp.token_hint ?? ''}` : '官方 OAuth'} · ${this.hduHelp.external_name ?? '当前用户'}`)
                .fontSize(this.palette.bodySize).fontColor(this.palette.accent).width('100%')

              Text(`${this.hduHelp.resources.length} 类校园数据可供助手使用`)
                .fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
            }.width('100%').padding(12).backgroundColor(this.palette.accentSoft).borderRadius(this.palette.controlRadius)
            Row({ space: 9 }) {
              Button('同步数据').layoutWeight(1).constraintSize({ minHeight: 48 }).fontColor(this.palette.onAccent).backgroundColor(this.palette.accent)
                .borderRadius(this.palette.controlRadius).enabled(this.hduHelpLoaded && !this.hduHelpBusy).onClick(() => this.syncHduHelp())
              Button(this.confirmDisconnect ? '确认断开并删除' : '断开并删除').layoutWeight(1).constraintSize({ minHeight: 48 }).fontColor(this.palette.danger).backgroundColor(this.palette.bg)
                .borderRadius(this.palette.controlRadius).enabled(this.hduHelpLoaded && !this.hduHelpBusy && !this.hduHelpDataLoading).onClick(() => this.disconnectHduHelp())
            }.width('100%')
            Button('我的校园档案').width('100%').constraintSize({ minHeight: 48 }).fontColor(this.palette.accent)
              .backgroundColor(this.palette.accentSoft).borderRadius(this.palette.controlRadius).enabled(!this.hduHelpBusy && !this.hduHelpDataLoading).onClick(() => this.openHduHelpData())
          } else {
            Text('HDUHelp 个人访问令牌').fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
            TextInput({ text: this.hduHelpPat, placeholder: 'hduhelp_pat_…' }).type(InputType.Password)
              .constraintSize({ minHeight: 48 }).backgroundColor(this.palette.field).borderRadius(this.palette.controlRadius)
              .enabled(!this.hduHelpBusy).onChange((value) => this.hduHelpPat = value)
            Text('令牌发送到当前配置的行简服务端，并加密保存。').fontSize(this.palette.metaSize)
              .fontColor(this.palette.secondary).width('100%')
            Text('无需提供杭电密码。').fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
            Button('使用令牌连接并同步').width('100%').constraintSize({ minHeight: 48 }).fontColor(this.palette.onAccent)
              .backgroundColor(this.palette.accent).borderRadius(this.palette.controlRadius).enabled(this.hduHelpLoaded && !this.hduHelpBusy && !this.hduHelpDataLoading).onClick(() => this.connectHduHelpPat())
            Button('或使用官方 OAuth').width('100%').constraintSize({ minHeight: 48 }).fontColor(this.palette.accent)
              .backgroundColor(this.palette.accentSoft).borderRadius(this.palette.controlRadius).enabled(this.hduHelpLoaded && !this.hduHelpBusy && !this.hduHelpDataLoading).onClick(() => this.connectHduHelp())
            if (this.hduHelpAuthorizeUrl.length > 0) {
              Hyperlink(this.hduHelpAuthorizeUrl, '打开 HDUHelp 官方授权页 ↗')
                .color(this.palette.accent).width('100%')
              Button('我已授权，检查连接').width('100%').constraintSize({ minHeight: 48 }).fontColor(this.palette.accent)
                .backgroundColor(this.palette.accentSoft).borderRadius(this.palette.controlRadius).enabled(!this.hduHelpBusy && !this.hduHelpDataLoading).onClick(() => this.loadHduHelp())
            }
          }
        }.width('100%').padding(this.palette.cardInset).backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
          .border({ width: 1, color: this.palette.line })

        Column({ space: 12 }) {
          Row() {
            Text('课表订阅').fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.palette.ink)
            Blank()
            Text(!this.subscriptionLoaded ? '状态待核对' : this.subscription.configured ? `${this.subscription.event_count} 节` : '未连接')
              .fontSize(this.palette.metaSize).fontColor(this.subscription.configured ? this.palette.success : this.palette.muted)
          }.width('100%')
          if (this.subscriptionLoading) {
            FeedbackPanel({ kind: 'loading', title: '正在读取订阅状态' })
          }
          if (this.message.length > 0) {
            FeedbackPanel({ kind: this.subscriptionError ? 'error' : 'info', title: '课表订阅', message: this.message })
          }
          Button('刷新订阅状态').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
            .fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft)
            .enabled(!this.subscriptionBusy && !this.subscriptionLoading).onClick(() => this.loadSubscription())
          Text('订阅链接').fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
          TextInput({ text: this.scheduleUrl, placeholder: '粘贴 HDUHelp 订阅链接' }).constraintSize({ minHeight: 48 })
            .backgroundColor(this.palette.field).borderRadius(this.palette.controlRadius).enabled(!this.subscriptionBusy)
            .onChange((value) => this.scheduleUrl = value)
          Row({ space: 9 }) {
            Button(this.subscriptionBusy ? '处理中…' : '连接新课表').layoutWeight(1).constraintSize({ minHeight: 48 })
              .fontColor(this.palette.onAccent).backgroundColor(this.palette.accent).enabled(!this.subscriptionBusy)
              .borderRadius(this.palette.controlRadius).onClick(() => this.saveSubscription())
            if (this.subscription.configured) {
              Button('立即同步').layoutWeight(1).constraintSize({ minHeight: 48 }).fontColor(this.palette.accent)
                .backgroundColor(this.palette.accentSoft).enabled(!this.subscriptionBusy)
                .borderRadius(this.palette.controlRadius).onClick(() => this.syncSubscription())
            }
          }.width('100%')
          if (this.timetableUpdated || this.subscriptionNeedsCheck) {
            Text(this.subscriptionNeedsCheck ? '本次同步结果尚未确认，请先核对课表再重试。' :
              '课表已更新，去计划核对冲突。已有任务的时间不会自动改变。')
              .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
            Button(this.subscriptionNeedsCheck ? '先查看当前课表' : '去计划核对冲突').width('100%').constraintSize({ minHeight: 48 })
              .fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft)
              .enabled(!this.subscriptionBusy).borderRadius(this.palette.controlRadius).onClick(() => { if (this.subscriptionNeedsCheck) { this.onOpenTimetable(); } else { this.onOpenPlan(); } })
          }
        }.width('100%').padding(this.palette.cardInset).backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
          .border({ width: 1, color: this.palette.line })

          }
          this.groupHeader('data', '历史与本机数据', () => '会话记录、草稿与服务地址')
          if (this.section === 'data') {
            Column({ space: 16 }) {
              Button('打开会话历史').width('100%').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
                .fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft).onClick(() => this.onOpenHistory())
              Text('本机草稿').fontSize(this.palette.bodySize).fontColor(this.palette.ink).width('100%')
              Text(this.draftNotice || '未提交的输入只保存在这台设备。退出账号会清除，不包含密码或模型凭据。')
                .fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
              if (this.draftClearConfirm) {
                Text('确定清除本机未提交草稿？账号内已经保存的安排不受影响。')
                  .fontSize(this.palette.bodySize).fontColor(this.palette.warning).width('100%')
                Button('保留草稿').constraintSize({ minHeight: 48 }).onClick(() => this.onCancelClearDrafts())
              }
              Button(this.draftClearConfirm ? '确认清除本机草稿' : '清除本机草稿')
                .width('100%').constraintSize({ minHeight: 48 }).fontColor(this.palette.danger)
                .backgroundColor(this.palette.dangerSoft).enabled(!this.draftCleanupBusy).onClick(() => this.onClearDrafts())
              Text('当前服务地址').fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
              Text(this.baseUrl).fontSize(this.palette.bodySize).fontColor(this.palette.ink).width('100%').wordBreak(WordBreak.BREAK_ALL)
            }.width('100%').padding(this.palette.cardInset).backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
              .border({ width: 1, color: this.palette.line })
          }
          if (this.user.role === 'admin') { this.groupHeader('admin', '用户管理', () => '管理员可查看的账号摘要') }
        if (this.user.role === 'admin' && this.section === 'admin') {
          Column({ space: 12 }) {
            Row() {
              Text('用户管理').fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.palette.ink)
              Blank()
              Text(`${this.adminUsers.length} 人`).fontSize(this.palette.metaSize).fontColor(this.palette.accent)
            }.width('100%')
            if (this.adminLoading) { FeedbackPanel({ kind: 'loading', title: '正在读取用户列表' }) }
            if (this.adminMessage.length > 0) {
              FeedbackPanel({ kind: 'error', title: '用户列表未更新', message: this.adminMessage, actionLabel: '重试',
                busy: this.adminLoading, onAction: () => this.loadAdminUsers() })
            }
            ForEach(this.adminUsers, (account: AdminUserSummary) => {
              Row({ space: 11 }) {
                Text(account.display_name.slice(0, 1)).fontSize(this.palette.bodySize).fontWeight(FontWeight.Bold)
                  .fontColor(this.palette.accent).width(36).height(36).textAlign(TextAlign.Center)
                  .backgroundColor(this.palette.accentSoft).borderRadius(12)
                Column({ space: 3 }) {
                  Row({ space: 6 }) {
                    Text(account.display_name).fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium).fontColor(this.palette.ink)
                    if (account.role === 'admin') {
                      Text('管理员').fontSize(this.palette.metaSize).fontColor(this.palette.onAccent).backgroundColor(this.palette.accent)
                        .padding({ left: 5, right: 5, top: 2, bottom: 2 }).borderRadius(7)
                    }
                  }
                  Text(account.email).fontSize(this.palette.metaSize).fontColor(this.palette.secondary)

                  Text(`${account.timetable_count} 节课 · ${account.campus_place_count} 个地点 · ${account.api_key_configured ? '凭据已配置' : '凭据未配置'}`)
                    .fontSize(this.palette.metaSize).fontColor(this.palette.muted)
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              }.width('100%')
            }, (account: AdminUserSummary) => account.user_id)
          }.width('100%').padding(this.palette.cardInset).backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
            .border({ width: 1, color: this.palette.line })
        }

          if (this.section === 'data') {
          Button('退出登录').width('100%').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
            .fontColor(this.palette.danger).backgroundColor(this.palette.dangerSoft).borderRadius(this.palette.controlRadius)
            .onClick(() => this.onLogout())
          }
        }.width('100%').alignItems(HorizontalAlign.Start)
          .padding({ left: this.palette.pageInset, right: this.palette.pageInset, top: 16, bottom: 24 })
      }.width('100%').height('100%').backgroundColor(this.palette.canvas)
        .align(Alignment.TopStart)
        .visibility(this.showHduHelpData ? Visibility.Hidden : Visibility.Visible)
      if (this.showHduHelpData) { this.hduHelpDataView() }
    }.width('100%').height('100%')
  }
}
