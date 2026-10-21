import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../models/app_user.dart';
import '../../services/reset_service.dart';

/// Confirmation, progress and outcome for the master student-data reset.
///
/// The one button that clears an entire intake. It is gated harder than the
/// other Danger Zone rows because it is the only one you cannot partially
/// undo by re-running something else: the exact scope is spelled out in two
/// columns — gone and kept — before the confirmation box will even accept
/// input.
///
/// `collegeId` and `actor` are passed in rather than read from the context: a
/// dialog is pushed onto the root Navigator, so its context sits above
/// SessionScope and `Session.of` would throw. Same as [BulkDeleteUsersDialog].
class ResetStudentDataDialog extends StatefulWidget {
  final String collegeId;
  final AppUser actor;

  /// How many non-admin accounts exist right now, so the confirmation can
  /// state the real number instead of a vague "everyone".
  final int studentCount;

  const ResetStudentDataDialog({
    super.key,
    required this.collegeId,
    required this.actor,
    required this.studentCount,
  });

  @override
  State<ResetStudentDataDialog> createState() => _ResetStudentDataDialogState();
}

class _ResetStudentDataDialogState extends State<ResetStudentDataDialog> {
  static const _phrase = 'DELETE ALL STUDENTS';

  final _confirm = TextEditingController();
  bool _armed = false;
  bool _running = false;
  bool _stopRequested = false;

  ResetStage _stage = ResetStage.reading;
  int _done = 0;
  int _total = 0;

  StudentDataResetOutcome? _outcome;
  String? _error;

  @override
  void initState() {
    super.initState();
    _confirm.addListener(() {
      final ok = _confirm.text.trim().toUpperCase() == _phrase;
      if (ok != _armed) setState(() => _armed = ok);
    });
  }

  @override
  void dispose() {
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    setState(() {
      _running = true;
      _stopRequested = false;
      _error = null;
      _done = 0;
      _total = 0;
      _stage = ResetStage.reading;
    });
    try {
      final outcome = await ResetService.instance.resetStudentData(
        collegeId: widget.collegeId,
        actor: widget.actor,
        onProgress: (stage, done, total) {
          if (mounted) {
            setState(() {
              _stage = stage;
              _done = done;
              _total = total;
            });
          }
        },
        isCancelled: () => _stopRequested,
      );
      if (mounted) setState(() => _outcome = outcome);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      _outcome != null
          ? 'Student data cleared'
          : (_running ? 'Clearing…' : 'Delete all student data?'),
    ),
    content: SizedBox(
      width: 580,
      child: _outcome != null
          ? _Result(outcome: _outcome!)
          : (_running
                ? _Progress(stage: _stage, done: _done, total: _total)
                : _Confirm(
                    studentCount: widget.studentCount,
                    controller: _confirm,
                    phrase: _phrase,
                    error: _error,
                  )),
    ),
    actions: _outcome != null
        ? [
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Done'),
            ),
          ]
        : _running
        ? [
            TextButton(
              onPressed: _stopRequested
                  ? null
                  : () => setState(() => _stopRequested = true),
              child: Text(_stopRequested ? 'Stopping…' : 'Stop'),
            ),
          ]
        : [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
              onPressed: _armed ? _run : null,
              child: const Text('Delete everything'),
            ),
          ],
  );
}

class _Confirm extends StatelessWidget {
  final int studentCount;
  final TextEditingController controller;
  final String phrase;
  final String? error;

  const _Confirm({
    required this.studentCount,
    required this.controller,
    required this.phrase,
    this.error,
  });

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            color: AppColors.dangerSoft,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            '$studentCount account${studentCount == 1 ? '' : 's'} and every '
            'record attached to them will be permanently deleted. This cannot '
            'be undone from inside the app.',
            style: TextStyle(
              color: AppColors.danger,
              fontSize: 13,
              height: 1.45,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: 16),

        // Two columns, because the question people actually have is not "what
        // does this delete" but "will it take my hostels with it".
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Expanded(
                child: _ScopeList(
                  title: 'Deleted',
                  icon: Icons.close_rounded,
                  danger: true,
                  items: [
                    'Every student and staff profile',
                    'Their sign-in accounts (Firebase Auth)',
                    'All mess fee records',
                    'All fines, paid and unpaid',
                    'All requests and complaints',
                    'All academic records (every session\'s roster)',
                    'Room occupancy (who is in which bed)',
                  ],
                ),
              ),
              SizedBox(width: 20),
              Expanded(
                child: _ScopeList(
                  title: 'Kept',
                  icon: Icons.check_rounded,
                  danger: false,
                  items: [
                    'Hostels, blocks and rooms',
                    'College details and branding',
                    'Roles and permissions',
                    'Notices and office orders',
                    'Super Admins, including you',
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // The caveat that bites later, not now. Without it you clear the
        // roster, re-import the same registration numbers and get "email
        // already in use" with nothing to connect it to.
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            color: AppColors.warningSoft,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            'Sign-in accounts are removed by signing in as each student with '
            'their registration-number password — a few minutes for a few '
            'hundred students. Anyone who changed their password (and staff '
            'with a real one) can\'t be removed that way: they are listed at '
            'the end, and this clears them:\n'
            'tools/delete-students.js --orphans --commit',
            style: TextStyle(
              color: AppColors.warning,
              fontSize: 12.5,
              height: 1.5,
            ),
          ),
        ),
        const SizedBox(height: 18),

        Text(
          'Type $phrase to confirm',
          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: phrase, isDense: true),
        ),
        if (error != null) ...[
          const SizedBox(height: 10),
          Text(
            error!,
            style: TextStyle(color: AppColors.danger, fontSize: 12.5),
          ),
        ],
      ],
    ),
  );
}

class _ScopeList extends StatelessWidget {
  final String title;
  final IconData icon;
  final bool danger;
  final List<String> items;

  const _ScopeList({
    required this.title,
    required this.icon,
    required this.danger,
    required this.items,
  });

  @override
  Widget build(BuildContext context) {
    final color = danger ? AppColors.danger : AppColors.success;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            color: color,
            letterSpacing: 0.4,
          ),
        ),
        const SizedBox(height: 7),
        ...items.map(
          (t) => Padding(
            padding: const EdgeInsets.only(bottom: 5),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(icon, size: 14, color: color),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    t,
                    style: const TextStyle(fontSize: 12.5, height: 1.35),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Progress extends StatelessWidget {
  final ResetStage stage;
  final int done;
  final int total;

  const _Progress({
    required this.stage,
    required this.done,
    required this.total,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 34),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          stage.label,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        // Only the profile stage knows a total; the collection sweeps run to
        // exhaustion, so they get an indeterminate bar rather than a fake one.
        Text(
          total > 0 ? '$done of $total' : 'Working…',
          style: TextStyle(
            fontSize: total > 0 ? 27 : 14,
            fontWeight: total > 0 ? FontWeight.w800 : FontWeight.w500,
            color: total > 0 ? AppColors.textStrong : AppColors.textMuted,
          ),
        ),
        const SizedBox(height: 16),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: total > 0 ? done / total : null,
            minHeight: 8,
            backgroundColor: AppColors.border,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Leave this open until it finishes.',
          style: TextStyle(color: AppColors.textMuted, fontSize: 12.5),
        ),
      ],
    ),
  );
}

class _Result extends StatelessWidget {
  final StudentDataResetOutcome outcome;
  const _Result({required this.outcome});

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (outcome.stoppedEarly)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 14),
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: AppColors.warningSoft,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              'Stopped before finishing. Everything already deleted is gone. '
              'Run it again to clear the rest — nothing is double-deleted.',
              style: TextStyle(
                fontSize: 12.5,
                color: AppColors.warning,
                height: 1.45,
              ),
            ),
          ),
        Wrap(
          spacing: 30,
          runSpacing: 14,
          children: [
            _Tally(
              'Sign-in accounts',
              outcome.accountsDeleted,
              AppColors.success,
            ),
            _Tally('Profiles', outcome.profilesDeleted, AppColors.success),
            _Tally('Fee records', outcome.feeRecordsDeleted, AppColors.success),
            _Tally('Fines', outcome.finesDeleted, AppColors.success),
            _Tally('Requests', outcome.requestsDeleted, AppColors.success),
            _Tally(
              'Academic records',
              outcome.enrollmentsDeleted,
              AppColors.success,
            ),
            _Tally('Beds freed', outcome.bedsFreed, AppColors.info),
            _Tally('Admins kept', outcome.adminsKept, AppColors.info),
          ],
        ),
        // Only when some survived — named, because "email already in use" on
        // the next import is the symptom, and it needs connecting to a cause.
        if (outcome.accountsKept.isNotEmpty) ...[
          const SizedBox(height: 18),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: AppColors.warningSoft,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${outcome.accountsKept.length} sign-in account'
                  '${outcome.accountsKept.length == 1 ? '' : 's'} could not '
                  'be removed from the app. Re-importing them would fail with '
                  '"email already in use" — clear them with:\n'
                  'tools/delete-students.js --orphans --commit',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: AppColors.warning,
                    height: 1.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 150),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final k in outcome.accountsKept)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 3),
                            child: Text(
                              k.split(':').first,
                              style: TextStyle(
                                fontSize: 12,
                                color: AppColors.warning,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        if (outcome.failures.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(
            'These stages did not complete:',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: AppColors.danger,
            ),
          ),
          const SizedBox(height: 6),
          ...outcome.failures.map(
            (f) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                f,
                style: TextStyle(fontSize: 12.5, color: AppColors.danger),
              ),
            ),
          ),
        ],
      ],
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
          fontSize: 24,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    ],
  );
}
