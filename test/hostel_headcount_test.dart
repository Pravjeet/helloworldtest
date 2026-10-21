import 'package:flutter_test/flutter_test.dart';
import 'package:helloworld/models/app_user.dart';
import 'package:helloworld/models/enrollment.dart';
import 'package:helloworld/models/hostel.dart';

/// Students per hostel, counted from the roster.
///
/// Deliberately independent of `occupiedBeds`, which is denormalised onto the
/// hostel document by the allotment transaction. The two should agree now that
/// every student is given a hostel and a room together — and because this one
/// is derived from the students themselves, a disagreement means the stored
/// counter has drifted, not the roster.
void main() {
  AppUser student(
    String uid, {
    String? hostelId,
    String? roomId,
    bool isActive = true,
    bool graduated = false,
  }) => AppUser(
    uid: uid,
    name: uid,
    email: '$uid@x.test',
    collegeId: 'c1',
    roleId: 'r1',
    roleName: 'Student',
    isActive: isActive,
    status: graduated ? 'graduated' : 'active',
    hostelId: hostelId,
    roomId: roomId,
    roomNumber: roomId,
  );

  group('studentsByHostel', () {
    test('counts everyone attached to a hostel', () {
      final counts = studentsByHostel([
        student('a', hostelId: 'h1', roomId: '101'),
        student('b', hostelId: 'h1', roomId: '101'),
        student('c', hostelId: 'h1', roomId: '102'),
      ]);

      expect(counts['h1'], 3);
    });

    test('keeps hostels apart', () {
      final counts = studentsByHostel([
        student('a', hostelId: 'h1', roomId: '101'),
        student('b', hostelId: 'h2', roomId: '201'),
        student('c', hostelId: 'h2', roomId: '202'),
      ]);

      expect(counts['h1'], 1);
      expect(counts['h2'], 2);
    });

    test('ignores students with no hostel', () {
      final counts = studentsByHostel([
        student('a'),
        student('b', hostelId: ''),
        student('c', hostelId: 'h1', roomId: '101'),
      ]);

      expect(counts.keys, ['h1']);
      expect(counts['h1'], 1);
    });

    test('excludes deactivated accounts', () {
      // They cannot hold a bed, so counting them would show a hostel as
      // fuller than it can actually be filled.
      final counts = studentsByHostel([
        student('a', hostelId: 'h1', roomId: '101'),
        student('b', hostelId: 'h1', roomId: '102', isActive: false),
      ]);

      expect(counts['h1'], 1);
    });

    test('excludes graduates — promotion is what moves the head-count', () {
      // A graduate still carrying a hostel would otherwise keep a block
      // looking occupied long after they left, and the Hostels page would
      // disagree with Student Overview, which lists current students only.
      final counts = studentsByHostel([
        student('a', hostelId: 'h1', roomId: '101'),
        student('b', hostelId: 'h1', roomId: '102', graduated: true),
        student('c', hostelId: 'h2', roomId: '201', graduated: true),
      ]);

      expect(counts['h1'], 1);
      expect(counts['h2'], isNull);
    });

    test('a hostel with nobody in it is absent, not zero', () {
      final counts = studentsByHostel([student('a', hostelId: 'h1')]);

      expect(counts['h2'], isNull);
      // Callers read a missing key as zero.
      expect(counts['h2'] ?? 0, 0);
    });

    test('an empty roster yields no entries', () {
      expect(studentsByHostel(const []), isEmpty);
    });

    test('counts a student whose room is not yet set', () {
      // Not a state the app creates deliberately any more, but an import with
      // a blank room cell still produces it, and such a student is genuinely
      // in the hostel — they just show up in Room Allotment as pending.
      final counts = studentsByHostel([
        student('a', hostelId: 'h1', roomId: '101'),
        student('b', hostelId: 'h1'),
      ]);

      expect(counts['h1'], 2);
    });

    test('scales over a full intake', () {
      final roster = [
        for (var i = 0; i < 400; i++)
          student('s$i', hostelId: 'h1', roomId: '${100 + i}'),
      ];

      expect(studentsByHostel(roster)['h1'], 400);
    });
  });

  group('studentsByHostelFor', () {
    // The past-session counterpart to studentsByHostel, used while browsing
    // history — see Session.viewingSession. Same shape, deliberately
    // different rule on one point: no isActive filter, because deactivation
    // is a live-account concept with nothing to say about who was actually
    // housed in a session that already happened.
    Enrollment enrolled(String uid, {String? hostelId, String? roomId}) =>
        Enrollment(
          id: '${uid}_2025-26',
          uid: uid,
          session: '2025-26',
          collegeId: 'c1',
          year: 1,
          name: uid,
          hostelId: hostelId,
          roomId: roomId,
        );

    test('counts everyone attached to a hostel that session', () {
      final counts = studentsByHostelFor([
        enrolled('a', hostelId: 'h1', roomId: '101'),
        enrolled('b', hostelId: 'h1', roomId: '101'),
        enrolled('c', hostelId: 'h1', roomId: '102'),
      ]);

      expect(counts['h1'], 3);
    });

    test('keeps hostels apart', () {
      final counts = studentsByHostelFor([
        enrolled('a', hostelId: 'h1'),
        enrolled('b', hostelId: 'h2'),
        enrolled('c', hostelId: 'h2'),
      ]);

      expect(counts['h1'], 1);
      expect(counts['h2'], 2);
    });

    test('ignores enrollments with no hostel', () {
      final counts = studentsByHostelFor([
        enrolled('a'),
        enrolled('b', hostelId: ''),
        enrolled('c', hostelId: 'h1'),
      ]);

      expect(counts.keys, ['h1']);
    });

    test(
      'does NOT exclude anyone by activity — a graduate is still counted '
      'for the session they were actually enrolled in',
      () {
        // The whole reason this function exists rather than reusing
        // studentsByHostel: those 765 graduates are inactive-by-status only
        // in the live sense, and 2025-26 genuinely had them.
        final counts = studentsByHostelFor([
          enrolled('a', hostelId: 'h1'),
          enrolled('b', hostelId: 'h1'),
        ]);

        expect(counts['h1'], 2);
      },
    );

    test('an empty roster yields no entries', () {
      expect(studentsByHostelFor(const []), isEmpty);
    });
  });
}
