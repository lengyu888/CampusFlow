import { CourseAcknowledgement, CourseOverlap, TaskStatusPreview, TaskStatusReceipt } from '../model/ApiModels';
import { TaskStatusItem, TaskStatusState } from '../utils/TaskStatusController';
import { formatPlanDateTime } from '../utils/PlanPresentation';
import { TaskScheduleDetails } from './TaskScheduleDetails';
import { AppTheme } from '../theme/AppTheme';

// Controlled view: Index owns the only account-scoped coordinator and durable operation ledger.
@Component
export struct TaskStatusPanel {
  @Prop @Watch('stateChanged') state: TaskStatusState = { items: [], selectedId: '', lockedTaskIds: [], pendingCount: 0, message: '' };
  @Prop active: boolean = true;
  onSelect: (id: string) => void = () => {};
  onCheck: (id: string) => void = () => {};
  onRetry: (id: string) => void = () => {};
  onConfirm: (id: string, acks: CourseAcknowledgement[]) => void = () => {};
  onCancel: (id: string) => void = () => {};
  onDismiss: (id: string) => void = () => {};
  onClose: () => void = () => {};
  onOpenTask: (id: string) => void = () => {};
  @State private selectedAcks: CourseAcknowledgement[] = [];
  @State private pageIndex: number = 0;
  @State private overlapPage: number = 0;
  private reviewKey: string = '';

  aboutToAppear(): void { this.stateChanged(); }
  private stateChanged(): void {
    const item = this.selected();
    const review = item?.operation?.preview?.course_review;
    const key = `${item?.operationId ?? ''}:${review?.review_digest ?? ''}`;
    if (key !== this.reviewKey) { this.reviewKey = key; this.selectedAcks = []; this.overlapPage = 0; }
    this.pageIndex = Math.min(this.pageIndex, Math.max(0, Math.ceil(this.state.items.length / 6) - 1));
  }
  private selected(): TaskStatusItem | null { return this.state.items.find((item: TaskStatusItem) => item.operationId === this.state.selectedId) ?? null; }
  private selectedItems(): TaskStatusItem[] { const selected = this.selected(); return selected === null ? [] : [selected]; }
  private items(): TaskStatusItem[] { return this.state.items.slice(this.pageIndex * 6, this.pageIndex * 6 + 6); }
  private label(item: TaskStatusItem): string {
    const title = item.operation?.preview?.task.title;
    return title ?? `${item.kind === 'restore' ? '恢复未完成' : '标记完成'} · 任务 ${item.taskId}`;
  }
  private phaseLabel(item: TaskStatusItem): string {
    if (item.busy) { return '正在核对 / 保存，请稍候'; }
    if (item.phase === 'applied') { return '该次操作已生效'; }
    if (item.phase === 'cancelled') { return '此恢复预览已取消'; }
    if (item.phase === 'review') { return '恢复预览 · 尚未改变任务'; }
    if (item.phase === 'cleanup') { return '服务结果已核实，本机记录待结清'; }
    if (item.phase === 'unknown' || item.phase === 'retryable') { return '结果待核对'; }
    return '本次操作未完成';
  }
  private previewContext(item: TaskStatusItem): string {
    if (item.operation?.state === 'cancelled') { return '这份恢复预览已取消，未执行；以下保留当时核对的内容。'; }
    if (item.operation?.state === 'applied') { return '该次恢复已生效；以下是当时核对的预览，不是当前任务快照。'; }
    return '已完成 → 未完成 · 仅恢复状态，保留当前任务内容';
  }
  private checked(preview: TaskStatusPreview): boolean {
    return this.selectedAcks.some((ack: CourseAcknowledgement) => ack.candidate_id === preview.candidate_id && ack.review_digest === preview.course_review.review_digest);
  }
  private toggleAck(item: TaskStatusItem): void {
    const current = this.selected(); const preview = current?.operation?.preview;
    if (!this.active || current?.operationId !== item.operationId || !current.canConfirm || current.busy || preview === null || preview === undefined || !preview.course_review.requires_acknowledgement) { return; }
    this.selectedAcks = this.checked(preview) ? [] : [{ candidate_id: preview.candidate_id, review_digest: preview.course_review.review_digest }];
  }
  private confirm(item: TaskStatusItem): void {
    const current = this.selected(); const preview = current?.operation?.preview;
    if (!this.active || current?.operationId !== item.operationId || !current.canConfirm || current.busy || preview === null || preview === undefined) { return; }
    if (preview.course_review.requires_acknowledgement && !this.checked(preview)) { return; }
    this.onConfirm(current.operationId, this.selectedAcks.map((ack: CourseAcknowledgement) => ({ candidate_id: ack.candidate_id, review_digest: ack.review_digest })));
  }
  private overlaps(preview: TaskStatusPreview): CourseOverlap[] { return preview.course_review.overlaps.slice(this.overlapPage * 6, this.overlapPage * 6 + 6); }
  private canOpenTask(item: TaskStatusItem): boolean { return this.active && !this.state.lockedTaskIds.includes(item.taskId); }

  @Builder
  private Receipt(receipt: TaskStatusReceipt) {
    Column({ space: 8 }) {
      Text(receipt.kind === 'complete' ? '这次标记完成已保存' : '这次恢复未完成已保存').fontSize(AppTheme.sectionTitle).fontColor(AppTheme.success).width('100%')
      Text(`生效时间：${formatPlanDateTime(receipt.applied_at)}`).fontSize(AppTheme.bodySize).fontColor(AppTheme.ink).width('100%')
      Text(`状态：${receipt.before_status === 'completed' ? '已完成' : '未完成'} → ${receipt.after_status === 'completed' ? '已完成' : '未完成'}`)
        .fontSize(AppTheme.bodySize).fontColor(AppTheme.ink).width('100%')
      Text('这是该次操作的回执，当前任务可能已有后续修改；请打开任务查看最新内容。恢复不会删除专注记录，也不会还原旧标题、时间或地点。')
        .fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
      Text(`回执编号：${receipt.operation_id}`).fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
    }.width('100%').padding(16).alignItems(HorizontalAlign.Start).backgroundColor(AppTheme.successSoft).borderRadius(AppTheme.cardRadius)
  }

  @Builder
  private Preview(item: TaskStatusItem, preview: TaskStatusPreview) {
    Column({ space: 12 }) {
      Text(preview.task.title).fontSize(AppTheme.sectionTitle).fontColor(AppTheme.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
      Text(this.previewContext(item)).fontSize(AppTheme.bodySize).fontColor(AppTheme.secondary).width('100%')
      TaskScheduleDetails({ startAt: preview.task.start_at, endAt: preview.task.end_at, location: preview.task.location, reminderMinutes: preview.task.reminder_minutes })
      Text(`预览有效至：${formatPlanDateTime(item.operation?.expires_at ?? null)}`).fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%')
      ForEach(preview.conflicts, (message: string, index: number) => {
        Text(`不能恢复：${message}`).fontSize(AppTheme.bodySize).fontColor(AppTheme.danger).width('100%').wordBreak(WordBreak.BREAK_WORD)
      }, (_message: string, index: number) => `${item.operationId}-conflict-${index}`)
      ForEach(preview.warnings, (message: string, index: number) => {
        Text(message).fontSize(AppTheme.bodySize).fontColor(AppTheme.warning).width('100%').wordBreak(WordBreak.BREAK_WORD)
      }, (_message: string, index: number) => `${item.operationId}-warning-${index}`)
      if (preview.course_review.overlaps.length > 0) {
        Text('重新核对课内安排').fontSize(AppTheme.sectionTitle).fontColor(AppTheme.warning).width('100%')
        Text('过去的课内确认不代替这次恢复。请核对当前课程、任务和重叠时段。').fontSize(AppTheme.bodySize).fontColor(AppTheme.secondary).width('100%')
        Text(`${preview.course_review.school} · ${preview.course_review.campus} · 北京时间`).fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%')
        ForEach(this.overlaps(preview), (overlap: CourseOverlap, index: number) => {
          Column({ space: 4 }) {
            Text(`${overlap.course.date} · ${overlap.course.title}`).fontSize(AppTheme.bodySize).fontColor(AppTheme.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
            Text(`课程 ${overlap.course.start_time}–${overlap.course.end_time} · ${overlap.course.location || '地点未填'} · ${overlap.course.teacher || '教师未填'}`)
              .fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
            Text(`实际重叠：${formatPlanDateTime(overlap.overlap_start_at)} 至 ${formatPlanDateTime(overlap.overlap_end_at)}`)
              .fontSize(AppTheme.bodySize).fontColor(AppTheme.warning).width('100%').wordBreak(WordBreak.BREAK_WORD)
          }.width('100%').alignItems(HorizontalAlign.Start)
        }, (overlap: CourseOverlap, index: number) => `${item.operationId}-${this.overlapPage}-${overlap.course_key}-${index}`)
        if (preview.course_review.overlaps.length > 6) {
          Text(`重叠课程第 ${this.overlapPage + 1} / ${Math.ceil(preview.course_review.overlaps.length / 6)} 页`).fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary)
          Row({ space: 8 }) {
            Button('上一页').constraintSize({ minHeight: 48 }).layoutWeight(1).enabled(this.overlapPage > 0).onClick(() => this.overlapPage--)
            Button('下一页').constraintSize({ minHeight: 48 }).layoutWeight(1).enabled((this.overlapPage + 1) * 6 < preview.course_review.overlaps.length).onClick(() => this.overlapPage++)
          }.width('100%')
        }
        if (preview.course_review.requires_acknowledgement) {
          Button(this.checked(preview) ? '已选择：仍这样安排（点此取消）' : '仍这样安排').width('100%').constraintSize({ minHeight: 48 })
            .fontSize(AppTheme.bodySize).fontColor(this.checked(preview) ? AppTheme.onAccent : AppTheme.accent)
            .backgroundColor(this.checked(preview) ? AppTheme.accent : AppTheme.accentSoft).enabled(this.active && item.canConfirm && !item.busy)
            .onClick(() => this.toggleAck(item))
        }
      }
      if (item.canConfirm) {
        Button('确认恢复未完成').width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
          .fontColor(AppTheme.onAccent).backgroundColor(AppTheme.accent)
          .enabled(this.active && !item.busy && (!preview.course_review.requires_acknowledgement || this.checked(preview))).onClick(() => this.confirm(item))
      }
    }.width('100%').padding(16).alignItems(HorizontalAlign.Start).backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
  }

  build() {
    Column({ space: 8 }) {
      Row({ space: 12 }) {
        Button('返回').constraintSize({ minHeight: 48, minWidth: 64 }).fontColor(AppTheme.accent).backgroundColor(Color.Transparent).onClick(() => this.onClose())
        Text('完成与恢复记录').fontSize(AppTheme.sectionTitle).fontColor(AppTheme.ink).layoutWeight(1).wordBreak(WordBreak.BREAK_WORD)
      }.width('100%')
      Scroll() {
        Column({ space: 16 }) {
          Text('关闭此页不会取消已提交的操作。待核对记录会保留；只限制对应任务，其他任务仍可使用。').fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
          if (this.state.message.length > 0) { Text(this.state.message).fontSize(AppTheme.bodySize).fontColor(AppTheme.warning).width('100%').wordBreak(WordBreak.BREAK_WORD) }
          ForEach(this.items(), (item: TaskStatusItem) => {
            Button({ type: ButtonType.Normal }) {
              Column({ space: 4 }) {
                Text(this.label(item)).fontSize(AppTheme.bodySize).fontColor(AppTheme.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
                Text(this.phaseLabel(item)).fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%')
              }.width('100%').alignItems(HorizontalAlign.Start)
            }.width('100%').constraintSize({ minHeight: 56 }).padding(12).backgroundColor(this.state.selectedId === item.operationId ? AppTheme.accentSoft : AppTheme.surface)
              .borderRadius(AppTheme.controlRadius).onClick(() => this.onSelect(item.operationId))
          }, (item: TaskStatusItem) => `${item.operationId}-${item.phase}`)
          if (this.state.items.length > 6) {
            Row({ space: 8 }) {
              Button('上一页').constraintSize({ minHeight: 48 }).layoutWeight(1).enabled(this.pageIndex > 0).onClick(() => this.pageIndex--)
              Text(`${this.pageIndex + 1}/${Math.ceil(this.state.items.length / 6)}`).fontSize(AppTheme.metaSize)
              Button('下一页').constraintSize({ minHeight: 48 }).layoutWeight(1).enabled((this.pageIndex + 1) * 6 < this.state.items.length).onClick(() => this.pageIndex++)
            }.width('100%')
          }
          ForEach(this.selectedItems(), (item: TaskStatusItem) => {
            Column({ space: 12 }) {
              Text(this.phaseLabel(item)).fontSize(AppTheme.sectionTitle).fontColor(item.phase === 'applied' ? AppTheme.success : AppTheme.ink).width('100%')
              if (item.message.length > 0) { Text(item.message).fontSize(AppTheme.bodySize).fontColor(AppTheme.warning).width('100%').wordBreak(WordBreak.BREAK_WORD) }
              if (item.operation?.preview) { this.Preview(item, item.operation.preview) }
              if (item.operation?.receipt) { this.Receipt(item.operation.receipt) }
              if (!item.busy && ['unknown', 'cleanup', 'retryable', 'review'].includes(item.phase)) {
                Button('核对原操作结果').width('100%').constraintSize({ minHeight: 48 }).enabled(this.active).onClick(() => this.onCheck(item.operationId))
              }
              if (item.canRetry) {
                Button('用原编号和原内容重试').width('100%').constraintSize({ minHeight: 48 }).enabled(this.active && !item.busy).onClick(() => this.onRetry(item.operationId))
              }
              if (item.canCancel) {
                Button('取消这份恢复预览').width('100%').constraintSize({ minHeight: 48 }).enabled(this.active && !item.busy).onClick(() => this.onCancel(item.operationId))
              }
              if (this.canOpenTask(item)) {
                Button('查看当前任务').width('100%').constraintSize({ minHeight: 48 }).onClick(() => this.onOpenTask(item.taskId))
              }
              if (['applied', 'cancelled', 'error'].includes(item.phase) && !this.state.lockedTaskIds.includes(item.taskId)) {
                Button('收起这条本机记录').width('100%').constraintSize({ minHeight: 48 }).enabled(this.active).onClick(() => this.onDismiss(item.operationId))
              }
            }.width('100%').alignItems(HorizontalAlign.Start)
          }, (item: TaskStatusItem) => `${item.operationId}-${item.phase}-${item.operation?.state ?? ''}`)
        }.width('100%').alignItems(HorizontalAlign.Start)
      }.width('100%').layoutWeight(1)
    }.width('100%').height('100%').padding({ left: 20, right: 20, bottom: 16 }).backgroundColor(AppTheme.bg)
  }
}
