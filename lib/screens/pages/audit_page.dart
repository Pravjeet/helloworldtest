import 'package:flutter/material.dart';

import '../../core/permissions.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../models/audit_entry.dart';
import '../../services/audit_service.dart';
import '../../services/auth_service.dart';

/// The record of what changed, with an undo button where one is honest.
///
/// Two things kept it from becoming a wall of noise: entries are grouped under
/// day headings, and undo is *offered* only when it will actually work —
/// otherwise the button is disabled with the reason on it, rather than failing
/// after the click.
class AuditPage extends StatefulWidget {
  const AuditPage({super.key});

  @override
  State<AuditPage> createState() => _AuditPageState();
}

class _AuditPageState extends State<AuditPage> {
  String _query = '';
  String? _module;
  bool _onlyUndoable = false;

  @override
  Widget build(BuildContext context) {
    final session = Session.of(context);
    final collegeId = session.user.collegeId;

    if (!session.can(Perm.settingsManage)) {
      return AppCard(
        padding: const EdgeInsets.symmetric(vertical: 54),
        child: Center(
          child: Text(
            'You don\'t have permission to view the activity log.',
            style: TextStyle(color: AppColors.textMuted),
          ),
        ),
      );
    }

    return StreamBuilder<List<AuditEntry>>(
      stream: AuditService.instance.watch(collegeId),
      builder: (context, snap) {
        if (snap.hasError) {
          return AppCard(child: Text(AuthService.describeError(snap.error!)));
        }

        final all = snap.data ?? const <AuditEntry>[];
        final q = _query.trim().toLowerCase();
        final shown = all.where((e) {
          if (_module != null && e.module != _module) return false;
          if (_onlyUndoable && !e.canUndo) return false;
          if (q.isEmpty) return true;
          return e.summary.toLowerCase().contains(q) ||
              e.actorName.toLowerCase().contains(q) ||
              e.targetLabel.toLowerCase().contains(q);
        }).toList();

        final modulesPresent = all.map((e) => e.module).toSet().toList()
          ..sort();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SectionHeader(
                    'Activity log',
                    trailing: Text(
                      '${all.where((e) => e.canUndo).length} undoable',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Recent changes across the workspace. Anything still '
                    'within 24 hours can be undone.',
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.textMuted,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          onChanged: (v) => setState(() => _query = v),
                          decoration: const InputDecoration(
                            hintText: 'Search what changed, or who changed it',
                            prefixIcon: Icon(Icons.search_rounded),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 180,
                        child: DropdownButtonFormField<String>(
                          initialValue: modulesPresent.contains(_module)
                              ? _module
                              : null,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Area',
                            isDense: true,
                          ),
                          hint: const Text('All'),
                          items: [
                            const DropdownMenuItem<String>(
                              value: null,
                              child: Text('All'),
                            ),
                            ...modulesPresent.map(
                              (m) => DropdownMenuItem(
                                value: m,
                                child: Text(kAuditModules[m] ?? m),
                              ),
                            ),
                          ],
                          onChanged: (v) => setState(() => _module = v),
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilterChip(
                        label: const Text('Undoable only'),
                        selected: _onlyUndoable,
                        onSelected: (v) => setState(() => _onlyUndoable = v),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            if (!snap.hasData)
              const Padding(
                padding: EdgeInsets.all(60),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (all.isEmpty)
              AppCard(
                padding: const EdgeInsets.symmetric(
                  vertical: 60,
                  horizontal: 28,
                ),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.history_rounded,
                        size: 34,
                        color: AppColors.textMuted,
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        'Nothing recorded yet',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Changes appear here as they happen — deletions, fines, '
                        'fee records, role changes.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else if (shown.isEmpty)
              AppCard(
                padding: const EdgeInsets.symmetric(vertical: 54),
                child: Center(
                  child: Text(
                    'Nothing matches those filters.',
                    style: TextStyle(color: AppColors.textMuted),
                  ),
                ),
              )
            else
              _Grouped(entries: shown, collegeId: collegeId),
          ],
        );
      },
    );
  }
}

/// Entries under day headings — "Today", "Yesterday", then the date.
class _Grouped extends StatelessWidget {
  final List<AuditEntry> entries;
  final String collegeId;

  const _Grouped({required this.entries, required this.collegeId});

  @override
  Widget build(BuildContext context) {
    final groups = <String, List<AuditEntry>>{};
    for (final e in entries) {
      groups.putIfAbsent(_dayLabel(e.createdAt), () => []).add(e);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final entry in groups.entries) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 10),
            child: Text(
              entry.key.toUpperCase(),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.7,
                color: AppColors.textMuted,
              ),
            ),
          ),
          AppCard(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              children: [
                for (var i = 0; i < entry.value.length; i++) ...[
                  if (i != 0)
                    Divider(
                      height: 1,
                      indent: 20,
                      endIndent: 20,
                      color: AppColors.border,
                    ),
                  _EntryRow(entry: entry.value[i], collegeId: collegeId),
                ],
              ],
            ),
          ),
          const SizedBox(height: 18),
        ],
      ],
    );
  }

  static String _dayLabel(DateTime? t) {
    if (t == null) return 'Unknown';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(t.year, t.month, t.day);
    final diff = today.difference(that).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${t.day} ${months[t.month - 1]} ${t.year}';
  }
}

class _EntryRow extends StatefulWidget {
  final AuditEntry entry;
  final String collegeId;

  const _EntryRow({required this.entry, required this.collegeId});

  @override
  State<_EntryRow> createState() => _EntryRowState();
}

class _EntryRowState extends State<_EntryRow> {
  bool _busy = false;

  Future<void> _undo() async {
    final e = widget.entry;
    final messenger = ScaffoldMessenger.of(context);
    final session = Session.of(context);

    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Undo this change?'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(e.summary, style: const TextStyle(fontSize: 13.5)),
              const SizedBox(height: 12),
              Text(
                e.before == null
                    ? 'This will delete what was created.'
                    : 'This will restore the record exactly as it was before '
                          'the change — anything edited since will be '
                          'overwritten.',
                style: TextStyle(
                  fontSize: 12.5,
                  color: AppColors.textMuted,
                  height: 1.45,
                ),
              ),
              if (e.undoCaveat != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.warningSoft,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text(
                    e.undoCaveat!,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: AppColors.warning,
                      height: 1.45,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Undo'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _busy = true);
    try {
      await AuditService.instance.undo(
        collegeId: widget.collegeId,
        entry: e,
        actor: session.user,
      );
      messenger.showSnackBar(const SnackBar(content: Text('Change undone')));
    } catch (err) {
      messenger.showSnackBar(
        SnackBar(content: Text(AuthService.describeError(err))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final tone = switch (e.tone) {
      AuditTone.additive => AppColors.success,
      AuditTone.destructive => AppColors.danger,
      AuditTone.neutral => AppColors.primary,
    };

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        children: [
          Container(
            height: 34,
            width: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: tone.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(e.icon, size: 16, color: tone),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  e.summary,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    decoration: e.undone ? TextDecoration.lineThrough : null,
                    color: e.undone ? AppColors.textMuted : null,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    e.actorName,
                    if (e.createdAt != null) _time(e.createdAt!),
                    if (e.undone && e.undoneByName != null)
                      'undone by ${e.undoneByName}',
                  ].join(' · '),
                  style: TextStyle(
                    fontSize: 11.5,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (e.undone)
            StatusPill('UNDONE', AppColors.textMuted, AppColors.canvas)
          else if (e.canUndo)
            OutlinedButton.icon(
              onPressed: _busy ? null : _undo,
              icon: _busy
                  ? const SizedBox(
                      height: 13,
                      width: 13,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.undo_rounded, size: 15),
              label: const Text('Undo'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                textStyle: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
          else
            // Say why, rather than hiding the affordance and leaving them
            // wondering whether undo exists at all.
            Tooltip(
              message: e.undoBlockedReason ?? '',
              child: Text(
                e.undoBlockedReason ?? '',
                style: TextStyle(
                  fontSize: 11.5,
                  color: AppColors.textMuted,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
        ],
      ),
    );
  }

  static String _time(DateTime t) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m ${t.hour < 12 ? 'AM' : 'PM'}';
  }
}
