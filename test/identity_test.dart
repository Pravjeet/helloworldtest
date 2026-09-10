import 'package:flutter_test/flutter_test.dart';

import 'package:helloworld/core/identity.dart';

/// [Identity] is the layer that lets a student sign in with a bare
/// registration number instead of an email address — see identity.dart's
/// own doc comment for the trade-off (no inbox, so password reset is an
/// admin action). Getting this wrong either locks students out or, worse,
/// makes two different registration numbers collide on the same synthetic
/// address.
void main() {
  group('toAuthEmail', () {
    test('a bare registration number gets the synthetic domain appended', () {
      expect(Identity.toAuthEmail('2110910'), '2110910@homihostel.local');
    });

    test('something that already looks like an email passes through', () {
      expect(
        Identity.toAuthEmail('warden@college.edu'),
        'warden@college.edu',
      );
    });

    test('is case- and whitespace-insensitive', () {
      expect(
        Identity.toAuthEmail('  Warden@College.EDU  '),
        'warden@college.edu',
      );
      expect(Identity.toAuthEmail('  2110910  '), '2110910@homihostel.local');
    });

    test('an empty string stays empty rather than becoming "@domain"', () {
      expect(Identity.toAuthEmail(''), '');
      expect(Identity.toAuthEmail('   '), '');
    });
  });

  group('isSynthetic / display', () {
    test('recognises an address this app generated', () {
      expect(Identity.isSynthetic('2110910@homihostel.local'), isTrue);
      expect(Identity.isSynthetic('warden@college.edu'), isFalse);
    });

    test('display shows the bare registration number for synthetic addresses', () {
      expect(Identity.display('2110910@homihostel.local'), '2110910');
    });

    test('display shows a real address unchanged', () {
      expect(Identity.display('warden@college.edu'), 'warden@college.edu');
    });
  });

  group('isValidRegistrationNumber', () {
    test('accepts typical SLIET-style registration numbers', () {
      expect(Identity.isValidRegistrationNumber('2110910'), isTrue);
      expect(Identity.isValidRegistrationNumber('21-CS-045'), isTrue);
    });

    test('rejects anything too short to be a real registration number', () {
      expect(Identity.isValidRegistrationNumber('12'), isFalse);
      expect(Identity.isValidRegistrationNumber(''), isFalse);
    });

    test('rejects characters that would not survive the email round trip', () {
      // @ would turn the "registration number" into a different address than
      // the one the round trip through toAuthEmail would produce.
      expect(Identity.isValidRegistrationNumber('foo@bar'), isFalse);
      expect(Identity.isValidRegistrationNumber('has space'), isFalse);
    });
  });

  group('derivedPassword', () {
    test('uses the registration number as-is when it meets the minimum', () {
      expect(Identity.derivedPassword('2110910'), '2110910');
    });

    test('pads a short registration number to Firebase\'s 6-char minimum', () {
      final pw = Identity.derivedPassword('123');
      expect(pw.length, greaterThanOrEqualTo(6));
      expect(pw, startsWith('123'));
    });

    test('is deterministic — the same input always derives the same password', () {
      // AuthService.deleteAuthAccount depends on being able to reconstruct
      // this later without storing it anywhere.
      expect(Identity.derivedPassword('2110910'), Identity.derivedPassword('2110910'));
    });
  });
}
