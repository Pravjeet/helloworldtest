import 'package:flutter_test/flutter_test.dart';
import 'package:helloworld/models/app_user.dart';
import 'package:helloworld/models/college_settings.dart';

/// The Student Overview's Course / Category / Blood Group filters bucket
/// students through these. The inputs below are the exact distinct values
/// the live roster holds, so a regression shows up as a student landing in
/// the wrong tile.
void main() {
  group('categoryLabel', () {
    test('the import sheet spellings land on the standard list', () {
      expect(categoryLabel('GENERAL'), 'General');
      expect(categoryLabel('OBC'), 'OBC');
      expect(categoryLabel('SC'), 'SC');
      expect(categoryLabel('ST'), 'ST');
      expect(categoryLabel('EWS'), 'EWS');
    });

    test('case, spacing and common aliases', () {
      expect(categoryLabel(' general '), 'General');
      expect(categoryLabel('obc'), 'OBC');
      expect(categoryLabel('Gen'), 'General');
      expect(categoryLabel('UR'), 'General');
      expect(categoryLabel('OBC-NCL'), 'OBC');
    });

    test('anything else is kept as typed, blank is null', () {
      expect(categoryLabel('Minority'), 'Minority');
      expect(categoryLabel('  '), isNull);
      expect(categoryLabel(null), isNull);
    });
  });

  group('bloodGroupLabel', () {
    test('the eight standard groups pass through', () {
      for (final g in kBloodGroups) {
        expect(bloodGroupLabel(g), g);
      }
    });

    test('unambiguous slips are corrected', () {
      expect(bloodGroupLabel('b+'), 'B+');
      expect(bloodGroupLabel('o+'), 'O+');
      expect(bloodGroupLabel('0+'), 'O+');
      expect(bloodGroupLabel(' ab - '), 'AB-');
      expect(bloodGroupLabel('B+ve'), 'B+');
      expect(bloodGroupLabel('O -VE'), 'O-');
      expect(bloodGroupLabel('A Positive'), 'A+');
      expect(bloodGroupLabel('AB negative'), 'AB-');
    });

    test('a missing Rh factor is not invented', () {
      expect(bloodGroupLabel('B'), 'B');
      expect(bloodGroupLabel('ab'), 'AB');
      expect(bloodGroupLabel('O'), 'O');
    });

    test('an ambiguous slip is kept as typed', () {
      // "=" sits between "+" and "-" on a keyboard — not a guess to make on
      // a blood group.
      expect(bloodGroupLabel('O='), 'O=');
    });

    test('blank is null', () {
      expect(bloodGroupLabel(''), isNull);
      expect(bloodGroupLabel(null), isNull);
    });
  });

  group('religionLabel', () {
    test('"Others" from the sheets joins "Other"', () {
      expect(religionLabel('Others'), 'Other');
      expect(religionLabel('OTHERS'), 'Other');
      expect(religionLabel('Other'), 'Other');
    });

    test('"BUDDHIST" joins "Buddhist"', () {
      expect(religionLabel('BUDDHIST'), 'Buddhist');
    });
  });

  group('courses', () {
    test('courseLabel spells out the institute codes', () {
      expect(courseLabel('ICD'), 'ICD — Diploma');
      expect(courseLabel('UG'), 'UG — Graduation');
      expect(courseLabel('PG'), 'PG — Post-graduation');
      expect(courseLabel('PhD'), 'PhD');
      expect(courseLabel('Not set'), 'Not set');
    });

    test('courseNames are the configured rules, defaults when none', () {
      expect(const CollegeSettings().courseNames, ['UG', 'ICD', 'PG']);
      expect(
        const CollegeSettings(
          courseRules: [CourseRule(course: 'B.E.', totalYears: 4)],
        ).courseNames,
        ['B.E.'],
      );
    });

    test('a rule repeated in another case is offered once', () {
      expect(
        const CollegeSettings(
          courseRules: [
            CourseRule(course: 'UG', totalYears: 4),
            CourseRule(course: 'ICD', totalYears: 3),
            CourseRule(course: 'ug', totalYears: 4),
          ],
        ).courseNames,
        ['UG', 'ICD'],
      );
    });

    test('courseNameFor matches the rule ignoring case', () {
      const s = CollegeSettings();
      expect(s.courseNameFor('UG'), 'UG');
      expect(s.courseNameFor(' ug '), 'UG');
      expect(s.courseNameFor('icd'), 'ICD');
      expect(s.courseNameFor('PhD'), 'PhD');
      expect(s.courseNameFor(''), isNull);
      expect(s.courseNameFor(null), isNull);
    });
  });
}
