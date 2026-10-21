import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../core/theme.dart';
import '../../models/app_user.dart';
import '../../models/enrollment.dart';
import '../../models/hostel.dart';
import '../../services/allotment_service.dart';
import '../../services/auth_service.dart';
import '../../services/enrollment_service.dart';
import '../../services/hostel_service.dart';
import '../../utils/enrollment_helpers.dart';

/// Pick a hostel, then a free room, for one student.
///
/// Hostels the student is ineligible for (wrong gender) are shown but disabled
/// with the reason attached, rather than hidden — a warden looking for "why
/// isn't Block A listed?" should get an answer, not an absence.
///
/// Rendered as a drill-down inside the dashboard shell rather than a dialog,
/// so the sidebar stays visible and a hostel with many rooms has room to
/// breathe. The shell already scrolls, so nothing here takes a bounded height.
class AllotRoomView extends StatefulWidget {
  final AppUser student;

  /// True when the student already has a room and we're relocating them.
  final bool isMove;

  /// Leave without allotting.
  final VoidCallback onBack;

  /// Called after a successful allot/move. Usually the same as [onBack].
  final VoidCallback onDone;

  const AllotRoomView({
    super.key,
    required this.student,
    required this.onBack,
    required this.onDone,
    this.isMove = false,
  });

  @override
  State<AllotRoomView> createState() => _AllotRoomViewState();
}

class _AllotRoomViewState extends State<AllotRoomView> {
  Hostel? _hostel;
  Room? _room;
  bool _onlyEmpty = false;
  bool _busy = false;
  String? _error;

  /// "Bypass course room allotment rules" — Super Admin only, and only for
  /// this one allotment. Everyone else gets exactly the room type the seating
  /// policy entitles the student to, enforced by the service as well as by
  /// the room list, so it is the same rule as Hostels & Rooms and auto-allot.
  bool _bypass = false;

  /// The room type this student must get, from the live policy — or null
  /// when no rule covers them, or a Super Admin is bypassing it.
  int? _required(Enrollment? enrollment) {
    final session = Session.of(context);
    if (_bypass && session.user.isSuperAdmin) return null;
    return _entitled(enrollment);
  }

  /// What the policy says, ignoring any bypass — shown in the banner either
  /// way, so a Super Admin can see what they are overriding.
  int? _entitled(Enrollment? enrollment) => entitledRoomCapacity(
    settings: Session.of(context).settings,
    course: widget.student.course,
    year: enrollment?.year ?? int.tryParse(widget.student.year?.trim() ?? ''),
    singleRoomEligible: widget.student.singleRoomEligible,
  );

  /// Fetched once — the current session's enrollment doesn't change while
  /// this screen is open, and a Future (not a Stream) keeps a slow read from
  /// blocking the hostel picker above it from rendering. Not final: a read
  /// that failed is retried on confirm, rather than every press replaying the
  /// same stored error until the screen is reopened.
  late Future<Enrollment?> _enrollmentFuture = _loadEnrollment();

  Future<Enrollment?> _loadEnrollment() {
    final session = Session.of(context);
    final currentSession = session.settings.session.current;
    if (currentSession == null) return Future.value(null);
    return EnrollmentService.instance.get(
      widget.student.collegeId,
      widget.student.uid,
      currentSession,
    );
  }

  Future<void> _confirm() async {
    if (_hostel == null || _room == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    final messenger = ScaffoldMessenger.of(context);
    try {
      Enrollment? enrollment;
      try {
        enrollment = await _enrollmentFuture;
      } catch (_) {
        final retry = _loadEnrollment();
        if (mounted) setState(() => _enrollmentFuture = retry);
        enrollment = await retry; // a second failure is shown below
      }
      if (!mounted) return;
      final required = _required(enrollment);
      // The room was picked from a list filtered by the same rule — but the
      // policy is live, and a room picked a moment before the entitlement
      // loaded must not slip through to a refusal from the service.
      if (required != null && _room!.capacity != required) {
        setState(() {
          _room = null;
          _error =
              'Pick a ${roomTypeLabel(required)} room — the seating policy '
              'entitles ${widget.student.name} to one this year.';
        });
        return;
      }
      if (widget.isMove) {
        await AllotmentService.instance.move(
          collegeId: widget.student.collegeId,
          student: widget.student,
          toHostel: _hostel!,
          toRoom: _room!,
          requiredCapacity: required,
        );
      } else {
        await AllotmentService.instance.allot(
          collegeId: widget.student.collegeId,
          student: widget.student,
          hostel: _hostel!,
          room: _room!,
          requiredCapacity: required,
        );
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${widget.student.name} → ${_hostel!.name}, '
            'Room ${_roomCode(_hostel!, _room!)}',
          ),
        ),
      );
      widget.onDone();
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is AllotmentFailure
              ? e.message
              : AuthService.describeError(e),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final collegeId = Session.of(context).user.collegeId;
    final isSuperAdmin = Session.of(context).user.isSuperAdmin;
    final student = widget.student;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ------------------------------ header ------------------------------
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  IconButton(
                    onPressed: _busy ? null : widget.onBack,
                    icon: const Icon(Icons.arrow_back_rounded),
                    tooltip: 'Back',
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.isMove
                              ? 'Move ${student.name}'
                              : 'Allot a room to ${student.name}',
                          style: const TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          'Pick a hostel, then a free room.',
                          style: TextStyle(
                            fontSize: 13,
                            color: AppColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: _busy ? null : widget.onBack,
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    onPressed: (_room == null || _busy) ? null : _confirm,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 16,
                      ),
                    ),
                    child: _busy
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.2,
                              color: Colors.white,
                            ),
                          )
                        : Text(
                            _room == null
                                ? 'Select a room'
                                : widget.isMove
                                ? 'Move to ${_roomCode(_hostel!, _room!)}'
                                : 'Allot ${_roomCode(_hostel!, _room!)}',
                          ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _StudentStrip(student: student),
              FutureBuilder<Enrollment?>(
                future: _enrollmentFuture,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const SizedBox.shrink();
                  }
                  final capacity = _entitled(snap.data);
                  if (capacity == null) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.primarySoft,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.stars_rounded,
                            size: 17,
                            color: AppColors.primary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _bypass
                                  ? 'Entitled to a ${roomTypeLabel(capacity)} '
                                        'room — bypassed, so any room type '
                                        'can be chosen.'
                                  : 'Entitled to a ${roomTypeLabel(capacity)} '
                                        'room this year, per the seating '
                                        'policy.',
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: _bypass
                                    ? AppColors.warning
                                    : AppColors.primary,
                              ),
                            ),
                          ),
                          // Super Admin only: the escape hatch for the one
                          // student the policy gets wrong. Never in auto-allot.
                          if (isSuperAdmin) ...[
                            Text(
                              'Bypass course room\nallotment rules',
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: AppColors.primary,
                              ),
                            ),
                            Switch(
                              value: _bypass,
                              onChanged: _busy
                                  ? null
                                  : (v) => setState(() {
                                      _bypass = v;
                                      _room = null;
                                    }),
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                },
              ),
              if (_error != null) ...[
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.dangerSoft,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: AppColors.danger,
                      fontSize: 13,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 18),

        // ------------------------------ picker ------------------------------
        StreamBuilder<List<Hostel>>(
          stream: HostelService.instance.watchHostels(collegeId),
          builder: (context, hostelSnap) {
            if (!hostelSnap.hasData) {
              return const Padding(
                padding: EdgeInsets.all(60),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final hostels = hostelSnap.data!;
            if (hostels.isEmpty) {
              return AppCard(
                padding: EdgeInsets.symmetric(vertical: 50),
                child: Center(
                  child: Text(
                    'No hostels exist yet. Create one first.',
                    style: TextStyle(color: AppColors.textMuted),
                  ),
                ),
              );
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _Label('Hostel'),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: hostels.map((h) {
                          final eligible = AllotmentService.genderAllows(
                            h.gender,
                            student.gender,
                          );
                          final selected = _hostel?.id == h.id;
                          // Wardens navigate by the code that appears in room
                          // codes ("A-101"), not the long hostel name — so the
                          // chip shows the code and the name moves to the
                          // tooltip.
                          final label = h.code.trim().isEmpty
                              ? h.name
                              : h.code.trim().toUpperCase();
                          return Tooltip(
                            message: eligible
                                ? '${h.name} · ${h.freeBeds} free of '
                                      '${h.bedCount}'
                                : '${h.name} · ${h.gender.label} hostel — '
                                      'not eligible',
                            child: ChoiceChip(
                              label: Text(
                                '$label  (${h.freeBeds})',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                  color: !eligible
                                      ? AppColors.textMuted
                                      : selected
                                      ? AppColors.primary
                                      : AppColors.textStrong,
                                ),
                              ),
                              selected: selected,
                              onSelected: eligible && !_busy
                                  ? (_) => setState(() {
                                      _hostel = h;
                                      _room = null;
                                    })
                                  : null,
                              selectedColor: AppColors.primarySoft,
                              backgroundColor: Colors.white,
                              side: BorderSide(
                                color: selected
                                    ? AppColors.primary
                                    : AppColors.border,
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                if (_hostel == null)
                  AppCard(
                    padding: EdgeInsets.symmetric(vertical: 50),
                    child: Center(
                      child: Text(
                        'Pick a hostel to see its free rooms.',
                        style: TextStyle(color: AppColors.textMuted),
                      ),
                    ),
                  )
                else
                  FutureBuilder<Enrollment?>(
                    future: _enrollmentFuture,
                    builder: (context, snap) {
                      // No rooms until the entitlement is known — listing
                      // every type meanwhile offered rooms the policy then
                      // refused.
                      if (snap.connectionState != ConnectionState.done) {
                        return const Padding(
                          padding: EdgeInsets.all(60),
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }
                      return _RoomPicker(
                        collegeId: collegeId,
                        hostel: _hostel!,
                        selected: _room,
                        onlyEmpty: _onlyEmpty,
                        onToggleOnlyEmpty: (v) =>
                            setState(() => _onlyEmpty = v),
                        onPick: (r) => setState(() => _room = r),
                        requiredCapacity: _required(snap.data),
                      );
                    },
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _StudentStrip extends StatelessWidget {
  final AppUser student;
  const _StudentStrip({required this.student});

  @override
  Widget build(BuildContext context) {
    final noGender = student.gender == null || student.gender!.trim().isEmpty;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: AppColors.canvas,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              [
                student.displayRole,
                if (student.gender != null) student.gender!,
                if (student.enrollmentNo != null) student.enrollmentNo!,
                if (student.isAllotted) 'Currently in ${student.roomLabel}',
              ].join('  ·  '),
              style: TextStyle(
                fontSize: 12.5,
                color: AppColors.textMuted,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (noGender)
            Tooltip(
              message:
                  'No gender on this profile, so Boys/Girls hostels can\'t be '
                  'checked. Set it on their detail screen.',
              child: Icon(
                Icons.info_outline_rounded,
                size: 18,
                color: AppColors.warning,
              ),
            ),
        ],
      ),
    );
  }
}

class _RoomPicker extends StatelessWidget {
  final String collegeId;
  final Hostel hostel;
  final Room? selected;
  final bool onlyEmpty;
  final ValueChanged<bool> onToggleOnlyEmpty;
  final ValueChanged<Room> onPick;

  /// When set, only rooms of this capacity are shown — the seating-policy
  /// entitlement, applied as a filter rather than hiding the picker
  /// entirely. Null means no policy applies, or the "Match only" switch
  /// above has been turned off — every available room is shown either way.
  final int? requiredCapacity;

  const _RoomPicker({
    required this.collegeId,
    required this.hostel,
    required this.selected,
    required this.onlyEmpty,
    required this.onToggleOnlyEmpty,
    required this.onPick,
    this.requiredCapacity,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Room>>(
      stream: HostelService.instance.watchRooms(collegeId, hostel.id),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Padding(
            padding: EdgeInsets.all(60),
            child: Center(child: CircularProgressIndicator()),
          );
        }

        // Only rooms that can actually take someone.
        var rooms = snap.data!.where((r) => r.isAvailable).toList();
        if (onlyEmpty) rooms = rooms.where((r) => r.occupied == 0).toList();
        if (requiredCapacity != null) {
          rooms = rooms.where((r) => r.capacity == requiredCapacity).toList();
        }

        final byFloor = <int, List<Room>>{};
        for (final r in rooms) {
          byFloor.putIfAbsent(r.floor, () => []).add(r);
        }
        final floors = byFloor.keys.toList()..sort();

        return AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _Label('Available rooms  (${rooms.length})'),
                  const Spacer(),
                  Text(
                    'Empty rooms only',
                    style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                  ),
                  Switch(value: onlyEmpty, onChanged: onToggleOnlyEmpty),
                ],
              ),
              const SizedBox(height: 6),
              if (rooms.isEmpty)
                Padding(
                  padding: EdgeInsets.symmetric(vertical: 40),
                  child: Center(
                    child: Text(
                      requiredCapacity != null
                          ? 'No free ${roomTypeLabel(requiredCapacity!)} '
                                'rooms here — the type the seating policy '
                                'entitles this student to. Try another '
                                'hostel, or turn off "empty rooms only".'
                          : 'No free rooms match. Try another hostel, or '
                                'turn off "empty rooms only".',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.textMuted),
                    ),
                  ),
                )
              else
                ...floors.map((floor) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Text(
                          'Floor $floor',
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: byFloor[floor]!.map((r) {
                          final isSel = selected?.id == r.id;
                          return InkWell(
                            onTap: () => onPick(r),
                            borderRadius: BorderRadius.circular(10),
                            child: Container(
                              width: 96,
                              padding: const EdgeInsets.symmetric(
                                vertical: 10,
                                horizontal: 8,
                              ),
                              decoration: BoxDecoration(
                                color: isSel ? AppColors.primary : Colors.white,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: isSel
                                      ? AppColors.primary
                                      : AppColors.border,
                                ),
                              ),
                              child: Column(
                                children: [
                                  Text(
                                    _roomCode(hostel, r),
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w800,
                                      color: isSel
                                          ? Colors.white
                                          : AppColors.textStrong,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${r.free} of ${r.capacity} free',
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w600,
                                      color: isSel
                                          ? Colors.white70
                                          : AppColors.textMuted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ],
                  );
                }),
            ],
          ),
        );
      },
    );
  }
}

/// "A-101" — the hostel's short code plus the room number. Falls back to the
/// bare number when a hostel has no code set.
String _roomCode(Hostel hostel, Room room) {
  final code = hostel.code.trim();
  return code.isEmpty ? room.number : '${code.toUpperCase()}-${room.number}';
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w800,
      letterSpacing: 0.9,
      color: AppColors.textMuted,
    ),
  );
}
