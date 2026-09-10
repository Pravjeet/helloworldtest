import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/app_user.dart';
import '../models/college_settings.dart';
import '../models/enrollment.dart';
import '../utils/enrollment_helpers.dart';
import 'allotment_service.dart';
import 'stream_cache.dart';

/// Firestore access for `colleges/{collegeId}/enrollments`.
///
/// Every write here is a `.set()` on the deterministic `{uid}_{session}` id
/// (see [Enrollment.idFor]) — never `.add()`, never an update that assumes
/// the document already exists. That is what makes backfill and promotion
/// safe to re-run: a crash halfway through 1,800 students is recovered from
/// by running the same call again, not by writing a recovery script.
class EnrollmentService {
  EnrollmentService._();
  static final EnrollmentService instance = EnrollmentService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  /// Firestore caps a single batch at 500 operations.
  static const int _batchLimit = 450;

  CollectionReference<Map<String, dynamic>> _enrollments(String collegeId) =>
      _db.collection('colleges').doc(collegeId).collection('enrollments');

  // ------------------------------- reads -------------------------------

  Future<Enrollment?> get(String collegeId, String uid, String session) async {
    final snap = await _enrollments(
      collegeId,
    ).doc(Enrollment.idFor(uid, session)).get();
    return snap.exists ? Enrollment.fromMap(snap.id, snap.data()!) : null;
  }

  /// Shared the same way [DataService.watchUsers] is — Academic Records and
  /// Student Overview both watch the same session's roster, and without a
  /// pool that's the whole enrollments collection read twice for the price
  /// of once, plus a re-subscribe every time either page rebuilds.
  final CachedStreamPool<List<Enrollment>> _rosterPool = CachedStreamPool();

  Stream<List<Enrollment>> watchRoster(String collegeId, String session) =>
      _rosterPool.stream(
        '$collegeId/$session',
        () => _enrollments(collegeId)
            .where('session', isEqualTo: session)
            .snapshots()
            .map(
              (s) => s.docs
                  .map((d) => Enrollment.fromMap(d.id, d.data()))
                  .toList()
                ..sort(
                  (a, b) =>
                      a.name.toLowerCase().compareTo(b.name.toLowerCase()),
                ),
            ),
      );

  /// The capacity of `colleges/{collegeId}/hostels/{hostelId}/rooms/{roomId}`,
  /// or null if either id is missing or the room doesn't exist. [cache] lets
  /// a bulk caller (see [backfillAll]) avoid re-reading the same room for
  /// every roommate — a 3-Seater is read once, not three times.
  Future<int?> _roomCapacityOf(
    String collegeId,
    String? hostelId,
    String? roomId,
    Map<String, int?> cache,
  ) async {
    if (hostelId == null || roomId == null) return null;
    final key = '$hostelId/$roomId';
    if (cache.containsKey(key)) return cache[key];
    final snap = await _db
        .collection('colleges')
        .doc(collegeId)
        .collection('hostels')
        .doc(hostelId)
        .collection('rooms')
        .doc(roomId)
        .get();
    final capacity = snap.exists ? (snap.data()?['capacity'] as num?)?.toInt() : null;
    cache[key] = capacity;
    return capacity;
  }

  // ----------------------------- backfill ------------------------------

  /// Derives [uid]'s first enrollment record for [session] from their
  /// current profile fields (`batch`, `course`, `sem`, room). Used both for
  /// the one-time backfill of existing students and for a brand-new
  /// admission — the two are the same operation because both start from
  /// "here is what the profile says right now".
  ///
  /// Room capacity and the seating-policy entitlement are looked up/derived
  /// here too, since this is the first point a student's room is on record
  /// at all — [AllotmentService] has nothing to sync onto yet at this stage.
  ///
  /// Returns null (writes nothing) when `batch` doesn't parse against
  /// [session] — a row that needs a human to fix the batch field rather than
  /// silently getting year 1.
  Future<Enrollment?> backfillOne({
    required AppUser user,
    required String collegeId,
    required String session,
  }) async {
    final year = yearFromBatch(user.batch, session);
    if (year == null) return null;

    final roomCapacity = await _roomCapacityOf(
      collegeId,
      user.hostelId,
      user.roomId,
      {},
    );

    final enrollment = Enrollment(
      id: Enrollment.idFor(user.uid, session),
      uid: user.uid,
      session: session,
      collegeId: collegeId,
      year: year,
      sem: user.sem,
      hostelId: user.hostelId,
      hostelName: user.hostelName,
      roomId: user.roomId,
      roomNumber: user.roomNumber,
      roomCapacity: roomCapacity,
      requiredCapacity: requiredRoomCapacity(
        course: user.course,
        year: year,
        singleRoomEligible: user.singleRoomEligible,
      ),
      name: user.name,
      course: user.course,
      trade: user.trade,
      batch: user.batch,
      enrollmentNo: user.enrollmentNo,
      gender: user.gender,
    );

    await _enrollments(collegeId).doc(enrollment.id).set({
      ...enrollment.toMap(),
      'createdAt': FieldValue.serverTimestamp(),
    });
    return enrollment;
  }

  /// Backfills every student in [users] who doesn't already have a [session]
  /// enrollment. Skips students whose batch won't parse and reports them,
  /// rather than guessing — the office corrects the profile and re-runs.
  ///
  /// Re-running after a partial failure is safe: students who already have
  /// the document are re-derived from the same profile fields and written
  /// again, which produces the identical document.
  Future<BackfillOutcome> backfillAll({
    required List<AppUser> users,
    required String collegeId,
    required String session,
  }) async {
    var created = 0;
    final unresolved = <String>[];

    // Shared across the whole run: a 3-Seater with three roommates in it
    // gets its capacity read once, not once per occupant.
    final roomCapacityCache = <String, int?>{};

    for (var start = 0; start < users.length; start += _batchLimit) {
      final chunk = users.sublist(
        start,
        (start + _batchLimit).clamp(0, users.length),
      );

      // Reads happen outside the write batch — Firestore batches are
      // write-only, and a room's capacity has to be known before the
      // enrollment doc that denormalises it can be built.
      final capacities = <String, int?>{};
      for (final user in chunk) {
        if (user.hostelId == null || user.roomId == null) continue;
        capacities[user.uid] = await _roomCapacityOf(
          collegeId,
          user.hostelId,
          user.roomId,
          roomCapacityCache,
        );
      }

      final batch = _db.batch();
      var chunkWrites = 0;

      for (final user in chunk) {
        final year = yearFromBatch(user.batch, session);
        if (year == null) {
          unresolved.add(
            '${user.name}${user.enrollmentNo == null ? '' : ' (${user.enrollmentNo})'}: '
            'batch "${user.batch ?? ''}" doesn\'t parse against session "$session"',
          );
          continue;
        }
        final enrollment = Enrollment(
          id: Enrollment.idFor(user.uid, session),
          uid: user.uid,
          session: session,
          collegeId: collegeId,
          year: year,
          sem: user.sem,
          hostelId: user.hostelId,
          hostelName: user.hostelName,
          roomId: user.roomId,
          roomNumber: user.roomNumber,
          roomCapacity: capacities[user.uid],
          requiredCapacity: requiredRoomCapacity(
            course: user.course,
            year: year,
            singleRoomEligible: user.singleRoomEligible,
          ),
          name: user.name,
          course: user.course,
          trade: user.trade,
          batch: user.batch,
          enrollmentNo: user.enrollmentNo,
          gender: user.gender,
        );
        batch.set(_enrollments(collegeId).doc(enrollment.id), {
          ...enrollment.toMap(),
          'createdAt': FieldValue.serverTimestamp(),
        });
        chunkWrites++;
      }

      if (chunkWrites > 0) await batch.commit();
      created += chunkWrites;
    }

    return BackfillOutcome(created: created, unresolved: unresolved);
  }

  // ----------------------------- promotion -------------------------------

  /// Advances one student from [fromSession] to [toSession].
  ///
  /// Deliberately reads the *previous enrollment's* year and adds one — never
  /// batch math — because a repeater's year can disagree with what their
  /// batch alone would predict, and promotion must move students from where
  /// they actually are, not recompute where they "should" be.
  ///
  /// Rooms reset every session — students get new rooms each year, per the
  /// college's actual practice — **except** a Single room already earned by
  /// merit, which is kept unchanged until graduation rather than reshuffled.
  /// A student being reset is actually vacated (frees the bed for the next
  /// intake, updates the room's occupant list) via [AllotmentService], not
  /// just cleared on the enrollment record — otherwise the physical room
  /// would stay phantom-occupied by someone whose new-session record shows
  /// no room at all.
  ///
  /// Returns [PromotionResult.graduated] without writing a new enrollment
  /// when the advanced year would exceed the course length — graduating a
  /// student is the *absence* of a next-session record, not a delete of
  /// anything. The student's own profile is marked `status: 'graduated'`,
  /// and their room (if any) is vacated the same as anyone else's, so they
  /// drop out of every session-scoped query and every occupancy count
  /// without a single document being removed.
  Future<PromotionResult> promoteOne({
    required AppUser user,
    required String collegeId,
    required String fromSession,
    required String toSession,
    required CollegeSettings settings,
  }) async {
    final previous = await get(collegeId, user.uid, fromSession);
    if (previous == null) {
      return PromotionResult.skipped(
        user,
        'No $fromSession enrollment to promote from.',
      );
    }

    final newYear = previous.year + 1;
    final totalYears = settings.totalYearsFor(user.course);

    if (hasGraduated(newYear, totalYears)) {
      if (user.isAllotted) {
        try {
          await AllotmentService.instance.vacate(
            collegeId: collegeId,
            student: user,
          );
        } catch (_) {
          // Best-effort — a stale room reference must not block graduating
          // someone whose degree is otherwise done.
        }
      }
      await _db.collection('users').doc(user.uid).update({
        'status': 'graduated',
        'updatedAt': FieldValue.serverTimestamp(),
      });
      return PromotionResult.graduated(user, previous.year);
    }

    final requiredCapacity = requiredRoomCapacity(
      course: user.course,
      year: newYear,
      singleRoomEligible: user.singleRoomEligible,
    );

    // A Single already held is kept; anything else (a 3-Seater, or no room
    // at all) is reset so the student starts the new session unallotted,
    // ready for a fresh assignment against this year's policy.
    final keepsRoom = previous.roomCapacity == 1;

    var hostelId = previous.hostelId;
    var hostelName = previous.hostelName;
    var roomId = previous.roomId;
    var roomNumber = previous.roomNumber;
    var roomCapacity = previous.roomCapacity;

    if (!keepsRoom) {
      if (user.isAllotted) {
        try {
          await AllotmentService.instance.vacate(
            collegeId: collegeId,
            student: user,
          );
        } catch (_) {
          // Best-effort — a stale room must not block the year advancing;
          // the enrollment is still cleared below regardless.
        }
      }
      hostelId = null;
      hostelName = null;
      roomId = null;
      roomNumber = null;
      roomCapacity = null;
    }

    // Off-track relative to a fresh batch calculation (e.g. a repeater) is
    // reported, never blocked — see the module doc for why promotion must
    // not consult batch math to decide whether to proceed.
    final batchYear = yearFromBatch(previous.batch, toSession);
    final offTrack = batchYear != null && batchYear != newYear;

    final next = Enrollment(
      id: Enrollment.idFor(user.uid, toSession),
      uid: user.uid,
      session: toSession,
      collegeId: collegeId,
      year: newYear,
      sem: previous.sem,
      hostelId: hostelId,
      hostelName: hostelName,
      roomId: roomId,
      roomNumber: roomNumber,
      roomCapacity: roomCapacity,
      requiredCapacity: requiredCapacity,
      name: user.name,
      course: user.course,
      trade: user.trade,
      batch: previous.batch,
      enrollmentNo: user.enrollmentNo,
      gender: user.gender,
    );

    await _enrollments(collegeId).doc(next.id).set({
      ...next.toMap(),
      'createdAt': FieldValue.serverTimestamp(),
    });

    return PromotionResult.promoted(
      user,
      newYear,
      offTrack: offTrack,
      roomKept: keepsRoom,
      requiredCapacity: requiredCapacity,
    );
  }

  /// Promotes every student in [users], chunking writes to stay under
  /// Firestore's batch limit. Best-effort per student: one profile with a
  /// missing or unparseable previous enrollment must not stop the other
  /// 1,799 from advancing.
  Future<List<PromotionResult>> promoteAll({
    required List<AppUser> users,
    required String collegeId,
    required String fromSession,
    required String toSession,
    required CollegeSettings settings,
  }) async {
    final results = <PromotionResult>[];
    for (final user in users) {
      try {
        results.add(
          await promoteOne(
            user: user,
            collegeId: collegeId,
            fromSession: fromSession,
            toSession: toSession,
            settings: settings,
          ),
        );
      } catch (e) {
        results.add(PromotionResult.skipped(user, e.toString()));
      }
    }
    return results;
  }
}

class BackfillOutcome {
  final int created;
  final List<String> unresolved;
  const BackfillOutcome({required this.created, required this.unresolved});
}

enum PromotionOutcome { promoted, graduated, skipped }

class PromotionResult {
  final AppUser user;
  final PromotionOutcome outcome;
  final int? year;
  final bool offTrack;

  /// True when a Single room was carried forward unchanged rather than
  /// reset. Only meaningful for [PromotionOutcome.promoted].
  final bool roomKept;

  /// The room capacity this student is entitled to this session, if the
  /// seating policy covers their course. Null means no reallotment guidance
  /// applies — not that they need nothing.
  final int? requiredCapacity;

  final String? note;

  const PromotionResult._(
    this.user,
    this.outcome, {
    this.year,
    this.offTrack = false,
    this.roomKept = false,
    this.requiredCapacity,
    this.note,
  });

  factory PromotionResult.promoted(
    AppUser user,
    int year, {
    bool offTrack = false,
    bool roomKept = false,
    int? requiredCapacity,
  }) => PromotionResult._(
    user,
    PromotionOutcome.promoted,
    year: year,
    offTrack: offTrack,
    roomKept: roomKept,
    requiredCapacity: requiredCapacity,
  );

  factory PromotionResult.graduated(AppUser user, int finalYear) =>
      PromotionResult._(user, PromotionOutcome.graduated, year: finalYear);

  factory PromotionResult.skipped(AppUser user, String note) =>
      PromotionResult._(user, PromotionOutcome.skipped, note: note);

  /// True when this student needs a room this session and doesn't have one
  /// of the right type yet — the case the allotment screen should surface.
  bool get needsRoom =>
      outcome == PromotionOutcome.promoted && !roomKept && requiredCapacity != null;
}
