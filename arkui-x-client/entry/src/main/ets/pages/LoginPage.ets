import { AuthResponse } from '../model/ApiModels';
import { CampusFlowApi } from '../services/CampusFlowApi';
import { AppTheme } from '../theme/AppTheme';
import { FeedbackPanel } from '../components/FeedbackPanel';
import { CampusFlowRequestError } from '../utils/AgentFeedback';

@Component
export struct LoginPage {
  @Prop baseUrl: string;
  @Prop localHistoryCount: number = 0;
  @Prop localDisplayName: string = '';
  @Prop cacheNotice: string = '';
  @Prop cleanupNeeded: boolean = false;
  onClearLocalHistory: () => Promise<void> = async () => {};
  onAuthenticated: (auth: AuthResponse) => Promise<void> = async () => {};
  onOpenLocalHistory: () => void = () => {};
  onBaseUrlChange: (baseUrl: string) => void = () => {};
  @State private registerMode: boolean = false;
  @State private email: string = '';
  @State private password: string = '';
  @State private displayName: string = '';
  @State private apiKey: string = '';
  @State private loading: boolean = false;
  @State private errorText: string = '';
  @State private confirmCleanup: boolean = false;

  private pageActive: boolean = true;
  private requestRevision: number = 0;

  aboutToAppear(): void { this.pageActive = true; }
  aboutToDisappear(): void { this.pageActive = false; this.requestRevision++; }

  private failure(error: Error): string {
    if (error instanceof CampusFlowRequestError) {
      if (error.statusCode === 401 || error.statusCode === 403) { return '邮箱、密码或权限未通过校验，请检查后重试。'; }
      if (error.statusCode === 409) { return '此邮箱已注册，请切换到登录。'; }
      if (error.statusCode === 422) { return '填写内容未通过校验，请检查邮箱、密码和必填项。'; }
    }
    return '连接未完成，请检查服务地址和网络后重试。输入内容已保留。';
  }

  private async clearLocalHistory(): Promise<void> {
    if (!this.pageActive || this.loading || !this.confirmCleanup) { return; }
    const revision = ++this.requestRevision;
    this.loading = true;
    try { await this.onClearLocalHistory(); }
    catch { if (this.pageActive && revision === this.requestRevision) { this.errorText = '本机记录未能清除，请重试。'; } }
    finally { if (this.pageActive && revision === this.requestRevision) { this.loading = false; this.confirmCleanup = false; } }
  }

  private async submit(): Promise<void> {
    if (!this.pageActive || this.loading) { return; }
    if (this.email.length < 5 || this.password.length < 8) {
      this.errorText = '请输入有效邮箱，密码至少 8 位。';
      return;
    }
    if (this.registerMode && (this.displayName.length === 0 || this.apiKey.length === 0)) {
      this.errorText = '注册时需要填写昵称和 DeepSeek API Key。';
      return;
    }
    const revision = ++this.requestRevision;
    this.loading = true;
    this.errorText = '';
    try {
      const api = new CampusFlowApi(this.baseUrl);
      const auth = this.registerMode
        ? await api.register(this.email, this.password, this.displayName, this.apiKey)
        : await api.login(this.email, this.password);
      if (!this.pageActive || revision !== this.requestRevision) { return; }
      await this.onAuthenticated(auth);
    } catch (error) {
      if (this.pageActive && revision === this.requestRevision) { this.errorText = this.failure(error); }
    } finally {
      if (this.pageActive && revision === this.requestRevision) { this.loading = false; }
    }
  }

  @Builder
  private inputField(label: string, hint: string, value: string, onChange: (value: string) => void,
    inputType: InputType = InputType.Normal) {
    Column({ space: 7 }) {
      Text(label).fontSize(AppTheme.bodySize).fontColor(AppTheme.secondary).fontWeight(FontWeight.Medium).width('100%')
      TextInput({ placeholder: hint, text: value })
        .type(inputType)
        .constraintSize({ minHeight: 52 })
        .fontSize(AppTheme.bodySize)
        .backgroundColor(AppTheme.field)
        .borderRadius(AppTheme.controlRadius)
        .padding({ left: 16, right: 16 })
        .enabled(!this.loading)
        .onChange(onChange)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Scroll() {
      Column({ space: 22 }) {
        Column({ space: 8 }) {
          Text('行简').fontSize(AppTheme.pageTitle).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
          Text('登录后，把课表和待办安排在一起。').fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet)
        }.width('100%').alignItems(HorizontalAlign.Start)

        Column({ space: 16 }) {
          Text(this.registerMode ? '创建账号' : '登录账号')
            .fontSize(AppTheme.sectionTitle).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink).width('100%')
          if (this.registerMode) {
            this.inputField('昵称', '你的称呼', this.displayName, (value) => this.displayName = value)
          }
          this.inputField('服务地址', 'http://局域网IP:8000', this.baseUrl, (value) => this.onBaseUrlChange(value))
          this.inputField('邮箱', 'name@example.com', this.email, (value) => this.email = value, InputType.Email)
          this.inputField('密码', '至少 8 位', this.password, (value) => this.password = value, InputType.Password)
          if (this.registerMode) {
            this.inputField('DeepSeek API Key', 'sk-…（服务端加密保存）', this.apiKey,
              (value) => this.apiKey = value, InputType.Password)
          }
          if (this.errorText.length > 0) {
            FeedbackPanel({ kind: 'error', title: '暂未完成', message: this.errorText })
          }
          Button(this.loading ? '连接中…' : (this.registerMode ? '注册并继续' : '登录'))
            .width('100%').constraintSize({ minHeight: 52 }).fontSize(AppTheme.bodySize).fontWeight(FontWeight.Bold)
            .fontColor(AppTheme.onAccent).backgroundColor(AppTheme.accent).borderRadius(AppTheme.controlRadius)
            .enabled(!this.loading)
            .onClick(() => this.submit())
          Button(this.registerMode ? '已有账号，直接登录' : '第一次使用？创建账号')
            .width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize).fontColor(AppTheme.accent)
            .backgroundColor(Color.Transparent)
            .enabled(!this.loading)
            .onClick(() => {
              this.getUIContext().animateTo({ duration: AppTheme.motion(200), curve: Curve.EaseOut }, () => {
                this.registerMode = !this.registerMode;
                this.errorText = '';
              });
            })
        }
        .width('100%')
        .padding(AppTheme.cardInset)
        .backgroundColor(AppTheme.surface)
        .borderRadius(AppTheme.cardRadius)

        if (this.localHistoryCount > 0) {
          Column({ space: 8 }) {
            Text(`${this.localDisplayName} · 本机已保存 ${this.localHistoryCount} 个会话`)
              .fontSize(AppTheme.bodySize).fontColor(AppTheme.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
            Button('离线查看本机对话').constraintSize({ minHeight: 48 }).width('100%')
              .fontSize(AppTheme.bodySize).fontColor(AppTheme.accent).backgroundColor(AppTheme.accentSoft)
              .enabled(!this.loading).onClick(() => this.onOpenLocalHistory())
            Text('仅查看已保存的文字，不会登录或发送请求。解锁此设备的人可查看；退出账号会清除本机记录。')
              .fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%')
          }.width('100%').alignItems(HorizontalAlign.Start)
        }
        if (this.cacheNotice.length > 0) {
          Text(this.cacheNotice).fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%')
        }
        if (this.cleanupNeeded) {
          if (this.confirmCleanup) {
            Text('清除本机记录不会删除服务端会话。清除后需联网重新保存。')
              .fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%')
            Button('确认清除本机记录').constraintSize({ minHeight: 48 }).width('100%')
              .fontColor(AppTheme.danger).backgroundColor(AppTheme.surface).enabled(!this.loading)
              .onClick(() => this.clearLocalHistory())
            Button('保留').constraintSize({ minHeight: 48 }).enabled(!this.loading)
              .onClick(() => this.confirmCleanup = false)
          } else {
            Button('清理本机记录后重试').constraintSize({ minHeight: 48 }).width('100%')
              .fontColor(AppTheme.accent).backgroundColor(AppTheme.accentSoft).enabled(!this.loading)
              .onClick(() => this.confirmCleanup = true)
          }
        }
        Text('登录后自动使用已保存的模型配置，无需重复填写 API Key。')
          .fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).textAlign(TextAlign.Center)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start).justifyContent(FlexAlign.Start)
      .padding({ left: 20, right: 20, top: 24, bottom: 32 })
    }
    .width('100%').height('100%').backgroundColor(AppTheme.bg)
  }
}
