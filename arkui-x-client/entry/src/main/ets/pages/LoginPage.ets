import { AuthResponse } from '../model/ApiModels';
import { CampusFlowApi } from '../services/CampusFlowApi';
import { AppTheme } from '../theme/AppTheme';
import { ThemePalette, themePalette } from '../theme/ThemePalette';
import { FeedbackPanel } from '../components/FeedbackPanel';
import { CampusFlowRequestError } from '../utils/AgentFeedback';
import { InfoDisclosure } from '../components/InfoDisclosure';
import { ConnectionCheckPanel } from '../components/ConnectionCheckPanel';
import { normalizeServiceBaseUrl } from '../utils/SessionPersistence';

@Component
export struct LoginPage {
  @StorageLink('campusflowThemePalette') private palette: ThemePalette = themePalette('paper-green');
  @Prop baseUrl: string;
  @Prop localHistoryCount: number = 0;
  @Prop localDisplayName: string = '';
  @Prop cacheNotice: string = '';
  @Prop cleanupNeeded: boolean = false;
  onClearLocalHistory: () => Promise<void> = async () => {};
  @Prop restoreBusy: boolean = false;
  @Prop restoreNotice: string = '';
  @Prop canRetryRestore: boolean = false;
  onRetryRestore: () => void = () => {};
  onAuthenticationStarted: () => void = () => {};
  onAuthenticated: (auth: AuthResponse, requestBase: string, remember: boolean) => Promise<void> = async () => {};
  onOpenLocalHistory: () => void = () => {};
  onBaseUrlChange: (baseUrl: string) => void = () => {};
  @State private registerMode: boolean = false;
  @State private email: string = '';
  @State private password: string = '';
  @State private displayName: string = '';
  @State private apiKey: string = '';
  @State private showModelConfig: boolean = false;
  @State private loading: boolean = false;
  @State private errorText: string = '';
  @State private confirmCleanup: boolean = false;
  @State private rememberLogin: boolean = true;

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
    if (!this.pageActive || this.loading || this.restoreBusy) { return; }
    const requestBase = normalizeServiceBaseUrl(this.baseUrl);
    if (requestBase === null) { this.errorText = '服务地址格式不正确，请检查地址与端口。'; return; }
    if (this.email.length < 5 || this.password.length < 8) {
      this.errorText = '请输入有效邮箱，密码至少 8 位。';
      return;
    }
    if (this.registerMode && this.displayName.trim().length === 0) {
      this.errorText = '请填写昵称，模型配置可以稍后设置。';
      return;
    }
    const revision = ++this.requestRevision;
    this.loading = true;
    this.errorText = '';
    const remember = this.rememberLogin;
    this.onAuthenticationStarted();
    try {
      const api = new CampusFlowApi(requestBase);
      const auth = this.registerMode
        ? await api.register(this.email, this.password, this.displayName,
          this.apiKey.trim().length > 0 ? this.apiKey : undefined)
        : await api.login(this.email, this.password);
      if (!this.pageActive || revision !== this.requestRevision) { return; }
      if (normalizeServiceBaseUrl(this.baseUrl) !== requestBase) {
        this.errorText = '服务地址已变化，本次未登录。请核对后重试。'; return;
      }
      await this.onAuthenticated(auth, requestBase, remember);
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
      Text(label).fontSize(this.palette.bodySize).fontColor(this.palette.secondary).fontWeight(FontWeight.Medium).width('100%')
      TextInput({ placeholder: hint, text: value })
        .type(inputType)
        .constraintSize({ minHeight: 52 })
        .fontSize(this.palette.bodySize)
        .backgroundColor(this.palette.field)
        .borderRadius(this.palette.controlRadius)
        .padding({ left: 16, right: 16 })
        .enabled(!this.loading && !this.restoreBusy)
        .onChange(onChange)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Scroll() {
      Column({ space: 24 }) {
        Column({ space: 8 }) {
          Text('行简').fontSize(this.palette.pageTitle).fontWeight(FontWeight.Bold).fontColor(this.palette.ink)
          Text('安排今天，专心完成。').fontSize(this.palette.bodySize).fontColor(this.palette.quiet)
        }.width('100%').alignItems(HorizontalAlign.Start)

        Column({ space: 16 }) {
          Text(this.registerMode ? '创建账号' : '登录账号')
            .fontSize(this.palette.sectionTitle).fontWeight(FontWeight.Bold).fontColor(this.palette.ink).width('100%')
          if (this.registerMode) {
            this.inputField('昵称', '你的称呼', this.displayName, (value) => this.displayName = value)
          }
          this.inputField('服务地址', 'http://局域网IP:8000', this.baseUrl, (value) => this.onBaseUrlChange(value))
          ConnectionCheckPanel({ baseUrl: this.baseUrl, active: !this.loading && !this.restoreBusy })
          this.inputField('邮箱', 'name@example.com', this.email, (value) => this.email = value, InputType.Email)
          this.inputField('密码', '至少 8 位', this.password, (value) => this.password = value, InputType.Password)
          Row({ space: 10 }) {
            Checkbox({ name: 'rememberLogin' }).select(this.rememberLogin)
              .selectedColor(this.palette.accent).enabled(!this.loading && !this.restoreBusy)
              .onChange((value: boolean) => this.rememberLogin = value)
            Column({ space: 3 }) {
              Text('保持登录').fontSize(this.palette.bodySize).fontColor(this.palette.ink).width('100%')
              Text('使用系统安全存储，不保存密码').fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
            }.layoutWeight(1)
          }.width('100%').constraintSize({ minHeight: 48 })
          if (this.restoreBusy) {
            FeedbackPanel({ kind: 'loading', title: '正在恢复登录', message: '正在原服务核验账号，请稍候。' })
          } else if (this.restoreNotice.length > 0) {
            FeedbackPanel({ kind: 'info', title: '登录状态', message: this.restoreNotice })
            if (this.canRetryRestore) {
              Button('重试恢复登录').width('100%').constraintSize({ minHeight: 48 })
                .fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft).enabled(!this.loading)
                .onClick(() => this.onRetryRestore())
            }
          }
          if (this.registerMode) {
            Text('先确认校园与课表，再安排每天的待办。模型密钥可以稍后添加。')
              .fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
            Button(this.showModelConfig ? '收起模型配置（可选）' : '现在配置模型（可选）')
              .width('100%').constraintSize({ minHeight: 44 }).fontSize(this.palette.bodySize)
              .fontColor(this.palette.accent).backgroundColor(Color.Transparent)
              .enabled(!this.loading).onClick(() => this.showModelConfig = !this.showModelConfig)
            if (this.showModelConfig) {
              this.inputField('DeepSeek API Key（可选）', 'sk-…（服务端加密保存）', this.apiKey,
                (value) => this.apiKey = value, InputType.Password)
              Text('填写后会随注册保存；只做输入校验，不会在注册时调用模型。')
                .fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
            } else if (this.apiKey.trim().length > 0) {
              Text('已填写模型密钥，将随注册保存；展开可修改或清空。')
                .fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
            }
            InfoDisclosure({ title: '模型配置有什么用？', message: '手动维护课表、待办和专注不需要模型密钥。助手对话与图片识别需要可用的模型配置，可在我的 → 模型连接中添加。密钥只发送到当前配置的行简服务端并加密保存。' })
          }
          if (this.errorText.length > 0) {
            FeedbackPanel({ kind: 'error', title: '暂未完成', message: this.errorText })
          }
          Button(this.loading ? '连接中…' : (this.registerMode ? '注册并继续' : '登录'))
            .width('100%').constraintSize({ minHeight: 52 }).fontSize(this.palette.bodySize).fontWeight(FontWeight.Bold)
            .fontColor(this.palette.onAccent).backgroundColor(this.palette.accent).borderRadius(this.palette.controlRadius)
            .enabled(!this.loading && !this.restoreBusy)
            .onClick(() => this.submit())
          Button(this.registerMode ? '已有账号，直接登录' : '第一次使用？创建账号')
            .width('100%').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize).fontColor(this.palette.accent)
            .backgroundColor(Color.Transparent)
            .enabled(!this.loading && !this.restoreBusy)
            .onClick(() => {
              this.getUIContext().animateTo({ duration: AppTheme.motion(200), curve: Curve.EaseOut }, () => {
                this.registerMode = !this.registerMode;
                this.errorText = '';
              });
            })
        }
        .width('100%')
        .padding(this.palette.cardInset)
        .backgroundColor(this.palette.surface)
        .borderRadius(this.palette.cardRadius)

        if (this.localHistoryCount > 0) {
          Column({ space: 8 }) {
            Text(`${this.localDisplayName} · 本机已保存 ${this.localHistoryCount} 个会话`)
              .fontSize(this.palette.bodySize).fontColor(this.palette.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
            Button('离线查看本机对话').constraintSize({ minHeight: 48 }).width('100%')
              .fontSize(this.palette.bodySize).fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft)
              .enabled(!this.loading).onClick(() => this.onOpenLocalHistory())
            Text('仅查看已保存的文字，不会登录或发送请求。解锁此设备的人可查看；退出账号会清除本机记录。')
              .fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
          }.width('100%').alignItems(HorizontalAlign.Start)
        }
        if (this.cacheNotice.length > 0) {
          Text(this.cacheNotice).fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
        }
        if (this.cleanupNeeded) {
          if (this.confirmCleanup) {
            Text('清除本机记录不会删除服务端会话。清除后需联网重新保存。')
              .fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
            Button('确认清除本机记录').constraintSize({ minHeight: 48 }).width('100%')
              .fontColor(this.palette.danger).backgroundColor(this.palette.surface).enabled(!this.loading)
              .onClick(() => this.clearLocalHistory())
            Button('保留').constraintSize({ minHeight: 48 }).enabled(!this.loading)
              .onClick(() => this.confirmCleanup = false)
          } else {
            Button('清理本机记录后重试').constraintSize({ minHeight: 48 }).width('100%')
              .fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft).enabled(!this.loading)
              .onClick(() => this.confirmCleanup = true)
          }
        }
        if (!this.registerMode) {
          Text('登录后沿用账号配置，无需重复填写模型密钥。')
            .fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%').textAlign(TextAlign.Center)
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start).justifyContent(FlexAlign.Start)
      .padding({ left: 20, right: 20, top: 24, bottom: 32 })
    }
    .width('100%').height('100%').backgroundColor(this.palette.bg)
  }
}
