import { SkillSummary } from '../model/ApiModels';
import { CampusFlowApi } from '../services/CampusFlowApi';

@Component
export struct SkillsPage {
  @Prop baseUrl: string;
  @Prop token: string;
  @State private skills: SkillSummary[] = [];
  @State private message: string = '';

  aboutToAppear(): void {
    this.reload();
  }

  private async reload(): Promise<void> {
    try {
      this.skills = await new CampusFlowApi(this.baseUrl, this.token).skills();
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

  build() {
    Scroll() {
      Column({ space: 18 }) {
        Column({ space: 5 }) {
          Text('Skills').fontSize(28).fontWeight(FontWeight.Bold).fontColor('#171A22')
          Text('从官方能力库扩展你的校园 Agent').fontSize(13).fontColor('#777E8F')
        }.width('100%').alignItems(HorizontalAlign.Start)

        if (this.message.length > 0) {
          Text(this.message).fontSize(12).fontColor('#315BFF').width('100%')
            .padding(12).backgroundColor('#E9EEFF').borderRadius(13)
        }

        ForEach(this.skills, (skill: SkillSummary) => {
          Column({ space: 13 }) {
            Row() {
              Text(skill.name.slice(0, 1)).fontSize(20).fontWeight(FontWeight.Bold).fontColor('#315BFF')
                .width(44).height(44).textAlign(TextAlign.Center).backgroundColor('#E9EEFF').borderRadius(14)
              Column({ space: 3 }) {
                Row({ space: 6 }) {
                  Text(skill.name).fontSize(16).fontWeight(FontWeight.Bold).fontColor('#171A22')
                  if (skill.official) {
                    Text('官方').fontSize(10).fontColor('#FFFFFF').backgroundColor('#315BFF')
                      .padding({ left: 6, right: 6, top: 3, bottom: 3 }).borderRadius(8)
                  }
                }
                Text(`${skill.category} · v${skill.version}`).fontSize(11).fontColor('#8A90A0')
              }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 12 })
            }.width('100%')
            Text(skill.description).fontSize(13).fontColor('#646B7A').lineHeight(20).width('100%')
            Text(`权限：${skill.permissions.map((item) => item.label).join('、') || '无需额外权限'}`)
              .fontSize(11).fontColor('#8A90A0').width('100%')
            if (!skill.installed) {
              Button('查看权限并安装').height(42).fontColor('#FFFFFF').backgroundColor('#315BFF')
                .borderRadius(13).onClick(() => this.install(skill))
            } else {
              Row() {
                Text(skill.enabled ? '已启用' : '已停用').fontSize(12)
                  .fontColor(skill.enabled ? '#19966B' : '#8A90A0')
                Blank()
                Toggle({ type: ToggleType.Switch, isOn: skill.enabled }).onChange(() => this.toggle(skill))
              }.width('100%')
            }
          }.width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(22)
        }, (skill: SkillSummary) => skill.skill_id)
      }.width('100%').padding({ left: 18, right: 18, top: 18, bottom: 110 })
    }.width('100%').height('100%').backgroundColor('#F5F7FB')
  }
}
