import { CampusDataPlace, CampusDataSnapshot, CampusRoute } from '../model/ApiModels';
import { RouteMap } from '../components/RouteMap';
import { CampusFlowApi } from '../services/CampusFlowApi';
import { AppTheme } from '../theme/AppTheme';
import { AppIcon } from '../components/AppIcon';

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
  onBack: () => void = () => {};
  @State private places: CampusDataPlace[] = [];
  @State private originIndex: number = 0;
  @State private destinationIndex: number = 0;
  @State private route: CampusRoute | null = null;
  @State private loading: boolean = true;
  @State private routeLoading: boolean = false;
  @State private errorText: string = '';

  aboutToAppear(): void {
    this.loadPlaces();
  }

  private async loadPlaces(): Promise<void> {
    try {
      const data: CampusDataSnapshot = await new CampusFlowApi(this.baseUrl, this.token).campusData();
      this.places = data.places;
      const origin = this.places.findIndex((item) => item.place_id === 'teaching-6');
      const destination = this.places.findIndex((item) => item.place_id === 'cainiao-station');
      this.originIndex = origin >= 0 ? origin : 0;
      this.destinationIndex = destination >= 0 ? destination : Math.min(1, this.places.length - 1);
    } catch (error) {
      this.errorText = `校园地点加载失败：${error}`;
    } finally {
      this.loading = false;
    }
  }

  private options(): Array<SelectOption> {
    return this.places.map((place: CampusDataPlace) => new CampusSelectOption(place.name));
  }

  private swap(): void {
    const previous = this.originIndex;
    this.originIndex = this.destinationIndex;
    this.destinationIndex = previous;
    this.route = null;
  }

  private async createRoute(): Promise<void> {
    if (this.places.length === 0 || this.originIndex === this.destinationIndex) {
      this.errorText = '请选择不同的起点和终点。';
      return;
    }
    this.errorText = '';
    this.routeLoading = true;
    try {
      this.route = await new CampusFlowApi(this.baseUrl, this.token).campusRoute(
        this.places[this.originIndex].name,
        this.places[this.destinationIndex].name
      );
    } catch (error) {
      this.route = null;
      this.errorText = `路线生成失败：${error}`;
    } finally {
      this.routeLoading = false;
    }
  }

  build() {
    Column() {
      Row({ space: 12 }) {
        Button() {
          AppIcon({ name: 'back', iconSize: 22, color: AppTheme.blue })
        }.width(44).height(44).backgroundColor(AppTheme.surface).borderRadius(22)
          .onClick(() => this.onBack())
        Column({ space: 3 }) {
          Text('校园导航').fontSize(28).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
          Text('查看校园步行路线').fontSize(14).fontColor(AppTheme.secondary)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      }.width('100%').padding({ left: 18, right: 18, top: 18, bottom: 12 })

      Scroll() {
        Column({ space: 16 }) {
          Column({ space: 12 }) {
            Row() {
              Text('选择路线').fontSize(18).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
              Blank()
              Text(`${this.places.length} 个地点`).fontSize(13).fontColor(AppTheme.secondary)
            }.width('100%')

            if (this.loading) {
              Text('正在加载地点…').fontSize(15).fontColor(AppTheme.secondary).width('100%')
            } else {
              Column({ space: 6 }) {
                Text('起点').fontSize(12).fontColor(AppTheme.secondary).width('100%')
                Select(this.options()).selected(this.originIndex)
                  .value(this.places[this.originIndex]?.name ?? '')
                  .fontColor(AppTheme.ink).backgroundColor(AppTheme.field)
                  .optionBgColor(AppTheme.surface).optionFontColor(AppTheme.ink)
                  .selectedOptionBgColor(AppTheme.blueSoft).selectedOptionFontColor(AppTheme.blue)
                  .borderRadius(13).width('100%').height(46)
                  .onSelect((index: number) => {
                    this.originIndex = index;
                    this.route = null;
                  })
              }.width('100%').alignItems(HorizontalAlign.Start)

              Button('交换起终点').height(44).fontSize(14).fontColor(AppTheme.blue)
                .backgroundColor(AppTheme.blueSoft).borderRadius(12).onClick(() => {
                  this.getUIContext().animateTo({ duration: AppTheme.motion(200), curve: Curve.EaseOut }, () => this.swap());
                })

              Column({ space: 6 }) {
                Text('终点').fontSize(12).fontColor(AppTheme.secondary).width('100%')
                Select(this.options()).selected(this.destinationIndex)
                  .value(this.places[this.destinationIndex]?.name ?? '')
                  .fontColor(AppTheme.ink).backgroundColor(AppTheme.field)
                  .optionBgColor(AppTheme.surface).optionFontColor(AppTheme.ink)
                  .selectedOptionBgColor(AppTheme.blueSoft).selectedOptionFontColor(AppTheme.blue)
                  .borderRadius(13).width('100%').height(46)
                  .onSelect((index: number) => {
                    this.destinationIndex = index;
                    this.route = null;
                  })
              }.width('100%').alignItems(HorizontalAlign.Start)

              Button(this.routeLoading ? '正在计算道路…' : '生成路线图').width('100%').height(46)
                .fontSize(14).fontWeight(FontWeight.Bold).fontColor(AppTheme.surface)
                .backgroundColor(AppTheme.blue).borderRadius(15).enabled(!this.routeLoading)
                .onClick(() => this.createRoute())
            }

            if (this.errorText.length > 0) {
              Text(this.errorText).fontSize(14).fontColor(AppTheme.red).width('100%')
            }
          }.width('100%').padding(18).backgroundColor(AppTheme.surface).borderRadius(18)

          if (this.route !== null) {
            RouteMap({ route: this.route as CampusRoute })
          } else if (!this.loading && this.errorText.length === 0) {
            Column({ space: 7 }) {
              AppIcon({ name: 'route', iconSize: 32, color: AppTheme.blue })
              Text('选择两个地点').fontSize(17).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
              Text('路线将在你上传的杭电原地图上绘制，并沿校园道路转折。')
                .fontSize(14).fontColor(AppTheme.secondary).textAlign(TextAlign.Center)
            }.width('100%').padding(24).backgroundColor(AppTheme.blueSoft).borderRadius(18)
          }
        }.width('100%').alignItems(HorizontalAlign.Start).justifyContent(FlexAlign.Start)
          .padding({ left: 18, right: 18, top: 4, bottom: 32 })
      }.layoutWeight(1).width('100%').align(Alignment.TopStart)
    }.width('100%').height('100%').alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Start).backgroundColor(AppTheme.bg)
  }
}
