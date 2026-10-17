import { TimetableEntry } from '../model/ApiModels';
import { CampusFlowApi } from '../services/CampusFlowApi';
import { TimetableMaintenance, TimetableMaintenanceState } from '../utils/TimetableMaintenance';
import { TimetableFieldErrors, TimetableIssue, normalizeTimetableEntry, validateTimetableEntry, validateTimetableList, parseTimetablePreview, expandWeeklyEntry } from '../utils/OnboardingTimetable';
import { shanghaiDate } from '../utils/DailyAgenda';
import { AppTheme } from '../theme/AppTheme';
import { EvidencePanel } from '../components/EvidencePanel';
import { AppIcon } from '../components/AppIcon';
import { FeedbackPanel } from '../components/FeedbackPanel';

interface CourseRow { index: number; entry: TimetableEntry; }

@Component
export struct TimetablePage {
  @Prop baseUrl: string;
  @Prop token: string;
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
  @State private importEntries: TimetableEntry[] = [];
  @State private importWarnings: TimetableIssue[] = [];
  @State private importPage: number = 0;
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
  private controller: TimetableMaintenance | null = null;
  private pageActive: boolean = false;
  private requestRevision: number = 0;
  private previewBusy: boolean = false;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.pageActive = true;
    if (this.controller === null) {
      this.resetEditor();
      this.controller = new TimetableMaintenance(new CampusFlowApi(this.baseUrl, this.token),
        (state: TimetableMaintenanceState) => {
          if (!this.pageActive) { return; }
          if (JSON.stringify(this.entries) !== JSON.stringify(state.entries)) {
            this.entries = state.entries;
            this.draftRevision++;
            this.pendingDelete = -1;
            this.pageIndex = Math.max(0, Math.min(this.pageIndex, Math.ceil(this.entries.length / 10) - 1));
          }
          this.view = state;
          this.warnings = state.warnings;
          this.loading = this.previewBusy || ['loading', 'saving', 'checking'].includes(state.phase);
          if (state.phase === 'saved') { this.reviewOpen = false; this.notice = ''; this.message = ''; }
          if (!state.dirty) { this.sourceWarnings = []; }
        }, () => { if (this.pageActive && this.active) { this.onTimetableChanged(); } });
    }
    this.controller.setActive(this.active);
  }

  aboutToDisappear(): void {
    this.pageActive = false;
    this.requestRevision++;
    this.scheduleUrl = '';
    this.controller?.dispose();
    this.controller = null;
  }

  private activityChanged(): void {
    if (!this.active) {
      this.requestRevision++;
      this.previewBusy = false;
      this.scheduleUrl = '';
    }
    this.controller?.setActive(this.active);
  }

  private editable(): boolean { return this.controller !== null && this.controller.canEdit(); }
  private current(revision: number): boolean { return this.pageActive && this.active && this.requestRevision === revision; }
  private resetEditor(): void {
    this.editor = { date: shanghaiDate(Date.now()), title: '', start_time: '', end_time: '', location: '', teacher: '' };
    this.fieldErrors = { date: '', title: '', start_time: '', end_time: '', location: '', teacher: '' };
    this.editingIndex = -1; this.repeatWeeks = 1; this.editorDirty = false;
  }
  private syncPending(): void {
    this.controller?.setEditorPending(this.editorDirty || this.editingIndex >= 0 || this.importEntries.length > 0);
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
    this.fieldErrors = { date: '', title: '', start_time: '', end_time: '', location: '', teacher: '' };
    this.syncPending();
  }
  private setRepeatWeeks(weeks: number): void {
    if (this.loading || !this.editable() || this.editingIndex >= 0) { return; }
    this.repeatWeeks = weeks; this.editorDirty = true; this.syncPending();
  }
  private addEntry(): void {
    if (this.loading || !this.editable()) { return; }
    const checked = validateTimetableEntry(this.editor); this.fieldErrors = checked.errors;
    if (!checked.valid) { this.message = '请先修正课程表单中标出的内容。'; return; }
    const additions = expandWeeklyEntry(checked.entry, this.editingIndex < 0 ? this.repeatWeeks : 1);
    if (!additions.valid) { this.message = additions.errors[0].message; return; }
    const next = this.entries.map((entry: TimetableEntry) => normalizeTimetableEntry(entry));
    if (this.editingIndex >= 0) {
      if (this.editingIndex >= next.length) { this.message = '课程草稿已变化，请重新选择。'; return; }
      next[this.editingIndex] = checked.entry;
    } else { next.push(...additions.entries); }
    if (!this.controller?.replaceDraft(next)) { return; }
    this.resetEditor(); this.editorOpen = false; this.syncPending();
    this.notice = '课程已加入本页草稿，尚未保存到账号。'; this.message = '';
  }
  private newEntry(): void {
    if (this.loading || !this.editable() || this.editorDirty || this.editingIndex >= 0) { return; }
    this.resetEditor(); this.source = 'manual'; this.editorOpen = true; this.message = '';
  }
  private editEntry(index: number): void {
    if (this.loading || !this.editable() || index < 0 || index >= this.entries.length) { return; }
    if (this.editorDirty || this.editingIndex >= 0) { this.message = '请先加入或取消当前编辑，再编辑另一条课程。'; return; }
    this.cancelPreview(); this.source = 'manual'; this.editor = normalizeTimetableEntry(this.entries[index]);
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
      this.pendingDelete = -1; this.notice = '已从草稿移除，账号课表尚未改动。'; this.message = '';
    }
  }
  private selectSource(source: string): void {
    if (this.loading || !this.editable() || source === this.source) { return; }
    if (this.editorDirty || this.editingIndex >= 0) { this.message = '请先加入或取消当前表单，再切换录入方式。'; return; }
    this.cancelPreview(); this.source = source; this.message = '';
  }
  private updateScheduleUrl(value: string): void {
    if (this.loading || !this.editable()) { return; }
    this.requestRevision++; this.scheduleUrl = value; this.importEntries = []; this.importWarnings = []; this.importPage = 0;
    this.message = ''; this.syncPending();
  }
  private cancelPreview(): void {
    this.requestRevision++; this.previewBusy = false; this.importEntries = []; this.importWarnings = []; this.importPage = 0;
    this.loading = ['loading', 'saving', 'checking'].includes(this.view.phase); this.busyLabel = ''; this.syncPending();
  }
  private async previewImport(): Promise<void> {
    if (this.loading || !this.editable() || !this.active || this.source !== 'subscription') { return; }
    const url = this.scheduleUrl.trim();
    if (url.length === 0 || url.length > 2048) { this.message = '请粘贴完整的 HDUHelp 课表订阅链接（不超过 2048 字符）。'; return; }
    const revision = ++this.requestRevision; this.previewBusy = true; this.loading = true;
    this.busyLabel = '正在读取课表预览…'; this.message = ''; this.importEntries = []; this.importWarnings = [];
    try {
      const result = await new CampusFlowApi(this.baseUrl, this.token).previewSubscription(url);
      if (!this.current(revision) || this.scheduleUrl.trim() !== url || this.source !== 'subscription') { return; }
      const checked = parseTimetablePreview(JSON.stringify(result));
      if (!checked.valid) { this.message = checked.errors[0].message; return; }
      this.importEntries = checked.entries; this.importWarnings = checked.warnings; this.importPage = 0; this.syncPending();
      this.notice = '候选课程尚未加入草稿。核对后可加入；不会保存订阅链接。';
    } catch {
      if (this.current(revision)) { this.message = '预览读取失败，请检查连接或链接有效性；现有课表草稿未改动。'; }
    } finally {
      if (this.current(revision)) { this.previewBusy = false; this.loading = false; this.busyLabel = ''; }
    }
  }
  private acceptImport(): void {
    if (this.loading || !this.editable() || this.importEntries.length === 0) { return; }
    const checked = validateTimetableList(this.entries.concat(this.importEntries));
    if (!checked.valid) { this.message = `无法合并：${checked.errors[0].message} 原草稿和候选均保留。`; return; }
    if (!this.controller?.replaceDraft(checked.entries)) { return; }
    this.sourceWarnings = this.sourceWarnings.concat(this.importWarnings.filter((issue: TimetableIssue) => issue.index < 0));
    this.cancelPreview(); this.scheduleUrl = ''; this.editorOpen = false; this.notice = '候选已加入草稿，可逐条编辑后保存。'; this.message = '';
  }
  private draftRows(): CourseRow[] {
    return this.entries.slice(this.pageIndex * 10, this.pageIndex * 10 + 10)
      .map((entry: TimetableEntry, index: number): CourseRow => ({ index: this.pageIndex * 10 + index, entry: entry }));
  }
  private previewRows(): CourseRow[] {
    return this.importEntries.slice(this.importPage * 10, this.importPage * 10 + 10)
      .map((entry: TimetableEntry, index: number): CourseRow => ({ index: this.importPage * 10 + index, entry: entry }));
  }
  private courseRange(): string {
    if (this.entries.length === 0) { return '尚未添加课程'; }
    const dates = this.entries.map((entry: TimetableEntry) => entry.date).sort();
    return dates[0] === dates[dates.length - 1] ? dates[0] : `${dates[0]} 至 ${dates[dates.length - 1]}`;
  }
  private requestClear(): void {
    if (this.loading || !this.editable()) { return; }
    if (this.editorDirty || this.editingIndex >= 0 || this.importEntries.length > 0) {
      this.message = '请先处理表单或导入候选，再清空草稿。'; return;
    }
    this.clearRequested = true;
  }
  private clearDraft(): void {
    if (!this.clearRequested || this.loading || !this.editable()) { return; }
    if (this.editorDirty || this.editingIndex >= 0 || this.importEntries.length > 0) {
      this.message = '表单或导入候选已变化，请先处理后再清空草稿。'; return;
    }
    if (this.controller?.replaceDraft([])) {
      this.clearRequested = false; this.sourceWarnings = []; this.editorOpen = false;
      this.notice = '草稿已清空，账号原课表仍保留。保存时还需明确确认清空账号课表。';
    }
  }
  private reviewSave(): void {
    if (this.loading || !this.editable() || this.view.phase === 'stale') { return; }
    if (this.editorDirty || this.editingIndex >= 0 || this.importEntries.length > 0) {
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
      this.resetEditor(); this.editorOpen = false; this.importEntries = []; this.importWarnings = [];
      this.scheduleUrl = ''; this.sourceWarnings = []; this.reviewOpen = false; this.reloadRequested = false;
      this.message = ''; this.notice = ''; this.syncPending();
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
  private Pagination(preview: boolean) {
    Row({ space: 8 }) {
      Button('上一页').layoutWeight(1).constraintSize({ minHeight: 48 }).fontSize(AppTheme.metaSize)
        .fontColor(AppTheme.accent).backgroundColor(AppTheme.accentSoft)
        .enabled((preview ? this.importPage : this.pageIndex) > 0)
        .onClick(() => { if (preview) { this.importPage--; } else { this.pageIndex--; } })
      Text(`${(preview ? this.importPage : this.pageIndex) + 1} / ${Math.max(1, Math.ceil((preview ? this.importEntries.length : this.entries.length) / 10))}`)
        .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet)
      Button('下一页').layoutWeight(1).constraintSize({ minHeight: 48 }).fontSize(AppTheme.metaSize)
        .fontColor(AppTheme.accent).backgroundColor(AppTheme.accentSoft)
        .enabled(((preview ? this.importPage : this.pageIndex) + 1) * 10 <
          (preview ? this.importEntries.length : this.entries.length))
        .onClick(() => { if (preview) { this.importPage++; } else { this.pageIndex++; } })
    }.width('100%')
  }

  @Builder
  private Editor() {
    Column({ space: 16 }) {
      Text(this.editingIndex >= 0 ? '修改这一次课程' : '添加一门课程')
        .fontSize(AppTheme.sectionTitle).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink).width('100%')
      this.FormField('课程名称 *', '例如：操作系统', this.editor.title, this.fieldErrors.title,
        (value: string) => this.updateEditor('title', value))
      this.FormField(this.editingIndex >= 0 ? '上课日期 *' : '第一次上课日期 *', 'YYYY-MM-DD，例如 2026-10-19',
        this.editor.date, this.fieldErrors.date, (value: string) => this.updateEditor('date', value))
      Row({ space: 12 }) {
        Column() {
          this.FormField('开始时间 *', '08:05', this.editor.start_time, this.fieldErrors.start_time,
            (value: string) => this.updateEditor('start_time', value))
        }.layoutWeight(1)
        Column() {
          this.FormField('结束时间 *', '09:40', this.editor.end_time, this.fieldErrors.end_time,
            (value: string) => this.updateEditor('end_time', value))
        }.layoutWeight(1)
      }.width('100%').alignItems(VerticalAlign.Top)
      Text('使用 24 小时制；每条课程对应一个具体日期，当天结束时间应晚于开始时间。')
        .fontSize(AppTheme.metaSize).lineHeight(19).fontColor(AppTheme.quiet).width('100%')
      this.FormField('上课地点（选填）', '例如：第7教研楼北406', this.editor.location, this.fieldErrors.location,
        (value: string) => this.updateEditor('location', value))
      this.FormField('任课教师（选填）', '老师姓名', this.editor.teacher, this.fieldErrors.teacher,
        (value: string) => this.updateEditor('teacher', value))
      if (this.editingIndex < 0) {
        Text('每周同一天，连续添加').fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink).width('100%')
        Row({ space: 6 }) {
          ForEach([1, 4, 8, 16], (weeks: number) => {
            Button(weeks === 1 ? '仅一次' : `${weeks} 周`).layoutWeight(1).constraintSize({ minHeight: 48 })
              .fontSize(AppTheme.metaSize).fontColor(this.repeatWeeks === weeks ? AppTheme.onAccent : AppTheme.quiet)
              .backgroundColor(this.repeatWeeks === weeks ? AppTheme.accent : AppTheme.field)
              .borderRadius(AppTheme.controlRadius).enabled(!this.loading && this.editable())
              .accessibilityText(`${weeks === 1 ? '仅添加一次' : `连续 ${weeks} 周`}${this.repeatWeeks === weeks ? '，已选择' : ''}`)
              .onClick(() => this.setRepeatWeeks(weeks))
          }, (weeks: number) => weeks.toString())
        }.width('100%')
        Text(this.repeatWeeks === 1 ? '默认仅添加一次，不会自动生成整学期。' :
          `将生成 ${this.repeatWeeks} 个具体日期；单双周、节假日请在课表中逐条调整。`)
          .fontSize(AppTheme.metaSize).lineHeight(19).fontColor(AppTheme.quiet).width('100%')
      } else {
        Text('此次只修改选中的日期，不会改变其他周的同名课程。')
          .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
      }
      Button(this.editingIndex >= 0 ? '保存这次修改' : '加入课表草稿').width('100%')
        .constraintSize({ minHeight: 50 }).fontSize(AppTheme.bodySize).fontColor(AppTheme.onAccent)
        .backgroundColor(AppTheme.accent).borderRadius(AppTheme.controlRadius)
        .enabled(!this.loading && this.editable()).onClick(() => this.addEntry())
      if (this.editorDirty || this.editingIndex >= 0 || this.entries.length > 0) {
        Button(this.editorDirty ? '放弃本次表单修改' : '收起表单').width('100%').constraintSize({ minHeight: 48 })
          .fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet).backgroundColor(Color.Transparent)
          .enabled(!this.loading && this.editable()).onClick(() => this.cancelEdit())
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(AppTheme.cardInset)
      .backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
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
        .enabled(!this.loading && this.editable() && this.importEntries.length === 0).onClick(() => this.previewImport())
      if (this.importEntries.length > 0) {
        Text(`预览共 ${this.importEntries.length} 次课程`).fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium)
          .fontColor(AppTheme.ink).width('100%')
        Text('下方为本次读取结果。加入草稿后，可逐条修改、移除，再统一确认。')
          .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
        ForEach(this.importWarnings, (warning: TimetableIssue) => {
          Text(warning.message).fontSize(AppTheme.metaSize).fontColor(AppTheme.warning).width('100%')
        }, (_warning: TimetableIssue, index: number) => `import-warning-${this.requestRevision}-${index}`)
        ForEach(this.previewRows(), (row: CourseRow) => {
          this.CourseCard(row, false)
        }, (row: CourseRow) => `preview-${this.requestRevision}-${row.index}`)
        if (this.importEntries.length > 10) { this.Pagination(true) }
        Button('将这些课程加入草稿').width('100%').constraintSize({ minHeight: 50 })
          .fontSize(AppTheme.bodySize).fontColor(AppTheme.onAccent).backgroundColor(AppTheme.accent)
          .enabled(!this.loading && this.editable()).onClick(() => this.acceptImport())
        Button('放弃本次预览').width('100%').constraintSize({ minHeight: 48 })
          .fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet).backgroundColor(Color.Transparent)
          .enabled(!this.loading && this.editable()).onClick(() => this.cancelPreview())
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
      if (this.entries.length > 10) { this.Pagination(false) }
    }.width('100%').alignItems(HorizontalAlign.Start)
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
          Text('草稿只在本次登录期间保留；退出账号会清除。所有课程按北京时间填写。')
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
