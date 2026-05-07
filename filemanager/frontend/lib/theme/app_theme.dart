import 'package:flutter/material.dart';
import 'app_typography.dart';

class AppColors {
  static const Color background = Color(0xFF0D1117);
  static const Color backgroundElevated = Color(0xFF111827);
  static const Color backgroundCanvas = Color(0xFF081018);
  static const Color surface = Color(0xFF161B22);
  static const Color surfaceElevated = Color(0xFF11161D);
  static const Color surfaceMuted = Color(0xFF21262D);
  static const Color surfacePanel = Color(0xFF0F1722);
  static const Color surfacePanelRaised = Color(0xFF121A24);
  static const Color menuDivider = Color(0xFF262C33);
  static const Color border = Color(0xFF30363D);
  static const Color borderStrong = Color(0xFF484F58);
  static const Color overlay = Color(0x66000000);
  static const Color textPrimary = Colors.white;
  static const Color textSecondary = Color(0xFFC9D1D9);
  static const Color textMuted = Color(0xFF8B949E);
  static const Color textSubtle = Color(0xFF6E7681);
  static const Color primary = Color(0xFF58A6FF);
  static const Color primarySoft = Color(0xFF102846);
  static const Color primaryFill = Color(0xFF1F6FEB);
  static const Color primaryGlow = Color(0xFF79C0FF);
  static const Color success = Color(0xFF238636);
  static const Color successText = Color(0xFF3FB950);
  static const Color danger = Color(0xFFF85149);
  static const Color dangerMuted = Color(0xFFC93C37);
  static const Color warning = Color(0xFFD29922);
  static const Color info = Color(0xFF58A6FF);
  static const Color actionMuted = Color(0xFF6E7681);
  static const Color authKeyBg = Color(0xFF1F3A5F);
  static const Color authPasswordBg = Color(0xFF1F3A2A);
  static const Color authKeyText = Color(0xFF58A6FF);
  static const Color authPasswordText = Color(0xFF3FB950);
  static const Color chipActiveBg = Color(0xFF1C2F56);
  static const Color chipActiveBorder = Color(0xFF4F63D9);
  static const Color chipActiveText = Color(0xFFD0D7E8);
  static const Color chipInactiveText = Color(0xFF9AA4B2);

  const AppColors._();
}

class AppTheme {
  const AppTheme._();

  static const bool _preferSystemFonts =
      bool.fromEnvironment('SPANEL_PREFER_SYSTEM_FONTS', defaultValue: false);

  static const String _bundledUIFont = 'SourceHanSansSC';

  static const List<String> _uiFontFallback = <String>[
    // Keep a local-only fallback chain and avoid remote web font fetching.
    _bundledUIFont,
    // Emoji and symbols from local system fonts (no remote fetching).
    'Noto Color Emoji',
    'Segoe UI Emoji',
    'Apple Color Emoji',
    'Segoe UI Symbol',
    'Noto Sans Symbols 2',
    'PingFang SC',
    'Hiragino Sans GB',
    'Microsoft YaHei',
    'sans-serif',
  ];

  static ThemeData buildDarkTheme() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AppColors.background,
      canvasColor: AppColors.background,
      // Allow fast rollback to pure system-local fonts when required.
      fontFamily: _preferSystemFonts ? null : _bundledUIFont,
      fontFamilyFallback: _uiFontFallback,
      colorScheme: const ColorScheme.dark(
        primary: AppColors.primary,
        secondary: AppColors.info,
        surface: AppColors.surface,
        error: AppColors.danger,
      ),
      dividerColor: AppColors.menuDivider,
      dividerTheme: const DividerThemeData(
        color: AppColors.menuDivider,
        thickness: 1,
        space: 16,
      ),
      textTheme: const TextTheme(
        titleLarge: TextStyle(
          color: AppColors.textPrimary,
          fontSize: AppTypography.displayS,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
        ),
        titleMedium: TextStyle(
          color: AppColors.textPrimary,
          fontSize: AppTypography.titleM,
          fontWeight: FontWeight.w600,
        ),
        bodyLarge: TextStyle(
          color: AppColors.textSecondary,
          fontSize: AppTypography.bodyL,
          height: 1.5,
        ),
        bodyMedium: TextStyle(
          color: AppColors.textSecondary,
          fontSize: AppTypography.bodyM,
          height: 1.45,
        ),
        bodySmall: TextStyle(
          color: AppColors.textMuted,
          fontSize: AppTypography.bodyS,
          height: 1.4,
        ),
      ),
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: AppColors.primary,
        selectionColor: Color(0x55388BFD),
        selectionHandleColor: AppColors.primary,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.background,
        labelStyle: const TextStyle(
            color: AppColors.textMuted, fontSize: AppTypography.bodyM),
        hintStyle: const TextStyle(
            color: AppColors.textSubtle, fontSize: AppTypography.bodyM),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.primary),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.danger),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      cardTheme: CardThemeData(
        color: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        elevation: 0,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: AppButtonStyles.filled(),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: AppButtonStyles.outlined(),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.textSecondary,
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: AppColors.textMuted,
          hoverColor: AppColors.surfaceMuted,
          highlightColor: AppColors.surfaceMuted,
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: AppColors.border),
        ),
        textStyle: const TextStyle(
          color: AppColors.textSecondary,
          fontSize: AppTypography.bodyM,
        ),
      ),
    );
  }
}

class AppButtonStyles {
  const AppButtonStyles._();

  static ButtonStyle filled({
    Color background = AppColors.success,
    Color foreground = Colors.white,
    EdgeInsetsGeometry padding = const EdgeInsets.symmetric(
      horizontal: 14,
      vertical: 0,
    ),
    Size minimumSize = const Size(0, 36),
    double radius = 8,
  }) {
    return ElevatedButton.styleFrom(
      backgroundColor: background,
      foregroundColor: foreground,
      padding: padding,
      minimumSize: minimumSize,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }

  static ButtonStyle subtle({
    Color background = AppColors.surfaceMuted,
    Color foreground = AppColors.textSecondary,
    EdgeInsetsGeometry padding = const EdgeInsets.symmetric(
      horizontal: 14,
      vertical: 0,
    ),
    Size minimumSize = const Size(0, 36),
    double radius = 8,
  }) {
    return ElevatedButton.styleFrom(
      backgroundColor: background,
      foregroundColor: foreground,
      elevation: 0,
      padding: padding,
      minimumSize: minimumSize,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }

  static ButtonStyle outlined({
    Color foreground = AppColors.textSecondary,
    Color border = AppColors.border,
    Color background = AppColors.background,
    EdgeInsetsGeometry padding = const EdgeInsets.symmetric(
      horizontal: 14,
      vertical: 0,
    ),
    Size minimumSize = const Size(0, 36),
    double radius = 8,
  }) {
    return OutlinedButton.styleFrom(
      foregroundColor: foreground,
      side: BorderSide(color: border),
      padding: padding,
      minimumSize: minimumSize,
      backgroundColor: background,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

class AppInputDecorations {
  const AppInputDecorations._();

  static InputDecoration outlined({
    String? labelText,
    String? hintText,
    Widget? prefixIcon,
    Widget? suffixIcon,
    bool isDense = true,
    EdgeInsetsGeometry? contentPadding,
    Color fillColor = AppColors.background,
    double radius = 8,
  }) {
    return InputDecoration(
      labelText: labelText,
      hintText: hintText,
      prefixIcon: prefixIcon,
      suffixIcon: suffixIcon,
      isDense: isDense,
      alignLabelWithHint: true,
      contentPadding: contentPadding ??
          const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      filled: true,
      fillColor: fillColor,
      labelStyle: const TextStyle(
          color: AppColors.textMuted, fontSize: AppTypography.bodyM),
      hintStyle: const TextStyle(
          color: AppColors.textSubtle, fontSize: AppTypography.bodyM),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radius),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radius),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radius),
        borderSide: const BorderSide(color: AppColors.primary),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radius),
        borderSide: const BorderSide(color: AppColors.danger),
      ),
    );
  }
}
