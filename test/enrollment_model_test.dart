import 'package:flutter_test/flutter_test.dart';
import 'package:helloworld/models/enrollment.dart';

/// The [Enrollment] shape itself — the deterministic id backfill/promotion
/// rely on to be safely re-runnable, and the two derived facts
/// ([isAllotted], [needsReallotment]) other screens read off it.
void main() {
  Enrollment enrollment({
    String? hostelId,
    String? roomId,
    int? roomCapacity,
    int? requiredCapacity,
  }) => Enrollment(
    id: 'u1_2026-27',
    uid: 'u1',
    session: '2026-27',
    collegeId: 'c1',
    year: 2,
    name: 'Test Student',
    hostelId: hostelId,
    roomId: roomId,
    roomCapacity: roomCapacity,
    requiredCapacity: requiredCapacity,
  );

  group('Enrollment.idFor', () {
    test('joins uid and session with an underscore', () {
      expect(Enrollment.idFor('abc123', '2026-27'), 'abc123_2026-27');
    });

    test('is what backfill/promotion both write to, so re-running overwrites', () {
      // The whole safety property: calling idFor twice with the same
      // arguments always gives the same id.
      expect(
        Enrollment.idFor('abc123', '2026-27'),
        Enrollment.idFor('abc123', '2026-27'),
      );
    });
  });

  group('isAllotted', () {
    test('requires both hostelId and roomId', () {
      expect(enrollment(hostelId: 'h1', roomId: '101').isAllotted, isTrue);
      expect(enrollment(hostelId: 'h1').isAllotted, isFalse);
      expect(enrollment(roomId: '101').isAllotted, isFalse);
      expect(enrollment().isAllotted, isFalse);
    });
  });

  group('needsReallotment', () {
    test('null when no policy applies to this student', () {
      expect(enrollment().needsReallotment, isNull);
      expect(
        enrollment(hostelId: 'h1', roomId: '101', roomCapacity: 3).needsReallotment,
        isNull,
      );
    });

    test('true when unallotted but a policy applies', () {
      expect(
        enrollment(requiredCapacity: 1).needsReallotment,
        isTrue,
      );
    });

    test('true when allotted to the wrong capacity', () {
      expect(
        enrollment(
          hostelId: 'h1',
          roomId: '101',
          roomCapacity: 3,
          requiredCapacity: 1,
        ).needsReallotment,
        isTrue,
      );
    });

    test('false when the room held matches the entitlement', () {
      expect(
        enrollment(
          hostelId: 'h1',
          roomId: '101',
          roomCapacity: 1,
          requiredCapacity: 1,
        ).needsReallotment,
        isFalse,
      );
    });
  });

  group('round-tripping through Firestore\'s map shape', () {
    test('every field survives', () {
      final e = Enrollment(
        id: 'u1_2026-27',
        uid: 'u1',
        session: '2026-27',
        collegeId: 'c1',
        year: 3,
        sem: 5,
        hostelId: 'h1',
        hostelName: 'BH-9',
        roomId: '301',
        roomNumber: '301',
        roomCapacity: 1,
        requiredCapacity: 1,
        name: 'Test Student',
        course: 'UG',
        trade: 'CSE',
        batch: '2024-25',
        enrollmentNo: '2431073',
        gender: 'Male',
      );

      final back = Enrollment.fromMap('u1_2026-27', e.toMap());

      expect(back.uid, 'u1');
      expect(back.session, '2026-27');
      expect(back.year, 3);
      expect(back.sem, 5);
      expect(back.hostelId, 'h1');
      expect(back.roomNumber, '301');
      expect(back.roomCapacity, 1);
      expect(back.requiredCapacity, 1);
      expect(back.course, 'UG');
      expect(back.batch, '2024-25');
    });

    test('a missing year defaults to 1 rather than throwing', () {
      final back = Enrollment.fromMap('x', {'uid': 'u1', 'session': '2026-27'});
      expect(back.year, 1);
    });

    test('a missing name defaults to Unnamed rather than throwing', () {
      final back = Enrollment.fromMap('x', {'uid': 'u1', 'session': '2026-27'});
      expect(back.name, 'Unnamed');
    });
  });
}
