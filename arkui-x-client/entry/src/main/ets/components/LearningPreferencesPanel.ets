import { CampusFlowApi } from '../services/CampusFlowApi';
import { LearningPreferencesController, PreferenceState, PreferenceIssue, PreferenceDraft, defaultPreferenceDraft, copyPreferenceDraft } from '../utils/LearningPreferences';
import { AppTheme } from '../theme/AppTheme';
import { ThemePalette, themePalette } from '../theme/ThemePalette';
import { FeedbackPanel } from './FeedbackPanel';
import { formatPlanDateTime } from '../utils/PlanPresentation';
import { InfoDisclosure } from './InfoDisclosure';

@Component
export struct LearningPreferencesPanel {
  @StorageLink('campusflowThemePalette') private palette: ThemePalette = themePalette('paper-green');
  @Watch('connectionChanged') @Prop baseUrl: string;
  @Watch('connectionChanged') @Prop token: string;
  @Watch('connectionChanged') @Prop userId: string;
  @Watch('activityChanged') @Prop active: boolean = true;
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
    const draft: PreferenceDraft = copyPreferenceDraft(this.state.draft);
    if (field === 'session') { draft.session = value; }
    else if (field === 'rest') { draft.rest = value; }
    else if (field === 'daily') { draft.daily = value; }
    else if (field === 'period') { draft.period = value; }
    this.discardConfirm = false; this.instance().edit(draft);
  }
  private setEnabled(enabled: boolean): void {
    const draft: PreferenceDraft = copyPreferenceDraft(this.state.draft);
    draft.enabled = enabled;
    this.discardConfirm = false; this.instance().edit(draft);
  }
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
      Text(label).fontSize(this.palette.bodySize).fontColor(this.palette.ink).width('100%')
      TextInput({ text: value, placeholder: placeholder }).type(InputType.Number).constraintSize({ minHeight: 48 })
        .fontSize(this.palette.bodySize).backgroundColor(this.palette.field).borderRadius(this.palette.controlRadius)
        .enabled(this.editable()).onChange((text: string) => this.editField(field, text)).accessibilityText(label)
      if (this.fieldError(field).length > 0) { Text(this.fieldError(field)).fontSize(this.palette.metaSize).fontColor(this.palette.danger).width('100%') }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
  build() {
    Column({ space: 16 }) {
        Text(this.summary()).fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
        InfoDisclosure({ title: '这些偏好如何使用？', message: '只保存你主动填写的选项。保存并启用后，用于助手后续安排学习；课程冲突、截止时间和你当次的明确要求优先。不会自动推断习惯，也不会修改已经确认的任务。这里的学习时长用于安排建议，不会自动启动专注计时。' })
        if (this.state.snapshot !== null) {
          InfoDisclosure({ title: '查看已保存的偏好', message: `当前${this.state.snapshot.enabled ? '启用' : '停用'}：单次学习 ${this.state.snapshot.session_minutes} 分钟，休息 ${this.state.snapshot.break_minutes} 分钟，每日 ${this.state.snapshot.daily_minutes} 分钟，偏好${this.periodLabel(this.state.snapshot.preferred_period)}。${this.state.snapshot.updated_at === null ? '尚无保存记录。' : `更新于 ${formatPlanDateTime(this.state.snapshot.updated_at)}`}` })
        }
        if (this.state.message.length > 0) {
          FeedbackPanel({ kind: this.busy() ? 'loading' : this.state.phase === 'unknown' ? 'unknown' :
            this.state.phase === 'stale' ? 'warning' : this.state.phase === 'error' ? 'error' : 'info',
            title: this.state.phase === 'unknown' ? '保存结果待核对' : '学习偏好状态', message: this.state.message })
        }
        Row({ space: 12 }) {
          Column({ space: 4 }) {
            Text('使用学习偏好').fontSize(this.palette.bodySize).fontColor(this.palette.ink).width('100%')
            Text('点击保存后生效').fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Toggle({ type: ToggleType.Switch, isOn: this.state.draft.enabled }).selectedColor(this.palette.accent)
            .enabled(this.editable()).onChange((enabled: boolean) => this.setEnabled(enabled)).accessibilityText('启用学习偏好，需要保存后生效')
        }.width('100%').constraintSize({ minHeight: 48 })
        Divider().color(this.palette.line).strokeWidth(0.5)
        Text('学习节奏').fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium).fontColor(this.palette.ink).width('100%')
        this.NumberField('session', '单次学习（分钟）', this.state.draft.session, '15–120')
        this.NumberField('rest', '单次休息（分钟）', this.state.draft.rest, '0–30')
        this.NumberField('daily', '每日学习（分钟）', this.state.draft.daily, '30–480')
        Text('偏好时段').fontSize(this.palette.bodySize).fontColor(this.palette.ink).width('100%')
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(['any', 'morning', 'afternoon', 'evening'], (period: string) => {
            Button(`${this.periodLabel(period)}${this.state.draft.period === period ? ' · 已选' : ''}`)
              .constraintSize({ minHeight: 44 }).fontSize(this.palette.bodySize).margin({ right: 8, bottom: 8 })
              .fontColor(this.state.draft.period === period ? this.palette.accent : this.palette.secondary)
              .backgroundColor(this.state.draft.period === period ? this.palette.accentSoft : this.palette.field)
              .borderRadius(this.palette.controlRadius)
              .enabled(this.editable()).onClick(() => this.editField('period', period))
          }, (period: string) => period)
        }.width('100%')
        if (this.state.phase === 'unknown' || this.state.canRetry) {
          Button('使用原操作重试核对').width('100%').constraintSize({ minHeight: 48 }).fontColor(this.palette.accent)
            .backgroundColor(this.palette.accentSoft).enabled(this.state.canRetry && !this.busy()).onClick(() => this.instance().retry())
        } else {
          Button('保存偏好').width('100%').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
            .fontColor(this.palette.onAccent).backgroundColor(this.palette.accent).borderRadius(this.palette.controlRadius)
            .enabled(this.editable() && this.state.dirty).onClick(() => this.instance().save())
        }
        Button('读取最新值，保留草稿').width('100%').constraintSize({ minHeight: 44 }).fontColor(this.palette.accent)
          .backgroundColor(Color.Transparent).enabled(!this.busy() && (this.state.phase !== 'unknown' || this.state.canRetry)).onClick(() => this.instance().load())
        if (this.state.dirty && this.editable()) {
          Button('放弃未保存草稿').width('100%').constraintSize({ minHeight: 44 }).fontColor(this.palette.secondary)
            .backgroundColor(Color.Transparent).onClick(() => this.discardConfirm = true)
        }
        if (this.discardConfirm) {
          Text('确认后重新读取当前偏好；读取失败仍保留草稿。').fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
          Button('确认放弃并读取').constraintSize({ minHeight: 48 }).fontColor(this.palette.danger).backgroundColor(this.palette.dangerSoft)
            .enabled(!this.busy()).onClick(() => { this.discardConfirm = false; this.instance().load(true); })
          Button('保留草稿').constraintSize({ minHeight: 48 }).onClick(() => this.discardConfirm = false)
        }
        Divider().color(this.palette.line).strokeWidth(0.5)
        if (this.state.confirmClear) {
          Text('确认清除后停用并恢复默认值，只影响后续请求；已开始的运行和历史不会撤回。').fontSize(this.palette.bodySize).fontColor(this.palette.danger).width('100%')
          Button('确认清除学习偏好').width('100%').constraintSize({ minHeight: 48 }).fontColor(this.palette.danger)
            .backgroundColor(this.palette.dangerSoft).enabled(this.editable()).onClick(() => this.instance().clear())
          Button('保留偏好').constraintSize({ minHeight: 48 }).onClick(() => this.instance().cancelClear())
        } else {
          Button('清除学习偏好…').width('100%').constraintSize({ minHeight: 44 }).fontColor(this.palette.danger)
            .backgroundColor(Color.Transparent).enabled(this.editable()).onClick(() => this.instance().askClear())
        }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(this.palette.cardInset)
      .backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
  }
}
