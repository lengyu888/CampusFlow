import { AuthResponse, UserProfile } from '../model/ApiModels';
import { CampusFlowApi } from '../services/CampusFlowApi';
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

@Entry
@Component
struct Index {
  @StorageLink('apiBaseUrl') private baseUrl: string = 'http://127.0.0.1:8000';
  @State private token: string = '';
  @State private activeTab: number = 0;
  @State private agentPrompt: string = '';
  @State private promptRevision: number = 0;
  @State private homeRefresh: number = 0;
  @State private planRefresh: number = 0;
  @State private returnTab: number = 0;
  @State private contentOpacity: number = 1;
  @State private contentOffset: number = 0;
  @State private user: UserProfile = {
    user_id: '', email: '', display_name: '', school: null, campus: null, semester: null,
    onboarding_complete: false, role: 'user', api_key_configured: false, api_key_hint: null
  };

  aboutToAppear(): void {
    PersistentStorage.persistProp('reduceMotion', false);
  }

  onBackPress(): boolean {
    if (this.activeTab > 4) {
      this.selectTab(this.returnTab);
      return true;
    }
    return false;
  }

  private authenticated(auth: AuthResponse): void {
    this.token = auth.access_token;
    this.user = auth.user;
  }

  private async logout(): Promise<void> {
    try {
      await new CampusFlowApi(this.baseUrl, this.token).logout();
    } catch {
      // Local sign-out must remain available when the service is temporarily unreachable.
    } finally {
      this.token = '';
      this.activeTab = 0;
    }
  }

  private selectTab(tab: number): void {
    if (tab === this.activeTab) {
      return;
    }
    if (tab > 4 && this.activeTab <= 4) {
      this.returnTab = this.activeTab;
    }
    this.activeTab = tab;
    if (tab === 0) {
      this.homeRefresh++;
    } else if (tab === 2) {
      this.planRefresh++;
    }
    const duration = AppTheme.motion(220);
    this.contentOpacity = duration === 0 ? 1 : 0.6;
    this.contentOffset = duration === 0 ? 0 : 5;
    this.getUIContext().animateTo({ duration: duration, curve: Curve.EaseOut }, () => {
      this.contentOpacity = 1;
      this.contentOffset = 0;
    });
  }

  private openAgentWithPrompt(prompt: string): void {
    this.agentPrompt = prompt;
    this.promptRevision++;
    this.selectTab(1);
  }

  @Builder
  private pageContent() {
    Stack({ alignContent: Alignment.TopStart }) {
      HomePage({ baseUrl: this.baseUrl, token: this.token, user: this.user,
        refreshKey: this.homeRefresh,
        onOpenAgent: () => this.selectTab(1), onOpenPlan: () => this.selectTab(2),
        onOpenRoute: () => this.selectTab(6),
        onOpenServices: () => this.selectTab(7), onOpenProfile: () => this.selectTab(4) })
        .visibility(this.activeTab === 0 ? Visibility.Visible : Visibility.Hidden)
      AgentPage({ baseUrl: this.baseUrl, token: this.token, initialPrompt: this.agentPrompt,
        promptRevision: this.promptRevision,
        onOpenHistory: () => this.selectTab(5), onOpenRoute: () => this.selectTab(6),
        onOpenPlan: () => this.selectTab(2) })
        .visibility(this.activeTab === 1 ? Visibility.Visible : Visibility.Hidden)
      PlanCenterPage({ baseUrl: this.baseUrl, token: this.token,
        refreshKey: this.planRefresh,
        onOpenAgent: (prompt) => this.openAgentWithPrompt(prompt) })
        .visibility(this.activeTab === 2 ? Visibility.Visible : Visibility.Hidden)
      SkillsPage({ baseUrl: this.baseUrl, token: this.token })
        .visibility(this.activeTab === 3 ? Visibility.Visible : Visibility.Hidden)
      ProfilePage({ baseUrl: this.baseUrl, token: this.token, user: this.user,
        onUserChanged: (updated) => this.user = updated, onLogout: () => this.logout(),
        onOpenAgent: (prompt) => this.openAgentWithPrompt(prompt) })
        .visibility(this.activeTab === 4 ? Visibility.Visible : Visibility.Hidden)
      if (this.activeTab === 5) {
        HistoryPage({ baseUrl: this.baseUrl, token: this.token, onBack: () => this.selectTab(this.returnTab) })
      } else if (this.activeTab === 6) {
        RoutePage({ baseUrl: this.baseUrl, token: this.token, onBack: () => this.selectTab(this.returnTab) })
      } else if (this.activeTab === 7) {
        CampusServicesPage({ baseUrl: this.baseUrl, token: this.token, onBack: () => this.selectTab(this.returnTab),
          onOpenAgent: (prompt) => this.openAgentWithPrompt(prompt) })
      }
    }.width('100%').height('100%')
  }

  @Builder
  private navItem(tab: number, icon: string, label: string) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 4 }) {
        AppIcon({ name: icon, iconSize: 23,
          color: this.selectedTab() === tab ? AppTheme.blue : AppTheme.secondary })
        Text(label).fontSize(10).fontWeight(this.selectedTab() === tab ? FontWeight.Medium : FontWeight.Regular)
          .fontColor(this.selectedTab() === tab ? AppTheme.blue : AppTheme.secondary)
      }.height(52).justifyContent(FlexAlign.Center)
    }.layoutWeight(1).height(56).backgroundColor(Color.Transparent).borderRadius(16)
      .accessibilityText(`${label}${this.selectedTab() === tab ? '，已选中' : ''}`)
      .onClick(() => this.selectTab(tab))
  }

  private selectedTab(): number {
    return this.activeTab <= 4 ? this.activeTab : this.returnTab;
  }

  build() {
    if (this.token.length === 0) {
      LoginPage({
        baseUrl: this.baseUrl,
        onBaseUrlChange: (value) => this.baseUrl = value,
        onAuthenticated: (auth) => this.authenticated(auth)
      })
    } else if (!this.user.onboarding_complete) {
      OnboardingPage({ baseUrl: this.baseUrl, token: this.token,
        onCompleted: (updated) => this.user = updated })
    } else {
      Column() {
        Column() {
          this.pageContent()
        }.layoutWeight(1).width('100%').clip(true)
          .opacity(this.contentOpacity).translate({ y: this.contentOffset })
        Row() {
          this.navItem(0, 'home', '今日')
          this.navItem(1, 'agent', 'Agent')
          this.navItem(2, 'calendar', '规划')
          this.navItem(3, 'skills', 'Skills')
          this.navItem(4, 'person', '我的')
        }
        .width('100%').height(64)
        .padding({ left: 10, right: 10, bottom: 4 })
        .backgroundColor('#F9FFFFFF').backgroundBlurStyle(BlurStyle.Thin)
        .border({ width: { top: 0.5 }, color: AppTheme.separator })
      }.width('100%').height('100%').backgroundColor(AppTheme.bg)
    }
  }
}
