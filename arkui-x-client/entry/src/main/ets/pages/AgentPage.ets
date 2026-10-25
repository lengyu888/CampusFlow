import { HistoryMessage, SessionSummary, PendingAction, PendingMilestonePreview, PendingTaskPreview, ToolDisplaySummary, PlanningTaskDraft, PlanningPlanDraft, RunSnapshot, RunToolProgress, ModelCatalog, ModelOption, RunStartRequest, PlanningTask } from '../model/ApiModels';
import { CampusFlowApi } from '../services/CampusFlowApi';
import { localDrafts } from '../services/LocalDrafts';
import { DraftLease, DraftRecord, DraftOperation, AssistantDraft, DraftRunRequest, DraftSaveState, DraftKey, assistantDraftKey } from '../utils/DraftStore';
import { shanghaiDate } from '../utils/DailyAgenda';
import { localHistory } from '../services/LocalHistory';
import { MessageContent } from '../components/MessageContent';
import { InfoDisclosure } from '../components/InfoDisclosure';
import { AppTheme } from '../theme/AppTheme';
import { ThemePalette, themePalette } from '../theme/ThemePalette';
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
import { SessionContext, CoursePermissionChoice, CourseAcknowledgement, CourseReview, DataEvidence } from '../model/ApiModels';
import { conversationTitle, proposalOverview, proposalSources, validSessionContext, samePermissionReplacement } from '../utils/ConversationPresentation';
import { AgentProposalSummary } from '../components/AgentProposalSummary';
import { CourseReviewPanel } from '../components/CourseReviewPanel';
import { courseCandidates, validCourseAcknowledgements } from '../utils/CourseReview';

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
  @StorageLink('campusflowThemePalette') private palette: ThemePalette = themePalette('paper-green');
  @Watch('modelConnectionChanged') @Prop baseUrl: string;
  @Watch('modelConnectionChanged') @Prop token: string;
  @Prop historyScope: string = '';
  @Prop userId: string = '';
  @Prop @Watch('sessionRequested') requestedSessionId: string = '';
  @Prop @Watch('sessionRequested') resumeRevision: number = 0;
  @Prop @Watch('draftLeaseChanged') draftLease: DraftLease | null = null;
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
  @Prop statusLockedTaskIds: string[] = [];
  onOpenStatus: (taskId: string) => void = () => {};
  onOpenProfile: () => void = () => {};
  onChatBusyChange: (busy: boolean) => void = () => {};
  @State private prompt: string = '';
  @State private sessionTitle: string = '';
  @State private sessionNotice: string = '';
  @State private sessionLoading: boolean = false;
  @State private switchTarget: string = '';
  private switchRunId: string = '';
  private switchDraftId: string = '';
  private contextReadRevision: number = 0;
  @State private switchConfirmOpen: boolean = false;
  @State private voiceExplanationOpen: boolean = false;
  private voiceExplanationAccepted: boolean = false;
  private explainedSpeechId: string = '';
  private appliedResumeRevision: number = -1;
  private sessionRequestQueued: boolean = false;
  private boundDraftOwner: string = '';
  private sessionRequestRevision: number = 0;
  private contextRevision: string = '';
  private sessionMode: 'new' | 'continue' = 'new';
  @State private selectedCourseAcks: CourseAcknowledgement[] = [];
  private courseAckProposalId: string = '';
  @State private decisionOperations: DraftOperation[] = [];
  @State private otherDecisionOperations: DraftOperation[] = [];
  @State private otherDrafts: DraftRecord[] = [];
  @State private permissionChoices: CoursePermissionChoice[] = [];
  @State private permissionProposalId: string = '';
  @State private adjustingProposalId: string = '';
  @State private adjustmentText: string = '';
  @State private adjustmentReady: boolean = false;
  @State private recoverableDraft: DraftRecord | null = null;
  @State private draftOperations: DraftOperation[] = [];
  @State private draftMessage: string = '本机草稿尚未就绪。';
  @State private draftNotice: string = '';
  @State private draftPhase: string = 'idle';
  @State private draftAnchorDate: string = '';
  private draftKey: DraftKey = { kind: 'assistant', ownerId: 'main' };
  private boundDraftLease: DraftLease | null = null;
  private draftBindingRevision: number = 0;
  private draftUnsubscribe: (() => void) | null = null;
  private draftLocalRevision: number = 0;
  private settlingDraftRuns: string[] = [];

  @State private availableHeight: number = 600;
  @State private composerExpanded: boolean = false;
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
  private sessionId: string = `arkuix-${this.newRunId()}`;
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
  private liveRecoveredRunIds: string[] = [];
  private cachedRunRequests: string[] = [];
  private displayedRunFailures: string[] = [];
  private historySaveGenerations: HistorySaveGeneration[] = [];
  private nextHistorySaveRevision: number = 0;
  private deletedRunSessionIds: string[] = [];

  aboutToAppear(): void {
    this.pageActive = true;
    try {
      PersistentStorage.persistProp('voiceUsageExplained', false);
      this.voiceExplanationAccepted = AppStorage.get<boolean>('voiceUsageExplained') ?? false;
    } catch { /* A settings failure keeps the explanation visible instead of assuming consent. */ }
    this.bindDraftLease();
    this.loadModels();
    this.sessionRequested();
    if (this.receivedPromptRevision !== this.promptRevision) {
      this.initialPromptChanged();
    }
  }

  aboutToDisappear(): void {
    this.flushDraft();
    this.draftUnsubscribe?.(); this.draftUnsubscribe = null;
    this.pageActive = false;
    this.sessionRequestRevision++;
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

  private sessionRequested(): void {
    if (this.sessionRequestQueued) { return; }
    this.sessionRequestQueued = true;
    // Both props can update independently; consume their final pair in this render turn.
    Promise.resolve().then(() => {
      this.sessionRequestQueued = false;
      if (!this.pageActive || !this.voiceActive || this.requestedSessionId.length === 0 || this.appliedResumeRevision === this.resumeRevision) { return; }
      if (this.sessionLoading) { this.sessionRequestRevision++; this.sessionLoading = false; }
      this.appliedResumeRevision = this.resumeRevision;
      this.requestConversation(this.requestedSessionId);
    });
  }

  private requestConversation(id: string = ''): void {
    if (!this.pageActive || !this.voiceActive || this.sessionLoading || this.deletionBusy) { return; }
    this.switchTarget = id; this.switchRunId = ''; this.switchDraftId = '';
    if (id === this.sessionId) { this.refreshSessionContext(); return; }
    const unfinished = this.prompt.trim().length > 0 || this.recoverableDraft !== null || this.capturePending() ||
      this.loading || this.attentionActions().length > 0 || this.decisionId.length > 0 || this.decisionOperations.length > 0 || this.adjustingProposalId.length > 0;
    this.switchConfirmOpen = unfinished;
    if (!unfinished) { this.switchConversation(); }
  }

  private async switchConversation(): Promise<void> {
    if (!this.pageActive || !this.voiceActive || this.sessionLoading || this.deletionBusy) { return; }
    if (this.decisionId.length > 0 || this.decisionOperations.length > 0 || this.pendingActions.some((action: PendingAction) => this.needsReview(action.proposal_id))) {
      this.sessionNotice = '先核对正在提交或结果未知的提案，再切换会话。原编号和输入均已保留。'; return;
    }
    if (this.capturePending()) { this.sessionNotice = '请先将识别文字填入原输入，或明确放弃语音，再切换会话。'; return; }
    if (this.recoverableDraft !== null) { this.sessionNotice = '请先恢复或舍弃上次输入，避免切换时覆盖尚未处理的草稿。'; return; }
    const lease = this.draftLease; const revision = ++this.sessionRequestRevision;
    const target = this.switchTarget; const targetRun = this.switchRunId; const account = this.userId; const scope = this.historyScope;
    if (lease === null || !localDrafts.valid(lease) || !this.stagePrompt()) { this.sessionNotice = '请先恢复本机保存，输入尚未切换。'; return; }
    this.sessionLoading = true; this.sessionNotice = '';
    try {
      await localDrafts.flush(lease);
      if (!this.sessionRequestCurrent(revision, lease, account, scope)) { return; }
      let context: SessionContext | null = null;
      let targetWasActive: boolean = false;
      if (target.length > 0) {
        try { context = await new CampusFlowApi(this.baseUrl, this.token).sessionContext(target); }
        catch (error) {
          // A queued first turn has no completed history. Its owned run remains the authority.
          const failure: CampusFlowRequestError = this.safeFailure(error as Error);
          if ((targetRun.length === 0 && this.switchDraftId !== target) || failure.code !== 'SESSION_NOT_FOUND') { throw failure; }
          if (targetRun.length > 0) {
          const run = await new CampusFlowApi(this.baseUrl, this.token).agentRun(targetRun);
          if (run.run_id !== targetRun || run.session_id !== target) { throw localRequestFailure('INVALID_RESPONSE'); }
          targetWasActive = ['queued', 'running'].includes(run.status);
          }
        }
      }
      if (!this.sessionRequestCurrent(revision, lease, account, scope)) { return; }
      if (context !== null && !validSessionContext(context, account, target)) { throw localRequestFailure('INVALID_RESPONSE'); }
      await localDrafts.flush(lease);
      if (!this.sessionRequestCurrent(revision, lease, account, scope)) { return; }
      this.enterConversation(target.length === 0 ? `arkuix-${this.newRunId()}` : target, context);
      this.switchConfirmOpen = false;
      this.sessionNotice = context === null ? '已开始新对话，原会话输入保留在本机。' : '已读取服务端文字上下文；旧缓存提案不会恢复为可执行操作。';
      const recoverId = context === null ? targetRun : context.active_run?.run_id ?? '';
      if (recoverId.length > 0) {
        this.restoredRunIds = this.restoredRunIds.concat([recoverId]);
        if (context?.active_run !== null && context?.active_run !== undefined || targetWasActive) {
          this.liveRecoveredRunIds = this.liveRecoveredRunIds.concat([recoverId]);
        }
        await this.runController().recover(recoverId);
      }
    } catch (error) {
      if (this.sessionRequestCurrent(revision, lease, account, scope)) { this.sessionNotice = `未切换会话，原输入保留。${this.safeFailure(error).message}`; }
    } finally {
      if (revision === this.sessionRequestRevision) { this.sessionLoading = false; }
    }
  }

  private sessionRequestCurrent(revision: number, lease: DraftLease, account: string, scope: string): boolean {
    return this.pageActive && this.voiceActive && revision === this.sessionRequestRevision && this.draftLease === lease &&
      localDrafts.valid(lease) && this.userId === account && this.historyScope === scope;
  }

  private enterConversation(id: string, context: SessionContext | null): void {
    this.cancelVoice(); this.voiceExplanationOpen = false;
    this.runInteraction?.dispose(); this.runInteraction = null;
    this.conversationRevision++; this.contextReadRevision++;
    this.sessionId = id; this.sessionTitle = context?.summary.title ?? '';
    this.contextRevision = context?.context_revision ?? ''; this.sessionMode = context === null ? 'new' : 'continue';
    this.savedMessages = context?.messages.map((item: HistoryMessage): HistoryMessage => ({ role: item.role, content: item.content, created_at: item.created_at })) ?? [];
    this.messages = this.savedMessages.map((item: HistoryMessage, index: number): ConversationEntry => ({
      id: `history-${id}-${index}`, role: item.role, content: item.content, tools: [], failedPrompt: '', failureCode: '', sessionId: id
    }));
    this.pendingActions = []; this.proposalOrigins = []; this.decisionFeedback = []; this.decisionId = '';
    this.invalidatedProposalIds = []; this.notifiedReceiptIds = []; this.expandedReceiptIds = []; this.expandedProposalIds = [];
    this.decisionOperations = []; this.adjustingProposalId = ''; this.adjustmentText = ''; this.adjustmentReady = false;
    this.cacheNotice = ''; this.collapsedToolIds = []; this.courseAckProposalId = '';
    this.selectedCourseAcks = []; this.permissionChoices = []; this.permissionProposalId = '';
    this.messageAnchors = []; this.proposalAnchors = []; this.pendingJumpId = ''; this.focusedProposalId = '';
    this.unreadMessages = 0; this.followLatest = true; this.scrollForNewMessage = true;
    this.prompt = ''; this.promptSuggestions = []; this.suggestionNotice = ''; this.draftAnchorDate = '';
    this.loading = false; this.onChatBusyChange(false);
    this.runState = { phase: 'idle', runId: '', request: null, snapshot: null, events: [], recent: [],
      message: '', listMessage: '', listLoading: false, lastAppliedSeq: 0, canRetryStart: false, errorCode: '' };
    this.runRecordsExpanded = false; this.runProgressExpanded = false; this.liveRecoveredRunIds = [];
    this.draftKey = assistantDraftKey(id); this.bindDraftLease();
    this.conversationCreatedAt = context?.summary.created_at ?? new Date().toISOString();
  }

  private async refreshSessionContext(): Promise<void> {
    const id = this.sessionId; const revision = this.conversationRevision; const account = this.userId;
    const readRevision = ++this.contextReadRevision;
    if (account.length === 0) { return; }
    try {
      const context = await new CampusFlowApi(this.baseUrl, this.token).sessionContext(id);
      if (!this.pageActive || readRevision !== this.contextReadRevision || revision !== this.conversationRevision || account !== this.userId || id !== this.sessionId) { return; }
      if (!validSessionContext(context, account, id)) { throw localRequestFailure('INVALID_RESPONSE'); }
      this.applyContextMessages(context);
      this.contextRevision = context.context_revision; this.sessionMode = 'continue'; this.sessionTitle = context.summary.title;
      this.sessionNotice = '';
    } catch (error) {
      if (this.pageActive && readRevision === this.contextReadRevision && revision === this.conversationRevision) {
        this.contextRevision = ''; this.sessionNotice = `会话上下文尚未核对，请刷新后继续发送。${this.safeFailure(error).message}`;
      }
    }
  }

  private applyContextMessages(context: SessionContext): void {
    const previous = this.messages.slice().reverse(); const used: string[] = [];
    const rebuilt: ConversationEntry[] = [];
    for (let index = context.messages.length - 1; index >= 0; index--) {
      const item = context.messages[index];
      const matched = previous.find((entry: ConversationEntry) => !used.includes(entry.id) &&
        entry.role === item.role && entry.content === item.content && entry.incomplete !== true &&
        (entry.sessionId === undefined || entry.sessionId === this.sessionId));
      if (matched !== undefined) { used.push(matched.id); rebuilt.unshift(matched); }
      else { rebuilt.unshift({ id: `history-${this.sessionId}-${index}-${context.context_revision}`, role: item.role,
        content: item.content, tools: [], failedPrompt: '', failureCode: '', sessionId: this.sessionId }); }
    }
    this.savedMessages = context.messages.map((item: HistoryMessage): HistoryMessage => ({ role: item.role, content: item.content, created_at: item.created_at }));
    // Match surviving answer bubbles by exact text/role so their live proposals keep the same anchor.
    // Never turn history text into actions; unmatched local pending results remain visibly separate.
    const live = this.messages.filter((entry: ConversationEntry) => !used.includes(entry.id) &&
      (entry.role === 'feedback' || entry.incomplete === true || this.proposalOrigins.some((origin: ProposalOrigin) => origin.messageId === entry.id)));
    this.messages = rebuilt.concat(live);
    this.messageAnchors = []; this.proposalAnchors = [];
  }

  private draftLeaseChanged(): void { this.bindDraftLease(); }

  private draftCurrent(lease: DraftLease, revision: number): boolean {
    return this.pageActive && revision === this.draftBindingRevision && localDrafts.valid(lease) &&
      this.draftLease?.scope === lease.scope && this.draftLease?.generation === lease.generation;
  }

  private bindDraftLease(): void {
    this.draftKey = assistantDraftKey(this.sessionId);
    const lease = this.draftLease;
    const same = lease !== null && this.boundDraftLease?.scope === lease.scope &&
      this.boundDraftLease?.generation === lease.generation && this.boundDraftOwner === this.draftKey.ownerId;
    if (!same) {
      this.draftBindingRevision++; this.draftUnsubscribe?.(); this.draftUnsubscribe = null;
      if (this.boundDraftLease !== null) {
        // Never transfer the previous account's input or pending request to a new lease.
        this.prompt = ''; this.promptSuggestions = []; this.draftAnchorDate = '';
        this.runInteraction?.dispose(); this.runInteraction = null;
        this.loading = false; this.onChatBusyChange(false);
      }
      this.boundDraftLease = lease === null ? null : { scope: lease.scope, generation: lease.generation };
      this.boundDraftOwner = this.draftKey.ownerId;
      this.recoverableDraft = null; this.draftOperations = []; this.draftLocalRevision = 0;
      this.draftNotice = ''; this.settlingDraftRuns = [];
    }
    if (lease === null || !localDrafts.valid(lease)) {
      this.draftPhase = 'error'; this.draftMessage = '本机草稿暂不可用，输入仍保留；恢复保存后才能发送。'; return;
    }
    if (!same) {
      const saved = localDrafts.read(lease, this.draftKey) ?? localDrafts.read(lease, { kind: 'assistant', ownerId: 'main' });
      if (saved !== undefined && !localDrafts.isBlocked(lease, { kind: saved.kind, ownerId: saved.ownerId }, saved.localRevision)) {
        if ((saved.payload as AssistantDraft).text.length > 0) { this.recoverableDraft = saved; }
      }
    }
    if (this.draftUnsubscribe === null) {
      const revision = this.draftBindingRevision;
      this.draftUnsubscribe = localDrafts.subscribe((state: DraftSaveState): void => {
        if (!this.draftCurrent(lease, revision) || state.scope !== lease.scope || state.generation !== lease.generation) { return; }
        this.draftPhase = state.phase; this.draftMessage = state.message;
        this.draftOperations = localDrafts.operations(lease).filter((item: DraftOperation): boolean =>
          item.kind === 'run' && item.draftKind === 'assistant');
        this.decisionOperations = localDrafts.operations(lease).filter((item: DraftOperation): boolean =>
          (item.kind === 'proposal' || item.kind === 'course-permission') && item.sessionId === this.sessionId);
        this.otherDrafts = localDrafts.list(lease, 'assistant').filter((item: DraftRecord) => item.ownerId.startsWith('session:') &&
          (item.payload as AssistantDraft).sessionId !== this.sessionId && (item.payload as AssistantDraft).text.length > 0 &&
          !localDrafts.isBlocked(lease, { kind: item.kind, ownerId: item.ownerId }, item.localRevision));
        this.otherDecisionOperations = localDrafts.operations(lease).filter((item: DraftOperation): boolean =>
          (item.kind === 'proposal' || item.kind === 'course-permission') && item.sessionId !== null && item.sessionId !== this.sessionId);
      });
    }
    const currentRun = this.draftOperations.find((item: DraftOperation) => item.runRequest?.session_id === this.sessionId);
    if (this.voiceActive && currentRun !== undefined && this.runInteraction === null) { this.recoverDraftRun(currentRun); }
    if (this.adjustingProposalId.length === 0) {
      const adjustment = localDrafts.list(lease, 'assistant').find((item: DraftRecord) =>
        item.ownerId.startsWith('agent-adjustment:') && (item.payload as AssistantDraft).sessionId === this.sessionId);
      if (adjustment !== undefined) {
        this.adjustingProposalId = adjustment.ownerId.substring('agent-adjustment:'.length);
        this.adjustmentText = (adjustment.payload as AssistantDraft).text; this.adjustmentReady = false;
      }
    }
  }

  private changePrompt(value: string, keepAnchor: boolean = false): void {
    if (!keepAnchor && this.prompt.length === 0 && value.length > 0) { this.draftAnchorDate = shanghaiDate(Date.now()); }
    this.prompt = value;
    this.stagePrompt();
  }

  private stagePrompt(): boolean {
    const lease = this.draftLease;
    if (this.recoverableDraft !== null) {
      this.draftNotice = '输入框内容尚未覆盖上次草稿，请先恢复或舍弃上次草稿。'; return false;
    }
    if (lease === null || !localDrafts.valid(lease)) {
      this.draftPhase = 'error'; this.draftMessage = '本机草稿暂不可用，输入仍保留；恢复保存后才能发送。'; return false;
    }
    if (this.draftAnchorDate.length === 0) { this.draftAnchorDate = shanghaiDate(Date.now()); }
    const value: AssistantDraft = { text: this.prompt, sessionId: this.sessionId,
      anchorDate: this.draftAnchorDate, timezone: 'Asia/Shanghai' };
    const current = localDrafts.read(lease, this.draftKey);
    if (current !== undefined && JSON.stringify(current.payload) === JSON.stringify(value)) {
      this.draftLocalRevision = current.localRevision; return true;
    }
    try { this.draftLocalRevision = localDrafts.stage(lease, this.draftKey, value).localRevision; return true; }
    catch { this.draftPhase = 'error'; this.draftMessage = localDrafts.status(lease).message; return false; }
  }

  private async flushDraft(): Promise<void> {
    const lease = this.draftLease;
    if (lease === null || !localDrafts.valid(lease)) { return; }
    try { await localDrafts.flush(lease); } catch { /* The store exposes a truthful persistent error state. */ }
  }

  private async restoreStoredDraft(): Promise<void> {
    const saved = this.recoverableDraft; const lease = this.draftLease; const revision = this.draftBindingRevision;
    if (saved === null || this.prompt.length > 0 || lease === null || !localDrafts.valid(lease)) { return; }
    const value = saved.payload as AssistantDraft;
    this.recoverableDraft = null; this.draftAnchorDate = value.anchorDate;
    this.changePrompt(value.text, true);
    this.draftNotice = '已恢复文字，未自动发送。请核对“今天、明天”等相对日期。';
    if (saved.ownerId !== this.draftKey.ownerId) {
      try {
        await localDrafts.flush(lease);
        if (!this.draftCurrent(lease, revision)) { return; }
        await localDrafts.remove(lease, { kind: saved.kind, ownerId: saved.ownerId }, saved.localRevision);
      } catch { if (this.draftCurrent(lease, revision)) { this.draftNotice = '文字已显示；旧草稿仍保留，迁移尚未完整保存。'; } }
    }
  }

  private async discardStoredDraft(): Promise<void> {
    const saved = this.recoverableDraft; const lease = this.draftLease; const revision = this.draftBindingRevision;
    if (saved === null || lease === null || !localDrafts.valid(lease)) { return; }
    try {
      const removed = await localDrafts.remove(lease, { kind: saved.kind, ownerId: saved.ownerId }, saved.localRevision);
      if (!this.draftCurrent(lease, revision)) { return; }
      if (!removed) { this.draftNotice = '草稿已变化或仍有待核对操作，尚未舍弃。'; return; }
      this.recoverableDraft = null; this.draftNotice = '上次草稿已舍弃。';
      if (this.prompt.length > 0) { this.stagePrompt(); }
    } catch { if (this.draftCurrent(lease, revision)) { this.draftNotice = '舍弃失败，原草稿仍保留。'; } }
  }

  private draftBlocksSend(): boolean {
    return this.draftLease === null || !localDrafts.valid(this.draftLease) || this.recoverableDraft !== null ||
      localDrafts.isBlocked(this.draftLease, this.draftKey);
  }

  private async prepareRunDraft(request: RunStartRequest): Promise<void> {
    const lease = this.draftLease; const revision = this.draftBindingRevision;
    const base = this.baseUrl; const token = this.token;
    if (lease === null || !this.draftCurrent(lease, revision) || !this.voiceActive) { throw new Error('draft unavailable'); }
    const existing = localDrafts.operations(lease).find((item: DraftOperation): boolean => item.kind === 'run' && item.id === request.run_id);
    const localRevision = existing?.localRevision ?? this.draftLocalRevision;
    if (existing === undefined) {
      if (localDrafts.isBlocked(lease, this.draftKey)) { throw new Error('another run pending'); }
      const saved = localDrafts.read(lease, this.draftKey);
      if (saved === undefined || saved.localRevision !== localRevision ||
        (saved.payload as AssistantDraft).text.trim() !== request.message ||
        (saved.payload as AssistantDraft).sessionId !== request.session_id) { throw new Error('draft changed'); }
    } else if (existing.runRequest === null || JSON.stringify(existing.runRequest) !== JSON.stringify(request)) {
      throw new Error('request changed');
    }
    const frozen: DraftRunRequest = { run_id: request.run_id, session_id: request.session_id, model: request.model, message: request.message };
    if (request.session_mode !== undefined) { frozen.session_mode = request.session_mode; }
    if (request.expected_context_revision !== undefined) { frozen.expected_context_revision = request.expected_context_revision; }
    await localDrafts.beginOperation(lease, { kind: 'run', id: request.run_id, draftKind: 'assistant', ownerId: this.draftKey.ownerId,
      localRevision: localRevision, runRequest: frozen });
    if (!this.draftCurrent(lease, revision) || !this.voiceActive || base !== this.baseUrl || token !== this.token) {
      throw new Error('draft identity changed');
    }
    // The submitted revision remains durable until the terminal result. New typing creates a newer revision.
    if (this.draftLocalRevision === localRevision && this.prompt.trim() === request.message) { this.prompt = ''; }
  }

  private async recoverDraftRun(operation: DraftOperation): Promise<void> {
    if (!this.pageActive || !this.voiceActive || this.deletionBusy || this.decisionId.length > 0 ||
      this.draftLease === null || !localDrafts.valid(this.draftLease) || operation.scope !== this.draftLease.scope) { return; }
    if (this.userId.length > 0 && operation.runRequest !== null && operation.runRequest.session_id !== this.sessionId) {
      this.requestRunConversation(operation.runRequest.session_id, operation.id); return;
    }
    this.restoredRunIds = this.restoredRunIds.includes(operation.id) ? this.restoredRunIds : this.restoredRunIds.concat([operation.id]);
    this.liveRecoveredRunIds = this.liveRecoveredRunIds.includes(operation.id) ? this.liveRecoveredRunIds : this.liveRecoveredRunIds.concat([operation.id]);
    if (operation.runRequest !== null) {
      const saved = operation.runRequest;
      const request: RunStartRequest = { run_id: saved.run_id, session_id: saved.session_id, model: saved.model, message: saved.message };
      if (saved.session_mode !== undefined) { request.session_mode = saved.session_mode; }
      if (saved.expected_context_revision !== undefined) { request.expected_context_revision = saved.expected_context_revision; }
      await this.runController().recoverRequest(request);
    }
    else { await this.runController().recover(operation.id); }
  }

  private async settleRunDraft(state: AgentRunState): Promise<void> {
    const lease = this.draftLease; const revision = this.draftBindingRevision;
    const terminal = state.snapshot !== null && ['succeeded', 'failed', 'cancelled', 'timed_out', 'budget_exceeded', 'interrupted'].includes(state.snapshot.status);
    if (lease === null || !localDrafts.valid(lease) || (!terminal && state.phase !== 'error') || this.settlingDraftRuns.includes(state.runId)) { return; }
    const operation = localDrafts.operations(lease).find((item: DraftOperation): boolean => item.kind === 'run' && item.id === state.runId);
    if (operation === undefined) { return; }
    this.settlingDraftRuns = this.settlingDraftRuns.concat([state.runId]);
    try {
      const removeSubmitted = state.snapshot?.status === 'succeeded' || state.errorCode === 'RUN_DELETED';
      await localDrafts.resolveOperation(lease, 'run', operation.id, removeSubmitted);
      if (!this.draftCurrent(lease, revision)) { return; }
      if (!removeSubmitted && this.prompt.length === 0) {
        const saved = localDrafts.read(lease, this.draftKey);
        if (saved !== undefined && (saved.payload as AssistantDraft).text.length > 0) { this.recoverableDraft = saved; }
      }
    } catch { if (this.draftCurrent(lease, revision)) { this.draftNotice = '服务器状态已取得，本机核对记录尚未保存。请再次查询同一次运行。'; } }
    finally {
      if (this.draftCurrent(lease, revision)) { this.settlingDraftRuns = this.settlingDraftRuns.filter((id: string): boolean => id !== state.runId); }
    }
  }

  private async settleDeletedDraftSession(sessionId: string): Promise<void> {
    const lease = this.draftLease; const revision = this.draftBindingRevision;
    if (sessionId.length === 0 || lease === null || !localDrafts.valid(lease)) { return; }
    const operations = localDrafts.operations(lease).filter((item: DraftOperation): boolean =>
      item.kind === 'run' && item.runRequest?.session_id === sessionId);
    for (const operation of operations) {
      try { await localDrafts.resolveOperation(lease, 'run', operation.id, true); }
      catch {
        if (this.draftCurrent(lease, revision)) { this.draftNotice = '会话已删除，本机恢复标识清理失败。可核对原运行后重试清理。'; }
      }
    }
  }

  private sessionDeleted(): void {
    // This callback is issued only after an authoritative server deletion or tombstone.
    this.settleDeletedDraftSession(this.deletedSessionId);
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
    this.sessionId = `arkuix-${this.newRunId()}`;
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
    this.resetDeletedSessionDraft();
    this.cacheNotice = '原会话已删除，下次发送将开始新会话。';
  }

  private resetDeletedSessionDraft(): void {
    const text = this.prompt; const anchor = this.draftAnchorDate;
    this.sessionMode = 'new'; this.contextRevision = ''; this.sessionTitle = ''; this.contextReadRevision++;
    this.bindDraftLease();
    this.recoverableDraft = null; this.draftAnchorDate = anchor;
    if (text.length > 0) { this.changePrompt(text, true); }
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
      const messages: HistoryMessage[] = history.map((item: HistoryMessage): HistoryMessage =>
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
    if (this.recoverableDraft === null && this.inputLength(this.prompt) === 0 && this.inputLength(value) <= 8000) {
      this.changePrompt(value);
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
    this.changePrompt(combined);
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
    this.sessionRequestRevision++; this.sessionLoading = false;
    this.conversationRevision++; this.contextReadRevision++; this.contextRevision = ''; this.decisionId = ''; this.cancelVoice();
    // A controller must not reuse the previous connection or credential on a later retry.
    this.runInteraction?.dispose(); this.runInteraction = null;
    this.loading = false; this.onChatBusyChange(false);
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
    // Offset updates can arrive after a manual upward gesture. Reaching the
    // bottom (or explicitly sending/viewing latest) is what resumes following.
    if (this.contentHeight > this.viewportHeight && this.contentHeight - this.viewportHeight - offset > 48) {
      this.followLatest = false;
    }
    if (this.followLatest) { this.unreadMessages = 0; }
    else { this.scrollForNewMessage = false; }
  }

  private chatViewportChanged(height: number): void {
    if (!Number.isFinite(height) || height <= 0 || height === this.viewportHeight) { return; }
    this.viewportHeight = height;
    // Keyboard and composer resizing can shrink the viewport without changing
    // message height. Follow only readers who were already at the latest reply.
    if (!this.voiceActive || !this.followLatest || !this.hasConversation() ||
      this.restoreOptionsOffset >= 0 || this.pendingJumpId.length > 0 || this.optionsExpanded) { return; }
    this.unreadMessages = 0;
    this.chatScroller.scrollEdge(Edge.Bottom);
  }

  private chatContentChanged(height: number): void {
    const heightChanged = height !== this.contentHeight;
    this.contentHeight = height;
    if (this.restoreOptionsOffset >= 0) {
      this.chatScroller.scrollTo({ xOffset: 0, yOffset: this.restoreOptionsOffset, animation: false });
      this.restoreOptionsOffset = -1;
      return;
    }
    if (heightChanged && this.voiceActive && this.followLatest && this.scrollForNewMessage && this.hasConversation()) {
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
      this.sessionRequestRevision++; this.sessionLoading = false;
      this.flushDraft();
      this.scrollForNewMessage = false;
      this.voiceInteraction?.suspend();
      this.voiceProbeRevision++;
      this.voiceProbeBusy = false;
      this.modelsRevision++; this.modelsLoading = false;
    } else { this.bindDraftLease(); this.loadModels(); this.sessionRequested(); }
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
    if (!this.voiceExplanationAccepted) { this.explainedSpeechId = ''; this.voiceExplanationOpen = true; return; }
    const conversation = this.conversationRevision;
    this.voiceNotice = '';
    this.followLatest = true;
    this.scrollForNewMessage = true;
    if (await this.probeVoice() && conversation === this.conversationRevision && !this.loading && !this.deletionBusy && this.decisionId.length === 0 && !this.capturePending()) {
      await this.voiceController().startListening();
    }
  }

  private async acceptVoiceExplanation(): Promise<void> {
    if (!this.pageActive || !this.voiceActive) { return; }
    this.voiceExplanationAccepted = true; this.voiceExplanationOpen = false;
    try { AppStorage.setOrCreate<boolean>('voiceUsageExplained', true); }
    catch { /* The current visit remains explained; no claim of durable settings success. */ }
    const speechId = this.explainedSpeechId; this.explainedSpeechId = '';
    if (speechId.length > 0) {
      const message = this.messages.find((item: ConversationEntry) => item.id === speechId);
      if (message !== undefined) { await this.speakReply(message); }
    } else { await this.startVoice(); }
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
    if (!this.pageActive || !this.voiceActive || this.voiceState.phase !== 'review' || this.voiceInteraction === null) { return; }
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
    this.changePrompt(combined);
    this.voiceNotice = '文字已填入，请检查后手动发送。';
  }

  private async speakReply(message: ConversationEntry): Promise<void> {
    if (!this.pageActive || !this.voiceActive || message.incomplete === true || message.role !== 'assistant' || message.id === 'welcome' ||
      !this.messages.some((item: ConversationEntry) => item.id === message.id && item.role === 'assistant')) { return; }
    if (!this.voiceExplanationAccepted) { this.explainedSpeechId = message.id; this.voiceExplanationOpen = true; return; }
    const conversation = this.conversationRevision;
    if (this.speechPending() && this.voiceState.speakingMessageId === message.id) {
      this.cancelVoice();
      return;
    }
    if (this.loading || this.deletionBusy || this.decisionId.length > 0 || this.capturePending() || this.voiceProbeBusy) { return; }
    this.voiceNotice = '';
    if (await this.probeVoice() && conversation === this.conversationRevision && !this.loading && !this.deletionBusy && this.decisionId.length === 0 && !this.capturePending()) {
      await this.voiceController().speak(message.id, message.content);
    }
  }

  private async send(): Promise<void> {
    const text = this.prompt.trim();
    if (!this.pageActive || !this.voiceActive || text.length === 0 || this.inputLength(text) > 8000 || this.loading || this.deletionBusy ||
      this.decisionId.length > 0 || this.capturePending() || this.sessionLoading || this.switchConfirmOpen) {
      return;
    }
    if (this.selectedModelBlocked()) { this.optionsExpanded = true; this.modelsMessage = '当前模型不可用，请选择已就绪并支持工具与增量回答的模型。'; return; }
    if (this.adjustingProposalId.length > 0) { this.sessionNotice = '请先核对原候选的取消结果，再发送调整描述。'; return; }
    this.cancelVoice();
    this.optionsExpanded = false;
    this.followLatest = true;
    if (this.draftBlocksSend() || !this.stagePrompt()) { this.draftNotice = '请先恢复本机保存，或核对上次运行；输入尚未发送。'; return; }
    if (this.userId.length > 0 && this.sessionMode === 'continue' && this.contextRevision.length === 0) {
      this.sessionNotice = '请先刷新当前会话上下文，再明确发送。'; await this.refreshSessionContext(); return;
    }
    if (this.sessionTitle.length === 0) { this.sessionTitle = text; }
    if (this.userId.length > 0) {
      await this.runController().start(this.sessionId, this.model, text, this.sessionMode, this.sessionMode === 'continue' ? this.contextRevision : null);
    } else { await this.runController().start(this.sessionId, this.model, text); }
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
      this.runInteraction.setBeforeSubmit((request: RunStartRequest): Promise<void> => this.prepareRunDraft(request));
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
    this.settleRunDraft(state);
    if (state.errorCode === 'RUN_DELETED') {
      state.recent = state.recent.filter((run: RunSnapshot) => run.run_id !== state.runId);
      const sessionId = state.snapshot?.session_id ?? state.request?.session_id ?? '';
      this.removeDeletedRunSession(sessionId);
      if (sessionId === this.sessionId) {
        this.conversationRevision++;
        this.sessionId = `arkuix-${this.newRunId()}`;
        this.savedMessages = []; this.resetDeletedSessionDraft();
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
      if (!this.restoredRunIds.includes(state.runId) && this.prompt.length === 0) { this.changePrompt(restoreDraft(this.prompt, original), true); }
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
    const restoring = this.restoredRunIds.includes(run.run_id);
    const actions = restoring ? [] : run.result.pending_actions.filter((action: PendingAction) => validActionPreview(action));
    this.pendingActions = mergeActions(this.pendingActions, actions);
    this.linkProposals(messageId, actions);
    if (!restoring && actions.length !== run.result.pending_actions.length) {
      this.appendMessage('feedback', '部分提案内容不完整，未开放执行。请根据最新安排重新生成预览。');
    }
    this.actionsRevision++;
    if (restoring && run.result.pending_actions.length > 0) {
      if (this.liveRecoveredRunIds.includes(run.run_id)) { this.readRecoveredProposals(run, messageId); }
      else { this.appendMessage('feedback', '已读取历史运行正文。旧候选快照仅供记录，不恢复为可执行提案；需要变更时请重新生成预览。'); }
    }
    this.saveRunHistory(run);
    if (run.session_id === this.sessionId && this.userId.length > 0) {
      this.sessionMode = 'continue'; this.contextRevision = ''; this.refreshSessionContext();
    }
  }

  private async readRecoveredProposals(run: RunSnapshot, messageId: string): Promise<void> {
    const revision = this.conversationRevision;
    const api = new CampusFlowApi(this.baseUrl, this.token);
    if (run.result === null) { return; }
    for (const preview of run.result.pending_actions) {
      try {
        const current = await api.actionStatus(preview.proposal_id);
        if (!this.pageActive || revision !== this.conversationRevision) { return; }
        if (!sameActionCandidate(preview, current) || !validReliableAction(current) || decisionDisposition(current) === 'invalid') {
          throw localRequestFailure('INVALID_RESPONSE');
        }
        this.pendingActions = mergeActions(this.pendingActions, [current]); this.linkProposals(messageId, [current]); this.actionsRevision++;
      } catch {
        if (this.pageActive && revision === this.conversationRevision) {
          this.appendMessage('feedback', `「${preview.title}」的最新提案状态尚未核实，未开放执行。可重新核对本次运行，或读取最新安排后重新生成。`);
        }
      }
    }
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
    const selected = this.runState.recent.find((item: RunSnapshot) => item.run_id === runId);
    if (this.userId.length > 0 && selected === undefined) { this.sessionNotice = '请先刷新最近运行，再选择原记录。'; return; }
    if (this.userId.length > 0 && selected !== undefined && selected.session_id !== this.sessionId) {
      this.requestRunConversation(selected.session_id, runId); return;
    }
    if (selected !== undefined && ['queued', 'running'].includes(selected.status)) { this.liveRecoveredRunIds = this.liveRecoveredRunIds.concat([runId]); }
    this.cancelVoice();
    this.restoredRunIds = this.restoredRunIds.includes(runId) ? this.restoredRunIds : this.restoredRunIds.concat([runId]);
    await this.runController().recover(runId);
  }

  private async refreshRun(): Promise<void> {
    if (!this.pageActive || this.deletionBusy) { return; }
    await this.runController().refresh();
    const run = this.runState.snapshot;
    if (this.pageActive && run !== null && run.status === 'succeeded') {
      await this.saveRunHistory(run);
      if (this.liveRecoveredRunIds.includes(run.run_id)) { await this.readRecoveredProposals(run, `run-${run.run_id}-assistant`); }
    }
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
    return this.decisionFeedback.some((item: DecisionFeedback) => item.proposalId !== proposalId && item.needsReview) ||
      this.decisionOperations.some((item: DraftOperation) => item.id !== proposalId);
  }

  private sourcesForProposal(action: PendingAction): DataEvidence[] {
    const origin = this.proposalOrigins.find((item: ProposalOrigin) => item.proposalId === action.proposal_id);
    const message = this.messages.find((item: ConversationEntry) => item.id === origin?.messageId);
    return proposalSources(message?.tools ?? []);
  }

  private acksFor(action: PendingAction): CourseAcknowledgement[] {
    return this.courseAckProposalId === action.proposal_id ? this.selectedCourseAcks : [];
  }

  private toggleCourseAck(action: PendingAction, review: CourseReview): void {
    if (this.decisionId.length > 0 || action.status !== 'pending' || this.needsReview(action.proposal_id)) { return; }
    const current = this.acksFor(action);
    const selected = current.some((item: CourseAcknowledgement) => item.candidate_id === review.candidate_id && item.review_digest === review.review_digest);
    this.courseAckProposalId = action.proposal_id;
    this.selectedCourseAcks = current.filter((item: CourseAcknowledgement) => item.candidate_id !== review.candidate_id);
    if (!selected) { this.selectedCourseAcks = this.selectedCourseAcks.concat([{ candidate_id: review.candidate_id, review_digest: review.review_digest }]); }
  }

  private permissionValue(task: PlanningTaskDraft): boolean {
    return this.permissionChoices.find((item: CoursePermissionChoice) => item.candidate_id === task.candidate_id)?.allow_during_course ?? (task.allow_during_course ?? false);
  }

  private togglePermissionEditor(action: PendingAction): void {
    if (this.decisionId.length > 0 || this.needsReview(action.proposal_id)) { return; }
    if (this.permissionProposalId === action.proposal_id) { this.permissionProposalId = ''; return; }
    this.permissionProposalId = action.proposal_id;
    this.permissionChoices = courseCandidates(action).map((task: PlanningTaskDraft): CoursePermissionChoice =>
      ({ candidate_id: task.candidate_id ?? '', allow_during_course: task.allow_during_course ?? false }));
  }

  private togglePermission(task: PlanningTaskDraft): void {
    if (this.decisionId.length > 0) { return; }
    const value = !this.permissionValue(task);
    this.permissionChoices = this.permissionChoices.filter((item: CoursePermissionChoice) => item.candidate_id !== task.candidate_id)
      .concat([{ candidate_id: task.candidate_id ?? '', allow_during_course: value }]);
  }

  private async prepareDecision(action: PendingAction, confirm: boolean, permissions: CoursePermissionChoice[] | null = null): Promise<void> {
    const lease = this.draftLease;
    if (lease === null || !localDrafts.valid(lease)) { throw localRequestFailure('LOCAL_DRAFT_SAVE_FAILED'); }
    const kind = permissions === null ? 'proposal' : 'course-permission';
    const existing = localDrafts.operations(lease).find((item: DraftOperation) => item.kind === kind && item.id === action.proposal_id);
    if (existing !== undefined) {
      if (permissions === null && existing.proposalRequest !== null &&
        JSON.stringify(existing.proposalRequest.course_acknowledgements) !== JSON.stringify(confirm ? this.acksFor(action) : [])) {
        throw localRequestFailure('INVALID_RESPONSE');
      }
      await localDrafts.flush(lease); return;
    }
    const owner = `${permissions === null ? 'agent-proposal' : 'agent-permission'}:${action.proposal_id}`;
    const ticket = localDrafts.stage(lease, { kind: 'new-task', ownerId: owner },
      { title: '', date: '', dateChoice: 'none', time: '', anchorDate: shanghaiDate(Date.now()), timezone: 'Asia/Shanghai' });
    if (permissions === null) {
      await localDrafts.beginOperation(lease, { kind: 'proposal', id: action.proposal_id, draftKind: 'new-task', ownerId: owner,
        localRevision: ticket.localRevision, sessionId: this.sessionId,
        proposalRequest: { proposal_id: action.proposal_id, intent: confirm ? 'confirm' : 'cancel', course_acknowledgements: confirm ? this.acksFor(action) : [] } });
    } else {
      await localDrafts.beginOperation(lease, { kind: 'course-permission', id: action.proposal_id, draftKind: 'new-task', ownerId: owner,
        localRevision: ticket.localRevision, sessionId: this.sessionId, permissionRequest: { proposal_id: action.proposal_id, choices: permissions } });
    }
  }

  private async settleDecision(id: string, permission: boolean = false): Promise<boolean> {
    const lease = this.draftLease;
    if (lease === null || !localDrafts.valid(lease)) { return false; }
    try { await localDrafts.resolveOperation(lease, permission ? 'course-permission' : 'proposal', id, true); return true; }
    catch { this.setFeedback(id, '服务端结果已查回，本机恢复标识尚未结清。请再次查询原编号。', true); return false; }
  }

  private showRecoveredAction(action: PendingAction): void {
    if (this.pendingActions.some((item: PendingAction) => item.proposal_id === action.proposal_id)) { this.replaceAction(action); return; }
    this.pendingActions = this.pendingActions.concat([action]);
    const id = this.appendMessage('assistant', '已从服务器查回原提案。请重新核对完整内容，尚未发起新的执行。');
    this.linkProposals(id, [action]); this.actionsRevision++;
  }

  private async recoverDecisionOperation(operation: DraftOperation): Promise<void> {
    if (this.decisionId.length > 0 || !this.pageActive || !this.voiceActive || operation.sessionId !== this.sessionId) { return; }
    const revision = this.conversationRevision; this.decisionId = operation.id;
    try {
      const api = new CampusFlowApi(this.baseUrl, this.token);
      const original = await api.actionStatus(operation.id);
      if (!this.pageActive || revision !== this.conversationRevision) { return; }
      if (!validReliableAction(original) || original.proposal_id !== operation.id || decisionDisposition(original) === 'invalid') {
        throw localRequestFailure('INVALID_RESPONSE');
      }
      const existing = this.pendingActions.find((item: PendingAction) => item.proposal_id === operation.id);
      if (existing !== undefined && !sameActionCandidate(existing, original)) { throw localRequestFailure('INVALID_RESPONSE'); }
      this.showRecoveredAction(original);
      if (operation.kind === 'course-permission' && operation.permissionRequest !== null) {
        if (original.status === 'cancelled' && (original.replacement_proposal_id ?? '').length > 0) {
          const replacement = await api.actionStatus(original.replacement_proposal_id ?? '');
          if (!this.pageActive || revision !== this.conversationRevision) { return; }
          if (replacement.proposal_id !== original.replacement_proposal_id || !samePermissionReplacement(original, replacement, operation.permissionRequest.choices)) { throw localRequestFailure('INVALID_RESPONSE'); }
          this.showRecoveredAction(replacement);
          if (await this.settleDecision(operation.id, true)) {
            this.setFeedback(original.proposal_id, '已核对替代候选，原提案不再执行。新候选仍需完整确认。', false);
          }
        } else if (['confirmed', 'cancelled'].includes(decisionDisposition(original))) {
          this.acceptResolvedAction(original);
          await this.settleDecision(operation.id, true);
        } else if (original.status === 'pending') {
          this.permissionProposalId = original.proposal_id; this.permissionChoices = operation.permissionRequest.choices;
          this.setFeedback(original.proposal_id, '原提案仍待处理。可明确重试同一份许可设置；不会执行任务。', false, 'COURSE_PERMISSION_RETRY');
        } else { throw localRequestFailure('INVALID_RESPONSE'); }
      } else if (['confirmed', 'cancelled'].includes(decisionDisposition(original))) {
        this.acceptResolvedAction(original);
        if (await this.settleDecision(original.proposal_id)) { this.completeAdjustment(original); }
      } else {
        if (operation.proposalRequest !== null) {
          this.courseAckProposalId = original.proposal_id; this.selectedCourseAcks = operation.proposalRequest.course_acknowledgements;
        }
        this.setFeedback(original.proposal_id, '原提案仍待处理，请重新核对。明确确认或取消仍沿用同一编号。', false, 'ACTION_RETRY');
      }
    } catch (error) {
      if (this.pageActive && revision === this.conversationRevision) { this.setFeedback(operation.id, `${this.safeFailure(error).message} 原操作尚未核对，不重新生成。`, true); }
    } finally { if (revision === this.conversationRevision) { this.decisionId = ''; } }
  }

  private async previewCoursePermissions(action: PendingAction): Promise<void> {
    const current = this.pendingActions.find((item: PendingAction) => item.proposal_id === action.proposal_id);
    if (!this.pageActive || !this.voiceActive || this.decisionId.length > 0 || this.loading || current === undefined ||
      current.status !== 'pending' || !sameActionCandidate(current, action) || this.needsReview(action.proposal_id)) { return; }
    const choices = JSON.parse(JSON.stringify(this.permissionChoices)) as CoursePermissionChoice[];
    const operation = this.decisionOperations.find((item: DraftOperation) => item.kind === 'course-permission' && item.id === action.proposal_id);
    if (operation !== undefined && this.feedbackFor(action.proposal_id)?.code !== 'COURSE_PERMISSION_RETRY') {
      this.setFeedback(action.proposal_id, '先查询原许可设置，再明确重试同一份选择。', true); return;
    }
    if (operation?.permissionRequest !== null && operation?.permissionRequest !== undefined &&
      JSON.stringify(operation.permissionRequest.choices) !== JSON.stringify(choices)) {
      this.setFeedback(action.proposal_id, '先核对原许可设置，未知结果不能换一组选择重试。', true); return;
    }
    const revision = this.conversationRevision; this.decisionId = action.proposal_id;
    try {
      await this.prepareDecision(current, false, choices);
      if (!this.pageActive || !this.voiceActive || revision !== this.conversationRevision) { return; }
      const replacement = await new CampusFlowApi(this.baseUrl, this.token).coursePermissions(action.proposal_id, choices);
      if (!this.pageActive || revision !== this.conversationRevision) { return; }
      if (!samePermissionReplacement(current, replacement, choices)) { throw localRequestFailure('INVALID_RESPONSE'); }
      const cancelled = JSON.parse(JSON.stringify(current)) as PendingAction;
      cancelled.status = 'cancelled'; cancelled.replacement_proposal_id = replacement.proposal_id;
      this.replaceAction(cancelled);
      this.showRecoveredAction(replacement); this.permissionProposalId = ''; this.selectedCourseAcks = [];
      if (await this.settleDecision(action.proposal_id, true)) {
        this.setFeedback(action.proposal_id, '许可设置已生成新的预览；原提案不再执行。请确认新候选。', false);
      }
    } catch (error) {
      if (this.pageActive && revision === this.conversationRevision) {
        const failure = this.safeFailure(error);
        const rejected = ['LOGIN_REQUIRED', 'ACTION_EXPIRED', 'ACTION_STALE', 'ACTION_LEGACY_UNVERIFIED', 'ACTION_INVALID', 'ACTION_NOT_FOUND', 'COURSE_ACK_INVALID'].includes(failure.code);
        this.setFeedback(action.proposal_id, rejected ? failure.message : `${failure.message} 请查询原提案，核对是否已有替代候选。`, !rejected, failure.code);
        if (rejected) {
          this.invalidatedProposalIds = this.invalidatedProposalIds.concat([action.proposal_id]);
          await this.settleDecision(action.proposal_id, true);
        }
      }
    } finally { if (revision === this.conversationRevision) { this.decisionId = ''; } }
  }

  private beginAdjustment(action: PendingAction): void {
    if (this.decisionId.length > 0 || this.needsReview(action.proposal_id)) { return; }
    this.adjustingProposalId = action.proposal_id;
    this.adjustmentReady = false;
    this.adjustmentText = `请读取最新课表和任务，重新安排「${action.title}」。\n原时间：${proposalOverview(action).timeRange}。\n希望日期：\n希望时长：\n其他偏好：\n请先提出新的候选，等待我确认；不要执行旧候选。`;
    this.saveAdjustment();
  }

  private completeAdjustment(action: PendingAction): void {
    if (action.proposal_id !== this.adjustingProposalId || action.status !== 'cancelled' || this.needsReview(action.proposal_id)) { return; }
    this.adjustmentReady = true;
    this.sessionNotice = '原候选已取消。可将调整描述填入输入，编辑后由你发送，再生成新候选。';
  }

  private saveAdjustment(): boolean {
    const lease = this.draftLease;
    if (lease === null || !localDrafts.valid(lease) || this.adjustingProposalId.length === 0) { return false; }
    try {
      localDrafts.stage(lease, { kind: 'assistant', ownerId: `agent-adjustment:${this.adjustingProposalId}` },
        { text: this.adjustmentText, sessionId: this.sessionId, anchorDate: shanghaiDate(Date.now()), timezone: 'Asia/Shanghai' });
      return true;
    } catch { this.sessionNotice = '调整描述暂未保存，请保留当前页面并恢复本机保存。'; return false; }
  }

  private changeAdjustment(value: string): void { this.adjustmentText = value; this.saveAdjustment(); }

  private async queryAdjustment(): Promise<void> {
    if (this.adjustingProposalId.length === 0 || this.decisionId.length > 0 || !this.voiceActive) { return; }
    const id = this.adjustingProposalId; const revision = this.conversationRevision;
    const operation = this.decisionOperations.find((item: DraftOperation) => item.kind === 'proposal' && item.id === id);
    if (operation !== undefined) { await this.recoverDecisionOperation(operation); return; }
    this.decisionId = id;
    try {
      const action = await new CampusFlowApi(this.baseUrl, this.token).actionStatus(id);
      if (!this.pageActive || revision !== this.conversationRevision) { return; }
      if (!validReliableAction(action) || action.proposal_id !== id) { throw localRequestFailure('INVALID_RESPONSE'); }
      this.showRecoveredAction(action); this.completeAdjustment(action);
      if (action.status === 'confirmed') { this.sessionNotice = '原候选已经执行，不能当作已取消。请查看实际任务后重新描述修改。'; }
    } catch (error) { if (this.pageActive && revision === this.conversationRevision) { this.sessionNotice = this.safeFailure(error).message; } }
    finally { if (revision === this.conversationRevision) { this.decisionId = ''; } }
  }

  private async adoptAdjustment(append: boolean): Promise<void> {
    const lease = this.draftLease; const revision = this.draftBindingRevision; const id = this.adjustingProposalId;
    if (!this.adjustmentReady || id.length === 0 || lease === null || !localDrafts.valid(lease) || this.recoverableDraft !== null ||
      (!append && this.prompt.length > 0) || this.needsReview(id)) { return; }
    const alreadyFilled = this.prompt === this.adjustmentText || this.prompt.endsWith(`\n${this.adjustmentText}`);
    const text = alreadyFilled ? this.prompt : append && this.prompt.length > 0 ? `${this.prompt}\n${this.adjustmentText}` : this.adjustmentText;
    if (this.inputLength(text) > 8000) { this.sessionNotice = '合并后超过 8000 字，两份草稿均保留，请先精简。'; return; }
    const key: DraftKey = { kind: 'assistant', ownerId: `agent-adjustment:${id}` };
    const saved = localDrafts.read(lease, key);
    this.changePrompt(text);
    try {
      await localDrafts.flush(lease);
      if (!this.draftCurrent(lease, revision)) { return; }
      if (saved !== undefined) { await localDrafts.remove(lease, key, saved.localRevision); }
      if (!this.draftCurrent(lease, revision)) { return; }
      this.adjustingProposalId = ''; this.adjustmentText = ''; this.adjustmentReady = false;
      this.sessionNotice = '调整描述已填入并保存；发送后会生成新的候选，仍需确认。';
    } catch { if (this.draftCurrent(lease, revision)) { this.sessionNotice = '调整描述尚未完整保存，原调整草稿仍保留。'; } }
  }

  private async dismissAdjustment(): Promise<void> {
    const lease = this.draftLease; const revision = this.draftBindingRevision;
    if (lease === null || !localDrafts.valid(lease) || this.decisionId.length > 0 || this.needsReview(this.adjustingProposalId) ||
      this.decisionOperations.some((item: DraftOperation) => item.id === this.adjustingProposalId)) { return; }
    const key: DraftKey = { kind: 'assistant', ownerId: `agent-adjustment:${this.adjustingProposalId}` };
    const saved = localDrafts.read(lease, key);
    try {
      if (saved !== undefined && !await localDrafts.remove(lease, key, saved.localRevision)) { return; }
      if (this.draftCurrent(lease, revision)) { this.adjustingProposalId = ''; this.adjustmentText = ''; this.adjustmentReady = false; }
    } catch { this.sessionNotice = '尚未放弃调整描述，请重试。'; }
  }

  private requestRunConversation(sessionId: string, runId: string): void {
    if (!this.pageActive || !this.voiceActive || this.sessionLoading) { return; }
    this.switchTarget = sessionId; this.switchRunId = runId; this.switchDraftId = ''; this.switchConfirmOpen = true;
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

  private async statusBlocksAction(action: PendingAction): Promise<boolean> {
    if (this.statusLockedTaskIds.length === 0 || action.action === 'create') { return false; }
    let locked = this.statusLockedTaskIds.find((id: string) => id === action.target_task_id);
    const planId = action.target_plan_id;
    if (locked === undefined && action.kind === 'plan' && typeof planId === 'string' && planId.length > 0) {
      const revision = this.conversationRevision; const base = this.baseUrl; const token = this.token;
      try {
        const overview = await new CampusFlowApi(base, token).planning();
        if (!this.pageActive || !this.voiceActive || this.conversationRevision !== revision || this.baseUrl !== base || this.token !== token) { return true; }
        locked = this.statusLockedTaskIds.find((id: string) => overview.tasks.some((task: PlanningTask) => task.task_id === id && task.plan_id === planId));
      } catch {
        if (!this.pageActive || !this.voiceActive || this.conversationRevision !== revision || this.baseUrl !== base || this.token !== token) { return true; }
        this.setFeedback(action.proposal_id, '暂未核实该计划与待核对任务的关系，本次未提交；请重试核对。', false); return true;
      }
    }
    if (locked === undefined) { return false; }
    this.setFeedback(action.proposal_id, '相关任务的完成或恢复结果尚待核对，请先处理原操作。其他任务与聊天仍可使用。', false);
    this.onOpenStatus(locked); return true;
  }

  private async decide(action: PendingAction, confirm: boolean): Promise<void> {
    // Guard the handler as well as the buttons against rapid taps and stale callbacks.
    const current = this.pendingActions.find((item: PendingAction) => item.proposal_id === action.proposal_id);
    if (!this.pageActive || !this.voiceActive || this.deletionBusy || this.loading || this.decisionId.length > 0 || current === undefined || current.status !== 'pending' ||
      this.needsReview(action.proposal_id)) {
      return;
    }
    if (confirm && !validCourseAcknowledgements(current, this.acksFor(current))) {
      this.setFeedback(current.proposal_id, '请逐项核对课程重叠并选择仍这样安排，再确认整份候选。', false); return;
    }
    const savedOperation = this.decisionOperations.find((item: DraftOperation) => item.id === current.proposal_id);
    if (savedOperation !== undefined && this.feedbackFor(current.proposal_id)?.code !== 'ACTION_RETRY') {
      this.setFeedback(current.proposal_id, '原操作尚未核对，请先查询同一编号。', true); return;
    }
    if (savedOperation !== undefined && (savedOperation.kind === 'course-permission' ||
      savedOperation.proposalRequest !== null && savedOperation.proposalRequest.intent !== (confirm ? 'confirm' : 'cancel') &&
      !(confirm === false && savedOperation.proposalRequest.intent === 'confirm' && this.feedbackFor(current.proposal_id)?.code === 'ACTION_RETRY'))) {
      this.setFeedback(current.proposal_id, '原操作仍有待核对的恢复标识，请先查询同一编号，不切换提交类型。', true); return;
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
    if (!confirm && action.proposal_id === this.adjustingProposalId && !this.saveAdjustment()) { return; }
    this.decisionId = action.proposal_id;
    const revision = this.conversationRevision;
    let submitted = false;
    const statusLocks = JSON.stringify(this.statusLockedTaskIds);
    try {
      if (confirm && await this.statusBlocksAction(current)) { return; }
      if (!confirm && savedOperation?.proposalRequest?.intent === 'confirm' && this.draftLease !== null) {
        await localDrafts.replaceProposalIntent(this.draftLease, current.proposal_id, this.sessionId, savedOperation.proposalRequest);
        if (!this.pageActive || !this.voiceActive || revision !== this.conversationRevision) { return; }
      }
      await this.prepareDecision(current, confirm);
      if (!this.pageActive || !this.voiceActive || revision !== this.conversationRevision) { return; }
      if (confirm && statusLocks !== JSON.stringify(this.statusLockedTaskIds) && await this.statusBlocksAction(current)) { return; }
      const api = new CampusFlowApi(this.baseUrl, this.token);
      submitted = true;
      const result = confirm ? await api.confirmAction(action.proposal_id, this.acksFor(current)) : await api.cancelAction(action.proposal_id);
      if (!this.pageActive || revision !== this.conversationRevision ||
        !this.pendingActions.some((item: PendingAction) => item.proposal_id === action.proposal_id)) { return; }
      const expectedStatus = confirm ? 'confirmed' : 'cancelled';
      if (result !== null && sameActionCandidate(current, result.action) &&
        decisionDisposition(result.action) === expectedStatus && result.applied === confirm &&
        sameActionReceipt(result.action.receipt, result.receipt)) {
        this.acceptResolvedAction(result.action);
        if (await this.settleDecision(action.proposal_id)) { this.completeAdjustment(result.action); }
      } else {
        this.setFeedback(action.proposal_id, '服务返回的状态与本次操作不一致。请核对状态和计划列表，暂不重复提交。', true);
      }
    } catch (error) {
      if (!this.pageActive || revision !== this.conversationRevision ||
        !this.pendingActions.some((item: PendingAction) => item.proposal_id === action.proposal_id)) { return; }
      const failure = this.safeFailure(error);
      if (!submitted) { this.setFeedback(action.proposal_id, '本机恢复标识尚未保存，本次未提交。请重试保存后再核对。', true, 'LOCAL_DRAFT_SAVE_FAILED'); return; }
      const rejectedBeforeWrite = ['LOGIN_REQUIRED', 'ACTION_UNSUPPORTED', 'ACTION_EXPIRED', 'ACTION_LEGACY_UNVERIFIED',
        'ACTION_STALE', 'ACTION_CONFLICT', 'ACTION_INVALID', 'ACTION_NOT_FOUND', 'COURSE_PERMISSION_PREVIEW_REQUIRED', 'COURSE_ACK_STALE', 'COURSE_ACK_INVALID'].includes(failure.code);
      if (['ACTION_EXPIRED', 'ACTION_LEGACY_UNVERIFIED', 'ACTION_STALE', 'ACTION_CONFLICT', 'ACTION_INVALID', 'ACTION_NOT_FOUND', 'COURSE_PERMISSION_PREVIEW_REQUIRED', 'COURSE_ACK_STALE', 'COURSE_ACK_INVALID']
        .includes(failure.code) && !this.invalidatedProposalIds.includes(action.proposal_id)) {
        this.invalidatedProposalIds = this.invalidatedProposalIds.concat([action.proposal_id]);
      }
      this.setFeedback(action.proposal_id,
        rejectedBeforeWrite ? failure.message : `${failure.message} 请核对状态和计划列表，暂不重复提交。`,
        !rejectedBeforeWrite, failure.code);
      if (rejectedBeforeWrite) { await this.settleDecision(action.proposal_id); }
    } finally {
      if (revision === this.conversationRevision) { this.decisionId = ''; }
    }
  }

  private async checkDecision(action: PendingAction): Promise<void> {
    const operation = this.decisionOperations.find((item: DraftOperation) => item.id === action.proposal_id);
    if (operation !== undefined) { await this.recoverDecisionOperation(operation); return; }
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
      return this.palette.danger;
    }
    if (state === 'unavailable' || state === 'unverified' || state === 'demo') {
      return this.palette.warning;
    }
    return this.palette.secondary;
  }

  private toggleToolResults(messageId: string): void {
    this.scrollForNewMessage = false;
    this.collapsedToolIds = this.collapsedToolIds.includes(messageId) ?
      this.collapsedToolIds.filter((id: string) => id !== messageId) : this.collapsedToolIds.concat([messageId]);
  }

  private hasConversation(): boolean {
    return this.messages.some((message: ConversationEntry) => message.id !== 'welcome');
  }

  private requestDraftConversation(record: DraftRecord): void {
    if (!this.pageActive || !this.voiceActive || this.sessionLoading || this.draftLease === null || !localDrafts.valid(this.draftLease)) { return; }
    const current = localDrafts.read(this.draftLease, { kind: record.kind, ownerId: record.ownerId });
    if (current === undefined || current.localRevision !== record.localRevision) { return; }
    const value = current.payload as AssistantDraft;
    this.switchTarget = value.sessionId; this.switchDraftId = value.sessionId; this.switchRunId = ''; this.switchConfirmOpen = true;
  }

  @Builder
  private ConversationSwitch() {
    Column({ space: 12 }) {
      Text(this.switchTarget.length === 0 ? '开始新的对话？' : '继续另一段对话？')
        .fontSize(this.palette.sectionTitle).fontWeight(FontWeight.Medium).fontColor(this.palette.ink).width('100%')
      Text('当前输入先保存到本机会话草稿。服务端运行不会自动取消；返回后按原编号核对。未执行候选不会从历史文字恢复。')
        .fontSize(this.palette.bodySize).fontColor(this.palette.secondary).width('100%')
      if (this.capturePending()) {
        Text('语音仍有待处理文字，请先填入输入或明确放弃。').fontSize(this.palette.bodySize).fontColor(this.palette.warning).width('100%')
        Button('放弃本次语音').constraintSize({ minHeight: 48 }).fontColor(this.palette.danger).backgroundColor(this.palette.dangerSoft)
          .onClick(() => this.cancelVoice())
      }
      Row({ space: 8 }) {
        Button('留在当前对话').layoutWeight(1).constraintSize({ minHeight: 48 }).fontColor(this.palette.secondary)
          .backgroundColor(this.palette.field).onClick(() => this.switchConfirmOpen = false)
        Button(this.sessionLoading ? '正在核对…' : '保存并切换').layoutWeight(1).constraintSize({ minHeight: 48 })
          .fontColor(this.palette.onAccent).backgroundColor(this.palette.accent)
          .enabled(!this.sessionLoading && !this.capturePending() && this.decisionId.length === 0 && this.decisionOperations.length === 0)
          .onClick(() => this.switchConversation())
      }.width('100%')
    }.width('100%').padding(16).backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius).alignItems(HorizontalAlign.Start)
  }

  @Builder
  private VoiceExplanation() {
    Column({ space: 12 }) {
      Text('关于语音').fontSize(this.palette.sectionTitle).fontWeight(FontWeight.Medium).fontColor(this.palette.ink).width('100%')
      Text('语音识别与播报由设备系统服务处理，部分系统可能联网。行简不保存录音；识别文字先供你编辑，再由你手动发送给所选模型。')
        .fontSize(this.palette.bodySize).fontColor(this.palette.secondary).width('100%')
      Text('继续后才检测系统能力并按需申请权限。拒绝权限仍可输入文字；切换会话会停止语音。')
        .fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
      Row({ space: 8 }) {
        Button('稍后再说').layoutWeight(1).constraintSize({ minHeight: 48 }).backgroundColor(this.palette.field).fontColor(this.palette.secondary)
          .onClick(() => { this.voiceExplanationOpen = false; this.explainedSpeechId = ''; })
        Button(this.explainedSpeechId.length > 0 ? '继续播报' : '继续语音输入').layoutWeight(1).constraintSize({ minHeight: 48 })
          .backgroundColor(this.palette.accent).fontColor(this.palette.onAccent).onClick(() => this.acceptVoiceExplanation())
      }.width('100%')
    }.width('100%').padding(16).backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius).alignItems(HorizontalAlign.Start)
  }

  @Builder
  private DecisionRecovery() {
    if (this.decisionOperations.length > 0) {
      Column({ space: 10 }) {
        Text('有操作结果待核对').fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium).fontColor(this.palette.warning).width('100%')
        Text('先查询持久记录；不会自动重复确认、取消或修改许可。核对前不能切换会话。')
          .fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
        ForEach(this.decisionOperations, (operation: DraftOperation) => {
          Button(operation.kind === 'course-permission' ? '核对原课内许可设置' : '核对原提案操作')
            .width('100%').constraintSize({ minHeight: 48 }).fontColor(this.palette.accent).backgroundColor(this.palette.surface)
            .enabled(this.decisionId.length === 0 && !this.loading).onClick(() => this.recoverDecisionOperation(operation))
        }, (operation: DraftOperation) => `${operation.kind}-${operation.id}`)
      }.width('100%').padding(16).backgroundColor(this.palette.warningSoft).borderRadius(this.palette.cardRadius).alignItems(HorizontalAlign.Start)
    }
    ForEach(this.otherDecisionOperations, (operation: DraftOperation) => {
      Button('返回有待核对操作的原会话').width('100%').constraintSize({ minHeight: 48 })
        .fontColor(this.palette.warning).backgroundColor(this.palette.warningSoft)
        .onClick(() => this.requestConversation(operation.sessionId ?? ''))
    }, (operation: DraftOperation) => `${operation.kind}-${operation.id}`)
    if (this.runRecordsExpanded) {
      ForEach(this.otherDrafts, (record: DraftRecord) => {
        Column({ space: 8 }) {
          Text((record.payload as AssistantDraft).text).fontSize(this.palette.bodySize).fontColor(this.palette.ink).width('100%').maxLines(3)
          Button('返回这份未发送草稿').width('100%').constraintSize({ minHeight: 48 })
            .fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft).onClick(() => this.requestDraftConversation(record))
        }.width('100%').alignItems(HorizontalAlign.Start)
      }, (record: DraftRecord) => `${record.ownerId}-${record.localRevision}`)
    }
  }

  @Builder
  private AdjustmentEditor() {
    Column({ space: 12 }) {
      Text('调整日期、时长或偏好').fontSize(this.palette.sectionTitle).fontWeight(FontWeight.Medium).fontColor(this.palette.ink).width('100%')
      Text(this.adjustmentReady ? '已核对原候选取消。调整描述不会直接执行，仍需发送并确认新的候选。' :
        '编辑以下描述，然后取消原候选。只有取得取消记录后，才开放填入输入；结果未知时先查询原编号。')
        .fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
      TextArea({ text: this.adjustmentText, placeholder: '希望日期、时长与其他偏好' })
        .width('100%').constraintSize({ minHeight: 140, maxHeight: 240 }).fontSize(this.palette.bodySize)
        .backgroundColor(this.palette.field).borderRadius(this.palette.controlRadius)
        .onChange((value: string) => this.changeAdjustment(value))
      if (this.adjustmentReady) {
        Button(this.prompt.length > 0 ? '追加到现有输入' : '填入输入').width('100%').constraintSize({ minHeight: 48 })
          .fontColor(this.palette.onAccent).backgroundColor(this.palette.accent).enabled(this.recoverableDraft === null)
          .onClick(() => this.adoptAdjustment(this.prompt.length > 0))
      } else {
        ForEach(this.pendingActions.filter((action: PendingAction) => action.proposal_id === this.adjustingProposalId && action.status === 'pending'), (action: PendingAction) => {
          Button('取消原候选，再调整').width('100%').constraintSize({ minHeight: 48 }).fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft)
            .enabled(this.decisionId.length === 0 && !this.needsReview(action.proposal_id)).onClick(() => this.decide(action, false))
        }, (action: PendingAction) => action.proposal_id)
        Button('核对原候选是否已取消').width('100%').constraintSize({ minHeight: 48 }).fontColor(this.palette.accent).backgroundColor(Color.Transparent)
          .enabled(this.decisionId.length === 0).onClick(() => this.queryAdjustment())
      }
      Button('放弃这份调整描述').width('100%').constraintSize({ minHeight: 48 }).fontColor(this.palette.secondary).backgroundColor(Color.Transparent)
        .enabled(this.decisionId.length === 0 && !this.needsReview(this.adjustingProposalId) &&
          !this.decisionOperations.some((item: DraftOperation) => item.id === this.adjustingProposalId)).onClick(() => this.dismissAdjustment())
    }.width('100%').padding(16).backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius).alignItems(HorizontalAlign.Start)
  }

  @Builder
  private CoursePermissionEditor(action: PendingAction) {
    Column({ space: 10 }) {
      Text('仅对所选任务允许课内完成。系统仍会显示具体课程和重叠时间，需要再次确认；任务之间的冲突不会被忽略。')
        .fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
      ForEach(courseCandidates(action), (task: PlanningTaskDraft) => {
        Column({ space: 8 }) {
          Text(task.title).fontSize(this.palette.bodySize).fontColor(this.palette.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
          TaskScheduleDetails({ startAt: task.start_at, endAt: task.end_at, location: task.location, reminderMinutes: task.reminder_minutes })
          Button(this.permissionValue(task) ? '已选：可在上课时完成' : '不允许在上课时完成').width('100%').constraintSize({ minHeight: 48 })
            .fontColor(this.permissionValue(task) ? this.palette.onAccent : this.palette.accent)
            .backgroundColor(this.permissionValue(task) ? this.palette.accent : this.palette.accentSoft)
            .enabled(this.decisionId.length === 0 && !this.decisionOperations.some((item: DraftOperation) => item.id === action.proposal_id))
            .onClick(() => this.togglePermission(task))
        }.width('100%').padding(12).backgroundColor(this.palette.field).borderRadius(this.palette.controlRadius).alignItems(HorizontalAlign.Start)
      }, (task: PlanningTaskDraft) => task.candidate_id ?? '')
      Button('按这份设置重新预览').width('100%').constraintSize({ minHeight: 48 }).fontColor(this.palette.accent)
        .backgroundColor(this.palette.accentSoft).enabled(this.decisionId.length === 0 && !this.loading && !this.needsReview(action.proposal_id))
        .onClick(() => this.previewCoursePermissions(action))
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private DraftRecovery() {
    Column({ space: 8 }) {
      if (this.draftPhase !== 'idle' && this.draftPhase !== 'ready' && this.draftPhase !== 'saved') {
      Text(`本机草稿 · ${this.draftMessage}`).fontSize(this.palette.metaSize)
        .fontColor(this.draftPhase === 'error' ? this.palette.danger : this.palette.quiet).width('100%')
      }
      if (this.draftPhase === 'error') {
        Button('重试本机保存').constraintSize({ minHeight: 48 }).fontColor(this.palette.accent)
          .backgroundColor(this.palette.accentSoft).onClick(() => this.flushDraft())
      }
      if (this.recoverableDraft !== null) {
        Text('发现上次未提交的输入').fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium).fontColor(this.palette.ink).width('100%')
        Text((this.recoverableDraft.payload as AssistantDraft).text).fontSize(this.palette.metaSize)
          .fontColor(this.palette.quiet).maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        Text(`原日期 ${(this.recoverableDraft.payload as AssistantDraft).anchorDate} · 上海时区。恢复后请核对相对日期。`)
          .fontSize(this.palette.metaSize).fontColor(this.palette.warning).width('100%')
        Flex({ wrap: FlexWrap.Wrap }) {
          Button('恢复文字').constraintSize({ minHeight: 48 }).fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft)
            .enabled(this.prompt.length === 0).onClick(() => this.restoreStoredDraft())
          Button('舍弃上次草稿').constraintSize({ minHeight: 48 }).fontColor(this.palette.secondary).backgroundColor(this.palette.field)
            .onClick(() => this.discardStoredDraft())
        }.width('100%')
      }
      ForEach(this.draftOperations, (operation: DraftOperation) => {
        Column({ space: 4 }) {
          Text('这次提交仍需核对，未自动重发。').fontSize(this.palette.metaSize).fontColor(this.palette.warning).width('100%')
          Button('核对原运行').constraintSize({ minHeight: 48 }).fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft)
            .enabled(this.voiceActive && !this.deletionBusy && !['creating', 'cancelling', 'checking'].includes(this.runState.phase))
            .onClick(() => this.recoverDraftRun(operation))
        }.width('100%')
      }, (operation: DraftOperation) => operation.id)
      if (this.draftNotice.length > 0) {
        Text(this.draftNotice).fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
      }
      if (this.prompt.length > 0 && this.draftAnchorDate.length > 0 && this.draftAnchorDate !== shanghaiDate(Date.now())) {
        Text(`这份输入起于 ${this.draftAnchorDate}（上海时区），请核对“今天、明天”等表达后再发送。`)
          .fontSize(this.palette.metaSize).fontColor(this.palette.warning).width('100%')
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private ToolResults(message: ConversationEntry) {
    Column({ space: 8 }) {
      if (message.tools.length === 0) {
        Text('本轮未提供工具记录').fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
      } else {
        Button({ type: ButtonType.Normal }) {
          Text(`本轮工具记录 · ${message.tools.length} 项 · ${this.collapsedToolIds.includes(message.id) ? '展开' : '收起'}`)
            .fontSize(this.palette.metaSize).fontColor(this.palette.accent).width('100%').textAlign(TextAlign.Start)
        }.width('100%').constraintSize({ minHeight: 48 }).padding(0).backgroundColor(Color.Transparent)
          .onClick(() => this.toggleToolResults(message.id))
        if (!this.collapsedToolIds.includes(message.id)) {
          ForEach(message.tools, (item: ToolDisplaySummary) => {
            Column({ space: 4 }) {
              Row({ space: 8 }) {
                Text(item.label).fontSize(this.palette.metaSize).fontWeight(FontWeight.Medium).fontColor(this.palette.ink).layoutWeight(1)
                Text(this.toolStateLabel(item.state)).fontSize(this.palette.metaSize).fontColor(this.toolStateColor(item.state))
              }.width('100%')
              Text(item.summary).fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
              EvidencePanel({ evidence: item.evidence ?? [], active: this.voiceActive })
            }.width('100%').alignItems(HorizontalAlign.Start).padding(10)
              .backgroundColor(this.palette.field).borderRadius(10)
          }, (_item: ToolDisplaySummary, index: number) => `${message.id}-tool-${index}`)
        }
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private RequestFailure(message: ConversationEntry) {
    Column({ space: 8 }) {
      Text('请求未完成').fontSize(this.palette.bodySize).fontWeight(FontWeight.Bold).fontColor(this.palette.danger).width('100%')
      Text(message.content).fontSize(this.palette.metaSize).fontColor(this.palette.ink).width('100%')
      Text('原输入已保留在对话中，可复制或恢复后手动发送。若请求曾到达服务端，请先查看历史和已有提案。')
        .fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
      Button(this.inputLength(this.prompt) > 0 ? '输入框已有草稿' : '恢复本次输入')
        .constraintSize({ minHeight: 48 }).fontSize(this.palette.metaSize).fontColor(this.palette.accent)
        .backgroundColor(this.palette.accentSoft).enabled(!this.loading && this.inputLength(this.prompt) === 0)
        .onClick(() => this.changePrompt(restoreDraft(this.prompt, message.failedPrompt), true))
      if (message.failureCode === 'LOGIN_REQUIRED' || message.failureCode === 'MODEL_AUTH_INVALID' ||
        message.failureCode === 'MODEL_KEY_REQUIRED') {
        Text(message.failureCode === 'LOGIN_REQUIRED' ? '重新登录前，请先复制要保留的输入。' : '可在个人设置检查模型 API Key。')
          .fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
        Button('前往个人设置').constraintSize({ minHeight: 48 }).fontSize(this.palette.metaSize)
          .fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft).onClick(() => this.onOpenProfile())
      }
    }.width('100%').padding(14).alignItems(HorizontalAlign.Start)
      .backgroundColor(this.palette.surface).borderRadius(16)
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
      Text(task.title).fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium).fontColor(this.palette.ink)
        .width('100%').wordBreak(WordBreak.BREAK_WORD)
      TaskScheduleDetails({ startAt: task.start_at, endAt: task.end_at, location: task.location, reminderMinutes: task.reminder_minutes })
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private PlanDraftDetails(plan: PlanningPlanDraft) {
    Column({ space: 8 }) {
      Text(plan.title).fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium).fontColor(this.palette.ink)
        .width('100%').wordBreak(WordBreak.BREAK_WORD)
      Text(plan.summary.length > 0 ? plan.summary : '未填写计划说明').fontSize(this.palette.bodySize)
        .fontColor(this.palette.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
      Text(plan.target_date === null ? '未设截止日' : `截止 ${plan.target_date}`).fontSize(this.palette.metaSize)
        .fontColor(this.palette.quiet).width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private ProposalChanges(action: PendingAction) {
    Column({ space: 12 }) {
      Text(action.action === 'delete' ? '将删除的原内容' : '修改前').fontSize(this.palette.bodySize)
        .fontWeight(FontWeight.Medium).fontColor(this.palette.ink).width('100%')
      ForEach(this.beforeTasks(action), (task: PlanningTaskDraft) => {
        this.TaskDraftDetails(task)
      }, (_task: PlanningTaskDraft) => `${action.proposal_id}-before-task`)
      ForEach(this.beforePlans(action), (plan: PlanningPlanDraft) => {
        this.PlanDraftDetails(plan)
      }, (_plan: PlanningPlanDraft) => `${action.proposal_id}-before-plan`)
      Divider().color(this.palette.line)
      if (action.action === 'delete') {
        Text(action.kind === 'plan' ?
          `只移除计划与里程碑，${action.before_plan?.task_count ?? 0} 项现有任务将保留为独立待办。` :
          '确认后移除此任务；如果它属于计划，计划的任务计数也会更新。')
          .fontSize(this.palette.bodySize).fontColor(this.palette.danger).width('100%').wordBreak(WordBreak.BREAK_WORD)
      } else {
        Text('修改后').fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium).fontColor(this.palette.accent).width('100%')
        ForEach(this.afterTasks(action), (task: PlanningTaskDraft) => {
          this.TaskDraftDetails(task)
        }, (_task: PlanningTaskDraft) => `${action.proposal_id}-after-task`)
        ForEach(this.afterPlans(action), (plan: PlanningPlanDraft) => {
          this.PlanDraftDetails(plan)
        }, (_plan: PlanningPlanDraft) => `${action.proposal_id}-after-plan`)
        if (action.kind === 'plan') {
          Text('本次只修改计划资料；原有里程碑与任务不会自动改期或删除。')
            .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
        }
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(12)
      .backgroundColor(this.palette.canvas).borderRadius(this.palette.controlRadius)
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
      Text('以下时间均为北京时间').fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
      ForEach(action.payload.milestones ?? [], (milestone: PendingMilestonePreview, milestoneIndex: number) => {
        Column({ space: 10 }) {
          Text(`${milestoneIndex + 1}. ${milestone.title}`)
            .fontSize(this.palette.bodySize).fontWeight(FontWeight.Bold).fontColor(this.palette.ink).width('100%')
          Text(`截止：${formatPlanDateTime(milestone.due_at)} · ${milestone.tasks.length} 项任务`)
            .fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
          if (milestone.tasks.length === 0) {
            Text('这个里程碑尚无任务').fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
          }
          ForEach(milestone.tasks, (task: PendingTaskPreview, taskIndex: number) => {
            Column({ space: 6 }) {
              Text(`${milestoneIndex + 1}.${taskIndex + 1} ${task.title}`)
                .fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium).fontColor(this.palette.ink).width('100%')
              TaskScheduleDetails({ startAt: task.start_at, endAt: task.end_at,
                location: task.location, reminderMinutes: task.reminder_minutes })
            }.width('100%').alignItems(HorizontalAlign.Start).padding(12)
              .backgroundColor(this.palette.field).borderRadius(12)
          }, (_task: PendingTaskPreview, taskIndex: number) =>
            `${action.proposal_id}-${milestoneIndex}-${taskIndex}`)
        }.width('100%').alignItems(HorizontalAlign.Start).padding(12)
          .backgroundColor(this.palette.surface).borderRadius(14)
      }, (_milestone: PendingMilestonePreview, milestoneIndex: number) =>
        `${action.proposal_id}-${milestoneIndex}`)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private suggestion(title: string, detail: string, icon: string, prompt: string) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        AppIcon({ name: icon, iconSize: 20, color: this.palette.accent })
        Text(title).fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium).fontColor(this.palette.ink)
          .layoutWeight(1).textAlign(TextAlign.Start).wordBreak(WordBreak.BREAK_WORD)
        AppIcon({ name: 'chevron', iconSize: 16, color: this.palette.quiet })
      }.width('100%')
    }.width('100%').padding({ left: 16, right: 12, top: 14, bottom: 14 }).constraintSize({ minHeight: 60 })
      .backgroundColor(Color.Transparent).borderRadius(0)
      .accessibilityText(`${title}，${detail}，填入输入框`)
      .onClick(() => this.choosePrompt(prompt))
  }

  @Builder
  private VoicePanel() {
    Column({ space: 12 }) {
      Row({ space: 10 }) {
        if (this.voiceState.phase === 'starting' || this.voiceState.phase === 'recognizing') {
          LoadingProgress().width(20).height(20).color(this.palette.accent)
        } else {
          AppIcon({ name: 'microphone', iconSize: 20, color: this.palette.accent })
        }
        Text(this.voiceState.phase === 'review' ? '核对语音文字' :
          (this.voiceState.phase === 'error' ? '语音提示' : '语音输入'))
          .fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium).fontColor(this.palette.ink).layoutWeight(1)
        if (this.voiceState.phase === 'listening') {
          Text('录音中').fontSize(this.palette.metaSize).fontColor(this.palette.accent)
        }
      }.width('100%')
      Text(this.voiceState.message).fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
      if (this.voiceState.phase === 'review') {
        TextArea({ text: this.voiceState.transcript, placeholder: '识别文字，可在这里修改…' })
          .width('100%').fontSize(this.palette.bodySize).fontColor(this.palette.ink)
          .constraintSize({ minHeight: 72, maxHeight: 140 })
          .backgroundColor(this.palette.surface).borderRadius(this.palette.controlRadius).padding(12)
          .border({ width: 1, color: this.palette.outline })
          .accessibilityText('识别文字，可编辑，尚未发送')
          .onChange((value: string) => this.editVoiceTranscript(value))
        Row({ space: 10 }) {
          Button('放弃文字').layoutWeight(1).constraintSize({ minHeight: 48 })
            .fontSize(this.palette.bodySize).fontColor(this.palette.quiet).backgroundColor(this.palette.surface)
            .onClick(() => this.cancelVoice())
          Button('填入输入框').layoutWeight(1).constraintSize({ minHeight: 48 })
            .fontSize(this.palette.bodySize).fontColor(this.palette.onAccent).backgroundColor(this.palette.accent)
            .accessibilityText('将识别文字追加到输入框，不自动发送')
            .onClick(() => this.useVoiceTranscript())
        }.width('100%')
        Text('识别文字将追加到原输入，检查后再手动发送。')
          .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
      } else if (this.capturePending()) {
        if (this.voiceState.transcript.length > 0) {
          Text(this.voiceState.transcript).fontSize(this.palette.bodySize).fontColor(this.palette.ink).width('100%')
            .maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        Row({ space: 10 }) {
          Button('取消录音').layoutWeight(1).constraintSize({ minHeight: 48 })
            .fontSize(this.palette.bodySize).fontColor(this.palette.quiet).backgroundColor(this.palette.surface)
            .onClick(() => this.cancelVoice())
          if (this.voiceState.phase === 'listening') {
            Button('完成录音').layoutWeight(1).constraintSize({ minHeight: 48 })
              .fontSize(this.palette.bodySize).fontColor(this.palette.onAccent).backgroundColor(this.palette.accent)
              .onClick(() => this.voiceInteraction?.finishListening())
          }
        }.width('100%')
        Text('录音最长 60 秒，说完后可编辑文字；行简不保存录音。')
          .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
      } else {
        Button('知道了').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
          .fontColor(this.palette.accent).backgroundColor(this.palette.surface)
          .onClick(() => this.cancelVoice())
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(this.palette.cardInset)
      .backgroundColor(this.palette.accentSoft).borderRadius(this.palette.cardRadius)
      .border({ width: 1, color: this.palette.line })
  }

  @Builder
  private ModelOptions() {
    Column({ space: 12 }) {
      Text('模型与工具').fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium)
        .fontColor(this.palette.ink).width('100%')
      Text(`当前：${this.selectedModelLabel()}`).fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
      if (this.modelsLoading) { Text('正在核对模型配置…').fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%') }
      if (this.modelsMessage.length > 0) { Text(this.modelsMessage).fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%') }
      if (this.modelCatalog !== null) {
        ForEach(this.modelCatalog.models, (option: ModelOption) => {
          Column({ space: 4 }) {
            Button(`${option.label}${this.model === option.id ? ' · 已选' : ''}${this.modelCatalog?.default_model === option.id ? ' · 服务推荐' : ''}`).width('100%')
              .constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
              .fontColor(this.model === option.id ? this.palette.onAccent : this.palette.accent)
              .backgroundColor(this.model === option.id ? this.palette.accent : this.palette.accentSoft)
              .borderRadius(this.palette.controlRadius).enabled(!this.loading && this.decisionId.length === 0 && !this.deletionBusy && modelUnavailableReason(option).length === 0)
              .onClick(() => this.selectModel(option.id))
            InfoDisclosure({ title: `${option.provider} · 能力说明`,
              message: `工具${option.supports_tools ? '支持' : '未声明'}，增量回答${option.supports_streaming ? '支持' : '未声明'}，推理${option.supports_reasoning ? '已声明' : '未声明'}。` })
            if (modelUnavailableReason(option).length > 0) {
              Text(modelUnavailableReason(option)).fontSize(this.palette.metaSize).fontColor(this.palette.danger).width('100%').wordBreak(WordBreak.BREAK_WORD)
            }
          }.width('100%').alignItems(HorizontalAlign.Start)
        }, (option: ModelOption) => `${option.id}-${this.modelsDataRevision}`)
      }
      Button('刷新模型列表').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize).fontColor(this.palette.accent)
        .backgroundColor(this.palette.surface).enabled(!this.modelsLoading).onClick(() => this.loadModels())
      InfoDisclosure({ title: '模型使用说明', message: '能力以服务配置为准，配置可用不代表已完成真实评测。切换仅影响后续消息。' })
      Button(this.runRecordsExpanded ? '收起最近运行' : '最近运行 · 恢复查看').width('100%')
        .constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize).fontColor(this.palette.accent)
        .backgroundColor(this.palette.surface).borderRadius(this.palette.controlRadius).onClick(() => this.toggleRunRecords())
      Button('语音使用说明').width('100%').constraintSize({ minHeight: 48 }).fontColor(this.palette.accent).backgroundColor(this.palette.surface)
        .onClick(() => { this.explainedSpeechId = ''; this.voiceExplanationOpen = true; })
      if (this.sessionMode === 'continue') {
        Button('刷新会话上下文').width('100%').constraintSize({ minHeight: 48 }).fontColor(this.palette.accent).backgroundColor(this.palette.surface)
          .enabled(!this.loading && !this.sessionLoading).onClick(() => this.refreshSessionContext())
      }
      Button('账号与模型设置').width('100%').constraintSize({ minHeight: 48 })
        .fontSize(this.palette.bodySize).fontColor(this.palette.accent).backgroundColor(this.palette.surface)
        .borderRadius(this.palette.controlRadius).onClick(() => this.onOpenProfile())
      Button('校园导航').width('100%').constraintSize({ minHeight: 48 })
        .fontSize(this.palette.bodySize).fontColor(this.palette.accent).backgroundColor(this.palette.surface)
        .borderRadius(this.palette.controlRadius).onClick(() => this.onOpenRoute())
    }.width('100%').padding(this.palette.cardInset).backgroundColor(this.palette.surface)
      .borderRadius(this.palette.cardRadius).border({ width: 1, color: this.palette.line }).alignItems(HorizontalAlign.Start)
  }

  @Builder
  private SuggestedPrompt() {
    Column({ space: 12 }) {
      Text(`新的输入建议 · ${this.promptSuggestions.length} 条待处理`)
        .fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium).fontColor(this.palette.ink).width('100%')
      Text(this.promptSuggestions[0] ?? '').fontSize(this.palette.bodySize).fontColor(this.palette.quiet)
        .width('100%').wordBreak(WordBreak.BREAK_WORD).copyOption(CopyOptions.InApp)
      Text('原输入不会被替换。追加后仍需你手动发送。')
        .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
      Row({ space: 8 }) {
        Button('略过').layoutWeight(1).constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
          .fontColor(this.palette.quiet).backgroundColor(this.palette.surface).borderRadius(this.palette.controlRadius)
          .onClick(() => this.dismissSuggestion())
        Button('采用').layoutWeight(1).constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
          .fontColor(this.palette.accent).backgroundColor(this.palette.surface).borderRadius(this.palette.controlRadius)
          .enabled(this.inputLength(this.prompt) === 0).onClick(() => this.applySuggestion(false))
        Button('追加').layoutWeight(1).constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
          .fontColor(this.palette.onAccent).backgroundColor(this.palette.accent).borderRadius(this.palette.controlRadius)
          .onClick(() => this.applySuggestion(true))
      }.width('100%')
    }.width('100%').padding(this.palette.cardInset).backgroundColor(this.palette.accentSoft)
      .borderRadius(this.palette.cardRadius).alignItems(HorizontalAlign.Start)
  }

  @Builder
  private RunPanel() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Text(this.runState.errorCode === 'RUN_DELETED' ? '运行已删除' : this.runState.snapshot !== null ? this.runStatusLabel(this.runState.snapshot) :
          (this.runState.phase === 'creating' ? '正在提交运行' : '核对本次运行'))
          .fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium).fontColor(this.palette.ink).layoutWeight(1)
        if (['creating', 'polling', 'checking', 'cancelling'].includes(this.runState.phase)) {
          LoadingProgress().width(20).height(20).color(this.palette.accent)
        }
      }.width('100%')
      if (this.runState.message.length > 0) {
        Text(this.runState.message).fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
          .wordBreak(WordBreak.BREAK_WORD)
      }
      if (this.runState.snapshot !== null) {
        Text(`实际模型调用 ${this.runState.snapshot.model_calls} 次 · 工具调用 ${this.runState.snapshot.tool_calls} 次`)
          .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
        if (this.restoredRunIds.includes(this.runState.runId)) {
          Text(this.runState.snapshot.session_id === this.sessionId ? '已回到这次运行所属的会话，后续输入沿用该会话。' : '这是恢复查看的运行，后续输入仍属于当前会话。')
            .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
        }
        if (this.runState.snapshot.tool_progress.length > 0) {
          Button(this.runProgressExpanded ? '收起实际工具进度' : `查看 ${this.runState.snapshot.tool_progress.length} 条实际工具进度`)
            .width('100%').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
            .fontColor(this.palette.accent).backgroundColor(Color.Transparent)
            .onClick(() => this.runProgressExpanded = !this.runProgressExpanded)
          if (this.runProgressExpanded) {
            ForEach(this.runState.snapshot.tool_progress, (tool: RunToolProgress) => {
              Column({ space: 4 }) {
                Text(`${tool.label} · ${tool.state === 'running' ? '正在执行' : tool.state === 'success' ? '已返回' : '调用失败'}`)
                  .fontSize(this.palette.bodySize).fontColor(this.palette.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
                if (tool.summary.length > 0) {
                  Text(tool.summary).fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
                }
              }.width('100%').alignItems(HorizontalAlign.Start)
            }, (tool: RunToolProgress) => `${this.runState.runId}-${tool.call_id}-${this.runState.lastAppliedSeq}`)
          }
        }
      }
      if (this.canCancelRun()) {
        Button('取消本次运行').width('100%').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
          .fontColor(this.palette.danger).backgroundColor(this.palette.dangerSoft).borderRadius(this.palette.controlRadius)
          .enabled(!this.deletionBusy).onClick(() => this.cancelRun())
      }
      if (this.runState.canRetryStart) {
        Text(this.runState.phase === 'local_error' ? '本次尚未发送；先完成本机保存，再沿用同一运行标识提交。' :
          '尚不能确定首次提交是否到达。重试会沿用同一运行标识和原问题，不创建另一笔请求。')
          .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
        Button('重试提交同一运行').width('100%').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
          .fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft).borderRadius(this.palette.controlRadius)
          .enabled(!this.deletionBusy).onClick(() => this.retryRunStart())
      }
      if (this.runState.errorCode !== 'RUN_DELETED') {
        Button('核对运行状态').width('100%').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
          .fontColor(this.palette.accent).backgroundColor(Color.Transparent)
          .enabled(!this.deletionBusy && !['creating', 'checking', 'cancelling', 'polling'].includes(this.runState.phase))
          .onClick(() => this.refreshRun())
      }
      if (this.loading) {
        Text('切换页面会暂停本机刷新，服务端可能继续运行；返回后将核对实际状态。')
          .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
      }
    }.width('100%').padding(this.palette.cardInset).backgroundColor(this.palette.canvas)
      .alignItems(HorizontalAlign.Start).borderRadius(this.palette.cardRadius)
  }

  @Builder
  private RunRecords() {
    Column({ space: 12 }) {
      Text('最近运行 · 仅联网查看').fontSize(this.palette.sectionTitle).fontWeight(FontWeight.Medium).fontColor(this.palette.ink).width('100%')
      Text('最多显示最近 20 次。恢复只查询原运行，不重新发送问题；重启后的中断运行需你明确发起新请求。')
        .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
      if (this.runState.listMessage.length > 0) {
        Text(this.runState.listMessage).fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
      }
      if (this.runState.listLoading) { LoadingProgress().width(24).height(24).color(this.palette.accent) }
      if (!this.runState.listLoading && this.runState.recent.length === 0) {
        Text('暂无可展示的运行记录。').fontSize(this.palette.bodySize).fontColor(this.palette.quiet).width('100%')
      }
      ForEach(this.runState.recent, (run: RunSnapshot) => {
        Column({ space: 8 }) {
          Text(run.message).fontSize(this.palette.bodySize).fontColor(this.palette.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
          Text(`${this.runStatusLabel(run)} · ${formatPlanDateTime(run.created_at)}（北京时间）`)
            .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
          Button(this.runState.runId === run.run_id ? '核对当前运行' : '恢复查看这次运行').width('100%')
            .constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize).fontColor(this.palette.accent)
            .backgroundColor(this.palette.accentSoft).borderRadius(this.palette.controlRadius)
            .enabled(!this.deletionBusy && (!this.loading || this.runState.runId === run.run_id))
            .onClick(() => this.runState.runId === run.run_id ? this.refreshRun() : this.recoverRun(run.run_id))
        }.width('100%').alignItems(HorizontalAlign.Start).padding(12).backgroundColor(this.palette.surface).borderRadius(this.palette.controlRadius)
      }, (run: RunSnapshot) => `${run.run_id}-${run.seq}`)
      Button('刷新运行记录').width('100%').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
        .fontColor(this.palette.accent).backgroundColor(Color.Transparent).enabled(!this.runState.listLoading)
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
            Text('恢复的运行 · 原问题').fontSize(this.palette.metaSize).fontColor(this.palette.onAccent).width('100%')
          }
          if (message.role === 'assistant') {
            Row({ space: 8 }) {
              AppIcon({ name: 'assistant', iconSize: 20, color: this.palette.accent })
              Text('行简').fontSize(this.palette.metaSize).fontWeight(FontWeight.Medium)
                .fontColor(this.palette.quiet).layoutWeight(1)
              Button({ type: ButtonType.Normal }) {
                Row({ space: 6 }) {
                  AppIcon({ name: this.voiceState.speakingMessageId === message.id ? 'stop' : 'speaker',
                    iconSize: 20, color: this.palette.accent })
                  Text(this.voiceState.speakingMessageId === message.id ? '停止' : '播报')
                    .fontSize(this.palette.metaSize).fontColor(this.palette.accent)
                }
              }.constraintSize({ minHeight: 48, minWidth: 72 }).padding(8)
                .backgroundColor(Color.Transparent).borderRadius(this.palette.controlRadius)
                .accessibilityText(this.voiceState.speakingMessageId === message.id ? '停止播报这条回答' : '播报这条回答正文')
                .enabled(message.incomplete !== true && (this.speechPending() && this.voiceState.speakingMessageId === message.id ||
                  !this.loading && !this.deletionBusy && this.decisionId.length === 0 && !this.capturePending()))
                .onClick(() => this.speakReply(message))
            }.width('100%')
          }
          if (message.incomplete === true) {
            Text('已收到的回答片段 · 尚未形成完整结果').fontSize(this.palette.metaSize)
              .fontColor(this.palette.warning).width('100%')
          }
          MessageContent({ content: message.content, isUser: message.role === 'user' })
          if (message.role === 'assistant') { this.ToolResults(message) }
        }.alignItems(HorizontalAlign.Start)
          .padding(message.role === 'user' ? 14 : 0)
          .width(message.role === 'user' ? '90%' : '100%')
          .backgroundColor(message.role === 'user' ? this.palette.accent : this.palette.surface)
          .border({ width: 0, color: this.palette.line })
          .borderRadius(message.role === 'user' ? { topLeft: 18, topRight: 18, bottomLeft: 18, bottomRight: 4 }
            : { topLeft: 18, topRight: 18, bottomLeft: 4, bottomRight: 18 })
        if (message.role !== 'user') { Blank() }
      }.width('100%')
    }
  }

  @Builder
  private ProposalCard(action: PendingAction) {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Text(`${this.operationLabel(action)}提案`)
          .fontSize(this.palette.metaSize).fontWeight(FontWeight.Medium).fontColor(this.palette.accent).layoutWeight(1)
        Text(this.decisionLabel(action)).fontSize(this.palette.metaSize)
          .fontColor(this.needsReview(action.proposal_id) ? this.palette.warning : this.palette.quiet)
      }.width('100%')
      Text(action.title).fontSize(this.palette.sectionTitle).fontWeight(FontWeight.Bold).fontColor(this.palette.ink)
        .width('100%').wordBreak(WordBreak.BREAK_WORD)
      if (!this.receiptCollapsed(action)) {
        AgentProposalSummary({ action: action, evidence: this.sourcesForProposal(action), active: this.voiceActive })
        CourseReviewPanel({ action: action, selected: this.acksFor(action),
          reviewEnabled: this.decisionId.length === 0 && !this.loading && !this.needsReview(action.proposal_id),
          onToggle: (review: CourseReview) => this.toggleCourseAck(action, review) })
        if (action.status === 'pending' && validReliableAction(action) && !this.needsReview(action.proposal_id) && courseCandidates(action).length > 0) {
          Button(this.permissionProposalId === action.proposal_id ? '收起课内许可设置' : '逐项设置课内许可')
            .width('100%').constraintSize({ minHeight: 48 }).fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft)
            .enabled(this.decisionId.length === 0).onClick(() => this.togglePermissionEditor(action))
          if (this.permissionProposalId === action.proposal_id) { this.CoursePermissionEditor(action) }
          Button('调整日期、时长或偏好').width('100%').constraintSize({ minHeight: 48 }).fontColor(this.palette.accent)
            .backgroundColor(Color.Transparent).enabled(this.decisionId.length === 0 && this.adjustingProposalId.length === 0)
            .onClick(() => this.beginAdjustment(action))
        }
        Text(this.proposalMeta(action)).fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
        if ((action.payload.summary ?? '').length > 0) {
          InfoDisclosure({ title: '计划说明', message: action.payload.summary ?? '' })
        }
        if (action.action !== 'create' && validReliableAction(action)) {
          this.ProposalChanges(action)
        } else if (action.kind === 'plan') {
          if ((action.payload.milestones ?? []).length > 0) {
            Button({ type: ButtonType.Normal }) {
              Text(this.proposalExpanded(action.proposal_id) ? '收起完整计划' :
                `查看全部 ${action.payload.milestones?.length ?? 0} 个里程碑 · ${this.proposalTaskCount(action)} 项任务`)
                .fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium).fontColor(this.palette.accent)
                .width('100%').textAlign(TextAlign.Start).wordBreak(WordBreak.BREAK_WORD)
            }.width('100%').constraintSize({ minHeight: 48 }).padding(12)
              .backgroundColor(this.palette.accentSoft).borderRadius(this.palette.controlRadius)
              .accessibilityText(`${action.title}，${this.proposalExpanded(action.proposal_id) ? '已展开，收起完整计划' : '已折叠，查看完整计划'}`)
              .onClick(() => this.toggleProposal(action.proposal_id))
            if (this.proposalExpanded(action.proposal_id)) { this.ProposalMilestones(action) }
          } else {
            Text('提案中暂无里程碑，请补充计划后再确认。')
              .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
          }
        } else {
          TaskScheduleDetails({ startAt: action.start_at, endAt: action.end_at,
            location: action.payload.task?.location ?? action.payload.location ?? null, reminderMinutes: action.reminder_minutes })
        }
        if (action.conflicts.length > 0) {
          Text('需要调整的冲突').fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium).fontColor(this.palette.danger).width('100%')
          ForEach(action.conflicts, (conflict: string, index: number) => {
            Text(`${index + 1}. ${conflict}`).fontSize(this.palette.metaSize).fontColor(this.palette.danger).width('100%')
              .wordBreak(WordBreak.BREAK_WORD)
          }, (_conflict: string, index: number) => `${action.proposal_id}-conflict-${index}`)
        }
        if ((action.warnings ?? []).length > 0) {
          Text('仍需手动核对').fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium).fontColor(this.palette.warning).width('100%')
          ForEach(action.warnings ?? [], (warning: string, index: number) => {
            Text(`${index + 1}. ${warning}`).fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
              .wordBreak(WordBreak.BREAK_WORD)
          }, (_warning: string, index: number) => `${action.proposal_id}-warning-${index}`)
        }
        if (validReliableAction(action)) {
          Text(action.status === 'pending' ? `预览有效至 ${formatPlanDateTime(action.expires_at ?? null)}（北京时间）` :
            `原预览生成于 ${formatPlanDateTime(action.created_at ?? null)}（北京时间）`)
            .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
        }
        if ((action.reason ?? '').length > 0) {
          InfoDisclosure({ title: '建议依据', message: action.reason ?? '' })
        }
      }
      if (validatedActionReceipt(action) !== null) {
        Text(`执行回执 · ${formatPlanDateTime(action.receipt?.applied_at ?? null)}（北京时间）`)
          .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
        Text(this.completedMessage(action)).fontSize(this.palette.bodySize).fontColor(this.palette.ink).width('100%')
      }
      if (this.feedbackFor(action.proposal_id) !== undefined) {
        Text(this.feedbackFor(action.proposal_id)?.message ?? '').fontSize(this.palette.metaSize).width('100%')
          .fontColor(this.needsReview(action.proposal_id) ? this.palette.warning : this.palette.quiet)
      }
      if (this.feedbackFor(action.proposal_id)?.code === 'LOGIN_REQUIRED') {
        Button('前往个人设置重新登录').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
          .fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft)
          .onClick(() => this.onOpenProfile())
      }
      if (this.needsReview(action.proposal_id)) {
        Button(this.decisionId === action.proposal_id ? '核对中…' : '核对状态')
          .width('100%').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
          .fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft).borderRadius(this.palette.controlRadius)
          .enabled(!this.loading && !this.deletionBusy && this.decisionId.length === 0)
          .onClick(() => this.checkDecision(action))
        Button('查看计划列表').width('100%').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
          .fontColor(this.palette.accent).backgroundColor(Color.Transparent).onClick(() => this.onOpenPlan())
      } else if (decisionDisposition(action) === 'confirmed' || decisionDisposition(action) === 'cancelled') {
        Button(this.receiptCollapsed(action) ? '查看原提案' : '收起原提案')
          .width('100%').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
          .fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft).borderRadius(this.palette.controlRadius)
          .onClick(() => this.toggleReceipt(action.proposal_id))
        if (action.status === 'confirmed') {
          if (receiptTaskId(action).length > 0 || receiptPlanId(action).length > 0) {
            Button(action.kind === 'task' ? '查看这个任务' : '查看这个计划').width('100%').constraintSize({ minHeight: 48 })
              .fontSize(this.palette.bodySize).fontColor(this.palette.accent).backgroundColor(Color.Transparent)
              .onClick(() => this.openReceipt(action))
          } else {
            Button('查看计划列表').width('100%').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
              .fontColor(this.palette.accent).backgroundColor(Color.Transparent).onClick(() => this.onOpenPlan())
          }
        }
      } else if (this.requiresNewPreview(action)) {
        Text(this.proposalBlockMessage(action)).fontSize(this.palette.metaSize).fontColor(this.palette.warning).width('100%')
        Button('填入重新规划建议').width('100%').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
          .fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft).borderRadius(this.palette.controlRadius)
          .onClick(() => this.regenerateProposal(action))
        if (action.status === 'confirmed' || action.status === 'cancelled') {
          Button('核对持久状态').width('100%').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
            .fontColor(this.palette.accent).backgroundColor(Color.Transparent)
            .enabled(!this.loading && !this.deletionBusy && this.decisionId.length === 0).onClick(() => this.checkDecision(action))
        } else if (action.status === 'pending' && validReliableAction(action)) {
          Button('取消这份预览').width('100%').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
            .fontColor(this.palette.quiet).backgroundColor(Color.Transparent)
            .enabled(!this.loading && !this.deletionBusy && this.decisionId.length === 0).onClick(() => this.decide(action, false))
        }
      } else if (action.status === 'pending') {
        if (this.anotherDecisionUnknown(action.proposal_id)) {
          Text('先核对另一份提案的执行结果，再确认这份提案。仍可取消预览或继续聊天。')
            .fontSize(this.palette.metaSize).fontColor(this.palette.warning).width('100%').wordBreak(WordBreak.BREAK_WORD)
        }
        Row({ space: 8 }) {
          Button('暂不执行').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize).fontColor(this.palette.quiet)
            .backgroundColor(this.palette.field).borderRadius(this.palette.controlRadius).layoutWeight(1)
            .enabled(!this.loading && !this.deletionBusy && this.decisionId.length === 0)
            .onClick(() => this.decide(action, false))
          Button(this.decisionId === action.proposal_id ? '处理中…' : `确认${this.operationLabel(action)}`)
            .constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize).fontColor(this.palette.onAccent)
            .backgroundColor(this.palette.accent).borderRadius(this.palette.controlRadius).layoutWeight(1)
            .enabled(!this.loading && !this.deletionBusy && this.decisionId.length === 0 && canConfirmAction(action) &&
              !this.anotherDecisionUnknown(action.proposal_id) && validCourseAcknowledgements(action, this.acksFor(action)))
            .onClick(() => this.decide(action, true))
        }.width('100%')
      }
    }.width('100%').padding(this.palette.cardInset).backgroundColor(this.palette.surface)
      .alignItems(HorizontalAlign.Start).borderRadius(this.palette.cardRadius)
      .border({ width: 1, color: this.focusedProposalId === action.proposal_id ? this.palette.accent : this.palette.line })
      .onAreaChange((_oldArea: Area, newArea: Area) => {
        this.rememberProposalAnchor(action.proposal_id, Number(newArea.position.y));
      })
  }

  build() {
    Column() {
      Row({ space: 4 }) {
        Column({ space: 2 }) {
          Text(this.hasConversation() ? conversationTitle(this.sessionTitle) : '助手')
            .fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.palette.ink).width('100%')
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.selectedModelLabel()).fontSize(12).fontColor(this.palette.quiet).width('100%')
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button({ type: ButtonType.Normal }) {
          AppIcon({ name: 'plus', iconSize: 23, color: this.palette.accent })
        }.width(44).height(44).backgroundColor(Color.Transparent).borderRadius(22)
          .accessibilityText('新建对话').enabled(!this.sessionLoading)
          .onClick(() => this.requestConversation())
        Button({ type: ButtonType.Normal }) {
          AppIcon({ name: 'history', iconSize: 21, color: this.palette.accent })
        }.width(44).height(44).backgroundColor(Color.Transparent)
          .borderRadius(22).accessibilityText('历史会话').onClick(() => this.onOpenHistory())
        Button({ type: ButtonType.Normal }) {
          AppIcon({ name: this.optionsExpanded ? 'collapse' : 'more', iconSize: 23, color: this.palette.accent })
        }.width(44).height(44).backgroundColor(Color.Transparent).borderRadius(22)
          .accessibilityText(this.optionsExpanded ? '收起模型与快捷入口' : '展开模型与快捷入口')
          .onClick(() => this.toggleOptions())
      }.width('100%').height(64).padding({ left: this.palette.pageInset, right: 8, top: 4, bottom: 4 })
        .backgroundColor(this.palette.surface).border({ width: { bottom: 0.5 }, color: this.palette.line })

      if (this.attentionActions().length > 0) {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 8 }) {
            Text(this.attentionLabel()).fontSize(this.palette.metaSize).fontColor(this.palette.quiet)
              .layoutWeight(1).textAlign(TextAlign.Start).wordBreak(WordBreak.BREAK_WORD)
            Text('定位提案').fontSize(this.palette.metaSize).fontColor(this.palette.accent)
            AppIcon({ name: 'chevron', iconSize: 20, color: this.palette.accent })
          }.width('100%')
        }.width('100%').constraintSize({ minHeight: 48 }).padding({ left: this.palette.pageInset, right: 16, top: 8, bottom: 8 })
          .backgroundColor(this.attentionActions().some((action: PendingAction) => this.needsReview(action.proposal_id)) ?
            this.palette.warningSoft : this.palette.accentSoft)
          .accessibilityText(`${this.attentionLabel()}，按顺序定位需处理的提案`)
          .onClick(() => this.jumpToNextProposal())
      }

      Scroll(this.chatScroller) {
        Column({ space: 24 }) {
          if (this.sessionNotice.length > 0) {
            Text(this.sessionNotice).fontSize(this.palette.bodySize).fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
          }
          if (this.sessionLoading) { LoadingProgress().width(24).height(24).color(this.palette.accent) }
          if (this.switchConfirmOpen) { this.ConversationSwitch() }
          if (this.voiceExplanationOpen) { this.VoiceExplanation() }
          if (this.optionsExpanded) { this.ModelOptions() }
          this.DecisionRecovery()
          if (this.adjustingProposalId.length > 0) { this.AdjustmentEditor() }
          this.DraftRecovery()
          if (this.runRecordsExpanded) { this.RunRecords() }
          if (this.runState.runId.length > 0) { this.RunPanel() }
          if (!this.hasConversation()) {
            Column({ space: 12 }) {
              Text('今天想安排什么？').fontSize(28).fontWeight(FontWeight.Bold)
                .fontColor(this.palette.ink).width('100%')
              Text('查课表、拆解目标，安排好每一天。')
                .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
            }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 28, bottom: 4 })
            Column() {
              this.suggestion('安排一段专注时间', '结合课程，找到今天的空闲', 'calendar',
                '根据我今天的课程和待办，找一段合适的空闲时间安排复习，先生成待确认的提案。')
              Divider().color(this.palette.line).strokeWidth(1).margin({ left: 48 })
              this.suggestion('制定一周复习计划', '分解目标，循序渐进', 'book',
                '结合我的近期课程，帮我制定一周复习计划，分解为里程碑和待办，先生成提案。')
              Divider().color(this.palette.line).strokeWidth(1).margin({ left: 48 })
              this.suggestion('看看我的校园安排', '查询已同步的个人校园信息', 'classroom',
                '查看我已同步的校园信息，结合最近的课表，提醒我接下来需要关注的事项。')
            }.width('100%').backgroundColor(this.palette.field).borderRadius(this.palette.cardRadius).clip(true)
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
              LoadingProgress().width(20).height(20).color(this.palette.accent)
              Text('正在处理请求…').fontSize(this.palette.metaSize).fontColor(this.palette.quiet)
            }.width('100%')
          }
          if (this.promptSuggestions.length > 0) { this.SuggestedPrompt() }
          if (this.capturePending() || this.voiceState.phase === 'error') { this.VoicePanel() }
          if (this.suggestionNotice.length > 0) {
            Text(this.suggestionNotice).fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
          }
          if (this.voiceNotice.length > 0) {
            Text(this.voiceNotice).fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
          }
          if (this.speechPending()) {
            Text(this.voiceState.message).fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
          }
        }.width('100%').padding({ left: this.palette.pageInset, right: this.palette.pageInset, top: 16, bottom: 24 })
          .onAreaChange((_oldArea: Area, newArea: Area) => this.chatContentChanged(Number(newArea.height)))
      }.layoutWeight(1).width('100%').clip(true).scrollBar(BarState.Off).align(Alignment.TopStart)
        .onAreaChange((_oldArea: Area, newArea: Area) => this.chatViewportChanged(Number(newArea.height)))
        .onWillScroll((_xOffset: number, yOffset: number, _state: ScrollState, source: ScrollSource) => {
          if (yOffset < 0 && source !== ScrollSource.SCROLLER && source !== ScrollSource.SCROLLER_ANIMATION) {
            this.followLatest = false;
            this.scrollForNewMessage = false;
          }
        })
        .onReachEnd(() => {
          this.followLatest = true;
          this.unreadMessages = 0;
        })
        .onScroll(() => this.recordScrollOffset(this.chatScroller.currentOffset().yOffset))

      if (this.unreadMessages > 0 || this.promptSuggestions.length > 0) {
        Button(this.promptSuggestions.length > 0 ? `查看 ${this.promptSuggestions.length} 条输入建议` :
          `查看 ${this.unreadMessages} 条新消息`).width('100%').constraintSize({ minHeight: 48 })
          .fontSize(this.palette.metaSize).fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft)
          .onClick(() => this.viewLatest())
      }
      if (this.cacheNotice.length > 0 && this.cacheNotice !== '对话已保存到本机，可在历史会话离线回看。') {
        Text(this.cacheNotice).fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
          .padding({ left: 20, right: 20, top: 8, bottom: 8 }).backgroundColor(this.palette.accentSoft)
      }
      if (this.deletionBusy) {
        Text('正在删除会话，完成后可继续发送。').fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
          .padding({ left: 18, right: 18, top: 6, bottom: 4 })
      }
      if (this.selectedModelBlocked()) {
        Column({ space: 4 }) {
          Text(this.selectedModelReason()).fontSize(this.palette.metaSize).fontColor(this.palette.danger).width('100%').wordBreak(WordBreak.BREAK_WORD)
          Button('选择可用模型').constraintSize({ minHeight: 48 }).fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft)
            .onClick(() => this.showModelOptions())
        }.width('100%').padding({ left: 20, right: 20, top: 8, bottom: 8 })
      }
      if (this.inputLength(this.prompt) > 8000) {
        Text(`当前 ${this.inputLength(this.prompt)} 字，超过 8000 字上限，请精简后发送。原文仍保留在输入框中。`)
          .fontSize(this.palette.metaSize).fontColor(this.palette.danger).width('100%')
          .padding({ left: 18, right: 18, top: 6, bottom: 6 })
      }
      Row({ space: 8 }) {
        if (this.capturePending() || this.speechPending()) {
          Button({ type: ButtonType.Normal }) {
            AppIcon({ name: 'stop', iconSize: 21, color: this.palette.accent })
          }.width(44).height(44).backgroundColor(this.palette.field).borderRadius(22)
            .accessibilityText(this.speechPending() ? '停止播报' : '取消语音').onClick(() => this.cancelVoice())
        } else {
          Button({ type: ButtonType.Normal }) {
            if (this.voiceProbeBusy) { LoadingProgress().width(20).height(20).color(this.palette.accent) }
            else { AppIcon({ name: 'microphone', iconSize: 21, color: this.palette.accent }) }
          }.width(44).height(44).backgroundColor(this.palette.field).borderRadius(22)
            .accessibilityText('开始语音输入，识别后可编辑，不自动发送')
            .enabled(this.voiceActive && !this.voiceProbeBusy && !this.loading && !this.deletionBusy && this.decisionId.length === 0)
            .onClick(() => this.startVoice())
        }
        Row({ space: 2 }) {
          TextArea({ text: this.prompt, placeholder: '描述你的目标或安排…' })
            .layoutWeight(1).fontSize(this.palette.bodySize)
            .height(this.composerExpanded ? Math.max(72, Math.min(144, this.availableHeight * 0.24)) : 44)
            .accessibilityText('输入目标或安排').enabled(!this.sessionLoading)
            .fontColor(this.palette.ink).placeholderColor(this.palette.muted)
            .backgroundColor(Color.Transparent).borderRadius(20)
            .padding({ left: 12, right: 4, top: 10, bottom: 8 })
            .onChange((value) => this.changePrompt(value))
          if (this.composerExpanded || this.prompt.includes('\n') || this.inputLength(this.prompt) > 80) {
            Button({ type: ButtonType.Normal }) {
              AppIcon({ name: this.composerExpanded ? 'collapse' : 'expand', iconSize: 19, color: this.palette.quiet })
            }.width(44).height(44).backgroundColor(Color.Transparent).borderRadius(22)
              .accessibilityText(this.composerExpanded ? '收起多行编辑，保留全部输入' : '展开多行编辑')
              .onClick(() => this.composerExpanded = !this.composerExpanded)
          }
          Button({ type: ButtonType.Normal }) {
            AppIcon({ name: 'send', iconSize: 21,
              color: this.inputLength(this.prompt) > 0 && this.inputLength(this.prompt) <= 8000 ? this.palette.onAccent : this.palette.muted })
          }.width(44).height(44).accessibilityText('发送')
            .backgroundColor(this.inputLength(this.prompt) > 0 && this.inputLength(this.prompt) <= 8000 ? this.palette.accent : this.palette.field)
            .borderRadius(22)
            .enabled(!this.sessionLoading && !this.switchConfirmOpen && this.adjustingProposalId.length === 0 && !this.draftBlocksSend() && !this.selectedModelBlocked() && !this.capturePending() && !this.loading && !this.deletionBusy && this.decisionId.length === 0 && this.inputLength(this.prompt) > 0 && this.inputLength(this.prompt) <= 8000).onClick(() => this.send())
        }.layoutWeight(1).padding(4).alignItems(VerticalAlign.Bottom)
          .backgroundColor(this.palette.field).borderRadius(26).border({ width: 0.5, color: this.palette.line })
      }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 }).alignItems(VerticalAlign.Bottom)
        .backgroundColor(this.palette.surface)
        .border({ width: { top: 0.5 }, color: this.palette.line })
    }.width('100%').height('100%').alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Start).backgroundColor(this.palette.surface)
      .onAreaChange((_oldArea: Area, newArea: Area) => {
        const height = Number(newArea.height);
        if (height > 0 && height !== this.availableHeight) {
          this.availableHeight = height;
        }
      })
  }
}
