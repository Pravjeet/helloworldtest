import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';

import '../core/identity.dart';
import '../models/app_role.dart';
import '../models/app_user.dart';
import 'allotment_service.dart';
import 'audit_service.dart';
import 'auth_service.dart';
import 'fine_service.dart';
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
    if (role.isSystem) throw Exception('The Super Admin role cannot be edited.');
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
  /// students it is the entire `users` collection — and several screens want
  /// it. Going through [CachedStreamPool] means they share one live query
  /// instead of opening one each, and that the returned object is stable, so
  /// a rebuild does not re-subscribe. See [CachedStream] for the arithmetic.
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

  Future<void> updateUser(String uid, Map<String, dynamic> changes) => _db
      .collection('users')
      .doc(uid)
      .update({...changes, 'updatedAt': FieldValue.serverTimestamp()});

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

    // Only the derived password is ever tried — the app has no store of real
    // ones and must not pretend otherwise.
    final candidates = <String>{
      if ((user.enrollmentNo ?? '').trim().isNotEmpty)
        Identity.derivedPassword(user.enrollmentNo!.trim()),
      if (Identity.isSynthetic(user.email))
        Identity.derivedPassword(Identity.display(user.email)),
    }.toList();

    final auth = await AuthService.instance.deleteAuthAccount(
      email: user.email,
      candidatePasswords: candidates,
      app: provisioningApp,
    );

    var vacated = false;
    if (user.isAllotted) {
      try {
        await AllotmentService.instance.vacate(collegeId: collegeId, student: user);
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

    await deleteUserProfile(user.uid);

    if (actor != null && before != null) {
      await AuditService.instance.record(
        collegeId: collegeId,
        actor: actor,
        action: 'user.delete',
        summary: 'Deleted ${user.name}'
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

    for (var i = 0; i < targets.length; i += 400) {
      if (isCancelled?.call() ?? false) break;
      final end = (i + 400).clamp(0, targets.length);
      final batch = _db.batch();
      for (final u in targets.sublist(i, end)) {
        batch.delete(_db.collection('users').doc(u.uid));
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
  Future<BulkDeleteOutcome> deleteUserProfiles({
    required String collegeId,
    required List<AppUser> users,
    void Function(int done, int total)? onProgress,
  }) async {
    final failures = <String>[];
    final authLeftBehind = <String>[];
    var deleted = 0;
    var vacated = 0;
    var finesDeleted = 0;
    var requestsDeleted = 0;
    var authDeleted = 0;
    var done = 0;

    // ONE provisioning app for the whole run — creating one per user is what
    // made bulk import crawl, and this does the same work.
    FirebaseApp? provisioning;

    try {
      provisioning = await AuthService.instance.openProvisioningApp();

      for (final user in users) {
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
      authDeleted: authDeleted,
      authLeftBehind: authLeftBehind,
      failures: failures,
    );
  }
}

class UserDeleteOutcome {
  final AuthDeleteResult auth;
  final bool vacated;
  final int finesDeleted;
  final int requestsDeleted;
  const UserDeleteOutcome({
    required this.auth,
    required this.vacated,
    this.finesDeleted = 0,
    this.requestsDeleted = 0,
  });
}

class BulkDeleteOutcome {
  final int deleted;
  final int vacated;
  final int finesDeleted;
  final int requestsDeleted;

  /// Sign-in accounts actually removed. Can be lower than [deleted] — see
  /// [authLeftBehind].
  final int authDeleted;

  /// Profiles removed whose sign-in account survived, each with the reason.
  final List<String> authLeftBehind;

  final List<String> failures;

  const BulkDeleteOutcome({
    required this.deleted,
    required this.vacated,
    this.finesDeleted = 0,
    this.requestsDeleted = 0,
    this.authDeleted = 0,
    this.authLeftBehind = const [],
    required this.failures,
  });
}
