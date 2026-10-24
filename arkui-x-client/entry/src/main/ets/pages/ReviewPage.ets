import { ReviewPeriod, ReviewSnapshot, ReviewTask, ReviewAllocation, ReviewUnknownGap } from '../model/ReviewModels';
import { ReviewController, ReviewState, emptyReviewState } from '../utils/ReviewController';
import { reviewRange, reviewToday, reviewShiftAnchor } from '../utils/ReviewTime';
import { reviewSummary } from '../utils/ReviewSummary';
import { DraftLease, DraftRecord, DraftKey, ReviewNoteDraft, reviewNoteKey } from '../utils/DraftStore';
import { localDrafts } from '../services/LocalDrafts';
import { historyScope } from '../utils/LocalHistoryStore';
import { CampusFlowApi } from '../services/CampusFlowApi';
import { formatPlanDateTime } from '../utils/PlanPresentation';
import { AppTheme } from '../theme/AppTheme';
import { ThemePalette, themePalette } from '../theme/ThemePalette';
import { AppIllustration } from '../components/AppIllustration';
import { FeedbackPanel } from '../components/FeedbackPanel';

@Component
export struct ReviewPage {
  @StorageLink('campusflowThemePalette') private palette: ThemePalette = themePalette('paper-green');
  @Watch('connectionChanged') @Prop baseUrl: string = '';
  @Watch('connectionChanged') @Prop token: string = '';
  @Watch('connectionChanged') @Prop userId: string = '';
  @Watch('connectionChanged') @Prop draftLease: DraftLease | null = null;
  @Watch('connectionChanged') @Prop accountRevision: number = 0;
  @Watch('activeChanged') @Prop active: boolean = false;
  @Watch('initialChanged') @Prop initialPeriod: ReviewPeriod = 'day';
  @Watch('initialChanged') @Prop initialAnchor: string = '';
  @Watch('initialChanged') @Prop entryRevision: number = 0;
  @Watch('backRequested') @Prop backRevision: number = 0;
  @Prop localPendingRecordCount: number = 0;
  onBack: (revision: number) => void = () => {};
  onOpenTask: (id: string, revision: number) => void = () => {};
  onOpenFocus: (id: string, revision: number) => void = () => {};
  onOfferSummary: (text: string, revision: number) => void = () => {};
  @State private state: ReviewState = emptyReviewState();
  @State private dateInput: string = '';
  @State private dateEditorOpen: boolean = false;
  @State private pageMessage: string = '';
  @State private noteText: string = '';
  @State private noteDirty: boolean = false;
  @State private noteBusy: boolean = false;
  @State private noteMessage: string = '';
  @State private savedNotes: DraftRecord[] = [];
  @State private notesOpen: boolean = false;
  @State private deleteNoteId: string = '';
  @State private deleteNoteRevision: number = 0;
  @State private sourceKind: string = '';
  @State private expandedEvidence: string[] = [];
  @State private discardNoteText: string | null = null;
  @State private sourcePage: number = 0;
  @State private factCompleted: boolean = true;
  @State private factUnscheduled: boolean = true;
  @State private factFocus: boolean = true;
  @State private includeNote: boolean = false;
  @State private summaryText: string = '';
  private controller: ReviewController | null = null;
  private alive: boolean = false;
  private binding: string = '';
  private generation: number = 0;
  private queued: boolean = false;
  private appliedInitial: string = '';
  private noteKey: DraftKey | null = null;
  private noteRevision: number = 0;
  private savedText: string = '';
  private selectionRevision: number = 0;
  private pendingInitial: boolean = false;
  private stagedNote: boolean = false;

  aboutToAppear(): void { this.alive = true; this.connectionChanged(); }
  aboutToDisappear(): void {
    // Index keeps this page mounted for ordinary navigation; account teardown must
    // never stage an old note under a replacement account or lease.
    this.alive = false; this.generation++; this.controller?.dispose(); this.controller = null;
  }
  private connectionChanged(): void { this.queueBinding(); }
  private initialChanged(): void { this.queueBinding(); }
  private queueBinding(): void {
    if (!this.alive || this.queued) { return; }
    this.queued = true;
    Promise.resolve().then((): void => { this.queued = false; if (this.alive) { this.bind(); } });
  }
  private bind(): void {
    const leaseKey = this.draftLease === null ? '' : `${this.draftLease.scope}:${this.draftLease.generation}`;
    const binding = `${this.accountRevision}|${this.baseUrl}|${this.token}|${this.userId}|${leaseKey}`;
    if (binding !== this.binding) {
      this.generation++; this.controller?.dispose(); this.binding = binding;
      this.state = emptyReviewState(); this.appliedInitial = ''; this.noteKey = null;
      this.noteText = ''; this.savedText = ''; this.noteRevision = 0; this.noteDirty = false;
      this.noteBusy = false; this.noteMessage = ''; this.savedNotes = []; this.deleteNoteId = ''; this.discardNoteText = null; this.stagedNote = false; this.expandedEvidence = [];
      this.summaryText = ''; this.includeNote = false; this.sourceKind = ''; this.sourcePage = 0;
      const generation = this.generation;
      this.controller = new ReviewController((state: ReviewState): void => {
        if (!this.alive || generation !== this.generation) { return; }
        if (state.snapshot?.snapshot_digest !== this.state.snapshot?.snapshot_digest) { this.sourcePage = 0; this.summaryText = ''; }
        this.state = state;
      });
      this.controller.configure(historyScope(this.baseUrl, this.userId), this.userId, new CampusFlowApi(this.baseUrl, this.token));
    }
    this.controller?.setActive(this.active);
    if (!this.active) { return; }
    const anchor = this.initialAnchor.length > 0 ? this.initialAnchor : reviewToday();
    const signature = `${this.entryRevision}:${this.initialPeriod}:${anchor}`;
    if (signature !== this.appliedInitial) {
      if (this.noteBusy) { this.pendingInitial = true; return; }
      this.selectPeriod(this.initialPeriod, anchor, signature);
    }
    else { this.controller?.refresh(); }
  }
  private activeChanged(): void {
    if (!this.alive) { return; }
    this.controller?.setActive(this.active);
    if (this.active) { this.queueBinding(); }
    else if (this.noteDirty && !this.noteBusy) { this.saveNote(false); }
  }
  private current(generation: number, account: number): boolean {
    const leaseKey = this.draftLease === null ? '' : `${this.draftLease.scope}:${this.draftLease.generation}`;
    return this.alive && this.generation === generation && this.accountRevision === account &&
      this.binding === `${this.accountRevision}|${this.baseUrl}|${this.token}|${this.userId}|${leaseKey}`;
  }
  private usableLease(): DraftLease | null {
    const lease = this.draftLease;
    return lease !== null && lease.scope === historyScope(this.baseUrl, this.userId) && localDrafts.valid(lease) ? lease : null;
  }
  private listNotes(): void {
    const lease = this.usableLease(); this.savedNotes = lease === null ? [] : localDrafts.list(lease, 'review-note');
  }
  private readNote(period: ReviewPeriod, anchor: string): void {
    this.noteKey = reviewNoteKey(period, anchor);
    const lease = this.usableLease(); const record = lease === null ? undefined : localDrafts.read(lease, this.noteKey);
    this.noteText = record === undefined ? '' : (record.payload as ReviewNoteDraft).text;
    this.savedText = this.noteText; this.noteRevision = record?.localRevision ?? 0; this.noteDirty = false; this.stagedNote = false; this.discardNoteText = null;
    this.noteMessage = ''; this.deleteNoteId = ''; this.includeNote = false; this.summaryText = ''; this.listNotes();
  }
  private noteChanged(text: string): void {
    this.noteText = text; this.noteDirty = text !== this.savedText; this.noteMessage = ''; this.summaryText = '';
  }
  private async saveNote(requireActive: boolean = true): Promise<boolean> {
    if (!this.alive || requireActive && !this.active || this.noteBusy) { return false; }
    if (!this.noteDirty) { return true; }
    const lease = this.usableLease(); const key = this.noteKey;
    if (lease === null || key === null) { this.noteMessage = '本机感受暂不可保存，输入仍保留。请先恢复本机草稿访问。'; return false; }
    if (Array.from(this.noteText).length > 500) { this.noteMessage = '感受最多 500 个字符；当前文字仍完整保留，请缩短后保存。'; return false; }
    const current = localDrafts.read(lease, key);
    if ((current?.localRevision ?? 0) !== this.noteRevision) {
      this.noteMessage = '这份感受已有另一版本，当前输入未覆盖它。请先查看已保存感受，再决定保留哪份。'; return false;
    }
    const generation = this.generation; const account = this.accountRevision; const text = this.noteText;
    const range = reviewRange(this.state.period, this.state.anchor);
    if (range === null) { return false; }
    this.noteBusy = true;
    try {
      const payload: ReviewNoteDraft = { period: this.state.period, anchor: range.noteAnchor, timezone: 'Asia/Shanghai', text: text };
      this.noteRevision = localDrafts.stage(lease, key, payload).localRevision; this.stagedNote = true;
      await localDrafts.flush(lease);
      if (!this.current(generation, account) || this.usableLease() !== lease) { return false; }
      this.stagedNote = false; this.savedText = text; this.noteDirty = this.noteText !== text; this.noteMessage = this.noteDirty ? '上一版已保存；新输入尚未保存。' : '已保存到本机，仅你主动选入摘要时才会交给助手。';
      this.listNotes(); return !this.noteDirty;
    } catch {
      if (this.current(generation, account)) { this.noteMessage = '尚未保存到本机，输入仍保留。请重试，或在已保存感受中释放空间。'; }
      return false;
    } finally {
      if (this.current(generation, account)) {
        this.noteBusy = false;
        if (this.pendingInitial && !this.noteDirty) { this.pendingInitial = false; this.queueBinding(); }
      }
    }
  }
  private async selectPeriod(period: ReviewPeriod, anchor: string, initialSignature: string = ''): Promise<void> {
    if (!this.active || !this.alive || this.noteBusy) { return; }
    if (reviewRange(period, anchor) === null) { this.pageMessage = '请输入可查看的完整日期（YYYY-MM-DD）。'; return; }
    const generation = this.generation; const account = this.accountRevision; const selection = ++this.selectionRevision; const entry = this.entryRevision;
    if (!await this.saveNote() || !this.current(generation, account) || !this.active || selection !== this.selectionRevision || entry !== this.entryRevision) { return; }
    if (initialSignature.length > 0) { this.appliedInitial = initialSignature; }
    this.pageMessage = ''; this.dateInput = anchor; this.dateEditorOpen = false; this.sourceKind = ''; this.sourcePage = 0;
    this.readNote(period, anchor);
    this.controller?.select(period, anchor);
  }
  private shiftPeriod(direction: number): void {
    this.selectPeriod(this.state.period, reviewShiftAnchor(this.state.anchor, direction * (this.state.period === 'week' ? 7 : 1)));
  }
  private backRequested(): void { if (this.active) { this.navigate('back'); } }
  private async navigate(kind: string, id: string = ''): Promise<void> {
    if (!this.active || this.noteBusy) { return; }
    const generation = this.generation; const account = this.accountRevision; const summary = this.summaryText;
    const entry = this.entryRevision; const selection = this.selectionRevision;
    if (kind === 'summary' && summary.length === 0) { return; }
    if (!await this.saveNote() || !this.current(generation, account) || !this.active || entry !== this.entryRevision || selection !== this.selectionRevision) { return; }
    if (kind === 'back') { this.onBack(account); }
    else if (kind === 'task' && id.length > 0) { this.onOpenTask(id, account); }
    else if (kind === 'focus') { this.onOpenFocus(id, account); }
    else if (kind === 'summary' && summary === this.summaryText) { this.onOfferSummary(summary, account); }
  }
  private async openSaved(record: DraftRecord): Promise<void> {
    if (!this.active || record.kind !== 'review-note') { return; }
    const note = record.payload as ReviewNoteDraft;
    await this.selectPeriod(note.period, note.anchor);
  }
  private askDeleteNote(record: DraftRecord): void {
    if (!this.active || this.noteBusy) { return; }
    this.deleteNoteId = record.ownerId; this.deleteNoteRevision = record.localRevision;
  }
  private async deleteSavedNote(): Promise<void> {
    const lease = this.usableLease(); const owner = this.deleteNoteId; const revision = this.deleteNoteRevision;
    if (!this.active || this.noteBusy || lease === null || owner.length === 0) { return; }
    const generation = this.generation; const account = this.accountRevision; this.noteBusy = true;
    try {
      const removed = await localDrafts.remove(lease, { kind: 'review-note', ownerId: owner }, revision);
      if (!this.current(generation, account)) { return; }
      this.deleteNoteId = ''; this.listNotes();
      if (!removed) { this.noteMessage = '已保存版本发生变化，未删除。请重新查看后决定。'; return; }
      if (this.noteKey?.ownerId === owner) {
        if (!this.noteDirty) { this.noteText = ''; }
        this.savedText = ''; this.noteRevision = 0; this.noteDirty = this.noteText.length > 0; this.summaryText = '';
      }
      this.noteMessage = '这份已保存感受已移除；当前未保存输入如有更改仍保留。';
    } catch { if (this.current(generation, account)) { this.noteMessage = '删除失败，已保存感受仍保留，请重试。'; } }
    finally { if (this.current(generation, account)) { this.noteBusy = false; } }
  }
  private async discardUnsaved(): Promise<void> {
    const chosen = this.discardNoteText;
    if (!this.active || this.noteBusy || chosen === null || !this.noteDirty) { return; }
    if (chosen !== this.noteText) { this.discardNoteText = null; this.noteMessage = '输入又有变化，未放弃新的文字。请重新决定。'; return; }
    const generation = this.generation; const account = this.accountRevision;
    if (this.stagedNote) {
      const lease = this.usableLease(); const key = this.noteKey; const range = reviewRange(this.state.period, this.state.anchor);
      if (lease === null || key === null || range === null) { this.noteMessage = '本机保存尚未恢复，未放弃这段输入。'; return; }
      if ((localDrafts.read(lease, key)?.localRevision ?? 0) !== this.noteRevision) { this.noteMessage = '本机版本已有变化，请先核对已保存感受。'; return; }
      this.noteBusy = true;
      try {
        this.noteRevision = localDrafts.stage(lease, key, { period: this.state.period, anchor: range.noteAnchor, timezone: 'Asia/Shanghai', text: this.savedText }).localRevision;
        await localDrafts.flush(lease);
        if (!this.current(generation, account)) { return; }
        this.stagedNote = false;
      } catch { if (this.current(generation, account)) { this.noteMessage = '本机更改尚未撤回，输入仍保留；请恢复保存后重试。'; } return; }
      finally { if (this.current(generation, account)) { this.noteBusy = false; } }
    }
    if (!this.current(generation, account) || this.noteText !== chosen) { return; }
    this.noteText = this.savedText; this.noteDirty = false; this.discardNoteText = null; this.summaryText = '';
    this.noteMessage = '已放弃这一版未保存输入，其他草稿不受影响。'; this.listNotes();
  }
  private toggleEvidence(id: string): void {
    this.expandedEvidence = this.expandedEvidence.includes(id) ? this.expandedEvidence.filter((value: string): boolean => value !== id) : this.expandedEvidence.concat([id]);
  }
  private previewSummary(): void {
    const snapshot = this.state.snapshot;
    if (!this.active || snapshot === null || this.noteBusy) { return; }
    this.summaryText = reviewSummary(snapshot, { completed: this.factCompleted, unscheduled: this.factUnscheduled, focus: this.factFocus }, this.includeNote ? this.noteText : '');
    this.pageMessage = this.summaryText.length === 0 ? '先选择至少一项事实，或主动选入你的感受。' : '';
  }
  private factChanged(kind: string, selected: boolean): void {
    if (kind === 'completed') { this.factCompleted = selected; }
    else if (kind === 'unscheduled') { this.factUnscheduled = selected; }
    else if (kind === 'focus') { this.factFocus = selected; }
    else { this.includeNote = selected; }
    this.summaryText = '';
  }
  private duration(ms: number): string {
    if (ms > 0 && ms < 1000) { return '不足 1 秒'; }
    const seconds = Math.floor(ms / 1000); const minutes = Math.floor(seconds / 60);
    return minutes >= 60 ? `${Math.floor(minutes / 60)} 小时 ${minutes % 60} 分钟` : `${minutes} 分 ${seconds % 60} 秒`;
  }
  private readingTime(): string {
    const value = formatPlanDateTime(this.state.snapshot?.as_of ?? null);
    if (!/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$/.test(value)) { return value; }
    return `${value.slice(0, 4)}年${Number(value.slice(5, 7))}月${Number(value.slice(8, 10))}日 ${value.slice(11)}（校园时间）`;
  }
  private rangeLabel(): string {
    const range = reviewRange(this.state.period, this.state.anchor);
    return range === null ? this.state.anchor : this.state.period === 'day' ? range.noteAnchor : `${range.noteAnchor} — ${reviewShiftAnchor(range.noteAnchor, 6)}`;
  }
  private toggleSource(kind: string): void { this.sourceKind = this.sourceKind === kind ? '' : kind; this.sourcePage = 0; }
  private sourceCount(): number {
    const snapshot = this.state.snapshot; if (snapshot === null) { return 0; }
    if (this.sourceKind === 'completed') { return snapshot.completed_tasks.length; }
    if (this.sourceKind === 'unscheduled') { return snapshot.unscheduled_tasks.length; }
    if (this.sourceKind === 'unattributed') { return snapshot.unattributed_completed_tasks.length; }
    if (this.sourceKind === 'focus') { return snapshot.focus_intervals.length; }
    return this.sourceKind === 'gaps' ? snapshot.unknown_gaps.length : 0;
  }
  private visibleTasks(): ReviewTask[] {
    const snapshot = this.state.snapshot; if (snapshot === null) { return []; }
    const rows = this.sourceKind === 'completed' ? snapshot.completed_tasks : this.sourceKind === 'unscheduled' ? snapshot.unscheduled_tasks : this.sourceKind === 'unattributed' ? snapshot.unattributed_completed_tasks : [];
    return rows.slice(this.sourcePage * 8, this.sourcePage * 8 + 8);
  }
  private visibleIntervals(): ReviewAllocation[] { return this.sourceKind === 'focus' ? (this.state.snapshot?.focus_intervals ?? []).slice(this.sourcePage * 8, this.sourcePage * 8 + 8) : []; }
  private visibleGaps(): ReviewUnknownGap[] { return this.sourceKind === 'gaps' ? (this.state.snapshot?.unknown_gaps ?? []).slice(this.sourcePage * 8, this.sourcePage * 8 + 8) : []; }
  private evidenceLabel(task: ReviewTask): string {
    return task.completion_evidence === 'operation_receipt' ? '有完成回执' : task.completion_evidence === 'current_task_time' ? '按任务当前完成时间 · 无旧回执' : task.completion_evidence === 'unattributed' ? '缺少完成时间 · 未计入本期' : '当前尚未安排开始时间';
  }

  @Builder
  private Fact(value: string, label: string, note: string) {
    Column({ space: 4 }) {
      Text(value).fontSize('30fp').fontWeight(FontWeight.Medium).fontColor(this.palette.ink).width('100%')
      Text(label).fontSize(this.palette.bodySize).fontColor(this.palette.ink).width('100%')
      Text(note).fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
    }.width('100%').alignItems(HorizontalAlign.Start).padding(16).backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
  }
  @Builder
  private SourceToggle(label: string, kind: string, count: number) {
    Button(`${label} · ${count} ${this.sourceKind === kind ? '收起' : '查看'}`).width('100%').constraintSize({ minHeight: 48 }).fontColor(this.palette.accent)
      .backgroundColor(this.palette.surface).onClick(() => this.toggleSource(kind))
  }
  @Builder
  private Sources(snapshot: ReviewSnapshot) {
    Column({ space: 10 }) {
      Text('每个数字，都有来处').fontSize(this.palette.sectionTitle).fontColor(this.palette.ink).width('100%')
      this.SourceToggle('本期完成事项', 'completed', snapshot.completed_tasks.length)
      this.SourceToggle('当前待安排', 'unscheduled', snapshot.unscheduled_tasks.length)
      this.SourceToggle('完成时间未记录', 'unattributed', snapshot.unattributed_completed_tasks.length)
      this.SourceToggle('已确认专注片段', 'focus', snapshot.focus_intervals.length)
      this.SourceToggle('本期开始的待核对区间', 'gaps', snapshot.unknown_gaps.length)
      ForEach(this.visibleTasks(), (task: ReviewTask) => {
        Column({ space: 8 }) {
          Text(task.title).fontSize(this.palette.bodySize).fontColor(this.palette.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
          Text(`${this.evidenceLabel(task)}${task.completed_at === null ? '' : `\n完成标注 ${formatPlanDateTime(task.completed_at)}`}`).fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
          Button(task.status === 'pending' ? '查看任务，选择下一步' : '查看当前任务').constraintSize({ minHeight: 48 }).width('100%').enabled(!this.noteBusy).onClick(() => this.navigate('task', task.task_id))
        }.width('100%').padding(16).alignItems(HorizontalAlign.Start).backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
      }, (task: ReviewTask) => `${task.task_id}:${task.task_version}`)
      ForEach(this.visibleIntervals(), (row: ReviewAllocation) => {
        Column({ space: 8 }) {
          Text(row.task_missing ? '原任务已删除 · 保留的计时片段' : row.task_title ?? '任务名称未读取').fontSize(this.palette.bodySize).fontColor(this.palette.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
          Text(`本期记录 ${this.duration(row.allocated_elapsed_ms)}\n${formatPlanDateTime(row.interval.started_at)} 至 ${formatPlanDateTime(row.interval.ended_at)}`).fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
          Button(this.expandedEvidence.includes(row.interval.interval_id) ? '收起核对依据' : '核对依据').width('100%').constraintSize({ minHeight: 48 }).onClick(() => this.toggleEvidence(row.interval.interval_id))
          if (this.expandedEvidence.includes(row.interval.interval_id)) {
            Text(`本期分配 ${row.allocated_elapsed_ms} 毫秒 · 原段 ${row.interval.elapsed_ms} 毫秒\n${row.interval.started_at}\n至 ${row.interval.ended_at}\n片段 ${row.interval.interval_id}\n记录 ${row.record_id}\n本期交集：原段起点后 ${row.clip_from_us}–${row.clip_to_us} 微秒；原跨度 ${row.span_us} 微秒。`).fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
          }
          Button('查看这条专注记录').width('100%').constraintSize({ minHeight: 48 }).enabled(!this.noteBusy).onClick(() => this.navigate('focus', row.record_id))
        }.width('100%').padding(16).alignItems(HorizontalAlign.Start).backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
      }, (row: ReviewAllocation) => `${row.record_id}:${row.interval.interval_id}`)
      ForEach(this.visibleGaps(), (row: ReviewUnknownGap) => {
        Column({ space: 8 }) {
          Text(row.task_missing ? '原任务已删除 · 待核对区间' : row.task_title ?? '任务名称未读取').fontSize(this.palette.bodySize).fontColor(this.palette.ink).width('100%')
          Text(`开始标注 ${row.gap.observed_start_at}\n结束标注 ${row.gap.observed_end_at ?? '未知'}\n不补算时长；按开始标注归入本期。\n区间 ${row.gap.gap_id}`).fontSize(this.palette.metaSize).fontColor(this.palette.warning).width('100%').wordBreak(WordBreak.BREAK_WORD)
          Button('查看待核对记录').width('100%').constraintSize({ minHeight: 48 }).enabled(!this.noteBusy).onClick(() => this.navigate('focus', row.record_id))
        }.width('100%').padding(16).alignItems(HorizontalAlign.Start).backgroundColor(this.palette.warningSoft).borderRadius(this.palette.cardRadius)
      }, (row: ReviewUnknownGap) => `${row.record_id}:${row.gap.gap_id}`)
      if (this.sourceKind.length > 0 && this.sourceCount() === 0) { Text('这一组暂时没有可核对的记录。').fontSize(this.palette.bodySize).fontColor(this.palette.secondary).width('100%') }
      if (this.sourceCount() > 8) {
        Text(`明细 ${this.sourcePage + 1}/${Math.ceil(this.sourceCount() / 8)} 页 · 共 ${this.sourceCount()} 项`).fontSize(this.palette.metaSize).fontColor(this.palette.secondary)
        Row({ space: 8 }) {
          Button('上一页').layoutWeight(1).constraintSize({ minHeight: 48 }).enabled(this.sourcePage > 0).onClick(() => this.sourcePage--)
          Button('下一页').layoutWeight(1).constraintSize({ minHeight: 48 }).enabled((this.sourcePage + 1) * 8 < this.sourceCount()).onClick(() => this.sourcePage++)
        }.width('100%')
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
  @Builder
  private Notes() {
    Column({ space: 12 }) {
      Text('留一句自己的感受').fontSize(this.palette.sectionTitle).fontColor(this.palette.ink).width('100%')
      Text('可选，仅保存在本机。切换日期或返回前会先保存；退出账号或清除本机草稿会一并移除。').fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
      TextArea({ text: this.noteText, placeholder: '比如：下午留一点余量，会从容一些。' }).constraintSize({ minHeight: 120 }).width('100%').fontSize(this.palette.bodySize)
        .backgroundColor(this.palette.surface).onChange((text: string) => this.noteChanged(text))
      Text(`${Array.from(this.noteText).length}/500${this.noteDirty ? ' · 尚未保存' : ''}`).fontSize(this.palette.metaSize).fontColor(this.palette.secondary)
      if (this.noteMessage.length > 0) { Text(this.noteMessage).fontSize(this.palette.bodySize).fontColor(this.noteDirty ? this.palette.warning : this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD) }
      Button(this.noteBusy ? '正在保存…' : '保存到本机').width('100%').constraintSize({ minHeight: 48 }).enabled(this.active && !this.noteBusy).onClick(() => this.saveNote())
      if (this.noteDirty) {
        Button('放弃这段未保存输入').width('100%').constraintSize({ minHeight: 48 }).fontColor(this.palette.secondary).backgroundColor(Color.Transparent).enabled(!this.noteBusy).onClick(() => this.discardNoteText = this.noteText)
      }
      if (this.discardNoteText !== null) {
        Text('确认放弃当前这一版未保存文字？已保存感受和其他草稿仍保留。').fontSize(this.palette.bodySize).fontColor(this.palette.warning).width('100%')
        Button('继续保留输入').width('100%').constraintSize({ minHeight: 48 }).onClick(() => this.discardNoteText = null)
        Button('确认放弃这版输入').width('100%').constraintSize({ minHeight: 48 }).enabled(!this.noteBusy).onClick(() => this.discardUnsaved())
      }
      Button(this.notesOpen ? '收起已保存感受' : `管理已保存感受 · ${this.savedNotes.length}`).width('100%').constraintSize({ minHeight: 48 }).backgroundColor(Color.Transparent).fontColor(this.palette.accent)
        .onClick(() => { this.listNotes(); this.notesOpen = !this.notesOpen; })
      if (this.notesOpen) {
        ForEach(this.savedNotes, (record: DraftRecord) => {
          Column({ space: 6 }) {
            Text(`${(record.payload as ReviewNoteDraft).period === 'week' ? '一周 · ' : '一天 · '}${(record.payload as ReviewNoteDraft).anchor}`).fontSize(this.palette.bodySize).fontColor(this.palette.ink).width('100%')
            Text((record.payload as ReviewNoteDraft).text || '已保存的空白感受').fontSize(this.palette.bodySize).fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
            Row({ space: 8 }) {
              Button('打开').layoutWeight(1).constraintSize({ minHeight: 48 }).enabled(!this.noteBusy).onClick(() => this.openSaved(record))
              Button('删除').layoutWeight(1).constraintSize({ minHeight: 48 }).fontColor(this.palette.danger).backgroundColor(this.palette.dangerSoft).enabled(!this.noteBusy).onClick(() => this.askDeleteNote(record))
            }.width('100%')
          }.width('100%').padding(12).backgroundColor(this.palette.surface).borderRadius(this.palette.controlRadius)
        }, (record: DraftRecord) => `${record.ownerId}:${record.localRevision}`)
        if (this.savedNotes.length === 0) { Text('尚未保存感受。留白也可以。').fontSize(this.palette.bodySize).fontColor(this.palette.secondary) }
      }
      if (this.deleteNoteId.length > 0) {
        Text('只删除选中的已保存版本；尚未保存的新输入会保留。').fontSize(this.palette.bodySize).fontColor(this.palette.warning).width('100%')
        Button('保留这份感受').width('100%').constraintSize({ minHeight: 48 }).onClick(() => this.deleteNoteId = '')
        Button('确认删除此版本').width('100%').constraintSize({ minHeight: 48 }).enabled(!this.noteBusy).onClick(() => this.deleteSavedNote())
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
  @Builder
  private Summary() {
    Column({ space: 12 }) {
      Text('想一想下一步').fontSize(this.palette.sectionTitle).fontColor(this.palette.ink).width('100%')
      Text('选好事实，先预览，再放入助手输入框。不会自动发送，也不会自动调整安排。').fontSize(this.palette.bodySize).fontColor(this.palette.secondary).width('100%')
      Row({ space: 8 }) { Checkbox({ name: 'completed' }).select(this.factCompleted).onChange((value: boolean) => this.factChanged('completed', value)); Text('本期完成事项数').layoutWeight(1).fontSize(this.palette.bodySize) }.width('100%').constraintSize({ minHeight: 48 })
      Row({ space: 8 }) { Checkbox({ name: 'unscheduled' }).select(this.factUnscheduled).onChange((value: boolean) => this.factChanged('unscheduled', value)); Text('当前待安排事项数').layoutWeight(1).fontSize(this.palette.bodySize) }.width('100%').constraintSize({ minHeight: 48 })
      Row({ space: 8 }) { Checkbox({ name: 'focus' }).select(this.factFocus).onChange((value: boolean) => this.factChanged('focus', value)); Text('已确认计时与待核对区间').layoutWeight(1).fontSize(this.palette.bodySize) }.width('100%').constraintSize({ minHeight: 48 })
      Row({ space: 8 }) { Checkbox({ name: 'note' }).select(this.includeNote).onChange((value: boolean) => this.factChanged('note', value)); Text('另外加入我写的感受').layoutWeight(1).fontSize(this.palette.bodySize) }.width('100%').constraintSize({ minHeight: 48 })
      Button('预览要交给助手的内容').width('100%').constraintSize({ minHeight: 48 }).enabled(this.state.snapshot !== null && !this.noteBusy).onClick(() => this.previewSummary())
      if (this.summaryText.length > 0) {
        Text(this.summaryText).width('100%').fontSize(this.palette.bodySize).fontColor(this.palette.ink).wordBreak(WordBreak.BREAK_WORD).copyOption(CopyOptions.LocalDevice)
        Button('放入助手输入框').width('100%').constraintSize({ minHeight: 48 }).fontColor(this.palette.onAccent).backgroundColor(this.palette.accent).enabled(!this.noteBusy).onClick(() => this.navigate('summary'))
      }
    }.width('100%').padding(16).alignItems(HorizontalAlign.Start).backgroundColor(this.palette.accentSoft).borderRadius(this.palette.cardRadius)
  }
  build() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Button('返回').constraintSize({ minHeight: 48, minWidth: 64 }).fontColor(this.palette.accent).backgroundColor(Color.Transparent).enabled(!this.noteBusy).onClick(() => this.navigate('back'))
        Text('回看').fontSize(this.palette.pageTitle).fontColor(this.palette.ink).layoutWeight(1)
        Button('刷新').constraintSize({ minHeight: 48 }).fontColor(this.palette.accent).backgroundColor(Color.Transparent).enabled(this.active && this.state.phase !== 'loading').onClick(() => this.controller?.refresh())
      }.width('100%')
      Scroll() {
        Column({ space: 16 }) {
          Text('看看已经留下的记录，再想一个小步。').fontSize(this.palette.bodySize).fontColor(this.palette.secondary).width('100%')
          Row({ space: 8 }) {
            Button('一天').layoutWeight(1).constraintSize({ minHeight: 48 }).backgroundColor(this.state.period === 'day' ? this.palette.accentSoft : this.palette.surface).fontColor(this.palette.accent).enabled(!this.noteBusy).onClick(() => this.selectPeriod('day', this.state.anchor))
            Button('一周').layoutWeight(1).constraintSize({ minHeight: 48 }).backgroundColor(this.state.period === 'week' ? this.palette.accentSoft : this.palette.surface).fontColor(this.palette.accent).enabled(!this.noteBusy).onClick(() => this.selectPeriod('week', this.state.anchor))
          }.width('100%')
          Text(this.rangeLabel()).fontSize(this.palette.sectionTitle).fontColor(this.palette.ink).width('100%')
          Row({ space: 8 }) {
            Button('上一期').layoutWeight(1).constraintSize({ minHeight: 48 }).enabled(!this.noteBusy).onClick(() => this.shiftPeriod(-1))
            Button('下一期').layoutWeight(1).constraintSize({ minHeight: 48 }).enabled(!this.noteBusy).onClick(() => this.shiftPeriod(1))
          }.width('100%')
          Button(this.dateEditorOpen ? '收起日期输入' : '选择其他日期').width('100%').constraintSize({ minHeight: 48 }).fontColor(this.palette.accent).backgroundColor(Color.Transparent).onClick(() => this.dateEditorOpen = !this.dateEditorOpen)
          if (this.dateEditorOpen) {
            TextInput({ text: this.dateInput, placeholder: 'YYYY-MM-DD' }).width('100%').fontSize(this.palette.bodySize).constraintSize({ minHeight: 48 }).onChange((text: string) => this.dateInput = text)
            Button('查看这个日期').width('100%').constraintSize({ minHeight: 48 }).enabled(!this.noteBusy).onClick(() => this.selectPeriod(this.state.period, this.dateInput.trim()))
          }
          Text('校园时间 UTC+08:00；一天从 00:00 起，一周从周一开始。').fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
          if (this.pageMessage.length > 0) { Text(this.pageMessage).fontSize(this.palette.bodySize).fontColor(this.palette.warning).width('100%') }
          if (this.state.phase === 'loading') { FeedbackPanel({ kind: 'loading', title: '正在核对这段时间', message: '只读取任务与计时记录，不会调整你的安排。' }) }
          if (this.state.phase === 'error' || this.state.phase === 'stale') { FeedbackPanel({ kind: this.state.phase === 'stale' ? 'warning' : 'error', title: this.state.phase === 'stale' ? '目前显示上次读取的资料' : '暂时无法读取回看', message: this.state.message, actionLabel: '重新读取', onAction: () => this.controller?.refresh() }) }
          if (this.state.snapshot !== null) {
            Text(`资料读取于 ${this.readingTime()}`).fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
            Button(this.expandedEvidence.includes('snapshot') ? '收起资料核对信息' : '资料核对信息').constraintSize({ minHeight: 48 }).width('100%').fontColor(this.palette.accent).backgroundColor(Color.Transparent).onClick(() => this.toggleEvidence('snapshot'))
            if (this.expandedEvidence.includes('snapshot')) {
              Text(`读取标注 ${this.state.snapshot.as_of}\n范围 ${this.state.snapshot.period_start} 至 ${this.state.snapshot.period_end}（不含结束时刻）\n快照标识 ${this.state.snapshot.snapshot_digest}`).fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
            }
            this.Fact(`${this.state.snapshot.totals.current_completed_count} 项`, '本期完成，当前仍完成', '按已记录的完成时间归期；恢复未完成和删除后，刷新会重新计算。')
            this.Fact(this.duration(this.state.snapshot.totals.confirmed_elapsed_ms), '已确认专注记录时长', '只计已同步的确认片段，不等于有效学习时长。')
            this.Fact(`${this.state.snapshot.totals.current_unscheduled_count} 项`, '当前待安排', '当前尚未安排开始时间的待办，不是历史期末状态。')
            if (this.state.snapshot.completed_tasks.length === 0 && this.state.snapshot.focus_intervals.length === 0) {
              AppIllustration({ source: $r('app.media.xj_review_empty'), imageWidth: 120, imageHeight: 80, fallbackIcon: 'history' })
              Text('这段时间还没有可汇总的完成或专注记录。没有记录，不代表没有学习。').fontSize(this.palette.bodySize).fontColor(this.palette.secondary).width('100%')
            }
            this.Sources(this.state.snapshot)
          }
          if (this.localPendingRecordCount > 0) {
            Column({ space: 8 }) {
              Text(`本机还有 ${this.localPendingRecordCount} 条记录待同步`).fontSize(this.palette.bodySize).fontColor(this.palette.warning).width('100%')
              Text('包括各个日期的本机记录，未加入上方本期时长。').fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
              Button('查看本机专注记录').width('100%').constraintSize({ minHeight: 48 }).enabled(!this.noteBusy).onClick(() => this.navigate('focus'))
            }.width('100%').padding(16).backgroundColor(this.palette.warningSoft).borderRadius(this.palette.cardRadius)
          }
          this.Notes()
          if (this.state.snapshot !== null) { this.Summary() }
        }.width('100%').alignItems(HorizontalAlign.Start)
      }.width('100%').layoutWeight(1)
    }.width('100%').height('100%').padding({ left: 20, right: 20, bottom: 16 }).backgroundColor(this.palette.bg)
  }
}
