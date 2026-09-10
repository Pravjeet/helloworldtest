import 'package:flutter/material.dart';

/// The app's design tokens.
///
/// These are deliberately **mutable statics**, not constants. A `const`
/// colour is baked into the widget at compile time, which is precisely why an
/// accent picker that only changed `ThemeData` left 570 hardcoded references
/// still rendering the old default — and why a dark mode was impossible.
///
/// [apply] rewrites every token for a given accent and brightness;
/// [PaletteScope] calls it and rebuilds the tree beneath. The cost of this
/// design is that any widget reading a token cannot be `const` — the analyzer
/// enforces that for us, loudly.
class AppColors {
  static Color primary = _lightPrimary;
  static Color primarySoft = const Color(0xFFEEF2FF);
  static Color sidebar = const Color(0xFF1E1B4B);
  static Color sidebarDeep = const Color(0xFF17153F);
  static Color canvas = const Color(0xFFF6F7FB);
  static Color card = Colors.white;
  static Color border = const Color(0xFFE9EBF3);
  static Color textStrong = const Color(0xFF0F172A);
  static Color textMuted = const Color(0xFF64748B);

  // Status colours keep their meaning in both modes — green is "fine"
  // whatever the background — but the soft variants have to flip, or a pale
  // green pill on a near-black card is unreadable.
  static Color success = const Color(0xFF16A34A);
  static Color successSoft = const Color(0xFFDCFCE7);
  static Color warning = const Color(0xFFF59E0B);
  static Color warningSoft = const Color(0xFFFEF3C7);
  static Color danger = const Color(0xFFDC2626);
  static Color dangerSoft = const Color(0xFFFEE2E2);
  static Color info = const Color(0xFF0EA5E9);
  static Color infoSoft = const Color(0xFFE0F2FE);

  static const _lightPrimary = Color(0xFF394A6C);

  /// True when the dark palette is currently loaded.
  static bool isDark = false;

  /// The accent currently loaded, so [PaletteScope] can skip redundant work.
  static Color accent = _lightPrimary;

  /// Rewrites every token. Call before the frame that should use them.
  static void apply({required Color accent, required bool dark}) {
    AppColors.accent = accent;
    isDark = dark;
    primary = accent;

    if (dark) {
      primarySoft = Color.alphaBlend(
        accent.withValues(alpha: 0.20),
        const Color(0xFF171A23),
      );
      // The sidebar is the accent, pushed very dark — it stays recognisably
      // "the brand colour" without competing with the content beside it.
      sidebar = Color.alphaBlend(
        accent.withValues(alpha: 0.14),
        const Color(0xFF0A0C11),
      );
      sidebarDeep = const Color(0xFF07080C);
      canvas = const Color(0xFF0F1117);
      card = const Color(0xFF171A23);
      border = const Color(0xFF272C3A);
      textStrong = const Color(0xFFE8EAF0);
      textMuted = const Color(0xFF98A2B6);

      success = const Color(0xFF34D399);
      successSoft = const Color(0xFF10291F);
      warning = const Color(0xFFFBBF24);
      warningSoft = const Color(0xFF2C2411);
      danger = const Color(0xFFF87171);
      dangerSoft = const Color(0xFF2E1618);
      info = const Color(0xFF38BDF8);
      infoSoft = const Color(0xFF0E2430);
    } else {
      primarySoft = Color.alphaBlend(
        accent.withValues(alpha: 0.11),
        Colors.white,
      );
      sidebar = Color.alphaBlend(
        accent.withValues(alpha: 0.55),
        const Color(0xFF13112E),
      );
      sidebarDeep = Color.alphaBlend(
        accent.withValues(alpha: 0.35),
        const Color(0xFF0E0C22),
      );
      canvas = const Color(0xFFF6F7FB);
      card = Colors.white;
      border = const Color(0xFFE9EBF3);
      textStrong = const Color(0xFF0F172A);
      textMuted = const Color(0xFF64748B);

      success = const Color(0xFF16A34A);
      successSoft = const Color(0xFFDCFCE7);
      warning = const Color(0xFFF59E0B);
      warningSoft = const Color(0xFFFEF3C7);
      danger = const Color(0xFFDC2626);
      dangerSoft = const Color(0xFFFEE2E2);
      info = const Color(0xFF0EA5E9);
      infoSoft = const Color(0xFFE0F2FE);
    }
  }
}

/// Loads a palette and rebuilds everything below it.
///
/// A StatefulWidget rather than calling [AppColors.apply] inline in a build
/// method: mutating globals during someone else's build is how you get half
/// the tree painted in the old colours.
class PaletteScope extends StatefulWidget {
  final Color accent;
  final bool dark;
  final Widget child;

  const PaletteScope({
    super.key,
    required this.accent,
    required this.dark,
    required this.child,
  });

  @override
  State<PaletteScope> createState() => _PaletteScopeState();
}

class _PaletteScopeState extends State<PaletteScope> {
  @override
  void initState() {
    super.initState();
    AppColors.apply(accent: widget.accent, dark: widget.dark);
  }

  @override
  void didUpdateWidget(PaletteScope old) {
    super.didUpdateWidget(old);
    if (old.accent != widget.accent || old.dark != widget.dark) {
      AppColors.apply(accent: widget.accent, dark: widget.dark);
    }
  }

  @override
  Widget build(BuildContext context) => KeyedSubtree(
    // Re-keying forces a full rebuild when the palette changes, so nothing
    // keeps a colour it read on a previous frame.
    key: ValueKey('${widget.accent.toARGB32()}-${widget.dark}'),
    child: widget.child,
  );
}

/// Builds the Material theme to match whatever [AppColors.apply] last loaded.
///
/// Call it *after* the palette is applied — it reads the tokens rather than
/// duplicating them, so the two can never disagree.
ThemeData buildAppTheme({Color? seed, bool? dark}) {
  final accent = seed ?? AppColors.primary;
  final isDark = dark ?? AppColors.isDark;

  final base = ThemeData(
    useMaterial3: true,
    brightness: isDark ? Brightness.dark : Brightness.light,
    colorScheme: ColorScheme.fromSeed(
      seedColor: accent,
      primary: accent,
      brightness: isDark ? Brightness.dark : Brightness.light,
      surface: AppColors.card,
    ),
    scaffoldBackgroundColor: AppColors.canvas,
    dividerColor: AppColors.border,
  );

  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: AppColors.textStrong,
      displayColor: AppColors.textStrong,
    ),
    cardTheme: CardThemeData(
      color: AppColors.card,
      elevation: 0,
      margin: EdgeInsets.zero,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.card,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: accent, width: 1.6),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: AppColors.danger),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: Colors.white,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: accent,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
        side: BorderSide(color: AppColors.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

/// The white rounded panel used for every block in the dashboard.
class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: child,
    );
  }
}

class SectionHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;
  const SectionHeader(this.title, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

class StatusPill extends StatelessWidget {
  final String label;
  final Color color;
  final Color background;
  const StatusPill(this.label, this.color, this.background, {super.key});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      label,
      style: TextStyle(
        color: color,
        fontSize: 11.5,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}
