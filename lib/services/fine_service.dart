import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/app_user.dart';
import '../models/fine.dart';
import '../models/office_order.dart';
import 'audit_service.dart';
import 'stream_cache.dart';

/// Fines live under their college:
///   colleges/{collegeId}/fines/{fineId}
///
/// A flat collection rather than a subcollection per student, because the
/// dashboard's whole job is aggregating across everyone — one query beats a
/// collection-group scan. Two read paths, same as [RequestService]: a student
/// may only ever query their own, and the Firestore rules enforce that the
/// where-clause is present.
class FineService {
  FineService._();
  static final FineService instance = FineService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> _col(String collegeId) =>
      _db.collection('colleges').doc(collegeId).collection('fines');

  CollectionReference<Map<String, dynamic>> _ordersCol(String collegeId) =>
      _db.collection('colleges').doc(collegeId).collection('officeOrders');

  // ------------------------------ reads ------------------------------

  final CachedStreamPool<List<Fine>> _allPool = CachedStreamPool();

  /// Everything, newest first — for staff holding fines.viewAll.
  Stream<List<Fine>> watchAll(String collegeId) => _allPool.stream(
    collegeId,
    () => _col(collegeId)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((s) => s.docs.map((d) => Fine.fromMap(d.id, d.data())).toList()),
  );

  final CachedStreamPool<List<Fine>> _minePool = CachedStreamPool();

  /// One student's own fines. Not ordered in the query — an `orderBy` next to
  /// the `where` would need a composite index, and sorting a handful of
  /// documents client-side is free.
  ///
  /// Pooled per student. The document count is small, but this sits in
  /// `build()` on the student dashboard and the fines page — the two screens
  /// every one of a few thousand residents opens — so an unpooled re-read on
  /// each rebuild is a per-student cost paid thousands of times over.
  Stream<List<Fine>> watchMine(String collegeId, String uid) =>
      _minePool.stream('$collegeId/$uid', () {
        return _col(collegeId).where('studentUid', isEqualTo: uid).snapshots().map((
          s,
        ) {
          final list = s.docs.map((d) => Fine.fromMap(d.id, d.data())).toList();
          list.sort((a, b) {
            final at = a.createdAt, bt = b.createdAt;
            if (at == null && bt == null) return 0;
            if (at == null) return 1;
            if (bt == null) return -1;
            return bt.compareTo(at);
          });
          return list;
        });
      });

  // ------------------------------ writes -----------------------------

  /// Publishes one office order against one or more students, fining each of
  /// them whatever they individually deserve, in a single batch.
  ///
  /// One incident is one order. Five students in the same fight get one order
  /// naming all five, not five near-identical orders — which is how the office
  /// actually issues them, and it keeps the scanned photo stored once instead
  /// of five times (it is base64 in the document, so five copies is five times
  /// the storage and five times the read cost).
  ///
  /// **Amounts are per student.** [charges] pairs each student with what they
  /// owe, and a null or zero amount means that student is named on the order
  /// but not fined. That is a normal outcome, not an edge case: the ringleader
  /// and the bystander rarely pay the same, and letting one off with a warning
  /// while fining the others is exactly what a real order does. An order where
  /// nobody is fined is a warning, suspension or notice of enquiry, and writes
  /// no fine documents at all.
  ///
  /// [category] is shared — one incident is one reason — and is only required
  /// when somebody is actually being fined.
  ///
  /// Ids are pre-generated so the cross-links can be written in the same
  /// batch: each `fine.officeOrderId` points at the order, and each
  /// `order.students[].fineId` points back at that student's fine.
  Future<({List<String> fineIds, String orderId})> publishOfficeOrder({
    required String collegeId,
    required List<({AppUser student, num? amount})> charges,
    required AppUser imposedBy,
    String? category,
    String reason = '',
    required String orderNo,
    required String orderTitle,
    required Uint8List orderImageBytes,
    required String orderImageMimeType,
    String? orderDescription,
    DateTime? orderDate,
  }) async {
    if (charges.isEmpty) {
      throw ArgumentError('An office order must name at least one student.');
    }
    // The same student twice would raise two fines for one incident.
    final uids = charges.map((c) => c.student.uid).toSet();
    if (uids.length != charges.length) {
      throw ArgumentError('The same student is listed twice on this order.');
    }
    if (charges.any((c) => (c.amount ?? 0) < 0)) {
      throw ArgumentError('A fine cannot be for a negative amount.');
    }

    final fined = charges.where((c) => (c.amount ?? 0) > 0).toList();
    if (fined.isNotEmpty && (category == null || category.trim().isEmpty)) {
      throw ArgumentError('A fine needs a category.');
    }

    final orderRef = _ordersCol(collegeId).doc();
    final batch = _db.batch();

    final fineIds = <String>[];
    final covered = <OrderStudent>[];
    num total = 0;

    for (final charge in charges) {
      final student = charge.student;
      final amount = charge.amount;
      String? fineId;

      if (amount != null && amount > 0) {
        final fineRef = _col(collegeId).doc();
        fineId = fineRef.id;
        fineIds.add(fineRef.id);
        total += amount;

        final fine = Fine(
          id: fineRef.id,
          studentUid: student.uid,
          studentName: student.name,
          studentRegNo: student.enrollmentNo,
          hostelId: student.hostelId,
          hostelName: student.hostelName,
          roomNumber: student.roomNumber,
          trade: student.trade,
          batch: student.batch,
          sem: student.sem,
          // Fall back to parsing the address, so a student whose `state` field
          // was never filled in still lands on the right bar than "Not set".
          state: student.state ?? stateFromAddress(student.address),
          amount: amount,
          category: category!.trim(),
          reason: reason.trim(),
          officeOrderId: orderRef.id,
          officeOrderNo: orderNo.trim(),
          imposedByUid: imposedBy.uid,
          imposedByName: imposedBy.name,
        );
        batch.set(fineRef, {
          ...fine.toMap(),
          'createdAt': FieldValue.serverTimestamp(),
        });
      }

      covered.add(
        OrderStudent(
          uid: student.uid,
          name: student.name,
          regNo: student.enrollmentNo,
          fineId: fineId,
          fineAmount: fineId == null ? null : amount,
        ),
      );
    }

    final order = OfficeOrder(
      id: orderRef.id,
      orderNo: orderNo.trim(),
      title: orderTitle.trim(),
      description: (orderDescription == null || orderDescription.trim().isEmpty)
          ? null
          : orderDescription.trim(),
      orderDate: orderDate,
      imageBase64: base64Encode(orderImageBytes),
      imageMimeType: orderImageMimeType,
      postedByUid: imposedBy.uid,
      postedByName: imposedBy.name,
      students: covered,
      // Null rather than 0 when nobody was fined: the rules read this field to
      // decide whether the write needs fines.manage, and "absent" is the
      // clearest way to say "this order levies nothing".
      fineTotal: fined.isEmpty ? null : total,
      fineCategory: fined.isEmpty ? null : category!.trim(),
    );

    batch.set(orderRef, {
      ...order.toMap(),
      'createdAt': FieldValue.serverTimestamp(),
    });
    await batch.commit();

    final who = charges.length == 1
        ? charges.first.student.name
        : '${charges.length} students';
    await AuditService.instance.record(
      collegeId: collegeId,
      actor: imposedBy,
      action: fined.isEmpty ? 'officeOrder.publish' : 'fine.impose',
      summary: fined.isEmpty
          ? 'Issued order $orderNo against $who'
          : 'Fined ${fined.length} of $who '
                '\u20b9$total total for ${category!.trim()} (order $orderNo)',
      targetLabel: who,
      // Points at the order, which is the one document that always exists —
      // a group order has many fines and an order-only has none, so neither
      // makes a stable target.
      path: 'colleges/$collegeId/officeOrders/${orderRef.id}',
      reversible: false,
    );

    return (fineIds: fineIds, orderId: orderRef.id);
  }

  /// Marks a fine paid or waived, recording who decided.
  Future<void> setStatus({
    required String collegeId,
    required Fine fine,
    required FineStatus status,
    required AppUser handler,
  }) async {
    if (status == FineStatus.pending) {
      throw ArgumentError('Cannot move a fine back to unpaid.');
    }

    final ref = _col(collegeId).doc(fine.id);
    final before = (await ref.get()).data();

    await ref.update({
      'status': status.name,
      'resolvedByUid': handler.uid,
      'resolvedByName': handler.name,
      'resolvedAt': FieldValue.serverTimestamp(),
    });

    await AuditService.instance.record(
      collegeId: collegeId,
      actor: handler,
      action: 'fine.${status.name}',
      summary:
          'Marked ${fine.studentName}\'s ₹${fine.amount} fine '
          '${status.label.toLowerCase()}',
      targetLabel: fine.studentName,
      path: 'colleges/$collegeId/fines/${fine.id}',
      before: before,
      reversible: before != null,
    );
  }

  /// Removes a fine, paid or unpaid. Once removed there is no record it was
  /// ever collected — the caller decides that's acceptable, this doesn't.
  Future<void> remove({
    required String collegeId,
    required Fine fine,
    AppUser? actor,
  }) async {
    final ref = _col(collegeId).doc(fine.id);
    final before = (await ref.get()).data();
    await ref.delete();

    if (actor != null) {
      await AuditService.instance.record(
        collegeId: collegeId,
        actor: actor,
        action: 'fine.delete',
        summary: 'Removed ${fine.studentName}\'s ₹${fine.amount} fine',
        targetLabel: fine.studentName,
        path: 'colleges/$collegeId/fines/${fine.id}',
        before: before,
        reversible: before != null,
      );
    }
  }

  /// Deletes every fine belonging to one student.
  ///
  /// Called when the student's own account is deleted — a fine pointing at a
  /// uid that no longer exists is an orphaned record nobody can act on, not a
  /// preserved one. Unlike [remove] this does NOT spare settled fines, same
  /// reasoning as [deleteAll]: the person the money was owed by is gone, so
  /// there is nothing left to collect against.
  Future<int> deleteForStudent(String collegeId, String uid) async {
    final snap = await _col(
      collegeId,
    ).where('studentUid', isEqualTo: uid).get();
    if (snap.docs.isEmpty) return 0;

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

  /// Removes fines whose student is no longer in [liveUids].
  ///
  /// Filtered client-side because Firestore has no "not-in a set of N"
  /// operator, and the fine collection is small enough to read whole. For
  /// clearing the backlog left behind before the delete rule allowed removing
  /// a settled fine — see the note on `deleteForStudent`'s call site in
  /// `DataService.deleteUserCompletely`.
  Future<int> deleteOrphaned(String collegeId, Set<String> liveUids) async {
    final snap = await _col(collegeId).get();
    final orphaned = snap.docs.where((d) {
      final uid = d.data()['studentUid'] as String?;
      return uid == null || uid.isEmpty || !liveUids.contains(uid);
    }).toList();
    if (orphaned.isEmpty) return 0;

    for (var i = 0; i < orphaned.length; i += 400) {
      final end = (i + 400).clamp(0, orphaned.length);
      final batch = _db.batch();
      for (final d in orphaned.sublist(i, end)) {
        batch.delete(d.reference);
      }
      await batch.commit();
    }
    return orphaned.length;
  }

  /// Deletes every fine in the college. For clearing test data.
  ///
  /// Unlike [remove] this does NOT spare settled fines — the point is a clean
  /// slate, and a reset that left the paid ones behind would be a confusing
  /// half-measure. Guarded in the UI by a typed confirmation, and by
  /// `fines.manage` in the rules.
  ///
  /// Chunked because a Firestore batch caps at 500 operations.
  Future<int> deleteAll(String collegeId) async {
    final snap = await _col(collegeId).get();
    if (snap.docs.isEmpty) return 0;

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
}
