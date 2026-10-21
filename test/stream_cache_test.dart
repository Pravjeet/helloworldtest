import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:helloworld/services/stream_cache.dart';

/// These exist because [CachedStream] sits under every screen in the app. If
/// it opens a second query the read savings vanish; if it drops or reorders an
/// event, a page shows stale data with nothing to indicate it. Both failures
/// are silent, so they get tests rather than trust.
void main() {
  group('CachedStream', () {
    test('opens the upstream once no matter how many listeners', () async {
      var opened = 0;
      final controller = StreamController<int>.broadcast();
      final cached = CachedStream<int>(() {
        opened++;
        return controller.stream;
      });

      final a = cached.listen((_) {});
      final b = cached.listen((_) {});
      final c = cached.listen((_) {});
      await Future<void>.delayed(Duration.zero);

      expect(opened, 1, reason: 'three screens must share one query');

      await a.cancel();
      await b.cancel();
      await c.cancel();
      await cached.dispose();
      await controller.close();
    });

    test('a listener that arrives late is given the cached value', () async {
      final controller = StreamController<int>.broadcast();
      final cached = CachedStream<int>(() => controller.stream);

      final first = <int>[];
      final subA = cached.listen(first.add);
      await Future<void>.delayed(Duration.zero);
      controller.add(7);
      await Future<void>.delayed(Duration.zero);
      expect(first, [7]);

      // The case that matters: a page opened after the data already landed.
      // Without replay this sits on a spinner until something changes.
      final second = <int>[];
      final subB = cached.listen(second.add);
      await Future<void>.delayed(Duration.zero);
      expect(second, [7]);

      await subA.cancel();
      await subB.cancel();
      await cached.dispose();
      await controller.close();
    });

    test('later values still reach everyone', () async {
      final controller = StreamController<int>.broadcast();
      final cached = CachedStream<int>(() => controller.stream);

      final a = <int>[];
      final b = <int>[];
      final subA = cached.listen(a.add);
      await Future<void>.delayed(Duration.zero);
      controller.add(1);
      await Future<void>.delayed(Duration.zero);

      final subB = cached.listen(b.add);
      await Future<void>.delayed(Duration.zero);
      controller.add(2);
      await Future<void>.delayed(Duration.zero);

      expect(a, [1, 2]);
      expect(b, [1, 2], reason: 'replayed 1, then live 2 — in that order');

      await subA.cancel();
      await subB.cancel();
      await cached.dispose();
      await controller.close();
    });

    test('the upstream survives the last listener leaving', () async {
      var opened = 0;
      final controller = StreamController<int>.broadcast();
      final cached = CachedStream<int>(() {
        opened++;
        return controller.stream;
      });

      final sub = cached.listen((_) {});
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      // Navigating away and back is the whole point — it must not re-query.
      final again = <int>[];
      final sub2 = cached.listen(again.add);
      await Future<void>.delayed(Duration.zero);

      expect(opened, 1);

      await sub2.cancel();
      await cached.dispose();
      await controller.close();
    });

    test('an error is replayed, so a late page shows it', () async {
      final controller = StreamController<int>.broadcast();
      final cached = CachedStream<int>(() => controller.stream);

      final subA = cached.listen((_) {}, onError: (_) {});
      await Future<void>.delayed(Duration.zero);
      controller.addError(StateError('permission-denied'));
      await Future<void>.delayed(Duration.zero);

      Object? seen;
      final subB = cached.listen((_) {}, onError: (Object e) => seen = e);
      await Future<void>.delayed(Duration.zero);

      expect(seen, isA<StateError>());

      await subA.cancel();
      await subB.cancel();
      await cached.dispose();
      await controller.close();
    });

    test('after an error, the next listener opens a fresh query', () async {
      // Firestore ends a listener after permission-denied. Keeping the dead
      // subscription meant a page reopened after a rules deploy replayed the
      // old error until sign-out, and never saw the data it may now read.
      var opened = 0;
      final controllers = <StreamController<int>>[];
      final cached = CachedStream<int>(() {
        opened++;
        final c = StreamController<int>.broadcast();
        controllers.add(c);
        return c.stream;
      });

      final subA = cached.listen((_) {}, onError: (_) {});
      await Future<void>.delayed(Duration.zero);
      controllers.last.addError(StateError('permission-denied'));
      await Future<void>.delayed(Duration.zero);

      final seen = <int>[];
      final subB = cached.listen(seen.add, onError: (_) {});
      await Future<void>.delayed(Duration.zero);
      expect(opened, 2, reason: 'the dead query must be replaced');

      controllers.last.add(7);
      await Future<void>.delayed(Duration.zero);
      expect(seen, [7]);

      await subA.cancel();
      await subB.cancel();
      await cached.dispose();
      for (final c in controllers) {
        await c.close();
      }
    });

    test('disposeAll drops the query and the cached value', () async {
      var opened = 0;
      final controller = StreamController<int>.broadcast();
      final pool = CachedStreamPool<int>();

      Stream<int> open() => pool.stream('k', () {
        opened++;
        return controller.stream;
      });

      final sub = open().listen((_) {});
      await Future<void>.delayed(Duration.zero);
      controller.add(1);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      await StreamCaches.disposeAll();

      // After sign-out the next session must re-query rather than be handed a
      // closed stream, or the previous user's data.
      final after = <int>[];
      final sub2 = open().listen(after.add);
      await Future<void>.delayed(Duration.zero);
      controller.add(2);
      await Future<void>.delayed(Duration.zero);

      expect(opened, 2, reason: 'a fresh query after sign-out');
      expect(after, [2], reason: 'the old value must not be replayed');

      await sub2.cancel();
      await StreamCaches.disposeAll();
      await controller.close();
    });

    test('the pool hands back one instance per key', () {
      final pool = CachedStreamPool<int>();
      final c = StreamController<int>.broadcast();

      final a1 = pool.stream('a', () => c.stream);
      final a2 = pool.stream('a', () => c.stream);
      final b1 = pool.stream('b', () => c.stream);

      // Identity is what stops StreamBuilder re-subscribing on every rebuild.
      expect(identical(a1, a2), isTrue);
      expect(identical(a1, b1), isFalse);

      c.close();
    });
  });
}
