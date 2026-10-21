import 'package:flutter_test/flutter_test.dart';
import 'package:helloworld/models/app_user.dart';
import 'package:helloworld/models/hostel.dart';
import 'package:helloworld/services/allotment_service.dart';

/// Who auto-allot puts where.
///
/// This is the whole decision behind a one-click action that touches a
/// hundred students at once, so each rule a warden relies on is pinned: rooms
/// in series and full before the next, registration-number order, nobody the
/// single-student path would refuse, the seating policy, and nobody in the
/// group silently unaccounted for.
void main() {
  final bh5 = Hostel(id: 'h5', name: 'BH-5', code: 'BH-5');

  Room room(
    String number, {
    int floor = 1,
    int capacity = 3,
    int occupied = 0,
    RoomStatus status = RoomStatus.active,
  }) => Room(
    id: number,
    number: number,
    floor: floor,
    capacity: capacity,
    status: status,
    occupantUids: [for (var i = 0; i < occupied; i++) 'someone-$number-$i'],
  );

  AppUser student(
    String reg, {
    String? name,
    String? hostelId,
    String? roomId,
    String? gender = 'male',
    bool isActive = true,
    bool graduated = false,
  }) => AppUser(
    uid: 'u$reg',
    name: name ?? 'Student $reg',
    email: '$reg@x.test',
    collegeId: 'c1',
    roleId: 'r1',
    roleName: 'Student',
    isActive: isActive,
    status: graduated ? 'graduated' : 'active',
    enrollmentNo: reg,
    hostelId: hostelId,
    roomId: roomId,
    roomNumber: roomId,
    gender: gender,
  );

  /// "101: a, b, c | 102: d" — the plan as a warden would read it.
  String layout(AutoAllotPlan p) {
    final byRoom = <String, List<String>>{};
    for (final a in p.assignments) {
      byRoom.putIfAbsent(a.room.number, () => []).add(a.student.enrollmentNo!);
    }
    return byRoom.entries
        .map((e) => '${e.key}: ${e.value.join(', ')}')
        .join(' | ');
  }

  group('AllotmentService.planAutoAllot', () {
    test('fills each room before starting the next, in room order', () {
      final plan = AllotmentService.planAutoAllot(
        hostel: bh5,
        rooms: [room('102'), room('101')],
        students: [
          for (final r in ['1', '2', '3', '4', '5']) student(r),
        ],
      );
      expect(layout(plan), '101: 1, 2, 3 | 102: 4, 5');
      expect(plan.noBed, isEmpty);
    });

    test('room numbers count numerically', () {
      // A string sort would put 110 before 19 and 201 before 99.
      final plan = AllotmentService.planAutoAllot(
        hostel: bh5,
        rooms: [
          room('201', floor: 2, capacity: 1),
          room('110', capacity: 1),
          room('19', capacity: 1),
          room('9', capacity: 1),
        ],
        students: [
          for (final r in ['1', '2', '3', '4']) student(r),
        ],
      );
      expect(plan.rooms.map((r) => r.number), ['9', '19', '110', '201']);
    });

    test('room-number series wins over floor in wing-numbered hostels', () {
      // BH-3 is numbered 1–252 by wing: floor 1 holds 1–29 *and* 88–111.
      // Floor-first filled 29 and then jumped to 88, splitting consecutive
      // registration numbers across the building.
      final plan = AllotmentService.planAutoAllot(
        hostel: bh5,
        rooms: [
          room('88', floor: 1, capacity: 1),
          room('30', floor: 2, capacity: 1),
          room('29', floor: 1, capacity: 1),
        ],
        students: [
          for (final r in ['1', '2', '3']) student(r),
        ],
      );
      expect(layout(plan), '29: 1 | 30: 2 | 88: 3');
    });

    test('rooms are listed in series even when room types interleave', () {
      // With mixed policies the first PG student reaches Single 105 before
      // anyone reaches 3-Seater 101; the plan must still read 101 → 105.
      final plan = AllotmentService.planAutoAllot(
        hostel: bh5,
        rooms: [room('101', capacity: 3), room('105', capacity: 1)],
        students: [student('1'), student('2')],
        requiredCapacityOf: (u) => u.enrollmentNo == '1' ? 1 : 3,
      );
      expect(plan.rooms.map((r) => r.number), ['101', '105']);
    });

    test('a hostel that no longer exists counts as no hostel, not another', () {
      // Deleting a hostel never cleared its id off students; 357 pointed at
      // a dead BH-2 id once. They must not be excluded as "elsewhere".
      final plan = AllotmentService.planAutoAllot(
        hostel: bh5,
        rooms: [room('101')],
        students: [
          student('1', hostelId: 'deleted-id'),
          student('2', hostelId: 'h2'),
        ],
        knownHostelIds: {'h5', 'h2'},
      );
      expect(layout(plan), '101: 1');
      expect(plan.otherHostel.map((u) => u.enrollmentNo), ['2']);
    });

    test('a room type the hostel has none of is reported as such', () {
      // All-Single BH-3 vs a policy asking for 3-Seaters: nobody fits, and
      // the reason is the building, not a shortage of free beds.
      final plan = AllotmentService.planAutoAllot(
        hostel: bh5,
        rooms: [room('1', capacity: 1), room('2', capacity: 1, occupied: 1)],
        students: [student('1'), student('2')],
        requiredCapacityOf: (_) => 3,
      );
      expect(plan.assignments, isEmpty);
      expect(plan.noBed, isEmpty);
      expect(plan.noRoomOfType, hasLength(2));
      expect(plan.missingTypes, {3: 2});
    });

    test('rooms of the type that are all out of service are said so', () {
      // "BH-2 has no 3-Seaters" would be false when it has twenty, all under
      // maintenance — the fix is to reactivate them, not turn the policy off.
      final plan = AllotmentService.planAutoAllot(
        hostel: bh5,
        rooms: [
          room('101', capacity: 3, status: RoomStatus.maintenance),
          room('102', capacity: 3, status: RoomStatus.reserved),
          room('103', capacity: 1),
        ],
        students: [student('1')],
        requiredCapacityOf: (_) => 3,
      );
      expect(plan.noRoomOfType, isEmpty);
      expect(plan.typeOutOfService, hasLength(1));
      expect(plan.outOfServiceTypes, {3: 1});
    });

    test('full rooms of the right type are a shortage, not a missing type', () {
      final plan = AllotmentService.planAutoAllot(
        hostel: bh5,
        rooms: [room('101', capacity: 3, occupied: 3)],
        students: [student('1')],
        requiredCapacityOf: (_) => 3,
      );
      expect(plan.noRoomOfType, isEmpty);
      expect(plan.noBed, hasLength(1));
    });

    test('takes students in registration-number order, numerically', () {
      final plan = AllotmentService.planAutoAllot(
        hostel: bh5,
        rooms: [room('101', capacity: 3)],
        students: [
          student('251020110'),
          student('251020103'),
          student('251020104'),
        ],
      );
      expect(layout(plan), '101: 251020103, 251020104, 251020110');
    });

    test('tops up a part-filled room first, then moves on', () {
      final plan = AllotmentService.planAutoAllot(
        hostel: bh5,
        rooms: [room('101', occupied: 2), room('102')],
        students: [student('1'), student('2')],
      );
      expect(layout(plan), '101: 1 | 102: 2');
    });

    test('skips full rooms and rooms not in service', () {
      final plan = AllotmentService.planAutoAllot(
        hostel: bh5,
        rooms: [
          room('101', occupied: 3),
          room('102', status: RoomStatus.maintenance),
          room('103', status: RoomStatus.reserved),
          room('104'),
        ],
        students: [student('1')],
      );
      expect(layout(plan), '104: 1');
    });

    test('anyone left over once the beds run out is reported, not dropped', () {
      final plan = AllotmentService.planAutoAllot(
        hostel: bh5,
        rooms: [room('101', capacity: 2)],
        students: [student('1'), student('2'), student('3')],
      );
      expect(layout(plan), '101: 1, 2');
      expect(plan.noBed.map((u) => u.enrollmentNo), ['3']);
    });

    test('never plans a bed the single-student allot would refuse', () {
      final girlsOnly = Hostel(
        id: 'g1',
        name: 'GH-1',
        code: 'GH-1',
        gender: HostelGender.girls,
      );
      final plan = AllotmentService.planAutoAllot(
        hostel: girlsOnly,
        rooms: [room('101')],
        students: [
          student('1', gender: 'female'),
          student('2', gender: 'male'),
          student('3', gender: 'female', isActive: false),
          student('4', gender: 'female', graduated: true),
          student('5', gender: 'female', hostelId: 'g1', roomId: '102'),
        ],
      );
      expect(layout(plan), '101: 1');
      expect(plan.ineligible.map((u) => u.enrollmentNo).toSet(), {
        '2',
        '3',
        '4',
        '5',
      });
    });

    test('leaves out students recorded in another hostel unless asked', () {
      final students = [
        student('1', hostelId: 'h5'),
        student('2', hostelId: 'h2'),
        student('3'),
      ];
      final plan = AllotmentService.planAutoAllot(
        hostel: bh5,
        rooms: [room('101')],
        students: students,
      );
      expect(layout(plan), '101: 1, 3');
      expect(plan.otherHostel.map((u) => u.enrollmentNo), ['2']);

      final withThem = AllotmentService.planAutoAllot(
        hostel: bh5,
        rooms: [room('101')],
        students: students,
        includeOtherHostels: true,
      );
      expect(layout(withThem), '101: 1, 2, 3');
      expect(withThem.otherHostel, isEmpty);
    });

    test('the seating policy matches each student to their room type', () {
      // A PG student entitled to a Single must not be put in a 3-Seater just
      // because it comes first in the corridor — and vice versa.
      final plan = AllotmentService.planAutoAllot(
        hostel: bh5,
        rooms: [room('101', capacity: 3), room('102', capacity: 1)],
        students: [student('1'), student('2'), student('3')],
        requiredCapacityOf: (u) => u.enrollmentNo == '2' ? 1 : 3,
      );
      expect(layout(plan), '101: 1, 3 | 102: 2');
    });

    test('with no matching room type, the student waits rather than '
        'getting the wrong one', () {
      final plan = AllotmentService.planAutoAllot(
        hostel: bh5,
        rooms: [room('101', capacity: 3)],
        students: [student('1')],
        requiredCapacityOf: (_) => 1,
      );
      expect(plan.assignments, isEmpty);
      expect(plan.noRoomOfType.map((u) => u.enrollmentNo), ['1']);
    });

    test('a student no policy covers can take any room', () {
      final plan = AllotmentService.planAutoAllot(
        hostel: bh5,
        rooms: [room('101', capacity: 2)],
        students: [student('1')],
        requiredCapacityOf: (_) => null,
      );
      expect(layout(plan), '101: 1');
    });

    test('everyone in the group lands in exactly one bucket', () {
      final students = [
        for (var i = 0; i < 12; i++)
          student(
            '${100 + i}',
            hostelId: i % 4 == 0 ? 'h2' : null,
            gender: i % 5 == 0 ? 'female' : 'male',
          ),
      ];
      final plan = AllotmentService.planAutoAllot(
        hostel: bh5,
        rooms: [room('101'), room('102', capacity: 2)],
        students: students,
        // Every bucket in play: some need a Single this hostel lacks, the
        // rest compete for five beds.
        requiredCapacityOf: (u) => u.enrollmentNo!.endsWith('7') ? 1 : null,
        knownHostelIds: {'h5', 'h2'},
      );
      expect(plan.noRoomOfType, isNotEmpty);
      final accounted = [
        ...plan.assignments.map((a) => a.student.uid),
        ...plan.noBed.map((u) => u.uid),
        ...plan.noRoomOfType.map((u) => u.uid),
        ...plan.typeOutOfService.map((u) => u.uid),
        ...plan.otherHostel.map((u) => u.uid),
        ...plan.ineligible.map((u) => u.uid),
      ];
      expect(accounted, hasLength(students.length));
      expect(accounted.toSet(), students.map((u) => u.uid).toSet());
    });
  });
}
