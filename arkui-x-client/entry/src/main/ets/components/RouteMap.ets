import { CampusRoute } from '../model/ApiModels';
import { ROUTE_MAP_ASPECT_RATIO, RouteMapGeometry, routeMapGeometry, routeScreenPoint } from '../utils/RouteGeometry';
import { AppTheme } from '../theme/AppTheme';

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
    this.context.strokeStyle = AppTheme.accent;
    this.context.lineWidth = 4 * geometry.scale;
    this.context.lineJoin = 'round';
    this.context.lineCap = 'round';
    this.context.shadowColor = AppTheme.surface;
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
      this.context.fillStyle = index === 0 ? AppTheme.ink :
        (index === this.route.path.length - 1 ? AppTheme.terracotta : AppTheme.surface);
      this.context.arc(screenPoint.x, screenPoint.y, radius, 0, Math.PI * 2);
      this.context.fill();
      this.context.strokeStyle = AppTheme.accent;
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
      .borderRadius(AppTheme.controlRadius)

      Text('原图：HDUHELP 杭电地图 · 墨绿路线为行简示意叠加层')
        .fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)

      Row({ space: 8 }) {
        Column({ space: 4 }) {
          Text(`${this.route.origin.name} → ${this.route.destination.name}`)
            .fontSize(AppTheme.bodySize)
            .fontWeight(FontWeight.Medium)
            .fontColor(AppTheme.ink)
            .width('100%').wordBreak(WordBreak.BREAK_WORD)
          Text(`估算 ${this.route.estimated_distance_meters} 米 · 步行约 ${this.route.total_minutes} 分钟`)
            .fontSize(AppTheme.metaSize)
            .fontColor(AppTheme.secondary)
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Text('示意路线')
          .fontSize(AppTheme.metaSize)
          .fontColor(AppTheme.accent)
          .backgroundColor(AppTheme.accentSoft)
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .borderRadius(8)
      }
      .width('100%')
    }
    .width('100%')
    .padding(AppTheme.cardInset)
    .backgroundColor(AppTheme.surface)
    .borderRadius(AppTheme.cardRadius)
  }
}
