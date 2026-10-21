import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../core/theme.dart';
import '../../models/hostel_request.dart';
import '../../services/auth_service.dart';
import '../../services/request_service.dart';
import 'requests_page.dart' show statusColours, typeIcon, shortDate;

/// One request in full, with the actions available to whoever is looking.
///
/// The action buttons come from [RequestTypeX.nextStates], so a complaint can
/// never be "approved" and leave can never be "resolved" — the model decides,
/// not the UI.
class RequestDetailView extends StatefulWidget {
  final String requestId;
  final HostelRequest initial;
  final bool canApprove;
  final VoidCallback onBack;

  const RequestDetailView({
    super.key,
    required this.requestId,
    required this.initial,
    required this.canApprove,
    required this.onBack,
  });

  @override
  State<RequestDetailView> createState() => _RequestDetailViewState();
}

class _RequestDetailViewState extends State<RequestDetailView> {
  final _note = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _act(HostelRequest request, RequestStatus status) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final session = Session.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await RequestService.instance.setStatus(
        collegeId: session.user.collegeId,
        request: request,
        status: status,
        handler: session.user,
        note: _note.text,
      );
      messenger.showSnackBar(
        SnackBar(content: Text('Marked ${status.label.toLowerCase()}')),
      );
      if (mounted) _note.clear();
    } catch (e) {
      if (mounted) setState(() => _error = AuthService.describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _withdraw(HostelRequest request) async {
    final messenger = ScaffoldMessenger.of(context);
    final collegeId = Session.of(context).user.collegeId;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Withdraw this request?'),
        content: const Text(
          'It will be removed entirely. You can raise a new one any time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Withdraw'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      await RequestService.instance.withdraw(
        collegeId: collegeId,
        request: request,
      );
      messenger.showSnackBar(
        const SnackBar(content: Text('Request withdrawn')),
      );
      widget.onBack();
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

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 820),
      child: StreamBuilder<List<HostelRequest>>(
        // Reuse the stream the list already runs, so an action taken here is
        // reflected without a second listener or a manual refresh.
        stream: widget.canApprove
            ? RequestService.instance.watchAll(collegeId)
            : RequestService.instance.watchMine(collegeId, session.user.uid),
        builder: (context, snap) {
          // Fall back to the row we were opened with until the stream
          // delivers, so the screen never flashes empty.
          var request = widget.initial;
          for (final r in snap.data ?? const <HostelRequest>[]) {
            if (r.id == widget.requestId) {
              request = r;
              break;
            }
          }

          final isMine = request.raisedByUid == session.user.uid;
          final c = statusColours(request.status);
          final actions = request.type.nextStates;
          final canAct =
              widget.canApprove && request.status == RequestStatus.pending;
          final canProgress =
              widget.canApprove && request.status == RequestStatus.inProgress;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        IconButton(
                          onPressed: widget.onBack,
                          icon: const Icon(Icons.arrow_back_rounded),
                          tooltip: 'Back to requests',
                        ),
                        const SizedBox(width: 4),
                        Container(
                          height: 42,
                          width: 42,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: AppColors.primarySoft,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            typeIcon(request.type),
                            size: 20,
                            color: AppColors.primary,
                          ),
                        ),
                        const SizedBox(width: 13),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                request.subject.isEmpty
                                    ? request.type.label
                                    : request.subject,
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                [
                                  request.type.label,
                                  if (request.category != null)
                                    request.category!,
                                  if (request.createdAt != null)
                                    'Raised ${shortDate(request.createdAt)}',
                                ].join(' · '),
                                style: TextStyle(
                                  color: AppColors.textMuted,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                        StatusPill(
                          request.status.label.toUpperCase(),
                          c.fg,
                          c.bg,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),

              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SectionHeader('Details'),
                    const SizedBox(height: 14),
                    _Line('Raised by', request.raisedByName),
                    if (request.raisedByRegNo != null)
                      _Line('Registration no.', request.raisedByRegNo!),
                    _Line('Room', request.whereFrom ?? 'No room allotted'),
                    if (request.type == RequestType.leave) ...[
                      _Line(
                        'Dates',
                        '${shortDate(request.fromDate)} → '
                            '${shortDate(request.toDate)}'
                            '${request.leaveDays != null ? '  (${request.leaveDays} days)' : ''}',
                      ),
                      if (request.destination != null)
                        _Line('Destination', request.destination!),
                    ],
                    if (request.details.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(
                        'NOTES',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.9,
                          color: AppColors.textMuted,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        request.details,
                        style: const TextStyle(fontSize: 13.5, height: 1.5),
                      ),
                    ],
                  ],
                ),
              ),

              if (request.handledByName != null) ...[
                const SizedBox(height: 18),
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SectionHeader(
                        request.type.isDecision ? 'Decision' : 'Response',
                      ),
                      const SizedBox(height: 12),
                      _Line('By', request.handledByName!),
                      if (request.handledAt != null)
                        _Line('On', shortDate(request.handledAt)),
                      if (request.decisionNote != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          request.decisionNote!,
                          style: const TextStyle(fontSize: 13.5, height: 1.5),
                        ),
                      ],
                    ],
                  ),
                ),
              ],

              if (_error != null) ...[
                const SizedBox(height: 18),
                AppCard(
                  padding: const EdgeInsets.all(14),
                  child: Text(
                    _error!,
                    style: TextStyle(color: AppColors.danger, fontSize: 13),
                  ),
                ),
              ],

              // ------------------------ actions ------------------------
              if (canAct || canProgress) ...[
                const SizedBox(height: 18),
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SectionHeader(
                        request.type.isDecision
                            ? 'Approve or reject'
                            : 'Update this complaint',
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _note,
                        enabled: !_busy,
                        maxLines: 2,
                        decoration: InputDecoration(
                          labelText: request.type.isDecision
                              ? 'Note for the student (optional)'
                              : 'What was done (optional)',
                          alignLabelWithHint: true,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          for (final s
                              in canProgress
                                  ? [RequestStatus.resolved]
                                  : actions)
                            FilledButton(
                              onPressed: _busy ? null : () => _act(request, s),
                              style: FilledButton.styleFrom(
                                backgroundColor: s == RequestStatus.rejected
                                    ? AppColors.danger
                                    : s == RequestStatus.inProgress
                                    ? AppColors.info
                                    : AppColors.primary,
                              ),
                              child: Text(switch (s) {
                                RequestStatus.approved => 'Approve',
                                RequestStatus.rejected => 'Reject',
                                RequestStatus.inProgress => 'Mark in progress',
                                RequestStatus.resolved => 'Mark resolved',
                                RequestStatus.pending => 'Pending',
                              }),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],

              if (isMine && request.status == RequestStatus.pending) ...[
                const SizedBox(height: 18),
                AppCard(
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Raised this by mistake? You can withdraw it while '
                          'nobody has acted on it yet.',
                          style: TextStyle(
                            fontSize: 13,
                            color: AppColors.textMuted,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton(
                        onPressed: () => _withdraw(request),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.danger,
                        ),
                        child: const Text('Withdraw'),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _Line extends StatelessWidget {
  final String label;
  final String value;
  const _Line(this.label, this.value);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 9),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 150,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              color: AppColors.textMuted,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(child: Text(value, style: const TextStyle(fontSize: 13.5))),
      ],
    ),
  );
}
