import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/app_user.dart';
import '../utils/jpeg_shrink.dart';
import 'audit_service.dart';

export '../utils/jpeg_shrink.dart' show PhotoRejected;

/// Student ID photos — what a warden or guard checks a face against when they
/// don't know the student, so impersonation can be caught at the gate.
///
///   colleges/{collegeId}/photos/{uid}   { bytes (base64 JPEG), updatedAt, … }
///
/// One document per person, deliberately NOT a field on `users/{uid}`: every
/// roster stream reads every user document, and ~40 KB on each would turn a
/// 4,000-student roster into ~160 MB per load. Instead the user document
/// carries only `photoUpdatedAt`, so a screen knows whether there is a photo
/// without paying a read, and the photo is fetched once per session and only
/// where it is actually shown.
///
/// Base64 in Firestore rather than Storage because the project is on the
/// Spark plan — same pattern as office-order scans and the college logo.
class PhotoService {
  PhotoService._();
  static final PhotoService instance = PhotoService._();

  // A getter, not a field: resolved on use, so a failure to reach Firebase
  // lands inside _fetch's try and reads as "no photo" instead of throwing
  // out of a widget's build.
  FirebaseFirestore get _db => FirebaseFirestore.instance;

  /// Smallest source file accepted. Below this there is too little detail to
  /// tell one face from another, which is the entire point of the photo.
  static const int minSourceBytes = 20 * 1024;

  /// Longest side after shrinking — recognisable at the largest size any
  /// screen draws it, and typically 30–60 KB as a JPEG. A raw phone photo is
  /// 3–5 MB and would not fit in a Firestore document at all.
  static const int maxEdge = 480;

  /// Hard ceiling on what is stored, mirrored by the security rules. Keeps a
  /// few thousand photos well inside the Spark plan's 1 GiB of storage.
  static const int maxStoredBytes = 90 * 1024;

  DocumentReference<Map<String, dynamic>> _doc(String collegeId, String uid) =>
      _db.collection('colleges').doc(collegeId).collection('photos').doc(uid);

  // ------------------------------ preparing ------------------------------

  /// Turns whatever was picked into a small JPEG, or throws [PhotoRejected].
  static Future<Uint8List> prepare(Uint8List source) async {
    if (source.lengthInBytes < minSourceBytes) {
      throw PhotoRejected(
        'That photo is only ${(source.lengthInBytes / 1024).toStringAsFixed(1)} '
        'KB — too little detail to recognise someone by. Please use a clearer '
        'photo of at least ${minSourceBytes ~/ 1024} KB.',
      );
    }
    // Size fixed at maxEdge: a face needs the pixels more than the bytes, and
    // 480px fits the budget at every quality tried.
    return shrinkToJpeg(
      source,
      maxEdge: maxEdge,
      maxBytes: maxStoredBytes,
      edgeSteps: const [1],
      qualities: const [82, 72, 62, 52],
    );
  }

  // ------------------------------- reading -------------------------------

  final Map<String, _Entry> _cache = {};

  /// The photo, fetched once per session and shared by every screen after.
  ///
  /// [version] is the user's `photoUpdatedAt` when known; a different value
  /// means the photo was replaced and is fetched again. Null means "whatever
  /// is cached" — used where only a uid is known (a fine, an office order).
  /// Resolves to null when there is no photo or it can't be read.
  Future<Uint8List?> load(String collegeId, String uid, {DateTime? version}) {
    final key = '$collegeId/$uid';
    final hit = _cache[key];
    if (hit != null && (version == null || hit.sameVersion(version))) {
      return hit.bytes;
    }
    // Bounded: ~50 KB each, and a long session can browse a lot of people.
    if (_cache.length >= 250) _cache.clear();
    // Cached BEFORE the fetch starts: if the read fails synchronously, the
    // eviction in _fetch has to find this entry to remove it.
    final entry = _Entry(version);
    _cache[key] = entry;
    entry.bytes = _fetch(collegeId, uid, key, entry);
    return entry.bytes;
  }

  /// The photo if it has already arrived, so a widget can paint it on the
  /// first frame instead of flashing a placeholder for one.
  Uint8List? peek(String collegeId, String uid, {DateTime? version}) {
    final hit = _cache['$collegeId/$uid'];
    if (hit == null || (version != null && !hit.sameVersion(version))) {
      return null;
    }
    return hit.resolved;
  }

  Future<Uint8List?> _fetch(
    String collegeId,
    String uid,
    String key,
    _Entry entry,
  ) async {
    try {
      final snap = await _doc(collegeId, uid).get();
      final data = snap.data();
      final raw = data?['bytes'] as String?;
      final bytes = (raw == null || raw.isEmpty) ? null : base64Decode(raw);
      // Written onto this entry, not whatever is under the key now — an
      // upload may have replaced it while this read was in flight.
      entry.resolved = bytes;
      // Fetched by uid alone: learn the version, so a later caller that does
      // know it doesn't pay for the same photo again.
      entry.versionMs ??=
          (data?['updatedAt'] as Timestamp?)?.millisecondsSinceEpoch;
      return bytes;
    } catch (_) {
      // Offline or refused: don't remember the failure for the whole session.
      if (identical(_cache[key], entry)) _cache.remove(key);
      return null;
    }
  }

  /// Forgets every photo. Called on sign-out, so the next person to log in on
  /// this browser can't be shown faces their role isn't allowed to read.
  void clearCache() => _cache.clear();

  // ------------------------------- writing -------------------------------

  /// Stores [jpeg] (from [prepare]) as [student]'s photo.
  ///
  /// The photo and the user's `photoUpdatedAt` go in one batch so no screen
  /// can ever see a stamp for a photo that isn't there. The stamp is written
  /// from the client rather than as a server timestamp so it matches the
  /// cache entry set here exactly — otherwise the roster would echo back a
  /// slightly different time and every screen would re-read the photo.
  Future<void> upload({
    required AppUser student,
    required Uint8List jpeg,
    required AppUser actor,
  }) async {
    final collegeId = student.collegeId;
    final stamp = Timestamp.now();

    final batch = _db.batch()
      ..set(_doc(collegeId, student.uid), {
        // Also the document id; repeated as a field so tools/delete-students.js
        // can match photos by uid the same way it matches fines.
        'uid': student.uid,
        'bytes': base64Encode(jpeg),
        'mimeType': 'image/jpeg',
        'updatedAt': stamp,
        'updatedByUid': actor.uid,
        'updatedByName': actor.name,
      })
      ..update(_db.collection('users').doc(student.uid), {
        'photoUpdatedAt': stamp,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    await batch.commit();

    _cache['$collegeId/${student.uid}'] = _Entry(stamp.toDate())
      ..bytes = Future.value(jpeg)
      ..resolved = jpeg;

    // Worth a line in the log: swapping someone's ID photo is exactly how an
    // impersonation would be set up, so who changed it has to be findable.
    await AuditService.instance.record(
      collegeId: collegeId,
      actor: actor,
      action: student.hasPhoto ? 'user.photoReplace' : 'user.photoAdd',
      summary:
          '${student.hasPhoto ? 'Replaced' : 'Added'} the ID photo for '
          '${student.name}',
      targetLabel: student.name,
      path: 'users/${student.uid}',
    );
  }

  Future<void> remove({
    required AppUser student,
    required AppUser actor,
  }) async {
    final collegeId = student.collegeId;
    final batch = _db.batch()
      ..delete(_doc(collegeId, student.uid))
      ..update(_db.collection('users').doc(student.uid), {
        'photoUpdatedAt': FieldValue.delete(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    await batch.commit();
    _cache.remove('$collegeId/${student.uid}');

    await AuditService.instance.record(
      collegeId: collegeId,
      actor: actor,
      action: 'user.photoRemove',
      summary: 'Removed the ID photo for ${student.name}',
      targetLabel: student.name,
      path: 'users/${student.uid}',
    );
  }

  /// Deletes the photo document alone, when the person themselves is being
  /// deleted — an orphaned photo is ~50 KB of the storage quota nobody can
  /// ever see again.
  Future<void> deleteFor(String collegeId, String uid) async {
    await _doc(collegeId, uid).delete();
    _cache.remove('$collegeId/$uid');
  }

  /// The photo reference, for callers batching the delete with other writes.
  DocumentReference<Map<String, dynamic>> refFor(
    String collegeId,
    String uid,
  ) => _doc(collegeId, uid);
}

class _Entry {
  int? versionMs;
  late final Future<Uint8List?> bytes;
  Uint8List? resolved;

  _Entry(DateTime? version) : versionMs = version?.millisecondsSinceEpoch;

  // Milliseconds, not DateTime equality: a Timestamp round-tripped through
  // Firestore can differ from the local one below that.
  bool sameVersion(DateTime v) => versionMs == v.millisecondsSinceEpoch;
}
