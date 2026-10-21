import 'package:cloud_firestore/cloud_firestore.dart';
import '../core/hostel_codes.dart';

/// Typed wrapper around the `users/{uid}` document.
///
/// Using a model instead of `Map<String, dynamic>` everywhere means a typo in
/// a field name becomes a compile error rather than a silent `null` at runtime.
class AppUser {
  final String uid;
  final String name;
  final String email;
  final String collegeId;

  /// Document id inside `colleges/{collegeId}/roles`. Null = not yet assigned.
  final String? roleId;

  /// Denormalised human-readable role name, so lists render without an extra read.
  final String? roleName;

  final bool isSuperAdmin;
  final bool isActive;

  /// Lifecycle state, distinct from [isActive] (which is about login access).
  /// 'active' unless annual promotion has moved this student past their
  /// course's length, at which point it becomes 'graduated' and no further
  /// enrollment document gets created for them. Never null in practice —
  /// defaults to 'active' so every existing account reads correctly with no
  /// migration.
  final String status;

  /// Earned a single room by performing well in 2nd year, per the college's
  /// seating policy (see [CourseRule] / `requiredRoomCapacity` in
  /// enrollment_helpers.dart).
  ///
  /// Set once by staff after results come out and never auto-cleared — it's
  /// a permanent merit designation, not something re-evaluated every session.
  /// Only meaningful for a course whose [CourseSeating] is `meritSingle`; a
  /// course that is unconditionally shared or unconditionally single ignores
  /// this flag entirely — the policy function is what actually decides, this
  /// is just one of its inputs.
  final bool singleRoomEligible;

  final String? phone;
  final String? gender;
  final String? enrollmentNo;
  final DateTime? createdAt;

  // --- Optional profile detail ---
  //
  // None of this is asked for at account creation — you only need a name,
  // email and role to get someone in. These are filled in afterwards from the
  // user's detail screen, which is why every one of them is nullable.
  final String? course;
  final String? year;

  // --- Trade / Batch / Sem ---
  //
  // Separate from course/year: trade is a controlled list (see [kTrades]),
  // batch is the admission-year range ("2023-24"), and sem is numeric so the
  // fines dashboard can sort/bucket by it. course/year stay as free text for
  // whatever a given college already uses them for.
  final String? trade;
  final String? batch;
  final int? sem;

  /// Home state, canonicalised against [kIndianStates].
  ///
  /// Kept as its own field rather than parsed out of [address] on demand,
  /// because the dashboard groups by it — and "UP" and "Uttar Pradesh" typed
  /// into a free-text address would chart as two different places.
  final String? state;

  /// Where a staff member sits — "Admin Block, Room 12".
  ///
  /// Deliberately plain text and separate from the [roomId] allotment fields:
  /// an office is not a bed. It has no occupancy limit, no gender rule and no
  /// transaction, so putting it through the allotment machinery would mean
  /// inventing a fake hostel to hold offices in.
  final String? officeRoom;

  final String? dateOfBirth;
  final String? bloodGroup;
  final String? address;
  final String? guardianName;
  final String? guardianPhone;
  final String? guardianRelation;
  final String? notes;

  // --- Additional profile detail (from bulk import) ---
  final String? category;
  final String? religion;
  final String? admissionYear;
  final String? motherName;
  final String? permanentMobile;
  final String? section;
  final String? city;
  final String? pinCode;

  // --- Room allotment (denormalised from the room document) ---
  //
  // The room also stores this student's uid in `occupantUids`. Both sides are
  // written inside one transaction, so they can't disagree. The duplication
  // buys the student's "My Room" page a single document read instead of a
  // collection-group query across every room in the institution.
  final String? hostelId;
  final String? hostelName;
  final String? roomId;
  final String? roomNumber;
  final DateTime? allottedAt;

  /// Hostels this staff member is responsible for — set instead of the
  /// student academic fields for a role that manages hostels (Chief Warden,
  /// Warden, Caretaker, BHS, or any custom role with the same permissions).
  /// See [Perm.managesHostels]. Empty for residents and for staff who
  /// haven't been assigned one yet.
  final List<String> managedHostelIds;

  /// When the ID photo was last set, or null when there isn't one.
  ///
  /// The photo itself lives in `colleges/{collegeId}/photos/{uid}`, never on
  /// this document — every roster stream reads every user doc, and ~40 KB
  /// each would make the full roster tens of megabytes. This stamp is what
  /// lets a screen skip the photo read for someone who has none, and doubles
  /// as the cache key so a replaced photo is fetched fresh.
  final DateTime? photoUpdatedAt;

  /// Whether this person can sign in. False for students added by the bulk
  /// importer, which writes the record only — the college runs this app for
  /// staff, and a thousand sign-in accounts would only be throttled into
  /// existence for nobody to use. A Super Admin turns one into a login later
  /// from the student's record (see `LoginAccountService`).
  ///
  /// Absent on every document written before this existed, all of which were
  /// created alongside a real account — hence the default of true.
  final bool hasLogin;

  /// Set while "Create login account" is part-way through: the sign-in account
  /// exists under this uid, but the record has not finished moving to it.
  /// Running it again resumes from here rather than making a second account.
  final String? pendingLoginUid;

  const AppUser({
    required this.uid,
    required this.name,
    required this.email,
    required this.collegeId,
    this.roleId,
    this.roleName,
    this.isSuperAdmin = false,
    this.isActive = true,
    this.status = 'active',
    this.singleRoomEligible = false,
    this.phone,
    this.gender,
    this.enrollmentNo,
    this.createdAt,
    this.course,
    this.year,
    this.trade,
    this.batch,
    this.sem,
    this.state,
    this.officeRoom,
    this.dateOfBirth,
    this.bloodGroup,
    this.address,
    this.guardianName,
    this.guardianPhone,
    this.guardianRelation,
    this.notes,
    this.category,
    this.religion,
    this.admissionYear,
    this.motherName,
    this.permanentMobile,
    this.section,
    this.city,
    this.pinCode,
    this.hostelId,
    this.hostelName,
    this.roomId,
    this.roomNumber,
    this.allottedAt,
    this.managedHostelIds = const [],
    this.photoUpdatedAt,
    this.hasLogin = true,
    this.pendingLoginUid,
  });

  factory AppUser.fromMap(String uid, Map<String, dynamic> m) {
    return AppUser(
      uid: uid,
      name: (m['name'] as String?)?.trim().isNotEmpty == true
          ? m['name'] as String
          : 'Unnamed',
      email: m['email'] as String? ?? '',
      collegeId: m['collegeId'] as String? ?? '',
      roleId: m['roleId'] as String?,
      roleName: m['roleName'] as String?,
      isSuperAdmin: m['isSuperAdmin'] as bool? ?? false,
      isActive: m['isActive'] as bool? ?? true,
      status: m['status'] as String? ?? 'active',
      singleRoomEligible: m['singleRoomEligible'] as bool? ?? false,
      phone: m['phone'] as String?,
      gender: m['gender'] as String?,
      enrollmentNo: m['enrollmentNo'] as String?,
      createdAt: (m['createdAt'] as Timestamp?)?.toDate(),
      course: m['course'] as String?,
      year: m['year'] as String?,
      trade: m['trade'] as String?,
      batch: m['batch'] as String?,
      sem: (m['sem'] as num?)?.toInt(),
      state: m['state'] as String?,
      officeRoom: m['officeRoom'] as String?,
      dateOfBirth: m['dateOfBirth'] as String?,
      bloodGroup: m['bloodGroup'] as String?,
      address: m['address'] as String?,
      guardianName: m['guardianName'] as String?,
      guardianPhone: m['guardianPhone'] as String?,
      guardianRelation: m['guardianRelation'] as String?,
      notes: m['notes'] as String?,
      category: m['category'] as String?,
      religion: m['religion'] as String?,
      admissionYear: m['admissionYear'] as String?,
      motherName: m['motherName'] as String?,
      permanentMobile: m['permanentMobile'] as String?,
      section: m['section'] as String?,
      city: m['city'] as String?,
      pinCode: m['pinCode'] as String?,
      hostelId: m['hostelId'] as String?,
      hostelName: m['hostelName'] as String?,
      roomId: m['roomId'] as String?,
      roomNumber: m['roomNumber'] as String?,
      allottedAt: (m['allottedAt'] as Timestamp?)?.toDate(),
      managedHostelIds: ((m['managedHostelIds'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(),
      photoUpdatedAt: (m['photoUpdatedAt'] as Timestamp?)?.toDate(),
      hasLogin: m['hasLogin'] as bool? ?? true,
      pendingLoginUid: m['pendingLoginUid'] as String?,
    );
  }

  Map<String, dynamic> toMap() => {
    'uid': uid,
    'name': name,
    'email': email,
    'collegeId': collegeId,
    'roleId': roleId,
    'roleName': roleName,
    'isSuperAdmin': isSuperAdmin,
    'isActive': isActive,
    'status': status,
    'singleRoomEligible': singleRoomEligible,
    'phone': phone,
    'gender': gender,
    'enrollmentNo': enrollmentNo,
    'course': course,
    'year': year,
    'trade': trade,
    'batch': batch,
    'sem': sem,
    'state': state,
    'officeRoom': officeRoom,
    'dateOfBirth': dateOfBirth,
    'bloodGroup': bloodGroup,
    'address': address,
    'guardianName': guardianName,
    'guardianPhone': guardianPhone,
    'guardianRelation': guardianRelation,
    'notes': notes,
    'category': category,
    'religion': religion,
    'admissionYear': admissionYear,
    'motherName': motherName,
    'permanentMobile': permanentMobile,
    'section': section,
    'city': city,
    'pinCode': pinCode,
    'hostelId': hostelId,
    'hostelName': hostelName,
    'roomId': roomId,
    'roomNumber': roomNumber,
    'managedHostelIds': managedHostelIds,
  };

  String get initials {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }

  String get displayRole =>
      isSuperAdmin ? 'Super Admin' : (roleName ?? 'Unassigned');

  bool get isAllotted => roomId != null && hostelId != null;

  bool get hasPhoto => photoUpdatedAt != null;

  /// True once annual promotion has moved this student past their course's
  /// length. A graduated student is not deleted or deactivated — they simply
  /// stop being included in the next session's enrollment roster.
  bool get isGraduated => status == 'graduated';

  /// "Block A · Room 101", or null when not allotted.
  String? get roomLabel => isAllotted
      ? '${HostelCodes.of(hostelName, id: hostelId)} · Room $roomNumber'
      : null;

  /// The hostel as staff refer to it — its code, e.g. "BH-3".
  String? get hostelLabel => HostelCodes.of(hostelName, id: hostelId);
}

/// Trade/branch codes a workspace starts with, taken from SLIET's own
/// programme listings (academic.sliet.ac.in).
///
/// This is only the **starting point**. A college edits its own list under
/// System Settings, which is stored on the settings document and read through
/// `CollegeSettings.tradeCodes` — that is what every dropdown in the app
/// actually shows. These defaults exist so a brand-new workspace isn't
/// staring at an empty dropdown, and so an install that never opens the
/// settings screen still behaves sensibly.
///
/// Grouped by level: D* = Diploma (ICD), G* = B.E., PG* = postgraduate. An
/// unrecognised code isn't rejected on import — it is saved as typed and
/// flagged, because a sheet inventing a code is far more likely than a
/// student not existing.
const List<String> kTrades = [
  // Diploma (ICD)
  'DCE',
  'DCE-CBM',
  'DME',
  'DME-CAC',
  'DME-CAF',
  'DME-CFF',
  'DME-CTD',
  'DME-CWG',
  'DEE',
  'DEE-CEN',
  'DIN',
  'DIN-CIM',
  'DIN-CSMM',
  'DEC',
  'DEC-CSME',
  'DEC-CTC',
  'DEC-CTV',
  'DCS',
  'DCS-CDE',
  'DCT',
  'DCT-CPT',
  'DFT',
  'DFT-CFP',
  // B.E.
  'GCS',
  'GME',
  'GCT',
  'GEE',
  'GEC',
  'GFT',
  'GIN',
  'GCE',
  'GAI',
  // M.Tech
  'PGCE',
  'PGCSE',
  'PGICE',
  'PGECE',
  'PGFET',
  'PGMSE',
  'PGWLF',
  'PGVLSI',
  // M.Sc
  'PGPHY',
  'PGCHY',
  'PGMATH',
  // MBA
  'MBA',
];

/// Human-readable names for [kTrades], shown beside the code so nobody has to
/// remember that "GIN" is Instrumentation & Control.
///
/// Only covers the built-in codes — a college-invented code simply shows as
/// itself, which is the honest thing to do rather than inventing a label.
const Map<String, String> kTradeNames = {
  'DCE': 'Civil Technology',
  'DME': 'Mechanical Technology',
  'DEE': 'Electrical Engineering',
  'DIN': 'Instrumentation & Control Engineering',
  'DEC': 'Electronics & Communication Engineering',
  'DCS': 'Computer Science & Engineering',
  'DCT': 'Chemical Technology',
  'DFT': 'Food Technology',
  'GCS': 'Computer Science & Engineering',
  'GME': 'Mechanical Engineering',
  'GCT': 'Chemical Engineering',
  'GEE': 'Electrical Engineering',
  'GEC': 'Electronics & Communication Engineering',
  'GFT': 'Food Technology',
  'GIN': 'Instrumentation & Control Engineering',
  'GCE': 'Civil Engineering',
  'GAI': 'Artificial Intelligence & Data Science',
  'PGCE': 'M.Tech Chemical Engineering',
  'PGCSE': 'M.Tech Computer Science & Engineering',
  'PGICE': 'M.Tech Instrumentation & Control Engineering',
  'PGECE': 'M.Tech Electronics & Communication Engineering',
  'PGFET': 'M.Tech Food Engineering & Technology',
  'PGMSE': 'M.Tech Manufacturing Systems Engineering',
  'PGWLF': 'M.Tech Welding & Sheet Metal Engineering',
  'PGVLSI': 'M.Tech VLSI Design',
  'PGPHY': 'M.Sc Physics',
  'PGCHY': 'M.Sc Chemistry',
  'PGMATH': 'M.Sc Mathematics',
  'MBA': 'Master of Business Administration',
};

/// "GIN — Instrumentation & Control Engineering", or just the code when it
/// isn't one of the built-ins.
String tradeLabel(String code) {
  final name = kTradeNames[code];
  return name == null ? code : '$code — $name';
}

/// What this institute's course codes stand for, so the Course filter reads
/// "UG — Graduation" rather than leaving staff to decode "UG". Same idea as
/// [kTradeNames]: a course a college adds under Settings shows as itself.
const Map<String, String> kCourseNames = {
  'ICD': 'Diploma',
  'UG': 'Graduation',
  'PG': 'Post-graduation',
};

/// "UG — Graduation", or just the course when it isn't one of the above.
String courseLabel(String course) {
  final name = kCourseNames[course.toUpperCase()];
  return name == null ? course : '$course — $name';
}

/// The course that takes lateral-entry (LEET) students — diploma holders
/// admitted straight into 2nd year of graduation.
const String kLateralEntryCourse = 'UG';

const String kEntryRegular = 'Regular';
const String kEntryLeet = 'LEET';

/// True when [course] is the one LEET applies to, however it's cased.
bool hasLateralEntry(String? course) =>
    course?.trim().toUpperCase() == kLateralEntryCourse;

/// [kEntryLeet] or [kEntryRegular] for a graduation student; null for any
/// other course, or when the sheet didn't give both years.
///
/// Worked out, not stored: no sheet has a LEET column. A LEET student is
/// counted in the batch they'd have started 1st year with, but admitted a
/// year later — batch "2024-25", admissionYear "2025-26". In the source sheet
/// this agrees with the registration number's own LEET marker on every
/// student that carries one (617 of 617), and there are no 1st-year LEET
/// students, as there shouldn't be.
String? entryTypeOf(AppUser u) {
  if (!hasLateralEntry(u.course)) return null;
  int? start(String? span) =>
      int.tryParse((span ?? '').trim().split('-').first);
  final batch = start(u.batch);
  final admitted = start(u.admissionYear);
  if (batch == null || admitted == null) return null;
  return admitted > batch ? kEntryLeet : kEntryRegular;
}

/// Religions the Student Overview filter always offers, whether or not
/// anyone currently on the roll records them. Values found on students that
/// aren't in this list are still offered alongside — see [religionLabel].
const List<String> kReligions = [
  'Hindu',
  'Muslim',
  'Sikh',
  'Christian',
  'Buddhist',
  'Jain',
  'Parsi',
  'Jewish',
  'Other',
];

/// [raw] as the filter should show it: matched to [kReligions] ignoring case
/// and spacing, so "hindu" and "HINDU " from different import sheets land in
/// one bucket; otherwise trimmed as typed. Null when nothing was recorded.
String? religionLabel(String? raw) {
  final v = raw?.trim() ?? '';
  if (v.isEmpty) return null;
  // The import sheets say "Others"; the list says "Other". One bucket.
  if (v.toLowerCase() == 'others') return 'Other';
  for (final r in kReligions) {
    if (r.toLowerCase() == v.toLowerCase()) return r;
  }
  return v;
}

/// Admission categories the Student Overview filter always offers. Anything
/// else a sheet records ("Minority") is still offered alongside — see
/// [categoryLabel].
const List<String> kCategories = ['General', 'OBC', 'SC', 'ST', 'EWS'];

/// Other ways the sheets write the same category.
const Map<String, String> _categoryAliases = {
  'gen': 'General',
  'gn': 'General',
  'ur': 'General',
  'unreserved': 'General',
  'obcncl': 'OBC',
};

/// [raw] as the filter should show it: matched to [kCategories] ignoring
/// case and punctuation, so the import's "GENERAL" and a hand-typed
/// "General" are one bucket; otherwise trimmed as typed. Null when nothing
/// was recorded.
String? categoryLabel(String? raw) {
  final v = raw?.trim() ?? '';
  if (v.isEmpty) return null;
  final key = v.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  for (final c in kCategories) {
    if (c.toLowerCase() == key) return c;
  }
  return _categoryAliases[key] ?? v;
}

/// The eight ABO/Rh groups, in the order the profile form lists them.
const List<String> kBloodGroups = [
  'A+',
  'A-',
  'B+',
  'B-',
  'O+',
  'O-',
  'AB+',
  'AB-',
];

/// [raw] as the filter and the profile form should show it.
///
/// Only fixes what is unambiguous: case ("b+"), spacing, "+ve"/"positive",
/// and a zero typed for the letter O ("0+"), since no blood group is called
/// zero. Anything else is kept as typed — a bare "B" has no Rh factor
/// recorded, and "O=" could be a slip for either "O+" or "O-", which on a
/// blood group is not a guess worth making. Those show as their own filter
/// option so someone can find and correct them. Null when nothing was
/// recorded.
String? bloodGroupLabel(String? raw) {
  final typed = raw?.trim() ?? '';
  if (typed.isEmpty) return null;
  var v = typed.toUpperCase().replaceAll(RegExp(r'\s+'), '');
  v = v
      .replaceAll('POSITIVE', '+')
      .replaceAll('NEGATIVE', '-')
      .replaceAll(RegExp(r'[−–]'), '-')
      .replaceAllMapped(RegExp(r'([+-])VE$'), (m) => m[1]!);
  if (v.startsWith('0')) v = 'O${v.substring(1)}';
  if (kBloodGroups.contains(v)) return v;
  if (const ['A', 'B', 'AB', 'O'].contains(v)) return v;
  return typed;
}

/// States and union territories, as the dashboard should label them.
const List<String> kIndianStates = [
  'Andhra Pradesh',
  'Arunachal Pradesh',
  'Assam',
  'Bihar',
  'Chhattisgarh',
  'Delhi',
  'Goa',
  'Gujarat',
  'Haryana',
  'Himachal Pradesh',
  'Jammu and Kashmir',
  'Jharkhand',
  'Karnataka',
  'Kerala',
  'Ladakh',
  'Madhya Pradesh',
  'Maharashtra',
  'Manipur',
  'Meghalaya',
  'Mizoram',
  'Nagaland',
  'Odisha',
  'Puducherry',
  'Punjab',
  'Rajasthan',
  'Sikkim',
  'Tamil Nadu',
  'Telangana',
  'Tripura',
  'Uttar Pradesh',
  'Uttarakhand',
  'West Bengal',
  'Andaman and Nicobar Islands',
  'Chandigarh',
  'Dadra and Nagar Haveli and Daman and Diu',
  'Lakshadweep',
];

/// What people actually type. Without this, "UP" and "Uttar Pradesh" become
/// two separate bars on the by-state chart and the totals stop meaning
/// anything.
const Map<String, String> _stateAliases = {
  'up': 'Uttar Pradesh',
  'uttarpradesh': 'Uttar Pradesh',
  'mp': 'Madhya Pradesh',
  'madhyapradesh': 'Madhya Pradesh',
  'hp': 'Himachal Pradesh',
  'himachal': 'Himachal Pradesh',
  'ap': 'Andhra Pradesh',
  'tn': 'Tamil Nadu',
  'tamilnadu': 'Tamil Nadu',
  'wb': 'West Bengal',
  'westbengal': 'West Bengal',
  'jk': 'Jammu and Kashmir',
  'jandk': 'Jammu and Kashmir',
  'jammukashmir': 'Jammu and Kashmir',
  'uk': 'Uttarakhand',
  'ua': 'Uttarakhand',
  'uttaranchal': 'Uttarakhand',
  'orissa': 'Odisha',
  'pondicherry': 'Puducherry',
  'newdelhi': 'Delhi',
  'nct': 'Delhi',
  'chattisgarh': 'Chhattisgarh',
  'pb': 'Punjab',
  'hr': 'Haryana',
  'br': 'Bihar',
  'jh': 'Jharkhand',
  'rj': 'Rajasthan',
  'mh': 'Maharashtra',
  'ka': 'Karnataka',
  'kl': 'Kerala',
  'gj': 'Gujarat',
  'ts': 'Telangana',
  'ch': 'Chandigarh',
};

String _stateKey(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');

/// Canonicalises a state name someone typed. Returns null if it isn't one.
String? normaliseState(String? raw) {
  final v = raw?.trim() ?? '';
  if (v.isEmpty) return null;
  final key = _stateKey(v);
  if (key.isEmpty) return null;

  for (final s in kIndianStates) {
    if (_stateKey(s) == key) return s;
  }
  return _stateAliases[key];
}

/// Pulls the state out of a free-text address.
///
/// Addresses in the college sheets are "City, State" — so the last
/// comma-separated part is the candidate. Falls back to scanning every
/// segment, because a three-part address ("Village, District, Punjab") is
/// just as common. Returns null rather than guessing when nothing matches, so
/// the chart shows an honest "Not set" bucket instead of an invented state.
String? stateFromAddress(String? address) {
  final v = address?.trim() ?? '';
  if (v.isEmpty) return null;

  final parts = v.split(',').map((p) => p.trim()).where((p) => p.isNotEmpty);
  for (final part in parts.toList().reversed) {
    final hit = normaliseState(part);
    if (hit != null) return hit;
  }
  return null;
}

/// Turns a registration number into the admission batch it belongs to.
///
/// SLIET registration numbers start with the two-digit admission year —
/// `2110910` was admitted in 2021, so their batch is "2021-22". Deriving it
/// means the batch column is optional on an import: a sheet that only has
/// registration numbers still populates the dashboard's batch breakdown.
String? batchFromRegistrationNo(String? regNo) {
  final v = regNo?.trim() ?? '';
  if (v.length < 2) return null;
  final yy = int.tryParse(v.substring(0, 2));
  if (yy == null || yy < 0 || yy > 99) return null;
  final start = 2000 + yy;
  // Guard against a stray number producing a batch decades away.
  final thisYear = DateTime.now().year;
  if (start < 2000 || start > thisYear + 1) return null;
  return '$start-${(start + 1) % 100 == 0 ? '00' : ((start + 1) % 100).toString().padLeft(2, '0')}';
}
