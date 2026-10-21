import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/app_user.dart';
import '../models/college_settings.dart';
import '../models/enrollment.dart';
import '../utils/enrollment_helpers.dart';
import 'allotment_service.dart';
import 'audit_service.dart';
import 'stream_cache.dart';

/// Firestore access for `colleges/{collegeId}/enrollments`.
///
/// Every write here is a `.set()` on the deterministic `{uid}_{session}` id
/// (see [Enrollment.idFor]) — never `.add()`, never an update that assumes
/// the document already exists. That is what makes backfill and promotion
/// safe to re-run: a crash halfway through 2,600 students is recovered from
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

  /// Shared the same way `DataService.watchUsers` is — Academic Records and
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
              (s) =>
                  s.docs.map((d) => Enrollment.fromMap(d.id, d.data())).toList()
                    ..sort(
                      (a, b) =>
                          a.name.toLowerCase().compareTo(b.name.toLowerCase()),
                    ),
            ),
      );

  /// The whole roster for one session, once — the one-shot counterpart to
  /// [watchRoster], for callers that need the data and then finish.
  ///
  /// [promoteAll] uses this instead of a `get()` per student: one query for
  /// 2,600 students costs the same billed reads as 2,600 individual reads, but
  /// it is *one* network round-trip rather than 2,600 sequential ones, which
  /// is the difference between a promotion run taking seconds and taking
  /// minutes.
  Future<List<Enrollment>> rosterOnce(String collegeId, String session) async {
    final snap = await _enrollments(
      collegeId,
    ).where('session', isEqualTo: session).get();
    return snap.docs.map((d) => Enrollment.fromMap(d.id, d.data())).toList();
  }

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
    final capacity = snap.exists
        ? (snap.data()?['capacity'] as num?)?.toInt()
        : null;
    cache[key] = capacity;
    return capacity;
  }

  /// Which past sessions actually have enrollment data, newest first,
  /// [currentSession] always included even if it is still empty.
  ///
  /// Firestore has no "distinct values" query, so this walks backward one
  /// session at a time from [currentSession], each step a single cheap
  /// existence check (`limit(1)`) rather than a full read of that session's
  /// roster. It stops once it has seen [maxGap] consecutive sessions with
  /// nothing in them — tolerating one skipped or renamed session without
  /// walking through the workspace's entire history — or after [maxSteps]
  /// regardless, as a hard backstop.
  ///
  /// Cheap by construction: a five-year-old workspace costs on the order of
  /// five to seven reads, once, not one read per year of history.
  Future<List<String>> sessionsWithData(
    String collegeId,
    String? currentSession, {
    int maxGap = 2,
    int maxSteps = 20,
  }) async {
    if (currentSession == null) return const [];

    final found = <String>[currentSession];
    var probe = previousSessionBefore(currentSession);
    var gap = 0;
    var steps = 0;

    while (probe != null && gap < maxGap && steps < maxSteps) {
      steps++;
      final snap = await _enrollments(
        collegeId,
      ).where('session', isEqualTo: probe).limit(1).get();
      if (snap.docs.isNotEmpty) {
        found.add(probe);
        gap = 0;
      } else {
        gap++;
      }
      probe = previousSessionBefore(probe);
    }
    return found;
  }

  // ----------------------------- deletion ------------------------------

  /// Deletes every enrollment in the college, across all sessions.
  ///
  /// Part of the master student-data reset. The roster pages read this
  /// collection, not `users`, so clearing the profiles alone left Academic
  /// Records and Student Overview reporting thousands of students who no
  /// longer existed — and the next backfill simply added to them.
  ///
  /// Paged for the same reason as `FeeService.deleteAll`. Super Admin only;
  /// the rules refuse this to everyone else.
  Future<int> deleteAll(String collegeId) async {
    final col = _enrollments(collegeId);
    var removed = 0;
    while (true) {
      final snap = await col.limit(400).get();
      if (snap.docs.isEmpty) break;
      final batch = _db.batch();
      for (final d in snap.docs) {
        batch.delete(d.reference);
      }
      await batch.commit();
      removed += snap.docs.length;
      if (snap.docs.length < 400) break;
    }
    return removed;
  }

  /// Removes enrollments whose student is no longer in [liveUids] — the
  /// cleanup for a roster that was cleared before [deleteAll] existed.
  Future<int> deleteOrphaned(String collegeId, Set<String> liveUids) async {
    final snap = await _enrollments(collegeId).get();
    final orphaned = snap.docs.where((d) {
      final uid = d.data()['uid'] as String?;
      return uid == null || uid.isEmpty || !liveUids.contains(uid);
    }).toList();

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
    required CollegeSettings settings,
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
        rule: settings.courseRuleFor(user.course),
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

  /// Backfills every student in [users] for [session]. Skips students whose
  /// batch won't parse and reports them, rather than guessing — the office
  /// corrects the profile and re-runs.
  ///
  /// Re-running after a partial failure is safe: students who already have
  /// the document are re-derived from the same profile fields and written
  /// again, which produces the identical document.
  Future<BackfillOutcome> backfillAll({
    required List<AppUser> users,
    required String collegeId,
    required String session,
    required CollegeSettings settings,
    required AppUser actor,
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
            rule: settings.courseRuleFor(user.course),
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

    await AuditService.instance.record(
      collegeId: collegeId,
      actor: actor,
      action: 'academic.backfill',
      summary:
          'Backfilled $created enrollment(s) for $session'
          '${unresolved.isEmpty ? '' : ' (${unresolved.length} unresolved)'}',
      targetLabel: session,
      reversible: false,
    );

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
    final plan = _planFor(
      user: user,
      previous: await get(collegeId, user.uid, fromSession),
      collegeId: collegeId,
      fromSession: fromSession,
      toSession: toSession,
      settings: settings,
    );

    if (!plan.writes) return plan.result;
    if (plan.vacates) await _vacateQuietly(collegeId, user);

    if (plan.graduates) {
      await _db
          .collection('users')
          .doc(user.uid)
          .update(_graduationFieldsFor(user));
    } else {
      await _enrollments(collegeId).doc(plan.next!.id).set({
        ...plan.next!.toMap(),
        'createdAt': FieldValue.serverTimestamp(),
      });
    }
    return plan.result;
  }

  /// A graduate leaves the hostel with the degree. A student holding a room is
  /// handed it back by the vacate that runs before this, which clears every
  /// field below; someone recorded against a hostel with *no* room is not
  /// "allotted", so nothing vacates them, and their hostel would otherwise
  /// stay on the profile and keep counting toward that hostel's head-count.
  static Map<String, dynamic> _graduationFieldsFor(AppUser user) => {
    'status': 'graduated',
    if (!user.isAllotted && user.hostelId != null) ...{
      'hostelId': null,
      'hostelName': null,
    },
    'updatedAt': FieldValue.serverTimestamp(),
  };

  /// Best-effort by design: a stale room reference must never block a year
  /// advancing, or block graduating someone whose degree is otherwise done.
  Future<void> _vacateQuietly(String collegeId, AppUser user) async {
    try {
      await AllotmentService.instance.vacate(
        collegeId: collegeId,
        student: user,
      );
    } catch (_) {}
  }

  /// Everything promotion decides for one student, worked out with no I/O.
  ///
  /// Extracted so [promoteOne] and [promoteAll] cannot drift apart. The
  /// batched path has to reach exactly the same verdict as the single-student
  /// one — same graduation cut-off, same room reset, same off-track flag — and
  /// the only way to guarantee that is for both to ask this one function.
  _PromotionPlan _planFor({
    required AppUser user,
    required Enrollment? previous,
    required String collegeId,
    required String fromSession,
    required String toSession,
    required CollegeSettings settings,
  }) {
    if (previous == null) {
      return _PromotionPlan(
        result: PromotionResult.skipped(
          user,
          'No $fromSession enrollment to promote from.',
        ),
      );
    }

    final newYear = previous.year + 1;
    final totalYears = settings.totalYearsFor(user.course);

    if (hasGraduated(newYear, totalYears)) {
      return _PromotionPlan(
        result: PromotionResult.graduated(user, previous.year),
        graduates: true,
        vacates: user.isAllotted,
      );
    }

    final requiredCapacity = requiredRoomCapacity(
      rule: settings.courseRuleFor(user.course),
      year: newYear,
      singleRoomEligible: user.singleRoomEligible,
    );

    // A Single already held is kept; anything else (a 3-Seater, or no room
    // at all) is reset so the student starts the new session unallotted,
    // ready for a fresh assignment against this year's policy.
    final keepsRoom = previous.roomCapacity == 1;

    // Off-track relative to a fresh batch calculation (e.g. a repeater) is
    // reported, never blocked — see the module doc for why promotion must
    // not consult batch math to decide whether to proceed.
    final batchYear = yearFromBatch(previous.batch, toSession);
    final offTrack = batchYear != null && batchYear != newYear;

    return _PromotionPlan(
      result: PromotionResult.promoted(
        user,
        newYear,
        offTrack: offTrack,
        roomKept: keepsRoom,
        requiredCapacity: requiredCapacity,
      ),
      vacates: !keepsRoom && user.isAllotted,
      next: Enrollment(
        id: Enrollment.idFor(user.uid, toSession),
        uid: user.uid,
        session: toSession,
        collegeId: collegeId,
        year: newYear,
        sem: previous.sem,
        hostelId: keepsRoom ? previous.hostelId : null,
        hostelName: keepsRoom ? previous.hostelName : null,
        roomId: keepsRoom ? previous.roomId : null,
        roomNumber: keepsRoom ? previous.roomNumber : null,
        roomCapacity: keepsRoom ? previous.roomCapacity : null,
        requiredCapacity: requiredCapacity,
        name: user.name,
        course: user.course,
        trade: user.trade,
        batch: previous.batch,
        enrollmentNo: user.enrollmentNo,
        gender: user.gender,
      ),
    );
  }

  /// Promotes every student in [users]. Best-effort per student: one profile
  /// with a missing or unparseable previous enrollment must not stop the
  /// others from advancing.
  ///
  /// **Reads once, writes in batches.** This used to call [promoteOne] in a
  /// loop, which meant two or three sequential network round-trips per
  /// student — a `get()` for the previous enrollment, then the write. Across a
  /// few thousand students that is thousands of round-trips one after another,
  /// and a promotion run took minutes rather than seconds.
  ///
  /// The old comment here claimed the writes could not be bundled because each
  /// promotion may run its own [AllotmentService.vacate] transaction. That is
  /// true of the *vacate*, but not of the enrollment write beside it — and
  /// only the handful of students actually holding a room need one at all, so
  /// it was making every student pay for a constraint that applies to very
  /// few. The vacates still run individually; everything else is batched.
  ///
  /// [previousRoster] lets a caller hand over the `fromSession` records it has
  /// already loaded — Academic Records is streaming exactly that list to
  /// render the page — which drops the read cost of a promotion run to zero.
  /// Omitted, they are fetched in a single query rather than one per student.
  Future<List<PromotionResult>> promoteAll({
    required List<AppUser> users,
    required String collegeId,
    required String fromSession,
    required String toSession,
    required CollegeSettings settings,
    required AppUser actor,
    List<Enrollment>? previousRoster,
  }) async {
    final roster =
        previousRoster ?? await rosterOnce(collegeId, fromSession);
    final previousByUid = {for (final e in roster) e.uid: e};

    // Decided up front, with no I/O, so the writes below are the only thing
    // that touches the network.
    final plans = [
      for (final user in users)
        _planFor(
          user: user,
          previous: previousByUid[user.uid],
          collegeId: collegeId,
          fromSession: fromSession,
          toSession: toSession,
          settings: settings,
        ),
    ];

    final results = [for (final p in plans) p.result];

    // Rooms first, and only for the few who hold one. Each is its own
    // transaction and cannot join a batch.
    for (final plan in plans) {
      if (plan.vacates) await _vacateQuietly(collegeId, plan.result.user);
    }

    // Then everything else, 450 writes at a time. A failed batch marks just
    // its own students skipped — the rest of the run still lands.
    final pending = [
      for (var i = 0; i < plans.length; i++)
        if (plans[i].writes) i,
    ];

    for (var start = 0; start < pending.length; start += _batchLimit) {
      final slice = pending.sublist(
        start,
        (start + _batchLimit).clamp(0, pending.length),
      );
      final batch = _db.batch();
      for (final i in slice) {
        final plan = plans[i];
        if (plan.graduates) {
          batch.update(
            _db.collection('users').doc(plan.result.user.uid),
            _graduationFieldsFor(plan.result.user),
          );
        } else {
          batch.set(_enrollments(collegeId).doc(plan.next!.id), {
            ...plan.next!.toMap(),
            'createdAt': FieldValue.serverTimestamp(),
          });
        }
      }
      try {
        await batch.commit();
      } catch (e) {
        for (final i in slice) {
          results[i] = PromotionResult.skipped(plans[i].result.user, '$e');
        }
      }
    }

    final promoted = results
        .where((r) => r.outcome == PromotionOutcome.promoted)
        .length;
    final graduated = results
        .where((r) => r.outcome == PromotionOutcome.graduated)
        .length;
    await AuditService.instance.record(
      collegeId: collegeId,
      actor: actor,
      action: 'academic.promote',
      summary:
          'Promoted $fromSession to $toSession: $promoted promoted, '
          '$graduated graduated',
      targetLabel: toSession,
      reversible: false,
    );

    return results;
  }
}

/// One student's promotion, decided but not yet written.
///
/// Separating the decision from the writing is what lets [promoteAll] batch:
/// every verdict is reached in memory first, so the network work left over is
/// a handful of room transactions plus a few bulk commits.
class _PromotionPlan {
  final PromotionResult result;

  /// The record to write, or null when this student graduates (graduation is
  /// the *absence* of a next-session record) or is skipped.
  final Enrollment? next;

  final bool graduates;

  /// Whether this student's room has to be handed back — true only when they
  /// actually hold one, so the expensive path stays rare.
  final bool vacates;

  const _PromotionPlan({
    required this.result,
    this.next,
    this.graduates = false,
    this.vacates = false,
  });

  /// A skip writes nothing at all; everything else writes exactly one document.
  bool get writes => result.outcome != PromotionOutcome.skipped;
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
      outcome == PromotionOutcome.promoted &&
      !roomKept &&
      requiredCapacity != null;
}
