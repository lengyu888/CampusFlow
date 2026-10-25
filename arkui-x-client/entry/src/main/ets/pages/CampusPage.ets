import { UserProfile, WeatherForecast } from '../model/ApiModels';
import { AppIcon } from '../components/AppIcon';
import { AppTheme } from '../theme/AppTheme';
import { ThemePalette, themePalette } from '../theme/ThemePalette';
import { EvidencePanel } from '../components/EvidencePanel';
import { CampusKnowledgePanel } from '../components/CampusKnowledgePanel';
import { FeedbackPanel } from '../components/FeedbackPanel';
import { InfoDisclosure } from '../components/InfoDisclosure';
import { CampusFlowApi } from '../services/CampusFlowApi';
import { shanghaiDate } from '../utils/DailyAgenda';
import { validWeather, weatherUsable } from '../utils/EvidencePresentation';

// Shared entry shell. Each entry opens the existing native feature page.
@Component
export struct CampusPage {
  @StorageLink('campusflowThemePalette') private palette: ThemePalette = themePalette('paper-green');
  @Watch('profileChanged') @Prop user: UserProfile;
  @Watch('connectionChanged') @Prop baseUrl: string;
  @Watch('connectionChanged') @Prop token: string;
  @Watch('activeChanged') @Prop active: boolean = true;
  @State private knowledgeExpanded: boolean = false;
  @State private weatherExpanded: boolean = false;
  @State private forecast: WeatherForecast | null = null;
  @State private weatherLoading: boolean = false;
  @State private weatherError: string = '';
  @State private now: number = Date.now();
  private pageActive: boolean = false;
  private weatherRevision: number = 0;
  private clock: number = -1;
  private weatherCampus: string = '';
  private presentationScope: string = '';
  onOpenTimetable: () => void = () => {};
  onOpenRoute: () => void = () => {};
  onOpenServices: () => void = () => {};
  onOpenSkills: () => void = () => {};
  onOpenProfile: () => void = () => {};
  onOpenAgent: (prompt: string) => void = () => {};
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void { this.pageActive = true; this.presentationScope = this.campusIdentity(); this.activeChanged(); }
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
  private profileChanged(): void {
    const scope = this.campusIdentity();
    if (this.presentationScope !== scope) { this.knowledgeExpanded = false; this.weatherExpanded = false; this.presentationScope = scope; }
    if (this.weatherCampus !== scope) { this.activeChanged(); }
  }
  private connectionChanged(): void {
    this.knowledgeExpanded = false; this.weatherExpanded = false;
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
    Column({ space: 8 }) {
      Row({ space: 12 }) {
        Text('今日天气').fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium)
          .fontColor(this.palette.ink).layoutWeight(1)
        Button('刷新').constraintSize({ minHeight: 44, minWidth: 44 }).fontSize(this.palette.metaSize)
          .padding({ left: 8, right: 0 }).fontColor(this.palette.accent)
          .backgroundColor(Color.Transparent).enabled(!this.weatherLoading)
          .onClick(() => this.loadWeather())
      }.width('100%')
      if (this.weatherLoading) {
        Text('正在读取今日预报…').fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
      } else if (this.weatherError.length > 0) {
        Text(this.weatherError).fontSize(this.palette.metaSize).fontColor(this.palette.warning).width('100%').wordBreak(WordBreak.BREAK_WORD)
      }
      if (!this.weatherLoading && this.forecast !== null) {
        if (this.forecast.condition !== null) {
          Text(`${this.currentForecast() ? '' : '非当前有效预报 · '}${this.forecast.condition}`)
            .fontSize(24).fontWeight(FontWeight.Medium).fontColor(this.palette.ink).width('100%')
            .wordBreak(WordBreak.BREAK_WORD)
          Text(this.weatherNumbers()).fontSize(this.palette.bodySize).fontColor(this.palette.quiet).width('100%')
            .wordBreak(WordBreak.BREAK_WORD)
        } else {
          Text('暂无可用天气预报，请展开来源查看覆盖范围或获取状态。')
            .fontSize(this.palette.bodySize).fontColor(this.palette.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
        }
        Text(`${this.forecast.location_label} · ${this.forecast.date}`).fontSize(this.palette.metaSize)
          .fontColor(this.palette.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
        Row() {
          Text('城市预报，不读取设备位置').fontSize(this.palette.metaSize).fontColor(this.palette.quiet).layoutWeight(1)
            .wordBreak(WordBreak.BREAK_WORD)
          Button(this.weatherExpanded ? '收起来源' : '来源').constraintSize({ minHeight: 44 }).fontSize(this.palette.metaSize)
            .padding({ left: 8, right: 0 }).fontColor(this.palette.accent).backgroundColor(Color.Transparent)
            .onClick(() => animateTo({ duration: AppTheme.motion(160) }, () => this.weatherExpanded = !this.weatherExpanded))
        }.width('100%')
        if (this.weatherExpanded) { EvidencePanel({ evidence: this.forecast.evidence, active: this.active }) }
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: 20, right: 20, top: 8, bottom: 12 })
      .backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
  }

  @Builder
  private Entry(icon: string, title: string, description: string, action: () => void) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        Stack() {
          AppIcon({ name: icon, iconSize: 20,
            color: icon === 'route' ? this.palette.success : icon === 'classroom' ? this.palette.orange : this.palette.accent })
        }.width(32).height(32)
          .backgroundColor(icon === 'route' ? this.palette.successSoft : icon === 'classroom' ? this.palette.orangeSoft : this.palette.accentSoft)
          .borderRadius(8)
        Column({ space: 3 }) {
          Text(title).fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium)
            .fontColor(this.palette.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
          Text(description).fontSize(this.palette.metaSize).fontColor(this.palette.quiet)
            .width('100%').wordBreak(WordBreak.BREAK_WORD)
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        AppIcon({ name: 'chevron', iconSize: 14, color: this.palette.muted })
      }.width('100%')
    }.width('100%').constraintSize({ minHeight: 68 }).padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .backgroundColor(Color.Transparent).borderRadius(0)
      .accessibilityText(`${title}，${description}`).onClick(action)
  }

  @Builder
  private EntryDivider() {
    Row() { Divider().color(this.palette.line).strokeWidth(0.5) }.width('100%').padding({ left: 60, right: 0 })
  }

  build() {
    Scroll(this.scroller) {
      Column({ space: this.palette.sectionGap }) {
        Row({ space: 12 }) {
          Column({ space: 6 }) {
            Text('校园').fontSize(this.palette.pageTitle).fontWeight(FontWeight.Bold).fontColor(this.palette.ink)
            Text(`${this.user.school ?? '尚未配置学校'} · ${this.user.campus ?? '尚未配置校区'}`)
              .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
              .wordBreak(WordBreak.BREAK_WORD)
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Button({ type: ButtonType.Circle }) {
            Text(this.user.display_name.slice(0, 1)).fontSize(this.palette.sectionTitle).fontColor(this.palette.accent)
          }.width(44).height(44).backgroundColor(this.palette.accentSoft)
            .accessibilityText('打开个人设置').onClick(() => this.onOpenProfile())
        }.width('100%')
        Column({ space: 10 }) {
          Text('校园生活').fontSize(this.palette.sectionTitle).fontWeight(FontWeight.Bold).fontColor(this.palette.ink)
          Column() {
            this.Entry('calendar', '我的课表', '查看课程与导入课表', () => this.onOpenTimetable())
            this.EntryDivider()
            this.Entry('route', '校园导航', '选择地点，查看路线', () => this.onOpenRoute())
            this.EntryDivider()
            this.Entry('classroom', '校园实时服务', '教室、电费、图书馆与校园卡', () => this.onOpenServices())
          }.width('100%').backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
            .clip(true)
        }.width('100%').alignItems(HorizontalAlign.Start)
        this.WeatherCard()
        Button({ type: ButtonType.Normal }) {
          Row({ space: 12 }) {
            Stack() { AppIcon({ name: 'book', iconSize: 20, color: this.palette.accent }) }
              .width(32).height(32).backgroundColor(this.palette.accentSoft).borderRadius(8)
            Column({ space: 5 }) {
              Text('校园指南').fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium).fontColor(this.palette.ink).width('100%')
              Text('图书馆、校园网络等资料').fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            AppIcon({ name: 'chevron', iconSize: 14, color: this.palette.muted })
              .rotate({ angle: this.knowledgeExpanded ? 90 : 0 })
          }.width('100%')
        }.width('100%').constraintSize({ minHeight: 68 }).padding(this.palette.cardInset).backgroundColor(this.palette.surface)
          .borderRadius(this.palette.cardRadius)
          .accessibilityText(`校园指南，${this.knowledgeExpanded ? '已展开' : '已收起'}`)
          .onClick(() => animateTo({ duration: AppTheme.motion(160) }, () => this.knowledgeExpanded = !this.knowledgeExpanded))
        CampusKnowledgePanel({ baseUrl: this.baseUrl, token: this.token, campusScope: this.campusIdentity(), active: this.active && this.knowledgeExpanded })
          .visibility(this.knowledgeExpanded ? Visibility.Visible : Visibility.None)
        Column({ space: 10 }) {
          Text('工具与设置').fontSize(this.palette.sectionTitle).fontWeight(FontWeight.Bold).fontColor(this.palette.ink)
          Column() {
            this.Entry('skills', '能力管理', '查看用途与权限', () => this.onOpenSkills())
            this.EntryDivider()
            this.Entry('person', '数据与连接', '账号、课表与模型设置', () => this.onOpenProfile())
            this.EntryDivider()
            this.Entry('assistant', '问问助手', '结合课表安排校园生活',
              () => this.onOpenAgent('根据我的课表，帮我看看今天需要注意的校园安排。请说明信息来源。'))
          }.width('100%').backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
            .clip(true)
        }.width('100%').alignItems(HorizontalAlign.Start)
        InfoDisclosure({ title: '信息来源与使用说明', message: '校园信息以已连接的数据源为准。天气为城市级预报，不读取设备位置；时间安排须预览确认后执行。' })
      }.width('100%').alignItems(HorizontalAlign.Start)
        .padding({ left: this.palette.pageInset, right: this.palette.pageInset, top: 20, bottom: 32 })
    }.width('100%').height('100%').backgroundColor(this.palette.canvas).scrollBar(BarState.Off).align(Alignment.TopStart)
  }
}
