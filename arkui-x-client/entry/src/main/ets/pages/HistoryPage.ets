import { HistoryMessage, SessionSummary } from '../model/ApiModels';
import { CampusFlowApi } from '../services/CampusFlowApi';
import { plainMessage } from '../utils/MessageText';

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

  build() {
    Column() {
      Row({ space: 12 }) {
        Button('‹').width(42).height(42).fontSize(26).fontColor('#171A22')
          .backgroundColor('#FFFFFF').borderRadius(14).onClick(() => {
            if (this.selected !== null) {
              this.selected = null;
              this.messages = [];
            } else {
              this.onBack();
            }
          })
        Column({ space: 3 }) {
          Text(this.selected === null ? '历史会话' : (this.selected as SessionSummary).title)
            .fontSize(this.selected === null ? 24 : 20).fontWeight(FontWeight.Bold)
            .fontColor('#171A22').maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
          Text(this.selected === null ? `${this.sessions.length} 个已保存会话` : '上下文已持久化到本地服务')
            .fontSize(12).fontColor('#7B8292')
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      }.width('100%').alignItems(VerticalAlign.Top)
        .padding({ left: 18, right: 18, top: 18, bottom: 12 })

      if (this.errorText.length > 0) {
        Text(this.errorText).fontSize(12).fontColor('#D33D3D').width('100%')
          .padding({ left: 18, right: 18, bottom: 8 })
      }

      if (this.loading) {
        Text('加载中…').fontSize(13).fontColor('#7B8292').margin({ top: 30 })
      } else if (this.selected === null) {
        Scroll() {
          Column({ space: 12 }) {
            if (this.sessions.length === 0) {
              Text('还没有历史会话，去 Agent 发起第一个任务吧。')
                .fontSize(14).fontColor('#7B8292').padding(24).width('100%')
            }
            ForEach(this.sessions, (session: SessionSummary) => {
              Column({ space: 8 }) {
                Row() {
                  Text(session.title).fontSize(16).fontWeight(FontWeight.Bold).fontColor('#171A22')
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
                  Text(`${session.message_count} 条`).fontSize(11).fontColor('#315BFF')
                }.width('100%')
                Text(plainMessage(session.last_message)).fontSize(13).fontColor('#697083').maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
                Text(session.model_name === 'deepseek-flash' ? 'FLASH' : 'V4 PRO')
                  .fontSize(10).fontColor('#8A90A0').width('100%')
              }
              .width('100%').padding(17).backgroundColor('#FFFFFF').borderRadius(20)
              .onClick(() => this.openSession(session))
            }, (session: SessionSummary) => session.session_id)
          }.width('100%').padding({ left: 18, right: 18, top: 8, bottom: 24 })
        }.layoutWeight(1).width('100%')
      } else {
        Scroll() {
          Column({ space: 12 }) {
            ForEach(this.messages, (message: HistoryMessage, index: number) => {
              Row() {
                if (message.role === 'user') {
                  Blank()
                }
                Text(plainMessage(message.content)).fontSize(14).lineHeight(22)
                  .fontColor(message.role === 'user' ? '#FFFFFF' : '#272B34')
                  .padding(15).constraintSize({ maxWidth: '86%' })
                  .backgroundColor(message.role === 'user' ? '#315BFF' : '#FFFFFF')
                  .borderRadius(18)
                if (message.role !== 'user') {
                  Blank()
                }
              }.width('100%')
            }, (message: HistoryMessage, index: number) => `${index}-${message.created_at}`)
          }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 24 })
        }.layoutWeight(1).width('100%')
      }
    }.width('100%').height('100%').backgroundColor('#F5F7FB')
  }
}
