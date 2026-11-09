import { CampusDataStatus } from '../model/ApiModels';
import { ThemePalette, themePalette } from '../theme/ThemePalette';
import { campusStatusLabel, currentCampusStatus } from '../utils/CampusDataPresentation';
import { evidenceTime } from '../utils/EvidencePresentation';

@Component
export struct CampusDataStatusView {
  @StorageLink('campusflowThemePalette') private palette: ThemePalette = themePalette('paper-green');
  @Prop status: CampusDataStatus;
  @Prop busy: boolean = false;
  @Prop actionEnabled: boolean = true;
  @Prop resourceName: string = '';
  onRetry: () => void = () => {};
  onConnect: () => void = () => {};

  private actionLabel(): string {
    if (this.status.action === 'connect') { return '校园数据连接'; }
    return this.status.issue !== null || this.status.state === 'unavailable' ? '重试' : '刷新';
  }

  private displayStatus(): CampusDataStatus { return currentCampusStatus(this.status); }

  build() {
    Column({ space: 3 }) {
      Row({ space: 6 }) {
        Text(campusStatusLabel(this.displayStatus())).fontSize(this.palette.metaSize).fontWeight(FontWeight.Medium)
          .fontColor(this.displayStatus().state === 'live' ? this.palette.success :
            (this.status.issue !== null || this.displayStatus().state === 'stale' ? this.palette.warning : this.palette.secondary))
          .layoutWeight(1)
        if (this.status.action !== 'none') {
          Button(this.busy ? '更新中…' : this.actionLabel()).constraintSize({ minHeight: 44 })
            .fontSize(this.palette.metaSize).fontColor(this.palette.accent).backgroundColor(Color.Transparent)
            .padding({ left: 8, right: 0 }).enabled(this.actionEnabled && !this.busy)
            .accessibilityText(`${this.resourceName}${this.busy ? '更新中' : this.actionLabel()}`)
            .onClick(() => {
              if (this.status.action === 'connect') { this.onConnect(); }
              else { this.onRetry(); }
            })
        }
      }.width('100%')
      if (this.status.updated_at !== null || this.status.state !== 'unavailable') {
        Text(`数据更新于 ${evidenceTime(this.status.updated_at)}`).fontSize(this.palette.metaSize)
          .fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
      }
      if (this.displayStatus().message.length > 0) {
        Text(this.displayStatus().message).fontSize(this.palette.metaSize).fontColor(this.palette.secondary)
          .width('100%').wordBreak(WordBreak.BREAK_WORD)
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
