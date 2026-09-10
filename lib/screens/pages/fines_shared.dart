import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../core/theme.dart';
import '../../models/fine.dart';
import '../../services/auth_service.dart';
import '../../services/fine_service.dart';

/// Pieces shared by the fines register, the overview dashboard and the fines
/// card on a student's detail screen. They live here rather than in any one of
/// those so none of them has to import another — and so a fine looks and
/// behaves identically wherever it appears.

/// "31K", "1.4L", "450" — how the reference report shows money.
String compactAmount(num v) {
  if (v >= 100000) return '${(v / 100000).toStringAsFixed(1)}L';
  if (v >= 1000) return '${(v / 1000).toStringAsFixed(v >= 10000 ? 0 : 1)}K';
  return v.toStringAsFixed(0);
}

String shortDate(DateTime d) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${d.day} ${months[d.month - 1]}';
}

({Color fg, Color bg}) fineStatusColours(FineStatus s) => switch (s) {
  FineStatus.pending => (fg: AppColors.danger, bg: AppColors.dangerSoft),
  FineStatus.paid => (fg: AppColors.success, bg: AppColors.successSoft),
  FineStatus.waived => (fg: AppColors.textMuted, bg: AppColors.canvas),
};

/// One fine, as shown in the register, a student's own list, and the fines
/// card on a student's detail screen.
class FineRow extends StatelessWidget {
  final Fine fine;
  final bool showWho;
  final bool canManage;
  final String collegeId;

  const FineRow({
    super.key,
    required this.fine,
    required this.showWho,
    required this.canManage,
    required this.collegeId,
  });

  Future<void> _act(BuildContext context, String action) async {
    final session = Session.of(context);
    final messenger = ScaffoldMessenger.of(context);

    try {
      if (action == 'delete') {
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Remove this fine?'),
            content: Text(
              fine.status.isOutstanding
                  ? 'The ₹${fine.amount} fine on ${fine.studentName} will '
                        'be deleted. Use this only for a fine raised in '
                        'error.'
                  : 'The ₹${fine.amount} fine on ${fine.studentName} will '
                        'be deleted permanently — including the record '
                        'that it was ${fine.status.label.toLowerCase()}.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('Keep it'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.danger,
                ),
                onPressed: () => Navigator.pop(c, true),
                child: const Text('Remove'),
              ),
            ],
          ),
        );
        if (ok != true) return;
        await FineService.instance.remove(
          collegeId: collegeId,
          fine: fine,
          actor: session.user,
        );
        messenger.showSnackBar(const SnackBar(content: Text('Fine removed')));
        return;
      }

      final status = action == 'paid' ? FineStatus.paid : FineStatus.waived;
      await FineService.instance.setStatus(
        collegeId: collegeId,
        fine: fine,
        status: status,
        handler: session.user,
      );
      messenger.showSnackBar(
        SnackBar(content: Text('Marked ${status.label.toLowerCase()}')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(AuthService.describeError(e))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = fineStatusColours(fine.status);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
      child: Row(
        children: [
          Container(
            height: 40,
            width: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: c.bg,
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(Icons.gavel_rounded, size: 18, color: c.fg),
          ),
          const SizedBox(width: 14),
          Expanded(
            flex: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  showWho ? fine.studentName : fine.category,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14.5,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    if (showWho) fine.category,
                    if (fine.studentRegNo != null) fine.studentRegNo!,
                    if (fine.whereFrom != null) fine.whereFrom!,
                    if (fine.sem != null) 'Sem ${fine.sem}',
                    if (fine.trade != null) fine.trade!,
                    if (fine.officeOrderNo != null) fine.officeOrderNo!,
                    if (fine.createdAt != null) shortDate(fine.createdAt!),
                  ].join(' · '),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12.5,
                  ),
                ),
                if (fine.reason.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Text(
                    fine.reason,
                    style: const TextStyle(fontSize: 13, height: 1.4),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '₹${fine.amount}',
            style: const TextStyle(
              fontSize: 15.5,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(width: 12),
          StatusPill(fine.status.label.toUpperCase(), c.fg, c.bg),
          if (canManage)
            PopupMenuButton<String>(
              itemBuilder: (context) => [
                if (fine.status.isOutstanding) ...[
                  const PopupMenuItem(value: 'paid', child: Text('Mark paid')),
                  const PopupMenuItem(value: 'waived', child: Text('Waive')),
                ],
                PopupMenuItem(
                  value: 'delete',
                  child: Text(
                    'Remove',
                    style: TextStyle(color: AppColors.danger),
                  ),
                ),
              ],
              onSelected: (v) => _act(context, v),
              child: const Padding(
                padding: EdgeInsets.only(left: 6),
                child: Icon(Icons.more_vert_rounded, size: 20),
              ),
            ),
        ],
      ),
    );
  }
}
