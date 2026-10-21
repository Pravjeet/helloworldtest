import 'package:flutter_test/flutter_test.dart';
import 'package:helloworld/models/app_user.dart';

/// LEET vs Regular is derived, never stored, so the rule itself is pinned:
/// it drives a filter on Student Overview and Room Allotment, and through the
/// latter, who auto-allot puts into a hostel.
void main() {
  AppUser student({
    String? course = 'UG',
    String? batch,
    String? admissionYear,
  }) => AppUser(
    uid: 'u',
    name: 'Student',
    email: 'u@x.test',
    collegeId: 'c1',
    roleId: 'r1',
    roleName: 'Student',
    course: course,
    batch: batch,
    admissionYear: admissionYear,
  );

  group('entryTypeOf', () {
    test('admitted the same year as the batch is Regular', () {
      expect(
        entryTypeOf(student(batch: '2024-25', admissionYear: '2024-25')),
        kEntryRegular,
      );
    });

    test('admitted a year after the batch is LEET', () {
      // Joined straight into 2nd year with the 2024-25 batch.
      expect(
        entryTypeOf(student(batch: '2024-25', admissionYear: '2025-26')),
        kEntryLeet,
      );
    });

    test('only graduation has lateral entry, however it is cased', () {
      expect(
        entryTypeOf(
          student(course: 'ug', batch: '2024-25', admissionYear: '2025-26'),
        ),
        kEntryLeet,
      );
      // An ICD student admitted late is a repeater or a data quirk, not LEET.
      expect(
        entryTypeOf(
          student(course: 'ICD', batch: '2023-24', admissionYear: '2024-25'),
        ),
        isNull,
      );
      expect(
        entryTypeOf(
          student(course: 'PG', batch: '2025-26', admissionYear: '2025-26'),
        ),
        isNull,
      );
    });

    test('missing or malformed years give no answer rather than a guess', () {
      expect(entryTypeOf(student(batch: '2024-25')), isNull);
      expect(entryTypeOf(student(admissionYear: '2024-25')), isNull);
      expect(
        entryTypeOf(student(batch: 'unknown', admissionYear: '2024-25')),
        isNull,
      );
    });
  });
}
