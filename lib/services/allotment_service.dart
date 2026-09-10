import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/app_user.dart';
import '../models/enrollment.dart';
import '../models/hostel.dart';

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

  DocumentReference<Map<String, dynamic>> _settingsRef(String collegeId) =>
      _db
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
  /// [CollegeSettings] parse is unwanted work when only one string is
  /// needed. Null means the workspace hasn't set one yet, in which case
  /// enrollment sync below is skipped entirely: allotment must keep working
  /// exactly as it did before enrollments existed.
  String? _currentSessionOf(DocumentSnapshot<Map<String, dynamic>> settingsSnap) {
    final data = settingsSnap.data();
    if (data == null) return null;
    final session = data['session'] as Map<String, dynamic>?;
    return session?['current'] as String?;
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

  static String genderRefusal(HostelGender hostel, String? studentGender) =>
      'This is a ${hostel.label} hostel and the student is recorded as '
      '${studentGender ?? 'unspecified'}. Change the hostel, or correct the '
      'student\'s gender on their profile.';

  // ------------------------------------------------------------------
  // Allot
  // ------------------------------------------------------------------

  /// Places [student] into [room]. Fails if the room filled up in the meantime,
  /// if the student already holds a bed, or if gender rules forbid it.
  Future<void> allot({
    required String collegeId,
    required AppUser student,
    required Hostel hostel,
    required Room room,
  }) async {
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

    await _db.runTransaction((tx) async {
      // --- all reads first; Firestore forbids a read after a write ---
      final roomSnap = await tx.get(roomRef);
      final userSnap = await tx.get(userRef);
      final settingsSnap = await tx.get(settingsRef);

      if (!roomSnap.exists) {
        throw AllotmentFailure('That room no longer exists.');
      }
      if (!userSnap.exists) {
        throw AllotmentFailure('That student no longer exists.');
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
      // the warden's screen was showing when they clicked.
      if (freshUser.isAllotted) {
        throw AllotmentFailure(
          '${freshUser.name} was just allotted ${freshUser.roomLabel} by '
          'someone else.',
        );
      }
      if (fresh.status != RoomStatus.active) {
        throw AllotmentFailure(
          'Room ${fresh.number} is marked ${fresh.status.label} and can\'t '
          'take students.',
        );
      }
      if (fresh.occupantUids.contains(student.uid)) {
        throw AllotmentFailure('That student is already in this room.');
      }
      if (fresh.occupied >= fresh.capacity) {
        throw AllotmentFailure(
          'Room ${fresh.number} filled up while you were choosing '
          '(${fresh.occupied}/${fresh.capacity}).',
        );
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
  }

  // ------------------------------------------------------------------
  // Hostel-only assignment (no specific room/bed)
  // ------------------------------------------------------------------
  //
  // Some colleges know who lives in which hostel before rooms are finalised
  // — or never track individual beds for a given block at all. This records
  // hostel membership on [AppUser.hostelId]/[hostelName] without touching
  // [AppUser.roomId] or any room's occupancy, so [AppUser.isAllotted] (which
  // requires a room) correctly stays false. Same best-effort enrollment-sync
  // as [allot]/[vacate]: only touched if a current-session enrollment
  // document already exists for this student.

  /// Marks [student] as belonging to [hostel] with no room chosen yet.
  Future<void> assignHostelOnly({
    required String collegeId,
    required AppUser student,
    required Hostel hostel,
  }) async {
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

    await _db.runTransaction((tx) async {
      final settingsSnap = await tx.get(settingsRef);
      final currentSession = _currentSessionOf(settingsSnap);
      final enrollmentRef = currentSession == null
          ? null
          : _enrollmentRef(collegeId, student.uid, currentSession);
      final enrollmentSnap = enrollmentRef == null
          ? null
          : await tx.get(enrollmentRef);

      tx.update(userRef, {
        'hostelId': hostel.id,
        'hostelName': hostel.name,
      });

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

    await _db.runTransaction((tx) async {
      final settingsSnap = await tx.get(settingsRef);
      final currentSession = _currentSessionOf(settingsSnap);
      final enrollmentRef = currentSession == null
          ? null
          : _enrollmentRef(collegeId, student.uid, currentSession);
      final enrollmentSnap = enrollmentRef == null
          ? null
          : await tx.get(enrollmentRef);

      tx.update(userRef, {
        'hostelId': null,
        'hostelName': null,
      });

      if (enrollmentSnap != null && enrollmentSnap.exists) {
        tx.update(enrollmentRef!, {
          'hostelId': null,
          'hostelName': null,
        });
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

    await _db.runTransaction((tx) async {
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
  }) async {
    if (!genderAllows(toHostel.gender, student.gender)) {
      throw AllotmentFailure(genderRefusal(toHostel.gender, student.gender));
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
      results.addAll(
        snap.docs.map((d) => AppUser.fromMap(d.id, d.data())),
      );
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

class AllotmentFailure implements Exception {
  final String message;
  AllotmentFailure(this.message);
  @override
  String toString() => message;
}
