import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../models/fine.dart';
import '../../models/office_order.dart';
import '../../services/office_order_service.dart';
import '../../widgets/student_photo.dart';
import 'fines_shared.dart' show fineStatusColours;
import 'office_order_detail_dialog.dart';
import 'office_orders_page.dart' show OfficeOrderViewer;

/// Everything about one fine: who (with their face), where they were living
/// when it was imposed, why, who imposed it, how it was settled, and the
/// office order it was issued under.
///
/// A dialog because a fine row appears in three places — the register, a
/// student's own list, and the fines card on their record — and it should
/// open the same way from each. Dialogs sit above SessionScope, so the
/// permissions it needs are passed in.
class FineDetailDialog extends StatelessWidget {
  final Fine fine;
  final String collegeId;

  /// `officeOrders.view` — the order itself is only fetched when this holds;
  /// otherwise the rules would refuse the read.
  final bool canViewOrders;

  /// `users.view` — passed through to the order's detail screen.
  final bool canSeeProfiles;

  const FineDetailDialog({
    super.key,
    required this.fine,
    required this.collegeId,
    required this.canViewOrders,
    required this.canSeeProfiles,
  });

  @override
  Widget build(BuildContext context) {
    final c = fineStatusColours(fine.status);

    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 800, maxHeight: 860),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 16, 12, 12),
              child: Row(
                children: [
                  Container(
                    height: 42,
                    width: 42,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: c.bg,
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: Icon(Icons.gavel_rounded, size: 20, color: c.fg),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '₹${fine.amount}  ·  ${fine.category}',
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          [
                            if (fine.createdAt != null)
                              'Imposed ${_date(fine.createdAt!)}',
                            'by ${fine.imposedByName}',
                          ].join(' '),
                          style: TextStyle(
                            fontSize: 12.5,
                            color: AppColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  StatusPill(fine.status.label.toUpperCase(), c.fg, c.bg),
                  const SizedBox(width: 6),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                    tooltip: 'Close',
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: AppColors.border),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LayoutBuilder(
                      builder: (context, box) {
                        // Only a uid is on the fine, so whether there is a
                        // photo is unknown until the one read answers.
                        final photo = StudentPhoto(
                          collegeId: collegeId,
                          uid: fine.studentUid,
                          name: fine.studentName,
                          width: 160,
                          height: 210,
                          radius: 12,
                        );
                        final facts = _Facts(fine: fine);
                        if (box.maxWidth < 560) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              photo,
                              const SizedBox(height: 18),
                              facts,
                            ],
                          );
                        }
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            photo,
                            const SizedBox(width: 22),
                            Expanded(child: facts),
                          ],
                        );
                      },
                    ),
                    if (fine.reason.trim().isNotEmpty) ...[
                      const SizedBox(height: 22),
                      const _Label('Reason'),
                      const SizedBox(height: 6),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: AppColors.canvas,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: Text(
                          fine.reason,
                          style: const TextStyle(fontSize: 13.5, height: 1.5),
                        ),
                      ),
                    ],
                    const SizedBox(height: 22),
                    const _Label('Office order'),
                    const SizedBox(height: 8),
                    _OrderSection(
                      fine: fine,
                      collegeId: collegeId,
                      canViewOrders: canViewOrders,
                      canSeeProfiles: canSeeProfiles,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _date(DateTime d) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${d.day} ${months[d.month - 1]} ${d.year}';
}

class _Facts extends StatelessWidget {
  final Fine fine;
  const _Facts({required this.fine});

  @override
  Widget build(BuildContext context) {
    final resolved = switch (fine.status) {
      FineStatus.pending => null,
      FineStatus.paid => 'Marked paid',
      FineStatus.waived => 'Waived',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          fine.studentName,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        if ((fine.studentRegNo ?? '').isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            fine.studentRegNo!,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: AppColors.textStrong,
            ),
          ),
        ],
        const SizedBox(height: 16),
        Wrap(
          spacing: 28,
          runSpacing: 14,
          children: [
            // Snapshotted when the fine was imposed — where they lived *then*,
            // which is what the incident is about. Their room now is on the
            // office order's detail and their own record.
            _Fact('Room at the time', fine.whereFrom ?? 'Not allotted'),
            if ((fine.trade ?? '').isNotEmpty) _Fact('Trade', fine.trade!),
            if (fine.sem != null) _Fact('Semester', '${fine.sem}'),
            if ((fine.batch ?? '').isNotEmpty) _Fact('Batch', fine.batch!),
            if ((fine.state ?? '').isNotEmpty) _Fact('Home state', fine.state!),
            _Fact('Amount', '₹${fine.amount}'),
            _Fact('Category', fine.category),
            _Fact('Imposed by', fine.imposedByName),
            if (fine.createdAt != null)
              _Fact('Imposed on', _date(fine.createdAt!)),
            if (resolved != null)
              _Fact(
                resolved,
                [
                  if (fine.resolvedByName != null) 'by ${fine.resolvedByName}',
                  if (fine.resolvedAt != null) 'on ${_date(fine.resolvedAt!)}',
                ].join(' ').trim().ifEmpty('Yes'),
              ),
          ],
        ),
      ],
    );
  }
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}

/// The order this fine was issued under: its scan, and a way into its full
/// detail (everyone else it names, with their faces).
class _OrderSection extends StatefulWidget {
  final Fine fine;
  final String collegeId;
  final bool canViewOrders;
  final bool canSeeProfiles;

  const _OrderSection({
    required this.fine,
    required this.collegeId,
    required this.canViewOrders,
    required this.canSeeProfiles,
  });

  @override
  State<_OrderSection> createState() => _OrderSectionState();
}

class _OrderSectionState extends State<_OrderSection> {
  Future<OfficeOrder?>? _order;

  @override
  void initState() {
    super.initState();
    final id = widget.fine.officeOrderId;
    if (id != null && widget.canViewOrders) {
      _order = OfficeOrderService.instance.fetch(widget.collegeId, id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fine = widget.fine;

    if (_order == null) {
      final no = fine.officeOrderNo;
      return _Muted(
        fine.officeOrderId == null && no == null
            ? 'This fine was recorded without an office order.'
            : widget.canViewOrders
            ? 'Issued under office order ${no ?? ''} (recorded before orders '
                  'were linked to fines, so there is no scan to show).'
            : 'Issued under office order ${no ?? ''}. You don\'t have '
                  'permission to view office orders.',
      );
    }

    return FutureBuilder<OfficeOrder?>(
      future: _order,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 18),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final order = snap.data;
        if (order == null) {
          return _Muted(
            'The office order for this fine'
            '${fine.officeOrderNo == null ? '' : ' (${fine.officeOrderNo})'} '
            'could not be loaded — it may have been deleted.',
          );
        }
        final bytes = decodedOrderImage(order);

        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.canvas,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (bytes != null)
                MouseRegion(
                  cursor: SystemMouseCursors.zoomIn,
                  child: GestureDetector(
                    onTap: () => showDialog<void>(
                      context: context,
                      barrierColor: Colors.black.withValues(alpha: 0.86),
                      builder: (_) =>
                          OfficeOrderViewer(order: order, bytes: bytes),
                    ),
                    child: Container(
                      width: 150,
                      height: 200,
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Image.memory(
                        bytes,
                        fit: BoxFit.contain,
                        cacheWidth: 400,
                      ),
                    ),
                  ),
                ),
              if (bytes != null) const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      order.title.isEmpty ? order.orderNo : order.title,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      [
                        if (order.orderNo.isNotEmpty) order.orderNo,
                        if (order.dateLabel != null) order.dateLabel!,
                        order.postedByName,
                      ].join('  ·  '),
                      style: TextStyle(
                        fontSize: 12.5,
                        color: AppColors.textMuted,
                      ),
                    ),
                    if (order.isGroup) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Group order — names ${order.students.length} '
                        'students: ${order.students.map((s) => s.name).join(', ')}.',
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.45,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primary,
                        ),
                      ),
                    ],
                    if ((order.description ?? '').trim().isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        order.description!,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, height: 1.45),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.tonalIcon(
                          onPressed: () => showDialog<void>(
                            context: context,
                            builder: (_) => OfficeOrderDetailDialog(
                              order: order,
                              collegeId: widget.collegeId,
                              canSeeProfiles: widget.canSeeProfiles,
                            ),
                          ),
                          icon: const Icon(Icons.groups_rounded, size: 18),
                          label: const Text('Open office order'),
                        ),
                        if (bytes != null)
                          OutlinedButton.icon(
                            onPressed: () => showDialog<void>(
                              context: context,
                              barrierColor: Colors.black.withValues(
                                alpha: 0.86,
                              ),
                              builder: (_) =>
                                  OfficeOrderViewer(order: order, bytes: bytes),
                            ),
                            icon: const Icon(Icons.zoom_in_rounded, size: 18),
                            label: const Text('View scan'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
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
      letterSpacing: 0.8,
      color: AppColors.textMuted,
    ),
  );
}

class _Muted extends StatelessWidget {
  final String text;
  const _Muted(this.text);

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(fontSize: 13, color: AppColors.textMuted, height: 1.45),
  );
}

class _Fact extends StatelessWidget {
  final String label;
  final String value;
  const _Fact(this.label, this.value);

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minWidth: 110, maxWidth: 240),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label.toUpperCase(),
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.7,
            color: AppColors.textMuted,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          value,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
        ),
      ],
    ),
  );
}
