import { CampusDataSnapshot, CampusMapSummary, CampusPlaceImport, TimetableEntry, ScheduleImportRow, UserProfile, OnboardingSnapshot, OnboardingSaveReceipt } from '../model/ApiModels';
import { CampusFlowApi } from '../services/CampusFlowApi';
import { CampusFlowRequestError } from '../utils/AgentFeedback';
import { TimetableFieldErrors, TimetableIssue, normalizeTimetableEntry, validateTimetableEntry, validateTimetableList, expandWeeklyEntry } from '../utils/OnboardingTimetable';
import { DraftLease, DraftKey, DraftRecord, DraftSaveState, OnboardingDraft, OnboardingSubmission, DraftCampusPlace } from '../utils/DraftStore';
import { localDrafts } from '../services/LocalDrafts';
import { historyScope } from '../utils/LocalHistoryStore';
import { shanghaiDate } from '../utils/DailyAgenda';
import { timetableOperationId } from '../utils/TimetableMaintenance';
import { ImportRowChoice, parseImportReview, assembleSelectedImport } from '../utils/TimetableImportReview';
import { TimetableEntryEditor } from '../components/TimetableEntryEditor';
import { TimetableImportPanel } from '../components/TimetableImportPanel';
import { AppTheme } from '../theme/AppTheme';
import { AppIcon } from '../components/AppIcon';
import { AppIllustration } from '../components/AppIllustration';
import { FeedbackPanel } from '../components/FeedbackPanel';

interface CourseRow {
  index: number;
  entry: TimetableEntry;
}

@Component
export struct OnboardingPage {
  @Watch('editorConnectionChanged') @Prop baseUrl: string;
  @Watch('editorConnectionChanged') @Prop token: string;
  @Watch('draftLeaseChanged') @Prop draftLease: DraftLease | null = null;
  onCompleted: (user: UserProfile) => void = () => {};
  onReturnToLogin: () => void = () => {};
  @State private step: number = 0;
  // The supplied campus package is HDU Xiasha; do not relabel it as another campus.
  private school: string = '杭州电子科技大学';
  private campus: string = '下沙校区';
  @State private semester: string = '';
  @State private source: string = 'manual';
  @State private entries: TimetableEntry[] = [];
  @State private editor: TimetableEntry = { date: '', title: '', start_time: '', end_time: '', location: '', teacher: '' };
  @State private fieldErrors: TimetableFieldErrors = { date: '', title: '', start_time: '', end_time: '', location: '', teacher: '' };
  @State private editorOpen: boolean = true;
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
  @State private importedNotice: string = '';
  @State private sourceWarnings: TimetableIssue[] = [];
  @State private warnings: TimetableIssue[] = [];
  @State private showAllWarnings: boolean = false;
  @State private loading: boolean = false;
  @State private busyLabel: string = '';
  @State private message: string = '';
  @State private notice: string = '';
  @State private needsLogin: boolean = false;
  @State private completed: boolean = false;
  @State private recoverableDraft: DraftRecord | null = null;
  @State private draftMessage: string = '';
  @State private focusRevision: number = 0;
  @State private editorGeneration: number = 0;
  private lastEntry: TimetableEntry | null = null;
  private lastRepeatWeeks: number = 1;
  @State private expectedRevision: string = '';
  @State private baselineStale: boolean = false;
  @State private latestSnapshot: OnboardingSnapshot | null = null;
  @State private latestExpanded: boolean = false;
  @State private latestPage: number = 0;
  @State private submission: OnboardingSubmission | null = null;
  @State private savePhase: string = '';
  private baselineEntries: TimetableEntry[] = [];
  private anchorDate: string = shanghaiDate(Date.now());
  private draftKey: DraftKey = { kind: 'onboarding', ownerId: 'main' };
  private boundLease: DraftLease | null = null;
  private draftUnsubscribe: (() => void) | null = null;
  private localRevision: number = 0;
  private requestRevision: number = 0;
  private pageActive: boolean = true;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.pageActive = true;
    this.bindDraftLease();
    if (this.semester.length === 0) {
      const parts = this.anchorDate.split('-'); const month = Number(parts[1]);
      const year = month >= 8 ? Number(parts[0]) : Number(parts[0]) - 1;
      this.semester = `${year}-${year + 1} ${month >= 2 && month < 8 ? '第二' : '第一'}学期`;
    }
    if (this.editor.date.length === 0) { this.resetEditor(); }
    if (this.recoverableDraft === null) { this.loadBaseline(); }
  }

  aboutToDisappear(): void {
    this.flushDraft();
    this.draftUnsubscribe?.(); this.draftUnsubscribe = null;
    this.pageActive = false;
    this.requestRevision++;
    this.scheduleUrl = '';
    this.importRows = []; this.importChoices = []; this.importGeneration++;
  }

  private current(revision: number): boolean {
    return this.pageActive && this.requestRevision === revision && !this.completed &&
      (this.boundLease === null || localDrafts.valid(this.boundLease));
  }

  private today(): string { return this.anchorDate; }

  private editable(): boolean { return !this.completed && this.recoverableDraft === null && this.submission === null; }
  private draftLeaseChanged(): void {
    if (!this.pageActive) { return; }
    const lease = this.draftLease;
    if (this.boundLease !== null && (lease === null || lease.scope !== this.boundLease.scope || lease.generation !== this.boundLease.generation)) {
      this.requestRevision++; this.entries = []; this.editorDirty = false; this.editingIndex = -1;
      this.submission = null; this.expectedRevision = ''; this.baselineEntries = []; this.baselineStale = false;
      this.sourceWarnings = []; this.scheduleUrl = ''; this.importRows = []; this.importChoices = []; this.importGeneration++; this.localRevision = 0;
      this.step = 0; this.semester = ''; this.completed = false; this.loading = false;
      this.lastEntry = null; this.lastRepeatWeeks = 1; this.anchorDate = shanghaiDate(Date.now()); this.resetEditor();
      this.latestSnapshot = null; this.latestExpanded = false; this.latestPage = 0; this.savePhase = '';
      this.message = ''; this.notice = ''; this.draftMessage = ''; this.importedNotice = ''; this.warnings = [];
    }
    this.bindDraftLease();
    if (lease !== null && localDrafts.valid(lease) && this.recoverableDraft === null) { this.loadBaseline(); }
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
    this.boundLease = lease; this.observeDraftState(); this.recoverableDraft = localDrafts.read(lease, this.draftKey) ?? null;
    this.localRevision = this.recoverableDraft?.localRevision ?? 0;
  }
  private draftPayload(): OnboardingDraft {
    return { school: this.school, campus: this.campus, step: this.step, semester: this.semester, entries: this.entries,
      editor: this.editor, editorOpen: this.editorOpen, editorDirty: this.editorDirty, editingIndex: this.editingIndex,
      repeatWeeks: this.repeatWeeks, sourceWarnings: this.sourceWarnings, anchorDate: this.anchorDate, timezone: 'Asia/Shanghai',
      expectedRevision: this.expectedRevision, baselineEntries: this.baselineEntries, submission: this.submission };
  }
  private stageDraft(): void {
    const lease = this.boundLease;
    if (!this.pageActive || this.completed || this.recoverableDraft !== null || this.submission !== null || lease === null || !localDrafts.valid(lease)) { return; }
    try { this.localRevision = localDrafts.stage(lease, this.draftKey, this.draftPayload()).localRevision; this.draftMessage = ''; }
    catch { this.draftMessage = '本机草稿暂未保存，内容仍在本页。请重试保存草稿。'; }
  }
  private async flushDraft(): Promise<void> {
    this.stageDraft(); const lease = this.boundLease;
    if (lease === null || !localDrafts.valid(lease)) { return; }
    try { await localDrafts.flush(lease); }
    catch { if (this.pageActive && this.boundLease === lease) { this.draftMessage = '本机草稿保存失败，请保留本页并重试。'; } }
  }
  private updateSemester(value: string): void {
    if (this.loading || !this.editable()) { return; }
    this.semester = value; this.stageDraft();
  }
  private validSnapshot(snapshot: OnboardingSnapshot): boolean {
    return snapshot !== null && typeof snapshot === 'object' && typeof snapshot.revision === 'string' &&
      /^[a-f0-9]{64}$/.test(snapshot.revision) && snapshot.user !== null && typeof snapshot.user === 'object' &&
      typeof snapshot.user.user_id === 'string' && snapshot.user.user_id.length > 0 &&
      (this.boundLease === null || historyScope(this.baseUrl, snapshot.user.user_id) === this.boundLease.scope) &&
      typeof snapshot.user.onboarding_complete === 'boolean' &&
      validateTimetableList(snapshot.timetable, true).valid;
  }
  private async loadBaseline(): Promise<void> {
    if (!this.pageActive || this.completed || this.submission !== null || this.recoverableDraft !== null) { return; }
    const revision = this.requestRevision; const lease = this.boundLease;
    try {
      const snapshot = await new CampusFlowApi(this.baseUrl, this.token).onboardingSnapshot();
      if (!this.current(revision) || this.boundLease !== lease || this.submission !== null || this.recoverableDraft !== null) { return; }
      if (!this.validSnapshot(snapshot)) { throw new Error('invalid snapshot'); }
      if (this.expectedRevision.length === 0) {
        this.expectedRevision = snapshot.revision;
        this.baselineEntries = snapshot.timetable.map((entry: TimetableEntry) => normalizeTimetableEntry(entry));
      }
      this.baselineStale = this.expectedRevision !== snapshot.revision;
      this.latestSnapshot = this.baselineStale ? snapshot : null; this.latestPage = 0;
      if (this.baselineStale) { this.message = '账号配置已有变化，旧草稿和原版本保留。请查看差异后舍弃旧草稿，再按最新配置重新录入。'; }
      if (this.localRevision > 0) { this.stageDraft(); }
    } catch (error) {
      if (this.current(revision) && this.boundLease === lease) {
        if (error instanceof CampusFlowRequestError && error.statusCode === 401) { this.needsLogin = true; }
        this.message = this.needsLogin ? '登录已失效，请返回登录后继续。退出账号会清除本机草稿。'
          : '暂时无法核对账号版本，草稿可继续填写；保存前请重新核对。';
      }
    }
  }
  private restoreStoredDraft(): void {
    const record = this.recoverableDraft; const lease = this.boundLease;
    if (record === null || lease === null || !localDrafts.valid(lease)) { return; }
    const draft = record.payload as OnboardingDraft;
    this.requestRevision++; this.step = draft.step; this.semester = draft.semester;
    this.entries = draft.entries;
    this.editor = { date: draft.editor.date, title: draft.editor.title, start_time: draft.editor.start_time,
      end_time: draft.editor.end_time, location: draft.editor.location, teacher: draft.editor.teacher };
    this.editorOpen = draft.editorOpen;
    this.editorDirty = draft.editorDirty; this.editingIndex = draft.editingIndex; this.repeatWeeks = draft.repeatWeeks;
    this.sourceWarnings = draft.sourceWarnings; this.anchorDate = draft.anchorDate;
    this.expectedRevision = draft.expectedRevision; this.baselineEntries = draft.baselineEntries;
    this.submission = draft.submission; this.recoverableDraft = null; this.localRevision = record.localRevision;
    this.source = 'manual'; this.scheduleUrl = ''; this.importRows = []; this.importChoices = []; this.importGeneration++; this.draftRevision++;
    this.warnings = validateTimetableList(this.entries, true).warnings;
    this.notice = '已恢复本机草稿，原日期与原版本保持不变；不会自动提交。';
    if (this.submission !== null) { this.savePhase = 'uncertain'; this.checkSaveResult(); } else { this.loadBaseline(); }
  }
  private async discardStoredDraft(): Promise<void> {
    const lease = this.boundLease;
    if (lease === null || !localDrafts.valid(lease) || this.submission !== null || this.loading) { return; }
    const record = this.recoverableDraft ?? localDrafts.read(lease, this.draftKey) ?? null;
    if (record === null || (record.payload as OnboardingDraft).submission !== null || localDrafts.isBlocked(lease, this.draftKey)) { return; }
    try {
      const removed = await localDrafts.remove(lease, this.draftKey, record.localRevision);
      if (!removed || this.boundLease !== lease || !localDrafts.valid(lease) || !this.pageActive) { return; }
      this.requestRevision++; this.recoverableDraft = null; this.localRevision = 0;
      this.entries = []; this.sourceWarnings = []; this.baselineEntries = []; this.expectedRevision = '';
      this.baselineStale = false; this.latestSnapshot = null; this.step = 0; this.resetEditor();
      this.editorOpen = true; this.draftMessage = ''; this.message = ''; this.loadBaseline();
    } catch { if (this.boundLease === lease) { this.draftMessage = '未能舍弃本机草稿，请重试。'; } }
  }
  private latestRows(): CourseRow[] {
    return (this.latestSnapshot?.timetable ?? []).slice(this.latestPage * 10, this.latestPage * 10 + 10)
      .map((entry: TimetableEntry, index: number): CourseRow => ({ index: this.latestPage * 10 + index, entry: entry }));
  }

  private editorConnectionChanged(): void {
    this.editorGeneration++;
    if (this.submission === null && (this.busyLabel === '正在核对账号版本…' || this.busyLabel === '正在读取校园地点…')) {
      this.requestRevision++; this.loading = false; this.busyLabel = '';
    }
    if (this.busyLabel === '正在读取课表预览…') { this.cancelPreview(); }
    else { this.importRows = []; this.importChoices = []; this.importGeneration++; this.importWarnings = []; }
  }
  private resetEditor(): void {
    this.editorGeneration++;
    this.editor = { date: this.today(), title: '', start_time: '', end_time: '', location: '', teacher: '' };
    this.fieldErrors = { date: '', title: '', start_time: '', end_time: '', location: '', teacher: '' };
    this.editingIndex = -1;
    this.repeatWeeks = 1;
    this.editorDirty = false;
  }

  private updateEditor(field: string, value: string): void {
    if (this.loading || !this.editable()) { return; }
    const next: TimetableEntry = { date: this.editor.date, title: this.editor.title, start_time: this.editor.start_time,
      end_time: this.editor.end_time, location: this.editor.location, teacher: this.editor.teacher };
    if (field === 'date') { next.date = value; }
    else if (field === 'title') { next.title = value; }
    else if (field === 'start_time') { next.start_time = value; }
    else if (field === 'end_time') { next.end_time = value; }
    else if (field === 'location') { next.location = value; }
    else if (field === 'teacher') { next.teacher = value; }
    this.editor = next;
    this.editorDirty = true;
    this.message = '';
    // Once a field has reported an error, keep its correction visible while editing.
    if (this.fieldErrors.date.length + this.fieldErrors.title.length + this.fieldErrors.start_time.length +
      this.fieldErrors.end_time.length + this.fieldErrors.location.length + this.fieldErrors.teacher.length > 0) {
      this.fieldErrors = validateTimetableEntry(next).errors;
    }
    this.stageDraft();
  }

  private setRepeatWeeks(weeks: number): void {
    if (this.loading || !this.editable() || this.editingIndex >= 0) { return; }
    this.repeatWeeks = weeks;
    this.editorDirty = true; this.stageDraft();
  }

  private refreshDraft(entries: TimetableEntry[]): void {
    const result = validateTimetableList(entries, true);
    this.entries = result.entries;
    this.warnings = result.warnings;
    this.draftRevision++;
    this.pendingDelete = -1;
    this.pageIndex = Math.max(0, Math.min(this.pageIndex, Math.ceil(this.entries.length / 10) - 1));
    this.showAllWarnings = false; this.stageDraft();
  }

  private addEntry(keepOpen: boolean = false): void {
    if (this.loading || !this.editable()) { return; }
    const checked = validateTimetableEntry(this.editor);
    this.fieldErrors = checked.errors;
    if (!checked.valid) { this.message = '请先修正课程表单中标出的内容。'; this.focusRevision++; this.scroller.scrollEdge(Edge.Top); return; }
    const additions = expandWeeklyEntry(checked.entry, this.editingIndex < 0 ? this.repeatWeeks : 1);
    if (!additions.valid) { this.message = additions.errors[0].message; return; }
    const next = this.entries.map((entry: TimetableEntry) => normalizeTimetableEntry(entry));
    if (this.editingIndex >= 0) {
      if (this.editingIndex >= next.length) { this.message = '这条课程已变化，请重新选择。'; return; }
      next[this.editingIndex] = checked.entry;
    } else {
      next.push(...additions.entries);
    }
    const validated = validateTimetableList(next);
    if (!validated.valid) { this.message = validated.errors[0].message; return; }
    const edited = this.editingIndex >= 0;
    if (!edited) { this.lastEntry = normalizeTimetableEntry(checked.entry); this.lastRepeatWeeks = this.repeatWeeks; }
    this.refreshDraft(validated.entries);
    this.notice = edited ? '这一次课程已修改，确认前还可以调整。' : `已加入 ${additions.entries.length} 次课程，尚未保存到账号。`;
    this.message = '';
    this.resetEditor();
    this.editorOpen = keepOpen && !edited; this.stageDraft();
  }

  private reuseLastEntry(): void {
    if (this.loading || !this.editable() || this.lastEntry === null || this.editingIndex >= 0) { return; }
    if (this.editorDirty) { this.message = '请先加入或取消当前输入，再沿用上一门信息。'; return; }
    this.editorGeneration++; this.editor = normalizeTimetableEntry(this.lastEntry);
    this.repeatWeeks = this.lastRepeatWeeks; this.editorDirty = true; this.editorOpen = true;
    this.fieldErrors = { date: '', title: '', start_time: '', end_time: '', location: '', teacher: '' };
    this.notice = '已复制到新表单，请核对日期、时间与周次；尚未加入课表。';
    this.message = ''; this.stageDraft();
  }
  private changeImportChoices(choices: ImportRowChoice[]): void {
    if (this.loading || !this.editable()) { return; }
    this.importChoices = choices; this.message = '';
  }

  private newEntry(): void {
    if (this.loading || !this.editable() || this.editorDirty || this.editingIndex >= 0) { return; }
    this.resetEditor();
    this.source = 'manual';
    this.editorOpen = true;
    this.message = ''; this.stageDraft();
  }

  private editEntry(index: number): void {
    if (this.loading || !this.editable() || index < 0 || index >= this.entries.length) { return; }
    if (this.editorDirty || this.editingIndex >= 0) { this.message = '请先保存或取消当前编辑，再编辑另一条课程。'; return; }
    if (this.importRows.length > 0) { this.message = '请先加入所选课程或明确放弃本次预览，再编辑已有课程。'; return; }
    this.cancelPreview();
    this.source = 'manual';
    this.editor = normalizeTimetableEntry(this.entries[index]);
    this.editorGeneration++;
    this.editingIndex = index;
    this.repeatWeeks = 1;
    this.fieldErrors = { date: '', title: '', start_time: '', end_time: '', location: '', teacher: '' };
    this.editorDirty = false;
    this.editorOpen = true;
    this.message = '';
    this.step = 1; this.stageDraft();
    this.scroller.scrollEdge(Edge.Top);
  }

  private cancelEdit(): void {
    if (this.loading || !this.editable()) { return; }
    this.resetEditor();
    this.editorOpen = false;
    this.message = ''; this.stageDraft();
  }

  private requestDelete(index: number): void {
    if (this.loading || !this.editable()) { return; }
    if (this.editorDirty || this.editingIndex >= 0) { this.message = '请先保存或取消当前编辑，再移除课程。'; return; }
    this.pendingDelete = index;
  }

  private removeEntry(index: number): void {
    if (this.loading || !this.editable() || this.pendingDelete !== index || this.editorDirty || this.editingIndex >= 0) { return; }
    this.refreshDraft(this.entries.filter((_entry: TimetableEntry, entryIndex: number) => entryIndex !== index));
    this.notice = '已从待确认课表移除，尚未修改账号中的课表。';
    this.message = '';
  }

  private selectSource(source: string): void {
    if (this.loading || !this.editable() || this.source === source) { return; }
    if (this.editorDirty || this.editingIndex >= 0) { this.message = '请先加入、保存或取消当前课程，再切换录入方式。'; return; }
    if (this.importRows.length > 0) { this.message = '请先加入所选课程或明确放弃本次预览，再切换录入方式。'; return; }
    this.cancelPreview();
    this.source = source;
    this.message = '';
    if (source === 'manual' && this.entries.length === 0) { this.editorOpen = true; }
  }

  private updateScheduleUrl(value: string): void {
    if (this.loading || !this.editable()) { return; }
    this.requestRevision++;
    this.scheduleUrl = value;
    this.importRows = []; this.importChoices = []; this.importGeneration++;
    this.importWarnings = [];
    this.message = '';
  }

  private cancelPreview(): void {
    // Only preview is cancellable. A submitted save cannot be uncommitted from the UI.
    if (this.loading && this.busyLabel !== '正在读取课表预览…') { return; }
    this.requestRevision++;
    this.loading = false;
    this.busyLabel = '';
    this.importRows = []; this.importChoices = []; this.importGeneration++;
    this.importWarnings = [];
  }

  private failureMessage(error: Error, saving: boolean): string {
    if (error instanceof CampusFlowRequestError) {
      if (!saving && error.code.startsWith('IMPORT_')) { return error.message; }
      if (error.statusCode === 401) {
        this.needsLogin = true;
        return '登录已失效，请重新登录后继续；本机草稿按账号隔离，主动退出账号时会清除。';
      }
      if (error.statusCode === 422) {
        return saving ? '课表未通过服务校验，请返回检查课程、学期和时间。草稿已保留。'
          : '无法读取此订阅。请检查 HDUHelp 课表链接是否完整、有效，或改用手动录入。';
      }
      if (error.code === 'NETWORK_ERROR' || error.statusCode === 504 || error.statusCode === 408) {
        return saving ? '暂时无法确认保存结果，草稿仍保留；请先核对原保存操作，不会自动重复提交。'
          : '课表预览连接失败，请检查网络和服务地址后重试。现有草稿未改动。';
      }
    }
    return saving ? '暂时无法完成配置，已保留课表草稿，请稍后重试。'
      : '暂时无法读取课表预览，请稍后重试或手动录入。现有草稿未改动。';
  }

  private async previewImport(): Promise<void> {
    if (this.loading || !this.editable() || !this.pageActive || this.source !== 'subscription') { return; }
    const url = this.scheduleUrl.trim();
    if (url.length === 0 || url.length > 2048) { this.message = '请粘贴完整的 HDUHelp 课表订阅链接（不超过 2048 字符）。'; return; }
    const revision = ++this.requestRevision; const baseUrl = this.baseUrl; const token = this.token;
    this.loading = true;
    this.busyLabel = '正在读取课表预览…';
    this.message = '';
    this.importRows = []; this.importChoices = []; this.importGeneration++;
    this.importWarnings = [];
    try {
      const preview = await new CampusFlowApi(baseUrl, token).previewSubscription(url);
      if (!this.current(revision) || this.baseUrl !== baseUrl || this.token !== token || this.scheduleUrl.trim() !== url || this.source !== 'subscription') { return; }
      const checked = parseImportReview(JSON.stringify(preview));
      if (!checked.valid) {
        this.message = `预览未加入草稿：${checked.message}`;
        return;
      }
      this.importRows = checked.rows; this.importChoices = []; this.importGeneration++;
      this.importWarnings = checked.sourceWarnings;
        this.notice = '这是只读预览，尚未保存或绑定订阅。核对后可加入待确认课表。';
    } catch (error) {
      if (this.current(revision) && this.baseUrl === baseUrl && this.token === token) { this.message = this.failureMessage(error, false); }
    } finally {
      if (this.current(revision)) { this.loading = false; this.busyLabel = ''; }
    }
  }

  private acceptImport(): void {
    if (this.loading || !this.editable() || this.importRows.length === 0) { return; }
    const checked = assembleSelectedImport(this.importRows, this.entries, this.importChoices);
    if (!checked.valid) { this.message = `尚未加入：${checked.message} 原草稿与预览均保留。`; return; }
    this.refreshDraft(checked.entries);
    this.sourceWarnings = this.sourceWarnings.concat(this.importWarnings, checked.warnings.filter((issue: TimetableIssue) => issue.index < 0));
    this.importedNotice = '只保存最终确认的课程，不保存订阅链接，也不会再次抓取覆盖本次修改。';
    const count = checked.addedEntries.length;
    this.cancelPreview(); this.scheduleUrl = ''; this.editorOpen = false;
    this.notice = `已将所选 ${count} 次课程加入草稿，重复 ${checked.duplicateCount} 条、明确排除 ${checked.excludedCount} 条；尚未保存到账号。`;
    this.message = ''; this.stageDraft();
  }

  private nextStep(): void {
    if (this.loading || !this.editable()) { return; }
    this.message = '';
    if (this.step === 0) {
      if (this.semester.trim().length === 0 || Array.from(this.semester.trim()).length > 80) {
        this.message = '请填写学期，最多 80 字。'; return;
      }
      this.step = 1;
    } else if (this.step === 1) {
      if (this.editorDirty || this.editingIndex >= 0) { this.message = '表单中还有未加入的修改，请先保存或取消编辑。'; return; }
      if (this.importRows.length > 0) { this.message = '请先将预览加入课表，或放弃本次预览。'; return; }
      const checked = validateTimetableList(this.entries);
      if (!checked.valid) { this.message = checked.errors[0].message; return; }
      this.refreshDraft(checked.entries);
      this.step = 2;
      this.scheduleUrl = '';
    }
    this.stageDraft(); this.scroller.scrollEdge(Edge.Top);
  }

  private previousStep(): void {
    if (this.loading || !this.editable() || this.step === 0) { return; }
    this.step--;
    this.message = ''; this.stageDraft();
    this.scroller.scrollEdge(Edge.Top);
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

  private campusMap(snapshot: CampusDataSnapshot): CampusMapSummary | null {
    if (snapshot === null || snapshot.package === null || snapshot.package === undefined ||
      snapshot.package.school !== this.school || snapshot.package.campus !== this.campus ||
      !Array.isArray(snapshot.places) || snapshot.places.length === 0 || snapshot.places.length > 120) { return null; }
    const places: CampusPlaceImport[] = [];
    for (const item of snapshot.places) {
      if (item === null || typeof item.name !== 'string' || item.name.trim().length === 0 ||
        typeof item.category !== 'string' || typeof item.zone !== 'string' || !Array.isArray(item.aliases) ||
        item.aliases.some((alias: string) => typeof alias !== 'string')) { return null; }
      places.push({ name: item.name, category: item.category, zone: item.zone, aliases: item.aliases.slice() });
    }
    return { campus_name: `${this.school}${this.campus}`, places: places,
      warnings: ['使用杭电下沙校区地点参考数据；未知通路仍需核对。'] };
  }

  private finishCurrent(revision: number, lease: DraftLease | null, baseUrl: string, token: string): boolean {
    return this.current(revision) && this.boundLease === lease && this.baseUrl === baseUrl && this.token === token && this.step === 2;
  }

  private async finish(): Promise<void> {
    if (this.loading || !this.editable() || !this.pageActive || this.step !== 2 || this.baselineStale) { return; }
    const checked = validateTimetableList(this.entries);
    if (!checked.valid) { this.message = checked.errors[0].message; return; }
    const semester = this.semester.trim();
    if (semester.length === 0 || Array.from(semester).length > 80) { this.message = '请返回填写有效学期。'; return; }
    const lease = this.boundLease; const baseUrl = this.baseUrl; const token = this.token;
    const baselineRequest = this.requestRevision;
    this.loading = true; this.busyLabel = '正在核对账号版本…';
    if (this.expectedRevision.length === 0) { await this.loadBaseline(); }
    // A discarded read must also abort its caller; it is not permission to use another account's revision.
    if (!this.finishCurrent(baselineRequest, lease, baseUrl, token)) { return; }
    if (this.expectedRevision.length === 0 || this.baselineStale || !this.editable()) { this.loading = false; this.busyLabel = ''; return; }
    const expectedRevision = this.expectedRevision;
    const revision = ++this.requestRevision;
    this.loading = true; this.busyLabel = '正在读取校园地点…'; this.message = '';
    try {
      const data = await new CampusFlowApi(baseUrl, token).campusData();
      if (!this.finishCurrent(revision, lease, baseUrl, token)) { return; }
      const map = this.campusMap(data);
      if (map === null) { this.message = '校园地点数据缺失或校区不匹配，尚未提交。请稍后重试，课表草稿仍保留。'; return; }
      this.submission = { operationId: timetableOperationId(), expectedRevision: expectedRevision,
        school: this.school, campus: this.campus, semester: semester, timetable: checked.entries, campusMap: map };
      this.loading = false;
      await this.submitFrozen();
    } catch (error) { if (this.finishCurrent(revision, lease, baseUrl, token)) { this.message = this.failureMessage(error, false); } }
    finally { if (this.finishCurrent(revision, lease, baseUrl, token)) { this.loading = false; this.busyLabel = ''; } }
  }
  private validReceipt(receipt: OnboardingSaveReceipt, submission: OnboardingSubmission): boolean {
    return receipt !== null && typeof receipt === 'object' && receipt.operation_id === submission.operationId &&
      receipt.status === 'applied' && receipt.previous_revision === submission.expectedRevision &&
      typeof receipt.revision === 'string' && /^[a-f0-9]{64}$/.test(receipt.revision) &&
      receipt.timetable_count === submission.timetable.length && receipt.campus_place_count === submission.campusMap.places.length &&
      typeof receipt.applied_at === 'string' && Number.isFinite(Date.parse(receipt.applied_at));
  }
  private sameSubmission(left: OnboardingSubmission, right: OnboardingSubmission): boolean {
    return left.operationId === right.operationId && left.expectedRevision === right.expectedRevision &&
      left.school === right.school && left.campus === right.campus && left.semester === right.semester &&
      left.timetable.length === right.timetable.length && left.timetable.every((entry: TimetableEntry, index: number) => {
        const other = right.timetable[index];
        return entry.date === other.date && entry.title === other.title && entry.start_time === other.start_time &&
          entry.end_time === other.end_time && entry.location === other.location && entry.teacher === other.teacher;
      }) && left.campusMap.campus_name === right.campusMap.campus_name &&
      JSON.stringify(left.campusMap.warnings) === JSON.stringify(right.campusMap.warnings) &&
      left.campusMap.places.length === right.campusMap.places.length &&
      left.campusMap.places.every((place: CampusPlaceImport, index: number) => {
        const other = right.campusMap.places[index];
        return place.name === other.name && place.category === other.category && place.zone === other.zone &&
          JSON.stringify(place.aliases) === JSON.stringify(other.aliases);
      });
  }
  private async persistSubmission(): Promise<void> {
    const lease = this.boundLease; const submission = this.submission;
    if (lease === null || !localDrafts.valid(lease) || submission === null) { throw new Error('draft storage unavailable'); }
    const record = localDrafts.read(lease, this.draftKey) ?? null;
    if (record !== null && (record.payload as OnboardingDraft).submission?.operationId === submission.operationId) {
      const stored = (record.payload as OnboardingDraft).submission;
      if (stored === null || !this.sameSubmission(stored, submission)) { throw new Error('operation mismatch'); }
      this.localRevision = record.localRevision;
    } else { this.localRevision = localDrafts.stage(lease, this.draftKey, this.draftPayload()).localRevision; }
    await localDrafts.flush(lease);
    await localDrafts.beginOperation(lease, { kind: 'onboarding', id: submission.operationId,
      draftKind: 'onboarding', ownerId: 'main', localRevision: this.localRevision });
    if (!localDrafts.valid(lease) || this.boundLease !== lease) { throw new Error('stale lease'); }
  }
  private async submitFrozen(): Promise<void> {
    if (this.submission === null || this.loading || !this.pageActive || this.completed) { return; }
    const submission = this.submission; const revision = ++this.requestRevision;
    this.loading = true; this.busyLabel = '正在保存已确认课表…'; this.savePhase = 'uncertain'; this.message = '';
    let sent = false;
    try {
      await this.persistSubmission();
      if (!this.current(revision)) { return; }
      sent = true;
      const campusMap: CampusMapSummary = { campus_name: submission.campusMap.campus_name,
        warnings: submission.campusMap.warnings,
        places: submission.campusMap.places.map((place: DraftCampusPlace): CampusPlaceImport => ({ name: place.name,
          category: place.category, zone: place.zone, aliases: place.aliases })) };
      const result = await new CampusFlowApi(this.baseUrl, this.token).completeOnboarding(submission.school, submission.campus,
        submission.semester, submission.timetable, campusMap, submission.operationId, submission.expectedRevision);
      if (!this.current(revision)) { return; }
      if (result === null || result.user === undefined || result.user === null || result.user.onboarding_complete !== true ||
        result.timetable_count !== submission.timetable.length || result.campus_place_count !== submission.campusMap.places.length ||
        result.receipt === null || result.receipt === undefined || !this.validReceipt(result.receipt, submission)) {
        this.message = '服务端回执不完整，请先核对原保存操作；不会自动重复提交。'; return;
      }
      this.savePhase = 'applied'; this.loading = false;
      await this.finishApplied();
    } catch (error) {
      if (!this.current(revision)) { return; }
      if (sent && error instanceof CampusFlowRequestError && error.code === 'ONBOARDING_STALE') {
        const lease = this.boundLease;
        try { if (lease !== null) { await localDrafts.resolveOperation(lease, 'onboarding', submission.operationId); } }
        catch { this.message = '账号未被覆盖，但本机操作记录清理失败。原标识仍保留，请重新核对。'; return; }
        if (!this.current(revision)) { return; }
        this.submission = null; this.baselineStale = true; this.savePhase = 'stale'; this.stageDraft();
        this.message = '账号配置已变化，本次未覆盖。旧草稿仍保留，请核对差异后重新录入。'; this.loadBaseline();
      } else {
        this.message = sent ? '保存结果尚未确认，可能已经生效。请先核对原操作，暂勿重复提交。'
          : '本机保存未完成，本次未向账号提交；请先核对原标识，再重试同一份内容。';
        if (error instanceof CampusFlowRequestError && error.statusCode === 401) { this.needsLogin = true; }
      }
    } finally { if (this.current(revision)) { this.loading = false; this.busyLabel = ''; } }
  }
  private async checkSaveResult(): Promise<void> {
    if (this.submission === null || this.loading || !this.pageActive || this.completed) { return; }
    const submission = this.submission; const revision = ++this.requestRevision;
    this.loading = true; this.busyLabel = '正在核对原保存…'; this.message = '';
    try {
      const receipt = await new CampusFlowApi(this.baseUrl, this.token).onboardingOperation(submission.operationId);
      if (!this.current(revision)) { return; }
      if (!this.validReceipt(receipt, submission)) { this.savePhase = 'uncertain'; this.message = '原保存回执不完整，请稍后再核对。'; return; }
      this.savePhase = 'applied'; this.loading = false; await this.finishApplied();
    } catch (error) {
      if (!this.current(revision)) { return; }
      if (error instanceof CampusFlowRequestError && error.statusCode === 401) { this.needsLogin = true; }
      this.savePhase = error instanceof CampusFlowRequestError && error.statusCode === 404 &&
        error.code === 'ONBOARDING_OPERATION_NOT_FOUND' ? 'retryable' : 'uncertain';
      this.message = this.savePhase === 'retryable' ? '暂未查到原操作。可再次核对，或明确使用原标识与原内容重试。'
        : '暂时无法核对原保存，草稿和操作标识仍保留；请稍后重试核对。';
    } finally { if (this.current(revision)) { this.loading = false; this.busyLabel = ''; } }
  }
  private async retrySameSubmission(): Promise<void> {
    if (this.savePhase !== 'retryable') { return; }
    await this.submitFrozen();
  }
  private async finishApplied(): Promise<void> {
    if (this.submission === null || this.loading || !this.pageActive || this.completed || this.savePhase !== 'applied') { return; }
    const submission = this.submission; const revision = ++this.requestRevision; const lease = this.boundLease;
    this.loading = true; this.busyLabel = '正在读取最新配置…';
    try {
      const snapshot = await new CampusFlowApi(this.baseUrl, this.token).onboardingSnapshot();
      if (!this.current(revision) || this.boundLease !== lease) { return; }
      if (!this.validSnapshot(snapshot) || snapshot.user.onboarding_complete !== true) { throw new Error('latest configuration unavailable'); }
      if (lease !== null) {
        await localDrafts.resolveOperation(lease, 'onboarding', submission.operationId, true);
      }
      if (!this.current(revision) || this.boundLease !== lease) { return; }
      this.completed = true; this.loading = false; this.scheduleUrl = ''; this.submission = null;
      this.onCompleted(snapshot.user);
    } catch (error) { if (this.current(revision)) {
      if (error instanceof CampusFlowRequestError && error.statusCode === 401) { this.needsLogin = true; }
      this.message = '原保存已有成功回执，最新配置读取或本机清理未完成；请重试读取，不会重复提交。';
    } }
    finally { if (this.current(revision)) { this.loading = false; this.busyLabel = ''; } }
  }

  @Builder
  private DraftRecovery() {
    if (this.recoverableDraft !== null) {
      FeedbackPanel({ kind: 'info', title: '继续上次的录课草稿',
        message: '原日期、表单和课表版本保留；未加入的订阅预览与逐行选择未存入本机，需重新读取。已提交操作先查询结果。',
        actionLabel: '恢复草稿', onAction: () => this.restoreStoredDraft() })
      if ((this.recoverableDraft.payload as OnboardingDraft).submission === null) {
        Button('舍弃上次草稿，重新开始').width('100%').constraintSize({ minHeight: 48 })
          .fontColor(AppTheme.quiet).backgroundColor(AppTheme.surface).onClick(() => this.discardStoredDraft())
      }
    }
    if (this.draftMessage.length > 0) {
      FeedbackPanel({ kind: 'error', title: '本机草稿', message: this.draftMessage,
        actionLabel: '重试保存草稿', onAction: () => this.flushDraft() })
    }
    if (this.submission !== null) {
      FeedbackPanel({ kind: 'info', title: this.savePhase === 'applied' ? '已收到原保存回执' : '先核对原保存',
        message: this.message.length > 0 ? this.message : '已保留原操作标识与冻结内容。结果未确认前，不会新建另一笔保存。',
        actionLabel: this.savePhase === 'applied' ? '读取最新配置' : '核对原保存结果', busy: this.loading,
        onAction: () => { if (this.savePhase === 'applied') { this.finishApplied(); } else { this.checkSaveResult(); } } })
      if (this.savePhase === 'retryable') {
        Button('使用原标识与原内容重试').width('100%').constraintSize({ minHeight: 48 })
          .fontColor(AppTheme.accent).backgroundColor(AppTheme.accentSoft).enabled(!this.loading)
          .onClick(() => this.retrySameSubmission())
      }
    } else if (this.baselineStale) {
      FeedbackPanel({ kind: 'info', title: '账号配置有了新版本',
        message: '以下草稿仍基于原版本。可对照账号最新配置；舍弃旧草稿后才能重新录入，不能覆盖新版本。' })
      if (this.latestSnapshot !== null) {
        Text(`${this.latestSnapshot.user.school} · ${this.latestSnapshot.user.campus} · ${this.latestSnapshot.user.semester}`)
          .fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
        Button(this.latestExpanded ? '收起账号最新课程' : `查看账号最新 ${this.latestSnapshot.timetable.length} 次课程`)
          .width('100%').constraintSize({ minHeight: 48 }).fontColor(AppTheme.accent).backgroundColor(AppTheme.accentSoft)
          .onClick(() => this.latestExpanded = !this.latestExpanded)
        if (this.latestExpanded) {
          ForEach(this.latestRows(), (row: CourseRow) => { this.CourseCard(row, false) },
            (row: CourseRow) => `latest-${this.latestSnapshot?.revision}-${row.index}`)
          Row({ space: 8 }) {
            Button('上一页').layoutWeight(1).constraintSize({ minHeight: 48 }).enabled(this.latestPage > 0).onClick(() => this.latestPage--)
            Button('下一页').layoutWeight(1).constraintSize({ minHeight: 48 })
              .enabled((this.latestPage + 1) * 10 < (this.latestSnapshot?.timetable.length ?? 0)).onClick(() => this.latestPage++)
          }.width('100%')
        }
      }
      Button('舍弃旧草稿，按最新配置重新开始').width('100%').constraintSize({ minHeight: 48 })
        .fontColor(AppTheme.danger).backgroundColor(AppTheme.dangerSoft).onClick(() => this.discardStoredDraft())
    } else if (this.expectedRevision.length === 0 && this.recoverableDraft === null) {
      FeedbackPanel({ kind: 'info', title: '保存前需核对账号版本', message: '现在可以填写课程，联网核对后再确认保存。',
        actionLabel: '重新核对版本', onAction: () => this.loadBaseline() })
    }
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
        .enabled(!this.loading && this.pageIndex > 0)
        .onClick(() => { this.pageIndex--; })
      Text(`${this.pageIndex + 1} / ${Math.max(1, Math.ceil(this.entries.length / 10))}`)
        .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet)
      Button('下一页').layoutWeight(1).constraintSize({ minHeight: 48 }).fontSize(AppTheme.metaSize)
        .fontColor(AppTheme.accent).backgroundColor(AppTheme.accentSoft)
        .enabled(!this.loading && (this.pageIndex + 1) * 10 <
          this.entries.length)
        .onClick(() => { this.pageIndex++; })
    }.width('100%')
  }

  @Builder
  private Editor() {
    TimetableEntryEditor({ entry: this.editor, errors: this.fieldErrors, repeatWeeks: this.repeatWeeks,
      editing: this.editingIndex >= 0, busy: this.loading || !this.editable(), active: this.pageActive,
      anchorDate: this.anchorDate, idPrefix: 'onboarding-main',
      contextKey: `onboarding-${this.boundLease?.generation ?? 0}-${this.editorGeneration}-${this.editingIndex}`,
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
      Text('链接可能含私人凭据，仅用于本次读取，不会随首次配置保存。以后可从校园进入课表维护或校园连接。')
        .fontSize(AppTheme.metaSize).lineHeight(21).fontColor(AppTheme.quiet).width('100%')
      Button(this.loading && this.busyLabel === '正在读取课表预览…' ? '正在读取…' : '读取预览，不保存')
        .width('100%').constraintSize({ minHeight: 50 }).fontSize(AppTheme.bodySize).fontColor(AppTheme.onAccent)
        .backgroundColor(AppTheme.accent).borderRadius(AppTheme.controlRadius)
        .enabled(!this.loading && this.importRows.length === 0).onClick(() => this.previewImport())
      if (this.importRows.length > 0) {
        TimetableImportPanel({ rows: this.importRows, currentDraft: this.entries, choices: this.importChoices,
          warnings: this.importWarnings, busy: this.loading || !this.editable(), active: this.pageActive,
          anchorDate: this.anchorDate, contextKey: `onboarding-${this.boundLease?.generation ?? 0}-${this.importGeneration}`,
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
        Text(`待确认课表 · ${this.entries.length} 次`).fontSize(AppTheme.sectionTitle)
          .fontWeight(FontWeight.Bold).fontColor(AppTheme.ink).layoutWeight(1)
        if (this.step === 1 && !this.editorOpen && this.source === 'manual') {
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
        FeedbackPanel({ kind: 'empty', title: '先添加一门课程',
          message: '可以手动填写，也可从订阅读取预览。只有核对并确认后，课程才会保存到账号。' })
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
        this.CourseCard(row, this.step === 1 && this.editable())
      }, (row: CourseRow) => `draft-${this.draftRevision}-${row.index}-${this.step}`)
      if (this.entries.length > 10) { this.Pagination() }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      Scroll(this.scroller) {
        Column({ space: AppTheme.sectionGap }) {
          Column({ space: 10 }) {
            Row({ space: 8 }) {
              AppIcon({ name: 'calendar', iconSize: 22, color: AppTheme.accent })
              Text('首次使用').fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium).fontColor(AppTheme.accent)
              Blank()
              Text(`${this.step + 1} / 3`).fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet)
            }.width('100%')
            Text(this.step === 0 ? '校园与学期' : (this.step === 1 ? '添加真实课程' : '核对完整课表'))
              .fontSize(AppTheme.pageTitle).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink).width('100%')
            Text(this.step === 0 ? '课表用来避开上课时间，校园地点用来辅助安排。' :
              (this.step === 1 ? '手动录入和订阅导入都可以；确认前均为草稿。' : '保存眼前这份课表，之后助手才能据此安排学习。'))
              .fontSize(AppTheme.bodySize).lineHeight(24).fontColor(AppTheme.quiet).width('100%')
            Row({ space: 6 }) {
              ForEach([0, 1, 2], (step: number) => {
                Row().height(4).layoutWeight(1).borderRadius(2)
                  .backgroundColor(step <= this.step ? AppTheme.accent : AppTheme.line)
              }, (step: number) => step.toString())
            }.width('100%').accessibilityText(`第 ${this.step + 1} 步，共三步`)
          }.width('100%').alignItems(HorizontalAlign.Start)

          this.DraftRecovery()
          if (this.step === 0) {
            Row() {
              AppIllustration({ source: $r('app.media.xj_onboarding'), imageWidth: 188, imageHeight: 140 })
            }.width('100%').justifyContent(FlexAlign.Center)
            Column({ space: 16 }) {
              Text('当前支持的校园').fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
              Text(this.school).fontSize(20).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink).width('100%')
              Text(`${this.campus} · 内置校园地点参考数据`)
                .fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet).width('100%')
              Divider().color(AppTheme.line)
              this.FormField('学期 *', '例如：2026-2027 第一学期', this.semester, '',
                (value: string) => this.updateSemester(value))
              Text('没有 HDUHelp 订阅链接也可以继续，下一步先录入一门真实课程即可。模型、语音与提醒可以开始使用后再设置。')
                .fontSize(AppTheme.bodySize).lineHeight(22).fontColor(AppTheme.quiet).width('100%')
            }.width('100%').alignItems(HorizontalAlign.Start).padding(AppTheme.cardInset)
              .backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
          } else if (this.step === 1) {
            Row({ space: 8 }) {
              Button('手动录入').layoutWeight(1).constraintSize({ minHeight: 50 }).fontSize(AppTheme.bodySize)
                .fontColor(this.source === 'manual' ? AppTheme.onAccent : AppTheme.quiet)
                .backgroundColor(this.source === 'manual' ? AppTheme.accent : AppTheme.surface)
                .borderRadius(AppTheme.controlRadius).enabled(!this.loading && this.editable())
                .accessibilityText(`手动录入${this.source === 'manual' ? '，已选择' : ''}`)
                .onClick(() => this.selectSource('manual'))
              Button('订阅导入').layoutWeight(1).constraintSize({ minHeight: 50 }).fontSize(AppTheme.bodySize)
                .fontColor(this.source === 'subscription' ? AppTheme.onAccent : AppTheme.quiet)
                .backgroundColor(this.source === 'subscription' ? AppTheme.accent : AppTheme.surface)
                .borderRadius(AppTheme.controlRadius).enabled(!this.loading && this.editable())
                .accessibilityText(`订阅导入${this.source === 'subscription' ? '，已选择' : ''}`)
                .onClick(() => this.selectSource('subscription'))
            }.width('100%')
            if (this.source === 'manual') {
              if (this.editorOpen) { this.Editor() }
              else {
                Button('添加课程').width('100%').constraintSize({ minHeight: 50 }).fontSize(AppTheme.bodySize)
                  .fontColor(AppTheme.accent).backgroundColor(AppTheme.accentSoft)
                  .enabled(!this.loading && this.editable()).onClick(() => this.newEntry())
              }
            } else { this.ImportPanel() }
            if (this.notice.length > 0) {
              Text(this.notice).fontSize(AppTheme.metaSize).lineHeight(21).fontColor(AppTheme.quiet).width('100%')
            }
            this.DraftList()
          } else {
            Column({ space: 10 }) {
              Text(`${this.school} · ${this.campus}`).fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium)
                .fontColor(AppTheme.ink).width('100%')
              Text(this.semester).fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet).width('100%')
              Text(`即将保存 ${this.entries.length} 次课程，不会再次抓取或替换为另一份课表。`)
                .fontSize(AppTheme.bodySize).lineHeight(22).fontColor(AppTheme.quiet).width('100%')
              if (this.importedNotice.length > 0) {
                Text(this.importedNotice).fontSize(AppTheme.metaSize).lineHeight(21).fontColor(AppTheme.quiet).width('100%')
              }
              Text('这些课程将保存到当前账号，并用于助手规划；未提交草稿保存在本机并按账号隔离，退出账号会清除。')
                .fontSize(AppTheme.metaSize).lineHeight(20).fontColor(AppTheme.quiet).width('100%')
            }.width('100%').alignItems(HorizontalAlign.Start).padding(AppTheme.cardInset)
              .backgroundColor(AppTheme.accentSoft).borderRadius(AppTheme.cardRadius)
            this.DraftList()
          }
        }.width('100%').alignItems(HorizontalAlign.Start)
          .padding({ left: AppTheme.pageInset, right: AppTheme.pageInset, top: 24, bottom: 28 })
      }.layoutWeight(1).width('100%').clip(true).scrollBar(BarState.Off)
      Column({ space: 10 }) {
        if (this.message.length > 0) {
          FeedbackPanel({ kind: 'error', title: '请先核对', message: this.message })
        }
        if (this.loading) {
          FeedbackPanel({ kind: 'loading', title: this.busyLabel, message: '课表草稿仍保留，请稍候。' })
        }
        Row({ space: 10 }) {
          if (this.loading && this.busyLabel === '正在读取课表预览…') {
            Button('取消读取').constraintSize({ minHeight: 50 }).fontSize(AppTheme.bodySize)
              .fontColor(AppTheme.quiet).backgroundColor(AppTheme.field).onClick(() => this.cancelPreview())
          } else if (this.step > 0) {
            Button(this.step === 2 ? '返回编辑' : '上一步').constraintSize({ minHeight: 50 })
              .fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet).backgroundColor(AppTheme.field)
              .enabled(!this.loading && this.editable()).onClick(() => this.previousStep())
          }
          Button(this.completed ? '已完成配置' : (this.step === 2 ? '确认课表并开始使用' :
            (this.step === 0 ? '下一步：添加课表' : '下一步：核对课表')))
            .layoutWeight(1).constraintSize({ minHeight: 50 }).fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium)
            .fontColor(AppTheme.onAccent).backgroundColor(AppTheme.accent).borderRadius(AppTheme.controlRadius)
            .enabled(!this.loading && this.editable() && !this.baselineStale)
            .onClick(() => { if (this.step === 2) { this.finish(); } else { this.nextStep(); } })
        }.width('100%')
        if (this.needsLogin) {
          Button('返回登录（退出账号会清除本机草稿）').width('100%').constraintSize({ minHeight: 48 })
            .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).backgroundColor(Color.Transparent)
            .enabled(!this.loading).onClick(() => this.onReturnToLogin())
        }
      }.width('100%').padding({ left: 20, right: 20, top: 12, bottom: 16 })
        .backgroundColor(AppTheme.surface).border({ width: { top: 1 }, color: AppTheme.line })
    }.width('100%').height('100%').backgroundColor(AppTheme.canvas)
  }
}
