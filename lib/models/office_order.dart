import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';

/// One student named on an office order.
///
/// Carries the student's own fine id rather than the order holding a single
/// one, because a group order raises a separate fine per student — five
/// students on a ₹1000 order owe ₹1000 each, and each has to be settleable and
/// countable on its own.
class OrderStudent {
  final String uid;
  final String name;
  final String? regNo;

  /// The fine raised for this student under this order. Null when this
  /// particular student was not fined — which is a normal outcome, not an
  /// error: one order can fine three students heavily, a fourth lightly, and
  /// let a fifth off with a warning.
  final String? fineId;

  /// What this student was fined, in rupees. Null when they were not.
  ///
  /// Stored on the student rather than the order because it genuinely differs
  /// per person — the ringleader and the bystander do not pay the same. The
  /// order keeps only the shared facts: the category, and the total.
  final num? fineAmount;

  const OrderStudent({
    required this.uid,
    required this.name,
    this.regNo,
    this.fineId,
    this.fineAmount,
  });

  factory OrderStudent.fromMap(Map<String, dynamic> m) => OrderStudent(
    uid: m['uid'] as String? ?? '',
    name: m['name'] as String? ?? 'Unknown',
    regNo: m['regNo'] as String?,
    fineId: m['fineId'] as String?,
    fineAmount: m['fineAmount'] as num?,
  );

  Map<String, dynamic> toMap() => {
    'uid': uid,
    'name': name,
    'regNo': regNo,
    'fineId': fineId,
    'fineAmount': fineAmount,
  };

  /// True when this student actually owes something under this order.
  bool get isFined => fineId != null && (fineAmount ?? 0) > 0;
}

/// An office order issued by the institute.
///
/// There is no Firebase Storage on the free Spark plan, so the scanned copy
/// is not a file at all — it's a small photo, base64-encoded directly into
/// the document ([imageBase64]). That only works because it's a photo (a few
/// hundred KB) rather than a multi-page PDF; a Firestore document tops out
/// at ~1 MB. Older orders were published as an external link instead
/// ([pdfUrl]) and still open that way.
class OfficeOrder {
  final String id;

  /// The order's own reference number, as printed on it. This is what people
  /// actually search by, so it is stored verbatim *and* normalised.
  final String orderNo;

  final String title;
  final String? description;

  /// Date printed on the order, which is not the date it was uploaded here.
  final DateTime? orderDate;

  /// Legacy field: a link to where the order already lives (institute site,
  /// Drive share). Null for orders published with an inline photo instead.
  final String? pdfUrl;

  /// Base64-encoded photo of the order. Null for legacy link-based orders.
  final String? imageBase64;

  /// MIME type of [imageBase64], e.g. `image/jpeg`.
  final String? imageMimeType;

  final String postedByUid;
  final String postedByName;
  final DateTime? createdAt;

  // --- who this order is against ---
  //
  // An order covers one *or more* students: a single incident involving five
  // students is one order, not five. Denormalised (name and registration
  // number, not bare ids) so the register and a student's detail page render
  // without a second read.
  //
  // Empty only for orders published before orders were linked to students at
  // all.
  final List<OrderStudent> students;

  /// Everything this order levied, added up across its students.
  ///
  /// Null or zero for an order that carries no money — a warning, a
  /// suspension, a notice of enquiry.
  ///
  /// Denormalised rather than summed from [students] on demand for one
  /// specific reason: the security rules cannot look inside an array, so this
  /// flat number is what lets them tell "this order levies money, require
  /// fines.manage" from "this is a warning". It is also what the register
  /// shows without walking every entry.
  final num? fineTotal;

  /// The shared reason. Amounts differ per student; the category does not —
  /// one incident is one category.
  final String? fineCategory;

  const OfficeOrder({
    required this.id,
    required this.orderNo,
    required this.title,
    this.description,
    this.orderDate,
    this.pdfUrl,
    this.imageBase64,
    this.imageMimeType,
    required this.postedByUid,
    required this.postedByName,
    this.createdAt,
    this.students = const [],
    this.fineTotal,
    this.fineCategory,
  });

  factory OfficeOrder.fromMap(String id, Map<String, dynamic> m) => OfficeOrder(
    id: id,
    orderNo: m['orderNo'] as String? ?? '',
    title: m['title'] as String? ?? '',
    description: m['description'] as String?,
    orderDate: (m['orderDate'] as Timestamp?)?.toDate(),
    pdfUrl: m['pdfUrl'] as String?,
    imageBase64: m['imageBase64'] as String?,
    imageMimeType: m['imageMimeType'] as String?,
    postedByUid: m['postedByUid'] as String? ?? '',
    postedByName: m['postedByName'] as String? ?? 'Unknown',
    createdAt: (m['createdAt'] as Timestamp?)?.toDate(),
    students: _readStudents(m),
    fineTotal: _readTotal(m),
    fineCategory: m['fineCategory'] as String?,
  );

  /// Reads the covered students, accepting both shapes.
  ///
  /// Before an order could cover a group, one was described by flat
  /// `studentUid` / `studentName` / `studentRegNo` / `fineId` fields. No such
  /// document exists in this project — the collection was empty when the shape
  /// changed, which is why there is no migration script. The fallback is kept
  /// only so restoring an old backup reads correctly instead of showing orders
  /// with nobody named on them.
  static List<OrderStudent> _readStudents(Map<String, dynamic> m) {
    final raw = m['students'] as List?;
    if (raw != null) {
      return raw
          .whereType<Map>()
          .map((e) => OrderStudent.fromMap(e.cast<String, dynamic>()))
          .where((s) => s.uid.isNotEmpty)
          .toList();
    }

    final legacyUid = m['studentUid'] as String?;
    if (legacyUid == null || legacyUid.isEmpty) return const [];
    return [
      OrderStudent(
        uid: legacyUid,
        name: m['studentName'] as String? ?? 'Unknown',
        regNo: m['studentRegNo'] as String?,
        fineId: m['fineId'] as String?,
        // The order-level amount was that one student's amount.
        fineAmount: m['fineAmount'] as num?,
      ),
    ];
  }

  Map<String, dynamic> toMap() => {
    'orderNo': orderNo,
    'title': title,
    'description': description,
    'orderDate': orderDate == null ? null : Timestamp.fromDate(orderDate!),
    'pdfUrl': pdfUrl,
    'imageBase64': imageBase64,
    'imageMimeType': imageMimeType,
    'postedByUid': postedByUid,
    'postedByName': postedByName,
    'students': students.map((s) => s.toMap()).toList(),
    // A flat array of uids purely so "orders against this student" can be a
    // query. Firestore's array-contains cannot reach into `students[].uid`, so
    // the ids have to exist as a top-level array of their own.
    'studentUids': students.map((s) => s.uid).toList(),
    'fineTotal': fineTotal,
    'fineCategory': fineCategory,
  };

  /// Reads the total, accepting the shape that stored one amount for everyone.
  ///
  /// An order written while every student paid the same carried `fineAmount`
  /// meaning "each". Multiplying it back out by the number of students
  /// recovers the same total those orders always represented.
  static num? _readTotal(Map<String, dynamic> m) {
    final total = m['fineTotal'] as num?;
    if (total != null) return total;

    final each = m['fineAmount'] as num?;
    if (each == null) return null;
    final n = (m['students'] as List?)?.length ?? 1;
    return each * n;
  }

  /// True when this order actually imposed money on anyone.
  ///
  /// False for a warning or suspension, and for the legacy orders published
  /// before orders were linked to students at all.
  bool get hasFine => students.any((s) => s.isFined);

  /// Those actually fined under this order — not necessarily everyone it names.
  List<OrderStudent> get finedStudents =>
      students.where((s) => s.isFined).toList();

  /// True when the order names people who were not fined alongside people who
  /// were. Worth surfacing, because "5 students, 3 fined" is the interesting
  /// shape and a single figure hides it.
  bool get hasUnfinedStudents =>
      students.isNotEmpty && students.any((s) => !s.isFined);

  /// "₹1000", or "₹500–₹2000" when the students paid different amounts.
  String? get fineRangeLabel {
    final amounts = finedStudents.map((s) => s.fineAmount!).toList()..sort();
    if (amounts.isEmpty) return null;
    if (amounts.first == amounts.last) return '₹${amounts.first}';
    return '₹${amounts.first}–₹${amounts.last}';
  }

  /// True when one order covers several students — a group incident.
  bool get isGroup => students.length > 1;

  /// "Ravi Kumar", or "Ravi Kumar and 4 others". Empty when unlinked.
  String get studentLabel {
    if (students.isEmpty) return '';
    if (students.length == 1) return students.first.name;
    return '${students.first.name} and ${students.length - 1} '
        'other${students.length == 2 ? '' : 's'}';
  }

  /// True when this order is against [uid].
  bool covers(String uid) => students.any((s) => s.uid == uid);

  /// What [uid] was fined under this order, or null if they were named but not
  /// fined — or not named at all.
  ///
  /// This is the figure to show a student. The order's [fineTotal] is everyone
  /// else's money as well as theirs, and on a group order that is a very
  /// different number from what they personally owe.
  num? amountFor(String uid) {
    for (final s in students) {
      if (s.uid == uid) return s.isFined ? s.fineAmount : null;
    }
    return null;
  }

  bool get hasImage => imageBase64 != null && imageBase64!.isNotEmpty;

  /// True for the older orders that were published as an external link.
  bool get hasLink => (pdfUrl ?? '').trim().isNotEmpty;

  bool get isPdf => (pdfUrl ?? '').toLowerCase().endsWith('.pdf');

  /// True when this order matches a free-text search of its number or title.
  /// Punctuation is ignored on the number, so "SLIET/HM/2024/17" is found by
  /// typing "hm 2024 17" — nobody remembers the exact slashes.
  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    if (title.toLowerCase().contains(q)) return true;
    if (orderNo.toLowerCase().contains(q)) return true;
    // Any covered student, not just the first — searching a group order by the
    // name of its third student has to find it.
    for (final s in students) {
      if (s.name.toLowerCase().contains(q)) return true;
      if ((s.regNo ?? '').toLowerCase().contains(q)) return true;
    }
    return _loose(orderNo).contains(_loose(q));
  }

  static String _loose(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  /// "17 Mar 2026", or null when no date was recorded.
  String? get dateLabel {
    final d = orderDate;
    if (d == null) return null;
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }

  /// True when [orderDate] falls on the same calendar day as [day].
  bool isOn(DateTime day) {
    final d = orderDate;
    if (d == null) return false;
    return d.year == day.year && d.month == day.month && d.day == day.day;
  }
}

/// Decoded photo bytes, memoised by order id.
///
/// Without this, a register of forty orders re-runs `base64Decode` on a
/// ~700 KB string for every single one on every rebuild — which is enough to
/// make scrolling stutter. The cache is bounded because a long session
/// browsing hundreds of orders would otherwise grow without limit; anything
/// evicted is simply decoded again next time it is shown.
final Map<String, Uint8List> _decodedImages = {};

Uint8List? decodedOrderImage(OfficeOrder order) {
  if (!order.hasImage) return null;

  final hit = _decodedImages[order.id];
  if (hit != null) return hit;

  try {
    final bytes = base64Decode(order.imageBase64!);
    if (_decodedImages.length >= 40) _decodedImages.clear();
    _decodedImages[order.id] = bytes;
    return bytes;
  } catch (_) {
    // A corrupt or truncated string shouldn't take the whole register down —
    // the row falls back to its placeholder icon.
    return null;
  }
}
