import 'package:cloud_firestore/cloud_firestore.dart';

/// One student's record for one academic session.
///
/// Doc id is always `{uid}_{session}` — deterministic, so writing it twice
/// (a re-run after a crash, an accidental double-click) overwrites the same
/// document instead of duplicating it. That determinism is what makes
/// backfill and promotion safe to re-run: there is no "did this already
/// happen?" check to get wrong, because running it twice IS safe.
///
/// `year` is stored here, per session — never on the student profile itself.
/// A student's Year 2 belongs to the 2026-27 session; asking "what year is
/// this student in" only makes sense once you also say "...in which
/// session", which is exactly what reading `enrollments/{uid}_{session}`
/// does and a `year` field on the profile never could.
///
/// Room/hostel are duplicated here rather than looked up from the room
/// document for the same reason `AppUser` denormalises them today: a
/// dashboard listing a session's students needs the room number without a
/// second read per row. They are also *history* — overwriting them on the
/// student profile every July would destroy which room someone held in a
/// past session, which a warden eventually needs for damage disputes and
/// deposit refunds.
class Enrollment {
  final String id;
  final String uid;
  final String session;
  final String collegeId;
  final int year;
  final int? sem;

  final String? hostelId;
  final String? hostelName;
  final String? roomId;
  final String? roomNumber;
  final DateTime? allottedAt;

  /// The capacity of the room actually held, if any — denormalised from the
  /// room document whenever [AllotmentService] allots/vacates one, or copied
  /// forward by promotion when a Single room is kept. Distinct from
  /// [requiredCapacity]: this is what the student *has*, that is what they're
  /// *entitled to*. They usually match, but won't for a student who hasn't
  /// been (re-)allotted yet this session.
  final int? roomCapacity;

  /// The room capacity (1 = Single, N = shared) this student is entitled to
  /// this session, per `requiredRoomCapacity` in enrollment_helpers.dart —
  /// snapshotted at backfill/promotion time so the allotment screen can show
  /// it without recomputing the policy live. Null means the policy doesn't
  /// cover this student's course, so nothing is enforced for them.
  final int? requiredCapacity;

  // --- denormalised, so a session's roster renders without a join ---
  final String name;
  final String? course;
  final String? trade;
  final String? batch;
  final String? enrollmentNo;
  final String? gender;

  final DateTime? createdAt;

  const Enrollment({
    required this.id,
    required this.uid,
    required this.session,
    required this.collegeId,
    required this.year,
    this.sem,
    this.hostelId,
    this.hostelName,
    this.roomId,
    this.roomNumber,
    this.allottedAt,
    this.roomCapacity,
    this.requiredCapacity,
    required this.name,
    this.course,
    this.trade,
    this.batch,
    this.enrollmentNo,
    this.gender,
    this.createdAt,
  });

  /// The doc id both sides of every read/write must agree on. A helper
  /// rather than string interpolation at each call site, so the separator
  /// only needs to change in one place if it ever does.
  static String idFor(String uid, String session) => '${uid}_$session';

  factory Enrollment.fromMap(String id, Map<String, dynamic> m) => Enrollment(
    id: id,
    uid: m['uid'] as String? ?? '',
    session: m['session'] as String? ?? '',
    collegeId: m['collegeId'] as String? ?? '',
    year: (m['year'] as num?)?.toInt() ?? 1,
    sem: (m['sem'] as num?)?.toInt(),
    hostelId: m['hostelId'] as String?,
    hostelName: m['hostelName'] as String?,
    roomId: m['roomId'] as String?,
    roomNumber: m['roomNumber'] as String?,
    allottedAt: (m['allottedAt'] as Timestamp?)?.toDate(),
    roomCapacity: (m['roomCapacity'] as num?)?.toInt(),
    requiredCapacity: (m['requiredCapacity'] as num?)?.toInt(),
    name: m['name'] as String? ?? 'Unnamed',
    course: m['course'] as String?,
    trade: m['trade'] as String?,
    batch: m['batch'] as String?,
    enrollmentNo: m['enrollmentNo'] as String?,
    gender: m['gender'] as String?,
    createdAt: (m['createdAt'] as Timestamp?)?.toDate(),
  );

  Map<String, dynamic> toMap() => {
    'uid': uid,
    'session': session,
    'collegeId': collegeId,
    'year': year,
    'sem': sem,
    'hostelId': hostelId,
    'hostelName': hostelName,
    'roomId': roomId,
    'roomNumber': roomNumber,
    'roomCapacity': roomCapacity,
    'requiredCapacity': requiredCapacity,
    'name': name,
    'course': course,
    'trade': trade,
    'batch': batch,
    'enrollmentNo': enrollmentNo,
    'gender': gender,
  };

  bool get isAllotted => roomId != null && hostelId != null;

  /// True when the room actually held doesn't match the seating policy —
  /// either not allotted yet, or allotted to the wrong capacity. Null when
  /// [requiredCapacity] is null, meaning the policy has no opinion.
  bool? get needsReallotment =>
      requiredCapacity == null ? null : roomCapacity != requiredCapacity;
}
