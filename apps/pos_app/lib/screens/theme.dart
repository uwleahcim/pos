import 'package:flutter/material.dart';

/// Semantic hospitality colors that adapt between light and dark themes.
@immutable
class PosColors extends ThemeExtension<PosColors> {
  const PosColors({
    required this.checkPaper,
    required this.checkHeader,
    required this.checkFooter,
    required this.floorCanvas,
    required this.floorGridDot,
    required this.roomFill,
    required this.roomBorder,
    required this.freeTable,
    required this.freeTableBorder,
    required this.freeTableText,
    required this.seated,
    required this.seatedBorder,
    required this.seatedText,
    required this.waiting,
    required this.waitingBorder,
    required this.waitingText,
    required this.fired,
    required this.firedBorder,
    required this.firedText,
    required this.highlightFlash,
  });

  final Color checkPaper;
  final Color checkHeader;
  final Color checkFooter;
  final Color floorCanvas;
  final Color floorGridDot;
  final Color roomFill;
  final Color roomBorder;
  final Color freeTable;
  final Color freeTableBorder;
  final Color freeTableText;
  final Color seated;
  final Color seatedBorder;
  final Color seatedText;
  final Color waiting;
  final Color waitingBorder;
  final Color waitingText;
  final Color fired;
  final Color firedBorder;
  final Color firedText;
  final Color highlightFlash;

  static const light = PosColors(
    checkPaper: Color(0xFFFFFDF9),
    checkHeader: Color(0xFFF3ECE1),
    checkFooter: Color(0xFFF6F0E6),
    floorCanvas: Color(0xFFF4EFE6),
    floorGridDot: Color(0xFFD8CFC2),
    roomFill: Color(0xB8FFFFFF),
    roomBorder: Color(0xFFD5CBBF),
    freeTable: Color(0xFFFFFFFF),
    freeTableBorder: Color(0xFFC8BEB0),
    freeTableText: Color(0xFF2D2621),
    seated: Color(0xFFDBEAFE),
    seatedBorder: Color(0xFF3B82F6),
    seatedText: Color(0xFF1E3A8A),
    waiting: Color(0xFFFEF3C7),
    waitingBorder: Color(0xFFD97706),
    waitingText: Color(0xFF78350F),
    fired: Color(0xFFDCFCE7),
    firedBorder: Color(0xFF16A34A),
    firedText: Color(0xFF14532D),
    highlightFlash: Color(0x33B8332A),
  );

  static const dark = PosColors(
    checkPaper: Color(0xFF1F1C19),
    checkHeader: Color(0xFF2B2622),
    checkFooter: Color(0xFF27221E),
    floorCanvas: Color(0xFF141210),
    floorGridDot: Color(0xFF2E2A26),
    roomFill: Color(0x881E1B18),
    roomBorder: Color(0xFF3D3731),
    freeTable: Color(0xFF2A2622),
    freeTableBorder: Color(0xFF4A433C),
    freeTableText: Color(0xFFEDE6DF),
    seated: Color(0xFF1E3A5F),
    seatedBorder: Color(0xFF60A5FA),
    seatedText: Color(0xFFDBEAFE),
    waiting: Color(0xFF452C0C),
    waitingBorder: Color(0xFFFBBF24),
    waitingText: Color(0xFFFEF3C7),
    fired: Color(0xFF143D27),
    firedBorder: Color(0xFF4ADE80),
    firedText: Color(0xFFDCFCE7),
    highlightFlash: Color(0x44FF8A7A),
  );

  static PosColors of(BuildContext context) =>
      Theme.of(context).extension<PosColors>() ?? (Theme.of(context).brightness == Brightness.dark ? dark : light);

  @override
  PosColors copyWith({
    Color? checkPaper,
    Color? checkHeader,
    Color? checkFooter,
    Color? floorCanvas,
    Color? floorGridDot,
    Color? roomFill,
    Color? roomBorder,
    Color? freeTable,
    Color? freeTableBorder,
    Color? freeTableText,
    Color? seated,
    Color? seatedBorder,
    Color? seatedText,
    Color? waiting,
    Color? waitingBorder,
    Color? waitingText,
    Color? fired,
    Color? firedBorder,
    Color? firedText,
    Color? highlightFlash,
  }) => PosColors(
    checkPaper: checkPaper ?? this.checkPaper,
    checkHeader: checkHeader ?? this.checkHeader,
    checkFooter: checkFooter ?? this.checkFooter,
    floorCanvas: floorCanvas ?? this.floorCanvas,
    floorGridDot: floorGridDot ?? this.floorGridDot,
    roomFill: roomFill ?? this.roomFill,
    roomBorder: roomBorder ?? this.roomBorder,
    freeTable: freeTable ?? this.freeTable,
    freeTableBorder: freeTableBorder ?? this.freeTableBorder,
    freeTableText: freeTableText ?? this.freeTableText,
    seated: seated ?? this.seated,
    seatedBorder: seatedBorder ?? this.seatedBorder,
    seatedText: seatedText ?? this.seatedText,
    waiting: waiting ?? this.waiting,
    waitingBorder: waitingBorder ?? this.waitingBorder,
    waitingText: waitingText ?? this.waitingText,
    fired: fired ?? this.fired,
    firedBorder: firedBorder ?? this.firedBorder,
    firedText: firedText ?? this.firedText,
    highlightFlash: highlightFlash ?? this.highlightFlash,
  );

  @override
  PosColors lerp(ThemeExtension<PosColors>? other, double t) {
    if (other is! PosColors) return this;
    return PosColors(
      checkPaper: Color.lerp(checkPaper, other.checkPaper, t)!,
      checkHeader: Color.lerp(checkHeader, other.checkHeader, t)!,
      checkFooter: Color.lerp(checkFooter, other.checkFooter, t)!,
      floorCanvas: Color.lerp(floorCanvas, other.floorCanvas, t)!,
      floorGridDot: Color.lerp(floorGridDot, other.floorGridDot, t)!,
      roomFill: Color.lerp(roomFill, other.roomFill, t)!,
      roomBorder: Color.lerp(roomBorder, other.roomBorder, t)!,
      freeTable: Color.lerp(freeTable, other.freeTable, t)!,
      freeTableBorder: Color.lerp(freeTableBorder, other.freeTableBorder, t)!,
      freeTableText: Color.lerp(freeTableText, other.freeTableText, t)!,
      seated: Color.lerp(seated, other.seated, t)!,
      seatedBorder: Color.lerp(seatedBorder, other.seatedBorder, t)!,
      seatedText: Color.lerp(seatedText, other.seatedText, t)!,
      waiting: Color.lerp(waiting, other.waiting, t)!,
      waitingBorder: Color.lerp(waitingBorder, other.waitingBorder, t)!,
      waitingText: Color.lerp(waitingText, other.waitingText, t)!,
      fired: Color.lerp(fired, other.fired, t)!,
      firedBorder: Color.lerp(firedBorder, other.firedBorder, t)!,
      firedText: Color.lerp(firedText, other.firedText, t)!,
      highlightFlash: Color.lerp(highlightFlash, other.highlightFlash, t)!,
    );
  }
}

/// Warm hospitality themes for the POS terminal.
abstract final class PosTheme {
  static const _seed = Color(0xFFA83226);

  static const tabular = [FontFeature.tabularFigures()];

  /// [highContrast] is a staff member's own setting: black-on-white text, darker outlines and thicker
  /// borders, for a bright room or tired eyes. The same colours otherwise.
  static ThemeData light({bool highContrast = false}) => _build(Brightness.light, highContrast: highContrast);
  static ThemeData dark({bool highContrast = false}) => _build(Brightness.dark, highContrast: highContrast);

  static ThemeData _build(Brightness brightness, {bool highContrast = false}) {
    final isDark = brightness == Brightness.dark;
    final strongLine = isDark ? const Color(0xFF9A9088) : const Color(0xFF6B6157);
    final baseScheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: brightness,
      primary: isDark ? const Color(0xFFFF8A7A) : const Color(0xFFA83226),
      secondary: isDark ? const Color(0xFFDCC2B4) : const Color(0xFF5C4033),
      tertiary: isDark ? const Color(0xFF8CD4B0) : const Color(0xFF2F5E48),
      surface: isDark ? const Color(0xFF181513) : const Color(0xFFFAF7F2),
      onSurface: highContrast ? (isDark ? Colors.white : Colors.black) : null,
      onSurfaceVariant: highContrast ? (isDark ? const Color(0xFFF2ECE4) : const Color(0xFF1E1A17)) : null,
      outline: highContrast ? strongLine : null,
      surfaceContainerLowest: isDark ? const Color(0xFF12100E) : const Color(0xFFFFFFFF),
      surfaceContainerLow: isDark ? const Color(0xFF1D1A17) : const Color(0xFFF6F2EB),
      surfaceContainer: isDark ? const Color(0xFF231F1C) : const Color(0xFFF0EAE1),
      surfaceContainerHigh: isDark ? const Color(0xFF2D2824) : const Color(0xFFE9E2D7),
      surfaceContainerHighest: isDark ? const Color(0xFF38322D) : const Color(0xFFE1D9CC),
      outlineVariant: highContrast ? strongLine : (isDark ? const Color(0xFF3F3832) : const Color(0xFFD8CFC2)),
    );
    final posColors = isDark ? PosColors.dark : PosColors.light;
    final lineWidth = highContrast ? 1.6 : 1.0;

    final baseText = Typography.material2021().englishLike.apply(
      bodyColor: baseScheme.onSurface,
      displayColor: baseScheme.onSurface,
    );

    final textTheme = baseText.copyWith(
      headlineMedium: baseText.headlineMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.5),
      headlineSmall: baseText.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.3),
      titleLarge: baseText.titleLarge?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.2),
      titleMedium: baseText.titleMedium?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.1),
      titleSmall: baseText.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      labelLarge: baseText.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      labelMedium: baseText.labelMedium?.copyWith(fontWeight: FontWeight.w500),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: baseScheme,
      textTheme: textTheme,
      scaffoldBackgroundColor: baseScheme.surface,
      extensions: [
        highContrast
            ? posColors.copyWith(
                freeTableBorder: strongLine,
                roomBorder: strongLine,
                freeTableText: baseScheme.onSurface,
                floorGridDot: baseScheme.outlineVariant,
              )
            : posColors,
      ],
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        backgroundColor: baseScheme.surface,
        foregroundColor: baseScheme.onSurface,
        titleTextStyle: textTheme.titleLarge?.copyWith(
          color: baseScheme.onSurface,
          fontWeight: FontWeight.w700,
          fontSize: 19,
        ),
        shape: Border(bottom: BorderSide(color: baseScheme.outlineVariant, width: 1)),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: baseScheme.surfaceContainerLowest,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: baseScheme.outlineVariant, width: lineWidth),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        side: BorderSide(color: baseScheme.outlineVariant, width: lineWidth),
        selectedColor: baseScheme.primaryContainer,
        backgroundColor: baseScheme.surfaceContainerLow,
        labelStyle: textTheme.labelLarge?.copyWith(color: baseScheme.onSurface),
        secondaryLabelStyle: textTheme.labelLarge?.copyWith(
          color: baseScheme.onPrimaryContainer,
          fontWeight: FontWeight.w700,
        ),
        showCheckmark: false,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          side: BorderSide(color: baseScheme.outlineVariant),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          textStyle: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        elevation: 3,
        highlightElevation: 6,
        backgroundColor: baseScheme.primary,
        foregroundColor: baseScheme.onPrimary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: baseScheme.surfaceContainerLowest,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: baseScheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: baseScheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: baseScheme.primary, width: 1.8),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: baseScheme.surfaceContainerLowest,
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: baseScheme.outlineVariant.withValues(alpha: 0.6)),
        ),
        titleTextStyle: textTheme.titleLarge?.copyWith(color: baseScheme.onSurface, fontWeight: FontWeight.w700),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: baseScheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      dividerTheme: DividerThemeData(color: baseScheme.outlineVariant, thickness: lineWidth, space: 1),
    );
  }
}

/// The colours of a category tile: the hue the menu gives the category (`#RRGGBB`), or one from a fixed
/// palette by its position, set light or dark for the theme so the name stays readable on it.
({Color fill, Color border, Color text}) categoryTint(ColorScheme scheme, {String? hex, required int index}) {
  const hues = [8.0, 32.0, 52.0, 98.0, 152.0, 190.0, 222.0, 262.0, 300.0, 335.0];
  final given = parseHexColor(hex);
  final hue = given == null ? hues[index % hues.length] : HSLColor.fromColor(given).hue;
  final saturation = given == null ? 0.42 : HSLColor.fromColor(given).saturation.clamp(0.25, 0.7);
  final dark = scheme.brightness == Brightness.dark;
  return (
    fill: HSLColor.fromAHSL(1, hue, saturation, dark ? 0.2 : 0.88).toColor(),
    border: HSLColor.fromAHSL(1, hue, saturation, dark ? 0.45 : 0.6).toColor(),
    text: HSLColor.fromAHSL(1, hue, dark ? 0.35 : 0.5, dark ? 0.9 : 0.2).toColor(),
  );
}

/// `#RRGGBB` or `RRGGBB` as a colour; null for anything else.
Color? parseHexColor(String? hex) {
  if (hex == null) return null;
  final digits = hex.trim().replaceFirst('#', '');
  if (digits.length != 6) return null;
  final value = int.tryParse(digits, radix: 16);
  return value == null ? null : Color(0xFF000000 | value);
}

/// Tactile press-scale feedback that uses a passive [Listener] so it never competes with child
/// gestures ([InkWell], long-press, or scroll drags).
class PressableScale extends StatefulWidget {
  const PressableScale({
    super.key,
    required this.child,
    this.enabled = true,
    this.pressedScale = 0.96,
    this.duration = const Duration(milliseconds: 110),
  });

  final Widget child;
  final bool enabled;
  final double pressedScale;
  final Duration duration;

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _down = false;

  void _set(bool down) {
    if (!widget.enabled || _down == down || !mounted) return;
    setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return Listener(
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedScale(
        scale: _down ? widget.pressedScale : 1.0,
        duration: widget.duration,
        curve: Curves.easeOutCubic,
        child: widget.child,
      ),
    );
  }
}

/// Smooth fade + gentle upward slide transition for POS screen navigation.
class PosPageRoute<T> extends PageRouteBuilder<T> {
  PosPageRoute({required WidgetBuilder builder, super.settings})
    : super(
        transitionDuration: const Duration(milliseconds: 240),
        reverseTransitionDuration: const Duration(milliseconds: 200),
        pageBuilder: (context, animation, secondaryAnimation) => builder(context),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(begin: const Offset(0, 0.025), end: Offset.zero).animate(curved),
              child: child,
            ),
          );
        },
      );
}
