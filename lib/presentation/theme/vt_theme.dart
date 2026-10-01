/// Tema visual do techVT (desktop-first, densidade IDE).
/// Dark default + light + high-contrast (spec §UI — temas).
library;

import 'package:flutter/material.dart';

class VtColors extends ThemeExtension<VtColors> {
  const VtColors({
    required this.sidebar,
    required this.panel,
    required this.codeBackground,
    required this.diffAddition,
    required this.diffDeletion,
    required this.riskLow,
    required this.riskMedium,
    required this.riskHigh,
    required this.riskCritical,
    required this.accent,
  });

  final Color sidebar;
  final Color panel;
  final Color codeBackground;
  final Color diffAddition;
  final Color diffDeletion;
  final Color riskLow;
  final Color riskMedium;
  final Color riskHigh;
  final Color riskCritical;
  final Color accent;

  @override
  VtColors copyWith({
    Color? sidebar,
    Color? panel,
    Color? codeBackground,
    Color? diffAddition,
    Color? diffDeletion,
    Color? riskLow,
    Color? riskMedium,
    Color? riskHigh,
    Color? riskCritical,
    Color? accent,
  }) =>
      VtColors(
        sidebar: sidebar ?? this.sidebar,
        panel: panel ?? this.panel,
        codeBackground: codeBackground ?? this.codeBackground,
        diffAddition: diffAddition ?? this.diffAddition,
        diffDeletion: diffDeletion ?? this.diffDeletion,
        riskLow: riskLow ?? this.riskLow,
        riskMedium: riskMedium ?? this.riskMedium,
        riskHigh: riskHigh ?? this.riskHigh,
        riskCritical: riskCritical ?? this.riskCritical,
        accent: accent ?? this.accent,
      );

  @override
  VtColors lerp(ThemeExtension<VtColors>? other, double t) {
    if (other is! VtColors) return this;
    return VtColors(
      sidebar: Color.lerp(sidebar, other.sidebar, t)!,
      panel: Color.lerp(panel, other.panel, t)!,
      codeBackground: Color.lerp(codeBackground, other.codeBackground, t)!,
      diffAddition: Color.lerp(diffAddition, other.diffAddition, t)!,
      diffDeletion: Color.lerp(diffDeletion, other.diffDeletion, t)!,
      riskLow: Color.lerp(riskLow, other.riskLow, t)!,
      riskMedium: Color.lerp(riskMedium, other.riskMedium, t)!,
      riskHigh: Color.lerp(riskHigh, other.riskHigh, t)!,
      riskCritical: Color.lerp(riskCritical, other.riskCritical, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
    );
  }
}

class VtTheme {
  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF4F8CFF),
      brightness: Brightness.dark,
    );
    return _base(scheme, const VtColors(
      sidebar: Color(0xFF15171C),
      panel: Color(0xFF1B1E24),
      codeBackground: Color(0xFF101216),
      diffAddition: Color(0xFF1F3A24),
      diffDeletion: Color(0xFF3F1F22),
      riskLow: Color(0xFF3FBF6F),
      riskMedium: Color(0xFFE0B341),
      riskHigh: Color(0xFFE07B39),
      riskCritical: Color(0xFFE0414E),
      accent: Color(0xFF4F8CFF),
    ));
  }

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF2F6FE0),
      brightness: Brightness.light,
    );
    return _base(scheme, const VtColors(
      sidebar: Color(0xFFEDEFF3),
      panel: Color(0xFFF6F7FA),
      codeBackground: Color(0xFFEFF1F5),
      diffAddition: Color(0xFFDFF3E3),
      diffDeletion: Color(0xFFFBE2E4),
      riskLow: Color(0xFF1E8E4E),
      riskMedium: Color(0xFFB58500),
      riskHigh: Color(0xFFC25E1B),
      riskCritical: Color(0xFFC22834),
      accent: Color(0xFF2F6FE0),
    ));
  }

  static ThemeData highContrast() {
    final scheme = ColorScheme.fromSeed(
      seedColor: Colors.amberAccent,
      brightness: Brightness.dark,
    ).copyWith(
      surface: Colors.black,
      onSurface: Colors.white,
      outline: Colors.white54,
    );
    return _base(
        scheme,
        const VtColors(
          sidebar: Color(0xFF000000),
          panel: Color(0xFF0A0A0A),
          codeBackground: Color(0xFF000000),
          diffAddition: Color(0xFF004D00),
          diffDeletion: Color(0xFF660000),
          riskLow: Color(0xFF00E676),
          riskMedium: Color(0xFFFFEA00),
          riskHigh: Color(0xFFFF9100),
          riskCritical: Color(0xFFFF1744),
          accent: Color(0xFFFFD740),
        ));
  }

  static ThemeData _base(ColorScheme scheme, VtColors vt) {
    final isDark = scheme.brightness == Brightness.dark;
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      visualDensity: VisualDensity.compact,
      fontFamily: 'Segoe UI',
    );
    return base.copyWith(
      scaffoldBackgroundColor: vt.panel,
      dividerTheme: DividerThemeData(
          space: 1, thickness: 1, color: scheme.outlineVariant),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: isDark ? vt.codeBackground : Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      cardTheme: CardThemeData(
        color: vt.sidebar,
        elevation: 0,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: scheme.outlineVariant),
          borderRadius: BorderRadius.circular(8),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: vt.sidebar,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: vt.sidebar,
        indicatorColor: vt.accent.withValues(alpha: 0.18),
        selectedLabelStyle: const TextStyle(fontSize: 11),
        unselectedLabelStyle: const TextStyle(fontSize: 11),
      ),
      extensions: [vt],
    );
  }

  static VtColors of(BuildContext context) =>
      Theme.of(context).extension<VtColors>()!;
}
