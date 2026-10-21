import 'package:flutter/material.dart';

import '../../core/permissions.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../models/hostel_request.dart';
import '../../services/auth_service.dart';
import '../../services/request_service.dart';
import 'raise_request_view.dart';
import 'request_detail_view.dart';

/// Requests: one page, two audiences.
///
/// A student sees their own requests and a button to raise a new one. Staff
/// holding requests.viewAll see the queue of everything that needs acting on.
/// Someone with both — a warden who also lives in — sees both, as tabs.
class RequestsPage extends StatefulWidget {
  const RequestsPage({super.key});

  @override
  State<RequestsPage> createState() => _RequestsPageState();
}

class _RequestsPageState extends State<RequestsPage> {
  int _tab = 0;
  bool _raising = false;
  HostelRequest? _open;

  Future<void> _deleteRequest(HostelRequest request) async {
    final messenger = ScaffoldMessenger.of(context);
    final collegeId = Session.of(context).user.collegeId;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete this request?'),
        content: Text(
          '${request.raisedByName}\'s ${request.type.label.toLowerCase()} '
          'will be removed permanently. This cannot be undone.',
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
      await RequestService.instance.remove(
        collegeId: collegeId,
        request: request,
      );
      messenger.showSnackBar(const SnackBar(content: Text('Request deleted')));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(AuthService.describeError(e))),
      );
    }
  }

  _Queue _queue = _Queue.open;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final session = Session.of(context);
    final collegeId = session.user.collegeId;

    final canCreate = session.can(Perm.requestsCreate);
    final canViewAll = session.can(Perm.requestsViewAll);
    final canApprove = session.can(Perm.requestsApprove);
    final canViewOwn = session.can(Perm.requestsViewOwn) || canCreate;

    if (_raising) {
      return RaiseRequestView(
        onBack: () => setState(() => _raising = false),
        onDone: () => setState(() {
          _raising = false;
          _tab = canViewAll && !canViewOwn ? 0 : (canViewAll ? 1 : 0);
        }),
      );
    }

    if (_open != null) {
      return RequestDetailView(
        requestId: _open!.id,
        initial: _open!,
        canApprove: canApprove,
        onBack: () => setState(() => _open = null),
      );
    }

    // Which sections this person actually gets.
    final showsQueue = canViewAll;
    final showsMine = canViewOwn;
    final bothTabs = showsQueue && showsMine;
    final onQueue = showsQueue && (!bothTabs || _tab == 0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionHeader(
                'Requests',
                trailing: canCreate
                    ? ElevatedButton.icon(
                        onPressed: () => setState(() => _raising = true),
                        icon: const Icon(Icons.add_rounded, size: 18),
                        label: const Text('New request'),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 14,
                          ),
                        ),
                      )
                    : null,
              ),
              const SizedBox(height: 4),
              Text(
                showsQueue
                    ? 'Leave, complaints and room changes raised by residents.'
                    : 'Ask for leave, report a problem, or request a move.',
                style: TextStyle(fontSize: 13, color: AppColors.textMuted),
              ),
              if (bothTabs) ...[
                const SizedBox(height: 16),
                Row(
                  children: [
                    _TabButton(
                      label: 'To handle',
                      selected: _tab == 0,
                      onTap: () => setState(() => _tab = 0),
                    ),
                    const SizedBox(width: 8),
                    _TabButton(
                      label: 'My requests',
                      selected: _tab == 1,
                      onTap: () => setState(() => _tab = 1),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 18),
        if (onQueue)
          _QueueSection(
            collegeId: collegeId,
            filter: _queue,
            query: _query,
            canDelete: canApprove,
            onFilter: (q) => setState(() => _queue = q),
            onQuery: (q) => setState(() => _query = q),
            onOpen: (r) => setState(() => _open = r),
            onDelete: _deleteRequest,
          )
        else if (showsMine)
          _MineSection(
            collegeId: collegeId,
            uid: session.user.uid,
            canCreate: canCreate,
            onRaise: () => setState(() => _raising = true),
            onOpen: (r) => setState(() => _open = r),
          )
        else
          AppCard(
            padding: EdgeInsets.symmetric(vertical: 54),
            child: Center(
              child: Text(
                'You don\'t have access to requests.',
                style: TextStyle(color: AppColors.textMuted),
              ),
            ),
          ),
      ],
    );
  }
}

enum _Queue { open, handled, all }

// ---------------------------- staff queue ----------------------------

class _QueueSection extends StatelessWidget {
  final String collegeId;
  final _Queue filter;
  final String query;
  final bool canDelete;
  final ValueChanged<_Queue> onFilter;
  final ValueChanged<String> onQuery;
  final ValueChanged<HostelRequest> onOpen;
  final ValueChanged<HostelRequest> onDelete;

  const _QueueSection({
    required this.collegeId,
    required this.filter,
    required this.query,
    required this.canDelete,
    required this.onFilter,
    required this.onQuery,
    required this.onOpen,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<HostelRequest>>(
      stream: RequestService.instance.watchAll(collegeId),
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
        final open = all.where((r) => r.status.isOpen).toList();
        final handled = all.where((r) => !r.status.isOpen).toList();

        final source = switch (filter) {
          _Queue.open => open,
          _Queue.handled => handled,
          _Queue.all => all,
        };
        final q = query.trim().toLowerCase();
        final shown = q.isEmpty
            ? source
            : source
                  .where(
                    (r) =>
                        r.raisedByName.toLowerCase().contains(q) ||
                        r.subject.toLowerCase().contains(q) ||
                        (r.raisedByRegNo ?? '').toLowerCase().contains(q) ||
                        (r.roomNumber ?? '').toLowerCase().contains(q),
                  )
                  .toList();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 30,
                    runSpacing: 14,
                    children: [
                      _Metric(
                        'Needs action',
                        '${open.length}',
                        open.isEmpty ? AppColors.success : AppColors.warning,
                      ),
                      _Metric(
                        'Leave pending',
                        '${open.where((r) => r.type == RequestType.leave).length}',
                        AppColors.primary,
                      ),
                      _Metric(
                        'Complaints open',
                        '${open.where((r) => r.type == RequestType.complaint).length}',
                        AppColors.danger,
                      ),
                      _Metric(
                        'Handled',
                        '${handled.length}',
                        AppColors.textStrong,
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          onChanged: onQuery,
                          decoration: const InputDecoration(
                            hintText: 'Search name, subject, reg no or room',
                            prefixIcon: Icon(Icons.search_rounded),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      SegmentedButton<_Queue>(
                        segments: [
                          ButtonSegment(
                            value: _Queue.open,
                            label: Text('Open (${open.length})'),
                          ),
                          ButtonSegment(
                            value: _Queue.handled,
                            label: Text('Handled (${handled.length})'),
                          ),
                          const ButtonSegment(
                            value: _Queue.all,
                            label: Text('All'),
                          ),
                        ],
                        selected: {filter},
                        showSelectedIcon: false,
                        onSelectionChanged: (s) => onFilter(s.first),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            if (shown.isEmpty)
              AppCard(
                padding: const EdgeInsets.symmetric(vertical: 54),
                child: Center(
                  child: Text(
                    filter == _Queue.open
                        ? 'Nothing waiting. All caught up.'
                        : 'Nothing matches that search.',
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
                      _RequestRow(
                        request: shown[i],
                        showWho: true,
                        onTap: () => onOpen(shown[i]),
                        onDelete: canDelete && !shown[i].status.isOpen
                            ? () => onDelete(shown[i])
                            : null,
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

// ---------------------------- student view ----------------------------

class _MineSection extends StatelessWidget {
  final String collegeId;
  final String uid;
  final bool canCreate;
  final VoidCallback onRaise;
  final ValueChanged<HostelRequest> onOpen;

  const _MineSection({
    required this.collegeId,
    required this.uid,
    required this.canCreate,
    required this.onRaise,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<HostelRequest>>(
      stream: RequestService.instance.watchMine(collegeId, uid),
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
            padding: const EdgeInsets.symmetric(vertical: 56, horizontal: 28),
            child: Column(
              children: [
                Container(
                  height: 62,
                  width: 62,
                  decoration: BoxDecoration(
                    color: AppColors.primarySoft,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Icon(
                    Icons.assignment_turned_in_rounded,
                    size: 29,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  'No requests yet',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 430),
                  child: Text(
                    'Ask for leave, report something broken in your room, or '
                    'request a room change. You\'ll see the warden\'s reply '
                    'here.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 14,
                      height: 1.5,
                    ),
                  ),
                ),
                if (canCreate) ...[
                  const SizedBox(height: 22),
                  ElevatedButton.icon(
                    onPressed: onRaise,
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('Raise a request'),
                  ),
                ],
              ],
            ),
          );
        }

        return AppCard(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            children: [
              for (var i = 0; i < mine.length; i++) ...[
                _RequestRow(
                  request: mine[i],
                  showWho: false,
                  onTap: () => onOpen(mine[i]),
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
        );
      },
    );
  }
}

// ------------------------------- pieces -------------------------------

/// Colour for a status pill. Kept in one place so the queue, the student list
/// and the detail screen can't disagree about what "approved" looks like.
({Color fg, Color bg}) statusColours(RequestStatus s) => switch (s) {
  RequestStatus.pending => (fg: AppColors.warning, bg: AppColors.warningSoft),
  RequestStatus.inProgress => (fg: AppColors.info, bg: AppColors.infoSoft),
  RequestStatus.approved => (fg: AppColors.success, bg: AppColors.successSoft),
  RequestStatus.resolved => (fg: AppColors.success, bg: AppColors.successSoft),
  RequestStatus.rejected => (fg: AppColors.danger, bg: AppColors.dangerSoft),
};

IconData typeIcon(RequestType t) => switch (t) {
  RequestType.leave => Icons.flight_takeoff_rounded,
  RequestType.complaint => Icons.build_rounded,
  RequestType.roomChange => Icons.swap_horiz_rounded,
  RequestType.other => Icons.help_outline_rounded,
};

String shortDate(DateTime? d) {
  if (d == null) return '';
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
  return '${d.day} ${months[d.month - 1]}';
}

class _RequestRow extends StatelessWidget {
  final HostelRequest request;
  final bool showWho;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  const _RequestRow({
    required this.request,
    required this.showWho,
    required this.onTap,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final c = statusColours(request.status);

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        child: Row(
          children: [
            Container(
              height: 40,
              width: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.primarySoft,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(
                typeIcon(request.type),
                size: 19,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              flex: 4,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    request.subject.isEmpty
                        ? request.type.label
                        : request.subject,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14.5,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      request.type.label,
                      if (showWho) request.raisedByName,
                      if (request.whereFrom != null) request.whereFrom!,
                      if (request.leaveDays != null)
                        '${request.leaveDays} day(s)',
                      if (request.createdAt != null)
                        shortDate(request.createdAt),
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
            StatusPill(request.status.label.toUpperCase(), c.fg, c.bg),
            if (onDelete != null)
              IconButton(
                onPressed: onDelete,
                icon: Icon(
                  Icons.delete_outline_rounded,
                  size: 19,
                  color: AppColors.danger,
                ),
                tooltip: 'Delete this request',
                visualDensity: VisualDensity.compact,
              )
            else
              const SizedBox(width: 6),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: AppColors.textMuted,
            ),
          ],
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _Metric(this.label, this.value, this.color);

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: TextStyle(
          color: AppColors.textMuted,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(height: 2),
      Text(
        value,
        style: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    ],
  );
}

class _TabButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _TabButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(9),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: selected ? AppColors.primary : AppColors.canvas,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(
          color: selected ? AppColors.primary : AppColors.border,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: selected ? Colors.white : AppColors.textStrong,
        ),
      ),
    ),
  );
}
