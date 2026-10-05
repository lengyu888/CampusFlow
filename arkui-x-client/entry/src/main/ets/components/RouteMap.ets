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
    this.context.fillStyle = '#EAF5E5';
    this.context.fillRect(0, 0, width, height);

    // The vector base follows the uploaded HDU Xiasha campus map: the living
    // area is north of Xuelin Street and the teaching area is in the south.
    this.context.fillStyle = '#F1E5D4';
    this.context.fillRect(0, 0, width, 62);
    this.context.fillStyle = '#D7DCCF';
    this.context.fillRect(0, 62, width, 12);
    this.context.fillStyle = '#CBE9F2';
    this.context.fillRect(0, 222, width, 8);

    this.context.strokeStyle = '#D6DFC9';
    this.context.lineWidth = 7;
    for (let y = 104; y < 220; y += 48) {
      this.context.beginPath();
      this.context.moveTo(0, y);
      this.context.lineTo(width, y);
      this.context.stroke();
    }
    for (let x = 70; x < width; x += 64) {
      this.context.beginPath();
      this.context.moveTo(x, 74);
      this.context.lineTo(x, 222);
      this.context.stroke();
    }

    this.context.fillStyle = '#F1BDBD';
    this.context.fillRect(112, 114, 42, 28);
    this.context.fillRect(178, 91, 44, 27);
    this.context.fillRect(244, 124, 42, 28);
    this.context.fillStyle = '#F4D3A5';
    this.context.fillRect(135, 23, 46, 22);
    this.context.fillRect(259, 19, 48, 24);
    this.context.fillStyle = '#B9D9A8';
    this.context.fillRect(24, 122, 55, 62);
    this.context.fillStyle = '#FFF7EA';
    this.context.fillRect(150, 157, 58, 30);

    this.context.font = '10px sans-serif';
    this.context.fillStyle = '#526052';
    this.context.fillText('生活区', 9, 18);
    this.context.fillText('学林街', 8, 71);
    this.context.fillText('体育场', 31, 154);
    this.context.fillText('六教', 121, 132);
    this.context.fillText('图书馆', 183, 108);
    this.context.fillText('东门', 296, 151);
    this.context.fillText('南大门', 144, 240);

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

      Text('杭电下沙校区 · 基于已确认校园地图数据绘制')
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
