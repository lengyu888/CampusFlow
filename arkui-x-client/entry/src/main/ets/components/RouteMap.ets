import { CampusRoute } from '../model/ApiModels';

@Component
export struct RouteMap {
  @Prop route: CampusRoute;
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);

  private drawRoute(): void {
    const width = 330;
    const height = 244;
    this.context.clearRect(0, 0, width, height);
    this.context.fillStyle = '#F0F4E9';
    this.context.fillRect(0, 0, width, height);

    this.context.strokeStyle = '#D8DECF';
    this.context.lineWidth = 10;
    for (let y = 42; y < height; y += 58) {
      this.context.beginPath();
      this.context.moveTo(0, y);
      this.context.lineTo(width, y);
      this.context.stroke();
    }
    for (let x = 48; x < width; x += 72) {
      this.context.beginPath();
      this.context.moveTo(x, 0);
      this.context.lineTo(x, height);
      this.context.stroke();
    }

    if (this.route.path.length === 0) {
      return;
    }
    this.context.strokeStyle = '#315BFF';
    this.context.lineWidth = 5;
    this.context.lineJoin = 'round';
    this.context.lineCap = 'round';
    this.context.beginPath();
    this.context.moveTo(this.route.path[0].x * 3.3, this.route.path[0].y * 3.2);
    for (let index = 1; index < this.route.path.length; index++) {
      this.context.lineTo(this.route.path[index].x * 3.3, this.route.path[index].y * 3.2);
    }
    this.context.stroke();

    for (let index = 0; index < this.route.path.length; index++) {
      const point = this.route.path[index];
      this.context.beginPath();
      this.context.fillStyle = index === 0 ? '#171A22' : (index === this.route.path.length - 1 ? '#FF6B4A' : '#FFFFFF');
      this.context.arc(point.x * 3.3, point.y * 3.2, index === 0 || index === this.route.path.length - 1 ? 7 : 4,
        0, Math.PI * 2);
      this.context.fill();
      this.context.strokeStyle = '#315BFF';
      this.context.lineWidth = 2;
      this.context.stroke();
    }
  }

  build() {
    Column({ space: 12 }) {
      Stack() {
        Canvas(this.context)
          .width(330)
          .height(244)
          .onReady(() => this.drawRoute())
      }
      .width('100%')
      .height(244)
      .clip(true)
      .borderRadius(22)

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
