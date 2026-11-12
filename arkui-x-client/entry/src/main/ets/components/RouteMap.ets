import { webview } from '@kit.ArkWeb';
import { BaiduMapConfig, CampusDataPlace, CampusRoute } from '../model/ApiModels';
import { CampusFlowApi } from '../services/CampusFlowApi';
import { mapConfigScript, mapStateScript, routeMapUrl, trustedMapDocument } from '../utils/RouteMapBridge';
import { ThemePalette, themePalette } from '../theme/ThemePalette';

@Component
export struct RouteMap {
  @StorageLink('campusflowThemePalette') private palette: ThemePalette = themePalette('paper-green');
  @Watch('sourceChanged') @Prop baseUrl: string = '';
  @Watch('tokenChanged') @Prop token: string = '';
  @Watch('stateChanged') @Prop active: boolean = true;
  @Watch('stateChanged') @Prop route: CampusRoute | null = null;
  @Watch('stateChanged') @Prop origin: CampusDataPlace | null = null;
  @Watch('stateChanged') @Prop destination: CampusDataPlace | null = null;
  @State private documentUrl: string = '';
  @State private errorText: string = '';
  private controller: webview.WebviewController = new webview.WebviewController();
  private pageActive: boolean = false;
  private ready: boolean = false;
  private loadedBaseUrl: string = '';
  private configRevision: number = 0;

  aboutToAppear(): void {
    this.pageActive = true;
    this.sourceChanged();
  }

  aboutToDisappear(): void {
    this.clearDocument();
    this.pageActive = false;
    this.invalidateDocument();
    this.documentUrl = '';
  }

  private clearDocument(): void {
    if (!this.ready) { return; }
    try {
      if (trustedMapDocument(this.controller.getUrl(), this.loadedBaseUrl)) {
        this.controller.runJavaScript(mapStateScript({ active: false, route: null, origin: null, destination: null }))
          .catch(() => {});
      }
    } catch { /* The Web controller may already have been detached. */ }
  }

  private sourceChanged(): void {
    this.clearDocument();
    this.invalidateDocument();
    this.errorText = '';
    this.documentUrl = this.pageActive && this.active && this.token.length > 0 ? routeMapUrl(this.baseUrl) : '';
  }

  private invalidateDocument(): void {
    this.configRevision++;
    this.ready = false;
    this.loadedBaseUrl = '';
  }

  private tokenChanged(): void {
    const previous = this.documentUrl;
    this.sourceChanged();
    if (previous.length > 0 && this.documentUrl === previous) { this.retryMap(); }
  }

  private stateChanged(): void {
    if (!this.pageActive) { return; }
    if (!this.active) {
      this.clearDocument();
      this.invalidateDocument();
      this.documentUrl = '';
      return;
    }
    if (this.documentUrl !== routeMapUrl(this.baseUrl)) { this.sourceChanged(); return; }
    this.pushState();
  }

  private configCurrent(revision: number, baseUrl: string, token: string): boolean {
    return this.pageActive && this.active && revision === this.configRevision &&
      this.baseUrl === baseUrl && this.token === token;
  }

  private async pageFinished(url: string): Promise<void> {
    const baseUrl = this.baseUrl;
    const token = this.token;
    if (!this.pageActive || !this.active || token.length === 0 || !trustedMapDocument(url, baseUrl)) { return; }
    const revision = ++this.configRevision;
    try {
      if (!trustedMapDocument(this.controller.getUrl(), baseUrl)) { return; }
      const config = await new CampusFlowApi(baseUrl, token).baiduMapConfig();
      if (!this.configCurrent(revision, baseUrl, token) || !trustedMapDocument(this.controller.getUrl(), baseUrl)) { return; }
      this.loadedBaseUrl = baseUrl;
      this.ready = true;
      this.errorText = '';
      this.pushState(config);
    } catch {
      if (this.configCurrent(revision, baseUrl, token)) { this.errorText = '地图配置暂时无法读取，请重试。'; }
    }
  }

  private pushState(config: BaiduMapConfig | null = null): void {
    if (!this.ready || !this.active || !this.pageActive) { return; }
    try {
      if (!trustedMapDocument(this.controller.getUrl(), this.baseUrl)) { this.ready = false; return; }
      const initialize = config === null ? '' : mapConfigScript(config);
      this.controller.runJavaScript(initialize + mapStateScript({ active: true, route: this.route,
        origin: this.origin, destination: this.destination })).catch(() => {});
    } catch { this.ready = false; }
  }

  private retryMap(): void {
    if (!this.pageActive || !this.active || this.documentUrl.length === 0) { return; }
    this.errorText = '';
    this.invalidateDocument();
    try { this.controller.loadUrl(this.documentUrl); }
    catch { this.errorText = '地图暂时无法显示，请重试。'; }
  }

  build() {
    Column({ space: 8 }) {
      if (this.documentUrl.length > 0) {
        Web({ src: this.documentUrl, controller: this.controller })
          .width('100%').height(400)
          .javaScriptAccess(true).domStorageAccess(false).fileAccess(false).geolocationAccess(false)
          .onPageBegin(() => { this.invalidateDocument(); })
          .onPageEnd((event) => { if (event) { this.pageFinished(event.url); } })
          .onLoadIntercept((event) => {
            if (!event || !event.data.isMainFrame()) { return false; }
            return !trustedMapDocument(event.data.getRequestUrl(), this.baseUrl);
          })
          .onErrorReceive((event) => {
            if (event && event.request.isMainFrame() && this.pageActive && this.active) {
              this.invalidateDocument();
              this.errorText = '地图页面加载失败，请检查服务连接后重试。';
            }
          })
      } else if (this.active) {
        Text('地图服务地址不可用，请核对连接设置。').fontColor(this.palette.quiet).fontSize(this.palette.bodySize)
      }
      if (this.errorText.length > 0) {
        Text(this.errorText).fontColor(this.palette.quiet).fontSize(this.palette.bodySize).width('100%')
        Button('重新加载地图').onClick(() => this.retryMap()).fontColor(this.palette.accent)
          .backgroundColor(this.palette.accentSoft).constraintSize({ minHeight: 44 })
      }
    }.width('100%').clip(true).borderRadius(this.palette.cardRadius)
  }
}
