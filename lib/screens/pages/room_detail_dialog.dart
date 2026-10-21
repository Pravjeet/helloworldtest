import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../models/app_user.dart';
import '../../models/college_settings.dart';
import '../../models/enrollment.dart';
import '../../models/hostel.dart';
import '../../services/allotment_service.dart';
import '../../services/auth_service.dart';
import '../../services/data_service.dart';
import '../../services/enrollment_service.dart';
import '../../utils/enrollment_helpers.dart';
import '../../widgets/student_photo.dart';

/// Renders one past-session enrollment through the same `_OccupantTile` a
/// live [AppUser] uses, rather than forking the display code in two.
///
/// [AppUser.fromMap] is fully defensive — every field falls back to a sane
/// default — so a map built from only what [Enrollment] actually carries
/// produces a legitimate display object. `isActive: true` is forced
/// unconditionally: deactivation is a live-account concept with nothing to
/// say about who was housed in a past year, so it must never hide a row here
/// the way it correctly does for the live roster.
AppUser _asDisplayUser(Enrollment e) => AppUser.fromMap(e.uid, {
  'name': e.name,
  'email': '',
  'collegeId': e.collegeId,
  'enrollmentNo': e.enrollmentNo,
  'course': e.course,
  'trade': e.trade,
  'batch': e.batch,
  'gender': e.gender,
  'hostelId': e.hostelId,
  'hostelName': e.hostelName,
  'roomId': e.roomId,
  'roomNumber': e.roomNumber,
  'isActive': true,
});

/// Who is in one room, and a way to fill its free beds.
///
/// Occupancy is read from the roster (`hostelId` + `roomId` on each student)
/// rather than from the room's own `occupantUids`. Both are written by the
/// same allotment transaction so they agree, but the roster carries the names
/// and registration numbers this dialog needs anyway — deriving from it means
/// one pooled stream instead of a second read, and the list updates the
/// instant an allotment lands.
///
/// Allotting here goes through [AllotmentService.allot], the same call Room
/// Allotment makes. That is the whole point: the room's `occupantUids`, the
/// student's `roomId` and the hostel's `occupiedBeds` counter all move inside
/// one transaction, so a bed filled from this dialog shows up everywhere —
/// the hostel card, the fees roster, the student's profile — with no extra
/// bookkeeping here.
/// Permissions are passed in rather than read from the context: a dialog is
/// pushed onto the root Navigator, so its context sits above SessionScope and
/// `Session.of` would throw. See the note on [BulkDeleteUsersDialog].
class RoomDetailDialog extends StatefulWidget {
  final String collegeId;
  final Hostel hostel;
  final Room room;

  /// `allotment.manage` — whether the free-bed picker is offered.
  final bool canAllot;

  /// `users.view` — whether the roster may be listed at all. Without it the
  /// occupants can't be shown, and the query would be rejected by the rules.
  final bool canSeeRoster;

  /// Opens the room editor. Null when the viewer can't manage hostels, which
  /// hides the button rather than showing one that fails.
  final VoidCallback? onEditRoom;

  /// Set only while viewing history: who is shown is that session's
  /// enrollment records for this room instead of the live roster, and the
  /// allot button — already excluded from [canAllot] by the caller — is
  /// additionally explained rather than merely absent.
  final String? viewingSession;

  /// The college's course rules — for the seating policy, so a student is
  /// only offered a room of the type they're entitled to. The same rule Room
  /// Allotment and auto-allot use; passed in because this dialog sits above
  /// SessionScope.
  final CollegeSettings settings;

  /// The live session, whose enrollments give each candidate's year.
  final String? liveSession;

  /// Only a Super Admin is offered "Bypass course room allotment rules".
  final bool isSuperAdmin;

  const RoomDetailDialog({
    super.key,
    required this.collegeId,
    required this.hostel,
    required this.room,
    required this.canAllot,
    required this.canSeeRoster,
    this.onEditRoom,
    this.viewingSession,
    this.settings = const CollegeSettings(),
    this.liveSession,
    this.isSuperAdmin = false,
  });

  @override
  State<RoomDetailDialog> createState() => _RoomDetailDialogState();
}

class _RoomDetailDialogState extends State<RoomDetailDialog> {
  final _search = TextEditingController();
  String _query = '';

  /// True once the warden has asked to add someone, so the picker (and the
  /// roster search it implies) stays out of the way until wanted.
  bool _picking = false;

  bool _busy = false;
  String? _error;

  /// Super Admin's per-allotment override of the seating policy.
  bool _bypass = false;

  /// The room type [u] must get, or null when no rule covers them or the
  /// Super Admin is bypassing it. [yearByUid] is the live session's roster.
  int? _requiredFor(AppUser u, Map<String, int> yearByUid) {
    if (_bypass && widget.isSuperAdmin) return null;
    return entitledRoomCapacity(
      settings: widget.settings,
      course: u.course,
      year: yearByUid[u.uid] ?? int.tryParse(u.year?.trim() ?? ''),
      singleRoomEligible: u.singleRoomEligible,
    );
  }

  /// Rendering every candidate is what made other screens crawl — a campus
  /// with thousands awaiting a room would build thousands of rows here.
  static const _maxCandidates = 25;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Empties one bed.
  ///
  /// Removes the student from the room *and* the hostel, which is what
  /// `vacate` does. There is deliberately no "free the bed but stay in the
  /// hostel" variant: a student is either allotted a hostel and room together
  /// or is waiting in Room Allotment to be given both, and a half-state of
  /// hostel-without-room is exactly what this app no longer tracks.
  Future<void> _removeOccupant(AppUser student) async {
    final hostelName = widget.hostel.label;
    // Captured before the confirm dialog: reading it afterwards would be
    // reaching through a context that may no longer be mounted.
    final messenger = ScaffoldMessenger.of(context);

    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Move ${student.name} out of room ${widget.room.number}?'),
        content: Text(
          '${student.name} leaves $hostelName and the bed is freed. They will '
          'appear in Room Allotment as awaiting a room, where you can give '
          'them a new hostel and room together.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Move out'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AllotmentService.instance.vacate(
        collegeId: widget.collegeId,
        student: student,
      );
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(
        SnackBar(content: Text('${student.name} moved out of $hostelName')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e is AllotmentFailure
            ? e.message
            : AuthService.describeError(e);
      });
    }
  }

  /// Empties the room in one go.
  ///
  /// Sequential, not parallel — each call is a transaction on the same room
  /// and hostel document, so firing them together would just make them retry
  /// against each other.
  Future<void> _emptyRoom(List<AppUser> occupants) async {
    final n = occupants.length;
    final messenger = ScaffoldMessenger.of(context);

    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Empty room ${widget.room.number}?'),
        content: Text(
          'All $n student${n == 1 ? '' : 's'} leave ${widget.hostel.label} and '
          'the beds are freed. They will appear in Room Allotment awaiting a '
          'room, where you can give each a new hostel and room together.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(c, true),
            child: Text('Move out $n student${n == 1 ? '' : 's'}'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    var freed = 0;
    final failures = <String>[];
    for (final student in occupants) {
      try {
        await AllotmentService.instance.vacate(
          collegeId: widget.collegeId,
          student: student,
        );
        freed++;
      } catch (e) {
        // One student failing shouldn't abandon the rest — report at the end.
        failures.add('${student.name}: ${AuthService.describeError(e)}');
      }
    }

    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = failures.isEmpty ? null : failures.join('\n');
    });
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          'Moved out $freed student${freed == 1 ? '' : 's'} from room '
          '${widget.room.number}'
          '${failures.isEmpty ? '' : ' — ${failures.length} could not be done'}',
        ),
      ),
    );
  }

  Future<void> _allot(AppUser student, int? requiredCapacity) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      await AllotmentService.instance.allot(
        collegeId: widget.collegeId,
        student: student,
        hostel: widget.hostel,
        room: widget.room,
        requiredCapacity: requiredCapacity,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        // Collapse the picker and clear the search: the common case is one
        // student at a time, and leaving a stale query up implies the next
        // person is already filtered for.
        _picking = false;
        // The bypass was for that one student. The next bed follows the
        // policy again unless the Super Admin deliberately bypasses again.
        _bypass = false;
        _query = '';
        _search.clear();
      });
      messenger.showSnackBar(
        SnackBar(
          content: Text('${student.name} allotted room ${widget.room.number}'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      // The service re-checks capacity, gender and prior allotment inside its
      // transaction, so its message is the accurate one — show it verbatim
      // instead of guessing why it refused.
      setState(() {
        _busy = false;
        _error = e is AllotmentFailure
            ? e.message
            : AuthService.describeError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final viewingSession = widget.viewingSession;
    // Defensive, not decorative: the caller already zeroes `canAllot` while
    // viewing history, but the invariant "no mutation on a historical
    // snapshot" should be true reading this file alone, not only by trusting
    // every call site to have remembered it.
    final canAllot = widget.canAllot && viewingSession == null;
    final canSeeRoster = widget.canSeeRoster;
    final room = widget.room;

    return AlertDialog(
      title: Text('Room ${room.number}'),
      content: SizedBox(
        width: 500,
        // Asks for this room's occupants rather than the whole roster.
        //
        // It used to stream every user in the college — 2,649 documents — and
        // filter down to the three people in this room. Still a live stream,
        // so allotting someone from inside this dialog updates it the same way
        // it always did; it is simply the right query now.
        //
        // While viewing history there is no live occupant list to stream —
        // the question is "who was here in 2025-26", answerable only from
        // that session's enrollment records. `Stream.fromFuture` wraps that
        // one-shot answer as a single-emission stream so this stays a
        // `StreamBuilder` either way and the live path — which genuinely must
        // keep updating as allotments happen — is untouched.
        child: StreamBuilder<List<AppUser>>(
          stream: !canSeeRoster
              ? const Stream<List<AppUser>>.empty()
              : viewingSession != null
              ? Stream.fromFuture(
                  EnrollmentService.instance
                      .rosterOnce(widget.collegeId, viewingSession)
                      .then(
                        (roster) => roster
                            .where(
                              (e) =>
                                  e.hostelId == widget.hostel.id &&
                                  e.roomId == room.id,
                            )
                            .map(_asDisplayUser)
                            .toList(),
                      ),
                )
              : DataService.instance.watchRoomOccupants(
                  widget.collegeId,
                  widget.hostel.id,
                  room.id,
                ),
          builder: (context, snap) {
            // Sorted by the query; only the active filter is left, and it
            // stays client-side because it is a handful of documents and
            // folding it into the query would cost another composite index.
            // Historical rows have no `isActive` to speak of, so they are
            // never filtered — see [_asDisplayUser].
            final occupants = (snap.data ?? const <AppUser>[])
                .where((u) => u.isActive)
                .toList();

            // Beds free according to the roster. `room.capacity` is a snapshot
            // from when the dialog opened, which is fine — capacity only
            // changes when someone edits the room.
            final free = (room.capacity - occupants.length).clamp(
              0,
              room.capacity,
            );

            return SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_error != null) ...[
                    _Banner(_error!, AppColors.danger, AppColors.dangerSoft),
                    const SizedBox(height: 16),
                  ],

                  _RoomFacts(room: room, occupied: occupants.length),
                  const SizedBox(height: 18),

                  if (!canSeeRoster)
                    Text(
                      'You don\'t have permission to see who lives here.',
                      style: TextStyle(
                        fontSize: 13,
                        color: AppColors.textMuted,
                      ),
                    )
                  else if (!snap.hasData)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else ...[
                    _OccupantList(
                      occupants: occupants,
                      busy: _busy,
                      // Emptying a bed is the same authority as filling one.
                      // `canAllot` is already false while viewing history, so
                      // these two are just as inert then — there is no
                      // separate check to remember here.
                      onRemove: canAllot ? _removeOccupant : null,
                      onEmptyRoom: canAllot
                          ? () => _emptyRoom(occupants)
                          : null,
                    ),
                    const SizedBox(height: 16),
                    if (viewingSession != null)
                      // "Free beds" and room status are both live, current-
                      // moment facts — neither means anything about a past
                      // session, so the whole allot/status block is replaced
                      // rather than shown with numbers that don't apply.
                      Text(
                        'This is how Room ${room.number} stood in '
                        '$viewingSession. Allotment works on the live room, '
                        'not this snapshot.',
                        style: TextStyle(
                          fontSize: 13,
                          color: AppColors.textMuted,
                        ),
                      )
                    else if (room.status != RoomStatus.active)
                      _Banner(
                        'This room is marked ${room.status.label}, so it '
                        'can\'t take students until that changes.'
                        '${room.status == RoomStatus.maintenance && (room.maintenanceNote ?? '').trim().isNotEmpty ? ' ${room.maintenanceNote}' : ''}',
                        AppColors.warning,
                        AppColors.warningSoft,
                      )
                    else if (free == 0)
                      Text(
                        'All ${room.capacity} beds are taken.',
                        style: TextStyle(
                          fontSize: 13,
                          color: AppColors.textMuted,
                        ),
                      )
                    else if (!canAllot)
                      Text(
                        '$free bed${free == 1 ? '' : 's'} free. You don\'t '
                        'have permission to allot students.',
                        style: TextStyle(
                          fontSize: 13,
                          color: AppColors.textMuted,
                        ),
                      )
                    else if (!_picking)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: ElevatedButton.icon(
                          onPressed: () => setState(() => _picking = true),
                          icon: const Icon(Icons.person_add_alt_1, size: 18),
                          label: Text(
                            'Allot a student  ($free bed'
                            '${free == 1 ? '' : 's'} free)',
                          ),
                        ),
                      )
                    else
                      // The roster is loaded here and nowhere else in this
                      // dialog, because choosing who to allot is the only
                      // thing that genuinely needs every student — you have to
                      // be able to search for someone who is not in this room
                      // yet. Merely opening a room to see who is in it does
                      // not, and that is by far the commoner action, so it no
                      // longer pays for 2,649 documents.
                      //
                      // `_picking` gates this branch, so the subscription is
                      // only opened once someone actually taps "Allot a
                      // student".
                      // The live session's enrollments give each candidate's
                      // year for the seating policy. Pooled with Room
                      // Allotment's roster, so usually already loaded.
                      StreamBuilder<List<Enrollment>>(
                        stream: widget.liveSession == null
                            ? const Stream<List<Enrollment>>.empty()
                            : EnrollmentService.instance.watchRoster(
                                widget.collegeId,
                                widget.liveSession!,
                              ),
                        builder: (context, enrollSnap) {
                          // Wait for the live years before offering anyone.
                          // Falling back to the sheet's year meanwhile would
                          // judge a promoted 4th-year as a 3rd-year — and the
                          // service would accept that wrong entitlement.
                          if (widget.liveSession != null) {
                            if (enrollSnap.hasError) {
                              return _Banner(
                                'Can\'t check the seating policy — academic '
                                'records didn\'t load '
                                '(${AuthService.describeError(enrollSnap.error!)}).',
                                AppColors.danger,
                                AppColors.dangerSoft,
                              );
                            }
                            if (!enrollSnap.hasData) {
                              return const Padding(
                                padding: EdgeInsets.symmetric(vertical: 24),
                                child: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              );
                            }
                          }
                          final yearByUid = {
                            for (final e
                                in enrollSnap.data ?? const <Enrollment>[])
                              e.uid: e.year,
                          };
                          return StreamBuilder<List<AppUser>>(
                            stream: DataService.instance.watchUsers(
                              widget.collegeId,
                            ),
                            builder: (context, rosterSnap) => _Picker(
                              hostel: widget.hostel,
                              room: room,
                              roster: rosterSnap.data ?? const <AppUser>[],
                              requiredFor: (u) => _requiredFor(u, yearByUid),
                              isSuperAdmin: widget.isSuperAdmin,
                              bypass: _bypass,
                              onBypass: (v) => setState(() => _bypass = v),
                              controller: _search,
                              query: _query,
                              busy: _busy,
                              maxShown: _maxCandidates,
                              onQuery: (v) => setState(() => _query = v),
                              onCancel: () => setState(() {
                                _picking = false;
                                _bypass = false;
                                _query = '';
                                _search.clear();
                              }),
                              onPick: (u) =>
                                  _allot(u, _requiredFor(u, yearByUid)),
                            ),
                          );
                        },
                      ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        if (widget.onEditRoom != null)
          TextButton(
            onPressed: _busy
                ? null
                : () {
                    Navigator.pop(context);
                    widget.onEditRoom!();
                  },
            child: const Text('Edit room'),
          ),
        FilledButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

// ------------------------------- room facts -------------------------------

class _RoomFacts extends StatelessWidget {
  final Room room;
  final int occupied;

  const _RoomFacts({required this.room, required this.occupied});

  @override
  Widget build(BuildContext context) {
    final free = (room.capacity - occupied).clamp(0, room.capacity);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.canvas,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 22,
            runSpacing: 8,
            children: [
              _Fact('Beds', '$occupied / ${room.capacity}'),
              _Fact('Free', '$free'),
              _Fact('Type', room.capacityLabel),
              _Fact('Floor', '${room.floor}'),
              _Fact('Status', room.status.label),
            ],
          ),
          if (room.features.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              room.features.join('  ·  '),
              style: TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
          ],
          if ((room.note ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              room.note!,
              style: TextStyle(
                fontSize: 12,
                fontStyle: FontStyle.italic,
                color: AppColors.textMuted,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  final String label;
  final String value;
  const _Fact(this.label, this.value);

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: AppColors.textMuted,
        ),
      ),
      const SizedBox(height: 2),
      Text(
        value,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
      ),
    ],
  );
}

// ------------------------------- occupants -------------------------------

class _OccupantList extends StatelessWidget {
  final List<AppUser> occupants;

  /// Null when the viewer can't allot, which hides the remove action rather
  /// than offering one that would be refused.
  final ValueChanged<AppUser>? onRemove;

  final VoidCallback? onEmptyRoom;
  final bool busy;

  const _OccupantList({
    required this.occupants,
    this.onRemove,
    this.onEmptyRoom,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    if (occupants.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 26),
        decoration: BoxDecoration(
          color: AppColors.successSoft,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Center(
          child: Text(
            'Empty — nobody is in this room yet.',
            style: TextStyle(
              color: AppColors.success,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Residents (${occupants.length})',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            // Only worth offering for more than one — a single resident is
            // quicker to remove from their own row.
            if (onEmptyRoom != null && occupants.length > 1)
              TextButton.icon(
                onPressed: busy ? null : onEmptyRoom,
                icon: const Icon(Icons.logout_rounded, size: 16),
                label: const Text('Empty room'),
              ),
          ],
        ),
        const SizedBox(height: 10),
        // Faces side by side, big enough to recognise — "who actually lives
        // here" is answered by looking, not by reading three names.
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final o in occupants)
              _OccupantCard(student: o, onRemove: onRemove, busy: busy),
          ],
        ),
      ],
    );
  }
}

class _OccupantCard extends StatelessWidget {
  final AppUser student;
  final ValueChanged<AppUser>? onRemove;
  final bool busy;

  const _OccupantCard({
    required this.student,
    this.onRemove,
    this.busy = false,
  });

  static const double _width = 142;

  @override
  Widget build(BuildContext context) {
    final u = student;
    final detail = [
      if ((u.trade ?? '').isNotEmpty) u.trade!,
      if ((u.year ?? '').isNotEmpty) u.year!,
      if (u.sem != null) 'Sem ${u.sem}',
    ].join(' · ');

    return Container(
      width: _width,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppColors.canvas,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          StudentPhoto.user(u, width: _width - 16, height: 158, radius: 9),
          const SizedBox(height: 8),
          Text(
            u.name,
            maxLines: 2,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 13,
              height: 1.25,
            ),
          ),
          if ((u.enrollmentNo ?? '').isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              u.enrollmentNo!,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: AppColors.textStrong,
              ),
            ),
          ],
          if (detail.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              detail,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: AppColors.textMuted),
            ),
          ],
          if ((u.phone ?? '').isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              u.phone!,
              style: TextStyle(fontSize: 11, color: AppColors.textMuted),
            ),
          ],
          if (onRemove != null) ...[
            const SizedBox(height: 4),
            TextButton.icon(
              onPressed: busy ? null : () => onRemove!(u),
              icon: Icon(
                Icons.person_remove_outlined,
                size: 15,
                color: AppColors.danger,
              ),
              label: Text(
                'Move out',
                style: TextStyle(fontSize: 12, color: AppColors.danger),
              ),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// -------------------------------- picker --------------------------------

/// Chooses a student for a free bed.
///
/// Students already recorded as living in this hostel but with no room yet
/// come first: after a CSV import that is the overwhelming majority of who a
/// warden is looking for, and making them scroll past the whole institute to
/// find one is the difference between this being useful and being ignored.
class _Picker extends StatelessWidget {
  final Hostel hostel;
  final Room room;
  final List<AppUser> roster;

  /// The room type each student must get (null: any). Students entitled to a
  /// different type than [room] are left out, the same as the room list in
  /// Room Allotment leaves out rooms of the wrong type.
  final int? Function(AppUser) requiredFor;
  final bool isSuperAdmin;
  final bool bypass;
  final ValueChanged<bool> onBypass;
  final TextEditingController controller;
  final String query;
  final bool busy;
  final int maxShown;
  final ValueChanged<String> onQuery;
  final VoidCallback onCancel;
  final ValueChanged<AppUser> onPick;

  const _Picker({
    required this.hostel,
    required this.room,
    required this.roster,
    required this.requiredFor,
    required this.isSuperAdmin,
    required this.bypass,
    required this.onBypass,
    required this.controller,
    required this.query,
    required this.busy,
    required this.maxShown,
    required this.onQuery,
    required this.onCancel,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    // The eligibility rule and its ordering live on the service, so they can
    // be tested directly and stay consistent with what `allot` will accept.
    final waiting = AllotmentService.bedCandidates(
      hostel: hostel,
      roster: roster,
    );

    // The seating policy, applied exactly as Room Allotment applies it:
    // a Single goes to students entitled to a Single, and so on.
    bool fits(AppUser u) {
      final need = requiredFor(u);
      return need == null || need == room.capacity;
    }

    final eligible = waiting.where(fits).toList();
    final hiddenByPolicy = waiting.length - eligible.length;

    // Counted separately only to explain the omission: silently dropping the
    // students a Boys/Girls hostel can't take looks like a missing roster.
    final hiddenByGender = roster
        .where(
          (u) =>
              u.isActive && !u.isGraduated && !u.isSuperAdmin && !u.isAllotted,
        )
        .where((u) => !AllotmentService.genderAllows(hostel.gender, u.gender))
        .length;

    final q = query.trim().toLowerCase();
    final matched = q.isEmpty
        ? eligible
        : eligible
              .where(
                (u) =>
                    u.name.toLowerCase().contains(q) ||
                    (u.enrollmentNo ?? '').toLowerCase().contains(q) ||
                    u.email.toLowerCase().contains(q),
              )
              .toList();

    final shown = matched.take(maxShown).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Who is moving in?',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
            ),
            TextButton(
              onPressed: busy ? null : onCancel,
              child: const Text('Cancel'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          autofocus: true,
          enabled: !busy,
          onChanged: onQuery,
          decoration: const InputDecoration(
            hintText: 'Search name, registration number or email',
            prefixIcon: Icon(Icons.search_rounded),
            isDense: true,
          ),
        ),
        const SizedBox(height: 10),
        if (busy)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (shown.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Text(
              waiting.isEmpty
                  ? 'Nobody is waiting for a room.'
                  : eligible.isEmpty
                  ? 'Nobody waiting is entitled to a '
                        '${roomTypeLabel(room.capacity)} room.'
                  : 'No unallotted student matches that search.',
              style: TextStyle(fontSize: 13, color: AppColors.textMuted),
            ),
          )
        else
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              children: [
                for (var i = 0; i < shown.length; i++) ...[
                  if (i > 0) Divider(height: 1, color: AppColors.border),
                  _CandidateRow(
                    student: shown[i],
                    inThisHostel: shown[i].hostelId == hostel.id,
                    onTap: () => onPick(shown[i]),
                  ),
                ],
              ],
            ),
          ),
        if (matched.length > shown.length) ...[
          const SizedBox(height: 8),
          Text(
            'Showing $maxShown of ${matched.length} — keep typing to narrow it '
            'down.',
            style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
          ),
        ],
        if (hiddenByPolicy > 0) ...[
          const SizedBox(height: 6),
          Text(
            '$hiddenByPolicy waiting student'
            '${hiddenByPolicy == 1 ? '' : 's'} not shown — the seating policy '
            'entitles them to a different room type than this '
            '${roomTypeLabel(room.capacity)}.',
            style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
          ),
        ],
        // Super Admin only, and per allotment — never in auto-allot.
        if (isSuperAdmin && (hiddenByPolicy > 0 || bypass)) ...[
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: bypass,
            onChanged: busy ? null : onBypass,
            title: const Text('Bypass course room allotment rules'),
            subtitle: const Text(
              'Super Admin: offer every waiting student for this room.',
            ),
          ),
        ],
        if (hiddenByGender > 0) ...[
          const SizedBox(height: 6),
          Text(
            '$hiddenByGender student${hiddenByGender == 1 ? '' : 's'} not '
            'shown — this is a ${hostel.gender.label} hostel.',
            style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
          ),
        ],
      ],
    );
  }
}

class _CandidateRow extends StatelessWidget {
  final AppUser student;
  final bool inThisHostel;
  final VoidCallback onTap;

  const _CandidateRow({
    required this.student,
    required this.inThisHostel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final u = student;
    final detail = [
      if ((u.enrollmentNo ?? '').isNotEmpty) u.enrollmentNo!,
      if ((u.trade ?? '').isNotEmpty) u.trade!,
      if (u.sem != null) 'Sem ${u.sem}',
    ].join('  ·  ');

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          u.name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13.5,
                          ),
                        ),
                      ),
                      if (inThisHostel) ...[
                        const SizedBox(width: 8),
                        StatusPill(
                          'IN THIS HOSTEL',
                          AppColors.primary,
                          AppColors.primarySoft,
                        ),
                      ],
                    ],
                  ),
                  if (detail.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      detail,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.add_circle_outline, size: 19, color: AppColors.primary),
          ],
        ),
      ),
    );
  }
}

// -------------------------------- banner --------------------------------

class _Banner extends StatelessWidget {
  final String text;
  final Color fg;
  final Color bg;

  const _Banner(this.text, this.fg, this.bg);

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(text, style: TextStyle(color: fg, fontSize: 12.5, height: 1.4)),
  );
}
