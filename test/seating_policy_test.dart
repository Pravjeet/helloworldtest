import 'package:flutter_test/flutter_test.dart';
import 'package:helloworld/models/app_user.dart';
import 'package:helloworld/models/college_settings.dart';
import 'package:helloworld/models/hostel.dart';
import 'package:helloworld/services/allotment_service.dart';
import 'package:helloworld/utils/enrollment_helpers.dart';

/// The one answer every allotment screen asks for. Room Allotment, Hostels &
/// Rooms and auto-allot all call [entitledRoomCapacity], and the service
/// refuses any room of another type — so this is the seating policy.
void main() {
  // The workspace defaults: UG merit single (4 yrs), ICD shared, PG single.
  const settings = CollegeSettings();

  int? entitled(String course, int? year, {bool merit = false}) =>
      entitledRoomCapacity(
        settings: settings,
        course: course,
        year: year,
        singleRoomEligible: merit,
      );

  group('entitledRoomCapacity — this college\'s policy', () {
    test('UG: 1st–2nd shared, 3rd on merit, 4th single for all', () {
      expect(entitled('UG', 1), 3);
      expect(entitled('UG', 2, merit: true), 3);
      expect(entitled('UG', 3), 3);
      expect(entitled('UG', 3, merit: true), 1);
      expect(entitled('UG', 4), 1);
      expect(entitled('UG', 4, merit: true), 1);
    });

    test('ICD always shared, PG always single', () {
      expect(entitled('ICD', 1), 3);
      expect(entitled('ICD', 3, merit: true), 3);
      expect(entitled('PG', 1), 1);
      expect(entitled('PG', 2), 1);
    });

    test('course is matched however a sheet cased it', () {
      expect(entitled('ug', 4), 1);
    });

    test('an unknown year or an unconfigured course means no rule', () {
      expect(entitled('UG', null), isNull);
      expect(entitled('B.Arch', 1), isNull);
    });
  });

  test('auto-allot carries each student\'s entitlement to the write', () {
    // The service re-checks the room type inside its transaction, so the
    // plan must hand over what it assumed — not drop it.
    AppUser s(String reg) => AppUser(
      uid: 'u$reg',
      name: reg,
      email: '$reg@x.test',
      collegeId: 'c1',
      roleId: 'r1',
      roleName: 'Student',
      enrollmentNo: reg,
      gender: 'Male',
    );
    final plan = AllotmentService.planAutoAllot(
      hostel: const Hostel(id: 'h', name: 'BH-9', code: 'BH-9'),
      rooms: const [
        Room(id: '101', number: '101', floor: 1, capacity: 3),
        Room(id: '102', number: '102', floor: 1, capacity: 1),
      ],
      students: [s('1'), s('2')],
      requiredCapacityOf: (u) => u.enrollmentNo == '2' ? 1 : 3,
    );
    final byReg = {
      for (final a in plan.assignments)
        a.student.enrollmentNo: (a.room.number, a.requiredCapacity),
    };
    expect(byReg['1'], ('101', 3));
    expect(byReg['2'], ('102', 1));
  });
}
