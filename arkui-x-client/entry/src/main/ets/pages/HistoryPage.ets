import { HistoryMessage, SessionSummary } from '../model/ApiModels';
import { CampusFlowApi } from '../services/CampusFlowApi';
import { localHistory } from '../services/LocalHistory';
import { CampusFlowRequestError } from '../utils/AgentFeedback';
import { plainMessage } from '../utils/MessageText';
import { MessageContent } from '../components/MessageContent';
import { AppTheme } from '../theme/AppTheme';
import { AppIcon } from '../components/AppIcon';

@Component
export struct HistoryPage {
  @Prop baseUrl: string;
  @Prop token: string;
  @Prop historyScope: string = '';
  @Prop offlineOnly: boolean = false;
  @Prop chatBusy: boolean = false;
  @Prop remoteDeleteBusy: boolean = false;
  @Prop accountRevision: number = 0;
  onBack: () => void = () => {};
  onSessionDeleted: (sessionId: string, revision: number) => void = () => {};
  onDeleteBusyChange: (busy: boolean, revision: number) => void = () => {};
  @State private sessions: SessionSummary[] = [];
  @State private selected: SessionSummary | null = null;
  @State private messages: HistoryMessage[] = [];
  @State private loading: boolean = false;
  @State private errorText: string = '';
  @State private pendingDeleteId: string = '';
  @State private sourceText: string = '';
  @State private deleting: boolean = false;
  private requestRevision: number = 0;
  private pageActive: boolean = true;

  aboutToAppear(): void {
    this.pageActive = true;
    this.reload();
  }

  aboutToDisappear(): void {
    this.pageActive = false;
    this.requestRevision++;
  }

  private current(revision: number): boolean {
    return this.pageActive && this.requestRevision === revision;
  }

  private async reload(): Promise<void> {
    const revision = ++this.requestRevision;
    this.errorText = '';
    this.selected = null;
    this.messages = [];
    this.sessions = localHistory.list(this.historyScope);
    this.sourceText = this.offlineOnly ? '本机副本 · 只读回看，不会发送请求或执行提案。' : '正在同步服务端会话…';
    if (this.offlineOnly) {
      this.loading = false;
      return;
    }
    this.loading = true;
    try {
      const sessions = await new CampusFlowApi(this.baseUrl, this.token).sessions();
      if (!this.current(revision)) { return; }
      this.sessions = sessions.filter((item: SessionSummary) => !localHistory.isRemoved(this.historyScope, item.session_id));
      this.sourceText = this.historyScope.length > 0
        ? '服务端会话 · 打开后保存完整文字到本机，最多保留最近 20 个会话。'
        : '服务端会话 · 本机保存暂不可用。';
    } catch {
      if (!this.current(revision)) { return; }
      this.sourceText = '本机副本 · 可能不是最新内容，联网后可刷新。';
      this.errorText = this.sessions.length > 0 ? '暂时无法同步，仍可阅读本机已保存的会话。' : '暂时无法同步，且本机还没有保存的会话。';
    } finally {
      if (this.current(revision)) { this.loading = false; }
    }
  }

  private async openSession(session: SessionSummary): Promise<void> {
    if (this.deleting) { return; }
    const revision = ++this.requestRevision;
    const accountRevision = this.accountRevision;
    this.errorText = '';
    this.pendingDeleteId = '';
    const cached = localHistory.messages(this.historyScope, session.session_id);
    if (cached !== undefined) {
      this.messages = cached;
      this.selected = session;
      this.sourceText = '本机副本 · 尚未同步最新内容。';
    }
    if (this.offlineOnly) {
      this.loading = false;
      if (cached === undefined) { this.errorText = '本机没有此会话的完整内容。'; }
      return;
    }
    this.loading = true;
    try {
      const messages = await new CampusFlowApi(this.baseUrl, this.token).history(session.session_id);
      if (!this.current(revision)) { return; }
      this.messages = messages;
      this.selected = session;
      this.sourceText = '已读取服务端对话。';
      try {
        // The API returns an empty array when a session no longer exists.
        if (messages.length === 0) {
          if (this.historyScope.length > 0) {
            await localHistory.removeSession(this.historyScope, session.session_id);
          }
          if (!this.current(revision)) { return; }
          this.sessions = this.sessions.filter((item: SessionSummary) => item.session_id !== session.session_id);
          this.sourceText = '服务端已无此会话内容，本机副本已移除。';
          this.onSessionDeleted(session.session_id, accountRevision);
        } else {
          const saved = await localHistory.save(this.historyScope, session, messages);
          if (!this.current(revision)) { return; }
          this.sourceText = saved ? '完整对话已保存到本机，可断网回看。' : '已读取对话，但此会话未保存到本机。';
        }
      } catch {
        if (this.current(revision)) { this.errorText = '对话已读取，但本机保存未完成。'; }
      }
    } catch {
      if (!this.current(revision)) { return; }
      this.errorText = cached !== undefined ? '暂时无法同步，显示上次保存的本机副本。' : '此会话尚未保存到本机，请联网后重试。';
    } finally {
      if (this.current(revision)) { this.loading = false; }
    }
  }

  private async deleteSession(session: SessionSummary): Promise<void> {
    if (this.deleting || this.chatBusy || this.remoteDeleteBusy) { return; }
    const revision = ++this.requestRevision;
    const scope = this.historyScope;
    const accountRevision = this.accountRevision;
    const storageEpoch = localHistory.epoch();
    const offline = this.offlineOnly;
    this.deleting = true;
    this.onDeleteBusyChange(true, accountRevision);
    this.loading = false;
    this.errorText = '';
    try {
      if (!offline) {
        try {
          await new CampusFlowApi(this.baseUrl, this.token).deleteSession(session.session_id);
        } catch (error) {
          // This endpoint reports 404 when the authenticated user's session is already gone.
          if (!(error instanceof CampusFlowRequestError) || error.statusCode !== 404) { throw error; }
        }
        // A committed delete must finish even if the user changes tabs. Only an
        // account/storage-generation change may prevent local cleanup.
        if (storageEpoch !== localHistory.epoch()) { return; }
        this.onSessionDeleted(session.session_id, accountRevision);
      }
      try {
        if (scope.length > 0) {
          await localHistory.removeSession(scope, session.session_id, !offline);
        }
      } catch {
        if (!this.current(revision)) { return; }
        this.errorText = this.offlineOnly ? '本机副本移除失败，请重试。' : '服务端已删除，但本机副本移除失败，请重试清理本机记录。';
        return;
      }
      if (!this.current(revision)) { return; }
      this.sessions = this.sessions.filter((item) => item.session_id !== session.session_id);
      if (this.selected?.session_id === session.session_id) {
        this.selected = null;
        this.messages = [];
      }
      this.pendingDeleteId = '';
    } catch {
      if (this.current(revision)) { this.errorText = '删除未完成，请联网核对后重试。'; }
    } finally {
      this.onDeleteBusyChange(false, accountRevision);
      if (this.current(revision)) { this.deleting = false; }
    }
  }

  private goBack(): void {
    if (this.deleting) { return; }
    this.requestRevision++;
    this.loading = false;
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
            .enabled(!this.loading && !this.deleting).onClick(() => this.reload())
        } else {
          Blank().width(12)
        }
      }.width('100%').height(56).padding({ left: 7, right: 10 })
        .backgroundColor(AppTheme.bg)

      if (this.errorText.length > 0) {
        Text(this.errorText).fontSize(13).fontColor(AppTheme.red).width('100%')
          .padding({ left: 20, right: 20, top: 8, bottom: 8 })
      }
      Text(this.sourceText).fontSize(12).fontColor(AppTheme.secondary).width('100%')
        .padding({ left: 20, right: 20, top: 6, bottom: 6 })
      if (this.loading && (this.sessions.length > 0 || this.selected !== null)) {
        Text('正在同步，已保存的内容仍可阅读…').fontSize(12).fontColor(AppTheme.secondary)
          .width('100%').padding({ left: 20, right: 20, bottom: 6 })
      }
      if (this.chatBusy) {
        Text('Agent 正在回复，结束后可删除会话。').fontSize(12).fontColor(AppTheme.secondary)
          .width('100%').padding({ left: 20, right: 20, bottom: 6 })
      }
      if (this.remoteDeleteBusy) {
        Text('正在完成会话删除…').fontSize(12).fontColor(AppTheme.secondary).width('100%')
          .padding({ left: 20, right: 20, bottom: 6 })
      }

      if (this.loading && this.sessions.length === 0 && this.selected === null) {
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
                Text(this.offlineOnly ? '本机没有保存的完整会话。\n联网登录后，对话会逐步保存。' : '向 Agent 描述一个目标，\n成功的对话会保存到本机。')
                  .fontSize(14).lineHeight(23).fontColor(AppTheme.secondary).textAlign(TextAlign.Center)
                Button(this.offlineOnly ? '返回登录' : '开始一个任务').height(44).fontSize(14).fontColor(AppTheme.blue)
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
                    Button(this.offlineOnly ? '移除本机副本' : '删除').constraintSize({ minHeight: 44 }).fontSize(12).fontColor(AppTheme.red)
                      .padding({ left: 6, right: 6 }).backgroundColor(Color.Transparent).borderRadius(15)
                      .enabled(!this.chatBusy && !this.deleting && !this.remoteDeleteBusy)
                      .onClick(() => this.requestDelete(session.session_id))
                  }.width('100%')
                  if (this.pendingDeleteId === session.session_id) {
                    Column({ space: 10 }) {
                      Text(this.offlineOnly ? '仅移除此设备上的副本，服务端记录不受影响。' : '删除服务端会话及本机副本？此操作无法恢复。').fontSize(13).fontColor(AppTheme.secondary)
                        .width('100%')
                      Row({ space: 10 }) {
                        Button('保留').height(44).fontSize(14).fontColor(AppTheme.blue)
                          .backgroundColor(AppTheme.surface).borderRadius(13).layoutWeight(1)
                          .enabled(!this.deleting)
                          .onClick(() => this.requestDelete(''))
                        Button(this.deleting ? '处理中…' : '确认删除').constraintSize({ minHeight: 44 }).fontSize(14).fontColor('#FFFFFF')
                          .backgroundColor(AppTheme.red).borderRadius(13).layoutWeight(1)
                          .enabled(!this.chatBusy && !this.deleting && !this.remoteDeleteBusy)
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
