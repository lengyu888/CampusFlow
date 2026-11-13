import { ToolDisplaySummary } from '../model/ApiModels';
import { ThemePalette, themePalette } from '../theme/ThemePalette';
import { EvidencePanel } from './EvidencePanel';

@Component
export struct ReplyToolDetails {
  @StorageLink('campusflowThemePalette') private palette: ThemePalette = themePalette('paper-green');
  @Prop tools: ToolDisplaySummary[] = [];
  @Prop active: boolean = true;

  private stateLabel(state: string): string {
    switch (state) {
      case 'running': return '读取中';
      case 'success': return '已返回';
      case 'empty': return '暂无数据';
      case 'error': return '调用失败';
      case 'unavailable': return '暂不可用';
      case 'pending': return '待确认';
      case 'demo': return '演示数据';
      default: return '未核验';
    }
  }

  private stateColor(state: string): string {
    if (state === 'error') { return this.palette.danger; }
    if (['unavailable', 'unverified', 'demo'].includes(state)) { return this.palette.warning; }
    return this.palette.secondary;
  }

  build() {
    Column({ space: 12 }) {
      ForEach(this.tools, (item: ToolDisplaySummary) => {
        Column({ space: 7 }) {
          Row({ space: 8 }) {
            Text(item.label).fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium).fontColor(this.palette.ink)
              .layoutWeight(1).wordBreak(WordBreak.BREAK_WORD)
            Text(this.stateLabel(item.state)).fontSize(this.palette.metaSize).fontColor(this.stateColor(item.state))
          }.width('100%')
          if (item.summary.length > 0) {
            Text(item.summary).fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
              .wordBreak(WordBreak.BREAK_WORD)
          }
          if ((item.evidence?.length ?? 0) > 0) {
            EvidencePanel({ evidence: item.evidence ?? [], active: this.active, initiallyExpanded: true })
          }
        }.width('100%').alignItems(HorizontalAlign.Start).padding(this.palette.cardInset)
          .backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
      }, (item: ToolDisplaySummary, index: number) => `${index}-${JSON.stringify(item)}`)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
