import { validatedActionReceipt } from '../utils/ActionReliability';
import { CourseReview, CourseOverlap, CourseAcknowledgement, PendingAction, PlanningTaskDraft } from '../model/ApiModels';
import { courseCandidates, validCoursePolicy } from '../utils/CourseReview';
import { formatPlanDateTime } from '../utils/PlanPresentation';
import { AppTheme } from '../theme/AppTheme';

@Component
export struct CourseReviewPanel {
  @Prop action: PendingAction;
  @Prop reviewEnabled: boolean = true;
  @Prop selected: CourseAcknowledgement[] = [];
  onToggle: (review: CourseReview) => void = () => {};

  private title(review: CourseReview): string {
    return courseCandidates(this.action).find((task: PlanningTaskDraft) => task.candidate_id === review.candidate_id)?.title ?? '这项任务';
  }
  private checked(review: CourseReview): boolean {
    return this.selected.some((item: CourseAcknowledgement) => item.candidate_id === review.candidate_id && item.review_digest === review.review_digest);
  }
  private reviews(): CourseReview[] {
    return validCoursePolicy(this.action) ? (this.action.course_reviews ?? []).filter((item: CourseReview) =>
      item.overlaps.length > 0 || item.revoke_only) : [];
  }

  build() {
    Column({ space: 12 }) {
      ForEach(this.reviews(), (review: CourseReview) => {
        Column({ space: 10 }) {
          Text(this.title(review)).fontSize(AppTheme.bodySize).fontColor(AppTheme.ink).fontWeight(FontWeight.Medium).width('100%')
          Text(review.revoke_only ? '关闭课内许可后，原时段仍需调整' :
            this.action.status === 'confirmed' && validatedActionReceipt(this.action) !== null ? '本次已确认课内安排；课表变化时会重新核对' : review.state === 'accepted' ? '已确认的课内安排' :
            review.allow_during_course ? '这项任务可以课内完成，仍需核对以下重叠' : '这项任务未允许课内完成，请调整时间或任务设置')
            .fontSize(AppTheme.bodySize).fontColor(AppTheme.warning).width('100%').wordBreak(WordBreak.BREAK_WORD)
          Text(`${review.school} · ${review.campus} · 北京时间`).fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%')
          ForEach(review.overlaps, (overlap: CourseOverlap) => {
            Column({ space: 4 }) {
              Text(`${overlap.course.date} · ${overlap.course.title}`).fontSize(AppTheme.bodySize).fontColor(AppTheme.ink).width('100%')
              Text(`课程 ${overlap.course.start_time}–${overlap.course.end_time} · ${overlap.course.location || '地点未填'}`)
                .fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
              Text(`重叠：${formatPlanDateTime(overlap.overlap_start_at)} 至 ${formatPlanDateTime(overlap.overlap_end_at)}`)
                .fontSize(AppTheme.bodySize).fontColor(AppTheme.warning).width('100%').wordBreak(WordBreak.BREAK_WORD)
            }.width('100%').alignItems(HorizontalAlign.Start)
          }, (overlap: CourseOverlap, index: number) => `${overlap.course_key}-${index}`)
          if (review.requires_acknowledgement && this.action.status === 'pending') {
            Button(this.checked(review) ? '已选择：仍这样安排（点此取消）' : '仍这样安排').width('100%').constraintSize({ minHeight: 48 })
              .fontSize(AppTheme.bodySize).fontColor(this.checked(review) ? AppTheme.onAccent : AppTheme.accent)
              .backgroundColor(this.checked(review) ? AppTheme.accent : AppTheme.accentSoft).borderRadius(AppTheme.controlRadius)
              .enabled(this.reviewEnabled).onClick(() => this.onToggle(review))
            Text('仅确认上面这项任务与所列课程的重叠；最后还需确认整份变更。')
              .fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
          }
        }.width('100%').padding(16).backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius).alignItems(HorizontalAlign.Start)
      }, (review: CourseReview) => `${this.action.proposal_id}-${review.candidate_id}-${review.review_digest}`)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
