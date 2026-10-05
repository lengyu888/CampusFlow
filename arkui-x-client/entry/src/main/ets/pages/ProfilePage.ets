import {
  AdminUserSummary,
  HDUHelpConnectionStatus,
  ScheduleSubscriptionStatus,
  UserProfile
} from '../model/ApiModels';
import { CampusFlowApi } from '../services/CampusFlowApi';

@Component
export struct ProfilePage {
  @Prop baseUrl: string;
  @Prop token: string;
  @Prop user: UserProfile;
  onUserChanged: (user: UserProfile) => void = () => {};
  onLogout: () => void = () => {};
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

  aboutToAppear(): void {
    this.displayName = this.user.display_name;
    this.school = this.user.school ?? '';
    this.campus = this.user.campus ?? '';
    this.semester = this.user.semester ?? '';
    this.loadSubscription();
    this.loadHduHelp();
    if (this.user.role === 'admin') {
      this.loadAdminUsers();
    }
  }

  private async loadAdminUsers(): Promise<void> {
    try {
      this.adminUsers = await new CampusFlowApi(this.baseUrl, this.token).adminUsers();
    } catch (error) {
      this.message = `管理员用户列表加载失败：${error}`;
    }
  }

  private async loadSubscription(): Promise<void> {
    try {
      this.subscription = await new CampusFlowApi(this.baseUrl, this.token).subscriptionStatus();
    } catch (error) {
      this.message = `订阅状态加载失败：${error}`;
    }
  }

  private async loadHduHelp(): Promise<void> {
    try {
      this.hduHelp = await new CampusFlowApi(this.baseUrl, this.token).hduHelpStatus();
    } catch (error) {
      this.hduHelpMessage = `HDUHelp 状态加载失败：${error}`;
      this.hduHelpMessageIsError = true;
    }
  }

  private async connectHduHelp(): Promise<void> {
    try {
      const result = await new CampusFlowApi(this.baseUrl, this.token).connectHduHelp();
      this.hduHelpAuthorizeUrl = result.authorize_url;
      this.hduHelpMessage = '授权链接已生成，请在 HDUHelp 官方页面确认后返回并检查连接。';
      this.hduHelpMessageIsError = false;
    } catch (error) {
      this.hduHelpMessage = `无法发起 HDUHelp 授权：${error}`;
      this.hduHelpMessageIsError = true;
    }
  }

  private async connectHduHelpPat(): Promise<void> {
    if (this.hduHelpPat.trim().length === 0) {
      this.hduHelpMessage = '请先填写 HDUHelp 个人访问令牌。';
      this.hduHelpMessageIsError = true;
      return;
    }
    try {
      const result = await new CampusFlowApi(this.baseUrl, this.token)
        .connectHduHelpPat(this.hduHelpPat.trim());
      this.hduHelpPat = '';
      this.hduHelp = result.status;
      this.hduHelpMessage = `令牌已连接，已同步 ${result.synced_resources.length} 类 HDUHelp 数据。`;
      this.hduHelpMessageIsError = false;
    } catch (error) {
      this.hduHelpPat = '';
      this.hduHelpMessage = `HDUHelp 令牌连接失败：${error}`;
      this.hduHelpMessageIsError = true;
    }
  }

  private async syncHduHelp(): Promise<void> {
    try {
      const result = await new CampusFlowApi(this.baseUrl, this.token).syncHduHelp();
      this.hduHelp = result.status;
      this.hduHelpMessage = `已同步 ${result.synced_resources.length} 类 HDUHelp 数据。`;
      this.hduHelpMessageIsError = false;
    } catch (error) {
      this.hduHelpMessage = `HDUHelp 同步失败：${error}`;
      this.hduHelpMessageIsError = true;
    }
  }

  private async disconnectHduHelp(): Promise<void> {
    try {
      await new CampusFlowApi(this.baseUrl, this.token).disconnectHduHelp();
      this.hduHelp.configured = false;
      this.hduHelp.resources = [];
      this.hduHelpAuthorizeUrl = '';
      this.hduHelpMessage = 'HDUHelp 已断开，本地同步数据已删除。';
      this.hduHelpMessageIsError = false;
    } catch (error) {
      this.hduHelpMessage = `HDUHelp 断开失败：${error}`;
      this.hduHelpMessageIsError = true;
    }
  }

  private async saveProfile(): Promise<void> {
    try {
      const updated = await new CampusFlowApi(this.baseUrl, this.token).updateSettings(
        this.displayName, this.school, this.campus, this.semester, this.newApiKey
      );
      this.newApiKey = '';
      this.message = '账号配置已更新。';
      this.onUserChanged(updated);
    } catch (error) {
      this.message = `保存失败：${error}`;
    }
  }

  private async saveSubscription(): Promise<void> {
    if (this.scheduleUrl.length === 0) {
      return;
    }
    try {
      const result = await new CampusFlowApi(this.baseUrl, this.token).saveSubscription(this.scheduleUrl);
      this.subscription = result.status;
      this.scheduleUrl = '';
      this.message = `已导入 ${result.imported_count} 节课程。`;
    } catch (error) {
      this.message = `订阅失败：${error}`;
    }
  }

  private async syncSubscription(): Promise<void> {
    try {
      const result = await new CampusFlowApi(this.baseUrl, this.token).syncSubscription();
      this.subscription = result.status;
      this.message = `课表已同步，共 ${result.imported_count} 节。`;
    } catch (error) {
      this.message = `同步失败：${error}`;
    }
  }

  @Builder
  private field(label: string, value: string, onChange: (value: string) => void, secure: boolean = false) {
    Column({ space: 6 }) {
      Text(label).fontSize(11).fontColor('#7E8595').width('100%')
      TextInput({ text: value }).type(secure ? InputType.Password : InputType.Normal)
        .height(46).backgroundColor('#F5F7FB').borderRadius(13).onChange(onChange)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  build() {
    Scroll() {
      Column({ space: 18 }) {
        Row({ space: 14 }) {
          Text(this.user.display_name.slice(0, 1)).fontSize(25).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
            .width(58).height(58).textAlign(TextAlign.Center).backgroundColor('#315BFF').borderRadius(20)
          Column({ space: 4 }) {
            Text(this.user.display_name).fontSize(21).fontWeight(FontWeight.Bold).fontColor('#171A22')
            Text(this.user.email).fontSize(12).fontColor('#7B8292')
          }.alignItems(HorizontalAlign.Start)
        }.width('100%')

        if (this.message.length > 0) {
          Text(this.message).fontSize(12).fontColor('#315BFF').width('100%')
            .padding(12).backgroundColor('#E9EEFF').borderRadius(13)
        }

        Column({ space: 13 }) {
          Text('账号与校园').fontSize(17).fontWeight(FontWeight.Bold).fontColor('#171A22').width('100%')
          this.field('昵称', this.displayName, (value) => this.displayName = value)
          this.field('学校', this.school, (value) => this.school = value)
          this.field('校区', this.campus, (value) => this.campus = value)
          this.field('学期', this.semester, (value) => this.semester = value)
          this.field(`更新 API Key（当前 ${this.user.api_key_hint ?? '未配置'}）`, this.newApiKey,
            (value) => this.newApiKey = value, true)
          Button('保存配置').width('100%').height(43).fontColor('#FFFFFF').backgroundColor('#171A22')
            .borderRadius(13).onClick(() => this.saveProfile())
        }.width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(22)

        Column({ space: 12 }) {
          Row() {
            Column({ space: 4 }) {
              Text('HDUHelp 校园档案').fontSize(17).fontWeight(FontWeight.Bold).fontColor('#171A22')
              Text('PAT 加密保存，也支持官方 OAuth；不提交杭电密码').fontSize(10).fontColor('#7B8292')
            }.alignItems(HorizontalAlign.Start)
            Blank()
            Text(this.hduHelp.configured ? '已连接' : '未连接').fontSize(11)
              .fontColor(this.hduHelp.configured ? '#19966B' : '#8B91A0')
          }.width('100%')
          if (this.hduHelpMessage.length > 0) {
            Text(this.hduHelpMessage).fontSize(11)
              .fontColor(this.hduHelpMessageIsError ? '#B42318' : '#315BFF')
              .width('100%').padding(11)
              .backgroundColor(this.hduHelpMessageIsError ? '#FFF0F0' : '#E9EEFF')
              .borderRadius(12)
          }
          if (this.hduHelp.configured) {
            Column({ space: 3 }) {
              Text(`${this.hduHelp.auth_mode === 'pat' ? `个人令牌 ${this.hduHelp.token_hint ?? ''}` : '官方 OAuth'} · ${this.hduHelp.external_name ?? '当前用户'}`)
                .fontSize(12).fontColor('#315BFF').width('100%').maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(`${this.hduHelp.resources.length} 类校园数据可供 Agent 使用`)
                .fontSize(10).fontColor('#6B7CC8').width('100%')
            }.width('100%').padding(12).backgroundColor('#E9EEFF').borderRadius(13)
            Row({ space: 9 }) {
              Button('同步数据').layoutWeight(1).height(42).fontColor('#FFFFFF').backgroundColor('#315BFF')
                .borderRadius(13).onClick(() => this.syncHduHelp())
              Button('断开并删除').layoutWeight(1).height(42).fontColor('#D33D3D').backgroundColor('#FFF0F0')
                .borderRadius(13).onClick(() => this.disconnectHduHelp())
            }.width('100%')
          } else {
            TextInput({ text: this.hduHelpPat, placeholder: 'hduhelp_pat_…' }).type(InputType.Password)
              .height(46).backgroundColor('#F5F7FB').borderRadius(13)
              .onChange((value) => this.hduHelpPat = value)
            Text('令牌仅发送到本机 CampusFlow 后端并以密文保存。').fontSize(10)
              .fontColor('#7B8292').width('100%')
            Button('使用令牌连接并同步').width('100%').height(42).fontColor('#FFFFFF')
              .backgroundColor('#315BFF').borderRadius(13).onClick(() => this.connectHduHelpPat())
            Button('或使用官方 OAuth').width('100%').height(40).fontColor('#315BFF')
              .backgroundColor('#E9EEFF').borderRadius(13).onClick(() => this.connectHduHelp())
            if (this.hduHelpAuthorizeUrl.length > 0) {
              Hyperlink(this.hduHelpAuthorizeUrl, '打开 HDUHelp 官方授权页 ↗')
                .color('#315BFF').width('100%')
              Button('我已授权，检查连接').width('100%').height(40).fontColor('#315BFF')
                .backgroundColor('#E9EEFF').borderRadius(13).onClick(() => this.loadHduHelp())
            }
          }
        }.width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(22)

        Column({ space: 12 }) {
          Row() {
            Text('课表订阅').fontSize(17).fontWeight(FontWeight.Bold).fontColor('#171A22')
            Blank()
            Text(this.subscription.configured ? `${this.subscription.event_count} 节` : '未连接')
              .fontSize(11).fontColor(this.subscription.configured ? '#19966B' : '#8B91A0')
          }.width('100%')
          TextInput({ text: this.scheduleUrl, placeholder: '粘贴 HDUHelp 订阅链接' }).height(46)
            .backgroundColor('#F5F7FB').borderRadius(13).onChange((value) => this.scheduleUrl = value)
          Row({ space: 9 }) {
            Button('连接新课表').layoutWeight(1).height(42).fontColor('#FFFFFF').backgroundColor('#315BFF')
              .borderRadius(13).onClick(() => this.saveSubscription())
            if (this.subscription.configured) {
              Button('立即同步').layoutWeight(1).height(42).fontColor('#315BFF').backgroundColor('#E9EEFF')
                .borderRadius(13).onClick(() => this.syncSubscription())
            }
          }.width('100%')
        }.width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(22)

        if (this.user.role === 'admin') {
          Column({ space: 12 }) {
            Row() {
              Text('用户管理').fontSize(17).fontWeight(FontWeight.Bold).fontColor('#171A22')
              Blank()
              Text(`${this.adminUsers.length} 人`).fontSize(11).fontColor('#315BFF')
            }.width('100%')
            ForEach(this.adminUsers, (account: AdminUserSummary) => {
              Row({ space: 11 }) {
                Text(account.display_name.slice(0, 1)).fontSize(14).fontWeight(FontWeight.Bold)
                  .fontColor('#315BFF').width(36).height(36).textAlign(TextAlign.Center)
                  .backgroundColor('#E9EEFF').borderRadius(12)
                Column({ space: 3 }) {
                  Row({ space: 6 }) {
                    Text(account.display_name).fontSize(14).fontWeight(FontWeight.Medium).fontColor('#171A22')
                    if (account.role === 'admin') {
                      Text('管理员').fontSize(9).fontColor('#FFFFFF').backgroundColor('#315BFF')
                        .padding({ left: 5, right: 5, top: 2, bottom: 2 }).borderRadius(7)
                    }
                  }
                  Text(account.email).fontSize(10).fontColor('#7B8292').maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(`${account.timetable_count} 节课 · ${account.campus_place_count} 个地点 · ${account.api_key_configured ? '凭据已配置' : '凭据未配置'}`)
                    .fontSize(10).fontColor('#8B91A0')
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              }.width('100%')
            }, (account: AdminUserSummary) => account.user_id)
          }.width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(22)
        }

        Column({ space: 5 }) {
          Text('API 服务').fontSize(11).fontColor('#7E8595').width('100%')
          Text(this.baseUrl).fontSize(13).fontColor('#171A22').width('100%')
        }.width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(18)

        Button('退出登录').width('100%').height(46).fontColor('#D33D3D').backgroundColor('#FFF0F0')
          .borderRadius(14).onClick(() => this.onLogout())
      }.width('100%').padding({ left: 18, right: 18, top: 20, bottom: 110 })
    }.width('100%').height('100%').backgroundColor('#F5F7FB')
  }
}
