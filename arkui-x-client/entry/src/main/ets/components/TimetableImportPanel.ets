import { TimetableEntry, ScheduleImportRow, ScheduleImportIssue } from '../model/ApiModels';
import { TimetableFieldErrors, TimetableIssue, validateTimetableEntry } from '../utils/OnboardingTimetable';
import { ImportRowChoice, ImportReviewRow, ImportOverlap, ImportClassification, classifyImportRows } from '../utils/TimetableImportReview';
import { TimetableEntryEditor } from './TimetableEntryEditor';
import { AppTheme } from '../theme/AppTheme';
import { ThemePalette, themePalette } from '../theme/ThemePalette';
import { InfoDisclosure } from './InfoDisclosure';

@Component
export struct TimetableImportPanel {
  @StorageLink('campusflowThemePalette') private palette: ThemePalette = themePalette('paper-green');
  @Watch('reclassify') @Prop rows: ScheduleImportRow[] = [];
  @Watch('reclassify') @Prop currentDraft: TimetableEntry[] = [];
  @Watch('reclassify') @Prop choices: ImportRowChoice[] = [];
  @Prop warnings: TimetableIssue[] = [];
  @Prop busy: boolean = false;
  @Prop active: boolean = true;
  @Prop anchorDate: string = '';
  @Watch('contextChanged') @Prop contextKey: string = '';
  onChoicesChanged: (choices: ImportRowChoice[]) => void = () => {};
  onAccept: () => void = () => {};
  onCancel: () => void = () => {};
  @State private classified: ImportClassification = { valid: false, message: '', rows: [], addCount: 0, duplicateCount: 0, overlapCount: 0, invalidCount: 0, excludedCount: 0, unresolvedCount: 0 };
  @State private projectionRevision: number = 0;
  @State private sourceDetails: number[] = [];
  @State private category: string = 'all';
  @State private pageIndex: number = 0;
  @State private editingSource: number = -1;
  @State private editor: TimetableEntry = { date: '', title: '', start_time: '', end_time: '', location: '', teacher: '' };
  @State private errors: TimetableFieldErrors = { date: '', title: '', start_time: '', end_time: '', location: '', teacher: '' };
  @State private focusRevision: number = 0;
  @State private message: string = '';

  aboutToAppear(): void { this.reclassify(); }
  private contextChanged(): void { this.category = 'all'; this.pageIndex = 0; this.editingSource = -1; this.message = ''; this.sourceDetails = []; this.reclassify(); }
  private reclassify(): void {
    this.classified = classifyImportRows(this.rows, this.currentDraft, this.choices); this.projectionRevision++;
    this.pageIndex = Math.max(0, Math.min(this.pageIndex, Math.ceil(this.filteredRows().length / 6) - 1));
  }
  private classification(): ImportClassification { return this.classified; }
  private filteredRows(): ImportReviewRow[] {
    return this.classification().rows.filter((row: ImportReviewRow) => this.category === 'all' || row.category === this.category);
  }
  private pageRows(): ImportReviewRow[] { return this.filteredRows().slice(this.pageIndex * 6, this.pageIndex * 6 + 6); }
  private label(category: string): string {
    if (category === 'new') { return '可新增'; }
    if (category === 'duplicate') { return '完全重复'; }
    if (category === 'overlap') { return '时间重叠'; }
    if (category === 'invalid') { return '需修正'; }
    return '全部';
  }
  private selectCategory(value: string): void {
    if (this.editingSource >= 0) { this.message = '请先应用或取消本行编辑，再切换分类。'; return; }
    this.category = value; this.pageIndex = 0; this.message = '';
  }
  private choice(index: number): ImportRowChoice {
    const existing = this.choices.find((choice: ImportRowChoice) => choice.sourceIndex === index);
    return existing === undefined ? { sourceIndex: index, mode: 'default', edited: null, sourceIssuesReviewed: false, overlapKey: '' }
      : { sourceIndex: index, mode: existing.mode, edited: existing.edited, sourceIssuesReviewed: existing.sourceIssuesReviewed, overlapKey: existing.overlapKey };
  }
  private setChoice(choice: ImportRowChoice): void {
    if (!this.active || this.busy) { return; }
    this.onChoicesChanged(this.choices.filter((item: ImportRowChoice) => item.sourceIndex !== choice.sourceIndex).concat([choice]));
    this.message = '';
  }
  private decide(index: number, include: boolean): void {
    if (!this.active || this.busy || this.editingSource >= 0) { return; }
    const row = this.classification().rows.find((item: ImportReviewRow) => item.sourceIndex === index);
    if (row === undefined) { return; }
    const choice = this.choice(index); choice.mode = include ? 'include' : 'exclude';
    choice.overlapKey = include && !row.excluded && row.category === 'overlap' ? row.overlapKey : '';
    if (include && row.excluded) { choice.mode = 'default'; }
    this.setChoice(choice);
  }
  private reviewSource(index: number): void {
    if (!this.active || this.busy || this.editingSource >= 0) { return; }
    const row = this.classification().rows.find((item: ImportReviewRow) => item.sourceIndex === index);
    if (row === undefined || !validateTimetableEntry(row.input).valid) { this.message = '请先修正这一行的课程字段。'; return; }
    const choice = this.choice(index);
    choice.edited = { date: row.input.date, title: row.input.title, start_time: row.input.start_time,
      end_time: row.input.end_time, location: row.input.location, teacher: row.input.teacher };
    choice.sourceIssuesReviewed = true; choice.mode = 'default'; choice.overlapKey = ''; this.setChoice(choice);
  }
  private editRow(index: number): void {
    if (!this.active || this.busy || this.editingSource >= 0) { return; }
    const row = this.classification().rows.find((item: ImportReviewRow) => item.sourceIndex === index);
    if (row === undefined) { return; }
    this.editor = { date: row.input.date, title: row.input.title, start_time: row.input.start_time,
      end_time: row.input.end_time, location: row.input.location, teacher: row.input.teacher };
    this.errors = validateTimetableEntry(this.editor).errors; this.editingSource = index; this.message = '';
  }
  private updateEditor(field: string, value: string): void {
    if (!this.active || this.busy || this.editingSource < 0) { return; }
    const next: TimetableEntry = { date: this.editor.date, title: this.editor.title, start_time: this.editor.start_time,
      end_time: this.editor.end_time, location: this.editor.location, teacher: this.editor.teacher };
    if (field === 'date') { next.date = value; } else if (field === 'title') { next.title = value; }
    else if (field === 'start_time') { next.start_time = value; } else if (field === 'end_time') { next.end_time = value; }
    else if (field === 'location') { next.location = value; } else if (field === 'teacher') { next.teacher = value; }
    this.editor = next; this.errors = validateTimetableEntry(next).errors;
  }
  private saveEdit(): void {
    if (!this.active || this.busy || this.editingSource < 0) { return; }
    const checked = validateTimetableEntry(this.editor); this.errors = checked.errors;
    if (!checked.valid) { this.focusRevision++; return; }
    const choice = this.choice(this.editingSource); choice.edited = checked.entry;
    choice.mode = 'default'; choice.sourceIssuesReviewed = false; choice.overlapKey = '';
    this.setChoice(choice); this.editingSource = -1; this.category = 'all'; this.pageIndex = Math.floor(choice.sourceIndex / 6);
  }
  private accept(): void {
    if (!this.active || this.busy || this.editingSource >= 0) { return; }
    this.onAccept();
  }

  @Builder
  private ReviewRow(row: ImportReviewRow) {
    Column({ space: 8 }) {
      Text(`源第 ${row.sourceIndex + 1} 行 · ${this.label(row.category)}${row.excluded ? ' · 已明确排除' : row.selected ? ' · 将加入' : ' · 待核对'}`)
        .fontSize(this.palette.metaSize).fontColor(row.excluded ? this.palette.quiet : row.selected ? this.palette.accent : this.palette.warning).width('100%')
      Text(row.input.title.length > 0 ? row.input.title : '尚无课程名称').fontSize(this.palette.bodySize)
        .fontWeight(FontWeight.Medium).fontColor(this.palette.ink).width('100%')
      Text(`${row.input.date || '未提供日期'}  ${row.input.start_time || '未提供开始'}–${row.input.end_time || '未提供结束'}`)
        .fontSize(this.palette.bodySize).fontColor(this.palette.ink).width('100%')
      Text(`地点：${row.input.location || '未填写'} · 教师：${row.input.teacher || '未填写'}`)
        .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
      Button(this.sourceDetails.includes(row.sourceIndex) ? '收起源时间字段' : '查看源时间字段')
        .constraintSize({ minHeight: 48 }).width('100%').fontSize(this.palette.metaSize).fontColor(this.palette.quiet)
        .backgroundColor(Color.Transparent).onClick(() => {
          this.sourceDetails = this.sourceDetails.includes(row.sourceIndex) ? this.sourceDetails.filter((index: number) => index !== row.sourceIndex) : this.sourceDetails.concat([row.sourceIndex]);
        })
      if (this.sourceDetails.includes(row.sourceIndex)) {
        Text(`原开始：${row.original.source_time.start_value ?? '未提供'}；时区：${row.original.source_time.start_tzid ?? '未声明'}；类型：${row.original.source_time.start_value_type ?? '未声明'}`)
          .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
        Text(`原结束：${row.original.source_time.end_value ?? '未提供'}；时区：${row.original.source_time.end_tzid ?? '未声明'}；类型：${row.original.source_time.end_value_type ?? '未声明'}`)
          .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
        Text('上方可加入的课程日期与时间统一按北京时间显示。').fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
      }
      ForEach(row.sourceIssues, (issue: ScheduleImportIssue) => {
        Text(`来源提示：${issue.message}`).fontSize(this.palette.metaSize).fontColor(this.palette.warning).width('100%')
      }, (_issue: ScheduleImportIssue, index: number) => `source-${row.sourceIndex}-${index}`)
      ForEach(row.issues, (issue: TimetableIssue) => {
        Text(issue.message).fontSize(this.palette.metaSize).fontColor(this.palette.warning).width('100%')
      }, (_issue: TimetableIssue, index: number) => `issue-${row.sourceIndex}-${index}`)
      ForEach(row.overlaps, (other: ImportOverlap) => {
        Text(`与${other.kind === 'draft' ? '当前草稿' : '本批源'}第 ${other.index + 1} 行重叠：${other.entry.title}，${other.entry.date} ${other.entry.start_time}–${other.entry.end_time}；地点：${other.entry.location || '未填写'}；教师：${other.entry.teacher || '未填写'}`)
          .fontSize(this.palette.metaSize).fontColor(this.palette.warning).width('100%')
      }, (other: ImportOverlap) => `${other.kind}-${other.index}`)
      if (row.needsSourceReview) {
        Text('原记录不能按原样导入。修正后仅作为上方这一次课程，不代表已展开原系列或完整跨日事件。')
          .fontSize(this.palette.metaSize).fontColor(this.palette.warning).width('100%')
        Button('已核对，按这一次课程重建').constraintSize({ minHeight: 48 }).width('100%').fontSize(this.palette.bodySize)
          .fontColor(this.palette.warning).backgroundColor(this.palette.warningSoft).enabled(!this.busy && this.active && this.editingSource < 0)
          .onClick(() => this.reviewSource(row.sourceIndex))
      }
      if (row.category === 'duplicate') {
        Text('六个字段完全相同，默认不重复加入；不同教师不会合并。').fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
      }
      if (!row.excluded && row.category === 'overlap' && !row.selected) {
        Button('保留以上重叠，加入这条').constraintSize({ minHeight: 48 }).width('100%').fontSize(this.palette.bodySize)
          .fontColor(this.palette.warning).backgroundColor(this.palette.warningSoft).enabled(!this.busy && this.active && this.editingSource < 0)
          .onClick(() => this.decide(row.sourceIndex, true))
      }
      Row({ space: 8 }) {
        Button('修改这一行').constraintSize({ minHeight: 44 }).layoutWeight(1).fontSize(this.palette.metaSize)
          .fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft).borderRadius(10)
          .enabled(!this.busy && this.active && this.editingSource < 0).onClick(() => this.editRow(row.sourceIndex))
        Button(row.excluded ? '重新纳入核对' : '明确排除此行').constraintSize({ minHeight: 44 }).layoutWeight(1).fontSize(this.palette.metaSize)
          .fontColor(this.palette.quiet).backgroundColor(this.palette.surface).borderRadius(10)
          .enabled(!this.busy && this.active && this.editingSource < 0).onClick(() => this.decide(row.sourceIndex, row.excluded))
      }.width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start).padding(this.palette.cardInset)
      .backgroundColor(this.palette.canvas).borderRadius(this.palette.controlRadius)
  }
  build() {
    Column({ space: 12 }) {
      Text(`核对 ${this.rows.length} 条源记录`).fontSize(this.palette.sectionTitle).fontWeight(FontWeight.Bold).fontColor(this.palette.ink).width('100%')
      Text(`可加入 ${this.classification().addCount} · 重复 ${this.classification().duplicateCount} · 重叠 ${this.classification().overlapCount} · 需修正 ${this.classification().invalidCount} · 已排除 ${this.classification().excludedCount}`)
        .fontSize(this.palette.bodySize).fontColor(this.palette.ink).width('100%')
      Text('先核对并加入草稿，确认保存后才更新课表。')
        .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
      InfoDisclosure({ title: '导入与草稿说明', message: '逐行核对后才加入本地草稿，不按名称覆盖旧课。未加入的预览与选择只在本页内存中；退出应用后需重新读取。' })
      ForEach(this.warnings, (warning: TimetableIssue) => {
        Text(warning.message).fontSize(this.palette.metaSize).fontColor(this.palette.warning).width('100%')
      }, (_warning: TimetableIssue, index: number) => `warning-${index}`)
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(['all', 'new', 'duplicate', 'overlap', 'invalid'], (category: string) => {
          Button(this.label(category)).constraintSize({ minHeight: 44 }).margin({ right: 6, bottom: 6 })
            .fontSize(this.palette.metaSize).fontColor(this.category === category ? this.palette.onAccent : this.palette.ink)
            .backgroundColor(this.category === category ? this.palette.accent : this.palette.field).borderRadius(10)
            .onClick(() => this.selectCategory(category))
        }, (category: string) => category)
      }.width('100%')
      if (this.editingSource >= 0) {
        Text(`正在修改源第 ${this.editingSource + 1} 行，尚未应用`).fontSize(this.palette.bodySize).fontColor(this.palette.ink).width('100%')
        TimetableEntryEditor({ entry: this.editor, errors: this.errors, editing: true, showRepeat: false,
          busy: this.busy, active: this.active, anchorDate: this.anchorDate,
          contextKey: `${this.contextKey}-${this.editingSource}`, idPrefix: `import-${this.contextKey}-${this.editingSource}`,
          focusRevision: this.focusRevision, saveLabel: '应用修改并重新核对',
          onFieldChange: (field: string, value: string) => this.updateEditor(field, value),
          onSave: () => this.saveEdit(), onCancel: () => this.editingSource = -1 })
      }
      ForEach(this.pageRows(), (row: ImportReviewRow) => { this.ReviewRow(row) },
        (row: ImportReviewRow) => `${this.contextKey}-${row.sourceIndex}-${this.projectionRevision}`)
      if (this.filteredRows().length === 0) { Text('此分类暂无记录。').fontSize(this.palette.bodySize).fontColor(this.palette.quiet).width('100%') }
      if (this.filteredRows().length > 6) {
        Row({ space: 8 }) {
          Button('上一页').constraintSize({ minHeight: 48 }).layoutWeight(1).enabled(this.pageIndex > 0 && this.editingSource < 0)
            .fontSize(this.palette.metaSize).fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft)
            .borderRadius(this.palette.controlRadius)
            .onClick(() => this.pageIndex--)
          Text(`${this.pageIndex + 1}/${Math.max(1, Math.ceil(this.filteredRows().length / 6))}`).fontColor(this.palette.quiet)
          Button('下一页').constraintSize({ minHeight: 48 }).layoutWeight(1)
            .fontSize(this.palette.metaSize).fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft)
            .borderRadius(this.palette.controlRadius)
            .enabled((this.pageIndex + 1) * 6 < this.filteredRows().length && this.editingSource < 0).onClick(() => this.pageIndex++)
        }.width('100%')
      }
      if (this.message.length > 0) { Text(this.message).fontColor(this.palette.warning).width('100%') }
      if (!this.classification().valid) { Text(this.classification().message).fontColor(this.palette.danger).width('100%') }
      if (this.classification().unresolvedCount > 0) {
        Text(`还有 ${this.classification().unresolvedCount} 条需修正、确认重叠或明确排除。`).fontColor(this.palette.warning).width('100%')
      }
      Button(`将所选 ${this.classification().addCount} 条加入草稿`).constraintSize({ minHeight: 50 }).width('100%')
        .fontSize(this.palette.bodySize).fontColor(this.palette.onAccent).backgroundColor(this.palette.accent)
        .borderRadius(this.palette.controlRadius)
        .enabled(!this.busy && this.active && this.editingSource < 0 && this.classification().unresolvedCount === 0 && this.classification().addCount > 0)
        .onClick(() => this.accept())
      Button('放弃本次预览').constraintSize({ minHeight: 48 }).width('100%').fontSize(this.palette.bodySize)
        .fontColor(this.palette.quiet).backgroundColor(Color.Transparent).enabled(!this.busy && this.active).onClick(() => this.onCancel())
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
