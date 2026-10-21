import 'package:flutter/material.dart';

import '../../core/permissions.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../models/fine.dart';
import '../../services/auth_service.dart';
import '../../services/fine_service.dart';
import 'fines_overview_view.dart';
import 'fines_shared.dart';
import 'impose_fine_view.dart';

/// Fines: one page, two audiences.
///
/// Staff holding `fines.viewAll` get the register plus a button through to the
/// analytics dashboard. A resident holding only `fines.viewOwn` gets their own
/// list.
///
/// Note the "only": `Session.can` short-circuits to true for a Super Admin, so
/// asking `can(finesViewOwn)` alone would show the owner a "My fines" view for
/// fines nobody will ever impose on them. Anyone who can see everyone's fines
/// can already find their own in the register, so viewAll supersedes viewOwn
/// rather than sitting alongside it.
class FinesPage extends StatefulWidget {
  const FinesPage({super.key});

  @override
  State<FinesPage> createState() => _FinesPageState();
}

class _FinesPageState extends State<FinesPage> {
  bool _imposing = false;
  bool _overview = false;
  String _query = '';
  String? _status;

  Future<void> _deleteAllFines(String collegeId) async {
    const phrase = 'DELETE FINES';
    final controller = TextEditingController();
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setLocal) => AlertDialog(
          title: const Text('Delete every fine?'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Every fine in this workspace will be removed — including '
                  'ones already marked paid. This cannot be undone.',
                  style: TextStyle(fontSize: 13, height: 1.5),
                ),
                const SizedBox(height: 16),
                Text(
                  'Type $phrase to confirm',
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: phrase,
                    isDense: true,
                  ),
                  onChanged: (_) => setLocal(() {}),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
              onPressed: controller.text.trim().toUpperCase() == phrase
                  ? () => Navigator.pop(c, true)
                  : null,
              child: const Text('Delete all'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (ok != true) return;

    try {
      final n = await FineService.instance.deleteAll(collegeId);
      messenger.showSnackBar(SnackBar(content: Text('Deleted $n fine(s)')));
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

    final canViewAll = session.can(Perm.finesViewAll);
    final canManage = session.can(Perm.finesManage);
    final showsMine = session.can(Perm.finesViewOwn) && !canViewAll;

    if (_imposing) {
      return ImposeFineView(
        onBack: () => setState(() => _imposing = false),
        onDone: () => setState(() => _imposing = false),
      );
    }

    if (_overview && canViewAll) {
      return FinesOverviewView(
        collegeId: collegeId,
        onBack: () => setState(() => _overview = false),
      );
    }

    if (!canViewAll && !showsMine) {
      return AppCard(
        padding: EdgeInsets.symmetric(vertical: 54),
        child: Center(
          child: Text(
            'You don\'t have access to fines.',
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
              SectionHeader(
                'Fines',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (canManage) ...[
                      OutlinedButton.icon(
                        onPressed: () => _deleteAllFines(collegeId),
                        icon: Icon(
                          Icons.delete_sweep_rounded,
                          size: 18,
                          color: AppColors.danger,
                        ),
                        label: Text(
                          'Delete all',
                          style: TextStyle(color: AppColors.danger),
                        ),
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(color: AppColors.dangerSoft),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                    ],
                    if (canViewAll) ...[
                      OutlinedButton.icon(
                        onPressed: () => setState(() => _overview = true),
                        icon: const Icon(Icons.insights_rounded, size: 18),
                        label: const Text('Overview'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                    ],
                    if (canManage)
                      ElevatedButton.icon(
                        onPressed: () => setState(() => _imposing = true),
                        icon: const Icon(Icons.add_rounded, size: 18),
                        label: const Text('Impose fine'),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 14,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Text(
                canViewAll
                    ? 'Every fine on record. Open Overview for the dashboard.'
                    : 'Fines raised against you, and what is still owed.',
                style: TextStyle(fontSize: 13, color: AppColors.textMuted),
              ),
              if (canViewAll) ...[
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        onChanged: (v) => setState(() => _query = v),
                        decoration: const InputDecoration(
                          hintText:
                              'Search student, registration number, '
                              'room or reason',
                          prefixIcon: Icon(Icons.search_rounded),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 160,
                      child: DropdownButtonFormField<String>(
                        initialValue: _status,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Status',
                          isDense: true,
                        ),
                        hint: const Text('All'),
                        items: [
                          const DropdownMenuItem<String>(
                            value: null,
                            child: Text('All'),
                          ),
                          ...FineStatus.values.map(
                            (s) => DropdownMenuItem(
                              value: s.name,
                              child: Text(s.label),
                            ),
                          ),
                        ],
                        onChanged: (v) => setState(() => _status = v),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 18),
        if (canViewAll)
          _Register(
            collegeId: collegeId,
            canManage: canManage,
            query: _query,
            status: _status,
          )
        else
          _MyFines(collegeId: collegeId, uid: session.user.uid),
      ],
    );
  }
}

// ------------------------------- register -------------------------------

class _Register extends StatelessWidget {
  final String collegeId;
  final bool canManage;
  final String query;
  final String? status;

  const _Register({
    required this.collegeId,
    required this.canManage,
    required this.query,
    required this.status,
  });

  bool _keep(Fine f) {
    if (status != null && f.status.name != status) return false;
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return f.studentName.toLowerCase().contains(q) ||
        (f.studentRegNo ?? '').toLowerCase().contains(q) ||
        (f.roomNumber ?? '').toLowerCase().contains(q) ||
        f.category.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Fine>>(
      stream: FineService.instance.watchAll(collegeId),
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

        final all = snap.data!;
        if (all.isEmpty) {
          return AppCard(
            padding: EdgeInsets.symmetric(vertical: 60, horizontal: 28),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.gavel_rounded,
                    size: 34,
                    color: AppColors.textMuted,
                  ),
                  SizedBox(height: 14),
                  Text(
                    'No fines have been imposed yet',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                  SizedBox(height: 6),
                  Text(
                    'Impose the first one and the dashboard fills in.',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 13),
                  ),
                ],
              ),
            ),
          );
        }

        final shown = all.where(_keep).toList();
        final summary = FineSummary(shown);

        if (shown.isEmpty) {
          return AppCard(
            padding: EdgeInsets.symmetric(vertical: 54),
            child: Center(
              child: Text(
                'No fines match that search.',
                style: TextStyle(color: AppColors.textMuted),
              ),
            ),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppCard(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              child: Wrap(
                spacing: 34,
                runSpacing: 12,
                children: [
                  _Stat('Showing', '${summary.count}', AppColors.primary),
                  _Stat(
                    'Total',
                    '₹${compactAmount(summary.total)}',
                    AppColors.textStrong,
                  ),
                  _Stat(
                    'Outstanding',
                    '₹${compactAmount(summary.outstanding)}',
                    summary.outstanding == 0
                        ? AppColors.success
                        : AppColors.danger,
                  ),
                  _Stat(
                    'Collected',
                    '₹${compactAmount(summary.collected)}',
                    AppColors.success,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            AppCard(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                children: [
                  for (var i = 0; i < shown.length; i++) ...[
                    FineRow(
                      fine: shown[i],
                      showWho: true,
                      canManage: canManage,
                      collegeId: collegeId,
                    ),
                    if (i != shown.length - 1)
                      Divider(
                        height: 1,
                        indent: 20,
                        endIndent: 20,
                        color: AppColors.border,
                      ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

// ------------------------------ student view ------------------------------

class _MyFines extends StatelessWidget {
  final String collegeId;
  final String uid;

  const _MyFines({required this.collegeId, required this.uid});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Fine>>(
      stream: FineService.instance.watchMine(collegeId, uid),
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

        final mine = snap.data!;
        if (mine.isEmpty) {
          return AppCard(
            padding: EdgeInsets.symmetric(vertical: 56, horizontal: 28),
            child: Center(
              child: Text(
                'You have no fines. Keep it that way.',
                style: TextStyle(color: AppColors.textMuted),
              ),
            ),
          );
        }

        final summary = FineSummary(mine);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppCard(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              child: Wrap(
                spacing: 34,
                runSpacing: 12,
                children: [
                  _Stat(
                    'Still owed',
                    '₹${compactAmount(summary.outstanding)}',
                    summary.outstanding == 0
                        ? AppColors.success
                        : AppColors.danger,
                  ),
                  _Stat('On record', '${summary.count}', AppColors.primary),
                  _Stat(
                    'Paid so far',
                    '₹${compactAmount(summary.collected)}',
                    AppColors.success,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            AppCard(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                children: [
                  for (var i = 0; i < mine.length; i++) ...[
                    FineRow(
                      fine: mine[i],
                      showWho: false,
                      canManage: false,
                      collegeId: collegeId,
                    ),
                    if (i != mine.length - 1)
                      Divider(
                        height: 1,
                        indent: 20,
                        endIndent: 20,
                        color: AppColors.border,
                      ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _Stat(this.label, this.value, this.color);

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: AppColors.textMuted,
        ),
      ),
      const SizedBox(height: 2),
      Text(
        value,
        style: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    ],
  );
}
