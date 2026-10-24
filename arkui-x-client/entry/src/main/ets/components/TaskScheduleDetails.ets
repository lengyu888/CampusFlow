import { AppTheme } from '../theme/AppTheme';
import { ThemePalette, themePalette } from '../theme/ThemePalette';
import { formatPlanReminder, formatPlanTimeRange } from '../utils/PlanPresentation';

// Shared by pending proposals and saved plans; these labels describe saved settings.
@Component
export struct TaskScheduleDetails {
  @StorageLink('campusflowThemePalette') private palette: ThemePalette = themePalette('paper-green');
  @Prop startAt: string | null = null;
  @Prop endAt: string | null = null;
  @Prop location: string | null = null;
  @Prop reminderMinutes: number | null = null;

  build() {
    Column({ space: 4 }) {
      Text(`时间：${formatPlanTimeRange(this.startAt, this.endAt)}`)
        .fontSize(13).fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
      Text(`地点：${this.location === null || this.location.trim().length === 0 ? '未设置' : this.location}`)
        .fontSize(13).fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
      Text(`提醒设置：${formatPlanReminder(this.reminderMinutes)}`)
        .fontSize(13).fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
