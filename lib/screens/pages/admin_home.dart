import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../core/permissions.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../models/app_user.dart';
import '../../models/fee.dart';
import '../../models/fine.dart';
import '../../models/hostel.dart';
import '../../models/hostel_request.dart';
import '../../models/mess.dart';
import '../../models/notice.dart';
import '../../services/data_service.dart';
import '../../services/fee_service.dart';
import '../../services/fine_service.dart';
import '../../services/hostel_service.dart';
import '../../services/mess_service.dart';
import '../../services/notice_service.dart';
import '../../services/request_service.dart';
import '../dashboard_shell.dart';

/// The staff landing page: the whole institution at a glance.
///
/// Laid out as one KPI strip over three card rows. Colour is deliberately
/// scarce — the accent marks links and bars, and red/amber appear *only* where
/// something is actually wrong. When every tile is coloured, none of them mean
/// anything.
///
/// Every block reads live data and every number is a shortcut: nothing here
/// makes you navigate twice to act on what you just read.
class AdminHome extends StatelessWidget {
  const AdminHome({super.key});

  @override
  Widget build(BuildContext context) {
    final session = Session.of(context);
    final collegeId = session.user.collegeId;

    // Everything on the page hangs off these five streams. Gathered at the
    // top rather than per-card so the counts can never disagree with each
    // other mid-frame.
    return _Feed(
      collegeId: collegeId,
      builder: (context, data) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _KpiStrip(data: data),
          const SizedBox(height: 16),
          _Row3(
            first: _UsersByRole(data: data),
            second: _Occupancy(data: data),
            third: _RecentActivity(data: data),
          ),
          const SizedBox(height: 16),
          _Row3(
            first: _RequestsCard(data: data),
            second: _RevenueCard(data: data),
            third: _DuesCard(data: data),
          ),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, c) {
              final table = _RecentPayments(data: data);
              if (c.maxWidth <= 1100) {
                return Column(
                  children: [
                    table,
                    const SizedBox(height: 16),
                    const _QuickActions(),
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 7, child: table),
                  const SizedBox(width: 16),
                  const Expanded(flex: 5, child: _QuickActions()),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Three cards side by side, collapsing to two then one.
class _Row3 extends StatelessWidget {
  final Widget first;
  final Widget second;
  final Widget third;

  const _Row3({
    required this.first,
    required this.second,
    required this.third,
  });

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      if (c.maxWidth > 1180) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 10, child: first),
            const SizedBox(width: 16),
            Expanded(flex: 12, child: second),
            const SizedBox(width: 16),
            Expanded(flex: 11, child: third),
          ],
        );
      }
      if (c.maxWidth > 820) {
        return Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: first),
                const SizedBox(width: 16),
                Expanded(child: second),
              ],
            ),
            const SizedBox(height: 16),
            third,
          ],
        );
      }
      return Column(
        children: [
          first,
          const SizedBox(height: 16),
          second,
          const SizedBox(height: 16),
          third,
        ],
      );
    },
  );
}

// =====================================================================
// Data
// =====================================================================

/// Everything the dashboard renders, resolved together.
class _Data {
  final List<AppUser> users;
  final List<Hostel> hostels;
  final List<HostelRequest> requests;
  final List<Fine> fines;
  final List<FeeRecord> fees;
  final List<Notice> notices;
  final MessConfig mess;

  const _Data({
    required this.users,
    required this.hostels,
    required this.requests,
    required this.fines,
    required this.fees,
    required this.notices,
    required this.mess,
  });

  List<AppUser> get residents => users.where((u) => u.isAllotted).toList();
  List<AppUser> get staff =>
      users.where((u) => !u.isAllotted && !u.isSuperAdmin).toList();
  int get unassigned => users.where((u) => u.roleId == null).length;
  int get inactive => users.where((u) => !u.isActive).length;

  int get totalRooms => hostels.fold(0, (a, h) => a + h.roomCount);
  int get totalBeds => hostels.fold(0, (a, h) => a + h.bedCount);
  int get occupiedBeds => hostels.fold(0, (a, h) => a + h.occupiedBeds);
  int get freeBeds => (totalBeds - occupiedBeds).clamp(0, totalBeds);
  double get occupancy => totalBeds == 0 ? 0 : occupiedBeds / totalBeds;

  List<HostelRequest> get openRequests =>
      requests.where((r) => r.status.isOpen).toList();

  num get outstandingFines => fines
      .where((f) => f.status.isOutstanding)
      .fold<num>(0, (a, f) => a + f.amount);

  String get thisPeriod => periodOf(DateTime.now());

  List<FeeRecord> get thisMonthFees =>
      fees.where((f) => f.period == thisPeriod).toList();

  num get collectedThisMonth =>
      thisMonthFees.fold<num>(0, (a, f) => a + f.amount);

  /// What the mess *should* bring in this month if every resident pays.
  num get expectedThisMonth => mess.monthlyCharge * residents.length;

  num get messPending =>
      (expectedThisMonth - collectedThisMonth).clamp(0, double.infinity);

  int get unpaidResidents {
    final paid = thisMonthFees.map((f) => f.studentUid).toSet();
    return residents.where((r) => !paid.contains(r.uid)).length;
  }

  /// The last 7 periods, oldest first — the x-axis every trend here shares.
  List<String> get trendPeriods =>
      recentPeriods(DateTime.now(), count: 7).reversed.toList();

  /// Head-count at the END of each period, from users' `createdAt`.
  ///
  /// Cumulative rather than per-month arrivals: the tile shows a total, so a
  /// sparkline of monthly intake underneath it would be a different quantity
  /// wearing the same label.
  List<num> growthOf(bool Function(AppUser) test) {
    final matched = users.where(test).toList();
    return [
      for (final p in trendPeriods)
        matched
            .where(
              (u) =>
                  u.createdAt == null || periodOf(u.createdAt!).compareTo(p) <= 0,
            )
            .length,
    ];
  }

  /// How many matching users first appeared this month.
  int addedThisMonth(bool Function(AppUser) test) => users
      .where(test)
      .where((u) => u.createdAt != null && periodOf(u.createdAt!) == thisPeriod)
      .length;

  List<num> get feeTrend => [
    for (final p in trendPeriods)
      fees.where((f) => f.period == p).fold<num>(0, (a, f) => a + f.amount),
  ];

  /// Things a warden should actually look at. Counted, not guessed — an alert
  /// tile that invents urgency trains people to ignore it.
  List<String> get alerts => [
    if (unassigned > 0) '$unassigned user(s) have no role assigned',
    if (inactive > 0) '$inactive account(s) are deactivated',
    if (openRequests.length > 10)
      '${openRequests.length} requests are waiting',
    if (!mess.isConfigured) 'No monthly mess charge is set',
    if (hostels.isEmpty) 'No hostels have been created yet',
  ];
}

/// Fans out the streams the dashboard needs and hands over one snapshot.
class _Feed extends StatelessWidget {
  final String collegeId;
  final Widget Function(BuildContext, _Data) builder;

  const _Feed({required this.collegeId, required this.builder});

  @override
  Widget build(BuildContext context) {
    // Six months back covers the revenue trend without pulling years of
    // history the page never draws.
    final from = recentPeriods(DateTime.now(), count: 7).last;

    return StreamBuilder<List<AppUser>>(
      stream: DataService.instance.watchUsers(collegeId),
      builder: (context, users) => StreamBuilder<List<Hostel>>(
        stream: HostelService.instance.watchHostels(collegeId),
        builder: (context, hostels) => StreamBuilder<List<HostelRequest>>(
          stream: RequestService.instance.watchAll(collegeId),
          builder: (context, requests) => StreamBuilder<List<Fine>>(
            stream: FineService.instance.watchAll(collegeId),
            builder: (context, fines) => StreamBuilder<List<FeeRecord>>(
              stream: FeeService.instance.watchSince(collegeId, from),
              builder: (context, fees) => StreamBuilder<List<Notice>>(
                stream: NoticeService.instance.watchAll(collegeId),
                builder: (context, notices) => StreamBuilder<MessConfig>(
                  stream: MessService.instance.watchConfig(collegeId),
                  builder: (context, mess) {
                    // Rendered as soon as users arrive; the rest fill in as
                    // they land. Blocking on all seven would leave the page
                    // blank for as long as the slowest one takes.
                    if (!users.hasData) {
                      return const Padding(
                        padding: EdgeInsets.all(80),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }
                    return builder(
                      context,
                      _Data(
                        users: users.data!,
                        hostels: hostels.data ?? const [],
                        requests: requests.data ?? const [],
                        fines: fines.data ?? const [],
                        fees: fees.data ?? const [],
                        notices: notices.data ?? const [],
                        mess: mess.data ?? const MessConfig(),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// =====================================================================
// KPI strip
// =====================================================================

/// Six figures on one connected surface rather than six floating boxes — the
/// dividers say "these belong together", which six separate cards do not.
class _KpiStrip extends StatelessWidget {
  final _Data data;
  const _KpiStrip({required this.data});

  @override
  Widget build(BuildContext context) {
    final symbol = data.mess.currencySymbol;

    final newResidents = data.addedThisMonth((u) => u.isAllotted);
    final newStaff = data.addedThisMonth(
      (u) => !u.isAllotted && !u.isSuperAdmin,
    );

    final cells = <Widget>[
      _Kpi(
        icon: Icons.school_rounded,
        label: 'Residents',
        value: '${data.residents.length}',
        sub: '${data.users.length} people in total',
        navId: 'users',
        delta: newResidents > 0 ? '$newResidents this month' : null,
        spark: data.growthOf((u) => u.isAllotted),
      ),
      _Kpi(
        icon: Icons.badge_rounded,
        label: 'Staff',
        value: '${data.staff.length}',
        sub: data.unassigned == 0
            ? 'All have a role'
            : '${data.unassigned} awaiting a role',
        navId: 'users',
        delta: newStaff > 0 ? '$newStaff this month' : null,
        spark: data.growthOf((u) => !u.isAllotted && !u.isSuperAdmin),
      ),
      _Kpi(
        icon: Icons.grid_view_rounded,
        label: 'Rooms',
        value: '${data.totalRooms}',
        sub: data.totalBeds == 0
            ? 'No beds configured'
            : '${(data.occupancy * 100).round()}% full · '
                  '${data.freeBeds} free',
        navId: 'hostels',
      ),
      _Kpi(
        icon: Icons.payments_rounded,
        label: 'Collected · ${periodLabel(data.thisPeriod).split(' ').first}',
        value: '$symbol${_compact(data.collectedThisMonth)}',
        sub: data.mess.isConfigured
            ? '$symbol${_compact(data.messPending)} still due'
            : 'Set a mess charge',
        navId: 'fees',
        spark: data.feeTrend,
      ),
      _Kpi(
        icon: Icons.assignment_rounded,
        label: 'Open requests',
        value: '${data.openRequests.length}',
        sub: data.openRequests.isEmpty ? 'All caught up' : 'Review queue',
        navId: 'requests',
        warn: data.openRequests.length > 10,
      ),
      _Kpi(
        icon: Icons.warning_amber_rounded,
        label: 'Needs attention',
        value: '${data.alerts.length}',
        sub: data.alerts.isEmpty ? 'Nothing outstanding' : data.alerts.first,
        alert: data.alerts.isNotEmpty,
        navId: data.unassigned > 0 ? 'users' : null,
      ),
    ];

    return LayoutBuilder(
      builder: (context, c) {
        final columns = c.maxWidth > 1400
            ? 6
            : c.maxWidth > 860
            ? 3
            : 2;

        return Container(
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (var r = 0; r * columns < cells.length; r++) ...[
                if (r != 0) Divider(height: 1, color: AppColors.border),
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < columns; i++) ...[
                        if (i != 0)
                          VerticalDivider(width: 1, color: AppColors.border),
                        Expanded(
                          child: r * columns + i < cells.length
                              ? cells[r * columns + i]
                              : const SizedBox.shrink(),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _Kpi extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final String sub;
  final String? navId;
  final bool alert;
  final bool warn;

  /// "12 this month" — shown with an up-arrow before [sub]. Only ever passed
  /// when there is a real figure behind it; a decorative trend arrow is a lie.
  final String? delta;

  /// Seven points, oldest first. Drawn small in the corner.
  final List<num>? spark;

  const _Kpi({
    required this.icon,
    required this.label,
    required this.value,
    required this.sub,
    this.navId,
    this.alert = false,
    this.warn = false,
    this.delta,
    this.spark,
  });

  @override
  Widget build(BuildContext context) {
    final nav = DashboardNav.maybeOf(context);
    final canGo = navId != null && (nav?.canReach(navId!) ?? false);
    final tone = alert
        ? AppColors.danger
        : warn
        ? AppColors.warning
        : AppColors.textStrong;

    // The sparkline sits in the bottom-right corner, behind the text — the
    // trend is ambient context, not something to read precisely.
    final hasSpark =
        spark != null &&
        spark!.length > 1 &&
        spark!.any((v) => v > 0) &&
        spark!.toSet().length > 1;

    return InkWell(
      onTap: canGo ? () => nav!.goTo(navId!) : null,
      child: Stack(
        children: [
          if (hasSpark)
            Positioned(
              right: 14,
              bottom: 12,
              child: CustomPaint(
                size: const Size(52, 20),
                painter: _SparkPainter(
                  values: spark!,
                  colour: alert ? AppColors.danger : AppColors.success,
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(17, 15, 17, 15),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(
                      icon,
                      size: 14,
                      color: alert ? AppColors.danger : AppColors.textMuted,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 9),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    value,
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.6,
                      height: 1.1,
                      color: tone,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    if (delta != null) ...[
                      Icon(
                        Icons.arrow_upward_rounded,
                        size: 11,
                        color: AppColors.success,
                      ),
                      Text(
                        delta!,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: AppColors.success,
                        ),
                      ),
                    ] else
                      Flexible(
                        child: Text(
                          sub,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: canGo
                                ? AppColors.primary
                                : AppColors.textMuted,
                            fontWeight: canGo
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A 52×20 trend line. Hand-painted rather than a chart widget — at this size
/// axes, tooltips and touch handling are all overhead for something the eye
/// reads as a single gesture.
class _SparkPainter extends CustomPainter {
  final List<num> values;
  final Color colour;

  const _SparkPainter({required this.values, required this.colour});

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;

    final lo = values.reduce(math.min).toDouble();
    final hi = values.reduce(math.max).toDouble();
    // A flat series would divide by zero; draw it down the middle instead.
    final span = (hi - lo).abs() < 0.0001 ? 1.0 : hi - lo;

    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = size.width * (i / (values.length - 1));
      final y = size.height - ((values[i] - lo) / span) * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = colour.withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_SparkPainter old) =>
      old.colour != colour || !_same(old.values, values);

  static bool _same(List<num> a, List<num> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

// =====================================================================
// Card chrome
// =====================================================================

class _Card extends StatelessWidget {
  final String title;
  final String? subtitle;
  final String? linkLabel;
  final String? linkNavId;
  final Widget child;

  const _Card({
    required this.title,
    this.subtitle,
    this.linkLabel,
    this.linkNavId,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final nav = DashboardNav.maybeOf(context);
    final canGo = linkNavId != null && (nav?.canReach(linkNavId!) ?? false);

    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(17, 14, 12, 13),
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    title,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.15,
                    ),
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(width: 7),
                  Flexible(
                    child: Text(
                      subtitle!,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ),
                ],
                const Spacer(),
                if (canGo)
                  TextButton(
                    onPressed: () => nav!.goTo(linkNavId!),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 30),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                      linkLabel ?? 'View all',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Divider(height: 1, color: AppColors.border),
          Padding(
            padding: const EdgeInsets.fromLTRB(17, 16, 17, 16),
            child: child,
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  final String text;
  const _Empty(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 26),
    child: Center(
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 12.5,
          color: AppColors.textMuted,
          height: 1.5,
        ),
      ),
    ),
  );
}

/// Footer line under a card body — a secondary fact plus an optional action.
class _Foot extends StatelessWidget {
  final Widget left;
  final Widget? right;
  const _Foot({required this.left, this.right});

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(top: 14),
    padding: const EdgeInsets.only(top: 12),
    decoration: BoxDecoration(
      border: Border(top: BorderSide(color: AppColors.border)),
    ),
    child: Row(
      children: [
        Expanded(child: left),
        if (right != null) right!,
      ],
    ),
  );
}

// =====================================================================
// Users by role
// =====================================================================

class _UsersByRole extends StatelessWidget {
  final _Data data;
  const _UsersByRole({required this.data});

  @override
  Widget build(BuildContext context) {
    final nav = DashboardNav.maybeOf(context);
    final byRole = <String, int>{};
    for (final u in data.users) {
      byRole[u.displayRole] = (byRole[u.displayRole] ?? 0) + 1;
    }
    final entries = byRole.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final total = data.users.length;

    // A short categorical ramp. Not the status colours — a role is not good
    // or bad, and reusing red here would make "danger" meaningless.
    final palette = <Color>[
      AppColors.primary,
      const Color(0xFF14B8A6),
      const Color(0xFFF43F5E),
      const Color(0xFFA855F7),
      const Color(0xFFF59E0B),
      const Color(0xFF94A3B8),
    ];

    return _Card(
      title: 'Users by role',
      linkNavId: 'users',
      child: total == 0
          ? const _Empty('No users yet.')
          : Column(
              children: [
                LayoutBuilder(
                  builder: (context, c) {
                    final chart = SizedBox(
                      height: 128,
                      width: 128,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          PieChart(
                            PieChartData(
                              sectionsSpace: 1.5,
                              centerSpaceRadius: 44,
                              startDegreeOffset: -90,
                              sections: [
                                for (var i = 0; i < entries.length; i++)
                                  PieChartSectionData(
                                    value: entries[i].value.toDouble(),
                                    color: palette[i % palette.length],
                                    radius: 18,
                                    showTitle: false,
                                  ),
                              ],
                            ),
                          ),
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '$total',
                                style: const TextStyle(
                                  fontSize: 21,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.5,
                                  height: 1,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                'total users',
                                style: TextStyle(
                                  fontSize: 10.5,
                                  color: AppColors.textMuted,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );

                    final legend = Column(
                      children: [
                        for (var i = 0; i < entries.length; i++)
                          _LegendRow(
                            colour: palette[i % palette.length],
                            name: entries[i].key,
                            value: '${entries[i].value}',
                            percent: total == 0
                                ? ''
                                : '${(entries[i].value / total * 100).toStringAsFixed(entries[i].value / total < 0.1 ? 1 : 0)}%',
                          ),
                      ],
                    );

                    if (c.maxWidth < 330) {
                      return Column(
                        children: [chart, const SizedBox(height: 12), legend],
                      );
                    }
                    return Row(
                      children: [
                        chart,
                        const SizedBox(width: 16),
                        Expanded(child: legend),
                      ],
                    );
                  },
                ),
                if (data.unassigned > 0)
                  _Foot(
                    left: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: '${data.unassigned}',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const TextSpan(text: ' still need a role assigned'),
                        ],
                      ),
                      style: TextStyle(
                        fontSize: 11.5,
                        color: AppColors.textMuted,
                      ),
                    ),
                    right: (nav?.canReach('users') ?? false)
                        ? TextButton(
                            onPressed: () => nav!.goTo('users'),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 6),
                              minimumSize: const Size(0, 28),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: const Text(
                              'Assign',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          )
                        : null,
                  ),
              ],
            ),
    );
  }
}

class _LegendRow extends StatelessWidget {
  final Color colour;
  final String name;
  final String value;
  final String percent;

  const _LegendRow({
    required this.colour,
    required this.name,
    required this.value,
    required this.percent,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Container(
          height: 8,
          width: 8,
          decoration: BoxDecoration(
            color: colour,
            borderRadius: BorderRadius.circular(2.5),
          ),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12.5),
          ),
        ),
        Text(
          value,
          style: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        SizedBox(
          width: 42,
          child: Text(
            percent,
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: 11,
              color: AppColors.textMuted,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    ),
  );
}

// =====================================================================
// Occupancy
// =====================================================================

class _Occupancy extends StatelessWidget {
  final _Data data;
  const _Occupancy({required this.data});

  @override
  Widget build(BuildContext context) {
    final blocks = [...data.hostels]
      ..sort((a, b) => b.occupancy.compareTo(a.occupancy));
    final overall = data.occupancy;

    // Named so the footer can point at the block that is actually dragging
    // the average down, which is the one worth walking over to.
    final worst = blocks.isEmpty ? null : blocks.last;

    return _Card(
      title: 'Hostel occupancy',
      subtitle: blocks.isEmpty ? null : '· ${blocks.length} blocks',
      linkLabel: 'View details',
      linkNavId: 'hostels',
      child: blocks.isEmpty
          ? const _Empty('No hostels created yet.')
          : Column(
              children: [
                for (final h in blocks.take(6))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 13),
                    child: _OccRow(hostel: h),
                  ),
                _Foot(
                  left: Text.rich(
                    TextSpan(
                      children: [
                        const TextSpan(text: 'Overall '),
                        TextSpan(
                          text: '${(overall * 100).round()}%',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const TextSpan(text: ' · '),
                        TextSpan(
                          text: '${data.freeBeds}',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const TextSpan(text: ' beds unfilled'),
                      ],
                    ),
                    style: TextStyle(
                      fontSize: 11.5,
                      color: AppColors.textMuted,
                    ),
                  ),
                  right: worst == null || blocks.length < 2
                      ? null
                      : Text(
                          '${worst.code.isEmpty ? worst.name : worst.code} '
                          'lowest at ${(worst.occupancy * 100).round()}%',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: worst.occupancy < 0.7
                                ? AppColors.warning
                                : AppColors.textMuted,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ],
            ),
    );
  }
}

class _OccRow extends StatelessWidget {
  final Hostel hostel;
  const _OccRow({required this.hostel});

  @override
  Widget build(BuildContext context) {
    final pct = hostel.occupancy;
    final low = pct < 0.7;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              hostel.code.isEmpty ? hostel.name : hostel.code,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${(pct * 100).round()}%',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: low ? AppColors.warning : AppColors.textStrong,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const Spacer(),
            Text(
              '${hostel.occupiedBeds} / ${hostel.bedCount}',
              style: TextStyle(
                fontSize: 11.5,
                color: AppColors.textMuted,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: pct.clamp(0, 1),
            minHeight: 6,
            backgroundColor: AppColors.border,
            valueColor: AlwaysStoppedAnimation(
              low ? AppColors.warning : AppColors.primary,
            ),
          ),
        ),
      ],
    );
  }
}

// =====================================================================
// Recent activity
// =====================================================================

class _Event {
  final DateTime at;
  final IconData icon;
  final Color tone;
  final String title;
  final String detail;

  const _Event({
    required this.at,
    required this.icon,
    required this.tone,
    required this.title,
    required this.detail,
  });
}

/// A merged timeline built from what the modules already record.
///
/// There is no audit log yet, so rather than an empty card this reads the
/// timestamps that fines, requests, notices and fee records already carry.
/// When a real audit log lands it becomes another source here, not a rewrite.
class _RecentActivity extends StatelessWidget {
  final _Data data;
  const _RecentActivity({required this.data});

  @override
  Widget build(BuildContext context) {
    final events = <_Event>[
      for (final r in data.requests.take(12))
        if (r.createdAt != null)
          _Event(
            at: r.createdAt!,
            icon: Icons.assignment_rounded,
            tone: AppColors.primary,
            title: '${r.type.label} request raised',
            detail: [r.raisedByName, if (r.whereFrom != null) r.whereFrom!]
                .join(' · '),
          ),
      for (final f in data.fines.take(12))
        if (f.createdAt != null)
          _Event(
            at: f.createdAt!,
            icon: Icons.gavel_rounded,
            tone: AppColors.danger,
            title: 'Fine imposed',
            detail: '${f.studentName} · ${f.category}',
          ),
      for (final n in data.notices.take(8))
        if (n.createdAt != null)
          _Event(
            at: n.createdAt!,
            icon: Icons.campaign_rounded,
            tone: AppColors.info,
            title: 'Notice posted',
            detail: n.title,
          ),
      for (final f in data.fees.take(12))
        if (f.createdAt != null)
          _Event(
            at: f.createdAt!,
            icon: Icons.check_circle_rounded,
            tone: AppColors.success,
            title: 'Mess fee recorded',
            detail: '${f.studentName} · ${periodLabel(f.period)}',
          ),
    ]..sort((a, b) => b.at.compareTo(a.at));

    return _Card(
      title: 'Recent activity',
      child: events.isEmpty
          ? const _Empty('Nothing has happened yet.')
          : Column(
              children: [
                for (var i = 0; i < math.min(6, events.length); i++)
                  Padding(
                    padding: EdgeInsets.only(
                      bottom: i == math.min(6, events.length) - 1 ? 0 : 12,
                    ),
                    child: _EventRow(event: events[i]),
                  ),
              ],
            ),
    );
  }
}

class _EventRow extends StatelessWidget {
  final _Event event;
  const _EventRow({required this.event});

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        height: 26,
        width: 26,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: event.tone.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Icon(event.icon, size: 13, color: event.tone),
      ),
      const SizedBox(width: 11),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              event.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
            Text(
              event.detail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
            ),
          ],
        ),
      ),
      const SizedBox(width: 8),
      Text(
        _ago(event.at),
        style: TextStyle(fontSize: 11, color: AppColors.textMuted),
      ),
    ],
  );
}

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  if (d.inDays == 1) return 'yesterday';
  if (d.inDays < 7) return '${d.inDays}d ago';
  return shortDay(t);
}

// =====================================================================
// Requests
// =====================================================================

class _RequestsCard extends StatelessWidget {
  final _Data data;
  const _RequestsCard({required this.data});

  @override
  Widget build(BuildContext context) {
    final nav = DashboardNav.maybeOf(context);
    final open = data.openRequests;

    return _Card(
      title: 'Requests',
      linkLabel: 'Open queue',
      linkNavId: 'requests',
      child: data.requests.isEmpty
          ? const _Empty('No requests have been raised.')
          : Column(
              children: [
                for (final t in RequestType.values)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 11),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            t.label,
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (open.where((r) => r.type == t).isNotEmpty)
                          StatusPill(
                            '${open.where((r) => r.type == t).length} pending',
                            AppColors.warning,
                            AppColors.warningSoft,
                          ),
                        const SizedBox(width: 10),
                        SizedBox(
                          width: 28,
                          child: Text(
                            '${data.requests.where((r) => r.type == t).length}',
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (open.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(top: 4),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.warningSoft,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.schedule_rounded,
                          size: 17,
                          color: AppColors.warning,
                        ),
                        const SizedBox(width: 11),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '${open.length}',
                              style: TextStyle(
                                fontSize: 19,
                                fontWeight: FontWeight.w800,
                                height: 1.1,
                                color: AppColors.warning,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                            Text(
                              'awaiting action',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: AppColors.warning,
                              ),
                            ),
                          ],
                        ),
                        const Spacer(),
                        if (nav?.canReach('requests') ?? false)
                          TextButton(
                            onPressed: () => nav!.goTo('requests'),
                            style: TextButton.styleFrom(
                              foregroundColor: AppColors.warning,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              minimumSize: const Size(0, 30),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: const Text(
                              'Review',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

// =====================================================================
// Revenue
// =====================================================================

class _RevenueCard extends StatelessWidget {
  final _Data data;
  const _RevenueCard({required this.data});

  @override
  Widget build(BuildContext context) {
    // Oldest first, so the line reads left to right like a calendar.
    final periods = recentPeriods(DateTime.now(), count: 7).reversed.toList();
    final totals = {
      for (final p in periods)
        p: data.fees
            .where((f) => f.period == p)
            .fold<num>(0, (a, f) => a + f.amount),
    };
    final values = periods.map((p) => totals[p]!).toList();
    final maxV = values.isEmpty
        ? 0
        : values.reduce((a, b) => a > b ? a : b);

    final thisMonth = values.last;
    final lastMonth = values.length > 1 ? values[values.length - 2] : 0;
    final delta = thisMonth - lastMonth;
    final symbol = data.mess.currencySymbol;

    return _Card(
      title: 'Fee collection',
      subtitle: '· last 7 months',
      linkLabel: 'View details',
      linkNavId: 'fees',
      child: maxV == 0
          ? const _Empty(
              'No mess fees recorded yet.\nMark someone paid and the trend '
              'appears here.',
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$symbol${thisMonth.toStringAsFixed(0)}',
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.8,
                    height: 1,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 5),
                Row(
                  children: [
                    Text(
                      periodLabel(periods.last),
                      style: TextStyle(
                        fontSize: 11.5,
                        color: AppColors.textMuted,
                      ),
                    ),
                    if (values.length > 1) ...[
                      Text(
                        ' · ',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: AppColors.textMuted,
                        ),
                      ),
                      Icon(
                        delta >= 0
                            ? Icons.arrow_upward_rounded
                            : Icons.arrow_downward_rounded,
                        size: 12,
                        color: delta >= 0
                            ? AppColors.success
                            : AppColors.danger,
                      ),
                      Text(
                        '$symbol${delta.abs().toStringAsFixed(0)} vs '
                        '${periodLabel(periods[periods.length - 2]).split(' ').first}',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: delta >= 0
                              ? AppColors.success
                              : AppColors.danger,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 16),
                SizedBox(
                  height: 150,
                  child: LineChart(
                    LineChartData(
                      minY: 0,
                      maxY: maxV * 1.25,
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: false,
                        horizontalInterval: maxV * 1.25 / 4,
                        getDrawingHorizontalLine: (_) =>
                            FlLine(color: AppColors.border, strokeWidth: 1),
                      ),
                      borderData: FlBorderData(show: false),
                      lineTouchData: const LineTouchData(enabled: false),
                      titlesData: FlTitlesData(
                        topTitles: const AxisTitles(),
                        rightTitles: const AxisTitles(),
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 42,
                            interval: maxV * 1.25 / 4,
                            getTitlesWidget: (v, meta) => Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: Text(
                                '$symbol${_compact(v)}',
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                  fontSize: 10,
                                  color: AppColors.textMuted,
                                ),
                              ),
                            ),
                          ),
                        ),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 24,
                            interval: 1,
                            getTitlesWidget: (v, meta) {
                              final i = v.toInt();
                              if (i < 0 || i >= periods.length) {
                                return const SizedBox.shrink();
                              }
                              final isLast = i == periods.length - 1;
                              return Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Text(
                                  periodLabel(periods[i]).split(' ').first
                                      .substring(0, 3),
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: isLast
                                        ? FontWeight.w700
                                        : FontWeight.w400,
                                    color: isLast
                                        ? AppColors.textStrong
                                        : AppColors.textMuted,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      lineBarsData: [
                        LineChartBarData(
                          isCurved: false,
                          color: AppColors.primary,
                          barWidth: 2.2,
                          dotData: FlDotData(
                            show: true,
                            getDotPainter: (spot, _, _, i) =>
                                FlDotCirclePainter(
                                  radius: i == periods.length - 1 ? 4.5 : 3,
                                  color: i == periods.length - 1
                                      ? AppColors.primary
                                      : AppColors.card,
                                  strokeColor: AppColors.primary,
                                  strokeWidth: 2,
                                ),
                          ),
                          belowBarData: BarAreaData(
                            show: true,
                            color: AppColors.primary.withValues(alpha: 0.12),
                          ),
                          spots: [
                            for (var i = 0; i < values.length; i++)
                              FlSpot(i.toDouble(), values[i].toDouble()),
                          ],
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

// =====================================================================
// Dues
// =====================================================================

class _DuesCard extends StatelessWidget {
  final _Data data;
  const _DuesCard({required this.data});

  @override
  Widget build(BuildContext context) {
    final symbol = data.mess.currencySymbol;
    final mess = data.messPending;
    final fines = data.outstandingFines;
    final total = mess + fines;

    final owing = data.unpaidResidents;

    return _Card(
      title: 'Outstanding',
      linkLabel: 'View fees',
      linkNavId: 'fees',
      child: total == 0
          ? const _Empty('Nothing outstanding. Everything is settled.')
          : Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _DueStat(
                        label: 'Total outstanding',
                        value: '$symbol${total.toStringAsFixed(0)}',
                        hot: true,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _DueStat(
                        label: 'Residents owing',
                        value: '$owing',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 15),
                ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: SizedBox(
                    height: 9,
                    child: Row(
                      children: [
                        if (mess > 0)
                          Expanded(
                            flex: (mess / total * 1000).round(),
                            child: ColoredBox(color: AppColors.primary),
                          ),
                        if (fines > 0)
                          Expanded(
                            flex: (fines / total * 1000).round(),
                            child: const ColoredBox(color: Color(0xFF14B8A6)),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                _LegendRow(
                  colour: AppColors.primary,
                  name: 'Mess fees',
                  value: '$symbol${mess.toStringAsFixed(0)}',
                  percent: total == 0
                      ? ''
                      : '${(mess / total * 100).round()}%',
                ),
                _LegendRow(
                  colour: const Color(0xFF14B8A6),
                  name: 'Unpaid fines',
                  value: '$symbol${fines.toStringAsFixed(0)}',
                  percent: total == 0
                      ? ''
                      : '${(fines / total * 100).round()}%',
                ),
                _Foot(
                  left: Text(
                    owing == 0
                        ? 'Fines only — mess fees are settled'
                        : 'Avg $symbol${(total / owing).toStringAsFixed(0)} '
                              'per resident owing',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: AppColors.textMuted,
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _DueStat extends StatelessWidget {
  final String label;
  final String value;
  final bool hot;

  const _DueStat({required this.label, required this.value, this.hot = false});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
    decoration: BoxDecoration(
      color: hot ? AppColors.dangerSoft : AppColors.canvas,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(
        color: hot
            ? AppColors.danger.withValues(alpha: 0.25)
            : AppColors.border,
      ),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w500,
            color: hot ? AppColors.danger : AppColors.textMuted,
          ),
        ),
        const SizedBox(height: 3),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
              color: hot ? AppColors.danger : AppColors.textStrong,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    ),
  );
}

// =====================================================================
// Recent payments
// =====================================================================

class _RecentPayments extends StatelessWidget {
  final _Data data;
  const _RecentPayments({required this.data});

  @override
  Widget build(BuildContext context) {
    final recent = [...data.fees]
      ..sort((a, b) {
        final at = a.paidOn ?? a.createdAt;
        final bt = b.paidOn ?? b.createdAt;
        if (at == null && bt == null) return 0;
        if (at == null) return 1;
        if (bt == null) return -1;
        return bt.compareTo(at);
      });
    final shown = recent.take(5).toList();
    final symbol = data.mess.currencySymbol;

    return _Card(
      title: 'Recent fee payments',
      linkLabel: 'View all',
      linkNavId: 'fees',
      child: shown.isEmpty
          ? const _Empty('No payments recorded yet.')
          : Column(
              children: [
                const Padding(
                  padding: EdgeInsets.only(bottom: 9),
                  child: Row(
                    children: [
                      Expanded(flex: 5, child: _Th('Student')),
                      Expanded(flex: 4, child: _Th('Month')),
                      Expanded(flex: 3, child: _Th('Amount', right: true)),
                      Expanded(flex: 3, child: _Th('Recorded', right: true)),
                    ],
                  ),
                ),
                Divider(height: 1, color: AppColors.border),
                for (var i = 0; i < shown.length; i++) ...[
                  if (i != 0) Divider(height: 1, color: AppColors.border),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 5,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                shown[i].studentName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (shown[i].studentRegNo != null)
                                Text(
                                  shown[i].studentRegNo!,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: AppColors.textMuted,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        Expanded(
                          flex: 4,
                          child: Text(
                            periodLabel(shown[i].period),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: AppColors.textMuted,
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 3,
                          child: Text(
                            '$symbol${shown[i].amount.toStringAsFixed(0)}',
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: AppColors.success,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 3,
                          child: Text(
                            shown[i].paidOnLabel ?? '—',
                            textAlign: TextAlign.right,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11.5,
                              color: AppColors.textMuted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}

class _Th extends StatelessWidget {
  final String text;
  final bool right;
  const _Th(this.text, {this.right = false});

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    textAlign: right ? TextAlign.right : TextAlign.left,
    style: TextStyle(
      fontSize: 10.5,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.7,
      color: AppColors.textMuted,
    ),
  );
}

// =====================================================================
// Quick actions
// =====================================================================

class _QuickActions extends StatelessWidget {
  const _QuickActions();

  @override
  Widget build(BuildContext context) {
    final nav = DashboardNav.maybeOf(context);
    final session = Session.of(context);

    // Backup and Generate Report are deliberately absent: neither exists, and
    // a tile that does nothing is worse than one that isn't there.
    final actions =
        <({String id, String label, IconData icon, String? perm})>[
          (
            id: 'users',
            label: 'Add User',
            icon: Icons.person_add_alt_1_rounded,
            perm: Perm.usersCreate,
          ),
          (
            id: 'roles',
            label: 'Manage Roles',
            icon: Icons.shield_rounded,
            perm: Perm.rolesManage,
          ),
          (
            id: 'hostels',
            label: 'Hostel Settings',
            icon: Icons.apartment_rounded,
            perm: Perm.hostelsManage,
          ),
          (
            id: 'allotment',
            label: 'Room Allotment',
            icon: Icons.bed_rounded,
            perm: Perm.allotmentManage,
          ),
          (
            id: 'notices',
            label: 'Add Notice',
            icon: Icons.campaign_rounded,
            perm: Perm.noticesManage,
          ),
          (
            id: 'settings',
            label: 'System Settings',
            icon: Icons.settings_rounded,
            perm: Perm.settingsManage,
          ),
        ].where((a) {
          if (!(nav?.canReach(a.id) ?? false)) return false;
          return a.perm == null || session.can(a.perm!);
        }).toList();

    return _Card(
      title: 'Quick actions',
      child: actions.isEmpty
          ? const _Empty('Nothing available for your role.')
          : LayoutBuilder(
              builder: (context, c) {
                final columns = c.maxWidth > 460 ? 3 : 2;
                return GridView.count(
                  crossAxisCount: columns,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 9,
                  crossAxisSpacing: 9,
                  childAspectRatio: 1.75,
                  children: [
                    for (final a in actions)
                      _ActionTile(
                        label: a.label,
                        icon: a.icon,
                        onTap: () => nav!.goTo(a.id),
                      ),
                  ],
                );
              },
            ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  const _ActionTile({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(9),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Icon(icon, size: 17, color: AppColors.primary),
          Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              height: 1.25,
            ),
          ),
        ],
      ),
    ),
  );
}

// =====================================================================

/// "12.5K", "3.4L", "450" — keeps a rupee figure inside a KPI cell.
String _compact(num v) {
  if (v >= 100000) return '${(v / 100000).toStringAsFixed(2)}L';
  if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}K';
  return v.toStringAsFixed(0);
}
