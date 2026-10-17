import { ChatMessage, PendingAction, PendingMilestonePreview, PendingTaskPreview } from '../model/ApiModels';
import { CampusFlowApi } from '../services/CampusFlowApi';
import { plainMessage } from '../utils/MessageText';
import { AppTheme } from '../theme/AppTheme';
import { AppIcon } from '../components/AppIcon';
import { TaskScheduleDetails } from '../components/TaskScheduleDetails';
import { formatPlanDateTime } from '../utils/PlanPresentation';

@Component
export struct AgentPage {
  @Prop baseUrl: string;
  @Prop token: string;
  @Prop initialPrompt: string = '';
  @Prop @Watch('initialPromptChanged') promptRevision: number = 0;
  onOpenHistory: () => void = () => {};
  onOpenRoute: () => void = () => {};
  onOpenPlan: () => void = () => {};
  @State private prompt: string = '';
  @State private model: string = 'deepseek-v4-pro';
  @State private messages: ChatMessage[] = [
    { role: 'assistant', content: '告诉我你的目标，我会结合课表、校园地点和待办，给出可执行的安排。' }
  ];
  @State private pendingActions: PendingAction[] = [];
  @State private expandedProposalIds: string[] = [];
  @State private loading: boolean = false;
  @State private decisionId: string = '';
  private sessionId: string = `arkuix-${Date.now()}`;
  private chatScroller: Scroller = new Scroller();
  private scrollForNewMessage: boolean = false;

  aboutToAppear(): void {
    if (this.initialPrompt.length > 0) {
      this.prompt = this.initialPrompt;
    }
  }

  private initialPromptChanged(): void {
    if (this.initialPrompt.length > 0) {
      this.prompt = this.initialPrompt;
    }
  }

  private async send(): Promise<void> {
    const text = this.prompt.trim();
    if (text.length === 0 || this.loading) {
      return;
    }
    this.scrollForNewMessage = true;
    this.messages = this.messages.concat([{ role: 'user', content: text }]);
    this.prompt = '';
    this.loading = true;
    try {
      const response = await new CampusFlowApi(this.baseUrl, this.token).chat(this.sessionId, this.model, text);
      this.scrollForNewMessage = true;
      this.messages = this.messages.concat([{ role: 'assistant', content: response.message }]);
      this.pendingActions = response.pending_actions;
      this.expandedProposalIds = this.expandedProposalIds.filter((id: string) =>
        this.pendingActions.some((action: PendingAction) => action.proposal_id === id));
    } catch (error) {
      this.scrollForNewMessage = true;
      this.messages = this.messages.concat([{ role: 'assistant', content: `任务执行失败：${error}` }]);
    } finally {
      this.loading = false;
    }
  }

  private async confirm(action: PendingAction): Promise<void> {
    this.decisionId = action.proposal_id;
    try {
      const result = await new CampusFlowApi(this.baseUrl, this.token).confirmAction(action.proposal_id);
      this.scrollForNewMessage = true;
      this.messages = this.messages.concat([{ role: 'assistant', content: result.message }]);
      if (result.applied) {
        this.pendingActions = this.pendingActions.filter((item) => item.proposal_id !== action.proposal_id);
        this.expandedProposalIds = this.expandedProposalIds.filter((id: string) => id !== action.proposal_id);
        this.onOpenPlan();
      }
    } catch (error) {
      this.scrollForNewMessage = true;
      this.messages = this.messages.concat([{ role: 'assistant', content: `确认失败：${error}` }]);
    } finally {
      this.decisionId = '';
    }
  }

  private async cancel(action: PendingAction): Promise<void> {
    this.decisionId = action.proposal_id;
    try {
      const result = await new CampusFlowApi(this.baseUrl, this.token).cancelAction(action.proposal_id);
      this.scrollForNewMessage = true;
      this.messages = this.messages.concat([{ role: 'assistant', content: result.message }]);
      this.pendingActions = this.pendingActions.filter((item) => item.proposal_id !== action.proposal_id);
      this.expandedProposalIds = this.expandedProposalIds.filter((id: string) => id !== action.proposal_id);
    } catch (error) {
      this.scrollForNewMessage = true;
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
      return `执行时间 ${formatPlanDateTime(action.start_at)}`;
    }
    return '未设置执行时间';
  }

  private proposalExpanded(proposalId: string): boolean {
    return this.expandedProposalIds.includes(proposalId);
  }

  private toggleProposal(proposalId: string): void {
    // Expanding a long plan must not jump the reader to the bottom of the chat.
    this.scrollForNewMessage = false;
    this.expandedProposalIds = this.proposalExpanded(proposalId) ?
      this.expandedProposalIds.filter((id: string) => id !== proposalId) :
      this.expandedProposalIds.concat([proposalId]);
  }

  @Builder
  private ProposalMilestones(action: PendingAction) {
    Column({ space: 12 }) {
      Text('以下时间均为北京时间').fontSize(12).fontColor(AppTheme.secondary).width('100%')
      ForEach(action.payload.milestones ?? [], (milestone: PendingMilestonePreview, milestoneIndex: number) => {
        Column({ space: 10 }) {
          Text(`${milestoneIndex + 1}. ${milestone.title}`)
            .fontSize(15).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink).width('100%')
          Text(`截止：${formatPlanDateTime(milestone.due_at)} · ${milestone.tasks.length} 项任务`)
            .fontSize(12).fontColor(AppTheme.secondary).width('100%')
          if (milestone.tasks.length === 0) {
            Text('这个里程碑尚无任务').fontSize(13).fontColor(AppTheme.secondary).width('100%')
          }
          ForEach(milestone.tasks, (task: PendingTaskPreview, taskIndex: number) => {
            Column({ space: 6 }) {
              Text(`${milestoneIndex + 1}.${taskIndex + 1} ${task.title}`)
                .fontSize(14).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink).width('100%')
              TaskScheduleDetails({ startAt: task.start_at, endAt: task.end_at,
                location: task.location, reminderMinutes: task.reminder_minutes })
            }.width('100%').alignItems(HorizontalAlign.Start).padding(12)
              .backgroundColor(AppTheme.field).borderRadius(12)
          }, (_task: PendingTaskPreview, taskIndex: number) =>
            `${action.proposal_id}-${milestoneIndex}-${taskIndex}`)
        }.width('100%').alignItems(HorizontalAlign.Start).padding(12)
          .backgroundColor(AppTheme.surface).borderRadius(14)
      }, (_milestone: PendingMilestonePreview, milestoneIndex: number) =>
        `${action.proposal_id}-${milestoneIndex}`)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  private choosePrompt(value: string): void {
    this.getUIContext().animateTo({ duration: AppTheme.motion(180), curve: Curve.EaseOut }, () => {
      this.prompt = value;
    });
  }

  @Builder
  private suggestion(title: string, detail: string, icon: string, prompt: string) {
    Row({ space: 13 }) {
      AppIcon({ name: icon, iconSize: 22, color: AppTheme.blue })
      Column({ space: 4 }) {
        Text(title).fontSize(16).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink)
        Text(detail).fontSize(12).fontColor(AppTheme.secondary).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      AppIcon({ name: 'chevron', iconSize: 16, color: AppTheme.muted })
    }.width('100%').padding({ left: 17, right: 16, top: 17, bottom: 17 })
      .constraintSize({ minHeight: 72 }).onClick(() => this.choosePrompt(prompt))
  }

  build() {
    Column() {
      Row({ space: 2 }) {
        Text('CampusFlow').fontSize(17).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
          .layoutWeight(1)
        Button(this.model === 'deepseek-v4-pro' ? 'V4 Pro' : 'Flash')
          .height(44).fontSize(13).fontWeight(FontWeight.Medium).fontColor(AppTheme.blue)
          .backgroundColor(Color.Transparent).padding({ left: 12, right: 12 })
          .onClick(() => {
            this.getUIContext().animateTo({ duration: AppTheme.motion(180), curve: Curve.EaseOut }, () => {
              this.model = this.model === 'deepseek-v4-pro' ? 'deepseek-flash' : 'deepseek-v4-pro';
            });
          })
        Button({ type: ButtonType.Normal }) {
          AppIcon({ name: 'route', iconSize: 22, color: AppTheme.blue })
        }.width(44).height(44).backgroundColor(Color.Transparent).borderRadius(22)
          .accessibilityText('校园路线').onClick(() => this.onOpenRoute())
        Button({ type: ButtonType.Normal }) {
          AppIcon({ name: 'history', iconSize: 22, color: AppTheme.blue })
        }.width(44).height(44).backgroundColor(Color.Transparent).borderRadius(22)
          .accessibilityText('历史会话').onClick(() => this.onOpenHistory())
      }.width('100%').height(56).padding({ left: 20, right: 10 })
        .backgroundColor(AppTheme.bg)

      Scroll(this.chatScroller) {
        Column({ space: 16 }) {
          if (this.messages.length === 1) {
            Column({ space: 12 }) {
              AppIcon({ name: 'agent', iconSize: 38, color: AppTheme.blue })
              Text('有目标，交给我。').fontSize(31).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
                .letterSpacing(-0.6).width('100%')
              Text('结合你的课表与校园信息，\n一起把想法变成可执行的安排。')
                .fontSize(15).lineHeight(24).fontColor(AppTheme.secondary).width('100%')
            }.width('100%').alignItems(HorizontalAlign.Start)
              .padding({ top: 22, bottom: 18, left: 4, right: 4 })
            Column() {
              this.suggestion('安排一段专注时间', '结合课程，找到今天的空闲', 'calendar',
                '根据我今天的课程和待办，找一段合适的空闲时间安排复习，先生成待确认的提案。')
              Divider().color(AppTheme.separator).strokeWidth(0.5).margin({ left: 52 })
              this.suggestion('制定一周复习计划', '分解目标，循序渐进', 'book',
                '结合我的近期课程，帮我制定一周复习计划，分解为里程碑和待办，先生成提案。')
              Divider().color(AppTheme.separator).strokeWidth(0.5).margin({ left: 52 })
              this.suggestion('看看我的校园安排', '查询已同步的个人校园信息', 'classroom',
                '查看我已同步的校园信息，结合最近的课表，提醒我接下来需要关注的事项。')
            }.width('100%').backgroundColor(AppTheme.surface).borderRadius(20).clip(true)
            Text('点击建议填入输入框，准备好后再发送。')
              .fontSize(11).fontColor(AppTheme.muted).width('100%').padding({ left: 4, top: 1 })
          }

          ForEach(this.messages.length === 1 ? [] : this.messages, (message: ChatMessage) => {
            Row() {
              if (message.role === 'user') {
                Blank()
              }
              Text(plainMessage(message.content))
                .fontSize(16).fontColor(message.role === 'user' ? '#FFFFFF' : AppTheme.ink)
                .lineHeight(25).copyOption(CopyOptions.InApp)
                .padding({ left: 16, right: 16, top: 13, bottom: 13 })
                .constraintSize({ maxWidth: '90%' })
                .backgroundColor(message.role === 'user' ? AppTheme.blue : AppTheme.surface)
                .borderRadius(message.role === 'user' ? { topLeft: 20, topRight: 20, bottomLeft: 20, bottomRight: 6 }
                  : { topLeft: 20, topRight: 20, bottomLeft: 6, bottomRight: 20 })
                .transition(TransitionEffect.OPACITY.animation({ duration: AppTheme.motion(180), curve: Curve.EaseOut }))
              if (message.role !== 'user') {
                Blank()
              }
            }.width('100%')
          })

          ForEach(this.pendingActions, (action: PendingAction) => {
            Column({ space: 10 }) {
              Row() {
                Text(action.kind === 'plan' ? '计划提案' : '待办提案')
                  .fontSize(12).fontWeight(FontWeight.Bold).fontColor(AppTheme.blue)
                Blank()
                Text('等待你的确认').fontSize(11).fontColor(AppTheme.secondary)
              }.width('100%')
              Text(action.title).fontSize(18).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink).width('100%')
              Text(this.proposalMeta(action)).fontSize(12).fontColor(AppTheme.secondary).width('100%')
              if ((action.payload.summary ?? '').length > 0) {
                Text(action.payload.summary ?? '').fontSize(14).lineHeight(22).fontColor(AppTheme.secondary).width('100%')
              }
              if (action.kind === 'plan') {
                if ((action.payload.milestones ?? []).length > 0) {
                  Button({ type: ButtonType.Normal }) {
                    Text(this.proposalExpanded(action.proposal_id) ? '收起完整计划' :
                      `查看全部 ${action.payload.milestones?.length ?? 0} 个里程碑 · ${this.proposalTaskCount(action)} 项任务`)
                      .fontSize(14).fontWeight(FontWeight.Medium).fontColor(AppTheme.blue)
                      .width('100%').textAlign(TextAlign.Start)
                  }.width('100%').constraintSize({ minHeight: 48 }).padding(12)
                    .backgroundColor(AppTheme.surface).borderRadius(12)
                    .accessibilityText(`${action.title}，${this.proposalExpanded(action.proposal_id) ? '已展开，收起完整计划' : '已折叠，查看完整计划'}`)
                    .onClick(() => this.toggleProposal(action.proposal_id))
                  if (this.proposalExpanded(action.proposal_id)) {
                    this.ProposalMilestones(action)
                  }
                } else {
                  Text('提案中暂无里程碑，请补充计划后再确认。')
                    .fontSize(13).fontColor(AppTheme.secondary).width('100%')
                }
              } else {
                TaskScheduleDetails({ startAt: action.start_at, endAt: action.end_at,
                  location: action.payload.location ?? null, reminderMinutes: action.reminder_minutes })
              }
              if (action.conflicts.length > 0) {
                Text(`检测到冲突：${action.conflicts.join('；')}`).fontSize(13).fontColor(AppTheme.red).width('100%')
              }
              Row({ space: 9 }) {
                Button('暂不执行').height(46).fontSize(14).fontColor(AppTheme.secondary).backgroundColor(AppTheme.surface).borderRadius(14)
                  .layoutWeight(1).enabled(this.decisionId.length === 0).onClick(() => this.cancel(action))
                Button(this.decisionId === action.proposal_id ? '处理中…' : '确认执行')
                  .height(46).fontSize(14).fontColor('#FFFFFF').backgroundColor(AppTheme.blue).borderRadius(14)
                  .layoutWeight(1).enabled(this.decisionId.length === 0).onClick(() => this.confirm(action))
              }.width('100%')
            }.width('100%').padding(17).backgroundColor(AppTheme.blueSoft).borderRadius(22)
          }, (action: PendingAction) => action.proposal_id)

          if (this.loading) {
            Row({ space: 10 }) {
              LoadingProgress().width(20).height(20).color(AppTheme.blue)
              Text('正在查阅信息、整理安排…').fontSize(13).fontColor(AppTheme.secondary)
            }.width('100%').padding({ left: 5, top: 4, bottom: 4 })
          }
        }.width('100%').padding({ left: 18, right: 18, top: 8, bottom: 24 })
          .onAreaChange(() => {
            if (this.scrollForNewMessage && this.messages.length > 1) {
              this.scrollForNewMessage = false;
              this.chatScroller.scrollEdge(Edge.Bottom);
            }
          })
      }.layoutWeight(1).width('100%').clip(true).scrollBar(BarState.Off).align(Alignment.TopStart)

      Row({ space: 8 }) {
        TextArea({ text: this.prompt, placeholder: '描述你的目标或安排…' })
          .layoutWeight(1).height(this.prompt.length > 36 ? 82 : 48).fontSize(15)
          .fontColor(AppTheme.ink).placeholderColor(AppTheme.muted)
          .backgroundColor(AppTheme.field).borderRadius(22)
          .padding({ left: 15, right: 12, top: 13, bottom: 10 })
          .onChange((value) => this.prompt = value)
        Button('发送').width(64).height(44).fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor(this.prompt.trim().length > 0 ? '#FFFFFF' : AppTheme.muted)
          .backgroundColor(this.prompt.trim().length > 0 ? AppTheme.blue : AppTheme.field).borderRadius(22)
          .enabled(!this.loading && this.prompt.trim().length > 0).onClick(() => this.send())
      }.width('100%').alignItems(VerticalAlign.Bottom)
        .padding({ left: 16, right: 16, top: 10, bottom: 10 }).backgroundColor(AppTheme.surface)
        .border({ width: { top: 0.5 }, color: AppTheme.separator })
    }.width('100%').height('100%').alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Start).backgroundColor(AppTheme.bg)
  }
}
