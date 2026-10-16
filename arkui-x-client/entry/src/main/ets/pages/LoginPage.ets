import { AuthResponse } from '../model/ApiModels';
import { CampusFlowApi } from '../services/CampusFlowApi';
import { AppTheme } from '../theme/AppTheme';

@Component
export struct LoginPage {
  @Prop baseUrl: string;
  onAuthenticated: (auth: AuthResponse) => void = () => {};
  onBaseUrlChange: (baseUrl: string) => void = () => {};
  @State private registerMode: boolean = false;
  @State private email: string = '';
  @State private password: string = '';
  @State private displayName: string = '';
  @State private apiKey: string = '';
  @State private loading: boolean = false;
  @State private errorText: string = '';

  private async submit(): Promise<void> {
    if (this.email.length < 5 || this.password.length < 8) {
      this.errorText = '请输入有效邮箱，密码至少 8 位。';
      return;
    }
    if (this.registerMode && (this.displayName.length === 0 || this.apiKey.length === 0)) {
      this.errorText = '注册时需要填写昵称和 DeepSeek API Key。';
      return;
    }
    this.loading = true;
    this.errorText = '';
    try {
      const api = new CampusFlowApi(this.baseUrl);
      const auth = this.registerMode
        ? await api.register(this.email, this.password, this.displayName, this.apiKey)
        : await api.login(this.email, this.password);
      this.onAuthenticated(auth);
    } catch (error) {
      this.errorText = `连接失败：${error}`;
    } finally {
      this.loading = false;
    }
  }

  @Builder
  private inputField(label: string, hint: string, value: string, onChange: (value: string) => void,
    inputType: InputType = InputType.Normal) {
    Column({ space: 7 }) {
      Text(label).fontSize(14).fontColor(AppTheme.secondary).fontWeight(FontWeight.Medium).width('100%')
      TextInput({ placeholder: hint, text: value })
        .type(inputType)
        .height(52)
        .fontSize(15)
        .backgroundColor(AppTheme.field)
        .borderRadius(16)
        .padding({ left: 16, right: 16 })
        .onChange(onChange)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Scroll() {
      Column({ space: 22 }) {
        Column({ space: 10 }) {
          Row() {
            Text('CF').fontColor(AppTheme.surface).fontSize(17).fontWeight(FontWeight.Bold)
          }
          .width(54).height(54).justifyContent(FlexAlign.Center)
          .backgroundColor(AppTheme.blue).borderRadius(18)
          Text('CampusFlow').fontSize(34).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
          Text('让校园安排顺着你的目标流动').fontSize(15).fontColor(AppTheme.secondary)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        Column({ space: 16 }) {
          Text(this.registerMode ? '创建你的校园智能体' : '欢迎回来')
            .fontSize(22).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink).width('100%')
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
            Text(this.errorText).fontSize(14).fontColor(AppTheme.red).width('100%')
          }
          Button(this.loading ? '连接中…' : (this.registerMode ? '注册并继续' : '登录'))
            .width('100%').height(52).fontSize(16).fontWeight(FontWeight.Bold)
            .fontColor(AppTheme.surface).backgroundColor(AppTheme.blue).borderRadius(16)
            .enabled(!this.loading)
            .onClick(() => this.submit())
          Button(this.registerMode ? '已有账号，直接登录' : '第一次使用？创建账号')
            .width('100%').height(44).fontSize(14).fontColor(AppTheme.blue)
            .backgroundColor(Color.Transparent)
            .onClick(() => {
              this.getUIContext().animateTo({ duration: AppTheme.motion(200), curve: Curve.EaseOut }, () => {
                this.registerMode = !this.registerMode;
                this.errorText = '';
              });
            })
        }
        .width('100%')
        .padding(22)
        .backgroundColor(AppTheme.surface)
        .borderRadius(20)

        Text('登录后自动使用已保存的模型配置，无需重复填写 API Key。')
          .fontSize(13).fontColor(AppTheme.secondary).textAlign(TextAlign.Center)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start).justifyContent(FlexAlign.Start)
      .padding({ left: 20, right: 20, top: 40, bottom: 32 })
    }
    .width('100%').height('100%').backgroundColor(AppTheme.bg)
  }
}
