import { AppTheme } from '../theme/AppTheme';
import { formatPlanReminder, formatPlanTimeRange } from '../utils/PlanPresentation';

// Shared by pending proposals and saved plans; these labels describe saved settings.
@Component
export struct TaskScheduleDetails {
  @Prop startAt: string | null = null;
  @Prop endAt: string | null = null;
  @Prop location: string | null = null;
  @Prop reminderMinutes: number | null = null;

  build() {
    Column({ space: 4 }) {
      Text(`时间：${formatPlanTimeRange(this.startAt, this.endAt)}`)
        .fontSize(13).lineHeight(20).fontColor(AppTheme.secondary).width('100%')
      Text(`地点：${this.location === null || this.location.trim().length === 0 ? '未设置' : this.location}`)
        .fontSize(13).lineHeight(20).fontColor(AppTheme.secondary).width('100%')
      Text(`提醒设置：${formatPlanReminder(this.reminderMinutes)}`)
        .fontSize(13).lineHeight(20).fontColor(AppTheme.secondary).width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
