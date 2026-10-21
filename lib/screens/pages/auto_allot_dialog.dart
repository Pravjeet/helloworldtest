import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../models/app_user.dart';
import '../../models/hostel.dart';
import '../../services/allotment_service.dart';
import '../../services/auth_service.dart';
import '../../services/hostel_service.dart';
import '../../utils/enrollment_helpers.dart';

/// Allots a whole filtered group — "ICD 1st year", say — into one hostel in a
/// single click, filling rooms in series (101, 102, 103 …).
///
/// Three steps in one dialog: pick a hostel and read the plan, run it, read
/// the outcome. The plan is shown in full before anything is written, room by
/// room, because the point of the feature is to skip hundreds of clicks — not
/// to skip looking at what is about to happen to hundreds of students.
///
/// Everything comes in through the constructor: a dialog is pushed onto the
/// root Navigator, above SessionScope, so `Session.of` would throw here. See
/// [BulkDeleteUsersDialog] and `test/room_detail_dialog_test.dart`.
class AutoAllotDialog extends StatefulWidget {
  final String collegeId;
  final AppUser actor;
  final List<Hostel> hostels;

  /// The students waiting for a room under the page's current filters.
  final List<AppUser> students;

  /// Room capacity the seating policy entitles each student to this session,
  /// by uid, from their enrollment. Missing or null means no policy applies.
  final Map<String, int?> requiredCapacityByUid;

  /// What the page was filtered by, echoed back so you can see this is the
  /// group you meant — "UG — Graduation · 1st year".
  final String scopeLabel;

  const AutoAllotDialog({
    super.key,
    required this.collegeId,
    required this.actor,
    required this.hostels,
    required this.students,
    required this.requiredCapacityByUid,
    required this.scopeLabel,
  });

  @override
  State<AutoAllotDialog> createState() => _AutoAllotDialogState();
}

enum _Step { plan, running, done }

class _AutoAllotDialogState extends State<AutoAllotDialog> {
  _Step _step = _Step.plan;

  Hostel? _hostel;
  List<Room>? _rooms;
  bool _loadingRooms = false;
  String? _loadError;

  bool _includeOtherHostels = false;

  late final Set<String> _knownHostelIds = {
    for (final h in widget.hostels) h.id,
  };

  int _done = 0;
  int _total = 0;
  bool _stopRequested = false;
  AutoAllotOutcome? _outcome;
  String? _runError;

  @override
  void initState() {
    super.initState();
    // Start on the hostel most of this group is already recorded against —
    // after an import that is nearly always the one the warden wants.
    final counts = <String, int>{};
    for (final u in widget.students) {
      // Only hostels that still exist — a deleted hostel's id lingers on its
      // students, and would otherwise win the vote and preselect nothing.
      final id = u.hostelId;
      if (id != null && _knownHostelIds.contains(id)) {
        counts[id] = (counts[id] ?? 0) + 1;
      }
    }
    if (counts.isNotEmpty) {
      final top = counts.entries.reduce((a, b) => b.value > a.value ? b : a);
      final match = widget.hostels.where((h) => h.id == top.key);
      if (match.isNotEmpty) {
        _hostel = match.first;
        _loadingRooms = true;
        _loadRooms(match.first);
      }
    }
  }

  void _pickHostel(Hostel h) {
    setState(() {
      _hostel = h;
      _rooms = null;
      _loadError = null;
      _loadingRooms = true;
      // Moving people out of their hostel is opted into per hostel — a
      // switch left on from the last pick would silently move a different
      // group.
      _includeOtherHostels = false;
    });
    _loadRooms(h);
  }

  Future<void> _loadRooms(Hostel h) async {
    try {
      final rooms = await HostelService.instance.roomsOnce(
        widget.collegeId,
        h.id,
      );
      if (!mounted || _hostel?.id != h.id) return;
      setState(() {
        _rooms = rooms;
        _loadingRooms = false;
      });
    } catch (e) {
      if (!mounted || _hostel?.id != h.id) return;
      setState(() {
        _loadError = AuthService.describeError(e);
        _loadingRooms = false;
      });
    }
  }

  AutoAllotPlan? get _plan {
    final hostel = _hostel;
    final rooms = _rooms;
    if (hostel == null || rooms == null) return null;
    return AllotmentService.planAutoAllot(
      hostel: hostel,
      rooms: rooms,
      students: widget.students,
      // Always the seating policy: bypassing it is a Super Admin decision
      // about one student at a time, never a whole group in one click.
      requiredCapacityOf: (u) => widget.requiredCapacityByUid[u.uid],
      includeOtherHostels: _includeOtherHostels,
      knownHostelIds: _knownHostelIds,
    );
  }

  bool get _anyPolicy =>
      widget.students.any((u) => widget.requiredCapacityByUid[u.uid] != null);

  Future<void> _run(AutoAllotPlan plan) async {
    setState(() {
      _step = _Step.running;
      _done = 0;
      _total = plan.assignments.length;
      _stopRequested = false;
    });
    try {
      final outcome = await AllotmentService.instance.runAutoAllot(
        collegeId: widget.collegeId,
        hostel: _hostel!,
        assignments: plan.assignments,
        actor: widget.actor,
        onProgress: (done, total) {
          if (mounted) setState(() => _done = done);
        },
        isCancelled: () => _stopRequested,
      );
      if (!mounted) return;
      setState(() {
        _outcome = outcome;
        _step = _Step.done;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _runError = AuthService.describeError(e);
        _step = _Step.done;
      });
    }
  }

  static String _hostelLabel(Hostel h) =>
      h.code.trim().isEmpty ? h.name : h.code;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _step != _Step.running,
      child: AlertDialog(
        title: Text(switch (_step) {
          _Step.plan => 'Auto-allot rooms',
          _Step.running => 'Allotting…',
          _Step.done => 'Auto-allot finished',
        }),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620, minWidth: 420),
          child: SingleChildScrollView(
            child: switch (_step) {
              _Step.plan => _planBody(),
              _Step.running => _runningBody(),
              _Step.done => _doneBody(),
            },
          ),
        ),
        actions: switch (_step) {
          _Step.plan => [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            Builder(
              builder: (context) {
                final plan = _plan;
                final n = plan?.assignments.length ?? 0;
                return FilledButton.icon(
                  onPressed: n == 0 ? null : () => _run(plan!),
                  icon: const Icon(Icons.bolt_rounded, size: 18),
                  label: Text(
                    n == 0 ? 'Allot' : 'Allot $n student${n == 1 ? '' : 's'}',
                  ),
                );
              },
            ),
          ],
          _Step.running => [
            TextButton(
              onPressed: _stopRequested
                  ? null
                  : () => setState(() => _stopRequested = true),
              child: Text(_stopRequested ? 'Stopping…' : 'Stop'),
            ),
          ],
          _Step.done => [
            FilledButton(
              onPressed: () =>
                  Navigator.pop(context, (_outcome?.allotted ?? 0) > 0),
              child: const Text('Close'),
            ),
          ],
        },
      ),
    );
  }

  // ------------------------------------------------------------ plan step

  Widget _planBody() {
    final hostels = [...widget.hostels]..sort(Hostel.compareByCode);
    final plan = _plan;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '${widget.scopeLabel} · ${widget.students.length} waiting for a '
          'room',
          style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        Text(
          'Rooms are filled in order — 101, 102, 103 … — each one full before '
          'the next. Students go in registration-number order, so classmates '
          'end up together.',
          style: TextStyle(
            fontSize: 12.5,
            height: 1.45,
            color: AppColors.textMuted,
          ),
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          initialValue: _hostel?.id,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Hostel', isDense: true),
          items: [
            for (final h in hostels)
              DropdownMenuItem(
                value: h.id,
                child: Text(
                  '${_hostelLabel(h)} · ${h.freeBeds} free bed'
                  '${h.freeBeds == 1 ? '' : 's'} · ${h.gender.label}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (id) {
            if (id == null) return;
            _pickHostel(hostels.firstWhere((h) => h.id == id));
          },
        ),
        const SizedBox(height: 14),
        if (_hostel == null)
          Text(
            'Pick the hostel to fill.',
            style: TextStyle(fontSize: 12.5, color: AppColors.textMuted),
          )
        else if (_loadingRooms)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 18),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_loadError != null)
          Text(_loadError!, style: TextStyle(color: AppColors.danger))
        else if (plan != null)
          _planSummary(plan),
      ],
    );
  }

  Widget _planSummary(AutoAllotPlan plan) {
    final rooms = plan.rooms;
    final n = plan.assignments.length;
    final hostel = _hostelLabel(_hostel!);
    final moving = plan.assignments
        .where(
          (a) =>
              a.student.hostelId != null &&
              a.student.hostelId != _hostel!.id &&
              _knownHostelIds.contains(a.student.hostelId),
        )
        .length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (n > 0)
          _Note(
            '$n student${n == 1 ? '' : 's'} into ${rooms.length} '
            'room${rooms.length == 1 ? '' : 's'} of $hostel: '
            '${rooms.first.number}'
            '${rooms.length > 1 ? ' → ${rooms.last.number}' : ''}',
            AppColors.success,
          )
        else if (plan.noRoomOfType.isEmpty &&
            plan.typeOutOfService.isEmpty &&
            plan.noBed.isEmpty)
          _Note(
            'Nobody in this group can be placed in $hostel.',
            AppColors.warning,
          ),
        // The policy asks for a room type this hostel simply doesn't have.
        // Saying it "ran out" would send the warden looking for free beds
        // that would never help.
        for (final e in plan.missingTypes.entries)
          _Note(
            '${e.value} ${e.value == 1 ? 'is' : 'are'} entitled to a '
            '${roomTypeLabel(e.key)} by the seating policy, and $hostel has '
            'no ${roomTypeLabel(e.key)} rooms. Pick another hostel for them.',
            AppColors.warning,
          ),
        for (final e in plan.outOfServiceTypes.entries)
          _Note(
            '${e.value} ${e.value == 1 ? 'needs' : 'need'} a '
            '${roomTypeLabel(e.key)}, and every ${roomTypeLabel(e.key)} in '
            '$hostel is under maintenance or reserved. Make some active '
            'under Hostels & Rooms, or pick another hostel.',
            AppColors.warning,
          ),
        if (plan.noBed.isNotEmpty)
          _Note(
            '${plan.noBed.length} won\'t fit — $hostel runs out of free '
            '${_anyPolicy ? 'beds of the type they need' : 'beds'}. '
            'Run again with another hostel for them.',
            AppColors.warning,
          ),
        if (plan.otherHostel.isNotEmpty)
          _Note(
            '${plan.otherHostel.length} '
            '${plan.otherHostel.length == 1 ? 'is' : 'are'} left out because '
            'they\'re recorded in another hostel.',
            AppColors.info,
          ),
        if (moving > 0)
          _Note(
            '$moving will be moved here from the hostel they\'re recorded in.',
            AppColors.warning,
          ),
        if (plan.ineligible.isNotEmpty)
          _Note(
            '${plan.ineligible.length} can\'t go in a ${_hostel!.gender.label} '
            'hostel or aren\'t active, and are skipped.',
            AppColors.info,
          ),
        if (_anyPolicy)
          _Note(
            'Each student only gets the room type the seating policy entitles '
            'them to.',
            AppColors.info,
          ),
        if (plan.otherHostel.isNotEmpty || _includeOtherHostels)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _includeOtherHostels,
            onChanged: (v) => setState(() => _includeOtherHostels = v),
            title: const Text('Include students recorded in another hostel'),
            subtitle: Text('They will be moved to $hostel.'),
          ),
        if (n > 0) ...[
          const SizedBox(height: 10),
          Text(
            'Plan',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: AppColors.textMuted,
            ),
          ),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260),
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.border),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final room in rooms)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text:
                                    'Room ${room.number} '
                                    '(${roomTypeLabel(room.capacity)})  ',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              TextSpan(
                                text: plan.assignments
                                    .where((a) => a.room.id == room.id)
                                    .map(
                                      (a) =>
                                          '${a.student.name}'
                                          '${a.student.enrollmentNo == null ? '' : ' (${a.student.enrollmentNo})'}',
                                    )
                                    .join(', '),
                              ),
                            ],
                          ),
                          style: const TextStyle(fontSize: 12.5, height: 1.4),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  // --------------------------------------------------------- running step

  Widget _runningBody() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        '$_done of $_total',
        style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 12),
      ClipRRect(
        borderRadius: BorderRadius.circular(5),
        child: LinearProgressIndicator(
          value: _total == 0 ? null : _done / _total,
          minHeight: 8,
          backgroundColor: AppColors.border,
        ),
      ),
      const SizedBox(height: 12),
      Text(
        _stopRequested
            ? 'Finishing the beds already in progress, then stopping.'
            : 'Please leave this window open until it finishes.',
        style: TextStyle(fontSize: 12.5, color: AppColors.textMuted),
      ),
    ],
  );

  // ------------------------------------------------------------ done step

  Widget _doneBody() {
    final outcome = _outcome;
    if (outcome == null) {
      return Text(
        _runError ?? 'Something went wrong.',
        style: TextStyle(color: AppColors.danger),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: 30,
          runSpacing: 12,
          children: [
            _Tally('Allotted', outcome.allotted, AppColors.success),
            _Tally(
              'Refused',
              outcome.failures.length,
              outcome.failures.isEmpty ? AppColors.textMuted : AppColors.danger,
            ),
          ],
        ),
        if (outcome.stoppedEarly) ...[
          const SizedBox(height: 12),
          _Note(
            'Stopped early. Running auto-allot again picks up whoever is '
            'still waiting.',
            AppColors.warning,
          ),
        ],
        if (outcome.failures.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            'Not allotted — usually someone else took the bed or changed the '
            'student a moment earlier. Run it again to place them:',
            style: TextStyle(fontSize: 12.5, color: AppColors.textMuted),
          ),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 200),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final f in outcome.failures)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        f,
                        style: TextStyle(fontSize: 12, color: AppColors.danger),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _Note extends StatelessWidget {
  final String text;
  final Color color;
  const _Note(this.text, this.color);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 13,
        height: 1.4,
        fontWeight: FontWeight.w600,
        color: color,
      ),
    ),
  );
}

class _Tally extends StatelessWidget {
  final String label;
  final int value;
  final Color color;
  const _Tally(this.label, this.value, this.color);

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: AppColors.textMuted,
        ),
      ),
      Text(
        '$value',
        style: TextStyle(
          fontSize: 26,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    ],
  );
}
