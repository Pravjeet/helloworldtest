import 'package:flutter_test/flutter_test.dart';
import 'package:helloworld/services/csv_import.dart';

/// The account-creation pool in the CSV importer. Its whole job is to be fast
/// when Firebase allows it and to become the old sequential importer the
/// instant it doesn't — so the tests that matter are the ones about narrowing.
void main() {
  group('runPooled', () {
    test('every item is handled exactly once', () async {
      final seen = <int>[];
      await runPooled<int>(
        items: List.generate(50, (i) => i),
        lanes: 4,
        task: (item, lane) async {
          await Future<void>.delayed(Duration.zero);
          seen.add(item);
          return LaneVerdict.ok;
        },
      );

      expect(seen, hasLength(50));
      expect(seen.toSet(), List.generate(50, (i) => i).toSet());
    });

    test('work actually overlaps — lanes run concurrently', () async {
      var inFlight = 0;
      var peak = 0;

      await runPooled<int>(
        items: List.generate(20, (i) => i),
        lanes: 4,
        task: (item, lane) async {
          inFlight++;
          peak = peak > inFlight ? peak : inFlight;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          inFlight--;
          return LaneVerdict.ok;
        },
      );

      expect(peak, 4, reason: 'all four lanes should have been busy at once');
    });

    test('never exceeds the lane count', () async {
      var inFlight = 0;
      var peak = 0;

      await runPooled<int>(
        items: List.generate(30, (i) => i),
        lanes: 3,
        task: (item, lane) async {
          inFlight++;
          peak = peak > inFlight ? peak : inFlight;
          await Future<void>.delayed(const Duration(milliseconds: 2));
          inFlight--;
          return LaneVerdict.ok;
        },
      );

      expect(peak, lessThanOrEqualTo(3));
    });

    test('a narrow verdict drops the pool to one lane, permanently', () async {
      var inFlight = 0;
      final peakAfterNarrow = <int>[];
      var narrowed = false;

      await runPooled<int>(
        items: List.generate(40, (i) => i),
        lanes: 4,
        task: (item, lane) async {
          inFlight++;
          if (narrowed) peakAfterNarrow.add(inFlight);
          await Future<void>.delayed(const Duration(milliseconds: 2));
          inFlight--;

          // The tenth item is the one that gets throttled.
          if (item == 10) {
            narrowed = true;
            return LaneVerdict.narrow;
          }
          return LaneVerdict.ok;
        },
      );

      expect(
        peakAfterNarrow.every((n) => n <= 4),
        isTrue,
        reason: 'in-flight count must never grow after narrowing',
      );
      // Once the lanes in flight at the time have drained, nothing may overlap.
      expect(peakAfterNarrow.last, 1);
    });

    test('still finishes every item after narrowing', () async {
      final seen = <int>[];

      await runPooled<int>(
        items: List.generate(25, (i) => i),
        lanes: 4,
        task: (item, lane) async {
          await Future<void>.delayed(Duration.zero);
          seen.add(item);
          return item == 3 ? LaneVerdict.narrow : LaneVerdict.ok;
        },
      );

      expect(seen.toSet(), List.generate(25, (i) => i).toSet());
    });

    test('narrowing is one-way — a later ok does not widen it again', () async {
      var inFlight = 0;
      var peakLate = 0;
      var itemsDone = 0;

      await runPooled<int>(
        items: List.generate(30, (i) => i),
        lanes: 4,
        task: (item, lane) async {
          inFlight++;
          // Only measure well after the narrowing has taken effect.
          if (itemsDone > 12 && inFlight > peakLate) peakLate = inFlight;
          await Future<void>.delayed(const Duration(milliseconds: 2));
          inFlight--;
          itemsDone++;
          return item == 2 ? LaneVerdict.narrow : LaneVerdict.ok;
        },
      );

      expect(peakLate, 1);
    });

    test('cancelling stops early and reports it', () async {
      var handled = 0;
      var stopped = false;

      await runPooled<int>(
        items: List.generate(100, (i) => i),
        lanes: 2,
        isCancelled: () => handled >= 10,
        onStopped: () => stopped = true,
        task: (item, lane) async {
          await Future<void>.delayed(Duration.zero);
          handled++;
          return LaneVerdict.ok;
        },
      );

      expect(stopped, isTrue);
      expect(handled, lessThan(100));
      // Cancellation is checked between items, so the ones already in flight
      // finish — it must never abandon work midway.
      expect(handled, greaterThanOrEqualTo(10));
    });

    test('an empty list or no lanes does nothing, without throwing', () async {
      var called = false;
      Future<LaneVerdict> never(int item, int lane) async {
        called = true;
        return LaneVerdict.ok;
      }

      await runPooled<int>(items: [], lanes: 4, task: never);
      await runPooled<int>(items: [1, 2, 3], lanes: 0, task: never);

      expect(called, isFalse);
    });

    test('a lane index is always within range', () async {
      final lanesSeen = <int>{};

      await runPooled<int>(
        items: List.generate(30, (i) => i),
        lanes: 3,
        task: (item, lane) async {
          lanesSeen.add(lane);
          await Future<void>.delayed(Duration.zero);
          return LaneVerdict.ok;
        },
      );

      // Every lane id must be a valid index into the caller's per-lane
      // resources — the importer uses it to pick a provisioning FirebaseApp.
      expect(lanesSeen.every((l) => l >= 0 && l < 3), isTrue);
    });

    test('a task that throws propagates rather than hanging', () async {
      expect(
        () => runPooled<int>(
          items: [1, 2, 3],
          lanes: 2,
          task: (item, lane) async => throw StateError('boom'),
        ),
        throwsA(isA<StateError>()),
      );
    });
  });
}
