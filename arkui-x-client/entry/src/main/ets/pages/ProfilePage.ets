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

@Component
export struct ProfilePage {
  @StorageLink('reduceMotion') private reduceMotion: boolean = false;
  @Prop baseUrl: string;
  @Prop token: string;
  @Prop user: UserProfile;
  onUserChanged: (user: UserProfile) => void = () => {};
  onLogout: () => void = () => {};
  onOpenAgent: (prompt: string) => void = () => {};
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
  @State private showHduHelpData: boolean = false;
  @State private hduHelpDataLoading: boolean = false;
  @State private hduHelpSections: HDUHelpDisplaySection[] = [];
  @State private hduHelpPrompts: HDUHelpSuggestedPrompt[] = [];
  @State private hduHelpSyncErrors: string[] = [];
  @State private hduHelpDataError: string = '';

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

  private async openHduHelpData(): Promise<void> {
    this.getUIContext().animateTo({ duration: AppTheme.motion(200), curve: Curve.EaseOut }, () => {
      this.showHduHelpData = true;
    });
    this.hduHelpDataLoading = true;
    this.hduHelpDataError = '';
    try {
      const result: HDUHelpDataResponse = await new CampusFlowApi(this.baseUrl, this.token).hduHelpData();
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
      this.hduHelpDataError = `校园档案加载失败：${error}`;
    } finally {
      this.hduHelpDataLoading = false;
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
      Text(label).fontSize(13).fontColor(AppTheme.secondary).width('100%')
      TextInput({ text: value }).type(secure ? InputType.Password : InputType.Normal)
        .height(48).fontSize(16).backgroundColor(AppTheme.field).borderRadius(12).onChange(onChange)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private dataItem(item: HDUHelpDisplayItem) {
    if (item.label.length > 12 || item.value.length > 22) {
      Column({ space: 5 }) {
        Text(item.label).fontSize(13).fontColor(AppTheme.secondary).width('100%')
        Text(item.value).fontSize(item.emphasis ? 17 : 15)
          .fontWeight(item.emphasis ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(item.emphasis ? AppTheme.blue : AppTheme.ink)
          .width('100%').maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.width('100%').alignItems(HorizontalAlign.Start)
        .padding(11).backgroundColor(AppTheme.field).borderRadius(13)
    } else {
      Row() {
        Text(item.label).fontSize(13).fontColor(AppTheme.secondary)
        Blank()
        Text(item.value).fontSize(item.emphasis ? 17 : 15)
          .fontWeight(item.emphasis ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(item.emphasis ? AppTheme.blue : AppTheme.ink)
          .constraintSize({ maxWidth: '68%' }).maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }.width('100%')
    }
  }

  @Builder
  private hduHelpDataView() {
    Column() {
      Row({ space: 12 }) {
        Button() {
          AppIcon({ name: 'back', iconSize: 22, color: AppTheme.blue })
        }.width(44).height(44)
          .backgroundColor(AppTheme.surface).borderRadius(22)
          .onClick(() => this.showHduHelpData = false)
        Column({ space: 3 }) {
          Text('我的校园档案').fontSize(23).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
          Text('由 HDUHelp 同步，Agent 可按需调用').fontSize(13).fontColor(AppTheme.secondary)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button('刷新').height(44).fontSize(13).fontColor(AppTheme.blue).backgroundColor(AppTheme.blueSoft)
          .borderRadius(14).onClick(() => this.openHduHelpData())
      }.width('100%').padding({ left: 18, right: 18, top: 18, bottom: 12 })

      Scroll() {
        Column({ space: 14 }) {
          if (this.hduHelpDataLoading) {
            Text('正在整理校园数据…').fontSize(15).fontColor(AppTheme.secondary).width('100%')
              .padding(18).backgroundColor(AppTheme.surface).borderRadius(20)
          } else if (this.hduHelpDataError.length > 0) {
            Text(this.hduHelpDataError).fontSize(14).fontColor(AppTheme.red).width('100%')
              .padding(16).backgroundColor(AppTheme.bg).borderRadius(18)
          } else {
            Column({ space: 7 }) {
              Text('已连接的数据').fontSize(13).fontWeight(FontWeight.Bold).fontColor(AppTheme.blue).width('100%')
              Text(`${this.hduHelpSections.length} 个信息分区`).fontSize(20).fontWeight(FontWeight.Bold)
                .fontColor(AppTheme.ink).width('100%')
            }.width('100%').padding(18).backgroundColor(AppTheme.blueSoft).borderRadius(18)

            ForEach(this.hduHelpSections, (section: HDUHelpDisplaySection) => {
              Column({ space: 10 }) {
                Row() {
                  Column({ space: 3 }) {
                    Text(section.title).fontSize(17).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
                    Text(section.summary).fontSize(13).fontColor(AppTheme.secondary)
                  }.alignItems(HorizontalAlign.Start)
                  Blank()
                  Row() {
                    AppIcon({ name: 'check', iconSize: 16, color: AppTheme.green })
                  }.width(28).height(28).justifyContent(FlexAlign.Center)
                    .backgroundColor(AppTheme.greenSoft).borderRadius(10)
                }.width('100%')
                ForEach(section.items, (item: HDUHelpDisplayItem) => {
                  this.dataItem(item)
                }, (item: HDUHelpDisplayItem) => `${section.resource}-${item.label}`)
              }.width('100%').padding(17).backgroundColor(AppTheme.surface).borderRadius(18)
            }, (section: HDUHelpDisplaySection) => section.resource)

            if (this.hduHelpSyncErrors.length > 0) {
              Column({ space: 8 }) {
                Text('暂不可用的数据').fontSize(16).fontWeight(FontWeight.Bold)
                  .fontColor(AppTheme.red).width('100%')
                Text('以下项目需要在 HDUHelp 补充权限或服务授权，其余成功数据已全部展示。')
                  .fontSize(13).fontColor(AppTheme.secondary).width('100%')
                ForEach(this.hduHelpSyncErrors, (message: string) => {
                  Text(message).fontSize(13).fontColor(AppTheme.secondary).width('100%').maxLines(3)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }, (message: string) => message)
              }.width('100%').padding(17).backgroundColor(AppTheme.bg).borderRadius(18)
            }

            if (this.hduHelpPrompts.length > 0) {
              Column({ space: 11 }) {
                Text('问问 Agent').fontSize(18).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink).width('100%')
                Text('基于已连接的数据继续完成任务').fontSize(13).fontColor(AppTheme.secondary).width('100%')
                ForEach(this.hduHelpPrompts, (suggestion: HDUHelpSuggestedPrompt) => {
                  Button() {
                    Row({ space: 10 }) {
                      Text(suggestion.title).fontSize(15).fontColor(AppTheme.blue)
                        .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                      AppIcon({ name: 'chevron', iconSize: 16, color: AppTheme.blue })
                    }.width('100%')
                  }.width('100%').height(48).padding({ left: 14, right: 14 })
                    .backgroundColor(AppTheme.blueSoft).borderRadius(12)
                    .onClick(() => this.onOpenAgent(suggestion.prompt))
                }, (suggestion: HDUHelpSuggestedPrompt) => suggestion.prompt_id)
              }.width('100%').padding(18).backgroundColor(AppTheme.surface).borderRadius(18)
            }
          }
        }.width('100%').padding({ left: 18, right: 18, bottom: 28 })
      }.layoutWeight(1).width('100%')
    }.width('100%').height('100%').alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Start).backgroundColor(AppTheme.bg)
  }

  build() {
    if (this.showHduHelpData) {
      this.hduHelpDataView()
    } else {
      Scroll() {
      Column({ space: 18 }) {
        Text('我的').fontSize(32).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink).width('100%')
        Row({ space: 14 }) {
          Text(this.user.display_name.slice(0, 1)).fontSize(25).fontWeight(FontWeight.Bold).fontColor(AppTheme.surface)
            .width(58).height(58).textAlign(TextAlign.Center).backgroundColor(AppTheme.blue).borderRadius(29)
          Column({ space: 4 }) {
            Text(this.user.display_name).fontSize(21).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.user.email).fontSize(14).fontColor(AppTheme.secondary)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        }.width('100%').padding(18).backgroundColor(AppTheme.surface).borderRadius(18)

        if (this.message.length > 0) {
          Text(this.message).fontSize(14).fontColor(AppTheme.blue).width('100%')
            .padding(12).backgroundColor(AppTheme.blueSoft).borderRadius(13)
        }

        Column({ space: 13 }) {
          Text('账号与校园').fontSize(17).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink).width('100%')
          this.field('昵称', this.displayName, (value) => this.displayName = value)
          this.field('学校', this.school, (value) => this.school = value)
          this.field('校区', this.campus, (value) => this.campus = value)
          this.field('学期', this.semester, (value) => this.semester = value)
          this.field(`更新 API Key（当前 ${this.user.api_key_hint ?? '未配置'}）`, this.newApiKey,
            (value) => this.newApiKey = value, true)
          Button('保存配置').width('100%').height(48).fontSize(16).fontColor(AppTheme.surface).backgroundColor(AppTheme.blue)
            .borderRadius(13).onClick(() => this.saveProfile())
        }.width('100%').padding(18).backgroundColor(AppTheme.surface).borderRadius(18)

        Column({ space: 12 }) {
          Row() {
            Column({ space: 4 }) {
              Text('HDUHelp 校园档案').fontSize(17).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
              Text('PAT 加密保存，也支持官方 OAuth；不提交杭电密码').fontSize(12).fontColor(AppTheme.secondary)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Blank()
            Text(this.hduHelp.configured ? '已连接' : '未连接').fontSize(13)
              .fontColor(this.hduHelp.configured ? AppTheme.green : AppTheme.muted)
          }.width('100%')
          if (this.hduHelpMessage.length > 0) {
            Text(this.hduHelpMessage).fontSize(13)
              .fontColor(this.hduHelpMessageIsError ? AppTheme.red : AppTheme.blue)
              .width('100%').padding(11)
              .backgroundColor(this.hduHelpMessageIsError ? AppTheme.bg : AppTheme.blueSoft)
              .borderRadius(12)
          }
          if (this.hduHelp.configured) {
            Column({ space: 3 }) {
              Text(`${this.hduHelp.auth_mode === 'pat' ? `个人令牌 ${this.hduHelp.token_hint ?? ''}` : '官方 OAuth'} · ${this.hduHelp.external_name ?? '当前用户'}`)
                .fontSize(14).fontColor(AppTheme.blue).width('100%').maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(`${this.hduHelp.resources.length} 类校园数据可供 Agent 使用`)
                .fontSize(12).fontColor(AppTheme.secondary).width('100%')
            }.width('100%').padding(12).backgroundColor(AppTheme.blueSoft).borderRadius(13)
            Row({ space: 9 }) {
              Button('同步数据').layoutWeight(1).height(44).fontColor(AppTheme.surface).backgroundColor(AppTheme.blue)
                .borderRadius(13).onClick(() => this.syncHduHelp())
              Button('断开并删除').layoutWeight(1).height(44).fontColor(AppTheme.red).backgroundColor(AppTheme.bg)
                .borderRadius(13).onClick(() => this.disconnectHduHelp())
            }.width('100%')
            Button('查看校园档案与推荐问题').width('100%').height(44).fontColor(AppTheme.blue)
              .backgroundColor(AppTheme.blueSoft).borderRadius(13).onClick(() => this.openHduHelpData())
          } else {
            TextInput({ text: this.hduHelpPat, placeholder: 'hduhelp_pat_…' }).type(InputType.Password)
              .height(46).backgroundColor(AppTheme.field).borderRadius(13)
              .onChange((value) => this.hduHelpPat = value)
            Text('令牌仅发送到本机 CampusFlow 后端并以密文保存。').fontSize(12)
              .fontColor(AppTheme.secondary).width('100%')
            Button('使用令牌连接并同步').width('100%').height(44).fontColor(AppTheme.surface)
              .backgroundColor(AppTheme.blue).borderRadius(13).onClick(() => this.connectHduHelpPat())
            Button('或使用官方 OAuth').width('100%').height(44).fontColor(AppTheme.blue)
              .backgroundColor(AppTheme.blueSoft).borderRadius(13).onClick(() => this.connectHduHelp())
            if (this.hduHelpAuthorizeUrl.length > 0) {
              Hyperlink(this.hduHelpAuthorizeUrl, '打开 HDUHelp 官方授权页 ↗')
                .color(AppTheme.blue).width('100%')
              Button('我已授权，检查连接').width('100%').height(44).fontColor(AppTheme.blue)
                .backgroundColor(AppTheme.blueSoft).borderRadius(13).onClick(() => this.loadHduHelp())
            }
          }
        }.width('100%').padding(18).backgroundColor(AppTheme.surface).borderRadius(18)

        Column({ space: 12 }) {
          Row() {
            Text('课表订阅').fontSize(17).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
            Blank()
            Text(this.subscription.configured ? `${this.subscription.event_count} 节` : '未连接')
              .fontSize(13).fontColor(this.subscription.configured ? AppTheme.green : AppTheme.muted)
          }.width('100%')
          TextInput({ text: this.scheduleUrl, placeholder: '粘贴 HDUHelp 订阅链接' }).height(46)
            .backgroundColor(AppTheme.field).borderRadius(13).onChange((value) => this.scheduleUrl = value)
          Row({ space: 9 }) {
            Button('连接新课表').layoutWeight(1).height(44).fontColor(AppTheme.surface).backgroundColor(AppTheme.blue)
              .borderRadius(13).onClick(() => this.saveSubscription())
            if (this.subscription.configured) {
              Button('立即同步').layoutWeight(1).height(44).fontColor(AppTheme.blue).backgroundColor(AppTheme.blueSoft)
                .borderRadius(13).onClick(() => this.syncSubscription())
            }
          }.width('100%')
        }.width('100%').padding(18).backgroundColor(AppTheme.surface).borderRadius(18)

        if (this.user.role === 'admin') {
          Column({ space: 12 }) {
            Row() {
              Text('用户管理').fontSize(17).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
              Blank()
              Text(`${this.adminUsers.length} 人`).fontSize(13).fontColor(AppTheme.blue)
            }.width('100%')
            ForEach(this.adminUsers, (account: AdminUserSummary) => {
              Row({ space: 11 }) {
                Text(account.display_name.slice(0, 1)).fontSize(14).fontWeight(FontWeight.Bold)
                  .fontColor(AppTheme.blue).width(36).height(36).textAlign(TextAlign.Center)
                  .backgroundColor(AppTheme.blueSoft).borderRadius(12)
                Column({ space: 3 }) {
                  Row({ space: 6 }) {
                    Text(account.display_name).fontSize(14).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink)
                    if (account.role === 'admin') {
                      Text('管理员').fontSize(11).fontColor(AppTheme.surface).backgroundColor(AppTheme.blue)
                        .padding({ left: 5, right: 5, top: 2, bottom: 2 }).borderRadius(7)
                    }
                  }
                  Text(account.email).fontSize(12).fontColor(AppTheme.secondary).maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(`${account.timetable_count} 节课 · ${account.campus_place_count} 个地点 · ${account.api_key_configured ? '凭据已配置' : '凭据未配置'}`)
                    .fontSize(12).fontColor(AppTheme.muted)
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              }.width('100%')
            }, (account: AdminUserSummary) => account.user_id)
          }.width('100%').padding(18).backgroundColor(AppTheme.surface).borderRadius(18)
        }

        Row({ space: 16 }) {
          Column({ space: 4 }) {
            Text('减少动态效果').fontSize(16).fontColor(AppTheme.ink)
            Text('简化页面切换与交互动画').fontSize(13).fontColor(AppTheme.secondary)
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.reduceMotion })
            .selectedColor(AppTheme.green)
            .onChange((value: boolean) => this.reduceMotion = value)
            .accessibilityText('减少动态效果')
        }.width('100%').padding(18).backgroundColor(AppTheme.surface).borderRadius(18)

        Column({ space: 5 }) {
          Text('API 服务').fontSize(13).fontColor(AppTheme.secondary).width('100%')
          Text(this.baseUrl).fontSize(15).fontColor(AppTheme.ink).width('100%')
        }.width('100%').padding(16).backgroundColor(AppTheme.surface).borderRadius(18)

        Button('退出登录').width('100%').height(46).fontColor(AppTheme.red).backgroundColor(AppTheme.bg)
          .borderRadius(14).onClick(() => this.onLogout())
      }.width('100%').alignItems(HorizontalAlign.Start).justifyContent(FlexAlign.Start)
        .padding({ left: 18, right: 18, top: 20, bottom: 32 })
      }.width('100%').height('100%').backgroundColor(AppTheme.bg)
    }
  }
}
