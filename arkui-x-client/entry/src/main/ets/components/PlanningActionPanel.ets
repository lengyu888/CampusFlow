import { PendingAction, PlanningTaskDraft, PlanningPlanDraft } from '../model/ApiModels';
import { PlanningActionState } from '../utils/PlanningAction';
import { canConfirmAction, validatedActionReceipt, receiptTaskId, receiptPlanId } from '../utils/ActionReliability';
import { formatPlanDateTime } from '../utils/PlanPresentation';
import { TaskScheduleDetails } from './TaskScheduleDetails';
import { FeedbackPanel } from './FeedbackPanel';
import { AppTheme } from '../theme/AppTheme';

@Component
export struct PlanningActionPanel {
  @Prop state: PlanningActionState;
  @Prop active: boolean = true;
  @Prop retryIntent: string = '';
  onConfirm: () => void = () => {};
  onCancel: () => void = () => {};
  onCheck: () => void = () => {};
  onDismiss: () => void = () => {};
  onOpenTask: (id: string) => void = () => {};
  onOpenPlan: (id: string) => void = () => {};

  private actions(): PendingAction[] { return this.state.action === null ? [] : [this.state.action]; }
  private busy(): boolean { return ['previewing', 'confirming', 'cancelling', 'checking'].includes(this.state.phase); }
  private label(action: PendingAction): string {
    return `${action.action === 'create' ? '创建' : action.action === 'update' ? '修改' : '删除'}${action.kind === 'task' ? '任务' : '计划'}`;
  }

  @Builder
  private TaskFields(label: string, task: PlanningTaskDraft) {
    Column({ space: 8 }) {
      Text(label).fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%')
      Text(task.title).fontSize(AppTheme.bodySize).fontColor(AppTheme.ink).fontWeight(FontWeight.Medium)
        .width('100%').wordBreak(WordBreak.BREAK_WORD)
      TaskScheduleDetails({ startAt: task.start_at, endAt: task.end_at, location: task.location, reminderMinutes: task.reminder_minutes })
    }.width('100%').alignItems(HorizontalAlign.Start).padding(16).backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
  }

  @Builder
  private PlanFields(label: string, plan: PlanningPlanDraft) {
    Column({ space: 8 }) {
      Text(label).fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%')
      Text(plan.title).fontSize(AppTheme.bodySize).fontColor(AppTheme.ink).fontWeight(FontWeight.Medium)
        .width('100%').wordBreak(WordBreak.BREAK_WORD)
      Text(plan.summary.length > 0 ? plan.summary : '未设置说明').fontSize(AppTheme.bodySize)
        .fontColor(AppTheme.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
      Text(plan.target_date === null ? '未设截止日' : `截止日：${plan.target_date}`)
        .fontSize(AppTheme.bodySize).fontColor(AppTheme.secondary).width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start).padding(16).backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
  }

  build() {
    Column({ space: 16 }) {
      if (this.state.phase === 'uncertain') {
        FeedbackPanel({ kind: 'unknown', title: '变更结果待核对', message: this.state.message })
      } else {
        Text(this.state.message).fontSize(AppTheme.bodySize).fontColor(AppTheme.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
      }
      if (this.busy()) { LoadingProgress().width(24).height(24).color(AppTheme.accent) }
      ForEach(this.actions(), (action: PendingAction) => {
        Column({ space: 12 }) {
          Text(this.label(action)).fontSize(AppTheme.sectionTitle).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink).width('100%')
          if (action.before_task !== undefined && action.before_task !== null) { this.TaskFields('变更前', action.before_task) }
          if (action.before_plan !== undefined && action.before_plan !== null) {
            this.PlanFields('变更前', action.before_plan)
            Text(`当前 ${action.before_plan.milestones.length} 个阶段 · ${action.before_plan.task_count} 项子任务 · ${action.before_plan.completed_count} 项已完成`)
              .fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
          }
          if (action.action === 'delete') {
            Text(action.kind === 'plan' ? '变更后：删除此计划与阶段，子任务保留为独立待办，时间与完成状态保持不变。' :
              '变更后：删除这条任务；关联计划的任务数量与进度会更新。')
              .fontSize(AppTheme.bodySize).fontColor(AppTheme.danger).width('100%').wordBreak(WordBreak.BREAK_WORD)
          } else {
            if (action.payload.task !== undefined) { this.TaskFields('变更后', action.payload.task) }
            if (action.payload.plan !== undefined) {
              this.PlanFields('变更后', action.payload.plan)
              Text('仅修改计划名称、说明和截止日；现有阶段与子任务保持原内容和时间。')
                .fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%')
            }
          }
          if (action.reason !== null && action.reason.length > 0) {
            Text(`原因：${action.reason}`).fontSize(AppTheme.bodySize).fontColor(AppTheme.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
          }
          ForEach(action.conflicts, (conflict: string, index: number) => {
            Text(`冲突 ${index + 1}：${conflict}`).fontSize(AppTheme.bodySize).fontColor(AppTheme.danger).width('100%').wordBreak(WordBreak.BREAK_WORD)
          }, (conflict: string, index: number) => `${index}`)
          ForEach(action.warnings ?? [], (warning: string, index: number) => {
            Text(`核对提示 ${index + 1}：${warning}`).fontSize(AppTheme.bodySize).fontColor(AppTheme.warning).width('100%').wordBreak(WordBreak.BREAK_WORD)
          }, (warning: string, index: number) => `${index}`)
          Text(`预览有效至 ${formatPlanDateTime(action.expires_at ?? null)} · 北京时间`)
            .fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%')
          if (this.state.phase === 'review' || this.state.phase === 'retryable') {
            if (this.retryIntent !== 'cancel') {
              Button(this.state.phase === 'retryable' ? '重试确认同一笔变更' : '确认以上变更').width('100%').constraintSize({ minHeight: 48 })
                .fontSize(AppTheme.bodySize).fontColor(AppTheme.onAccent).backgroundColor(AppTheme.accent)
                .borderRadius(AppTheme.controlRadius).enabled(this.active && canConfirmAction(action)).onClick(this.onConfirm)
            }
            if (!canConfirmAction(action)) {
              Text('候选存在冲突或已过期，不能直接确认。取消本提案后可调整草稿重新预览。')
                .fontSize(AppTheme.metaSize).fontColor(AppTheme.danger).width('100%')
            }
            if (this.state.phase === 'review' || this.state.phase === 'retryable') {
              Button(this.retryIntent === 'cancel' ? '重试取消同一笔提案' : '取消本提案').width('100%').constraintSize({ minHeight: 48 })
                .fontSize(AppTheme.bodySize).fontColor(AppTheme.secondary).backgroundColor(AppTheme.surface)
                .borderRadius(AppTheme.controlRadius).enabled(this.active).onClick(this.onCancel)
            }
          }
          if (this.state.phase === 'uncertain' || this.state.phase === 'retryable') {
            Button('查询本次结果').width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
              .fontColor(AppTheme.accent).backgroundColor(AppTheme.accentSoft).borderRadius(AppTheme.controlRadius)
              .enabled(this.active).onClick(this.onCheck)
          }
          if (this.state.phase === 'resolved' && validatedActionReceipt(action) !== null) {
            Text(`执行时间：${formatPlanDateTime(action.receipt?.applied_at ?? null)}`)
              .fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%')
            Text(`回执：${action.receipt?.receipt_id ?? ''}`).fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary)
              .width('100%').wordBreak(WordBreak.BREAK_WORD)
            if (action.kind === 'plan' && action.action === 'delete') {
              Text(`已保留 ${action.receipt?.retained_task_ids.length ?? 0} 项独立待办。`).fontSize(AppTheme.bodySize).fontColor(AppTheme.secondary).width('100%')
            }
            if (receiptTaskId(action).length > 0) {
              Button('查看这条任务').width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
                .fontColor(AppTheme.accent).backgroundColor(AppTheme.accentSoft).borderRadius(AppTheme.controlRadius)
                .onClick(() => this.onOpenTask(receiptTaskId(action)))
            }
            if (receiptPlanId(action).length > 0) {
              Button('查看这个计划').width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
                .fontColor(AppTheme.accent).backgroundColor(AppTheme.accentSoft).borderRadius(AppTheme.controlRadius)
                .onClick(() => this.onOpenPlan(receiptPlanId(action)))
            }
          }
        }.width('100%').alignItems(HorizontalAlign.Start)
      }, (action: PendingAction) => `${action.proposal_id}-${this.state.phase}`)
      if (['resolved', 'cancelled', 'invalidated', 'error', 'idle'].includes(this.state.phase)) {
        Button('返回继续编辑').width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
          .fontColor(AppTheme.accent).backgroundColor(AppTheme.accentSoft).borderRadius(AppTheme.controlRadius).onClick(this.onDismiss)
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
