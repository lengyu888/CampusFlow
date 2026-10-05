import { CampusMapSummary, CampusPlaceImport, UserProfile } from '../model/ApiModels';
import { CampusFlowApi } from '../services/CampusFlowApi';

@Component
export struct OnboardingPage {
  @Prop baseUrl: string;
  @Prop token: string;
  onCompleted: (user: UserProfile) => void = () => {};
  @State private school: string = '杭州电子科技大学';
  @State private campus: string = '下沙校区';
  @State private semester: string = '2026-2027 第一学期';
  @State private scheduleUrl: string = '';
  @State private loading: boolean = false;
  @State private message: string = '';

  private async finish(): Promise<void> {
    if (this.scheduleUrl.trim().length === 0) {
      this.message = '请先填写 HDUHelp 课表订阅链接，完成后仍可在“我的”中更换或同步。';
      return;
    }
    this.loading = true;
    this.message = '';
    try {
      const api = new CampusFlowApi(this.baseUrl, this.token);
      const sync = await api.saveSubscription(this.scheduleUrl.trim());
      if (sync.imported_count === 0) {
        throw new Error('订阅中没有可导入的课程。');
      }
      const context = await api.context();
      const campusData = await api.campusData();
      const places: CampusPlaceImport[] = campusData.places.map((item): CampusPlaceImport => {
        const place: CampusPlaceImport = {
          name: item.name,
          category: item.category,
          zone: item.zone,
          aliases: item.aliases
        };
        return place;
      });
      const campusMap: CampusMapSummary = {
        campus_name: `${this.school}${this.campus}`,
        places: places,
        warnings: ['使用 CampusFlow 官方杭电下沙校区数据包。']
      };
      const result = await api.completeOnboarding(
        this.school, this.campus, this.semester, context.timetable, campusMap
      );
      this.onCompleted(result.user);
    } catch (error) {
      this.message = `配置失败：${error}`;
    } finally {
      this.loading = false;
    }
  }

  @Builder
  private field(label: string, value: string, onChange: (value: string) => void) {
    Column({ space: 6 }) {
      Text(label).fontSize(12).fontColor('#6F7688').width('100%')
      TextInput({ text: value }).height(50).backgroundColor('#F5F7FB').borderRadius(15)
        .padding({ left: 14, right: 14 }).onChange(onChange)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  build() {
    Scroll() {
      Column({ space: 20 }) {
        Column({ space: 8 }) {
          Text('先让 Agent 认识你').fontSize(28).fontWeight(FontWeight.Bold).fontColor('#171A22')
          Text('这些校园上下文会用于课表问答、冲突检测和路线规划。').fontSize(14).fontColor('#707789')
        }.width('100%').alignItems(HorizontalAlign.Start)

        Column({ space: 15 }) {
          this.field('学校', this.school, (value) => this.school = value)
          this.field('校区', this.campus, (value) => this.campus = value)
          this.field('学期', this.semester, (value) => this.semester = value)
          this.field('HDUHelp 课表订阅链接', this.scheduleUrl, (value) => this.scheduleUrl = value)
          Text('课表将从 HDUHelp 安全导入；校园地点使用 CampusFlow 官方杭电数据包。订阅凭据由服务端加密保存。')
            .fontSize(12).fontColor('#858C9C').width('100%')
          if (this.message.length > 0) {
            Text(this.message).fontSize(12).fontColor('#D33D3D').width('100%')
          }
          Button(this.loading ? '保存中…' : '完成配置')
            .width('100%').height(52).fontColor('#FFFFFF').backgroundColor('#315BFF')
            .borderRadius(16).enabled(!this.loading).onClick(() => this.finish())
        }
        .width('100%').padding(22).backgroundColor('#FFFFFF').borderRadius(26)
      }
      .padding({ left: 22, right: 22, top: 44, bottom: 32 })
    }.width('100%').height('100%').backgroundColor('#F1F4FA')
  }
}
