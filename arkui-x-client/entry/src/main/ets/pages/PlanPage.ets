import { PlanningOverview, PlanningTask, TimetableEntry, UserContextResponse } from '../model/ApiModels';
import { CampusFlowApi } from '../services/CampusFlowApi';
import { AppTheme } from '../theme/AppTheme';

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
          Text('计划').fontSize(AppTheme.pageTitle).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
          Text('课程、日历与行动在同一条时间线上').fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary)
        }.width('100%').alignItems(HorizontalAlign.Start)

        Column({ space: 12 }) {
          Row() {
            Button('‹').width(44).height(44).fontSize(22).fontColor(AppTheme.accent)
              .backgroundColor(AppTheme.accentSoft).borderRadius(12).onClick(() => this.moveMonth(-1))
            Blank()
            Text(this.monthLabel()).fontSize(AppTheme.sectionTitle).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
            Blank()
            Button('›').width(44).height(44).fontSize(22).fontColor(AppTheme.accent)
              .backgroundColor(AppTheme.accentSoft).borderRadius(12).onClick(() => this.moveMonth(1))
          }.width('100%')
          Row() {
            ForEach(['日', '一', '二', '三', '四', '五', '六'], (label: string) => {
              Text(label).fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).textAlign(TextAlign.Center).layoutWeight(1)
            }, (label: string) => label)
          }.width('100%')
          Grid() {
            ForEach(this.calendarDays(), (item: CalendarDay) => {
              GridItem() {
                if (item.day === 0) {
                  Blank().height(44)
                } else {
                  Column({ space: 3 }) {
                    Text(`${item.day}`).fontSize(AppTheme.metaSize)
                      .fontWeight(this.selectedDate === item.date ? FontWeight.Bold : FontWeight.Regular)
                      .fontColor(this.selectedDate === item.date ? AppTheme.onAccent : AppTheme.ink)
                    if (item.courseCount > 0) {
                      Text(`${item.courseCount}`).fontSize(AppTheme.metaSize)
                        .fontColor(this.selectedDate === item.date ? AppTheme.onAccent : AppTheme.accent)
                    } else {
                      Text('·').fontSize(AppTheme.metaSize).fontColor(AppTheme.separator)
                    }
                  }.width('100%').height(44).justifyContent(FlexAlign.Center)
                    .backgroundColor(this.selectedDate === item.date ? AppTheme.accent : AppTheme.field)
                    .borderRadius(12).onClick(() => this.selectedDate = item.date)
                }
              }
            }, (item: CalendarDay) => item.key)
          }.columnsTemplate('repeat(7, 1fr)').columnsGap(4).rowsGap(4).width('100%')
            .height(this.calendarDays().length > 35 ? 288 : 240)

          Column({ space: 9 }) {
            Row() {
              Text(this.selectedDate).fontSize(AppTheme.metaSize).fontWeight(FontWeight.Bold).fontColor(AppTheme.accent)
              Blank()
              Text(`${this.selectedCourses().length} 节课`).fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary)
            }.width('100%')
            if (this.selectedCourses().length === 0) {
              Text('当天没有课程安排').fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%')
            } else {
              ForEach(this.selectedCourses(), (course: TimetableEntry) => {
                Row({ space: 10 }) {
                  Text(course.start_time).fontSize(AppTheme.metaSize).fontWeight(FontWeight.Bold).fontColor(AppTheme.accent).width(42)
                  Column({ space: 2 }) {
                    Text(course.title).fontSize(AppTheme.metaSize).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink)
                    Text(`${course.location}${course.teacher.length > 0 ? ` · ${course.teacher}` : ''}`)
                      .fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary)
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                }.width('100%').padding(10).backgroundColor(AppTheme.field).borderRadius(13)
              }, (course: TimetableEntry) => `${course.date}-${course.start_time}-${course.title}`)
            }
          }.width('100%').padding(13).backgroundColor(AppTheme.accentSoft).borderRadius(16)
        }.width('100%').padding(17).backgroundColor(AppTheme.surface).borderRadius(22)

        Row({ space: 12 }) {
          Column({ space: 6 }) {
            Text(`${this.overview.progress}%`).fontSize(AppTheme.pageTitle).fontWeight(FontWeight.Bold).fontColor(AppTheme.accent)
            Text('总体进度').fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary)
          }.layoutWeight(1).padding(18).backgroundColor(AppTheme.surface).borderRadius(20)
          Column({ space: 6 }) {
            Text(`${this.overview.due_today}`).fontSize(AppTheme.pageTitle).fontWeight(FontWeight.Bold).fontColor(AppTheme.warning)
            Text('今日到期').fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary)
          }.layoutWeight(1).padding(18).backgroundColor(AppTheme.surface).borderRadius(20)
        }.width('100%')

        Row({ space: 10 }) {
          TextInput({ text: this.title, placeholder: '添加一个待办' }).layoutWeight(1).height(48)
            .backgroundColor(AppTheme.surface).borderRadius(15).onChange((value) => this.title = value)
          Button('+').width(48).height(48).fontSize(23).fontColor(AppTheme.onAccent).backgroundColor(AppTheme.accent)
            .borderRadius(15).onClick(() => this.addTask())
        }.width('100%')

        if (this.errorText.length > 0) {
          Text(this.errorText).fontSize(AppTheme.metaSize).fontColor(AppTheme.danger).width('100%')
        }

        ForEach(this.overview.tasks, (task: PlanningTask) => {
          Row({ space: 13 }) {
            Button(task.status === 'completed' ? '✓' : '')
              .width(44).height(44).fontSize(AppTheme.metaSize).fontColor(AppTheme.onAccent)
              .backgroundColor(task.status === 'completed' ? AppTheme.accent : AppTheme.field)
              .borderRadius(9).onClick(() => this.toggle(task))
            Column({ space: 4 }) {
              Text(task.title).fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium)
                .fontColor(task.status === 'completed' ? AppTheme.muted : AppTheme.ink)
                .decoration({ type: task.status === 'completed' ? TextDecorationType.LineThrough : TextDecorationType.None })
              Text(task.location ?? (task.source === 'agent' ? '由助手创建' : '手动创建'))
                .fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          }.width('100%').padding(17).backgroundColor(AppTheme.surface).borderRadius(18)
        }, (task: PlanningTask) => task.task_id)
      }.width('100%').padding({ left: AppTheme.pageInset, right: AppTheme.pageInset, top: 18, bottom: 110 })
    }.width('100%').height('100%').backgroundColor(AppTheme.canvas)
  }
}
