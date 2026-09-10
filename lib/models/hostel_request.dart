import 'package:cloud_firestore/cloud_firestore.dart';

/// A request raised by a resident: leave, a complaint, a room change, or
/// something that fits none of those.
///
/// Leave and complaints are deliberately different workflows sharing one
/// collection. Leave is *decided* — approved or rejected. A complaint is
/// *worked* — acknowledged, then fixed. Forcing a leaking tap through an
/// "approve/reject" gate would be nonsense, so [RequestStatus] covers both
/// and [RequestType.isDecision] says which set applies.

enum RequestType { leave, complaint, roomChange, other }

extension RequestTypeX on RequestType {
  static RequestType parse(String? raw) => switch (raw) {
    'leave' => RequestType.leave,
    'complaint' => RequestType.complaint,
    'roomChange' => RequestType.roomChange,
    _ => RequestType.other,
  };

  String get label => switch (this) {
    RequestType.leave => 'Leave',
    RequestType.complaint => 'Complaint',
    RequestType.roomChange => 'Room change',
    RequestType.other => 'Other',
  };

  /// True when this type ends in a yes/no decision rather than being worked
  /// through to a resolution.
  bool get isDecision =>
      this == RequestType.leave || this == RequestType.roomChange;

  /// Statuses this type can legitimately move to from [RequestStatus.pending].
  List<RequestStatus> get nextStates => isDecision
      ? const [RequestStatus.approved, RequestStatus.rejected]
      : const [RequestStatus.inProgress, RequestStatus.resolved];
}

enum RequestStatus { pending, approved, rejected, inProgress, resolved }

extension RequestStatusX on RequestStatus {
  static RequestStatus parse(String? raw) => switch (raw) {
    'approved' => RequestStatus.approved,
    'rejected' => RequestStatus.rejected,
    'inProgress' => RequestStatus.inProgress,
    'resolved' => RequestStatus.resolved,
    _ => RequestStatus.pending,
  };

  String get label => switch (this) {
    RequestStatus.pending => 'Pending',
    RequestStatus.approved => 'Approved',
    RequestStatus.rejected => 'Rejected',
    RequestStatus.inProgress => 'In progress',
    RequestStatus.resolved => 'Resolved',
  };

  /// Still needs someone to act on it.
  bool get isOpen =>
      this == RequestStatus.pending || this == RequestStatus.inProgress;
}

/// Complaint categories. Kept as plain strings so you can add one without a
/// migration.
const List<String> kComplaintCategories = [
  'Electrical',
  'Plumbing',
  'WiFi / Internet',
  'Furniture',
  'Cleanliness',
  'Mess / Food',
  'Security',
  'Other',
];

class HostelRequest {
  final String id;
  final RequestType type;
  final RequestStatus status;

  /// Who raised it. Name and room are denormalised so the staff queue renders
  /// without an extra read per row.
  final String raisedByUid;
  final String raisedByName;
  final String? raisedByRegNo;
  final String? hostelName;
  final String? roomNumber;

  final String subject;
  final String details;

  /// Leave only.
  final DateTime? fromDate;
  final DateTime? toDate;
  final String? destination;

  /// Complaint only.
  final String? category;

  /// Set when someone acts on it.
  final String? handledByUid;
  final String? handledByName;
  final String? decisionNote;
  final DateTime? handledAt;

  final DateTime? createdAt;

  const HostelRequest({
    required this.id,
    required this.type,
    required this.status,
    required this.raisedByUid,
    required this.raisedByName,
    this.raisedByRegNo,
    this.hostelName,
    this.roomNumber,
    required this.subject,
    this.details = '',
    this.fromDate,
    this.toDate,
    this.destination,
    this.category,
    this.handledByUid,
    this.handledByName,
    this.decisionNote,
    this.handledAt,
    this.createdAt,
  });

  factory HostelRequest.fromMap(String id, Map<String, dynamic> m) =>
      HostelRequest(
        id: id,
        type: RequestTypeX.parse(m['type'] as String?),
        status: RequestStatusX.parse(m['status'] as String?),
        raisedByUid: m['raisedByUid'] as String? ?? '',
        raisedByName: m['raisedByName'] as String? ?? 'Unknown',
        raisedByRegNo: m['raisedByRegNo'] as String?,
        hostelName: m['hostelName'] as String?,
        roomNumber: m['roomNumber'] as String?,
        subject: m['subject'] as String? ?? '',
        details: m['details'] as String? ?? '',
        fromDate: (m['fromDate'] as Timestamp?)?.toDate(),
        toDate: (m['toDate'] as Timestamp?)?.toDate(),
        destination: m['destination'] as String?,
        category: m['category'] as String?,
        handledByUid: m['handledByUid'] as String?,
        handledByName: m['handledByName'] as String?,
        decisionNote: m['decisionNote'] as String?,
        handledAt: (m['handledAt'] as Timestamp?)?.toDate(),
        createdAt: (m['createdAt'] as Timestamp?)?.toDate(),
      );

  Map<String, dynamic> toMap() => {
    'type': type.name,
    'status': status.name,
    'raisedByUid': raisedByUid,
    'raisedByName': raisedByName,
    'raisedByRegNo': raisedByRegNo,
    'hostelName': hostelName,
    'roomNumber': roomNumber,
    'subject': subject,
    'details': details,
    'fromDate': fromDate == null ? null : Timestamp.fromDate(fromDate!),
    'toDate': toDate == null ? null : Timestamp.fromDate(toDate!),
    'destination': destination,
    'category': category,
  };

  /// "Block A · Room 101", or null when the person has no room.
  String? get whereFrom => (hostelName == null || roomNumber == null)
      ? null
      : '$hostelName · Room $roomNumber';

  /// Inclusive day count for a leave request.
  int? get leaveDays => (fromDate == null || toDate == null)
      ? null
      : toDate!.difference(fromDate!).inDays + 1;
}
