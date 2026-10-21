import 'package:flutter_test/flutter_test.dart';
import 'package:helloworld/core/identity.dart';
import 'package:helloworld/models/app_user.dart';
import 'package:helloworld/services/data_service.dart';

/// The passwords "delete" may try when removing someone's sign-in account
/// from the browser. They must match what the importers set —
/// `derivedPassword(registrationNo || authEmail)` — or the app reports a
/// login it built itself as one it can't remove.
void main() {
  AppUser user({String? reg, required String email}) => AppUser(
    uid: 'u',
    name: 'Someone',
    email: email,
    collegeId: 'c1',
    roleId: 'r1',
    roleName: 'Student',
    enrollmentNo: reg,
  );

  test('a student with a registration number: that number', () {
    expect(
      DataService.derivedPasswordsFor(
        user(reg: '251020103', email: 'someone@gmail.com'),
      ),
      [Identity.derivedPassword('251020103')],
    );
  });

  test('a registration-number login: the number, once', () {
    expect(
      DataService.derivedPasswordsFor(
        user(reg: '2432059', email: '2432059@homihostel.local'),
      ),
      [Identity.derivedPassword('2432059')],
    );
  });

  test('imported with only an email: the lower-cased email', () {
    // What both importers used when the row had no registration number.
    expect(
      DataService.derivedPasswordsFor(
        user(email: 'Warden@College.edu'),
      ),
      [Identity.derivedPassword('warden@college.edu')],
    );
  });

  test('short registration numbers are padded the way Firebase needs', () {
    expect(
      DataService.derivedPasswordsFor(user(reg: '123', email: 'x@y.z')).single,
      hasLength(greaterThanOrEqualTo(6)),
    );
  });
}
