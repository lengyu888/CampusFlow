// CampusFlow design contract. Native system font follows user text scaling.
export class AppTheme {
  static readonly bg: string = '#F5F7FA';
  static readonly surface: string = '#FFFFFF';
  static readonly ink: string = '#182A43';
  static readonly secondary: string = '#526176';
  static readonly muted: string = '#69778A';
  static readonly blue: string = '#2864D7';
  static readonly blueSoft: string = '#EAF0FC';
  static readonly green: string = '#237354';
  static readonly greenSoft: string = '#EDF7F1';
  static readonly orange: string = '#986019';
  static readonly orangeSoft: string = '#FFF6E7';
  static readonly red: string = '#B2443B';
  static readonly separator: string = '#DFE5EF';
  static readonly field: string = '#F5F7FA';

  // Aliases keep existing components on the same palette during the migration.
  static readonly canvas: string = '#F5F7FA';
  static readonly actionBlue: string = '#2864D7';
  static readonly quiet: string = '#526176';
  static readonly line: string = '#DFE5EF';
  static readonly redSoft: string = '#FFF0EE';
  static readonly pageInset: number = 20;
  static readonly sectionGap: number = 24;
  static readonly cardInset: number = 16;
  static readonly cardRadius: number = 18;
  static readonly controlRadius: number = 12;
  static readonly pageTitle: number = 28;
  static readonly sectionTitle: number = 18;
  static readonly bodySize: number = 16;
  static readonly metaSize: number = 13;

  static motion(duration: number = 220): number {
    return AppStorage.get<boolean>('reduceMotion') === true ? 0 : duration;
  }
}
