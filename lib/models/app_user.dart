import 'package:cloud_firestore/cloud_firestore.dart';

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
  /// 'active' unless promotion has moved this student past their course's
  /// length, at which point it becomes 'graduated' and no further enrollment
  /// document gets created for them. Never null in practice; defaults to
  /// 'active' so every existing account reads correctly with no migration.
  final String status;
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

  /// Earned a single room by performing well in 2nd year, per the college's
  /// seating policy (see [requiredRoomCapacity] in enrollment_helpers.dart).
  ///
  /// Set once by staff after results come out and never auto-cleared — it's
  /// a permanent merit designation, not something re-evaluated every session.
  /// Only meaningful for a B.E. student past 2nd year; a Diploma student or a
  /// B.E. student still in year 1/2 is unconditionally 3-Seater regardless of
  /// this flag, and M.Tech/M.Sc/PhD are unconditionally Single regardless of
  /// it too — the policy function is what actually decides, this is just one
  /// of its inputs.
  final bool singleRoomEligible;

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
    this.phone,
    this.gender,
    this.enrollmentNo,
    this.createdAt,
    this.course,
    this.year,
    this.trade,
    this.batch,
    this.sem,
    this.singleRoomEligible = false,
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
      phone: m['phone'] as String?,
      gender: m['gender'] as String?,
      enrollmentNo: m['enrollmentNo'] as String?,
      createdAt: (m['createdAt'] as Timestamp?)?.toDate(),
      course: m['course'] as String?,
      year: m['year'] as String?,
      trade: m['trade'] as String?,
      batch: m['batch'] as String?,
      sem: (m['sem'] as num?)?.toInt(),
      singleRoomEligible: m['singleRoomEligible'] as bool? ?? false,
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
    'phone': phone,
    'gender': gender,
    'enrollmentNo': enrollmentNo,
    'course': course,
    'year': year,
    'trade': trade,
    'batch': batch,
    'sem': sem,
    'singleRoomEligible': singleRoomEligible,
    'state': state,
    'officeRoom': officeRoom,
    'dateOfBirth': dateOfBirth,
    'bloodGroup': bloodGroup,
    'address': address,
    'guardianName': guardianName,
    'guardianPhone': guardianPhone,
    'guardianRelation': guardianRelation,
    'notes': notes,
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

  bool get isGraduated => status == 'graduated';

  /// "Block A · Room 101", or null when not allotted.
  String? get roomLabel =>
      isAllotted ? '$hostelName · Room $roomNumber' : null;
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

/// States and union territories, as the dashboard should label them.
const List<String> kIndianStates = [
  'Andhra Pradesh', 'Arunachal Pradesh', 'Assam', 'Bihar', 'Chhattisgarh',
  'Delhi', 'Goa', 'Gujarat', 'Haryana', 'Himachal Pradesh',
  'Jammu and Kashmir', 'Jharkhand', 'Karnataka', 'Kerala', 'Ladakh',
  'Madhya Pradesh', 'Maharashtra', 'Manipur', 'Meghalaya', 'Mizoram',
  'Nagaland', 'Odisha', 'Puducherry', 'Punjab', 'Rajasthan', 'Sikkim',
  'Tamil Nadu', 'Telangana', 'Tripura', 'Uttar Pradesh', 'Uttarakhand',
  'West Bengal', 'Andaman and Nicobar Islands', 'Chandigarh',
  'Dadra and Nagar Haveli and Daman and Diu', 'Lakshadweep',
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

String _stateKey(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');

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
