// Flat theme: no elevation, 1px outlines and surface tones separate areas.
// System fonts only (nothing bundled).
import 'dart:io';

import 'package:flutter/material.dart';

const _seed = Color(0xFF3D6FE0);

List<String>? get _fallback {
  if (Platform.isWindows) return const ['Microsoft YaHei UI', 'Microsoft YaHei', 'Segoe UI'];
  if (Platform.isMacOS) return const ['PingFang SC', 'Hiragino Sans GB'];
  return null;
}

String? get _fontFamily => Platform.isWindows ? 'Noto Sans SC' : null;

ThemeData buildTheme(Brightness b) {
  final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: b);
  final outline = scheme.outlineVariant;
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: b,
    fontFamily: _fontFamily,
    fontFamilyFallback: _fallback,
    visualDensity: Platform.isAndroid ? VisualDensity.standard : VisualDensity.compact,
  );
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: outline));
  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      shape: Border(bottom: BorderSide(color: outline)),
    ),
    cardTheme: CardThemeData(elevation: 0, shape: shape, color: scheme.surface, margin: EdgeInsets.zero),
    dialogTheme: DialogThemeData(elevation: 0, shape: shape, backgroundColor: scheme.surface),
    popupMenuTheme: PopupMenuThemeData(elevation: 0, shape: shape, color: scheme.surfaceContainerLow),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        elevation: const WidgetStatePropertyAll(0),
        shape: WidgetStatePropertyAll(shape),
        backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerLow),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(elevation: 0, backgroundColor: scheme.surface, modalElevation: 0),
    navigationBarTheme: NavigationBarThemeData(
      elevation: 0,
      backgroundColor: scheme.surfaceContainerLow,
      indicatorColor: scheme.secondaryContainer,
    ),
    navigationRailTheme: NavigationRailThemeData(backgroundColor: scheme.surfaceContainerLow, elevation: 0),
    dividerTheme: DividerThemeData(color: outline, thickness: 1, space: 1),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: outline)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: outline)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    ),
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(elevation: 0)),
    elevatedButtonTheme: ElevatedButtonThemeData(style: ElevatedButton.styleFrom(elevation: 0)),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(elevation: 0, highlightElevation: 0),
    snackBarTheme: SnackBarThemeData(elevation: 0, behavior: SnackBarBehavior.floating, shape: shape),
    tooltipTheme: const TooltipThemeData(waitDuration: Duration(milliseconds: 600)),
  );
}

/// Layout breakpoints (logical pixels).
enum LayoutSize {
  compact,
  medium,
  expanded;

  static LayoutSize of(double width) => width < 600 ? compact : (width <= 1000 ? medium : expanded);
}

String formatDuration(int ms) {
  final s = (ms / 1000).round();
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  final mm = h > 0 ? m.toString().padLeft(2, '0') : '$m';
  return h > 0 ? '$h:$mm:${sec.toString().padLeft(2, '0')}' : '$mm:${sec.toString().padLeft(2, '0')}';
}

String formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}
