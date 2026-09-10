import 'package:flutter/material.dart';

import '../../core/identity.dart';
import '../../core/permissions.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../models/fine.dart';
import '../../models/hostel_request.dart';
import '../../models/mess.dart';
import '../../models/notice.dart';
import '../../services/fine_service.dart';
import '../../services/mess_service.dart';
import '../../services/notice_service.dart';
import '../../services/request_service.dart';
import '../dashboard_shell.dart';

/// The landing page for a resident.
///
/// Built around the four questions a student actually opens the app to
/// answer: where do I live, what do I owe, what's for dinner, and did anyone
/// reply to me. Everything on it is live and everything is a shortcut — a
/// dashboard that only *displays* numbers makes you navigate twice.
///
/// Blocks disappear rather than showing "—" when the student lacks the
/// permission behind them. An empty placeholder tile is worse than no tile:
/// it looks broken.
class StudentHome extends StatelessWidget {
  const StudentHome({super.key});

  @override
  Widget build(BuildContext context) {
    final session = Session.of(context);
    final user = session.user;
    final collegeId = user.collegeId;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Greeting(),
        const SizedBox(height: 18),
        _StatRow(collegeId: collegeId, uid: user.uid),
        const SizedBox(height: 18),
        LayoutBuilder(
          builder: (context, c) {
            final wide = c.maxWidth > 900;
            final mess = session.can(Perm.messView)
                ? _TodaysMess(collegeId: collegeId)
                : null;
            const actions = _QuickActions();

            if (!wide) {
              return Column(
                children: [
                  if (mess != null) ...[mess, const SizedBox(height: 18)],
                  actions,
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (mess != null) ...[
                  Expanded(flex: 3, child: mess),
                  const SizedBox(width: 18),
                ],
                const Expanded(flex: 2, child: actions),
              ],
            );
          },
        ),
        const SizedBox(height: 18),
        LayoutBuilder(
          builder: (context, c) {
            final requests = session.canAny([
              Perm.requestsViewOwn,
              Perm.requestsCreate,
            ])
                ? _MyRequests(collegeId: collegeId, uid: user.uid)
                : null;
            final notices = session.can(Perm.noticesView)
                ? _LatestNotices(collegeId: collegeId)
                : null;

            final blocks = [
              if (requests != null) requests,
              if (notices != null) notices,
            ];
            if (blocks.isEmpty) return const SizedBox.shrink();
            if (c.maxWidth <= 900 || blocks.length == 1) {
              return Column(
                children: [
                  for (var i = 0; i < blocks.length; i++) ...[
                    if (i != 0) const SizedBox(height: 18),
                    blocks[i],
                  ],
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: blocks[0]),
                const SizedBox(width: 18),
                Expanded(child: blocks[1]),
              ],
            );
          },
        ),
      ],
    );
  }
}

// ------------------------------- greeting -------------------------------

class _Greeting extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final user = Session.of(context).user;
    final now = DateTime.now();
    final hour = now.hour;
    final part = hour < 12
        ? 'Good morning'
        : hour < 17
        ? 'Good afternoon'
        : 'Good evening';
    final first = user.name.trim().split(RegExp(r'\s+')).first;

    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 20),
      child: Row(
        children: [
          CircleAvatar(
            radius: 27,
            backgroundColor: AppColors.primarySoft,
            child: Text(
              user.initials,
              style: TextStyle(
                color: AppColors.primary,
                fontWeight: FontWeight.w800,
                fontSize: 17,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$part, $first',
                  style: const TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  [
                    Identity.display(user.email),
                    if (user.trade != null) user.trade!,
                    if (user.sem != null) 'Sem ${user.sem}',
                    if (user.roomLabel != null) user.roomLabel!,
                  ].join('  ·  '),
                  style: TextStyle(
                    fontSize: 13,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                weekdayName(now.weekday),
                style: const TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                _longDate(now),
                style: TextStyle(
                  fontSize: 12.5,
                  color: AppColors.textMuted,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

String _longDate(DateTime d) {
  const months = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];
  return '${d.day} ${months[d.month - 1]} ${d.year}';
}

// -------------------------------- stats --------------------------------

class _StatRow extends StatelessWidget {
  final String collegeId;
  final String uid;

  const _StatRow({required this.collegeId, required this.uid});

  @override
  Widget build(BuildContext context) {
    final session = Session.of(context);
    final user = session.user;

    return LayoutBuilder(
      builder: (context, c) {
        final columns = c.maxWidth > 900
            ? 3
            : c.maxWidth > 560
            ? 2
            : 1;

        final tiles = <Widget>[
          _Tile(
            label: 'Your room',
            value: user.roomNumber ?? 'Not allotted',
            sub: user.hostelName ?? 'Ask your warden',
            icon: Icons.meeting_room_rounded,
            color: user.isAllotted ? AppColors.primary : AppColors.warning,
            navId: 'my-room',
          ),
          if (session.can(Perm.finesViewOwn))
            StreamBuilder<List<Fine>>(
              stream: FineService.instance.watchMine(collegeId, uid),
              builder: (context, snap) {
                final s = FineSummary(snap.data ?? const []);
                final owed = s.outstanding;
                return _Tile(
                  label: 'Fines outstanding',
                  value: snap.hasData ? '₹${owed.toStringAsFixed(0)}' : '…',
                  sub: owed == 0
                      ? 'Nothing owed'
                      : '${s.fines.where((f) => f.status.isOutstanding).length} '
                            'unpaid',
                  icon: Icons.gavel_rounded,
                  color: owed == 0 ? AppColors.success : AppColors.danger,
                  navId: 'fines',
                );
              },
            ),
          if (session.canAny([Perm.requestsViewOwn, Perm.requestsCreate]))
            StreamBuilder<List<HostelRequest>>(
              stream: RequestService.instance.watchMine(collegeId, uid),
              builder: (context, snap) {
                final all = snap.data ?? const <HostelRequest>[];
                final open = all.where((r) => r.status.isOpen).length;
                return _Tile(
                  label: 'Open requests',
                  value: snap.hasData ? '$open' : '…',
                  sub: all.isEmpty
                      ? 'None raised yet'
                      : '${all.length} in total',
                  icon: Icons.assignment_turned_in_rounded,
                  color: open == 0 ? AppColors.success : AppColors.info,
                  navId: 'requests',
                );
              },
            ),
        ];

        return GridView.count(
          crossAxisCount: columns,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 16,
          crossAxisSpacing: 16,
          childAspectRatio: 2.6,
          children: tiles,
        );
      },
    );
  }
}

class _Tile extends StatelessWidget {
  final String label;
  final String value;
  final String sub;
  final IconData icon;
  final Color color;
  final String? navId;

  const _Tile({
    required this.label,
    required this.value,
    required this.sub,
    required this.icon,
    required this.color,
    this.navId,
  });

  @override
  Widget build(BuildContext context) {
    final nav = DashboardNav.maybeOf(context);
    final canGo = navId != null && (nav?.canReach(navId!) ?? false);

    return InkWell(
      onTap: canGo ? () => nav!.goTo(navId!) : null,
      borderRadius: BorderRadius.circular(14),
      child: AppCard(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            Container(
              height: 46,
              width: 46,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(13),
              ),
              child: Icon(icon, color: color, size: 23),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      value,
                      style: TextStyle(
                        fontSize: 23,
                        fontWeight: FontWeight.w800,
                        color: color,
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            if (canGo)
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

// ------------------------------ today's mess ------------------------------

class _TodaysMess extends StatelessWidget {
  final String collegeId;
  const _TodaysMess({required this.collegeId});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final nav = DashboardNav.maybeOf(context);

    return StreamBuilder<MessMenu>(
      stream: MessService.instance.watchMenu(collegeId),
      builder: (context, snap) {
        final menu = snap.data;

        return AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionHeader(
                'Today\'s mess  ·  ${weekdayName(now.weekday)}',
                trailing: (nav?.canReach('mess') ?? false)
                    ? TextButton(
                        onPressed: () => nav!.goTo('mess'),
                        child: const Text('Full week'),
                      )
                    : null,
              ),
              const SizedBox(height: 12),
              if (menu == null)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 30),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (menu.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 22),
                  child: Text(
                    'The menu hasn\'t been published yet.',
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 13,
                    ),
                  ),
                )
              else
                for (final meal in Meal.values) ...[
                  _MealRow(
                    meal: meal,
                    item: menu.item(now.weekday, meal),
                    // The meal happening now gets the accent, so a glance
                    // answers "what's next" without reading four rows.
                    highlight: _isCurrent(meal, now),
                  ),
                  if (meal != Meal.values.last)
                    Divider(height: 18, color: AppColors.border),
                ],
            ],
          ),
        );
      },
    );
  }

  /// Rough serving windows, used only to pick which row to emphasise.
  static bool _isCurrent(Meal meal, DateTime now) {
    final h = now.hour;
    return switch (meal) {
      Meal.breakfast => h < 10,
      Meal.lunch => h >= 10 && h < 16,
      Meal.eveningTea => h >= 16 && h < 19,
      Meal.dinner => h >= 19,
    };
  }
}

class _MealRow extends StatelessWidget {
  final Meal meal;
  final String? item;
  final bool highlight;

  const _MealRow({
    required this.meal,
    required this.item,
    required this.highlight,
  });

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        height: 34,
        width: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: highlight ? AppColors.primarySoft : AppColors.canvas,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(
          switch (meal) {
            Meal.breakfast => Icons.free_breakfast_rounded,
            Meal.lunch => Icons.lunch_dining_rounded,
            Meal.eveningTea => Icons.emoji_food_beverage_rounded,
            Meal.dinner => Icons.dinner_dining_rounded,
          },
          size: 17,
          color: highlight ? AppColors.primary : AppColors.textMuted,
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  meal.label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: highlight
                        ? AppColors.primary
                        : AppColors.textStrong,
                  ),
                ),
                if (highlight) ...[
                  const SizedBox(width: 8),
                  StatusPill(
                    'NOW',
                    AppColors.primary,
                    AppColors.primarySoft,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 3),
            Text(
              item ?? 'Not listed',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.45,
                color: item == null
                    ? AppColors.textMuted
                    : AppColors.textStrong,
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

// ----------------------------- quick actions -----------------------------

class _QuickActions extends StatelessWidget {
  const _QuickActions();

  @override
  Widget build(BuildContext context) {
    final nav = DashboardNav.maybeOf(context);

    // Only offer what this person can actually reach — a shortcut to a page
    // their permissions hid would silently do nothing.
    final actions = <({String id, String label, IconData icon})>[
      (
        id: 'requests',
        label: 'Raise a request',
        icon: Icons.add_comment_rounded,
      ),
      (id: 'my-room', label: 'My room & roommates', icon: Icons.bed_rounded),
      (id: 'mess', label: 'Mess menu & fees', icon: Icons.restaurant_rounded),
      (id: 'fines', label: 'My fines', icon: Icons.gavel_rounded),
      (id: 'notices', label: 'Notices', icon: Icons.campaign_rounded),
      (
        id: 'office-orders',
        label: 'Office orders',
        icon: Icons.description_rounded,
      ),
      (id: 'profile', label: 'Edit my profile', icon: Icons.person_rounded),
    ].where((a) => nav?.canReach(a.id) ?? false).toList();

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader('Quick actions'),
          const SizedBox(height: 12),
          if (actions.isEmpty)
            Text(
              'Nothing available for your role yet.',
              style: TextStyle(color: AppColors.textMuted, fontSize: 13),
            )
          else
            for (final a in actions)
              InkWell(
                onTap: () => nav!.goTo(a.id),
                borderRadius: BorderRadius.circular(9),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  child: Row(
                    children: [
                      Icon(a.icon, size: 18, color: AppColors.primary),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          a.label,
                          style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 18,
                        color: AppColors.textMuted,
                      ),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

// ----------------------------- my requests -----------------------------

class _MyRequests extends StatelessWidget {
  final String collegeId;
  final String uid;

  const _MyRequests({required this.collegeId, required this.uid});

  @override
  Widget build(BuildContext context) {
    final nav = DashboardNav.maybeOf(context);

    return StreamBuilder<List<HostelRequest>>(
      stream: RequestService.instance.watchMine(collegeId, uid),
      builder: (context, snap) {
        final all = snap.data ?? const <HostelRequest>[];
        final shown = all.take(4).toList();

        return AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionHeader(
                'My requests',
                trailing: (nav?.canReach('requests') ?? false)
                    ? TextButton(
                        onPressed: () => nav!.goTo('requests'),
                        child: const Text('See all'),
                      )
                    : null,
              ),
              const SizedBox(height: 10),
              if (!snap.hasData)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 26),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (shown.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 22),
                  child: Text(
                    'Nothing raised yet. Use Quick actions to ask for leave '
                    'or report a problem.',
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 13,
                      height: 1.5,
                    ),
                  ),
                )
              else
                for (var i = 0; i < shown.length; i++) ...[
                  if (i != 0)
                    Divider(height: 16, color: AppColors.border),
                  _MiniRow(
                    icon: switch (shown[i].type) {
                      RequestType.leave => Icons.flight_takeoff_rounded,
                      RequestType.complaint => Icons.build_rounded,
                      RequestType.roomChange => Icons.swap_horiz_rounded,
                      RequestType.other => Icons.help_outline_rounded,
                    },
                    title: shown[i].subject.isEmpty
                        ? shown[i].type.label
                        : shown[i].subject,
                    subtitle: shown[i].type.label,
                    pill: shown[i].status.label.toUpperCase(),
                    pillColor: shown[i].status.isOpen
                        ? AppColors.warning
                        : AppColors.success,
                    pillBg: shown[i].status.isOpen
                        ? AppColors.warningSoft
                        : AppColors.successSoft,
                  ),
                ],
            ],
          ),
        );
      },
    );
  }
}

// ------------------------------- notices -------------------------------

class _LatestNotices extends StatelessWidget {
  final String collegeId;
  const _LatestNotices({required this.collegeId});

  @override
  Widget build(BuildContext context) {
    final nav = DashboardNav.maybeOf(context);

    return StreamBuilder<List<Notice>>(
      stream: NoticeService.instance.watchAll(collegeId),
      builder: (context, snap) {
        final active = (snap.data ?? const <Notice>[])
            .where((n) => !n.isExpired)
            .take(4)
            .toList();

        return AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionHeader(
                'Latest notices',
                trailing: (nav?.canReach('notices') ?? false)
                    ? TextButton(
                        onPressed: () => nav!.goTo('notices'),
                        child: const Text('See all'),
                      )
                    : null,
              ),
              const SizedBox(height: 10),
              if (!snap.hasData)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 26),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (active.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 22),
                  child: Text(
                    'No active notices.',
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 13,
                    ),
                  ),
                )
              else
                for (var i = 0; i < active.length; i++) ...[
                  if (i != 0)
                    Divider(height: 16, color: AppColors.border),
                  _MiniRow(
                    icon: Icons.campaign_rounded,
                    title: active[i].title,
                    subtitle: [
                      active[i].category,
                      active[i].postedByName,
                    ].join(' · '),
                  ),
                ],
            ],
          ),
        );
      },
    );
  }
}

// -------------------------------- shared --------------------------------

class _MiniRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String? pill;
  final Color? pillColor;
  final Color? pillBg;

  const _MiniRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.pill,
    this.pillColor,
    this.pillBg,
  });

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(
        height: 34,
        width: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.primarySoft,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, size: 16, color: AppColors.primary),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: AppColors.textMuted,
              ),
            ),
          ],
        ),
      ),
      if (pill != null) ...[
        const SizedBox(width: 8),
        StatusPill(pill!, pillColor!, pillBg!),
      ],
    ],
  );
}
