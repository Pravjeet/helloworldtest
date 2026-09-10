import 'package:cloud_firestore/cloud_firestore.dart';

/// A monetary penalty imposed on a resident.
///
/// The student's name, registration number, hostel, room, trade, batch and
/// semester are all *snapshotted* onto the fine at the moment it is imposed,
/// exactly as [HostelRequest] does. Two reasons: the dashboard aggregates
/// thousands of fines without reading a user document per row, and a fine
/// raised against a 3rd-semester BH-02 resident stays attributed to where
/// they were when it happened, even after they move room or progress a year.

enum FineStatus { pending, paid, waived }

extension FineStatusX on FineStatus {
  static FineStatus parse(String? raw) => switch (raw) {
    'paid' => FineStatus.paid,
    'waived' => FineStatus.waived,
    _ => FineStatus.pending,
  };

  String get label => switch (this) {
    FineStatus.pending => 'Unpaid',
    FineStatus.paid => 'Paid',
    FineStatus.waived => 'Waived',
  };

  /// Still owed. A waived fine counts towards the record but not the money.
  bool get isOutstanding => this == FineStatus.pending;
}

const List<String> kFineCategories = [
  'Damage to property',
  'Discipline',
  'Late return',
  'Mess violation',
  'Unauthorised absence',
  'Other',
];

class Fine {
  final String id;

  // --- who it's against (snapshotted at impose time) ---
  final String studentUid;
  final String studentName;
  final String? studentRegNo;
  final String? hostelId;
  final String? hostelName;
  final String? roomNumber;
  final String? trade;
  final String? batch;
  final int? sem;

  /// Home state, so the dashboard can rank where defaulters come from without
  /// reading a user document per fine.
  final String? state;

  final num amount;
  final String category;
  final String reason;
  final FineStatus status;

  /// Office order this fine was issued under.
  ///
  /// [officeOrderId] is the real document reference — every fine imposed
  /// through the current flow gets one, created in the same write. A handful
  /// of fines imposed before that link existed only have [officeOrderNo], the
  /// free-text order number staff typed by hand; kept for display on those.
  final String? officeOrderId;
  final String? officeOrderNo;

  final String imposedByUid;
  final String imposedByName;

  /// Set when marked paid or waived.
  final String? resolvedByUid;
  final String? resolvedByName;
  final DateTime? resolvedAt;

  final DateTime? createdAt;

  const Fine({
    required this.id,
    required this.studentUid,
    required this.studentName,
    this.studentRegNo,
    this.hostelId,
    this.hostelName,
    this.roomNumber,
    this.trade,
    this.batch,
    this.sem,
    this.state,
    required this.amount,
    required this.category,
    this.reason = '',
    this.status = FineStatus.pending,
    this.officeOrderId,
    this.officeOrderNo,
    required this.imposedByUid,
    required this.imposedByName,
    this.resolvedByUid,
    this.resolvedByName,
    this.resolvedAt,
    this.createdAt,
  });

  factory Fine.fromMap(String id, Map<String, dynamic> m) => Fine(
    id: id,
    studentUid: m['studentUid'] as String? ?? '',
    studentName: m['studentName'] as String? ?? 'Unknown',
    studentRegNo: m['studentRegNo'] as String?,
    hostelId: m['hostelId'] as String?,
    hostelName: m['hostelName'] as String?,
    roomNumber: m['roomNumber'] as String?,
    trade: m['trade'] as String?,
    batch: m['batch'] as String?,
    sem: (m['sem'] as num?)?.toInt(),
    state: m['state'] as String?,
    amount: (m['amount'] as num?) ?? 0,
    category: m['category'] as String? ?? 'Other',
    reason: m['reason'] as String? ?? '',
    status: FineStatusX.parse(m['status'] as String?),
    officeOrderId: m['officeOrderId'] as String?,
    officeOrderNo: m['officeOrderNo'] as String?,
    imposedByUid: m['imposedByUid'] as String? ?? '',
    imposedByName: m['imposedByName'] as String? ?? 'Unknown',
    resolvedByUid: m['resolvedByUid'] as String?,
    resolvedByName: m['resolvedByName'] as String?,
    resolvedAt: (m['resolvedAt'] as Timestamp?)?.toDate(),
    createdAt: (m['createdAt'] as Timestamp?)?.toDate(),
  );

  Map<String, dynamic> toMap() => {
    'studentUid': studentUid,
    'studentName': studentName,
    'studentRegNo': studentRegNo,
    'hostelId': hostelId,
    'hostelName': hostelName,
    'roomNumber': roomNumber,
    'trade': trade,
    'batch': batch,
    'sem': sem,
    'state': state,
    'amount': amount,
    'category': category,
    'reason': reason,
    'status': status.name,
    'officeOrderId': officeOrderId,
    'officeOrderNo': officeOrderNo,
    'imposedByUid': imposedByUid,
    'imposedByName': imposedByName,
  };

  /// "BH-02 · Room 101", or null when the student had no room.
  String? get whereFrom => (hostelName == null || roomNumber == null)
      ? null
      : '$hostelName · Room $roomNumber';
}

/// Everything the mini-dashboard needs, worked out in one pass over a list of
/// fines. Kept free of Firestore and Flutter so the arithmetic is testable and
/// so the charts and the stat tiles can never disagree about a total.
class FineSummary {
  final List<Fine> fines;

  const FineSummary(this.fines);

  int get count => fines.length;

  num get total => fines.fold<num>(0, (acc, f) => acc + f.amount);

  /// Money actually still owed — waived and paid fines don't count.
  num get outstanding => fines
      .where((f) => f.status.isOutstanding)
      .fold<num>(0, (acc, f) => acc + f.amount);

  num get collected => fines
      .where((f) => f.status == FineStatus.paid)
      .fold<num>(0, (acc, f) => acc + f.amount);

  /// Total fine amount per bucket, highest first. `null` keys (a student with
  /// no trade recorded, say) collapse into [unknownLabel] rather than being
  /// dropped, so the chart's total always matches the headline figure.
  List<MapEntry<String, num>> sumBy(
    String? Function(Fine) key, {
    String unknownLabel = 'Not set',
    int? limit,
  }) => _rank(key, (f) => f.amount, unknownLabel, limit);

  /// Number of fines per bucket, highest first.
  List<MapEntry<String, num>> countBy(
    String? Function(Fine) key, {
    String unknownLabel = 'Not set',
    int? limit,
  }) => _rank(key, (_) => 1, unknownLabel, limit);

  /// Number of distinct *students* per bucket, highest first.
  ///
  /// This is what "defaulters" means — a student with three fines is one
  /// defaulter, not three. Ranking states by [countBy] instead would let a
  /// single repeat offender outrank a state with five separate students.
  List<MapEntry<String, num>> defaultersBy(
    String? Function(Fine) key, {
    String unknownLabel = 'Not set',
    int? limit,
  }) {
    final buckets = <String, Set<String>>{};
    for (final f in fines) {
      final k = key(f)?.trim();
      final label = (k == null || k.isEmpty) ? unknownLabel : k;
      (buckets[label] ??= <String>{}).add(f.studentUid);
    }
    final entries = buckets.entries
        .map((e) => MapEntry(e.key, e.value.length as num))
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return (limit == null || entries.length <= limit)
        ? entries
        : entries.sublist(0, limit);
  }

  List<MapEntry<String, num>> _rank(
    String? Function(Fine) key,
    num Function(Fine) value,
    String unknownLabel,
    int? limit,
  ) {
    final buckets = <String, num>{};
    for (final f in fines) {
      final k = key(f)?.trim();
      final label = (k == null || k.isEmpty) ? unknownLabel : k;
      buckets[label] = (buckets[label] ?? 0) + value(f);
    }
    final entries = buckets.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return (limit == null || entries.length <= limit)
        ? entries
        : entries.sublist(0, limit);
  }

  /// Distinct values present in the data, for populating a filter dropdown.
  /// Sorted so "1, 3, 5, 7" doesn't come back as "1, 3, 5, 7" in random order.
  List<String> valuesOf(String? Function(Fine) key) {
    final seen = <String>{};
    for (final f in fines) {
      final v = key(f)?.trim();
      if (v != null && v.isNotEmpty) seen.add(v);
    }
    final list = seen.toList()..sort();
    return list;
  }
}
