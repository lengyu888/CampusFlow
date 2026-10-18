import { FocusRecord, FocusInterval, FocusGap } from '../model/FocusModels';
import { FocusState, FocusLocalView, FocusPendingView, emptyFocusState } from '../utils/FocusController';
import { formatPlanDateTime } from '../utils/PlanPresentation';
import { AppTheme } from '../theme/AppTheme';
import { AppIllustration } from '../components/AppIllustration';

// Only a view. Index owns the account-level clock, durable queue and server gateway.
@Component
export struct FocusPage {
  @Watch('stateChanged') @Prop state: FocusState = emptyFocusState();
  @Prop active: boolean = true;
  @Prop taskId: string = '';
  @Prop taskTitle: string = '';
  @Prop notice: string = '';
  @Prop completingTask: boolean = false;
  onBack: () => void = () => {};
  onStart: (taskId: string, targetMs: number | null, mode: 'online' | 'offline') => void = () => {};
  onPause: () => void = () => {};
  onResume: () => void = () => {};
  onEnd: () => void = () => {};
  onSync: () => void = () => {};
  onCheck: (id: string) => void = () => {};
  onRetry: (id: string) => void = () => {};
  onSelect: (id: string) => void = () => {};
  onRefresh: () => void = () => {};
  onLoadMore: () => void = () => {};
  onRemoteEnd: (id: string, revision: number) => void = () => {};
  onDelete: (id: string, revision: number) => void = () => {};
  onClearLocal: () => void = () => {};
  onCompleteTask: (id: string) => void = () => {};
  onOpenTask: (id: string) => void = () => {};
  @State private targetText: string = '';
  @State private offline: boolean = false;
  @State private inputMessage: string = '';
  @State private confirmation: string = '';
  @State private confirmId: string = '';
  @State private confirmRevision: number = 0;
  @State private intervalPage: number = 0;
  @State private gapPage: number = 0;
  @State private expandedOperations: string[] = [];
  @State private detailExpanded: boolean = false;
  @State private startExpanded: boolean = false;
  private selectedKey: string = '';
  private detailKey: string = '';

  aboutToAppear(): void { this.stateChanged(); }
  private stateChanged(): void {
    if (this.selectedKey !== this.state.selectedRecordId) {
      this.selectedKey = this.state.selectedRecordId; this.detailExpanded = false; this.startExpanded = false;
    }
    const key = `${this.state.selectedRecordId}:${this.state.record?.revision ?? ''}`;
    if (key !== this.detailKey) {
      this.detailKey = key; this.intervalPage = 0; this.gapPage = 0;
      if (this.confirmation === 'delete') { this.confirmation = ''; }
    }
    if (this.confirmation === 'remote' && (this.state.activeRecord?.record_id !== this.confirmId || this.state.activeRecord.revision !== this.confirmRevision)) { this.confirmation = ''; }
    if (this.confirmation === 'end' && this.state.local?.recordId !== this.confirmId) { this.confirmation = ''; }
  }
  private duration(ms: number): string {
    const seconds = Math.floor(Math.max(0, ms) / 1000);
    const hours = Math.floor(seconds / 3600); const minutes = Math.floor(seconds / 60) % 60; const rest = seconds % 60;
    return hours > 0 ? `${hours}:${String(minutes).padStart(2, '0')}:${String(rest).padStart(2, '0')}` : `${minutes}:${String(rest).padStart(2, '0')}`;
  }
  private targetReached(record: FocusLocalView): boolean {
    return record.targetMs !== null && record.elapsedMs >= record.targetMs;
  }
  private recordTitle(record: FocusRecord): string {
    if (record.task_missing) { return '原任务已删除 · 保留的专注记录'; }
    return record.task_title?.trim() || '任务名称暂未读取';
  }
  private localTitle(record: FocusLocalView): string {
    if (this.state.record?.record_id === record.recordId) { return this.recordTitle(this.state.record); }
    if (record.taskId === this.taskId && this.taskTitle.trim().length > 0) { return this.taskTitle; }
    return '本机专注记录 · 打开核对关联任务';
  }
  private localLabel(record: FocusLocalView): string {
    if (record.saveState === 'error') { return '本机保存失败 · 请保留页面并处理'; }
    if (record.saveState === 'pending') { return '正在保存到本机'; }
    if (record.localState === 'running') { return '正在记录前台经过时间'; }
    if (record.localState === 'ended') { return '本机已结束 · 同步状态见下方'; }
    if (record.localState === 'interrupted') { return '上次记录中断 · 未核实的尾段不补算'; }
    if (record.localState === 'paused') { return '已暂停 · 暂停期间不累计'; }
    return '准备记录 · 等待期间不累计';
  }
  private recordLabel(record: FocusRecord): string {
    return record.state === 'ended' ? '已同步 · 已结束' : record.state === 'paused' ? '已同步 · 已暂停' : '已同步 · 尚未结束';
  }
  private toggleOperationDetails(id: string): void {
    this.expandedOperations = this.expandedOperations.includes(id) ? this.expandedOperations.filter((value: string) => value !== id) : this.expandedOperations.concat([id]);
  }
  private otherLocalRecords(): FocusLocalView[] {
    return this.state.localRecords.filter((record: FocusLocalView): boolean => record.recordId !== this.state.local?.recordId);
  }
  private otherHistoryRecords(): FocusRecord[] {
    return this.state.history.filter((record: FocusRecord): boolean => record.record_id !== this.state.record?.record_id);
  }
  private showStartCard(): boolean {
    return this.startExpanded || this.state.local === null && this.state.record === null && this.state.activeRecord === null;
  }
  private toggleRecordDetails(id: string): void {
    if (this.state.record?.record_id === id) { this.detailExpanded = !this.detailExpanded; }
  }
  private synchronizedLabel(local: FocusLocalView): string {
    return local.confirmedElapsedMs === 0 ? '尚无已确认的计时片段；本机显示仍保留，进行中的片段不会立即计入已同步时长。' :
      `已确认片段 ${this.duration(local.confirmedElapsedMs)}；与本机时长分别核对，不相加。`;
  }
  private messageIsWarning(): boolean {
    if ((this.state.message === '本机已暂停；服务器是否已记录以同步结果为准。' ||
      this.state.message === '本机已结束计时；记录保存与任务完成分别核对。') &&
      this.state.pendingOperations.length === 0 && this.state.errorCode.length === 0) { return false; }
    return this.state.message !== '这次记录操作已取得回执，当前记录将单独读取。' &&
      this.state.message !== '本机专注缓存已清理；这不取消已发往服务器的操作。';
  }
  private noticeIsWarning(): boolean {
    return this.notice !== '本机专注记录已清除，服务端已确认的记录不受影响。' &&
      this.notice !== '退出后本机专注记录已清除。' &&
      this.notice !== '最新任务已经完成，不重复提交，也不会把它恢复为未完成。';
  }
  private startAllowed(): boolean {
    return this.active && this.taskId.trim().length > 0 && this.state.phase !== 'loading' &&
      !this.state.localRecords.some((item: FocusLocalView) => item.localState !== 'ended') && this.state.activeRecord === null;
  }
  private startRequested(): void {
    if (!this.startAllowed()) { return; }
    const text = this.targetText.trim();
    if (text.length > 0 && (!/^\d+$/.test(text) || !Number.isSafeInteger(Number(text)) || Number(text) < 1 || Number(text) > 240)) {
      this.inputMessage = '目标可留空；填写时请输入 1–240 分钟的整数。'; return;
    }
    this.inputMessage = '';
    this.onStart(this.taskId, text.length === 0 ? null : Number(text) * 60000, this.offline ? 'offline' : 'online');
  }
  private askEnd(): void {
    if (!this.active || !this.state.local?.canEnd) { return; }
    this.confirmation = 'end'; this.confirmId = this.state.local.recordId;
  }
  private askRemoteEnd(record: FocusRecord): void {
    if (!this.active || this.state.activeRecord?.record_id !== record.record_id || this.state.activeRecord.revision !== record.revision) { return; }
    this.confirmation = 'remote'; this.confirmId = record.record_id; this.confirmRevision = record.revision;
  }
  private askDelete(record: FocusRecord): void {
    if (!this.active || record.state === 'running' || this.state.pendingOperations.some((op: FocusPendingView) => op.recordId === record.record_id)) { return; }
    this.confirmation = 'delete'; this.confirmId = record.record_id; this.confirmRevision = record.revision;
  }
  private resumeRemoteRecord(record: FocusRecord): void {
    if (!this.active || record.state !== 'paused' || this.state.selectedRecordId !== record.record_id ||
      this.state.record?.revision !== record.revision || this.state.pendingOperations.length > 0) { return; }
    this.onResume();
  }
  private confirmAction(): void {
    if (!this.active) { return; }
    const kind = this.confirmation; const id = this.confirmId; const revision = this.confirmRevision;
    this.confirmation = '';
    if (kind === 'end' && this.state.local?.recordId === id && this.state.local.canEnd) { this.onEnd(); }
    else if (kind === 'remote' && this.state.activeRecord?.record_id === id && this.state.activeRecord.revision === revision) { this.onRemoteEnd(id, revision); }
    else if (kind === 'delete' && this.state.record?.record_id === id && this.state.record.revision === revision && this.state.record.state !== 'running' &&
      !this.state.pendingOperations.some((op: FocusPendingView) => op.recordId === id)) { this.onDelete(id, revision); }
    else if (kind === 'clear') { this.onClearLocal(); }
  }
  private confirmationText(): string {
    if (this.confirmation === 'clear') { return '清除会丢失本机尚未同步的区间和原操作标识。服务器已确认记录不受影响；清除不等于取消服务器已收到的操作。'; }
    if (this.confirmation === 'delete') { return '删除这条服务端记录及其区间明细，不能撤销；相关任务和它的完成状态不变。'; }
    if (this.confirmation === 'remote') { return '结束当前账号在服务端尚未结束的记录。无法核实的尾段只标为缺口，不补算时长；其他设备仍需重新核对。'; }
    return '结束后不能继续这一条记录。已核实区间会保留，待同步区间需取得回执；这不会把任务标为完成。';
  }
  private completionTaskId(): string {
    if (this.state.local?.localState === 'ended') { return this.state.local.taskId; }
    return this.state.record?.state === 'ended' && !this.state.record.task_missing ? this.state.record.task_id : '';
  }
  private completeRequested(): void {
    const taskId = this.completionTaskId();
    if (this.active && !this.completingTask && taskId.length > 0) { this.onCompleteTask(taskId); }
  }
  private visibleIntervals(): FocusInterval[] { return this.state.intervals.slice(this.intervalPage * 20, this.intervalPage * 20 + 20); }
  private visibleGaps(): FocusGap[] { return this.state.unknownGaps.slice(this.gapPage * 20, this.gapPage * 20 + 20); }
  private gapReason(gap: FocusGap): string {
    if (gap.reason === 'clock_changed') { return '设备时钟发生变化'; }
    if (gap.reason === 'sample_gap') { return '采样间隔无法核实'; }
    if (gap.reason === 'remote_end') { return '另一处结束了记录，尾段无法核实'; }
    if (gap.reason === 'storage_failed') { return '本机保存失败'; }
    return '进程中断，未核实尾段';
  }

  @Builder
  private StartCard() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        AppIllustration({ source: $r('app.media.xj_focus_entry'), imageWidth: 72, imageHeight: 72, fallbackIcon: 'book' })
        Column({ space: 4 }) {
          Text('给这一件事，一段专心的时间').fontSize(AppTheme.sectionTitle).fontColor(AppTheme.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
          Text(this.taskTitle || '从首页或计划的具体任务进入，才能开始记录。').fontSize(AppTheme.bodySize).fontColor(AppTheme.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%')
      Text('目标分钟（可不填）').fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%')
      TextInput({ text: this.targetText, placeholder: '不设目标，正向计时' }).height(52).fontSize(AppTheme.bodySize).backgroundColor(AppTheme.field)
        .onChange((value: string) => { this.targetText = value; this.inputMessage = ''; })
      if (this.inputMessage.length > 0) { Text(this.inputMessage).fontSize(AppTheme.bodySize).fontColor(AppTheme.danger).width('100%').wordBreak(WordBreak.BREAK_WORD) }
      Button(this.offline ? '已选：仅在本机记录（点此改为联网）' : '联网记录（点此改为仅本机）').width('100%').constraintSize({ minHeight: 48 })
        .fontSize(AppTheme.bodySize).backgroundColor(AppTheme.accentSoft).fontColor(AppTheme.accent).enabled(this.active).onClick(() => this.offline = !this.offline)
      Text(this.offline ? '仅本机模式：不会立即发出开始请求，不能保证其他设备没有进行中的记录。之后需主动同步，冲突不会自动覆盖。' :
        '联网模式：确认开始成功后计时，网络等待不计入。应用内切页继续，退到后台会暂停。')
        .fontSize(AppTheme.metaSize).fontColor(this.offline ? AppTheme.warning : AppTheme.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
      if (!this.state.clockAvailable) { Text('可靠计时能力尚未确认。点击开始会重新核对；无法取得可靠时钟时不会计时。').fontSize(AppTheme.bodySize).fontColor(AppTheme.warning).width('100%').wordBreak(WordBreak.BREAK_WORD) }
      Button('开始这项任务的专注记录').width('100%').constraintSize({ minHeight: 48 }).fontColor(AppTheme.onAccent).backgroundColor(AppTheme.accent)
        .fontSize(AppTheme.bodySize).enabled(this.startAllowed()).onClick(() => this.startRequested())
    }.width('100%').padding(16).alignItems(HorizontalAlign.Start).backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
  }

  @Builder
  private Current(local: FocusLocalView) {
    Column({ space: 12 }) {
      Text(this.localTitle(local)).fontSize(AppTheme.sectionTitle).fontColor(AppTheme.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
      Text(this.localLabel(local)).fontSize(AppTheme.bodySize).fontColor(local.saveState === 'error' ? AppTheme.danger : AppTheme.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
      Text(this.duration(local.elapsedMs)).fontSize('42fp').fontWeight(FontWeight.Medium).fontColor(AppTheme.ink).width('100%')
      Text(`本机已核实时长${local.targetMs === null ? ' · 不设目标' : ` · 目标 ${Math.floor(local.targetMs / 60000)} 分钟`}`).fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%')
      if (this.targetReached(local)) { Text('已到设定时长，计时继续；何时结束由你决定。').fontSize(AppTheme.bodySize).fontColor(AppTheme.accent).width('100%').wordBreak(WordBreak.BREAK_WORD) }
      Text(this.synchronizedLabel(local)).fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
      if (local.unknownGapCount > 0) { Text(`还有 ${local.unknownGapCount} 段无法核实时长，不作补算。`).fontSize(AppTheme.bodySize).fontColor(AppTheme.warning).width('100%') }
      if (local.canPause) { Button('暂停').width('100%').constraintSize({ minHeight: 48 }).enabled(this.active).onClick(() => this.onPause()) }
      if (local.canResume) { Button('继续这条记录').width('100%').constraintSize({ minHeight: 48 }).enabled(this.active).onClick(() => this.onResume()) }
      if (local.canEnd) { Button('结束本次记录').width('100%').constraintSize({ minHeight: 48 }).enabled(this.active).onClick(() => this.askEnd()) }
      if (local.localState === 'ended') { AppIllustration({ source: $r('app.media.xj_focus_end'), imageWidth: 100, imageHeight: 67, fallbackIcon: 'check' }) }
    }.width('100%').padding(16).alignItems(HorizontalAlign.Start).backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
  }

  @Builder
  private Pending(op: FocusPendingView) {
    Column({ space: 8 }) {
      Text(op.kind === 'start' ? '开始记录' : op.kind === 'resume' ? '继续记录' : op.kind === 'pause' ? '暂停记录' : op.kind === 'end' ? '结束记录' : '删除记录')
        .fontSize(AppTheme.bodySize).fontColor(AppTheme.ink).width('100%')
      Text(op.message).fontSize(AppTheme.bodySize).fontColor(AppTheme.warning).width('100%').wordBreak(WordBreak.BREAK_WORD)
      if (op.canCheck) { Button('查询这次操作结果').width('100%').constraintSize({ minHeight: 48 }).enabled(this.active).onClick(() => this.onCheck(op.operationId)) }
      if (op.canRetry) { Button('重试这次操作').width('100%').constraintSize({ minHeight: 48 }).enabled(this.active).onClick(() => this.onRetry(op.operationId)) }
      Button(this.expandedOperations.includes(op.operationId) ? '收起核对详情' : '核对详情').width('100%').constraintSize({ minHeight: 48 })
        .fontColor(AppTheme.secondary).backgroundColor(Color.Transparent).onClick(() => this.toggleOperationDetails(op.operationId))
      if (this.expandedOperations.includes(op.operationId)) {
        Text(`原操作编号 ${op.operationId}\n查询不会重发；只有明确未查到时，重试才会使用相同编号和相同内容，避免重复记录。`)
          .fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
      }
    }.width('100%').padding(16).alignItems(HorizontalAlign.Start).backgroundColor(AppTheme.warningSoft).borderRadius(AppTheme.cardRadius)
  }

  @Builder
  private Detail(record: FocusRecord) {
    Column({ space: 12 }) {
      if (this.state.local?.recordId !== record.record_id) {
        Text(this.recordTitle(record)).fontSize(AppTheme.sectionTitle).fontColor(AppTheme.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
        Text(this.duration(record.confirmed_elapsed_ms)).fontSize('32fp').fontWeight(FontWeight.Medium).fontColor(AppTheme.ink).width('100%')
        Text(`${this.recordLabel(record)} · 已确认片段，不代表有效学习时长`).fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
      }
      if (this.state.intervalError.length > 0 || this.state.unknownGaps.length > 0) {
        Text(this.state.intervalError || `还有 ${this.state.unknownGaps.length} 段待核对，不补算时长。`).fontSize(AppTheme.bodySize).fontColor(AppTheme.warning).width('100%').wordBreak(WordBreak.BREAK_WORD)
      }
      Button(this.detailExpanded ? '收起已同步区间与核对依据' : '查看已同步区间与核对依据').width('100%').constraintSize({ minHeight: 48 }).fontColor(AppTheme.accent).backgroundColor(AppTheme.accentSoft)
        .onClick(() => this.toggleRecordDetails(record.record_id))
      if (this.detailExpanded) {
      Text(`开始于 ${formatPlanDateTime(record.started_at)}${record.ended_at === null ? '' : `\n结束标注 ${formatPlanDateTime(record.ended_at)}`}`).fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
      Text('时间标注用于核对；总时长来自已确认区间，不是开始与结束日期之差，也不代表有效学习时长。').fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
      if (this.state.intervalLoading) { Text('正在读取完整区间…').fontSize(AppTheme.bodySize).fontColor(AppTheme.secondary) }
      if (this.state.intervalError.length > 0) { Text(this.state.intervalError).fontSize(AppTheme.bodySize).fontColor(AppTheme.warning).width('100%').wordBreak(WordBreak.BREAK_WORD) }
      ForEach(this.visibleIntervals(), (interval: FocusInterval) => {
        Text(`${formatPlanDateTime(interval.started_at)} 至 ${formatPlanDateTime(interval.ended_at)}\n本段 ${this.duration(interval.elapsed_ms)}`)
          .fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
      }, (interval: FocusInterval) => interval.interval_id)
      if (this.state.intervals.length > 20) {
        Text(`已核实区间 ${this.intervalPage + 1}/${Math.ceil(this.state.intervals.length / 20)} 页`).fontSize(AppTheme.metaSize)
        Row({ space: 8 }) {
          Button('上一页').layoutWeight(1).constraintSize({ minHeight: 48 }).enabled(this.intervalPage > 0).onClick(() => this.intervalPage--)
          Button('下一页').layoutWeight(1).constraintSize({ minHeight: 48 }).enabled((this.intervalPage + 1) * 20 < this.state.intervals.length).onClick(() => this.intervalPage++)
        }.width('100%')
      }
      ForEach(this.visibleGaps(), (gap: FocusGap) => {
        Text(`${this.gapReason(gap)}\n${formatPlanDateTime(gap.observed_start_at)} 至 ${formatPlanDateTime(gap.observed_end_at)} · 不计时长`)
          .fontSize(AppTheme.metaSize).fontColor(AppTheme.warning).width('100%').wordBreak(WordBreak.BREAK_WORD)
      }, (gap: FocusGap) => gap.gap_id)
      if (this.state.unknownGaps.length > 20) {
        Text(`无法核实的区间 ${this.gapPage + 1}/${Math.ceil(this.state.unknownGaps.length / 20)} 页`).fontSize(AppTheme.metaSize)
        Row({ space: 8 }) {
          Button('上一页').layoutWeight(1).constraintSize({ minHeight: 48 }).enabled(this.gapPage > 0).onClick(() => this.gapPage--)
          Button('下一页').layoutWeight(1).constraintSize({ minHeight: 48 }).enabled((this.gapPage + 1) * 20 < this.state.unknownGaps.length).onClick(() => this.gapPage++)
        }.width('100%')
      }
      }
      if (!record.task_missing) { Button('查看当前任务').width('100%').constraintSize({ minHeight: 48 }).onClick(() => this.onOpenTask(record.task_id)) }
      if (record.state !== 'ended' && this.state.local === null && this.state.activeRecord?.record_id === record.record_id) {
        Button('结束账号中的这条记录').width('100%').constraintSize({ minHeight: 48 }).enabled(this.active).onClick(() => this.askRemoteEnd(record))
      }
      if (record.state === 'paused' && this.state.local === null) {
        Button('继续这条已暂停记录').width('100%').constraintSize({ minHeight: 48 }).enabled(this.active && this.state.pendingOperations.length === 0)
          .onClick(() => this.resumeRemoteRecord(record))
      }
      if (record.state !== 'running') { Button('删除这条已同步记录').width('100%').constraintSize({ minHeight: 48 }).fontColor(AppTheme.danger).backgroundColor(AppTheme.dangerSoft)
        .enabled(this.active && !this.state.pendingOperations.some((op: FocusPendingView) => op.recordId === record.record_id)).onClick(() => this.askDelete(record)) }
    }.width('100%').padding(16).alignItems(HorizontalAlign.Start).backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
  }

  build() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Button('返回').constraintSize({ minHeight: 48, minWidth: 64 }).fontColor(AppTheme.accent).backgroundColor(Color.Transparent).onClick(() => this.onBack())
        Text('专注记录').fontSize(AppTheme.sectionTitle).fontColor(AppTheme.ink).layoutWeight(1)
      }.width('100%')
      Scroll() {
        Column({ space: 16 }) {
          Text('专心做一件事，完成与否由你决定。').fontSize(AppTheme.bodySize).fontColor(AppTheme.secondary).width('100%')
          if (this.state.phase === 'loading') { Text('正在读取本机专注记录…').fontSize(AppTheme.bodySize).fontColor(AppTheme.secondary).width('100%') }
          if (this.notice.length > 0) { Text(this.notice).fontSize(AppTheme.bodySize).fontColor(this.noticeIsWarning() ? AppTheme.warning : AppTheme.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD) }
          if (this.state.message.length > 0) { Text(this.state.message).fontSize(AppTheme.bodySize).fontColor(this.messageIsWarning() ? AppTheme.warning : AppTheme.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD) }
          if (this.state.local !== null) { this.Current(this.state.local) }
          if (this.state.record !== null) { this.Detail(this.state.record) }
          if (this.showStartCard()) { this.StartCard() }
          else if (this.state.local === null || this.state.local.localState === 'ended') {
            Button('另开一条专注记录').width('100%').constraintSize({ minHeight: 48 }).fontColor(AppTheme.accent).backgroundColor(AppTheme.accentSoft).onClick(() => this.startExpanded = true)
          }
          if (this.state.activeRecord !== null && this.state.activeRecord.record_id !== this.state.local?.recordId && this.state.activeRecord.record_id !== this.state.record?.record_id) {
            Column({ space: 10 }) {
              Text('账号还有一条尚未结束的记录').fontSize(AppTheme.sectionTitle).fontColor(AppTheme.ink).width('100%')
              Text(this.recordTitle(this.state.activeRecord)).fontSize(AppTheme.bodySize).fontColor(AppTheme.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
              Button('查看这条记录').width('100%').constraintSize({ minHeight: 48 }).onClick(() => this.onSelect(this.state.activeRecord?.record_id ?? ''))
              Button('结束账号中的这条记录').width('100%').constraintSize({ minHeight: 48 }).enabled(this.active).onClick(() => { if (this.state.activeRecord !== null) { this.askRemoteEnd(this.state.activeRecord); } })
            }.width('100%').padding(16).backgroundColor(AppTheme.warningSoft).borderRadius(AppTheme.cardRadius)
          }
          if (this.state.pendingOperations.length > 0) {
            Text('待同步与待确认').fontSize(AppTheme.sectionTitle).fontColor(AppTheme.ink).width('100%')
            ForEach(this.state.pendingOperations, (op: FocusPendingView) => { this.Pending(op) }, (op: FocusPendingView) => `${op.operationId}-${op.phase}`)
            Button('同步本机记录').width('100%').constraintSize({ minHeight: 48 }).enabled(this.active).onClick(() => this.onSync())
          }
          if (this.completionTaskId().length > 0) {
            Text('计时结束与任务完成是两件事。下方会先读取最新任务，再单独记录完成状态。').fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
            Button(this.completingTask ? '正在核对最新任务…' : '另外标记这项任务已完成').width('100%').constraintSize({ minHeight: 48 }).enabled(this.active && !this.completingTask).onClick(() => this.completeRequested())
          }
          if (this.confirmation.length > 0) {
            Column({ space: 10 }) {
              Text(this.confirmationText()).fontSize(AppTheme.bodySize).fontColor(AppTheme.warning).width('100%').wordBreak(WordBreak.BREAK_WORD)
              Button('保留，暂不执行').width('100%').constraintSize({ minHeight: 48 }).onClick(() => this.confirmation = '')
              Button('确认执行此项操作').width('100%').constraintSize({ minHeight: 48 }).enabled(this.active).onClick(() => this.confirmAction())
            }.width('100%').padding(16).backgroundColor(AppTheme.warningSoft).borderRadius(AppTheme.cardRadius)
          }
          if (this.otherLocalRecords().length > 0) {
            Text('其他本机记录').fontSize(AppTheme.sectionTitle).fontColor(AppTheme.ink).width('100%')
            ForEach(this.otherLocalRecords(), (local: FocusLocalView) => {
              Button({ type: ButtonType.Normal }) {
                Column({ space: 4 }) {
                  Text(this.localTitle(local)).fontSize(AppTheme.bodySize).fontColor(AppTheme.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
                  Text(`${this.duration(local.elapsedMs)} · ${this.localLabel(local)}`).fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
                }.width('100%').alignItems(HorizontalAlign.Start)
              }.width('100%').constraintSize({ minHeight: 64 }).padding(12).backgroundColor(AppTheme.surface).onClick(() => this.onSelect(local.recordId))
            }, (local: FocusLocalView) => `${local.recordId}-${local.localState}-${local.saveState}`)
          }
          Row({ space: 8 }) {
            Text(this.state.record === null ? '已同步记录' : '其他已同步记录').fontSize(AppTheme.sectionTitle).fontColor(AppTheme.ink).layoutWeight(1)
            Button('刷新记录').constraintSize({ minHeight: 48 }).enabled(this.active && !this.state.historyLoading).onClick(() => this.onRefresh())
          }.width('100%')
          if (this.state.historyLoading) { Text('正在读取记录…').fontSize(AppTheme.bodySize).fontColor(AppTheme.secondary) }
          if (this.state.historyError.length > 0) { Text(this.state.historyError).fontSize(AppTheme.bodySize).fontColor(AppTheme.warning).width('100%').wordBreak(WordBreak.BREAK_WORD) }
          if (!this.state.historyLoading && this.state.historyError.length === 0 && this.state.history.length === 0) { Text('还没有已读取的同步记录。').fontSize(AppTheme.bodySize).fontColor(AppTheme.secondary).width('100%') }
          if (this.state.record !== null) { Text('当前所选记录已在上方展示；这里列出其他已读取记录。').fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%') }
          ForEach(this.otherHistoryRecords(), (record: FocusRecord) => {
            Button({ type: ButtonType.Normal }) {
              Column({ space: 4 }) {
                Text(this.recordTitle(record)).fontSize(AppTheme.bodySize).fontColor(AppTheme.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
                Text(`${formatPlanDateTime(record.started_at)} · ${this.duration(record.confirmed_elapsed_ms)} · ${this.recordLabel(record)}`).fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
              }.width('100%').alignItems(HorizontalAlign.Start)
            }.width('100%').constraintSize({ minHeight: 64 }).padding(12).backgroundColor(AppTheme.surface).onClick(() => this.onSelect(record.record_id))
          }, (record: FocusRecord) => `${record.record_id}-${record.revision}`)
          if (this.state.historyHasMore) { Button('加载更多记录').width('100%').constraintSize({ minHeight: 48 }).enabled(this.active && !this.state.historyLoading).onClick(() => this.onLoadMore()) }

          Button('清除本机专注记录与待同步内容').width('100%').constraintSize({ minHeight: 48 }).fontColor(AppTheme.danger).backgroundColor(AppTheme.dangerSoft)
            .enabled(this.active).onClick(() => this.confirmation = 'clear')
        }.width('100%').alignItems(HorizontalAlign.Start)
      }.width('100%').layoutWeight(1)
    }.width('100%').height('100%').padding({ left: 20, right: 20, bottom: 16 }).backgroundColor(AppTheme.bg)
  }
}
