import '../models/app_user.dart';
import 'audit_service.dart';
import 'data_service.dart';
import 'fee_service.dart';
import 'fine_service.dart';
import 'hostel_service.dart';
import 'request_service.dart';

/// Which part of the reset is running, for the progress display.
enum ResetStage {
  reading('Reading the roster'),
  profiles('Deleting student profiles'),
  fees('Clearing mess fee records'),
  fines('Clearing fines'),
  requests('Clearing requests'),
  rooms('Emptying rooms'),
  done('Finished');

  final String label;
  const ResetStage(this.label);
}

class StudentDataResetOutcome {
  final int profilesDeleted;
  final int feeRecordsDeleted;
  final int finesDeleted;
  final int requestsDeleted;
  final int roomsCleared;
  final int bedsFreed;

  /// Accounts deliberately left alone — Super Admins, including you.
  final int adminsKept;

  /// Stages that failed, each with the reason. A reset carries on past a
  /// failed stage rather than aborting, so one missing permission cannot
  /// leave the job half-done with no way to tell what landed.
  final List<String> failures;

  final bool stoppedEarly;

  const StudentDataResetOutcome({
    required this.profilesDeleted,
    required this.feeRecordsDeleted,
    required this.finesDeleted,
    required this.requestsDeleted,
    required this.roomsCleared,
    required this.bedsFreed,
    required this.adminsKept,
    required this.failures,
    required this.stoppedEarly,
  });

  int get totalRecords =>
      profilesDeleted + feeRecordsDeleted + finesDeleted + requestsDeleted;
}

/// The single "clear every student and everything attached to them" operation.
///
/// This exists because clearing the roster was never one action. Deleting the
/// user documents left mess-fee rows, fines, requests and room occupancy
/// pointing at uids that no longer existed — so the Mess Fees page went on
/// reporting hundreds of residents and lakhs pending against a database with
/// no students in it, and Room Allotment went on showing thousands awaiting a
/// room. The Danger Zone had five separate buttons that between them *almost*
/// covered it, and no button for fee records at all.
///
/// What it deliberately does NOT touch, because these are the institution and
/// not its intake:
///
///   * hostels and their rooms — the buildings stay, only occupancy is cleared
///   * college details, branding and settings
///   * roles and permissions
///   * notices and office orders
///   * the audit log, which is the record of this reset having happened
///   * Super Admin accounts, including the one running it
///
/// The one thing it cannot do is remove Firebase Auth sign-in accounts. The
/// client SDK only ever deletes the *currently signed-in* user, so a browser
/// session can drop three thousand profile documents but not the three
/// thousand logins behind them. Those need the Admin SDK —
/// `tools/delete-students.js --all-students`. Callers must say so plainly
/// rather than implying a wipe that did not happen, because the symptom
/// surfaces much later as "email already in use" on the next import.
class ResetService {
  ResetService._();
  static final ResetService instance = ResetService._();

  /// Runs the full reset. Best-effort per stage; see [StudentDataResetOutcome].
  ///
  /// [isCancelled] is polled between stages and between profile batches.
  /// Stopping part-way is safe — every stage is idempotent, so running it
  /// again simply finishes the job.
  Future<StudentDataResetOutcome> resetStudentData({
    required String collegeId,
    required AppUser actor,
    void Function(ResetStage stage, int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final failures = <String>[];
    var stopped = false;
    bool cancelled() => isCancelled?.call() ?? false;

    // ------------------------------------------------ read the roster
    onProgress?.call(ResetStage.reading, 0, 0);
    final all = await DataService.instance.watchUsers(collegeId).first;
    final targets = all.where((u) => !u.isSuperAdmin).toList();
    final adminsKept = all.length - targets.length;

    // ------------------------------------------------ profiles
    var profilesDeleted = 0;
    onProgress?.call(ResetStage.profiles, 0, targets.length);
    try {
      profilesDeleted = await DataService.instance.deleteProfilesInBulk(
        users: targets,
        onProgress: (done, total) =>
            onProgress?.call(ResetStage.profiles, done, total),
        isCancelled: isCancelled,
      );
      if (profilesDeleted < targets.length) stopped = true;
    } catch (e) {
      failures.add('Student profiles: $e');
    }

    // Everything below sweeps a whole collection, so it stays correct even if
    // the profile stage stopped part-way. Each is wrapped on its own: losing
    // fines must not cost us the fee records.

    // ------------------------------------------------ mess fee records
    var feeRecordsDeleted = 0;
    if (!cancelled()) {
      onProgress?.call(ResetStage.fees, 0, 0);
      try {
        feeRecordsDeleted = await FeeService.instance.deleteAll(collegeId);
      } catch (e) {
        failures.add('Mess fee records: $e');
      }
    }

    // ------------------------------------------------ fines
    var finesDeleted = 0;
    if (!cancelled()) {
      onProgress?.call(ResetStage.fines, 0, 0);
      try {
        finesDeleted = await FineService.instance.deleteAll(collegeId);
      } catch (e) {
        failures.add('Fines: $e');
      }
    }

    // ------------------------------------------------ requests
    var requestsDeleted = 0;
    if (!cancelled()) {
      onProgress?.call(ResetStage.requests, 0, 0);
      try {
        requestsDeleted = await RequestService.instance.deleteAll(collegeId);
      } catch (e) {
        failures.add('Requests: $e');
      }
    }

    // ------------------------------------------------ room occupancy
    //
    // Last, and unconditional. The profiles are already gone by this point, so
    // every `occupantUids` entry still standing is a dangling reference and
    // every `occupiedBeds` counter is overcounted. This is what makes Room
    // Allotment show the right free-bed total again.
    var roomsCleared = 0;
    var bedsFreed = 0;
    if (!cancelled()) {
      onProgress?.call(ResetStage.rooms, 0, 0);
      try {
        final r = await HostelService.instance.emptyAllRooms(collegeId);
        roomsCleared = r.roomsCleared;
        bedsFreed = r.bedsFreed;
      } catch (e) {
        failures.add('Room occupancy: $e');
      }
    }

    if (cancelled()) stopped = true;
    onProgress?.call(ResetStage.done, 0, 0);

    final outcome = StudentDataResetOutcome(
      profilesDeleted: profilesDeleted,
      feeRecordsDeleted: feeRecordsDeleted,
      finesDeleted: finesDeleted,
      requestsDeleted: requestsDeleted,
      roomsCleared: roomsCleared,
      bedsFreed: bedsFreed,
      adminsKept: adminsKept,
      failures: failures,
      stoppedEarly: stopped,
    );

    // Not reversible and says so: there is no snapshot of three thousand
    // documents to put back. The entry exists so the workspace has a record of
    // who cleared it and when.
    await AuditService.instance.record(
      collegeId: collegeId,
      actor: actor,
      action: 'data.resetStudents',
      summary:
          'Cleared all student data — ${outcome.profilesDeleted} profile(s), '
          '${outcome.feeRecordsDeleted} fee record(s), '
          '${outcome.finesDeleted} fine(s), '
          '${outcome.requestsDeleted} request(s), '
          '${outcome.bedsFreed} bed(s) freed'
          '${outcome.stoppedEarly ? ' (stopped early)' : ''}',
      targetLabel: 'All students',
    );

    return outcome;
  }
}
