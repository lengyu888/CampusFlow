import { CampusFlowApi } from '../services/CampusFlowApi';
import { ThemePalette, themePalette } from '../theme/ThemePalette';
import { ConnectionCheckController, ConnectionCheckState, emptyConnectionCheck,
  connectionCheckTitle, connectionCheckMessage } from '../utils/ConnectionCheck';
import { FeedbackPanel } from './FeedbackPanel';
import { InfoDisclosure } from './InfoDisclosure';

@Component
export struct ConnectionCheckPanel {
  @StorageLink('campusflowThemePalette') private palette: ThemePalette = themePalette('paper-green');
  @Watch('configurationChanged') @Prop baseUrl: string;
  @Watch('configurationChanged') @Prop active: boolean = true;
  @State private state: ConnectionCheckState = emptyConnectionCheck();
  private controller: ConnectionCheckController | null = null;
  private pageActive: boolean = true;

  aboutToAppear(): void {
    this.pageActive = true;
    this.controller = new ConnectionCheckController((base: string) => new CampusFlowApi(base), (state: ConnectionCheckState) => {
      if (this.pageActive) { this.state = state; }
    });
    this.configurationChanged();
  }
  aboutToDisappear(): void { this.pageActive = false; this.controller?.dispose(); this.controller = null; }
  private configurationChanged(): void { this.controller?.configure(this.baseUrl, this.active && this.pageActive); }

  build() {
    Column({ space: 8 }) {
      Button(this.state.phase === 'checking' ? '正在检查…' : '检查连接')
        .width('100%').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
        .fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft).borderRadius(this.palette.controlRadius)
        .enabled(this.active && this.state.phase !== 'checking').onClick(() => this.controller?.check())
      if (this.state.phase !== 'idle') {
        FeedbackPanel({ kind: this.state.phase === 'checking' ? 'loading' : this.state.phase === 'online' ? 'success' : 'warning',
          title: connectionCheckTitle(this.state),
          message: this.state.phase === 'checking' ? '' : connectionCheckMessage(this.state) })
      }
      if (this.state.phase !== 'idle' && this.state.phase !== 'online' && this.state.phase !== 'checking') {
        InfoDisclosure({ title: '连接排查', message: '确认后端已启动，核对地址和端口。真机连接本地后端时使用电脑的局域网地址。Phone 模拟器使用 127.0.0.1 时需建立端口映射。' })
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
