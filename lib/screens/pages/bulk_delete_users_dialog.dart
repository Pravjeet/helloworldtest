import 'package:flutter/material.dart';

import '../../core/identity.dart';
import '../../core/theme.dart';
import '../../models/app_user.dart';
import '../../services/data_service.dart';

/// Confirmation + progress for deleting a batch of user profiles.
///
/// Deliberately awkward to complete. It operates on whatever the Users page is
/// currently showing, which means a mistyped search box is the difference
/// between clearing 30 test students and clearing the whole institution — so
/// the count is stated plainly, the names are listed, and you have to type the
/// word before the button turns on.
///
/// `collegeId` is passed in rather than read from the context: a dialog is
/// pushed onto the root Navigator, so its context sits above SessionScope and
/// `Session.of` would throw. See the note on [ImportStudentsDialog].
class BulkDeleteUsersDialog extends StatefulWidget {
  final String collegeId;
  final List<AppUser> users;

  /// What the Users page was filtered by, echoed back so you can see whether
  /// this batch is the one you meant.
  final String scopeLabel;

  const BulkDeleteUsersDialog({
    super.key,
    required this.collegeId,
    required this.users,
    required this.scopeLabel,
  });

  @override
  State<BulkDeleteUsersDialog> createState() => _BulkDeleteUsersDialogState();
}

class _BulkDeleteUsersDialogState extends State<BulkDeleteUsersDialog> {
  static const _phrase = 'DELETE';

  final _confirm = TextEditingController();
  bool _armed = false;
  bool _running = false;
  bool _stopRequested = false;
  int _done = 0;
  BulkDeleteOutcome? _outcome;
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
    });
    try {
      final outcome = await DataService.instance.deleteUserProfiles(
        collegeId: widget.collegeId,
        users: widget.users,
        onProgress: (done, _) {
          if (mounted) setState(() => _done = done);
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
  Widget build(BuildContext context) {
    final n = widget.users.length;

    return AlertDialog(
      title: Text(
        _outcome != null
            ? 'Deleted'
            : (_running ? 'Deleting…' : 'Delete $n user${n == 1 ? '' : 's'}?'),
      ),
      content: SizedBox(
        width: 560,
        child: _outcome != null
            ? _Result(outcome: _outcome!)
            : (_running
                  ? _Progress(done: _done, total: n)
                  : _Confirm(
                      users: widget.users,
                      scopeLabel: widget.scopeLabel,
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
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.danger,
                ),
                onPressed: _armed ? _run : null,
                child: Text('Delete $n'),
              ),
            ],
    );
  }
}

class _Confirm extends StatelessWidget {
  final List<AppUser> users;
  final String scopeLabel;
  final TextEditingController controller;
  final String phrase;
  final String? error;

  const _Confirm({
    required this.users,
    required this.scopeLabel,
    required this.controller,
    required this.phrase,
    this.error,
  });

  @override
  Widget build(BuildContext context) {
    final allotted = users.where((u) => u.isAllotted).length;

    return Column(
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
            'This permanently deletes ${users.length} user profile'
            '${users.length == 1 ? '' : 's'} matching: $scopeLabel'
            '${allotted > 0 ? '\n\n$allotted of them hold a room — those beds '
                      'will be freed first.' : ''}',
            style: TextStyle(
              color: AppColors.danger,
              fontSize: 13,
              height: 1.45,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: 14),

        // The honest caveat. Without this you delete 30 profiles, try to
        // re-import the same registration numbers, and get "email already in
        // use" with no idea why.
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            color: AppColors.warningSoft,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            'Sign-in accounts go too, wherever the password is still the one '
            'derived from the registration number.\n\n'
            'Anyone who changed their password keeps their login — those are '
            'listed by name when this finishes, and '
            'tools/delete-students.js clears them properly.',
            style: TextStyle(
              color: AppColors.warning,
              fontSize: 12.5,
              height: 1.5,
            ),
          ),
        ),
        const SizedBox(height: 14),

        const Text(
          'About to delete:',
          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        Container(
          height: 132,
          width: double.infinity,
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(9),
          ),
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
            itemCount: users.length,
            itemBuilder: (context, i) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                '${users[i].name}  ·  ${Identity.display(users[i].email)}'
                '${users[i].roomLabel == null ? '' : '  ·  ${users[i].roomLabel}'}',
                style: const TextStyle(fontSize: 12, height: 1.4),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),

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
    );
  }
}

class _Progress extends StatelessWidget {
  final int done;
  final int total;
  const _Progress({required this.done, required this.total});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 40),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$done of $total',
          style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 16),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: total == 0 ? null : done / total,
            minHeight: 8,
            backgroundColor: AppColors.border,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Freeing rooms and removing profiles. Leave this open.',
          style: TextStyle(color: AppColors.textMuted, fontSize: 12.5),
        ),
      ],
    ),
  );
}

class _Result extends StatelessWidget {
  final BulkDeleteOutcome outcome;
  const _Result({required this.outcome});

  @override
  Widget build(BuildContext context) => Column(
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
            'Stopped early — ${outcome.remaining} user(s) were never '
            'attempted. Open the same filter and delete again to pick up '
            'where this left off.',
            style: TextStyle(
              fontSize: 12.5,
              color: AppColors.warning,
              height: 1.45,
            ),
          ),
        ),
      Wrap(
        spacing: 30,
        runSpacing: 12,
        children: [
          _Tally('Profiles deleted', outcome.deleted, AppColors.success),
          _Tally('Logins removed', outcome.authDeleted, AppColors.success),
          _Tally('Beds freed', outcome.vacated, AppColors.info),
          _Tally('Fines removed', outcome.finesDeleted, AppColors.info),
          _Tally('Requests removed', outcome.requestsDeleted, AppColors.info),
          _Tally('Fee records removed', outcome.feesDeleted, AppColors.info),
          _Tally('Problems', outcome.failures.length, AppColors.danger),
        ],
      ),
      if (outcome.authLeftBehind.isNotEmpty) ...[
        const SizedBox(height: 16),
        Text(
          'Profile gone, sign-in account still there:',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: AppColors.warning,
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 90,
          child: ListView(
            children: outcome.authLeftBehind
                .map(
                  (f) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      f,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: AppColors.warning,
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        ),
      ],
      if (outcome.failures.isNotEmpty) ...[
        const SizedBox(height: 16),
        const Text(
          'These need a look:',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 90,
          child: ListView(
            children: outcome.failures
                .map(
                  (f) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      f,
                      style: TextStyle(fontSize: 12.5, color: AppColors.danger),
                    ),
                  ),
                )
                .toList(),
          ),
        ),
      ],
    ],
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
