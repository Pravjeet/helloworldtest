import 'package:flutter_test/flutter_test.dart';

import 'package:helloworld/models/hostel.dart';

/// [RoomPlan.build] is what turns the "add hostel" form into real room
/// documents, and the hostel editor's confirmation line (`rangeSummary`) has
/// to describe the exact same thing it will create — see
/// hostel_editor_dialog.dart.
///
/// The plan describes a building **floor by floor**, so one floor can hold
/// more than one seater type. An earlier version described it by seater type
/// and handed each type whole floors of its own, which made the common case
/// — a corridor of 25 singles and 25 three-seaters — impossible to express.
/// The floor-numbering arithmetic below is exactly the kind that goes quietly
/// wrong under a fencepost error, hence the room-by-room assertions.
void main() {
  group('FloorPlan', () {
    test('sums rooms and beds across its room types', () {
      const floor = FloorPlan(
        groups: [
          RoomGroup(capacity: 1, rooms: 25),
          RoomGroup(capacity: 3, rooms: 25),
        ],
      );
      expect(floor.rooms, 50);
      expect(floor.beds, 25 * 1 + 25 * 3);
    });

    test('describes its own mix', () {
      const floor = FloorPlan(
        groups: [
          RoomGroup(capacity: 1, rooms: 25),
          RoomGroup(capacity: 3, rooms: 25),
        ],
      );
      expect(floor.composition, '25 Single + 25 3 Seater');
    });

    test('an empty floor reads as a dash rather than an empty string', () {
      expect(const FloorPlan().composition, '—');
    });

    test('a zero-room type is left out of the description', () {
      const floor = FloorPlan(
        groups: [
          RoomGroup(capacity: 1, rooms: 10),
          RoomGroup(capacity: 2, rooms: 0),
        ],
      );
      expect(floor.composition, '10 Single');
    });
  });

  group('RoomPlan.build — one room type per floor', () {
    test('numbers rooms floor-prefixed starting at floor 1', () {
      final plan = RoomPlan.uniform(
        floors: 2,
        groups: const [RoomGroup(capacity: 2, rooms: 2)],
      );
      expect(
        plan.build().map((r) => r.number).toList(),
        ['101', '102', '201', '202'],
      );
    });

    test('every generated room carries its type\'s features', () {
      final plan = RoomPlan.uniform(
        floors: 1,
        groups: const [
          RoomGroup(capacity: 1, rooms: 2, features: ['Ceiling Fan']),
        ],
      );
      expect(
        plan.build(),
        everyElement(
          predicate<Room>((r) => r.features.contains('Ceiling Fan')),
        ),
      );
    });

    test('room id matches its number, so duplicates are impossible', () {
      final plan = RoomPlan.uniform(
        floors: 2,
        groups: const [RoomGroup(capacity: 2, rooms: 2)],
      );
      for (final r in plan.build()) {
        expect(r.id, r.number);
      }
    });

    test('a plan with no rooms produces nothing', () {
      final plan = RoomPlan.uniform(
        floors: 3,
        groups: const [RoomGroup(capacity: 2, rooms: 0)],
      );
      expect(plan.build(), isEmpty);
      // The floors still exist as far as the building is concerned.
      expect(plan.floors, 3);
    });
  });

  group('RoomPlan.build — two room types on the SAME floor', () {
    // The case the old block model could not express at all.
    final plan = RoomPlan.uniform(
      floors: 2,
      groups: const [
        RoomGroup(capacity: 1, rooms: 3),
        RoomGroup(capacity: 3, rooms: 2),
      ],
    );

    test('both types land on every floor', () {
      final rooms = plan.build();
      final singleFloors =
          rooms.where((r) => r.capacity == 1).map((r) => r.floor).toSet();
      final tripleFloors =
          rooms.where((r) => r.capacity == 3).map((r) => r.floor).toSet();

      expect(singleFloors, {1, 2});
      expect(tripleFloors, {1, 2});
    });

    test('types are numbered in order along the corridor', () {
      final floor1 = plan.build().where((r) => r.floor == 1).toList();
      // 101-103 are the singles, 104-105 the three-seaters.
      expect(floor1.map((r) => r.number).toList(), [
        '101',
        '102',
        '103',
        '104',
        '105',
      ]);
      expect(floor1.map((r) => r.capacity).toList(), [1, 1, 1, 3, 3]);
    });

    test('numbering restarts at 01 on each floor', () {
      final floor2 = plan.build().where((r) => r.floor == 2).toList();
      expect(floor2.first.number, '201');
      expect(floor2.last.number, '205');
    });

    test('totals count every type on every floor', () {
      expect(plan.totalRooms, (3 + 2) * 2);
      expect(plan.totalBeds, (3 * 1 + 2 * 3) * 2);
    });
  });

  group('RoomPlan.build — floors that differ from each other', () {
    // The ground floor is often the odd one out: fewer rooms, because the
    // warden's office and common room eat into it.
    const plan = RoomPlan(
      floorPlans: [
        FloorPlan(groups: [RoomGroup(capacity: 2, rooms: 2)]),
        FloorPlan(
          groups: [
            RoomGroup(capacity: 1, rooms: 1),
            RoomGroup(capacity: 4, rooms: 1),
          ],
        ),
      ],
    );

    test('each floor is built to its own spec', () {
      final rooms = plan.build();
      expect(rooms.map((r) => r.number).toList(), [
        '101',
        '102',
        '201',
        '202',
      ]);
      expect(rooms.map((r) => r.capacity).toList(), [2, 2, 1, 4]);
    });

    test('totals add the floors up rather than assuming they match', () {
      expect(plan.totalRooms, 4);
      expect(plan.totalBeds, 2 * 2 + 1 * 1 + 1 * 4);
      expect(plan.floors, 2);
    });
  });

  group('RoomPlan.exceedsFloorLimit', () {
    test('is false at the limit', () {
      final plan = RoomPlan.uniform(
        floors: 1,
        groups: const [RoomGroup(capacity: 1, rooms: kMaxRoomsPerFloor)],
      );
      expect(plan.exceedsFloorLimit, isFalse);
    });

    test('is true one room past it, because numbering would collide', () {
      // A 100th room on floor 1 would be numbered 200 — floor 2's first room.
      final plan = RoomPlan.uniform(
        floors: 1,
        groups: const [RoomGroup(capacity: 1, rooms: kMaxRoomsPerFloor + 1)],
      );
      expect(plan.exceedsFloorLimit, isTrue);
    });

    test('counts the whole floor, not one room type', () {
      final plan = RoomPlan.uniform(
        floors: 1,
        groups: const [
          RoomGroup(capacity: 1, rooms: 60),
          RoomGroup(capacity: 2, rooms: 60),
        ],
      );
      expect(plan.exceedsFloorLimit, isTrue);
    });
  });

  group('RoomPlan.rangeSummary', () {
    test('describes an empty plan without crashing', () {
      expect(const RoomPlan().rangeSummary, '—');
    });

    test('collapses consecutive identical floors into one range', () {
      final plan = RoomPlan.uniform(
        floors: 3,
        groups: const [
          RoomGroup(capacity: 1, rooms: 25),
          RoomGroup(capacity: 3, rooms: 25),
        ],
      );
      expect(
        plan.rangeSummary,
        'Floors 1–3: 50 rooms (25 Single + 25 3 Seater)',
      );
    });

    test('a single floor is named, not given a range', () {
      final plan = RoomPlan.uniform(
        floors: 1,
        groups: const [RoomGroup(capacity: 2, rooms: 10)],
      );
      expect(plan.rangeSummary, 'Floor 1: 10 rooms (10 2 Seater)');
    });

    test('a floor that differs breaks the range in two', () {
      const plan = RoomPlan(
        floorPlans: [
          FloorPlan(groups: [RoomGroup(capacity: 2, rooms: 10)]),
          FloorPlan(groups: [RoomGroup(capacity: 2, rooms: 10)]),
          FloorPlan(groups: [RoomGroup(capacity: 1, rooms: 5)]),
        ],
      );
      expect(
        plan.rangeSummary,
        'Floors 1–2: 10 rooms (10 2 Seater), Floor 3: 5 rooms (5 Single)',
      );
    });

    test('a single-capacity type is labelled "Single", not "1 Seater"', () {
      final plan = RoomPlan.uniform(
        floors: 1,
        groups: const [RoomGroup(capacity: 1, rooms: 5)],
      );
      expect(plan.rangeSummary, contains('Single'));
      expect(plan.rangeSummary, isNot(contains('1 Seater')));
    });

    test('an empty floor is skipped rather than described as 0 rooms', () {
      const plan = RoomPlan(
        floorPlans: [
          FloorPlan(groups: [RoomGroup(capacity: 2, rooms: 4)]),
          FloorPlan(),
        ],
      );
      expect(plan.rangeSummary, 'Floor 1: 4 rooms (4 2 Seater)');
    });
  });
}
