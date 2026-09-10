import 'package:flutter_test/flutter_test.dart';
import 'package:helloworld/utils/enrollment_helpers.dart';

void main() {
  group('startYearOf', () {
    test('reads the start year out of a batch/session span', () {
      expect(startYearOf('2025-27'), 2025);
      expect(startYearOf('2026-27'), 2026);
    });

    test('returns null for anything that does not parse', () {
      expect(startYearOf(null), isNull);
      expect(startYearOf(''), isNull);
      expect(startYearOf('garbage'), isNull);
      expect(startYearOf('-27'), isNull);
    });
  });

  group('yearFromBatch', () {
    test('a regular BE student in the batch\'s first session is Year 1', () {
      expect(yearFromBatch('2025-29', '2025-26'), 1);
    });

    test('the real M.Sc example: batch 2025-27, session 2026-27 is Year 2', () {
      // Matches an actual seeded student document: course M.Sc (2 years),
      // batch "2025-27", year stored as "2nd" once the 2026-27 session
      // started.
      expect(yearFromBatch('2025-27', '2026-27'), 2);
    });

    test('a lateral entrant carries the batch of the cohort ahead of them', () {
      // Both a regular BE student (batch 2023-27) and a lateral entrant who
      // joined in 2025 but was placed in that same 2023-27 cohort land on
      // the same year for the same session — no separate "lateral" branch.
      expect(yearFromBatch('2023-27', '2025-26'), 3);
      expect(yearFromBatch('2023-27', '2025-26'), 3);
    });

    test('works identically for a shorter course', () {
      expect(yearFromBatch('2024-27', '2026-27'), 3); // Diploma, 3 years
      expect(yearFromBatch('2024-26', '2025-26'), 2); // M.Tech, 2 years
    });

    test('returns null when batch or session does not parse', () {
      expect(yearFromBatch(null, '2026-27'), isNull);
      expect(yearFromBatch('2025-27', null), isNull);
      expect(yearFromBatch('not-a-batch', '2026-27'), isNull);
    });
  });

  group('nextSessionAfter', () {
    test('advances a session string by one year', () {
      expect(nextSessionAfter('2026-27'), '2027-28');
      expect(nextSessionAfter('2099-00'), '2100-01');
    });

    test('returns null for an unparseable session', () {
      expect(nextSessionAfter(null), isNull);
      expect(nextSessionAfter(''), isNull);
    });
  });

  group('hasGraduated', () {
    test('is false while the student is still within the course length', () {
      expect(hasGraduated(1, 4), isFalse);
      expect(hasGraduated(4, 4), isFalse);
    });

    test('is true once the year runs past the course length', () {
      expect(hasGraduated(5, 4), isTrue);
    });

    test('follows the year, not the batch — a repeater graduates late', () {
      // A student stuck in Year 2 for two sessions in a 4-year course is
      // still not graduated; the check only cares about the year reached.
      expect(hasGraduated(2, 4), isFalse);
    });
  });

  group('requiredRoomCapacity', () {
    test('Diploma is always 3-Seater, all three years', () {
      for (final year in [1, 2, 3]) {
        expect(
          requiredRoomCapacity(
            course: 'Diploma',
            year: year,
            singleRoomEligible: true, // must not matter for Diploma
          ),
          3,
          reason: 'Diploma year $year',
        );
      }
    });

    test('B.E. year 1 and 2 are always 3-Seater, merit or not', () {
      for (final year in [1, 2]) {
        expect(
          requiredRoomCapacity(course: 'B.E.', year: year, singleRoomEligible: true),
          3,
        );
        expect(
          requiredRoomCapacity(course: 'B.E.', year: year, singleRoomEligible: false),
          3,
        );
      }
    });

    test('B.E. year 3+ is Single only if merit-eligible', () {
      expect(
        requiredRoomCapacity(course: 'B.E.', year: 3, singleRoomEligible: true),
        1,
      );
      expect(
        requiredRoomCapacity(course: 'B.E.', year: 3, singleRoomEligible: false),
        3,
      );
      expect(
        requiredRoomCapacity(course: 'B.E.', year: 4, singleRoomEligible: true),
        1,
      );
      expect(
        requiredRoomCapacity(course: 'B.E.', year: 4, singleRoomEligible: false),
        3,
      );
    });

    test('recognises "B.Tech" as the same family as "B.E."', () {
      expect(
        requiredRoomCapacity(course: 'B.Tech CSE', year: 1, singleRoomEligible: false),
        3,
      );
      expect(
        requiredRoomCapacity(course: 'B.Tech CSE', year: 3, singleRoomEligible: true),
        1,
      );
    });

    test('M.Tech, M.Sc and PhD are always Single, merit is irrelevant', () {
      for (final course in ['M.Tech', 'M.Sc', 'PhD']) {
        for (final year in [1, 2]) {
          expect(
            requiredRoomCapacity(
              course: course,
              year: year,
              singleRoomEligible: false,
            ),
            1,
            reason: '$course year $year',
          );
        }
      }
    });

    test('matches course names case- and punctuation-insensitively', () {
      expect(
        requiredRoomCapacity(course: 'phd', year: 1, singleRoomEligible: false),
        1,
      );
      expect(
        requiredRoomCapacity(course: 'msc', year: 2, singleRoomEligible: false),
        1,
      );
      expect(
        requiredRoomCapacity(course: 'diploma', year: 1, singleRoomEligible: false),
        3,
      );
    });

    test('returns null for a course the policy has no opinion on', () {
      expect(
        requiredRoomCapacity(course: 'Certificate Course', year: 1, singleRoomEligible: false),
        isNull,
      );
      expect(
        requiredRoomCapacity(course: null, year: 1, singleRoomEligible: false),
        isNull,
      );
      expect(
        requiredRoomCapacity(course: '', year: 1, singleRoomEligible: false),
        isNull,
      );
    });
  });

  group('roomTypeLabel', () {
    test('capacity 1 is "Single"', () {
      expect(roomTypeLabel(1), 'Single');
    });

    test('anything else is "N-Seater"', () {
      expect(roomTypeLabel(3), '3-Seater');
      expect(roomTypeLabel(2), '2-Seater');
    });
  });

  group('ordinal', () {
    test('renders the common cases', () {
      expect(ordinal(1), '1st');
      expect(ordinal(2), '2nd');
      expect(ordinal(3), '3rd');
      expect(ordinal(4), '4th');
      expect(ordinal(6), '6th');
    });

    test('handles the 11th-13th exception', () {
      expect(ordinal(11), '11th');
      expect(ordinal(12), '12th');
      expect(ordinal(13), '13th');
    });
  });
}
