import 'package:flutter_test/flutter_test.dart';
import 'package:helloworld/models/enrollment.dart';

void main() {
  group('Enrollment.idFor', () {
    test('joins uid and session with an underscore', () {
      expect(Enrollment.idFor('abc123', '2026-27'), 'abc123_2026-27');
    });
  });

  group('Enrollment.needsReallotment', () {
    Enrollment build({int? roomCapacity, int? requiredCapacity}) => Enrollment(
      id: 'x',
      uid: 'u',
      session: '2026-27',
      collegeId: 'c',
      year: 3,
      name: 'Test Student',
      roomCapacity: roomCapacity,
      requiredCapacity: requiredCapacity,
    );

    test('null when the policy has no opinion on this course', () {
      final e = build(roomCapacity: 3, requiredCapacity: null);
      expect(e.needsReallotment, isNull);
    });

    test('false when the held room matches the entitlement', () {
      final e = build(roomCapacity: 1, requiredCapacity: 1);
      expect(e.needsReallotment, isFalse);
    });

    test('true when unallotted but a policy applies', () {
      final e = build(roomCapacity: null, requiredCapacity: 3);
      expect(e.needsReallotment, isTrue);
    });

    test('true when allotted to the wrong capacity', () {
      final e = build(roomCapacity: 3, requiredCapacity: 1);
      expect(e.needsReallotment, isTrue);
    });
  });

  group('Enrollment.isAllotted', () {
    test('requires both hostelId and roomId', () {
      const withBoth = Enrollment(
        id: 'x',
        uid: 'u',
        session: '2026-27',
        collegeId: 'c',
        year: 1,
        name: 'A',
        hostelId: 'h1',
        roomId: 'r1',
      );
      const missingRoom = Enrollment(
        id: 'x',
        uid: 'u',
        session: '2026-27',
        collegeId: 'c',
        year: 1,
        name: 'A',
        hostelId: 'h1',
      );
      expect(withBoth.isAllotted, isTrue);
      expect(missingRoom.isAllotted, isFalse);
    });
  });
}
