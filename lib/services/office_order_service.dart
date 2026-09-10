import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/office_order.dart';

/// Office orders live under their college:
///   colleges/{collegeId}/officeOrders/{orderId}
///
/// Read by anyone with `officeOrders.view`. Writing one is not exposed here
/// — every order now exists because a fine was imposed under it, so creation
/// happens in [FineService.imposeWithOfficeOrder], which writes both
/// documents in one batch. There is no update path either — an order printed
/// wrong is deleted and the fine re-imposed, same as notices, because an
/// "edited" office order is not a thing that exists on paper.
class OfficeOrderService {
  OfficeOrderService._();
  static final OfficeOrderService instance = OfficeOrderService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> _col(String collegeId) =>
      _db.collection('colleges').doc(collegeId).collection('officeOrders');

  // ------------------------------ reads ------------------------------

  /// Ordered by the date printed on the order, newest first — not by upload
  /// time, since a backlog of old orders is usually entered all at once.
  Stream<List<OfficeOrder>> watchAll(String collegeId) => _col(collegeId)
      .orderBy('orderDate', descending: true)
      .snapshots()
      .map(
        (s) => s.docs.map((d) => OfficeOrder.fromMap(d.id, d.data())).toList(),
      );

  /// One student's own orders, for their detail page. Not ordered in the
  /// query — same reasoning as [FineService.watchMine]: an extra composite
  /// index isn't worth it for sorting a handful of documents client-side.
  ///
  /// Matches on the flat `studentUids` array rather than `students[].uid`,
  /// because Firestore's array-contains cannot look inside the maps of an
  /// array — which is the whole reason that redundant-looking array of ids is
  /// written alongside them.
  Stream<List<OfficeOrder>> watchForStudent(String collegeId, String uid) =>
      _col(
        collegeId,
      ).where('studentUids', arrayContains: uid).snapshots().map((s) {
        final list = s.docs
            .map((d) => OfficeOrder.fromMap(d.id, d.data()))
            .toList();
        list.sort((a, b) {
          final at = a.orderDate, bt = b.orderDate;
          if (at == null && bt == null) return 0;
          if (at == null) return 1;
          if (bt == null) return -1;
          return bt.compareTo(at);
        });
        return list;
      });

  // ------------------------------ writes -----------------------------

  Future<void> delete({
    required String collegeId,
    required String orderId,
  }) => _col(collegeId).doc(orderId).delete();
}
