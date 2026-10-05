import { CampusRoute, ChatMessage, PendingAction } from '../model/ApiModels';
import { CampusFlowApi } from '../services/CampusFlowApi';
import { RouteMap } from '../components/RouteMap';

@Component
export struct AgentPage {
  @Prop baseUrl: string;
  @Prop token: string;
  onOpenHistory: () => void = () => {};
  @State private prompt: string = '';
  @State private model: string = 'deepseek-v4-pro';
  @State private messages: ChatMessage[] = [
    { role: 'assistant', content: '告诉我你的目标，我会结合课表、校园地点和待办，给出可执行的安排。' }
  ];
  @State private pendingActions: PendingAction[] = [];
  @State private loading: boolean = false;
  @State private origin: string = '六教';
  @State private destination: string = '菜鸟驿站';
  @State private route: CampusRoute | null = null;
  @State private routeError: string = '';
  private sessionId: string = `arkuix-${Date.now()}`;

  private async send(): Promise<void> {
    const text = this.prompt.trim();
    if (text.length === 0 || this.loading) {
      return;
    }
    this.messages = this.messages.concat([{ role: 'user', content: text }]);
    this.prompt = '';
    this.loading = true;
    try {
      const response = await new CampusFlowApi(this.baseUrl, this.token).chat(this.sessionId, this.model, text);
      this.messages = this.messages.concat([{ role: 'assistant', content: response.message }]);
      this.pendingActions = response.pending_actions;
    } catch (error) {
      this.messages = this.messages.concat([{ role: 'assistant', content: `任务执行失败：${error}` }]);
    } finally {
      this.loading = false;
    }
  }

  private async createRoute(): Promise<void> {
    this.routeError = '';
    try {
      this.route = await new CampusFlowApi(this.baseUrl, this.token).campusRoute(this.origin, this.destination);
    } catch (error) {
      this.route = null;
      this.routeError = `路线生成失败：${error}`;
    }
  }

  private async confirm(action: PendingAction): Promise<void> {
    try {
      const result = await new CampusFlowApi(this.baseUrl, this.token).confirmAction(action.proposal_id);
      this.messages = this.messages.concat([{ role: 'assistant', content: result.message }]);
      this.pendingActions = this.pendingActions.filter((item) => item.proposal_id !== action.proposal_id);
    } catch (error) {
      this.messages = this.messages.concat([{ role: 'assistant', content: `确认失败：${error}` }]);
    }
  }

  @Builder
  private routePlanner() {
    Column({ space: 12 }) {
      Row() {
        Text('校园路线').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#171A22')
        Blank()
        Text('官方地图数据').fontSize(11).fontColor('#315BFF')
      }.width('100%')
      Row({ space: 8 }) {
        TextInput({ text: this.origin, placeholder: '起点' }).layoutWeight(1).height(44)
          .backgroundColor('#F4F6FA').borderRadius(13).onChange((value) => this.origin = value)
        Text('→').fontColor('#7C8393')
        TextInput({ text: this.destination, placeholder: '终点' }).layoutWeight(1).height(44)
          .backgroundColor('#F4F6FA').borderRadius(13).onChange((value) => this.destination = value)
      }.width('100%')
      Button('生成路线图').width('100%').height(44).fontColor('#FFFFFF').backgroundColor('#171A22')
        .borderRadius(14).onClick(() => this.createRoute())
      if (this.routeError.length > 0) {
        Text(this.routeError).fontSize(12).fontColor('#D33D3D').width('100%')
      }
    }.width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(22)
  }

  build() {
    Column() {
      Scroll() {
        Column({ space: 14 }) {
          Row() {
            Column({ space: 3 }) {
              Text('任务会话').fontSize(25).fontWeight(FontWeight.Bold).fontColor('#171A22')
              Text('Agent 会先规划，再调用工具').fontSize(12).fontColor('#7B8292')
            }.alignItems(HorizontalAlign.Start)
            Blank()
            Button('历史').height(34).fontSize(11).fontColor('#5F6675')
              .backgroundColor('#FFFFFF').borderRadius(18).margin({ right: 8 })
              .onClick(() => this.onOpenHistory())
            Button(this.model === 'deepseek-v4-pro' ? 'V4 PRO' : 'FLASH')
              .height(34).fontSize(11).fontColor('#315BFF').backgroundColor('#E9EEFF').borderRadius(18)
              .onClick(() => this.model = this.model === 'deepseek-v4-pro' ? 'deepseek-flash' : 'deepseek-v4-pro')
          }.width('100%')

          this.routePlanner()
          if (this.route !== null) {
            RouteMap({ route: this.route as CampusRoute })
          }

          ForEach(this.messages, (message: ChatMessage) => {
            Row() {
              if (message.role === 'user') {
                Blank()
              }
              Text(message.content)
                .fontSize(14).fontColor(message.role === 'user' ? '#FFFFFF' : '#272B34')
                .lineHeight(22)
                .padding(15)
                .constraintSize({ maxWidth: '86%' })
                .backgroundColor(message.role === 'user' ? '#315BFF' : '#FFFFFF')
                .borderRadius(message.role === 'user' ? { topLeft: 18, topRight: 5, bottomLeft: 18, bottomRight: 18 }
                  : { topLeft: 5, topRight: 18, bottomLeft: 18, bottomRight: 18 })
              if (message.role !== 'user') {
                Blank()
              }
            }.width('100%')
          })

          ForEach(this.pendingActions, (action: PendingAction) => {
            Column({ space: 10 }) {
              Text('等待确认').fontSize(11).fontColor('#FF6B4A').width('100%')
              Text(action.title).fontSize(16).fontWeight(FontWeight.Bold).fontColor('#171A22').width('100%')
              if (action.conflicts.length > 0) {
                Text(`检测到冲突：${action.conflicts.join('；')}`).fontSize(12).fontColor('#D33D3D').width('100%')
              }
              Button('确认执行').height(40).fontColor('#FFFFFF').backgroundColor('#315BFF').borderRadius(12)
                .onClick(() => this.confirm(action))
            }.width('100%').padding(16).backgroundColor('#FFF4EE').borderRadius(20)
          }, (action: PendingAction) => action.proposal_id)

          if (this.loading) {
            Text('Agent 正在规划与调用工具…').fontSize(12).fontColor('#7B8292').width('100%')
          }
        }.width('100%').padding({ left: 16, right: 16, top: 16, bottom: 20 })
      }.layoutWeight(1).width('100%').clip(true)

      Row({ space: 10 }) {
        TextArea({ text: this.prompt, placeholder: '例如：从六教去菜鸟驿站，顺便安排复习…' })
          .layoutWeight(1).height(58).backgroundColor('#F4F6FA').borderRadius(18)
          .onChange((value) => this.prompt = value)
        Button('发送').width(68).height(48).fontColor('#FFFFFF').backgroundColor('#315BFF').borderRadius(16)
          .enabled(!this.loading).onClick(() => this.send())
      }.width('100%').padding({ left: 14, right: 14, top: 10, bottom: 10 }).backgroundColor('#FFFFFF')
        .border({ width: { top: 1 }, color: '#E8EBF2' })
    }.width('100%').height('100%').backgroundColor('#F5F7FB')
  }
}
