import { TimetableEntry, UserContextResponse, UserProfile } from '../model/ApiModels';
import { CampusFlowApi } from '../services/CampusFlowApi';

@Component
export struct HomePage {
  @Prop baseUrl: string;
  @Prop token: string;
  @Prop user: UserProfile;
  onOpenAgent: () => void = () => {};
  onOpenRoute: () => void = () => {};
  onOpenServices: () => void = () => {};
  @State private courses: TimetableEntry[] = [];
  @State private loading: boolean = true;
  @State private errorText: string = '';

  aboutToAppear(): void {
    this.loadToday();
  }

  private today(): string {
    const now = new Date();
    const month = `${now.getMonth() + 1}`.padStart(2, '0');
    const day = `${now.getDate()}`.padStart(2, '0');
    return `${now.getFullYear()}-${month}-${day}`;
  }

  private async loadToday(): Promise<void> {
    try {
      const context: UserContextResponse = await new CampusFlowApi(this.baseUrl, this.token).context();
      const today = this.today();
      this.courses = context.timetable.filter((course) => course.date === today);
    } catch (error) {
      this.errorText = `今日数据加载失败：${error}`;
    } finally {
      this.loading = false;
    }
  }

  build() {
    Scroll() {
      Column({ space: 18 }) {
        Column({ space: 6 }) {
          Text(`早上好，${this.user.display_name}`).fontSize(28).fontWeight(FontWeight.Bold).fontColor('#171A22')
          Text(`${this.user.school ?? '校园'} · ${this.today()}`).fontSize(13).fontColor('#777E8F')
        }.width('100%').alignItems(HorizontalAlign.Start)

        Column({ space: 14 }) {
          Row() {
            Column({ space: 6 }) {
              Text('今天怎么安排？').fontSize(13).fontColor('#C7D1FF')
              Text('把目标交给 Agent').fontSize(23).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
              Text('结合课表、地点和待办，给出可执行方案。').fontSize(13).fontColor('#E3E8FF')
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Text('↗').fontSize(28).fontColor('#FFFFFF')
          }.width('100%')
          Button('开始规划').height(42).fontColor('#315BFF').backgroundColor('#FFFFFF').borderRadius(14)
            .onClick(() => this.onOpenAgent())
        }.width('100%').padding(20).backgroundColor('#315BFF').borderRadius(26)

        Row({ space: 10 }) {
          Button('⌖  校园导航').layoutWeight(1).height(44).fontSize(12).fontColor('#171A22')
            .backgroundColor('#FFFFFF').borderRadius(15).onClick(() => this.onOpenRoute())
          Button('✦  问问 Agent').layoutWeight(1).height(44).fontSize(12).fontColor('#315BFF')
            .backgroundColor('#E9EEFF').borderRadius(15).onClick(() => this.onOpenAgent())
        }.width('100%')

        Row({ space: 12 }) {
          Column({ space: 3 }) {
            Text('校园实时服务').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#171A22')
            Text('教室 · 电费 · 图书馆 · 校园卡').fontSize(11).fontColor('#777E8F')
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Text('LIVE').fontSize(9).fontWeight(FontWeight.Bold).fontColor('#087D5B')
            .padding({ left: 8, right: 8, top: 5, bottom: 5 }).backgroundColor('#E5F7F0').borderRadius(9)
          Text('›').fontSize(23).fontColor('#315BFF')
        }.width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(18)
          .onClick(() => this.onOpenServices())

        Row() {
          Text('今日课程').fontSize(19).fontWeight(FontWeight.Bold).fontColor('#171A22')
          Blank()
          Text(`${this.courses.length} 节`).fontSize(12).fontColor('#7D8493')
        }.width('100%')

        if (this.loading) {
          Text('正在同步校园上下文…').fontSize(13).fontColor('#7D8493').width('100%')
        } else if (this.errorText.length > 0) {
          Text(this.errorText).fontSize(13).fontColor('#D33D3D').width('100%')
        } else if (this.courses.length === 0) {
          Column({ space: 8 }) {
            Text('今天没有课程').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#171A22')
            Text('留出一段完整时间，处理最重要的事。').fontSize(13).fontColor('#7D8493')
          }.width('100%').padding(22).backgroundColor('#FFFFFF').borderRadius(22)
        } else {
          ForEach(this.courses, (course: TimetableEntry) => {
            Row({ space: 14 }) {
              Column({ space: 2 }) {
                Text(course.start_time).fontSize(16).fontWeight(FontWeight.Bold).fontColor('#315BFF')
                Text(course.end_time).fontSize(11).fontColor('#8B91A0')
              }.width(52)
              Column({ space: 5 }) {
                Text(course.title).fontSize(16).fontWeight(FontWeight.Bold).fontColor('#171A22')
                Text(`${course.location}${course.teacher.length > 0 ? ` · ${course.teacher}` : ''}`)
                  .fontSize(12).fontColor('#777E8F')
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            }.width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(20)
          }, (course: TimetableEntry) => `${course.date}-${course.start_time}-${course.title}`)
        }
      }.width('100%').padding({ left: 18, right: 18, top: 18, bottom: 110 })
    }.width('100%').height('100%').backgroundColor('#F5F7FB')
  }
}
