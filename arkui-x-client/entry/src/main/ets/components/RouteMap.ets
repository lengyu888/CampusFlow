import { CampusRoute } from '../model/ApiModels';

@Component
export struct RouteMap {
  @Watch('routeChanged') @Prop route: CampusRoute;
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);

  private drawRoute(): void {
    const width = 330;
    const height = 372;
    // Calibrated from the untouched 1279 × 2155 HDUHELP bitmap. The main
    // campus panel spans x=43..1185 and y=209..1368 in the source image.
    const mapLeft = 11.1;
    const mapTop = 53.9;
    const mapWidth = 294.6;
    const mapHeight = 299.2;
    this.context.clearRect(0, 0, width, height);

    if (this.route.path.length === 0) {
      return;
    }
    const first = this.route.path[0];
    const firstX = mapLeft + first.x / 100 * mapWidth;
    const firstY = mapTop + first.y / 74 * mapHeight;
    this.context.strokeStyle = '#315BFF';
    this.context.lineWidth = 4;
    this.context.lineJoin = 'round';
    this.context.lineCap = 'round';
    this.context.shadowColor = '#FFFFFF';
    this.context.shadowBlur = 5;
    this.context.beginPath();
    this.context.moveTo(firstX, firstY);
    for (let index = 1; index < this.route.path.length; index++) {
      const point = this.route.path[index];
      this.context.lineTo(mapLeft + point.x / 100 * mapWidth, mapTop + point.y / 74 * mapHeight);
    }
    this.context.stroke();
    this.context.shadowBlur = 0;

    for (let index = 0; index < this.route.path.length; index++) {
      const point = this.route.path[index];
      const x = mapLeft + point.x / 100 * mapWidth;
      const y = mapTop + point.y / 74 * mapHeight;
      this.context.beginPath();
      this.context.fillStyle = index === 0 ? '#171A22' : (index === this.route.path.length - 1 ? '#FF6B4A' : '#FFFFFF');
      this.context.arc(x, y, index === 0 || index === this.route.path.length - 1 ? 7 : 3.5, 0, Math.PI * 2);
      this.context.fill();
      this.context.strokeStyle = '#315BFF';
      this.context.lineWidth = 2;
      this.context.stroke();
    }
  }

  private routeChanged(): void {
    this.drawRoute();
  }

  build() {
    Column({ space: 12 }) {
      Stack({ alignContent: Alignment.TopStart }) {
        Image($r('app.media.hdu_campus_map_original'))
          .width(330)
          .height(556)
          .objectFit(ImageFit.Fill)
        Canvas(this.context)
          .width(330)
          .height(372)
          .onReady(() => this.drawRoute())
      }
      .width('100%')
      .height(372)
      .clip(true)
      .borderRadius(22)

      Text('原图：HDUHELP 杭电地图 · 蓝色路线为 CampusFlow 叠加层')
        .fontSize(10).fontColor('#8A90A0').width('100%')

      Row() {
        Column({ space: 4 }) {
          Text(`${this.route.origin.name} → ${this.route.destination.name}`)
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor('#171A22')
          Text(`${this.route.estimated_distance_meters} 米 · 步行约 ${this.route.total_minutes} 分钟`)
            .fontSize(13)
            .fontColor('#697083')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Text('路线已生成')
          .fontSize(11)
          .fontColor('#315BFF')
          .backgroundColor('#E9EEFF')
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .borderRadius(20)
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor('#FFFFFF')
    .borderRadius(24)
  }
}
