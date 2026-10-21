import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/app_user.dart';
import '../models/enrollment.dart';
import '../models/hostel.dart';
import '../utils/enrollment_helpers.dart';
import 'audit_service.dart';

/// Moving students in and out of rooms.
///
/// Every operation here runs inside a Firestore **transaction**, not a batch.
/// The difference matters: a batch writes blindly, while a transaction re-reads
/// the room at commit time and aborts if someone else changed it first.
///
/// Without that, two wardens clicking "Allot" on the last free bed at the same
/// moment would both read `1 free`, both write, and you'd end up with three
/// students in a two-seater. With it, the second write is retried against fresh
/// data, sees the room is full, and fails cleanly.
class AllotmentService {
  AllotmentService._();
  static final AllotmentService instance = AllotmentService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  DocumentReference<Map<String, dynamic>> _hostelRef(
    String collegeId,
    String hostelId,
  ) => _db
      .collection('colleges')
      .doc(collegeId)
      .collection('hostels')
      .doc(hostelId);

  DocumentReference<Map<String, dynamic>> _roomRef(
    String collegeId,
    String hostelId,
    String roomId,
  ) => _hostelRef(collegeId, hostelId).collection('rooms').doc(roomId);

  DocumentReference<Map<String, dynamic>> _settingsRef(String collegeId) => _db
      .collection('colleges')
      .doc(collegeId)
      .collection('settings')
      .doc('config');

  DocumentReference<Map<String, dynamic>> _enrollmentRef(
    String collegeId,
    String uid,
    String session,
  ) => _db
      .collection('colleges')
      .doc(collegeId)
      .collection('enrollments')
      .doc(Enrollment.idFor(uid, session));

  /// The running session, straight off the settings doc's raw map — a full
  /// `CollegeSettings` parse is unwanted work when only one string is needed.
  /// Null means the workspace hasn't set one yet, in which case every
  /// enrollment sync below is skipped entirely: allotment must keep working
  /// exactly as it did before enrollments existed.
  String? _currentSessionOf(
    DocumentSnapshot<Map<String, dynamic>> settingsSnap,
  ) {
    final data = settingsSnap.data();
    if (data == null) return null;
    // Tolerant on purpose, like CollegeSettings.fromMap: on web a nested
    // map read inside a transaction arrives as Map<Object?, Object?>, and a
    // strict `as Map<String, dynamic>` threw on every allotment once a
    // session was set — which is every bed of an auto-allot run.
    final session = data['session'];
    if (session is! Map) return null;
    final current = session['current'];
    return current is String && current.trim().isNotEmpty ? current : null;
  }

  /// [FirebaseFirestore.runTransaction], but an exception thrown inside
  /// [handler] comes back out as itself.
  ///
  /// On web, firebase_core_web boxes anything the handler throws — a
  /// permission-denied from a read, a cast error, anything — in a JS
  /// "Dart exception thrown from converted Future" error, which is all the
  /// warden then sees. Keeping the original here means every caller shows
  /// the real reason on every platform.
  Future<T> _runTransaction<T>(
    Future<T> Function(Transaction tx) handler,
  ) async {
    Object? inner;
    StackTrace? innerTrace;
    try {
      return await _db.runTransaction<T>((tx) async {
        inner = null; // a retried attempt starts clean
        try {
          return await handler(tx);
        } catch (e, st) {
          inner = e;
          innerTrace = st;
          rethrow;
        }
      });
    } catch (_) {
      final e = inner;
      if (e != null) {
        Error.throwWithStackTrace(e, innerTrace ?? StackTrace.current);
      }
      rethrow;
    }
  }

  // ------------------------------------------------------------------
  // Gender eligibility
  // ------------------------------------------------------------------

  /// A co-ed hostel takes anyone. A Boys/Girls hostel takes only the matching
  /// gender. A student with no gender recorded is allowed through, because
  /// blocking on missing data would strand real students — the UI flags it
  /// instead so the warden can fill the field in.
  static bool genderAllows(HostelGender hostel, String? studentGender) {
    if (hostel == HostelGender.coed) return true;
    if (studentGender == null || studentGender.trim().isEmpty) return true;
    final g = studentGender.trim().toLowerCase();
    return switch (hostel) {
      HostelGender.boys => g == 'male',
      HostelGender.girls => g == 'female',
      HostelGender.coed => true,
    };
  }

  static String graduatedRefusal(String name) =>
      '$name has graduated, so can\'t be given a room. Only current students '
      'can be allotted.';

  /// Students who could take a free bed in [hostel], best match first.
  ///
  /// Pure, so the rule can be tested without a widget tree or a database. The
  /// five exclusions are each here for a reason:
  ///
  ///  * **inactive** — a deactivated account can't be allotted at all.
  ///  * **graduated** — they left. Promotion vacates a graduate's room, so
  ///    anyone offered here and allotted would be holding a bed for the rest
  ///    of time while appearing in no session roster — which is how a
  ///    "student" could sit in BH-3 and be invisible in Student Overview.
  ///    Room Allotment's worklist already drops them for the same reason.
  ///  * **Super Admin** — staff, not a resident. Same exclusion Room
  ///    Allotment makes on its worklist.
  ///  * **already allotted** — [allot] refuses these outright; offering them
  ///    would be offering a click that always fails. Moving someone is a
  ///    deliberate act with its own call ([move]).
  ///  * **wrong gender** — a Boys/Girls hostel can't take them, so the pick
  ///    would be refused on tap.
  ///
  /// Ordering puts students already recorded in this hostel but with no room
  /// first: after a CSV import that is who a warden is nearly always looking
  /// for, and burying them under the whole institute makes the list useless.
  static List<AppUser> bedCandidates({
    required Hostel hostel,
    required Iterable<AppUser> roster,
  }) {
    final out =
        roster
            .where(
              (u) =>
                  u.isActive &&
                  !u.isGraduated &&
                  !u.isSuperAdmin &&
                  !u.isAllotted &&
                  genderAllows(hostel.gender, u.gender),
            )
            .toList()
          ..sort((a, b) {
            final aHere = a.hostelId == hostel.id;
            final bHere = b.hostelId == hostel.id;
            if (aHere != bHere) return aHere ? -1 : 1;
            return a.name.toLowerCase().compareTo(b.name.toLowerCase());
          });
    return out;
  }

  static String seatingRefusal(
    String name, {
    required Room room,
    required int requiredCapacity,
  }) =>
      'Room ${room.number} is a ${roomTypeLabel(room.capacity)}, but the '
      'seating policy entitles $name to a ${roomTypeLabel(requiredCapacity)} '
      'this year.';

  /// Marks a UG student as having earned a single on merit (or not).
  ///
  /// Stored on the student's own record, `users/{uid}.singleRoomEligible` —
  /// the field the seating policy already reads. It is an allotment decision,
  /// so it rides on allotment.manage (the rules allow exactly this field
  /// alongside the room fields), and it changes no room by itself: a student
  /// already in a 3-Seater stays there until moved.
  Future<void> setMerit({
    required String collegeId,
    required AppUser student,
    required bool merit,
    required AppUser actor,
  }) async {
    await _db.collection('users').doc(student.uid).update({
      'singleRoomEligible': merit,
      'updatedAt': FieldValue.serverTimestamp(),
    });
    await AuditService.instance.record(
      collegeId: collegeId,
      actor: actor,
      action: 'allotment.merit',
      summary:
          '${merit ? 'Marked' : 'Unmarked'} ${student.name} as merit '
          '(single room)',
      targetLabel: student.name,
    );
  }

  static String genderRefusal(HostelGender hostel, String? studentGender) =>
      'This is a ${hostel.label} hostel and the student is recorded as '
      '${studentGender ?? 'unspecified'}. Change the hostel, or correct the '
      'student\'s gender on their profile.';

  // ------------------------------------------------------------------
  // Allot
  // ------------------------------------------------------------------

  /// Places [student] into [room]. Fails if the room filled up in the meantime,
  /// if the student already holds a bed, or if gender rules forbid it.
  ///
  /// [requiredCapacity] is the room type the seating policy entitles the
  /// student to (see `entitledRoomCapacity`); a room of any other capacity is
  /// refused. Every screen passes it, so the policy holds whichever way a bed
  /// is filled. Null means no policy applies — or a Super Admin has chosen to
  /// bypass it for this one allotment.
  Future<void> allot({
    required String collegeId,
    required AppUser student,
    required Hostel hostel,
    required Room room,
    int? requiredCapacity,
  }) async {
    if (student.isGraduated) {
      throw AllotmentFailure(graduatedRefusal(student.name));
    }
    if (student.isAllotted) {
      throw AllotmentFailure(
        '${student.name} already has ${student.roomLabel}. '
        'Use "Change room" to move them instead.',
      );
    }
    if (!genderAllows(hostel.gender, student.gender)) {
      throw AllotmentFailure(genderRefusal(hostel.gender, student.gender));
    }

    final roomRef = _roomRef(collegeId, hostel.id, room.id);
    final userRef = _db.collection('users').doc(student.uid);
    final hostelRef = _hostelRef(collegeId, hostel.id);
    final settingsRef = _settingsRef(collegeId);

    // Refusals found inside the transaction are carried out of it and thrown
    // afterwards, never thrown from the handler. On web, firebase_core_web
    // wraps anything the handler throws in a JS "Dart exception thrown from
    // converted Future" error, so `e is AllotmentFailure` was false and the
    // warden saw interop noise instead of "Room 104 filled up". Returning
    // without writing still commits nothing, and a stale read still retries.
    String? refusal;

    await _runTransaction((tx) async {
      refusal = null; // a retried attempt starts clean

      // --- all reads first; Firestore forbids a read after a write ---
      final roomSnap = await tx.get(roomRef);
      final userSnap = await tx.get(userRef);
      final settingsSnap = await tx.get(settingsRef);

      if (!roomSnap.exists) {
        refusal = 'That room no longer exists.';
        return;
      }
      if (!userSnap.exists) {
        refusal = 'That student no longer exists.';
        return;
      }

      // Only relevant if a current session is configured AND that session's
      // enrollment document already exists (backfill/promotion creates it) —
      // an allotment made before either of those must not be blocked on
      // them, so this stays best-effort rather than required.
      final currentSession = _currentSessionOf(settingsSnap);
      final enrollmentRef = currentSession == null
          ? null
          : _enrollmentRef(collegeId, student.uid, currentSession);
      final enrollmentSnap = enrollmentRef == null
          ? null
          : await tx.get(enrollmentRef);

      final fresh = Room.fromMap(roomSnap.id, roomSnap.data()!);
      final freshUser = AppUser.fromMap(userSnap.id, userSnap.data()!);

      // Re-check against what's actually in the database right now, not what
      // the warden's screen was showing when they clicked. A promotion run
      // can graduate someone between the list rendering and the tap.
      if (freshUser.isGraduated) {
        refusal = graduatedRefusal(freshUser.name);
        return;
      }
      if (freshUser.isAllotted) {
        refusal =
            '${freshUser.name} was just allotted ${freshUser.roomLabel} by '
            'someone else.';
        return;
      }
      if (fresh.status != RoomStatus.active) {
        refusal =
            'Room ${fresh.number} is marked ${fresh.status.label} and can\'t '
            'take students.';
        return;
      }
      if (fresh.occupantUids.contains(student.uid)) {
        refusal = 'That student is already in this room.';
        return;
      }
      if (fresh.occupied >= fresh.capacity) {
        refusal =
            'Room ${fresh.number} filled up while you were choosing '
            '(${fresh.occupied}/${fresh.capacity}).';
        return;
      }
      if (requiredCapacity != null && fresh.capacity != requiredCapacity) {
        refusal = seatingRefusal(
          freshUser.name,
          room: fresh,
          requiredCapacity: requiredCapacity,
        );
        return;
      }

      tx.update(roomRef, {
        'occupantUids': [...fresh.occupantUids, student.uid],
      });
      tx.update(userRef, {
        'hostelId': hostel.id,
        'hostelName': hostel.name,
        'roomId': fresh.id,
        'roomNumber': fresh.number,
        'allottedAt': FieldValue.serverTimestamp(),
      });
      tx.update(hostelRef, {'occupiedBeds': FieldValue.increment(1)});

      if (enrollmentSnap != null && enrollmentSnap.exists) {
        tx.update(enrollmentRef!, {
          'hostelId': hostel.id,
          'hostelName': hostel.name,
          'roomId': fresh.id,
          'roomNumber': fresh.number,
          'roomCapacity': fresh.capacity,
          'allottedAt': FieldValue.serverTimestamp(),
        });
      }
    });

    final refused = refusal;
    if (refused != null) throw AllotmentFailure(refused);
  }

  // ------------------------------------------------------------------
  // Auto-allot — a whole filtered group into one hostel, in room order
  // ------------------------------------------------------------------

  /// Works out who goes where, without touching the database.
  ///
  /// Rooms are filled strictly in room-number series, counted numerically
  /// (1, 2 … 10, 11, or 101, 102 … 110, 201) — see [compareRoomsInSeries] —
  /// and each room is filled before the next is started, so a batch lands as
  /// a contiguous block of rooms rather than scattered across the building.
  /// Students are taken in registration-number order, which keeps classmates
  /// together.
  ///
  /// Eligibility is exactly [bedCandidates]: anyone [allot] would refuse is
  /// never planned, because a planned bed that always fails reads as the app
  /// being broken. On top of that:
  ///
  ///  * **Seating policy** — with [requiredCapacityOf] given, a student only
  ///    gets a room of the capacity the policy entitles them to (a PG student
  ///    a Single, a 1st-year a 3-Seater). Null for a student means no policy
  ///    covers them and any room will do. The same rule the room picker's
  ///    "Match only" switch applies one student at a time.
  ///  * **Another hostel** — a student already recorded against a different
  ///    hostel (typically from the import sheet) is left out unless
  ///    [includeOtherHostels], because allotting them here silently moves
  ///    them out of the hostel the office put them in. With [knownHostelIds]
  ///    given, a hostelId outside it — a hostel since deleted, whose id
  ///    deleting never cleared off its students — counts as no hostel at all,
  ///    not "another hostel": there is nowhere else for them to be.
  ///
  /// Only active rooms with a free bed are used; a room under maintenance or
  /// reserved is skipped, as [allot] would refuse it.
  ///
  /// Anyone not placed says why: [AutoAllotPlan.noRoomOfType] when the
  /// policy entitles them to a room type this hostel has none of — so the
  /// warden is told to switch the policy off or pick another hostel, not that
  /// it "ran out" — and [AutoAllotPlan.noBed] when such rooms exist but are
  /// full.
  static AutoAllotPlan planAutoAllot({
    required Hostel hostel,
    required Iterable<Room> rooms,
    required Iterable<AppUser> students,
    int? Function(AppUser student)? requiredCapacityOf,
    bool includeOtherHostels = false,
    Set<String>? knownHostelIds,
  }) {
    final all = students.toList();
    final candidates = bedCandidates(hostel: hostel, roster: all);
    final candidateUids = {for (final u in candidates) u.uid};
    final ineligible = [
      for (final u in all)
        if (!candidateUids.contains(u.uid)) u,
    ];

    final otherHostel = <AppUser>[];
    final queue = <AppUser>[];
    for (final u in candidates) {
      final elsewhere =
          u.hostelId != null &&
          u.hostelId != hostel.id &&
          (knownHostelIds == null || knownHostelIds.contains(u.hostelId));
      (elsewhere && !includeOtherHostels ? otherHostel : queue).add(u);
    }
    queue.sort(_byRegistrationNo);

    final allRooms = rooms.toList();
    final active = allRooms
        .where((r) => r.status == RoomStatus.active)
        .toList();
    final capacitiesHere = {for (final r in active) r.capacity};
    // Types the building has at all — so "every 3-Seater is under
    // maintenance" isn't reported as "this hostel has no 3-Seaters".
    final capacitiesBuilt = {for (final r in allRooms) r.capacity};
    final open = active.where((r) => r.free > 0).toList()
      ..sort(compareRoomsInSeries);
    final remaining = [for (final r in open) r.free];

    final assignments = <AutoAllotAssignment>[];
    final noBed = <AppUser>[];
    final noRoomOfType = <AppUser>[];
    final typeOutOfService = <AppUser>[];
    for (final student in queue) {
      final need = requiredCapacityOf?.call(student);
      if (need != null && !capacitiesHere.contains(need)) {
        (capacitiesBuilt.contains(need) ? typeOutOfService : noRoomOfType).add(
          student,
        );
        continue;
      }
      var placed = false;
      for (var i = 0; i < open.length; i++) {
        if (remaining[i] == 0) continue;
        if (need != null && open[i].capacity != need) continue;
        assignments.add(
          AutoAllotAssignment(
            student: student,
            room: open[i],
            requiredCapacity: need,
          ),
        );
        remaining[i]--;
        placed = true;
        break;
      }
      if (!placed) noBed.add(student);
    }

    return AutoAllotPlan(
      assignments: assignments,
      noBed: noBed,
      noRoomOfType: noRoomOfType,
      typeOutOfService: typeOutOfService,
      requiredCapacityOf: requiredCapacityOf,
      otherHostel: otherHostel,
      ineligible: ineligible,
    );
  }

  /// Room number counted numerically — "9" before "10", "G-2" before "G-10"
  /// — with floor only breaking ties.
  ///
  /// Number first, not floor first, on purpose. For the usual floor-prefixed
  /// numbering (101 … 1xx, 201 …) the two orders are identical, but some of
  /// this college's hostels are numbered 1–252 by *wing*, so floor 1 holds
  /// 1–29, 88–111 and 160–190. Floor-first filled 1–29 and then jumped to
  /// 88, splitting consecutive registration numbers across the building —
  /// the opposite of the "series-wise room number order" asked for.
  static int compareRoomsInSeries(Room a, Room b) {
    final byNumber = Hostel.compareLabels(a.number, b.number);
    if (byNumber != 0) return byNumber;
    final byFloor = a.floor.compareTo(b.floor);
    return byFloor != 0 ? byFloor : a.id.compareTo(b.id);
  }

  static int _byRegistrationNo(AppUser a, AppUser b) {
    final ra = a.enrollmentNo?.trim() ?? '';
    final rb = b.enrollmentNo?.trim() ?? '';
    // Anyone without a registration number goes last, by name.
    if (ra.isEmpty != rb.isEmpty) return ra.isEmpty ? 1 : -1;
    final byReg = ra.isEmpty ? 0 : Hostel.compareLabels(ra, rb);
    if (byReg != 0) return byReg;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  /// Carries out [assignments] — each one through [allot], so every bed goes
  /// through the same transaction, re-checks and enrollment sync as a single
  /// click in the room picker. Never a blind batch: a bed someone else took
  /// a second ago must fail cleanly, not be double-booked.
  ///
  /// Rooms run [lanes] at a time; students within one room run one after
  /// another. Two transactions on the same room would only fight over it and
  /// retry, while different rooms share nothing they both write.
  ///
  /// Best-effort per student, like the CSV import: one refusal is recorded
  /// and the rest carry on. [isCancelled] is polled before every bed, so Stop
  /// never leaves one half-written. Re-running is safe — anyone placed by an
  /// earlier run is allotted and simply no longer planned.
  Future<AutoAllotOutcome> runAutoAllot({
    required String collegeId,
    required Hostel hostel,
    required List<AutoAllotAssignment> assignments,
    required AppUser actor,
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
    int lanes = 4,
  }) async {
    final byRoom = <String, List<AutoAllotAssignment>>{};
    for (final a in assignments) {
      byRoom.putIfAbsent(a.room.id, () => []).add(a);
    }
    final roomQueues = byRoom.values.toList();

    var done = 0;
    var allotted = 0;
    var stopped = false;
    final failures = <String>[];
    bool cancelled() => isCancelled?.call() ?? false;

    Future<void> runRoom(List<AutoAllotAssignment> queue) async {
      for (final a in queue) {
        if (cancelled()) {
          stopped = true;
          return;
        }
        try {
          await allot(
            collegeId: collegeId,
            student: a.student,
            hostel: hostel,
            room: a.room,
            requiredCapacity: a.requiredCapacity,
          );
          allotted++;
        } catch (e) {
          failures.add(
            '${a.student.name} → room ${a.room.number}: '
            '${e is AllotmentFailure
                ? e.message
                : e is FirebaseException
                ? (e.message ?? e.code)
                : e}',
          );
        }
        done++;
        onProgress?.call(done, assignments.length);
      }
    }

    // Each lane takes the next untouched room. `next++` cannot race: Dart
    // runs one lane at a time between awaits.
    var next = 0;
    Future<void> lane() async {
      while (next < roomQueues.length) {
        if (cancelled()) {
          stopped = true;
          return;
        }
        await runRoom(roomQueues[next++]);
      }
    }

    final laneCount = roomQueues.isEmpty
        ? 0
        : lanes.clamp(1, roomQueues.length);
    await Future.wait([for (var i = 0; i < laneCount; i++) lane()]);

    if (allotted > 0) {
      await AuditService.instance.record(
        collegeId: collegeId,
        actor: actor,
        action: 'allotment.auto',
        summary:
            'Auto-allotted $allotted student(s) into ${hostel.name}'
            '${failures.isEmpty ? '' : ', ${failures.length} refused'}'
            '${stopped ? ' (stopped early)' : ''}',
        targetLabel: hostel.name,
      );
    }

    return AutoAllotOutcome(
      allotted: allotted,
      failures: failures,
      stoppedEarly: stopped,
    );
  }

  // ------------------------------------------------------------------
  // Hostel-only assignment (no specific room/bed)
  // ------------------------------------------------------------------
  //
  // Some colleges know who lives in which hostel before rooms are finalised
  // — or never track individual beds for a given block at all. This records
  // hostel membership on [AppUser.hostelId]/[hostelName] without touching
  // [AppUser.roomId] or any room's occupancy, so [AppUser.isAllotted] (which
  // requires a room) correctly stays false. A plain write, not a
  // transaction: unlike [allot], nothing here contends over a shared,
  // capacity-limited resource.

  /// Marks [student] as belonging to [hostel] with no room chosen yet.
  Future<void> assignHostelOnly({
    required String collegeId,
    required AppUser student,
    required Hostel hostel,
  }) async {
    if (student.isGraduated) {
      throw AllotmentFailure(graduatedRefusal(student.name));
    }
    if (student.isAllotted) {
      throw AllotmentFailure(
        '${student.name} already has ${student.roomLabel}. '
        'Change or vacate their room instead.',
      );
    }
    if (!genderAllows(hostel.gender, student.gender)) {
      throw AllotmentFailure(genderRefusal(hostel.gender, student.gender));
    }

    final userRef = _db.collection('users').doc(student.uid);
    final settingsRef = _settingsRef(collegeId);

    // A transaction now, not a plain write — reading the enrollment to sync
    // onto requires it. Nothing here contends over a shared resource the way
    // a room's capacity does, so this isn't racing anyone; the transaction
    // exists only to keep the settings/enrollment read and the two writes
    // atomic with each other.
    await _runTransaction((tx) async {
      final settingsSnap = await tx.get(settingsRef);
      final currentSession = _currentSessionOf(settingsSnap);
      final enrollmentRef = currentSession == null
          ? null
          : _enrollmentRef(collegeId, student.uid, currentSession);
      final enrollmentSnap = enrollmentRef == null
          ? null
          : await tx.get(enrollmentRef);

      tx.update(userRef, {'hostelId': hostel.id, 'hostelName': hostel.name});

      if (enrollmentSnap != null && enrollmentSnap.exists) {
        tx.update(enrollmentRef!, {
          'hostelId': hostel.id,
          'hostelName': hostel.name,
        });
      }
    });
  }

  /// Clears a hostel-only assignment made by [assignHostelOnly]. A student
  /// who actually holds a room should be vacated via [vacate] instead, which
  /// also frees the bed — this refuses if called on one by mistake.
  Future<void> unassignHostelOnly({
    required String collegeId,
    required AppUser student,
  }) async {
    if (student.isAllotted) {
      throw AllotmentFailure(
        '${student.name} has an actual room — vacate it instead.',
      );
    }

    final userRef = _db.collection('users').doc(student.uid);
    final settingsRef = _settingsRef(collegeId);

    await _runTransaction((tx) async {
      final settingsSnap = await tx.get(settingsRef);
      final currentSession = _currentSessionOf(settingsSnap);
      final enrollmentRef = currentSession == null
          ? null
          : _enrollmentRef(collegeId, student.uid, currentSession);
      final enrollmentSnap = enrollmentRef == null
          ? null
          : await tx.get(enrollmentRef);

      tx.update(userRef, {'hostelId': null, 'hostelName': null});

      if (enrollmentSnap != null && enrollmentSnap.exists) {
        tx.update(enrollmentRef!, {'hostelId': null, 'hostelName': null});
      }
    });
  }

  // ------------------------------------------------------------------
  // Vacate
  // ------------------------------------------------------------------

  /// Frees the bed [student] currently holds. Safe to call even if the room
  /// document has drifted — the user's fields are always cleared.
  Future<void> vacate({
    required String collegeId,
    required AppUser student,
  }) async {
    if (!student.isAllotted) {
      throw AllotmentFailure('${student.name} has no room to vacate.');
    }

    final hostelId = student.hostelId!;
    final roomId = student.roomId!;
    final roomRef = _roomRef(collegeId, hostelId, roomId);
    final userRef = _db.collection('users').doc(student.uid);
    final hostelRef = _hostelRef(collegeId, hostelId);
    final settingsRef = _settingsRef(collegeId);

    await _runTransaction((tx) async {
      final roomSnap = await tx.get(roomRef);
      final settingsSnap = await tx.get(settingsRef);

      final currentSession = _currentSessionOf(settingsSnap);
      final enrollmentRef = currentSession == null
          ? null
          : _enrollmentRef(collegeId, student.uid, currentSession);
      final enrollmentSnap = enrollmentRef == null
          ? null
          : await tx.get(enrollmentRef);

      // Clear the student's side regardless — if the room was deleted out from
      // under them, leaving these fields set would strand the student with a
      // room that doesn't exist.
      tx.update(userRef, {
        'hostelId': null,
        'hostelName': null,
        'roomId': null,
        'roomNumber': null,
        'allottedAt': null,
      });

      if (enrollmentSnap != null && enrollmentSnap.exists) {
        tx.update(enrollmentRef!, {
          'hostelId': null,
          'hostelName': null,
          'roomId': null,
          'roomNumber': null,
          'roomCapacity': null,
          'allottedAt': null,
        });
      }

      if (roomSnap.exists) {
        final fresh = Room.fromMap(roomSnap.id, roomSnap.data()!);
        if (fresh.occupantUids.contains(student.uid)) {
          tx.update(roomRef, {
            'occupantUids': fresh.occupantUids
                .where((u) => u != student.uid)
                .toList(),
          });
          tx.update(hostelRef, {'occupiedBeds': FieldValue.increment(-1)});
        }
      }
    });
  }

  // ------------------------------------------------------------------
  // Move
  // ------------------------------------------------------------------

  /// Moves a student from their current room to another one. Done as vacate
  /// then allot so both rooms' counters stay correct; if the second step
  /// fails the student is left unallotted rather than in two rooms at once.
  Future<void> move({
    required String collegeId,
    required AppUser student,
    required Hostel toHostel,
    required Room toRoom,
    int? requiredCapacity,
  }) async {
    // Checked here as well as in `allot`: the rebuilt `cleared` student below
    // carries no status, so `allot` can't see the graduation, and by then the
    // vacate has already happened — a refusal after it would strand them.
    if (student.isGraduated) {
      throw AllotmentFailure(graduatedRefusal(student.name));
    }
    if (!genderAllows(toHostel.gender, student.gender)) {
      throw AllotmentFailure(genderRefusal(toHostel.gender, student.gender));
    }
    // Before the vacate, for the same reason as the checks above: refusing
    // only inside `allot` would leave the student with no room at all.
    if (requiredCapacity != null && toRoom.capacity != requiredCapacity) {
      throw AllotmentFailure(
        seatingRefusal(
          student.name,
          room: toRoom,
          requiredCapacity: requiredCapacity,
        ),
      );
    }

    await vacate(collegeId: collegeId, student: student);

    // Rebuild the student without their old room so `allot` accepts them.
    final cleared = AppUser(
      uid: student.uid,
      name: student.name,
      email: student.email,
      collegeId: student.collegeId,
      roleId: student.roleId,
      roleName: student.roleName,
      isSuperAdmin: student.isSuperAdmin,
      isActive: student.isActive,
      phone: student.phone,
      gender: student.gender,
      enrollmentNo: student.enrollmentNo,
    );

    await allot(
      collegeId: collegeId,
      student: cleared,
      hostel: toHostel,
      room: toRoom,
      requiredCapacity: requiredCapacity,
    );
  }

  // ------------------------------------------------------------------
  // Reads
  // ------------------------------------------------------------------

  /// The people sharing a room, for the "My Room" page.
  Future<List<AppUser>> occupantsOf(Room room, {String? excludeUid}) async {
    final uids = room.occupantUids.where((u) => u != excludeUid).toList();
    if (uids.isEmpty) return [];

    // whereIn caps at 30 values; a room will never be near that, but chunking
    // keeps this honest if capacity ever grows.
    final results = <AppUser>[];
    for (var i = 0; i < uids.length; i += 30) {
      final chunk = uids.sublist(i, (i + 30).clamp(0, uids.length));
      final snap = await _db
          .collection('users')
          .where(FieldPath.documentId, whereIn: chunk)
          .get();
      results.addAll(snap.docs.map((d) => AppUser.fromMap(d.id, d.data())));
    }
    return results;
  }

  Future<Room?> findRoom({
    required String collegeId,
    required String hostelId,
    required String roomId,
  }) async {
    final snap = await _roomRef(collegeId, hostelId, roomId).get();
    return snap.exists ? Room.fromMap(snap.id, snap.data()!) : null;
  }
}

/// One planned bed: [student] into [room].
class AutoAllotAssignment {
  final AppUser student;
  final Room room;

  /// The room type the policy entitles [student] to, carried through to
  /// [AllotmentService.allot] so the write enforces what the plan assumed.
  final int? requiredCapacity;

  const AutoAllotAssignment({
    required this.student,
    required this.room,
    this.requiredCapacity,
  });
}

/// What [AllotmentService.planAutoAllot] decided, with everyone it could not
/// place accounted for — nobody in the group silently disappears.
class AutoAllotPlan {
  /// In the order they will be written: rooms in series, students in
  /// registration-number order.
  final List<AutoAllotAssignment> assignments;

  /// Eligible, but every free bed of the type they need was used up.
  final List<AppUser> noBed;

  /// The seating policy entitles them to a room type this hostel has none
  /// of — no amount of free beds here would place them.
  final List<AppUser> noRoomOfType;

  /// The hostel has rooms of the type they need, but every one is under
  /// maintenance or reserved — reactivating some would place them.
  final List<AppUser> typeOutOfService;

  /// The policy lookup the plan was made with, kept so [noRoomOfType] can be
  /// explained by type ("12 need a 3-Seater"). Null when the policy was off.
  final int? Function(AppUser student)? requiredCapacityOf;

  /// Recorded against a different hostel, so left out on purpose.
  final List<AppUser> otherHostel;

  /// Refused by the same rules as a single allotment: already in a room,
  /// wrong gender for this hostel, inactive or graduated.
  final List<AppUser> ineligible;

  const AutoAllotPlan({
    required this.assignments,
    required this.noBed,
    this.noRoomOfType = const [],
    this.typeOutOfService = const [],
    this.requiredCapacityOf,
    required this.otherHostel,
    required this.ineligible,
  });

  /// Rooms touched, in series order — sorted, because with mixed room types
  /// the order of first use is not series order (the first PG student can
  /// land in Single 105 before anyone reaches 3-Seater 101).
  List<Room> get rooms {
    final seen = <String>{};
    return [
      for (final a in assignments)
        if (seen.add(a.room.id)) a.room,
    ]..sort(AllotmentService.compareRoomsInSeries);
  }

  /// [noRoomOfType], counted per room type they need: {3: 237}.
  Map<int, int> get missingTypes => _countByType(noRoomOfType);

  /// [typeOutOfService], counted the same way.
  Map<int, int> get outOfServiceTypes => _countByType(typeOutOfService);

  Map<int, int> _countByType(List<AppUser> students) {
    final out = <int, int>{};
    for (final u in students) {
      final need = requiredCapacityOf?.call(u);
      if (need != null) out[need] = (out[need] ?? 0) + 1;
    }
    return out;
  }
}

class AutoAllotOutcome {
  final int allotted;
  final List<String> failures;
  final bool stoppedEarly;
  const AutoAllotOutcome({
    required this.allotted,
    required this.failures,
    required this.stoppedEarly,
  });
}

class AllotmentFailure implements Exception {
  final String message;
  AllotmentFailure(this.message);
  @override
  String toString() => message;
}
