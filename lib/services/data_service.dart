import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';

import '../core/identity.dart';
import '../core/permissions.dart';
import '../models/app_role.dart';
import '../models/app_user.dart';
import 'allotment_service.dart';
import 'audit_service.dart';
import 'auth_service.dart';
import 'fee_service.dart';
import 'fine_service.dart';
import 'photo_service.dart';
import 'request_service.dart';
import 'stream_cache.dart';

/// Firestore reads/writes for roles and users.
class DataService {
  DataService._();
  static final DataService instance = DataService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> _roles(String collegeId) =>
      _db.collection('colleges').doc(collegeId).collection('roles');

  // ------------------------------- Roles -------------------------------

  final CachedStreamPool<List<AppRole>> _rolePool = CachedStreamPool();

  Stream<List<AppRole>> watchRoles(String collegeId) => _rolePool.stream(
    collegeId,
    () => _roles(collegeId)
        .orderBy('name')
        .snapshots()
        .map(
          (s) => s.docs.map((d) => AppRole.fromMap(d.id, d.data())).toList(),
        ),
  );

  Future<void> createRole({
    required String collegeId,
    required String name,
    required String description,
    required Set<String> permissions,
  }) async {
    final id = name.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-');
    if (id.isEmpty) throw Exception('Role name is required.');

    final ref = _roles(collegeId).doc(id);
    if ((await ref.get()).exists) {
      throw Exception('A role named "$name" already exists.');
    }
    await ref.set({
      'name': name.trim(),
      'description': description.trim(),
      'permissions': permissions.toList(),
      'isSystem': false,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> updateRole(String collegeId, AppRole role) async {
    if (role.isSystem) {
      throw Exception('The Super Admin role cannot be edited.');
    }
    await _roles(collegeId).doc(role.id).update({
      ...role.toMap(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Deletes a role and un-assigns everyone who held it, in one batch so you
  /// can never end up with users pointing at a role that no longer exists.
  Future<void> deleteRole(String collegeId, AppRole role) async {
    if (role.isSystem) {
      throw Exception('The Super Admin role cannot be deleted.');
    }
    final holders = await _db
        .collection('users')
        .where('collegeId', isEqualTo: collegeId)
        .where('roleId', isEqualTo: role.id)
        .get();

    final batch = _db.batch();
    for (final d in holders.docs) {
      batch.update(d.reference, {'roleId': null, 'roleName': null});
    }
    batch.delete(_roles(collegeId).doc(role.id));
    await batch.commit();
  }

  // ------------------------------- Users -------------------------------

  final CachedStreamPool<List<AppUser>> _userPool = CachedStreamPool();

  /// The whole roster, shared.
  ///
  /// This is the single most expensive query in the app — with a few thousand
  /// students it is the entire `users` collection — and six screens want it.
  /// Going through [CachedStreamPool] means those six share one live query
  /// instead of opening one each, and that the returned object is stable, so a
  /// rebuild does not re-subscribe. See [CachedStream] for the arithmetic.
  Stream<List<AppUser>> watchUsers(String collegeId) => _userPool.stream(
    collegeId,
    () => _db
        .collection('users')
        .where('collegeId', isEqualTo: collegeId)
        .snapshots()
        .map(
          (s) => s.docs.map((d) => AppUser.fromMap(d.id, d.data())).toList()
            ..sort(
              (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
            ),
        ),
  );

  final CachedStreamPool<List<AppUser>> _roomPool = CachedStreamPool();

  /// The people in one room, live.
  ///
  /// The hostels pages used to answer this by streaming the entire roster and
  /// filtering in Dart — 2,649 documents to name three roommates. This asks
  /// Firestore the question directly, so it costs about one read and still
  /// updates the moment someone is allotted.
  ///
  /// [hostelId] is part of the query and not an afterthought: a room id is the
  /// room *number*, so "204" exists in most blocks. Matching on `roomId` alone
  /// would show BH-1's occupants inside BH-2's room.
  Stream<List<AppUser>> watchRoomOccupants(
    String collegeId,
    String hostelId,
    String roomId,
  ) => _roomPool.stream(
    '$collegeId/$hostelId/$roomId',
    () => _db
        .collection('users')
        .where('collegeId', isEqualTo: collegeId)
        .where('hostelId', isEqualTo: hostelId)
        .where('roomId', isEqualTo: roomId)
        .snapshots()
        .map(
          (s) => s.docs.map((d) => AppUser.fromMap(d.id, d.data())).toList()
            ..sort(
              (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
            ),
        ),
  );

  // ------------------------ counts, not documents ----------------------
  //
  // The dashboard wants seven integers. Reading the roster to derive them
  // costs one billed read per student — 2,650 of them on this campus, every
  // time the app is opened, which is most of a day's free quota for a screen
  // nobody has interacted with yet.
  //
  // count() answers from the index instead. Firestore bills one read per 1,000
  // index entries matched, so the same figure costs 3 reads rather than 2,650,
  // and no document data crosses the network.
  //
  // The trade is that these are one-shot Futures, not streams: the dashboard
  // shows a snapshot taken when it loaded rather than numbers that move by
  // themselves. For a summary screen that is the right way round — and the
  // operational screens that genuinely need live data still stream.

  Query<Map<String, dynamic>> _usersIn(String collegeId) =>
      _db.collection('users').where('collegeId', isEqualTo: collegeId);

  /// How many users in [collegeId] match the optional extra filters.
  ///
  /// Always scoped by college, never an unscoped count: the security rules
  /// reject a query that drops the `collegeId` filter (proved in
  /// rules-tests), and an unscoped total would be meaningless anyway.
  /// [graduated] only ever narrows *to* graduates — there is deliberately no
  /// "not graduated" option. Firestore's `!=` excludes documents where the
  /// field is **absent**, and `profileFor` in `tools/lib.js` never writes
  /// `status`, so every bulk-imported student has no such field. A
  /// `status != 'graduated'` filter would therefore exclude the entire
  /// imported roster and report zero residents while everyone is still here —
  /// the opposite failure, and far harder to notice. Count the graduates and
  /// subtract instead; equality matches only real graduates.
  Future<int> countUsers(
    String collegeId, {
    String? roleId,
    bool? isActive,
    bool? hasNoRole,
    bool graduated = false,
  }) async {
    var q = _usersIn(collegeId);
    if (roleId != null) q = q.where('roleId', isEqualTo: roleId);
    if (hasNoRole == true) q = q.where('roleId', isNull: true);
    if (isActive != null) q = q.where('isActive', isEqualTo: isActive);
    if (graduated) q = q.where('status', isEqualTo: 'graduated');

    final snap = await q.count().get();
    return snap.count ?? 0;
  }

  /// How many active students each of [hostelIds] holds.
  ///
  /// The same figure `studentsByHostel` derives from the roster, obtained
  /// without downloading it: one aggregation per block, so fourteen blocks
  /// cost about fourteen reads instead of 2,649.
  ///
  /// Counts `isActive`, not-graduated students, matching `studentsByHostel`
  /// exactly rather than reusing the hostel document's `occupiedBeds`. Those
  /// two are not the same number — a deactivated student still occupies their
  /// bed — and quietly swapping one for the other would change what the page
  /// reports.
  ///
  /// Graduates are subtracted rather than filtered out in the query, for the
  /// reason [countUsers] spells out: `status != 'graduated'` would drop every
  /// imported student, who has no `status` field at all. Two counts per
  /// hostel, then, but both still aggregations — no documents cross the wire.
  Future<Map<String, int>> countStudentsByHostel(
    String collegeId,
    List<String> hostelIds,
  ) async {
    Query<Map<String, dynamic>> active(String id) => _usersIn(
      collegeId,
    ).where('hostelId', isEqualTo: id).where('isActive', isEqualTo: true);

    Future<int> count(Query<Map<String, dynamic>> q) =>
        q.count().get().then((s) => s.count ?? 0);

    final results = await Future.wait([
      for (final id in hostelIds) ...[
        count(active(id)),
        count(active(id).where('status', isEqualTo: 'graduated')),
      ],
    ]);
    return {
      for (var i = 0; i < hostelIds.length; i++)
        if (results[2 * i] - results[2 * i + 1] > 0)
          hostelIds[i]: results[2 * i] - results[2 * i + 1],
    };
  }

  /// Every headline figure the dashboard needs, in one pass.
  ///
  /// Counting per role rather than per category is what makes this cheap and
  /// complete at once: the role documents are already streamed (six of them),
  /// and one count each yields the total, the student/staff split *and* the
  /// role breakdown chart. Classifying with [Perm.isResident] keeps that split
  /// agreeing with the rest of the app rather than re-deciding it here.
  Future<UserCounts> countUsersByRole(
    String collegeId,
    List<AppRole> roles,
  ) async {
    // Issued together; each is a separate round trip but they do not contend.
    //
    // Two passes per role — everyone, then the graduates — because the
    // dashboard is asking about people who are *here now*. Counting graduates
    // as residents is how a fully graduated campus went on reporting 2,649
    // residents against a hostel with every bed free. See [countUsers] for why
    // this subtracts rather than filtering them out in the query.
    final perRole = await Future.wait([
      for (final r in roles) countUsers(collegeId, roleId: r.id),
    ]);
    final perRoleGraduated = await Future.wait([
      for (final r in roles) countUsers(collegeId, roleId: r.id, graduated: true),
    ]);

    final byRoleName = <String, int>{};
    var residents = 0;
    var staff = 0;

    for (var i = 0; i < roles.length; i++) {
      final role = roles[i];
      final n = perRole[i] - perRoleGraduated[i];
      if (n <= 0) continue;
      byRoleName[role.name] = n;
      if (Perm.isResident(role.permissions)) {
        residents += n;
      } else {
        staff += n;
      }
    }

    final results = await Future.wait([
      countUsers(collegeId),
      countUsers(collegeId, hasNoRole: true),
      countUsers(collegeId, isActive: false),
      countUsers(collegeId, graduated: true),
    ]);

    final graduated = results[3];

    return UserCounts(
      // Current people, so the headline figure agrees with the tiles beneath
      // it. Alumni are still in the database and still reachable from User
      // Management — they are reported separately rather than folded in.
      total: results[0] - graduated,
      unassigned: results[1],
      inactive: results[2],
      residents: residents,
      staff: staff,
      graduated: graduated,
      byRoleName: byRoleName,
    );
  }

  Future<void> updateUser(String uid, Map<String, dynamic> changes) => _db
      .collection('users')
      .doc(uid)
      .update({...changes, 'updatedAt': FieldValue.serverTimestamp()});

  /// One person's current profile, read once with no listener left open —
  /// for a detail screen that needs a handful of people's room and trade,
  /// not a live roster. Null when they no longer exist.
  Future<AppUser?> fetchUser(String uid) async {
    final d = await _db.collection('users').doc(uid).get();
    return d.exists ? AppUser.fromMap(d.id, d.data()!) : null;
  }

  /// One-shot lookup by email within a college. Used by the CSV importer to
  /// find an account it just created, since account creation happens on a
  /// throwaway Firebase instance and doesn't hand back a profile document.
  Future<AppUser?> findByEmail(String collegeId, String email) async {
    final snap = await _db
        .collection('users')
        .where('collegeId', isEqualTo: collegeId)
        .where('email', isEqualTo: email.trim().toLowerCase())
        .limit(1)
        .get();
    if (snap.docs.isEmpty) return null;
    return AppUser.fromMap(snap.docs.first.id, snap.docs.first.data());
  }

  /// Changes an edit-in-place on a user, recording the prior document so the
  /// audit log can put it back.
  ///
  /// Shared by role changes and activation because both are one-field edits
  /// with the same undo shape — snapshot, write, log.
  Future<void> _auditedUpdate({
    required String uid,
    required Map<String, dynamic> changes,
    required String collegeId,
    required AppUser? actor,
    required String action,
    required String Function(AppUser user) summary,
  }) async {
    if (actor == null) {
      await updateUser(uid, changes);
      return;
    }

    final snap = await _db.collection('users').doc(uid).get();
    final before = snap.data();
    await updateUser(uid, changes);

    if (before != null) {
      final user = AppUser.fromMap(uid, before);
      await AuditService.instance.record(
        collegeId: collegeId,
        actor: actor,
        action: action,
        summary: summary(user),
        targetLabel: user.name,
        path: 'users/$uid',
        before: before,
        reversible: true,
      );
    }
  }

  Future<void> setUserRole(
    String uid,
    AppRole? role, {
    String? collegeId,
    AppUser? actor,
  }) => _auditedUpdate(
    uid: uid,
    changes: {'roleId': role?.id, 'roleName': role?.name},
    collegeId: collegeId ?? actor?.collegeId ?? '',
    actor: collegeId == null ? null : actor,
    action: 'user.role',
    summary: (u) =>
        'Changed ${u.name} from ${u.displayRole} to ${role?.name ?? 'no role'}',
  );

  Future<void> setUserActive(
    String uid,
    bool active, {
    String? collegeId,
    AppUser? actor,
  }) => _auditedUpdate(
    uid: uid,
    changes: {'isActive': active},
    collegeId: collegeId ?? actor?.collegeId ?? '',
    actor: collegeId == null ? null : actor,
    action: active ? 'user.activate' : 'user.deactivate',
    summary: (u) => '${active ? 'Reactivated' : 'Deactivated'} ${u.name}',
  );

  /// Removes the profile document only.
  Future<void> deleteUserProfile(String uid) =>
      _db.collection('users').doc(uid).delete();

  /// The passwords the app can reconstruct for [user] — only ever the ones
  /// derived from their registration number. The app has no store of real
  /// passwords and must not pretend otherwise. Shared by the single delete
  /// and the "delete all students" reset, so the two can never disagree.
  ///
  /// Mirrors both importers, which set `derivedPassword(registrationNo ||
  /// authEmail)` — so someone imported with an email and no registration
  /// number (staff, typically) got their lower-cased email as the password,
  /// and that is tried too.
  static List<String> derivedPasswordsFor(AppUser user) => <String>{
    if ((user.enrollmentNo ?? '').trim().isNotEmpty)
      Identity.derivedPassword(user.enrollmentNo!.trim()),
    if (Identity.isSynthetic(user.email))
      Identity.derivedPassword(Identity.display(user.email)),
    if ((user.enrollmentNo ?? '').trim().isEmpty &&
        !Identity.isSynthetic(user.email) &&
        user.email.trim().isNotEmpty)
      Identity.derivedPassword(user.email.trim().toLowerCase()),
  }.toList();

  /// Removes a user completely: the Firestore profile, their room, and — where
  /// possible — the Firebase Auth account too.
  ///
  /// Order matters. The Auth account goes first: if it fails we still have the
  /// profile to show who is left over. Deleting the profile first and then
  /// failing would leave an orphaned login with no record of whose it was.
  Future<UserDeleteOutcome> deleteUserCompletely({
    required String collegeId,
    required AppUser user,
    FirebaseApp? provisioningApp,

    /// When supplied, the deletion is written to the audit log with a
    /// snapshot, so it can be undone.
    AppUser? actor,
  }) async {
    if (user.isSuperAdmin) {
      throw StateError('Super Admin accounts cannot be deleted.');
    }

    // Captured BEFORE anything is removed — this is what undo restores.
    final snapshot = await _db.collection('users').doc(user.uid).get();
    final before = snapshot.data();

    // A record-only student has no login to remove — and trying would cost a
    // throttled sign-in attempt per person for nothing.
    final auth = !user.hasLogin
        ? AuthDeleteResult.alreadyGone
        : await AuthService.instance.deleteAuthAccount(
            email: user.email,
            candidatePasswords: derivedPasswordsFor(user),
            app: provisioningApp,
          );

    var vacated = false;
    if (user.isAllotted) {
      try {
        await AllotmentService.instance.vacate(
          collegeId: collegeId,
          student: user,
        );
        vacated = true;
      } catch (_) {
        // Recorded by the caller through [vacated]; a stale room must not
        // block removing the person.
      }
    }

    // A fine pointing at a uid that no longer exists is an orphaned record,
    // not a preserved one — see FineService.deleteForStudent. Best-effort:
    // whoever can delete a user may not hold fines.manage, and either way a
    // fines cleanup failure must not block removing the person.
    var finesDeleted = 0;
    try {
      finesDeleted = await FineService.instance.deleteForStudent(
        collegeId,
        user.uid,
      );
    } catch (_) {}

    // Same reasoning as fines above: a request pointing at a uid that no
    // longer exists is an orphaned record, not a preserved one. Best-effort
    // so a requests cleanup failure never blocks removing the person.
    var requestsDeleted = 0;
    try {
      requestsDeleted = await RequestService.instance.deleteForStudent(
        collegeId,
        user.uid,
      );
    } catch (_) {}

    // And their mess-fee history, for the same reason. This was the gap that
    // left the Mess Fees page reporting hundreds of residents and lakhs
    // pending after the roster had already been cleared.
    var feesDeleted = 0;
    try {
      feesDeleted = await FeeService.instance.deleteForStudent(
        collegeId,
        user.uid,
      );
    } catch (_) {}

    // Best-effort like the rest: a leftover photo is wasted storage, not a
    // reason to keep the person.
    if (user.hasPhoto) {
      try {
        await PhotoService.instance.deleteFor(collegeId, user.uid);
      } catch (_) {}
    }

    await deleteUserProfile(user.uid);

    if (actor != null && before != null) {
      await AuditService.instance.record(
        collegeId: collegeId,
        actor: actor,
        action: 'user.delete',
        summary:
            'Deleted ${user.name}'
            '${user.enrollmentNo == null ? '' : ' (${user.enrollmentNo})'}',
        targetLabel: user.name,
        path: 'users/${user.uid}',
        before: before,
        reversible: true,
        undoCaveat: auth == AuthDeleteResult.deleted
            ? 'Restores the profile only — the sign-in account was deleted '
                  'and cannot be recreated. They will need a new account to '
                  'log in.'
            : (vacated ? 'Restores the profile, but not their room.' : null),
      );
    }

    return UserDeleteOutcome(
      auth: auth,
      vacated: vacated,
      finesDeleted: finesDeleted,
      requestsDeleted: requestsDeleted,
      feesDeleted: feesDeleted,
    );
  }

  /// Deletes profile documents wholesale, in batches, with no per-user work.
  ///
  /// The counterpart to [deleteUserProfiles] for the case where *everyone* is
  /// going. That method does five round-trips per person — an Auth sign-in
  /// attempt, a vacate transaction, a fines query, a requests query, a delete
  /// — which is right for thirty students and unusable for three thousand.
  /// Here the attached records are cleared collection-at-a-time by the caller
  /// instead, and rooms are emptied in one sweep afterwards, so this only has
  /// to delete documents.
  ///
  /// Super Admins are filtered out before anything is written, so there is no
  /// path through this that locks you out of your own workspace.
  ///
  /// Returns the number of profiles removed. [isCancelled] is polled between
  /// batches; stopping leaves a partially-cleared roster, which is safe to
  /// resume by simply running again.
  Future<int> deleteProfilesInBulk({
    required List<AppUser> users,
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final targets = users.where((u) => !u.isSuperAdmin).toList();
    var done = 0;

    // 200 people is at most 400 deletes with their photos, under Firestore's
    // 500-writes-per-batch limit. Photos only for those who have one — a
    // delete of a missing document still spends a write from the daily quota.
    for (var i = 0; i < targets.length; i += 200) {
      if (isCancelled?.call() ?? false) break;
      final end = (i + 200).clamp(0, targets.length);
      final batch = _db.batch();
      for (final u in targets.sublist(i, end)) {
        batch.delete(_db.collection('users').doc(u.uid));
        if (u.hasPhoto) {
          batch.delete(PhotoService.instance.refFor(u.collegeId, u.uid));
        }
      }
      await batch.commit();
      done = end;
      onProgress?.call(done, targets.length);
    }
    return done;
  }

  /// Bulk-removes profiles, freeing any rooms they held first.
  ///
  /// Vacating before deleting is not optional: dropping the user document
  /// while their uid is still in a room's `occupantUids` leaves the room
  /// showing a resident who no longer exists and the hostel's `occupiedBeds`
  /// permanently overcounted. That drift is invisible until someone wonders
  /// why a half-empty block reports itself full.
  ///
  /// Deliberately sequential and best-effort: one student whose room was
  /// deleted out from under them must not abort the other twenty-nine.
  ///
  /// As with [deleteUserProfile], the Firebase Auth accounts survive. See
  /// `tools/delete-students.js` for a wipe that removes those too.
  /// [isCancelled] is polled between users, never mid-delete — same
  /// contract as [runImport]'s: a "Stop" click takes effect after whichever
  /// person is currently being removed finishes, not before. Re-running
  /// (selecting the same filter and deleting again) is safe and just picks
  /// up where it left off, since anyone already gone is simply absent from
  /// the next batch.
  Future<BulkDeleteOutcome> deleteUserProfiles({
    required String collegeId,
    required List<AppUser> users,
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final failures = <String>[];
    final authLeftBehind = <String>[];
    var deleted = 0;
    var vacated = 0;
    var finesDeleted = 0;
    var requestsDeleted = 0;
    var feesDeleted = 0;
    var authDeleted = 0;
    var done = 0;
    var stoppedEarly = false;

    // ONE provisioning app for the whole run — creating one per user is what
    // made bulk import crawl, and this does the same work.
    FirebaseApp? provisioning;

    try {
      // Only when someone in the batch actually has a login: opening one is
      // a whole extra Firebase app, wasted on a batch of record-only students.
      if (users.any((u) => u.hasLogin && !u.isSuperAdmin)) {
        provisioning = await AuthService.instance.openProvisioningApp();
      }

      for (final user in users) {
        if (isCancelled?.call() ?? false) {
          stoppedEarly = true;
          break;
        }
        if (user.isSuperAdmin) {
          failures.add('${user.name}: Super Admin accounts are never deleted');
          done++;
          onProgress?.call(done, users.length);
          continue;
        }

        try {
          final outcome = await deleteUserCompletely(
            collegeId: collegeId,
            user: user,
            provisioningApp: provisioning,
          );
          deleted++;
          if (outcome.vacated) vacated++;
          finesDeleted += outcome.finesDeleted;
          requestsDeleted += outcome.requestsDeleted;
          feesDeleted += outcome.feesDeleted;
          if (outcome.auth == AuthDeleteResult.deleted) {
            authDeleted++;
          } else if (!outcome.auth.isGone) {
            authLeftBehind.add('${user.name}: ${outcome.auth.explanation}');
          }
        } catch (e) {
          failures.add('${user.name}: ${e is FirebaseException ? e.code : e}');
        }

        done++;
        onProgress?.call(done, users.length);
      }
    } finally {
      if (provisioning != null) {
        await AuthService.instance.closeProvisioningApp(provisioning);
      }
    }

    return BulkDeleteOutcome(
      deleted: deleted,
      vacated: vacated,
      finesDeleted: finesDeleted,
      requestsDeleted: requestsDeleted,
      feesDeleted: feesDeleted,
      authDeleted: authDeleted,
      authLeftBehind: authLeftBehind,
      failures: failures,
      stoppedEarly: stoppedEarly,
      remaining: users.length - done,
    );
  }
}

class UserDeleteOutcome {
  final AuthDeleteResult auth;
  final bool vacated;
  final int finesDeleted;
  final int requestsDeleted;
  final int feesDeleted;
  const UserDeleteOutcome({
    required this.auth,
    required this.vacated,
    this.finesDeleted = 0,
    this.requestsDeleted = 0,
    this.feesDeleted = 0,
  });
}

class BulkDeleteOutcome {
  final int deleted;
  final int vacated;
  final int finesDeleted;
  final int requestsDeleted;
  final int feesDeleted;

  /// Sign-in accounts actually removed. Can be lower than [deleted] — see
  /// [authLeftBehind].
  final int authDeleted;

  /// Profiles removed whose sign-in account survived, each with the reason.
  final List<String> authLeftBehind;

  final List<String> failures;

  /// True when [DataService.deleteUserProfiles]'s `isCancelled` stopped the
  /// run before every user was processed.
  final bool stoppedEarly;

  /// How many users in the batch were never attempted because of that stop.
  final int remaining;

  const BulkDeleteOutcome({
    required this.deleted,
    required this.vacated,
    this.finesDeleted = 0,
    this.requestsDeleted = 0,
    this.feesDeleted = 0,
    this.authDeleted = 0,
    this.authLeftBehind = const [],
    required this.failures,
    this.stoppedEarly = false,
    this.remaining = 0,
  });
}

/// The dashboard's headline figures, counted rather than derived from
/// documents.
///
/// [residents] and [staff] are split by whether the role is a resident one, so
/// a Mess Manager counts as staff without anyone having to enumerate staff
/// role names here. Users with no role at all fall into neither and are
/// reported separately as [unassigned].
class UserCounts {
  final int total;
  final int unassigned;
  final int inactive;
  final int residents;
  final int staff;

  /// Alumni — students whose promotion carried them past the end of their
  /// course. Excluded from every other figure here, and reported on its own
  /// so a fully graduated campus reads as "0 residents, 2,649 alumni" rather
  /// than silently dropping two and a half thousand people out of the totals.
  final int graduated;

  /// Headcount per role name, for the breakdown chart. Roles with nobody in
  /// them are omitted rather than charted as a zero-width slice.
  final Map<String, int> byRoleName;

  const UserCounts({
    this.total = 0,
    this.unassigned = 0,
    this.inactive = 0,
    this.residents = 0,
    this.staff = 0,
    this.graduated = 0,
    this.byRoleName = const {},
  });
}
