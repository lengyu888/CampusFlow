import { HistoryMessage, SessionSummary, PendingAction, PendingMilestonePreview, PendingTaskPreview, ToolDisplaySummary } from '../model/ApiModels';
import { CampusFlowApi } from '../services/CampusFlowApi';
import { localHistory } from '../services/LocalHistory';
import { MessageContent } from '../components/MessageContent';
import { AppTheme } from '../theme/AppTheme';
import { AppIcon } from '../components/AppIcon';
import { TaskScheduleDetails } from '../components/TaskScheduleDetails';
import { formatPlanDateTime } from '../utils/PlanPresentation';
import { CampusFlowRequestError, displayToolTraces, mergeActions, restoreDraft, localRequestFailure } from '../utils/AgentFeedback';
import common from '@ohos.app.ability.common';
import { PlatformVoiceDriver } from '../services/PlatformVoiceDriver';
import { VoiceInteraction, VoiceState } from '../utils/VoiceInteraction';

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

interface ProposalOrigin {
  proposalId: string;
  messageId: string;
}

interface ChatAnchor {
  id: string;
  y: number;
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
  @Prop @Watch('voiceActivityChanged') voiceActive: boolean = false;
  onOpenHistory: () => void = () => {};
  onOpenRoute: () => void = () => {};
  onOpenPlan: () => void = () => {};
  onOpenProfile: () => void = () => {};
  onChatBusyChange: (busy: boolean) => void = () => {};
  @State private prompt: string = '';
  @State private availableHeight: number = 600;
  @State private model: string = 'deepseek-v4-pro';
  @State private optionsExpanded: boolean = false;
  @State private promptSuggestions: string[] = [];
  @State private suggestionNotice: string = '';
  private receivedPromptRevision: number = -1;
  @State private messages: ConversationEntry[] = [
    { id: 'welcome', role: 'assistant', content: '告诉我你的目标，我会结合课表、校园地点和待办，给出可执行的安排。',
      tools: [], failedPrompt: '', failureCode: '' }
  ];
  @State private decisionFeedback: DecisionFeedback[] = [];
  @State private collapsedToolIds: string[] = [];
  private nextMessageId: number = 0;
  @State private pendingActions: PendingAction[] = [];
  @State private proposalOrigins: ProposalOrigin[] = [];
  @State private expandedReceiptIds: string[] = [];
  @State private focusedProposalId: string = '';
  @State private expandedProposalIds: string[] = [];
  @State private actionsRevision: number = 0;
  @State private loading: boolean = false;
  @State private decisionId: string = '';
  @State private cacheNotice: string = '';
  @State private voiceState: VoiceState = { phase: 'idle', transcript: '', message: '', speakingMessageId: '' };
  @State private voiceNotice: string = '';
  private voiceInteraction: VoiceInteraction | null = null;
  private savedMessages: HistoryMessage[] = [];
  private conversationCreatedAt: string = new Date().toISOString();
  private conversationRevision: number = 0;
  private pageActive: boolean = true;
  private sessionId: string = `arkuix-${Date.now()}`;
  private chatScroller: Scroller = new Scroller();
  private scrollForNewMessage: boolean = false;
  private followLatest: boolean = true;
  @State private unreadMessages: number = 0;
  private scrollOffset: number = 0;
  private viewportHeight: number = 0;
  private contentHeight: number = 0;
  private messageAnchors: ChatAnchor[] = [];
  private proposalAnchors: ChatAnchor[] = [];
  private pendingJumpId: string = '';
  private optionsReturnOffset: number = 0;
  private restoreOptionsOffset: number = -1;

  aboutToAppear(): void {
    this.pageActive = true;
    if (this.receivedPromptRevision !== this.promptRevision) {
      this.initialPromptChanged();
    }
  }

  aboutToDisappear(): void {
    this.pageActive = false;
    this.conversationRevision++;
    this.voiceInteraction?.dispose();
    this.voiceInteraction = null;
  }

  private sessionDeleted(): void {
    if (this.deletedSessionId !== this.sessionId) {
      return;
    }
    this.cancelVoice();
    this.conversationRevision++;
    this.sessionId = `arkuix-${Date.now()}-${this.conversationRevision}`;
    this.savedMessages = [];
    this.messages = [];
    this.pendingActions = [];
    this.proposalOrigins = [];
    this.expandedReceiptIds = [];
    this.messageAnchors = [];
    this.proposalAnchors = [];
    this.pendingJumpId = '';
    this.focusedProposalId = '';
    this.unreadMessages = 0;
    this.loading = false;
    this.decisionId = '';
    this.onChatBusyChange(false);
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
    this.receivedPromptRevision = this.promptRevision;
    if (this.initialPrompt.length > 0) {
      this.offerPrompt(this.initialPrompt);
    }
  }

  private offerPrompt(value: string): void {
    if (value.trim().length === 0) { return; }
    this.voiceInteraction?.suspend();
    if (this.inputLength(this.prompt) === 0 && this.inputLength(value) <= 8000) {
      this.prompt = value;
      this.suggestionNotice = '建议已填入，请检查后手动发送。';
    } else if (value.trim() !== this.prompt.trim() && !this.promptSuggestions.includes(value)) {
      this.promptSuggestions = this.promptSuggestions.concat([value]);
      this.suggestionNotice = '原草稿已保留。可追加建议，或清空输入后采用。';
    }
  }

  private applySuggestion(append: boolean): void {
    const suggestion = this.promptSuggestions[0];
    if (suggestion === undefined) { return; }
    if (!append && this.inputLength(this.prompt) > 0) {
      this.suggestionNotice = '输入框已有草稿，请先清空后采用，或选择追加。';
      return;
    }
    const combined = append && this.inputLength(this.prompt) > 0 ? `${this.prompt.trim()}\n${suggestion.trim()}` : suggestion;
    if (this.inputLength(combined) > 8000) {
      this.suggestionNotice = '合并后超过 8000 字，原草稿和建议均已保留。请缩短输入后再操作。';
      return;
    }
    this.prompt = combined;
    this.promptSuggestions = this.promptSuggestions.slice(1);
    this.suggestionNotice = '建议已填入，请检查后手动发送。';
  }

  private dismissSuggestion(): void {
    this.promptSuggestions = this.promptSuggestions.slice(1);
    this.suggestionNotice = '已略过这条建议，输入草稿未改变。';
  }

  private choosePrompt(value: string): void {
    this.offerPrompt(value);
  }

  private selectModel(value: string): void {
    if (this.loading || this.decisionId.length > 0 || this.deletionBusy ||
      !['deepseek-v4-pro', 'deepseek-flash'].includes(value)) { return; }
    this.model = value;
  }

  private toggleOptions(): void {
    this.scrollForNewMessage = false;
    if (!this.optionsExpanded) {
      this.optionsReturnOffset = this.scrollOffset;
      this.optionsExpanded = true;
      this.chatScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: false });
    } else {
      this.optionsExpanded = false;
      this.restoreOptionsOffset = this.optionsReturnOffset;
    }
  }

  private appendMessage(role: string, content: string, tools: ToolDisplaySummary[] = [],
    failedPrompt: string = '', failureCode: string = ''): string {
    this.scrollForNewMessage = this.voiceActive && (role === 'user' || this.followLatest);
    if (role !== 'user' && !this.scrollForNewMessage) { this.unreadMessages++; }
    this.nextMessageId++;
    this.messages = this.messages.concat([{
      id: `message-${this.nextMessageId}`, role: role, content: content, tools: tools,
      failedPrompt: failedPrompt, failureCode: failureCode
    }]);
    if (role === 'assistant') { this.collapsedToolIds = this.collapsedToolIds.concat([`message-${this.nextMessageId}`]); }
    return `message-${this.nextMessageId}`;
  }

  private linkProposals(messageId: string, actions: PendingAction[]): void {
    const origins = this.proposalOrigins.slice();
    actions.forEach((action: PendingAction) => {
      if (!origins.some((origin: ProposalOrigin) => origin.proposalId === action.proposal_id)) {
        origins.push({ proposalId: action.proposal_id, messageId: messageId });
      }
    });
    this.proposalOrigins = origins;
  }

  private actionsForMessage(messageId: string): PendingAction[] {
    return this.pendingActions.filter((action: PendingAction) => this.proposalOrigins.some((origin: ProposalOrigin) =>
      origin.proposalId === action.proposal_id && origin.messageId === messageId));
  }

  private attentionActions(): PendingAction[] {
    return this.pendingActions.filter((action: PendingAction) => action.status === 'pending' || this.needsReview(action.proposal_id));
  }

  private attentionLabel(): string {
    const pending = this.pendingActions.filter((action: PendingAction) => action.status === 'pending' && !this.needsReview(action.proposal_id)).length;
    const review = this.pendingActions.filter((action: PendingAction) => this.needsReview(action.proposal_id)).length;
    return `${pending} 份待确认${review > 0 ? ` · ${review} 份结果待核对` : ''}`;
  }

  private receiptCollapsed(action: PendingAction): boolean {
    return !this.needsReview(action.proposal_id) && ['confirmed', 'cancelled'].includes(action.status) &&
      !this.expandedReceiptIds.includes(action.proposal_id);
  }

  private toggleReceipt(proposalId: string): void {
    this.scrollForNewMessage = false;
    this.expandedReceiptIds = this.expandedReceiptIds.includes(proposalId) ?
      this.expandedReceiptIds.filter((id: string) => id !== proposalId) : this.expandedReceiptIds.concat([proposalId]);
  }

  private rememberMessageAnchor(id: string, y: number): void {
    if (!Number.isFinite(y)) { return; }
    this.messageAnchors = this.messageAnchors.filter((anchor: ChatAnchor) => anchor.id !== id).concat([{ id: id, y: y }]);
    this.flushProposalJump();
  }

  private rememberProposalAnchor(id: string, y: number): void {
    if (!Number.isFinite(y)) { return; }
    this.proposalAnchors = this.proposalAnchors.filter((anchor: ChatAnchor) => anchor.id !== id).concat([{ id: id, y: y }]);
    this.flushProposalJump();
  }

  private jumpToNextProposal(): void {
    const actions = this.attentionActions();
    if (actions.length === 0) { return; }
    const index = actions.findIndex((action: PendingAction) => action.proposal_id === this.focusedProposalId);
    this.pendingJumpId = actions[(index + 1) % actions.length].proposal_id;
    this.scrollForNewMessage = false;
    this.followLatest = false;
    this.flushProposalJump();
  }

  private flushProposalJump(): void {
    if (this.pendingJumpId.length === 0 || !this.voiceActive) { return; }
    const origin = this.proposalOrigins.find((item: ProposalOrigin) => item.proposalId === this.pendingJumpId);
    const message = this.messageAnchors.find((anchor: ChatAnchor) => anchor.id === origin?.messageId);
    const proposal = this.proposalAnchors.find((anchor: ChatAnchor) => anchor.id === this.pendingJumpId);
    if (message === undefined || proposal === undefined) { return; }
    this.chatScroller.scrollTo({ xOffset: 0, yOffset: Math.max(0, message.y + proposal.y - 8), animation: false });
    this.focusedProposalId = this.pendingJumpId;
    this.pendingJumpId = '';
  }

  private recordScrollOffset(offset: number): void {
    if (!Number.isFinite(offset)) { return; }
    this.scrollOffset = offset;
    this.followLatest = this.contentHeight <= this.viewportHeight ||
      this.contentHeight - this.viewportHeight - offset <= 48;
    if (this.followLatest) { this.unreadMessages = 0; }
    else { this.scrollForNewMessage = false; }
  }

  private chatContentChanged(height: number): void {
    this.contentHeight = height;
    if (this.restoreOptionsOffset >= 0) {
      this.chatScroller.scrollTo({ xOffset: 0, yOffset: this.restoreOptionsOffset, animation: false });
      this.restoreOptionsOffset = -1;
      return;
    }
    if (this.voiceActive && this.scrollForNewMessage) {
      this.scrollForNewMessage = false;
      this.unreadMessages = 0;
      this.chatScroller.scrollEdge(Edge.Bottom);
    }
    this.flushProposalJump();
  }

  private viewLatest(): void {
    this.followLatest = true;
    this.unreadMessages = 0;
    this.scrollForNewMessage = false;
    this.chatScroller.scrollEdge(Edge.Bottom);
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

  private voiceActivityChanged(): void {
    // Index keeps hidden tabs mounted. Also stop when the Ability enters background.
    if (!this.voiceActive) {
      this.scrollForNewMessage = false;
      this.voiceInteraction?.suspend();
    }
  }

  private voiceController(): VoiceInteraction {
    if (this.voiceInteraction === null) {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
      this.voiceInteraction = new VoiceInteraction(new PlatformVoiceDriver(context), (state: VoiceState) => {
        if (this.pageActive) {
          if (this.voiceActive && this.followLatest && state.phase !== this.voiceState.phase) { this.scrollForNewMessage = true; }
          this.voiceState = state;
        }
      });
    }
    return this.voiceInteraction;
  }

  private capturePending(): boolean {
    return this.voiceState.phase === 'starting' || this.voiceState.phase === 'listening' ||
      this.voiceState.phase === 'recognizing' || this.voiceState.phase === 'review';
  }

  private speechPending(): boolean {
    return this.voiceState.phase === 'preparingSpeech' || this.voiceState.phase === 'speaking';
  }

  private async startVoice(): Promise<void> {
    if (!this.pageActive || !this.voiceActive || this.loading || this.deletionBusy ||
      this.decisionId.length > 0 || this.capturePending()) { return; }
    this.voiceNotice = '';
    this.followLatest = true;
    this.scrollForNewMessage = true;
    await this.voiceController().startListening();
  }

  private cancelVoice(): void {
    this.voiceInteraction?.cancel();
    this.voiceNotice = '';
  }

  private editVoiceTranscript(value: string): void {
    this.voiceNotice = '';
    this.voiceInteraction?.editTranscript(value);
  }

  private useVoiceTranscript(): void {
    if (this.voiceState.phase !== 'review' || this.voiceInteraction === null) { return; }
    const transcript = this.voiceState.transcript.trim();
    if (transcript.length === 0) { this.voiceInteraction.takeTranscript(); return; }
    const draft = this.prompt.trim();
    const combined = draft.length === 0 ? transcript : `${draft}\n${transcript}`;
    if (this.inputLength(combined) > 8000) {
      this.voiceNotice = '合并后超过 8000 字，请缩短识别文字，或编辑下方原输入。两份文字均已保留。';
      return;
    }
    const accepted = this.voiceInteraction.takeTranscript();
    if (accepted.length === 0) { return; }
    this.prompt = combined;
    this.voiceNotice = '文字已填入，请检查后手动发送。';
  }

  private async speakReply(message: ConversationEntry): Promise<void> {
    if (!this.pageActive || !this.voiceActive || message.role !== 'assistant' || message.id === 'welcome' ||
      !this.messages.some((item: ConversationEntry) => item.id === message.id && item.role === 'assistant')) { return; }
    if (this.speechPending() && this.voiceState.speakingMessageId === message.id) {
      this.cancelVoice();
      return;
    }
    if (this.loading || this.deletionBusy || this.decisionId.length > 0 || this.capturePending()) { return; }
    this.voiceNotice = '';
    await this.voiceController().speak(message.id, message.content);
  }

  private async send(): Promise<void> {
    const text = this.prompt.trim();
    if (!this.pageActive || text.length === 0 || this.inputLength(text) > 8000 || this.loading || this.deletionBusy ||
      this.decisionId.length > 0 || this.capturePending()) {
      return;
    }
    this.cancelVoice();
    this.optionsExpanded = false;
    this.followLatest = true;
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
      const messageId = this.appendMessage('assistant', response.message, displayToolTraces(response.tool_traces));
      // A later turn without proposals must not erase an earlier pending decision.
      this.pendingActions = mergeActions(this.pendingActions, response.pending_actions);
      this.linkProposals(messageId, response.pending_actions);
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
      if (revision === this.conversationRevision) {
        this.loading = false;
        if (this.pageActive) { this.onChatBusyChange(false); }
      }
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
    if (!this.pageActive || this.deletionBusy || this.loading || this.decisionId.length > 0 || current === undefined || current.status !== 'pending' ||
      this.needsReview(action.proposal_id) || (confirm && current.action !== 'create')) {
      return;
    }
    this.decisionId = action.proposal_id;
    const revision = this.conversationRevision;
    try {
      const api = new CampusFlowApi(this.baseUrl, this.token);
      const result = confirm ? await api.confirmAction(action.proposal_id) : await api.cancelAction(action.proposal_id);
      if (!this.pageActive || revision !== this.conversationRevision) { return; }
      const expectedStatus = confirm ? 'confirmed' : 'cancelled';
      if (result.action.proposal_id === action.proposal_id && result.action.status === expectedStatus &&
        result.applied === confirm) {
        this.replaceAction(result.action);
        this.setFeedback(action.proposal_id, confirm ? '已确认，可到计划列表查看具体任务。' : '提案已取消。', false);
      } else {
        this.setFeedback(action.proposal_id, '服务返回的状态与本次操作不一致。请核对状态和计划列表，暂不重复提交。', true);
      }
    } catch (error) {
      if (!this.pageActive || revision !== this.conversationRevision) { return; }
      const failure = this.safeFailure(error);
      const rejectedBeforeWrite = failure.code === 'LOGIN_REQUIRED' || failure.code === 'ACTION_UNSUPPORTED';
      this.setFeedback(action.proposal_id,
        rejectedBeforeWrite ? failure.message : `${failure.message} 请核对状态和计划列表，暂不重复提交。`,
        !rejectedBeforeWrite, failure.code);
    } finally {
      if (revision === this.conversationRevision) { this.decisionId = ''; }
    }
  }

  private async checkDecision(action: PendingAction): Promise<void> {
    if (!this.pageActive || this.deletionBusy || this.loading || this.decisionId.length > 0 ||
      !this.pendingActions.some((item: PendingAction) => item.proposal_id === action.proposal_id)) {
      return;
    }
    this.decisionId = action.proposal_id;
    const revision = this.conversationRevision;
    try {
      const latest = await new CampusFlowApi(this.baseUrl, this.token).actionStatus(action.proposal_id);
      if (!this.pageActive || revision !== this.conversationRevision) { return; }
      if (latest.proposal_id !== action.proposal_id ||
        !['pending', 'confirmed', 'cancelled'].includes(latest.status)) {
        this.setFeedback(action.proposal_id, '未取得可核验的提案状态，请到计划列表核对。', true);
        return;
      }
      this.replaceAction(latest);
      const state = latest.status === 'confirmed' ? '已确认' : latest.status === 'cancelled' ? '已取消' : '待确认';
      // A status read cannot prove that a failed transaction left no partial tasks.
      this.setFeedback(action.proposal_id,
        `服务端记录为「${state}」。上次操作的实际写入仍需到计划列表核对，本会话不重复提交。`, true);
    } catch (error) {
      if (!this.pageActive || revision !== this.conversationRevision) { return; }
      const failure = this.safeFailure(error);
      this.setFeedback(action.proposal_id, `暂时无法核对状态。${failure.message}`, true, failure.code);
    } finally {
      if (revision === this.conversationRevision) { this.decisionId = ''; }
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

  private hasConversation(): boolean {
    return this.messages.some((message: ConversationEntry) => message.id !== 'welcome');
  }

  @Builder
  private ToolResults(message: ConversationEntry) {
    Column({ space: 8 }) {
      if (message.tools.length === 0) {
        Text('本轮未提供工具记录').fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%')
      } else {
        Button({ type: ButtonType.Normal }) {
          Text(`本轮工具记录 · ${message.tools.length} 项 · ${this.collapsedToolIds.includes(message.id) ? '展开' : '收起'}`)
            .fontSize(AppTheme.metaSize).fontColor(AppTheme.blue).width('100%').textAlign(TextAlign.Start)
        }.width('100%').constraintSize({ minHeight: 48 }).padding(0).backgroundColor(Color.Transparent)
          .onClick(() => this.toggleToolResults(message.id))
        if (!this.collapsedToolIds.includes(message.id)) {
          ForEach(message.tools, (item: ToolDisplaySummary) => {
            Column({ space: 4 }) {
              Row({ space: 8 }) {
                Text(item.label).fontSize(AppTheme.metaSize).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink).layoutWeight(1)
                Text(this.toolStateLabel(item.state)).fontSize(AppTheme.metaSize).fontColor(this.toolStateColor(item.state))
              }.width('100%')
              Text(item.summary).fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%')
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
      Text('请求未完成').fontSize(AppTheme.bodySize).fontWeight(FontWeight.Bold).fontColor(AppTheme.red).width('100%')
      Text(message.content).fontSize(AppTheme.metaSize).fontColor(AppTheme.ink).width('100%')
      Text('原输入已保留在对话中，可复制或恢复后手动发送。若请求曾到达服务端，请先查看历史和已有提案。')
        .fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%')
      Button(this.inputLength(this.prompt) > 0 ? '输入框已有草稿' : '恢复本次输入')
        .constraintSize({ minHeight: 48 }).fontSize(AppTheme.metaSize).fontColor(AppTheme.blue)
        .backgroundColor(AppTheme.blueSoft).enabled(!this.loading && this.inputLength(this.prompt) === 0)
        .onClick(() => this.prompt = restoreDraft(this.prompt, message.failedPrompt))
      if (message.failureCode === 'LOGIN_REQUIRED' || message.failureCode === 'MODEL_AUTH_INVALID' ||
        message.failureCode === 'MODEL_KEY_REQUIRED') {
        Text(message.failureCode === 'LOGIN_REQUIRED' ? '重新登录前，请先复制要保留的输入。' : '可在个人设置检查模型 API Key。')
          .fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%')
        Button('前往个人设置').constraintSize({ minHeight: 48 }).fontSize(AppTheme.metaSize)
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
      Text('以下时间均为北京时间').fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%')
      ForEach(action.payload.milestones ?? [], (milestone: PendingMilestonePreview, milestoneIndex: number) => {
        Column({ space: 10 }) {
          Text(`${milestoneIndex + 1}. ${milestone.title}`)
            .fontSize(AppTheme.bodySize).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink).width('100%')
          Text(`截止：${formatPlanDateTime(milestone.due_at)} · ${milestone.tasks.length} 项任务`)
            .fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%')
          if (milestone.tasks.length === 0) {
            Text('这个里程碑尚无任务').fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%')
          }
          ForEach(milestone.tasks, (task: PendingTaskPreview, taskIndex: number) => {
            Column({ space: 6 }) {
              Text(`${milestoneIndex + 1}.${taskIndex + 1} ${task.title}`)
                .fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink).width('100%')
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

  @Builder
  private suggestion(title: string, detail: string, icon: string, prompt: string) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        Row() {
          AppIcon({ name: icon, iconSize: 22, color: AppTheme.actionBlue })
        }.width(40).height(40).justifyContent(FlexAlign.Center)
          .backgroundColor(AppTheme.blueSoft).borderRadius(12)
        Column({ space: 4 }) {
          Text(title).fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink)
            .width('100%').textAlign(TextAlign.Start).wordBreak(WordBreak.BREAK_WORD)
          Text(detail).fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
            .textAlign(TextAlign.Start).wordBreak(WordBreak.BREAK_WORD)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        AppIcon({ name: 'chevron', iconSize: 16, color: AppTheme.quiet })
      }.width('100%')
    }.width('100%').padding(16).constraintSize({ minHeight: 76 })
      .backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
      .accessibilityText(`${title}，${detail}，填入输入框`)
      .onClick(() => this.choosePrompt(prompt))
  }

  @Builder
  private VoicePanel() {
    Column({ space: 12 }) {
      Row({ space: 10 }) {
        if (this.voiceState.phase === 'starting' || this.voiceState.phase === 'recognizing') {
          LoadingProgress().width(20).height(20).color(AppTheme.actionBlue)
        } else {
          AppIcon({ name: 'microphone', iconSize: 20, color: AppTheme.actionBlue })
        }
        Text(this.voiceState.phase === 'review' ? '核对语音文字' :
          (this.voiceState.phase === 'error' ? '语音提示' : '语音输入'))
          .fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink).layoutWeight(1)
        if (this.voiceState.phase === 'listening') {
          Text('录音中').fontSize(AppTheme.metaSize).fontColor(AppTheme.actionBlue)
        }
      }.width('100%')
      Text(this.voiceState.message).fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
      if (this.voiceState.phase === 'review') {
        TextArea({ text: this.voiceState.transcript, placeholder: '识别文字，可在这里修改…' })
          .width('100%').fontSize(16).fontColor(AppTheme.ink)
          .constraintSize({ minHeight: 72, maxHeight: 140 })
          .backgroundColor(AppTheme.surface).borderRadius(AppTheme.controlRadius).padding(12)
          .accessibilityText('识别文字，可编辑，尚未发送')
          .onChange((value: string) => this.editVoiceTranscript(value))
        Row({ space: 10 }) {
          Button('放弃文字').layoutWeight(1).constraintSize({ minHeight: 48 })
            .fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet).backgroundColor(AppTheme.surface)
            .onClick(() => this.cancelVoice())
          Button('填入输入框').layoutWeight(1).constraintSize({ minHeight: 48 })
            .fontSize(AppTheme.bodySize).fontColor('#FFFFFF').backgroundColor(AppTheme.actionBlue)
            .accessibilityText('将识别文字追加到输入框，不自动发送')
            .onClick(() => this.useVoiceTranscript())
        }.width('100%')
        Text('识别文字将追加到原输入，检查后再手动发送。')
          .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
      } else if (this.capturePending()) {
        if (this.voiceState.transcript.length > 0) {
          Text(this.voiceState.transcript).fontSize(AppTheme.bodySize).fontColor(AppTheme.ink).width('100%')
            .maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        Row({ space: 10 }) {
          Button('取消录音').layoutWeight(1).constraintSize({ minHeight: 48 })
            .fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet).backgroundColor(AppTheme.surface)
            .onClick(() => this.cancelVoice())
          if (this.voiceState.phase === 'listening') {
            Button('完成录音').layoutWeight(1).constraintSize({ minHeight: 48 })
              .fontSize(AppTheme.bodySize).fontColor('#FFFFFF').backgroundColor(AppTheme.actionBlue)
              .onClick(() => this.voiceInteraction?.finishListening())
          }
        }.width('100%')
        Text('录音最长 60 秒，说完后可编辑文字；CampusFlow 不保存录音。')
          .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
      } else {
        Button('知道了').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
          .fontColor(AppTheme.actionBlue).backgroundColor(AppTheme.surface)
          .onClick(() => this.cancelVoice())
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(AppTheme.cardInset)
      .backgroundColor(AppTheme.blueSoft).borderRadius(AppTheme.cardRadius)
      .border({ width: 1, color: AppTheme.line })
  }

  @Builder
  private ModelOptions() {
    Column({ space: 12 }) {
      Text('后续消息使用的模型').fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium)
        .fontColor(AppTheme.ink).width('100%')
      Row({ space: 8 }) {
        Button(this.model === 'deepseek-v4-pro' ? 'V4 Pro · 已选' : 'V4 Pro')
          .layoutWeight(1).constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
          .fontColor(this.model === 'deepseek-v4-pro' ? '#FFFFFF' : AppTheme.actionBlue)
          .backgroundColor(this.model === 'deepseek-v4-pro' ? AppTheme.actionBlue : AppTheme.blueSoft)
          .borderRadius(AppTheme.controlRadius).enabled(!this.loading && this.decisionId.length === 0 && !this.deletionBusy)
          .onClick(() => this.selectModel('deepseek-v4-pro'))
        Button(this.model === 'deepseek-flash' ? 'Flash · 已选' : 'Flash')
          .layoutWeight(1).constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
          .fontColor(this.model === 'deepseek-flash' ? '#FFFFFF' : AppTheme.actionBlue)
          .backgroundColor(this.model === 'deepseek-flash' ? AppTheme.actionBlue : AppTheme.blueSoft)
          .borderRadius(AppTheme.controlRadius).enabled(!this.loading && this.decisionId.length === 0 && !this.deletionBusy)
          .onClick(() => this.selectModel('deepseek-flash'))
      }.width('100%')
      Text('模型是否可用取决于服务配置。切换不会改写已有回答。')
        .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
      Button('个人与模型凭据').width('100%').constraintSize({ minHeight: 48 })
        .fontSize(AppTheme.bodySize).fontColor(AppTheme.actionBlue).backgroundColor(AppTheme.surface)
        .borderRadius(AppTheme.controlRadius).onClick(() => this.onOpenProfile())
      Button('校园导航').width('100%').constraintSize({ minHeight: 48 })
        .fontSize(AppTheme.bodySize).fontColor(AppTheme.actionBlue).backgroundColor(AppTheme.surface)
        .borderRadius(AppTheme.controlRadius).onClick(() => this.onOpenRoute())
    }.width('100%').padding(AppTheme.cardInset).backgroundColor(AppTheme.field)
      .borderRadius(AppTheme.cardRadius).alignItems(HorizontalAlign.Start)
  }

  @Builder
  private SuggestedPrompt() {
    Column({ space: 12 }) {
      Text(`新的输入建议 · ${this.promptSuggestions.length} 条待处理`)
        .fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink).width('100%')
      Text(this.promptSuggestions[0] ?? '').fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet)
        .width('100%').wordBreak(WordBreak.BREAK_WORD).copyOption(CopyOptions.InApp)
      Text('原输入不会被替换。追加后仍需你手动发送。')
        .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
      Row({ space: 8 }) {
        Button('略过').layoutWeight(1).constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
          .fontColor(AppTheme.quiet).backgroundColor(AppTheme.surface).borderRadius(AppTheme.controlRadius)
          .onClick(() => this.dismissSuggestion())
        Button('采用').layoutWeight(1).constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
          .fontColor(AppTheme.actionBlue).backgroundColor(AppTheme.surface).borderRadius(AppTheme.controlRadius)
          .enabled(this.inputLength(this.prompt) === 0).onClick(() => this.applySuggestion(false))
        Button('追加').layoutWeight(1).constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
          .fontColor('#FFFFFF').backgroundColor(AppTheme.actionBlue).borderRadius(AppTheme.controlRadius)
          .onClick(() => this.applySuggestion(true))
      }.width('100%')
    }.width('100%').padding(AppTheme.cardInset).backgroundColor(AppTheme.blueSoft)
      .borderRadius(AppTheme.cardRadius).alignItems(HorizontalAlign.Start)
  }

  @Builder
  private ConversationMessage(message: ConversationEntry) {
    if (message.role === 'feedback') {
      this.RequestFailure(message)
    } else {
      Row() {
        if (message.role === 'user') { Blank() }
        Column({ space: 12 }) {
          if (message.role === 'assistant') {
            Row({ space: 8 }) {
              AppIcon({ name: 'agent', iconSize: 20, color: AppTheme.actionBlue })
              Text('CampusFlow').fontSize(AppTheme.metaSize).fontWeight(FontWeight.Medium)
                .fontColor(AppTheme.quiet).layoutWeight(1)
              Button({ type: ButtonType.Normal }) {
                Row({ space: 6 }) {
                  AppIcon({ name: this.voiceState.speakingMessageId === message.id ? 'stop' : 'speaker',
                    iconSize: 20, color: AppTheme.actionBlue })
                  Text(this.voiceState.speakingMessageId === message.id ? '停止' : '播报')
                    .fontSize(AppTheme.metaSize).fontColor(AppTheme.actionBlue)
                }
              }.constraintSize({ minHeight: 48, minWidth: 72 }).padding(8)
                .backgroundColor(Color.Transparent).borderRadius(AppTheme.controlRadius)
                .accessibilityText(this.voiceState.speakingMessageId === message.id ? '停止播报这条回答' : '播报这条回答正文')
                .enabled(this.speechPending() && this.voiceState.speakingMessageId === message.id ||
                  !this.loading && !this.deletionBusy && this.decisionId.length === 0 && !this.capturePending())
                .onClick(() => this.speakReply(message))
            }.width('100%')
          }
          MessageContent({ content: message.content, isUser: message.role === 'user' })
          if (message.role === 'assistant') { this.ToolResults(message) }
        }.alignItems(HorizontalAlign.Start)
          .padding(message.role === 'user' ? 16 : 0)
          .width(message.role === 'user' ? '90%' : '100%')
          .backgroundColor(message.role === 'user' ? AppTheme.actionBlue : Color.Transparent)
          .borderRadius(message.role === 'user' ? { topLeft: 18, topRight: 18, bottomLeft: 18, bottomRight: 4 }
            : { topLeft: 0, topRight: 0, bottomLeft: 0, bottomRight: 0 })
        if (message.role !== 'user') { Blank() }
      }.width('100%')
    }
  }

  @Builder
  private ProposalCard(action: PendingAction) {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Text(action.kind === 'plan' ? '计划提案' : '待办提案')
          .fontSize(AppTheme.metaSize).fontWeight(FontWeight.Medium).fontColor(AppTheme.actionBlue).layoutWeight(1)
        Text(this.decisionLabel(action)).fontSize(AppTheme.metaSize)
          .fontColor(this.needsReview(action.proposal_id) ? AppTheme.orange : AppTheme.quiet)
      }.width('100%')
      Text(action.title).fontSize(AppTheme.sectionTitle).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
        .width('100%').wordBreak(WordBreak.BREAK_WORD)
      if (!this.receiptCollapsed(action)) {
        Text(this.proposalMeta(action)).fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
        if ((action.payload.summary ?? '').length > 0) {
          Text(action.payload.summary ?? '').fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet).width('100%')
        }
        if (action.kind === 'plan') {
          if ((action.payload.milestones ?? []).length > 0) {
            Button({ type: ButtonType.Normal }) {
              Text(this.proposalExpanded(action.proposal_id) ? '收起完整计划' :
                `查看全部 ${action.payload.milestones?.length ?? 0} 个里程碑 · ${this.proposalTaskCount(action)} 项任务`)
                .fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium).fontColor(AppTheme.actionBlue)
                .width('100%').textAlign(TextAlign.Start).wordBreak(WordBreak.BREAK_WORD)
            }.width('100%').constraintSize({ minHeight: 48 }).padding(12)
              .backgroundColor(AppTheme.blueSoft).borderRadius(AppTheme.controlRadius)
              .accessibilityText(`${action.title}，${this.proposalExpanded(action.proposal_id) ? '已展开，收起完整计划' : '已折叠，查看完整计划'}`)
              .onClick(() => this.toggleProposal(action.proposal_id))
            if (this.proposalExpanded(action.proposal_id)) { this.ProposalMilestones(action) }
          } else {
            Text('提案中暂无里程碑，请补充计划后再确认。')
              .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
          }
        } else {
          TaskScheduleDetails({ startAt: action.start_at, endAt: action.end_at,
            location: action.payload.location ?? null, reminderMinutes: action.reminder_minutes })
        }
        if (action.conflicts.length > 0) {
          Text(`检测到冲突：${action.conflicts.join('；')}`)
            .fontSize(AppTheme.metaSize).fontColor(AppTheme.red).width('100%')
        }
      }
      if (this.feedbackFor(action.proposal_id) !== undefined) {
        Text(this.feedbackFor(action.proposal_id)?.message ?? '').fontSize(AppTheme.metaSize).width('100%')
          .fontColor(this.needsReview(action.proposal_id) ? AppTheme.orange : AppTheme.quiet)
      }
      if (this.feedbackFor(action.proposal_id)?.code === 'LOGIN_REQUIRED') {
        Button('前往个人设置重新登录').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
          .fontColor(AppTheme.actionBlue).backgroundColor(AppTheme.blueSoft)
          .onClick(() => this.onOpenProfile())
      }
      if (this.needsReview(action.proposal_id)) {
        Button(this.decisionId === action.proposal_id ? '核对中…' : '核对状态')
          .width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
          .fontColor(AppTheme.actionBlue).backgroundColor(AppTheme.blueSoft).borderRadius(AppTheme.controlRadius)
          .enabled(!this.loading && !this.deletionBusy && this.decisionId.length === 0)
          .onClick(() => this.checkDecision(action))
        Button('查看计划列表').width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
          .fontColor(AppTheme.actionBlue).backgroundColor(Color.Transparent).onClick(() => this.onOpenPlan())
      } else if (action.status === 'confirmed' || action.status === 'cancelled') {
        Button(this.receiptCollapsed(action) ? '查看原提案' : '收起原提案')
          .width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
          .fontColor(AppTheme.actionBlue).backgroundColor(AppTheme.blueSoft).borderRadius(AppTheme.controlRadius)
          .onClick(() => this.toggleReceipt(action.proposal_id))
        if (action.status === 'confirmed') {
          Button('查看计划列表').width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
            .fontColor(AppTheme.actionBlue).backgroundColor(Color.Transparent).onClick(() => this.onOpenPlan())
        }
      } else if (action.status === 'pending') {
        if (action.action !== 'create') {
          Text('暂不支持通过提案修改或删除已有任务，请到计划页操作。')
            .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
        }
        Row({ space: 8 }) {
          Button('暂不执行').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet)
            .backgroundColor(AppTheme.field).borderRadius(AppTheme.controlRadius).layoutWeight(1)
            .enabled(!this.loading && !this.deletionBusy && this.decisionId.length === 0)
            .onClick(() => this.decide(action, false))
          Button(this.decisionId === action.proposal_id ? '处理中…' : '确认执行')
            .constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize).fontColor('#FFFFFF')
            .backgroundColor(AppTheme.actionBlue).borderRadius(AppTheme.controlRadius).layoutWeight(1)
            .enabled(!this.loading && !this.deletionBusy && this.decisionId.length === 0 && action.action === 'create')
            .onClick(() => this.decide(action, true))
        }.width('100%')
      }
    }.width('100%').padding(AppTheme.cardInset).backgroundColor(AppTheme.surface)
      .alignItems(HorizontalAlign.Start).borderRadius(AppTheme.cardRadius)
      .border({ width: 1, color: this.focusedProposalId === action.proposal_id ? AppTheme.actionBlue : AppTheme.line })
      .onAreaChange((_oldArea: Area, newArea: Area) => {
        this.rememberProposalAnchor(action.proposal_id, Number(newArea.position.y));
      })
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Column({ space: 4 }) {
          Text('Agent').fontSize(20).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink).width('100%')
          Text('校园规划助手').fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button({ type: ButtonType.Normal }) {
          AppIcon({ name: 'history', iconSize: 24, color: AppTheme.actionBlue })
        }.width(48).constraintSize({ minHeight: 48 }).backgroundColor(Color.Transparent)
          .borderRadius(AppTheme.controlRadius).accessibilityText('历史会话').onClick(() => this.onOpenHistory())
        Button(this.optionsExpanded ? '收起' : '更多').constraintSize({ minHeight: 48, minWidth: 48 })
          .fontSize(AppTheme.metaSize).fontColor(AppTheme.actionBlue).backgroundColor(Color.Transparent)
          .borderRadius(AppTheme.controlRadius)
          .accessibilityText(this.optionsExpanded ? '收起模型与快捷入口' : '展开模型与快捷入口')
          .onClick(() => this.toggleOptions())
      }.width('100%').constraintSize({ minHeight: 64 }).padding({ left: AppTheme.pageInset, right: 12, top: 4, bottom: 4 })
        .backgroundColor(AppTheme.surface).border({ width: { bottom: 1 }, color: AppTheme.line })

      if (this.attentionActions().length > 0) {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 8 }) {
            Text(this.attentionLabel()).fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet)
              .layoutWeight(1).textAlign(TextAlign.Start).wordBreak(WordBreak.BREAK_WORD)
            Text('定位提案').fontSize(AppTheme.metaSize).fontColor(AppTheme.actionBlue)
            AppIcon({ name: 'chevron', iconSize: 20, color: AppTheme.actionBlue })
          }.width('100%')
        }.width('100%').constraintSize({ minHeight: 48 }).padding({ left: AppTheme.pageInset, right: 16, top: 8, bottom: 8 })
          .backgroundColor(AppTheme.blueSoft).accessibilityText(`${this.attentionLabel()}，按顺序定位需处理的提案`)
          .onClick(() => this.jumpToNextProposal())
      }

      Scroll(this.chatScroller) {
        Column({ space: 24 }) {
          if (this.optionsExpanded) { this.ModelOptions() }
          if (!this.hasConversation()) {
            Column({ space: 12 }) {
              Text('想安排什么？').fontSize(AppTheme.pageTitle).fontWeight(FontWeight.Bold)
                .fontColor(AppTheme.ink).width('100%')
              Text('结合课表找时间，把目标拆成可确认的计划。')
                .fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet).width('100%')
            }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 12 })
            Column({ space: 12 }) {
              this.suggestion('安排一段专注时间', '结合课程，找到今天的空闲', 'calendar',
                '根据我今天的课程和待办，找一段合适的空闲时间安排复习，先生成待确认的提案。')
              this.suggestion('制定一周复习计划', '分解目标，循序渐进', 'book',
                '结合我的近期课程，帮我制定一周复习计划，分解为里程碑和待办，先生成提案。')
              this.suggestion('看看我的校园安排', '查询已同步的个人校园信息', 'classroom',
                '查看我已同步的校园信息，结合最近的课表，提醒我接下来需要关注的事项。')
            }.width('100%')
            Text('建议只填入草稿，准备好后再发送。').fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
          }
          ForEach(this.messages.filter((item: ConversationEntry) => item.id !== 'welcome'), (message: ConversationEntry) => {
            Column({ space: 16 }) {
              this.ConversationMessage(message)
              ForEach(this.actionsForMessage(message.id), (action: PendingAction) => {
                this.ProposalCard(action)
              }, (action: PendingAction) => `${action.proposal_id}-${action.status}-${this.actionsRevision}`)
            }.width('100%').alignItems(HorizontalAlign.Start)
              .onAreaChange((_oldArea: Area, newArea: Area) => {
                this.rememberMessageAnchor(message.id, Number(newArea.position.y));
              })
          }, (message: ConversationEntry) => message.id)
          if (this.loading) {
            Row({ space: 10 }) {
              LoadingProgress().width(20).height(20).color(AppTheme.actionBlue)
              Text('正在处理请求…').fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet)
            }.width('100%')
          }
          if (this.promptSuggestions.length > 0) { this.SuggestedPrompt() }
          if (this.capturePending() || this.voiceState.phase === 'error') { this.VoicePanel() }
        }.width('100%').padding({ left: AppTheme.pageInset, right: AppTheme.pageInset, top: 16, bottom: 24 })
          .onAreaChange((_oldArea: Area, newArea: Area) => this.chatContentChanged(Number(newArea.height)))
      }.layoutWeight(1).width('100%').clip(true).scrollBar(BarState.Off).align(Alignment.TopStart)
        .onAreaChange((_oldArea: Area, newArea: Area) => this.viewportHeight = Number(newArea.height))
        .onScroll(() => this.recordScrollOffset(this.chatScroller.currentOffset().yOffset))

      if (this.unreadMessages > 0 || this.promptSuggestions.length > 0) {
        Button(this.promptSuggestions.length > 0 ? `查看 ${this.promptSuggestions.length} 条输入建议` :
          `查看 ${this.unreadMessages} 条新消息`).width('100%').constraintSize({ minHeight: 48 })
          .fontSize(AppTheme.metaSize).fontColor(AppTheme.actionBlue).backgroundColor(AppTheme.blueSoft)
          .onClick(() => this.viewLatest())
      }
      if (this.cacheNotice.length > 0 && this.cacheNotice !== '对话已保存到本机，可在历史会话离线回看。') {
        Text(this.cacheNotice).fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
          .padding({ left: 20, right: 20, top: 8, bottom: 8 }).backgroundColor(AppTheme.blueSoft)
      }
      if (this.deletionBusy) {
        Text('正在删除会话，完成后可继续发送。').fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%')
          .padding({ left: 18, right: 18, top: 6, bottom: 4 })
      }
      if (this.inputLength(this.prompt) > 8000) {
        Text(`当前 ${this.inputLength(this.prompt)} 字，超过 8000 字上限，请精简后发送。原文仍保留在输入框中。`)
          .fontSize(AppTheme.metaSize).fontColor(AppTheme.red).width('100%')
          .padding({ left: 18, right: 18, top: 6, bottom: 6 })
      }
      Column({ space: 8 }) {
        Row() {
          Text(this.speechPending() ? this.voiceState.message :
            (this.cacheNotice === '对话已保存到本机，可在历史会话离线回看。' ? '你的目标 · 对话已保存' : '你的目标'))
            .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).layoutWeight(1)
          if (this.capturePending() || this.speechPending()) {
            Button(this.speechPending() ? '停止播报' : '取消语音')
              .constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize).fontColor(AppTheme.actionBlue)
              .backgroundColor(Color.Transparent).onClick(() => this.cancelVoice())
          } else {
            Button({ type: ButtonType.Normal }) {
              Row({ space: 6 }) {
                AppIcon({ name: 'microphone', iconSize: 19, color: AppTheme.actionBlue })
                Text('语音输入').fontSize(AppTheme.bodySize).fontColor(AppTheme.actionBlue)
              }
            }.constraintSize({ minHeight: 48 }).padding({ left: 10, right: 10 })
              .backgroundColor(Color.Transparent).borderRadius(AppTheme.controlRadius)
              .accessibilityText('开始语音输入，识别后可编辑，不自动发送')
              .enabled(this.voiceActive && !this.loading && !this.deletionBusy && this.decisionId.length === 0)
              .onClick(() => this.startVoice())
          }
        }.width('100%')
        if (this.suggestionNotice.length > 0) {
          Text(this.suggestionNotice).fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
        }
        if (this.voiceNotice.length > 0) {
          Text(this.voiceNotice).fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
        }
        Row({ space: 8 }) {
          TextArea({ text: this.prompt, placeholder: '描述你的目标或安排…' })
            .layoutWeight(1).fontSize(16)
            .constraintSize({ minHeight: 48, maxHeight: Math.max(48, Math.min(160, this.availableHeight * 0.3)) })
            .accessibilityText('输入目标或安排')
            .fontColor(AppTheme.ink).placeholderColor(AppTheme.muted)
            .backgroundColor(AppTheme.canvas).borderRadius(AppTheme.controlRadius)
            .padding({ left: 15, right: 12, top: 13, bottom: 10 })
            .onChange((value) => this.prompt = value)
          Button('发送').constraintSize({ minWidth: 64, minHeight: 48 }).fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium)
            .fontColor(this.inputLength(this.prompt) > 0 && this.inputLength(this.prompt) <= 8000 ? '#FFFFFF' : AppTheme.muted)
            .backgroundColor(this.inputLength(this.prompt) > 0 && this.inputLength(this.prompt) <= 8000 ? AppTheme.actionBlue : AppTheme.field)
            .borderRadius(AppTheme.controlRadius)
            .enabled(!this.capturePending() && !this.loading && !this.deletionBusy && this.decisionId.length === 0 && this.inputLength(this.prompt) > 0 && this.inputLength(this.prompt) <= 8000).onClick(() => this.send())
        }.width('100%').alignItems(VerticalAlign.Bottom)
      }.width('100%').padding({ left: 20, right: 20, top: 12, bottom: 12 }).backgroundColor(AppTheme.surface)
        .border({ width: { top: 0.5 }, color: AppTheme.line })
    }.width('100%').height('100%').alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Start).backgroundColor(AppTheme.canvas)
      .onAreaChange((_oldArea: Area, newArea: Area) => {
        const height = Number(newArea.height);
        if (height > 0 && height !== this.availableHeight) {
          this.availableHeight = height;
        }
      })
  }
}
