import { KeyboardAvoidMode } from '@ohos.arkui.UIContext';
import { AuthResponse, UserProfile } from '../model/ApiModels';
import { CampusFlowApi } from '../services/CampusFlowApi';
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
import { AppNavigationState, createNavigation, currentRoute, selectRoot, openSecondary, backNavigation, isRootRoute, hasBack } from '../utils/AppNavigation';

@Entry
@Component
struct Index {
  @StorageLink('apiBaseUrl') private baseUrl: string = 'http://127.0.0.1:8000';
  @StorageLink('voiceForeground') private voiceForeground: boolean = true;
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
  @State private activeTab: number = 0;
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
  @State private planInnerActive: boolean = false;
  private focusOrigin: AppNavigationState | null = null;
  @State private contentOpacity: number = 1;
  @State private contentOffset: number = 0;
  @State private user: UserProfile = {
    user_id: '', email: '', display_name: '', school: null, campus: null, semester: null,
    onboarding_complete: false, role: 'user', api_key_configured: false, api_key_hint: null
  };

  aboutToAppear(): void {
    PersistentStorage.persistProp('reduceMotion', false);
    // Resize the flex layout so the composer remains above the system keyboard.
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    this.refreshLocalHistory();
    this.cacheNotice = AppStorage.get<string>('localHistoryError') ?? '';
    this.cleanupNeeded = this.cacheNotice.length > 0;
  }

  onBackPress(): boolean {
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
    this.offlineHistory = false;
    this.cacheNotice = '';
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
    this.user = auth.user;
    this.resetNavigation();
    this.agentPrompt = '';
    this.token = auth.access_token;
    this.agentChatBusy = false;
    this.historyDeleteBusy = false;
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
    const api = new CampusFlowApi(this.baseUrl, this.token);
    this.token = '';
    this.cacheScope = '';
    this.localHistoryCount = 0;
    this.offlineHistory = false;
    this.resetNavigation();
    this.agentPrompt = '';
    this.agentChatBusy = false;
    this.historyDeleteBusy = false;
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
  }

  private resetNavigation(): void {
    this.navigation = createNavigation();
    this.activeTab = 0;
    this.focusTaskId = '';
    this.focusPlanId = '';
    this.focusRevision++;
    this.focusOrigin = null;
    this.planRequestedView = '';
    this.planViewRevision++;
    this.planInnerActive = false;
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

  private selectTab(tab: number): void {
    this.applyNavigation(isRootRoute(tab) ? selectRoot(this.navigation, tab) : openSecondary(this.navigation, tab));
  }

  private goBack(): void {
    this.applyNavigation(backNavigation(this.navigation));
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
      HomePage({ baseUrl: this.baseUrl, token: this.token, user: this.user,
        refreshKey: this.homeRefresh, active: this.activeTab === 0 && this.voiceForeground,
        onOpenAgent: () => this.applyNavigation(selectRoot(this.navigation, 1, true)),
        onOpenPlan: (view) => this.openPlanList(view),
        onOpenTaskDetails: (id) => this.openPlanDetails(id, ''),
        onOpenPlanDetails: (id) => this.openPlanDetails('', id),
        onOpenRoute: () => this.selectTab(6),
        onOpenServices: () => this.selectTab(7), onOpenProfile: () => this.selectTab(4) })
        .visibility(this.activeTab === 0 ? Visibility.Visible : Visibility.Hidden)
      AgentPage({ baseUrl: this.baseUrl, token: this.token, initialPrompt: this.agentPrompt,
        voiceActive: this.activeTab === 1 && this.voiceForeground,
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
      PlanCenterPage({ baseUrl: this.baseUrl, token: this.token,
        refreshKey: this.planRefresh, active: this.activeTab === 2 && this.voiceForeground,
        focusTaskId: this.focusTaskId, focusPlanId: this.focusPlanId, focusRevision: this.focusRevision,
        requestedView: this.planRequestedView, viewRevision: this.planViewRevision,
        backRevision: this.planBackRevision, onInnerNavigationChanged: (active) => this.planInnerActive = active,
        onCloseFocus: () => this.closePlanFocus(),
        onPlanningChanged: () => this.homeRefresh++,
        onOpenAgent: (prompt) => this.openAgentWithPrompt(prompt) })
        .visibility(this.activeTab === 2 ? Visibility.Visible : Visibility.Hidden)
      CampusPage({ user: this.user, baseUrl: this.baseUrl, token: this.token, active: this.activeTab === 8 && this.voiceForeground,
        onOpenTimetable: () => this.selectTab(9), onOpenRoute: () => this.selectTab(6),
        onOpenServices: () => this.selectTab(7), onOpenSkills: () => this.selectTab(3),
        onOpenProfile: () => this.selectTab(4), onOpenAgent: (prompt) => this.openAgentWithPrompt(prompt) })
        .visibility(this.activeTab === 8 ? Visibility.Visible : Visibility.Hidden)
      Column() {
        this.SecondaryHeader('能力管理')
        Column() { SkillsPage({ baseUrl: this.baseUrl, token: this.token, active: this.activeTab === 3 && this.voiceForeground }) }.layoutWeight(1).width('100%')
      }.width('100%').height('100%').visibility(this.activeTab === 3 ? Visibility.Visible : Visibility.Hidden)
      Column() {
        this.SecondaryHeader('个人设置')
        Column() {
          ProfilePage({ baseUrl: this.baseUrl, token: this.token, user: this.user,
            active: this.activeTab === 4 && this.voiceForeground, onOpenTimetable: () => this.selectTab(9),
            onUserChanged: (updated) => this.user = updated, onLogout: () => this.logout(),
            onTimetableChanged: () => this.timetableChanged(), onOpenPlan: () => this.openPlanList(),
            onOpenAgent: (prompt) => this.openAgentWithPrompt(prompt) })
        }.layoutWeight(1).width('100%')
      }.width('100%').height('100%').visibility(this.activeTab === 4 ? Visibility.Visible : Visibility.Hidden)
      if (this.activeTab === 5) {
        HistoryPage({ baseUrl: this.baseUrl, token: this.token, historyScope: this.cacheScope,
          chatBusy: this.agentChatBusy,
          remoteDeleteBusy: this.historyDeleteBusy,
          accountRevision: this.authRevision,
          onSessionDeleted: (id, revision) => this.sessionDeleted(id, revision),
          onDeleteBusyChange: (busy, revision) => this.deletionBusyChanged(busy, revision),
          onBack: () => this.goBack() })
      }
      RoutePage({ baseUrl: this.baseUrl, token: this.token, active: this.activeTab === 6 && this.voiceForeground,
        onBack: () => this.goBack() })
        .visibility(this.activeTab === 6 ? Visibility.Visible : Visibility.Hidden)
      CampusServicesPage({ baseUrl: this.baseUrl, token: this.token, active: this.activeTab === 7 && this.voiceForeground,
        onBack: () => this.goBack(), onOpenProfile: () => this.selectTab(4),
        onOpenAgent: (prompt) => this.openAgentWithPrompt(prompt) })
        .visibility(this.activeTab === 7 ? Visibility.Visible : Visibility.Hidden)
      TimetablePage({ baseUrl: this.baseUrl, token: this.token, active: this.activeTab === 9 && this.voiceForeground,
        onBack: () => this.goBack(), onTimetableChanged: () => this.timetableChanged(),
        onOpenPlan: () => this.openPlanList('agenda') })
        .visibility(this.activeTab === 9 ? Visibility.Visible : Visibility.Hidden)
    }.width('100%').height('100%')
  }

  @Builder
  private SecondaryHeader(title: string) {
    Row({ space: 8 }) {
      Button({ type: ButtonType.Normal }) {
        AppIcon({ name: 'back', iconSize: 22, color: AppTheme.actionBlue })
      }.width(48).height(48).backgroundColor(Color.Transparent).borderRadius(AppTheme.controlRadius)
        .accessibilityText('返回上一页').onClick(() => this.goBack())
      Text(title).fontSize(18).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink).layoutWeight(1)
    }.width('100%').padding({ left: 8, right: 20, top: 4, bottom: 4 }).backgroundColor(AppTheme.surface)
      .border({ width: { bottom: 1 }, color: AppTheme.line })
  }

  @Builder
  private navItem(tab: number, icon: string, label: string) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 4 }) {
        AppIcon({ name: icon, iconSize: 23,
          color: this.selectedTab() === tab ? AppTheme.blue : AppTheme.secondary })
        Text(label).fontSize(12).fontWeight(this.selectedTab() === tab ? FontWeight.Medium : FontWeight.Regular)
          .fontColor(this.selectedTab() === tab ? AppTheme.blue : AppTheme.secondary)
      }.height(52).justifyContent(FlexAlign.Center)
    }.layoutWeight(1).height(56).backgroundColor(Color.Transparent).borderRadius(16)
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
      LoginPage({
        baseUrl: this.baseUrl,
        localHistoryCount: this.localHistoryCount, localDisplayName: this.localDisplayName,
        cacheNotice: this.cacheNotice,
        cleanupNeeded: this.cleanupNeeded, onClearLocalHistory: () => this.clearLocalHistory(),
        onOpenLocalHistory: () => this.offlineHistory = true,
        onBaseUrlChange: (value) => this.baseUrl = value,
        onAuthenticated: (auth) => this.authenticated(auth)
      })
    } else if (!this.user.onboarding_complete) {
      OnboardingPage({ baseUrl: this.baseUrl, token: this.token,
        onCompleted: (updated) => this.user = updated, onReturnToLogin: () => this.logout() })
    } else {
      Column() {
        Column() {
          this.pageContent()
        }.layoutWeight(1).width('100%').clip(true)
          .opacity(this.contentOpacity).translate({ y: this.contentOffset })
        if (isRootRoute(this.activeTab) && !(this.activeTab === 2 && this.planInnerActive)) {
          Row() {
            this.navItem(0, 'home', '今日')
            this.navItem(1, 'agent', 'Agent')
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
