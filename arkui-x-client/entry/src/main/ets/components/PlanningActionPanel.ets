import { CourseAcknowledgement, CourseReview } from '../model/ApiModels';
import { CourseReviewPanel } from './CourseReviewPanel';
import { validCourseAcknowledgements } from '../utils/CourseReview';
import { PendingAction, PlanningTaskDraft, PlanningPlanDraft } from '../model/ApiModels';
import { PlanningActionState } from '../utils/PlanningAction';
import { canConfirmAction, validatedActionReceipt, receiptTaskId, receiptPlanId } from '../utils/ActionReliability';
import { formatPlanDateTime } from '../utils/PlanPresentation';
import { TaskScheduleDetails } from './TaskScheduleDetails';
import { FeedbackPanel } from './FeedbackPanel';
import { AppTheme } from '../theme/AppTheme';
import { ThemePalette, themePalette } from '../theme/ThemePalette';

@Component
export struct PlanningActionPanel {
  @StorageLink('campusflowThemePalette') private palette: ThemePalette = themePalette('paper-green');
  @Prop @Watch('stateChanged') state: PlanningActionState;
  @State private selectedCourseAcks: CourseAcknowledgement[] = [];
  private courseSelectionKey: string = '';
  @Prop active: boolean = true;
  @Prop retryIntent: string = '';
  onConfirm: (acknowledgements: CourseAcknowledgement[]) => void = () => {};
  onCancel: () => void = () => {};
  onCheck: () => void = () => {};
  onDismiss: () => void = () => {};
  onOpenTask: (id: string) => void = () => {};
  onOpenPlan: (id: string) => void = () => {};

  private stateChanged(): void {
    const action = this.state.action;
    const key = action === null ? '' : `${action.proposal_id}:${(action.course_reviews ?? []).map((item: CourseReview) => item.review_digest).join(':')}`;
    if (key !== this.courseSelectionKey || !['review', 'retryable'].includes(this.state.phase)) { this.selectedCourseAcks = []; }
    this.courseSelectionKey = key;
  }
  private toggleCourse(review: CourseReview): void {
    if (!this.active || !['review', 'retryable'].includes(this.state.phase)) { return; }
    const existing = this.selectedCourseAcks.some((item: CourseAcknowledgement) => item.candidate_id === review.candidate_id && item.review_digest === review.review_digest);
    this.selectedCourseAcks = this.selectedCourseAcks.filter((item: CourseAcknowledgement) => item.candidate_id !== review.candidate_id);
    if (!existing) { this.selectedCourseAcks = this.selectedCourseAcks.concat([{ candidate_id: review.candidate_id, review_digest: review.review_digest }]); }
  }

  private actions(): PendingAction[] { return this.state.action === null ? [] : [this.state.action]; }
  private busy(): boolean { return ['previewing', 'confirming', 'cancelling', 'checking'].includes(this.state.phase); }
  private label(action: PendingAction): string {
    return `${action.action === 'create' ? '创建' : action.action === 'update' ? '修改' : '删除'}${action.kind === 'task' ? '任务' : '计划'}`;
  }

  @Builder
  private TaskFields(label: string, task: PlanningTaskDraft) {
    Column({ space: 8 }) {
      Text(label).fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
      Text(task.title).fontSize(this.palette.bodySize).fontColor(this.palette.ink).fontWeight(FontWeight.Medium)
        .width('100%').wordBreak(WordBreak.BREAK_WORD)
      Text(task.allow_during_course === true ? '可在上课时完成：已开启' : '可在上课时完成：未开启')
        .fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
      TaskScheduleDetails({ startAt: task.start_at, endAt: task.end_at, location: task.location, reminderMinutes: task.reminder_minutes })
    }.width('100%').alignItems(HorizontalAlign.Start).padding(16).backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
  }

  @Builder
  private PlanFields(label: string, plan: PlanningPlanDraft) {
    Column({ space: 8 }) {
      Text(label).fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
      Text(plan.title).fontSize(this.palette.bodySize).fontColor(this.palette.ink).fontWeight(FontWeight.Medium)
        .width('100%').wordBreak(WordBreak.BREAK_WORD)
      Text(plan.summary.length > 0 ? plan.summary : '未设置说明').fontSize(this.palette.bodySize)
        .fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
      Text(plan.target_date === null ? '未设截止日' : `截止日：${plan.target_date}`)
        .fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start).padding(16).backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
  }

  build() {
    Column({ space: 16 }) {
      if (this.state.phase === 'uncertain') {
        FeedbackPanel({ kind: 'unknown', title: '变更结果待核对', message: this.state.message })
      } else {
        Text(this.state.message).fontSize(this.palette.bodySize).fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
      }
      if (this.busy()) { LoadingProgress().width(24).height(24).color(this.palette.accent) }
      ForEach(this.actions(), (action: PendingAction) => {
        Column({ space: 12 }) {
          Text(this.label(action)).fontSize(this.palette.sectionTitle).fontWeight(FontWeight.Bold).fontColor(this.palette.ink).width('100%')
          if (action.before_task !== undefined && action.before_task !== null) { this.TaskFields('变更前', action.before_task) }
          if (action.before_plan !== undefined && action.before_plan !== null) {
            this.PlanFields('变更前', action.before_plan)
            Text(`当前 ${action.before_plan.milestones.length} 个阶段 · ${action.before_plan.task_count} 项子任务 · ${action.before_plan.completed_count} 项已完成`)
              .fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
          }
          if (action.action === 'delete') {
            Text(action.kind === 'plan' ? '变更后：删除此计划与阶段，子任务保留为独立待办，时间与完成状态保持不变。' :
              '变更后：删除这条任务；关联计划的任务数量与进度会更新。')
              .fontSize(this.palette.bodySize).fontColor(this.palette.danger).width('100%').wordBreak(WordBreak.BREAK_WORD)
          } else {
            if (action.payload.task !== undefined) { this.TaskFields('变更后', action.payload.task) }
            if (action.payload.plan !== undefined) {
              this.PlanFields('变更后', action.payload.plan)
              Text('仅修改计划名称、说明和截止日；现有阶段与子任务保持原内容和时间。')
                .fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
            }
          }
          if (action.reason !== null && action.reason.length > 0) {
            Text(`原因：${action.reason}`).fontSize(this.palette.bodySize).fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
          }
          ForEach(action.conflicts, (conflict: string, index: number) => {
            Text(`冲突 ${index + 1}：${conflict}`).fontSize(this.palette.bodySize).fontColor(this.palette.danger).width('100%').wordBreak(WordBreak.BREAK_WORD)
          }, (conflict: string, index: number) => `${index}`)
          ForEach(action.warnings ?? [], (warning: string, index: number) => {
            Text(`核对提示 ${index + 1}：${warning}`).fontSize(this.palette.bodySize).fontColor(this.palette.warning).width('100%').wordBreak(WordBreak.BREAK_WORD)
          }, (warning: string, index: number) => `${index}`)
          CourseReviewPanel({ action: action, reviewEnabled: this.active && ['review', 'retryable'].includes(this.state.phase),
            selected: this.selectedCourseAcks, onToggle: (review: CourseReview) => this.toggleCourse(review) })
          Text(`预览有效至 ${formatPlanDateTime(action.expires_at ?? null)} · 北京时间`)
            .fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
          if (this.state.phase === 'review' || this.state.phase === 'retryable') {
            if (this.retryIntent !== 'cancel') {
              Button(this.state.phase === 'retryable' ? '重试确认同一笔变更' : '确认以上变更').width('100%').constraintSize({ minHeight: 48 })
                .fontSize(this.palette.bodySize).fontColor(this.palette.onAccent).backgroundColor(this.palette.accent)
                .borderRadius(this.palette.controlRadius).enabled(this.active && canConfirmAction(action) && validCourseAcknowledgements(action, this.selectedCourseAcks))
                .onClick(() => this.onConfirm(this.selectedCourseAcks))
            }
            if (!canConfirmAction(action)) {
              Text('候选存在冲突或已过期，不能直接确认。取消本提案后可调整草稿重新预览。')
                .fontSize(this.palette.metaSize).fontColor(this.palette.danger).width('100%')
            }
            if (this.state.phase === 'review' || this.state.phase === 'retryable') {
              Button(this.retryIntent === 'cancel' ? '重试取消同一笔提案' : '取消本提案').width('100%').constraintSize({ minHeight: 48 })
                .fontSize(this.palette.bodySize).fontColor(this.palette.secondary).backgroundColor(this.palette.surface)
                .borderRadius(this.palette.controlRadius).enabled(this.active).onClick(this.onCancel)
            }
          }
          if (this.state.phase === 'uncertain' || this.state.phase === 'retryable') {
            Button('查询本次结果').width('100%').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
              .fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft).borderRadius(this.palette.controlRadius)
              .enabled(this.active).onClick(this.onCheck)
          }
          if (this.state.phase === 'resolved' && validatedActionReceipt(action) !== null) {
            Text(`执行时间：${formatPlanDateTime(action.receipt?.applied_at ?? null)}`)
              .fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
            Text(`回执：${action.receipt?.receipt_id ?? ''}`).fontSize(this.palette.metaSize).fontColor(this.palette.secondary)
              .width('100%').wordBreak(WordBreak.BREAK_WORD)
            if (action.kind === 'plan' && action.action === 'delete') {
              Text(`已保留 ${action.receipt?.retained_task_ids.length ?? 0} 项独立待办。`).fontSize(this.palette.bodySize).fontColor(this.palette.secondary).width('100%')
            }
            if (receiptTaskId(action).length > 0) {
              Button('查看这条任务').width('100%').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
                .fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft).borderRadius(this.palette.controlRadius)
                .onClick(() => this.onOpenTask(receiptTaskId(action)))
            }
            if (receiptPlanId(action).length > 0) {
              Button('查看这个计划').width('100%').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
                .fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft).borderRadius(this.palette.controlRadius)
                .onClick(() => this.onOpenPlan(receiptPlanId(action)))
            }
          }
        }.width('100%').alignItems(HorizontalAlign.Start)
      }, (action: PendingAction) => `${action.proposal_id}-${this.state.phase}`)
      if (['resolved', 'cancelled', 'invalidated', 'error', 'idle'].includes(this.state.phase)) {
        Button('返回继续编辑').width('100%').constraintSize({ minHeight: 44 }).fontSize(this.palette.bodySize)
          .fontColor(this.palette.accent).backgroundColor(Color.Transparent).borderRadius(this.palette.controlRadius).onClick(this.onDismiss)
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
