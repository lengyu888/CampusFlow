import { ChatMessage, PendingAction, PendingMilestonePreview } from '../model/ApiModels';
import { CampusFlowApi } from '../services/CampusFlowApi';
import { plainMessage } from '../utils/MessageText';

@Component
export struct AgentPage {
  @Prop baseUrl: string;
  @Prop token: string;
  @Prop initialPrompt: string = '';
  onOpenHistory: () => void = () => {};
  onOpenRoute: () => void = () => {};
  onOpenPlan: () => void = () => {};
  @State private prompt: string = '';
  @State private model: string = 'deepseek-v4-pro';
  @State private messages: ChatMessage[] = [
    { role: 'assistant', content: '告诉我你的目标，我会结合课表、校园地点和待办，给出可执行的安排。' }
  ];
  @State private pendingActions: PendingAction[] = [];
  @State private loading: boolean = false;
  @State private decisionId: string = '';
  private sessionId: string = `arkuix-${Date.now()}`;

  aboutToAppear(): void {
    if (this.initialPrompt.length > 0) {
      this.prompt = this.initialPrompt;
    }
  }

  private async send(): Promise<void> {
    const text = this.prompt.trim();
    if (text.length === 0 || this.loading) {
      return;
    }
    this.messages = this.messages.concat([{ role: 'user', content: text }]);
    this.prompt = '';
    this.loading = true;
    try {
      const response = await new CampusFlowApi(this.baseUrl, this.token).chat(this.sessionId, this.model, text);
      this.messages = this.messages.concat([{ role: 'assistant', content: response.message }]);
      this.pendingActions = response.pending_actions;
    } catch (error) {
      this.messages = this.messages.concat([{ role: 'assistant', content: `任务执行失败：${error}` }]);
    } finally {
      this.loading = false;
    }
  }

  private async confirm(action: PendingAction): Promise<void> {
    this.decisionId = action.proposal_id;
    try {
      const result = await new CampusFlowApi(this.baseUrl, this.token).confirmAction(action.proposal_id);
      this.messages = this.messages.concat([{ role: 'assistant', content: result.message }]);
      this.pendingActions = this.pendingActions.filter((item) => item.proposal_id !== action.proposal_id);
      this.onOpenPlan();
    } catch (error) {
      this.messages = this.messages.concat([{ role: 'assistant', content: `确认失败：${error}` }]);
    } finally {
      this.decisionId = '';
    }
  }

  private async cancel(action: PendingAction): Promise<void> {
    this.decisionId = action.proposal_id;
    try {
      const result = await new CampusFlowApi(this.baseUrl, this.token).cancelAction(action.proposal_id);
      this.messages = this.messages.concat([{ role: 'assistant', content: result.message }]);
      this.pendingActions = this.pendingActions.filter((item) => item.proposal_id !== action.proposal_id);
    } catch (error) {
      this.messages = this.messages.concat([{ role: 'assistant', content: `操作失败：${error}` }]);
    } finally {
      this.decisionId = '';
    }
  }

  private proposalTaskCount(action: PendingAction): number {
    const milestones = action.payload.milestones ?? [];
    let count = 0;
    milestones.forEach((milestone: PendingMilestonePreview) => count += milestone.tasks.length);
    return count;
  }

  private proposalMeta(action: PendingAction): string {
    if (action.kind === 'plan') {
      const milestoneCount = (action.payload.milestones ?? []).length;
      const target = action.payload.target_date ?? '未设截止日';
      return `${milestoneCount} 个里程碑 · ${this.proposalTaskCount(action)} 项任务 · ${target}`;
    }
    if (action.start_at !== null) {
      return `执行时间 ${action.start_at.substring(0, 16).replace('T', ' ')}`;
    }
    return '未设置执行时间';
  }

  build() {
    Column() {
      Scroll() {
        Column({ space: 14 }) {
          Row() {
            Column({ space: 3 }) {
              Text('任务会话').fontSize(25).fontWeight(FontWeight.Bold).fontColor('#171A22')
              Text('Agent 会先规划，再调用工具').fontSize(12).fontColor('#7B8292')
            }.alignItems(HorizontalAlign.Start)
            Blank()
            Button('路线').height(34).fontSize(11).fontColor('#315BFF')
              .backgroundColor('#E9EEFF').borderRadius(18).margin({ right: 8 })
              .onClick(() => this.onOpenRoute())
            Button('历史').height(34).fontSize(11).fontColor('#5F6675')
              .backgroundColor('#FFFFFF').borderRadius(18).margin({ right: 8 })
              .onClick(() => this.onOpenHistory())
            Button(this.model === 'deepseek-v4-pro' ? 'V4 PRO' : 'FLASH')
              .height(34).fontSize(11).fontColor('#315BFF').backgroundColor('#E9EEFF').borderRadius(18)
              .onClick(() => this.model = this.model === 'deepseek-v4-pro' ? 'deepseek-flash' : 'deepseek-v4-pro')
          }.width('100%')

          ForEach(this.messages, (message: ChatMessage) => {
            Row() {
              if (message.role === 'user') {
                Blank()
              }
              Text(plainMessage(message.content))
                .fontSize(14).fontColor(message.role === 'user' ? '#FFFFFF' : '#272B34')
                .lineHeight(22)
                .padding(15)
                .constraintSize({ maxWidth: '86%' })
                .backgroundColor(message.role === 'user' ? '#315BFF' : '#FFFFFF')
                .borderRadius(message.role === 'user' ? { topLeft: 18, topRight: 5, bottomLeft: 18, bottomRight: 18 }
                  : { topLeft: 5, topRight: 18, bottomLeft: 18, bottomRight: 18 })
              if (message.role !== 'user') {
                Blank()
              }
            }.width('100%')
          })

          ForEach(this.pendingActions, (action: PendingAction) => {
            Column({ space: 10 }) {
              Row() {
                Text(action.kind === 'plan' ? '计划提案' : '待办提案')
                  .fontSize(11).fontWeight(FontWeight.Bold).fontColor('#FF6B4A')
                Blank()
                Text('确认后才会写入').fontSize(10).fontColor('#8B91A0')
              }.width('100%')
              Text(action.title).fontSize(16).fontWeight(FontWeight.Bold).fontColor('#171A22').width('100%')
              Text(this.proposalMeta(action)).fontSize(11).fontColor('#626A7A').width('100%')
              if ((action.payload.summary ?? '').length > 0) {
                Text(action.payload.summary ?? '').fontSize(12).lineHeight(18).fontColor('#4D5360').width('100%')
              }
              if (action.kind === 'plan') {
                ForEach((action.payload.milestones ?? []).slice(0, 3), (milestone: PendingMilestonePreview) => {
                  Row({ space: 8 }) {
                    Text('○').fontSize(13).fontColor('#315BFF')
                    Text(milestone.title).fontSize(12).fontWeight(FontWeight.Medium).fontColor('#272B34')
                      .layoutWeight(1)
                    Text(`${milestone.tasks.length} 项`).fontSize(10).fontColor('#8B91A0')
                  }.width('100%').padding({ top: 7, bottom: 7, left: 10, right: 10 })
                    .backgroundColor('#FFFFFF').borderRadius(10)
                }, (milestone: PendingMilestonePreview) => milestone.title)
              }
              if (action.conflicts.length > 0) {
                Text(`检测到冲突：${action.conflicts.join('；')}`).fontSize(12).fontColor('#D33D3D').width('100%')
              }
              Row({ space: 9 }) {
                Button('暂不执行').height(40).fontColor('#5F6675').backgroundColor('#FFFFFF').borderRadius(12)
                  .layoutWeight(1).enabled(this.decisionId.length === 0).onClick(() => this.cancel(action))
                Button(this.decisionId === action.proposal_id ? '处理中…' : '确认执行')
                  .height(40).fontColor('#FFFFFF').backgroundColor('#315BFF').borderRadius(12)
                  .layoutWeight(1).enabled(this.decisionId.length === 0).onClick(() => this.confirm(action))
              }.width('100%')
            }.width('100%').padding(16).backgroundColor('#FFF4EE').borderRadius(20)
          }, (action: PendingAction) => action.proposal_id)

          if (this.loading) {
            Text('Agent 正在规划与调用工具…').fontSize(12).fontColor('#7B8292').width('100%')
          }
        }.width('100%').padding({ left: 16, right: 16, top: 16, bottom: 20 })
      }.layoutWeight(1).width('100%').clip(true)

      Row({ space: 10 }) {
        TextArea({ text: this.prompt, placeholder: '例如：从六教去菜鸟驿站，顺便安排复习…' })
          .layoutWeight(1).height(58).backgroundColor('#F4F6FA').borderRadius(18)
          .onChange((value) => this.prompt = value)
        Button('发送').width(68).height(48).fontColor('#FFFFFF').backgroundColor('#315BFF').borderRadius(16)
          .enabled(!this.loading).onClick(() => this.send())
      }.width('100%').padding({ left: 14, right: 14, top: 10, bottom: 10 }).backgroundColor('#FFFFFF')
        .border({ width: { top: 1 }, color: '#E8EBF2' })
    }.width('100%').height('100%').backgroundColor('#F5F7FB')
  }
}
