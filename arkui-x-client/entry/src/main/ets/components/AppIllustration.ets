import { AppIcon } from './AppIcon';
import { AppTheme } from '../theme/AppTheme';
import { ThemePalette, themePalette } from '../theme/ThemePalette';

// Decorative local resources only. Page text and actions stay usable without the image.
@Component
export struct AppIllustration {
  @StorageLink('campusflowThemePalette') private palette: ThemePalette = themePalette('paper-green');
  @Watch('sourceChanged') @Prop source: Resource | undefined = undefined;
  @Prop imageWidth: number = 144;
  @Prop imageHeight: number = 108;
  @Prop fallbackIcon: string = 'book';
  @State private imageFailed: boolean = false;

  private sourceChanged(): void {
    this.imageFailed = false;
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.source !== undefined && !this.imageFailed) {
        Image(this.source as Resource)
          .width('100%').height('100%').objectFit(ImageFit.Contain)
          .onError(() => this.imageFailed = true)
          .accessibilityLevel('no')
      } else {
        AppIcon({ name: this.fallbackIcon,
          iconSize: Math.max(0, Math.min(40, this.imageWidth, this.imageHeight)), color: this.palette.secondary })
      }
    }.width(this.imageWidth).height(this.imageHeight).accessibilityLevel('no')
  }
}
