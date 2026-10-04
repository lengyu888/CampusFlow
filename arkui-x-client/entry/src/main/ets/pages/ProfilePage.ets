import { ScheduleSubscriptionStatus, UserProfile } from '../model/ApiModels';
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

  aboutToAppear(): void {
    this.displayName = this.user.display_name;
    this.school = this.user.school ?? '';
    this.campus = this.user.campus ?? '';
    this.semester = this.user.semester ?? '';
    this.loadSubscription();
  }

  private async loadSubscription(): Promise<void> {
    try {
      this.subscription = await new CampusFlowApi(this.baseUrl, this.token).subscriptionStatus();
    } catch (error) {
      this.message = `订阅状态加载失败：${error}`;
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
