import 'package:flutter_test/flutter_test.dart';
import 'package:helloworld/models/college_settings.dart';
import 'package:helloworld/utils/enrollment_helpers.dart';

/// The Reset session button in System Settings writes `const AcademicSession()`
/// and nothing else, so what that value round-trips to is the whole contract.
///
/// The distinction these pin is null vs `''`. Academic Records decides whether
/// to show its "No academic session set" screen by testing `current == null`,
/// so an empty string would slip past it and render a blank session name into
/// "Backfill " — a page that looks broken rather than un-set.
void main() {
  group('a reset academic session', () {
    test('is null, not an empty string', () {
      const reset = AcademicSession();

      expect(reset.current, isNull);
      expect(reset.next, isNull);
      // Not `''`: the empty-state check is a null test, and '' is not null.
      expect(reset.current, isNot(''));
    });

    test('survives the trip through Firestore as null', () {
      // saveSection writes toMap() with merge:true, so the nulls are written
      // explicitly and read back by fromMap on the next snapshot.
      final back = AcademicSession.fromMap(const AcademicSession().toMap());

      expect(back.current, isNull);
      expect(back.next, isNull);
    });

    test('returns the semester to Odd', () {
      const reset = AcademicSession();

      expect(reset.oddSemester, isTrue);
      expect(reset.activeSems, [1, 3, 5, 7]);
    });

    test('labels itself without a session name', () {
      expect(const AcademicSession().label, 'Odd semester');
    });
  });

  group('a session that was set', () {
    test('round-trips both halves', () {
      final back = AcademicSession.fromMap(
        const AcademicSession(
          current: '2026-27',
          next: '2027-28',
          oddSemester: false,
        ).toMap(),
      );

      expect(back.current, '2026-27');
      expect(back.next, '2027-28');
      expect(back.oddSemester, isFalse);
      expect(back.activeSems, [2, 4, 6, 8]);
    });

    test('a bare year does not parse, which is what breaks backfill', () {
      // The real incident: "2026" typed instead of "2026-27". The session is
      // stored happily — nothing validates it — and then every student fails
      // yearFromBatch against it, so backfill writes nothing and reports all
      // of them as needing a batch fix.
      expect(startYearOf('2026'), isNull);
      expect(yearFromBatch('2021-22', '2026'), isNull);

      // The same batch against a well-formed session resolves fine.
      expect(yearFromBatch('2021-22', '2026-27'), 6);
    });
  });
}
