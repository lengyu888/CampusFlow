import { ChatMessage, PendingAction, PendingMilestonePreview } from '../model/ApiModels';
import { CampusFlowApi } from '../services/CampusFlowApi';
import { plainMessage } from '../utils/MessageText';
import { AppTheme } from '../theme/AppTheme';
import { AppIcon } from '../components/AppIcon';

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
  @State private loading: boolean = false;
  @State private decisionId: string = '';
  private sessionId: string = `arkuix-${Date.now()}`;
  private chatScroller: Scroller = new Scroller();

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
                ForEach((action.payload.milestones ?? []).slice(0, 3), (milestone: PendingMilestonePreview) => {
                  Row({ space: 8 }) {
                    AppIcon({ name: 'calendar', iconSize: 16, color: AppTheme.blue })
                    Text(milestone.title).fontSize(13).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink)
                      .layoutWeight(1)
                    Text(`${milestone.tasks.length} 项`).fontSize(11).fontColor(AppTheme.muted)
                  }.width('100%').padding({ top: 7, bottom: 7, left: 10, right: 10 })
                    .backgroundColor(AppTheme.surface).borderRadius(12)
                }, (milestone: PendingMilestonePreview) => milestone.title)
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
            if (this.messages.length > 1) {
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
