import { TimetableEntry } from '../model/ApiModels';
import { TimetableFieldErrors, validateTimetableEntry } from '../utils/OnboardingTimetable';
import { AppTheme } from '../theme/AppTheme';

// A controlled form: the parent owns drafts, validation and every remote write.
@Component
export struct TimetableEntryEditor {
  @Prop entry: TimetableEntry = { date: '', title: '', start_time: '', end_time: '', location: '', teacher: '' };
  @Watch('errorsChanged') @Prop errors: TimetableFieldErrors = { date: '', title: '', start_time: '', end_time: '', location: '', teacher: '' };
  @Prop repeatWeeks: number = 1;
  @Prop editing: boolean = false;
  @Prop busy: boolean = false;
  @Watch('contextChanged') @Prop active: boolean = true;
  @Prop anchorDate: string = '';
  @Prop idPrefix: string = 'course-editor';
  @Watch('contextChanged') @Prop contextKey: string = '';
  @Watch('focusRequested') @Prop focusRevision: number = 0;
  @Prop canReuse: boolean = false;
  @Prop showRepeat: boolean = true;
  @Prop saveLabel: string = '';
  onFieldChange: (field: string, value: string) => void = () => {};
  onWeeksChange: (weeks: number) => void = () => {};
  onSave: (keepOpen: boolean) => void = () => {};
  onCancel: () => void = () => {};
  onReuse: () => void = () => {};
  @State private optionalExpanded: boolean = false;
  @State private notice: string = '';
  private mounted: boolean = false;
  private generation: number = 0;
  private focusPending: boolean = false;

  aboutToAppear(): void { this.mounted = true; this.errorsChanged(); }
  aboutToDisappear(): void { this.mounted = false; this.generation++; this.focusPending = false; }
  private contextChanged(): void { this.generation++; this.notice = ''; if (!this.active) { this.focusPending = false; } }
  private errorsChanged(): void {
    if (this.errors.location.length > 0 || this.errors.teacher.length > 0) { this.optionalExpanded = true; }
  }
  private firstError(): string {
    if (this.errors.title.length > 0) { return 'title'; }
    if (this.errors.date.length > 0) { return 'date'; }
    if (this.errors.start_time.length > 0) { return 'start_time'; }
    if (this.errors.end_time.length > 0) { return 'end_time'; }
    if (this.errors.location.length > 0) { return 'location'; }
    if (this.errors.teacher.length > 0) { return 'teacher'; }
    return '';
  }
  private focusRequested(): void { this.errorsChanged(); this.focusPending = true; }
  private locateError(): void {
    const field = this.firstError();
    if (!this.mounted || !this.active || this.busy || !this.focusPending || field.length === 0) { return; }
    this.focusPending = false;
    try {
      if (!focusControl.requestFocus(`${this.idPrefix}-${field}`)) {
        this.notice = '请点选标有错误的输入框继续修改；原输入已保留。';
      }
    } catch { this.notice = '请点选标有错误的输入框继续修改；原输入已保留。'; }
  }
  private dateValid(value: string): boolean {
    return validateTimetableEntry({ date: value, title: '日期校验', start_time: '00:00', end_time: '00:01', location: '', teacher: '' }).errors.date.length === 0;
  }
  private pickerDate(value: string): Date {
    const parts = value.split('-'); const date = new Date(0);
    date.setFullYear(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2])); date.setHours(12, 0, 0, 0);
    return date;
  }
  private pickerCurrent(generation: number, context: string, original: string): boolean {
    return this.mounted && this.active && !this.busy && generation === this.generation && context === this.contextKey &&
      original === JSON.stringify(this.entry);
  }
  private openDatePicker(): void {
    if (!this.mounted || !this.active || this.busy) { return; }
    const value = this.dateValid(this.entry.date) ? this.entry.date : this.anchorDate;
    if (!this.dateValid(value) || value < '1900-01-31' || value > '2100-12-31') {
      this.notice = '此日期请手动输入；选择器支持 1900-01-31 至 2100-12-31，原日期未改动。'; return;
    }
    const generation = ++this.generation; const context = this.contextKey; const original = JSON.stringify(this.entry);
    try {
      this.getUIContext().showDatePickerDialog({ selected: this.pickerDate(value),
        start: this.pickerDate('1900-01-31'), end: this.pickerDate('2100-12-31'),
        onAccept: (result: DatePickerResult) => {
          if (!this.pickerCurrent(generation, context, original)) { return; }
          this.generation++;
          if (result.year === undefined || result.month === undefined || result.day === undefined ||
            !Number.isInteger(result.year) || !Number.isInteger(result.month) || !Number.isInteger(result.day) ||
            result.month < 0 || result.month > 11) { this.notice = '未取得完整日期，请手动输入。'; return; }
          const next = `${result.year.toString().padStart(4, '0')}-${(result.month + 1).toString().padStart(2, '0')}-${result.day.toString().padStart(2, '0')}`;
          if (!this.dateValid(next)) { this.notice = '选择结果不是有效日期，请手动输入。'; return; }
          this.notice = ''; this.onFieldChange('date', next);
        }, onCancel: () => { if (this.generation === generation) { this.generation++; } }
      });
    } catch { this.notice = '日期选择器暂不可用，仍可直接输入完整日期。'; }
  }
  private openTimePicker(field: string): void {
    if (!this.mounted || !this.active || this.busy || (field !== 'start_time' && field !== 'end_time')) { return; }
    const value = field === 'start_time' ? this.entry.start_time : this.entry.end_time;
    const selected = new Date(0); selected.setHours(0, 0, 0, 0);
    if (/^([01]\d|2[0-3]):[0-5]\d$/.test(value)) {
      const parts = value.split(':'); selected.setHours(Number(parts[0]), Number(parts[1]), 0, 0);
    }
    const generation = ++this.generation; const context = this.contextKey; const original = JSON.stringify(this.entry);
    try {
      this.getUIContext().showTimePickerDialog({ selected: selected, useMilitaryTime: true,
        onAccept: (result: TimePickerResult) => {
          if (!this.pickerCurrent(generation, context, original)) { return; }
          this.generation++;
          if (result.hour === undefined || result.minute === undefined || !Number.isInteger(result.hour) ||
            !Number.isInteger(result.minute) || result.hour < 0 || result.hour > 23 || result.minute < 0 || result.minute > 59) {
            this.notice = '未取得完整时间，请手动输入。'; return;
          }
          this.notice = ''; this.onFieldChange(field, `${result.hour.toString().padStart(2, '0')}:${result.minute.toString().padStart(2, '0')}`);
        }, onCancel: () => { if (this.generation === generation) { this.generation++; } }
      });
    } catch { this.notice = '时间选择器暂不可用，仍可直接输入 HH:mm。'; }
  }
  private changed(field: string, value: string): void {
    if (!this.active || this.busy) { return; }
    this.generation++; this.notice = ''; this.onFieldChange(field, value);
  }
  // Read props inside UI update expressions instead of passing Builder value snapshots.
  private fieldValue(field: string): string {
    if (field === 'date') { return this.entry.date; }
    if (field === 'title') { return this.entry.title; }
    if (field === 'start_time') { return this.entry.start_time; }
    if (field === 'end_time') { return this.entry.end_time; }
    if (field === 'location') { return this.entry.location; }
    if (field === 'teacher') { return this.entry.teacher; }
    return '';
  }
  private fieldError(field: string): string {
    if (field === 'date') { return this.errors.date; }
    if (field === 'title') { return this.errors.title; }
    if (field === 'start_time') { return this.errors.start_time; }
    if (field === 'end_time') { return this.errors.end_time; }
    if (field === 'location') { return this.errors.location; }
    if (field === 'teacher') { return this.errors.teacher; }
    return '';
  }

  @Builder
  private Field(label: string, field: string, placeholder: string) {
    Column({ space: 6 }) {
      Text(field === 'date' && !this.editing ? '第一次上课日期 *' : label)
        .fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink).width('100%')
      Row({ space: 8 }) {
        TextInput({ text: this.fieldValue(field), placeholder: placeholder }).id(`${this.idPrefix}-${field}`).layoutWeight(1)
          .constraintSize({ minHeight: 50 }).fontSize(AppTheme.bodySize).fontColor(AppTheme.ink)
          .backgroundColor(AppTheme.field).borderRadius(AppTheme.controlRadius).padding({ left: 12, right: 12 })
          .enabled(this.active && !this.busy)
          .accessibilityText(`${field === 'date' && !this.editing ? '第一次上课日期 *' : label}${this.fieldError(field).length > 0 ? `，${this.fieldError(field)}` : ''}`)
          .onChange((next: string) => this.changed(field, next)).onAreaChange(() => this.locateError())
        if (field === 'date' || field === 'start_time' || field === 'end_time') {
          Button('选择').constraintSize({ minHeight: 50, minWidth: 64 }).fontSize(AppTheme.bodySize)
            .fontColor(AppTheme.accent).backgroundColor(AppTheme.accentSoft).enabled(this.active && !this.busy)
            .accessibilityText(field === 'date' ? '选择日期' : field === 'start_time' ? '选择开始时间' : '选择结束时间')
            .onClick(() => { if (field === 'date') { this.openDatePicker(); } else { this.openTimePicker(field); } })
        }
      }.width('100%')
      if (this.fieldError(field).length > 0) {
        Text(this.fieldError(field)).fontSize(AppTheme.metaSize).fontColor(AppTheme.danger).width('100%')
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  build() {
    Column({ space: 16 }) {
      Text(this.editing ? '修改这一次课程' : '添加一门课程')
        .fontSize(AppTheme.sectionTitle).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink).width('100%')
      if (this.canReuse && !this.editing) {
        Button('沿用上一门信息').constraintSize({ minHeight: 48 }).width('100%').fontSize(AppTheme.bodySize)
          .fontColor(AppTheme.accent).backgroundColor(AppTheme.accentSoft).enabled(this.active && !this.busy)
          .onClick(() => this.onReuse())
        Text('只复制到新表单，不会更改或再次加入上一门课程。').fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
      }
      if (this.firstError().length > 0) {
        Button('定位第一处错误').constraintSize({ minHeight: 48 }).width('100%').fontColor(AppTheme.danger)
          .backgroundColor(AppTheme.dangerSoft).onClick(() => { this.focusRequested(); this.locateError(); })
      }
      this.Field('课程名称 *', 'title', '例如：操作系统')
      this.Field('上课日期 *', 'date', 'YYYY-MM-DD')
      this.Field('开始时间 *', 'start_time', '08:05')
      this.Field('结束时间 *', 'end_time', '09:40')
      Text('使用北京时间、24 小时制；当天结束时间应晚于开始时间，也可直接手动输入。')
        .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
      Button(this.optionalExpanded ? '收起补充信息' : '地点、教师与重复周次（选填）')
        .constraintSize({ minHeight: 48 }).width('100%').fontSize(AppTheme.bodySize).fontColor(AppTheme.accent)
        .backgroundColor(AppTheme.accentSoft).onClick(() => this.optionalExpanded = !this.optionalExpanded)
      if (this.optionalExpanded || this.errors.location.length > 0 || this.errors.teacher.length > 0) {
        this.Field('上课地点（选填）', 'location', '例如：第7教研楼北406')
        this.Field('任课教师（选填）', 'teacher', '老师姓名')
        if (!this.editing && this.showRepeat) {
          Text('每周同一天，连续添加').fontSize(AppTheme.bodySize).fontColor(AppTheme.ink).width('100%')
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach([1, 4, 8, 16], (weeks: number) => {
              Button(weeks === 1 ? '仅一次' : `${weeks} 周`).constraintSize({ minHeight: 48 }).margin({ right: 8, bottom: 8 })
                .fontSize(AppTheme.bodySize).fontColor(this.repeatWeeks === weeks ? AppTheme.onAccent : AppTheme.ink)
                .backgroundColor(this.repeatWeeks === weeks ? AppTheme.accent : AppTheme.field).enabled(this.active && !this.busy)
                .accessibilityText(`${weeks} 次，${this.repeatWeeks === weeks ? '已选择' : '未选择'}`)
                .onClick(() => this.onWeeksChange(weeks))
            }, (weeks: number) => weeks.toString())
          }.width('100%')
        }
      }
      Text(this.editing || !this.showRepeat ? '只修改选中的这一次；不会推测或展开原始系列课程。' :
        this.repeatWeeks === 1 ? '默认仅添加一次，不自动生成整学期。' : `将生成 ${this.repeatWeeks} 个具体日期；单双周和节假日请逐条核对。`)
        .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
      if (this.notice.length > 0) { Text(this.notice).fontSize(AppTheme.metaSize).fontColor(AppTheme.warning).width('100%') }
      if (!this.editing && this.showRepeat) {
        Button('加入并继续').width('100%').constraintSize({ minHeight: 50 }).fontSize(AppTheme.bodySize)
          .fontColor(AppTheme.onAccent).backgroundColor(AppTheme.accent).enabled(this.active && !this.busy).onClick(() => this.onSave(true))
      }
      Button(this.saveLabel.length > 0 ? this.saveLabel : this.editing ? '保存这次修改' : '加入并收起')
        .width('100%').constraintSize({ minHeight: 50 }).fontSize(AppTheme.bodySize).fontColor(AppTheme.accent)
        .backgroundColor(AppTheme.accentSoft).enabled(this.active && !this.busy).onClick(() => this.onSave(false))
      Button('取消本次编辑').width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
        .fontColor(AppTheme.quiet).backgroundColor(Color.Transparent).enabled(this.active && !this.busy).onClick(() => this.onCancel())
    }.width('100%').alignItems(HorizontalAlign.Start).padding(AppTheme.cardInset)
      .backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius).onAreaChange(() => this.locateError())
  }
}
