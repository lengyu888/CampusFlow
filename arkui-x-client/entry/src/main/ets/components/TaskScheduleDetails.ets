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

  @Builder
  private DetailRow(label: string, value: string) {
    Row({ space: 12 }) {
      Text(label).fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width(42)
      Text(value).fontSize(this.palette.bodySize).fontColor(this.palette.ink).layoutWeight(1).wordBreak(WordBreak.BREAK_WORD)
    }.width('100%').alignItems(VerticalAlign.Top).padding({ top: 7, bottom: 7 })
  }

  build() {
    Column() {
      this.DetailRow('时间', formatPlanTimeRange(this.startAt, this.endAt))
      Divider().color(this.palette.line).strokeWidth(0.5).margin({ left: 54 })
      this.DetailRow('地点', this.location === null || this.location.trim().length === 0 ? '未设置' : this.location)
      Divider().color(this.palette.line).strokeWidth(0.5).margin({ left: 54 })
      this.DetailRow('提醒', formatPlanReminder(this.reminderMinutes))
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
