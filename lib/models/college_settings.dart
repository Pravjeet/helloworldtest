import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'app_user.dart';
import 'fine.dart';

/// Everything an admin can configure about their workspace.
///
/// One document — `colleges/{collegeId}/settings/config` — rather than a
/// collection, because there is exactly one of each of these at any time.
/// Same reasoning as the mess module's `menu` and `config` docs.
///
/// Every field has a working default, so a workspace that has never opened
/// this screen behaves identically to one that has.
class CollegeSettings {
  final InstitutionProfile institution;
  final AppTheming theming;
  final AcademicSession session;

  /// Overrides [kFineCategories]. Empty means "use the built-in list".
  final List<FineCategory> fineCategories;

  /// The college's own trade/branch list. Empty means "use [kTrades]", so a
  /// workspace that has never opened this screen still gets a sensible
  /// dropdown. Once edited, this is the authoritative list everywhere.
  final List<Trade> trades;

  /// How many years each course runs — "M.Sc" -> 2, "B.E." -> 4, and so on.
  /// Empty means nobody has configured this yet; [totalYearsFor] falls back
  /// to a sane guess rather than refusing to compute a year at all.
  final List<ProgramLength> programs;

  final DateTime? updatedAt;
  final String? updatedByName;

  const CollegeSettings({
    this.institution = const InstitutionProfile(),
    this.theming = const AppTheming(),
    this.session = const AcademicSession(),
    this.fineCategories = const [],
    this.trades = const [],
    this.programs = const [],
    this.updatedAt,
    this.updatedByName,
  });

  factory CollegeSettings.fromMap(Map<String, dynamic> m) => CollegeSettings(
    institution: InstitutionProfile.fromMap(
      (m['institution'] as Map?)?.cast<String, dynamic>() ?? const {},
    ),
    theming: AppTheming.fromMap(
      (m['theming'] as Map?)?.cast<String, dynamic>() ?? const {},
    ),
    session: AcademicSession.fromMap(
      (m['session'] as Map?)?.cast<String, dynamic>() ?? const {},
    ),
    fineCategories: ((m['fineCategories'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => FineCategory.fromMap(e.cast<String, dynamic>()))
        .toList(),
    trades: ((m['trades'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Trade.fromMap(e.cast<String, dynamic>()))
        .toList(),
    programs: ((m['programs'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => ProgramLength.fromMap(e.cast<String, dynamic>()))
        .toList(),
    updatedAt: (m['updatedAt'] as Timestamp?)?.toDate(),
    updatedByName: m['updatedByName'] as String?,
  );

  Map<String, dynamic> toMap() => {
    'institution': institution.toMap(),
    'theming': theming.toMap(),
    'session': session.toMap(),
    'fineCategories': fineCategories.map((c) => c.toMap()).toList(),
    'trades': trades.map((t) => t.toMap()).toList(),
    'programs': programs.map((p) => p.toMap()).toList(),
  };

  /// Course lengths a brand-new workspace starts with, keyed by the same
  /// free-text course names the rest of the app already stores on a student
  /// (see `AppUser.course`). Matched case-insensitively by [totalYearsFor].
  static const Map<String, int> _builtInProgramLengths = {
    'B.E.': 4,
    'B.Tech': 4,
    'Diploma': 3,
    'M.Tech': 2,
    'M.Sc': 2,
    'PhD': 6,
  };

  /// How many years [course] runs. Falls back to the built-in guess for a
  /// recognised course name, then to 4 — wrong for some programmes, but a
  /// wrong-but-present number lets promotion flag it for review instead of
  /// crashing on a course nobody has configured yet.
  int totalYearsFor(String? course) {
    final c = course?.trim() ?? '';
    for (final p in programs) {
      if (p.course.toLowerCase() == c.toLowerCase()) return p.totalYears;
    }
    for (final entry in _builtInProgramLengths.entries) {
      if (entry.key.toLowerCase() == c.toLowerCase()) return entry.value;
    }
    return 4;
  }

  /// The category names the impose-fine form should offer. Falls back to the
  /// built-in list so the form is never empty.
  List<String> get categoryNames => fineCategories.isEmpty
      ? kFineCategories
      : fineCategories.map((c) => c.name).toList();

  /// The trade codes every dropdown in the app should offer. Falls back to
  /// [kTrades] so the form is never empty.
  List<String> get tradeCodes =>
      trades.isEmpty ? kTrades : trades.map((t) => t.code).toList();

  /// "GIN — Instrumentation & Control", using the college's own name for it
  /// where they've set one, otherwise the built-in name, otherwise the bare
  /// code.
  String tradeLabelFor(String code) {
    for (final t in trades) {
      if (t.code == code) return t.label;
    }
    return tradeLabel(code);
  }

  num? defaultAmountFor(String category) {
    for (final c in fineCategories) {
      if (c.name == category) return c.defaultAmount;
    }
    return null;
  }

  CollegeSettings copyWith({
    InstitutionProfile? institution,
    AppTheming? theming,
    AcademicSession? session,
    List<FineCategory>? fineCategories,
    List<Trade>? trades,
    List<ProgramLength>? programs,
  }) => CollegeSettings(
    institution: institution ?? this.institution,
    theming: theming ?? this.theming,
    session: session ?? this.session,
    fineCategories: fineCategories ?? this.fineCategories,
    trades: trades ?? this.trades,
    programs: programs ?? this.programs,
    updatedAt: updatedAt,
    updatedByName: updatedByName,
  );
}

// =====================================================================
// Program lengths
// =====================================================================

/// How many years one course runs — the only fact `yearFromBatch` and
/// promotion need to tell "still enrolled" from "should have graduated".
///
/// Kept as an editable list on the settings document (same shape as [Trade]
/// and [FineCategory]) rather than a Firestore collection: a college has a
/// handful of courses, an admin edits this rarely, and every reader already
/// has the settings document in hand — no extra read, no extra rules block.
class ProgramLength {
  final String course;
  final int totalYears;

  const ProgramLength({required this.course, required this.totalYears});

  factory ProgramLength.fromMap(Map<String, dynamic> m) => ProgramLength(
    course: (m['course'] as String? ?? '').trim(),
    totalYears: (m['totalYears'] as num?)?.toInt() ?? 4,
  );

  Map<String, dynamic> toMap() => {'course': course, 'totalYears': totalYears};
}

// =====================================================================
// Trades
// =====================================================================

/// One trade/branch a college runs — the short code students are recorded
/// under, plus an optional human name for it.
///
/// The code is what gets stored on a student and snapshotted onto a fine, so
/// it must stay stable; the name is presentation only and can be reworded
/// freely without touching a single existing record.
class Trade {
  final String code;

  /// Optional. Null falls back to the built-in name for a known code, or to
  /// showing the bare code.
  final String? name;

  const Trade({required this.code, this.name});

  factory Trade.fromMap(Map<String, dynamic> m) => Trade(
    code: (m['code'] as String? ?? '').trim(),
    name: (m['name'] as String?)?.trim().isEmpty == true
        ? null
        : m['name'] as String?,
  );

  Map<String, dynamic> toMap() => {'code': code, 'name': name};

  String get label {
    final n = name?.trim();
    if (n != null && n.isNotEmpty) return '$code — $n';
    return tradeLabel(code);
  }

  /// The built-in list, as editable rows to start from.
  static List<Trade> get defaults =>
      kTrades.map((c) => Trade(code: c, name: kTradeNames[c])).toList();
}

// =====================================================================
// Institution
// =====================================================================

class InstitutionProfile {
  final String? shortName;
  final String? address;
  final String? contactEmail;
  final String? contactPhone;
  final String? website;

  /// Line printed under the title on the fines dashboard and reports.
  final String? tagline;

  /// The college's own mark, base64-encoded straight into the settings
  /// document — same trade-off as an office order's photo: there's no
  /// Firebase Storage on the free plan, and a logo is small enough that it
  /// doesn't matter. Null falls back to the drawn [HomiLogo].
  final String? logoBase64;

  /// MIME type of [logoBase64], e.g. `image/png`.
  final String? logoMimeType;

  const InstitutionProfile({
    this.shortName,
    this.address,
    this.contactEmail,
    this.contactPhone,
    this.website,
    this.tagline,
    this.logoBase64,
    this.logoMimeType,
  });

  factory InstitutionProfile.fromMap(Map<String, dynamic> m) =>
      InstitutionProfile(
        shortName: m['shortName'] as String?,
        address: m['address'] as String?,
        contactEmail: m['contactEmail'] as String?,
        contactPhone: m['contactPhone'] as String?,
        website: m['website'] as String?,
        tagline: m['tagline'] as String?,
        logoBase64: m['logoBase64'] as String?,
        logoMimeType: m['logoMimeType'] as String?,
      );

  Map<String, dynamic> toMap() => {
    'shortName': shortName,
    'address': address,
    'contactEmail': contactEmail,
    'contactPhone': contactPhone,
    'website': website,
    'tagline': tagline,
    'logoBase64': logoBase64,
    'logoMimeType': logoMimeType,
  };

  bool get hasLogo => logoBase64 != null && logoBase64!.isNotEmpty;
}

// =====================================================================
// Theming
// =====================================================================

/// A named accent colour.
///
/// Presets rather than a free colour picker on purpose: an arbitrary hex lets
/// someone choose a yellow that makes white button text unreadable. Each of
/// these is dark enough to carry white text at the contrast ratio the rest of
/// the app assumes.
class ThemePreset {
  final String id;
  final String label;
  final Color color;
  const ThemePreset(this.id, this.label, this.color);
}

const List<ThemePreset> kThemePresets = [
  // The app's default accent. Not the first preset historically (that was
  // indigo, kept below for workspaces that already picked it) — this is a
  // deliberate choice, not a placeholder that never got revisited.
  ThemePreset('navy', 'Navy', Color(0xFF394A6C)),
  ThemePreset('indigo', 'Indigo', Color(0xFF4F46E5)),
  ThemePreset('violet', 'Violet', Color(0xFF7C3AED)),
  ThemePreset('blue', 'Blue', Color(0xFF2563EB)),
  ThemePreset('teal', 'Teal', Color(0xFF0D9488)),
  ThemePreset('emerald', 'Emerald', Color(0xFF059669)),
  ThemePreset('rose', 'Rose', Color(0xFFE11D48)),
  ThemePreset('amber', 'Amber', Color(0xFFB45309)),
  ThemePreset('slate', 'Slate', Color(0xFF334155)),
  ThemePreset('steel', 'Steel', Color(0xFF58799F)),
];

/// Light, dark, or follow the device.
enum AppBrightness { light, dark, system }

extension AppBrightnessX on AppBrightness {
  String get label => switch (this) {
    AppBrightness.light => 'Light',
    AppBrightness.dark => 'Dark',
    AppBrightness.system => 'Match device',
  };

  IconData get icon => switch (this) {
    AppBrightness.light => Icons.light_mode_rounded,
    AppBrightness.dark => Icons.dark_mode_rounded,
    AppBrightness.system => Icons.brightness_auto_rounded,
  };

  static AppBrightness parse(String? raw) => switch (raw) {
    'dark' => AppBrightness.dark,
    'system' => AppBrightness.system,
    _ => AppBrightness.light,
  };

  /// Resolves [AppBrightness.system] against what the device reports.
  bool isDark(Brightness platform) => switch (this) {
    AppBrightness.light => false,
    AppBrightness.dark => true,
    AppBrightness.system => platform == Brightness.dark,
  };
}

class AppTheming {
  /// One of [kThemePresets]. Unknown ids fall back to the first preset.
  final String presetId;

  final AppBrightness brightness;

  const AppTheming({
    this.presetId = 'navy',
    this.brightness = AppBrightness.light,
  });

  factory AppTheming.fromMap(Map<String, dynamic> m) => AppTheming(
    presetId: m['presetId'] as String? ?? 'navy',
    brightness: AppBrightnessX.parse(m['brightness'] as String?),
  );

  Map<String, dynamic> toMap() => {
    'presetId': presetId,
    'brightness': brightness.name,
  };

  ThemePreset get preset => kThemePresets.firstWhere(
    (p) => p.id == presetId,
    orElse: () => kThemePresets.first,
  );

  Color get seed => preset.color;

  AppTheming copyWith({String? presetId, AppBrightness? brightness}) =>
      AppTheming(
        presetId: presetId ?? this.presetId,
        brightness: brightness ?? this.brightness,
      );
}

// =====================================================================
// Academic session
// =====================================================================

class AcademicSession {
  /// "2026-27".
  final String? current;

  /// "2027-28" — set once, ahead of time, so the promotion screen can show
  /// what it's about to switch to before anyone clicks the button.
  final String? next;

  /// Which half of the year is running. Drives the default Sem filter.
  final bool oddSemester;

  const AcademicSession({this.current, this.next, this.oddSemester = true});

  factory AcademicSession.fromMap(Map<String, dynamic> m) => AcademicSession(
    current: m['current'] as String?,
    next: m['next'] as String?,
    oddSemester: m['oddSemester'] as bool? ?? true,
  );

  Map<String, dynamic> toMap() => {
    'current': current,
    'next': next,
    'oddSemester': oddSemester,
  };

  /// Semesters running in this half of the year — 1,3,5,7 or 2,4,6,8.
  List<int> get activeSems =>
      oddSemester ? const [1, 3, 5, 7] : const [2, 4, 6, 8];

  String get label => current == null
      ? (oddSemester ? 'Odd semester' : 'Even semester')
      : '$current · ${oddSemester ? 'Odd' : 'Even'} semester';
}

// =====================================================================
// Fine categories
// =====================================================================

class FineCategory {
  final String name;

  /// Pre-filled on the impose form. Null means "type it every time".
  final num? defaultAmount;

  const FineCategory({required this.name, this.defaultAmount});

  factory FineCategory.fromMap(Map<String, dynamic> m) => FineCategory(
    name: m['name'] as String? ?? '',
    defaultAmount: m['defaultAmount'] as num?,
  );

  Map<String, dynamic> toMap() => {
    'name': name,
    'defaultAmount': defaultAmount,
  };

  /// The built-in list, as editable rows to start from.
  static List<FineCategory> get defaults =>
      kFineCategories.map((c) => FineCategory(name: c)).toList();
}
