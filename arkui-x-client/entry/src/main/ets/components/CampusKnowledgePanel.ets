import { KnowledgeSearch, KnowledgeHit } from '../model/ApiModels';
import { CampusFlowApi } from '../services/CampusFlowApi';
import { validKnowledgeSearch, validKnowledgeHit, knowledgeEvidence } from '../utils/KnowledgePresentation';
import { AppTheme } from '../theme/AppTheme';
import { ThemePalette, themePalette } from '../theme/ThemePalette';
import { FeedbackPanel } from './FeedbackPanel';
import { EvidencePanel } from './EvidencePanel';

@Component
export struct CampusKnowledgePanel {
  @StorageLink('campusflowThemePalette') private palette: ThemePalette = themePalette('paper-green');
  @Watch('scopeChanged') @Prop baseUrl: string;
  @Watch('scopeChanged') @Prop token: string;
  @Watch('scopeChanged') @Prop campusScope: string;
  @Watch('activityChanged') @Prop active: boolean = true;
  @State private query: string = '';
  @State private pendingExample: string = '';
  @State private result: KnowledgeSearch | null = null;
  @State private source: KnowledgeHit | null = null;
  @State private loading: boolean = false;
  @State private sourceLoading: string = '';
  @State private message: string = '';
  @State private sourceMessage: string = '';
  private alive: boolean = false;
  private revision: number = 0;
  private sourceRevision: number = 0;

  aboutToAppear(): void { this.alive = true; }
  aboutToDisappear(): void { this.alive = false; this.invalidate(); }
  private invalidate(): void { this.revision++; this.sourceRevision++; this.loading = false; this.sourceLoading = ''; }
  private activityChanged(): void { if (!this.active) { this.invalidate(); } }
  private scopeChanged(): void { this.invalidate(); this.query = ''; this.pendingExample = ''; this.result = null; this.source = null; this.message = ''; this.sourceMessage = ''; }
  private current(revision: number, base: string, token: string, scope: string): boolean {
    return this.alive && this.active && revision === this.revision && base === this.baseUrl && token === this.token && scope === this.campusScope;
  }
  private chooseExample(value: string): void {
    if (!this.alive || !this.active || this.loading) { return; }
    if (this.query.trim().length > 0 && this.query !== value) { this.pendingExample = value; return; }
    this.query = value; this.pendingExample = '';
  }
  private applyExample(): void {
    if (!this.alive || !this.active || this.loading || this.pendingExample.length === 0) { return; }
    this.query = this.pendingExample; this.pendingExample = '';
  }
  private async search(): Promise<void> {
    if (!this.alive || !this.active || this.loading) { return; }
    const query = this.query.trim();
    if (Array.from(query).length === 0 || Array.from(query).length > 200) { this.message = '请输入 1–200 字的具体问题，原输入仍保留。'; return; }
    const revision = ++this.revision; const base = this.baseUrl; const token = this.token; const scope = this.campusScope;
    this.sourceRevision++; this.source = null; this.sourceLoading = ''; this.sourceMessage = '';
    this.loading = true; this.message = ''; this.result = null;
    try {
      const result = await new CampusFlowApi(base, token).searchKnowledge(query);
      if (!this.current(revision, base, token, scope)) { return; }
      if (!validKnowledgeSearch(result, query)) { throw new Error('INVALID_KNOWLEDGE'); }
      this.result = result;
    } catch {
      if (this.current(revision, base, token, scope)) { this.message = '资料查询未完成，请检查连接后重试。此状态不能当作没有相关资料。'; }
    } finally { if (this.current(revision, base, token, scope)) { this.loading = false; } }
  }
  private async openSource(id: string): Promise<void> {
    if (!this.alive || !this.active || this.loading || this.result === null || !this.result.hits.some((hit: KnowledgeHit) => hit.source_id === id)) { return; }
    const revision = this.revision; const detail = ++this.sourceRevision;
    const base = this.baseUrl; const token = this.token; const scope = this.campusScope;
    this.sourceLoading = id; this.sourceMessage = ''; this.source = null;
    try {
      const hit = await new CampusFlowApi(base, token).knowledgeSource(id);
      if (!this.current(revision, base, token, scope) || detail !== this.sourceRevision) { return; }
      if (!validKnowledgeHit(hit) || hit.source_id !== id) { throw new Error('INVALID_SOURCE'); }
      this.source = hit;
    } catch {
      if (this.current(revision, base, token, scope) && detail === this.sourceRevision) {
        this.sourceMessage = '已收录的出处暂未读取，请重新查询或查看原文；不据此补写答案。';
      }
    } finally { if (this.current(revision, base, token, scope) && detail === this.sourceRevision) { this.sourceLoading = ''; } }
  }
  private closeSource(): void { this.sourceRevision++; this.source = null; this.sourceLoading = ''; this.sourceMessage = ''; }
  @Builder
  private SourceDetail(hit: KnowledgeHit) {
    Column({ space: 8 }) {
      Text(`${hit.title} · ${hit.section}`).fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium).fontColor(this.palette.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
      Text(`适用范围：${hit.school} · ${hit.campus}`).fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
      Text(`整理核对日期：${hit.reviewed_at}`).fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
      Text('原文发布日期：资料未提供；这份参考资料不代表实时状态。').fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
      Text('原文摘录').fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
      Text(hit.excerpt).fontSize(this.palette.bodySize).fontColor(this.palette.ink).width('100%').copyOption(CopyOptions.LocalDevice)
      Text(hit.summary).fontSize(this.palette.bodySize).fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
      Text(`原文链接（可长按复制）\n${hit.url}`).fontSize(this.palette.metaSize).fontColor(this.palette.accent)
        .width('100%').wordBreak(WordBreak.BREAK_WORD).copyOption(CopyOptions.LocalDevice)
      EvidencePanel({ evidence: knowledgeEvidence(hit), active: this.active })
      Button('收起出处').constraintSize({ minHeight: 48 }).fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft).onClick(() => this.closeSource())
    }.width('100%').alignItems(HorizontalAlign.Start).padding(12).backgroundColor(this.palette.field).borderRadius(12)
  }
  build() {
    Column({ space: 12 }) {
      Text('校园资料 · 有出处再回答').fontSize(this.palette.sectionTitle).fontWeight(FontWeight.Bold).fontColor(this.palette.ink).width('100%')
      Text('查阅精选官方办事与使用指南，不查询实时开放、座位、考试或个人数据；无需模型密钥。')
        .fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
      ForEach(['校外怎么访问图书馆数据库', '校园网络资源使用说明', '如何申请信息公开', '杭电文库如何征集'], (example: string) => {
        Button(example).width('100%').constraintSize({ minHeight: 48 }).fontSize(this.palette.metaSize).fontColor(this.palette.accent)
          .backgroundColor(this.palette.accentSoft).enabled(!this.loading && this.active).onClick(() => this.chooseExample(example))
      }, (example: string) => example)
      if (this.pendingExample.length > 0) {
        Text('输入框已有问题，是否改用所选示例？').fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
        Button('保留原问题').constraintSize({ minHeight: 48 }).onClick(() => this.pendingExample = '')
        Button('使用所选示例').constraintSize({ minHeight: 48 }).onClick(() => this.applyExample())
      }
      TextInput({ text: this.query, placeholder: '例如：校外怎么访问图书馆数据库' }).height(48).fontSize(this.palette.bodySize)
        .backgroundColor(this.palette.field).borderRadius(this.palette.controlRadius).onChange((text: string) => this.query = text)
        .accessibilityText('输入校园资料问题，最多200字')
      Button(this.loading ? '查询中…' : '查询官方资料').width('100%').constraintSize({ minHeight: 48 })
        .fontSize(this.palette.bodySize).fontColor(this.palette.onAccent).backgroundColor(this.palette.accent)
        .enabled(!this.loading && this.active).onClick(() => this.search())
      if (this.message.length > 0) { FeedbackPanel({ kind: 'warning', title: '本次资料查询', message: this.message }) }
      if (this.result !== null) {
        Text(`查询：${this.result.query}`).fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
        if (this.result.status !== 'found') {
          FeedbackPanel({ kind: 'empty', title: this.result.status === 'unsupported' ? '当前校区尚未收录' : '没有可靠命中', message: this.result.message })
        } else {
          Text(this.result.message).fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
          ForEach(this.result.hits, (hit: KnowledgeHit) => {
            Column({ space: 8 }) {
              Text(hit.title).fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium).fontColor(this.palette.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
              Text(hit.section).fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
              Text(hit.summary).fontSize(this.palette.bodySize).fontColor(this.palette.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
              Text(`资料整理核对：${hit.reviewed_at}；不代表现行有效期。`).fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
              Button(this.sourceLoading === hit.source_id ? '读取中…' : '查看摘录与出处').constraintSize({ minHeight: 48 })
                .fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft).enabled(this.sourceLoading !== hit.source_id)
                .onClick(() => this.openSource(hit.source_id))
            }.width('100%').alignItems(HorizontalAlign.Start).padding(12).backgroundColor(this.palette.field).borderRadius(12)
          }, (hit: KnowledgeHit) => hit.source_id)
          EvidencePanel({ evidence: this.result.evidence, active: this.active })
        }
      }
      if (this.sourceMessage.length > 0) { FeedbackPanel({ kind: 'warning', title: '出处暂未读取', message: this.sourceMessage }) }
      if (this.source !== null) { this.SourceDetail(this.source) }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(this.palette.cardInset).backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
  }
}
