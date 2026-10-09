import {
  PlanningOverview,
  PlanningTask,
  TimetableEntry,
  UserContextResponse
} from '../model/ApiModels';
import { CampusFlowApi } from '../services/CampusFlowApi';

interface CalendarDay {
  key: string;
  day: number;
  date: string;
  courseCount: number;
  taskCount: number;
}

@Component
export struct PlanCenterPage {
  @Prop baseUrl: string;
  @Prop token: string;
  onOpenAgent: (prompt: string) => void = () => {};
  @State private overview: PlanningOverview = {
    plans: [], tasks: [], total_tasks: 0, completed_tasks: 0, due_today: 0, overdue_tasks: 0, progress: 0
  };
  @State private title: string = '';
  @State private errorText: string = '';
  @State private timetable: TimetableEntry[] = [];
  @State private calendarMonth: number = new Date(new Date().getFullYear(), new Date().getMonth(), 1).getTime();
  @State private selectedDate: string = '';
  @State private draftTaskDate: string = '';
  @State private deletePendingId: string = '';
  private taskInputController: TextInputController = new TextInputController();

  aboutToAppear(): void {
    this.selectedDate = this.dateKey(new Date());
    this.draftTaskDate = this.selectedDate;
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

  private taskDate(task: PlanningTask): string {
    return task.start_at === null ? '' : task.start_at.substring(0, 10);
  }

  private taskTime(task: PlanningTask): string {
    if (task.start_at === null) {
      return '待安排';
    }
    const start = task.start_at.substring(11, 16);
    if (task.source === 'manual' && task.end_at === null) {
      return '全天';
    }
    return task.end_at === null ? start : `${start}–${task.end_at.substring(11, 16)}`;
  }

  private relativeDate(offset: number): string {
    const date = new Date();
    date.setDate(date.getDate() + offset);
    return this.dateKey(date);
  }

  private taskOverdue(task: PlanningTask): boolean {
    if (task.status === 'completed' || task.start_at === null) {
      return false;
    }
    return new Date(task.end_at ?? task.start_at).getTime() < Date.now();
  }

  private calendarDays(): CalendarDay[] {
    const month = new Date(this.calendarMonth);
    const year = month.getFullYear();
    const monthIndex = month.getMonth();
    const firstWeekday = new Date(year, monthIndex, 1).getDay();
    const count = new Date(year, monthIndex + 1, 0).getDate();
    const result: CalendarDay[] = [];
    for (let index = 0; index < firstWeekday; index++) {
      result.push({ key: `blank-${index}`, day: 0, date: '', courseCount: 0, taskCount: 0 });
    }
    for (let day = 1; day <= count; day++) {
      const key = this.dateKey(new Date(year, monthIndex, day));
      result.push({
        key: key,
        day: day,
        date: key,
        courseCount: this.timetable.filter((course: TimetableEntry) => course.date === key).length,
        taskCount: this.overview.tasks.filter((task: PlanningTask) => this.taskDate(task) === key).length
      });
    }
    return result;
  }

  private selectedCourses(): TimetableEntry[] {
    return this.timetable.filter((course: TimetableEntry) => course.date === this.selectedDate);
  }

  private selectedTasks(): PlanningTask[] {
    return this.overview.tasks.filter((task: PlanningTask) => this.taskDate(task) === this.selectedDate);
  }

  private unscheduledCount(): number {
    return this.overview.tasks.filter((task: PlanningTask) => task.start_at === null && task.status === 'pending').length;
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
      this.errorText = '';
    } catch (error) {
      this.errorText = `规划加载失败：${error}`;
    }
  }

  private async addTask(): Promise<void> {
    if (this.title.trim().length === 0) {
      return;
    }
    try {
      const startAt = this.draftTaskDate.length === 0 ? null : `${this.draftTaskDate}T23:59:00+08:00`;
      await new CampusFlowApi(this.baseUrl, this.token).createTask(this.title.trim(), startAt);
      this.title = '';
      this.taskInputController.stopEditing();
      await this.reload();
    } catch (error) {
      this.errorText = `创建失败：${error}`;
    }
  }

  private async toggle(task: PlanningTask): Promise<void> {
    try {
      await new CampusFlowApi(this.baseUrl, this.token).updateTask(task.task_id, task.status !== 'completed');
      this.deletePendingId = '';
      await this.reload();
    } catch (error) {
      this.errorText = `更新失败：${error}`;
    }
  }

  private async requestDelete(task: PlanningTask): Promise<void> {
    if (this.deletePendingId !== task.task_id) {
      this.deletePendingId = task.task_id;
      return;
    }
    try {
      await new CampusFlowApi(this.baseUrl, this.token).deleteTask(task.task_id);
      this.deletePendingId = '';
      await this.reload();
    } catch (error) {
      this.errorText = `删除失败：${error}`;
    }
  }

  private planPrompt(): string {
    return '请读取我的课表和未完成待办，为未来 7 天制定一份可执行的学习计划。要求避开课程冲突，拆分里程碑和具体任务，为每项任务设置明确时间、地点与提醒；先展示提案，等我确认后再写入规划。';
  }

  private reviewPrompt(): string {
    return '请结合我的近期课程和未完成任务，安排今天晚上的复习计划。先检查时间冲突，给出具体时间段和提醒，等待我确认后再写入。';
  }

  @Builder
  private DayTimeline() {
    Column({ space: 9 }) {
      Row() {
        Text(this.selectedDate).fontSize(12).fontWeight(FontWeight.Bold).fontColor('#315BFF')
        Blank()
        Text(`${this.selectedCourses().length} 节课 · ${this.selectedTasks().length} 项任务`)
          .fontSize(11).fontColor('#7B8292')
      }.width('100%')
      if (this.selectedCourses().length === 0 && this.selectedTasks().length === 0) {
        Text('当天没有课程或任务安排').fontSize(12).fontColor('#8B91A0').width('100%')
      }
      ForEach(this.selectedCourses(), (course: TimetableEntry) => {
        Row({ space: 10 }) {
          Text(course.start_time).fontSize(12).fontWeight(FontWeight.Bold).fontColor('#315BFF').width(42)
          Column({ space: 2 }) {
            Text(course.title).fontSize(13).fontWeight(FontWeight.Medium).fontColor('#171A22')
            Text(`${course.location}${course.teacher.length > 0 ? ` · ${course.teacher}` : ''}`)
              .fontSize(10).fontColor('#8B91A0')
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Text('课程').fontSize(9).fontColor('#315BFF').padding({ left: 7, right: 7, top: 3, bottom: 3 })
            .backgroundColor('#E9EEFF').borderRadius(8)
        }.width('100%').padding(10).backgroundColor('#FFFFFF').borderRadius(13)
      }, (course: TimetableEntry) => `${course.date}-${course.start_time}-${course.title}`)
      ForEach(this.selectedTasks(), (task: PlanningTask) => {
        Row({ space: 10 }) {
          Text(this.taskTime(task)).fontSize(11).fontWeight(FontWeight.Bold).fontColor('#FF6B4A').width(72)
          Column({ space: 2 }) {
            Text(task.title).fontSize(13).fontWeight(FontWeight.Medium)
              .fontColor(task.status === 'completed' ? '#999EAA' : '#171A22')
            Text(task.location ?? (task.source === 'agent' ? 'Agent 计划' : '手动创建'))
              .fontSize(10).fontColor('#8B91A0')
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Button(task.status === 'completed' ? '✓' : '○').width(32).height(30).fontSize(12)
            .fontColor(task.status === 'completed' ? '#FFFFFF' : '#315BFF')
            .backgroundColor(task.status === 'completed' ? '#315BFF' : '#E9EEFF')
            .borderRadius(10).onClick(() => this.toggle(task))
        }.width('100%').padding(10).backgroundColor('#FFFFFF').borderRadius(13)
      }, (task: PlanningTask) => `${task.task_id}-${task.status}-${task.completed_at ?? ''}`)
    }.width('100%').padding(13).backgroundColor('#EEF2FF').borderRadius(16)
  }

  build() {
    Scroll() {
      Column({ space: 18 }) {
        Row() {
          Column({ space: 4 }) {
            Text('规划').fontSize(28).fontWeight(FontWeight.Bold).fontColor('#171A22')
            Text('把目标拆成每天真正做得完的行动').fontSize(13).fontColor('#777E8F')
          }.alignItems(HorizontalAlign.Start)
          Blank()
          Button('智能规划').height(38).fontSize(12).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
            .backgroundColor('#315BFF').borderRadius(14).onClick(() => this.onOpenAgent(this.planPrompt()))
        }.width('100%')

        Column({ space: 11 }) {
          Row() {
            Column({ space: 5 }) {
              Text('让 Agent 安排这一周').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
              Text('读取课表与待办 · 检查冲突 · 确认后写入').fontSize(11).fontColor('#DCE4FF')
            }.alignItems(HorizontalAlign.Start)
            Blank()
            Text('↗').fontSize(24).fontColor('#FFFFFF')
          }.width('100%')
          Row({ space: 8 }) {
            Button('生成 7 天计划').height(36).fontSize(11).fontColor('#315BFF').backgroundColor('#FFFFFF')
              .borderRadius(12).layoutWeight(1).onClick(() => this.onOpenAgent(this.planPrompt()))
            Button('安排今晚复习').height(36).fontSize(11).fontColor('#FFFFFF').backgroundColor('#4B6FFF')
              .borderRadius(12).layoutWeight(1).onClick(() => this.onOpenAgent(this.reviewPrompt()))
          }.width('100%')
        }.width('100%').padding(17).backgroundColor('#171A22').borderRadius(22)

        Column({ space: 12 }) {
          Row() {
            Button('上月').width(56).height(34).fontSize(10).fontColor('#315BFF')
              .backgroundColor('#E9EEFF').borderRadius(12).onClick(() => this.moveMonth(-1))
            Blank()
            Text(this.monthLabel()).fontSize(18).fontWeight(FontWeight.Bold).fontColor('#171A22')
            Blank()
            Button('下月').width(56).height(34).fontSize(10).fontColor('#315BFF')
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
                  Blank().height(46)
                } else {
                  Column({ space: 4 }) {
                    Text(`${item.day}`).fontSize(12)
                      .fontWeight(this.selectedDate === item.date ? FontWeight.Bold : FontWeight.Regular)
                      .fontColor(this.selectedDate === item.date ? '#FFFFFF' : '#171A22')
                    Row({ space: 3 }) {
                      if (item.courseCount > 0) {
                        Circle().width(4).height(4).fill(this.selectedDate === item.date ? '#FFFFFF' : '#315BFF')
                      }
                      if (item.taskCount > 0) {
                        Circle().width(4).height(4).fill(this.selectedDate === item.date ? '#BFD0FF' : '#FF6B4A')
                      }
                    }
                  }.width('100%').height(46).justifyContent(FlexAlign.Center)
                    .backgroundColor(this.selectedDate === item.date ? '#315BFF' : '#F5F7FB')
                    .borderRadius(12).onClick(() => this.selectedDate = item.date)
                }
              }
            }, (item: CalendarDay) =>
              `${item.key}-${item.courseCount}-${item.taskCount}-${this.selectedDate}`)
          }.columnsTemplate('repeat(7, 1fr)').columnsGap(4).rowsGap(4).width('100%')
            .height(this.calendarDays().length > 35 ? 300 : 250)
          this.DayTimeline()
        }.width('100%').padding(17).backgroundColor('#FFFFFF').borderRadius(22)

        Row({ space: 12 }) {
          Column({ space: 6 }) {
            Text(`${this.overview.progress}%`).fontSize(28).fontWeight(FontWeight.Bold).fontColor('#315BFF')
            Text('总体进度').fontSize(12).fontColor('#777E8F')
          }.layoutWeight(1).padding(18).backgroundColor('#FFFFFF').borderRadius(20)
          Column({ space: 6 }) {
            Text(`${this.overview.due_today}`).fontSize(28).fontWeight(FontWeight.Bold).fontColor('#FF6B4A')
            Text(this.overview.overdue_tasks > 0 ? `今日待执行 · ${this.overview.overdue_tasks} 项逾期` : '今日待执行')
              .fontSize(11).fontColor(this.overview.overdue_tasks > 0 ? '#D94D43' : '#777E8F')
          }.layoutWeight(1).padding(18).backgroundColor('#FFFFFF').borderRadius(20)
        }.width('100%')

        Column({ space: 10 }) {
          Row() {
            Column({ space: 3 }) {
              Text('待办收集箱').fontSize(17).fontWeight(FontWeight.Bold).fontColor('#171A22')
              Text(`${this.unscheduledCount()} 项尚未安排具体时间`).fontSize(10).fontColor('#8B91A0')
            }.alignItems(HorizontalAlign.Start)
            Blank()
            Text(`${this.overview.completed_tasks}/${this.overview.total_tasks} 已完成`)
              .fontSize(10).fontColor('#315BFF')
          }.width('100%')
          Row({ space: 10 }) {
            TextInput({ text: this.title, placeholder: '快速记录一个待办', controller: this.taskInputController })
              .layoutWeight(1).height(46)
              .backgroundColor('#F4F6FA').borderRadius(14).onChange((value) => this.title = value)
            Button('+').width(46).height(46).fontSize(22).fontColor('#FFFFFF').backgroundColor('#315BFF')
              .borderRadius(14).onClick(() => this.addTask())
          }.width('100%')
          Row() {
            Text('待办日期').fontSize(10).fontColor('#8B91A0')
            Blank()
            Text(this.draftTaskDate.length === 0 ? '无日期' : this.draftTaskDate)
              .fontSize(10).fontWeight(FontWeight.Medium).fontColor('#315BFF')
          }.width('100%')
          Row({ space: 6 }) {
            Button('今天').height(30).fontSize(9).layoutWeight(1)
              .fontColor(this.draftTaskDate === this.relativeDate(0) ? '#FFFFFF' : '#315BFF')
              .backgroundColor(this.draftTaskDate === this.relativeDate(0) ? '#315BFF' : '#E9EEFF')
              .borderRadius(10).onClick(() => this.draftTaskDate = this.relativeDate(0))
            Button('明天').height(30).fontSize(9).layoutWeight(1)
              .fontColor(this.draftTaskDate === this.relativeDate(1) ? '#FFFFFF' : '#315BFF')
              .backgroundColor(this.draftTaskDate === this.relativeDate(1) ? '#315BFF' : '#E9EEFF')
              .borderRadius(10).onClick(() => this.draftTaskDate = this.relativeDate(1))
            Button('日历所选').height(30).fontSize(9).layoutWeight(1).fontColor('#315BFF')
              .backgroundColor('#E9EEFF').borderRadius(10).onClick(() => this.draftTaskDate = this.selectedDate)
            Button('无日期').height(30).fontSize(9).layoutWeight(1)
              .fontColor(this.draftTaskDate.length === 0 ? '#FFFFFF' : '#6F7687')
              .backgroundColor(this.draftTaskDate.length === 0 ? '#315BFF' : '#F0F2F6')
              .borderRadius(10).onClick(() => this.draftTaskDate = '')
          }.width('100%')
        }.width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(20)

        if (this.errorText.length > 0) {
          Text(this.errorText).fontSize(12).fontColor('#D33D3D').width('100%')
        }

        ForEach(this.overview.tasks, (task: PlanningTask) => {
          Row({ space: 12 }) {
            Button(task.status === 'completed' ? '✓' : '').width(28).height(28).fontSize(13).fontColor('#FFFFFF')
              .backgroundColor(task.status === 'completed' ? '#315BFF' : '#E8EBF2')
              .borderRadius(9).onClick(() => this.toggle(task))
            Column({ space: 4 }) {
              Text(task.title).fontSize(14).fontWeight(FontWeight.Medium)
                .fontColor(task.status === 'completed' ? '#999EAA' : '#171A22')
                .decoration({ type: task.status === 'completed' ?
                  TextDecorationType.LineThrough : TextDecorationType.None })
              Text(`${this.taskDate(task).length > 0 ? this.taskDate(task) + ' · ' + this.taskTime(task) : '待安排时间'}${task.location === null ? '' : ' · ' + task.location}`)
                .fontSize(10).fontColor(this.taskOverdue(task) ? '#D94D43' : '#8B91A0')
              if (this.taskOverdue(task)) {
                Text('已逾期').fontSize(9).fontColor('#D94D43')
              }
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Button(this.deletePendingId === task.task_id ? '确认' : '删除').height(30).fontSize(10)
              .fontColor(this.deletePendingId === task.task_id ? '#FFFFFF' : '#A25B55')
              .backgroundColor(this.deletePendingId === task.task_id ? '#E4564F' : '#FFF0EE')
              .borderRadius(10).onClick(() => this.requestDelete(task))
          }.width('100%').padding(15).backgroundColor('#FFFFFF').borderRadius(18)
        }, (task: PlanningTask) => `${task.task_id}-${task.status}-${task.completed_at ?? ''}`)
      }.width('100%').padding({ left: 18, right: 18, top: 18, bottom: 110 })
    }.width('100%').height('100%').backgroundColor('#F5F7FB')
  }
}
