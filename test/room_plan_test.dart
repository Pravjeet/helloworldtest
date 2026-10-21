import 'package:flutter_test/flutter_test.dart';
import 'package:helloworld/models/hostel.dart';

/// [RoomPlan.build] turns the "add hostel" form into real room documents, so
/// what it produces is what the building becomes. It is floor-first: each
/// floor is described independently and can mix seater types, because real
/// buildings do — the corner rooms are smaller, a wing was converted.
void main() {
  group('one floor, one seater type', () {
    test('numbers rooms from the floor prefix', () {
      const plan = RoomPlan(
        floorPlans: [
          FloorPlan(groups: [RoomGroup(capacity: 2, count: 3)]),
        ],
      );
      final rooms = plan.build();

      expect(rooms.map((r) => r.number), ['101', '102', '103']);
      expect(rooms.every((r) => r.floor == 1), isTrue);
      expect(rooms.every((r) => r.capacity == 2), isTrue);
    });

    test('the room number is also the document id', () {
      // Rooms are addressed by number throughout the app; a mismatch here
      // would break every lookup.
      const plan = RoomPlan(
        floorPlans: [
          FloorPlan(groups: [RoomGroup(capacity: 1, count: 2)]),
        ],
      );
      for (final r in plan.build()) {
        expect(r.id, r.number);
      }
    });
  });

  group('several floors', () {
    test('each floor gets its own prefix', () {
      final plan = RoomPlan.uniform(
        floors: 3,
        roomsPerFloor: 2,
        capacity: 2,
      );
      expect(plan.build().map((r) => r.number), [
        '101', '102',
        '201', '202',
        '301', '302',
      ]);
    });

    test('floors can differ from one another', () {
      const plan = RoomPlan(
        floorPlans: [
          FloorPlan(groups: [RoomGroup(capacity: 3, count: 2)]),
          FloorPlan(groups: [RoomGroup(capacity: 1, count: 3)]),
        ],
      );
      final rooms = plan.build();

      expect(rooms.where((r) => r.floor == 1).map((r) => r.capacity), [3, 3]);
      expect(
        rooms.where((r) => r.floor == 2).map((r) => r.capacity),
        [1, 1, 1],
      );
    });
  });

  group('mixed seater types on one floor', () {
    // The thing the old floors × rooms-per-floor × capacity form could not
    // express at all.
    const plan = RoomPlan(
      floorPlans: [
        FloorPlan(
          groups: [
            RoomGroup(capacity: 3, count: 8),
            RoomGroup(capacity: 1, count: 4),
          ],
        ),
      ],
    );

    test('all of them land on the same floor', () {
      expect(plan.build().every((r) => r.floor == 1), isTrue);
      expect(plan.totalRooms, 12);
    });

    test('numbering runs straight through the groups, in order', () {
      final rooms = plan.build();
      expect(rooms.first.number, '101');
      expect(rooms.last.number, '112');
      expect(rooms[7].capacity, 3, reason: '101-108 are the three-seaters');
      expect(rooms[8].capacity, 1, reason: '109 onward are the singles');
    });

    test('beds count each group at its own size', () {
      expect(plan.totalBeds, 8 * 3 + 4 * 1);
    });

    test('a floor knows whether it is uniform', () {
      expect(plan.floorPlans.first.isUniform, isFalse);
      expect(
        const FloorPlan(groups: [RoomGroup(capacity: 2, count: 5)]).isUniform,
        isTrue,
      );
    });
  });

  group('degenerate input must not produce junk', () {
    test('an empty plan builds nothing', () {
      expect(const RoomPlan().build(), isEmpty);
      expect(const RoomPlan().totalRooms, 0);
      expect(const RoomPlan().totalBeds, 0);
    });

    test('a floor with zero rooms contributes nothing but still counts', () {
      const plan = RoomPlan(
        floorPlans: [
          FloorPlan(groups: [RoomGroup(capacity: 2, count: 0)]),
          FloorPlan(groups: [RoomGroup(capacity: 2, count: 2)]),
        ],
      );
      expect(plan.build().length, 2);
      expect(plan.floors, 2, reason: 'the empty floor still exists');
      // Numbered on floor 2, not renumbered to floor 1.
      expect(plan.build().first.number, '201');
    });

    test('a group with zero rooms is skipped, not built as one', () {
      const plan = RoomPlan(
        floorPlans: [
          FloorPlan(
            groups: [
              RoomGroup(capacity: 3, count: 0),
              RoomGroup(capacity: 2, count: 2),
            ],
          ),
        ],
      );
      final rooms = plan.build();
      expect(rooms.length, 2);
      expect(rooms.every((r) => r.capacity == 2), isTrue);
      expect(rooms.first.number, '101', reason: 'numbering is not skipped');
    });
  });

  group('rangeSummary', () {
    test('reads floor by floor', () {
      const plan = RoomPlan(
        floorPlans: [
          FloorPlan(
            groups: [
              RoomGroup(capacity: 3, count: 8),
              RoomGroup(capacity: 1, count: 4),
            ],
          ),
          FloorPlan(groups: [RoomGroup(capacity: 2, count: 10)]),
        ],
      );
      expect(
        plan.rangeSummary,
        'Floor 1: 8 × 3 Seater, 4 × Single  ·  Floor 2: 10 × 2 Seater',
      );
    });

    test('an empty plan says so rather than showing a blank', () {
      expect(const RoomPlan().rangeSummary, '—');
    });
  });

  group('the uniform shortcut', () {
    test('builds identical floors', () {
      final plan = RoomPlan.uniform(
        floors: 4,
        roomsPerFloor: 25,
        capacity: 2,
      );
      expect(plan.floors, 4);
      expect(plan.totalRooms, 100);
      expect(plan.totalBeds, 200);
      expect(plan.floorPlans.every((f) => f.isUniform), isTrue);
    });
  });
}
