import { PlanningOverview, PlanningTask } from '../model/ApiModels';
import { CampusFlowApi } from '../services/CampusFlowApi';

@Component
export struct PlanPage {
  @Prop baseUrl: string;
  @Prop token: string;
  @State private overview: PlanningOverview = {
    tasks: [], total_tasks: 0, completed_tasks: 0, due_today: 0, progress: 0
  };
  @State private title: string = '';
  @State private errorText: string = '';

  aboutToAppear(): void {
    this.reload();
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
          Text('把每一步变成可完成的行动').fontSize(13).fontColor('#777E8F')
        }.width('100%').alignItems(HorizontalAlign.Start)

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
