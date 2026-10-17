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
import { AppIcon } from '../components/AppIcon';
import { FeedbackPanel } from '../components/FeedbackPanel';
import { CampusFlowRequestError } from '../utils/AgentFeedback';
import { LearningPreferencesPanel } from '../components/LearningPreferencesPanel';
import { ReminderState } from '../utils/ReminderCoordinator';

@Component
export struct ProfilePage {
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
  @Prop reminderState: ReminderState = { phase: 'disabled', message: '本机系统提醒尚未启用。', scheduled: 0, skipped: 0, limited: false, enabled: false };
  @Prop reminderCleanupBusy: boolean = false;
  onEnableReminders: () => void = () => {};
  onDisableReminders: () => void = () => {};
  onRefreshReminders: () => void = () => {};
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
  @State private expandedGroups: string[] = ['account'];
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
    this.expandedGroups = this.expandedGroups.includes(group) ?
      this.expandedGroups.filter((item: string) => item !== group) : this.expandedGroups.concat([group]);
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
    this.settingsBusy = true;
    if (modelOnly) { this.modelMessage = ''; } else { this.profileMessage = ''; }
    try {
      const updated = await new CampusFlowApi(this.baseUrl, this.token).updateSettings(
        modelOnly ? saved.display_name : this.displayName, modelOnly ? saved.school ?? '' : this.school,
        modelOnly ? saved.campus ?? '' : this.campus, modelOnly ? saved.semester ?? '' : this.semester,
        modelOnly ? this.newApiKey : ''
      );
      if (!this.current(revision)) { return; }
      this.savedProfile = updated;
      if (modelOnly) { this.newApiKey = ''; this.modelMessage = '模型配置已保存。'; this.modelError = false; }
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
      this.message = `已导入 ${result.imported_count} 节课程。`;
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
      this.message = `课表已同步，共 ${result.imported_count} 节。`;
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
      Text(label).fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%')
      TextInput({ text: value }).type(secure ? InputType.Password : InputType.Normal)
        .constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize).backgroundColor(AppTheme.field).borderRadius(AppTheme.controlRadius).enabled(!this.settingsBusy).onChange(onChange)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private dataItem(item: HDUHelpDisplayItem) {
    if (item.label.length > 12 || item.value.length > 22) {
      Column({ space: 5 }) {
        Text(item.label).fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%')
        Text(item.value).fontSize(item.emphasis ? 17 : 15)
          .fontWeight(item.emphasis ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(item.emphasis ? AppTheme.accent : AppTheme.ink)
          .width('100%')
      }.width('100%').alignItems(HorizontalAlign.Start)
        .padding(11).backgroundColor(AppTheme.field).borderRadius(AppTheme.controlRadius)
    } else {
      Row() {
        Text(item.label).fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary)
        Blank()
        Text(item.value).fontSize(item.emphasis ? 17 : 15)
          .fontWeight(item.emphasis ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(item.emphasis ? AppTheme.accent : AppTheme.ink)
          .constraintSize({ maxWidth: '68%' })

      }.width('100%')
    }
  }

  @Builder
  private hduHelpDataView() {
    Column() {
      Row({ space: 12 }) {
        Button() {
          AppIcon({ name: 'back', iconSize: 22, color: AppTheme.accent })
        }.width(48).constraintSize({ minHeight: 48 })
          .backgroundColor(AppTheme.surface).borderRadius(22)
          .onClick(() => this.showHduHelpData = false)
        Column({ space: 3 }) {
          Text('我的校园档案').fontSize(23).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
          Text('由 HDUHelp 同步，助手可按需调用').fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button('刷新').constraintSize({ minHeight: 48 }).fontSize(AppTheme.metaSize).fontColor(AppTheme.accent).backgroundColor(AppTheme.accentSoft)
          .borderRadius(14).onClick(() => this.openHduHelpData())
      }.width('100%').padding({ left: 18, right: 18, top: 18, bottom: 12 })

      Scroll() {
        Column({ space: 14 }) {
          if (this.hduHelpDataLoading) {
            Text('正在整理校园数据…').fontSize(AppTheme.bodySize).fontColor(AppTheme.secondary).width('100%')
              .padding(AppTheme.cardInset).backgroundColor(AppTheme.surface).borderRadius(20)
          } else if (this.hduHelpDataError.length > 0) {
            FeedbackPanel({ kind: 'error', title: '校园档案未更新', message: this.hduHelpDataError,
              actionLabel: '重试读取', busy: this.hduHelpDataLoading, onAction: () => this.openHduHelpData() })
          } else {
            if (this.hduHelpSections.length === 0) {
              FeedbackPanel({ kind: 'info', title: '暂无可展示的校园档案', message: '可返回连接设置，检查 HDUHelp 授权与同步状态。' })
            }
            Column({ space: 7 }) {
              Text('已连接的数据').fontSize(AppTheme.metaSize).fontWeight(FontWeight.Bold).fontColor(AppTheme.accent).width('100%')
              Text(`${this.hduHelpSections.length} 个信息分区`).fontSize(20).fontWeight(FontWeight.Bold)
                .fontColor(AppTheme.ink).width('100%')
            }.width('100%').padding(AppTheme.cardInset).backgroundColor(AppTheme.accentSoft).borderRadius(18)

            ForEach(this.hduHelpSections, (section: HDUHelpDisplaySection) => {
              Column({ space: 10 }) {
                Row() {
                  Column({ space: 3 }) {
                    Text(section.title).fontSize(17).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
                    Text(section.summary).fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary)
                  }.alignItems(HorizontalAlign.Start)
                  Blank()
                  Row() {
                    AppIcon({ name: 'check', iconSize: 16, color: AppTheme.success })
                  }.width(28).height(28).justifyContent(FlexAlign.Center)
                    .backgroundColor(AppTheme.successSoft).borderRadius(10)
                }.width('100%')
                ForEach(section.items, (item: HDUHelpDisplayItem) => {
                  this.dataItem(item)
                }, (item: HDUHelpDisplayItem) => `${section.resource}-${item.label}`)
              }.width('100%').padding(17).backgroundColor(AppTheme.surface).borderRadius(18)
            }, (section: HDUHelpDisplaySection) => section.resource)

            if (this.hduHelpSyncErrors.length > 0) {
              Column({ space: 8 }) {
                Text('暂不可用的数据').fontSize(AppTheme.bodySize).fontWeight(FontWeight.Bold)
                  .fontColor(AppTheme.danger).width('100%')
                Text('以下项目需要在 HDUHelp 补充权限或服务授权，其余成功数据已全部展示。')
                  .fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%')
                ForEach(this.hduHelpSyncErrors, (message: string) => {
                  Text(message).fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%').maxLines(3)

                }, (message: string) => message)
              }.width('100%').padding(17).backgroundColor(AppTheme.bg).borderRadius(18)
            }

            if (this.hduHelpPrompts.length > 0) {
              Column({ space: 11 }) {
                Text('问问助手').fontSize(AppTheme.sectionTitle).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink).width('100%')
                Text('基于已连接的数据继续完成任务').fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%')
                ForEach(this.hduHelpPrompts, (suggestion: HDUHelpSuggestedPrompt) => {
                  Button() {
                    Row({ space: 10 }) {
                      Text(suggestion.title).fontSize(AppTheme.bodySize).fontColor(AppTheme.accent)
                        .layoutWeight(1)
                      AppIcon({ name: 'chevron', iconSize: 16, color: AppTheme.accent })
                    }.width('100%')
                  }.width('100%').constraintSize({ minHeight: 48 }).padding({ left: 14, right: 14 })
                    .backgroundColor(AppTheme.accentSoft).borderRadius(12)
                    .onClick(() => this.onOpenAgent(suggestion.prompt))
                }, (suggestion: HDUHelpSuggestedPrompt) => suggestion.prompt_id)
              }.width('100%').padding(AppTheme.cardInset).backgroundColor(AppTheme.surface).borderRadius(18)
            }
          }
        }.width('100%').padding({ left: 18, right: 18, bottom: 28 })
      }.layoutWeight(1).width('100%')
    }.width('100%').height('100%').alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Start).backgroundColor(AppTheme.bg)
  }

  @Builder
  private groupHeader(group: string, title: string, summary: string) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text(title).fontSize(AppTheme.sectionTitle).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink).width('100%')
          Text(summary).fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Text(this.expandedGroups.includes(group) ? '收起' : '展开').fontSize(AppTheme.metaSize).fontColor(AppTheme.accent)
      }.width('100%')
    }.width('100%').constraintSize({ minHeight: 64 }).padding(AppTheme.cardInset)
      .backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
      .accessibilityText(`${title}，${this.expandedGroups.includes(group) ? '已展开' : '已收起'}`)
      .onClick(() => this.toggleGroup(group))
  }

  build() {
    Stack() {
      Scroll() {
        Column({ space: 16 }) {
          Row({ space: 12 }) {
            Text(this.user.display_name.slice(0, 1)).fontSize(20).fontWeight(FontWeight.Bold).fontColor(AppTheme.accent)
              .width(48).constraintSize({ minHeight: 48 }).textAlign(TextAlign.Center).backgroundColor(AppTheme.accentSoft).borderRadius(24)
            Column({ space: 4 }) {
              Text(this.user.display_name).fontSize(AppTheme.sectionTitle).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink).width('100%')
              Text(this.user.email).fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%').wordBreak(WordBreak.BREAK_ALL)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          }.width('100%').padding({ top: 8, bottom: 8 })
          if (this.settingsNeedsCheck) {
            FeedbackPanel({ kind: 'warning', title: '保存结果待核对', message: '输入草稿仍在。先读取服务端资料，再决定是否重新保存。',
              actionLabel: '核对已保存资料', busy: this.settingsBusy, onAction: () => this.checkSettings() })
          }
          this.groupHeader('account', '账号与校园', '昵称、学校、校区和学期')
          if (this.expandedGroups.includes('account')) {
            Column({ space: 16 }) {
              this.field('昵称', this.displayName, (value) => this.displayName = value)
              this.field('学校', this.school, (value) => this.school = value)
              this.field('校区', this.campus, (value) => this.campus = value)
              this.field('学期', this.semester, (value) => this.semester = value)
              Text('这里保存校园资料；录入课程、导入和订阅请进入课表维护。')
                .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
              if (this.profileMessage.length > 0) {
                FeedbackPanel({ kind: this.profileError ? 'error' : 'info', title: '账号资料', message: this.profileMessage })
              }
              Button(this.settingsBusy ? '正在保存…' : '保存账号与校园').width('100%').constraintSize({ minHeight: 48 })
                .fontSize(AppTheme.bodySize).fontColor(AppTheme.onAccent).backgroundColor(AppTheme.accent).borderRadius(AppTheme.controlRadius)
                .enabled(!this.settingsBusy && !this.settingsNeedsCheck).onClick(() => this.saveProfile())
              Button('课表维护').width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
                .fontColor(AppTheme.accent).backgroundColor(AppTheme.accentSoft).borderRadius(AppTheme.controlRadius)
                .onClick(() => this.onOpenTimetable())
            }.width('100%').padding(AppTheme.cardInset).backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
          }
          LearningPreferencesPanel({ baseUrl: this.baseUrl, token: this.token, userId: this.user.user_id, active: this.active && !this.showHduHelpData })
          this.groupHeader('reminders', '本机系统提醒', this.reminderState.message)
          if (this.expandedGroups.includes('reminders')) {
            Column({ space: 12 }) {
              Text('仅对已确认、设置了具体时间和提前分钟数的未完成任务安排提醒。锁屏只显示通用提示，不显示任务内容。')
                .fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet).width('100%')
              FeedbackPanel({ kind: this.reminderState.phase === 'error' ? 'error' : this.reminderBusy() ? 'loading' : 'info',
                title: this.reminderState.enabled ? '本机提醒已启用' : '本机提醒状态', message: this.reminderState.message })
              Text(`系统接受 ${this.reminderState.scheduled} 项；${this.reminderState.skipped} 项因无具体提醒时间、已过期或超出一年范围未安排。`)
                .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
              if (this.reminderState.limited) {
                Text('仅安排系统容量内的近期提醒，最多 60 项，部分系统上限更低。重新打开应用或刷新核对时更新后续提醒。')
                  .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
              }
              Text('系统接受不等于已送达；通知设置、省电和系统调度可能影响提醒。退出账号会尝试清理本机提醒，后台切换不会取消。')
                .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
              if (!this.reminderState.enabled) {
                Button('启用本机提醒').width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
                  .fontColor(AppTheme.onAccent).backgroundColor(AppTheme.accent).borderRadius(AppTheme.controlRadius)
                  .enabled(!this.reminderBusy()).onClick(() => this.onEnableReminders())
              }
              Button('刷新核对').width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
                .fontColor(AppTheme.accent).backgroundColor(AppTheme.accentSoft).borderRadius(AppTheme.controlRadius)
                .enabled(!this.reminderBusy()).onClick(() => this.onRefreshReminders())
              Button('关闭并清理本机提醒').width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
                .fontColor(AppTheme.danger).backgroundColor(AppTheme.dangerSoft).borderRadius(AppTheme.controlRadius)
                .enabled(!this.reminderBusy()).onClick(() => this.onDisableReminders())
            }.width('100%').padding(AppTheme.cardInset).backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
          }
          this.groupHeader('model', '模型配置', `当前密钥 ${this.user.api_key_hint ?? '未配置'}`)
          if (this.expandedGroups.includes('model')) {
            Column({ space: 16 }) {
              this.field('新的 DeepSeek API Key', this.newApiKey, (value) => this.newApiKey = value, true)
              Text('留空保留现有密钥。保存模型配置不会提交账号与校园的未保存草稿。')
                .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
              if (this.modelMessage.length > 0) {
                FeedbackPanel({ kind: this.modelError ? 'error' : 'info', title: '模型配置', message: this.modelMessage })
              }
              Button(this.settingsBusy ? '正在保存…' : '保存新密钥').width('100%').constraintSize({ minHeight: 48 })
                .fontSize(AppTheme.bodySize).fontColor(AppTheme.onAccent).backgroundColor(AppTheme.accent).borderRadius(AppTheme.controlRadius)
                .enabled(!this.settingsBusy && !this.settingsNeedsCheck).onClick(() => this.saveModel())
            }.width('100%').padding(AppTheme.cardInset).backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
          }
          this.groupHeader('connections', '数据连接', 'HDUHelp 校园数据与课表订阅')
          if (this.expandedGroups.includes('connections')) {
        Column({ space: 12 }) {
          Row() {
            Column({ space: 4 }) {
              Text('HDUHelp 校园档案').fontSize(17).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
              Text('PAT 加密保存，也支持官方 OAuth；不提交杭电密码').fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Blank()
            Text(!this.hduHelpLoaded ? '状态待核对' : this.hduHelp.configured ? '已连接' : '未连接').fontSize(AppTheme.metaSize)
              .fontColor(this.hduHelp.configured ? AppTheme.success : AppTheme.muted)
          }.width('100%')
          if (this.hduHelpBusy) {
            FeedbackPanel({ kind: 'loading', title: '正在核对校园连接', message: '请稍候，连接操作不会重复提交。' })
          }
          Button('刷新连接状态').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
            .fontColor(AppTheme.accent).backgroundColor(AppTheme.accentSoft).enabled(!this.hduHelpBusy)
            .onClick(() => this.loadHduHelp())
          if (this.confirmDisconnect) {
            Text('确认断开后，将删除服务端同步的校园数据。').fontSize(AppTheme.metaSize).fontColor(AppTheme.danger).width('100%')
            Button('保留连接').constraintSize({ minHeight: 48 }).fontColor(AppTheme.accent)
              .backgroundColor(AppTheme.accentSoft).enabled(!this.hduHelpBusy).onClick(() => this.confirmDisconnect = false)
          }
          if (this.hduHelpMessage.length > 0) {
            Text(this.hduHelpMessage).fontSize(AppTheme.metaSize)
              .fontColor(this.hduHelpMessageIsError ? AppTheme.danger : AppTheme.accent)
              .width('100%').padding(11)
              .backgroundColor(this.hduHelpMessageIsError ? AppTheme.bg : AppTheme.accentSoft)
              .borderRadius(12)
          }
          if (this.hduHelp.configured) {
            Column({ space: 3 }) {
              Text(`${this.hduHelp.auth_mode === 'pat' ? `个人令牌 ${this.hduHelp.token_hint ?? ''}` : '官方 OAuth'} · ${this.hduHelp.external_name ?? '当前用户'}`)
                .fontSize(AppTheme.bodySize).fontColor(AppTheme.accent).width('100%')

              Text(`${this.hduHelp.resources.length} 类校园数据可供助手使用`)
                .fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%')
            }.width('100%').padding(12).backgroundColor(AppTheme.accentSoft).borderRadius(AppTheme.controlRadius)
            Row({ space: 9 }) {
              Button('同步数据').layoutWeight(1).constraintSize({ minHeight: 48 }).fontColor(AppTheme.onAccent).backgroundColor(AppTheme.accent)
                .borderRadius(AppTheme.controlRadius).enabled(this.hduHelpLoaded && !this.hduHelpBusy).onClick(() => this.syncHduHelp())
              Button(this.confirmDisconnect ? '确认断开并删除' : '断开并删除').layoutWeight(1).constraintSize({ minHeight: 48 }).fontColor(AppTheme.danger).backgroundColor(AppTheme.bg)
                .borderRadius(AppTheme.controlRadius).enabled(this.hduHelpLoaded && !this.hduHelpBusy && !this.hduHelpDataLoading).onClick(() => this.disconnectHduHelp())
            }.width('100%')
            Button('查看校园档案与推荐问题').width('100%').constraintSize({ minHeight: 48 }).fontColor(AppTheme.accent)
              .backgroundColor(AppTheme.accentSoft).borderRadius(AppTheme.controlRadius).enabled(!this.hduHelpBusy && !this.hduHelpDataLoading).onClick(() => this.openHduHelpData())
          } else {
            Text('HDUHelp 个人访问令牌').fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
            TextInput({ text: this.hduHelpPat, placeholder: 'hduhelp_pat_…' }).type(InputType.Password)
              .constraintSize({ minHeight: 48 }).backgroundColor(AppTheme.field).borderRadius(AppTheme.controlRadius)
              .enabled(!this.hduHelpBusy).onChange((value) => this.hduHelpPat = value)
            Text('令牌发送到当前配置的行简服务端，并加密保存。').fontSize(AppTheme.metaSize)
              .fontColor(AppTheme.secondary).width('100%')
            Button('使用令牌连接并同步').width('100%').constraintSize({ minHeight: 48 }).fontColor(AppTheme.onAccent)
              .backgroundColor(AppTheme.accent).borderRadius(AppTheme.controlRadius).enabled(this.hduHelpLoaded && !this.hduHelpBusy && !this.hduHelpDataLoading).onClick(() => this.connectHduHelpPat())
            Button('或使用官方 OAuth').width('100%').constraintSize({ minHeight: 48 }).fontColor(AppTheme.accent)
              .backgroundColor(AppTheme.accentSoft).borderRadius(AppTheme.controlRadius).enabled(this.hduHelpLoaded && !this.hduHelpBusy && !this.hduHelpDataLoading).onClick(() => this.connectHduHelp())
            if (this.hduHelpAuthorizeUrl.length > 0) {
              Hyperlink(this.hduHelpAuthorizeUrl, '打开 HDUHelp 官方授权页 ↗')
                .color(AppTheme.accent).width('100%')
              Button('我已授权，检查连接').width('100%').constraintSize({ minHeight: 48 }).fontColor(AppTheme.accent)
                .backgroundColor(AppTheme.accentSoft).borderRadius(AppTheme.controlRadius).enabled(!this.hduHelpBusy && !this.hduHelpDataLoading).onClick(() => this.loadHduHelp())
            }
          }
        }.width('100%').padding(AppTheme.cardInset).backgroundColor(AppTheme.surface).borderRadius(18)

        Column({ space: 12 }) {
          Row() {
            Text('课表订阅').fontSize(17).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
            Blank()
            Text(!this.subscriptionLoaded ? '状态待核对' : this.subscription.configured ? `${this.subscription.event_count} 节` : '未连接')
              .fontSize(AppTheme.metaSize).fontColor(this.subscription.configured ? AppTheme.success : AppTheme.muted)
          }.width('100%')
          if (this.subscriptionLoading) {
            FeedbackPanel({ kind: 'loading', title: '正在读取订阅状态' })
          }
          if (this.message.length > 0) {
            FeedbackPanel({ kind: this.subscriptionError ? 'error' : 'info', title: '课表订阅', message: this.message })
          }
          Button('刷新订阅状态').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
            .fontColor(AppTheme.accent).backgroundColor(AppTheme.accentSoft)
            .enabled(!this.subscriptionBusy && !this.subscriptionLoading).onClick(() => this.loadSubscription())
          Text('订阅链接').fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
          TextInput({ text: this.scheduleUrl, placeholder: '粘贴 HDUHelp 订阅链接' }).constraintSize({ minHeight: 48 })
            .backgroundColor(AppTheme.field).borderRadius(AppTheme.controlRadius).enabled(!this.subscriptionBusy)
            .onChange((value) => this.scheduleUrl = value)
          Row({ space: 9 }) {
            Button(this.subscriptionBusy ? '处理中…' : '连接新课表').layoutWeight(1).constraintSize({ minHeight: 48 })
              .fontColor(AppTheme.onAccent).backgroundColor(AppTheme.accent).enabled(!this.subscriptionBusy)
              .borderRadius(AppTheme.controlRadius).onClick(() => this.saveSubscription())
            if (this.subscription.configured) {
              Button('立即同步').layoutWeight(1).constraintSize({ minHeight: 48 }).fontColor(AppTheme.accent)
                .backgroundColor(AppTheme.accentSoft).enabled(!this.subscriptionBusy)
                .borderRadius(AppTheme.controlRadius).onClick(() => this.syncSubscription())
            }
          }.width('100%')
          if (this.timetableUpdated || this.subscriptionNeedsCheck) {
            Text(this.subscriptionNeedsCheck ? '本次同步结果尚未确认，请先核对课表再重试。' :
              '课表已更新，去计划核对冲突。已有任务的时间不会自动改变。')
              .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
            Button(this.subscriptionNeedsCheck ? '先查看当前课表' : '去计划核对冲突').width('100%').constraintSize({ minHeight: 48 })
              .fontColor(AppTheme.accent).backgroundColor(AppTheme.accentSoft)
              .enabled(!this.subscriptionBusy).borderRadius(AppTheme.controlRadius).onClick(() => { if (this.subscriptionNeedsCheck) { this.onOpenTimetable(); } else { this.onOpenPlan(); } })
          }
        }.width('100%').padding(AppTheme.cardInset).backgroundColor(AppTheme.surface).borderRadius(18)

          }
          this.groupHeader('preferences', '应用偏好', '动态效果与当前服务地址')
          if (this.expandedGroups.includes('preferences')) {
            Column({ space: 16 }) {
              Row({ space: 12 }) {
                Column({ space: 4 }) {
                  Text('减少动态效果').fontSize(AppTheme.bodySize).fontColor(AppTheme.ink)
                  Text('简化页面切换与交互动画').fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet)
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.reduceMotion }).selectedColor(AppTheme.success)
                  .onChange((value: boolean) => this.reduceMotion = value).accessibilityText('减少动态效果')
              }.width('100%').constraintSize({ minHeight: 48 })
              Text('当前服务地址').fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
              Text(this.baseUrl).fontSize(AppTheme.bodySize).fontColor(AppTheme.ink).width('100%').wordBreak(WordBreak.BREAK_ALL)
            }.width('100%').padding(AppTheme.cardInset).backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
          }
          if (this.user.role === 'admin') { this.groupHeader('admin', '用户管理', '管理员可查看的账号摘要') }
        if (this.user.role === 'admin' && this.expandedGroups.includes('admin')) {
          Column({ space: 12 }) {
            Row() {
              Text('用户管理').fontSize(17).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
              Blank()
              Text(`${this.adminUsers.length} 人`).fontSize(AppTheme.metaSize).fontColor(AppTheme.accent)
            }.width('100%')
            if (this.adminLoading) { FeedbackPanel({ kind: 'loading', title: '正在读取用户列表' }) }
            if (this.adminMessage.length > 0) {
              FeedbackPanel({ kind: 'error', title: '用户列表未更新', message: this.adminMessage, actionLabel: '重试',
                busy: this.adminLoading, onAction: () => this.loadAdminUsers() })
            }
            ForEach(this.adminUsers, (account: AdminUserSummary) => {
              Row({ space: 11 }) {
                Text(account.display_name.slice(0, 1)).fontSize(AppTheme.bodySize).fontWeight(FontWeight.Bold)
                  .fontColor(AppTheme.accent).width(36).height(36).textAlign(TextAlign.Center)
                  .backgroundColor(AppTheme.accentSoft).borderRadius(12)
                Column({ space: 3 }) {
                  Row({ space: 6 }) {
                    Text(account.display_name).fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink)
                    if (account.role === 'admin') {
                      Text('管理员').fontSize(AppTheme.metaSize).fontColor(AppTheme.onAccent).backgroundColor(AppTheme.accent)
                        .padding({ left: 5, right: 5, top: 2, bottom: 2 }).borderRadius(7)
                    }
                  }
                  Text(account.email).fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary)

                  Text(`${account.timetable_count} 节课 · ${account.campus_place_count} 个地点 · ${account.api_key_configured ? '凭据已配置' : '凭据未配置'}`)
                    .fontSize(AppTheme.metaSize).fontColor(AppTheme.muted)
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              }.width('100%')
            }, (account: AdminUserSummary) => account.user_id)
          }.width('100%').padding(AppTheme.cardInset).backgroundColor(AppTheme.surface).borderRadius(18)
        }

          Button('退出登录').width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
            .fontColor(AppTheme.danger).backgroundColor(AppTheme.dangerSoft).borderRadius(AppTheme.controlRadius)
            .onClick(() => this.onLogout())
        }.width('100%').alignItems(HorizontalAlign.Start)
          .padding({ left: AppTheme.pageInset, right: AppTheme.pageInset, top: 16, bottom: 24 })
      }.width('100%').height('100%').backgroundColor(AppTheme.canvas)
        .visibility(this.showHduHelpData ? Visibility.Hidden : Visibility.Visible)
      if (this.showHduHelpData) { this.hduHelpDataView() }
    }.width('100%').height('100%')
  }
}
