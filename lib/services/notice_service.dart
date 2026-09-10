import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/app_user.dart';
import '../models/notice.dart';
import 'stream_cache.dart';

/// Notices live under their college:
///   colleges/{collegeId}/notices/{noticeId}
///
/// Read by anyone with `notices.view`, created by anyone with `notices.manage`.
class NoticeService {
  NoticeService._();
  static final NoticeService instance = NoticeService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> _col(String collegeId) =>
      _db.collection('colleges').doc(collegeId).collection('notices');

  // ------------------------------ reads ------------------------------

  final CachedStreamPool<List<Notice>> _allPool = CachedStreamPool();

  /// All notices, newest first. Students see this; expired notices are filtered
  /// on the client side — the rules don't hide them, just in case staff want to
  /// see what's expired for archival purposes.
  Stream<List<Notice>> watchAll(String collegeId) => _allPool.stream(
    collegeId,
    () => _col(collegeId)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map(
          (s) => s.docs.map((d) => Notice.fromMap(d.id, d.data())).toList(),
        ),
  );

  // ------------------------------ writes -----------------------------

  /// Post a notice. Anyone with `notices.manage` can do this.
  Future<String> post({
    required String collegeId,
    required AppUser author,
    required String title,
    required String content,
    String category = 'General',
    DateTime? expiryDate,
  }) async {
    final ref = _col(collegeId).doc();
    final notice = Notice(
      id: ref.id,
      title: title.trim(),
      content: content.trim(),
      postedByUid: author.uid,
      postedByName: author.name,
      postedByDesignation: author.roleName,
      category: category,
      expiryDate: expiryDate,
    );

    await ref.set({
      ...notice.toMap(),
      'createdAt': FieldValue.serverTimestamp(),
    });
    return ref.id;
  }

  /// Delete a notice. Only the creator or a Super Admin can do this.
  /// The rules enforce this check — this is just the write.
  Future<void> delete({
    required String collegeId,
    required String noticeId,
  }) async {
    await _col(collegeId).doc(noticeId).delete();
  }
}
