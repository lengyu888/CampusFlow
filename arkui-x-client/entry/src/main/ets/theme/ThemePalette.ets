import { AppTheme } from './AppTheme';

export type AppThemeId = 'paper-green' | 'ios-blue';

// Flat immutable value objects: replacing the AppStorage value notifies every @StorageLink.
export interface ThemePalette {
  id: AppThemeId;
  name: string;
  canvas: string; surface: string; ink: string; secondary: string;
  accent: string; accentSoft: string; onAccent: string; line: string; outline: string;
  terracotta: string; success: string; successSoft: string; warning: string; warningSoft: string;
  danger: string; dangerSoft: string; dangerOutline: string; warningOutline: string;
  focus: string; pressed: string; pressedSoft: string; disabledContent: string; disabledSurface: string;
  bg: string; field: string; muted: string; quiet: string; blue: string; actionBlue: string;
  blueSoft: string; green: string; greenSoft: string; orange: string; orangeSoft: string;
  red: string; redSoft: string; separator: string;
  pageInset: number; sectionGap: number; cardInset: number; cardRadius: number;
  controlRadius: number; pageTitle: number; sectionTitle: number; bodySize: number; metaSize: number;
}

export const THEME_PALETTE_KEY: string = 'campusflowThemePalette';
export const THEME_ID_KEY: string = 'campusflowThemeId';
export const DEFAULT_THEME_ID: AppThemeId = 'paper-green';

export function themePalette(id: string): ThemePalette {
  const blue = id === 'ios-blue';
  return {
    id: blue ? 'ios-blue' : 'paper-green', name: blue ? '清透蓝' : '纸页绿',
    canvas: blue ? '#F2F2F7' : AppTheme.canvas, surface: blue ? '#FFFFFF' : AppTheme.surface,
    ink: blue ? '#1C1C1E' : AppTheme.ink, secondary: blue ? '#63636E' : AppTheme.secondary,
    accent: blue ? '#007AFF' : AppTheme.accent, accentSoft: blue ? '#EAF3FF' : AppTheme.accentSoft,
    onAccent: blue ? '#FFFFFF' : AppTheme.onAccent, line: blue ? '#E5E5EA' : AppTheme.line,
    outline: blue ? '#8E8E93' : AppTheme.outline, terracotta: blue ? '#C05600' : AppTheme.terracotta,
    success: blue ? '#248A3D' : AppTheme.success, successSoft: blue ? '#EAF7EE' : AppTheme.successSoft,
    warning: blue ? '#C05600' : AppTheme.warning, warningSoft: blue ? '#FFF4E5' : AppTheme.warningSoft,
    danger: blue ? '#D70015' : AppTheme.danger, dangerSoft: blue ? '#FFF0F1' : AppTheme.dangerSoft,
    dangerOutline: blue ? '#E8ACB3' : AppTheme.dangerOutline,
    warningOutline: blue ? '#E3BF96' : AppTheme.warningOutline,
    focus: blue ? '#007AFF' : AppTheme.focus, pressed: blue ? '#005FCC' : AppTheme.pressed,
    pressedSoft: blue ? '#D4E7FF' : AppTheme.pressedSoft,
    disabledContent: blue ? '#74747E' : AppTheme.disabledContent,
    disabledSurface: blue ? '#E5E5EA' : AppTheme.disabledSurface,
    bg: blue ? '#F2F2F7' : AppTheme.bg, field: blue ? '#F2F2F7' : AppTheme.field,
    muted: blue ? '#8E8E93' : AppTheme.muted, quiet: blue ? '#63636E' : AppTheme.quiet,
    blue: blue ? '#007AFF' : AppTheme.blue, actionBlue: blue ? '#007AFF' : AppTheme.actionBlue,
    blueSoft: blue ? '#EAF3FF' : AppTheme.blueSoft,
    green: blue ? '#248A3D' : AppTheme.green, greenSoft: blue ? '#EAF7EE' : AppTheme.greenSoft,
    orange: blue ? '#C05600' : AppTheme.orange, orangeSoft: blue ? '#FFF4E5' : AppTheme.orangeSoft,
    red: blue ? '#D70015' : AppTheme.red, redSoft: blue ? '#FFF0F1' : AppTheme.redSoft,
    separator: blue ? '#E5E5EA' : AppTheme.separator,
    pageInset: AppTheme.pageInset, sectionGap: AppTheme.sectionGap, cardInset: AppTheme.cardInset,
    cardRadius: blue ? 24 : AppTheme.cardRadius, controlRadius: blue ? 16 : AppTheme.controlRadius,
    pageTitle: AppTheme.pageTitle, sectionTitle: AppTheme.sectionTitle,
    bodySize: AppTheme.bodySize, metaSize: AppTheme.metaSize
  };
}

export function validThemeId(value: string | undefined): AppThemeId {
  return value === 'ios-blue' ? 'ios-blue' : DEFAULT_THEME_ID;
}

let initialized: boolean = false;

export function initializeAppTheme(): void {
  if (initialized) { return; }
  // Persist only the small preference, never account/form/navigation state or the palette object.
  PersistentStorage.persistProp(THEME_ID_KEY, DEFAULT_THEME_ID);
  const id = validThemeId(AppStorage.get<string>(THEME_ID_KEY));
  AppStorage.setOrCreate<string>(THEME_ID_KEY, id);
  AppStorage.setOrCreate<ThemePalette>(THEME_PALETTE_KEY, themePalette(id));
  initialized = true;
}

export function selectAppTheme(value: AppThemeId): void {
  initializeAppTheme();
  const id = validThemeId(value);
  if (AppStorage.get<string>(THEME_ID_KEY) === id) { return; }
  AppStorage.setOrCreate<string>(THEME_ID_KEY, id);
  // A fresh object reference is essential; a static getter alone is not observable UI state.
  AppStorage.setOrCreate<ThemePalette>(THEME_PALETTE_KEY, themePalette(id));
}
