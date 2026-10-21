import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../core/theme.dart';
import '../../models/app_user.dart';
import '../../models/hostel.dart';
import '../../services/allotment_service.dart';
import '../../widgets/selectable_chips.dart';

/// A student's own room, roommates and facilities.
class MyRoomPage extends StatefulWidget {
  const MyRoomPage({super.key});

  @override
  State<MyRoomPage> createState() => _MyRoomPageState();
}

class _MyRoomPageState extends State<MyRoomPage> {
  /// Memoised per room identity — the same reason `_FeedState._countsFor`
  /// exists on the admin dashboard.
  ///
  /// [AllotmentService.findRoom] is a one-shot read, so building the future
  /// inside `build()` spent a fresh Firestore read on every rebuild of the
  /// page every resident opens. Keyed on the allotment rather than held
  /// outright, so a student who is actually moved still refetches.
  Future<Room?>? _room;
  String? _roomKey;

  Future<Room?> _roomFor(AppUser user) {
    final key = '${user.collegeId}/${user.hostelId}/${user.roomId}';
    if (_roomKey != key || _room == null) {
      _roomKey = key;
      _room = AllotmentService.instance.findRoom(
        collegeId: user.collegeId,
        hostelId: user.hostelId!,
        roomId: user.roomId!,
      );
    }
    return _room!;
  }

  @override
  Widget build(BuildContext context) {
    final user = Session.of(context).user;

    if (!user.isAllotted) {
      return const _NotAllotted();
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 820),
      child: FutureBuilder<Room?>(
        future: _roomFor(user),
        builder: (context, roomSnap) {
          if (roomSnap.connectionState == ConnectionState.waiting) {
            return const Padding(
              padding: EdgeInsets.all(60),
              child: Center(child: CircularProgressIndicator()),
            );
          }

          final room = roomSnap.data;
          if (room == null) {
            return AppCard(
              child: Text(
                'Your room record couldn\'t be found. It may have been '
                'removed — please check with your warden.',
                style: TextStyle(color: AppColors.textMuted, height: 1.5),
              ),
            );
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _RoomHeader(user: user, room: room),
              const SizedBox(height: 18),
              if (room.features.isNotEmpty) ...[
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionHeader('In your room'),
                      const SizedBox(height: 14),
                      ReadOnlyChips(values: room.features),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
              ],
              _Roommates(user: user, room: room),
            ],
          );
        },
      ),
    );
  }
}

class _NotAllotted extends StatelessWidget {
  const _NotAllotted();

  @override
  Widget build(BuildContext context) => AppCard(
    padding: const EdgeInsets.symmetric(vertical: 64, horizontal: 28),
    child: Column(
      children: [
        Container(
          height: 64,
          width: 64,
          decoration: BoxDecoration(
            color: AppColors.warningSoft,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Icon(
            Icons.no_meeting_room_rounded,
            size: 30,
            color: AppColors.warning,
          ),
        ),
        const SizedBox(height: 20),
        const Text(
          'No room allotted yet',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Text(
            'Your warden hasn\'t assigned you a room yet. This page will fill '
            'in by itself as soon as they do.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 14,
              height: 1.5,
            ),
          ),
        ),
      ],
    ),
  );
}

class _RoomHeader extends StatelessWidget {
  final AppUser user;
  final Room room;
  const _RoomHeader({required this.user, required this.room});

  @override
  Widget build(BuildContext context) => AppCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              height: 54,
              width: 54,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.primarySoft,
                borderRadius: BorderRadius.circular(15),
              ),
              child: Text(
                room.number,
                style: TextStyle(
                  color: AppColors.primary,
                  fontWeight: FontWeight.w800,
                  fontSize: 17,
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Room ${room.number}',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${user.hostelLabel} · Floor ${room.floor} · '
                    '${room.capacityLabel}',
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 13.5,
                    ),
                  ),
                ],
              ),
            ),
            StatusPill(
              '${room.occupied}/${room.capacity} OCCUPIED',
              AppColors.primary,
              AppColors.primarySoft,
            ),
          ],
        ),
        if (room.rentPerBed != null) ...[
          const SizedBox(height: 16),
          Text(
            'Rent: ₹${room.rentPerBed} per bed',
            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
          ),
        ],
        if (room.status == RoomStatus.maintenance) ...[
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.warningSoft,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              (room.maintenanceNote ?? '').trim().isEmpty
                  ? 'This room is currently under maintenance.'
                  : 'Under maintenance: ${room.maintenanceNote}',
              style: TextStyle(
                color: AppColors.warning,
                fontSize: 12.5,
                height: 1.4,
              ),
            ),
          ),
        ],
        if (room.note != null && room.note!.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            room.note!,
            style: TextStyle(
              fontSize: 13,
              color: AppColors.textMuted,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ],
    ),
  );
}

class _Roommates extends StatefulWidget {
  final AppUser user;
  final Room room;
  const _Roommates({required this.user, required this.room});

  @override
  State<_Roommates> createState() => _RoommatesState();
}

class _RoommatesState extends State<_Roommates> {
  /// Memoised for the same reason as [_MyRoomPageState._roomFor].
  /// [AllotmentService.occupantsOf] is a `whereIn` read of the roommates'
  /// profiles, so an un-memoised future re-read all of them on every rebuild.
  ///
  /// Keyed on who is actually in the room, so someone moving in or out still
  /// refetches while an ordinary rebuild does not.
  Future<List<AppUser>>? _mates;
  String? _matesKey;

  Future<List<AppUser>> _matesFor() {
    final room = widget.room;
    final key = '${room.id}/${widget.user.uid}/${room.occupantUids.join(',')}';
    if (_matesKey != key || _mates == null) {
      _matesKey = key;
      _mates = AllotmentService.instance.occupantsOf(
        room,
        excludeUid: widget.user.uid,
      );
    }
    return _mates!;
  }

  @override
  Widget build(BuildContext context) {
    final room = widget.room;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader('Roommates'),
          const SizedBox(height: 14),
          FutureBuilder<List<AppUser>>(
            future: _matesFor(),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Center(
                    child: SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.2),
                    ),
                  ),
                );
              }

              final mates = snap.data ?? const <AppUser>[];
              if (mates.isEmpty) {
                return Text(
                  room.capacity == 1
                      ? 'You have this room to yourself.'
                      : 'Nobody else has been allotted here yet — '
                            '${room.free} bed(s) still free.',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 13.5),
                );
              }

              return Column(
                children: mates
                    .map(
                      (m) => Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Row(
                          children: [
                            CircleAvatar(
                              radius: 19,
                              backgroundColor: AppColors.primarySoft,
                              child: Text(
                                m.initials,
                                style: TextStyle(
                                  color: AppColors.primary,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            const SizedBox(width: 13),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    m.name,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 14,
                                    ),
                                  ),
                                  if (m.course != null || m.year != null)
                                    Text(
                                      [
                                        if (m.course != null) m.course!,
                                        if (m.year != null) m.year!,
                                      ].join(' · '),
                                      style: TextStyle(
                                        color: AppColors.textMuted,
                                        fontSize: 12.5,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            if (m.phone != null)
                              Text(
                                m.phone!,
                                style: TextStyle(
                                  color: AppColors.textMuted,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                          ],
                        ),
                      ),
                    )
                    .toList(),
              );
            },
          ),
        ],
      ),
    );
  }
}
