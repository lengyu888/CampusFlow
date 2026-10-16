// Shared iOS-inspired visual language. Native system font follows user text scaling.
export class AppTheme {
  static readonly bg: string = '#F2F2F7';
  static readonly surface: string = '#FFFFFF';
  static readonly ink: string = '#1C1C1E';
  static readonly secondary: string = '#63636E';
  static readonly muted: string = '#8E8E93';
  static readonly blue: string = '#007AFF';
  static readonly blueSoft: string = '#EAF3FF';
  static readonly green: string = '#248A3D';
  static readonly greenSoft: string = '#EAF7EE';
  static readonly orange: string = '#C05600';
  static readonly red: string = '#D70015';
  static readonly separator: string = '#E5E5EA';
  static readonly field: string = '#F2F2F7';

  static motion(duration: number = 220): number {
    return AppStorage.get<boolean>('reduceMotion') === true ? 0 : duration;
  }
}
