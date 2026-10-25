import { DataEvidence } from '../model/ApiModels';
import { normalizeEvidence, evidenceStatus, evidenceStatusLabel, evidenceKindLabel, evidenceSummary, evidenceTime } from '../utils/EvidencePresentation';
import { AppTheme } from '../theme/AppTheme';
import { ThemePalette, themePalette } from '../theme/ThemePalette';
import { AppIcon } from './AppIcon';

@Component
export struct EvidencePanel {
  @StorageLink('campusflowThemePalette') private palette: ThemePalette = themePalette('paper-green');
  @Watch('sourcesChanged') @Prop evidence: DataEvidence[] = [];
  @Watch('activeChanged') @Prop active: boolean = true;
  @State private expanded: boolean = false;
  @State private now: number = Date.now();
  @State private sourceRevision: number = 0;
  private timer: number = -1;
  private alive: boolean = false;

  aboutToAppear(): void { this.alive = true; this.activeChanged(); }
  aboutToDisappear(): void { this.alive = false; this.stopClock(); }
  private stopClock(): void { if (this.timer >= 0) { clearInterval(this.timer); this.timer = -1; } }
  private activeChanged(): void {
    this.stopClock();
    this.now = Date.now();
    if (this.active && this.alive) {
      // Expiry remains visible even when the page is left open; no API refresh or fabricated timestamp.
      this.timer = setInterval(() => { if (this.active && this.alive) { this.now = Date.now(); } }, 30000);
    }
  }
  private sourcesChanged(): void { this.now = Date.now(); this.sourceRevision++; }
  private sources(): DataEvidence[] { return normalizeEvidence(this.evidence); }
  private toggle(): void { this.now = Date.now(); this.expanded = !this.expanded; }

  build() {
    Column({ space: 8 }) {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 8 }) {
          Text('数据来源').fontSize(this.palette.metaSize).fontColor(this.palette.secondary)
          Text(evidenceSummary(this.evidence, this.now)).fontSize(this.palette.metaSize)
            .fontColor(this.palette.quiet).layoutWeight(1).textAlign(TextAlign.End)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          AppIcon({ name: 'chevron', iconSize: 14, color: this.palette.quiet })
            .rotate({ angle: this.expanded ? 90 : 0 })
        }.width('100%')
      }.width('100%').constraintSize({ minHeight: 44 }).padding({ left: 0, right: 0 })
        .backgroundColor(Color.Transparent).borderRadius(8)
        .accessibilityText(`${evidenceSummary(this.evidence, this.now)}，${this.expanded ? '收起来源' : '展开来源'}`)
        .onClick(() => animateTo({ duration: AppTheme.motion(160) }, () => this.toggle()))
      if (this.expanded) {
        ForEach(this.sources(), (item: DataEvidence) => {
          Column({ space: 6 }) {
            Text(`${item.label} · ${evidenceStatusLabel(evidenceStatus(item, this.now))}`)
              .fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium).fontColor(this.palette.ink)
              .width('100%').wordBreak(WordBreak.BREAK_WORD)
            Text(`${evidenceKindLabel(item.kind)} · ${item.source_id}`).fontSize(this.palette.metaSize)
              .fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
            Text(`来源记录时间：${evidenceTime(item.updated_at)}`).fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
            Text(item.expires_at === null ? '未提供自动到期时间，不代表实时有效。' : `缓存使用期限：${evidenceTime(item.expires_at)}`)
              .fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
            if (item.note.length > 0) {
              Text(item.note).fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
            }
            if (item.url !== null) {
              Text(item.url as string).fontSize(this.palette.metaSize).fontColor(this.palette.accent).width('100%')
                .wordBreak(WordBreak.BREAK_WORD).copyOption(CopyOptions.LocalDevice)
            }
          }.width('100%').alignItems(HorizontalAlign.Start).padding(12)
            .backgroundColor(this.palette.field).borderRadius(12).border({ width: 1, color: this.palette.line })
        }, (item: DataEvidence, index: number) => `${item.source_id}-${index}-${this.sourceRevision}`)
        Text('时间按上海时区展示；记录有效或缓存未到期，不等于现实情况一定未变。公开链接可长按复制。')
          .fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
