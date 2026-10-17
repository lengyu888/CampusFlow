import { CampusDataPlace, CampusDataSnapshot, CampusRoute } from '../model/ApiModels';
import { RouteMap } from '../components/RouteMap';
import { CampusFlowApi } from '../services/CampusFlowApi';
import { AppTheme } from '../theme/AppTheme';
import { AppIcon } from '../components/AppIcon';
import { FeedbackPanel } from '../components/FeedbackPanel';

class CampusSelectOption implements SelectOption {
  value: ResourceStr;

  constructor(value: string) {
    this.value = value;
  }
}

@Component
export struct RoutePage {
  @Prop baseUrl: string;
  @Prop token: string;
  @Watch('activeChanged') @Prop active: boolean = true;
  onBack: () => void = () => {};
  @State private places: CampusDataPlace[] = [];
  @State private originIndex: number = 0;
  @State private destinationIndex: number = 0;
  @State private route: CampusRoute | null = null;
  @State private loading: boolean = true;
  @State private routeLoading: boolean = false;
  @State private errorText: string = '';
  @State private placesError: string = '';
  private scroller: Scroller = new Scroller();
  private pageActive: boolean = true;
  private placesRevision: number = 0;
  private routeRevision: number = 0;
  private placesLoaded: boolean = false;

  aboutToAppear(): void {
    this.pageActive = true;
    this.activeChanged();
  }

  aboutToDisappear(): void {
    this.pageActive = false;
    this.invalidateRequests();
  }

  private invalidateRequests(): void {
    this.placesRevision++;
    this.routeRevision++;
    this.loading = false;
    this.routeLoading = false;
  }

  private activeChanged(): void {
    if (!this.active) { this.invalidateRequests(); return; }
    if (!this.placesLoaded) { this.loadPlaces(); }
  }

  private async loadPlaces(): Promise<void> {
    if (!this.active || !this.pageActive || this.loading && this.placesRevision > 0) { return; }
    const revision = ++this.placesRevision;
    const token = this.token;
    const baseUrl = this.baseUrl;
    const originId = this.places[this.originIndex]?.place_id ?? '';
    const destinationId = this.places[this.destinationIndex]?.place_id ?? '';
    this.loading = true;
    this.placesError = '';
    try {
      const data: CampusDataSnapshot = await new CampusFlowApi(baseUrl, token).campusData();
      if (!this.pageActive || !this.active || revision !== this.placesRevision || token !== this.token || baseUrl !== this.baseUrl) { return; }
      this.places = data.places;
      this.placesLoaded = true;
      const origin = this.places.findIndex((item: CampusDataPlace) => item.place_id === originId);
      const destination = this.places.findIndex((item: CampusDataPlace) => item.place_id === destinationId);
      this.originIndex = origin >= 0 ? origin : 0;
      this.destinationIndex = destination >= 0 ? destination : (this.places.length > 1 ? 1 : 0);
      this.invalidateRoute();
    } catch {
      if (this.pageActive && this.active && revision === this.placesRevision && token === this.token && baseUrl === this.baseUrl) {
        this.placesError = '暂时无法读取校园地点，请检查连接后重试。';
      }
    } finally {
      if (this.pageActive && this.active && revision === this.placesRevision && token === this.token && baseUrl === this.baseUrl) { this.loading = false; }
    }
  }

  private options(): Array<SelectOption> {
    return this.places.map((place: CampusDataPlace) => new CampusSelectOption(place.name));
  }

  private invalidateRoute(): void {
    this.routeRevision++;
    this.route = null;
    this.routeLoading = false;
    this.errorText = '';
  }

  private choosePlace(index: number, origin: boolean): void {
    if (!Number.isInteger(index) || index < 0 || index >= this.places.length) { return; }
    if (origin) { this.originIndex = index; } else { this.destinationIndex = index; }
    this.invalidateRoute();
  }

  private swap(): void {
    const previous = this.originIndex;
    this.originIndex = this.destinationIndex;
    this.destinationIndex = previous;
    this.invalidateRoute();
  }

  private async createRoute(): Promise<void> {
    if (!this.active || !this.pageActive || this.loading || this.routeLoading) { return; }
    const origin = this.places[this.originIndex];
    const destination = this.places[this.destinationIndex];
    if (origin === undefined || destination === undefined || origin.place_id === destination.place_id) {
      this.errorText = '请选择两个不同的地点。';
      return;
    }
    const revision = ++this.routeRevision;
    const token = this.token;
    const baseUrl = this.baseUrl;
    this.errorText = '';
    this.route = null;
    this.routeLoading = true;
    try {
      const route = await new CampusFlowApi(baseUrl, token).campusRoute(origin.name, destination.name);
      if (this.pageActive && this.active && revision === this.routeRevision && token === this.token && baseUrl === this.baseUrl) { this.route = route; }
    } catch {
      if (this.pageActive && this.active && revision === this.routeRevision && token === this.token && baseUrl === this.baseUrl) {
        this.errorText = '暂时无法生成路线。起终点已保留，可以重试。';
      }
    } finally {
      if (this.pageActive && this.active && revision === this.routeRevision && token === this.token && baseUrl === this.baseUrl) { this.routeLoading = false; }
    }
  }

  build() {
    Column() {
      Row({ space: 12 }) {
        Button() {
          AppIcon({ name: 'back', iconSize: 22, color: AppTheme.blue })
        }.width(48).height(48).backgroundColor(AppTheme.surface).borderRadius(22)
          .accessibilityText('返回上一页').onClick(() => this.onBack())
        Column({ space: 3 }) {
          Text('校园导航').fontSize(28).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
          Text('查看校园步行路线').fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      }.width('100%').padding({ left: 18, right: 18, top: 12, bottom: 12 })

      Scroll(this.scroller) {
        Column({ space: 16 }) {
          Column({ space: 12 }) {
            Row() {
              Text('选择路线').fontSize(18).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
              Blank()
              Text(`${this.places.length} 个地点`).fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary)
            }.width('100%')

            if (this.loading) {
              FeedbackPanel({ kind: 'loading', title: '正在读取校园地点', message: '保留当前选择，读取完成后可生成路线。' })
            } else if (this.placesError.length > 0) {
              FeedbackPanel({ kind: 'error', title: '地点暂不可用', message: this.placesError,
                actionLabel: '重试读取地点', onAction: () => this.loadPlaces() })
            } else if (this.places.length < 2) {
              FeedbackPanel({ kind: 'empty', title: '地点数据不足', message: '需要至少两个可用地点才能生成路线。',
                actionLabel: '重新读取', onAction: () => this.loadPlaces() })
            } else {
              Column({ space: 6 }) {
                Text('起点').fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%')
                Select(this.options()).selected(this.originIndex)
                  .value(this.places[this.originIndex]?.name ?? '')
                  .fontColor(AppTheme.ink).backgroundColor(AppTheme.field)
                  .optionBgColor(AppTheme.surface).optionFontColor(AppTheme.ink)
                  .selectedOptionBgColor(AppTheme.blueSoft).selectedOptionFontColor(AppTheme.blue)
                  .borderRadius(13).width('100%').constraintSize({ minHeight: 48 })
                  .onSelect((index: number) => {
                    this.choosePlace(index, true);
                  })
              }.width('100%').alignItems(HorizontalAlign.Start)

              Button('交换起终点').constraintSize({ minHeight: 48 }).fontSize(AppTheme.metaSize).fontColor(AppTheme.blue)
                .backgroundColor(AppTheme.blueSoft).borderRadius(12).onClick(() => {
                  this.getUIContext().animateTo({ duration: AppTheme.motion(200), curve: Curve.EaseOut }, () => this.swap());
                })

              Column({ space: 6 }) {
                Text('终点').fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%')
                Select(this.options()).selected(this.destinationIndex)
                  .value(this.places[this.destinationIndex]?.name ?? '')
                  .fontColor(AppTheme.ink).backgroundColor(AppTheme.field)
                  .optionBgColor(AppTheme.surface).optionFontColor(AppTheme.ink)
                  .selectedOptionBgColor(AppTheme.blueSoft).selectedOptionFontColor(AppTheme.blue)
                  .borderRadius(13).width('100%').constraintSize({ minHeight: 48 })
                  .onSelect((index: number) => {
                    this.choosePlace(index, false);
                  })
              }.width('100%').alignItems(HorizontalAlign.Start)

              Button(this.routeLoading ? '正在计算道路…' : '生成路线图').width('100%').constraintSize({ minHeight: 48 })
                .fontSize(AppTheme.metaSize).fontWeight(FontWeight.Bold).fontColor(AppTheme.surface)
                .backgroundColor(AppTheme.blue).borderRadius(15).enabled(!this.routeLoading)
                .onClick(() => this.createRoute())
            }

            if (this.errorText.length > 0) {
              FeedbackPanel({ kind: 'error', title: '路线尚未生成', message: this.errorText,
                actionLabel: '重试生成路线', busy: this.routeLoading, onAction: () => this.createRoute() })
            }
          }.width('100%').padding(18).backgroundColor(AppTheme.surface).borderRadius(18)

          if (this.route !== null) {
            RouteMap({ route: this.route as CampusRoute })
          } else if (!this.loading && !this.routeLoading && this.errorText.length === 0 && this.placesError.length === 0 && this.places.length >= 2) {
            Column({ space: 7 }) {
              AppIcon({ name: 'route', iconSize: 32, color: AppTheme.blue })
              Text('选择两个地点').fontSize(17).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
              Text('路线按已有校园地图生成，步行时间为估算；请以现场道路与通行情况为准。')
                .fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).textAlign(TextAlign.Center)
            }.width('100%').padding(24).backgroundColor(AppTheme.blueSoft).borderRadius(18)
          }
        }.width('100%').alignItems(HorizontalAlign.Start).justifyContent(FlexAlign.Start)
          .padding({ left: 18, right: 18, top: 4, bottom: 32 })
      }.layoutWeight(1).width('100%').align(Alignment.TopStart)
    }.width('100%').height('100%').alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Start).backgroundColor(AppTheme.bg)
  }
}
