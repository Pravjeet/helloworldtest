import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/permissions.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../models/hostel.dart';
import '../../services/auth_service.dart';
import '../../services/hostel_service.dart';
import '../dashboard_shell.dart' show HistoryBanner;
import 'hostel_detail_view.dart' show RoomEditorDialog;

/// Every room currently flagged [RoomStatus.maintenance], across every
/// hostel, in one place.
///
/// Without this, finding out what's broken where meant opening each hostel
/// in turn. Each hostel's list is a server-side filtered query
/// ([HostelService.watchMaintenanceRooms]) rather than a full room scan, so
/// this stays cheap regardless of how big the campus is.
///
/// Status is a live/administrative fact, same reasoning
/// `hostels_page.dart` documents for the rest of the hostel fabric — so this
/// page always shows the *current* flags, and editing is disabled while
/// browsing a past session.
class MaintenanceRoomsPage extends StatefulWidget {
  const MaintenanceRoomsPage({super.key});

  @override
  State<MaintenanceRoomsPage> createState() => _MaintenanceRoomsPageState();
}

class _MaintenanceRoomsPageState extends State<MaintenanceRoomsPage> {
  final Map<String, StreamSubscription<List<Room>>> _subs = {};
  final Map<String, List<Room>> _byHostel = {};
  String? _collegeId;

  /// Keeps one live subscription per hostel in step with the current hostel
  /// list, without re-subscribing on every rebuild — the same shape as the
  /// manual caching `_HostelsPageState` already uses for its aggregations,
  /// just over N small streams instead of one future.
  void _sync(String collegeId, List<Hostel> hostels) {
    if (_collegeId != collegeId) {
      for (final s in _subs.values) {
        s.cancel();
      }
      _subs.clear();
      _byHostel.clear();
      _collegeId = collegeId;
    }

    final ids = hostels.map((h) => h.id).toSet();

    for (final id in _subs.keys.toList()) {
      if (!ids.contains(id)) {
        _subs.remove(id)?.cancel();
        _byHostel.remove(id);
      }
    }

    for (final id in ids) {
      if (_subs.containsKey(id)) continue;
      _subs[id] = HostelService.instance
          .watchMaintenanceRooms(collegeId, id)
          .listen((rooms) {
            if (!mounted) return;
            setState(() => _byHostel[id] = rooms);
          });
    }
  }

  @override
  void dispose() {
    for (final s in _subs.values) {
      s.cancel();
    }
    super.dispose();
  }

  Future<void> _flagRoom(
    BuildContext context,
    String collegeId,
    List<Hostel> hostels,
  ) async {
    final picked = await showDialog<({Hostel hostel, Room room})>(
      context: context,
      builder: (_) => _FlagRoomDialog(collegeId: collegeId, hostels: hostels),
    );
    if (picked == null || !context.mounted) return;
    await showDialog(
      context: context,
      builder: (_) => RoomEditorDialog(
        collegeId: collegeId,
        hostel: picked.hostel,
        room: picked.room,
      ),
    );
  }

  Future<void> _resolve(
    BuildContext context,
    String collegeId,
    Hostel hostel,
    Room room,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await HostelService.instance.updateRoom(
        collegeId: collegeId,
        hostelId: hostel.id,
        before: room,
        after: Room(
          id: room.id,
          number: room.number,
          floor: room.floor,
          capacity: room.capacity,
          features: room.features,
          status: RoomStatus.active,
          occupantUids: room.occupantUids,
          rentPerBed: room.rentPerBed,
          note: room.note,
          maintenanceNote: null,
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(AuthService.describeError(e))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = Session.of(context);
    final collegeId = session.user.collegeId;

    if (!session.can(Perm.hostelsView)) {
      return AppCard(
        padding: const EdgeInsets.symmetric(vertical: 54),
        child: Center(
          child: Text(
            'You don\'t have permission to view hostels & rooms.',
            style: TextStyle(color: AppColors.textMuted),
          ),
        ),
      );
    }

    return StreamBuilder<List<Hostel>>(
      stream: HostelService.instance.watchHostels(collegeId),
      builder: (context, snap) {
        if (snap.hasError) {
          return AppCard(child: Text(AuthService.describeError(snap.error!)));
        }
        if (!snap.hasData) {
          return const Padding(
            padding: EdgeInsets.all(60),
            child: Center(child: CircularProgressIndicator()),
          );
        }

        final hostels = snap.data!;
        _sync(collegeId, hostels);

        final byId = {for (final h in hostels) h.id: h};
        final sections =
            _byHostel.entries
                .where((e) => e.value.isNotEmpty && byId.containsKey(e.key))
                .toList()
              ..sort(
                (a, b) => Hostel.compareByCode(byId[a.key]!, byId[b.key]!),
              );

        final total = sections.fold<int>(0, (s, e) => s + e.value.length);
        final canManage =
            session.can(Perm.hostelsManage) && !session.isViewingHistory;

        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const HistoryBanner(),
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SectionHeader(
                      'Under maintenance',
                      trailing: !canManage
                          ? null
                          : FilledButton.icon(
                              onPressed: () =>
                                  _flagRoom(context, collegeId, hostels),
                              icon: const Icon(Icons.add_rounded, size: 18),
                              label: const Text('Flag a room'),
                            ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      total == 0
                          ? 'Nothing is flagged right now.'
                          : '$total room${total == 1 ? '' : 's'} out of '
                                'service, across ${sections.length} '
                                'hostel${sections.length == 1 ? '' : 's'}.',
                      style: TextStyle(
                        fontSize: 13,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              if (total == 0)
                AppCard(
                  padding: const EdgeInsets.symmetric(vertical: 46),
                  child: Center(
                    child: Column(
                      children: [
                        Icon(
                          Icons.handyman_outlined,
                          size: 34,
                          color: AppColors.textMuted,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'No rooms are currently under maintenance.',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else
                for (final entry in sections) ...[
                  _HostelSection(
                    hostel: byId[entry.key]!,
                    rooms: entry.value,
                    canManage: canManage,
                    onEdit: (room) => showDialog(
                      context: context,
                      builder: (_) => RoomEditorDialog(
                        collegeId: collegeId,
                        hostel: byId[entry.key]!,
                        room: room,
                      ),
                    ),
                    onResolve: (room) =>
                        _resolve(context, collegeId, byId[entry.key]!, room),
                  ),
                  const SizedBox(height: 14),
                ],
            ],
          ),
        );
      },
    );
  }
}

class _HostelSection extends StatelessWidget {
  final Hostel hostel;
  final List<Room> rooms;
  final bool canManage;
  final ValueChanged<Room> onEdit;
  final ValueChanged<Room> onResolve;

  const _HostelSection({
    required this.hostel,
    required this.rooms,
    required this.canManage,
    required this.onEdit,
    required this.onResolve,
  });

  @override
  Widget build(BuildContext context) => AppCard(
    padding: EdgeInsets.zero,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Text(
            '${hostel.label}  ·  ${rooms.length} '
            'room${rooms.length == 1 ? '' : 's'}',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
          ),
        ),
        for (var i = 0; i < rooms.length; i++) ...[
          Divider(height: 1, color: AppColors.border),
          _RoomRow(
            room: rooms[i],
            canManage: canManage,
            onEdit: () => onEdit(rooms[i]),
            onResolve: () => onResolve(rooms[i]),
          ),
        ],
      ],
    ),
  );
}

class _RoomRow extends StatelessWidget {
  final Room room;
  final bool canManage;
  final VoidCallback onEdit;
  final VoidCallback onResolve;

  const _RoomRow({
    required this.room,
    required this.canManage,
    required this.onEdit,
    required this.onResolve,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 46,
          height: 46,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.dangerSoft,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            room.number,
            style: TextStyle(
              color: AppColors.danger,
              fontWeight: FontWeight.w800,
              fontSize: 13,
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Floor ${room.floor} · ${room.capacityLabel} · '
                '${room.occupied}/${room.capacity} occupied',
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                (room.maintenanceNote ?? '').trim().isEmpty
                    ? 'No message left for this one.'
                    : room.maintenanceNote!,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.4,
                  color: (room.maintenanceNote ?? '').trim().isEmpty
                      ? AppColors.textMuted
                      : AppColors.textStrong,
                  fontStyle: (room.maintenanceNote ?? '').trim().isEmpty
                      ? FontStyle.italic
                      : FontStyle.normal,
                ),
              ),
            ],
          ),
        ),
        if (canManage) ...[
          const SizedBox(width: 8),
          TextButton(onPressed: onEdit, child: const Text('Edit')),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.success,
            ),
            onPressed: onResolve,
            child: const Text('Mark resolved'),
          ),
        ],
      ],
    ),
  );
}

/// Step one of "Flag a room": pick which room, from a hostel picked first so
/// the room dropdown never has to hold the whole campus at once. Step two —
/// writing the actual status and message — reopens the same
/// [RoomEditorDialog] every other room edit already goes through, rather
/// than duplicating those fields here.
class _FlagRoomDialog extends StatefulWidget {
  final String collegeId;
  final List<Hostel> hostels;

  const _FlagRoomDialog({required this.collegeId, required this.hostels});

  @override
  State<_FlagRoomDialog> createState() => _FlagRoomDialogState();
}

class _FlagRoomDialogState extends State<_FlagRoomDialog> {
  Hostel? _hostel;
  Room? _room;

  @override
  Widget build(BuildContext context) {
    final hostels = [...widget.hostels]..sort(Hostel.compareByCode);

    return AlertDialog(
      title: const Text('Flag a room for maintenance'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<Hostel>(
              initialValue: _hostel,
              decoration: const InputDecoration(labelText: 'Hostel'),
              items: hostels
                  .map(
                    (h) => DropdownMenuItem(
                      value: h,
                      child: Text(h.label),
                    ),
                  )
                  .toList(),
              onChanged: (h) => setState(() {
                _hostel = h;
                _room = null;
              }),
            ),
            const SizedBox(height: 14),
            if (_hostel != null)
              StreamBuilder<List<Room>>(
                stream: HostelService.instance.watchRooms(
                  widget.collegeId,
                  _hostel!.id,
                ),
                builder: (context, snap) {
                  if (!snap.hasData) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 20),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  final rooms = snap.data!
                      .where((r) => r.status != RoomStatus.maintenance)
                      .toList();
                  if (rooms.isEmpty) {
                    return Text(
                      'Every room in this hostel is already flagged.',
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 13,
                      ),
                    );
                  }
                  return DropdownButtonFormField<Room>(
                    initialValue: _room,
                    decoration: const InputDecoration(labelText: 'Room'),
                    items: rooms
                        .map(
                          (r) => DropdownMenuItem(
                            value: r,
                            child: Text('Room ${r.number} · Floor ${r.floor}'),
                          ),
                        )
                        .toList(),
                    onChanged: (r) => setState(() => _room = r),
                  );
                },
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
          onPressed: (_hostel == null || _room == null)
              ? null
              : () => Navigator.pop(context, (hostel: _hostel!, room: _room!)),
          child: const Text('Next'),
        ),
      ],
    );
  }
}
