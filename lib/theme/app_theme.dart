// FILE: lib/theme/app_theme.dart
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  // Palette
  static const Color ffPrimary = Color(0xFFFF1493); // deep pink
  static const Color ffSecondary = Color(0xFFFF1493);
  static const Color ffTertiary = Color(0xFFE5E5E5);
  static const Color ffAlt = Color(0xFFFFFFFF);

  static const Color ffPrimaryText = Color(0xFFFFFFFF);
  static const Color ffSecondaryText = Color(0xFFEDE7E7);

  static const Color ffPrimaryBg = Color(0xFF201F1F); // scaffold background
  static const Color ffSecondaryBg = Color(0xFF121212); // app bar / surfaces

  static const Color ffAccent1 = Color(0xFFFF3366);
  static const Color ffAccent2 = Color(0xFFFFA366);
  static const Color ffAccent3 = Color(0xFFE57373);
  static const Color ffAccent4 = Color(0xFF4D4D4D);

  static const Color ffSuccess = Color(0xFF66CC99);
  static const Color ffWarning = Color(0xFFFFCC66);
  static const Color ffError = Color(0xFFFF6666);
  static const Color ffInfo = Color(0xFF6699FF);

  // -----------------------
  // Dark theme
  // -----------------------
  static ThemeData get dark {
    final base = ThemeData.dark(useMaterial3: true);

    const scheme = ColorScheme.dark(
      primary: ffPrimary,
      secondary: ffSecondary,
      surface: ffSecondaryBg,
      onPrimary: Colors.white,
      onSecondary: Colors.white,
      onSurface: ffPrimaryText,
      error: ffError,
      onError: Colors.white,
    );

    return base.copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: ffPrimaryBg,
      appBarTheme: const AppBarTheme(
        backgroundColor: ffSecondaryBg,
        foregroundColor: ffPrimaryText,
        elevation: 0,
        centerTitle: true,
      ),
      // NOTE: your SDK expects CardThemeData / DialogThemeData
      cardTheme: CardThemeData(
        color: ffSecondaryBg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        elevation: 2,
        surfaceTintColor: Colors.transparent,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: const Color(0xFF16181C),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        surfaceTintColor: Colors.transparent,
        titleTextStyle: GoogleFonts.inter(
          color: Colors.white,
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
        contentTextStyle: GoogleFonts.inter(
          color: Colors.white70,
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
      ),
      textTheme: _textTheme(base.textTheme, isDark: true),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: ffSecondaryBg,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(
            color: const Color.fromARGB(255, 255, 255, 255).withValues(alpha: 0.6),
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(
            color: const Color.fromARGB(255, 255, 255, 255).withValues(alpha: 0.6),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: ffSecondary),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: ffPrimary,
          foregroundColor: Colors.white,
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: ffSecondary,
          foregroundColor: Colors.white,
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: ffPrimary,
          side: const BorderSide(color: ffPrimary),
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: const Color.fromARGB(255, 255, 255, 255).withValues(alpha: 0.4),
        thickness: 0.8,
      ),
    );
  }

  // -----------------------
  // Light theme
  // -----------------------
  static ThemeData get light {
    final base = ThemeData.light(useMaterial3: true);

    const scheme = ColorScheme.light(
      primary: ffPrimary,
      secondary: ffSecondary,
      surface: Colors.white,
      onPrimary: Colors.white,
      onSecondary: Colors.white,
      onSurface: Colors.black87,
      error: ffError,
      onError: Colors.white,
    );

    return base.copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: Colors.white,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0,
        centerTitle: true,
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        elevation: 2,
        surfaceTintColor: Colors.transparent,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        surfaceTintColor: Colors.transparent,
        titleTextStyle: GoogleFonts.inter(
          color: Colors.black87,
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
        contentTextStyle: GoogleFonts.inter(
          color: Colors.black87,
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
      ),
      textTheme: _textTheme(base.textTheme, isDark: false),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: ffAccent4.withValues(alpha: 0.2)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: ffAccent4.withValues(alpha: 0.2)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: ffSecondary),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: ffPrimary,
          foregroundColor: Colors.white,
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: ffSecondary,
          foregroundColor: Colors.white,
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: ffPrimary,
          side: const BorderSide(color: ffPrimary),
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: ffAccent4.withValues(alpha: 0.2),
        thickness: 0.8,
      ),
    );
  }

  static TextTheme _textTheme(TextTheme base, {required bool isDark}) {
    final themed = GoogleFonts.interTextTheme(base);
    return isDark
        ? themed.apply(
            bodyColor: ffPrimaryText,
            displayColor: ffPrimaryText,
          )
        : themed;
  }
}
