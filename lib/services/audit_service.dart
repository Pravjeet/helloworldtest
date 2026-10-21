import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/app_user.dart';
import '../models/audit_entry.dart';
import 'stream_cache.dart';

/// Records what changed, and puts it back when asked.
///
/// Two rules shape this service:
///
/// **Recording must never break the thing it is recording.** Every [record]
/// call swallows its own errors. A warden imposing a fine should not see it
/// fail because the audit write did — the fine is the point, the log entry is
/// bookkeeping.
///
/// **Undo is generic.** An entry carries the document path and the document's
/// prior contents, so undo is "write `before` back, or delete if there was no
/// before". No per-action switch that rots as modules are added.
class AuditService {
  AuditService._();
  static final AuditService instance = AuditService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> _col(String collegeId) =>
      _db.collection('colleges').doc(collegeId).collection('auditLog');

  // ------------------------------ reads ------------------------------

  final CachedStreamPool<List<AuditEntry>> _pool = CachedStreamPool();

  /// Pooled per college+limit. The audit page rebuilds on every filter change
  /// and every keystroke in its search box; unpooled, each rebuild handed
  /// `StreamBuilder` a new stream object, which tore down the old listener and
  /// paid for all [limit] entries again. See [CachedStream].
  Stream<List<AuditEntry>> watch(String collegeId, {int limit = 200}) =>
      _pool.stream(
        '$collegeId/$limit',
        () => _col(collegeId)
            .orderBy('createdAt', descending: true)
            .limit(limit)
            .snapshots()
            .map(
              (s) => s.docs
                  .map((d) => AuditEntry.fromMap(d.id, d.data()))
                  .toList(),
            ),
      );

  // ------------------------------ writes -----------------------------

  /// Writes one entry. Never throws.
  ///
  /// [path] and [before] are what make the entry undoable; omit them for
  /// actions that cannot be reversed by rewriting a single document.
  Future<void> record({
    required String collegeId,
    required AppUser actor,
    required String action,
    required String summary,
    required String targetLabel,
    String? path,
    Map<String, dynamic>? before,
    bool reversible = false,
    String? undoCaveat,
  }) async {
    try {
      await _col(collegeId).add({
        ...AuditEntry(
          id: '',
          action: action,
          summary: summary,
          actorUid: actor.uid,
          actorName: actor.name,
          targetLabel: targetLabel,
          path: path,
          before: before == null ? null : _sanitise(before),
          reversible: reversible && path != null,
          undoCaveat: undoCaveat,
        ).toMap(),
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {
      // Deliberately silent. An audit failure must not surface as a failure
      // of the operation the user actually asked for.
    }
  }

  /// Puts the document back the way [entry] found it.
  ///
  /// Throws with a readable message rather than returning a flag — every
  /// caller here is a button that needs to show why it didn't work.
  Future<void> undo({
    required String collegeId,
    required AuditEntry entry,
    required AppUser actor,
  }) async {
    final blocked = entry.undoBlockedReason;
    if (blocked != null) throw StateError(blocked);

    final ref = _db.doc(entry.path!);

    if (entry.before == null) {
      // Nothing existed before, so the change was a creation: undo removes it.
      await ref.delete();
    } else {
      // `set` without merge, so fields ADDED by the change are removed too —
      // a merge would leave them behind and the "restored" document would not
      // match what was actually there.
      await ref.set(entry.before!);
    }

    await _col(collegeId).doc(entry.id).update({
      'undone': true,
      'undoneAt': FieldValue.serverTimestamp(),
      'undoneByName': actor.name,
    });

    await record(
      collegeId: collegeId,
      actor: actor,
      action: '${entry.module}.undo',
      summary: 'Undid: ${entry.summary}',
      targetLabel: entry.targetLabel,
    );
  }

  /// Deletes the whole log. For clearing test noise.
  Future<int> clear(String collegeId) async {
    final snap = await _col(collegeId).get();
    for (var i = 0; i < snap.docs.length; i += 400) {
      final end = (i + 400).clamp(0, snap.docs.length);
      final batch = _db.batch();
      for (final d in snap.docs.sublist(i, end)) {
        batch.delete(d.reference);
      }
      await batch.commit();
    }
    return snap.docs.length;
  }

  /// Firestore rejects nested values it cannot serialise, and a snapshot
  /// carrying a live `FieldValue` would corrupt the restore. Timestamps and
  /// primitives survive; anything exotic is dropped rather than risking the
  /// whole write.
  static Map<String, dynamic> _sanitise(Map<String, dynamic> input) {
    final out = <String, dynamic>{};
    input.forEach((k, v) {
      if (v == null ||
          v is String ||
          v is num ||
          v is bool ||
          v is Timestamp ||
          v is GeoPoint) {
        out[k] = v;
      } else if (v is DateTime) {
        out[k] = Timestamp.fromDate(v);
      } else if (v is List) {
        out[k] = v
            .where((e) => e == null || e is String || e is num || e is bool)
            .toList();
      } else if (v is Map) {
        out[k] = _sanitise(v.cast<String, dynamic>());
      }
    });
    return out;
  }
}
