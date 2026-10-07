import 'package:flutter/material.dart';

/// NexRadar's visual language.
///
/// Every colour, radius, gap and text style in the app resolves to a token in
/// this file. Nothing downstream hard-codes a hex value, which is what keeps a
/// 60 FPS HUD, a material settings page and a native overlay bubble looking
/// like one product.

// ---------------------------------------------------------------------------
// Colour
// ---------------------------------------------------------------------------

/// A cool graphite base with a mint "safe" accent, amber "approaching" and
/// coral "warning" — the three states the driver actually reacts to.
abstract final class NexColors {
  // --- surfaces (layered, so cards read as physical objects) ---------------
  static const Color background = Color(0xFF05080A);
  static const Color backgroundLift = Color(0xFF0A1013);
  static const Color surface = Color(0xFF0D1518);
  static const Color surfaceAlt = Color(0xFF121C20);
  static const Color surfaceHigh = Color(0xFF17242A);
  static const Color border = Color(0xFF1E2D33);
  static const Color borderSoft = Color(0xFF162126);

  // --- brand / status -------------------------------------------------------
  /// Safe / idle — the colour of a clean road.
  static const Color primary = Color(0xFF31F0A6);
  static const Color primaryDeep = Color(0xFF0EBE7C);
  static const Color primaryInk = Color(0xFF032014);

  /// Approaching — amber, "something is coming".
  static const Color amber = Color(0xFFFFB531);
  static const Color amberDeep = Color(0xFFD98A0B);

  /// Warning — coral red, "act now".
  static const Color danger = Color(0xFFFF4D5E);
  static const Color dangerDeep = Color(0xFFE02040);

  /// Data accent, used sparingly for charts / GPS quality.
  static const Color cyan = Color(0xFF4CD9FF);

  // --- text -----------------------------------------------------------------
  static const Color textHigh = Color(0xFFF2F7F6);
  static const Color textMid = Color(0xFF9BABB0);
  static const Color textLow = Color(0xFF5E727A);

  static const Color white = Color(0xFFFFFFFF);

  /// Soft translucent fill used for "quiet" chips and tracks.
  static Color hairline(double opacity) => white.withValues(alpha: opacity);
}

/// Reusable gradients so the gauge, buttons and cards share one lighting model.
abstract final class NexGradients {
  static const LinearGradient brand = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: <Color>[NexColors.primary, NexColors.primaryDeep],
  );

  static const LinearGradient card = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: <Color>[NexColors.surfaceAlt, NexColors.surface],
  );

  /// Slight top highlight that makes a flat card look milled.
  static LinearGradient sheen = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: <Color>[
      NexColors.white.withValues(alpha: 0.05),
      NexColors.white.withValues(alpha: 0.0),
    ],
  );
}

// ---------------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------------

/// A 4-point spacing scale. Use these instead of raw numbers so rhythm stays
/// consistent when a screen is edited later.
abstract final class NexSpace {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 44;

  /// Standard horizontal page padding.
  static const double page = 18;
}

abstract final class NexRadius {
  static const double sm = 10;
  static const double md = 16;
  static const double lg = 22;
  static const double xl = 28;
  static const double pill = 999;

  static const BorderRadius smAll = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdAll = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgAll = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius xlAll = BorderRadius.all(Radius.circular(xl));
  static const BorderRadius pillAll = BorderRadius.all(Radius.circular(pill));

  /// Card corners — the default radius for every surface in the app.
  static const BorderRadius card = BorderRadius.all(Radius.circular(lg));
}

abstract final class NexMotion {
  static const Duration fast = Duration(milliseconds: 140);
  static const Duration base = Duration(milliseconds: 240);
  static const Duration slow = Duration(milliseconds: 420);
  static const Curve ease = Curves.easeOutCubic;
  static const Curve emphasized = Curves.easeOutQuart;
}

/// Elevation expressed as coloured light, not grey drop shadows — a grey shadow
/// on a graphite background just looks like dirt.
abstract final class NexShadow {
  static List<BoxShadow> glow(Color color, {double strength = 0.35}) =>
      <BoxShadow>[
        BoxShadow(
          color: color.withValues(alpha: strength * 0.5),
          blurRadius: 34,
          spreadRadius: -6,
          offset: const Offset(0, 10),
        ),
      ];

  static const List<BoxShadow> card = <BoxShadow>[
    BoxShadow(
      color: Color(0x66000000),
      blurRadius: 22,
      spreadRadius: -12,
      offset: Offset(0, 12),
    ),
  ];
}

// ---------------------------------------------------------------------------
// Typography
// ---------------------------------------------------------------------------

abstract final class NexFont {
  static const String text = 'Inter';
  static const String display = 'InterDisplay';
}

/// Hand-tuned text styles. The default Material scale is too airy for a dense
/// data HUD, so the sizes are tighter and the weights heavier.
abstract final class NexText {
  static const TextStyle display = TextStyle(
    fontFamily: NexFont.display,
    fontSize: 76,
    height: 1.0,
    fontWeight: FontWeight.w700,
    letterSpacing: -3.5,
    color: NexColors.textHigh,
    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
  );

  static const TextStyle h1 = TextStyle(
    fontFamily: NexFont.text,
    fontSize: 27,
    height: 1.15,
    fontWeight: FontWeight.w800,
    letterSpacing: -0.8,
    color: NexColors.textHigh,
  );

  static const TextStyle h2 = TextStyle(
    fontFamily: NexFont.text,
    fontSize: 21,
    height: 1.2,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.5,
    color: NexColors.textHigh,
  );

  static const TextStyle h3 = TextStyle(
    fontFamily: NexFont.text,
    fontSize: 17,
    height: 1.25,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.3,
    color: NexColors.textHigh,
  );

  static const TextStyle title = TextStyle(
    fontFamily: NexFont.text,
    fontSize: 15,
    height: 1.3,
    fontWeight: FontWeight.w600,
    color: NexColors.textHigh,
  );

  static const TextStyle body = TextStyle(
    fontFamily: NexFont.text,
    fontSize: 14,
    height: 1.45,
    fontWeight: FontWeight.w400,
    color: NexColors.textMid,
  );

  static const TextStyle bodyStrong = TextStyle(
    fontFamily: NexFont.text,
    fontSize: 14,
    height: 1.35,
    fontWeight: FontWeight.w600,
    color: NexColors.textHigh,
  );

  static const TextStyle caption = TextStyle(
    fontFamily: NexFont.text,
    fontSize: 12,
    height: 1.4,
    fontWeight: FontWeight.w500,
    color: NexColors.textLow,
  );

  static const TextStyle label = TextStyle(
    fontFamily: NexFont.text,
    fontSize: 13,
    height: 1.3,
    fontWeight: FontWeight.w600,
    color: NexColors.textHigh,
  );

  /// Uppercase section eyebrows.
  static const TextStyle overline = TextStyle(
    fontFamily: NexFont.text,
    fontSize: 11,
    height: 1.2,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.6,
    color: NexColors.textLow,
  );

  /// Big numbers that must not jitter while counting (limits, distances).
  static const TextStyle numeric = TextStyle(
    fontFamily: NexFont.display,
    fontSize: 22,
    height: 1.05,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.6,
    color: NexColors.textHigh,
    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
  );

  static const TextStyle numericSmall = TextStyle(
    fontFamily: NexFont.text,
    fontSize: 15,
    height: 1.1,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.2,
    color: NexColors.textHigh,
    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
  );
}

// ---------------------------------------------------------------------------
// ThemeData
// ---------------------------------------------------------------------------

abstract final class NexTheme {
  static ThemeData dark() {
    const ColorScheme scheme = ColorScheme.dark(
      primary: NexColors.primary,
      onPrimary: NexColors.primaryInk,
      primaryContainer: NexColors.primaryDeep,
      onPrimaryContainer: NexColors.primaryInk,
      secondary: NexColors.amber,
      onSecondary: Color(0xFF231704),
      tertiary: NexColors.cyan,
      onTertiary: Color(0xFF04202A),
      error: NexColors.danger,
      onError: Color(0xFF2B0509),
      surface: NexColors.surface,
      onSurface: NexColors.textHigh,
      surfaceContainerLowest: NexColors.background,
      surfaceContainerLow: NexColors.backgroundLift,
      surfaceContainer: NexColors.surface,
      surfaceContainerHigh: NexColors.surfaceAlt,
      surfaceContainerHighest: NexColors.surfaceHigh,
      onSurfaceVariant: NexColors.textMid,
      outline: NexColors.border,
      outlineVariant: NexColors.borderSoft,
      shadow: Color(0xFF000000),
      scrim: Color(0xCC000000),
      inverseSurface: NexColors.textHigh,
      onInverseSurface: NexColors.background,
    );

    final TextTheme text = const TextTheme(
      displayLarge: NexText.display,
      displayMedium: NexText.h1,
      displaySmall: NexText.h2,
      headlineLarge: NexText.h1,
      headlineMedium: NexText.h2,
      headlineSmall: NexText.h3,
      titleLarge: NexText.h3,
      titleMedium: NexText.title,
      titleSmall: NexText.bodyStrong,
      bodyLarge: NexText.body,
      bodyMedium: NexText.body,
      bodySmall: NexText.caption,
      labelLarge: NexText.label,
      labelMedium: NexText.caption,
      labelSmall: NexText.overline,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      fontFamily: NexFont.text,
      scaffoldBackgroundColor: NexColors.background,
      canvasColor: NexColors.background,
      splashFactory: InkSparkle.splashFactory,
      textTheme: text,
      primaryTextTheme: text,
      visualDensity: VisualDensity.standard,

      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        foregroundColor: NexColors.textHigh,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: NexText.h3,
      ),

      cardTheme: CardThemeData(
        color: NexColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: NexRadius.card,
          side: const BorderSide(color: NexColors.borderSoft),
        ),
      ),

      dividerTheme: const DividerThemeData(
        color: NexColors.borderSoft,
        thickness: 1,
        space: 1,
      ),

      iconTheme: const IconThemeData(color: NexColors.textMid, size: 22),
      primaryIconTheme: const IconThemeData(color: NexColors.primaryInk),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: NexColors.primary,
          foregroundColor: NexColors.primaryInk,
          disabledBackgroundColor: NexColors.surfaceHigh,
          disabledForegroundColor: NexColors.textLow,
          minimumSize: const Size(0, 54),
          padding: const EdgeInsets.symmetric(horizontal: NexSpace.xl),
          textStyle: const TextStyle(
            fontFamily: NexFont.text,
            fontSize: 15.5,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.2,
          ),
          shape: const RoundedRectangleBorder(borderRadius: NexRadius.pillAll),
          elevation: 0,
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: NexColors.textHigh,
          minimumSize: const Size(0, 54),
          padding: const EdgeInsets.symmetric(horizontal: NexSpace.xl),
          textStyle: const TextStyle(
            fontFamily: NexFont.text,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
          side: const BorderSide(color: NexColors.border),
          shape: const RoundedRectangleBorder(borderRadius: NexRadius.pillAll),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: NexColors.primary,
          textStyle: const TextStyle(
            fontFamily: NexFont.text,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),

      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: NexColors.primary,
        foregroundColor: NexColors.primaryInk,
        elevation: 0,
        highlightElevation: 0,
      ),

      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) {
          if (states.contains(WidgetState.disabled)) return NexColors.textLow;
          return states.contains(WidgetState.selected)
              ? NexColors.primaryInk
              : const Color(0xFF6F848B);
        }),
        trackColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) {
          if (states.contains(WidgetState.disabled)) return NexColors.surfaceHigh;
          return states.contains(WidgetState.selected)
              ? NexColors.primary
              : NexColors.surfaceHigh;
        }),
        trackOutlineColor:
            const WidgetStatePropertyAll<Color>(Colors.transparent),
      ),

      sliderTheme: SliderThemeData(
        activeTrackColor: NexColors.primary,
        inactiveTrackColor: NexColors.surfaceHigh,
        thumbColor: NexColors.primary,
        overlayColor: NexColors.primary.withValues(alpha: 0.14),
        trackHeight: 6,
        valueIndicatorColor: NexColors.surfaceHigh,
        valueIndicatorTextStyle: NexText.numericSmall,
        showValueIndicator: ShowValueIndicator.never,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 20),
      ),

      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: NexColors.primary,
        linearTrackColor: NexColors.surfaceHigh,
        circularTrackColor: NexColors.surfaceHigh,
      ),

      snackBarTheme: SnackBarThemeData(
        backgroundColor: NexColors.surfaceHigh,
        contentTextStyle: NexText.bodyStrong,
        actionTextColor: NexColors.primary,
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        insetPadding: const EdgeInsets.all(NexSpace.md),
        shape: const RoundedRectangleBorder(borderRadius: NexRadius.mdAll),
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: NexColors.surfaceAlt,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: const RoundedRectangleBorder(borderRadius: NexRadius.xlAll),
        titleTextStyle: NexText.h3,
        contentTextStyle: NexText.body,
      ),

      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: NexColors.surfaceAlt,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: NexColors.surfaceAlt,
        elevation: 0,
        showDragHandle: true,
        dragHandleColor: NexColors.border,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(NexRadius.xl)),
        ),
      ),

      listTileTheme: const ListTileThemeData(
        iconColor: NexColors.textMid,
        textColor: NexColors.textHigh,
        titleTextStyle: NexText.title,
        subtitleTextStyle: NexText.caption,
        contentPadding: EdgeInsets.symmetric(horizontal: NexSpace.md),
      ),

      chipTheme: ChipThemeData(
        backgroundColor: NexColors.surfaceHigh,
        selectedColor: NexColors.primary.withValues(alpha: 0.16),
        side: const BorderSide(color: NexColors.borderSoft),
        labelStyle: NexText.caption,
        secondaryLabelStyle: NexText.caption,
        shape: const RoundedRectangleBorder(borderRadius: NexRadius.pillAll),
        padding: const EdgeInsets.symmetric(
          horizontal: NexSpace.sm,
          vertical: NexSpace.xxs,
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: NexColors.backgroundLift,
        hintStyle: NexText.body,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: NexSpace.md,
          vertical: NexSpace.sm,
        ),
        border: const OutlineInputBorder(
          borderRadius: NexRadius.mdAll,
          borderSide: BorderSide(color: NexColors.borderSoft),
        ),
        enabledBorder: const OutlineInputBorder(
          borderRadius: NexRadius.mdAll,
          borderSide: BorderSide(color: NexColors.borderSoft),
        ),
        focusedBorder: const OutlineInputBorder(
          borderRadius: NexRadius.mdAll,
          borderSide: BorderSide(color: NexColors.primary, width: 1.4),
        ),
      ),

      dropdownMenuTheme: DropdownMenuThemeData(
        menuStyle: MenuStyle(
          backgroundColor:
              const WidgetStatePropertyAll<Color>(NexColors.surfaceHigh),
          shape: const WidgetStatePropertyAll<OutlinedBorder>(
            RoundedRectangleBorder(borderRadius: NexRadius.mdAll),
          ),
        ),
        textStyle: NexText.title,
      ),

      popupMenuTheme: PopupMenuThemeData(
        color: NexColors.surfaceHigh,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: const RoundedRectangleBorder(borderRadius: NexRadius.mdAll),
        textStyle: NexText.title,
      ),

      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: NexColors.surfaceHigh,
          borderRadius: NexRadius.smAll,
        ),
        textStyle: NexText.caption.copyWith(color: NexColors.textHigh),
      ),

      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        },
      ),
    );
  }
}
