import 'package:firebase_core/firebase_core.dart';

import '../models/app_user.dart';
import 'audit_service.dart';
import 'auth_service.dart';
import 'csv_import.dart' show LaneVerdict, runPooled;
import 'data_service.dart';
import 'enrollment_service.dart';
import 'fee_service.dart';
import 'fine_service.dart';
import 'hostel_service.dart';
import 'request_service.dart';

/// Which part of the reset is running, for the progress display.
enum ResetStage {
  reading('Reading the roster'),
  accounts('Removing sign-in accounts'),
  profiles('Deleting student profiles'),
  fees('Clearing mess fee records'),
  fines('Clearing fines'),
  requests('Clearing requests'),
  enrollments('Clearing academic records'),
  rooms('Emptying rooms'),
  done('Finished');

  final String label;
  const ResetStage(this.label);
}

class StudentDataResetOutcome {
  /// Firebase Auth sign-in accounts removed.
  final int accountsDeleted;

  /// Sign-in accounts that survived, each "Name: why" — a student who changed
  /// their password, or staff with a real one. Their profiles are still
  /// deleted, so these become orphans for `delete-students.js --orphans`.
  final List<String> accountsKept;

  final int profilesDeleted;
  final int feeRecordsDeleted;
  final int finesDeleted;
  final int requestsDeleted;
  final int enrollmentsDeleted;
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
    this.accountsDeleted = 0,
    this.accountsKept = const [],
    required this.profilesDeleted,
    required this.feeRecordsDeleted,
    required this.finesDeleted,
    required this.requestsDeleted,
    required this.enrollmentsDeleted,
    required this.roomsCleared,
    required this.bedsFreed,
    required this.adminsKept,
    required this.failures,
    required this.stoppedEarly,
  });

  int get totalRecords =>
      profilesDeleted +
      feeRecordsDeleted +
      finesDeleted +
      requestsDeleted +
      enrollmentsDeleted;
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
/// Sign-in accounts are removed too, as far as a browser can: the client SDK
/// only deletes the *currently signed-in* user, so each student is signed in
/// as — on an isolated app, with the password derived from their
/// registration number — and deleted (see [AuthService.deleteAuthAccount]).
/// Anyone whose password is no longer the derived one (a student who changed
/// it, staff with a real one) cannot be removed that way; they are reported
/// by name, and `tools/delete-students.js --orphans` clears them. Callers
/// must show that list rather than imply a wipe that did not happen, because
/// the symptom surfaces later as "email already in use" on the next import.
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
    // Super Admin only, and refused before anything is touched. The sign-in
    // stage needs no Firestore permission at all, so a role that can open the
    // Danger Zone but not delete profiles would remove every login and then
    // be refused the profiles — leaving the whole roster unable to sign in.
    if (!actor.isSuperAdmin) {
      throw StateError('Only a Super Admin can delete all student data.');
    }

    final failures = <String>[];
    var stopped = false;
    bool cancelled() => isCancelled?.call() ?? false;

    // ------------------------------------------------ read the roster
    onProgress?.call(ResetStage.reading, 0, 0);
    final all = await DataService.instance.watchUsers(collegeId).first;
    // Never the person running it, whatever their flags say — the rules
    // refuse deleting your own profile, which would fail a whole batch.
    final targets = all
        .where((u) => !u.isSuperAdmin && u.uid != actor.uid)
        .toList();
    final adminsKept = all.length - targets.length;

    // ------------------------------------------------ sign-in accounts
    //
    // First, while every profile still exists: a profile is the only place
    // the app learns a student's login email and registration number. Delete
    // it first and a login that then fails to go is an orphan nobody can
    // trace from here.
    var accountsDeleted = 0;
    final accountsKept = <String>[];
    var accountsStageFailed = false;
    // Filled as each login goes, outside the try, so a Stop or a crash part
    // way through still knows exactly whose login is already gone.
    final removed = <AppUser>[];
    onProgress?.call(ResetStage.accounts, 0, targets.length);
    try {
      final r = await _deleteSignInAccounts(
        targets,
        onRemoved: removed.add,
        onProgress: (done, total) =>
            onProgress?.call(ResetStage.accounts, done, total),
        isCancelled: isCancelled,
      );
      accountsDeleted = r.deleted;
      accountsKept.addAll(r.kept);
    } catch (e) {
      failures.add('Sign-in accounts: $e');
      accountsStageFailed = true;
      accountsDeleted = removed.length;
    }

    // ------------------------------------------------ profiles
    //
    // Two steps, because a profile must never outlive its login. With
    // Firebase's email enumeration protection on (the default for new
    // projects), a later run can't tell "login already deleted" from
    // "password changed", and would report those logins as surviving.
    //
    //  1. Everyone whose login is already gone — always, even past a Stop.
    //  2. Everyone else — unless Stop was pressed, or the sign-in stage failed
    //     outright, in which case their profiles are kept so their logins
    //     stay traceable and running the reset again finishes the job.
    //
    // (Individual accounts that couldn't be removed are a different case —
    // they're reported by name, and their profiles do go in step 2.)
    var profilesDeleted = 0;
    final gone = {for (final u in removed) u.uid};
    final rest = targets.where((u) => !gone.contains(u.uid)).toList();
    final profileTotal = removed.length + rest.length;
    onProgress?.call(ResetStage.profiles, 0, profileTotal);
    try {
      profilesDeleted = await DataService.instance.deleteProfilesInBulk(
        users: removed,
        onProgress: (done, _) =>
            onProgress?.call(ResetStage.profiles, done, profileTotal),
      );
      if (accountsStageFailed || cancelled()) {
        stopped = true;
      } else {
        final base = profilesDeleted;
        final n = await DataService.instance.deleteProfilesInBulk(
          users: rest,
          onProgress: (done, _) =>
              onProgress?.call(ResetStage.profiles, base + done, profileTotal),
          isCancelled: isCancelled,
        );
        profilesDeleted += n;
        if (n < rest.length) stopped = true;
      }
    } catch (e) {
      failures.add('Student profiles: $e');
      stopped = true;
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

    // ------------------------------------------------ academic records
    //
    // The per-session enrollments that Academic Records and Student Overview
    // read. They live beside `users`, not on it, so deleting the profiles never
    // reached them.
    var enrollmentsDeleted = 0;
    if (!cancelled()) {
      onProgress?.call(ResetStage.enrollments, 0, 0);
      try {
        enrollmentsDeleted = await EnrollmentService.instance.deleteAll(
          collegeId,
        );
      } catch (e) {
        failures.add('Academic records: $e');
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
      accountsDeleted: accountsDeleted,
      accountsKept: accountsKept,
      profilesDeleted: profilesDeleted,
      feeRecordsDeleted: feeRecordsDeleted,
      finesDeleted: finesDeleted,
      requestsDeleted: requestsDeleted,
      enrollmentsDeleted: enrollmentsDeleted,
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
          '${outcome.accountsDeleted} sign-in account(s)'
          '${outcome.accountsKept.isEmpty ? '' : ' (${outcome.accountsKept.length} kept)'}, '
          '${outcome.feeRecordsDeleted} fee record(s), '
          '${outcome.finesDeleted} fine(s), '
          '${outcome.requestsDeleted} request(s), '
          '${outcome.enrollmentsDeleted} academic record(s), '
          '${outcome.bedsFreed} bed(s) freed'
          '${outcome.stoppedEarly ? ' (stopped early)' : ''}',
      targetLabel: 'All students',
    );

    return outcome;
  }

  /// Signs in as each of [users] on an isolated app and deletes the login.
  ///
  /// One provisioning app per lane, opened lazily and reused for every
  /// account that lane handles — opening one per account is what made bulk
  /// import crawl. Your own session is never touched.
  Future<({int deleted, List<String> kept})> _deleteSignInAccounts(
    List<AppUser> users, {
    void Function(AppUser user)? onRemoved,
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final apps = <int, FirebaseApp>{};
    try {
      return await removeSignInAccounts(
        users: users,
        onRemoved: onRemoved,
        onProgress: onProgress,
        isCancelled: isCancelled,
        remove: (user, lane) async {
          final app = apps[lane] ??= await AuthService.instance
              .openProvisioningApp();
          return AuthService.instance.deleteAuthAccount(
            email: user.email,
            candidatePasswords: DataService.derivedPasswordsFor(user),
            app: app,
          );
        },
      );
    } finally {
      for (final app in apps.values) {
        try {
          await AuthService.instance.closeProvisioningApp(app);
        } catch (_) {}
      }
    }
  }
}

/// How many sign-in deletions run at once. Each is a sign-in plus a delete
/// against Firebase Auth's public endpoint, which rate-limits per project;
/// [runPooled] drops to a single lane the first time it pushes back.
const int kAccountRemovalLanes = 4;

/// Waits before retrying a throttled account, longest last — the same ladder
/// as the Node tools' THROTTLE_BACKOFF_MS. A throttle is Firebase saying "slow
/// down", not "no", so the account is retried rather than written off.
const List<Duration> kAccountThrottleBackoff = [
  Duration(seconds: 3),
  Duration(seconds: 8),
  Duration(seconds: 20),
];

/// The pooling, retrying and tallying behind removing sign-in accounts, kept
/// apart from Firebase so it can be tested against a fake [remove].
///
/// [remove] deletes one user's login on the given lane. A throttled result
/// narrows the pool to one lane for good and is retried after each wait in
/// [backoff]; anything still not gone after that is reported in `kept` as
/// "Name: why". [sleep] is injectable so tests don't wait out real delays.
Future<({int deleted, List<String> kept})> removeSignInAccounts({
  required List<AppUser> users,
  required Future<AuthDeleteResult> Function(AppUser user, int lane) remove,
  int lanes = kAccountRemovalLanes,
  List<Duration> backoff = kAccountThrottleBackoff,
  Future<void> Function(Duration wait)? sleep,
  void Function(AppUser user)? onRemoved,
  void Function(int done, int total)? onProgress,
  bool Function()? isCancelled,
}) async {
  final pause = sleep ?? (d) => Future<void>.delayed(d);
  var done = 0;
  var deleted = 0;
  final kept = <String>[];

  await runPooled<AppUser>(
    items: users,
    lanes: lanes,
    isCancelled: isCancelled,
    task: (user, lane) async {
      var result = await remove(user, lane);
      var verdict = LaneVerdict.ok;
      for (final wait in backoff) {
        if (result != AuthDeleteResult.throttled) break;
        verdict = LaneVerdict.narrow;
        await pause(wait);
        result = await remove(user, lane);
      }

      if (result == AuthDeleteResult.deleted) {
        deleted++;
        onRemoved?.call(user);
      } else if (!result.isGone) {
        kept.add('${user.name}: ${result.explanation}');
      }
      onProgress?.call(++done, users.length);
      return verdict;
    },
  );

  return (deleted: deleted, kept: kept);
}
