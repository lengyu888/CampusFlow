import { DataEvidence } from '../model/ApiModels';
import { normalizeEvidence, evidenceStatus, evidenceStatusLabel, evidenceKindLabel, evidenceSummary, evidenceTime } from '../utils/EvidencePresentation';
import { AppTheme } from '../theme/AppTheme';

@Component
export struct EvidencePanel {
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
        Text(`${evidenceSummary(this.evidence, this.now)} · ${this.expanded ? '收起' : '核对来源'}`)
          .fontSize(AppTheme.metaSize).fontColor(AppTheme.actionBlue).width('100%')
          .textAlign(TextAlign.Start).wordBreak(WordBreak.BREAK_WORD)
      }.width('100%').constraintSize({ minHeight: 48 }).padding({ left: 10, right: 10 })
        .backgroundColor(AppTheme.blueSoft).borderRadius(12).onClick(() => this.toggle())
      if (this.expanded) {
        ForEach(this.sources(), (item: DataEvidence) => {
          Column({ space: 6 }) {
            Text(`${item.label} · ${evidenceStatusLabel(evidenceStatus(item, this.now))}`)
              .fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink)
              .width('100%').wordBreak(WordBreak.BREAK_WORD)
            Text(`${evidenceKindLabel(item.kind)} · ${item.source_id}`).fontSize(AppTheme.metaSize)
              .fontColor(AppTheme.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
            Text(`来源记录时间：${evidenceTime(item.updated_at)}`).fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
            Text(item.expires_at === null ? '未提供自动到期时间，不代表实时有效。' : `缓存使用期限：${evidenceTime(item.expires_at)}`)
              .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
            if (item.note.length > 0) {
              Text(item.note).fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
            }
            if (item.url !== null) {
              Text(item.url as string).fontSize(AppTheme.metaSize).fontColor(AppTheme.actionBlue).width('100%')
                .wordBreak(WordBreak.BREAK_WORD).copyOption(CopyOptions.LocalDevice)
            }
          }.width('100%').alignItems(HorizontalAlign.Start).padding(12)
            .backgroundColor(AppTheme.field).borderRadius(12)
        }, (item: DataEvidence, index: number) => `${item.source_id}-${index}-${this.sourceRevision}`)
        Text('时间按上海时区展示；记录有效或缓存未到期，不等于现实情况一定未变。公开链接可长按复制。')
          .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
