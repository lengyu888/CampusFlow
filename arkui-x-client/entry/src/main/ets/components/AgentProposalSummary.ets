import { PendingAction, DataEvidence } from '../model/ApiModels';
import { proposalOverview } from '../utils/ConversationPresentation';
import { EvidencePanel } from './EvidencePanel';
import { AppTheme } from '../theme/AppTheme';
import { ThemePalette, themePalette } from '../theme/ThemePalette';

@Component
export struct AgentProposalSummary {
  @StorageLink('campusflowThemePalette') private palette: ThemePalette = themePalette('paper-green');
  @Prop action: PendingAction;
  @Prop evidence: DataEvidence[] = [];
  @Prop active: boolean = true;
  @State private evidenceExpanded: boolean = false;

  build() {
    Column({ space: 8 }) {
      Text(`${this.action.action === 'create' ? '本次安排' : '涉及现有内容'} · ${proposalOverview(this.action).taskCount} 项任务` +
        (this.action.kind === 'plan' ? ` · ${proposalOverview(this.action).milestoneCount} 个阶段` : ''))
        .fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium).fontColor(this.palette.ink).width('100%')
      Text(proposalOverview(this.action).timeRange).fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
        .wordBreak(WordBreak.BREAK_WORD)
      if (proposalOverview(this.action).completeTimeCount > 1) {
        Text('以上为任务时间范围，不代表连续占用整个时段。').fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
      }
      if (proposalOverview(this.action).deadline.length > 0) {
        Text(`截止日期 ${proposalOverview(this.action).deadline}`).fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
      }
      if (proposalOverview(this.action).incompleteTimeCount > 0) {
        Text(`${proposalOverview(this.action).incompleteTimeCount} 项尚无完整起止时间，需要继续核对。`)
          .fontSize(this.palette.bodySize).fontColor(this.palette.warning).width('100%')
      }
      Text(`${proposalOverview(this.action).conflictCount} 项阻断冲突 · ${proposalOverview(this.action).warningCount} 项核对提示`)
        .fontSize(this.palette.metaSize).fontColor(proposalOverview(this.action).conflictCount > 0 ? this.palette.danger : this.palette.secondary).width('100%')
      Button(this.evidenceExpanded ? '收起本轮查询来源' : '查看本轮查询来源').constraintSize({ minHeight: 48 }).width('100%')
        .fontSize(this.palette.bodySize).fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft)
        .borderRadius(this.palette.controlRadius).onClick(() => this.evidenceExpanded = !this.evidenceExpanded)
      if (this.evidenceExpanded) {
        Text('这些是本轮工具返回的来源；不代表每项安排都有完整依据，具体冲突与时段仍需核对。')
          .fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
        EvidencePanel({ evidence: this.evidence, active: this.active })
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(12).backgroundColor(this.palette.canvas).borderRadius(this.palette.controlRadius)
  }
}
