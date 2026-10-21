import 'package:cloud_firestore/cloud_firestore.dart';

import 'app_user.dart';
import 'enrollment.dart';

/// Who a hostel accommodates. Stored as the enum `name` string.
enum HostelGender { boys, girls, coed }

extension HostelGenderX on HostelGender {
  String get label => switch (this) {
    HostelGender.boys => 'Boys',
    HostelGender.girls => 'Girls',
    HostelGender.coed => 'Co-ed',
  };

  static HostelGender parse(String? v) => HostelGender.values.firstWhere(
    (e) => e.name == v,
    orElse: () => HostelGender.coed,
  );
}

/// Operational state of a single room.
enum RoomStatus { active, maintenance, reserved }

extension RoomStatusX on RoomStatus {
  String get label => switch (this) {
    RoomStatus.active => 'Active',
    RoomStatus.maintenance => 'Maintenance',
    RoomStatus.reserved => 'Reserved',
  };

  static RoomStatus parse(String? v) => RoomStatus.values.firstWhere(
    (e) => e.name == v,
    orElse: () => RoomStatus.active,
  );
}

/// Things provided at the *building* level.
const List<String> kHostelAmenities = [
  'WiFi',
  'Mess',
  'Common Room',
  'Laundry',
  'Gym',
  'Reading Room',
  'Water Cooler / RO',
  'Power Backup',
  'CCTV',
  'Security Guard',
  'Parking',
  'Medical Room',
  'Indoor Games',
  'Lift',
];

/// Things provided at the *room* level. These vary room to room, which is why
/// they're separate from the hostel list — an AC room and a non-AC room can
/// sit on the same floor.
const List<String> kRoomFeatures = [
  'AC',
  'Attached Bathroom',
  'Balcony',
  'Study Table',
  'Almirah / Wardrobe',
  'Ceiling Fan',
  'Geyser',
];

// =====================================================================
// Hostel
// =====================================================================

class Hostel {
  final String id;
  final String name;

  /// Short label used in room codes and tight UI, e.g. "A".
  final String code;

  final HostelGender gender;
  final int floors;
  final List<String> amenities;
  final String? wardenUid;
  final String? wardenName;
  final String? address;

  /// Denormalised counters, kept in step by [HostelService] whenever rooms
  /// are added or removed. Storing them avoids reading every room document
  /// just to render the hostel list.
  final int roomCount;
  final int bedCount;
  final int occupiedBeds;

  final DateTime? createdAt;

  const Hostel({
    required this.id,
    required this.name,
    required this.code,
    this.gender = HostelGender.coed,
    this.floors = 1,
    this.amenities = const [],
    this.wardenUid,
    this.wardenName,
    this.address,
    this.roomCount = 0,
    this.bedCount = 0,
    this.occupiedBeds = 0,
    this.createdAt,
  });

  factory Hostel.fromMap(String id, Map<String, dynamic> m) => Hostel(
    id: id,
    name: m['name'] as String? ?? 'Unnamed hostel',
    code: m['code'] as String? ?? '',
    gender: HostelGenderX.parse(m['gender'] as String?),
    floors: (m['floors'] as num?)?.toInt() ?? 1,
    amenities: ((m['amenities'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList(),
    wardenUid: m['wardenUid'] as String?,
    wardenName: m['wardenName'] as String?,
    address: m['address'] as String?,
    roomCount: (m['roomCount'] as num?)?.toInt() ?? 0,
    bedCount: (m['bedCount'] as num?)?.toInt() ?? 0,
    occupiedBeds: (m['occupiedBeds'] as num?)?.toInt() ?? 0,
    createdAt: (m['createdAt'] as Timestamp?)?.toDate(),
  );

  Map<String, dynamic> toMap() => {
    'name': name,
    'code': code,
    'gender': gender.name,
    'floors': floors,
    'amenities': amenities,
    'wardenUid': wardenUid,
    'wardenName': wardenName,
    'address': address,
    'roomCount': roomCount,
    'bedCount': bedCount,
    'occupiedBeds': occupiedBeds,
  };

  /// Orders hostels the way their codes read: BH-1, BH-2 … BH-9, BH-10.
  ///
  /// Plain string ordering puts BH-10 between BH-1 and BH-2, because it
  /// compares "1" then "0" against "2" character by character. This splits
  /// each code into runs of digits and non-digits and compares the digit runs
  /// numerically, so the list reads in building order rather than dictionary
  /// order.
  ///
  /// Sorted on [code] when there is one and [name] otherwise — the code is
  /// what the tiles show and what people say out loud ("BH-9", not "Meghraj
  /// Goyal House"). Codes are grouped before comparing numbers, so every BH
  /// sorts before every GH regardless of number.
  static int compareByCode(Hostel a, Hostel b) {
    final left = a.code.trim().isEmpty ? a.name : a.code;
    final right = b.code.trim().isEmpty ? b.name : b.code;
    return _naturalCompare(left.toLowerCase(), right.toLowerCase());
  }

  /// The same ordering for bare labels, where all a screen has is the text of
  /// a hostel code in a dropdown rather than the [Hostel] itself.
  static int compareLabels(String a, String b) =>
      _naturalCompare(a.toLowerCase(), b.toLowerCase());

  static final RegExp _chunks = RegExp(r'\d+|\D+');

  static int _naturalCompare(String a, String b) {
    final ax = _chunks.allMatches(a).map((m) => m[0]!).toList();
    final bx = _chunks.allMatches(b).map((m) => m[0]!).toList();

    for (var i = 0; i < ax.length && i < bx.length; i++) {
      final l = ax[i], r = bx[i];
      final ln = int.tryParse(l), rn = int.tryParse(r);

      // Two numbers compare as numbers; anything else compares as text. A
      // number against text falls through to text so the order stays total.
      final cmp = (ln != null && rn != null)
          ? ln.compareTo(rn)
          : l.compareTo(r);
      if (cmp != 0) return cmp;
    }
    return ax.length.compareTo(bx.length);
  }

  /// What the app shows for this hostel: its code ("BH-3"), which is what
  /// staff actually call it. The full name is an alias, kept for the Hostels
  /// & Rooms page and the editor. Falls back to the name only when no code
  /// has been set.
  String get label => code.trim().isEmpty ? name : code.trim();

  int get freeBeds => (bedCount - occupiedBeds).clamp(0, bedCount);

  /// 0.0 – 1.0. Guarded against divide-by-zero on a hostel with no rooms.
  double get occupancy => bedCount == 0 ? 0 : occupiedBeds / bedCount;

  Hostel copyWith({
    String? name,
    String? code,
    HostelGender? gender,
    int? floors,
    List<String>? amenities,
    String? wardenUid,
    String? wardenName,
    String? address,
  }) => Hostel(
    id: id,
    name: name ?? this.name,
    code: code ?? this.code,
    gender: gender ?? this.gender,
    floors: floors ?? this.floors,
    amenities: amenities ?? this.amenities,
    wardenUid: wardenUid ?? this.wardenUid,
    wardenName: wardenName ?? this.wardenName,
    address: address ?? this.address,
    roomCount: roomCount,
    bedCount: bedCount,
    occupiedBeds: occupiedBeds,
    createdAt: createdAt,
  );
}

// =====================================================================
// Room
// =====================================================================

class Room {
  /// Document id — the room number itself ("101"), which makes duplicates
  /// impossible within a hostel and keeps paths readable.
  final String id;

  final String number;
  final int floor;
  final int capacity;
  final List<String> features;
  final RoomStatus status;

  /// UIDs of students currently allotted. The allotment module will own
  /// writes to this; for now it lets us show real occupancy.
  final List<String> occupantUids;

  final num? rentPerBed;
  final String? note;

  /// What's wrong, while [status] is [RoomStatus.maintenance] — separate from
  /// [note], which is a standing remark about the room ("corner room") and
  /// has nothing to do with whether it's currently out of service. Set
  /// alongside the status flip and cleared when it flips back to active, so
  /// it never lingers as a stale warning on a room that's fine again.
  final String? maintenanceNote;

  const Room({
    required this.id,
    required this.number,
    required this.floor,
    required this.capacity,
    this.features = const [],
    this.status = RoomStatus.active,
    this.occupantUids = const [],
    this.rentPerBed,
    this.note,
    this.maintenanceNote,
  });

  factory Room.fromMap(String id, Map<String, dynamic> m) => Room(
    id: id,
    number: m['number'] as String? ?? id,
    floor: (m['floor'] as num?)?.toInt() ?? 0,
    capacity: (m['capacity'] as num?)?.toInt() ?? 1,
    features: ((m['features'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList(),
    status: RoomStatusX.parse(m['status'] as String?),
    occupantUids: ((m['occupantUids'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList(),
    rentPerBed: m['rentPerBed'] as num?,
    note: m['note'] as String?,
    maintenanceNote: m['maintenanceNote'] as String?,
  );

  Map<String, dynamic> toMap() => {
    'number': number,
    'floor': floor,
    'capacity': capacity,
    'features': features,
    'status': status.name,
    'occupantUids': occupantUids,
    'rentPerBed': rentPerBed,
    'note': note,
    'maintenanceNote': maintenanceNote,
  };

  int get occupied => occupantUids.length;
  int get free => (capacity - occupied).clamp(0, capacity);
  bool get isFull => free == 0;
  bool get isAvailable => status == RoomStatus.active && !isFull;

  /// "2 Seater" / "Single" — matches the phrasing in the student mockup.
  String get capacityLabel => capacity == 1 ? 'Single' : '$capacity Seater';

  Room copyWith({
    int? capacity,
    List<String>? features,
    RoomStatus? status,
    List<String>? occupantUids,
    num? rentPerBed,
    String? note,
    String? maintenanceNote,
  }) => Room(
    id: id,
    number: number,
    floor: floor,
    capacity: capacity ?? this.capacity,
    features: features ?? this.features,
    status: status ?? this.status,
    occupantUids: occupantUids ?? this.occupantUids,
    rentPerBed: rentPerBed ?? this.rentPerBed,
    note: note ?? this.note,
    maintenanceNote: maintenanceNote ?? this.maintenanceNote,
  );
}

// =====================================================================
// Room generation
// =====================================================================

/// A run of identical rooms on one floor — "8 rooms, 3 Seater".
///
/// A floor is described as a *list* of these, so one floor can hold eight
/// three-seaters and four singles side by side. Real buildings are like that:
/// the corner rooms are smaller, the wing by the stairs was converted. The
/// common case, a floor where every room is the same, is just one group.
class RoomGroup {
  final int capacity;
  final int count;
  final List<String> features;

  const RoomGroup({
    required this.capacity,
    required this.count,
    this.features = const [],
  });

  int get beds => count * capacity;

  /// "8 × 3 Seater".
  String get label =>
      '$count \u00d7 ${capacity == 1 ? 'Single' : '$capacity Seater'}';

  RoomGroup copyWith({int? capacity, int? count, List<String>? features}) =>
      RoomGroup(
        capacity: capacity ?? this.capacity,
        count: count ?? this.count,
        features: features ?? this.features,
      );
}

/// One floor's rooms, in the order they will be numbered.
class FloorPlan {
  final List<RoomGroup> groups;

  const FloorPlan({this.groups = const []});

  int get roomCount => groups.fold(0, (a, g) => a + g.count);
  int get bedCount => groups.fold(0, (a, g) => a + g.beds);

  /// True when every room on the floor is the same size — which is what makes
  /// "convert this floor to N seater" a safe single action.
  bool get isUniform => groups.map((g) => g.capacity).toSet().length <= 1;

  /// "8 × 3 Seater, 4 × Single", or "empty".
  String get summary => groups.isEmpty || roomCount == 0
      ? 'empty'
      : groups.where((g) => g.count > 0).map((g) => g.label).join(', ');
}

/// The blueprint the "add hostel" form fills in.
///
/// Floor-first on purpose. The earlier shape described a building as a list of
/// seater types and *derived* the floors, which meant you could say "60
/// three-seaters, 25 per floor" but never "floor 1 has eight three-seaters and
/// four singles". Buildings are laid out floor by floor, so the form now asks
/// the same way, and [build] simply walks what it was told.
///
/// Kept as a plain value object so the preview in the UI and the actual write
/// use identical maths — what you see in the preview is literally what gets
/// created.
class RoomPlan {
  final List<FloorPlan> floorPlans;

  const RoomPlan({this.floorPlans = const []});

  /// A building where every floor is identical — the quick path in the form.
  factory RoomPlan.uniform({
    required int floors,
    required int roomsPerFloor,
    required int capacity,
    List<String> features = const [],
  }) => RoomPlan(
    floorPlans: [
      for (var i = 0; i < floors; i++)
        FloorPlan(
          groups: [
            RoomGroup(
              capacity: capacity,
              count: roomsPerFloor,
              features: features,
            ),
          ],
        ),
    ],
  );

  int get floors => floorPlans.length;
  int get totalRooms => floorPlans.fold(0, (a, f) => a + f.roomCount);
  int get totalBeds => floorPlans.fold(0, (a, f) => a + f.bedCount);

  /// Generates every room, floor by floor.
  ///
  /// Floor-prefixed numbering, unchanged: floor 1 -> 101, 102…; floor 2 ->
  /// 201… Groups are laid out in the order given, so a floor of eight
  /// three-seaters then four singles numbers 101–108 as three-seaters and
  /// 109–112 as singles.
  List<Room> build() {
    final rooms = <Room>[];
    for (var i = 0; i < floorPlans.length; i++) {
      final floor = i + 1;
      var n = 0;
      for (final group in floorPlans[i].groups) {
        for (var k = 0; k < group.count; k++) {
          n++;
          final number = '${floor * 100 + n}';
          rooms.add(
            Room(
              id: number,
              number: number,
              floor: floor,
              capacity: group.capacity,
              features: group.features,
            ),
          );
        }
      }
    }
    return rooms;
  }

  /// Human summary for the confirmation line, e.g.
  /// "Floor 1: 8 × 3 Seater, 4 × Single · Floor 2: 12 × Single".
  String get rangeSummary {
    final parts = <String>[];
    for (var i = 0; i < floorPlans.length; i++) {
      final f = floorPlans[i];
      if (f.roomCount <= 0) continue;
      parts.add('Floor ${i + 1}: ${f.summary}');
    }
    return parts.isEmpty ? '\u2014' : parts.join('  \u00b7  ');
  }
}

/// Graduates are skipped as well as the deactivated: a hostel's head-count is
/// the people who live there now, and promotion is what is supposed to move
/// that number. The live tally in `DataService.countStudentsByHostel` applies
/// the same rule.
Map<String, int> studentsByHostel(Iterable<AppUser> users) {
  final counts = <String, int>{};
  for (final u in users) {
    final id = u.hostelId;
    if (id == null || id.isEmpty || !u.isActive || u.isGraduated) continue;
    counts[id] = (counts[id] ?? 0) + 1;
  }
  return counts;
}

/// The same tally as [studentsByHostel], from one session's enrollment
/// records instead of the live roster.
///
/// Enrollment carries no `isActive` flag — deactivation is a live-account
/// concept, and a past session's roster is a record of who was actually
/// housed that year regardless of whether their account is active today —
/// so this counts every enrollment with a room, full stop.
Map<String, int> studentsByHostelFor(Iterable<Enrollment> enrollments) {
  final counts = <String, int>{};
  for (final e in enrollments) {
    final id = e.hostelId;
    if (id == null || id.isEmpty) continue;
    counts[id] = (counts[id] ?? 0) + 1;
  }
  return counts;
}
