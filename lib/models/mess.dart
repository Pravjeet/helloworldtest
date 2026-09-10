import 'package:cloud_firestore/cloud_firestore.dart';

/// The four things served in a day. Stored by [name] so adding a fifth slot
/// later doesn't rewrite existing documents.
enum Meal { breakfast, lunch, eveningTea, dinner }

extension MealX on Meal {
  String get label => switch (this) {
    Meal.breakfast => 'Breakfast',
    Meal.lunch => 'Lunch',
    Meal.eveningTea => 'Evening Tea',
    Meal.dinner => 'Dinner',
  };

  /// Default serving window, shown until an admin overrides it in the config.
  String get defaultTiming => switch (this) {
    Meal.breakfast => '6:45 AM – 8:15 AM (weekdays) · 8:00 AM – 9:15 AM (Sat, '
        'Sun & holidays)',
    Meal.lunch => '12:30 PM – 2:30 PM (weekdays) · 1:00 PM – 2:30 PM (Sat, '
        'Sun & holidays)',
    Meal.eveningTea => '5:00 PM – 6:00 PM (all days)',
    Meal.dinner => '7:15 PM – 9:00 PM (all days)',
  };

  static Meal parse(String? s) =>
      Meal.values.firstWhere((m) => m.name == s, orElse: () => Meal.breakfast);
}

/// Monday = 1 … Sunday = 7, matching `DateTime.weekday` so "what's on today"
/// is a straight lookup rather than a translation table.
const List<String> kWeekdayNames = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

String weekdayName(int weekday) => kWeekdayNames[(weekday - 1) % 7];

// =====================================================================
// Menu
// =====================================================================

/// The whole week in one document: `colleges/{collegeId}/mess/menu`.
///
/// A single doc rather than seven means the menu page is one read and one
/// stream, and an edit can never leave Tuesday saved but Wednesday not.
class MessMenu {
  /// `weekday (1–7) -> meal.name -> what's served`.
  final Map<int, Map<String, String>> days;

  /// Free-text footnotes shown under the grid — quantities, salad policy, etc.
  final List<String> notes;

  final DateTime? updatedAt;
  final String? updatedByName;

  const MessMenu({
    this.days = const {},
    this.notes = const [],
    this.updatedAt,
    this.updatedByName,
  });

  factory MessMenu.fromMap(Map<String, dynamic> m) {
    final raw = (m['days'] as Map?) ?? const {};
    final days = <int, Map<String, String>>{};
    for (final entry in raw.entries) {
      final weekday = int.tryParse(entry.key.toString());
      if (weekday == null) continue;
      final meals = (entry.value as Map?) ?? const {};
      days[weekday] = {
        for (final e in meals.entries) e.key.toString(): e.value.toString(),
      };
    }
    return MessMenu(
      days: days,
      notes: ((m['notes'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(),
      updatedAt: (m['updatedAt'] as Timestamp?)?.toDate(),
      updatedByName: m['updatedByName'] as String?,
    );
  }

  Map<String, dynamic> toMap() => {
    'days': days.map((k, v) => MapEntry(k.toString(), v)),
    'notes': notes,
  };

  /// What's served for one slot, or null when nothing has been entered yet.
  String? item(int weekday, Meal meal) {
    final text = days[weekday]?[meal.name]?.trim();
    return (text == null || text.isEmpty) ? null : text;
  }

  bool get isEmpty => days.values.every(
    (meals) => meals.values.every((v) => v.trim().isEmpty),
  );

  MessMenu withItem(int weekday, Meal meal, String value) {
    final next = {
      for (final e in days.entries) e.key: Map<String, String>.from(e.value),
    };
    next.putIfAbsent(weekday, () => {})[meal.name] = value;
    return MessMenu(
      days: next,
      notes: notes,
      updatedAt: updatedAt,
      updatedByName: updatedByName,
    );
  }
}

// =====================================================================
// Config (fees)
// =====================================================================

/// `colleges/{collegeId}/mess/config` — what the mess costs and how a rebate
/// is worked out. Only `mess.manage` may write it; everyone may read it,
/// because the student calculator needs the rate.
class MessConfig {
  /// What a resident pays for a full billing period, e.g. 3500.
  final num monthlyCharge;

  /// Days that charge covers. Null = use the real length of the chosen month,
  /// which is the common case (₹3500 over a 31-day month = ₹112.90/day).
  final int? billingDays;

  /// Currency symbol for display. Kept as data so this isn't India-only.
  final String currencySymbol;

  /// Some messes won't grant a rebate for a short absence. 0 = no threshold.
  final int minRebateDays;

  /// `meal.name -> serving window`, overriding [MealX.defaultTiming].
  final Map<String, String> timings;

  /// Shown on the fees card — what's included, how to claim a rebate, etc.
  final String? notes;

  final DateTime? updatedAt;

  const MessConfig({
    this.monthlyCharge = 0,
    this.billingDays,
    this.currencySymbol = '₹',
    this.minRebateDays = 0,
    this.timings = const {},
    this.notes,
    this.updatedAt,
  });

  factory MessConfig.fromMap(Map<String, dynamic> m) => MessConfig(
    monthlyCharge: (m['monthlyCharge'] as num?) ?? 0,
    billingDays: (m['billingDays'] as num?)?.toInt(),
    currencySymbol: m['currencySymbol'] as String? ?? '₹',
    minRebateDays: (m['minRebateDays'] as num?)?.toInt() ?? 0,
    timings: {
      for (final e in ((m['timings'] as Map?) ?? const {}).entries)
        e.key.toString(): e.value.toString(),
    },
    notes: m['notes'] as String?,
    updatedAt: (m['updatedAt'] as Timestamp?)?.toDate(),
  );

  Map<String, dynamic> toMap() => {
    'monthlyCharge': monthlyCharge,
    'billingDays': billingDays,
    'currencySymbol': currencySymbol,
    'minRebateDays': minRebateDays,
    'timings': timings,
    'notes': notes,
  };

  bool get isConfigured => monthlyCharge > 0;

  String timingFor(Meal meal) {
    final t = timings[meal.name]?.trim();
    return (t == null || t.isEmpty) ? meal.defaultTiming : t;
  }

  /// Days used for the per-day rate in [month]: the admin's fixed figure if
  /// one is set, otherwise the actual length of that month.
  int daysFor(DateTime month) =>
      billingDays ?? daysInMonth(month.year, month.month);
}

/// Days in a given month, leap years included. `DateTime(y, m + 1, 0)` rolls
/// back to the last day of month `m`, which handles February without a table.
int daysInMonth(int year, int month) => DateTime(year, month + 1, 0).day;

// =====================================================================
// Rebate maths
// =====================================================================

/// The result of "I was away for N days — what do I actually owe?".
///
/// Pure value type with no Firestore or Flutter in it, so the arithmetic can
/// be unit-tested on its own.
class MessRebate {
  final num monthlyCharge;
  final int daysInMonth;
  final int daysAbsent;
  final int minRebateDays;

  const MessRebate({
    required this.monthlyCharge,
    required this.daysInMonth,
    required this.daysAbsent,
    this.minRebateDays = 0,
  });

  /// Cost of a single day. Guarded against a zero-day month.
  double get perDay => daysInMonth <= 0 ? 0 : monthlyCharge / daysInMonth;

  /// Absent days capped at the month — you can't be away 40 days in June.
  int get effectiveAbsent => daysAbsent.clamp(0, daysInMonth);

  /// A rebate below the mess's threshold isn't granted at all.
  bool get qualifies => effectiveAbsent >= minRebateDays && effectiveAbsent > 0;

  int get daysPresent => daysInMonth - effectiveAbsent;

  double get rebate => qualifies ? perDay * effectiveAbsent : 0;

  double get payable => (monthlyCharge - rebate).clamp(0, monthlyCharge * 1.0);
}

// =====================================================================
// Default menu
// =====================================================================

/// A starting menu, transcribed from the standard institute mess sheet.
/// It is only ever *written* on request — it is not a fallback, so a college
/// that clears a cell sees it cleared rather than silently reverting.
final MessMenu kDefaultMessMenu = MessMenu(
  days: {
    1: {
      Meal.breakfast.name:
          'Stuffed parantha with 100 g curd / 17 g butter / 20 g jam / '
              'boiled egg (1)\nOR 4 bread slices with butter or jam or egg\n'
              'With 200 ml boiled milk or tea, and sprouts (black chana + '
              'sabut moong, 100 g)',
      Meal.lunch.name:
          'Chapati, seasonal green vegetable, rice\nDaal: Rajma\n'
              'Curd 100 g with chaat masala',
      Meal.eveningTea.name: 'Tea',
      Meal.dinner.name:
          'Chapati, rice, fried daal (moong sabut / moong dhuli), '
              'seasonal green vegetable',
    },
    2: {
      Meal.breakfast.name:
          'Plain parathas with aloo sabzi\nOR 4 bread slices with 17 g butter '
              'or 20 g jam or boiled egg (1)\nWith 200 ml boiled milk or tea, '
              'and sprouts (100 g)',
      Meal.lunch.name:
          'Chapati, seasonal green vegetable, rice\nSoy nuggets / vegetable '
              'kofta\nOnion-tomato raita (100 g curd) + papad',
      Meal.eveningTea.name: 'Samosa and tea',
      Meal.dinner.name:
          'Chapati, rice, fried daal (urad sabut), seasonal green vegetable\n'
              'Sweet dish: Halwa',
    },
    3: {
      Meal.breakfast.name:
          'Puri with aloo sabzi, 100 g curd, pickle / chutney\n'
              'With 200 ml boiled milk or tea, and sprouts (100 g)',
      Meal.lunch.name:
          'Chapati, seasonal green vegetable, rice\nDaal: Lobia / Raungi\n'
              'Boondi raita (100 g curd)',
      Meal.eveningTea.name: 'Tea',
      Meal.dinner.name:
          'SPECIAL DINNER — Puri, white chana, shahi paneer (50 g) / chilli '
              'paneer on alternate weeks, fried rice',
    },
    4: {
      Meal.breakfast.name:
          'Dalia and poha\nOR 4 bread slices with 17 g butter or 20 g jam or '
              'boiled egg (1)\nWith 200 ml boiled milk or tea, and sprouts '
              '(100 g)',
      Meal.lunch.name:
          'Chapati, seasonal mixed vegetable, rice\nKarhi pakora',
      Meal.eveningTea.name: 'Bread pakoda and tea',
      Meal.dinner.name:
          'Chapati, rice, fried daal (masur dhuli / masur sabut), seasonal '
              'green vegetable\nSweet: Gulab jamun / rasgulla',
    },
    5: {
      Meal.breakfast.name:
          'Stuffed parantha with 100 g curd / 17 g butter / 20 g jam / '
              'boiled egg (1)\nOR 4 bread slices with butter or jam or egg\n'
              'With 200 ml boiled milk or tea, and sprouts (100 g)',
      Meal.lunch.name:
          'Chapati, seasonal green vegetable, fried rice\nDaal: Black chana\n'
              'Onion-tomato raita (100 g curd) + papad',
      Meal.eveningTea.name: 'Tea',
      Meal.dinner.name:
          'Chapati, rice, fried daal (arhar), seasonal green vegetable',
    },
    6: {
      Meal.breakfast.name:
          'Plain paratha with aloo sabzi\nOR 4 bread slices with 17 g butter '
              'or 20 g jam or boiled egg (1)\nWith 200 ml boiled milk or tea, '
              'and sprouts (100 g)',
      Meal.lunch.name:
          'Chapati, seasonal green vegetable, rice\nMoong sabut\n'
              'Curd 100 g with chaat masala',
      Meal.eveningTea.name: 'Vegetable cutlets and tea',
      Meal.dinner.name:
          'Chapati, rice, rajma, seasonal green vegetable\n'
              'Sweet dish: Fruit custard / kheer',
    },
    7: {
      Meal.breakfast.name:
          'Poha with tomato chutney / idli sambhar / vada sambhar / dalia / '
              'sprouts\nOR 4 bread slices with 17 g butter or 20 g jam or '
              'boiled egg (1)\nWith 200 ml boiled milk or tea, and sprouts '
              '(100 g)',
      Meal.lunch.name:
          'SPECIAL LUNCH — Puri / bhature, rice pulao, white chana, boondi '
              'raita / dry masala aloo',
      Meal.eveningTea.name: 'Tea',
      Meal.dinner.name:
          'Chapati, rice, fried daal (moong chhilke wali), seasonal green '
              'vegetable',
    },
  },
  notes: const [
    'Daal, sabzi, chapati and rice are served in unlimited quantity.',
    'Curd, butter, milk/tea, sweet dish, paneer and eggs are limited quantity.',
    'Salad (3 seasonal items including onion with ¼ lemon), pickle and sweet '
        'saunf are served with both lunch and dinner.',
    'Sprouts (black chana + sabut moong) are served every day with breakfast.',
    'Stuffing in stuffed paranthas varies by day, as per seasonal availability.',
    'The menu may be modified in consultation with the Hostel Mess Committee, '
        'Warden and Chief Warden.',
  ],
);
