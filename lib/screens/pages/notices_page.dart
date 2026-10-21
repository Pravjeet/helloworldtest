import 'package:flutter/material.dart';

import '../../core/permissions.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../models/notice.dart';
import '../../services/auth_service.dart';
import '../../services/notice_service.dart';
import 'college_notices_view.dart';
import 'post_notice_view.dart';

/// Notices: announcements for the whole college.
///
/// Staff with `notices.manage` see a button to post; everyone with
/// `notices.view` sees the list. A notice may have an expiry date; expired
/// ones still exist in Firestore but students see them marked as archived.
class NoticesPage extends StatefulWidget {
  const NoticesPage({super.key});

  @override
  State<NoticesPage> createState() => _NoticesPageState();
}

class _NoticesPageState extends State<NoticesPage> {
  bool _posting = false;
  String _filter = 'active'; // 'active', 'expired', 'all'

  /// 0 = notices posted in this app, 1 = the college's own feed.
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final session = Session.of(context);
    final collegeId = session.user.collegeId;
    final canCreate = session.can(Perm.noticesManage);
    final canView = session.can(Perm.noticesView);

    if (_posting) {
      return PostNoticeView(
        onBack: () => setState(() => _posting = false),
        onDone: () => setState(() => _posting = false),
      );
    }

    if (!canView) {
      return AppCard(
        padding: EdgeInsets.symmetric(vertical: 54),
        child: Center(
          child: Text(
            'You don\'t have permission to view notices.',
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
                'Notices',
                trailing: (canCreate && _tab == 0)
                    ? ElevatedButton.icon(
                        onPressed: () => setState(() => _posting = true),
                        icon: const Icon(Icons.add_rounded, size: 18),
                        label: const Text('Post notice'),
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
                _tab == 0
                    ? 'Announcements posted by hostel staff.'
                    : 'Notices published by the college on sliet.ac.in.',
                style: TextStyle(fontSize: 13, color: AppColors.textMuted),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  _TabButton(
                    label: 'Hostel',
                    selected: _tab == 0,
                    onTap: () => setState(() => _tab = 0),
                  ),
                  const SizedBox(width: 8),
                  _TabButton(
                    label: 'College',
                    selected: _tab == 1,
                    onTap: () => setState(() => _tab = 1),
                  ),
                ],
              ),
              if (_tab == 0) ...[
                const SizedBox(height: 16),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'active', label: Text('Active')),
                    ButtonSegment(value: 'expired', label: Text('Expired')),
                    ButtonSegment(value: 'all', label: Text('All')),
                  ],
                  selected: {_filter},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) => setState(() => _filter = s.first),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 18),
        if (_tab == 1)
          const CollegeNoticesView()
        else
          StreamBuilder<List<Notice>>(
            stream: NoticeService.instance.watchAll(collegeId),
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

              final all = snap.data!;
              final active = all.where((n) => !n.isExpired).toList();
              final expired = all.where((n) => n.isExpired).toList();

              final shown = switch (_filter) {
                'active' => active,
                'expired' => expired,
                _ => all,
              };

              if (shown.isEmpty) {
                return AppCard(
                  padding: const EdgeInsets.symmetric(vertical: 54),
                  child: Center(
                    child: Text(
                      _filter == 'active'
                          ? 'No active notices.'
                          : _filter == 'expired'
                          ? 'No expired notices.'
                          : 'No notices yet.',
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
                      _NoticeRow(
                        notice: shown[i],
                        canDelete:
                            canCreate ||
                            shown[i].postedByUid == session.user.uid,
                        onDelete: () async {
                          final messenger = ScaffoldMessenger.of(context);
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (c) => AlertDialog(
                              title: const Text('Delete this notice?'),
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
                                  child: const Text('Delete'),
                                ),
                              ],
                            ),
                          );
                          if (ok != true) return;
                          try {
                            await NoticeService.instance.delete(
                              collegeId: collegeId,
                              noticeId: shown[i].id,
                            );
                            messenger.showSnackBar(
                              const SnackBar(content: Text('Notice deleted')),
                            );
                          } catch (e) {
                            messenger.showSnackBar(
                              SnackBar(
                                content: Text(AuthService.describeError(e)),
                              ),
                            );
                          }
                        },
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

class _NoticeRow extends StatelessWidget {
  final Notice notice;
  final bool canDelete;
  final VoidCallback onDelete;

  const _NoticeRow({
    required this.notice,
    required this.canDelete,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
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
    final dateStr = notice.createdAt == null
        ? ''
        : '${notice.createdAt!.day} ${months[notice.createdAt!.month - 1]}';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 44,
                width: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: notice.isExpired
                      ? AppColors.canvas
                      : AppColors.primarySoft,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.notifications_rounded,
                  size: 20,
                  color: notice.isExpired
                      ? AppColors.textMuted
                      : AppColors.primary,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      notice.title,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: notice.isExpired
                            ? AppColors.textMuted
                            : AppColors.textStrong,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Text(
                          notice.category,
                          style: TextStyle(
                            fontSize: 12,
                            color: notice.isExpired
                                ? AppColors.textMuted
                                : AppColors.textMuted,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          ' · ',
                          style: TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 12,
                          ),
                        ),
                        Text(
                          notice.postedByName,
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.textMuted,
                          ),
                        ),
                        if (dateStr.isNotEmpty) ...[
                          Text(
                            ' · ',
                            style: TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 12,
                            ),
                          ),
                          Text(
                            dateStr,
                            style: TextStyle(
                              fontSize: 12,
                              color: AppColors.textMuted,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              if (notice.isExpired)
                Chip(
                  label: const Text('Archived'),
                  backgroundColor: AppColors.canvas,
                  labelStyle: TextStyle(
                    fontSize: 11,
                    color: AppColors.textMuted,
                  ),
                )
              else if (canDelete)
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
                          SizedBox(width: 10),
                          Text(
                            'Delete',
                            style: TextStyle(color: AppColors.danger),
                          ),
                        ],
                      ),
                    ),
                  ],
                  onSelected: (value) {
                    if (value == 'delete') onDelete();
                  },
                  child: const Icon(Icons.more_vert_rounded, size: 20),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            notice.content,
            style: TextStyle(
              fontSize: 13.5,
              color: notice.isExpired
                  ? AppColors.textMuted
                  : AppColors.textStrong,
              height: 1.5,
            ),
          ),
          if (notice.expiryDate != null) ...[
            const SizedBox(height: 8),
            Text(
              'Expires: ${notice.expiryLabel}',
              style: TextStyle(
                fontSize: 11,
                color: notice.isExpired
                    ? AppColors.danger
                    : AppColors.textMuted,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
