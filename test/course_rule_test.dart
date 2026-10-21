import 'package:flutter_test/flutter_test.dart';
import 'package:helloworld/models/college_settings.dart';

/// [CollegeSettings.totalYearsFor] / [CollegeSettings.courseRuleFor] — how a
/// college's per-course rules are looked up, including the never-configured
/// case that a fresh workspace and a course nobody has typed a rule for both
/// hit constantly.
void main() {
  group('an unconfigured workspace uses the seeded defaults', () {
    const settings = CollegeSettings();

    test('the three courses on this campus are covered', () {
      expect(settings.totalYearsFor('UG'), 4);
      expect(settings.totalYearsFor('ICD'), 3);
      expect(settings.totalYearsFor('PG'), 2);
    });

    test('matching is case-insensitive', () {
      expect(settings.totalYearsFor('ug'), 4);
      expect(settings.totalYearsFor('Icd'), 3);
    });

    test('courseRuleFor returns the seeded rule, not just the length', () {
      final rule = settings.courseRuleFor('UG');
      expect(rule, isNotNull);
      expect(rule!.seating, CourseSeating.meritSingle);
    });
  });

  group('a course with no configured rule', () {
    const settings = CollegeSettings();

    test('totalYearsFor falls back to 4, not the length of an unrelated course', () {
      expect(settings.totalYearsFor('Certificate Course'), 4);
    });

    test('courseRuleFor returns null — no policy, not a guessed default', () {
      expect(settings.courseRuleFor('Certificate Course'), isNull);
    });

    test('a blank or missing course is also unconfigured', () {
      expect(settings.courseRuleFor(null), isNull);
      expect(settings.courseRuleFor(''), isNull);
      expect(settings.courseRuleFor('   '), isNull);
    });
  });

  group('once the college edits courseRules, that list is authoritative', () {
    const settings = CollegeSettings(
      courseRules: [
        CourseRule(course: 'B.E.', totalYears: 4, seating: CourseSeating.meritSingle),
      ],
    );

    test('the edited course is found', () {
      expect(settings.totalYearsFor('B.E.'), 4);
    });

    test('the seeded defaults no longer apply once any rule is set', () {
      // Matches the same empty-means-fallback pattern as `trades`: editing
      // the list at all opts out of the built-in one entirely.
      expect(settings.courseRuleFor('UG'), isNull);
    });
  });

  group('round-tripping a CourseRule through Firestore\'s map shape', () {
    test('every field survives', () {
      const rule = CourseRule(
        course: 'UG',
        totalYears: 4,
        seating: CourseSeating.meritSingle,
        sharedCapacity: 3,
      );
      final back = CourseRule.fromMap(rule.toMap());

      expect(back.course, 'UG');
      expect(back.totalYears, 4);
      expect(back.seating, CourseSeating.meritSingle);
      expect(back.sharedCapacity, 3);
    });

    test('an unrecognised seating string falls back rather than throwing', () {
      final back = CourseRule.fromMap({
        'course': 'X',
        'totalYears': 4,
        'seating': 'somethingRemoved',
      });
      expect(back.seating, CourseSeating.alwaysShared);
    });
  });
}
