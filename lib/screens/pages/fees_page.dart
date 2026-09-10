import 'package:flutter/material.dart';

import '../../core/permissions.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../models/app_user.dart';
import '../../models/fee.dart';
import '../../models/mess.dart';
import '../../services/auth_service.dart';
import '../../services/data_service.dart';
import '../../services/fee_service.dart';
import '../../services/mess_service.dart';

/// Mess fees — status, not payment.
///
/// The app never takes money and deliberately has no gateway. Everyone pays
/// the same monthly mess charge (from Mess → Fees), so there is nothing to
/// calculate per student: the only facts worth recording are *did it arrive*
/// and *when*.
///
/// Staff with `fees.viewAll` get a month roster they can tick down. A resident
/// with `fees.viewOwn` sees their own months.
class FeesPage extends StatefulWidget {
  const FeesPage({super.key});

  @override
  State<FeesPage> createState() => _FeesPageState();
}

class _FeesPageState extends State<FeesPage> {
  late String _period = periodOf(DateTime.now());
  String _query = '';
  String? _hostel;
  String? _status;

  @override
  Widget build(BuildContext context) {
    final session = Session.of(context);
    final collegeId = session.user.collegeId;

    final canViewAll = session.can(Perm.feesViewAll);
    final canManage = session.can(Perm.feesManage);
    // As with fines: can() short-circuits for a Super Admin, so viewAll has to
    // supersede viewOwn or the owner sees a "my fees" page for fees nobody
    // will ever charge them.
    final showsMine = session.can(Perm.feesViewOwn) && !canViewAll;

    if (!canViewAll && !showsMine) {
      return AppCard(
        padding: const EdgeInsets.symmetric(vertical: 54),
        child: Center(
          child: Text(
            'You don\'t have access to mess fees.',
            style: TextStyle(color: AppColors.textMuted),
          ),
        ),
      );
    }

    return StreamBuilder<MessConfig>(
      stream: MessService.instance.watchConfig(collegeId),
      builder: (context, cfgSnap) {
        final config = cfgSnap.data ?? const MessConfig();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SectionHeader(
                    'Mess Fees',
                    trailing: canViewAll
                        ? _PeriodPicker(
                            value: _period,
                            onChanged: (v) => setState(() => _period = v),
                          )
                        : null,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    canViewAll
                        ? 'Who has paid this month. The app records status '
                              'only — it does not take payments.'
                        : 'Your monthly mess fee status.',
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.textMuted,
                    ),
                  ),
                  if (!config.isConfigured) ...[
                    const SizedBox(height: 14),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.warningSoft,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Text(
                        'No monthly mess charge is set yet. Set it under '
                        'Mess → Fees and it will be used here.',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: AppColors.warning,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 18),
            if (canViewAll)
              _Roster(
                collegeId: collegeId,
                period: _period,
                amount: config.monthlyCharge,
                symbol: config.currencySymbol,
                canManage: canManage,
                query: _query,
                hostel: _hostel,
                status: _status,
                onQuery: (v) => setState(() => _query = v),
                onHostel: (v) => setState(() => _hostel = v),
                onStatus: (v) => setState(() => _status = v),
              )
            else
              _MyFees(
                collegeId: collegeId,
                uid: session.user.uid,
                amount: config.monthlyCharge,
                symbol: config.currencySymbol,
              ),
          ],
        );
      },
    );
  }
}

// ---------------------------- period picker ----------------------------

class _PeriodPicker extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;

  const _PeriodPicker({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final periods = recentPeriods(DateTime.now());
    // A period saved before this window (an old record being reviewed) must
    // still be selectable, or the dropdown would assert on an absent value.
    final options = periods.contains(value) ? periods : [value, ...periods];

    return SizedBox(
      width: 210,
      child: DropdownButtonFormField<String>(
        initialValue: value,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Month', isDense: true),
        items: options
            .map(
              (p) => DropdownMenuItem(value: p, child: Text(periodLabel(p))),
            )
            .toList(),
        onChanged: (v) => v == null ? null : onChanged(v),
      ),
    );
  }
}

// -------------------------------- roster --------------------------------

class _Roster extends StatelessWidget {
  final String collegeId;
  final String period;
  final num amount;
  final String symbol;
  final bool canManage;
  final String query;
  final String? hostel;
  final String? status;
  final ValueChanged<String> onQuery;
  final ValueChanged<String?> onHostel;
  final ValueChanged<String?> onStatus;

  const _Roster({
    required this.collegeId,
    required this.period,
    required this.amount,
    required this.symbol,
    required this.canManage,
    required this.query,
    required this.hostel,
    required this.status,
    required this.onQuery,
    required this.onHostel,
    required this.onStatus,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<AppUser>>(
      stream: DataService.instance.watchUsers(collegeId),
      builder: (context, userSnap) {
        if (userSnap.hasError) {
          return AppCard(
            child: Text(AuthService.describeError(userSnap.error!)),
          );
        }

        return StreamBuilder<List<FeeRecord>>(
          stream: FeeService.instance.watchPeriod(collegeId, period),
          builder: (context, feeSnap) {
            if (feeSnap.hasError) {
              return AppCard(
                child: Text(AuthService.describeError(feeSnap.error!)),
              );
            }
            if (!userSnap.hasData || !feeSnap.hasData) {
              return const Padding(
                padding: EdgeInsets.all(60),
                child: Center(child: CircularProgressIndicator()),
              );
            }

            // Only residents owe a mess fee — staff and the owner do not.
            // Allotment is the honest test for "lives here", and it is data,
            // not a role name.
            final students = userSnap.data!
                .where((u) => !u.isSuperAdmin)
                .where((u) => u.isAllotted)
                .toList()
              ..sort((a, b) => a.name.compareTo(b.name));

            final all = FeeService.standingsFor(
              students: students,
              records: feeSnap.data!,
            );
            final summary = FeeSummary(standings: all, amountEach: amount);

            final hostels =
                students
                    .map((s) => s.hostelName)
                    .whereType<String>()
                    .toSet()
                    .toList()
                  ..sort();

            final q = query.trim().toLowerCase();
            final shown = all.where((s) {
              if (hostel != null && s.hostelName != hostel) return false;
              if (status == 'paid' && !s.isPaid) return false;
              if (status == 'unpaid' && s.isPaid) return false;
              if (q.isEmpty) return true;
              return s.studentName.toLowerCase().contains(q) ||
                  (s.studentRegNo ?? '').toLowerCase().contains(q) ||
                  (s.roomNumber ?? '').toLowerCase().contains(q);
            }).toList();

            final unpaidShown = shown.where((s) => !s.isPaid).toList();

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SummaryBar(summary: summary, symbol: symbol),
                const SizedBox(height: 18),
                AppCard(
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          onChanged: onQuery,
                          decoration: const InputDecoration(
                            hintText: 'Search name, registration number '
                                'or room',
                            prefixIcon: Icon(Icons.search_rounded),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 180,
                        child: DropdownButtonFormField<String>(
                          initialValue: hostels.contains(hostel)
                              ? hostel
                              : null,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Hostel',
                            isDense: true,
                          ),
                          hint: const Text('All'),
                          items: [
                            const DropdownMenuItem<String>(
                              value: null,
                              child: Text('All'),
                            ),
                            ...hostels.map(
                              (h) => DropdownMenuItem(value: h, child: Text(h)),
                            ),
                          ],
                          onChanged: onHostel,
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 150,
                        child: DropdownButtonFormField<String>(
                          initialValue: status,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Status',
                            isDense: true,
                          ),
                          hint: const Text('All'),
                          items: const [
                            DropdownMenuItem(value: null, child: Text('All')),
                            DropdownMenuItem(value: 'paid', child: Text('Paid')),
                            DropdownMenuItem(
                              value: 'unpaid',
                              child: Text('Unpaid'),
                            ),
                          ],
                          onChanged: onStatus,
                        ),
                      ),
                      if (canManage && unpaidShown.isNotEmpty) ...[
                        const SizedBox(width: 12),
                        _MarkAllButton(
                          collegeId: collegeId,
                          period: period,
                          amount: amount,
                          students: students
                              .where(
                                (u) => unpaidShown.any(
                                  (s) => s.studentUid == u.uid,
                                ),
                              )
                              .toList(),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                if (students.isEmpty)
                  AppCard(
                    padding: const EdgeInsets.symmetric(
                      vertical: 54,
                      horizontal: 28,
                    ),
                    child: Center(
                      child: Text(
                        'No students have been allotted a room yet — mess fees '
                        'apply to residents.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppColors.textMuted),
                      ),
                    ),
                  )
                else if (shown.isEmpty)
                  AppCard(
                    padding: const EdgeInsets.symmetric(vertical: 54),
                    child: Center(
                      child: Text(
                        'Nobody matches those filters.',
                        style: TextStyle(color: AppColors.textMuted),
                      ),
                    ),
                  )
                else
                  AppCard(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      children: [
                        for (var i = 0; i < shown.length; i++) ...[
                          _StandingRow(
                            standing: shown[i],
                            student: students.firstWhere(
                              (u) => u.uid == shown[i].studentUid,
                            ),
                            collegeId: collegeId,
                            period: period,
                            amount: amount,
                            symbol: symbol,
                            canManage: canManage,
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
      },
    );
  }
}

class _SummaryBar extends StatelessWidget {
  final FeeSummary summary;
  final String symbol;

  const _SummaryBar({required this.summary, required this.symbol});

  @override
  Widget build(BuildContext context) => AppCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 34,
          runSpacing: 12,
          children: [
            _Stat('Residents', '${summary.total}', AppColors.primary),
            _Stat('Paid', '${summary.paid}', AppColors.success),
            _Stat(
              'Unpaid',
              '${summary.unpaid}',
              summary.unpaid == 0 ? AppColors.success : AppColors.danger,
            ),
            _Stat(
              'Collected',
              '$symbol${summary.collected.toStringAsFixed(0)}',
              AppColors.success,
            ),
            _Stat(
              'Pending',
              '$symbol${summary.pending.toStringAsFixed(0)}',
              summary.pending == 0 ? AppColors.success : AppColors.warning,
            ),
          ],
        ),
        const SizedBox(height: 16),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: summary.paidFraction,
            minHeight: 8,
            backgroundColor: AppColors.border,
            valueColor: AlwaysStoppedAnimation(AppColors.success),
          ),
        ),
        const SizedBox(height: 7),
        Text(
          '${(summary.paidFraction * 100).round()}% collected',
          style: TextStyle(fontSize: 12, color: AppColors.textMuted),
        ),
      ],
    ),
  );
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

class _MarkAllButton extends StatefulWidget {
  final String collegeId;
  final String period;
  final num amount;
  final List<AppUser> students;

  const _MarkAllButton({
    required this.collegeId,
    required this.period,
    required this.amount,
    required this.students,
  });

  @override
  State<_MarkAllButton> createState() => _MarkAllButtonState();
}

class _MarkAllButtonState extends State<_MarkAllButton> {
  bool _busy = false;

  Future<void> _run() async {
    final n = widget.students.length;
    final messenger = ScaffoldMessenger.of(context);
    final session = Session.of(context);

    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Mark $n student${n == 1 ? '' : 's'} paid?'),
        content: Text(
          'Everyone currently shown as unpaid for '
          '${periodLabel(widget.period)} will be recorded as paid today.\n\n'
          'This only records status — no money moves. You can undo any row '
          'individually afterwards.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text('Mark $n paid'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _busy = true);
    try {
      final done = await FeeService.instance.markManyPaid(
        collegeId: widget.collegeId,
        students: widget.students,
        recordedBy: session.user,
        period: widget.period,
        amount: widget.amount,
      );
      messenger.showSnackBar(
        SnackBar(content: Text('Marked $done paid')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(AuthService.describeError(e))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: _busy ? null : _run,
    icon: const Icon(Icons.done_all_rounded, size: 17),
    label: Text('Mark ${widget.students.length} paid'),
    style: OutlinedButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
    ),
  );
}

class _StandingRow extends StatelessWidget {
  final FeeStanding standing;
  final AppUser student;
  final String collegeId;
  final String period;
  final num amount;
  final String symbol;
  final bool canManage;

  const _StandingRow({
    required this.standing,
    required this.student,
    required this.collegeId,
    required this.period,
    required this.amount,
    required this.symbol,
    required this.canManage,
  });

  Future<void> _toggle(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final session = Session.of(context);
    try {
      if (standing.isPaid) {
        await FeeService.instance.markUnpaid(
          collegeId: collegeId,
          period: period,
          studentUid: standing.studentUid,
          actor: session.user,
        );
        messenger.showSnackBar(
          SnackBar(content: Text('${standing.studentName} marked unpaid')),
        );
      } else {
        await FeeService.instance.markPaid(
          collegeId: collegeId,
          student: student,
          recordedBy: session.user,
          period: period,
          amount: amount,
        );
        messenger.showSnackBar(
          SnackBar(content: Text('${standing.studentName} marked paid')),
        );
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(AuthService.describeError(e))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final paid = standing.isPaid;
    final fg = paid ? AppColors.success : AppColors.danger;
    final bg = paid ? AppColors.successSoft : AppColors.dangerSoft;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
      child: Row(
        children: [
          Container(
            height: 38,
            width: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(
              paid ? Icons.check_rounded : Icons.schedule_rounded,
              size: 18,
              color: fg,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            flex: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  standing.studentName,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14.5,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    if (standing.studentRegNo != null) standing.studentRegNo!,
                    if (standing.hostelName != null) standing.hostelName!,
                    if (standing.roomNumber != null)
                      'Room ${standing.roomNumber}',
                  ].join(' · '),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 2,
            child: Text(
              paid
                  ? 'Paid ${standing.record!.paidOnLabel ?? ''}'
                  : 'Not recorded',
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: AppColors.textMuted),
            ),
          ),
          const SizedBox(width: 14),
          Text(
            '$symbol${(standing.record?.amount ?? amount).toStringAsFixed(0)}',
            style: const TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(width: 14),
          StatusPill(paid ? 'PAID' : 'UNPAID', fg, bg),
          if (canManage) ...[
            const SizedBox(width: 10),
            Tooltip(
              message: paid ? 'Undo — mark unpaid' : 'Mark paid',
              child: Switch(
                value: paid,
                onChanged: (_) => _toggle(context),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ------------------------------ student view ------------------------------

class _MyFees extends StatelessWidget {
  final String collegeId;
  final String uid;
  final num amount;
  final String symbol;

  const _MyFees({
    required this.collegeId,
    required this.uid,
    required this.amount,
    required this.symbol,
  });

  @override
  Widget build(BuildContext context) {
    final thisMonth = periodOf(DateTime.now());

    return StreamBuilder<List<FeeRecord>>(
      stream: FeeService.instance.watchMine(collegeId, uid),
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

        final records = snap.data!;
        final current = records.where((r) => r.period == thisMonth).firstOrNull;
        final paidNow = current != null;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppCard(
              child: Row(
                children: [
                  Container(
                    height: 52,
                    width: 52,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: paidNow
                          ? AppColors.successSoft
                          : AppColors.warningSoft,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(
                      paidNow
                          ? Icons.check_circle_rounded
                          : Icons.schedule_rounded,
                      size: 26,
                      color: paidNow ? AppColors.success : AppColors.warning,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          periodLabel(thisMonth),
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textMuted,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          paidNow ? 'Paid' : 'Not yet recorded',
                          style: TextStyle(
                            fontSize: 21,
                            fontWeight: FontWeight.w800,
                            color: paidNow
                                ? AppColors.success
                                : AppColors.warning,
                          ),
                        ),
                        if (paidNow && current.paidOnLabel != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            'Received ${current.paidOnLabel}',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: AppColors.textMuted,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  Text(
                    '$symbol${amount.toStringAsFixed(0)}',
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SectionHeader('Payment history'),
                  const SizedBox(height: 12),
                  if (records.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      child: Text(
                        'Nothing recorded yet. If you have paid and this still '
                        'says nothing, speak to the hostel office — the record '
                        'is entered by hand.',
                        style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 13,
                          height: 1.5,
                        ),
                      ),
                    )
                  else
                    for (var i = 0; i < records.length; i++) ...[
                      if (i != 0)
                        Divider(height: 18, color: AppColors.border),
                      Row(
                        children: [
                          Icon(
                            Icons.check_circle_rounded,
                            size: 17,
                            color: AppColors.success,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              periodLabel(records[i].period),
                              style: const TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (records[i].paidOnLabel != null)
                            Text(
                              records[i].paidOnLabel!,
                              style: TextStyle(
                                fontSize: 12.5,
                                color: AppColors.textMuted,
                              ),
                            ),
                          const SizedBox(width: 16),
                          Text(
                            '$symbol${records[i].amount.toStringAsFixed(0)}',
                            style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
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
