import { HistoryMessage, SessionSummary, PendingAction, PendingMilestonePreview, PendingTaskPreview, ToolDisplaySummary, PlanningTaskDraft, PlanningPlanDraft, RunSnapshot, RunToolProgress, ModelCatalog, ModelOption } from '../model/ApiModels';
import { CampusFlowApi } from '../services/CampusFlowApi';
import { localHistory } from '../services/LocalHistory';
import { MessageContent } from '../components/MessageContent';
import { AppTheme } from '../theme/AppTheme';
import { EvidencePanel } from '../components/EvidencePanel';
import { validModelCatalog, modelUnavailableReason, modelLabel } from '../utils/ModelCatalog';
import { AppIcon } from '../components/AppIcon';
import { TaskScheduleDetails } from '../components/TaskScheduleDetails';
import { formatPlanDateTime } from '../utils/PlanPresentation';
import { CampusFlowRequestError, displayToolTraces, mergeActions, restoreDraft, localRequestFailure } from '../utils/AgentFeedback';
import common from '@ohos.app.ability.common';
import { PlatformVoiceDriver } from '../services/PlatformVoiceDriver';
import { VoiceInteraction, VoiceState, VoiceCapabilities } from '../utils/VoiceInteraction';
import { AgentRunController, AgentRunState } from '../utils/AgentRun';
import { validActionPreview, validReliableAction, canConfirmAction, decisionDisposition, sameActionCandidate, validatedActionReceipt, sameActionReceipt, receiptTaskId, receiptPlanId } from '../utils/ActionReliability';

interface ConversationEntry {
  id: string;
  role: string;
  content: string;
  tools: ToolDisplaySummary[];
  failedPrompt: string;
  failureCode: string;
  runId?: string;
  incomplete?: boolean;
  restored?: boolean;
  revision?: number;
  sessionId?: string;
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

interface HistorySaveGeneration {
  sessionId: string;
  revision: number;
}

@Component
export struct AgentPage {
  @Watch('modelConnectionChanged') @Prop baseUrl: string;
  @Watch('modelConnectionChanged') @Prop token: string;
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
  onOpenTaskDetails: (id: string) => void = () => {};
  onOpenPlanDetails: (id: string) => void = () => {};
  onPlanningChanged: () => void = () => {};
  onOpenProfile: () => void = () => {};
  onChatBusyChange: (busy: boolean) => void = () => {};
  @State private prompt: string = '';
  @State private availableHeight: number = 600;
  @State private model: string = 'deepseek-v4-pro';
  @State private modelCatalog: ModelCatalog | null = null;
  @State private modelsLoading: boolean = false;
  @State private modelsMessage: string = '';
  private modelsRevision: number = 0;
  @State private modelsDataRevision: number = 0;
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
  @State private voiceProbeBusy: boolean = false;
  @State private voiceCapabilities: VoiceCapabilities = { recognition: false, synthesis: false };
  private voiceDriver: PlatformVoiceDriver | null = null;
  private voiceProbeRevision: number = 0;
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
  private notifiedReceiptIds: string[] = [];
  private invalidatedProposalIds: string[] = [];
  @State private runState: AgentRunState = { phase: 'idle', runId: '', request: null, snapshot: null, events: [], recent: [],
    message: '', listMessage: '', listLoading: false, lastAppliedSeq: 0, canRetryStart: false, errorCode: '' };
  @State private runRecordsExpanded: boolean = false;
  @State private runProgressExpanded: boolean = false;
  private runInteraction: AgentRunController | null = null;
  private restoredRunIds: string[] = [];
  private cachedRunRequests: string[] = [];
  private displayedRunFailures: string[] = [];
  private historySaveGenerations: HistorySaveGeneration[] = [];
  private nextHistorySaveRevision: number = 0;
  private deletedRunSessionIds: string[] = [];

  aboutToAppear(): void {
    this.pageActive = true;
    this.loadModels();
    if (this.receivedPromptRevision !== this.promptRevision) {
      this.initialPromptChanged();
    }
  }

  aboutToDisappear(): void {
    this.pageActive = false;
    this.modelsRevision++;
    this.modelsLoading = false;
    this.conversationRevision++;
    this.voiceInteraction?.dispose();
    this.voiceInteraction = null;
    this.voiceDriver = null;
    this.voiceProbeRevision++;
    this.voiceProbeBusy = false;
    this.runInteraction?.dispose();
    this.runInteraction = null;
  }

  private sessionDeleted(): void {
    if (this.deletedSessionId !== this.sessionId) {
      this.removeDeletedRunSession(this.deletedSessionId);
      return;
    }
    this.cancelVoice();
    this.runInteraction?.dispose();
    this.runInteraction = null;
    this.runState = { phase: 'idle', runId: '', request: null, snapshot: null, events: [], recent: [],
      message: '', listMessage: '', listLoading: false, lastAppliedSeq: 0, canRetryStart: false, errorCode: '' };
    this.restoredRunIds = [];
    this.cachedRunRequests = [];
    this.displayedRunFailures = [];
    this.historySaveGenerations = [];
    this.conversationRevision++;
    this.sessionId = `arkuix-${Date.now()}-${this.conversationRevision}`;
    this.savedMessages = [];
    this.messages = [];
    this.pendingActions = [];
    this.invalidatedProposalIds = [];
    this.notifiedReceiptIds = [];
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

  private removeDeletedRunSession(sessionId: string): void {
    if (sessionId.length === 0) { return; }
    this.deletedRunSessionIds = this.deletedRunSessionIds.includes(sessionId) ? this.deletedRunSessionIds :
      this.deletedRunSessionIds.concat([sessionId]);
    const removedMessages = this.messages.filter((item: ConversationEntry) => item.sessionId === sessionId);
    const messageIds = removedMessages.map((item: ConversationEntry) => item.id);
    const runIds = removedMessages.map((item: ConversationEntry) => item.runId ?? '');
    const proposalIds = this.proposalOrigins.filter((origin: ProposalOrigin) => messageIds.includes(origin.messageId))
      .map((origin: ProposalOrigin) => origin.proposalId);
    this.messages = this.messages.filter((item: ConversationEntry) => item.sessionId !== sessionId);
    this.proposalOrigins = this.proposalOrigins.filter((origin: ProposalOrigin) => !messageIds.includes(origin.messageId));
    this.pendingActions = this.pendingActions.filter((action: PendingAction) => !proposalIds.includes(action.proposal_id));
    this.decisionFeedback = this.decisionFeedback.filter((item: DecisionFeedback) => !proposalIds.includes(item.proposalId));
    this.messageAnchors = this.messageAnchors.filter((item: ChatAnchor) => !messageIds.includes(item.id));
    this.proposalAnchors = this.proposalAnchors.filter((item: ChatAnchor) => !proposalIds.includes(item.id));
    this.historySaveGenerations = this.historySaveGenerations.filter((item: HistorySaveGeneration) => item.sessionId !== sessionId);
    this.restoredRunIds = this.restoredRunIds.filter((id: string) => !runIds.includes(id));
    this.expandedReceiptIds = this.expandedReceiptIds.filter((id: string) => !proposalIds.includes(id));
    this.expandedProposalIds = this.expandedProposalIds.filter((id: string) => !proposalIds.includes(id));
    this.invalidatedProposalIds = this.invalidatedProposalIds.filter((id: string) => !proposalIds.includes(id));
    if (proposalIds.includes(this.focusedProposalId)) { this.focusedProposalId = ''; }
    this.actionsRevision++;
    if (this.runState.snapshot?.session_id === sessionId || this.runState.request?.session_id === sessionId) {
      this.runInteraction?.dispose(); this.runInteraction = null;
      this.runState = { phase: 'idle', runId: '', request: null, snapshot: null, events: [], recent: [],
        message: '', listMessage: '', listLoading: false, lastAppliedSeq: 0, canRetryStart: false, errorCode: '' };
      this.loading = false; this.onChatBusyChange(false);
    } else {
      this.runState.recent = this.runState.recent.filter((run: RunSnapshot) => run.session_id !== sessionId);
    }
  }

  private async saveRunHistory(run: RunSnapshot): Promise<void> {
    if (this.cachedRunRequests.includes(run.run_id)) { return; }
    const revision = this.conversationRevision;
    if (this.historyScope.length === 0) {
      this.cacheNotice = '本机保存暂不可用，此对话尚不能离线回看。';
      return;
    }
    this.cachedRunRequests = this.cachedRunRequests.concat([run.run_id]);
    const historyRevision = ++this.nextHistorySaveRevision;
    this.historySaveGenerations = this.historySaveGenerations.filter((item: HistorySaveGeneration) => item.sessionId !== run.session_id)
      .concat([{ sessionId: run.session_id, revision: historyRevision }]);
    try {
      const history = await new CampusFlowApi(this.baseUrl, this.token).history(run.session_id);
      if (!this.canSaveRunHistory(run.session_id, revision, historyRevision)) { return; }
      if (!Array.isArray(history) || history.length === 0 || !history.every((item: HistoryMessage) =>
        item !== null && (item.role === 'user' || item.role === 'assistant') && typeof item.content === 'string' &&
        typeof item.created_at === 'string' && Number.isFinite(Date.parse(item.created_at)))) {
        throw localRequestFailure('INVALID_RESPONSE');
      }
      // The service commits the complete turn with the succeeded run. Always replace
      // from that authoritative history; recovery must never append a duplicate pair.
      const summary: SessionSummary = {
        session_id: run.session_id, title: Array.from(history[0].content).slice(0, 80).join(''),
        model_name: run.model, last_message: Array.from(history[history.length - 1].content).slice(0, 200).join(''),
        message_count: history.length, created_at: history[0].created_at, updated_at: history[history.length - 1].created_at
      };
      const messages: HistoryMessage[] = history.map((item: HistoryMessage) =>
        ({ role: item.role, content: item.content, created_at: item.created_at }));
      const saved = await localHistory.save(this.historyScope, summary, messages);
      if (!this.canSaveRunHistory(run.session_id, revision, historyRevision)) { return; }
      if (run.session_id === this.sessionId) { this.savedMessages = messages; }
      this.cacheNotice = saved ? '对话已保存到本机，可在历史会话离线回看。' : '此会话未保存到本机，请联网回看历史。';
    } catch {
      if (this.canSaveRunHistory(run.session_id, revision, historyRevision)) {
        this.cacheNotice = '完整会话保存失败，运行结果仍可阅读；可核对运行状态后重试保存，或联网回看历史。';
      }
    } finally {
      this.cachedRunRequests = this.cachedRunRequests.filter((id: string) => id !== run.run_id);
    }
  }

  private canSaveRunHistory(sessionId: string, revision: number, historyRevision: number): boolean {
    return this.pageActive && revision === this.conversationRevision && this.historySaveGenerations.some((item: HistorySaveGeneration) =>
      item.sessionId === sessionId && item.revision === historyRevision);
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

  private modelConnectionChanged(): void {
    this.modelsRevision++; this.modelsLoading = false; this.modelCatalog = null; this.modelsMessage = '';
    this.loadModels();
  }
  private async loadModels(): Promise<void> {
    if (!this.pageActive || !this.voiceActive || this.modelsLoading) { return; }
    const revision = ++this.modelsRevision; const token = this.token; const base = this.baseUrl;
    this.modelsLoading = true;
    try {
      const catalog = await new CampusFlowApi(base, token).models();
      if (!this.pageActive || !this.voiceActive || revision !== this.modelsRevision || token !== this.token || base !== this.baseUrl) { return; }
      if (!validModelCatalog(catalog)) { throw new Error('INVALID_MODEL_CATALOG'); }
      this.modelCatalog = catalog;
      this.modelsDataRevision++;
      this.modelsMessage = catalog.models.length === 0 ? '服务没有提供可选模型，请检查服务端配置。' : '';
    } catch {
      if (this.pageActive && this.voiceActive && revision === this.modelsRevision && token === this.token && base === this.baseUrl) {
        this.modelsMessage = '模型列表暂未核实，原选择仍保留；发送时服务会再次检查可用性。请刷新重试。';
      }
    } finally { if (revision === this.modelsRevision) { this.modelsLoading = false; } }
  }
  private selectedModelBlocked(): boolean {
    if (this.modelCatalog === null) { return false; } // Older servers may not expose a catalog; retain the existing explicit selection.
    const option = this.modelCatalog.models.find((item: ModelOption) => item.id === this.model);
    return option === undefined || modelUnavailableReason(option).length > 0;
  }
  private selectedModelReason(): string {
    if (this.modelCatalog === null) { return this.modelsMessage; }
    const option = this.modelCatalog.models.find((item: ModelOption) => item.id === this.model);
    return option === undefined ? '当前选择已不在服务模型列表中，请重新选择。' : modelUnavailableReason(option);
  }
  private showModelOptions(): void {
    if (!this.optionsExpanded) { this.toggleOptions(); }
    else { this.chatScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: false }); }
  }
  private selectedModelLabel(): string { return modelLabel(this.model, this.modelCatalog?.models ?? []); }
  private selectModel(value: string): void {
    if (this.loading || this.decisionId.length > 0 || this.deletionBusy || this.modelCatalog === null) { return; }
    const option = this.modelCatalog.models.find((item: ModelOption) => item.id === value);
    if (option === undefined || modelUnavailableReason(option).length > 0) { return; }
    this.model = value;
  }

  private toggleOptions(): void {
    this.scrollForNewMessage = false;
    if (!this.optionsExpanded) {
      this.optionsReturnOffset = this.scrollOffset;
      this.optionsExpanded = true;
      this.loadModels();
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
    return !this.needsReview(action.proposal_id) && ['confirmed', 'cancelled'].includes(decisionDisposition(action)) &&
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
      this.voiceProbeRevision++;
      this.voiceProbeBusy = false;
      this.modelsRevision++; this.modelsLoading = false;
    } else { this.loadModels(); }
    this.runInteraction?.setActive(this.voiceActive);
  }

  private voiceController(): VoiceInteraction {
    if (this.voiceInteraction === null) {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
      this.voiceDriver = new PlatformVoiceDriver(context);
      this.voiceInteraction = new VoiceInteraction(this.voiceDriver, (state: VoiceState) => {
        if (this.pageActive) {
          if (this.voiceActive && this.followLatest && state.phase !== this.voiceState.phase) { this.scrollForNewMessage = true; }
          this.voiceState = state;
        }
      });
    }
    return this.voiceInteraction;
  }

  private async probeVoice(): Promise<boolean> {
    if (this.voiceProbeBusy || !this.pageActive || !this.voiceActive) { return false; }
    const revision = ++this.voiceProbeRevision;
    this.voiceProbeBusy = true;
    try {
      this.voiceController();
      const driver = this.voiceDriver;
      if (driver === null) { return false; }
      const capabilities = await driver.probe();
      if (!this.pageActive || !this.voiceActive || revision !== this.voiceProbeRevision) { return false; }
      this.voiceCapabilities = capabilities;
      this.voiceNotice = capabilities.recognition || capabilities.synthesis ? '' : '此设备未提供可用系统语音服务，文字输入仍可使用。';
      return true;
    } catch {
      if (this.pageActive && this.voiceActive && revision === this.voiceProbeRevision) {
        this.voiceCapabilities = { recognition: false, synthesis: false };
        this.voiceNotice = '设备语音能力尚未核实，请稍后重试；文字输入仍可使用。';
      }
      return false;
    } finally {
      if (revision === this.voiceProbeRevision) { this.voiceProbeBusy = false; }
    }
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
      this.decisionId.length > 0 || this.capturePending() || this.voiceProbeBusy) { return; }
    this.voiceNotice = '';
    this.followLatest = true;
    this.scrollForNewMessage = true;
    if (await this.probeVoice() && !this.loading && !this.deletionBusy && this.decisionId.length === 0 && !this.capturePending()) {
      await this.voiceController().startListening();
    }
  }

  private cancelVoice(): void {
    this.voiceProbeRevision++;
    this.voiceProbeBusy = false;
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
    if (!this.pageActive || !this.voiceActive || message.incomplete === true || message.role !== 'assistant' || message.id === 'welcome' ||
      !this.messages.some((item: ConversationEntry) => item.id === message.id && item.role === 'assistant')) { return; }
    if (this.speechPending() && this.voiceState.speakingMessageId === message.id) {
      this.cancelVoice();
      return;
    }
    if (this.loading || this.deletionBusy || this.decisionId.length > 0 || this.capturePending() || this.voiceProbeBusy) { return; }
    this.voiceNotice = '';
    if (await this.probeVoice() && !this.loading && !this.deletionBusy && this.decisionId.length === 0 && !this.capturePending()) {
      await this.voiceController().speak(message.id, message.content);
    }
  }

  private async send(): Promise<void> {
    const text = this.prompt.trim();
    if (!this.pageActive || !this.voiceActive || text.length === 0 || this.inputLength(text) > 8000 || this.loading || this.deletionBusy ||
      this.decisionId.length > 0 || this.capturePending()) {
      return;
    }
    if (this.selectedModelBlocked()) { this.optionsExpanded = true; this.modelsMessage = '当前模型不可用，请选择已就绪并支持工具与增量回答的模型。'; return; }
    this.cancelVoice();
    this.optionsExpanded = false;
    this.followLatest = true;
    this.prompt = '';
    await this.runController().start(this.sessionId, this.model, text);
  }

  private newRunId(): string {
    // Correlation/idempotency identifier only; this is not an authentication secret.
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (character: string) => {
      const random = Math.floor(Math.random() * 16);
      return (character === 'x' ? random : (random & 3) | 8).toString(16);
    });
  }

  private runController(): AgentRunController {
    if (this.runInteraction === null) {
      const api = new CampusFlowApi(this.baseUrl, this.token);
      this.runInteraction = new AgentRunController(api, (state: AgentRunState) => this.runChanged(state),
        (run: RunSnapshot) => this.runSucceeded(run), () => this.newRunId());
      this.runInteraction.configure(this.historyScope.length > 0 ? this.historyScope : `${this.baseUrl}|current-page`, api);
      this.runInteraction.setActive(this.voiceActive);
    }
    return this.runInteraction;
  }

  private upsertRunMessage(runId: string, role: string, content: string, tools: ToolDisplaySummary[] = [],
    incomplete: boolean = false): string {
    const id = `run-${runId}-${role}`;
    const previous = this.messages.find((item: ConversationEntry) => item.id === id);
    if (previous !== undefined && previous.content === content && previous.incomplete === incomplete &&
      JSON.stringify(previous.tools) === JSON.stringify(tools)) { return id; }
    const entry: ConversationEntry = { id: id, role: role, content: content, tools: tools,
      failedPrompt: '', failureCode: '', runId: runId, incomplete: incomplete,
      restored: this.restoredRunIds.includes(runId), revision: (previous?.revision ?? 0) + 1,
      sessionId: this.runState.snapshot?.session_id ?? this.runState.request?.session_id ?? '' };
    this.scrollForNewMessage = this.voiceActive && (role === 'user' || this.followLatest);
    if (previous === undefined) {
      if (role !== 'user' && !this.scrollForNewMessage) { this.unreadMessages++; }
      this.messages = this.messages.concat([entry]);
      if (role === 'assistant') { this.collapsedToolIds = this.collapsedToolIds.concat([id]); }
    } else {
      this.messages = this.messages.map((item: ConversationEntry) => item.id === id ? entry : item);
    }
    return id;
  }

  private runChanged(state: AgentRunState): void {
    if (!this.pageActive) { return; }
    state.recent = state.recent.filter((run: RunSnapshot) => !this.deletedRunSessionIds.includes(run.session_id));
    this.runState = state;
    if (state.errorCode === 'RUN_DELETED') {
      state.recent = state.recent.filter((run: RunSnapshot) => run.run_id !== state.runId);
      const sessionId = state.snapshot?.session_id ?? state.request?.session_id ?? '';
      this.removeDeletedRunSession(sessionId);
      if (sessionId === this.sessionId) {
        this.conversationRevision++;
        this.sessionId = `arkuix-${Date.now()}-${this.conversationRevision}`;
        this.savedMessages = [];
      }
      this.loading = false; this.onChatBusyChange(false);
      this.cacheNotice = '这次运行已随原会话删除，旧请求不会重试。当前输入草稿已保留。';
      return;
    }
    const busy = this.runInteraction?.blocksNewRun() ?? false;
    if (this.loading !== busy) { this.loading = busy; this.onChatBusyChange(busy); }
    const run = state.snapshot;
    if (run !== null) {
      this.upsertRunMessage(run.run_id, 'user', run.message);
      this.upsertRunMessage(run.run_id, 'assistant', run.status === 'succeeded' ? run.result?.message ?? '' : run.partial_answer,
        run.status === 'succeeded' ? displayToolTraces(run.result?.tool_traces) : [], run.status !== 'succeeded');
    } else if (state.request !== null) {
      this.upsertRunMessage(state.request.run_id, 'user', state.request.message);
    }
    const stopped = state.phase === 'error' ||
      (run !== null && ['failed', 'cancelled', 'timed_out', 'budget_exceeded', 'interrupted'].includes(run.status));
    const original = state.request?.message ?? run?.message ?? '';
    if (stopped && state.runId.length > 0 && !this.displayedRunFailures.includes(state.runId)) {
      this.displayedRunFailures = this.displayedRunFailures.concat([state.runId]);
      if (!this.restoredRunIds.includes(state.runId)) { this.prompt = restoreDraft(this.prompt, original); }
      const messageId = this.appendMessage('feedback', state.message.length > 0 ? state.message : '这次运行未完成，已收到的片段保留供核对。',
        [], this.restoredRunIds.includes(state.runId) ? '' : original, 'RUN_STATE');
      this.messages = this.messages.map((item: ConversationEntry) => item.id === messageId ? {
        id: item.id, role: item.role, content: item.content, tools: item.tools, failedPrompt: item.failedPrompt,
        failureCode: item.failureCode, runId: state.runId, sessionId: state.snapshot?.session_id ?? state.request?.session_id ?? ''
      } : item);
    }
  }

  private runSucceeded(run: RunSnapshot): void {
    if (!this.pageActive || run.result === null) { return; }
    const messageId = this.upsertRunMessage(run.run_id, 'assistant', run.result.message, displayToolTraces(run.result.tool_traces));
    const actions = run.result.pending_actions.filter((action: PendingAction) => validActionPreview(action));
    this.pendingActions = mergeActions(this.pendingActions, actions);
    this.linkProposals(messageId, actions);
    if (actions.length !== run.result.pending_actions.length) {
      this.appendMessage('feedback', '部分提案内容不完整，未开放执行。请根据最新安排重新生成预览。');
    }
    this.actionsRevision++;
    this.saveRunHistory(run);
  }

  private runStatusLabel(run: RunSnapshot): string {
    switch (run.status) {
      case 'queued': return '等待开始';
      case 'running': return '正在运行';
      case 'succeeded': return '已完成';
      case 'cancelled': return '已取消';
      case 'timed_out': return '运行超时';
      case 'budget_exceeded': return '达到本次运行上限';
      case 'interrupted': return '服务重启，运行已中断';
      default: return '运行失败';
    }
  }

  private canCancelRun(): boolean {
    return this.runState.snapshot !== null && ['queued', 'running'].includes(this.runState.snapshot.status) &&
      !['creating', 'cancelling'].includes(this.runState.phase);
  }

  private async toggleRunRecords(): Promise<void> {
    this.runRecordsExpanded = !this.runRecordsExpanded;
    if (this.runRecordsExpanded) { await this.runController().loadRecent(); }
  }

  private async recoverRun(runId: string): Promise<void> {
    if (!this.pageActive || this.loading || this.deletionBusy || this.decisionId.length > 0) { return; }
    this.cancelVoice();
    this.restoredRunIds = this.restoredRunIds.includes(runId) ? this.restoredRunIds : this.restoredRunIds.concat([runId]);
    await this.runController().recover(runId);
  }

  private async refreshRun(): Promise<void> {
    if (!this.pageActive || this.deletionBusy) { return; }
    await this.runController().refresh();
    const run = this.runState.snapshot;
    if (this.pageActive && run !== null && run.status === 'succeeded') { await this.saveRunHistory(run); }
  }

  private async cancelRun(): Promise<void> {
    if (!this.pageActive || this.deletionBusy || !this.canCancelRun()) { return; }
    await this.runController().cancel();
  }

  private async retryRunStart(): Promise<void> {
    if (!this.pageActive || this.deletionBusy || !this.runState.canRetryStart) { return; }
    await this.runController().retryStart();
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
    const disposition = decisionDisposition(action);
    if (disposition === 'confirmed') { return '已完成执行'; }
    if (disposition === 'cancelled') { return '已取消'; }
    if (disposition === 'legacy') { return '旧提案 · 需重新生成'; }
    if (disposition === 'invalid') { return '结果尚未核验'; }
    if (this.requiresNewPreview(action)) { return '需要新的预览'; }
    return '等待你的确认';
  }

  private requiresNewPreview(action: PendingAction): boolean {
    return this.invalidatedProposalIds.includes(action.proposal_id) ||
      ['legacy', 'invalid', 'expired', 'conflict'].includes(decisionDisposition(action)) ||
      ['ACTION_EXPIRED', 'ACTION_LEGACY_UNVERIFIED', 'ACTION_STALE', 'ACTION_CONFLICT', 'ACTION_INVALID', 'ACTION_NOT_FOUND']
        .includes(this.feedbackFor(action.proposal_id)?.code ?? '');
  }

  private anotherDecisionUnknown(proposalId: string): boolean {
    return this.decisionFeedback.some((item: DecisionFeedback) => item.proposalId !== proposalId && item.needsReview);
  }

  private proposalBlockMessage(action: PendingAction): string {
    const disposition = decisionDisposition(action);
    if (disposition === 'legacy') { return '这份旧提案缺少可核验快照，不能直接执行。请核对当前计划后重新生成预览。'; }
    if (disposition === 'expired') { return '预览已过期，请读取最新课表和任务后重新生成；旧预览不会执行。'; }
    if (disposition === 'conflict') { return '候选中存在阻断冲突，请调整安排并生成新的预览。'; }
    if (disposition === 'invalid') { return '提案或执行回执不完整，暂不开放执行或具体结果跳转。'; }
    return '当前预览对应的安排已变化，请重新生成并核对后再执行。';
  }

  private operationLabel(action: PendingAction): string {
    const verb = action.action === 'delete' ? '删除' : action.action === 'update' ? '修改' : '创建';
    return `${verb}${action.kind === 'plan' ? '计划' : '待办'}`;
  }

  private regenerateProposal(action: PendingAction): void {
    this.offerPrompt(`请先读取最新课表、任务与计划，重新生成「${action.title}」的${this.operationLabel(action)}预览。` +
      '请说明新安排与当前课程、已有任务和候选内部的冲突，等待我确认；不要执行旧提案。');
  }

  private completedMessage(action: PendingAction): string {
    const receipt = validatedActionReceipt(action);
    if (receipt === null) { return '执行结果尚未核验，请查询持久回执。'; }
    if (action.action === 'delete') {
      return action.kind === 'plan' ? `计划已删除，${receipt.retained_task_ids.length} 项原任务已保留为独立待办。` : '任务已删除。';
    }
    if (action.action === 'update') { return action.kind === 'plan' ? '计划资料已更新，下属任务未自动改动。' : '任务已更新。'; }
    return action.kind === 'plan' ? `计划已创建，共 ${receipt.milestone_ids.length} 个里程碑、${receipt.task_ids.length} 项任务。` : '待办已创建。';
  }

  private acceptResolvedAction(action: PendingAction): void {
    this.replaceAction(action);
    this.setFeedback(action.proposal_id, action.status === 'cancelled' ? '服务端已记录取消，此提案不会再执行。' : this.completedMessage(action), false);
    const receipt = validatedActionReceipt(action);
    if (receipt !== null && !this.notifiedReceiptIds.includes(receipt.receipt_id)) {
      this.notifiedReceiptIds = this.notifiedReceiptIds.concat([receipt.receipt_id]);
      this.onPlanningChanged();
    }
  }

  private openReceipt(action: PendingAction): void {
    const current = this.pendingActions.find((item: PendingAction) => item.proposal_id === action.proposal_id);
    if (current === undefined || this.needsReview(current.proposal_id)) { return; }
    const taskId = receiptTaskId(current);
    const planId = receiptPlanId(current);
    if (taskId.length > 0) { this.onOpenTaskDetails(taskId); }
    else if (planId.length > 0) { this.onOpenPlanDetails(planId); }
  }

  private beforeTasks(action: PendingAction): PlanningTaskDraft[] {
    return validReliableAction(action) && action.before_task !== undefined && action.before_task !== null ? [action.before_task] : [];
  }

  private afterTasks(action: PendingAction): PlanningTaskDraft[] {
    return validReliableAction(action) && action.action !== 'delete' && action.payload.task !== undefined ? [action.payload.task] : [];
  }

  private beforePlans(action: PendingAction): PlanningPlanDraft[] {
    return validReliableAction(action) && action.before_plan !== undefined && action.before_plan !== null ? [action.before_plan] : [];
  }

  private afterPlans(action: PendingAction): PlanningPlanDraft[] {
    return validReliableAction(action) && action.action === 'update' && action.payload.plan !== undefined ? [action.payload.plan] : [];
  }

  private async decide(action: PendingAction, confirm: boolean): Promise<void> {
    // Guard the handler as well as the buttons against rapid taps and stale callbacks.
    const current = this.pendingActions.find((item: PendingAction) => item.proposal_id === action.proposal_id);
    if (!this.pageActive || this.deletionBusy || this.loading || this.decisionId.length > 0 || current === undefined || current.status !== 'pending' ||
      this.needsReview(action.proposal_id)) {
      return;
    }
    if (!sameActionCandidate(action, current)) {
      this.invalidatedProposalIds = this.invalidatedProposalIds.concat([current.proposal_id]);
      this.setFeedback(current.proposal_id, '提案内容已变化，请重新核对预览；本次未执行。', false, 'ACTION_STALE');
      return;
    }
    if (confirm && this.anotherDecisionUnknown(current.proposal_id)) {
      this.setFeedback(current.proposal_id, '请先核对另一份提案的执行结果，再确认这份提案。仍可取消预览或继续聊天。', false);
      return;
    }
    if (!validReliableAction(current) || (confirm && (!canConfirmAction(current) || this.requiresNewPreview(current)))) {
      this.setFeedback(current.proposal_id, this.proposalBlockMessage(current), false, this.feedbackFor(current.proposal_id)?.code ?? '');
      return;
    }
    this.decisionId = action.proposal_id;
    const revision = this.conversationRevision;
    try {
      const api = new CampusFlowApi(this.baseUrl, this.token);
      const result = confirm ? await api.confirmAction(action.proposal_id) : await api.cancelAction(action.proposal_id);
      if (!this.pageActive || revision !== this.conversationRevision ||
        !this.pendingActions.some((item: PendingAction) => item.proposal_id === action.proposal_id)) { return; }
      const expectedStatus = confirm ? 'confirmed' : 'cancelled';
      if (result !== null && sameActionCandidate(current, result.action) &&
        decisionDisposition(result.action) === expectedStatus && result.applied === confirm &&
        sameActionReceipt(result.action.receipt, result.receipt)) {
        this.acceptResolvedAction(result.action);
      } else {
        this.setFeedback(action.proposal_id, '服务返回的状态与本次操作不一致。请核对状态和计划列表，暂不重复提交。', true);
      }
    } catch (error) {
      if (!this.pageActive || revision !== this.conversationRevision ||
        !this.pendingActions.some((item: PendingAction) => item.proposal_id === action.proposal_id)) { return; }
      const failure = this.safeFailure(error);
      const rejectedBeforeWrite = ['LOGIN_REQUIRED', 'ACTION_UNSUPPORTED', 'ACTION_EXPIRED', 'ACTION_LEGACY_UNVERIFIED',
        'ACTION_STALE', 'ACTION_CONFLICT', 'ACTION_INVALID', 'ACTION_NOT_FOUND'].includes(failure.code);
      if (['ACTION_EXPIRED', 'ACTION_LEGACY_UNVERIFIED', 'ACTION_STALE', 'ACTION_CONFLICT', 'ACTION_INVALID', 'ACTION_NOT_FOUND']
        .includes(failure.code) && !this.invalidatedProposalIds.includes(action.proposal_id)) {
        this.invalidatedProposalIds = this.invalidatedProposalIds.concat([action.proposal_id]);
      }
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
      const original = this.pendingActions.find((item: PendingAction) => item.proposal_id === action.proposal_id);
      const latest = await new CampusFlowApi(this.baseUrl, this.token).actionStatus(action.proposal_id);
      if (!this.pageActive || revision !== this.conversationRevision ||
        !this.pendingActions.some((item: PendingAction) => item.proposal_id === action.proposal_id)) { return; }
      if (original === undefined || !sameActionCandidate(original, latest) || !validReliableAction(latest)) {
        this.setFeedback(action.proposal_id, '未取得匹配原预览的可靠状态；旧提案不会重发，请核对计划列表或重新生成。', true);
        return;
      }
      const disposition = decisionDisposition(latest);
      if (disposition === 'confirmed' || disposition === 'cancelled') {
        this.acceptResolvedAction(latest);
      } else if (disposition === 'ready') {
        this.replaceAction(latest);
        this.setFeedback(action.proposal_id, this.invalidatedProposalIds.includes(action.proposal_id) ?
          '服务仍记录为待确认，但这份预览已被判定失效。请重新生成，或取消这份预览。' :
          '可靠服务当前记录为待确认。可再次核对后主动确认同一提案；重复请求会返回同一回执，不会重复写入。', false);
      } else if (disposition === 'expired' || disposition === 'conflict') {
        this.replaceAction(latest);
        this.setFeedback(action.proposal_id, this.proposalBlockMessage(latest), false);
      } else {
        this.setFeedback(action.proposal_id, '服务端状态缺少有效执行回执，请继续核对，暂不重复提交。', true);
      }
    } catch (error) {
      if (!this.pageActive || revision !== this.conversationRevision ||
        !this.pendingActions.some((item: PendingAction) => item.proposal_id === action.proposal_id)) { return; }
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
              EvidencePanel({ evidence: item.evidence ?? [], active: this.voiceActive })
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
    if (action.action !== 'create') {
      return action.action === 'delete' ? '请核对将移除的内容与保留范围' : '请完整核对修改前与修改后内容';
    }
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

  @Builder
  private TaskDraftDetails(task: PlanningTaskDraft) {
    Column({ space: 8 }) {
      Text(task.title).fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink)
        .width('100%').wordBreak(WordBreak.BREAK_WORD)
      TaskScheduleDetails({ startAt: task.start_at, endAt: task.end_at, location: task.location, reminderMinutes: task.reminder_minutes })
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private PlanDraftDetails(plan: PlanningPlanDraft) {
    Column({ space: 8 }) {
      Text(plan.title).fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink)
        .width('100%').wordBreak(WordBreak.BREAK_WORD)
      Text(plan.summary.length > 0 ? plan.summary : '未填写计划说明').fontSize(AppTheme.bodySize)
        .fontColor(AppTheme.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
      Text(plan.target_date === null ? '未设截止日' : `截止 ${plan.target_date}`).fontSize(AppTheme.metaSize)
        .fontColor(AppTheme.quiet).width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private ProposalChanges(action: PendingAction) {
    Column({ space: 12 }) {
      Text(action.action === 'delete' ? '将删除的原内容' : '修改前').fontSize(AppTheme.bodySize)
        .fontWeight(FontWeight.Medium).fontColor(AppTheme.ink).width('100%')
      ForEach(this.beforeTasks(action), (task: PlanningTaskDraft) => {
        this.TaskDraftDetails(task)
      }, (_task: PlanningTaskDraft) => `${action.proposal_id}-before-task`)
      ForEach(this.beforePlans(action), (plan: PlanningPlanDraft) => {
        this.PlanDraftDetails(plan)
      }, (_plan: PlanningPlanDraft) => `${action.proposal_id}-before-plan`)
      Divider().color(AppTheme.line)
      if (action.action === 'delete') {
        Text(action.kind === 'plan' ?
          `只移除计划与里程碑，${action.before_plan?.task_count ?? 0} 项现有任务将保留为独立待办。` :
          '确认后移除此任务；如果它属于计划，计划的任务计数也会更新。')
          .fontSize(AppTheme.bodySize).fontColor(AppTheme.red).width('100%').wordBreak(WordBreak.BREAK_WORD)
      } else {
        Text('修改后').fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium).fontColor(AppTheme.actionBlue).width('100%')
        ForEach(this.afterTasks(action), (task: PlanningTaskDraft) => {
          this.TaskDraftDetails(task)
        }, (_task: PlanningTaskDraft) => `${action.proposal_id}-after-task`)
        ForEach(this.afterPlans(action), (plan: PlanningPlanDraft) => {
          this.PlanDraftDetails(plan)
        }, (_plan: PlanningPlanDraft) => `${action.proposal_id}-after-plan`)
        if (action.kind === 'plan') {
          Text('本次只修改计划资料；原有里程碑与任务不会自动改期或删除。')
            .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
        }
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(12)
      .backgroundColor(AppTheme.canvas).borderRadius(AppTheme.controlRadius)
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
      Text(`当前：${this.selectedModelLabel()}`).fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
      if (this.modelsLoading) { Text('正在核对模型配置…').fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%') }
      if (this.modelsMessage.length > 0) { Text(this.modelsMessage).fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%') }
      if (this.modelCatalog !== null) {
        ForEach(this.modelCatalog.models, (option: ModelOption) => {
          Column({ space: 4 }) {
            Button(`${option.label}${this.model === option.id ? ' · 已选' : ''}${this.modelCatalog?.default_model === option.id ? ' · 服务推荐' : ''}`).width('100%')
              .constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
              .fontColor(this.model === option.id ? '#FFFFFF' : AppTheme.actionBlue)
              .backgroundColor(this.model === option.id ? AppTheme.actionBlue : AppTheme.blueSoft)
              .borderRadius(AppTheme.controlRadius).enabled(!this.loading && this.decisionId.length === 0 && !this.deletionBusy && modelUnavailableReason(option).length === 0)
              .onClick(() => this.selectModel(option.id))
            Text(`${option.provider} · 工具${option.supports_tools ? '支持' : '未声明'} · 增量回答${option.supports_streaming ? '支持' : '未声明'} · 推理${option.supports_reasoning ? '已声明' : '未声明'}`)
              .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
            if (modelUnavailableReason(option).length > 0) {
              Text(modelUnavailableReason(option)).fontSize(AppTheme.metaSize).fontColor(AppTheme.red).width('100%').wordBreak(WordBreak.BREAK_WORD)
            }
          }.width('100%').alignItems(HorizontalAlign.Start)
        }, (option: ModelOption) => `${option.id}-${this.modelsDataRevision}`)
      }
      Button('刷新模型列表').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize).fontColor(AppTheme.actionBlue)
        .backgroundColor(AppTheme.surface).enabled(!this.modelsLoading).onClick(() => this.loadModels())
      Text('能力来自服务配置声明，可用表示配置已就绪，不代表已完成真实模型评测。切换只影响后续消息，历史模型仍按原记录展示。')
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
  private RunPanel() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Text(this.runState.errorCode === 'RUN_DELETED' ? '运行已删除' : this.runState.snapshot !== null ? this.runStatusLabel(this.runState.snapshot) :
          (this.runState.phase === 'creating' ? '正在提交运行' : '核对本次运行'))
          .fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink).layoutWeight(1)
        if (['creating', 'polling', 'checking', 'cancelling'].includes(this.runState.phase)) {
          LoadingProgress().width(20).height(20).color(AppTheme.actionBlue)
        }
      }.width('100%')
      if (this.runState.message.length > 0) {
        Text(this.runState.message).fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
          .wordBreak(WordBreak.BREAK_WORD)
      }
      if (this.runState.snapshot !== null) {
        Text(`实际模型调用 ${this.runState.snapshot.model_calls} 次 · 工具调用 ${this.runState.snapshot.tool_calls} 次`)
          .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
        if (this.restoredRunIds.includes(this.runState.runId)) {
          Text('这是恢复查看的运行。下方新输入仍发到当前会话，未切换到旧历史会话。')
            .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
        }
        if (this.runState.snapshot.tool_progress.length > 0) {
          Button(this.runProgressExpanded ? '收起实际工具进度' : `查看 ${this.runState.snapshot.tool_progress.length} 条实际工具进度`)
            .width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
            .fontColor(AppTheme.actionBlue).backgroundColor(Color.Transparent)
            .onClick(() => this.runProgressExpanded = !this.runProgressExpanded)
          if (this.runProgressExpanded) {
            ForEach(this.runState.snapshot.tool_progress, (tool: RunToolProgress) => {
              Column({ space: 4 }) {
                Text(`${tool.label} · ${tool.state === 'running' ? '正在执行' : tool.state === 'success' ? '已返回' : '调用失败'}`)
                  .fontSize(AppTheme.bodySize).fontColor(AppTheme.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
                if (tool.summary.length > 0) {
                  Text(tool.summary).fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
                }
              }.width('100%').alignItems(HorizontalAlign.Start)
            }, (tool: RunToolProgress) => `${this.runState.runId}-${tool.call_id}-${this.runState.lastAppliedSeq}`)
          }
        }
      }
      if (this.canCancelRun()) {
        Button('取消本次运行').width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
          .fontColor(AppTheme.red).backgroundColor(AppTheme.redSoft).borderRadius(AppTheme.controlRadius)
          .enabled(!this.deletionBusy).onClick(() => this.cancelRun())
      }
      if (this.runState.canRetryStart) {
        Text('尚不能确定首次提交是否到达。重试会沿用同一运行标识和原问题，不创建另一笔请求。')
          .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
        Button('重试提交同一运行').width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
          .fontColor(AppTheme.actionBlue).backgroundColor(AppTheme.blueSoft).borderRadius(AppTheme.controlRadius)
          .enabled(!this.deletionBusy).onClick(() => this.retryRunStart())
      }
      if (this.runState.errorCode !== 'RUN_DELETED') {
        Button('核对运行状态').width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
          .fontColor(AppTheme.actionBlue).backgroundColor(Color.Transparent)
          .enabled(!this.deletionBusy && !['creating', 'checking', 'cancelling', 'polling'].includes(this.runState.phase))
          .onClick(() => this.refreshRun())
      }
      if (this.loading) {
        Text('切换页面会暂停本机刷新，服务端可能继续运行；返回后将核对实际状态。')
          .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
      }
    }.width('100%').padding(AppTheme.cardInset).backgroundColor(AppTheme.canvas)
      .alignItems(HorizontalAlign.Start).borderRadius(AppTheme.cardRadius)
  }

  @Builder
  private RunRecords() {
    Column({ space: 12 }) {
      Text('最近运行 · 仅联网查看').fontSize(AppTheme.sectionTitle).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink).width('100%')
      Text('最多显示最近 20 次。恢复只查询原运行，不重新发送问题；重启后的中断运行需你明确发起新请求。')
        .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
      if (this.runState.listMessage.length > 0) {
        Text(this.runState.listMessage).fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
      }
      if (this.runState.listLoading) { LoadingProgress().width(24).height(24).color(AppTheme.actionBlue) }
      if (!this.runState.listLoading && this.runState.recent.length === 0) {
        Text('暂无可展示的运行记录。').fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet).width('100%')
      }
      ForEach(this.runState.recent, (run: RunSnapshot) => {
        Column({ space: 8 }) {
          Text(run.message).fontSize(AppTheme.bodySize).fontColor(AppTheme.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
          Text(`${this.runStatusLabel(run)} · ${formatPlanDateTime(run.created_at)}（北京时间）`)
            .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
          Button(this.runState.runId === run.run_id ? '核对当前运行' : '恢复查看这次运行').width('100%')
            .constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize).fontColor(AppTheme.actionBlue)
            .backgroundColor(AppTheme.blueSoft).borderRadius(AppTheme.controlRadius)
            .enabled(!this.deletionBusy && (!this.loading || this.runState.runId === run.run_id))
            .onClick(() => this.runState.runId === run.run_id ? this.refreshRun() : this.recoverRun(run.run_id))
        }.width('100%').alignItems(HorizontalAlign.Start).padding(12).backgroundColor(AppTheme.surface).borderRadius(AppTheme.controlRadius)
      }, (run: RunSnapshot) => `${run.run_id}-${run.seq}`)
      Button('刷新运行记录').width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
        .fontColor(AppTheme.actionBlue).backgroundColor(Color.Transparent).enabled(!this.runState.listLoading)
        .onClick(() => this.runController().loadRecent())
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private ConversationMessage(message: ConversationEntry) {
    if (message.role === 'feedback') {
      this.RequestFailure(message)
    } else {
      Row() {
        if (message.role === 'user') { Blank() }
        Column({ space: 12 }) {
          if (message.restored === true && message.role === 'user') {
            Text('恢复的运行 · 原问题').fontSize(AppTheme.metaSize).fontColor('#FFFFFF').width('100%')
          }
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
                .enabled(message.incomplete !== true && (this.speechPending() && this.voiceState.speakingMessageId === message.id ||
                  !this.loading && !this.deletionBusy && this.decisionId.length === 0 && !this.capturePending()))
                .onClick(() => this.speakReply(message))
            }.width('100%')
          }
          if (message.incomplete === true) {
            Text('已收到的回答片段 · 尚未形成完整结果').fontSize(AppTheme.metaSize)
              .fontColor(AppTheme.orange).width('100%')
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
        Text(`${this.operationLabel(action)}提案`)
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
        if (action.action !== 'create' && validReliableAction(action)) {
          this.ProposalChanges(action)
        } else if (action.kind === 'plan') {
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
            location: action.payload.task?.location ?? action.payload.location ?? null, reminderMinutes: action.reminder_minutes })
        }
        if (action.conflicts.length > 0) {
          Text('需要调整的冲突').fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium).fontColor(AppTheme.red).width('100%')
          ForEach(action.conflicts, (conflict: string, index: number) => {
            Text(`${index + 1}. ${conflict}`).fontSize(AppTheme.metaSize).fontColor(AppTheme.red).width('100%')
              .wordBreak(WordBreak.BREAK_WORD)
          }, (_conflict: string, index: number) => `${action.proposal_id}-conflict-${index}`)
        }
        if ((action.warnings ?? []).length > 0) {
          Text('仍需手动核对').fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium).fontColor(AppTheme.orange).width('100%')
          ForEach(action.warnings ?? [], (warning: string, index: number) => {
            Text(`${index + 1}. ${warning}`).fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
              .wordBreak(WordBreak.BREAK_WORD)
          }, (_warning: string, index: number) => `${action.proposal_id}-warning-${index}`)
        }
        if (validReliableAction(action)) {
          Text(action.status === 'pending' ? `预览有效至 ${formatPlanDateTime(action.expires_at ?? null)}（北京时间）` :
            `原预览生成于 ${formatPlanDateTime(action.created_at ?? null)}（北京时间）`)
            .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
        }
        if ((action.reason ?? '').length > 0) {
          Text(action.reason ?? '').fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
        }
      }
      if (validatedActionReceipt(action) !== null) {
        Text(`执行回执 · ${formatPlanDateTime(action.receipt?.applied_at ?? null)}（北京时间）`)
          .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
        Text(this.completedMessage(action)).fontSize(AppTheme.bodySize).fontColor(AppTheme.ink).width('100%')
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
      } else if (decisionDisposition(action) === 'confirmed' || decisionDisposition(action) === 'cancelled') {
        Button(this.receiptCollapsed(action) ? '查看原提案' : '收起原提案')
          .width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
          .fontColor(AppTheme.actionBlue).backgroundColor(AppTheme.blueSoft).borderRadius(AppTheme.controlRadius)
          .onClick(() => this.toggleReceipt(action.proposal_id))
        if (action.status === 'confirmed') {
          if (receiptTaskId(action).length > 0 || receiptPlanId(action).length > 0) {
            Button(action.kind === 'task' ? '查看这个任务' : '查看这个计划').width('100%').constraintSize({ minHeight: 48 })
              .fontSize(AppTheme.bodySize).fontColor(AppTheme.actionBlue).backgroundColor(Color.Transparent)
              .onClick(() => this.openReceipt(action))
          } else {
            Button('查看计划列表').width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
              .fontColor(AppTheme.actionBlue).backgroundColor(Color.Transparent).onClick(() => this.onOpenPlan())
          }
        }
      } else if (this.requiresNewPreview(action)) {
        Text(this.proposalBlockMessage(action)).fontSize(AppTheme.metaSize).fontColor(AppTheme.orange).width('100%')
        Button('填入重新规划建议').width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
          .fontColor(AppTheme.actionBlue).backgroundColor(AppTheme.blueSoft).borderRadius(AppTheme.controlRadius)
          .onClick(() => this.regenerateProposal(action))
        if (action.status === 'confirmed' || action.status === 'cancelled') {
          Button('核对持久状态').width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
            .fontColor(AppTheme.actionBlue).backgroundColor(Color.Transparent)
            .enabled(!this.loading && !this.deletionBusy && this.decisionId.length === 0).onClick(() => this.checkDecision(action))
        } else if (action.status === 'pending' && validReliableAction(action)) {
          Button('取消这份预览').width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
            .fontColor(AppTheme.quiet).backgroundColor(Color.Transparent)
            .enabled(!this.loading && !this.deletionBusy && this.decisionId.length === 0).onClick(() => this.decide(action, false))
        }
      } else if (action.status === 'pending') {
        if (this.anotherDecisionUnknown(action.proposal_id)) {
          Text('先核对另一份提案的执行结果，再确认这份提案。仍可取消预览或继续聊天。')
            .fontSize(AppTheme.metaSize).fontColor(AppTheme.orange).width('100%').wordBreak(WordBreak.BREAK_WORD)
        }
        Row({ space: 8 }) {
          Button('暂不执行').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet)
            .backgroundColor(AppTheme.field).borderRadius(AppTheme.controlRadius).layoutWeight(1)
            .enabled(!this.loading && !this.deletionBusy && this.decisionId.length === 0)
            .onClick(() => this.decide(action, false))
          Button(this.decisionId === action.proposal_id ? '处理中…' : `确认${this.operationLabel(action)}`)
            .constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize).fontColor('#FFFFFF')
            .backgroundColor(AppTheme.actionBlue).borderRadius(AppTheme.controlRadius).layoutWeight(1)
            .enabled(!this.loading && !this.deletionBusy && this.decisionId.length === 0 && canConfirmAction(action) &&
              !this.anotherDecisionUnknown(action.proposal_id))
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
          Button(this.runRecordsExpanded ? '收起最近运行' : '最近运行 · 恢复查看').width('100%')
            .constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize).fontColor(AppTheme.actionBlue)
            .backgroundColor(Color.Transparent).onClick(() => this.toggleRunRecords())
          if (this.runRecordsExpanded) { this.RunRecords() }
          if (this.runState.runId.length > 0) { this.RunPanel() }
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
          }, (message: ConversationEntry) => `${message.id}-${message.revision ?? 0}`)
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
      if (this.selectedModelBlocked()) {
        Column({ space: 4 }) {
          Text(this.selectedModelReason()).fontSize(AppTheme.metaSize).fontColor(AppTheme.red).width('100%').wordBreak(WordBreak.BREAK_WORD)
          Button('选择可用模型').constraintSize({ minHeight: 48 }).fontColor(AppTheme.actionBlue).backgroundColor(AppTheme.blueSoft)
            .onClick(() => this.showModelOptions())
        }.width('100%').padding({ left: 20, right: 20, top: 8, bottom: 8 })
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
                Text(this.voiceProbeBusy ? '正在检测…' : '语音输入').fontSize(AppTheme.bodySize).fontColor(AppTheme.actionBlue)
              }
            }.constraintSize({ minHeight: 48 }).padding({ left: 10, right: 10 })
              .backgroundColor(Color.Transparent).borderRadius(AppTheme.controlRadius)
              .accessibilityText('开始语音输入，识别后可编辑，不自动发送')
              .enabled(this.voiceActive && !this.voiceProbeBusy && !this.loading && !this.deletionBusy && this.decisionId.length === 0)
              .onClick(() => this.startVoice())
          }
        }.width('100%')
        Text('语音由设备系统服务处理，部分系统可能联网。CampusFlow 不保存录音；识别文字确认后才会发送。')
          .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
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
            .enabled(!this.selectedModelBlocked() && !this.capturePending() && !this.loading && !this.deletionBusy && this.decisionId.length === 0 && this.inputLength(this.prompt) > 0 && this.inputLength(this.prompt) <= 8000).onClick(() => this.send())
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
