import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/app_user.dart';
import 'audit_service.dart';
import 'auth_service.dart';

/// Turns a record-only student (see [AppUser.hasLogin]) into one who can sign
/// in.
///
/// The catch is the id. Every profile lives at `users/{uid}` and the rules
/// identify "this is you" by matching that id to the signed-in account. A
/// student imported without a login got a random id; Firebase then hands the
/// new sign-in account a different one, and on the free plan nothing can
/// choose it. So the record moves to the new id, and everything that names
/// the student by id moves with it:
///
///   * `enrollments/{uid}_{session}`   re-keyed, `uid` rewritten
///   * `feeRecords/{period}_{uid}`     re-keyed, `studentUid` rewritten
///   * `fines`                         `studentUid`
///   * `officeOrders`                  `students[].uid`, `studentUids`
///   * `requests`                      `raisedByUid`
///   * the room's `occupantUids`
///   * `photos/{uid}`                  re-keyed
///
/// The audit log is left as it is: it is the record of what happened under
/// the old id, and rewriting history is exactly what it exists to prevent.
///
/// Order matters, and makes the whole thing resumable:
///
///  1. Create the sign-in account, and note its uid on the old record
///     ([AppUser.pendingLoginUid]) before anything else — if the run dies
///     after this, the next attempt picks up that account instead of failing
///     with "email already in use".
///  2. Write the profile under the new id. The photo rule checks that the
///     person it belongs to exists, so this goes before the references.
///  3. Move every reference. Each step looks for what still points at the old
///     id, so running it twice finds nothing the second time.
///  4. Delete the old record — last, so a failure anywhere above leaves it in
///     place to resume from.
class LoginAccountService {
  LoginAccountService._();
  static final LoginAccountService instance = LoginAccountService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  /// Firestore caps a single batch at 500 operations.
  static const int _batchLimit = 450;

  CollectionReference<Map<String, dynamic>> _college(
    String collegeId,
    String name,
  ) => _db.collection('colleges').doc(collegeId).collection(name);

  /// Creates [student]'s sign-in account with [password] and moves their
  /// record onto it. Returns the new uid.
  ///
  /// [password] is ignored when resuming a run that already created the
  /// account.
  Future<String> createLogin({
    required AppUser student,
    required String password,
    required AppUser actor,
  }) async {
    if (!actor.isSuperAdmin) {
      throw AuthFailure('Only a Super Admin can create sign-in accounts.');
    }

    final oldUid = student.uid;
    final oldRef = _db.collection('users').doc(oldUid);
    final snap = await oldRef.get();
    final data = snap.data();
    if (data == null) {
      throw AuthFailure('This student no longer exists.');
    }
    if (data['hasLogin'] != false) {
      throw AuthFailure('${student.name} already has a sign-in account.');
    }
    final email = (data['email'] as String? ?? '').trim();
    if (email.isEmpty) {
      throw AuthFailure(
        '${student.name} has no registration number or email to sign in with.',
      );
    }

    // ---- 1. the account ----------------------------------------------------
    var newUid = data['pendingLoginUid'] as String?;
    if (newUid == null || newUid.isEmpty) {
      newUid = await _createAuthAccount(email, password);
      await oldRef.update({
        'pendingLoginUid': newUid,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }

    // ---- 2. the profile, under its new id ----------------------------------
    final profile = Map<String, dynamic>.from(data)
      ..remove('pendingLoginUid')
      ..['uid'] = newUid
      ..['hasLogin'] = true
      ..['loginCreatedAt'] = FieldValue.serverTimestamp()
      ..['updatedAt'] = FieldValue.serverTimestamp();
    await _db.collection('users').doc(newUid).set(profile);

    // ---- 3. everything that names them -------------------------------------
    final collegeId = data['collegeId'] as String? ?? student.collegeId;
    await _moveReferences(
      collegeId: collegeId,
      oldUid: oldUid,
      newUid: newUid,
      hostelId: data['hostelId'] as String?,
      roomId: data['roomId'] as String?,
      actorUid: actor.uid,
    );

    // ---- 4. the old record -------------------------------------------------
    await oldRef.delete();

    await AuditService.instance.record(
      collegeId: collegeId,
      actor: actor,
      action: 'user.createLogin',
      summary:
          'Created a sign-in account for ${student.name}'
          '${student.enrollmentNo == null ? '' : ' (${student.enrollmentNo})'}',
      targetLabel: student.name,
      path: 'users/$newUid',
    );

    return newUid;
  }

  /// Makes the Firebase Auth account on an isolated app, so the Super Admin's
  /// own session is never replaced — see [AuthService.openProvisioningApp].
  Future<String> _createAuthAccount(String email, String password) async {
    final app = await AuthService.instance.openProvisioningApp();
    try {
      final cred = await FirebaseAuth.instanceFor(
        app: app,
      ).createUserWithEmailAndPassword(email: email, password: password);
      return cred.user!.uid;
    } on FirebaseAuthException catch (e) {
      if (e.code == 'email-already-in-use') {
        throw AuthFailure(
          'A sign-in account for $email already exists, left over from '
          'an earlier import. Remove it with '
          '`node delete-students.js --orphans --commit` in tools/, then '
          'try again.',
        );
      }
      throw AuthFailure(AuthService.describeError(e));
    } finally {
      await AuthService.instance.closeProvisioningApp(app);
    }
  }

  Future<void> _moveReferences({
    required String collegeId,
    required String oldUid,
    required String newUid,
    required String? hostelId,
    required String? roomId,
    required String actorUid,
  }) async {
    final writes = <void Function(WriteBatch)>[];

    // Enrollments and fee records carry the uid in their id, so they are
    // re-created under the new id rather than edited.
    final enrollments = await _college(
      collegeId,
      'enrollments',
    ).where('uid', isEqualTo: oldUid).get();
    for (final d in enrollments.docs) {
      final to = _college(
        collegeId,
        'enrollments',
      ).doc(rekeyId(d.id, oldUid, newUid));
      final moved = {...d.data(), 'uid': newUid};
      writes
        ..add((b) => b.set(to, moved))
        ..add((b) => b.delete(d.reference));
    }

    final fees = await _college(
      collegeId,
      'feeRecords',
    ).where('studentUid', isEqualTo: oldUid).get();
    for (final d in fees.docs) {
      final to = _college(
        collegeId,
        'feeRecords',
      ).doc(rekeyId(d.id, oldUid, newUid));
      final moved = {...d.data(), 'studentUid': newUid};
      writes
        ..add((b) => b.set(to, moved))
        ..add((b) => b.delete(d.reference));
    }

    final fines = await _college(
      collegeId,
      'fines',
    ).where('studentUid', isEqualTo: oldUid).get();
    for (final d in fines.docs) {
      writes.add((b) => b.update(d.reference, {'studentUid': newUid}));
    }

    final orders = await _college(
      collegeId,
      'officeOrders',
    ).where('studentUids', arrayContains: oldUid).get();
    for (final d in orders.docs) {
      final changes = rewriteOrderStudents(d.data(), oldUid, newUid);
      if (changes.isNotEmpty) {
        writes.add((b) => b.update(d.reference, changes));
      }
    }

    final requests = await _college(
      collegeId,
      'requests',
    ).where('raisedByUid', isEqualTo: oldUid).get();
    for (final d in requests.docs) {
      writes.add((b) => b.update(d.reference, {'raisedByUid': newUid}));
    }

    if (hostelId != null && roomId != null) {
      final roomRef = _college(
        collegeId,
        'hostels',
      ).doc(hostelId).collection('rooms').doc(roomId);
      final room = await roomRef.get();
      final occupants = ((room.data()?['occupantUids'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList();
      if (occupants.contains(oldUid)) {
        writes.add(
          (b) => b.update(roomRef, {
            'occupantUids': [
              for (final u in occupants) u == oldUid ? newUid : u,
            ],
          }),
        );
      }
    }

    final photoFrom = _college(collegeId, 'photos').doc(oldUid);
    final photo = await photoFrom.get();
    if (photo.exists) {
      final moved = {
        ...photo.data()!,
        'uid': newUid,
        // The rule requires whoever writes a photo to be named as its last
        // editor. It is the same picture; only where it lives has changed.
        'updatedByUid': actorUid,
      };
      writes
        ..add(
          (b) => b.set(_college(collegeId, 'photos').doc(newUid), moved),
        )
        ..add((b) => b.delete(photoFrom));
    }

    for (var i = 0; i < writes.length; i += _batchLimit) {
      final batch = _db.batch();
      for (final w in writes.sublist(
        i,
        (i + _batchLimit).clamp(0, writes.length),
      )) {
        w(batch);
      }
      await batch.commit();
    }
  }
}

/// The id a uid-keyed document gets once its student moves to [newUid].
///
/// Enrollments are `{uid}_{session}` and fee records `{period}_{uid}`, so the
/// uid is swapped wherever it sits as a whole `_`-separated part. An id that
/// doesn't contain it is returned unchanged.
String rekeyId(String id, String oldUid, String newUid) {
  if (id.startsWith('${oldUid}_')) return newUid + id.substring(oldUid.length);
  if (id.endsWith('_$oldUid')) {
    return id.substring(0, id.length - oldUid.length) + newUid;
  }
  if (id == oldUid) return newUid;
  return id;
}

/// The fields of an office order to change so it names [newUid] where it
/// named [oldUid]. Empty when the order doesn't mention them.
///
/// Covers both shapes an order can have: `students[]` plus the flat
/// `studentUids` index, and the single `studentUid` of orders written before
/// orders could name several students.
Map<String, dynamic> rewriteOrderStudents(
  Map<String, dynamic> order,
  String oldUid,
  String newUid,
) {
  final out = <String, dynamic>{};

  final students = order['students'] as List?;
  if (students != null) {
    var touched = false;
    final rewritten = [
      for (final s in students)
        if (s is Map && s['uid'] == oldUid)
          (() {
            touched = true;
            return {...s.cast<String, dynamic>(), 'uid': newUid};
          })()
        else
          s,
    ];
    if (touched) out['students'] = rewritten;
  }

  final uids = order['studentUids'] as List?;
  if (uids != null && uids.contains(oldUid)) {
    out['studentUids'] = [for (final u in uids) u == oldUid ? newUid : u];
  }

  if (order['studentUid'] == oldUid) out['studentUid'] = newUid;

  return out;
}
