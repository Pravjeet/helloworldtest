import 'package:flutter_test/flutter_test.dart';
import 'package:helloworld/models/app_user.dart';
import 'package:helloworld/services/auth_service.dart';
import 'package:helloworld/services/reset_service.dart';

/// "Delete all students" removes sign-in accounts by signing in as each one.
/// What's pinned here is everything around that call: that every account is
/// tried exactly once, that Firebase's "slow down" is retried rather than
/// written off, that it narrows the pool for good, and that whatever is left
/// behind is named — the next import's "email already in use" depends on it.
void main() {
  AppUser user(String reg) => AppUser(
    uid: 'u$reg',
    name: 'Student $reg',
    email: '$reg@x.test',
    collegeId: 'c1',
    roleId: 'r1',
    roleName: 'Student',
    enrollmentNo: reg,
  );

  Future<void> noWait(Duration _) async {}

  test('every account is tried once and counted', () async {
    final tried = <String>[];
    final r = await removeSignInAccounts(
      users: [for (var i = 0; i < 20; i++) user('$i')],
      sleep: noWait,
      remove: (u, _) async {
        tried.add(u.uid);
        return AuthDeleteResult.deleted;
      },
    );
    expect(r.deleted, 20);
    expect(r.kept, isEmpty);
    expect(tried.toSet(), hasLength(20));
    expect(tried, hasLength(20));
  });

  test('already-gone accounts are neither counted nor reported', () async {
    final r = await removeSignInAccounts(
      users: [user('1'), user('2')],
      sleep: noWait,
      remove: (u, _) async => u.enrollmentNo == '1'
          ? AuthDeleteResult.alreadyGone
          : AuthDeleteResult.deleted,
    );
    expect(r.deleted, 1);
    expect(r.kept, isEmpty);
  });

  test('accounts that survive are named, with the reason', () async {
    final r = await removeSignInAccounts(
      users: [user('1'), user('2'), user('3')],
      sleep: noWait,
      remove: (u, _) async => switch (u.enrollmentNo) {
        '1' => AuthDeleteResult.wrongPassword,
        '2' => AuthDeleteResult.noCredential,
        _ => AuthDeleteResult.deleted,
      },
    );
    expect(r.deleted, 1);
    expect(r.kept, hasLength(2));
    expect(r.kept.first, startsWith('Student 1: '));
    expect(r.kept.first, contains('--orphans'));
  });

  test('a throttle is waited out and retried, not written off', () async {
    final waits = <Duration>[];
    var calls = 0;
    final r = await removeSignInAccounts(
      users: [user('1')],
      sleep: (d) async => waits.add(d),
      remove: (_, _) async =>
          ++calls < 3 ? AuthDeleteResult.throttled : AuthDeleteResult.deleted,
    );
    expect(r.deleted, 1);
    expect(r.kept, isEmpty);
    expect(waits, kAccountThrottleBackoff.take(2).toList());
  });

  test('throttled past every retry is reported, not lost', () async {
    final r = await removeSignInAccounts(
      users: [user('1')],
      sleep: noWait,
      remove: (_, _) async => AuthDeleteResult.throttled,
    );
    expect(r.deleted, 0);
    expect(r.kept, hasLength(1));
    expect(r.kept.single, contains('throttled'));
  });

  test('after a throttle the pool narrows to one lane for good', () async {
    var throttled = false;
    var otherLaneCallsAfter = 0;
    var lane0CallsAfter = 0;
    final r = await removeSignInAccounts(
      users: [for (var i = 0; i < 40; i++) user('$i')],
      lanes: 4,
      sleep: noWait,
      remove: (u, lane) async {
        if (throttled) {
          lane == 0 ? lane0CallsAfter++ : otherLaneCallsAfter++;
        }
        await Future<void>.delayed(Duration.zero);
        if (u.enrollmentNo == '2' && !throttled) {
          throttled = true;
          return AuthDeleteResult.throttled;
        }
        return AuthDeleteResult.deleted;
      },
    );
    // Every account still gets done…
    expect(r.deleted, 40);
    // …but once throttled, the other three lanes stop claiming work: at most
    // the one retry of the throttled account plus nothing new each, while
    // lane 0 carries the rest of the queue on its own.
    expect(otherLaneCallsAfter, lessThanOrEqualTo(3));
    expect(lane0CallsAfter, greaterThan(20));
  });

  test('Stop is honoured between accounts', () async {
    var stop = false;
    var tried = 0;
    final r = await removeSignInAccounts(
      users: [for (var i = 0; i < 30; i++) user('$i')],
      lanes: 1,
      sleep: noWait,
      isCancelled: () => stop,
      remove: (_, _) async {
        if (++tried == 5) stop = true;
        return AuthDeleteResult.deleted;
      },
    );
    expect(tried, 5);
    expect(r.deleted, 5);
  });

  test('progress reaches the total', () async {
    final seen = <int>[];
    await removeSignInAccounts(
      users: [for (var i = 0; i < 7; i++) user('$i')],
      sleep: noWait,
      onProgress: (done, total) {
        expect(total, 7);
        seen.add(done);
      },
      remove: (_, _) async => AuthDeleteResult.deleted,
    );
    expect(seen.last, 7);
    expect(seen, hasLength(7));
  });
}
