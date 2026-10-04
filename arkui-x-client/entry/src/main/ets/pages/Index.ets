import { AuthResponse, UserProfile } from '../model/ApiModels';
import { AgentPage } from './AgentPage';
import { HomePage } from './HomePage';
import { LoginPage } from './LoginPage';
import { OnboardingPage } from './OnboardingPage';
import { PlanPage } from './PlanPage';
import { ProfilePage } from './ProfilePage';
import { SkillsPage } from './SkillsPage';

@Entry
@Component
struct Index {
  @StorageLink('apiBaseUrl') private baseUrl: string = 'http://127.0.0.1:8000';
  @State private token: string = '';
  @State private activeTab: number = 0;
  @State private user: UserProfile = {
    user_id: '', email: '', display_name: '', school: null, campus: null, semester: null,
    onboarding_complete: false, role: 'user', api_key_configured: false, api_key_hint: null
  };

  private authenticated(auth: AuthResponse): void {
    this.token = auth.access_token;
    this.user = auth.user;
  }

  private logout(): void {
    this.token = '';
    this.activeTab = 0;
  }

  private selectTab(tab: number): void {
    animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
      this.activeTab = tab;
    });
  }

  @Builder
  private pageContent() {
    if (this.activeTab === 0) {
      HomePage({ baseUrl: this.baseUrl, token: this.token, user: this.user,
        onOpenAgent: () => this.selectTab(1) })
    } else if (this.activeTab === 1) {
      AgentPage({ baseUrl: this.baseUrl, token: this.token })
    } else if (this.activeTab === 2) {
      PlanPage({ baseUrl: this.baseUrl, token: this.token })
    } else if (this.activeTab === 3) {
      SkillsPage({ baseUrl: this.baseUrl, token: this.token })
    } else {
      ProfilePage({ baseUrl: this.baseUrl, token: this.token, user: this.user,
        onUserChanged: (updated) => this.user = updated, onLogout: () => this.logout() })
    }
  }

  @Builder
  private navItem(tab: number, icon: string, label: string) {
    Column({ space: 3 }) {
      Text(icon).fontSize(18).fontColor(this.activeTab === tab ? '#315BFF' : '#9BA1AF')
        .scale({ x: this.activeTab === tab ? 1.12 : 1, y: this.activeTab === tab ? 1.12 : 1 })
      Text(label).fontSize(10).fontWeight(this.activeTab === tab ? FontWeight.Bold : FontWeight.Regular)
        .fontColor(this.activeTab === tab ? '#315BFF' : '#9BA1AF')
    }
    .layoutWeight(1).height(58).justifyContent(FlexAlign.Center)
    .onClick(() => this.selectTab(tab))
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
      Stack({ alignContent: Alignment.Bottom }) {
        this.pageContent()
        Row() {
          this.navItem(0, '⌂', '今日')
          this.navItem(1, '✦', 'Agent')
          this.navItem(2, '✓', '规划')
          this.navItem(3, '◇', 'Skills')
          this.navItem(4, '○', '我的')
        }
        .width('100%').height(74)
        .padding({ left: 6, right: 6, bottom: 8 })
        .backgroundColor('#FFFFFF')
        .border({ width: { top: 1 }, color: '#E8EBF2' })
      }.width('100%').height('100%').backgroundColor('#F5F7FB')
    }
  }
}
