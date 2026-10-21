import 'package:flutter_test/flutter_test.dart';
import 'package:helloworld/models/app_role.dart';
import 'package:helloworld/models/app_user.dart';
import 'package:helloworld/services/csv_import.dart';
import 'package:helloworld/services/login_account_service.dart';

const _student = AppRole(id: 'student', name: 'Student', permissions: {});

ImportPlan _plan(String csv, {List<AppUser> existing = const []}) =>
    analyseImport(
      table: parseDelimited(csv),
      existingUsers: existing,
      roles: const [_student],
      hostels: const [],
      defaultRoleName: 'Student',
    );

void main() {
  group('AppUser.hasLogin', () {
    test('defaults to true for documents written before it existed', () {
      final u = AppUser.fromMap('u1', {'name': 'A', 'email': 'a@x.com'});
      expect(u.hasLogin, isTrue);
      expect(u.pendingLoginUid, isNull);
    });

    test('reads a record-only student', () {
      final u = AppUser.fromMap('u1', {
        'name': 'A',
        'hasLogin': false,
        'pendingLoginUid': 'new1',
      });
      expect(u.hasLogin, isFalse);
      expect(u.pendingLoginUid, 'new1');
    });
  });

  group('recordOnlyProfile', () {
    test('writes the row with no login, and a sign-in email for later', () {
      final row = _plan(
        'name,registrationNo,gender,trade\nAsha Rani,2110910,F,GCS',
      ).rows.single;
      final p = recordOnlyProfile(row, uid: 'abc', collegeId: 'c1');

      expect(p['uid'], 'abc');
      expect(p['hasLogin'], isFalse);
      expect(p['collegeId'], 'c1');
      expect(p['roleId'], 'student');
      expect(p['enrollmentNo'], '2110910');
      expect(p['email'], row.authEmail);
      expect(p['gender'], 'Female');
      expect(p['trade'], 'GCS');
      expect(p['isSuperAdmin'], isFalse);

      // What the run hands to the allotment phase must read back the same.
      final u = AppUser.fromMap('abc', p);
      expect(u.hasLogin, isFalse);
      expect(u.enrollmentNo, '2110910');
    });
  });

  group('re-importing matches by registration number', () {
    test('a record-only student is updated, not duplicated', () {
      const existing = AppUser(
        uid: 'rec1',
        name: 'Asha',
        // An email that no longer matches the sheet — the number still does.
        email: 'old@example.com',
        collegeId: 'c1',
        enrollmentNo: '2110910',
        hasLogin: false,
      );
      final row = _plan(
        'name,registrationNo\nAsha Rani,2110910',
        existing: [existing],
      ).rows.single;
      expect(row.action, RowAction.update);
      expect(row.existing?.uid, 'rec1');
    });

    test('a new number is a create', () {
      final row = _plan('name,registrationNo\nNew One,2316309').rows.single;
      expect(row.action, RowAction.create);
    });
  });

  group('rekeyId', () {
    test('moves an enrollment id, which leads with the uid', () {
      expect(rekeyId('old123_2026-27', 'old123', 'new9'), 'new9_2026-27');
    });

    test('moves a fee record id, which ends with the uid', () {
      expect(rekeyId('2026-08_old123', 'old123', 'new9'), '2026-08_new9');
    });

    test('leaves an id that does not name the student alone', () {
      expect(rekeyId('other_2026-27', 'old123', 'new9'), 'other_2026-27');
      // A uid that merely contains the old one is not it.
      expect(rekeyId('xold123_2026-27', 'old123', 'new9'), 'xold123_2026-27');
    });
  });

  group('rewriteOrderStudents', () {
    test('repoints the student in both students[] and studentUids', () {
      final changes = rewriteOrderStudents(
        {
          'students': [
            {'uid': 'a', 'name': 'A', 'fineAmount': 100},
            {'uid': 'old', 'name': 'B', 'fineAmount': 200},
          ],
          'studentUids': ['a', 'old'],
        },
        'old',
        'new',
      );
      expect(changes['studentUids'], ['a', 'new']);
      final students = changes['students'] as List;
      expect(students[0], {'uid': 'a', 'name': 'A', 'fineAmount': 100});
      expect(students[1], {'uid': 'new', 'name': 'B', 'fineAmount': 200});
      expect(changes.containsKey('studentUid'), isFalse);
    });

    test('handles the older single-student shape', () {
      expect(rewriteOrderStudents({'studentUid': 'old'}, 'old', 'new'), {
        'studentUid': 'new',
      });
    });

    test('changes nothing on an order that does not name them', () {
      expect(
        rewriteOrderStudents(
          {
            'students': [
              {'uid': 'a'},
            ],
            'studentUids': ['a'],
          },
          'old',
          'new',
        ),
        isEmpty,
      );
    });
  });
}
