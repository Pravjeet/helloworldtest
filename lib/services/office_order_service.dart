import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/office_order.dart';
import 'stream_cache.dart';

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

  final CachedStreamPool<List<OfficeOrder>> _allPool = CachedStreamPool();
  final CachedStreamPool<List<OfficeOrder>> _minePool = CachedStreamPool();

  /// Ordered by the date printed on the order, newest first — not by upload
  /// time, since a backlog of old orders is usually entered all at once.
  ///
  /// Pooling matters more here than anywhere else in the app: the scanned
  /// photo is base64 *inside* each order document, so re-reading this query is
  /// not just N reads but tens of megabytes. Unpooled it sat in `build()` on
  /// the register page, paying that on every rebuild — a filter change, a
  /// keystroke. See [CachedStream].
  Stream<List<OfficeOrder>> watchAll(String collegeId) => _allPool.stream(
    collegeId,
    () => _col(collegeId)
        .orderBy('orderDate', descending: true)
        .snapshots()
        .map(
          (s) =>
              s.docs.map((d) => OfficeOrder.fromMap(d.id, d.data())).toList(),
        ),
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
      _minePool.stream('$collegeId/$uid', () {
        return _col(collegeId)
            .where('studentUids', arrayContains: uid)
            .snapshots()
            .map((s) {
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
      });

  /// One order by id, read once and remembered — for a fine's detail screen,
  /// which needs just its own order and not the whole register.
  ///
  /// Safe to memoise because orders are never edited, only deleted (and
  /// [delete] forgets it). Bounded tightly: each carries its scanned photo,
  /// so a single entry can be most of a megabyte.
  Future<OfficeOrder?> fetch(String collegeId, String orderId) {
    final key = '$collegeId/$orderId';
    final hit = _byId[key];
    if (hit != null) return hit;
    if (_byId.length >= 15) _byId.clear();
    final future = _col(collegeId)
        .doc(orderId)
        .get()
        .then((d) => d.exists ? OfficeOrder.fromMap(d.id, d.data()!) : null);
    _byId[key] = future;
    // A failed read (offline, refused) must not stick for the session.
    future.catchError((_) {
      _byId.remove(key);
      return null;
    });
    return future;
  }

  final Map<String, Future<OfficeOrder?>> _byId = {};

  /// Called on sign-out alongside [StreamCaches.disposeAll].
  void clearCache() => _byId.clear();

  // ------------------------------ writes -----------------------------

  Future<void> delete({
    required String collegeId,
    required String orderId,
  }) async {
    await _col(collegeId).doc(orderId).delete();
    _byId.remove('$collegeId/$orderId');
  }
}
