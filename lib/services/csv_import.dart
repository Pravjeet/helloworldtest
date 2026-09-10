import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';

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
  'officeRoom',
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
String templateWithExample() => '${kImportColumns.join(',')}\n'
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
      '', // officeRoom
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
    'office': 'officeRoom',
    'officeroom': 'officeRoom',
    'staffroom': 'officeRoom',
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

  String get loginLabel =>
      (values['email']?.isNotEmpty ?? false) ? values['email']! : registrationNo;

  bool get isValid => action != RowAction.skip;
  bool get wantsAllotment => hostel != null && roomNumber != null;
}

class ImportPlan {
  final List<ImportRow> rows;
  final List<String> unknownColumns;
  final List<String> missingColumns;

  /// The file's columns, normalised and **in the order they appeared**.
  ///
  /// [ImportRow.values] is a map, so it can say what a cell holds but not
  /// which column it sat in. The spreadsheet preview needs the original order
  /// to lay out its columns — that layout is the whole point of it, since a
  /// sheet one comma short puts every later value under the wrong header and
  /// a map keyed by header name would render it looking perfectly fine.
  final List<String> headers;

  const ImportPlan({
    required this.rows,
    this.unknownColumns = const [],
    this.missingColumns = const [],
    this.headers = const [],
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
      table.headers.contains('registrationNo') || table.headers.contains('email');
  if (!hasLoginColumn) missing.add('registrationNo or email');

  if (missing.isNotEmpty) {
    return ImportPlan(
      rows: [],
      unknownColumns: unknown,
      missingColumns: missing,
      headers: table.headers,
    );
  }

  final byEmail = {for (final u in existingUsers) u.email.toLowerCase(): u};
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
      warnings.add('State "$rawState" isn\'t recognised — will try the address');
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
      warnings.add(
        'No role called "$wantedRole" — using ${role.name} instead',
      );
    }

    final existing = byEmail[authEmail];
    if (existing == null && role == null) {
      problems.add(
        'This workspace has no assignable roles. Create one under '
        'Roles & Permissions before importing.',
      );
    }
    if (existing != null && existing.isSuperAdmin) {
      problems.add('That login belongs to the Super Admin and won\'t be touched');
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
    unknownColumns: unknown,
    missingColumns: missing,
    headers: table.headers,
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

/// Firebase throttles rapid account creation from a browser. When it does, the
/// row is not broken — it just needs a moment. Backing off and retrying
/// recovers rows that would otherwise be reported as failures.
const List<Duration> kThrottleBackoff = [
  Duration(seconds: 3),
  Duration(seconds: 8),
  Duration(seconds: 20),
];

bool _isThrottle(Object e) {
  final code = e is FirebaseAuthException ? e.code : '';
  if (code == 'too-many-requests') return true;
  final text = e.toString().toLowerCase();
  return text.contains('too-many-requests') ||
      text.contains('too many attempts') ||
      text.contains('quota');
}

/// Runs the plan. Account creation is sequential because Firebase throttles it
/// from a browser. A failure on one row is recorded and the run continues — an
/// import that aborts halfway leaves you worse off than one that tells you
/// which six rows need attention.
///
/// [isCancelled] is polled between rows, never mid-row — a "Stop" click takes
/// effect after whichever student is currently being written finishes, not
/// before. Re-running the same file afterwards is safe and picks up where it
/// left off, same as recovering from a failure: rows already created are
/// matched by email and updated, not duplicated.
Future<ImportOutcome> runImport({
  required ImportPlan plan,
  required String collegeId,
  required void Function(int done, int total, String label) onProgress,
  bool Function()? isCancelled,
}) async {
  final work = plan.rows.where((r) => r.isValid).toList();
  final failures = <String>[];
  final allotIssues = <String>[];
  var created = 0, updated = 0, allotted = 0, hostelOnly = 0, done = 0;
  var stoppedEarly = false;

  // Cache rooms per hostel so a 30-row import doesn't re-read the same
  // collection 30 times.
  final roomCache = <String, List<Room>>{};

  // ONE provisioning app for the whole run. Creating a FirebaseApp per row
  // was costing more than every other operation combined.
  final needsAccounts = work.any((r) => r.action == RowAction.create);
  FirebaseApp? provisioning;

  try {
    if (needsAccounts) {
      provisioning = await AuthService.instance.openProvisioningApp();
    }

    for (final row in work) {
      // Checked between rows only — never mid-write. Stopping never leaves a
      // row half-imported, only the ones after it un-attempted.
      if (isCancelled?.call() ?? false) {
        stoppedEarly = true;
        break;
      }

      // Report before the work, so the label moves the moment a row starts
      // rather than only once it finishes.
      onProgress(done, work.length, row.name);

      AppUser? person;
      try {
        if (row.action == RowAction.create) {
          // Detail fields ride along in the same document write — no second
          // round trip, and no re-query to find the uid we were just handed.
          // Retried on throttling only: a duplicate email or a bad password is
          // not going to fix itself by waiting.
          for (var attempt = 0; ; attempt++) {
            try {
              person = await AuthService.instance
                  .createSubUser(
                    name: row.values['name']!,
                    email: row.authEmail,
                    password: Identity.derivedPassword(
                      row.registrationNo.isNotEmpty
                          ? row.registrationNo
                          : row.authEmail,
                    ),
                    collegeId: collegeId,
                    roleId: row.role!.id,
                    roleName: row.role!.name,
                    phone: row.values['phone'],
                    gender: row.values['gender'],
                    enrollmentNo: row.registrationNo.isEmpty
                        ? null
                        : row.registrationNo,
                    extra: _detailFields(row),
                    app: provisioning,
                  )
                  .timeout(kRowTimeout);
              break;
            } catch (e) {
              if (attempt >= kThrottleBackoff.length || !_isThrottle(e)) {
                rethrow;
              }
              final wait = kThrottleBackoff[attempt];
              onProgress(
                done,
                work.length,
                'Firebase is throttling — waiting ${wait.inSeconds}s, then '
                'retrying ${row.name}',
              );
              await Future<void>.delayed(wait);
            }
          }
          created++;
        } else {
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
          person = row.existing;
          updated++;
        }
      } on TimeoutException {
        failures.add(
          'Row ${row.lineNumber} (${row.loginLabel}): timed out after '
          '${kRowTimeout.inSeconds}s. Re-running the import is safe.',
        );
        done++;
        onProgress(done, work.length, row.name);
        continue;
      } catch (e) {
        failures.add(
          'Row ${row.lineNumber} (${row.loginLabel}): '
          '${AuthService.describeError(e)}',
        );
        done++;
        onProgress(done, work.length, row.name);
        continue;
      }

      // --- allotment, best-effort: a room problem must not undo the account ---
      if (row.wantsAllotment && person != null) {
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
      } else if (row.hostel != null && row.roomNumber == null &&
          person != null) {
        // Hostel named but no room — record membership without a bed.
        try {
          await AllotmentService.instance
              .assignHostelOnly(
                collegeId: collegeId,
                student: person,
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
      }

      done++;
      onProgress(done, work.length, row.name);
    }
  } finally {
    if (provisioning != null) {
      await AuthService.instance.closeProvisioningApp(provisioning);
    }
  }

  return ImportOutcome(
    created,
    updated,
    allotted,
    hostelOnly,
    failures,
    allotIssues,
    stoppedEarly: stoppedEarly,
    remaining: work.length - done,
  );
}

Map<String, dynamic> _detailFields(ImportRow row) {
  const keys = [
    'course',
    'year',
    'trade',
    'batch',
    'officeRoom',
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
    'i': 1, 'ii': 2, 'iii': 3, 'iv': 4, 'v': 5, 'vi': 6,
    'vii': 7, 'viii': 8,
  };
  final key = raw.toLowerCase().replaceAll(RegExp(r'[^ivx]'), '');
  return roman[key];
}
