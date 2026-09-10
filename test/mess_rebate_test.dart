import 'package:flutter_test/flutter_test.dart';
import 'package:helloworld/models/mess.dart';

void main() {
  group('daysInMonth', () {
    test('handles 31, 30 and February', () {
      expect(daysInMonth(2026, 1), 31);
      expect(daysInMonth(2026, 4), 30);
      expect(daysInMonth(2026, 2), 28);
      expect(daysInMonth(2024, 2), 29); // leap year
      expect(daysInMonth(2026, 12), 31); // month 12 rolls into next year
    });
  });

  group('MessRebate', () {
    // The worked example: ₹3500 over 31 days = ₹112.903… per day.
    const full = MessRebate(
      monthlyCharge: 3500,
      daysInMonth: 31,
      daysAbsent: 0,
    );

    test('per-day rate matches the hand calculation', () {
      expect(full.perDay, closeTo(112.903, 0.001));
    });

    test('no absence means no rebate and the full charge', () {
      expect(full.rebate, 0);
      expect(full.payable, 3500);
      expect(full.daysPresent, 31);
      expect(full.qualifies, isFalse);
    });

    test('ten days away knocks off ten days of charge', () {
      const r = MessRebate(
        monthlyCharge: 3500,
        daysInMonth: 31,
        daysAbsent: 10,
      );
      expect(r.rebate, closeTo(1129.03, 0.01));
      expect(r.payable, closeTo(2370.97, 0.01));
      expect(r.daysPresent, 21);
    });

    test('absence is capped at the length of the month', () {
      const r = MessRebate(
        monthlyCharge: 3500,
        daysInMonth: 30,
        daysAbsent: 45,
      );
      expect(r.effectiveAbsent, 30);
      expect(r.daysPresent, 0);
      expect(r.payable, 0);
    });

    test('a minimum-days rule blocks a short absence', () {
      const short = MessRebate(
        monthlyCharge: 3500,
        daysInMonth: 31,
        daysAbsent: 3,
        minRebateDays: 7,
      );
      expect(short.qualifies, isFalse);
      expect(short.rebate, 0);
      expect(short.payable, 3500);

      const long = MessRebate(
        monthlyCharge: 3500,
        daysInMonth: 31,
        daysAbsent: 7,
        minRebateDays: 7,
      );
      expect(long.qualifies, isTrue);
      expect(long.rebate, closeTo(790.32, 0.01));
    });

    test('a zero-day month cannot divide by zero', () {
      const r = MessRebate(monthlyCharge: 3500, daysInMonth: 0, daysAbsent: 5);
      expect(r.perDay, 0);
      expect(r.rebate, 0);
    });
  });

  group('MessConfig', () {
    test('falls back to the real length of the month', () {
      const c = MessConfig(monthlyCharge: 3500);
      expect(c.daysFor(DateTime(2026, 2)), 28);
      expect(c.daysFor(DateTime(2026, 8)), 31);
    });

    test('a fixed billing period overrides the calendar', () {
      const c = MessConfig(monthlyCharge: 3500, billingDays: 30);
      expect(c.daysFor(DateTime(2026, 2)), 30);
    });
  });

  group('MessMenu', () {
    test('round-trips through a Firestore-shaped map', () {
      final menu = const MessMenu().withItem(1, Meal.dinner, 'Rajma chawal');
      final back = MessMenu.fromMap(menu.toMap());
      expect(back.item(1, Meal.dinner), 'Rajma chawal');
      expect(back.item(2, Meal.dinner), isNull);
      expect(back.isEmpty, isFalse);
    });

    test('blank entries read as null, not empty strings', () {
      final menu = const MessMenu().withItem(3, Meal.lunch, '   ');
      expect(menu.item(3, Meal.lunch), isNull);
      expect(menu.isEmpty, isTrue);
    });

    test('the seeded default covers every meal of every day', () {
      for (var day = 1; day <= 7; day++) {
        for (final meal in Meal.values) {
          expect(
            kDefaultMessMenu.item(day, meal),
            isNotNull,
            reason: '${weekdayName(day)} ${meal.label} is missing',
          );
        }
      }
    });
  });
}
