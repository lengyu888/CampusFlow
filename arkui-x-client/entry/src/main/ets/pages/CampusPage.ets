import { UserProfile, WeatherForecast } from '../model/ApiModels';
import { AppIcon } from '../components/AppIcon';
import { AppTheme } from '../theme/AppTheme';
import { EvidencePanel } from '../components/EvidencePanel';
import { FeedbackPanel } from '../components/FeedbackPanel';
import { CampusFlowApi } from '../services/CampusFlowApi';
import { shanghaiDate } from '../utils/DailyAgenda';
import { validWeather, weatherUsable } from '../utils/EvidencePresentation';

// Shared entry shell. Each entry opens the existing native feature page.
@Component
export struct CampusPage {
  @Watch('profileChanged') @Prop user: UserProfile;
  @Watch('connectionChanged') @Prop baseUrl: string;
  @Watch('connectionChanged') @Prop token: string;
  @Watch('activeChanged') @Prop active: boolean = true;
  @State private forecast: WeatherForecast | null = null;
  @State private weatherLoading: boolean = false;
  @State private weatherError: string = '';
  @State private now: number = Date.now();
  private pageActive: boolean = false;
  private weatherRevision: number = 0;
  private clock: number = -1;
  private weatherCampus: string = '';
  onOpenTimetable: () => void = () => {};
  onOpenRoute: () => void = () => {};
  onOpenServices: () => void = () => {};
  onOpenSkills: () => void = () => {};
  onOpenProfile: () => void = () => {};
  onOpenAgent: (prompt: string) => void = () => {};
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void { this.pageActive = true; this.activeChanged(); }
  aboutToDisappear(): void { this.pageActive = false; this.invalidateWeather(); }

  private invalidateWeather(): void {
    this.weatherRevision++;
    this.weatherLoading = false;
    if (this.clock >= 0) { clearInterval(this.clock); this.clock = -1; }
  }

  private activeChanged(): void {
    this.invalidateWeather();
    this.now = Date.now();
    if (!this.active || !this.pageActive) { return; }
    this.clock = setInterval(() => { if (this.pageActive && this.active) { this.now = Date.now(); } }, 30000);
    if (this.weatherCampus !== this.campusIdentity()) { this.forecast = null; this.weatherError = ''; }
    if (this.forecast === null || this.forecast.date !== shanghaiDate(this.now) || !weatherUsable(this.forecast, this.now)) {
      this.loadWeather();
    }
  }

  private campusIdentity(): string { return `${this.user.user_id}|${this.user.school ?? ''}|${this.user.campus ?? ''}`; }
  private profileChanged(): void { if (this.weatherCampus !== this.campusIdentity()) { this.activeChanged(); } }
  private connectionChanged(): void {
    this.forecast = null;
    this.weatherError = '';
    this.weatherCampus = '';
    this.activeChanged();
  }

  private currentWeather(revision: number, token: string, baseUrl: string, campus: string): boolean {
    return this.pageActive && this.active && revision === this.weatherRevision && token === this.token &&
      baseUrl === this.baseUrl && campus === this.campusIdentity();
  }

  private async loadWeather(): Promise<void> {
    if (!this.pageActive || !this.active) { return; }
    const revision = ++this.weatherRevision;
    const token = this.token;
    const baseUrl = this.baseUrl;
    const campus = this.campusIdentity();
    const date = shanghaiDate(Date.now());
    this.weatherLoading = true;
    this.weatherError = '';
    try {
      const result = await new CampusFlowApi(baseUrl, token).weather(date);
      if (!this.currentWeather(revision, token, baseUrl, campus)) { return; }
      if (!validWeather(result, date)) { throw new Error('invalid weather'); }
      this.forecast = result;
      this.weatherCampus = campus;
      this.now = Date.now();
    } catch {
      if (this.currentWeather(revision, token, baseUrl, campus)) {
        this.weatherError = '本次天气查询未完成，不能把之前记录当作刚刚更新的预报。请检查连接后重试。';
      }
    } finally {
      if (this.currentWeather(revision, token, baseUrl, campus)) { this.weatherLoading = false; }
    }
  }

  private currentForecast(): boolean {
    return this.forecast !== null && this.weatherError.length === 0 &&
      this.forecast.date === shanghaiDate(this.now) && weatherUsable(this.forecast, this.now);
  }

  private weatherNumbers(): string {
    if (this.forecast === null) { return ''; }
    const low = this.forecast.temperature_min_c;
    const high = this.forecast.temperature_max_c;
    const rain = this.forecast.precipitation_probability;
    return `${low === null ? '—' : low}–${high === null ? '—' : high} °C · 降水概率 ${rain === null ? '未知' : `${rain}%`}`;
  }

  @Builder
  private WeatherCard() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text('出门前看看天气').fontSize(AppTheme.sectionTitle).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
          Text('城市级预报 · 不读取设备位置').fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet)
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Button('刷新').constraintSize({ minHeight: 48, minWidth: 64 }).fontSize(AppTheme.metaSize)
          .fontColor(AppTheme.actionBlue).backgroundColor(AppTheme.blueSoft).enabled(!this.weatherLoading)
          .onClick(() => this.loadWeather())
      }.width('100%')
      if (this.weatherLoading) {
        FeedbackPanel({ kind: 'loading', title: '正在查询天气', message: '从已配置的天气来源读取今日预报。' })
      } else if (this.weatherError.length > 0) {
        FeedbackPanel({ kind: 'error', title: '天气暂不可用', message: this.weatherError,
          actionLabel: '重试查询', onAction: () => this.loadWeather() })
      }
      if (!this.weatherLoading && this.forecast !== null) {
        Text(`${this.forecast.location_label} · ${this.forecast.date}`).fontSize(AppTheme.bodySize)
          .fontColor(AppTheme.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
        if (this.forecast.condition !== null) {
          Text(`${this.currentForecast() ? '' : '非当前有效预报 · '}${this.forecast.condition}`)
            .fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium).fontColor(AppTheme.ink).width('100%')
            .wordBreak(WordBreak.BREAK_WORD)
          Text(this.weatherNumbers()).fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet).width('100%')
            .wordBreak(WordBreak.BREAK_WORD)
        } else {
          Text('暂无可用天气预报，请展开来源查看覆盖范围或获取状态。')
            .fontSize(AppTheme.bodySize).fontColor(AppTheme.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
        }
        EvidencePanel({ evidence: this.forecast.evidence, active: this.active })
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(AppTheme.cardInset)
      .backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
  }

  @Builder
  private Entry(icon: string, title: string, description: string, action: () => void) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 14 }) {
        AppIcon({ name: icon, iconSize: 24, color: AppTheme.actionBlue })
        Column({ space: 5 }) {
          Text(title).fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium)
            .fontColor(AppTheme.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
          Text(description).fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet)
            .width('100%').wordBreak(WordBreak.BREAK_WORD)
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        AppIcon({ name: 'chevron', iconSize: 16, color: AppTheme.quiet })
      }.width('100%')
    }.width('100%').constraintSize({ minHeight: 84 }).padding(AppTheme.cardInset)
      .backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
      .accessibilityText(`${title}，${description}`).onClick(action)
  }

  build() {
    Scroll(this.scroller) {
      Column({ space: AppTheme.sectionGap }) {
        Row({ space: 12 }) {
          Column({ space: 6 }) {
            Text('校园').fontSize(AppTheme.pageTitle).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
            Text(`${this.user.school ?? '尚未配置学校'} · ${this.user.campus ?? '尚未配置校区'}`)
              .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
              .wordBreak(WordBreak.BREAK_WORD)
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Button({ type: ButtonType.Circle }) {
            Text(this.user.display_name.slice(0, 1)).fontSize(18).fontColor(AppTheme.actionBlue)
          }.width(48).height(48).backgroundColor(AppTheme.blueSoft)
            .accessibilityText('打开个人设置').onClick(() => this.onOpenProfile())
        }.width('100%')
        this.WeatherCard()
        Column({ space: 12 }) {
          this.Entry('calendar', '我的课表', '手动维护、预览导入与检查变更', () => this.onOpenTimetable())
          this.Entry('route', '校园导航', '选择地点，查看路线和步行估算', () => this.onOpenRoute())
          this.Entry('classroom', '校园服务', '教室、借阅与个人校园信息', () => this.onOpenServices())
          this.Entry('skills', '能力管理', '查看权限，按需要启用或停用', () => this.onOpenSkills())
          this.Entry('calendar', '数据与连接', '管理课表订阅、校园账号和模型配置', () => this.onOpenProfile())
        }.width('100%')
        Button({ type: ButtonType.Normal }) {
          Row({ space: 12 }) {
            AppIcon({ name: 'agent', iconSize: 24, color: AppTheme.actionBlue })
            Column({ space: 5 }) {
              Text('让 Agent 帮你找').fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium)
                .fontColor(AppTheme.actionBlue).width('100%')
              Text('结合已有课表，先核对再安排').fontSize(AppTheme.metaSize)
                .fontColor(AppTheme.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          }.width('100%')
        }.width('100%').constraintSize({ minHeight: 80 }).padding(AppTheme.cardInset)
          .backgroundColor(AppTheme.blueSoft).borderRadius(AppTheme.cardRadius)
          .onClick(() => this.onOpenAgent('根据我的课表，帮我看看今天需要注意的校园安排。请说明信息来源。'))
        Text('校园信息的覆盖范围以连接的数据源为准。时间安排先预览，确认后再执行。')
          .fontSize(AppTheme.metaSize).fontColor(AppTheme.quiet).width('100%')
          .wordBreak(WordBreak.BREAK_WORD)
      }.width('100%').alignItems(HorizontalAlign.Start)
        .padding({ left: AppTheme.pageInset, right: AppTheme.pageInset, top: 20, bottom: 32 })
    }.width('100%').height('100%').backgroundColor(AppTheme.canvas).scrollBar(BarState.Off)
  }
}
