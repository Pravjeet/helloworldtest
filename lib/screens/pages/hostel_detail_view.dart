import 'package:flutter/material.dart';

import '../../core/permissions.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../models/hostel.dart';
import '../../services/auth_service.dart';
import '../../services/data_service.dart';
import '../../services/enrollment_service.dart';
import '../../services/hostel_service.dart';
import '../../widgets/selectable_chips.dart';
import '../dashboard_shell.dart' show HistoryBanner;
import 'hostel_editor_dialog.dart';
import 'room_detail_dialog.dart';

/// Rooms inside one hostel, grouped by floor.
class HostelDetailView extends StatefulWidget {
  final String collegeId;
  final String hostelId;
  final VoidCallback onBack;

  const HostelDetailView({
    super.key,
    required this.collegeId,
    required this.hostelId,
    required this.onBack,
  });

  @override
  State<HostelDetailView> createState() => _HostelDetailViewState();
}

class _HostelDetailViewState extends State<HostelDetailView> {
  // Named so the rest of the class reads exactly as it did before the split
  // into StatefulWidget, rather than sprinkling `widget.` through methods
  // that have nothing to do with this change.
  String get collegeId => widget.collegeId;
  String get hostelId => widget.hostelId;
  VoidCallback get onBack => widget.onBack;

  /// Memoised: an aggregation always goes to the server, so building it in
  /// `build()` would re-count on every rebuild — and this page rebuilds
  /// whenever the room stream ticks.
  Future<int>? _students;
  String? _studentsKey;

  Future<int> _studentsIn(String collegeId, String hostelId) {
    final key = '$collegeId/$hostelId';
    if (_studentsKey != key || _students == null) {
      _studentsKey = key;
      _students = DataService.instance
          .countStudentsByHostel(collegeId, [hostelId])
          .then((m) => m[hostelId] ?? 0);
    }
    return _students!;
  }

  /// The past-session equivalent of [_studentsIn]: this hostel's headcount,
  /// and who occupied each room, both read off one session's enrollment
  /// records in the single query that fetches them.
  ///
  /// Deliberately one future rather than two — both numbers come from the
  /// same roster, so fetching it once and deriving both is free the second
  /// time and cannot let the headcount and the room grid disagree about
  /// which session they describe.
  Future<({int students, Map<String, int> byRoom})>? _historical;
  String? _historicalKey;

  Future<({int students, Map<String, int> byRoom})> _historicalFor(
    String collegeId,
    String hostelId,
    String session,
  ) {
    final key = '$collegeId/$hostelId/$session';
    if (_historicalKey != key || _historical == null) {
      _historicalKey = key;
      _historical = EnrollmentService.instance
          .rosterOnce(collegeId, session)
          .then((roster) {
            final here = roster.where((e) => e.hostelId == hostelId);
            final byRoom = <String, int>{};
            for (final e in here) {
              final r = e.roomId;
              if (r != null) byRoom[r] = (byRoom[r] ?? 0) + 1;
            }
            return (students: here.length, byRoom: byRoom);
          });
    }
    return _historical!;
  }

  @override
  Widget build(BuildContext context) {
    final session = Session.of(context);
    final canManage = session.can(Perm.hostelsManage);
    // Listing users needs `users.view`; without it the roster query would be
    // rejected, so the headcount is omitted rather than shown as a stuck dash.
    final canCount = session.can(Perm.usersView);

    return StreamBuilder<Hostel?>(
      stream: HostelService.instance.watchHostel(collegeId, hostelId),
      builder: (context, hostelSnap) {
        final hostel = hostelSnap.data;
        if (hostelSnap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.all(60),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (hostel == null) {
          return AppCard(
            child: Column(
              children: [
                const Text('This hostel no longer exists.'),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: onBack,
                  child: const Text('Back to hostels'),
                ),
              ],
            ),
          );
        }

        // One aggregation instead of the whole roster. The old version
        // streamed 2,649 user documents and filtered them in Dart to produce
        // a single integer, on the strength of a comment claiming the
        // dashboard had already paid for that query — which stopped being
        // true when the dashboard moved to counts.
        //
        // While viewing history there is no live count to ask for — the
        // question is "who was here in 2025-26", which only that session's
        // enrollment records can answer — so the historical future replaces
        // the live one entirely rather than running alongside it.
        return FutureBuilder<({int students, Map<String, int> byRoom})?>(
          future: session.isViewingHistory
              ? _historicalFor(collegeId, hostelId, session.viewingSession!)
              : Future.value(null),
          builder: (context, histSnap) {
            final isHistory = session.isViewingHistory;

            return FutureBuilder<int>(
              future: isHistory || !canCount
                  ? Future.value(0)
                  : _studentsIn(collegeId, hostelId),
              builder: (context, userSnap) {
                final students = isHistory
                    ? (histSnap.data?.students ?? 0)
                    : (userSnap.data ?? 0);
                final byRoom = histSnap.data?.byRoom;
                final countsReady = isHistory
                    ? histSnap.hasData
                    : (canCount && userSnap.hasData);

                final canMutate = canManage && !isHistory;

                return StreamBuilder<List<Room>>(
                  stream: HostelService.instance.watchRooms(
                    collegeId,
                    hostelId,
                  ),
                  builder: (context, roomSnap) {
                    if (roomSnap.hasError) {
                      return AppCard(
                        child: Text(AuthService.describeError(roomSnap.error!)),
                      );
                    }
                    final rooms = roomSnap.data ?? const <Room>[];

                    // Group by floor, preserving the service's floor→number
                    // ordering.
                    final byFloor = <int, List<Room>>{};
                    for (final r in rooms) {
                      byFloor.putIfAbsent(r.floor, () => []).add(r);
                    }
                    final floors = byFloor.keys.toList()..sort();

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const HistoryBanner(),
                        _Header(
                          hostel: hostel,
                          students: students,
                          countsReady: countsReady,
                          // Editing/adding rooms and floors are institution
                          // edits, same reasoning as the hostels grid: a room
                          // added while looking at 2025-26 would still be
                          // added to the live building, not to history.
                          canManage: canMutate,
                          onBack: onBack,
                          onAddRoom: () => _addRoom(context, hostel),
                          onAddFloor: () => _addFloor(context, hostel, floors),
                          onEditDetails: () => _editHostel(context, hostel),
                          onRecalculate: () => _recalculate(context),
                        ),
                        const SizedBox(height: 18),
                        if (!roomSnap.hasData)
                          const Padding(
                            padding: EdgeInsets.all(60),
                            child: Center(child: CircularProgressIndicator()),
                          )
                        else if (rooms.isEmpty)
                          AppCard(
                            padding: EdgeInsets.symmetric(vertical: 50),
                            child: Center(
                              child: Text(
                                'This hostel has no rooms yet.',
                                style: TextStyle(color: AppColors.textMuted),
                              ),
                            ),
                          )
                        else
                          ...floors.map(
                            (floor) => Padding(
                              padding: const EdgeInsets.only(bottom: 18),
                              child: _FloorSection(
                                floor: floor,
                                rooms: byFloor[floor]!,
                                // Null in the live case, so every tile falls
                                // back to `room.occupied` exactly as before —
                                // this only replaces the source of truth
                                // while a past session is on screen.
                                historicalOccupiedByRoom: byRoom,
                                onTapRoom: (room) =>
                                    _openRoom(context, hostel, room),
                                onRetype: canMutate
                                    ? () => _retypeFloor(
                                        context,
                                        hostel,
                                        floor,
                                        byFloor[floor]!,
                                      )
                                    : null,
                              ),
                            ),
                          ),
                        const SizedBox(height: 8),
                        const _Legend(),
                      ],
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  /// Tapping a room opens who lives in it, not the editor.
  ///
  /// Occupancy is what a warden actually wants from a room tile; editing
  /// capacity or features is rarer and now sits behind a button inside. The
  /// editor is still reachable, and only for those who can manage hostels.
  Future<void> _openRoom(BuildContext context, Hostel hostel, Room room) async {
    // Read here, in the page, where SessionScope is above us. The dialog is a
    // separate route and cannot reach it.
    final session = Session.of(context);
    final isHistory = session.isViewingHistory;
    final canManage = session.can(Perm.hostelsManage) && !isHistory;
    final canAllot = session.can(Perm.allotmentManage) && !isHistory;
    final canSeeRoster = session.can(Perm.usersView);

    await showDialog(
      context: context,
      builder: (_) => RoomDetailDialog(
        collegeId: collegeId,
        hostel: hostel,
        room: room,
        canAllot: canAllot,
        canSeeRoster: canSeeRoster,
        // Null in the live case — the dialog then behaves exactly as it
        // always has, reading `watchRoomOccupants` live.
        viewingSession: isHistory ? session.viewingSession : null,
        onEditRoom: canManage ? () => _editRoom(context, hostel, room) : null,
        // The seating policy, same as Room Allotment — read here because the
        // dialog can't reach SessionScope.
        settings: session.settings,
        liveSession: session.settings.session.current,
        isSuperAdmin: session.user.isSuperAdmin,
      ),
    );
  }

  /// Bulk-changes the seater type of a floor's rooms.
  ///
  /// Offered per floor rather than per hostel because that is the unit a
  /// warden thinks in — "the second floor is being converted to singles" — and
  /// because a building rarely changes all at once.
  Future<void> _retypeFloor(
    BuildContext context,
    Hostel hostel,
    int floor,
    List<Room> rooms,
  ) async {
    final sizes = rooms.map((r) => r.capacity).toSet().toList()..sort();
    final messenger = ScaffoldMessenger.of(context);

    final choice = await showDialog<({int? from, int to})>(
      context: context,
      builder: (_) =>
          _RetypeFloorDialog(floor: floor, rooms: rooms, existingSizes: sizes),
    );
    if (choice == null) return;

    try {
      final result = await HostelService.instance.retypeFloor(
        collegeId: collegeId,
        hostelId: hostel.id,
        floor: floor,
        fromCapacity: choice.from,
        toCapacity: choice.to,
      );
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            result.roomsChanged == 0
                ? 'Nothing to change on floor $floor'
                : 'Changed ${result.roomsChanged} room(s) on floor $floor '
                      '(${result.bedsDelta >= 0 ? '+' : ''}'
                      '${result.bedsDelta} beds)',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(AuthService.describeError(e))),
      );
    }
  }

  Future<void> _editRoom(BuildContext context, Hostel hostel, Room room) async {
    await showDialog(
      context: context,
      builder: (_) =>
          RoomEditorDialog(collegeId: collegeId, hostel: hostel, room: room),
    );
  }

  Future<void> _addRoom(BuildContext context, Hostel hostel) async {
    await showDialog(
      context: context,
      builder: (_) =>
          RoomEditorDialog(collegeId: collegeId, hostel: hostel, room: null),
    );
  }

  Future<void> _addFloor(
    BuildContext context,
    Hostel hostel,
    List<int> floors,
  ) async {
    await showDialog(
      context: context,
      builder: (_) => _AddFloorDialog(
        collegeId: collegeId,
        hostel: hostel,
        nextFloor: (floors.isEmpty ? 0 : floors.last) + 1,
      ),
    );
  }

  /// Opens the same editor used at creation, so every field captured when the
  /// hostel was set up can be changed here.
  Future<void> _editHostel(BuildContext context, Hostel hostel) async {
    await showDialog(
      context: context,
      builder: (_) => HostelEditorDialog(collegeId: collegeId, hostel: hostel),
    );
  }

  Future<void> _recalculate(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await HostelService.instance.recalculateCounters(collegeId, hostelId);
      messenger.showSnackBar(
        const SnackBar(content: Text('Counters recalculated from rooms')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(AuthService.describeError(e))),
      );
    }
  }
}

class _Header extends StatelessWidget {
  final Hostel hostel;
  final int students;
  final bool countsReady;
  final bool canManage;
  final VoidCallback onBack;
  final VoidCallback onAddRoom;
  final VoidCallback onAddFloor;
  final VoidCallback onEditDetails;
  final VoidCallback onRecalculate;

  const _Header({
    required this.hostel,
    required this.students,
    required this.countsReady,
    required this.canManage,
    required this.onBack,
    required this.onAddRoom,
    required this.onAddFloor,
    required this.onEditDetails,
    required this.onRecalculate,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back_rounded),
                tooltip: 'Back to hostels',
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      hostel.label,
                      style: const TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${hostel.label == hostel.name ? '' : '${hostel.name} · '}'
                      '${hostel.gender.label} · ${hostel.floors} floors · '
                      '${hostel.roomCount} rooms · ${hostel.bedCount} beds '
                      '(${hostel.freeBeds} free)',
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 13,
                      ),
                    ),
                    // Counted from the roster, not from the bed counters, so
                    // the two can be compared rather than one echoing the other.
                    if (countsReady) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Icon(
                            Icons.people_outline_rounded,
                            size: 15,
                            color: AppColors.primary,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '$students student${students == 1 ? '' : 's'} '
                            'in this hostel',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: AppColors.primary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              if (canManage) ...[
                OutlinedButton.icon(
                  onPressed: onEditDetails,
                  icon: const Icon(Icons.edit_outlined, size: 17),
                  label: const Text('Edit details'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 13,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  onPressed: onAddFloor,
                  icon: const Icon(Icons.layers_rounded, size: 17),
                  label: const Text('Add floor'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 13,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                ElevatedButton.icon(
                  onPressed: onAddRoom,
                  icon: const Icon(Icons.add_rounded, size: 17),
                  label: const Text('Add room'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 13,
                    ),
                  ),
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert_rounded, size: 20),
                  onSelected: (_) => onRecalculate(),
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'recalc',
                      child: Text('Recalculate counters'),
                    ),
                  ],
                ),
              ],
            ],
          ),
          if (hostel.address != null && hostel.address!.trim().isNotEmpty) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                Icon(
                  Icons.place_outlined,
                  size: 15,
                  color: AppColors.textMuted,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    hostel.address!,
                    style: TextStyle(color: AppColors.textMuted, fontSize: 13),
                  ),
                ),
              ],
            ),
          ],
          if (hostel.amenities.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              'Provided in this hostel',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppColors.textMuted,
              ),
            ),
            const SizedBox(height: 8),
            ReadOnlyChips(values: hostel.amenities),
          ],
        ],
      ),
    );
  }
}

class _FloorSection extends StatelessWidget {
  final int floor;
  final List<Room> rooms;

  /// Every room is tappable regardless of permission — the dialog it opens is
  /// read-only unless the viewer can allot or manage hostels, and it says so.
  final ValueChanged<Room> onTapRoom;

  /// Null when the viewer can't manage hostels.
  final VoidCallback? onRetype;

  /// Set only while viewing history — see [_RoomTile.historicalOccupied].
  final Map<String, int>? historicalOccupiedByRoom;

  const _FloorSection({
    required this.floor,
    required this.rooms,
    required this.onTapRoom,
    this.onRetype,
    this.historicalOccupiedByRoom,
  });

  @override
  Widget build(BuildContext context) {
    int occupiedOf(Room r) => historicalOccupiedByRoom?[r.id] ?? r.occupied;
    final beds = rooms.fold<int>(0, (s, r) => s + r.capacity);
    final occupied = rooms.fold<int>(0, (s, r) => s + occupiedOf(r));

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Floor $floor',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '${rooms.length} rooms · $occupied/$beds beds',
                style: TextStyle(color: AppColors.textMuted, fontSize: 12.5),
              ),
              const SizedBox(width: 10),
              // The mix, when the floor is not all one size — which is the
              // case the bulk change exists for.
              Builder(
                builder: (context) {
                  final sizes = <int, int>{};
                  for (final r in rooms) {
                    sizes[r.capacity] = (sizes[r.capacity] ?? 0) + 1;
                  }
                  if (sizes.length <= 1) return const SizedBox.shrink();
                  final parts = (sizes.keys.toList()..sort())
                      .map((c) => '${sizes[c]}×${c == 1 ? 'single' : '${c}s'}')
                      .join(', ');
                  return Text(
                    parts,
                    style: TextStyle(
                      color: AppColors.warning,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  );
                },
              ),
              const Spacer(),
              if (onRetype != null)
                TextButton.icon(
                  onPressed: onRetype,
                  icon: const Icon(Icons.swap_horiz_rounded, size: 16),
                  label: const Text('Seater type'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: rooms
                .map(
                  (r) => _RoomTile(
                    room: r,
                    // A room absent from the map genuinely had nobody in it
                    // that session — this must stay a definite 0, not null,
                    // or it would fall back to the room's *live* occupant
                    // count and misreport an empty-that-year room as full.
                    historicalOccupied: historicalOccupiedByRoom == null
                        ? null
                        : (historicalOccupiedByRoom![r.id] ?? 0),
                    onTap: () => onTapRoom(r),
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }
}

class _RoomTile extends StatelessWidget {
  final Room room;

  /// Occupant count for whichever session is on screen. Null in the live
  /// case — the tile then reads `room.occupied` exactly as it always has.
  /// Status (maintenance/reserved) always stays live: it is an
  /// administrative flag on the physical room, not a fact about a session.
  final int? historicalOccupied;

  final VoidCallback? onTap;

  const _RoomTile({required this.room, this.historicalOccupied, this.onTap});

  @override
  Widget build(BuildContext context) {
    final occupied = historicalOccupied ?? room.occupied;
    final isFull = occupied >= room.capacity;

    late final Color fg;
    late final Color bg;

    if (room.status == RoomStatus.maintenance) {
      fg = AppColors.danger;
      bg = AppColors.dangerSoft;
    } else if (room.status == RoomStatus.reserved) {
      fg = AppColors.info;
      bg = AppColors.infoSoft;
    } else if (isFull) {
      fg = AppColors.warning;
      bg = AppColors.warningSoft;
    } else if (occupied > 0) {
      fg = AppColors.primary;
      bg = AppColors.primarySoft;
    } else {
      fg = AppColors.success;
      bg = AppColors.successSoft;
    }

    return Tooltip(
      message:
          '${room.capacityLabel}'
          '${room.features.isEmpty ? '' : ' · ${room.features.join(', ')}'}'
          '\n$occupied/${room.capacity} occupied · ${room.status.label}'
          '${room.status == RoomStatus.maintenance && (room.maintenanceNote ?? '').isNotEmpty ? ': ${room.maintenanceNote}' : ''}',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 86,
          padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 8),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: fg.withValues(alpha: 0.35)),
          ),
          child: Column(
            children: [
              Text(
                room.number,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                  color: fg,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '$occupied/${room.capacity}',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) => AppCard(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
    child: Wrap(
      spacing: 18,
      runSpacing: 8,
      children: [
        _LegendDot('Empty', AppColors.success),
        _LegendDot('Partly filled', AppColors.primary),
        _LegendDot('Full', AppColors.warning),
        _LegendDot('Maintenance', AppColors.danger),
        _LegendDot('Reserved', AppColors.info),
      ],
    ),
  );
}

class _LegendDot extends StatelessWidget {
  final String label;
  final Color color;
  const _LegendDot(this.label, this.color);

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        height: 11,
        width: 11,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 7),
      Text(
        label,
        style: TextStyle(
          fontSize: 12,
          color: AppColors.textMuted,
          fontWeight: FontWeight.w600,
        ),
      ),
    ],
  );
}

// =====================================================================
// Room editor
// =====================================================================

/// Public so the Under Maintenance page can open the exact same form on a
/// room it picked from a different hostel's list, rather than duplicating
/// the status/message fields in a second dialog.
class RoomEditorDialog extends StatefulWidget {
  final String collegeId;
  final Hostel hostel;

  /// Null when adding a new room.
  final Room? room;

  const RoomEditorDialog({
    super.key,
    required this.collegeId,
    required this.hostel,
    this.room,
  });

  @override
  State<RoomEditorDialog> createState() => _RoomEditorDialogState();
}

class _RoomEditorDialogState extends State<RoomEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _number;
  late final TextEditingController _floor;
  late final TextEditingController _rent;
  late final TextEditingController _note;
  late final TextEditingController _maintenanceNote;

  late int _capacity;
  late RoomStatus _status;
  late Set<String> _features;

  bool _busy = false;
  String? _error;

  bool get _isNew => widget.room == null;

  @override
  void initState() {
    super.initState();
    final r = widget.room;
    _number = TextEditingController(text: r?.number ?? '');
    _floor = TextEditingController(text: '${r?.floor ?? 1}');
    _rent = TextEditingController(
      text: r?.rentPerBed == null ? '' : '${r!.rentPerBed}',
    );
    _note = TextEditingController(text: r?.note ?? '');
    _maintenanceNote = TextEditingController(text: r?.maintenanceNote ?? '');
    _capacity = r?.capacity ?? 2;
    _status = r?.status ?? RoomStatus.active;
    _features = {...?r?.features};
  }

  @override
  void dispose() {
    for (final c in [_number, _floor, _rent, _note, _maintenanceNote]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    // Shrinking a room below its current occupancy would leave students
    // assigned to beds that no longer exist.
    final occupied = widget.room?.occupied ?? 0;
    if (_capacity < occupied) {
      setState(
        () => _error =
            'This room already has $occupied student(s) in it, so capacity '
            'can\'t go below $occupied. Move someone out first.',
      );
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    final messenger = ScaffoldMessenger.of(context);
    try {
      final rent = num.tryParse(_rent.text.trim());
      final note = _note.text.trim().isEmpty ? null : _note.text.trim();
      // Forced to null the moment status isn't Maintenance, regardless of
      // what's still typed in the field — leaving it behind status would
      // read as a live issue on a room that's fine again.
      final maintenanceNote = _status != RoomStatus.maintenance
          ? null
          : (_maintenanceNote.text.trim().isEmpty
                ? null
                : _maintenanceNote.text.trim());

      if (_isNew) {
        final number = _number.text.trim();
        await HostelService.instance.addRoom(
          collegeId: widget.collegeId,
          hostelId: widget.hostel.id,
          room: Room(
            id: number,
            number: number,
            floor: int.parse(_floor.text.trim()),
            capacity: _capacity,
            features: _features.toList(),
            status: _status,
            rentPerBed: rent,
            note: note,
            maintenanceNote: maintenanceNote,
          ),
        );
      } else {
        await HostelService.instance.updateRoom(
          collegeId: widget.collegeId,
          hostelId: widget.hostel.id,
          before: widget.room!,
          // Constructed directly rather than via copyWith: copyWith treats a
          // null as "leave unchanged", which would make clearing the rent or
          // note field silently do nothing.
          after: Room(
            id: widget.room!.id,
            number: widget.room!.number,
            floor: widget.room!.floor,
            capacity: _capacity,
            features: _features.toList(),
            status: _status,
            occupantUids: widget.room!.occupantUids,
            rentPerBed: rent,
            note: note,
            maintenanceNote: maintenanceNote,
          ),
        );
      }
      if (mounted) Navigator.pop(context);
      messenger.showSnackBar(
        SnackBar(content: Text(_isNew ? 'Room added' : 'Room updated')),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Delete room ${widget.room!.number}?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      await HostelService.instance.deleteRoom(
        collegeId: widget.collegeId,
        hostelId: widget.hostel.id,
        room: widget.room!,
      );
      if (mounted) Navigator.pop(context);
      messenger.showSnackBar(const SnackBar(content: Text('Room deleted')));
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isNew ? 'Add a room' : 'Room ${widget.room!.number}'),
      content: SizedBox(
        width: 470,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_error != null) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.dangerSoft,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      _error!,
                      style: TextStyle(color: AppColors.danger, fontSize: 13),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                if (_isNew)
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _number,
                          enabled: !_busy,
                          decoration: const InputDecoration(
                            labelText: 'Room number',
                            hintText: '101',
                          ),
                          validator: (v) => (v == null || v.trim().isEmpty)
                              ? 'Required'
                              : null,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextFormField(
                          controller: _floor,
                          enabled: !_busy,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: 'Floor'),
                          validator: (v) {
                            final n = int.tryParse(v ?? '');
                            return (n == null || n < 1) ? 'Min 1' : null;
                          },
                        ),
                      ),
                    ],
                  )
                else
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.canvas,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      'Floor ${widget.room!.floor} · '
                      '${widget.room!.occupied}/${widget.room!.capacity} '
                      'beds occupied',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ),
                const SizedBox(height: 14),

                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        initialValue: _capacity,
                        decoration: const InputDecoration(
                          labelText: 'Capacity',
                        ),
                        items: const [1, 2, 3, 4, 5, 6]
                            .map(
                              (n) => DropdownMenuItem(
                                value: n,
                                child: Text(n == 1 ? 'Single' : '$n seater'),
                              ),
                            )
                            .toList(),
                        onChanged: _busy
                            ? null
                            : (v) => setState(() => _capacity = v ?? 1),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<RoomStatus>(
                        initialValue: _status,
                        decoration: const InputDecoration(labelText: 'Status'),
                        items: RoomStatus.values
                            .map(
                              (s) => DropdownMenuItem(
                                value: s,
                                child: Text(s.label),
                              ),
                            )
                            .toList(),
                        onChanged: _busy
                            ? null
                            : (v) => setState(
                                () => _status = v ?? RoomStatus.active,
                              ),
                      ),
                    ),
                  ],
                ),
                if (_status == RoomStatus.maintenance) ...[
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _maintenanceNote,
                    enabled: !_busy,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: "What's wrong",
                      hintText: 'e.g. AC not cooling, leaking tap',
                    ),
                  ),
                ],
                const SizedBox(height: 14),

                TextFormField(
                  controller: _rent,
                  enabled: !_busy,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Rent per bed (optional)',
                    prefixText: '₹ ',
                  ),
                ),
                const SizedBox(height: 14),

                TextFormField(
                  controller: _note,
                  enabled: !_busy,
                  decoration: const InputDecoration(
                    labelText: 'Note (optional)',
                    hintText: 'e.g. corner room, faces the ground',
                  ),
                ),
                const SizedBox(height: 18),

                const Text(
                  'Room features',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                SelectableChips(
                  options: kRoomFeatures,
                  selected: _features,
                  enabled: !_busy,
                  onChanged: (v) => setState(() => _features = v),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        if (!_isNew)
          TextButton(
            onPressed: _busy ? null : _delete,
            child: Text('Delete', style: TextStyle(color: AppColors.danger)),
          ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: _busy
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: Colors.white,
                  ),
                )
              : Text(_isNew ? 'Add room' : 'Save'),
        ),
      ],
    );
  }
}

// =====================================================================
// Add floor
// =====================================================================

class _AddFloorDialog extends StatefulWidget {
  final String collegeId;
  final Hostel hostel;
  final int nextFloor;

  const _AddFloorDialog({
    required this.collegeId,
    required this.hostel,
    required this.nextFloor,
  });

  @override
  State<_AddFloorDialog> createState() => _AddFloorDialogState();
}

class _AddFloorDialogState extends State<_AddFloorDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _floor;
  final _count = TextEditingController(text: '25');

  int _capacity = 2;
  Set<String> _features = {'Ceiling Fan', 'Study Table'};
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _floor = TextEditingController(text: '${widget.nextFloor}');
  }

  @override
  void dispose() {
    _floor.dispose();
    _count.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    final messenger = ScaffoldMessenger.of(context);
    try {
      await HostelService.instance.addFloor(
        collegeId: widget.collegeId,
        hostelId: widget.hostel.id,
        floor: int.parse(_floor.text.trim()),
        roomsPerFloor: int.parse(_count.text.trim()),
        capacity: _capacity,
        features: _features.toList(),
      );
      if (mounted) Navigator.pop(context);
      messenger.showSnackBar(const SnackBar(content: Text('Floor added')));
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final floor = int.tryParse(_floor.text) ?? widget.nextFloor;
    final count = int.tryParse(_count.text) ?? 0;

    return AlertDialog(
      title: const Text('Add a floor'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_error != null) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.dangerSoft,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      _error!,
                      style: TextStyle(color: AppColors.danger, fontSize: 13),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _floor,
                        enabled: !_busy,
                        keyboardType: TextInputType.number,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          labelText: 'Floor number',
                        ),
                        validator: (v) {
                          final n = int.tryParse(v ?? '');
                          if (n == null || n < 1) return 'Min 1';
                          if (n > 20) return 'Max 20';
                          return null;
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _count,
                        enabled: !_busy,
                        keyboardType: TextInputType.number,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(labelText: 'Rooms'),
                        validator: (v) {
                          final n = int.tryParse(v ?? '');
                          if (n == null || n < 1) return 'Min 1';
                          if (n > 99) return 'Max 99';
                          return null;
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        initialValue: _capacity,
                        decoration: const InputDecoration(
                          labelText: 'Capacity',
                        ),
                        items: const [1, 2, 3, 4, 5, 6]
                            .map(
                              (n) => DropdownMenuItem(
                                value: n,
                                child: Text(n == 1 ? 'Single' : '$n'),
                              ),
                            )
                            .toList(),
                        onChanged: _busy
                            ? null
                            : (v) => setState(() => _capacity = v ?? 2),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Text(
                  'Room features',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                SelectableChips(
                  options: kRoomFeatures,
                  selected: _features,
                  enabled: !_busy,
                  onChanged: (v) => setState(() => _features = v),
                ),
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(13),
                  decoration: BoxDecoration(
                    color: AppColors.primarySoft,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    count < 1
                        ? '—'
                        : 'Will create rooms ${floor * 100 + 1}–'
                              '${floor * 100 + count}. Any that already exist '
                              'are skipped.',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: AppColors.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: _busy
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: Colors.white,
                  ),
                )
              : const Text('Add floor'),
        ),
      ],
    );
  }
}

/// Asks what a floor's rooms should become.
///
/// Two modes because a floor is not always uniform: convert one size to
/// another and leave the rest, or flatten the whole floor to one size.
class _RetypeFloorDialog extends StatefulWidget {
  final int floor;
  final List<Room> rooms;
  final List<int> existingSizes;

  const _RetypeFloorDialog({
    required this.floor,
    required this.rooms,
    required this.existingSizes,
  });

  @override
  State<_RetypeFloorDialog> createState() => _RetypeFloorDialogState();
}

class _RetypeFloorDialogState extends State<_RetypeFloorDialog> {
  /// Null means "every room on this floor".
  int? _from;
  int _to = 3;

  @override
  void initState() {
    super.initState();
    // Default to converting the most common size on the floor, which is
    // usually what someone means.
    if (widget.existingSizes.length > 1) _from = widget.existingSizes.first;
    _to = widget.existingSizes.isEmpty ? 3 : widget.existingSizes.last;
  }

  String _label(int c) => c == 1 ? 'Single' : '$c Seater';

  int get _affected => widget.rooms
      .where((r) => _from == null || r.capacity == _from)
      .where((r) => r.capacity != _to)
      .length;

  /// Rooms that already hold more students than the new size allows.
  List<Room> get _blocked => widget.rooms
      .where((r) => _from == null || r.capacity == _from)
      .where((r) => r.occupied > _to)
      .toList();

  @override
  Widget build(BuildContext context) {
    final blocked = _blocked;

    return AlertDialog(
      title: Text('Seater type on floor ${widget.floor}'),
      content: SizedBox(
        width: 430,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<int?>(
              initialValue: _from,
              decoration: const InputDecoration(labelText: 'Change'),
              items: [
                const DropdownMenuItem<int?>(
                  value: null,
                  child: Text('Every room on this floor'),
                ),
                ...widget.existingSizes.map(
                  (c) => DropdownMenuItem<int?>(
                    value: c,
                    child: Text('Only the ${_label(c)} rooms'),
                  ),
                ),
              ],
              onChanged: (v) => setState(() => _from = v),
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<int>(
              initialValue: _to,
              decoration: const InputDecoration(labelText: 'Into'),
              items: const [1, 2, 3, 4, 5, 6]
                  .map(
                    (c) => DropdownMenuItem(
                      value: c,
                      child: Text(c == 1 ? 'Single' : '$c Seater'),
                    ),
                  )
                  .toList(),
              onChanged: (v) => setState(() => _to = v ?? _to),
            ),
            const SizedBox(height: 16),
            if (blocked.isNotEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.dangerSoft,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${blocked.length} room(s) already hold more than $_to '
                  'student(s) — ${blocked.take(4).map((r) => r.number).join(', ')}'
                  '${blocked.length > 4 ? '…' : ''}. Move somebody out first, '
                  'or pick a larger type.',
                  style: TextStyle(
                    color: AppColors.danger,
                    fontSize: 12.5,
                    height: 1.4,
                  ),
                ),
              )
            else
              Text(
                _affected == 0
                    ? 'Nothing would change.'
                    : '$_affected room(s) become ${_label(_to)}. '
                          'Room numbers, features and current occupants are '
                          'kept.',
                style: TextStyle(fontSize: 12.5, color: AppColors.textMuted),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: (blocked.isNotEmpty || _affected == 0)
              ? null
              : () => Navigator.pop(context, (from: _from, to: _to)),
          child: const Text('Change'),
        ),
      ],
    );
  }
}
