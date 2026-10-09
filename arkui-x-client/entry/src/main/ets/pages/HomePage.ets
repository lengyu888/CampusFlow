import {
  PlanningOverview,
  PlanningTask,
  PlanSummary,
  TimetableEntry,
  UserContextResponse,
  UserProfile
} from '../model/ApiModels';
import { CampusFlowApi } from '../services/CampusFlowApi';

@Component
export struct HomePage {
  @Prop baseUrl: string;
  @Prop token: string;
  @Prop user: UserProfile;
  onOpenAgent: () => void = () => {};
  onOpenPlan: () => void = () => {};
  onOpenRoute: () => void = () => {};
  onOpenServices: () => void = () => {};
  @State private courses: TimetableEntry[] = [];
  @State private overview: PlanningOverview = {
    plans: [], tasks: [], total_tasks: 0, completed_tasks: 0, due_today: 0, overdue_tasks: 0, progress: 0
  };
  @State private planDeletePendingId: string = '';
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
      const api = new CampusFlowApi(this.baseUrl, this.token);
      const context: UserContextResponse = await api.context();
      const today = this.today();
      this.courses = context.timetable.filter((course) => course.date === today);
      this.overview = await api.planning();
    } catch (error) {
      this.errorText = `今日数据加载失败：${error}`;
    } finally {
      this.loading = false;
    }
  }

  private activePlans(): PlanSummary[] {
    return this.overview.plans.filter((plan: PlanSummary) => plan.status !== 'completed');
  }

  private todayTasks(): PlanningTask[] {
    const today = this.today();
    return this.overview.tasks.filter((task: PlanningTask) =>
      task.status === 'pending' && (task.start_at === null || task.start_at.substring(0, 10) === today)
    ).slice(0, 5);
  }

  private taskSchedule(task: PlanningTask): string {
    if (task.start_at === null) {
      return '尚未安排日期';
    }
    if (task.source === 'manual' && task.end_at === null) {
      return task.start_at.substring(0, 10);
    }
    return `${task.start_at.substring(0, 10)} · ${task.start_at.substring(11, 16)}`;
  }

  private async reloadPlanning(): Promise<void> {
    this.overview = await new CampusFlowApi(this.baseUrl, this.token).planning();
  }

  private async toggleTask(task: PlanningTask): Promise<void> {
    try {
      await new CampusFlowApi(this.baseUrl, this.token).updateTask(task.task_id, true);
      await this.reloadPlanning();
      this.errorText = '';
    } catch (error) {
      this.errorText = `待办更新失败：${error}`;
    }
  }

  private async requestDeletePlan(plan: PlanSummary): Promise<void> {
    if (this.planDeletePendingId !== plan.plan_id) {
      this.planDeletePendingId = plan.plan_id;
      return;
    }
    try {
      await new CampusFlowApi(this.baseUrl, this.token).deletePlan(plan.plan_id);
      this.planDeletePendingId = '';
      await this.reloadPlanning();
      this.errorText = '';
    } catch (error) {
      this.errorText = `计划删除失败：${error}`;
    }
  }

  @Builder
  private PlanProgressCard(plan: PlanSummary) {
    Column({ space: 10 }) {
      Row() {
        Column({ space: 3 }) {
          Text(plan.title).fontSize(15).fontWeight(FontWeight.Bold).fontColor('#171A22')
          Text(plan.target_date === null ? '持续计划' : `目标 ${plan.target_date}`)
            .fontSize(10).fontColor('#7B8292')
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Column({ space: 3 }) {
          Text(`${plan.progress}%`).fontSize(20).fontWeight(FontWeight.Bold).fontColor('#315BFF')
          Text(plan.status === 'overdue' ? '已逾期' : '进行中').fontSize(9)
            .fontColor(plan.status === 'overdue' ? '#D94D43' : '#7B8292')
        }.alignItems(HorizontalAlign.End)
      }.width('100%')
      if (plan.summary.length > 0) {
        Text(plan.summary).fontSize(11).lineHeight(17).fontColor('#626A7A').maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      }
      Row() {
        Row().height(6).width(`${plan.progress}%`).backgroundColor('#315BFF').borderRadius(3)
      }.width('100%').height(6).backgroundColor('#E7EBF5').borderRadius(3)
      Row() {
        Text(`${plan.completed_count}/${plan.task_count} 项完成`).fontSize(10).fontColor('#7B8292')
        Blank()
        if (plan.status === 'overdue') {
          Button(this.planDeletePendingId === plan.plan_id ? '确认删除' : '删除逾期计划')
            .height(30).fontSize(9)
            .fontColor(this.planDeletePendingId === plan.plan_id ? '#FFFFFF' : '#A25B55')
            .backgroundColor(this.planDeletePendingId === plan.plan_id ? '#E4564F' : '#FFF0EE')
            .borderRadius(10).onClick(() => this.requestDeletePlan(plan))
        }
      }.width('100%')
    }.width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(20)
  }

  @Builder
  private TodayTaskCard(task: PlanningTask) {
    Row({ space: 12 }) {
      Button('').width(28).height(28).backgroundColor('#E8EBF2').borderRadius(9)
        .onClick(() => this.toggleTask(task))
      Column({ space: 4 }) {
        Text(task.title).fontSize(14).fontWeight(FontWeight.Medium).fontColor('#171A22')
        Text(this.taskSchedule(task)).fontSize(10).fontColor('#8B91A0')
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Text(task.source === 'agent' ? '计划' : '待办').fontSize(9).fontColor('#315BFF')
        .padding({ left: 7, right: 7, top: 3, bottom: 3 }).backgroundColor('#E9EEFF').borderRadius(8)
    }.width('100%').padding(15).backgroundColor('#FFFFFF').borderRadius(18)
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
          Text('计划进展').fontSize(19).fontWeight(FontWeight.Bold).fontColor('#171A22')
          Blank()
          Text(`${this.activePlans().length} 个`).fontSize(12).fontColor('#7D8493')
        }.width('100%')

        if (this.activePlans().length === 0) {
          Row() {
            Column({ space: 5 }) {
              Text('暂无进行中的计划').fontSize(15).fontWeight(FontWeight.Bold).fontColor('#171A22')
              Text('已完成计划会自动从今日页移出。').fontSize(11).fontColor('#7D8493')
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Button('去规划').height(34).fontSize(10).fontColor('#315BFF').backgroundColor('#E9EEFF')
              .borderRadius(11).onClick(() => this.onOpenPlan())
          }.width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(18)
        } else {
          ForEach(this.activePlans(), (plan: PlanSummary) => {
            this.PlanProgressCard(plan)
          }, (plan: PlanSummary) =>
            `${plan.plan_id}-${plan.status}-${plan.progress}-${plan.completed_count}-${this.planDeletePendingId}`)
        }

        Row() {
          Text('今日待办').fontSize(19).fontWeight(FontWeight.Bold).fontColor('#171A22')
          Blank()
          Text(`${this.todayTasks().length} 项`).fontSize(12).fontColor('#7D8493')
        }.width('100%')

        if (this.todayTasks().length === 0) {
          Row() {
            Text('今天没有待执行事项').fontSize(13).fontColor('#7D8493').layoutWeight(1)
            Button('添加待办').height(34).fontSize(10).fontColor('#315BFF').backgroundColor('#E9EEFF')
              .borderRadius(11).onClick(() => this.onOpenPlan())
          }.width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(18)
        } else {
          ForEach(this.todayTasks(), (task: PlanningTask) => {
            this.TodayTaskCard(task)
          }, (task: PlanningTask) => `${task.task_id}-${task.status}-${task.completed_at ?? ''}`)
        }

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
