import 'package:flutter_test/flutter_test.dart';
import 'package:helloworld/models/fee.dart';

FeeRecord _rec({
  String uid = 'a',
  String period = '2026-08',
  num amount = 3500,
  DateTime? paidOn,
}) => FeeRecord(
  id: feeDocId(period, uid),
  studentUid: uid,
  studentName: uid,
  period: period,
  amount: amount,
  paidOn: paidOn,
  recordedByUid: 'clerk',
  recordedByName: 'Clerk',
);

FeeStanding _standing({
  String uid = 'a',
  FeeRecord? record,
}) => FeeStanding(studentUid: uid, studentName: uid, record: record);

void main() {
  group('periods', () {
    test('periodOf pads the month so the string sorts chronologically', () {
      expect(periodOf(DateTime(2026, 8, 3)), '2026-08');
      expect(periodOf(DateTime(2026, 12, 31)), '2026-12');
      // The reason for padding: without it "2026-9" > "2026-12" as a string.
      expect('2026-09'.compareTo('2026-12'), lessThan(0));
    });

    test('periodLabel renders a month, or gives back what it was given', () {
      expect(periodLabel('2026-08'), 'August 2026');
      expect(periodLabel('2026-01'), 'January 2026');
      expect(periodLabel('nonsense'), 'nonsense');
      expect(periodLabel('2026-13'), '2026-13');
    });

    test('recentPeriods walks backwards across a year boundary', () {
      final p = recentPeriods(DateTime(2026, 2, 15), count: 4);
      expect(p, ['2026-02', '2026-01', '2025-12', '2025-11']);
    });

    test('the doc id pins one row per student per month', () {
      expect(feeDocId('2026-08', 'u1'), '2026-08_u1');
      expect(feeDocId('2026-08', 'u1'), feeDocId('2026-08', 'u1'));
      expect(feeDocId('2026-09', 'u1'), isNot(feeDocId('2026-08', 'u1')));
    });
  });

  group('FeeStanding', () {
    test('no record means unpaid — that is the whole rule', () {
      expect(_standing().isPaid, isFalse);
      expect(_standing(record: _rec()).isPaid, isTrue);
    });
  });

  group('FeeSummary', () {
    final summary = FeeSummary(
      standings: [
        _standing(uid: 'a', record: _rec(uid: 'a')),
        _standing(uid: 'b', record: _rec(uid: 'b')),
        _standing(uid: 'c'),
        _standing(uid: 'd'),
      ],
      amountEach: 3500,
    );

    test('counts paid and unpaid', () {
      expect(summary.total, 4);
      expect(summary.paid, 2);
      expect(summary.unpaid, 2);
      expect(summary.paidFraction, 0.5);
    });

    test('collected uses each record, expected uses the current rate', () {
      expect(summary.collected, 7000);
      expect(summary.expected, 14000);
      expect(summary.pending, 7000);
    });

    test('an old record keeps the rate it was collected at', () {
      // The rate rose to 4000, but March was collected at 3000. Totalling at
      // today's rate would overstate what actually came in.
      final s = FeeSummary(
        standings: [_standing(uid: 'a', record: _rec(uid: 'a', amount: 3000))],
        amountEach: 4000,
      );
      expect(s.collected, 3000);
      expect(s.expected, 4000);
    });

    test('an empty month does not divide by zero', () {
      const empty = FeeSummary(standings: [], amountEach: 3500);
      expect(empty.paidFraction, 0);
      expect(empty.pending, 0);
      expect(empty.total, 0);
    });

    test('pending never goes negative when overcollected', () {
      // Everyone paid at the old higher rate, then the rate dropped.
      final s = FeeSummary(
        standings: [_standing(uid: 'a', record: _rec(uid: 'a', amount: 5000))],
        amountEach: 3500,
      );
      expect(s.pending, 0);
    });
  });
}
