import 'package:flutter_test/flutter_test.dart';
import 'package:helloworld/models/app_user.dart';
import 'package:helloworld/models/hostel.dart';
import 'package:helloworld/services/allotment_service.dart';

/// Who may be offered a free bed.
///
/// This backs the picker in the room dialog. Getting it wrong is not a cosmetic
/// bug: offering someone who is already allotted produces a click that always
/// fails, and offering the wrong gender produces one the service refuses. Both
/// look like the app is broken.
void main() {
  Hostel hostel(
    String id, {
    HostelGender gender = HostelGender.boys,
  }) => Hostel(id: id, name: 'Hostel $id', code: id, gender: gender);

  AppUser student(
    String name, {
    String? hostelId,
    String? roomId,
    String? gender,
    bool isActive = true,
    bool isSuperAdmin = false,
    bool graduated = false,
  }) => AppUser(
    uid: name,
    name: name,
    email: '$name@x.test',
    collegeId: 'c1',
    roleId: 'r1',
    roleName: 'Student',
    isActive: isActive,
    isSuperAdmin: isSuperAdmin,
    status: graduated ? 'graduated' : 'active',
    hostelId: hostelId,
    roomId: roomId,
    roomNumber: roomId == null ? null : '101',
    gender: gender,
  );

  List<String> names(List<AppUser> us) => us.map((u) => u.name).toList();

  group('AllotmentService.bedCandidates', () {
    test('offers an unallotted student', () {
      final out = AllotmentService.bedCandidates(
        hostel: hostel('h1'),
        roster: [student('asha')],
      );
      expect(names(out), ['asha']);
    });

    test('excludes anyone who already holds a bed', () {
      // `allot` throws for these, so listing them offers a guaranteed failure.
      final out = AllotmentService.bedCandidates(
        hostel: hostel('h1'),
        roster: [
          student('has-bed', hostelId: 'h1', roomId: '101'),
          student('waiting', hostelId: 'h1'),
        ],
      );
      expect(names(out), ['waiting']);
    });

    test('excludes deactivated accounts', () {
      final out = AllotmentService.bedCandidates(
        hostel: hostel('h1'),
        roster: [student('gone', isActive: false), student('here')],
      );
      expect(names(out), ['here']);
    });

    test('excludes graduates — only current students can take a bed', () {
      // Promotion vacates a graduate's room, so they look exactly like
      // someone waiting for one. Offering them is how four passed-out
      // students ended up in BH-3 while appearing in no session roster.
      final out = AllotmentService.bedCandidates(
        hostel: hostel('h1'),
        roster: [student('passed-out', graduated: true), student('current')],
      );
      expect(names(out), ['current']);
    });

    test('excludes the Super Admin, who is staff not a resident', () {
      final out = AllotmentService.bedCandidates(
        hostel: hostel('h1'),
        roster: [student('owner', isSuperAdmin: true), student('resident')],
      );
      expect(names(out), ['resident']);
    });

    test('a boys hostel does not offer female students', () {
      final out = AllotmentService.bedCandidates(
        hostel: hostel('h1', gender: HostelGender.boys),
        roster: [
          student('bob', gender: 'Male'),
          student('bina', gender: 'Female'),
        ],
      );
      expect(names(out), ['bob']);
    });

    test('a girls hostel does not offer male students', () {
      final out = AllotmentService.bedCandidates(
        hostel: hostel('h1', gender: HostelGender.girls),
        roster: [
          student('bob', gender: 'Male'),
          student('bina', gender: 'Female'),
        ],
      );
      expect(names(out), ['bina']);
    });

    test('a co-ed hostel offers everyone', () {
      final out = AllotmentService.bedCandidates(
        hostel: hostel('h1', gender: HostelGender.coed),
        roster: [
          student('bob', gender: 'Male'),
          student('bina', gender: 'Female'),
        ],
      );
      expect(names(out), ['bina', 'bob']);
    });

    test('missing gender is offered rather than stranded', () {
      // Matches genderAllows: blocking on absent data would strand real
      // students, so the omission is surfaced in the UI instead.
      final out = AllotmentService.bedCandidates(
        hostel: hostel('h1', gender: HostelGender.girls),
        roster: [student('unknown'), student('blank', gender: '  ')],
      );
      expect(names(out), ['blank', 'unknown']);
    });

    test('students already in this hostel come first', () {
      // The import case: thousands are in a hostel awaiting a room, and they
      // are who the warden is looking for.
      final out = AllotmentService.bedCandidates(
        hostel: hostel('h1'),
        roster: [
          student('aaa-elsewhere', hostelId: 'h2'),
          student('zzz-here', hostelId: 'h1'),
          student('mmm-nowhere'),
        ],
      );
      expect(names(out), ['zzz-here', 'aaa-elsewhere', 'mmm-nowhere']);
    });

    test('within each group, sorted by name case-insensitively', () {
      final out = AllotmentService.bedCandidates(
        hostel: hostel('h1'),
        roster: [
          student('bravo', hostelId: 'h1'),
          student('Alpha', hostelId: 'h1'),
          student('charlie', hostelId: 'h1'),
        ],
      );
      expect(names(out), ['Alpha', 'bravo', 'charlie']);
    });

    test('an empty roster yields nothing rather than throwing', () {
      expect(
        AllotmentService.bedCandidates(hostel: hostel('h1'), roster: const []),
        isEmpty,
      );
    });

    test('a student with a room but no hostel is still a candidate', () {
      // isAllotted requires both, so this half-written record has no real bed
      // and should be offered one.
      final out = AllotmentService.bedCandidates(
        hostel: hostel('h1'),
        roster: [student('halfway', roomId: '101')],
      );
      expect(names(out), ['halfway']);
    });
  });
}
