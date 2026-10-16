import { SkillSummary } from '../model/ApiModels';
import { CampusFlowApi } from '../services/CampusFlowApi';
import { AppTheme } from '../theme/AppTheme';
import { AppIcon } from '../components/AppIcon';

@Component
export struct SkillsPage {
  @Prop baseUrl: string;
  @Prop token: string;
  @State private skills: SkillSummary[] = [];
  @State private message: string = '';
  @State private installedOnly: boolean = false;

  aboutToAppear(): void {
    this.reload();
  }

  private async reload(): Promise<void> {
    try {
      const skills = await new CampusFlowApi(this.baseUrl, this.token).skills();
      this.getUIContext().animateTo({ duration: AppTheme.motion(180), curve: Curve.EaseOut }, () => {
        this.skills = skills;
      });
    } catch (error) {
      this.message = `Skills 加载失败：${error}`;
    }
  }

  private async install(skill: SkillSummary): Promise<void> {
    try {
      await new CampusFlowApi(this.baseUrl, this.token).installSkill(skill);
      this.message = `${skill.name} 已安装，并记录权限授权。`;
      await this.reload();
    } catch (error) {
      this.message = `安装失败：${error}`;
    }
  }

  private async toggle(skill: SkillSummary): Promise<void> {
    try {
      await new CampusFlowApi(this.baseUrl, this.token).setSkillEnabled(skill.skill_id, !skill.enabled);
      await this.reload();
    } catch (error) {
      this.message = `状态更新失败：${error}`;
    }
  }

  private visibleSkills(): SkillSummary[] {
    return this.installedOnly ? this.skills.filter((skill: SkillSummary) => skill.installed) : this.skills;
  }

  private installedCount(): number {
    return this.skills.filter((skill: SkillSummary) => skill.installed).length;
  }

  private selectFilter(installedOnly: boolean): void {
    this.getUIContext().animateTo({ duration: AppTheme.motion(180), curve: Curve.EaseOut }, () => {
      this.installedOnly = installedOnly;
    });
  }

  build() {
    Scroll() {
      Column({ space: 24 }) {
        Column({ space: 7 }) {
          Text('Skills').fontSize(32).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
          Text('为校园生活，添一份新能力').fontSize(14).fontColor(AppTheme.secondary)
        }.width('100%').alignItems(HorizontalAlign.Start)

        Row({ space: 16 }) {
          AppIcon({ name: 'skills', iconSize: 30, color: AppTheme.blue })
          Column({ space: 7 }) {
            Text('你的 Agent，按需扩展').fontSize(18).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
            Text('安装前查看权限，随时启用或停用。').fontSize(14).fontColor(AppTheme.secondary).lineHeight(21)
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        }.width('100%').padding(20).backgroundColor(AppTheme.surface).borderRadius(22)

        Row({ space: 4 }) {
          Button(`全部 ${this.skills.length}`).height(44).layoutWeight(1).fontSize(14)
            .fontWeight(!this.installedOnly ? FontWeight.Medium : FontWeight.Regular)
            .fontColor(!this.installedOnly ? AppTheme.ink : AppTheme.secondary)
            .backgroundColor(!this.installedOnly ? AppTheme.surface : Color.Transparent)
            .borderRadius(11).onClick(() => this.selectFilter(false))
          Button(`已安装 ${this.installedCount()}`).height(44).layoutWeight(1).fontSize(14)
            .fontWeight(this.installedOnly ? FontWeight.Medium : FontWeight.Regular)
            .fontColor(this.installedOnly ? AppTheme.ink : AppTheme.secondary)
            .backgroundColor(this.installedOnly ? AppTheme.surface : Color.Transparent)
            .borderRadius(11).onClick(() => this.selectFilter(true))
        }.width('100%').padding(4).backgroundColor('#E5E5EA').borderRadius(14)

        if (this.message.length > 0) {
          Text(this.message).fontSize(14).fontColor(AppTheme.blue).width('100%').lineHeight(21)
            .padding(14).backgroundColor(AppTheme.blueSoft).borderRadius(14)
        }

        if (this.visibleSkills().length === 0 && this.installedOnly) {
          Column({ space: 12 }) {
            AppIcon({ name: 'skills', iconSize: 36, color: AppTheme.muted })
            Text('还没有安装的能力').fontSize(17).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink)
            Text('浏览全部 Skills，找到适合你的校园助手。')
              .fontSize(14).fontColor(AppTheme.secondary).textAlign(TextAlign.Center).lineHeight(21)
            Button('浏览全部').height(44).fontSize(14).fontColor(AppTheme.blue)
              .backgroundColor(AppTheme.blueSoft).borderRadius(12).onClick(() => this.selectFilter(false))
          }.width('100%').padding(28).backgroundColor(AppTheme.surface).borderRadius(22)
        }

        ForEach(this.visibleSkills(), (skill: SkillSummary) => {
          Column({ space: 16 }) {
            Row({ space: 14 }) {
              Stack() {
                AppIcon({ name: 'skills', iconSize: 25, color: AppTheme.blue })
              }.width(50).height(50).backgroundColor(AppTheme.blueSoft).borderRadius(14)
              Column({ space: 6 }) {
                Text(skill.name).fontSize(18).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
                Text(`${skill.category} · 版本 ${skill.version}`).fontSize(12).fontColor(AppTheme.secondary)
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              if (skill.official) {
                Text('官方').fontSize(11).fontWeight(FontWeight.Medium).fontColor(AppTheme.blue)
                  .padding({ left: 8, right: 8, top: 5, bottom: 5 }).backgroundColor(AppTheme.blueSoft).borderRadius(7)
              }
            }.width('100%')
            Text(skill.description).fontSize(15).fontColor(AppTheme.secondary).lineHeight(23).width('100%')
            Divider().color(AppTheme.separator)
            Column({ space: 6 }) {
              Text('使用权限').fontSize(12).fontColor(AppTheme.muted)
              Text(skill.permissions.map((item) => item.label).join('、') || '无需额外权限')
                .fontSize(13).fontColor(AppTheme.secondary).lineHeight(20)
            }.width('100%').alignItems(HorizontalAlign.Start)
            if (!skill.installed) {
              Button('同意以上权限并安装').width('100%').height(46).fontSize(14).fontWeight(FontWeight.Medium)
                .fontColor(AppTheme.blue).backgroundColor(AppTheme.blueSoft)
                .borderRadius(12).onClick(() => this.install(skill))
            } else {
              Row() {
                Row({ space: 7 }) {
                  Circle().width(6).height(6).fill(skill.enabled ? AppTheme.green : AppTheme.muted)
                  Text(skill.enabled ? '已启用' : '已停用').fontSize(14)
                    .fontColor(skill.enabled ? AppTheme.green : AppTheme.secondary)
                }
                Blank()
                Toggle({ type: ToggleType.Switch, isOn: skill.enabled }).selectedColor(AppTheme.green)
                  .accessibilityText(`${skill.enabled ? '停用' : '启用'}${skill.name}`)
                  .onChange(() => this.toggle(skill))
              }.width('100%').height(44)
            }
          }.width('100%').padding(20).backgroundColor(AppTheme.surface).borderRadius(22)
        }, (skill: SkillSummary) =>
          `${skill.skill_id}-${skill.installed}-${skill.enabled}-${skill.installed_version ?? 'none'}`)
      }.width('100%').padding({ left: 20, right: 20, top: 20, bottom: 32 })
    }.width('100%').height('100%').backgroundColor(AppTheme.bg)
  }
}
