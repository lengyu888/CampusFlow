import { CampusDataPlace, CampusDataSnapshot, CampusRoute } from '../model/ApiModels';
import { RouteMap } from '../components/RouteMap';
import { CampusFlowApi } from '../services/CampusFlowApi';

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
        Button('‹').width(42).height(42).fontSize(26).fontColor('#171A22')
          .backgroundColor('#FFFFFF').borderRadius(14).onClick(() => this.onBack())
        Column({ space: 3 }) {
          Text('校园导航').fontSize(24).fontWeight(FontWeight.Bold).fontColor('#171A22')
          Text('路线沿原图校园道路吸附').fontSize(12).fontColor('#7B8292')
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Text('HDU').fontSize(11).fontWeight(FontWeight.Bold).fontColor('#315BFF')
          .padding({ left: 11, right: 11, top: 7, bottom: 7 })
          .backgroundColor('#E9EEFF').borderRadius(14)
      }.width('100%').padding({ left: 18, right: 18, top: 18, bottom: 12 })

      Scroll() {
        Column({ space: 16 }) {
          Column({ space: 12 }) {
            Row() {
              Text('选择路线').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#171A22')
              Blank()
              Text(`${this.places.length} 个地点`).fontSize(11).fontColor('#7B8292')
            }.width('100%')

            if (this.loading) {
              Text('正在加载地点…').fontSize(13).fontColor('#7B8292').width('100%')
            } else {
              Column({ space: 6 }) {
                Text('起点').fontSize(10).fontColor('#8A90A0').width('100%')
                Select(this.options()).selected(this.originIndex)
                  .value(this.places[this.originIndex]?.name ?? '')
                  .fontColor('#171A22').backgroundColor('#F4F6FA')
                  .optionBgColor('#FFFFFF').optionFontColor('#171A22')
                  .selectedOptionBgColor('#E9EEFF').selectedOptionFontColor('#315BFF')
                  .borderRadius(13).width('100%').height(46)
                  .onSelect((index: number) => {
                    this.originIndex = index;
                    this.route = null;
                  })
              }.width('100%').alignItems(HorizontalAlign.Start)

              Button('⇅  交换起终点').height(34).fontSize(11).fontColor('#315BFF')
                .backgroundColor('#E9EEFF').borderRadius(12).onClick(() => this.swap())

              Column({ space: 6 }) {
                Text('终点').fontSize(10).fontColor('#8A90A0').width('100%')
                Select(this.options()).selected(this.destinationIndex)
                  .value(this.places[this.destinationIndex]?.name ?? '')
                  .fontColor('#171A22').backgroundColor('#F4F6FA')
                  .optionBgColor('#FFFFFF').optionFontColor('#171A22')
                  .selectedOptionBgColor('#E9EEFF').selectedOptionFontColor('#315BFF')
                  .borderRadius(13).width('100%').height(46)
                  .onSelect((index: number) => {
                    this.destinationIndex = index;
                    this.route = null;
                  })
              }.width('100%').alignItems(HorizontalAlign.Start)

              Button(this.routeLoading ? '正在计算道路…' : '生成路线图').width('100%').height(46)
                .fontSize(14).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
                .backgroundColor('#171A22').borderRadius(15).enabled(!this.routeLoading)
                .onClick(() => this.createRoute())
            }

            if (this.errorText.length > 0) {
              Text(this.errorText).fontSize(12).fontColor('#C53D3D').width('100%')
            }
          }.width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(22)

          if (this.route !== null) {
            RouteMap({ route: this.route as CampusRoute })
          } else if (!this.loading && this.errorText.length === 0) {
            Column({ space: 7 }) {
              Text('选择两个地点').fontSize(17).fontWeight(FontWeight.Bold).fontColor('#171A22')
              Text('路线将在你上传的杭电原地图上绘制，并沿校园道路转折。')
                .fontSize(12).fontColor('#7B8292').textAlign(TextAlign.Center)
            }.width('100%').padding(24).backgroundColor('#EEF2FF').borderRadius(22)
          }
        }.width('100%').padding({ left: 18, right: 18, top: 4, bottom: 32 })
      }.layoutWeight(1).width('100%')
    }.width('100%').height('100%').backgroundColor('#F5F7FB')
  }
}
