import { TimetableEntry, ScheduleImportRow } from '../model/ApiModels';
import { CampusFlowRequestError } from '../utils/AgentFeedback';
import { CampusFlowApi } from '../services/CampusFlowApi';
import { TimetableMaintenance, TimetableMaintenanceState, TimetableDraftSnapshot, timetableOperationId } from '../utils/TimetableMaintenance';
import { TimetableFieldErrors, TimetableIssue, normalizeTimetableEntry, validateTimetableEntry, validateTimetableList, expandWeeklyEntry } from '../utils/OnboardingTimetable';
import { DraftLease, DraftKey, DraftRecord, DraftSaveState, TimetableDraft, TimetableSubmission } from '../utils/DraftStore';
import { localDrafts } from '../services/LocalDrafts';
import { shanghaiDate } from '../utils/DailyAgenda';
import { ImportRowChoice, parseImportReview, assembleSelectedImport } from '../utils/TimetableImportReview';
import { TimetableEntryEditor } from '../components/TimetableEntryEditor';
import { TimetableImportPanel } from '../components/TimetableImportPanel';
import { AppTheme } from '../theme/AppTheme';
import { EvidencePanel } from '../components/EvidencePanel';
import { AppIcon } from '../components/AppIcon';
import { FeedbackPanel } from '../components/FeedbackPanel';

interface CourseRow { index: number; entry: TimetableEntry; }

@Component
export struct TimetablePage {
  @Watch('editorConnectionChanged') @Prop baseUrl: string;
  @Watch('editorConnectionChanged') @Prop token: string;
  @Watch('draftLeaseChanged') @Prop draftLease: DraftLease | null = null;
  @Watch('activityChanged') @Prop active: boolean = true;
  onBack: () => void = () => {};
  onTimetableChanged: () => void = () => {};
  onOpenPlan: () => void = () => {};
  @State private view: TimetableMaintenanceState = { phase: 'idle', entries: [], revision: '', dirty: false,
    warnings: [], message: '', notice: '' };
  @State private entries: TimetableEntry[] = [];
  @State private editor: TimetableEntry = { date: '', title: '', start_time: '', end_time: '', location: '', teacher: '' };
  @State private fieldErrors: TimetableFieldErrors = { date: '', title: '', start_time: '', end_time: '', location: '', teacher: '' };
  @State private source: string = 'manual';
  @State private editorOpen: boolean = false;
  @State private editorDirty: boolean = false;
  @State private editingIndex: number = -1;
  @State private repeatWeeks: number = 1;
  @State private pageIndex: number = 0;
  @State private draftRevision: number = 0;
  @State private pendingDelete: number = -1;
  @State private scheduleUrl: string = '';
  @State private importRows: ScheduleImportRow[] = [];
  @State private importChoices: ImportRowChoice[] = [];
  @State private importGeneration: number = 0;
  @State private importWarnings: TimetableIssue[] = [];
  @State private sourceWarnings: TimetableIssue[] = [];
  @State private warnings: TimetableIssue[] = [];
  @State private showAllWarnings: boolean = false;
  @State private loading: boolean = false;
  @State private busyLabel: string = '';
  @State private message: string = '';
  @State private notice: string = '';
  @State private reviewOpen: boolean = false;
  @State private clearRequested: boolean = false;
  @State private reloadRequested: boolean = false;
  @State private recoverableDraft: DraftRecord | null = null;
  @State private draftMessage: string = '';
  @State private focusRevision: number = 0;
  @State private editorGeneration: number = 0;
  private lastEntry: TimetableEntry | null = null;
  private lastRepeatWeeks: number = 1;
  @State private latestExpanded: boolean = false;
  @State private latestPage: number = 0;
  private anchorDate: string = shanghaiDate(Date.now());
  private draftKey: DraftKey = { kind: 'timetable', ownerId: 'main' };
  private boundLease: DraftLease | null = null;
  private draftUnsubscribe: (() => void) | null = null;
  private localRevision: number = 0;
  private trackedOperationId: string = '';
  private controllerGeneration: number = 0;
  private controller: TimetableMaintenance | null = null;
  private pageActive: boolean = false;
  private requestRevision: number = 0;
  private previewBusy: boolean = false;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.pageActive = true;
    this.bindDraftLease();
    if (this.controller === null) {
      const generation = ++this.controllerGeneration;
      this.resetEditor();
      this.controller = new TimetableMaintenance(new CampusFlowApi(this.baseUrl, this.token),
        (state: TimetableMaintenanceState) => {
          if (!this.pageActive || (this.boundLease !== null && !localDrafts.valid(this.boundLease)) || generation !== this.controllerGeneration) { return; }
          if (JSON.stringify(this.entries) !== JSON.stringify(state.entries)) {
            this.entries = state.entries;
            this.draftRevision++;
            this.pendingDelete = -1;
            this.pageIndex = Math.max(0, Math.min(this.pageIndex, Math.ceil(this.entries.length / 10) - 1));
          }
          if (state.latestRevision !== this.view.latestRevision) { this.latestPage = 0; }
          this.view = state;
          this.warnings = state.warnings;
          this.loading = this.previewBusy || ['loading', 'saving', 'checking'].includes(state.phase);
          if (state.phase === 'saved') {
            this.reviewOpen = false; this.notice = ''; this.message = ''; this.clearAppliedDraft();
          } else if (this.trackedOperationId.length > 0 && this.controller?.exportDraft()?.operation === null &&
            ['stale', 'error'].includes(state.phase)) { this.releaseKnownOperation(); }
          if (!state.dirty) { this.sourceWarnings = []; }
        }, () => { if (this.pageActive && this.active) { this.onTimetableChanged(); } }, timetableOperationId,
        (draft: TimetableDraftSnapshot) => this.persistSubmission(draft));
    }
    this.controller.setActive(this.active);
  }

  aboutToDisappear(): void {
    this.flushDraft();
    this.draftUnsubscribe?.(); this.draftUnsubscribe = null;
    this.pageActive = false;
    this.controllerGeneration++;
    this.requestRevision++;
    this.scheduleUrl = '';
    this.controller?.dispose();
    this.controller = null;
  }

  private activityChanged(): void {
    if (!this.active) {
      this.flushDraft();
      this.requestRevision++;
      this.previewBusy = false;
      this.scheduleUrl = '';
    }
    this.controller?.setActive(this.active);
  }

  private draftLeaseChanged(): void {
    if (!this.pageActive) { return; }
    const lease = this.draftLease;
    if (this.boundLease !== null && (lease === null || lease.scope !== this.boundLease.scope || lease.generation !== this.boundLease.generation)) {
      this.controllerGeneration++; this.requestRevision++; this.controller?.dispose(); this.controller = null;
      this.entries = []; this.editorDirty = false; this.editingIndex = -1; this.sourceWarnings = [];
      this.importRows = []; this.importChoices = []; this.importGeneration++; this.scheduleUrl = ''; this.localRevision = 0; this.trackedOperationId = '';
      this.reviewOpen = false; this.lastEntry = null; this.lastRepeatWeeks = 1; this.anchorDate = shanghaiDate(Date.now());
      this.resetEditor(); this.editorOpen = false; this.latestExpanded = false; this.latestPage = 0;
      this.view = { phase: 'idle', entries: [], revision: '', dirty: false, warnings: [], message: '', notice: '' };
      this.message = ''; this.notice = ''; this.draftMessage = ''; this.loading = false;
    }
    if (lease === null || !localDrafts.valid(lease)) {
      this.draftUnsubscribe?.(); this.draftUnsubscribe = null; this.boundLease = null; this.recoverableDraft = null; return;
    }
    this.aboutToAppear();
  }
  private observeDraftState(): void {
    this.draftUnsubscribe?.();
    this.draftUnsubscribe = localDrafts.subscribe((state: DraftSaveState) => {
      if (!this.pageActive || this.boundLease === null || state.scope !== this.boundLease.scope ||
        state.generation !== this.boundLease.generation) { return; }
      if (state.phase === 'error' || state.phase === 'unavailable') { this.draftMessage = state.message; }
      else if (state.phase === 'saved') { this.draftMessage = ''; }
    });
  }
  private bindDraftLease(): void {
    const lease = this.draftLease;
    if (lease === null || !localDrafts.valid(lease)) { this.boundLease = null; this.recoverableDraft = null; return; }
    if (this.boundLease?.scope === lease.scope && this.boundLease?.generation === lease.generation) { this.observeDraftState(); return; }
    this.boundLease = lease; this.observeDraftState();
    this.recoverableDraft = localDrafts.read(lease, this.draftKey) ?? null;
    this.localRevision = this.recoverableDraft?.localRevision ?? 0;
  }
  private draftPayload(snapshot: TimetableDraftSnapshot): TimetableDraft {
    const submission: TimetableSubmission | null = snapshot.operation === null ? null : { operationId: snapshot.operation.id,
      expectedRevision: snapshot.operation.revision, entries: snapshot.operation.entries, confirmClear: snapshot.operation.confirmClear };
    return { baselineEntries: snapshot.baselineEntries, expectedRevision: snapshot.expectedRevision,
      draftEntries: snapshot.draftEntries, editor: this.editor, editorOpen: this.editorOpen,
      editorDirty: this.editorDirty, editingIndex: this.editingIndex, repeatWeeks: this.repeatWeeks,
      sourceWarnings: this.sourceWarnings, anchorDate: this.anchorDate, timezone: 'Asia/Shanghai',
      submission: submission };
  }
  private stageDraft(): void {
    const lease = this.boundLease;
    if (!this.pageActive || this.recoverableDraft !== null || lease === null || !localDrafts.valid(lease)) { return; }
    const snapshot = this.controller?.exportDraft();
    if (snapshot === null || snapshot === undefined || snapshot.operation !== null || this.trackedOperationId.length > 0) { return; }
    if (!this.view.dirty && !this.editorDirty && this.editingIndex < 0) { return; }
    try { this.localRevision = localDrafts.stage(lease, this.draftKey, this.draftPayload(snapshot)).localRevision; this.draftMessage = ''; }
    catch { this.draftMessage = '本机草稿暂未保存。内容仍在本页，请重试保存草稿。'; }
  }
  private async flushDraft(): Promise<void> {
    if (this.trackedOperationId.length > 0 && this.view.phase === 'saved') { await this.clearAppliedDraft(); return; }
    if (this.trackedOperationId.length > 0 && this.controller?.exportDraft()?.operation === null &&
      ['stale', 'error'].includes(this.view.phase)) { await this.releaseKnownOperation(); }
    this.stageDraft(); const lease = this.boundLease;
    if (lease === null || !localDrafts.valid(lease)) { return; }
    try { await localDrafts.flush(lease); }
    catch { if (this.pageActive && this.boundLease === lease) { this.draftMessage = '本机草稿保存失败，请保留本页并重试。'; } }
  }
  private async persistSubmission(snapshot: TimetableDraftSnapshot): Promise<void> {
    const lease = this.boundLease; const operation = snapshot.operation;
    if (lease === null || !localDrafts.valid(lease) || operation === null) { throw new Error('draft storage unavailable'); }
    if (this.trackedOperationId.length > 0 && this.trackedOperationId !== operation.id) { throw new Error('previous operation cleanup pending'); }
    const existing = localDrafts.read(lease, this.draftKey) ?? null;
    const payload = this.draftPayload(snapshot);
    if (existing !== null && (existing.payload as TimetableDraft).submission?.operationId === operation.id) {
      if (JSON.stringify((existing.payload as TimetableDraft).submission) !== JSON.stringify(payload.submission)) { throw new Error('operation mismatch'); }
      this.localRevision = existing.localRevision;
    } else { this.localRevision = localDrafts.stage(lease, this.draftKey, payload).localRevision; }
    await localDrafts.flush(lease);
    if (!localDrafts.valid(lease) || this.boundLease !== lease) { throw new Error('stale lease'); }
    // beginOperation retains its in-memory block even when the disk write fails.
    // Track it before awaiting, so known-unsent cleanup cannot orphan this draft revision.
    this.trackedOperationId = operation.id;
    await localDrafts.beginOperation(lease, { kind: 'timetable', id: operation.id, draftKind: 'timetable',
      ownerId: 'main', localRevision: this.localRevision });
    if (!localDrafts.valid(lease) || this.boundLease !== lease) { throw new Error('stale lease'); }
  }
  private async releaseKnownOperation(): Promise<void> {
    const lease = this.boundLease; const id = this.trackedOperationId;
    if (lease === null || id.length === 0) { return; }
    try {
      await localDrafts.resolveOperation(lease, 'timetable', id);
      if (this.boundLease === lease && this.trackedOperationId === id && localDrafts.valid(lease)) {
        this.trackedOperationId = ''; this.stageDraft();
      }
    } catch { if (this.boundLease === lease) { this.draftMessage = '本机操作记录清理失败，请重试核对；原草稿仍保留。'; } }
  }
  private async clearAppliedDraft(): Promise<void> {
    const lease = this.boundLease; const id = this.trackedOperationId;
    if (lease === null || id.length === 0) { return; }
    try {
      await localDrafts.resolveOperation(lease, 'timetable', id, true);
      if (this.boundLease === lease && localDrafts.valid(lease)) { this.trackedOperationId = ''; this.localRevision = 0; this.draftMessage = ''; this.stageDraft(); }
    } catch { if (this.boundLease === lease) { this.draftMessage = '账号保存已确认，本机草稿清理失败；可再次核对后清理。'; } }
  }
  private async discardStoredDraft(): Promise<void> {
    const lease = this.boundLease;
    if (lease === null || !localDrafts.valid(lease)) { return; }
    const record = this.recoverableDraft ?? localDrafts.read(lease, this.draftKey) ?? null;
    if (record === null || (record.payload as TimetableDraft).submission !== null || localDrafts.isBlocked(lease, this.draftKey)) { return; }
    try {
      const removed = await localDrafts.remove(lease, this.draftKey, record.localRevision);
      if (removed && this.boundLease === lease && localDrafts.valid(lease)) { this.recoverableDraft = null; this.localRevision = 0; this.draftMessage = ''; }
    } catch { if (this.boundLease === lease) { this.draftMessage = '未能舍弃本机草稿，请重试。'; } }
  }
  private restoreStoredDraft(): void {
    const record = this.recoverableDraft; const lease = this.boundLease;
    if (record === null || lease === null || !localDrafts.valid(lease) || this.controller === null) { return; }
    const draft = record.payload as TimetableDraft;
    const submission = draft.submission;
    if (!this.controller.restoreDraft({ baselineEntries: draft.baselineEntries, expectedRevision: draft.expectedRevision,
      draftEntries: draft.draftEntries, operation: submission === null ? null : { id: submission.operationId,
        entries: submission.entries, revision: submission.expectedRevision, confirmClear: submission.confirmClear } },
      draft.editorDirty || draft.editingIndex >= 0)) { this.draftMessage = '草稿无法恢复，已保留原记录。'; return; }
    this.editor = { date: draft.editor.date, title: draft.editor.title, start_time: draft.editor.start_time,
      end_time: draft.editor.end_time, location: draft.editor.location, teacher: draft.editor.teacher };
    this.editorOpen = draft.editorOpen; this.editorDirty = draft.editorDirty; this.editingIndex = draft.editingIndex;
    this.repeatWeeks = draft.repeatWeeks; this.sourceWarnings = draft.sourceWarnings; this.anchorDate = draft.anchorDate;
    this.recoverableDraft = null; this.localRevision = record.localRevision;
    this.trackedOperationId = submission?.operationId ?? ''; this.source = 'manual'; this.scheduleUrl = ''; this.importRows = []; this.importChoices = []; this.importGeneration++;
    this.reviewOpen = false; this.notice = '已恢复本机草稿，原日期和课表版本保持不变。';
    if (submission !== null) { this.controller.checkResult(); } else { this.controller.refresh(); }
  }
  private latestRows(): CourseRow[] {
    return (this.view.latestEntries ?? []).slice(this.latestPage * 10, this.latestPage * 10 + 10)
      .map((entry: TimetableEntry, index: number): CourseRow => ({ index: this.latestPage * 10 + index, entry: entry }));
  }
  private editable(): boolean { return this.recoverableDraft === null && this.controller !== null && this.controller.canEdit(); }
  private current(revision: number): boolean { return this.pageActive && this.active && this.requestRevision === revision; }
  private editorConnectionChanged(): void {
    this.editorGeneration++;
    if (this.busyLabel === '正在读取课表预览…') { this.cancelPreview(); }
    else { this.importRows = []; this.importChoices = []; this.importGeneration++; this.importWarnings = [];
      this.controller?.setEditorPending(this.editorDirty || this.editingIndex >= 0);
    }
  }
  private resetEditor(): void {
    this.editorGeneration++;
    this.editor = { date: this.anchorDate, title: '', start_time: '', end_time: '', location: '', teacher: '' };
    this.fieldErrors = { date: '', title: '', start_time: '', end_time: '', location: '', teacher: '' };
    this.editingIndex = -1; this.repeatWeeks = 1; this.editorDirty = false;
  }
  private syncPending(): void {
    this.controller?.setEditorPending(this.editorDirty || this.editingIndex >= 0 || this.importRows.length > 0);
    this.stageDraft();
  }
  private updateEditor(field: string, value: string): void {
    if (this.loading || !this.editable()) { return; }
    const next: TimetableEntry = { date: this.editor.date, title: this.editor.title, start_time: this.editor.start_time,
      end_time: this.editor.end_time, location: this.editor.location, teacher: this.editor.teacher };
    // Keep input verbatim until explicit validation; no maxLength or silent trimming.
    if (field === 'date') { next.date = value; }
    else if (field === 'title') { next.title = value; }
    else if (field === 'start_time') { next.start_time = value; }
    else if (field === 'end_time') { next.end_time = value; }
    else if (field === 'location') { next.location = value; }
    else if (field === 'teacher') { next.teacher = value; }
    this.editor = next; this.editorDirty = true; this.message = '';
    if (this.fieldErrors.title.length + this.fieldErrors.date.length + this.fieldErrors.start_time.length +
      this.fieldErrors.end_time.length + this.fieldErrors.location.length + this.fieldErrors.teacher.length > 0) {
      this.fieldErrors = validateTimetableEntry(next).errors;
    }
    this.syncPending();
  }
  private setRepeatWeeks(weeks: number): void {
    if (this.loading || !this.editable() || this.editingIndex >= 0) { return; }
    this.repeatWeeks = weeks; this.editorDirty = true; this.syncPending();
  }
  private addEntry(keepOpen: boolean = false): void {
    if (this.loading || !this.editable()) { return; }
    const checked = validateTimetableEntry(this.editor); this.fieldErrors = checked.errors;
    if (!checked.valid) { this.message = '请先修正课程表单中标出的内容。'; this.focusRevision++; this.scroller.scrollEdge(Edge.Top); return; }
    const additions = expandWeeklyEntry(checked.entry, this.editingIndex < 0 ? this.repeatWeeks : 1);
    if (!additions.valid) { this.message = additions.errors[0].message; return; }
    const next = this.entries.map((entry: TimetableEntry) => normalizeTimetableEntry(entry));
    if (this.editingIndex >= 0) {
      if (this.editingIndex >= next.length) { this.message = '课程草稿已变化，请重新选择。'; return; }
      next[this.editingIndex] = checked.entry;
    } else { next.push(...additions.entries); }
    if (!this.controller?.replaceDraft(next)) { return; }
    const edited = this.editingIndex >= 0;
    if (!edited) { this.lastEntry = normalizeTimetableEntry(checked.entry); this.lastRepeatWeeks = this.repeatWeeks; }
    this.resetEditor(); this.editorOpen = keepOpen && !edited; this.syncPending();
    this.notice = '课程已加入本页草稿，尚未保存到账号。'; this.message = '';
  }
  private reuseLastEntry(): void {
    if (this.loading || !this.editable() || this.lastEntry === null || this.editingIndex >= 0) { return; }
    if (this.editorDirty) { this.message = '请先加入或取消当前输入，再沿用上一门信息。'; return; }
    this.editorGeneration++; this.editor = normalizeTimetableEntry(this.lastEntry);
    this.repeatWeeks = this.lastRepeatWeeks; this.editorDirty = true; this.editorOpen = true;
    this.fieldErrors = { date: '', title: '', start_time: '', end_time: '', location: '', teacher: '' };
    this.notice = '已复制到新表单，请核对日期、时间与周次；尚未加入课表。';
    this.message = ''; this.syncPending();
  }
  private changeImportChoices(choices: ImportRowChoice[]): void {
    if (this.loading || !this.editable()) { return; }
    this.importChoices = choices; this.message = '';
  }

  private newEntry(): void {
    if (this.loading || !this.editable() || this.editorDirty || this.editingIndex >= 0) { return; }
    this.resetEditor(); this.source = 'manual'; this.editorOpen = true; this.message = ''; this.stageDraft();
  }
  private editEntry(index: number): void {
    if (this.loading || !this.editable() || index < 0 || index >= this.entries.length) { return; }
    if (this.editorDirty || this.editingIndex >= 0) { this.message = '请先加入或取消当前编辑，再编辑另一条课程。'; return; }
    if (this.importRows.length > 0) { this.message = '请先加入所选课程或明确放弃本次预览，再编辑已有课程。'; return; }
    this.cancelPreview(); this.source = 'manual'; this.editor = normalizeTimetableEntry(this.entries[index]);
    this.editorGeneration++;
    this.editingIndex = index; this.repeatWeeks = 1; this.editorDirty = false; this.editorOpen = true;
    this.reviewOpen = false; this.message = ''; this.syncPending(); this.scroller.scrollEdge(Edge.Top);
  }
  private cancelEdit(): void {
    if (this.loading || !this.editable()) { return; }
    this.resetEditor(); this.editorOpen = false; this.message = ''; this.syncPending();
  }
  private requestDelete(index: number): void {
    if (this.loading || !this.editable()) { return; }
    if (this.editorDirty || this.editingIndex >= 0) { this.message = '请先加入或取消当前编辑，再移除课程。'; return; }
    this.pendingDelete = index;
  }
  private removeEntry(index: number): void {
    if (this.loading || !this.editable() || this.pendingDelete !== index || this.editorDirty || this.editingIndex >= 0) { return; }
    if (this.controller?.replaceDraft(this.entries.filter((_entry: TimetableEntry, position: number) => position !== index))) {
      this.pendingDelete = -1; this.notice = '已从草稿移除，账号课表尚未改动。'; this.message = ''; this.stageDraft();
    }
  }
  private selectSource(source: string): void {
    if (this.loading || !this.editable() || source === this.source) { return; }
    if (this.editorDirty || this.editingIndex >= 0) { this.message = '请先加入或取消当前表单，再切换录入方式。'; return; }
    if (this.importRows.length > 0) { this.message = '请先加入所选课程或明确放弃本次预览，再切换录入方式。'; return; }
    this.cancelPreview(); this.source = source; this.message = '';
  }
  private updateScheduleUrl(value: string): void {
    if (this.loading || !this.editable()) { return; }
    this.requestRevision++; this.scheduleUrl = value; this.importRows = []; this.importChoices = []; this.importGeneration++; this.importWarnings = [];
    this.message = ''; this.syncPending();
  }
  private cancelPreview(): void {
    this.requestRevision++; this.previewBusy = false; this.importRows = []; this.importChoices = []; this.importGeneration++; this.importWarnings = [];
    this.loading = ['loading', 'saving', 'checking'].includes(this.view.phase); this.busyLabel = ''; this.syncPending();
  }
  private async previewImport(): Promise<void> {
    if (this.loading || !this.editable() || !this.active || this.source !== 'subscription') { return; }
    const url = this.scheduleUrl.trim();
    if (url.length === 0 || url.length > 2048) { this.message = '请粘贴完整的 HDUHelp 课表订阅链接（不超过 2048 字符）。'; return; }
    const revision = ++this.requestRevision; const baseUrl = this.baseUrl; const token = this.token; this.previewBusy = true; this.loading = true;
    this.busyLabel = '正在读取课表预览…'; this.message = ''; this.importRows = []; this.importChoices = []; this.importGeneration++; this.importWarnings = [];
    try {
      const result = await new CampusFlowApi(baseUrl, token).previewSubscription(url);
      if (!this.current(revision) || this.baseUrl !== baseUrl || this.token !== token || this.scheduleUrl.trim() !== url || this.source !== 'subscription') { return; }
      const checked = parseImportReview(JSON.stringify(result));
      if (!checked.valid) { this.message = checked.message; return; }
      this.importRows = checked.rows; this.importChoices = []; this.importGeneration++; this.importWarnings = checked.sourceWarnings; this.syncPending();
      this.notice = '候选课程尚未加入草稿。核对后可加入；不会保存订阅链接。';
    } catch (error) {
      if (this.current(revision) && this.baseUrl === baseUrl && this.token === token) {
        this.message = error instanceof CampusFlowRequestError && error.code.startsWith('IMPORT_') ? error.message
          : '预览读取失败，请检查连接或链接有效性；现有课表草稿未改动。';
      }
    } finally {
      if (this.current(revision)) { this.previewBusy = false; this.loading = false; this.busyLabel = ''; }
    }
  }
  private acceptImport(): void {
    if (this.loading || !this.editable() || this.importRows.length === 0) { return; }
    const checked = assembleSelectedImport(this.importRows, this.entries, this.importChoices);
    if (!checked.valid) { this.message = `尚未加入：${checked.message} 原草稿与预览均保留。`; return; }
    if (!this.controller?.replaceDraft(checked.entries)) { return; }
    this.sourceWarnings = this.sourceWarnings.concat(this.importWarnings, checked.warnings.filter((issue: TimetableIssue) => issue.index < 0));

    const count = checked.addedEntries.length;
    this.cancelPreview(); this.scheduleUrl = ''; this.editorOpen = false;
    this.notice = `已将所选 ${count} 次课程加入草稿，重复 ${checked.duplicateCount} 条、明确排除 ${checked.excludedCount} 条；尚未保存到账号。`;
    this.message = ''; this.syncPending();
  }

  private draftRows(): CourseRow[] {
    return this.entries.slice(this.pageIndex * 10, this.pageIndex * 10 + 10)
      .map((entry: TimetableEntry, index: number): CourseRow => ({ index: this.pageIndex * 10 + index, entry: entry }));
  }

  private courseRange(): string {
    if (this.entries.length === 0) { return '尚未添加课程'; }
    const dates = this.entries.map((entry: TimetableEntry) => entry.date).sort();
    return dates[0] === dates[dates.length - 1] ? dates[0] : `${dates[0]} 至 ${dates[dates.length - 1]}`;
  }
  private requestClear(): void {
    if (this.loading || !this.editable()) { return; }
    if (this.editorDirty || this.editingIndex >= 0 || this.importRows.length > 0) {
      this.message = '请先处理表单或导入候选，再清空草稿。'; return;
    }
    this.clearRequested = true;
  }
  private clearDraft(): void {
    if (!this.clearRequested || this.loading || !this.editable()) { return; }
    if (this.editorDirty || this.editingIndex >= 0 || this.importRows.length > 0) {
      this.message = '表单或导入候选已变化，请先处理后再清空草稿。'; return;
    }
    if (this.controller?.replaceDraft([])) {
      this.clearRequested = false; this.sourceWarnings = []; this.editorOpen = false;
      this.notice = '草稿已清空，账号原课表仍保留。保存时还需明确确认清空账号课表。'; this.stageDraft();
    }
  }
  private reviewSave(): void {
    if (this.loading || !this.editable() || this.view.phase === 'stale') { return; }
    if (this.editorDirty || this.editingIndex >= 0 || this.importRows.length > 0) {
      this.message = '请先加入、保存或取消表单及导入候选，再核对整份课表。'; return;
    }
    if (!this.view.dirty) { this.message = '课表没有未保存的修改。'; return; }
    this.reviewOpen = true; this.message = ''; this.scheduleUrl = ''; this.scroller.scrollEdge(Edge.Top);
  }
  private async save(): Promise<void> {
    if (!this.reviewOpen || this.loading || !this.editable()) { return; }
    await this.controller?.save(this.entries.length === 0);
  }
  private async requestRefresh(): Promise<void> {
    if (this.loading) { return; }
    if (this.view.dirty && this.view.phase !== 'applied') { this.reloadRequested = true; return; }
    await this.controller?.refresh();
  }
  private async discardAndReload(): Promise<void> {
    if (!this.reloadRequested || this.loading) { return; }
    const revision = this.requestRevision;
    const loaded = await this.controller?.refresh(true);
    if (loaded && this.current(revision)) {
      this.resetEditor(); this.editorOpen = false; this.importRows = []; this.importChoices = []; this.importGeneration++; this.importWarnings = [];
      this.scheduleUrl = ''; this.sourceWarnings = []; this.reviewOpen = false; this.reloadRequested = false;
      this.message = ''; this.notice = ''; this.syncPending(); await this.discardStoredDraft();
    }
  }
  private returnFromReview(): void {
    if (this.loading || !this.editable()) { return; }
    this.reviewOpen = false;
  }
  @Builder
  private FormField(label: string, placeholder: string, value: string, error: string,
    onChange: (value: string) => void, inputType: InputType = InputType.Normal) {
    Column({ space: 6 }) {
      Text(label).fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink).width('100%')
      TextInput({ text: value, placeholder: placeholder }).type(inputType)
        .constraintSize({ minHeight: 50 }).fontSize(AppTheme.bodySize).fontColor(AppTheme.ink)
        .backgroundColor(AppTheme.canvas).borderRadius(AppTheme.controlRadius)
        .padding({ left: 12, right: 12 }).enabled(!this.loading && this.editable())
        .accessibilityText(`${label}${error.length > 0 ? `，${error}` : ''}`).onChange(onChange)
      if (error.length > 0) {
        Text(error).fontSize(AppTheme.metaSize).fontColor(AppTheme.danger).width('100%')
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private CourseCard(row: CourseRow, editable: boolean) {
    Column({ space: 8 }) {
      Text(`${row.index + 1}. ${row.entry.title}`).fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium)
        .fontColor(AppTheme.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
      Text(`${row.entry.date}  ·  ${row.entry.start_time}–${row.entry.end_time}`)
        .fontSize(AppTheme.metaSize).fontColor(AppTheme.accent).width('100%').wordBreak(WordBreak.BREAK_WORD)
      Text(`${row.entry.location || '地点未填写'}${row.entry.teacher.length > 0 ? ` · ${row.entry.teacher}` : ''}`)
        .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
      if (editable) {
        Row({ space: 10 }) {
          Button('编辑').layoutWeight(1).constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
            .fontColor(AppTheme.accent).backgroundColor(AppTheme.accentSoft)
            .enabled(!this.loading && this.editable()).accessibilityText(`编辑 ${row.entry.date} 的 ${row.entry.title}`)
            .onClick(() => this.editEntry(row.index))
          Button(this.pendingDelete === row.index ? '确认移除' : '移除').layoutWeight(1)
            .constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize).fontColor(AppTheme.danger)
            .backgroundColor(AppTheme.surface).enabled(!this.loading && this.editable())
            .accessibilityText(`${this.pendingDelete === row.index ? '确认移除' : '移除'} ${row.entry.date} 的 ${row.entry.title}`)
            .onClick(() => {
              if (this.pendingDelete === row.index) { this.removeEntry(row.index); }
              else { this.requestDelete(row.index); }
            })
        }.width('100%')
        if (this.pendingDelete === row.index) {
          Text('只从当前草稿移除；再次点“确认移除”生效。')
            .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
          Button('保留这条课程').constraintSize({ minHeight: 48 }).fontSize(AppTheme.metaSize)
            .fontColor(AppTheme.quiet).backgroundColor(Color.Transparent).enabled(!this.loading && this.editable())
            .onClick(() => this.pendingDelete = -1)
        }
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(AppTheme.cardInset)
      .backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
      .border({ width: 1, color: AppTheme.line })
  }

  @Builder
  private Pagination() {
    Row({ space: 8 }) {
      Button('上一页').layoutWeight(1).constraintSize({ minHeight: 48 }).fontSize(AppTheme.metaSize)
        .fontColor(AppTheme.accent).backgroundColor(AppTheme.accentSoft)
        .enabled(this.pageIndex > 0)
        .onClick(() => { this.pageIndex--; })
      Text(`${this.pageIndex + 1} / ${Math.max(1, Math.ceil(this.entries.length / 10))}`)
        .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet)
      Button('下一页').layoutWeight(1).constraintSize({ minHeight: 48 }).fontSize(AppTheme.metaSize)
        .fontColor(AppTheme.accent).backgroundColor(AppTheme.accentSoft)
        .enabled((this.pageIndex + 1) * 10 <
          this.entries.length)
        .onClick(() => { this.pageIndex++; })
    }.width('100%')
  }

  @Builder
  private Editor() {
    TimetableEntryEditor({ entry: this.editor, errors: this.fieldErrors, repeatWeeks: this.repeatWeeks,
      editing: this.editingIndex >= 0, busy: this.loading || !this.editable(), active: this.pageActive && this.active,
      anchorDate: this.anchorDate, idPrefix: 'timetable-main',
      contextKey: `timetable-${this.boundLease?.generation ?? 0}-${this.editorGeneration}-${this.editingIndex}`,
      focusRevision: this.focusRevision, canReuse: this.lastEntry !== null && this.editingIndex < 0,
      onFieldChange: (field: string, value: string) => this.updateEditor(field, value),
      onWeeksChange: (weeks: number) => this.setRepeatWeeks(weeks),
      onSave: (keepOpen: boolean) => this.addEntry(keepOpen), onCancel: () => this.cancelEdit(),
      onReuse: () => this.reuseLastEntry() })
  }

  @Builder
  private ImportPanel() {
    Column({ space: 16 }) {
      Text('从订阅获取预览').fontSize(AppTheme.sectionTitle).fontWeight(FontWeight.Bold)
        .fontColor(AppTheme.ink).width('100%')
      this.FormField('HDUHelp 课表订阅链接', '粘贴 HTTPS 课表订阅链接', this.scheduleUrl, '',
        (value: string) => this.updateScheduleUrl(value), InputType.Password)
      Text('链接可能含私人凭据，仅用于本次读取。这里只读取候选课程，不保存订阅链接，也不会自动同步。')
        .fontSize(AppTheme.metaSize).lineHeight(21).fontColor(AppTheme.quiet).width('100%')
      Button(this.loading && this.busyLabel === '正在读取课表预览…' ? '正在读取…' : '读取预览，不保存')
        .width('100%').constraintSize({ minHeight: 50 }).fontSize(AppTheme.bodySize).fontColor(AppTheme.onAccent)
        .backgroundColor(AppTheme.accent).borderRadius(AppTheme.controlRadius)
        .enabled(!this.loading && this.editable() && this.importRows.length === 0).onClick(() => this.previewImport())
      if (this.importRows.length > 0) {
        TimetableImportPanel({ rows: this.importRows, currentDraft: this.entries, choices: this.importChoices,
          warnings: this.importWarnings, busy: this.loading || !this.editable(), active: this.pageActive && this.active,
          anchorDate: this.anchorDate, contextKey: `timetable-${this.boundLease?.generation ?? 0}-${this.importGeneration}`,
          onChoicesChanged: (choices: ImportRowChoice[]) => this.changeImportChoices(choices),
          onAccept: () => this.acceptImport(), onCancel: () => this.cancelPreview() })
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(AppTheme.cardInset)
      .backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
  }

  @Builder
  private DraftList() {
    Column({ space: 12 }) {
      Row() {
        Text(`课表草稿 · ${this.entries.length} 次`).fontSize(AppTheme.sectionTitle)
          .fontWeight(FontWeight.Bold).fontColor(AppTheme.ink).layoutWeight(1)
        if (!this.reviewOpen && !this.editorOpen && this.source === 'manual') {
          Button('继续添加').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
            .fontColor(AppTheme.accent).backgroundColor(Color.Transparent)
            .enabled(!this.loading && this.editable()).onClick(() => this.newEntry())
        }
      }.width('100%')
      Text(this.courseRange()).fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
      if (this.sourceWarnings.length > 0) {
        Column({ space: 8 }) {
          Text('导入来源提示').fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium).fontColor(AppTheme.warning).width('100%')
          ForEach(this.sourceWarnings, (warning: TimetableIssue) => {
            Text(warning.message).fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
          }, (_warning: TimetableIssue, index: number) => `source-warning-${this.draftRevision}-${index}`)
        }.width('100%').padding(AppTheme.cardInset).backgroundColor(AppTheme.surface).borderRadius(AppTheme.controlRadius)
      }
      if (this.entries.length === 0) {
        FeedbackPanel({ kind: 'empty', title: '当前课表为空', message: '手动添加课程，或从订阅读取预览后加入；空课表保存需要明确确认。' })
      }
      if (this.warnings.length > 0) {
        Column({ space: 8 }) {
          Text(`有 ${this.warnings.length} 处时间重叠，请核对`).fontSize(AppTheme.bodySize)
            .fontWeight(FontWeight.Medium).fontColor(AppTheme.warning).width('100%')
          ForEach(this.showAllWarnings ? this.warnings : this.warnings.slice(0, 5), (warning: TimetableIssue) => {
            Text(warning.message).fontSize(AppTheme.metaSize).fontColor(AppTheme.warning).width('100%')
          }, (_warning: TimetableIssue, index: number) => `warning-${this.draftRevision}-${index}`)
          if (this.warnings.length > 5) {
            Button(this.showAllWarnings ? '收起提示' : `查看全部 ${this.warnings.length} 处提示`)
              .constraintSize({ minHeight: 48 }).fontSize(AppTheme.metaSize).fontColor(AppTheme.warning)
              .backgroundColor(Color.Transparent).onClick(() => this.showAllWarnings = !this.showAllWarnings)
          }
          Text('重叠课程不会自动删除；请返回编辑，或确认保留这些安排。')
            .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
        }.width('100%').padding(AppTheme.cardInset).backgroundColor(AppTheme.surface).borderRadius(AppTheme.controlRadius)
      }
      ForEach(this.draftRows(), (row: CourseRow) => {
        this.CourseCard(row, !this.reviewOpen)
      }, (row: CourseRow) => `draft-${this.draftRevision}-${row.index}-${this.reviewOpen}`)
      if (this.entries.length > 10) { this.Pagination() }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private DraftRecovery() {
    if (this.recoverableDraft !== null) {
      FeedbackPanel({ kind: 'info', title: '有一份本机课表草稿',
        message: '可恢复表单与原课表版本；未加入的订阅预览与逐行选择未存入本机，需重新读取。待核对的保存先查询原操作。',
        actionLabel: '恢复草稿', onAction: () => this.restoreStoredDraft() })
      if ((this.recoverableDraft.payload as TimetableDraft).submission === null) {
        Button('舍弃这份本机草稿').width('100%').constraintSize({ minHeight: 48 }).fontColor(AppTheme.quiet)
          .backgroundColor(AppTheme.surface).onClick(() => this.discardStoredDraft())
      }
    }
    if (this.draftMessage.length > 0) {
      FeedbackPanel({ kind: 'error', title: '本机草稿', message: this.draftMessage,
        actionLabel: '重试保存草稿', onAction: () => this.flushDraft() })
    }
    if ((this.view.latestRevision ?? '').length > 0) {
      FeedbackPanel({ kind: 'info', title: '原草稿与最新课表不同',
        message: `下方保留本机 ${this.entries.length} 次课程；账号最新为 ${(this.view.latestEntries ?? []).length} 次。不会把旧草稿绑定到新版本。` })
      Button(this.latestExpanded ? '收起账号最新课表' : '查看账号最新课表').width('100%').constraintSize({ minHeight: 48 })
        .fontColor(AppTheme.accent).backgroundColor(AppTheme.accentSoft).onClick(() => this.latestExpanded = !this.latestExpanded)
      if (this.latestExpanded) {
        ForEach(this.latestRows(), (row: CourseRow) => { this.CourseCard(row, false) },
          (row: CourseRow) => `latest-${this.view.latestRevision}-${row.index}`)
        if ((this.view.latestEntries ?? []).length === 0) { Text('账号最新课表为空').fontColor(AppTheme.quiet) }
        Row({ space: 8 }) {
          Button('上一页').constraintSize({ minHeight: 48 }).layoutWeight(1).enabled(this.latestPage > 0)
            .onClick(() => this.latestPage--)
          Button('下一页').constraintSize({ minHeight: 48 }).layoutWeight(1)
            .enabled((this.latestPage + 1) * 10 < (this.view.latestEntries ?? []).length).onClick(() => this.latestPage++)
        }.width('100%')
      }
    }
  }

  @Builder
  private SavingFeedback() {
    if (this.view.phase === 'uncertain' || this.view.phase === 'retryable' || this.view.phase === 'checking') {
      FeedbackPanel({ kind: 'info', title: '先核对这笔保存', message: this.view.message,
        actionLabel: '核对保存结果', busy: this.loading, onAction: () => { this.controller?.checkResult(); } })
      if (this.view.phase === 'retryable') {
        Button('用原标识和原课表重试').width('100%').constraintSize({ minHeight: 48 })
          .fontSize(AppTheme.bodySize).fontColor(AppTheme.accent).backgroundColor(AppTheme.accentSoft)
          .borderRadius(AppTheme.controlRadius).onClick(() => { this.controller?.retrySameOperation(); })
      }
    } else if (this.view.phase === 'applied') {
      FeedbackPanel({ kind: 'info', title: '已收到保存回执', message: this.view.message,
        actionLabel: '读取最新课表', busy: this.loading, onAction: () => { this.controller?.refresh(); } })
    } else if (this.view.phase === 'stale') {
      FeedbackPanel({ kind: 'info', title: '课表已有更新', message: this.view.message,
        actionLabel: '重新载入并核对', busy: this.loading, onAction: () => { this.requestRefresh(); } })
    } else if (this.view.message.length > 0) {
      FeedbackPanel({ kind: 'error', title: '尚未完成', message: this.view.message,
        actionLabel: '重新读取课表', busy: this.loading, onAction: () => { this.requestRefresh(); } })
    }
    if (this.view.notice.length > 0 && this.view.phase === 'saved') {
      FeedbackPanel({ kind: 'success', title: '课表已更新', message: this.view.notice,
        actionLabel: '去计划核对冲突', onAction: () => this.onOpenPlan() })
    }
  }

  build() {
    Column() {
      Row({ space: 12 }) {
        Button({ type: ButtonType.Circle }) { AppIcon({ name: 'back', iconSize: 22, color: AppTheme.accent }) }
          .width(48).height(48).backgroundColor(AppTheme.surface).accessibilityText('返回校园').onClick(() => this.onBack())
        Column({ space: 4 }) {
          Text(this.reviewOpen ? '确认课表' : '课表维护').fontSize(AppTheme.pageTitle).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
          Text(this.view.dirty ? '有未保存草稿 · 返回后可继续' : '课程、日期和地点集中维护')
            .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).wordBreak(WordBreak.BREAK_WORD)
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%').padding({ left: AppTheme.pageInset, right: AppTheme.pageInset, top: 16, bottom: 12 })
      Scroll(this.scroller) {
        Column({ space: AppTheme.sectionGap }) {
          this.DraftRecovery()
          this.SavingFeedback()
          if (this.loading) {
            FeedbackPanel({ kind: 'loading', title: this.previewBusy ? '读取导入候选' : this.view.phase === 'saving' ? '保存已确认课表' : '读取并核对课表',
              message: '现有课表与草稿会保留，请稍候。' })
            if (this.previewBusy) {
              Button('取消读取预览').width('100%').constraintSize({ minHeight: 48 })
                .fontColor(AppTheme.quiet).backgroundColor(AppTheme.surface).onClick(() => this.cancelPreview())
            }
          }
          if (this.message.length > 0) { FeedbackPanel({ kind: 'error', title: '请先核对', message: this.message }) }
          if (this.notice.length > 0 && !this.reviewOpen) { Text(this.notice).fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%') }
          if (this.view.revision.length > 0) {
            Text(this.view.dirty ? '以下来源对应已载入版本；当前未保存修改仅为本页草稿。' : '已载入课表的来源')
              .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
            EvidencePanel({ evidence: this.view.evidence ?? [], active: this.active })
            if (this.reviewOpen) {
              FeedbackPanel({ kind: 'info', title: this.entries.length === 0 ? '即将清空账号课表' : `即将保存 ${this.entries.length} 次课程`,
                message: '只更新课表，不修改校园资料、地图或订阅连接。保存前会核对版本；不会再次抓取导入链接。' })
            } else if (this.editable()) {
              Row({ space: 12 }) {
                Button('手动录入').layoutWeight(1).constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
                  .fontColor(this.source === 'manual' ? AppTheme.surface : AppTheme.accent)
                  .backgroundColor(this.source === 'manual' ? AppTheme.accent : AppTheme.accentSoft)
                  .borderRadius(AppTheme.controlRadius).enabled(!this.loading).onClick(() => this.selectSource('manual'))
                Button('导入预览').layoutWeight(1).constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
                  .fontColor(this.source === 'subscription' ? AppTheme.surface : AppTheme.accent)
                  .backgroundColor(this.source === 'subscription' ? AppTheme.accent : AppTheme.accentSoft)
                  .borderRadius(AppTheme.controlRadius).enabled(!this.loading).onClick(() => this.selectSource('subscription'))
              }.width('100%')
              if (this.source === 'manual') {
                if (this.editorOpen) { this.Editor() }
                else {
                  Button('添加课程').width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
                    .fontColor(AppTheme.onAccent).backgroundColor(AppTheme.accent).borderRadius(AppTheme.controlRadius)
                    .onClick(() => this.newEntry())
                }
              } else { this.ImportPanel() }
            }
            this.DraftList()
            if (!this.reviewOpen && this.editable()) {
              Button('重新读取账号课表').width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
                .fontColor(AppTheme.accent).backgroundColor(AppTheme.surface).enabled(!this.loading).onClick(() => this.requestRefresh())
              Button('清空课表草稿').width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
                .fontColor(AppTheme.danger).backgroundColor(AppTheme.dangerSoft).enabled(!this.loading && this.entries.length > 0)
                .onClick(() => this.requestClear())
            }
          }
          if (this.clearRequested) {
            FeedbackPanel({ kind: 'info', title: '移除草稿里的全部课程？', message: '账号课表仍保留，只有最后确认保存才会清空账号课表。' })
            Button('确认清空草稿').width('100%').constraintSize({ minHeight: 48 }).fontColor(AppTheme.danger)
              .backgroundColor(AppTheme.dangerSoft).enabled(this.editable() && !this.loading).onClick(() => this.clearDraft())
            Button('保留草稿').width('100%').constraintSize({ minHeight: 48 }).fontColor(AppTheme.quiet)
              .backgroundColor(AppTheme.surface).onClick(() => this.clearRequested = false)
          }
          if (this.reloadRequested) {
            FeedbackPanel({ kind: 'info', title: '放弃本页草稿并重新载入？', message: '包括未加入的表单和导入候选。读取失败会保留原草稿。' })
            Button('放弃草稿并读取最新课表').width('100%').constraintSize({ minHeight: 48 }).fontColor(AppTheme.danger)
              .backgroundColor(AppTheme.dangerSoft).enabled(!this.loading).onClick(() => this.discardAndReload())
            Button('保留当前草稿').width('100%').constraintSize({ minHeight: 48 }).fontColor(AppTheme.quiet)
              .backgroundColor(AppTheme.surface).onClick(() => this.reloadRequested = false)
          }
          Text('未完成草稿可保存在本机，恢复时仍需核对原课表版本；退出账号会清除。所有课程按北京时间填写。')
            .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
        }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: AppTheme.pageInset, right: AppTheme.pageInset, top: 12, bottom: 24 })
      }.width('100%').layoutWeight(1).scrollBar(BarState.Off)
      if (this.editable() && this.view.phase !== 'stale') {
        Column({ space: 8 }) {
          if (this.reviewOpen) {
            Button(this.entries.length === 0 ? '确认清空账号课表' : '确认保存这份课表').width('100%').constraintSize({ minHeight: 48 })
              .fontSize(AppTheme.bodySize).fontColor(AppTheme.onAccent)
              .backgroundColor(this.entries.length === 0 ? AppTheme.danger : AppTheme.accent)
              .borderRadius(AppTheme.controlRadius).enabled(!this.loading).onClick(() => this.save())
            Button('返回编辑').width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
              .fontColor(AppTheme.quiet).backgroundColor(AppTheme.surface).enabled(!this.loading).onClick(() => this.returnFromReview())
          } else {
            Button('核对整份课表').width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
              .fontColor(AppTheme.onAccent).backgroundColor(AppTheme.accent).borderRadius(AppTheme.controlRadius)
              .enabled(!this.loading && this.view.dirty).onClick(() => this.reviewSave())
          }
        }.width('100%').padding({ left: AppTheme.pageInset, right: AppTheme.pageInset, top: 12, bottom: 16 })
          .backgroundColor(AppTheme.surface).border({ width: { top: 1 }, color: AppTheme.line })
      }
    }.width('100%').height('100%').backgroundColor(AppTheme.canvas)
  }
}
