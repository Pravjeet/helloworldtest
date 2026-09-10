import 'package:cloud_firestore/cloud_firestore.dart';

/// A month's mess fee for one student — a *status record*, not a payment.
///
/// The app never takes money. It records that someone in the office saw the
/// money arrive, and when. That distinction shapes the whole model: there is
/// no gateway, no transaction id, no reconciliation, and marking something
/// paid is reversible.
///
/// **A missing record means unpaid.** Rows are written only when a student is
/// marked paid, so a new month needs no bulk pre-creation of 300 documents
/// and "unpaid" is never out of date because it was generated in advance.
/// Un-marking a student deletes the row, returning them to the same state as
/// everyone who was never marked.
class FeeRecord {
  /// `{period}_{studentUid}` — deterministic, so the same student can never
  /// end up with two rows for one month.
  final String id;

  final String studentUid;
  final String studentName;
  final String? studentRegNo;
  final String? hostelId;
  final String? hostelName;
  final String? roomNumber;
  final String? trade;
  final String? batch;
  final int? sem;

  /// The month, as `YYYY-MM`. Sorts lexicographically, which is why it isn't
  /// a Timestamp — "2026-08" > "2026-07" as a plain string.
  final String period;

  final num amount;

  /// When the office recorded the money as received. Distinct from
  /// [createdAt], which is when the row was typed in — a clerk entering
  /// July's payments in August needs those to differ.
  final DateTime? paidOn;

  /// Free text: "Cash", "UPI", "DD 4471". Not an enum — every institution
  /// counts these differently and none of them are worth a migration.
  final String? method;

  final String? note;

  final String recordedByUid;
  final String recordedByName;
  final DateTime? createdAt;

  const FeeRecord({
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
    required this.period,
    required this.amount,
    this.paidOn,
    this.method,
    this.note,
    required this.recordedByUid,
    required this.recordedByName,
    this.createdAt,
  });

  factory FeeRecord.fromMap(String id, Map<String, dynamic> m) => FeeRecord(
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
    period: m['period'] as String? ?? '',
    amount: (m['amount'] as num?) ?? 0,
    paidOn: (m['paidOn'] as Timestamp?)?.toDate(),
    method: m['method'] as String?,
    note: m['note'] as String?,
    recordedByUid: m['recordedByUid'] as String? ?? '',
    recordedByName: m['recordedByName'] as String? ?? 'Unknown',
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
    'period': period,
    'amount': amount,
    'paidOn': paidOn == null ? null : Timestamp.fromDate(paidOn!),
    'method': method,
    'note': note,
    'recordedByUid': recordedByUid,
    'recordedByName': recordedByName,
  };

  String? get paidOnLabel => paidOn == null ? null : shortDay(paidOn!);
}

/// Builds the document id, so the service and any tooling agree on it.
String feeDocId(String period, String studentUid) => '${period}_$studentUid';

// =====================================================================
// Periods
// =====================================================================

/// `YYYY-MM` for a date.
String periodOf(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}';

/// "August 2026" from `2026-08`. Returns the input unchanged if it isn't a
/// period, so a malformed value shows itself rather than crashing a list.
String periodLabel(String period) {
  final parts = period.split('-');
  if (parts.length != 2) return period;
  final y = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (y == null || m == null || m < 1 || m > 12) return period;
  return '${_months[m - 1]} $y';
}

/// The last [count] months, newest first, as periods.
List<String> recentPeriods(DateTime from, {int count = 12}) {
  final out = <String>[];
  var y = from.year;
  var m = from.month;
  for (var i = 0; i < count; i++) {
    out.add('$y-${m.toString().padLeft(2, '0')}');
    m--;
    if (m == 0) {
      m = 12;
      y--;
    }
  }
  return out;
}

const _months = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

String shortDay(DateTime d) {
  const short = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${d.day} ${short[d.month - 1]} ${d.year}';
}

// =====================================================================
// Roster
// =====================================================================

/// One student's standing for a month: either a [FeeRecord] exists (paid) or
/// it does not (unpaid). Pairing them here keeps the "no row means unpaid"
/// rule in one place instead of scattered `?? unpaid` checks across the UI.
class FeeStanding {
  final String studentUid;
  final String studentName;
  final String? studentRegNo;
  final String? hostelName;
  final String? roomNumber;
  final FeeRecord? record;

  const FeeStanding({
    required this.studentUid,
    required this.studentName,
    this.studentRegNo,
    this.hostelName,
    this.roomNumber,
    this.record,
  });

  bool get isPaid => record != null;
  DateTime? get paidOn => record?.paidOn;
}

/// Totals for a month, computed once so the tiles and the list agree.
class FeeSummary {
  final List<FeeStanding> standings;
  final num amountEach;

  const FeeSummary({required this.standings, required this.amountEach});

  int get total => standings.length;
  int get paid => standings.where((s) => s.isPaid).length;
  int get unpaid => total - paid;

  /// Uses each record's own amount, not [amountEach] — the rate may have
  /// changed since an old month was collected, and the record is the truth.
  num get collected =>
      standings.where((s) => s.isPaid).fold<num>(0, (a, s) => a + s.record!.amount);

  num get expected => amountEach * total;
  num get pending => (expected - collected).clamp(0, double.infinity);

  double get paidFraction => total == 0 ? 0 : paid / total;
}
