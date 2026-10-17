import { CampusRoute } from '../model/ApiModels';
import { ROUTE_MAP_ASPECT_RATIO, RouteMapGeometry, routeMapGeometry, routeScreenPoint } from '../utils/RouteGeometry';

@Component
export struct RouteMap {
  @Watch('routeChanged') @Prop route: CampusRoute;
  @State private geometry: RouteMapGeometry = routeMapGeometry(0);
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private ready: boolean = false;

  private drawRoute(): void {
    if (!this.ready || this.geometry.width === 0) {
      return;
    }
    const geometry = this.geometry;
    this.context.clearRect(0, 0, this.context.width, this.context.height);

    if (this.route.path.length === 0) {
      return;
    }
    const first = this.route.path[0];
    const firstPoint = routeScreenPoint(first.x, first.y, geometry);
    this.context.strokeStyle = '#315BFF';
    this.context.lineWidth = 4 * geometry.scale;
    this.context.lineJoin = 'round';
    this.context.lineCap = 'round';
    this.context.shadowColor = '#FFFFFF';
    this.context.shadowBlur = 5 * geometry.scale;
    this.context.beginPath();
    this.context.moveTo(firstPoint.x, firstPoint.y);
    for (let index = 1; index < this.route.path.length; index++) {
      const point = this.route.path[index];
      const screenPoint = routeScreenPoint(point.x, point.y, geometry);
      this.context.lineTo(screenPoint.x, screenPoint.y);
    }
    this.context.stroke();
    this.context.shadowBlur = 0;

    for (let index = 0; index < this.route.path.length; index++) {
      const point = this.route.path[index];
      const screenPoint = routeScreenPoint(point.x, point.y, geometry);
      const radius = (index === 0 || index === this.route.path.length - 1 ? 7 : 3.5) * geometry.scale;
      this.context.beginPath();
      this.context.fillStyle = index === 0 ? '#171A22' : (index === this.route.path.length - 1 ? '#FF6B4A' : '#FFFFFF');
      this.context.arc(screenPoint.x, screenPoint.y, radius, 0, Math.PI * 2);
      this.context.fill();
      this.context.strokeStyle = '#315BFF';
      this.context.lineWidth = 2 * geometry.scale;
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
          .width(this.geometry.width)
          .height(this.geometry.imageHeight)
          .objectFit(ImageFit.Fill)
        Canvas(this.context)
          .width('100%')
          .height('100%')
          .onReady(() => {
            // onReady runs after initial layout and every Canvas size change.
            // Read its actual width so window resizing keeps the image aligned.
            this.geometry = routeMapGeometry(this.context.width);
            this.ready = true;
            this.drawRoute();
          })
      }
      .width('100%')
      .aspectRatio(ROUTE_MAP_ASPECT_RATIO)
      .clip(true)
      .borderRadius(22)

      Text('原图：HDUHELP 杭电地图 · 蓝色路线为 CampusFlow 叠加层')
        .fontSize(10).fontColor('#8A90A0').width('100%')

      Row({ space: 8 }) {
        Column({ space: 4 }) {
          Text(`${this.route.origin.name} → ${this.route.destination.name}`)
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor('#171A22')
            .width('100%')
          Text(`估算 ${this.route.estimated_distance_meters} 米 · 步行约 ${this.route.total_minutes} 分钟`)
            .fontSize(13)
            .fontColor('#697083')
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Text('示意路线')
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
