import { CampusFlowApi } from '../services/CampusFlowApi';
import { LearningPreferencesController, PreferenceState, PreferenceIssue, PreferenceDraft, defaultPreferenceDraft } from '../utils/LearningPreferences';
import { AppTheme } from '../theme/AppTheme';
import { FeedbackPanel } from './FeedbackPanel';
import { formatPlanDateTime } from '../utils/PlanPresentation';

@Component
export struct LearningPreferencesPanel {
  @Watch('connectionChanged') @Prop baseUrl: string;
  @Watch('connectionChanged') @Prop token: string;
  @Watch('connectionChanged') @Prop userId: string;
  @Watch('activityChanged') @Prop active: boolean = true;
  @State private expanded: boolean = false;
  @State private discardConfirm: boolean = false;
  @State private state: PreferenceState = { phase: 'idle', snapshot: null, draft: defaultPreferenceDraft(), dirty: false,
    message: '', issues: [], confirmClear: false, canRetry: false };
  private controller: LearningPreferencesController | null = null;
  private alive: boolean = false;

  aboutToAppear(): void { this.alive = true; this.connectionChanged(); }
  aboutToDisappear(): void { this.alive = false; this.controller?.dispose(); this.controller = null; }
  private instance(): LearningPreferencesController {
    if (this.controller === null) {
      this.controller = new LearningPreferencesController(new CampusFlowApi(this.baseUrl, this.token), (state: PreferenceState) => {
        if (this.alive) { this.state = state; }
      });
    }
    return this.controller;
  }
  private connectionChanged(): void {
    if (!this.alive) { return; }
    this.discardConfirm = false;
    this.instance().configure(`${this.baseUrl}|${this.userId}|${this.token}`, new CampusFlowApi(this.baseUrl, this.token));
    this.instance().setActive(this.active);
  }
  private activityChanged(): void { if (this.alive) { this.instance().setActive(this.active); } }
  private editable(): boolean { return this.controller !== null && this.controller.editable(); }
  private busy(): boolean { return this.state.phase === 'loading' || this.state.phase === 'saving'; }
  private fieldError(field: string): string { return this.state.issues.find((item: PreferenceIssue) => item.field === field)?.message ?? ''; }
  private editField(field: string, value: string): void {
    const draft: PreferenceDraft = { ...this.state.draft };
    if (field === 'session') { draft.session = value; }
    else if (field === 'rest') { draft.rest = value; }
    else if (field === 'daily') { draft.daily = value; }
    else if (field === 'period') { draft.period = value; }
    this.discardConfirm = false; this.instance().edit(draft);
  }
  private setEnabled(enabled: boolean): void { this.discardConfirm = false; this.instance().edit({ ...this.state.draft, enabled: enabled }); }
  private periodLabel(period: string): string {
    return period === 'morning' ? '上午' : period === 'afternoon' ? '下午' : period === 'evening' ? '晚上' : '不限';
  }
  private summary(): string {
    if (this.state.snapshot === null) { return '明确填写、随时停用，不自动推断个人习惯'; }
    return `${this.state.snapshot.enabled ? '已启用' : '未启用'} · ${this.state.dirty ? '有未保存草稿' : '只用于后续学习安排'}`;
  }
  @Builder
  private NumberField(field: string, label: string, value: string, placeholder: string) {
    Column({ space: 6 }) {
      Text(label).fontSize(AppTheme.bodySize).fontColor(AppTheme.ink).width('100%')
      TextInput({ text: value, placeholder: placeholder }).type(InputType.Number).height(48)
        .fontSize(AppTheme.bodySize).backgroundColor(AppTheme.field).borderRadius(AppTheme.controlRadius)
        .enabled(this.editable()).onChange((text: string) => this.editField(field, text)).accessibilityText(label)
      if (this.fieldError(field).length > 0) { Text(this.fieldError(field)).fontSize(AppTheme.metaSize).fontColor(AppTheme.red).width('100%') }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
  build() {
    Column({ space: 12 }) {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 12 }) {
          Column({ space: 4 }) {
            Text('学习偏好').fontSize(AppTheme.sectionTitle).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink).width('100%')
            Text(this.summary()).fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Text(this.expanded ? '收起' : '展开').fontSize(AppTheme.metaSize).fontColor(AppTheme.actionBlue)
        }.width('100%')
      }.width('100%').constraintSize({ minHeight: 64 }).backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
        .onClick(() => this.expanded = !this.expanded)
      if (this.expanded) {
        Text('只保存下面这些主动填写的选项。启用后作为安排建议，课程冲突、截止时间和你当次明确要求优先。不会自动推断习惯。')
          .fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet).width('100%')
        if (this.state.snapshot !== null) {
          Text(`当前已保存：${this.state.snapshot.enabled ? '启用' : '停用'}，学习 ${this.state.snapshot.session_minutes} 分钟 / 休息 ${this.state.snapshot.break_minutes} 分钟，每日 ${this.state.snapshot.daily_minutes} 分钟，${this.periodLabel(this.state.snapshot.preferred_period)}。`)
            .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
          Text(this.state.snapshot.updated_at === null ? '尚无已保存偏好。' : `更新时间：${formatPlanDateTime(this.state.snapshot.updated_at)}`)
            .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
        }
        if (this.state.message.length > 0) {
          FeedbackPanel({ kind: this.busy() ? 'loading' : ['unknown', 'stale', 'error'].includes(this.state.phase) ? 'warning' : 'info',
            title: this.state.phase === 'unknown' ? '保存结果待核对' : '学习偏好状态', message: this.state.message })
        }
        Row({ space: 12 }) {
          Text('在后续安排中使用这些偏好').fontSize(AppTheme.bodySize).fontColor(AppTheme.ink).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.state.draft.enabled }).selectedColor(AppTheme.green)
            .enabled(this.editable()).onChange((enabled: boolean) => this.setEnabled(enabled)).accessibilityText('启用学习偏好，需要保存后生效')
        }.width('100%').constraintSize({ minHeight: 48 })
        this.NumberField('session', '单次学习（分钟）', this.state.draft.session, '15–120')
        this.NumberField('rest', '单次休息（分钟）', this.state.draft.rest, '0–30')
        this.NumberField('daily', '每日学习（分钟）', this.state.draft.daily, '30–480')
        Text('偏好时段').fontSize(AppTheme.bodySize).fontColor(AppTheme.ink).width('100%')
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(['any', 'morning', 'afternoon', 'evening'], (period: string) => {
            Button(`${this.periodLabel(period)}${this.state.draft.period === period ? ' · 已选' : ''}`)
              .constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize).margin({ right: 8, bottom: 8 })
              .fontColor(this.state.draft.period === period ? '#FFFFFF' : AppTheme.actionBlue)
              .backgroundColor(this.state.draft.period === period ? AppTheme.actionBlue : AppTheme.blueSoft)
              .enabled(this.editable()).onClick(() => this.editField('period', period))
          }, (period: string) => period)
        }.width('100%')
        if (this.state.phase === 'unknown' || this.state.canRetry) {
          Button('使用原操作重试核对').width('100%').constraintSize({ minHeight: 48 }).fontColor(AppTheme.actionBlue)
            .backgroundColor(AppTheme.blueSoft).enabled(this.state.canRetry && !this.busy()).onClick(() => this.instance().retry())
        } else {
          Button('保存偏好与开关').width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
            .fontColor('#FFFFFF').backgroundColor(AppTheme.actionBlue).enabled(this.editable() && this.state.dirty).onClick(() => this.instance().save())
        }
        Button('读取最新值 · 保留草稿').width('100%').constraintSize({ minHeight: 48 }).fontColor(AppTheme.actionBlue)
          .backgroundColor(AppTheme.blueSoft).enabled(!this.busy() && (this.state.phase !== 'unknown' || this.state.canRetry)).onClick(() => this.instance().load())
        if (this.state.dirty && this.editable()) {
          Button('放弃未保存草稿').width('100%').constraintSize({ minHeight: 48 }).fontColor(AppTheme.quiet)
            .backgroundColor(AppTheme.field).onClick(() => this.discardConfirm = true)
        }
        if (this.discardConfirm) {
          Text('确认后重新读取当前偏好；读取失败仍保留草稿。').fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
          Button('确认放弃并读取').constraintSize({ minHeight: 48 }).fontColor(AppTheme.red).backgroundColor(AppTheme.redSoft)
            .enabled(!this.busy()).onClick(() => { this.discardConfirm = false; this.instance().load(true); })
          Button('保留草稿').constraintSize({ minHeight: 48 }).onClick(() => this.discardConfirm = false)
        }
        if (this.state.confirmClear) {
          Text('确认清除后停用并恢复默认值，只影响后续请求；已开始的运行和历史不会撤回。').fontSize(AppTheme.bodySize).fontColor(AppTheme.red).width('100%')
          Button('确认清除学习偏好').width('100%').constraintSize({ minHeight: 48 }).fontColor(AppTheme.red)
            .backgroundColor(AppTheme.redSoft).enabled(this.editable()).onClick(() => this.instance().clear())
          Button('保留偏好').constraintSize({ minHeight: 48 }).onClick(() => this.instance().cancelClear())
        } else {
          Button('清除学习偏好…').width('100%').constraintSize({ minHeight: 48 }).fontColor(AppTheme.red)
            .backgroundColor(AppTheme.redSoft).enabled(this.editable()).onClick(() => this.instance().askClear())
        }
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(AppTheme.cardInset)
      .backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
  }
}
