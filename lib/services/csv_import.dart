import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../core/identity.dart';
import '../models/app_role.dart';
import '../models/app_user.dart';
import '../models/hostel.dart';
import 'allotment_service.dart';
import 'auth_service.dart';
import 'data_service.dart';
import 'hostel_service.dart';

/// Bulk import of people from a spreadsheet.
///
/// Dependency-free on purpose: the table is parsed by hand and the data
/// arrives by pasting from Excel rather than through a file picker, so the
/// feature can't break on a package version bump.

// =====================================================================
// Template
// =====================================================================

const List<String> kImportColumns = [
  'name',
  'registrationNo',
  'email',
  'role',
  'gender',
  'phone',
  'course',
  'year',
  'trade',
  'batch',
  'sem',
  'state',
  'hostel',
  'room',
  'dateOfBirth',
  'bloodGroup',
  'address',
  'guardianName',
  'guardianRelation',
  'guardianPhone',
  'notes',
  'category',
  'religion',
  'admissionYear',
  'motherName',
  'permanentMobile',
  'section',
  'city',
  'pinCode',
];

/// A row needs a name, and *some* way to log in — either a registration
/// number or a real email address.
const Set<String> kRequiredColumns = {'name'};

String templateHeaderRow({String delimiter = ','}) =>
    kImportColumns.join(delimiter);

/// One example row, in the same column order as [kImportColumns].
///
/// Split one field per line rather than run together: the previous version
/// was two commas short, so every value from `state` onwards sat under the
/// wrong header — the template itself taught people the wrong shape.
String templateWithExample() =>
    '${kImportColumns.join(',')}\n'
    '${[
      'Aarav Sharma', // name
      '2040353', // registrationNo
      '', // email
      'Student', // role
      'Male', // gender
      '9876543210', // phone
      'B.Tech', // course
      '2nd', // year
      'GCS', // trade
      '2023-24', // batch
      '3', // sem
      'Punjab', // state
      'BH-01', // hostel
      '101', // room
      '14/03/2004', // dateOfBirth
      'O+', // bloodGroup
      '"Ludhiana, Punjab"', // address
      'Rajesh Sharma', // guardianName
      'Father', // guardianRelation
      '9812345678', // guardianPhone
      '', // notes
      'GENERAL', // category
      'Hindu', // religion
      '2023-24', // admissionYear
      'Sunita Sharma', // motherName
      '9876500000', // permanentMobile
      'Sec-A', // section
      'Ludhiana', // city
      '141001', // pinCode
    ].join(',')}';

// =====================================================================
// Parsing
// =====================================================================

class DelimitedTable {
  final List<String> headers;
  final List<List<String>> rows;
  final String delimiter;

  const DelimitedTable({
    required this.headers,
    required this.rows,
    required this.delimiter,
  });

  bool get isEmpty => rows.isEmpty;
}

/// Handles comma files and tab-separated Excel clipboard data, plus quoted
/// fields containing commas or newlines — which any address column produces.
DelimitedTable parseDelimited(String raw) {
  var text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  if (text.startsWith('﻿')) text = text.substring(1);

  final firstLine = text.split('\n').first;
  final delimiter = firstLine.contains('\t') ? '\t' : ',';

  final records = <List<String>>[];
  var cell = StringBuffer();
  var record = <String>[];
  var inQuotes = false;

  for (var i = 0; i < text.length; i++) {
    final ch = text[i];

    if (inQuotes) {
      if (ch == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          cell.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        cell.write(ch);
      }
      continue;
    }

    if (ch == '"') {
      inQuotes = true;
    } else if (ch == delimiter) {
      record.add(cell.toString());
      cell = StringBuffer();
    } else if (ch == '\n') {
      record.add(cell.toString());
      cell = StringBuffer();
      records.add(record);
      record = <String>[];
    } else {
      cell.write(ch);
    }
  }
  if (cell.isNotEmpty || record.isNotEmpty) {
    record.add(cell.toString());
    records.add(record);
  }

  records.removeWhere((r) => r.every((c) => c.trim().isEmpty));
  if (records.isEmpty) {
    return DelimitedTable(headers: [], rows: [], delimiter: delimiter);
  }

  return DelimitedTable(
    headers: records.first.map(_normaliseHeader).toList(),
    rows: records.skip(1).toList(),
    delimiter: delimiter,
  );
}

/// Forgives case, spacing and the header names a real college sheet uses.
String _normaliseHeader(String raw) {
  final key = raw.trim().toLowerCase().replaceAll(RegExp(r'[\s_\-\.]'), '');
  const aliases = {
    'fullname': 'name',
    'studentname': 'name',
    'emailaddress': 'email',
    'emailid': 'email',
    'rollno': 'registrationNo',
    'rollnumber': 'registrationNo',
    'enrollment': 'registrationNo',
    'enrollmentno': 'registrationNo',
    'enrolmentno': 'registrationNo',
    'registrationno': 'registrationNo',
    'registrationnumber': 'registrationNo',
    'studentregistrationnumber': 'registrationNo',
    'mobile': 'phone',
    'phoneno': 'phone',
    'contact': 'phone',
    'contactno': 'phone',
    'studentscontactnumber': 'phone',
    'branch': 'trade',
    'programme': 'course',
    'semester': 'sem',
    'homestate': 'state',
    'domicile': 'state',
    'hostelnumber': 'hostel',
    'hostelname': 'hostel',
    'block': 'hostel',
    'roomno': 'room',
    'roomnumber': 'room',
    'hostelroomno': 'room',
    'dob': 'dateOfBirth',
    'dateofbirth': 'dateOfBirth',
    'blood': 'bloodGroup',
    'bloodgroup': 'bloodGroup',
    'fathername': 'guardianName',
    'guardian': 'guardianName',
    'guardianname': 'guardianName',
    'relation': 'guardianRelation',
    'guardianrelation': 'guardianRelation',
    'guardianphone': 'guardianPhone',
    'guardiancontact': 'guardianPhone',
    'permanentaddress': 'address',
    'remarks': 'notes',
  };
  if (aliases.containsKey(key)) return aliases[key]!;
  for (final col in kImportColumns) {
    if (col.toLowerCase() == key) return col;
  }
  return raw.trim();
}

// =====================================================================
// Analysis
// =====================================================================

enum RowAction { create, update, skip }

class ImportRow {
  final int lineNumber;
  final Map<String, String> values;
  final RowAction action;
  final List<String> problems;
  final List<String> warnings;
  final AppUser? existing;
  final AppRole? role;

  /// Resolved allotment target, when the row named a hostel and room.
  final Hostel? hostel;
  final String? roomNumber;

  const ImportRow({
    required this.lineNumber,
    required this.values,
    required this.action,
    this.problems = const [],
    this.warnings = const [],
    this.existing,
    this.role,
    this.hostel,
    this.roomNumber,
  });

  String get name => values['name'] ?? '';
  String get registrationNo => values['registrationNo'] ?? '';

  /// The address this row will authenticate with — the typed email if given,
  /// otherwise one synthesised from the registration number.
  String get authEmail {
    final e = values['email'];
    if (e != null && e.isNotEmpty) return e.toLowerCase();
    return Identity.toAuthEmail(registrationNo);
  }

  String get loginLabel => (values['email']?.isNotEmpty ?? false)
      ? values['email']!
      : registrationNo;

  bool get isValid => action != RowAction.skip;
  bool get wantsAllotment => hostel != null && roomNumber != null;
}

class ImportPlan {
  final List<ImportRow> rows;

  /// The sheet's own columns, in the order they appeared, after aliasing.
  ///
  /// Kept so the preview can lay the file out the way the user wrote it —
  /// including the columns the import ignores, which is usually how someone
  /// discovers a header this app never understood.
  final List<String> headers;

  final List<String> unknownColumns;
  final List<String> missingColumns;

  const ImportPlan({
    required this.rows,
    this.headers = const [],
    this.unknownColumns = const [],
    this.missingColumns = const [],
  });

  int get creates => rows.where((r) => r.action == RowAction.create).length;
  int get updates => rows.where((r) => r.action == RowAction.update).length;
  int get skips => rows.where((r) => r.action == RowAction.skip).length;
  int get allotments => rows.where((r) => r.isValid && r.wantsAllotment).length;
  int get hostelOnlyAllotments => rows
      .where((r) => r.isValid && r.hostel != null && r.roomNumber == null)
      .length;
  bool get canRun => creates + updates > 0 && missingColumns.isEmpty;
}

/// Works out what *would* happen without writing anything — the same function
/// the run uses, so the preview can't disagree with the outcome.
ImportPlan analyseImport({
  required DelimitedTable table,
  required List<AppUser> existingUsers,
  required List<AppRole> roles,
  required List<Hostel> hostels,
  required String defaultRoleName,

  /// The college's own trade list (see `CollegeSettings.tradeCodes`). A code
  /// outside it is still imported, just flagged — see below. Defaults to the
  /// built-ins so a caller that hasn't got settings to hand still works.
  List<String> knownTrades = kTrades,
}) {
  final known = kImportColumns.toSet();
  final unknown = table.headers.where((h) => !known.contains(h)).toList();
  final missing = kRequiredColumns
      .where((c) => !table.headers.contains(c))
      .toList();

  final hasLoginColumn =
      table.headers.contains('registrationNo') ||
      table.headers.contains('email');
  if (!hasLoginColumn) missing.add('registrationNo or email');

  if (missing.isNotEmpty) {
    return ImportPlan(
      rows: [],
      headers: table.headers,
      unknownColumns: unknown,
      missingColumns: missing,
    );
  }

  final byEmail = {for (final u in existingUsers) u.email.toLowerCase(): u};
  // Students are matched on their registration number first: a record-only
  // student has no sign-in account to anchor them, and the number is what the
  // college itself uses to tell students apart. Email still catches staff and
  // anyone whose sheet row has no number.
  final byRegNo = <String, AppUser>{
    for (final u in existingUsers)
      if ((u.enrollmentNo ?? '').trim().isNotEmpty)
        u.enrollmentNo!.trim().toLowerCase(): u,
  };
  final seen = <String>{};
  final result = <ImportRow>[];

  for (var i = 0; i < table.rows.length; i++) {
    final raw = table.rows[i];
    final values = <String, String>{};
    for (var c = 0; c < table.headers.length && c < raw.length; c++) {
      final v = raw[c].trim();
      if (v.isNotEmpty) values[table.headers[c]] = v;
    }

    final problems = <String>[];
    final warnings = <String>[];

    final name = values['name'] ?? '';
    if (name.length < 2) problems.add('Name is missing or too short');

    final reg = values['registrationNo'] ?? '';
    final email = values['email'] ?? '';
    if (reg.isEmpty && email.isEmpty) {
      problems.add('Needs a registration number or an email');
    }
    if (reg.isNotEmpty && !Identity.isValidRegistrationNumber(reg)) {
      problems.add('"$reg" isn\'t a usable registration number');
    }
    if (email.isNotEmpty &&
        !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      problems.add('"$email" is not a valid email');
    }

    final authEmail = email.isNotEmpty
        ? email.toLowerCase()
        : Identity.toAuthEmail(reg);
    if (seen.contains(authEmail)) {
      problems.add('Duplicate of an earlier row in this file');
    }
    seen.add(authEmail);

    // Gender: accept M/F shorthand, which is what college sheets contain.
    final rawGender = values['gender'];
    if (rawGender != null) {
      final g = _normaliseGender(rawGender);
      if (g == null) {
        problems.add('Gender "$rawGender" must be Male, Female, M, F or Other');
      } else {
        values['gender'] = g;
      }
    }

    // Trade: match the college's catalogue case-insensitively so "gcs" lands
    // on the same value the dropdown writes, otherwise the dashboard would
    // show two separate bars for the same programme.
    final rawTrade = values['trade'];
    if (rawTrade != null) {
      final match = knownTrades.firstWhere(
        (t) => t.toLowerCase() == rawTrade.trim().toLowerCase(),
        orElse: () => '',
      );
      if (match.isEmpty) {
        warnings.add(
          'Trade "$rawTrade" isn\'t in your trade list — saved as typed. '
          'Add it under System Settings to have it appear in dropdowns.',
        );
      } else {
        values['trade'] = match;
      }
    }

    final rawSem = values['sem'];
    if (rawSem != null && parseSem(rawSem) == null) {
      warnings.add('Semester "$rawSem" isn\'t a usable number — skipped');
    }

    final rawState = values['state'];
    if (rawState != null && normaliseState(rawState) == null) {
      warnings.add(
        'State "$rawState" isn\'t recognised — will try the address',
      );
    }

    // Resolve the role by name. An unrecognised name is NOT fatal — we fall
    // back to the role chosen on the paste screen and warn. Killing all 30
    // rows because a sheet says "Student" and the workspace says "Students"
    // is a terrible trade.
    final assignable = roles.where((r) => !r.isSystem).toList();
    final wantedRole = values['role'] ?? defaultRoleName;

    AppRole? role;
    for (final r in assignable) {
      if (r.name.toLowerCase() == wantedRole.toLowerCase()) {
        role = r;
        break;
      }
    }
    if (role == null && assignable.isNotEmpty) {
      for (final r in assignable) {
        if (r.name.toLowerCase() == defaultRoleName.toLowerCase()) {
          role = r;
          break;
        }
      }
      role ??= assignable.first;
      warnings.add('No role called "$wantedRole" — using ${role.name} instead');
    }

    final existing =
        (reg.isEmpty ? null : byRegNo[reg.toLowerCase()]) ?? byEmail[authEmail];
    if (existing == null && role == null) {
      problems.add(
        'This workspace has no assignable roles. Create one under '
        'Roles & Permissions before importing.',
      );
    }
    if (existing != null && existing.isSuperAdmin) {
      problems.add(
        'That login belongs to the Super Admin and won\'t be touched',
      );
    }

    // Allotment target, if named.
    Hostel? hostel;
    String? room;
    final hostelName = values['hostel'];
    final roomNo = values['room'];
    if (hostelName != null) {
      for (final h in hostels) {
        if (h.name.toLowerCase() == hostelName.toLowerCase() ||
            h.code.toLowerCase() == hostelName.toLowerCase()) {
          hostel = h;
          break;
        }
      }
      if (hostel == null) {
        warnings.add('No hostel called "$hostelName" — allotment skipped');
      } else if (roomNo == null) {
        warnings.add(
          'Hostel given without a room — will be assigned to the hostel, '
          'no bed yet',
        );
      } else {
        room = roomNo;
      }
    } else if (roomNo != null) {
      warnings.add('Room given without a hostel — allotment skipped');
    }

    final action = problems.isNotEmpty
        ? RowAction.skip
        : (existing == null ? RowAction.create : RowAction.update);

    result.add(
      ImportRow(
        lineNumber: i + 2,
        values: values,
        action: action,
        problems: problems,
        warnings: warnings,
        existing: existing,
        role: role,
        hostel: hostel,
        roomNumber: room,
      ),
    );
  }

  return ImportPlan(
    rows: result,
    headers: table.headers,
    unknownColumns: unknown,
    missingColumns: missing,
  );
}

String? _normaliseGender(String raw) {
  final v = raw.trim().toLowerCase();
  if (v == 'm' || v == 'male') return 'Male';
  if (v == 'f' || v == 'female') return 'Female';
  if (v == 'o' || v == 'other') return 'Other';
  return null;
}

// =====================================================================
// Execution
// =====================================================================

/// Which part of an import is running, for the progress display. Each phase
/// counts its own students, so the numbers always mean "students".
enum ImportPhase {
  updating('Updating existing students'),
  accounts('Adding students'),
  hostels('Assigning hostels'),
  rooms('Allotting rooms');

  final String label;
  const ImportPhase(this.label);
}

class ImportOutcome {
  final int created;
  final int updated;
  final int allotted;

  /// Assigned to a hostel with no specific room — see
  /// [AllotmentService.assignHostelOnly].
  final int hostelOnly;
  final List<String> failures;
  final List<String> allotmentIssues;

  /// True when [isCancelled] stopped the run before every row was processed.
  final bool stoppedEarly;

  /// How many rows in the plan were never attempted because of that stop.
  final int remaining;

  const ImportOutcome(
    this.created,
    this.updated,
    this.allotted,
    this.hostelOnly,
    this.failures,
    this.allotmentIssues, {
    this.stoppedEarly = false,
    this.remaining = 0,
  });
}

/// How long one account creation may take before we give up on that row.
///
/// Every step here is a network call, and a call with no deadline is what turns
/// one bad row into an import that sits on "Importing…" forever. Generous
/// enough that a slow connection still succeeds; short enough that a wedged row
/// is reported rather than waited on.
const Duration kRowTimeout = Duration(seconds: 30);
const Duration kAllotTimeout = Duration(seconds: 20);

/// How many profile updates to run at once.
///
/// These are plain Firestore writes — no Auth involved, and nothing Firebase
/// rate limits at this scale. The phase is purely round-trip bound, so this
/// is the one number here that can be raised without thinking hard about it.
const int kUpdateConcurrency = 20;

/// How many new student records go in one batch commit. Firestore allows 500
/// writes per batch; this leaves headroom.
const int kCreateBatchSize = 400;

/// What one pooled task learned about whether the pool should stay wide.
enum LaneVerdict {
  /// Nothing pushed back; the pool may keep every lane it has.
  ok,

  /// The remote end is rate limiting. The pool drops to a single lane and
  /// stays there — see [runPooled].
  narrow,
}

/// Runs [task] over [items] on up to [lanes] concurrent workers, narrowing to
/// one worker for good the first time a task reports [LaneVerdict.narrow].
///
/// Lives apart from [runImport] because this — not the Firestore plumbing —
/// is the part with the interesting failure modes, and out here it can be
/// tested against a fake task instead of a live Firebase project.
///
/// Narrowing is **one-way on purpose.** A pool that widened again after a
/// quiet spell would rediscover the limit over and over, and the limit being
/// probed here is a project-wide Firebase Auth block that affects real
/// sign-ins, not a per-request retry. Once it answers, believe it.
///
/// Lanes are pulled from a shared cursor rather than given a slice each, so
/// one slow item can't leave a lane idle while another still has a queue.
/// `next++` needs no lock: Dart only switches tasks at an `await`, and there
/// isn't one between the read and the write.
Future<void> runPooled<T>({
  required List<T> items,
  required int lanes,
  required Future<LaneVerdict> Function(T item, int lane) task,
  bool Function()? isCancelled,
  void Function()? onStopped,
}) async {
  if (items.isEmpty || lanes <= 0) return;

  var next = 0;
  var narrowed = false;

  Future<void> worker(int id) async {
    while (true) {
      if (isCancelled?.call() ?? false) {
        onStopped?.call();
        return;
      }
      // Every lane but the first stands down once the far end has pushed
      // back, leaving exactly the one-at-a-time behaviour known to work.
      // Checked before claiming an item, so nothing is stranded.
      if (narrowed && id != 0) return;

      final i = next++;
      if (i >= items.length) return;

      if (await task(items[i], id) == LaneVerdict.narrow) narrowed = true;
    }
  }

  await Future.wait([for (var id = 0; id < lanes; id++) worker(id)]);
}

/// Runs the plan in phases rather than one row-at-a-time pass.
///
/// The pass this replaced was sequential end to end, which meant a 200-student
/// import paid full network latency 600+ times over. Splitting it works
/// because the three kinds of work have nothing in common but the row they
/// came from:
///
///  * **Updates** touch Firestore only. Nothing throttles them, so they run
///    in parallel waves of [kUpdateConcurrency].
///  * **Creates** are profile documents only — no sign-in accounts, so
///    nothing for Firebase to throttle. They go in batches of
///    [kCreateBatchSize]; a login is made later, per student, from their
///    record (see `LoginAccountService`).
///    A new student named against a hostel with no room gets the hostel in
///    that same create write, so most of a typical sheet needs nothing more.
///  * **Hostel-only for existing students** runs in parallel waves — no room,
///    so nothing to contend over.
///  * **Room allotment stays strictly sequential.** Two rows can name the same
///    room, and the shared room cache is what stops the phase re-reading a
///    hostel per student. The transaction would keep it correct either way;
///    running it in parallel would just trade correctness-by-design for
///    correctness-by-retry.
///
/// A failure on one row is recorded and the run continues — an import that
/// aborts halfway leaves you worse off than one that tells you which six rows
/// need attention.
///
/// [isCancelled] is polled between rows, never mid-write — a "Stop" click
/// takes effect once the rows already in flight finish, and never leaves one
/// half-imported. Re-running the same file afterwards is safe and picks up
/// where it left off, same as recovering from a failure: rows already created
/// are matched by email and updated, not duplicated.
Future<ImportOutcome> runImport({
  required ImportPlan plan,
  required String collegeId,
  required void Function(ImportPhase phase, int done, int total, String label)
  onProgress,
  bool Function()? isCancelled,
}) async {
  final work = plan.rows.where((r) => r.isValid).toList();
  final failures = <String>[];
  final allotIssues = <String>[];
  var created = 0, updated = 0, allotted = 0, hostelOnly = 0;
  var stoppedEarly = false;

  // Cache rooms per hostel so a 30-row import doesn't re-read the same
  // collection 30 times.
  final roomCache = <String, List<Room>>{};

  final creates = work.where((r) => r.action == RowAction.create).toList();
  final updates = work.where((r) => r.action != RowAction.create).toList();

  // A NEW student named against a hostel with no room gets that hostel in
  // the very write that creates their profile — no separate transaction
  // afterwards. That used to be a second, strictly one-at-a-time pass over
  // nearly every row of a typical sheet (496 of 530), and the slowest part of
  // the import. Safe because a brand-new student has no room to contend over
  // and no enrollment yet to sync; the gender rule is still applied.
  final hostelAtCreate = <ImportRow>{
    for (final r in creates)
      if (r.hostel != null &&
          r.roomNumber == null &&
          AllotmentService.genderAllows(r.hostel!.gender, r.values['gender']))
        r,
  };

  // What's left for after the accounts: rooms (careful, sequential), and
  // hostel-only for existing students (parallel — nothing to contend over).
  final roomWork = work.where((r) => r.wantsAllotment).toList();
  final hostelWork = work
      .where(
        (r) =>
            r.hostel != null &&
            r.roomNumber == null &&
            !hostelAtCreate.contains(r),
      )
      .toList();

  // Who each row ended up being, so the allotment phase doesn't have to
  // re-query for a uid the account phase was already handed.
  final resolved = <ImportRow, AppUser>{};

  bool cancelled() => isCancelled?.call() ?? false;

  // Progress counts STUDENTS, per phase — "Creating accounts · 156 of 530",
  // then "Allotting rooms · 12 of 34". It used to count units of work across
  // phases, so a 530-student sheet read "of 1060" and looked like a double
  // import.
  var studentsDone = 0;
  void studentDone(String label) {
    studentsDone++;
    onProgress(
      creates.isEmpty ? ImportPhase.updating : ImportPhase.accounts,
      studentsDone,
      work.length,
      label,
    );
  }

  void recordFailure(ImportRow row, Object e) {
    failures.add(
      e is TimeoutException
          ? 'Row ${row.lineNumber} (${row.loginLabel}): timed out after '
                '${kRowTimeout.inSeconds}s. Re-running the import is safe.'
          : 'Row ${row.lineNumber} (${row.loginLabel}): '
                '${AuthService.describeError(e)}',
    );
  }

  // ---- phase 1: updates, in parallel waves -------------------------------

  for (var i = 0; i < updates.length; i += kUpdateConcurrency) {
    if (cancelled()) {
      stoppedEarly = true;
      break;
    }
    final slice = updates.sublist(
      i,
      (i + kUpdateConcurrency).clamp(0, updates.length),
    );
    onProgress(
      ImportPhase.updating,
      studentsDone,
      work.length,
      slice.first.name,
    );

    await Future.wait(
      slice.map((row) async {
        try {
          await DataService.instance
              .updateUser(row.existing!.uid, {
                'name': row.values['name']!,
                if (row.values['phone'] != null) 'phone': row.values['phone'],
                if (row.values['gender'] != null)
                  'gender': row.values['gender'],
                if (row.registrationNo.isNotEmpty)
                  'enrollmentNo': row.registrationNo,
                ..._detailFields(row),
              })
              .timeout(kRowTimeout);
          resolved[row] = row.existing!;
          updated++;
        } catch (e) {
          recordFailure(row, e);
        }
      }),
    );

    // Counted after the wave commits, so the count never runs ahead of the
    // work.
    for (final row in slice) {
      studentDone(row.name);
    }
  }

  // ---- phase 2: new students, as records only, in batches ---------------
  //
  // No sign-in accounts. The college uses this app for staff; a student's
  // login is made later, one at a time, by a Super Admin from their record
  // (see LoginAccountService). That turns what was the throttled, minutes-long
  // part of an import into a handful of batch commits — a thousand students
  // is three of them.
  //
  // Each batch commits whole or not at all, so a failed batch reports its
  // rows and the next one still runs. Re-running the file afterwards matches
  // what did land by registration number, so nothing is duplicated.
  final users = FirebaseFirestore.instance.collection('users');
  for (var i = 0; i < creates.length; i += kCreateBatchSize) {
    if (cancelled()) {
      stoppedEarly = true;
      break;
    }
    final slice = creates.sublist(
      i,
      (i + kCreateBatchSize).clamp(0, creates.length),
    );
    onProgress(
      ImportPhase.accounts,
      studentsDone,
      work.length,
      slice.first.name,
    );

    final batch = FirebaseFirestore.instance.batch();
    final made = <ImportRow, AppUser>{};
    for (final row in slice) {
      final ref = users.doc();
      final profile = recordOnlyProfile(
        row,
        uid: ref.id,
        collegeId: collegeId,
        withHostel: hostelAtCreate.contains(row),
      );
      batch.set(ref, {...profile, 'createdAt': FieldValue.serverTimestamp()});
      made[row] = AppUser.fromMap(ref.id, profile);
    }

    try {
      await batch.commit().timeout(kRowTimeout);
      resolved.addAll(made);
      created += slice.length;
      hostelOnly += slice.where(hostelAtCreate.contains).length;
    } catch (e) {
      for (final row in slice) {
        recordFailure(row, e);
      }
    }
    for (final row in slice) {
      studentDone(row.name);
    }
  }

  // A row whose student wasn't named against a hostel they can live in is
  // reported here rather than silently dropped.
  for (final r in creates) {
    if (r.hostel != null &&
        r.roomNumber == null &&
        !hostelAtCreate.contains(r) &&
        resolved[r] != null) {
      allotIssues.add(
        'Row ${r.lineNumber}: '
        '${AllotmentService.genderRefusal(r.hostel!.gender, r.values['gender'])}',
      );
    }
  }

  // ---- phase 3: hostel-only for EXISTING students, in parallel waves ------
  //
  // Existing students go through assignHostelOnly — it also syncs their
  // current-session enrollment, which a plain write would miss. Nothing is
  // contended (no room, no capacity), so waves run side by side.
  final hostelRows = hostelWork.where((r) => resolved[r] != null).toList();
  var hostelDone = 0;
  for (var i = 0; i < hostelRows.length; i += kUpdateConcurrency) {
    if (cancelled()) {
      stoppedEarly = true;
      break;
    }
    final slice = hostelRows.sublist(
      i,
      (i + kUpdateConcurrency).clamp(0, hostelRows.length),
    );
    onProgress(
      ImportPhase.hostels,
      hostelDone,
      hostelRows.length,
      slice.first.name,
    );
    await Future.wait(
      slice.map((row) async {
        try {
          await AllotmentService.instance
              .assignHostelOnly(
                collegeId: collegeId,
                student: resolved[row]!,
                hostel: row.hostel!,
              )
              .timeout(kAllotTimeout);
          hostelOnly++;
        } catch (e) {
          allotIssues.add(
            'Row ${row.lineNumber}: '
            '${e is AllotmentFailure ? e.message : AuthService.describeError(e)}',
          );
        }
      }),
    );
    hostelDone += slice.length;
    onProgress(
      ImportPhase.hostels,
      hostelDone,
      hostelRows.length,
      slice.last.name,
    );
  }

  // ---- phase 4: rooms, strictly sequential -------------------------------
  //
  // Two rows can name the same room; the transaction keeps that correct, and
  // the shared room cache stops a re-read of the hostel per student.
  final roomRows = roomWork.where((r) => resolved[r] != null).toList();
  var roomDone = 0;
  for (final row in roomRows) {
    if (cancelled()) {
      stoppedEarly = true;
      break;
    }
    final person = resolved[row]!;
    onProgress(ImportPhase.rooms, roomDone, roomRows.length, row.name);

    try {
      final h = row.hostel!;
      final rooms = roomCache[h.id] ??= await HostelService.instance
          .roomsOnce(collegeId, h.id)
          .timeout(kAllotTimeout);
      Room? target;
      var targetIndex = -1;
      for (var i = 0; i < rooms.length; i++) {
        if (rooms[i].number == row.roomNumber) {
          target = rooms[i];
          targetIndex = i;
          break;
        }
      }
      if (target == null) {
        allotIssues.add(
          'Row ${row.lineNumber}: ${h.name} has no room ${row.roomNumber}',
        );
      } else if (person.isAllotted) {
        allotIssues.add(
          'Row ${row.lineNumber}: ${person.name} already has '
          '${person.roomLabel}',
        );
      } else {
        await AllotmentService.instance
            .allot(
              collegeId: collegeId,
              student: person,
              hostel: h,
              room: target,
            )
            .timeout(kAllotTimeout);
        allotted++;
        // Patch the cached room rather than dropping the whole hostel's
        // room list and re-reading it on the next student.
        rooms[targetIndex] = target.copyWith(
          occupantUids: [...target.occupantUids, person.uid],
        );
      }
    } catch (e) {
      allotIssues.add(
        'Row ${row.lineNumber}: '
        '${e is AllotmentFailure ? e.message : AuthService.describeError(e)}',
      );
    }
    roomDone++;
    onProgress(ImportPhase.rooms, roomDone, roomRows.length, row.name);
  }

  return ImportOutcome(
    created,
    updated,
    allotted,
    hostelOnly,
    failures,
    allotIssues,
    stoppedEarly: stoppedEarly,
    remaining: work.length - studentsDone,
  );
}

/// The profile document a new student gets from an import: everything on
/// their row, with no sign-in account behind it (`hasLogin: false`).
///
/// `email` is still filled in — the typed one, or the synthetic one built
/// from the registration number. Nobody signs in with it yet, but it is what
/// "Create login account" will make the login for, and what the roster shows.
Map<String, dynamic> recordOnlyProfile(
  ImportRow row, {
  required String uid,
  required String collegeId,
  bool withHostel = false,
}) {
  final profile = AppUser(
    uid: uid,
    name: row.values['name']!.trim(),
    email: row.authEmail,
    collegeId: collegeId,
    roleId: row.role!.id,
    roleName: row.role!.name,
    phone: row.values['phone'],
    gender: row.values['gender'],
    enrollmentNo: row.registrationNo.isEmpty ? null : row.registrationNo,
  );
  return {
    ...profile.toMap(),
    ..._detailFields(row),
    if (withHostel && row.hostel != null) ...{
      'hostelId': row.hostel!.id,
      'hostelName': row.hostel!.name,
    },
    'hasLogin': false,
  };
}

Map<String, dynamic> _detailFields(ImportRow row) {
  const keys = [
    'course',
    'year',
    'trade',
    'batch',
    'dateOfBirth',
    'bloodGroup',
    'address',
    'guardianName',
    'guardianRelation',
    'guardianPhone',
    'notes',
    'category',
    'religion',
    'admissionYear',
    'motherName',
    'permanentMobile',
    'section',
    'city',
    'pinCode',
  ];
  final out = <String, dynamic>{};
  for (final k in keys) {
    final v = row.values[k];
    if (v != null && v.isNotEmpty) out[k] = v;
  }
  // Sem is numeric so the fines dashboard can bucket by it.
  final sem = parseSem(row.values['sem']);
  if (sem != null) out['sem'] = sem;

  // Batch falls back to the admission year encoded in the registration
  // number, so a sheet without the column still fills the dashboard.
  if (out['batch'] == null) {
    final derived = batchFromRegistrationNo(row.registrationNo);
    if (derived != null) out['batch'] = derived;
  }

  // State is canonicalised, and derived from the address when the column is
  // absent — every college sheet already has "City, State" in the address,
  // so the by-state chart works without anyone re-typing anything.
  final state =
      normaliseState(row.values['state']) ??
      stateFromAddress(row.values['address']);
  if (state != null) out['state'] = state;

  return out;
}

/// Pulls a semester number out of whatever a college sheet actually contains.
/// Real files say "Sem 5", "5th", "V Sem" or just "5" — accepting only a bare
/// integer would silently drop the column on most of them.
int? parseSem(String? raw) {
  if (raw == null) return null;
  final digits = RegExp(r'\d+').firstMatch(raw);
  if (digits != null) {
    final n = int.tryParse(digits.group(0)!);
    return (n != null && n >= 1 && n <= 12) ? n : null;
  }
  // Roman numerals, which a few departments still use on their sheets.
  const roman = {
    'i': 1,
    'ii': 2,
    'iii': 3,
    'iv': 4,
    'v': 5,
    'vi': 6,
    'vii': 7,
    'viii': 8,
  };
  final key = raw.toLowerCase().replaceAll(RegExp(r'[^ivx]'), '');
  return roman[key];
}
