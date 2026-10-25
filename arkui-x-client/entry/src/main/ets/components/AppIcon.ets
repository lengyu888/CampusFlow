import { AppTheme } from '../theme/AppTheme';
import { ThemePalette, themePalette } from '../theme/ThemePalette';

// One 24-unit vector grid keeps icon weight consistent across native platforms.
@Component
export struct AppIcon {
  @Watch('redraw') @StorageLink('campusflowThemePalette') private palette: ThemePalette = themePalette('paper-green');
  @Watch('redraw') @Prop name: string = 'assistant';
  @Watch('redraw') @Prop iconSize: number = 24;
  @Watch('redraw') @Prop color: string = '';
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private ready: boolean = false;

  private line(points: number[][]): void {
    if (points.length < 2) {
      return;
    }
    this.context.moveTo(points[0][0], points[0][1]);
    for (let index = 1; index < points.length; index++) {
      this.context.lineTo(points[index][0], points[index][1]);
    }
  }

  private roundedBox(x: number, y: number, width: number, height: number): void {
    const radius = 2;
    this.context.moveTo(x + radius, y);
    this.context.lineTo(x + width - radius, y);
    this.context.quadraticCurveTo(x + width, y, x + width, y + radius);
    this.context.lineTo(x + width, y + height - radius);
    this.context.quadraticCurveTo(x + width, y + height, x + width - radius, y + height);
    this.context.lineTo(x + radius, y + height);
    this.context.quadraticCurveTo(x, y + height, x, y + height - radius);
    this.context.lineTo(x, y + radius);
    this.context.quadraticCurveTo(x, y, x + radius, y);
  }

  private trace(): void {
    switch (this.name) {
      case 'assistant':
      case 'agent':
        this.roundedBox(3, 3, 18, 14);
        this.line([[5, 17], [5, 21], [10, 17]]);
        this.line([[7, 8], [17, 8]]);
        this.line([[7, 12], [14, 12]]);
        break;
      case 'home':
        this.line([[3, 10], [12, 3], [21, 10]]);
        this.line([[5, 9], [5, 21], [10, 21], [10, 15], [14, 15], [14, 21], [19, 21], [19, 9]]);
        break;
      case 'calendar':
        this.roundedBox(3, 5, 18, 16);
        this.line([[3, 10], [21, 10]]);
        this.line([[7, 3], [7, 7]]);
        this.line([[17, 3], [17, 7]]);
        this.line([[7, 14], [9, 14]]);
        this.line([[13, 14], [15, 14]]);
        this.line([[7, 18], [9, 18]]);
        break;
      case 'skills':
        this.line([[12, 2], [21, 7], [12, 12], [3, 7], [12, 2]]);
        this.line([[3, 12], [12, 17], [21, 12]]);
        this.line([[3, 17], [12, 22], [21, 17]]);
        break;
      case 'person':
        this.context.moveTo(16, 7);
        this.context.arc(12, 7, 4, 0, Math.PI * 2);
        this.context.moveTo(4, 21);
        this.context.lineTo(4, 19);
        this.context.quadraticCurveTo(4, 14, 12, 14);
        this.context.quadraticCurveTo(20, 14, 20, 19);
        this.context.lineTo(20, 21);
        break;
      case 'route':
        this.context.moveTo(7, 6);
        this.context.arc(5, 6, 2, 0, Math.PI * 2);
        this.context.moveTo(21, 18);
        this.context.arc(19, 18, 2, 0, Math.PI * 2);
        this.context.moveTo(9, 6);
        this.context.lineTo(16, 6);
        this.context.quadraticCurveTo(21, 6, 21, 10);
        this.context.quadraticCurveTo(21, 14, 15, 14);
        this.context.lineTo(8, 14);
        this.context.quadraticCurveTo(3, 14, 3, 20);
        break;
      case 'chevron': this.line([[9, 5], [16, 12], [9, 19]]); break;
      case 'back': this.line([[15, 4], [7, 12], [15, 20]]); break;
      case 'info':
        this.context.moveTo(22, 12);
        this.context.arc(12, 12, 10, 0, Math.PI * 2);
        this.line([[12, 11], [12, 17]]);
        this.line([[12, 7], [12, 7.4]]);
        break;
      case 'warning':
        this.line([[12, 3], [22, 21], [2, 21], [12, 3]]);
        this.line([[12, 9], [12, 14]]);
        this.line([[12, 17], [12, 17.4]]);
        break;
      case 'plus':
        this.line([[12, 4], [12, 20]]);
        this.line([[4, 12], [20, 12]]);
        break;
      case 'send':
        this.line([[12, 20], [12, 4]]);
        this.line([[5, 11], [12, 4], [19, 11]]);
        break;
      case 'more':
        this.line([[4, 12], [4.4, 12]]);
        this.line([[12, 12], [12.4, 12]]);
        this.line([[20, 12], [20.4, 12]]);
        break;
      case 'expand':
        this.line([[4, 9], [4, 4], [9, 4]]);
        this.line([[15, 20], [20, 20], [20, 15]]);
        this.line([[4, 4], [9, 9]]);
        this.line([[15, 15], [20, 20]]);
        break;
      case 'collapse':
        this.line([[4, 4], [9, 9], [4, 9]]);
        this.line([[9, 9], [9, 4]]);
        this.line([[20, 20], [15, 15], [20, 15]]);
        this.line([[15, 15], [15, 20]]);
        break;
      case 'microphone':
        this.roundedBox(9, 2, 6, 12);
        this.context.moveTo(6, 10);
        this.context.lineTo(6, 12);
        this.context.quadraticCurveTo(6, 18, 12, 18);
        this.context.quadraticCurveTo(18, 18, 18, 12);
        this.context.lineTo(18, 10);
        this.line([[12, 18], [12, 22]]);
        this.line([[8, 22], [16, 22]]);
        break;
      case 'speaker':
        this.line([[3, 9], [7, 9], [12, 5], [12, 19], [7, 15], [3, 15], [3, 9]]);
        this.context.moveTo(15, 9);
        this.context.quadraticCurveTo(18, 12, 15, 15);
        this.context.moveTo(18, 6);
        this.context.quadraticCurveTo(24, 12, 18, 18);
        break;
      case 'stop':
        this.roundedBox(6, 6, 12, 12);
        break;
      case 'check': this.line([[5, 12], [10, 17], [20, 6]]); break;
      case 'history':
        this.context.moveTo(3.5, 9);
        this.context.arc(12, 12, 9, -Math.PI * 0.89, Math.PI * 0.8);
        this.line([[3, 4], [3, 10], [9, 10]]);
        this.line([[12, 7], [12, 12], [16, 14]]);
        break;
      case 'book':
        this.context.moveTo(12, 6);
        this.context.quadraticCurveTo(7, 2, 2, 5);
        this.context.lineTo(2, 20);
        this.context.quadraticCurveTo(7, 17, 12, 21);
        this.context.quadraticCurveTo(17, 17, 22, 20);
        this.context.lineTo(22, 5);
        this.context.quadraticCurveTo(17, 2, 12, 6);
        this.context.lineTo(12, 21);
        break;
      case 'bolt': this.line([[13, 2], [4, 14], [11, 14], [10, 22], [20, 9], [13, 9], [13, 2]]); break;
      case 'card':
        this.roundedBox(2, 4, 20, 16);
        this.line([[2, 9], [22, 9]]);
        this.line([[6, 15], [10, 15]]);
        break;
      case 'classroom':
        this.context.rect(3, 3, 18, 13);
        this.line([[8, 21], [12, 16], [16, 21]]);
        this.line([[7, 8], [17, 8]]);
        this.line([[7, 12], [13, 12]]);
        break;
      default:
        this.context.moveTo(22, 12);
        this.context.arc(12, 12, 10, 0, Math.PI * 2);
        this.line([[12, 11], [12, 17]]);
        this.line([[12, 7], [12, 7.4]]);
    }
  }

  private redraw(): void {
    if (!this.ready) {
      return;
    }
    this.context.clearRect(0, 0, this.iconSize, this.iconSize);
    this.context.save();
    this.context.scale(this.iconSize / 24, this.iconSize / 24);
    this.context.strokeStyle = this.color.length > 0 ? this.color : this.palette.accent;
    this.context.lineWidth = 1.8;
    this.context.lineCap = 'round';
    this.context.lineJoin = 'round';
    this.context.beginPath();
    this.trace();
    this.context.stroke();
    this.context.restore();
  }

  build() {
    Canvas(this.context).width(this.iconSize).height(this.iconSize)
      .onReady(() => {
        this.ready = true;
        this.redraw();
      })
      .accessibilityLevel('no')
  }
}
