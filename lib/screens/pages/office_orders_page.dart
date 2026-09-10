import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/permissions.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../models/office_order.dart';
import '../../services/auth_service.dart';
import '../../services/office_order_service.dart';

/// Office orders: the register of disciplinary orders issued against
/// residents. Every order here exists because a fine was imposed under it —
/// see `ImposeFineView`, which is the only place one is created.
///
/// Everyone with `officeOrders.view` can search and open them; staff with
/// `officeOrders.manage` can delete their own. Two searches are offered
/// because they answer different questions — "find order SLIET/HM/2024/17"
/// (which also matches on the student it was issued to) and "what was
/// issued on 12 March".
class OfficeOrdersPage extends StatefulWidget {
  const OfficeOrdersPage({super.key});

  @override
  State<OfficeOrdersPage> createState() => _OfficeOrdersPageState();
}

class _OfficeOrdersPageState extends State<OfficeOrdersPage> {
  String _query = '';
  DateTime? _onDate;

  /// Opens an order the right way for how it was published.
  ///
  /// Photo orders open in a viewer inside the app; the older link-based ones
  /// still hand off to the browser. Both paths stay because the register
  /// contains a mix and always will.
  Future<void> _open(OfficeOrder order) async {
    if (order.hasImage) {
      final bytes = decodedOrderImage(order);
      if (bytes != null) {
        await showDialog<void>(
          context: context,
          barrierColor: Colors.black.withValues(alpha: 0.86),
          builder: (_) => OfficeOrderViewer(order: order, bytes: bytes),
        );
        return;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That photo could not be read')),
        );
      }
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    final uri = Uri.tryParse(order.pdfUrl ?? '');
    if (uri == null || !order.hasLink) {
      messenger.showSnackBar(
        const SnackBar(content: Text('That order has no photo or link')),
      );
      return;
    }
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not open that link')),
      );
    }
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _onDate ?? now,
      firstDate: DateTime(now.year - 15),
      lastDate: DateTime(now.year + 1, 12, 31),
    );
    if (picked == null) return;
    setState(() => _onDate = picked);
  }

  Future<void> _confirmDelete(String collegeId, OfficeOrder order) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete this office order?'),
        content: Text(
          '${order.orderNo.isEmpty ? order.title : order.orderNo} will be '
          'removed from the register. The PDF itself is not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      await OfficeOrderService.instance.delete(
        collegeId: collegeId,
        orderId: order.id,
      );
      messenger.showSnackBar(
        const SnackBar(content: Text('Office order deleted')),
      );
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
    final canManage = session.can(Perm.officeOrdersManage);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionHeader('Office Orders'),
              const SizedBox(height: 4),
              Text(
                'Disciplinary orders issued against residents, one per fine. '
                'Search by order number, student, or the date printed on the '
                'order. To add one, impose a fine — every fine is issued '
                'under an order.',
                style: TextStyle(fontSize: 13, color: AppColors.textMuted),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      onChanged: (v) => setState(() => _query = v),
                      decoration: const InputDecoration(
                        hintText: 'Search by office order number or title',
                        prefixIcon: Icon(Icons.search_rounded),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  OutlinedButton.icon(
                    onPressed: _pickDate,
                    icon: const Icon(Icons.calendar_today_rounded, size: 16),
                    label: Text(
                      _onDate == null
                          ? 'Any date'
                          : _labelFor(_onDate!),
                    ),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 16,
                      ),
                    ),
                  ),
                  if (_onDate != null) ...[
                    const SizedBox(width: 6),
                    IconButton(
                      onPressed: () => setState(() => _onDate = null),
                      icon: const Icon(Icons.close_rounded, size: 18),
                      tooltip: 'Clear date filter',
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        StreamBuilder<List<OfficeOrder>>(
          stream: OfficeOrderService.instance.watchAll(collegeId),
          builder: (context, snap) {
            if (snap.hasError) {
              return AppCard(
                child: Text(AuthService.describeError(snap.error!)),
              );
            }
            if (!snap.hasData) {
              return const Padding(
                padding: EdgeInsets.all(60),
                child: Center(child: CircularProgressIndicator()),
              );
            }

            final shown = snap.data!
                .where((o) => o.matches(_query))
                .where((o) => _onDate == null || o.isOn(_onDate!))
                .toList();

            if (shown.isEmpty) {
              return AppCard(
                padding: const EdgeInsets.symmetric(vertical: 54),
                child: Center(
                  child: Text(
                    (_query.isEmpty && _onDate == null)
                        ? 'No office orders have been added yet.'
                        : 'Nothing matches that search.',
                    style: TextStyle(color: AppColors.textMuted),
                  ),
                ),
              );
            }

            return AppCard(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                children: [
                  for (var i = 0; i < shown.length; i++) ...[
                    _OrderRow(
                      order: shown[i],
                      canDelete:
                          session.user.isSuperAdmin ||
                          (canManage &&
                              shown[i].postedByUid == session.user.uid),
                      onOpen: () => _open(shown[i]),
                      onDelete: () => _confirmDelete(collegeId, shown[i]),
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
            );
          },
        ),
      ],
    );
  }
}

String _labelFor(DateTime d) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${d.day} ${months[d.month - 1]} ${d.year}';
}

/// The order's own photo as a small square, so the register is scannable by
/// sight — most people recognise the letterhead faster than they read the
/// order number. Falls back to an icon for the older link-based orders.
/// Shared with the office-orders section on a student's detail page.
class OfficeOrderThumb extends StatelessWidget {
  final OfficeOrder order;
  final double size;
  const OfficeOrderThumb({super.key, required this.order, this.size = 42});

  @override
  Widget build(BuildContext context) {
    final bytes = decodedOrderImage(order);

    if (bytes == null) {
      return Container(
        height: size,
        width: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.primarySoft,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(
          order.hasLink ? Icons.link_rounded : Icons.description_rounded,
          size: 20,
          color: AppColors.primary,
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Image.memory(
        bytes,
        height: size,
        width: size,
        fit: BoxFit.cover,
        // Decoded down to roughly the size actually painted. Without this
        // Flutter holds the full-resolution bitmap in memory for every row.
        cacheWidth: 128,
        filterQuality: FilterQuality.low,
        errorBuilder: (context, _, _) => Container(
          height: 42,
          width: 42,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.dangerSoft,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            Icons.broken_image_rounded,
            size: 18,
            color: AppColors.danger,
          ),
        ),
      ),
    );
  }
}

/// Full-size viewer for a photographed order, shared with the office-orders
/// section on a student's detail page.
///
/// [InteractiveViewer] is the point of this screen: a phone photo of an A4
/// order is unreadable at fit-to-screen, so pinch and drag to zoom is what
/// makes the feature usable at all.
class OfficeOrderViewer extends StatelessWidget {
  final OfficeOrder order;
  final Uint8List bytes;

  const OfficeOrderViewer({super.key, required this.order, required this.bytes});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(18, 14, 10, 14),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(14),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        order.title.isEmpty ? order.orderNo : order.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [
                          if (order.orderNo.isNotEmpty) order.orderNo,
                          if (order.dateLabel != null) order.dateLabel!,
                          order.postedByName,
                        ].join('  ·  '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: AppColors.textMuted,
                        ),
                      ),
                      // Every student named on the order, spelled out. The
                      // register row only has space for "and 4 others", so
                      // this is the one place you can see who they were.
                      if (order.students.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          order.students
                              .map(
                                (s) =>
                                    '${s.name}'
                                    '${(s.regNo ?? '').isEmpty ? '' : ' (${s.regNo})'}'
                                    // Spelled out per student, because on this
                                    // order they did not all pay the same.
                                    '${s.isFined ? ' — ₹${s.fineAmount}' : ' — no fine'}',
                              )
                              .join(',   '),
                          style: TextStyle(
                            fontSize: 12.5,
                            height: 1.45,
                            fontWeight: FontWeight.w600,
                            color: AppColors.primary,
                          ),
                        ),
                        if (order.hasFine)
                          Text(
                            order.isGroup
                                ? '₹${order.fineTotal} across '
                                      '${order.finedStudents.length} of '
                                      '${order.students.length} students · '
                                      '${order.fineCategory ?? ''}'
                                : '₹${order.fineTotal} · '
                                      '${order.fineCategory ?? ''}',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: AppColors.textMuted,
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                  tooltip: 'Close',
                ),
              ],
            ),
          ),
          Flexible(
            child: Container(
              decoration: const BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.vertical(
                  bottom: Radius.circular(14),
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: InteractiveViewer(
                minScale: 1,
                maxScale: 5,
                child: Image.memory(bytes, fit: BoxFit.contain),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OrderRow extends StatelessWidget {
  final OfficeOrder order;
  final bool canDelete;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  const _OrderRow({
    required this.order,
    required this.canDelete,
    required this.onOpen,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            OfficeOrderThumb(order: order),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    order.title.isEmpty ? order.orderNo : order.title,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    [
                      if (order.orderNo.isNotEmpty) order.orderNo,
                      if (order.dateLabel != null) order.dateLabel!,
                      order.postedByName,
                    ].join(' · '),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: AppColors.textMuted,
                    ),
                  ),
                  if (order.students.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      [
                        'For ${order.studentLabel}',
                        // Only worth showing for a single student; on a group
                        // order the registration numbers don't fit and the
                        // expanded view lists them properly.
                        if (order.students.length == 1 &&
                            (order.students.first.regNo ?? '').isNotEmpty)
                          order.students.first.regNo!,
                        // Amounts differ per student, so the range is what
                        // means something — a single figure would imply
                        // everyone paid the same.
                        if (order.hasFine)
                          '${order.fineRangeLabel} · '
                              '${order.fineCategory ?? ''}',
                      ].join(' · '),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: AppColors.primary,
                      ),
                    ),
                  ],
                  if (order.description != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      order.description!,
                      style: TextStyle(
                        fontSize: 13,
                        color: AppColors.textStrong,
                        height: 1.45,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            TextButton.icon(
              onPressed: onOpen,
              icon: Icon(
                order.hasImage
                    ? Icons.zoom_in_rounded
                    : Icons.open_in_new_rounded,
                size: 16,
              ),
              label: Text(order.hasImage ? 'View' : 'Open'),
            ),
            if (canDelete)
              PopupMenuButton<String>(
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(
                          Icons.delete_outline_rounded,
                          size: 18,
                          color: AppColors.danger,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          'Delete',
                          style: TextStyle(color: AppColors.danger),
                        ),
                      ],
                    ),
                  ),
                ],
                onSelected: (v) {
                  if (v == 'delete') onDelete();
                },
                child: const Icon(Icons.more_vert_rounded, size: 20),
              ),
          ],
        ),
      ),
    );
  }
}
