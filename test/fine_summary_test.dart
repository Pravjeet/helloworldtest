import 'package:flutter_test/flutter_test.dart';
import 'package:helloworld/models/fine.dart';

Fine _fine({
  String student = 'A',
  String? hostel = 'BH-01',
  String? trade = 'GCS',
  String? batch = '2023-24',
  int? sem = 3,
  String? state = 'Punjab',
  num amount = 100,
  FineStatus status = FineStatus.pending,
}) => Fine(
  id: 'x',
  studentUid: student,
  studentName: student,
  hostelName: hostel,
  trade: trade,
  batch: batch,
  sem: sem,
  state: state,
  amount: amount,
  category: 'Discipline',
  status: status,
  imposedByUid: 'w',
  imposedByName: 'Warden',
);

void main() {
  group('FineSummary totals', () {
    final summary = FineSummary([
      _fine(amount: 500),
      _fine(amount: 300, status: FineStatus.paid),
      _fine(amount: 200, status: FineStatus.waived),
    ]);

    test('total counts every fine regardless of status', () {
      expect(summary.count, 3);
      expect(summary.total, 1000);
    });

    test('a waived fine is on the record but is not owed', () {
      expect(summary.outstanding, 500);
      expect(summary.collected, 300);
    });
  });

  group('FineSummary bucketing', () {
    final summary = FineSummary([
      _fine(hostel: 'BH-01', amount: 100),
      _fine(hostel: 'BH-02', amount: 400),
      _fine(hostel: 'BH-01', amount: 150),
    ]);

    test('sums per bucket and ranks highest first', () {
      final ranked = summary.sumBy((f) => f.hostelName);
      expect(ranked.map((e) => e.key).toList(), ['BH-02', 'BH-01']);
      expect(ranked.map((e) => e.value).toList(), [400, 250]);
    });

    test('counts per bucket', () {
      final ranked = summary.countBy((f) => f.hostelName);
      expect(ranked.first.key, 'BH-01');
      expect(ranked.first.value, 2);
    });

    test('limit keeps only the top N', () {
      expect(summary.sumBy((f) => f.hostelName, limit: 1).length, 1);
    });
  });

  test('a missing value collapses into one bucket, never dropped', () {
    final summary = FineSummary([
      _fine(trade: 'GCS', amount: 100),
      _fine(trade: null, amount: 60),
      _fine(trade: '', amount: 40),
    ]);

    final ranked = summary.sumBy((f) => f.trade, unknownLabel: 'No trade');
    // Both the null and the empty string land in the same bucket, so the
    // chart's bars still add up to the headline total.
    expect(ranked.length, 2);
    expect(
      ranked.fold<num>(0, (acc, e) => acc + e.value),
      summary.total,
    );
    expect(ranked.firstWhere((e) => e.key == 'No trade').value, 100);
  });

  group('defaultersBy counts students, not fines', () {
    // Anil has three fines from Punjab; Bina and Chetan have one each from
    // Bihar. Ranking by fine count would put Punjab top with 3 to Bihar's 2 —
    // but Punjab has ONE defaulter and Bihar has two.
    final summary = FineSummary([
      _fine(student: 'anil', state: 'Punjab', amount: 100),
      _fine(student: 'anil', state: 'Punjab', amount: 100),
      _fine(student: 'anil', state: 'Punjab', amount: 100),
      _fine(student: 'bina', state: 'Bihar', amount: 100),
      _fine(student: 'chetan', state: 'Bihar', amount: 100),
    ]);

    test('a repeat offender counts once', () {
      final ranked = summary.defaultersBy((f) => f.state);
      expect(ranked.first.key, 'Bihar');
      expect(ranked.first.value, 2);
      expect(ranked.last.key, 'Punjab');
      expect(ranked.last.value, 1);
    });

    test('counting fines instead would rank them the other way round', () {
      final byFines = summary.countBy((f) => f.state);
      expect(byFines.first.key, 'Punjab');
      expect(byFines.first.value, 3);
    });

    test('a missing state still forms an honest bucket', () {
      final s = FineSummary([
        _fine(student: 'a', state: null),
        _fine(student: 'b', state: null),
      ]);
      final ranked = s.defaultersBy((f) => f.state, unknownLabel: 'Not set');
      expect(ranked.single.key, 'Not set');
      expect(ranked.single.value, 2);
    });
  });

  test('valuesOf lists distinct non-empty values for a filter dropdown', () {
    final summary = FineSummary([
      _fine(batch: '2023-24'),
      _fine(batch: '2022-23'),
      _fine(batch: '2023-24'),
      _fine(batch: null),
    ]);
    expect(summary.valuesOf((f) => f.batch), ['2022-23', '2023-24']);
  });
}
