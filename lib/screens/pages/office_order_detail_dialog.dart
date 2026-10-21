import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme.dart';
import '../../models/app_user.dart';
import '../../models/office_order.dart';
import '../../services/data_service.dart';
import '../../widgets/student_photo.dart';
import 'office_orders_page.dart' show OfficeOrderViewer;

/// Everything about one office order: the scan, what it says, and a card per
/// student it names — face, registration number, room, fine — so whoever is
/// holding the order can match it to the people in front of them.
///
/// A dialog rather than a drill-down page because it is opened from three
/// places (the register, a student's record, a fine) and must look the same
/// from all of them. Being a dialog it sits above SessionScope, so the one
/// permission it needs is passed in.
class OfficeOrderDetailDialog extends StatelessWidget {
  final OfficeOrder order;
  final String collegeId;

  /// `users.view` — whether each student's current room and trade can be
  /// looked up. Without it the cards show what the order itself recorded.
  final bool canSeeProfiles;

  const OfficeOrderDetailDialog({
    super.key,
    required this.order,
    required this.collegeId,
    required this.canSeeProfiles,
  });

  @override
  Widget build(BuildContext context) {
    final fined = order.finedStudents.length;

    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 920, maxHeight: 860),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 16, 12, 12),
              child: Row(
                children: [
                  Icon(Icons.description_rounded, color: AppColors.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          order.title.isEmpty ? order.orderNo : order.title,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          [
                            if (order.orderNo.isNotEmpty) order.orderNo,
                            if (order.dateLabel != null) order.dateLabel!,
                            'Posted by ${order.postedByName}',
                          ].join('  ·  '),
                          style: TextStyle(
                            fontSize: 12.5,
                            color: AppColors.textMuted,
                          ),
                        ),
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
            Divider(height: 1, color: AppColors.border),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LayoutBuilder(
                      builder: (context, box) {
                        final scan = _OrderScan(order: order);
                        final facts = _OrderFacts(order: order);
                        if (box.maxWidth < 600) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [scan, const SizedBox(height: 18), facts],
                          );
                        }
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            scan,
                            const SizedBox(width: 22),
                            Expanded(child: facts),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 26),
                    Text(
                      order.students.isEmpty
                          ? 'Students'
                          : 'Students on this order (${order.students.length}'
                                '${order.hasFine && fined != order.students.length ? ', $fined fined' : ''})',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (order.students.isEmpty)
                      Text(
                        'This order was published before orders were linked '
                        'to students, so nobody is recorded on it.',
                        style: TextStyle(
                          fontSize: 13,
                          color: AppColors.textMuted,
                        ),
                      )
                    else
                      Wrap(
                        spacing: 14,
                        runSpacing: 14,
                        children: [
                          for (final s in order.students)
                            _OrderStudentCard(
                              key: ValueKey(s.uid),
                              student: s,
                              collegeId: collegeId,
                              canSeeProfiles: canSeeProfiles,
                            ),
                        ],
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

// ------------------------------- the scan -------------------------------

class _OrderScan extends StatelessWidget {
  final OfficeOrder order;
  const _OrderScan({required this.order});

  static const double _w = 250;
  static const double _h = 330;

  Future<void> _openLink(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final uri = Uri.tryParse(order.pdfUrl ?? '');
    final ok =
        uri != null &&
        await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not open that link')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = decodedOrderImage(order);

    if (bytes == null) {
      return Container(
        width: _w,
        height: 150,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.canvas,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: order.hasLink
            ? OutlinedButton.icon(
                onPressed: () => _openLink(context),
                icon: const Icon(Icons.open_in_new_rounded, size: 17),
                label: Text(order.isPdf ? 'Open PDF' : 'Open link'),
              )
            : Text(
                'No scan attached',
                style: TextStyle(color: AppColors.textMuted, fontSize: 13),
              ),
      );
    }

    return Column(
      children: [
        MouseRegion(
          cursor: SystemMouseCursors.zoomIn,
          child: GestureDetector(
            onTap: () => showDialog<void>(
              context: context,
              barrierColor: Colors.black.withValues(alpha: 0.86),
              builder: (_) => OfficeOrderViewer(order: order, bytes: bytes),
            ),
            child: Container(
              width: _w,
              height: _h,
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(12),
              ),
              clipBehavior: Clip.antiAlias,
              child: Image.memory(bytes, fit: BoxFit.contain, cacheWidth: 600),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Click the order to zoom in',
          style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
        ),
      ],
    );
  }
}

// ------------------------------- the facts -------------------------------

class _OrderFacts extends StatelessWidget {
  final OfficeOrder order;
  const _OrderFacts({required this.order});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 28,
          runSpacing: 14,
          children: [
            if (order.orderNo.isNotEmpty) _Fact('Order no.', order.orderNo),
            _Fact('Order date', order.dateLabel ?? 'Not recorded'),
            _Fact('Posted by', order.postedByName),
            if ((order.fineCategory ?? '').isNotEmpty)
              _Fact('Category', order.fineCategory!),
            _Fact(
              'Fine',
              order.hasFine
                  ? (order.isGroup
                        ? '₹${order.fineTotal} total  (${order.fineRangeLabel} each)'
                        : '₹${order.fineTotal}')
                  : 'No fine — warning / notice',
            ),
            _Fact('Students named', '${order.students.length}'),
          ],
        ),
        if ((order.description ?? '').trim().isNotEmpty) ...[
          const SizedBox(height: 18),
          Text(
            'DETAILS',
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.7,
              color: AppColors.textMuted,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            order.description!,
            style: const TextStyle(fontSize: 13.5, height: 1.5),
          ),
        ],
      ],
    );
  }
}

class _Fact extends StatelessWidget {
  final String label;
  final String value;
  const _Fact(this.label, this.value);

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minWidth: 120, maxWidth: 260),
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

// ------------------------------ one student ------------------------------

/// One named student: their face and where to find them.
///
/// The order only recorded name and registration number, so the room and
/// trade come from their profile — read once when the card opens, with no
/// listener left behind. That is the student's room *now*, which is what you
/// need to go and find them.
class _OrderStudentCard extends StatefulWidget {
  final OrderStudent student;
  final String collegeId;
  final bool canSeeProfiles;

  const _OrderStudentCard({
    super.key,
    required this.student,
    required this.collegeId,
    required this.canSeeProfiles,
  });

  @override
  State<_OrderStudentCard> createState() => _OrderStudentCardState();
}

class _OrderStudentCardState extends State<_OrderStudentCard> {
  /// Held in state so a rebuild doesn't read the profile again.
  Future<AppUser?>? _profile;

  static const double _width = 196;
  static const double _photoW = 150;
  static const double _photoH = 190;

  @override
  void initState() {
    super.initState();
    if (widget.canSeeProfiles) {
      _profile = DataService.instance
          .fetchUser(widget.student.uid)
          .catchError((Object _) => null);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_profile == null) return _card(null, loading: false);
    return FutureBuilder<AppUser?>(
      future: _profile,
      builder: (context, snap) => _card(
        snap.data,
        loading: snap.connectionState != ConnectionState.done,
      ),
    );
  }

  Widget _card(AppUser? profile, {required bool loading}) {
    final s = widget.student;

    final Widget photo;
    if (loading) {
      photo = Container(
        width: _photoW,
        height: _photoH,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.primarySoft,
          borderRadius: BorderRadius.circular(10),
        ),
        child: const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    } else if (profile != null) {
      photo = StudentPhoto.user(profile, width: _photoW, height: _photoH);
    } else {
      // No profile to say whether there is a photo — try the one read.
      photo = StudentPhoto(
        collegeId: widget.collegeId,
        uid: s.uid,
        name: s.name,
        width: _photoW,
        height: _photoH,
      );
    }

    final room = profile == null
        ? null
        : (profile.roomLabel ?? 'No room allotted');
    final academic = profile == null
        ? ''
        : [
            if ((profile.trade ?? '').isNotEmpty) profile.trade!,
            if ((profile.year ?? '').isNotEmpty) profile.year!,
            if (profile.sem != null) 'Sem ${profile.sem}',
          ].join(' · ');

    return Container(
      width: _width,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.canvas,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          photo,
          const SizedBox(height: 10),
          Text(
            s.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              height: 1.25,
            ),
          ),
          if ((s.regNo ?? '').isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              s.regNo!,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: AppColors.textStrong,
              ),
            ),
          ],
          if (room != null) ...[
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.bed_rounded, size: 14, color: AppColors.primary),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    room,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: profile!.isAllotted
                          ? AppColors.primary
                          : AppColors.textMuted,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (academic.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              academic,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
            ),
          ],
          if (!loading && widget.canSeeProfiles && profile == null) ...[
            const SizedBox(height: 4),
            Text(
              'No longer on the roster',
              style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
            ),
          ],
          const SizedBox(height: 8),
          s.isFined
              ? StatusPill(
                  '₹${s.fineAmount} FINE',
                  AppColors.danger,
                  AppColors.dangerSoft,
                )
              : StatusPill('NO FINE', AppColors.textMuted, AppColors.card),
        ],
      ),
    );
  }
}
