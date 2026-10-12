import 'package:flutter/material.dart';

/// Tails OS inspired palette, shared with the calsec app (gui/theme.py).
///
/// Both variants are built around Tails' brand purple (#56347c). Widgets read
/// the tokens with `AppPalette.of(context)`; Material widgets get them through
/// the [ThemeData] built by [buildAppTheme].
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.bg,
    required this.bgAlt,
    required this.bgPanel,
    required this.fg,
    required this.fgDim,
    required this.accent,
    required this.accentHover,
    required this.red,
    required this.border,
    required this.selBg,
  });

  final Color bg;          // window background
  final Color bgAlt;       // field / widget background
  final Color bgPanel;     // app bar, panels, heading rows
  final Color fg;          // primary text
  final Color fgDim;       // secondary / hint text
  final Color accent;      // brand purple
  final Color accentHover; // accent hover / pressed
  final Color red;         // errors
  final Color border;      // widget borders
  final Color selBg;       // selection background

  static const dark = AppPalette(
    bg: Color(0xFF1A1625),
    bgAlt: Color(0xFF231D30),
    bgPanel: Color(0xFF130F1C),
    fg: Color(0xFFE8E0F0),
    fgDim: Color(0xFF9B8FB0),
    accent: Color(0xFF9460D8),
    accentHover: Color(0xFF7A48B8),
    red: Color(0xFFE06C75),
    border: Color(0xFF3D3050),
    selBg: Color(0xFF3D2566),
  );

  static const light = AppPalette(
    bg: Color(0xFFF7F4FC),
    bgAlt: Color(0xFFEDE5F8),
    bgPanel: Color(0xFFE0D4F0),
    fg: Color(0xFF1A0D2E),
    fgDim: Color(0xFF6B5580),
    accent: Color(0xFF56347C),
    accentHover: Color(0xFF3D2260),
    red: Color(0xFFC0392B),
    border: Color(0xFFC9B0E0),
    selBg: Color(0xFFC4A8E8),
  );

  static AppPalette of(BuildContext context) =>
      Theme.of(context).extension<AppPalette>() ??
      (Theme.of(context).brightness == Brightness.dark ? dark : light);

  @override
  AppPalette copyWith({
    Color? bg,
    Color? bgAlt,
    Color? bgPanel,
    Color? fg,
    Color? fgDim,
    Color? accent,
    Color? accentHover,
    Color? red,
    Color? border,
    Color? selBg,
  }) {
    return AppPalette(
      bg: bg ?? this.bg,
      bgAlt: bgAlt ?? this.bgAlt,
      bgPanel: bgPanel ?? this.bgPanel,
      fg: fg ?? this.fg,
      fgDim: fgDim ?? this.fgDim,
      accent: accent ?? this.accent,
      accentHover: accentHover ?? this.accentHover,
      red: red ?? this.red,
      border: border ?? this.border,
      selBg: selBg ?? this.selBg,
    );
  }

  @override
  AppPalette lerp(ThemeExtension<AppPalette>? other, double t) {
    if (other is! AppPalette) return this;
    return AppPalette(
      bg: Color.lerp(bg, other.bg, t)!,
      bgAlt: Color.lerp(bgAlt, other.bgAlt, t)!,
      bgPanel: Color.lerp(bgPanel, other.bgPanel, t)!,
      fg: Color.lerp(fg, other.fg, t)!,
      fgDim: Color.lerp(fgDim, other.fgDim, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentHover: Color.lerp(accentHover, other.accentHover, t)!,
      red: Color.lerp(red, other.red, t)!,
      border: Color.lerp(border, other.border, t)!,
      selBg: Color.lerp(selBg, other.selBg, t)!,
    );
  }
}

ThemeData buildAppTheme(Brightness brightness) {
  final p = brightness == Brightness.dark ? AppPalette.dark : AppPalette.light;

  final scheme = ColorScheme(
    brightness: brightness,
    primary: p.accent,
    onPrimary: Colors.white,
    primaryContainer: p.selBg,
    onPrimaryContainer: p.fg,
    secondary: p.accentHover,
    onSecondary: Colors.white,
    secondaryContainer: p.selBg,
    onSecondaryContainer: p.fg,
    error: p.red,
    onError: Colors.white,
    surface: p.bg,
    onSurface: p.fg,
    onSurfaceVariant: p.fgDim,
    surfaceContainerLowest: p.bg,
    surfaceContainerLow: p.bgAlt,
    surfaceContainer: p.bgAlt,
    surfaceContainerHigh: p.bgAlt,
    surfaceContainerHighest: p.bgPanel,
    outline: p.border,
    outlineVariant: p.border,
  );

  OutlineInputBorder outlined(Color color, [double width = 1]) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: color, width: width),
      );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    primaryColor: p.accent,
    scaffoldBackgroundColor: p.bg,
    canvasColor: p.bg,
    cardColor: p.bgAlt,
    dividerColor: p.border,
    hintColor: p.fgDim,
    disabledColor: p.fgDim,
    extensions: [p],
    appBarTheme: AppBarTheme(
      backgroundColor: p.bgPanel,
      foregroundColor: p.fg,
      surfaceTintColor: Colors.transparent,
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: p.fg,
      unselectedLabelColor: p.fgDim,
      indicatorColor: p.accent,
      dividerColor: p.border,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: p.accent,
        foregroundColor: Colors.white,
        disabledBackgroundColor: p.bgPanel,
        disabledForegroundColor: p.fgDim,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ).copyWith(
        overlayColor: WidgetStatePropertyAll(p.accentHover.withValues(alpha: 0.35)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.bgAlt,
      labelStyle: TextStyle(color: p.fgDim),
      hintStyle: TextStyle(color: p.fgDim),
      floatingLabelStyle: TextStyle(color: p.accent),
      border: outlined(p.border),
      enabledBorder: outlined(p.border),
      focusedBorder: outlined(p.accent, 2),
      errorBorder: outlined(p.red),
      focusedErrorBorder: outlined(p.red, 2),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: p.fg,
      selectionColor: p.selBg,
      selectionHandleColor: p.accent,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: p.accent,
      linearTrackColor: p.bgPanel,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? Colors.white : p.fgDim),
      trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? p.accent : p.bgAlt),
      trackOutlineColor: WidgetStatePropertyAll(p.border),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      menuStyle: MenuStyle(backgroundColor: WidgetStatePropertyAll(p.bgAlt)),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.bgPanel,
      contentTextStyle: TextStyle(color: p.fg),
      behavior: SnackBarBehavior.floating,
    ),
  );
}

/// The app's theme mode, set by App; settings opened from the setup screens
/// use it.
ValueNotifier<ThemeMode> appThemeMode = ValueNotifier(ThemeMode.system);
