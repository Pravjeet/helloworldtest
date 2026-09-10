import 'package:cloud_firestore/cloud_firestore.dart';

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
  };

  int get occupied => occupantUids.length;
  int get free => (capacity - occupied).clamp(0, capacity);
  bool get isFull => free == 0;
  bool get isAvailable => status == RoomStatus.active && !isFull;

  /// "2 Seater" / "Single" — matches the phrasing in the student mockup.
  String get capacityLabel =>
      capacity == 1 ? 'Single' : '$capacity Seater';

  Room copyWith({
    int? capacity,
    List<String>? features,
    RoomStatus? status,
    List<String>? occupantUids,
    num? rentPerBed,
    String? note,
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
  );
}

// =====================================================================
// Room generation
// =====================================================================

/// The most rooms one floor may hold.
///
/// Numbering is floor-prefixed (`floor * 100 + n`), so a hundredth room on
/// floor 3 would be numbered 400 and collide with floor 4. The limit is the
/// numbering scheme's, not an arbitrary one.
const int kMaxRoomsPerFloor = 99;

/// A run of same-seater rooms **on one floor** — "25 rooms, 3 Seater".
///
/// A floor is a list of these, which is what lets one floor hold more than
/// one room type: 25 singles and 25 three-seaters on the same corridor is
/// two groups on one [FloorPlan], not two separate floors.
class RoomGroup {
  final int capacity;
  final int rooms;
  final List<String> features;

  const RoomGroup({
    required this.capacity,
    required this.rooms,
    this.features = const [],
  });

  int get beds => rooms * capacity;

  /// "Single" / "3 Seater" — same phrasing as [Room.capacityLabel].
  String get label => capacity == 1 ? 'Single' : '$capacity Seater';

  RoomGroup copyWith({int? capacity, int? rooms, List<String>? features}) =>
      RoomGroup(
        capacity: capacity ?? this.capacity,
        rooms: rooms ?? this.rooms,
        features: features ?? this.features,
      );
}

/// What one floor is made of.
///
/// Rooms are numbered in group order along the corridor: with 25 singles
/// then 25 three-seaters on floor 3, rooms 301–325 are the singles and
/// 326–350 the three-seaters. That ordering is deliberate — it matches how
/// a real corridor is walked, so a room number tells you its type.
class FloorPlan {
  final List<RoomGroup> groups;

  const FloorPlan({this.groups = const []});

  int get rooms => groups.fold(0, (acc, g) => acc + g.rooms);
  int get beds => groups.fold(0, (acc, g) => acc + g.beds);

  /// "25 Single + 25 3 Seater", or "—" for an empty floor.
  String get composition {
    final parts = groups
        .where((g) => g.rooms > 0)
        .map((g) => '${g.rooms} ${g.label}')
        .toList();
    return parts.isEmpty ? '—' : parts.join(' + ');
  }

  /// Everything that makes two floors interchangeable in a summary. Features
  /// are deliberately excluded — they don't change how a floor reads as
  /// "20 rooms: 10 Single + 10 2 Seater".
  String get _signature =>
      groups.where((g) => g.rooms > 0).map((g) => '${g.capacity}x${g.rooms}').join(',');
}

/// The blueprint the "add hostel" form fills in. Kept as a plain value object
/// so the preview in the UI and the actual write use the exact same maths —
/// what you see in the preview is literally what gets created.
///
/// Describes the building **floor by floor**. An earlier version described it
/// by seater type instead, handing each type whole floors of its own, which
/// made a floor holding two room types impossible to express — the common
/// case of a corridor that is half singles and half three-seaters.
class RoomPlan {
  /// Index 0 is floor 1. A floor with no rooms still occupies its number, so
  /// the floors above it keep the numbering everyone expects.
  final List<FloorPlan> floorPlans;

  const RoomPlan({this.floorPlans = const []});

  /// Every floor laid out identically — the usual case, and what the editor
  /// starts from before anyone customises a single floor.
  factory RoomPlan.uniform({
    required int floors,
    required List<RoomGroup> groups,
  }) => RoomPlan(
    floorPlans: List.generate(
      floors < 0 ? 0 : floors,
      (_) => FloorPlan(groups: groups),
    ),
  );

  int get floors => floorPlans.length;
  int get totalRooms => floorPlans.fold(0, (acc, f) => acc + f.rooms);
  int get totalBeds => floorPlans.fold(0, (acc, f) => acc + f.beds);

  /// True when some floor asks for more rooms than the numbering can carry.
  bool get exceedsFloorLimit =>
      floorPlans.any((f) => f.rooms > kMaxRoomsPerFloor);

  /// Generates every room, floor by floor and group by group.
  ///
  /// Floor-prefixed numbering: floor 1 -> 101, 102...; floor 2 -> 201...
  /// Room ids are the numbers themselves, so duplicates within a hostel are
  /// structurally impossible.
  List<Room> build() {
    final rooms = <Room>[];
    for (var i = 0; i < floorPlans.length; i++) {
      final floor = i + 1;
      var n = 1;
      for (final group in floorPlans[i].groups) {
        for (var r = 0; r < group.rooms; r++) {
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
          n++;
        }
      }
    }
    return rooms;
  }

  /// Human summary for the confirmation line, e.g.
  /// "Floors 1–3: 50 rooms (25 Single + 25 3 Seater), Floor 4: 20 rooms
  /// (20 Single)".
  ///
  /// Consecutive floors built the same way are collapsed into one range —
  /// a 10-floor hostel of identical floors reads as one clause, not ten.
  String get rangeSummary {
    final parts = <String>[];
    var i = 0;
    while (i < floorPlans.length) {
      final plan = floorPlans[i];
      if (plan.rooms == 0) {
        i++;
        continue;
      }
      final signature = plan._signature;
      var last = i;
      while (last + 1 < floorPlans.length &&
          floorPlans[last + 1]._signature == signature) {
        last++;
      }
      final where = i == last ? 'Floor ${i + 1}' : 'Floors ${i + 1}–${last + 1}';
      parts.add('$where: ${plan.rooms} rooms (${plan.composition})');
      i = last + 1;
    }
    return parts.isEmpty ? '—' : parts.join(', ');
  }
}
