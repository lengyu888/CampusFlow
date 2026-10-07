import { PlanningOverview, PlanningTask, TimetableEntry, UserContextResponse } from '../model/ApiModels';
import { CampusFlowApi } from '../services/CampusFlowApi';

interface CalendarDay {
  key: string;
  day: number;
  date: string;
  courseCount: number;
}

@Component
export struct PlanPage {
  @Prop baseUrl: string;
  @Prop token: string;
  @State private overview: PlanningOverview = {
    tasks: [], total_tasks: 0, completed_tasks: 0, due_today: 0, progress: 0
  };
  @State private title: string = '';
  @State private errorText: string = '';
  @State private timetable: TimetableEntry[] = [];
  @State private calendarMonth: number = new Date(new Date().getFullYear(), new Date().getMonth(), 1).getTime();
  @State private selectedDate: string = '';

  aboutToAppear(): void {
    this.selectedDate = this.dateKey(new Date());
    this.reload();
    this.loadTimetable();
  }

  private dateKey(date: Date): string {
    const month = `${date.getMonth() + 1}`.padStart(2, '0');
    const day = `${date.getDate()}`.padStart(2, '0');
    return `${date.getFullYear()}-${month}-${day}`;
  }

  private monthLabel(): string {
    const date = new Date(this.calendarMonth);
    return `${date.getFullYear()} 年 ${date.getMonth() + 1} 月`;
  }

  private calendarDays(): CalendarDay[] {
    const month = new Date(this.calendarMonth);
    const year = month.getFullYear();
    const monthIndex = month.getMonth();
    const firstWeekday = new Date(year, monthIndex, 1).getDay();
    const count = new Date(year, monthIndex + 1, 0).getDate();
    const result: CalendarDay[] = [];
    for (let index = 0; index < firstWeekday; index++) {
      result.push({ key: `blank-${index}`, day: 0, date: '', courseCount: 0 });
    }
    for (let day = 1; day <= count; day++) {
      const key = this.dateKey(new Date(year, monthIndex, day));
      const courseCount = this.timetable.filter((course: TimetableEntry) => course.date === key).length;
      result.push({ key: key, day: day, date: key, courseCount: courseCount });
    }
    return result;
  }

  private selectedCourses(): TimetableEntry[] {
    return this.timetable.filter((course: TimetableEntry) => course.date === this.selectedDate);
  }

  private moveMonth(offset: number): void {
    const month = new Date(this.calendarMonth);
    const next = new Date(month.getFullYear(), month.getMonth() + offset, 1);
    this.calendarMonth = next.getTime();
    this.selectedDate = this.dateKey(next);
  }

  private async loadTimetable(): Promise<void> {
    try {
      const context: UserContextResponse = await new CampusFlowApi(this.baseUrl, this.token).context();
      this.timetable = context.timetable;
    } catch (error) {
      this.errorText = `课表加载失败：${error}`;
    }
  }

  private async reload(): Promise<void> {
    try {
      this.overview = await new CampusFlowApi(this.baseUrl, this.token).planning();
    } catch (error) {
      this.errorText = `规划加载失败：${error}`;
    }
  }

  private async addTask(): Promise<void> {
    if (this.title.trim().length === 0) {
      return;
    }
    try {
      await new CampusFlowApi(this.baseUrl, this.token).createTask(this.title.trim());
      this.title = '';
      await this.reload();
    } catch (error) {
      this.errorText = `创建失败：${error}`;
    }
  }

  private async toggle(task: PlanningTask): Promise<void> {
    try {
      await new CampusFlowApi(this.baseUrl, this.token).updateTask(task.task_id, task.status !== 'completed');
      await this.reload();
    } catch (error) {
      this.errorText = `更新失败：${error}`;
    }
  }

  build() {
    Scroll() {
      Column({ space: 18 }) {
        Column({ space: 4 }) {
          Text('规划').fontSize(28).fontWeight(FontWeight.Bold).fontColor('#171A22')
          Text('课程、日历与行动在同一条时间线上').fontSize(13).fontColor('#777E8F')
        }.width('100%').alignItems(HorizontalAlign.Start)

        Column({ space: 12 }) {
          Row() {
            Button('‹').width(34).height(34).fontSize(22).fontColor('#315BFF')
              .backgroundColor('#E9EEFF').borderRadius(12).onClick(() => this.moveMonth(-1))
            Blank()
            Text(this.monthLabel()).fontSize(18).fontWeight(FontWeight.Bold).fontColor('#171A22')
            Blank()
            Button('›').width(34).height(34).fontSize(22).fontColor('#315BFF')
              .backgroundColor('#E9EEFF').borderRadius(12).onClick(() => this.moveMonth(1))
          }.width('100%')
          Row() {
            ForEach(['日', '一', '二', '三', '四', '五', '六'], (label: string) => {
              Text(label).fontSize(10).fontColor('#8B91A0').textAlign(TextAlign.Center).layoutWeight(1)
            }, (label: string) => label)
          }.width('100%')
          Grid() {
            ForEach(this.calendarDays(), (item: CalendarDay) => {
              GridItem() {
                if (item.day === 0) {
                  Blank().height(44)
                } else {
                  Column({ space: 3 }) {
                    Text(`${item.day}`).fontSize(12)
                      .fontWeight(this.selectedDate === item.date ? FontWeight.Bold : FontWeight.Regular)
                      .fontColor(this.selectedDate === item.date ? '#FFFFFF' : '#171A22')
                    if (item.courseCount > 0) {
                      Text(`${item.courseCount}`).fontSize(8)
                        .fontColor(this.selectedDate === item.date ? '#FFFFFF' : '#315BFF')
                    } else {
                      Text('·').fontSize(8).fontColor('#CDD2DD')
                    }
                  }.width('100%').height(44).justifyContent(FlexAlign.Center)
                    .backgroundColor(this.selectedDate === item.date ? '#315BFF' : '#F5F7FB')
                    .borderRadius(12).onClick(() => this.selectedDate = item.date)
                }
              }
            }, (item: CalendarDay) => item.key)
          }.columnsTemplate('repeat(7, 1fr)').columnsGap(4).rowsGap(4).width('100%')
            .height(this.calendarDays().length > 35 ? 288 : 240)

          Column({ space: 9 }) {
            Row() {
              Text(this.selectedDate).fontSize(12).fontWeight(FontWeight.Bold).fontColor('#315BFF')
              Blank()
              Text(`${this.selectedCourses().length} 节课`).fontSize(11).fontColor('#7B8292')
            }.width('100%')
            if (this.selectedCourses().length === 0) {
              Text('当天没有课程安排').fontSize(12).fontColor('#8B91A0').width('100%')
            } else {
              ForEach(this.selectedCourses(), (course: TimetableEntry) => {
                Row({ space: 10 }) {
                  Text(course.start_time).fontSize(12).fontWeight(FontWeight.Bold).fontColor('#315BFF').width(42)
                  Column({ space: 2 }) {
                    Text(course.title).fontSize(13).fontWeight(FontWeight.Medium).fontColor('#171A22')
                    Text(`${course.location}${course.teacher.length > 0 ? ` · ${course.teacher}` : ''}`)
                      .fontSize(10).fontColor('#8B91A0')
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                }.width('100%').padding(10).backgroundColor('#F7F8FC').borderRadius(13)
              }, (course: TimetableEntry) => `${course.date}-${course.start_time}-${course.title}`)
            }
          }.width('100%').padding(13).backgroundColor('#EEF2FF').borderRadius(16)
        }.width('100%').padding(17).backgroundColor('#FFFFFF').borderRadius(22)

        Row({ space: 12 }) {
          Column({ space: 6 }) {
            Text(`${this.overview.progress}%`).fontSize(28).fontWeight(FontWeight.Bold).fontColor('#315BFF')
            Text('总体进度').fontSize(12).fontColor('#777E8F')
          }.layoutWeight(1).padding(18).backgroundColor('#FFFFFF').borderRadius(20)
          Column({ space: 6 }) {
            Text(`${this.overview.due_today}`).fontSize(28).fontWeight(FontWeight.Bold).fontColor('#FF6B4A')
            Text('今日到期').fontSize(12).fontColor('#777E8F')
          }.layoutWeight(1).padding(18).backgroundColor('#FFFFFF').borderRadius(20)
        }.width('100%')

        Row({ space: 10 }) {
          TextInput({ text: this.title, placeholder: '添加一个待办' }).layoutWeight(1).height(48)
            .backgroundColor('#FFFFFF').borderRadius(15).onChange((value) => this.title = value)
          Button('+').width(48).height(48).fontSize(23).fontColor('#FFFFFF').backgroundColor('#315BFF')
            .borderRadius(15).onClick(() => this.addTask())
        }.width('100%')

        if (this.errorText.length > 0) {
          Text(this.errorText).fontSize(12).fontColor('#D33D3D').width('100%')
        }

        ForEach(this.overview.tasks, (task: PlanningTask) => {
          Row({ space: 13 }) {
            Button(task.status === 'completed' ? '✓' : '')
              .width(28).height(28).fontSize(13).fontColor('#FFFFFF')
              .backgroundColor(task.status === 'completed' ? '#315BFF' : '#E8EBF2')
              .borderRadius(9).onClick(() => this.toggle(task))
            Column({ space: 4 }) {
              Text(task.title).fontSize(15).fontWeight(FontWeight.Medium)
                .fontColor(task.status === 'completed' ? '#999EAA' : '#171A22')
                .decoration({ type: task.status === 'completed' ? TextDecorationType.LineThrough : TextDecorationType.None })
              Text(task.location ?? (task.source === 'agent' ? '由 Agent 创建' : '手动创建'))
                .fontSize(11).fontColor('#8B91A0')
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          }.width('100%').padding(17).backgroundColor('#FFFFFF').borderRadius(18)
        }, (task: PlanningTask) => task.task_id)
      }.width('100%').padding({ left: 18, right: 18, top: 18, bottom: 110 })
    }.width('100%').height('100%').backgroundColor('#F5F7FB')
  }
}
