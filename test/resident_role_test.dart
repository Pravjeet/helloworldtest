import 'package:flutter_test/flutter_test.dart';
import 'package:helloworld/core/permissions.dart';

/// Which form the "Add user" dialog shows.
///
/// A resident gets the full student record — every column the CSV importer
/// accepts — so a hand-added student is comparable with an imported one. Staff
/// get contact details and what they look after.
///
/// Worth pinning because both failure directions are bad and neither is loud:
/// misfiling staff as a resident asks a warden for their guardian's phone
/// number, and misfiling a student as staff creates a record missing every
/// academic field the reports group by.
void main() {
  Set<String> template(String name) =>
      kRoleTemplates[name]!.toSet();

  group('the starter roles are classified correctly', () {
    test('Student is a resident', () {
      expect(Perm.isResident(template('Student')), isTrue);
    });

    for (final staff in ['Chief Warden', 'Warden', 'Caretaker', 'BHS']) {
      test('$staff is staff', () {
        expect(Perm.isResident(template(staff)), isFalse);
      });
    }
  });

  group('what makes a role staff', () {
    test('managing anything', () {
      expect(Perm.isResident({Perm.noticesManage}), isFalse);
      expect(Perm.isResident({Perm.messManage}), isFalse);
      expect(Perm.isResident({Perm.settingsManage}), isFalse);
    });

    test('seeing everyone rather than yourself', () {
      expect(Perm.isResident({Perm.finesViewAll}), isFalse);
      expect(Perm.isResident({Perm.feesViewAll}), isFalse);
      expect(Perm.isResident({Perm.requestsViewAll}), isFalse);
    });

    test('reaching the user directory', () {
      expect(Perm.isResident({Perm.usersView}), isFalse);
      expect(Perm.isResident({Perm.usersEdit}), isFalse);
      expect(Perm.isResident({Perm.usersCreate}), isFalse);
    });

    test('hostel oversight, even read-only', () {
      expect(Perm.isResident({Perm.hostelsView}), isFalse);
    });
  });

  group('what keeps a role a resident', () {
    test('self-service permissions only', () {
      expect(
        Perm.isResident({
          Perm.selfRoom,
          Perm.finesViewOwn,
          Perm.feesViewOwn,
          Perm.requestsViewOwn,
        }),
        isTrue,
      );
    });

    test('raising your own request is not a staff power', () {
      // requests.create ends in .create like users.create, but it is how a
      // student asks for something. The predicate excludes it by name.
      expect(Perm.isResident({Perm.requestsCreate}), isTrue);
    });

    test('reading notices, mess and orders', () {
      expect(
        Perm.isResident({
          Perm.noticesView,
          Perm.messView,
          Perm.officeOrdersView,
        }),
        isTrue,
      );
    });

    test('a role with no permissions at all', () {
      // Not useful, but it is not staff — and it must not crash the form.
      expect(Perm.isResident(const {}), isTrue);
    });
  });

  group('the two predicates are not the same question', () {
    test('an accountant is staff but manages no hostel', () {
      // The reason the form does not branch on managesHostels: this role would
      // otherwise have been shown the student academic form.
      final accountant = {Perm.feesViewAll, Perm.feesManage};
      expect(Perm.isResident(accountant), isFalse, reason: 'staff');
      expect(
        Perm.managesHostels(accountant),
        isFalse,
        reason: 'no hostels to pick',
      );
    });

    test('a warden is staff and does manage hostels', () {
      final warden = template('Warden');
      expect(Perm.isResident(warden), isFalse);
      expect(Perm.managesHostels(warden), isTrue);
    });
  });
}
