import { HistoryMessage, SessionSummary } from '../model/ApiModels';
import { CampusFlowApi } from '../services/CampusFlowApi';
import { localHistory } from '../services/LocalHistory';
import { CampusFlowRequestError } from '../utils/AgentFeedback';
import { plainMessage } from '../utils/MessageText';
import { MessageContent } from '../components/MessageContent';
import { AppTheme } from '../theme/AppTheme';
import { ThemePalette, themePalette } from '../theme/ThemePalette';
import { AppIcon } from '../components/AppIcon';
import { FeedbackPanel } from '../components/FeedbackPanel';
import { InfoDisclosure } from '../components/InfoDisclosure';

@Component
export struct HistoryPage {
  @StorageLink('campusflowThemePalette') private palette: ThemePalette = themePalette('paper-green');
  @Prop baseUrl: string;
  @Prop token: string;
  @Prop historyScope: string = '';
  @Prop offlineOnly: boolean = false;
  @Prop chatBusy: boolean = false;
  @Prop remoteDeleteBusy: boolean = false;
  @Prop accountRevision: number = 0;
  onBack: () => void = () => {};
  onContinueSession: (sessionId: string) => void = () => {};
  @State private verifiedRemoteSessionId: string = '';
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
  private listSourceText: string = '';
  private lastAttempt: SessionSummary | null = null;
  private listScroller: Scroller = new Scroller();
  private listOffset: number = 0;
  private restoreList: boolean = false;

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
    if (!this.pageActive || this.deleting || this.remoteDeleteBusy) { return; }
    this.lastAttempt = null; this.verifiedRemoteSessionId = '';
    const revision = ++this.requestRevision;
    this.errorText = '';
    this.selected = null;
    this.messages = [];
    this.sessions = localHistory.list(this.historyScope);
    this.sourceText = this.offlineOnly ? '本机副本 · 只读回看，不会发送请求或执行提案。' : '正在同步服务端会话…';
    if (this.offlineOnly) {
      this.listSourceText = this.sourceText;
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
      if (this.current(revision)) { this.loading = false; this.listSourceText = this.sourceText; }
    }
  }

  private async openSession(session: SessionSummary): Promise<void> {
    if (!this.pageActive || this.deleting) { return; }
    this.lastAttempt = session; this.verifiedRemoteSessionId = '';
    const revision = ++this.requestRevision;
    const accountRevision = this.accountRevision;
    this.errorText = '';
    this.pendingDeleteId = '';
    const cached = localHistory.messages(this.historyScope, session.session_id);
    if (cached !== undefined) {
      this.messages = cached;
      this.selected = session;
      this.sourceText = this.offlineOnly ? '本机副本 · 离线只读，不会执行提案。' : '本机副本 · 正在核对服务端内容。';
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
      this.verifiedRemoteSessionId = messages.length > 0 ? session.session_id : '';
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
          this.sourceText = saved ? '服务端内容 · 完整对话已保存到本机，可断网回看。' : '服务端内容 · 已读取对话，但此会话未保存到本机。';
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
          if (!(error instanceof CampusFlowRequestError) || error.statusCode !== 404) {
            const failure: Error = error instanceof Error ? error : new Error('HISTORY_DELETE_FAILED');
            throw failure;
          }
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

  private canContinue(): boolean {
    return !this.offlineOnly && this.pageActive && !this.loading && !this.deleting &&
      !this.remoteDeleteBusy && this.pendingDeleteId.length === 0 && this.selected !== null &&
      this.messages.length > 0 && this.verifiedRemoteSessionId === this.selected.session_id;
  }

  private continueSession(): void {
    if (!this.canContinue() || this.selected === null) { return; }
    // The assistant fetches authenticated context again before switching; history is never executable.
    this.onContinueSession(this.selected.session_id);
  }

  private goBack(): void {
    if (this.deleting) { return; }
    this.requestRevision++;
    this.loading = false;
    this.errorText = '';
    this.lastAttempt = null; this.verifiedRemoteSessionId = '';
    this.sourceText = this.listSourceText;
    this.restoreList = true;
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
    if (this.deleting || this.chatBusy || this.remoteDeleteBusy) { return; }
    this.getUIContext().animateTo({ duration: AppTheme.motion(180), curve: Curve.EaseOut }, () => {
      this.pendingDeleteId = sessionId;
    });
  }

  private async retryRead(): Promise<void> {
    if (!this.pageActive || this.loading || this.deleting || this.remoteDeleteBusy) { return; }
    if (this.lastAttempt !== null) { await this.openSession(this.lastAttempt); }
    else { await this.reload(); }
  }
  private restoreListPosition(): void {
    if (!this.restoreList || this.selected !== null) { return; }
    this.restoreList = false;
    this.listScroller.scrollTo({ xOffset: 0, yOffset: this.listOffset, animation: false });
  }

  build() {
    Column() {
      Row({ space: 4 }) {
        Button({ type: ButtonType.Normal }) {
          AppIcon({ name: 'back', iconSize: 21, color: this.palette.accent })
        }.width(48).constraintSize({ minHeight: 48 }).backgroundColor(Color.Transparent).borderRadius(22)
          .accessibilityText(this.selected === null ? (this.offlineOnly ? '返回登录' : '返回助手') : '返回历史会话')
          .onClick(() => this.goBack())
        Text(this.selected === null ? '历史会话' : (this.selected as SessionSummary).title)
          .fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.palette.ink)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        if (this.selected === null) {
          Button('刷新').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize).fontColor(this.palette.accent)
            .backgroundColor(Color.Transparent).padding({ left: 12, right: 12 })
            .enabled(!this.loading && !this.deleting).onClick(() => this.reload())
        } else {
          Button('刷新').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize).fontColor(this.palette.accent)
            .backgroundColor(Color.Transparent).enabled(!this.loading && !this.deleting).onClick(() => this.retryRead())
        }
      }.width('100%').constraintSize({ minHeight: 64 }).padding({ left: 7, right: 10 })
        .backgroundColor(this.palette.bg)

      if (this.errorText.length > 0) {
        FeedbackPanel({ kind: 'error', title: '历史记录未更新', message: this.errorText,
          actionLabel: this.pendingDeleteId.length > 0 ? '' : '重试读取', busy: this.loading || this.deleting, onAction: () => this.retryRead() })
      }
      if (this.sourceText.length > 0) {
        Column() {
          InfoDisclosure({ title: this.offlineOnly ? '离线只读' :
            (this.sourceText.startsWith('本机') ? '本机副本 · 待同步' : '记录来源'), message: this.sourceText })
        }.width('100%').padding({ left: 20, right: 20, top: 4, bottom: 4 })
      }
      if (this.loading && (this.sessions.length > 0 || this.selected !== null)) {
        Text('正在同步，已保存的内容仍可阅读…').fontSize(this.palette.metaSize).fontColor(this.palette.secondary)
          .width('100%').padding({ left: 20, right: 20, bottom: 6 })
      }
      if (this.chatBusy) {
        Text('助手还有运行或待核对的操作，处理后再切换或删除会话。').fontSize(this.palette.metaSize).fontColor(this.palette.secondary)
          .width('100%').padding({ left: 20, right: 20, bottom: 6 })
      }
      if (this.remoteDeleteBusy) {
        Text('正在完成会话删除…').fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
          .padding({ left: 20, right: 20, bottom: 6 })
      }

      if (this.loading && this.sessions.length === 0 && this.selected === null) {
        Column({ space: 12 }) {
          LoadingProgress().width(28).height(28).color(this.palette.accent)
          Text('正在读取会话…').fontSize(this.palette.bodySize).fontColor(this.palette.secondary)
        }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else if (this.selected === null) {
        Scroll(this.listScroller) {
          Column({ space: 16 }) {
            Text(`${this.sessions.length} 段对话`).fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
            if (this.sessions.length === 0 && this.errorText.length === 0) {
              FeedbackPanel({ kind: 'info', title: this.offlineOnly ? '本机暂无完整会话' : '还没有会话',
                message: this.offlineOnly ? '联网打开会话后，可在此离线回看。' : '和助手聊聊，记录会保存在这里。',
                actionLabel: this.offlineOnly ? '返回登录' : '前往助手', onAction: () => this.onBack() })
            }
            Column({ space: 10 }) {
              ForEach(this.sessions, (session: SessionSummary, index: number) => {
                if (index === 0 || session.updated_at.substring(0, 10) !== this.sessions[index - 1].updated_at.substring(0, 10)) {
                  Text(session.updated_at.substring(0, 10)).fontSize(this.palette.metaSize)
                    .fontWeight(FontWeight.Medium).fontColor(this.palette.quiet).width('100%')
                    .margin({ top: index === 0 ? 0 : 14, bottom: 2 })
                }
                Column({ space: 0 }) {
                  Row({ space: 10 }) {
                    Column({ space: 6 }) {
                      Text(session.title).fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium).fontColor(this.palette.ink)
                        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
                      Text(plainMessage(session.last_message)).fontSize(this.palette.metaSize)
                        .fontColor(this.palette.secondary).maxLines(2)
                        .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
                    }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                    AppIcon({ name: 'chevron', iconSize: 16, color: this.palette.muted })
                  }.width('100%').padding({ top: 16, bottom: 4 }).constraintSize({ minHeight: 76 })
                    .accessibilityText(`打开会话：${session.title}`)
                    .onClick(() => this.openSession(session))
                  Row({ space: 6 }) {
                    Text(`${session.message_count} 条消息`)
                      .fontSize(this.palette.metaSize).fontColor(this.palette.muted).layoutWeight(1)
                    Text(session.model_name === 'deepseek-flash' ? 'Flash' : session.model_name === 'deepseek-v4-pro' ? 'V4 Pro' : session.model_name)
                      .fontSize(this.palette.metaSize).fontColor(this.palette.muted)
                    Button(this.offlineOnly ? '移除本机副本' : '删除').constraintSize({ minHeight: 48 }).fontSize(this.palette.metaSize).fontColor(this.palette.danger)
                      .padding({ left: 6, right: 6 }).backgroundColor(Color.Transparent).borderRadius(15)
                      .enabled(!this.chatBusy && !this.deleting && !this.remoteDeleteBusy)
                      .onClick(() => this.requestDelete(session.session_id))
                  }.width('100%')
                  if (this.pendingDeleteId === session.session_id) {
                    Column({ space: 10 }) {
                      Text(this.offlineOnly ? '仅移除此设备上的副本，服务端记录不受影响。' : '删除服务端会话及本机副本？此操作无法恢复。').fontSize(this.palette.metaSize).fontColor(this.palette.secondary)
                        .width('100%')
                      Row({ space: 10 }) {
                        Button('保留').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize).fontColor(this.palette.accent)
                          .backgroundColor(this.palette.surface).borderRadius(13).layoutWeight(1)
                          .enabled(!this.deleting)
                          .onClick(() => this.requestDelete(''))
                        Button(this.deleting ? '处理中…' : '确认删除').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize).fontColor(this.palette.onAccent)
                          .backgroundColor(this.palette.danger).borderRadius(13).layoutWeight(1)
                          .enabled(!this.chatBusy && !this.deleting && !this.remoteDeleteBusy)
                          .onClick(() => this.deleteSession(session))
                      }.width('100%')
                    }.width('100%').padding(12).margin({ bottom: 12 })
                      .backgroundColor(this.palette.field).borderRadius(15)
                      .transition(TransitionEffect.OPACITY.animation({ duration: AppTheme.motion(180) }))
                  }
                }.width('100%').padding({ left: 16, right: 12 })
                  .backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
                  .border({ width: 1, color: this.palette.line })
              }, (session: SessionSummary) => session.session_id)
            }.width('100%')
          }.width('100%').padding({ left: this.palette.pageInset, right: this.palette.pageInset, top: 8, bottom: 24 })
            .onAreaChange(() => this.restoreListPosition())
        }.layoutWeight(1).width('100%').scrollBar(BarState.Off).align(Alignment.TopStart)
          .onScroll(() => { if (!this.restoreList) { this.listOffset = this.listScroller.currentOffset().yOffset; } })
      } else {
        Scroll() {
          Column({ space: 20 }) {
            InfoDisclosure({ title: '会话信息', message: `${(this.selected as SessionSummary).title}\n${(this.selected as SessionSummary).updated_at.substring(0, 10)}` })
            if (!this.offlineOnly) {
              Button('继续此会话').width('100%').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
                .fontColor(this.palette.onAccent).backgroundColor(this.palette.accent).borderRadius(this.palette.controlRadius)
                .enabled(this.canContinue()).onClick(() => this.continueSession())
              InfoDisclosure({ title: '继续会话说明', message: '继续前会核对服务端上下文。历史中的安排仅供阅读，不会恢复为待执行提案。' })
            }
            Text('只读文字 · 不能从历史执行提案').fontSize(this.palette.metaSize).fontColor(this.palette.muted).width('100%')
              .textAlign(TextAlign.Center).margin({ bottom: 4, top: 4 })
            if (this.messages.length === 0 && !this.loading && this.errorText.length === 0) {
              FeedbackPanel({ kind: 'info', title: '没有可读取的文字', message: '此会话可能已从服务端移除。',
                actionLabel: '返回会话列表', onAction: () => this.goBack() })
            }
            ForEach(this.messages, (message: HistoryMessage, index: number) => {
              Row() {
                if (message.role === 'user') {
                  Blank()
                }
                Column() {
                  MessageContent({ content: message.content, isUser: message.role === 'user' })
                }.padding({ left: 16, right: 16, top: 13, bottom: 13 })
                  .width(message.role === 'user' ? '90%' : '100%')
                  .backgroundColor(message.role === 'user' ? this.palette.accent : this.palette.surface)
                  .border({ width: message.role === 'user' ? 0 : 1, color: this.palette.line })
                  .borderRadius(message.role === 'user' ? { topLeft: 20, topRight: 20, bottomLeft: 20, bottomRight: 6 }
                    : { topLeft: 20, topRight: 20, bottomLeft: 6, bottomRight: 20 })
                if (message.role !== 'user') {
                  Blank()
                }
              }.width('100%')
            }, (message: HistoryMessage, index: number) => `${index}-${message.created_at}`)
          }.width('100%').padding({ left: 18, right: 18, top: 12, bottom: 24 })
        }.layoutWeight(1).width('100%').scrollBar(BarState.Off).align(Alignment.TopStart)
      }
    }.width('100%').height('100%').alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Start).backgroundColor(this.palette.bg)
  }
}
