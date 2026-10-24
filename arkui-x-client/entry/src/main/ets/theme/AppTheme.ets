// Paper defaults and motion policy. UI components subscribe to ThemePalette instead of static colors.
// Layout numbers are vp; text sizes follow native fp scaling.
export class AppTheme {
  static readonly canvas: string = '#F6F4EF';
  static readonly surface: string = '#FFFEFB';
  static readonly ink: string = '#29352F';
  static readonly secondary: string = '#626E65';
  static readonly accent: string = '#416454';
  static readonly accentSoft: string = '#E7EEE6';
  static readonly onAccent: string = '#FFFEFB';
  static readonly line: string = '#DCE2D8';
  static readonly outline: string = '#788578';
  static readonly terracotta: string = '#9B573B';
  static readonly success: string = '#3D7054';
  static readonly successSoft: string = '#EDF4EA';
  static readonly warning: string = '#886023';
  static readonly warningSoft: string = '#FBF2DF';
  static readonly danger: string = '#A4493E';
  static readonly dangerSoft: string = '#FFF0EC';
  static readonly dangerOutline: string = '#D8A59A';
  static readonly warningOutline: string = '#D9C398';
  static readonly focus: string = AppTheme.accent;
  static readonly pressed: string = '#355445';
  static readonly pressedSoft: string = '#D8E4D7';
  static readonly disabledContent: string = '#717B72';
  static readonly disabledSurface: string = '#E8EBE4';

  // Legacy names remain aliases so existing business-state callers keep their meaning.
  static readonly bg: string = AppTheme.canvas;
  static readonly field: string = AppTheme.canvas;
  static readonly muted: string = AppTheme.secondary;
  static readonly quiet: string = AppTheme.secondary;
  static readonly blue: string = AppTheme.accent;
  static readonly actionBlue: string = AppTheme.accent;
  static readonly blueSoft: string = AppTheme.accentSoft;
  static readonly green: string = AppTheme.success;
  static readonly greenSoft: string = AppTheme.successSoft;
  static readonly orange: string = AppTheme.warning;
  static readonly orangeSoft: string = AppTheme.warningSoft;
  static readonly red: string = AppTheme.danger;
  static readonly redSoft: string = AppTheme.dangerSoft;
  static readonly separator: string = AppTheme.line;
  static readonly pageInset: number = 20;
  static readonly sectionGap: number = 24;
  static readonly cardInset: number = 16;
  static readonly cardRadius: number = 16;
  static readonly controlRadius: number = 12;
  static readonly pageTitle: number = 28;
  static readonly sectionTitle: number = 18;
  static readonly bodySize: number = 16;
  static readonly metaSize: number = 13;

  static motion(duration: number = 220): number {
    return AppStorage.get<boolean>('reduceMotion') === true ? 0 : duration;
  }
}
