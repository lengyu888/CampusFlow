import { HistoryMessage, SessionSummary, PendingAction, PendingMilestonePreview, PendingTaskPreview, ToolDisplaySummary } from '../model/ApiModels';
import { CampusFlowApi } from '../services/CampusFlowApi';
import { localHistory } from '../services/LocalHistory';
import { MessageContent } from '../components/MessageContent';
import { AppTheme } from '../theme/AppTheme';
import { AppIcon } from '../components/AppIcon';
import { TaskScheduleDetails } from '../components/TaskScheduleDetails';
import { formatPlanDateTime } from '../utils/PlanPresentation';
import { CampusFlowRequestError, displayToolTraces, mergeActions, restoreDraft, localRequestFailure } from '../utils/AgentFeedback';

interface ConversationEntry {
  id: string;
  role: string;
  content: string;
  tools: ToolDisplaySummary[];
  failedPrompt: string;
  failureCode: string;
}

interface DecisionFeedback {
  proposalId: string;
  message: string;
  needsReview: boolean;
  code: string;
}

@Component
export struct AgentPage {
  @Prop baseUrl: string;
  @Prop token: string;
  @Prop historyScope: string = '';
  @Prop deletedSessionId: string = '';
  @Prop deletionBusy: boolean = false;
  @Prop @Watch('sessionDeleted') deletionRevision: number = 0;
  @Prop initialPrompt: string = '';
  @Prop @Watch('initialPromptChanged') promptRevision: number = 0;
  onOpenHistory: () => void = () => {};
  onOpenRoute: () => void = () => {};
  onOpenPlan: () => void = () => {};
  onOpenProfile: () => void = () => {};
  onChatBusyChange: (busy: boolean) => void = () => {};
  @State private prompt: string = '';
  @State private availableHeight: number = 600;
  @State private model: string = 'deepseek-v4-pro';
  @State private messages: ConversationEntry[] = [
    { id: 'welcome', role: 'assistant', content: '告诉我你的目标，我会结合课表、校园地点和待办，给出可执行的安排。',
      tools: [], failedPrompt: '', failureCode: '' }
  ];
  @State private decisionFeedback: DecisionFeedback[] = [];
  @State private collapsedToolIds: string[] = [];
  private nextMessageId: number = 0;
  @State private pendingActions: PendingAction[] = [];
  @State private expandedProposalIds: string[] = [];
  @State private actionsRevision: number = 0;
  @State private loading: boolean = false;
  @State private decisionId: string = '';
  @State private cacheNotice: string = '';
  private savedMessages: HistoryMessage[] = [];
  private conversationCreatedAt: string = new Date().toISOString();
  private conversationRevision: number = 0;
  private pageActive: boolean = true;
  private sessionId: string = `arkuix-${Date.now()}`;
  private chatScroller: Scroller = new Scroller();
  private scrollForNewMessage: boolean = false;

  aboutToAppear(): void {
    this.pageActive = true;
    if (this.initialPrompt.length > 0) {
      this.prompt = this.initialPrompt;
    }
  }

  aboutToDisappear(): void {
    this.pageActive = false;
    this.conversationRevision++;
  }

  private sessionDeleted(): void {
    if (this.deletedSessionId !== this.sessionId) {
      return;
    }
    this.conversationRevision++;
    this.sessionId = `arkuix-${Date.now()}-${this.conversationRevision}`;
    this.savedMessages = [];
    this.messages = [];
    this.pendingActions = [];
    this.decisionFeedback = [];
    this.expandedProposalIds = [];
    this.conversationCreatedAt = new Date().toISOString();
    this.cacheNotice = '原会话已删除，下次发送将开始新会话。';
  }

  private async saveConversation(text: string, answer: string, sentAt: string): Promise<void> {
    const now = new Date().toISOString();
    this.savedMessages = this.savedMessages.concat([
      { role: 'user', content: text, created_at: sentAt },
      { role: 'assistant', content: answer, created_at: now }
    ]);
    if (this.historyScope.length === 0) {
      this.cacheNotice = '本机保存暂不可用，此对话尚不能离线回看。';
      return;
    }
    const summary: SessionSummary = {
      session_id: this.sessionId, title: Array.from(this.savedMessages[0].content).slice(0, 80).join(''),
      model_name: this.model, last_message: Array.from(answer).slice(0, 200).join(''),
      message_count: this.savedMessages.length, created_at: this.conversationCreatedAt, updated_at: now
    };
    try {
      const saved = await localHistory.save(this.historyScope, summary, this.savedMessages);
      this.cacheNotice = saved ? '对话已保存到本机，可在历史会话离线回看。' : '此会话未保存到本机，请联网回看历史。';
    } catch {
      this.cacheNotice = '本机保存失败，回答仍可阅读；请联网回看历史后重试。';
    }
  }

  private initialPromptChanged(): void {
    if (this.initialPrompt.length > 0) {
      this.prompt = this.initialPrompt;
    }
  }

  private appendMessage(role: string, content: string, tools: ToolDisplaySummary[] = [],
    failedPrompt: string = '', failureCode: string = ''): void {
    this.scrollForNewMessage = true;
    this.nextMessageId++;
    this.messages = this.messages.concat([{
      id: `message-${this.nextMessageId}`, role: role, content: content, tools: tools,
      failedPrompt: failedPrompt, failureCode: failureCode
    }]);
  }

  private safeFailure(error: Error): CampusFlowRequestError {
    if (error instanceof CampusFlowRequestError) {
      return error;
    }
    return new CampusFlowRequestError(0, 'UNKNOWN', '未取得完整结果，请检查连接后再操作。');
  }

  private inputLength(value: string): number {
    return Array.from(value.trim()).length;
  }

  private async send(): Promise<void> {
    const text = this.prompt.trim();
    if (text.length === 0 || this.inputLength(text) > 8000 || this.loading || this.deletionBusy || this.decisionId.length > 0) {
      return;
    }
    this.appendMessage('user', text);
    const revision = this.conversationRevision;
    const sentAt = new Date().toISOString();
    this.prompt = '';
    this.loading = true;
    this.onChatBusyChange(true);
    try {
      const response = await new CampusFlowApi(this.baseUrl, this.token).chat(this.sessionId, this.model, text);
      if (!this.pageActive || revision !== this.conversationRevision) {
        return;
      }
      if (response === null || typeof response.session_id !== 'string' || response.session_id.length === 0 ||
        typeof response.message !== 'string' || !Array.isArray(response.pending_actions)) {
        throw localRequestFailure('INVALID_RESPONSE');
      }
      this.sessionId = response.session_id;
      this.appendMessage('assistant', response.message, displayToolTraces(response.tool_traces));
      // A later turn without proposals must not erase an earlier pending decision.
      this.pendingActions = mergeActions(this.pendingActions, response.pending_actions);
      this.actionsRevision++;
      await this.saveConversation(text, response.message, sentAt);
    } catch (error) {
      if (!this.pageActive || revision !== this.conversationRevision) {
        return;
      }
      const failure = this.safeFailure(error);
      this.prompt = restoreDraft(this.prompt, text);
      this.appendMessage('feedback', failure.message, [], text, failure.code);
    } finally {
      this.loading = false;
      if (this.pageActive) { this.onChatBusyChange(false); }
    }
  }

  private feedbackFor(proposalId: string): DecisionFeedback | undefined {
    return this.decisionFeedback.find((item: DecisionFeedback) => item.proposalId === proposalId);
  }

  private needsReview(proposalId: string): boolean {
    return this.feedbackFor(proposalId)?.needsReview ?? false;
  }

  private setFeedback(proposalId: string, message: string, needsReview: boolean, code: string = ''): void {
    this.decisionFeedback = this.decisionFeedback.filter((item: DecisionFeedback) => item.proposalId !== proposalId)
      .concat([{ proposalId: proposalId, message: message, needsReview: needsReview, code: code }]);
  }

  private replaceAction(action: PendingAction): void {
    this.pendingActions = this.pendingActions.map((item: PendingAction) =>
      item.proposal_id === action.proposal_id ? action : item);
    this.actionsRevision++;
  }

  private decisionLabel(action: PendingAction): string {
    if (this.needsReview(action.proposal_id)) {
      return '结果待核对';
    }
    if (action.status === 'confirmed') {
      return '已确认';
    }
    if (action.status === 'cancelled') {
      return '已取消';
    }
    return '等待你的确认';
  }

  private async decide(action: PendingAction, confirm: boolean): Promise<void> {
    // Guard the handler as well as the buttons against rapid taps and stale callbacks.
    const current = this.pendingActions.find((item: PendingAction) => item.proposal_id === action.proposal_id);
    if (this.loading || this.decisionId.length > 0 || current === undefined || current.status !== 'pending' ||
      this.needsReview(action.proposal_id) || (confirm && current.action !== 'create')) {
      return;
    }
    this.decisionId = action.proposal_id;
    try {
      const api = new CampusFlowApi(this.baseUrl, this.token);
      const result = confirm ? await api.confirmAction(action.proposal_id) : await api.cancelAction(action.proposal_id);
      const expectedStatus = confirm ? 'confirmed' : 'cancelled';
      if (result.action.proposal_id === action.proposal_id && result.action.status === expectedStatus &&
        result.applied === confirm) {
        this.replaceAction(result.action);
        this.setFeedback(action.proposal_id, confirm ? '已确认，可到规划查看具体任务。' : '提案已取消。', false);
      } else {
        this.setFeedback(action.proposal_id, '服务返回的状态与本次操作不一致。请核对状态和规划，暂不重复提交。', true);
      }
    } catch (error) {
      const failure = this.safeFailure(error);
      const rejectedBeforeWrite = failure.code === 'LOGIN_REQUIRED' || failure.code === 'ACTION_UNSUPPORTED';
      this.setFeedback(action.proposal_id,
        rejectedBeforeWrite ? failure.message : `${failure.message} 请核对状态和规划，暂不重复提交。`,
        !rejectedBeforeWrite, failure.code);
    } finally {
      this.decisionId = '';
    }
  }

  private async checkDecision(action: PendingAction): Promise<void> {
    if (this.loading || this.decisionId.length > 0) {
      return;
    }
    this.decisionId = action.proposal_id;
    try {
      const latest = await new CampusFlowApi(this.baseUrl, this.token).actionStatus(action.proposal_id);
      if (latest.proposal_id !== action.proposal_id ||
        !['pending', 'confirmed', 'cancelled'].includes(latest.status)) {
        this.setFeedback(action.proposal_id, '未取得可核验的提案状态，请到规划核对。', true);
        return;
      }
      this.replaceAction(latest);
      const state = latest.status === 'confirmed' ? '已确认' : latest.status === 'cancelled' ? '已取消' : '待确认';
      // A status read cannot prove that a failed transaction left no partial tasks.
      this.setFeedback(action.proposal_id,
        `服务端记录为「${state}」。上次操作的实际写入仍需到规划核对，本会话不重复提交。`, true);
    } catch (error) {
      const failure = this.safeFailure(error);
      this.setFeedback(action.proposal_id, `暂时无法核对状态。${failure.message}`, true, failure.code);
    } finally {
      this.decisionId = '';
    }
  }

  private toolStateLabel(state: string): string {
    switch (state) {
      case 'success': return '已返回';
      case 'empty': return '暂无数据';
      case 'error': return '调用失败';
      case 'unavailable': return '暂不可用';
      case 'pending': return '待确认';
      case 'demo': return '演示数据';
      default: return '未核验';
    }
  }

  private toolStateColor(state: string): string {
    if (state === 'error') {
      return AppTheme.red;
    }
    if (state === 'unavailable' || state === 'unverified' || state === 'demo') {
      return AppTheme.orange;
    }
    return AppTheme.secondary;
  }

  private toggleToolResults(messageId: string): void {
    this.scrollForNewMessage = false;
    this.collapsedToolIds = this.collapsedToolIds.includes(messageId) ?
      this.collapsedToolIds.filter((id: string) => id !== messageId) : this.collapsedToolIds.concat([messageId]);
  }

  @Builder
  private ToolResults(message: ConversationEntry) {
    Column({ space: 8 }) {
      if (message.tools.length === 0) {
        Text('本轮未返回工具记录').fontSize(12).fontColor(AppTheme.secondary).width('100%')
      } else {
        Button({ type: ButtonType.Normal }) {
          Text(`本轮工具记录 · ${message.tools.length} 项 · ${this.collapsedToolIds.includes(message.id) ? '展开' : '收起'}`)
            .fontSize(12).fontColor(AppTheme.blue).width('100%').textAlign(TextAlign.Start)
        }.width('100%').constraintSize({ minHeight: 44 }).padding(0).backgroundColor(Color.Transparent)
          .onClick(() => this.toggleToolResults(message.id))
        if (!this.collapsedToolIds.includes(message.id)) {
          ForEach(message.tools, (item: ToolDisplaySummary) => {
            Column({ space: 4 }) {
              Row({ space: 8 }) {
                Text(item.label).fontSize(13).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink).layoutWeight(1)
                Text(this.toolStateLabel(item.state)).fontSize(11).fontColor(this.toolStateColor(item.state))
              }.width('100%')
              Text(item.summary).fontSize(12).fontColor(AppTheme.secondary).width('100%')
            }.width('100%').alignItems(HorizontalAlign.Start).padding(10)
              .backgroundColor(AppTheme.field).borderRadius(10)
          }, (_item: ToolDisplaySummary, index: number) => `${message.id}-tool-${index}`)
        }
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private RequestFailure(message: ConversationEntry) {
    Column({ space: 8 }) {
      Text('请求未完成').fontSize(14).fontWeight(FontWeight.Bold).fontColor(AppTheme.red).width('100%')
      Text(message.content).fontSize(13).fontColor(AppTheme.ink).width('100%')
      Text('原输入已保留在对话中，可复制或恢复后手动发送。若请求曾到达服务端，请先查看历史和已有提案。')
        .fontSize(12).fontColor(AppTheme.secondary).width('100%')
      Button(this.inputLength(this.prompt) > 0 ? '输入框已有草稿' : '恢复本次输入')
        .constraintSize({ minHeight: 44 }).fontSize(13).fontColor(AppTheme.blue)
        .backgroundColor(AppTheme.blueSoft).enabled(!this.loading && this.inputLength(this.prompt) === 0)
        .onClick(() => this.prompt = restoreDraft(this.prompt, message.failedPrompt))
      if (message.failureCode === 'LOGIN_REQUIRED' || message.failureCode === 'MODEL_AUTH_INVALID' ||
        message.failureCode === 'MODEL_KEY_REQUIRED') {
        Text(message.failureCode === 'LOGIN_REQUIRED' ? '重新登录前，请先复制要保留的输入。' : '可在「我的」检查模型 API Key。')
          .fontSize(12).fontColor(AppTheme.secondary).width('100%')
        Button('前往我的').constraintSize({ minHeight: 44 }).fontSize(13)
          .fontColor(AppTheme.blue).backgroundColor(AppTheme.blueSoft).onClick(() => this.onOpenProfile())
      }
    }.width('100%').padding(14).alignItems(HorizontalAlign.Start)
      .backgroundColor(AppTheme.surface).borderRadius(16)
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
        Text(detail).fontSize(12).fontColor(AppTheme.secondary).width('100%')
          .wordBreak(WordBreak.BREAK_WORD)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      AppIcon({ name: 'chevron', iconSize: 16, color: AppTheme.muted })
    }.width('100%').padding({ left: 17, right: 16, top: 17, bottom: 17 })
      .constraintSize({ minHeight: 72 }).onClick(() => this.choosePrompt(prompt))
  }

  build() {
    Column() {
      Row({ space: 2 }) {
        Text('CampusFlow').fontSize(17).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
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
        }.width(48).height(48).backgroundColor(Color.Transparent).borderRadius(22)
          .accessibilityText('校园路线').onClick(() => this.onOpenRoute())
        Button({ type: ButtonType.Normal }) {
          AppIcon({ name: 'history', iconSize: 22, color: AppTheme.blue })
        }.width(48).height(48).backgroundColor(Color.Transparent).borderRadius(22)
          .accessibilityText('历史会话').onClick(() => this.onOpenHistory())
      }.width('100%').constraintSize({ minHeight: 56 }).padding({ left: 16, right: 10 })
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

          ForEach(this.messages.length === 1 ? [] : this.messages, (message: ConversationEntry) => {
            if (message.role === 'feedback') {
              this.RequestFailure(message)
            } else {
              Row() {
                if (message.role === 'user') {
                  Blank()
                }
                Column({ space: 8 }) {
                  MessageContent({ content: message.content, isUser: message.role === 'user' })
                  if (message.role === 'assistant' && message.id !== 'welcome') {
                    this.ToolResults(message)
                  }
                }.alignItems(HorizontalAlign.Start)
                  .padding({ left: 16, right: 16, top: 13, bottom: 13 })
                  .width(message.role === 'user' ? '90%' : '100%')
                  .backgroundColor(message.role === 'user' ? AppTheme.blue : AppTheme.surface)
                  .borderRadius(message.role === 'user' ? { topLeft: 20, topRight: 20, bottomLeft: 20, bottomRight: 6 }
                    : { topLeft: 20, topRight: 20, bottomLeft: 6, bottomRight: 20 })
                if (message.role !== 'user') {
                  Blank()
                }
              }.width('100%')
            }
          }, (message: ConversationEntry) => message.id)

          ForEach(this.pendingActions, (action: PendingAction) => {
            Column({ space: 10 }) {
              Row() {
                Text(action.kind === 'plan' ? '计划提案' : '待办提案')
                  .fontSize(12).fontWeight(FontWeight.Bold).fontColor(AppTheme.blue)
                Blank()
                Text(this.decisionLabel(action)).fontSize(11)
                  .fontColor(this.needsReview(action.proposal_id) ? AppTheme.orange : AppTheme.secondary)
              }.width('100%')
              Text(action.title).fontSize(18).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink).width('100%')
                .wordBreak(WordBreak.BREAK_WORD)
              Text(this.proposalMeta(action)).fontSize(12).fontColor(AppTheme.secondary).width('100%')
              if ((action.payload.summary ?? '').length > 0) {
                Text(action.payload.summary ?? '').fontSize(14).fontColor(AppTheme.secondary).width('100%')
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
              if (this.feedbackFor(action.proposal_id) !== undefined) {
                Text(this.feedbackFor(action.proposal_id)?.message ?? '')
                  .fontSize(13).width('100%')
                  .fontColor(this.needsReview(action.proposal_id) ? AppTheme.orange : AppTheme.ink)
              }
              if (this.feedbackFor(action.proposal_id)?.code === 'LOGIN_REQUIRED') {
                Button('前往我的重新登录').constraintSize({ minHeight: 48 }).fontSize(13).fontColor(AppTheme.blue)
                  .backgroundColor(AppTheme.surface).onClick(() => this.onOpenProfile())
              }
              if (this.needsReview(action.proposal_id)) {
                Row({ space: 9 }) {
                  Button(this.decisionId === action.proposal_id ? '核对中…' : '核对状态')
                    .constraintSize({ minHeight: 48 }).fontSize(14).fontColor(AppTheme.blue).backgroundColor(AppTheme.surface)
                    .layoutWeight(1).enabled(!this.loading && this.decisionId.length === 0)
                    .onClick(() => this.checkDecision(action))
                  Button('查看规划').constraintSize({ minHeight: 48 }).fontSize(14).fontColor('#FFFFFF').backgroundColor(AppTheme.blue)
                    .layoutWeight(1).onClick(() => this.onOpenPlan())
                }.width('100%')
              } else if (action.status === 'confirmed') {
                Button('查看规划').constraintSize({ minHeight: 48 }).fontSize(14).fontColor('#FFFFFF').backgroundColor(AppTheme.blue)
                  .width('100%').onClick(() => this.onOpenPlan())
              } else if (action.status === 'pending') {
                if (action.action !== 'create') {
                  Text('暂不支持通过提案修改或删除已有任务，请到规划页操作。')
                    .fontSize(13).fontColor(AppTheme.secondary).width('100%')
                }
                Row({ space: 9 }) {
                  Button('暂不执行').constraintSize({ minHeight: 48 }).fontSize(14).fontColor(AppTheme.secondary)
                    .backgroundColor(AppTheme.surface).borderRadius(14).layoutWeight(1)
                    .enabled(!this.loading && this.decisionId.length === 0).onClick(() => this.decide(action, false))
                  Button(this.decisionId === action.proposal_id ? '处理中…' : '确认执行')
                    .constraintSize({ minHeight: 48 }).fontSize(14).fontColor('#FFFFFF').backgroundColor(AppTheme.blue).borderRadius(14)
                    .layoutWeight(1).enabled(!this.loading && this.decisionId.length === 0 && action.action === 'create')
                    .onClick(() => this.decide(action, true))
                }.width('100%')
              }
            }.width('100%').padding(17).backgroundColor(AppTheme.blueSoft).borderRadius(22)
          }, (action: PendingAction) => `${action.proposal_id}-${action.status}-${this.actionsRevision}`)

          if (this.loading) {
            Row({ space: 10 }) {
              LoadingProgress().width(20).height(20).color(AppTheme.blue)
              Text('正在处理请求…').fontSize(13).fontColor(AppTheme.secondary)
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

      if (this.cacheNotice.length > 0) {
        Text(this.cacheNotice).fontSize(12).fontColor(AppTheme.secondary).width('100%')
          .padding({ left: 18, right: 18, top: 6, bottom: 4 })
      }
      if (this.deletionBusy) {
        Text('正在删除会话，完成后可继续发送。').fontSize(12).fontColor(AppTheme.secondary).width('100%')
          .padding({ left: 18, right: 18, top: 6, bottom: 4 })
      }
      if (this.inputLength(this.prompt) > 8000) {
        Text(`当前 ${this.inputLength(this.prompt)} 字，超过 8000 字上限，请精简后发送。原文仍保留在输入框中。`)
          .fontSize(12).fontColor(AppTheme.red).width('100%')
          .padding({ left: 18, right: 18, top: 6, bottom: 6 })
      }
      Row({ space: 8 }) {
        TextArea({ text: this.prompt, placeholder: '描述你的目标或安排…' })
          .layoutWeight(1).fontSize(16)
          .constraintSize({ minHeight: 48, maxHeight: Math.max(48, Math.min(160, this.availableHeight * 0.3)) })
          .accessibilityText('输入目标或安排')
          .fontColor(AppTheme.ink).placeholderColor(AppTheme.muted)
          .backgroundColor(AppTheme.field).borderRadius(22)
          .padding({ left: 15, right: 12, top: 13, bottom: 10 })
          .onChange((value) => this.prompt = value)
        Button('发送').constraintSize({ minWidth: 64, minHeight: 48 }).fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor(this.inputLength(this.prompt) > 0 && this.inputLength(this.prompt) <= 8000 ? '#FFFFFF' : AppTheme.muted)
          .backgroundColor(this.inputLength(this.prompt) > 0 && this.inputLength(this.prompt) <= 8000 ? AppTheme.blue : AppTheme.field).borderRadius(22)
          .enabled(!this.loading && !this.deletionBusy && this.decisionId.length === 0 && this.inputLength(this.prompt) > 0 && this.inputLength(this.prompt) <= 8000).onClick(() => this.send())
      }.width('100%').alignItems(VerticalAlign.Bottom)
        .padding({ left: 16, right: 16, top: 10, bottom: 10 }).backgroundColor(AppTheme.surface)
        .border({ width: { top: 0.5 }, color: AppTheme.separator })
    }.width('100%').height('100%').alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Start).backgroundColor(AppTheme.bg)
      .onAreaChange((_oldArea: Area, newArea: Area) => {
        const height = Number(newArea.height);
        if (height > 0 && height !== this.availableHeight) {
          this.availableHeight = height;
        }
      })
  }
}
