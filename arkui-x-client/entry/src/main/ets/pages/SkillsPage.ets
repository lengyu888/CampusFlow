import { SkillSummary, SkillPermission } from '../model/ApiModels';
import { CampusFlowApi } from '../services/CampusFlowApi';
import { AppTheme } from '../theme/AppTheme';
import { AppIcon } from '../components/AppIcon';
import { FeedbackPanel } from '../components/FeedbackPanel';
import { CampusFlowRequestError } from '../utils/AgentFeedback';

@Component
export struct SkillsPage {
  @Prop baseUrl: string;
  @Prop token: string;
  @Prop @Watch('activeChanged') active: boolean = true;
  @State private skills: SkillSummary[] = [];
  @State private message: string = '';
  @State private errorText: string = '';
  @State private loading: boolean = false;
  @State private loaded: boolean = false;
  @State private busyId: string = '';
  @State private installedOnly: boolean = false;
  @State private expandedIds: string[] = [];
  private pageActive: boolean = true;
  private requestRevision: number = 0;

  aboutToAppear(): void { this.pageActive = true; if (this.active) { this.reload(); } }
  aboutToDisappear(): void { this.pageActive = false; this.requestRevision++; }
  private activeChanged(): void {
    this.requestRevision++;
    this.loading = false;
    if (this.active && this.pageActive) { this.reload(); }
  }
  private current(revision: number): boolean {
    return this.pageActive && this.active && revision === this.requestRevision;
  }
  private failure(error: Error): string {
    if (error instanceof CampusFlowRequestError && (error.statusCode === 401 || error.statusCode === 403)) {
      return '登录或权限已失效，请返回个人设置重新登录。';
    }
    return '暂时无法核对能力状态，原状态已保留。请刷新后再操作。';
  }
  private async reload(): Promise<void> {
    if (!this.active || !this.pageActive || this.loading || this.busyId.length > 0) { return; }
    const revision = ++this.requestRevision;
    this.loading = true;
    this.errorText = '';
    this.message = '';
    try {
      const skills = await new CampusFlowApi(this.baseUrl, this.token).skills();
      if (!this.current(revision)) { return; }
      this.skills = skills;
      this.loaded = true;
    } catch (error) {
      if (this.current(revision)) { this.errorText = this.failure(error); }
    } finally {
      if (this.current(revision)) { this.loading = false; }
    }
  }
  private async install(skill: SkillSummary): Promise<void> { await this.changeSkill(skill, true); }
  private async toggle(skill: SkillSummary): Promise<void> { await this.changeSkill(skill, false); }
  private async changeSkill(skill: SkillSummary, install: boolean): Promise<void> {
    const current = this.skills.find((item: SkillSummary) => item.skill_id === skill.skill_id);
    if (!this.pageActive || !this.active || this.loading || this.busyId.length > 0 || this.errorText.length > 0 ||
      current === undefined || install && current.installed || !install && !current.installed ||
      (install || !current.enabled) && !this.expandedIds.includes(current.skill_id)) { return; }
    const revision = ++this.requestRevision;
    this.busyId = current.skill_id;
    this.message = '';
    this.errorText = '';
    try {
      const api = new CampusFlowApi(this.baseUrl, this.token);
      const result = install ? await api.installSkill(current) : await api.setSkillEnabled(current.skill_id, !current.enabled);
      if (!this.current(revision)) { return; }
      if (result.skill_id !== current.skill_id || !result.installed || !install && result.enabled === current.enabled) {
        this.errorText = '服务返回的能力状态与操作不一致，请刷新核对后再操作。';
        return;
      }
      this.skills = this.skills.map((item: SkillSummary) => item.skill_id === result.skill_id ? result : item);
      this.message = `${result.name} · ${install ? '已安装' : result.enabled ? '已启用' : '已停用'}。`;
    } catch (error) {
      if (this.current(revision)) { this.errorText = this.failure(error); }
    } finally {
      if (this.pageActive) {
        this.busyId = '';
        if (!this.current(revision) && this.active) { this.reload(); }
      }
    }
  }
  private visibleSkills(): SkillSummary[] { return this.installedOnly ? this.skills.filter((skill: SkillSummary) => skill.installed) : this.skills; }
  private installedCount(): number { return this.skills.filter((skill: SkillSummary) => skill.installed).length; }
  private selectFilter(installedOnly: boolean): void { this.installedOnly = installedOnly; }
  private toggleDetails(id: string): void {
    this.expandedIds = this.expandedIds.includes(id) ? this.expandedIds.filter((value: string) => value !== id) : this.expandedIds.concat([id]);
  }

  build() {
    Scroll() {
      Column({ space: 24 }) {
        Text('查看用途和权限，再决定是否交给 Agent 使用。')
          .fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet).width('100%')
        Row({ space: 8 }) {
          Button(this.loaded ? `全部 ${this.skills.length}` : '全部').layoutWeight(1).constraintSize({ minHeight: 48 })
            .fontSize(AppTheme.bodySize).fontColor(!this.installedOnly ? '#FFFFFF' : AppTheme.actionBlue)
            .backgroundColor(!this.installedOnly ? AppTheme.actionBlue : AppTheme.blueSoft)
            .borderRadius(AppTheme.controlRadius).onClick(() => this.selectFilter(false))
          Button(this.loaded ? `已安装 ${this.installedCount()}` : '已安装').layoutWeight(1).constraintSize({ minHeight: 48 })
            .fontSize(AppTheme.bodySize).fontColor(this.installedOnly ? '#FFFFFF' : AppTheme.actionBlue)
            .backgroundColor(this.installedOnly ? AppTheme.actionBlue : AppTheme.blueSoft)
            .borderRadius(AppTheme.controlRadius).onClick(() => this.selectFilter(true))
        }.width('100%')
        if (this.loading) {
          FeedbackPanel({ kind: 'loading', title: '正在读取能力', message: '已有内容仍可查看，读取完成后可操作。', busy: true })
        }
        if (this.errorText.length > 0) {
          FeedbackPanel({ kind: 'error', title: '能力状态未更新', message: this.errorText, actionLabel: '刷新核对',
            busy: this.loading || this.busyId.length > 0, onAction: () => this.reload() })
        } else if (this.message.length > 0) {
          FeedbackPanel({ kind: 'success', title: '操作已完成', message: this.message })
        }
        if (this.loaded && !this.loading && this.errorText.length === 0 && this.visibleSkills().length === 0) {
          FeedbackPanel({ kind: 'info', title: this.installedOnly ? '还没有安装的能力' : '暂无可用能力',
            message: this.installedOnly ? '可先浏览全部能力，查看权限后安装。' : '服务暂未提供能力列表，可稍后刷新。',
            actionLabel: this.installedOnly ? '浏览全部' : '刷新',
            onAction: () => { if (this.installedOnly) { this.selectFilter(false); } else { this.reload(); } } })
        }
        ForEach(this.visibleSkills(), (skill: SkillSummary) => {
          Column({ space: 12 }) {
            Row({ space: 12 }) {
              AppIcon({ name: 'skills', iconSize: 24, color: AppTheme.actionBlue })
              Text(skill.name).fontSize(AppTheme.sectionTitle).fontWeight(FontWeight.Medium)
                .fontColor(AppTheme.ink).layoutWeight(1).wordBreak(WordBreak.BREAK_WORD)
            }.width('100%')
            Text(`${skill.official ? '官方 · ' : ''}${skill.category} · ${!skill.installed ? '未安装' : skill.enabled ? '已启用' : '已停用'}`)
              .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
            Text(skill.description).fontSize(AppTheme.bodySize).fontColor(AppTheme.ink).width('100%')
            Button(this.expandedIds.includes(skill.skill_id) ? '收起权限与版本' : `查看 ${skill.permissions.length} 项权限与版本`)
              .width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
              .fontColor(AppTheme.actionBlue).backgroundColor(AppTheme.blueSoft).borderRadius(AppTheme.controlRadius)
              .onClick(() => this.toggleDetails(skill.skill_id))
            if (this.expandedIds.includes(skill.skill_id)) {
              Text(`版本 ${skill.version} · ${skill.author}${skill.update_available ? ' · 有可用更新' : ''}`)
                .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
              if (skill.permissions.length === 0) {
                Text('无需额外权限').fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet).width('100%')
              }
              ForEach(skill.permissions, (permission: SkillPermission) => {
                Column({ space: 4 }) {
                  Text(permission.label).fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink).width('100%')
                  Text(`${permission.access} · ${permission.description}`).fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
                }.width('100%').alignItems(HorizontalAlign.Start)
              }, (permission: SkillPermission) => permission.code)
              Button(this.busyId === skill.skill_id ? '正在提交…' : !skill.installed ? '同意以上权限并安装' : skill.enabled ? '停用此能力' : '启用以上权限')
                .width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
                .fontColor('#FFFFFF').backgroundColor(AppTheme.actionBlue).borderRadius(AppTheme.controlRadius)
                .enabled(!this.loading && this.busyId.length === 0 && this.errorText.length === 0)
                .onClick(() => { if (skill.installed) { this.toggle(skill); } else { this.install(skill); } })
            } else if (skill.installed && skill.enabled) {
              Button('停用此能力').width('100%').constraintSize({ minHeight: 48 }).fontSize(AppTheme.bodySize)
                .fontColor(AppTheme.quiet).backgroundColor(AppTheme.field).borderRadius(AppTheme.controlRadius)
                .enabled(!this.loading && this.busyId.length === 0 && this.errorText.length === 0)
                .onClick(() => this.toggle(skill))
            }
          }.width('100%').padding(AppTheme.cardInset).alignItems(HorizontalAlign.Start)
            .backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
        }, (skill: SkillSummary) => `${skill.skill_id}-${skill.installed}-${skill.enabled}`)
      }.width('100%').padding({ left: AppTheme.pageInset, right: AppTheme.pageInset, top: 16, bottom: 24 })
    }.width('100%').height('100%').backgroundColor(AppTheme.canvas)
  }
}
