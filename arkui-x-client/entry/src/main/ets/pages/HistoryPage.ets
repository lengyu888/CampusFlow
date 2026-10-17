import { HistoryMessage, SessionSummary } from '../model/ApiModels';
import { CampusFlowApi } from '../services/CampusFlowApi';
import { plainMessage } from '../utils/MessageText';
import { MessageContent } from '../components/MessageContent';
import { AppTheme } from '../theme/AppTheme';
import { AppIcon } from '../components/AppIcon';

@Component
export struct HistoryPage {
  @Prop baseUrl: string;
  @Prop token: string;
  onBack: () => void = () => {};
  @State private sessions: SessionSummary[] = [];
  @State private selected: SessionSummary | null = null;
  @State private messages: HistoryMessage[] = [];
  @State private loading: boolean = false;
  @State private errorText: string = '';
  @State private pendingDeleteId: string = '';

  aboutToAppear(): void {
    this.reload();
  }

  private async reload(): Promise<void> {
    this.loading = true;
    this.errorText = '';
    try {
      this.sessions = await new CampusFlowApi(this.baseUrl, this.token).sessions();
    } catch (error) {
      this.errorText = `历史会话加载失败：${error}`;
    } finally {
      this.loading = false;
    }
  }

  private async openSession(session: SessionSummary): Promise<void> {
    this.loading = true;
    this.errorText = '';
    try {
      this.messages = await new CampusFlowApi(this.baseUrl, this.token).history(session.session_id);
      this.selected = session;
    } catch (error) {
      this.errorText = `会话内容加载失败：${error}`;
    } finally {
      this.loading = false;
    }
  }

  private async deleteSession(session: SessionSummary): Promise<void> {
    try {
      await new CampusFlowApi(this.baseUrl, this.token).deleteSession(session.session_id);
      this.sessions = this.sessions.filter((item) => item.session_id !== session.session_id);
      if (this.selected?.session_id === session.session_id) {
        this.selected = null;
        this.messages = [];
      }
      this.pendingDeleteId = '';
    } catch (error) {
      this.errorText = `删除失败：${error}`;
    }
  }

  private goBack(): void {
    if (this.selected !== null) {
      this.getUIContext().animateTo({ duration: AppTheme.motion(180), curve: Curve.EaseOut }, () => {
        this.selected = null;
        this.messages = [];
      });
    } else {
      this.onBack();
    }
  }

  private requestDelete(sessionId: string): void {
    this.getUIContext().animateTo({ duration: AppTheme.motion(180), curve: Curve.EaseOut }, () => {
      this.pendingDeleteId = sessionId;
    });
  }

  build() {
    Column() {
      Row({ space: 4 }) {
        Button({ type: ButtonType.Normal }) {
          AppIcon({ name: 'back', iconSize: 21, color: AppTheme.blue })
        }.width(44).height(44).backgroundColor(Color.Transparent).borderRadius(22)
          .accessibilityText(this.selected === null ? '返回 Agent' : '返回历史会话')
          .onClick(() => this.goBack())
        Text(this.selected === null ? '历史会话' : (this.selected as SessionSummary).title)
          .fontSize(17).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        if (this.selected === null) {
          Button('刷新').height(44).fontSize(14).fontColor(AppTheme.blue)
            .backgroundColor(Color.Transparent).padding({ left: 12, right: 12 })
            .enabled(!this.loading).onClick(() => this.reload())
        } else {
          Blank().width(12)
        }
      }.width('100%').height(56).padding({ left: 7, right: 10 })
        .backgroundColor(AppTheme.bg)

      if (this.errorText.length > 0) {
        Text(this.errorText).fontSize(13).fontColor(AppTheme.red).width('100%')
          .padding({ left: 20, right: 20, top: 8, bottom: 8 })
      }

      if (this.loading) {
        Column({ space: 12 }) {
          LoadingProgress().width(28).height(28).color(AppTheme.blue)
          Text('正在读取会话…').fontSize(14).fontColor(AppTheme.secondary)
        }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else if (this.selected === null) {
        Scroll() {
          Column({ space: 18 }) {
            Column({ space: 7 }) {
              Text('每个目标，都有记录。').fontSize(29).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
                .letterSpacing(-0.4).width('100%')
              Text(`${this.sessions.length} 个会话，随时回顾你的安排。`)
                .fontSize(14).fontColor(AppTheme.secondary).width('100%')
            }.width('100%').padding({ left: 3, right: 3, top: 12, bottom: 7 })
            if (this.sessions.length === 0) {
              Column({ space: 14 }) {
                AppIcon({ name: 'history', iconSize: 34, color: AppTheme.muted })
                Text('还没有会话').fontSize(19).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
                Text('向 Agent 描述一个目标，\n这里会保存你的对话与安排。')
                  .fontSize(14).lineHeight(23).fontColor(AppTheme.secondary).textAlign(TextAlign.Center)
                Button('开始一个任务').height(44).fontSize(14).fontColor(AppTheme.blue)
                  .backgroundColor(AppTheme.blueSoft).borderRadius(22).margin({ top: 3 })
                  .onClick(() => this.onBack())
              }.width('100%').padding({ top: 40, bottom: 40, left: 24, right: 24 })
                .backgroundColor(AppTheme.surface).borderRadius(22)
            }
            Column() {
              ForEach(this.sessions, (session: SessionSummary, index: number) => {
                Column({ space: 0 }) {
                  Row({ space: 10 }) {
                    Column({ space: 7 }) {
                      Text(session.title).fontSize(17).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink)
                        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
                      Text(plainMessage(session.last_message)).fontSize(14)
                        .fontColor(AppTheme.secondary).maxLines(2)
                        .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
                    }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                    AppIcon({ name: 'chevron', iconSize: 16, color: AppTheme.muted })
                  }.width('100%').padding({ top: 17, bottom: 4 }).constraintSize({ minHeight: 76 })
                    .onClick(() => this.openSession(session))
                  Row({ space: 6 }) {
                    Text(`${session.updated_at.substring(0, 10)}  ·  ${session.message_count} 条消息`)
                      .fontSize(11).fontColor(AppTheme.muted).layoutWeight(1)
                    Text(session.model_name === 'deepseek-flash' ? 'Flash' : 'V4 Pro')
                      .fontSize(11).fontColor(AppTheme.muted)
                    Button('删除').height(44).width(52).fontSize(12).fontColor(AppTheme.red)
                      .padding({ left: 6, right: 6 }).backgroundColor(Color.Transparent).borderRadius(15)
                      .onClick(() => this.requestDelete(session.session_id))
                  }.width('100%')
                  if (this.pendingDeleteId === session.session_id) {
                    Column({ space: 10 }) {
                      Text('删除此会话？对话记录将无法恢复。').fontSize(13).fontColor(AppTheme.secondary)
                        .width('100%')
                      Row({ space: 10 }) {
                        Button('保留').height(44).fontSize(14).fontColor(AppTheme.blue)
                          .backgroundColor(AppTheme.surface).borderRadius(13).layoutWeight(1)
                          .onClick(() => this.requestDelete(''))
                        Button('确认删除').height(44).fontSize(14).fontColor('#FFFFFF')
                          .backgroundColor(AppTheme.red).borderRadius(13).layoutWeight(1)
                          .onClick(() => this.deleteSession(session))
                      }.width('100%')
                    }.width('100%').padding(12).margin({ bottom: 12 })
                      .backgroundColor(AppTheme.field).borderRadius(15)
                      .transition(TransitionEffect.OPACITY.animation({ duration: AppTheme.motion(180) }))
                  }
                }.width('100%').padding({ left: 17, right: 12 })
                if (index < this.sessions.length - 1) {
                  Divider().color(AppTheme.separator).strokeWidth(0.5).margin({ left: 17 })
                }
              }, (session: SessionSummary) => session.session_id)
            }.width('100%').backgroundColor(AppTheme.surface).borderRadius(20).clip(true)
          }.width('100%').padding({ left: 18, right: 18, top: 8, bottom: 24 })
        }.layoutWeight(1).width('100%').scrollBar(BarState.Off)
      } else {
        Scroll() {
          Column({ space: 15 }) {
            Text((this.selected as SessionSummary).title).fontSize(20).fontWeight(FontWeight.Bold)
              .fontColor(AppTheme.ink).wordBreak(WordBreak.BREAK_WORD).width('100%')
            Text('已保存的对话').fontSize(12).fontColor(AppTheme.muted).width('100%')
              .textAlign(TextAlign.Center).margin({ bottom: 4, top: 4 })
            ForEach(this.messages, (message: HistoryMessage, index: number) => {
              Row() {
                if (message.role === 'user') {
                  Blank()
                }
                Column() {
                  MessageContent({ content: message.content, isUser: message.role === 'user' })
                }.padding({ left: 16, right: 16, top: 13, bottom: 13 })
                  .width(message.role === 'user' ? '90%' : '100%')
                  .backgroundColor(message.role === 'user' ? AppTheme.blue : AppTheme.surface)
                  .borderRadius(message.role === 'user' ? { topLeft: 20, topRight: 20, bottomLeft: 20, bottomRight: 6 }
                    : { topLeft: 20, topRight: 20, bottomLeft: 6, bottomRight: 20 })
                if (message.role !== 'user') {
                  Blank()
                }
              }.width('100%')
            }, (message: HistoryMessage, index: number) => `${index}-${message.created_at}`)
          }.width('100%').padding({ left: 18, right: 18, top: 12, bottom: 24 })
        }.layoutWeight(1).width('100%').scrollBar(BarState.Off)
      }
    }.width('100%').height('100%').alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Start).backgroundColor(AppTheme.bg)
  }
}
