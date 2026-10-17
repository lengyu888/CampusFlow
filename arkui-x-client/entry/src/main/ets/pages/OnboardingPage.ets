import { CampusDataSnapshot, CampusMapSummary, CampusPlaceImport, TimetableEntry, UserProfile } from '../model/ApiModels';
import { CampusFlowApi } from '../services/CampusFlowApi';
import { CampusFlowRequestError } from '../utils/AgentFeedback';
import { TimetableFieldErrors, TimetableIssue, normalizeTimetableEntry, validateTimetableEntry, validateTimetableList, parseTimetablePreview, expandWeeklyEntry } from '../utils/OnboardingTimetable';
import { AppTheme } from '../theme/AppTheme';
import { AppIcon } from '../components/AppIcon';
import { FeedbackPanel } from '../components/FeedbackPanel';

interface CourseRow {
  index: number;
  entry: TimetableEntry;
}

@Component
export struct OnboardingPage {
  @Prop baseUrl: string;
  @Prop token: string;
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
  @State private importEntries: TimetableEntry[] = [];
  @State private importWarnings: TimetableIssue[] = [];
  @State private importPage: number = 0;
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
  private requestRevision: number = 0;
  private pageActive: boolean = true;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.pageActive = true;
    if (this.semester.length === 0) {
      const now = new Date();
      const year = now.getMonth() >= 7 ? now.getFullYear() : now.getFullYear() - 1;
      this.semester = `${year}-${year + 1} ${now.getMonth() >= 1 && now.getMonth() < 7 ? '第二' : '第一'}学期`;
    }
    if (this.editor.date.length === 0) { this.resetEditor(); }
  }

  aboutToDisappear(): void {
    this.pageActive = false;
    this.requestRevision++;
    this.scheduleUrl = '';
    this.importEntries = [];
  }

  private current(revision: number): boolean {
    return this.pageActive && this.requestRevision === revision && !this.completed;
  }

  private today(): string {
    const now = new Date();
    return `${now.getFullYear()}-${(now.getMonth() + 1).toString().padStart(2, '0')}-${now.getDate().toString().padStart(2, '0')}`;
  }

  private resetEditor(): void {
    this.editor = { date: this.today(), title: '', start_time: '', end_time: '', location: '', teacher: '' };
    this.fieldErrors = { date: '', title: '', start_time: '', end_time: '', location: '', teacher: '' };
    this.editingIndex = -1;
    this.repeatWeeks = 1;
    this.editorDirty = false;
  }

  private updateEditor(field: string, value: string): void {
    if (this.loading || this.completed) { return; }
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
  }

  private setRepeatWeeks(weeks: number): void {
    if (this.loading || this.editingIndex >= 0 || this.completed) { return; }
    this.repeatWeeks = weeks;
    this.editorDirty = true;
  }

  private refreshDraft(entries: TimetableEntry[]): void {
    const result = validateTimetableList(entries, true);
    this.entries = result.entries;
    this.warnings = result.warnings;
    this.draftRevision++;
    this.pendingDelete = -1;
    this.pageIndex = Math.max(0, Math.min(this.pageIndex, Math.ceil(this.entries.length / 10) - 1));
    this.showAllWarnings = false;
  }

  private addEntry(): void {
    if (this.loading || this.completed) { return; }
    const checked = validateTimetableEntry(this.editor);
    this.fieldErrors = checked.errors;
    if (!checked.valid) { this.message = '请先修正课程表单中标出的内容。'; return; }
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
    this.refreshDraft(validated.entries);
    this.notice = edited ? '这一次课程已修改，确认前还可以调整。' : `已加入 ${additions.entries.length} 次课程，尚未保存到账号。`;
    this.message = '';
    this.resetEditor();
    this.editorOpen = false;
  }

  private newEntry(): void {
    if (this.loading || this.completed || this.editorDirty || this.editingIndex >= 0) { return; }
    this.resetEditor();
    this.source = 'manual';
    this.editorOpen = true;
    this.message = '';
  }

  private editEntry(index: number): void {
    if (this.loading || this.completed || index < 0 || index >= this.entries.length) { return; }
    if (this.editorDirty || this.editingIndex >= 0) { this.message = '请先保存或取消当前编辑，再编辑另一条课程。'; return; }
    this.cancelPreview();
    this.source = 'manual';
    this.editor = normalizeTimetableEntry(this.entries[index]);
    this.editingIndex = index;
    this.repeatWeeks = 1;
    this.fieldErrors = { date: '', title: '', start_time: '', end_time: '', location: '', teacher: '' };
    this.editorDirty = false;
    this.editorOpen = true;
    this.message = '';
    this.step = 1;
    this.scroller.scrollEdge(Edge.Top);
  }

  private cancelEdit(): void {
    if (this.loading || this.completed) { return; }
    this.resetEditor();
    this.editorOpen = false;
    this.message = '';
  }

  private requestDelete(index: number): void {
    if (this.loading || this.completed) { return; }
    if (this.editorDirty || this.editingIndex >= 0) { this.message = '请先保存或取消当前编辑，再移除课程。'; return; }
    this.pendingDelete = index;
  }

  private removeEntry(index: number): void {
    if (this.loading || this.completed || this.pendingDelete !== index || this.editorDirty || this.editingIndex >= 0) { return; }
    this.refreshDraft(this.entries.filter((_entry: TimetableEntry, entryIndex: number) => entryIndex !== index));
    this.notice = '已从待确认课表移除，尚未修改账号中的课表。';
    this.message = '';
  }

  private selectSource(source: string): void {
    if (this.loading || this.completed || this.source === source) { return; }
    if (this.editorDirty || this.editingIndex >= 0) { this.message = '请先加入、保存或取消当前课程，再切换录入方式。'; return; }
    this.cancelPreview();
    this.source = source;
    this.message = '';
    if (source === 'manual' && this.entries.length === 0) { this.editorOpen = true; }
  }

  private updateScheduleUrl(value: string): void {
    if (this.loading || this.completed) { return; }
    this.requestRevision++;
    this.scheduleUrl = value;
    this.importEntries = [];
    this.importWarnings = [];
    this.importPage = 0;
    this.message = '';
  }

  private cancelPreview(): void {
    // Only preview is cancellable. A submitted save cannot be uncommitted from the UI.
    if (this.loading && this.busyLabel !== '正在读取课表预览…') { return; }
    this.requestRevision++;
    this.loading = false;
    this.busyLabel = '';
    this.importEntries = [];
    this.importWarnings = [];
    this.importPage = 0;
  }

  private failureMessage(error: Error, saving: boolean): string {
    if (error instanceof CampusFlowRequestError) {
      if (error.statusCode === 401) {
        this.needsLogin = true;
        return '登录已失效，请重新登录后继续；返回登录会丢弃当前页面草稿。';
      }
      if (error.statusCode === 422) {
        return saving ? '课表未通过服务校验，请返回检查课程、学期和时间。草稿已保留。'
          : '无法读取此订阅。请检查 HDUHelp 课表链接是否完整、有效，或改用手动录入。';
      }
      if (error.code === 'NETWORK_ERROR' || error.statusCode === 504 || error.statusCode === 408) {
        return saving ? '暂时无法确认保存结果，草稿仍保留；网络恢复后可再次提交同一份课表。'
          : '课表预览连接失败，请检查网络和服务地址后重试。现有草稿未改动。';
      }
    }
    return saving ? '暂时无法完成配置，已保留课表草稿，请稍后重试。'
      : '暂时无法读取课表预览，请稍后重试或手动录入。现有草稿未改动。';
  }

  private async previewImport(): Promise<void> {
    if (this.loading || this.completed || !this.pageActive || this.source !== 'subscription') { return; }
    const url = this.scheduleUrl.trim();
    if (url.length === 0 || url.length > 2048) { this.message = '请粘贴完整的 HDUHelp 课表订阅链接（不超过 2048 字符）。'; return; }
    const revision = ++this.requestRevision;
    this.loading = true;
    this.busyLabel = '正在读取课表预览…';
    this.message = '';
    this.importEntries = [];
    this.importWarnings = [];
    try {
      const preview = await new CampusFlowApi(this.baseUrl, this.token).previewSubscription(url);
      if (!this.current(revision) || this.scheduleUrl.trim() !== url || this.source !== 'subscription') { return; }
      const checked = parseTimetablePreview(JSON.stringify(preview));
      if (!checked.valid) {
        this.message = `预览未加入草稿：${checked.errors[0].message}`;
        return;
      }
      this.importEntries = checked.entries;
      this.importWarnings = checked.warnings;
      this.importPage = 0;
      this.notice = '这是只读预览，尚未保存或绑定订阅。核对后可加入待确认课表。';
    } catch (error) {
      if (this.current(revision)) { this.message = this.failureMessage(error, false); }
    } finally {
      if (this.current(revision)) { this.loading = false; this.busyLabel = ''; }
    }
  }

  private acceptImport(): void {
    if (this.loading || this.completed || this.importEntries.length === 0) { return; }
    const checked = validateTimetableList(this.entries.concat(this.importEntries));
    if (!checked.valid) { this.message = `无法合并：${checked.errors[0].message} 已有课表和预览均保留。`; return; }
    const count = this.importEntries.length;
    this.refreshDraft(checked.entries);
    this.sourceWarnings = this.sourceWarnings.concat(this.importWarnings.filter((warning: TimetableIssue) => warning.index < 0));
    this.importedNotice = '本次使用过订阅预览，只会保存最终确认的课程，不保存订阅链接；首次配置后可从校园进入课表维护或校园连接。';
    this.cancelPreview();
    this.scheduleUrl = '';
    this.editorOpen = false;
    this.notice = `已加入 ${count} 次课程，可在下方逐条编辑或移除。`;
    this.message = '';
  }

  private nextStep(): void {
    if (this.loading || this.completed) { return; }
    this.message = '';
    if (this.step === 0) {
      if (this.semester.trim().length === 0 || Array.from(this.semester.trim()).length > 80) {
        this.message = '请填写学期，最多 80 字。'; return;
      }
      this.step = 1;
    } else if (this.step === 1) {
      if (this.editorDirty || this.editingIndex >= 0) { this.message = '表单中还有未加入的修改，请先保存或取消编辑。'; return; }
      if (this.importEntries.length > 0) { this.message = '请先将预览加入课表，或放弃本次预览。'; return; }
      const checked = validateTimetableList(this.entries);
      if (!checked.valid) { this.message = checked.errors[0].message; return; }
      this.refreshDraft(checked.entries);
      this.step = 2;
      this.scheduleUrl = '';
    }
    this.scroller.scrollEdge(Edge.Top);
  }

  private previousStep(): void {
    if (this.loading || this.completed || this.step === 0) { return; }
    this.step--;
    this.message = '';
    this.scroller.scrollEdge(Edge.Top);
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
      warnings: ['使用 CampusFlow 杭电下沙校区数据包；未知通路仍需核对。'] };
  }

  private async finish(): Promise<void> {
    if (this.loading || this.completed || !this.pageActive || this.step !== 2) { return; }
    const checked = validateTimetableList(this.entries);
    if (!checked.valid) { this.message = checked.errors[0].message; return; }
    const semester = this.semester.trim();
    if (semester.length === 0 || Array.from(semester).length > 80) { this.message = '请返回填写有效学期。'; return; }
    // Freeze exactly what the user reviewed. Never refetch a subscription while saving.
    const confirmedEntries = checked.entries;
    const revision = ++this.requestRevision;
    this.loading = true;
    this.busyLabel = '正在读取校园地点…';
    this.message = '';
    try {
      const api = new CampusFlowApi(this.baseUrl, this.token);
      const data = await api.campusData();
      if (!this.current(revision)) { return; }
      const map = this.campusMap(data);
      if (map === null) { this.message = '校园地点数据缺失或校区不匹配，尚未提交。请稍后重试，课表草稿仍保留。'; return; }
      this.busyLabel = '正在保存已确认课表…';
      const result = await api.completeOnboarding(this.school, this.campus, semester, confirmedEntries, map);
      if (!this.current(revision)) { return; }
      if (result === null || result.user === undefined || result.user === null || result.user.onboarding_complete !== true ||
        result.timetable_count !== confirmedEntries.length || result.campus_place_count !== map.places.length) {
        this.message = '服务端回执不完整，保存结果需要核对；课表草稿仍保留。';
        return;
      }
      this.completed = true;
      this.loading = false;
      this.scheduleUrl = '';
      this.onCompleted(result.user);
    } catch (error) {
      if (this.current(revision)) { this.message = this.failureMessage(error, true); }
    } finally {
      if (this.current(revision)) { this.loading = false; this.busyLabel = ''; }
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
        .padding({ left: 12, right: 12 }).enabled(!this.loading && !this.completed)
        .accessibilityText(`${label}${error.length > 0 ? `，${error}` : ''}`).onChange(onChange)
      if (error.length > 0) {
        Text(error).fontSize(AppTheme.metaSize).fontColor(AppTheme.red).width('100%')
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private CourseCard(row: CourseRow, editable: boolean) {
    Column({ space: 8 }) {
      Text(`${row.index + 1}. ${row.entry.title}`).fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium)
        .fontColor(AppTheme.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
      Text(`${row.entry.date}  ·  ${row.entry.start_time}–${row.entry.end_time}`)
        .fontSize(AppTheme.metaSize).fontColor(AppTheme.actionBlue).width('100%').wordBreak(WordBreak.BREAK_WORD)
      Text(`${row.entry.location || '地点未填写'}${row.entry.teacher.length > 0 ? ` · ${row.entry.teacher}` : ''}`)
        .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
      if (editable) {
        Row({ space: 10 }) {
          Button('编辑').layoutWeight(1).constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
            .fontColor(AppTheme.actionBlue).backgroundColor(AppTheme.blueSoft)
            .enabled(!this.loading).accessibilityText(`编辑 ${row.entry.date} 的 ${row.entry.title}`)
            .onClick(() => this.editEntry(row.index))
          Button(this.pendingDelete === row.index ? '确认移除' : '移除').layoutWeight(1)
            .constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize).fontColor(AppTheme.red)
            .backgroundColor(AppTheme.surface).enabled(!this.loading)
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
            .fontColor(AppTheme.quiet).backgroundColor(Color.Transparent).enabled(!this.loading)
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
        .fontColor(AppTheme.actionBlue).backgroundColor(AppTheme.blueSoft)
        .enabled(!this.loading && (preview ? this.importPage : this.pageIndex) > 0)
        .onClick(() => { if (preview) { this.importPage--; } else { this.pageIndex--; } })
      Text(`${(preview ? this.importPage : this.pageIndex) + 1} / ${Math.max(1, Math.ceil((preview ? this.importEntries.length : this.entries.length) / 10))}`)
        .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet)
      Button('下一页').layoutWeight(1).constraintSize({ minHeight: 48 }).fontSize(AppTheme.metaSize)
        .fontColor(AppTheme.actionBlue).backgroundColor(AppTheme.blueSoft)
        .enabled(!this.loading && ((preview ? this.importPage : this.pageIndex) + 1) * 10 <
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
              .fontSize(AppTheme.metaSize).fontColor(this.repeatWeeks === weeks ? '#FFFFFF' : AppTheme.quiet)
              .backgroundColor(this.repeatWeeks === weeks ? AppTheme.actionBlue : AppTheme.field)
              .borderRadius(AppTheme.controlRadius).enabled(!this.loading)
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
      Button(this.editingIndex >= 0 ? '保存这次修改' : '加入待确认课表').width('100%')
        .constraintSize({ minHeight: 50 }).fontSize(AppTheme.bodySize).fontColor('#FFFFFF')
        .backgroundColor(AppTheme.actionBlue).borderRadius(AppTheme.controlRadius)
        .enabled(!this.loading).onClick(() => this.addEntry())
      if (this.editorDirty || this.editingIndex >= 0 || this.entries.length > 0) {
        Button(this.editorDirty ? '放弃本次表单修改' : '收起表单').width('100%').constraintSize({ minHeight: 48 })
          .fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet).backgroundColor(Color.Transparent)
          .enabled(!this.loading).onClick(() => this.cancelEdit())
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
      Text('链接可能含私人凭据，仅用于本次读取，不会随首次配置保存。以后可从校园进入课表维护或校园连接。')
        .fontSize(AppTheme.metaSize).lineHeight(21).fontColor(AppTheme.quiet).width('100%')
      Button(this.loading && this.busyLabel === '正在读取课表预览…' ? '正在读取…' : '读取预览，不保存')
        .width('100%').constraintSize({ minHeight: 50 }).fontSize(AppTheme.bodySize).fontColor('#FFFFFF')
        .backgroundColor(AppTheme.actionBlue).borderRadius(AppTheme.controlRadius)
        .enabled(!this.loading && this.importEntries.length === 0).onClick(() => this.previewImport())
      if (this.importEntries.length > 0) {
        Text(`预览共 ${this.importEntries.length} 次课程`).fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium)
          .fontColor(AppTheme.ink).width('100%')
        Text('下方为本次读取结果。加入草稿后，可逐条修改、移除，再统一确认。')
          .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
        ForEach(this.importWarnings, (warning: TimetableIssue) => {
          Text(warning.message).fontSize(AppTheme.metaSize).fontColor(AppTheme.orange).width('100%')
        }, (_warning: TimetableIssue, index: number) => `import-warning-${this.requestRevision}-${index}`)
        ForEach(this.previewRows(), (row: CourseRow) => {
          this.CourseCard(row, false)
        }, (row: CourseRow) => `preview-${this.requestRevision}-${row.index}`)
        if (this.importEntries.length > 10) { this.Pagination(true) }
        Button('将这些课程加入草稿').width('100%').constraintSize({ minHeight: 50 })
          .fontSize(AppTheme.bodySize).fontColor('#FFFFFF').backgroundColor(AppTheme.actionBlue)
          .enabled(!this.loading).onClick(() => this.acceptImport())
        Button('放弃本次预览').width('100%').constraintSize({ minHeight: 48 })
          .fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet).backgroundColor(Color.Transparent)
          .enabled(!this.loading).onClick(() => this.cancelPreview())
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
            .fontColor(AppTheme.actionBlue).backgroundColor(Color.Transparent)
            .enabled(!this.loading).onClick(() => this.newEntry())
        }
      }.width('100%')
      Text(this.courseRange()).fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
      if (this.sourceWarnings.length > 0) {
        Column({ space: 8 }) {
          Text('导入来源提示').fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium).fontColor(AppTheme.orange).width('100%')
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
            .fontWeight(FontWeight.Medium).fontColor(AppTheme.orange).width('100%')
          ForEach(this.showAllWarnings ? this.warnings : this.warnings.slice(0, 5), (warning: TimetableIssue) => {
            Text(warning.message).fontSize(AppTheme.metaSize).fontColor(AppTheme.orange).width('100%')
          }, (_warning: TimetableIssue, index: number) => `warning-${this.draftRevision}-${index}`)
          if (this.warnings.length > 5) {
            Button(this.showAllWarnings ? '收起提示' : `查看全部 ${this.warnings.length} 处提示`)
              .constraintSize({ minHeight: 48 }).fontSize(AppTheme.metaSize).fontColor(AppTheme.orange)
              .backgroundColor(Color.Transparent).onClick(() => this.showAllWarnings = !this.showAllWarnings)
          }
          Text('重叠课程不会自动删除；请返回编辑，或确认保留这些安排。')
            .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
        }.width('100%').padding(AppTheme.cardInset).backgroundColor(AppTheme.surface).borderRadius(AppTheme.controlRadius)
      }
      ForEach(this.draftRows(), (row: CourseRow) => {
        this.CourseCard(row, this.step === 1)
      }, (row: CourseRow) => `draft-${this.draftRevision}-${row.index}-${this.step}`)
      if (this.entries.length > 10) { this.Pagination(false) }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      Scroll(this.scroller) {
        Column({ space: AppTheme.sectionGap }) {
          Column({ space: 10 }) {
            Row({ space: 8 }) {
              AppIcon({ name: 'calendar', iconSize: 22, color: AppTheme.actionBlue })
              Text('首次使用').fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium).fontColor(AppTheme.actionBlue)
              Blank()
              Text(`${this.step + 1} / 3`).fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet)
            }.width('100%')
            Text(this.step === 0 ? '校园与学期' : (this.step === 1 ? '添加真实课程' : '核对完整课表'))
              .fontSize(AppTheme.pageTitle).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink).width('100%')
            Text(this.step === 0 ? '课表用来避开上课时间，校园地点用来辅助安排。' :
              (this.step === 1 ? '手动录入和订阅导入都可以；确认前均为草稿。' : '保存眼前这份课表，之后 Agent 才能据此安排学习。'))
              .fontSize(AppTheme.bodySize).lineHeight(24).fontColor(AppTheme.quiet).width('100%')
            Row({ space: 6 }) {
              ForEach([0, 1, 2], (step: number) => {
                Row().height(4).layoutWeight(1).borderRadius(2)
                  .backgroundColor(step <= this.step ? AppTheme.actionBlue : AppTheme.line)
              }, (step: number) => step.toString())
            }.width('100%').accessibilityText(`第 ${this.step + 1} 步，共三步`)
          }.width('100%').alignItems(HorizontalAlign.Start)

          if (this.step === 0) {
            Column({ space: 16 }) {
              Text('当前支持的校园').fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
              Text(this.school).fontSize(20).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink).width('100%')
              Text(`${this.campus} · CampusFlow 校园地点数据包`)
                .fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet).width('100%')
              Divider().color(AppTheme.line)
              this.FormField('学期 *', '例如：2026-2027 第一学期', this.semester, '',
                (value: string) => { if (!this.loading) { this.semester = value; } })
              Text('没有 HDUHelp 订阅链接也可以继续，下一步可手动录入真实课程。')
                .fontSize(AppTheme.bodySize).lineHeight(22).fontColor(AppTheme.quiet).width('100%')
            }.width('100%').alignItems(HorizontalAlign.Start).padding(AppTheme.cardInset)
              .backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
          } else if (this.step === 1) {
            Row({ space: 8 }) {
              Button('手动录入').layoutWeight(1).constraintSize({ minHeight: 50 }).fontSize(AppTheme.bodySize)
                .fontColor(this.source === 'manual' ? '#FFFFFF' : AppTheme.quiet)
                .backgroundColor(this.source === 'manual' ? AppTheme.actionBlue : AppTheme.surface)
                .borderRadius(AppTheme.controlRadius).enabled(!this.loading)
                .accessibilityText(`手动录入${this.source === 'manual' ? '，已选择' : ''}`)
                .onClick(() => this.selectSource('manual'))
              Button('订阅导入').layoutWeight(1).constraintSize({ minHeight: 50 }).fontSize(AppTheme.bodySize)
                .fontColor(this.source === 'subscription' ? '#FFFFFF' : AppTheme.quiet)
                .backgroundColor(this.source === 'subscription' ? AppTheme.actionBlue : AppTheme.surface)
                .borderRadius(AppTheme.controlRadius).enabled(!this.loading)
                .accessibilityText(`订阅导入${this.source === 'subscription' ? '，已选择' : ''}`)
                .onClick(() => this.selectSource('subscription'))
            }.width('100%')
            if (this.source === 'manual') {
              if (this.editorOpen) { this.Editor() }
              else {
                Button('添加课程').width('100%').constraintSize({ minHeight: 50 }).fontSize(AppTheme.bodySize)
                  .fontColor(AppTheme.actionBlue).backgroundColor(AppTheme.blueSoft)
                  .enabled(!this.loading).onClick(() => this.newEntry())
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
              Text('这些课程将保存到当前账号，并用于 Agent 规划；本页草稿不会跨账号保留。')
                .fontSize(AppTheme.metaSize).lineHeight(20).fontColor(AppTheme.quiet).width('100%')
            }.width('100%').alignItems(HorizontalAlign.Start).padding(AppTheme.cardInset)
              .backgroundColor(AppTheme.blueSoft).borderRadius(AppTheme.cardRadius)
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
              .enabled(!this.loading && !this.completed).onClick(() => this.previousStep())
          }
          Button(this.completed ? '已完成配置' : (this.step === 2 ? '确认课表并开始使用' :
            (this.step === 0 ? '下一步：添加课表' : '下一步：核对课表')))
            .layoutWeight(1).constraintSize({ minHeight: 50 }).fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF').backgroundColor(AppTheme.actionBlue).borderRadius(AppTheme.controlRadius)
            .enabled(!this.loading && !this.completed)
            .onClick(() => { if (this.step === 2) { this.finish(); } else { this.nextStep(); } })
        }.width('100%')
        if (this.needsLogin) {
          Button('丢弃本页草稿，返回登录').width('100%').constraintSize({ minHeight: 48 })
            .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).backgroundColor(Color.Transparent)
            .enabled(!this.loading).onClick(() => this.onReturnToLogin())
        }
      }.width('100%').padding({ left: 20, right: 20, top: 12, bottom: 16 })
        .backgroundColor(AppTheme.surface).border({ width: { top: 1 }, color: AppTheme.line })
    }.width('100%').height('100%').backgroundColor(AppTheme.canvas)
  }
}
