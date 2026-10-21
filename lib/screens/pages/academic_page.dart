import 'package:flutter/material.dart';

import '../../core/permissions.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../models/app_user.dart';
import '../../models/college_settings.dart';
import '../../models/enrollment.dart';
import '../../services/auth_service.dart';
import '../../services/data_service.dart';
import '../../services/enrollment_service.dart';
import '../../utils/enrollment_helpers.dart';
import '../dashboard_shell.dart' show HistoryBanner;

/// Session rosters, the one-time backfill, and the annual promotion run.
///
/// Deliberately shows the enrollment roster *beside* the live user list
/// rather than replacing it: until those two counts agree, the enrollments
/// collection is not trustworthy enough to point the rest of the app at. The
/// mismatch banner is the whole reason this screen exists.
class AcademicPage extends StatefulWidget {
  const AcademicPage({super.key});

  @override
  State<AcademicPage> createState() => _AcademicPageState();
}

class _AcademicPageState extends State<AcademicPage> {
  bool _busy = false;
  String? _message;
  bool _messageIsError = false;

  Future<void> _runBackfill(
    Session session,
    List<AppUser> students,
    String currentSession,
  ) async {
    final ok = await _confirm(
      title: 'Backfill $currentSession enrollments?',
      body:
          'Creates one enrollment record per student for $currentSession, '
          'using each student\'s batch to work out their year. Existing '
          'records are rewritten with the same values, so running this twice '
          'changes nothing.',
      confirmLabel: 'Backfill ${students.length}',
    );
    if (ok != true) return;

    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final outcome = await EnrollmentService.instance.backfillAll(
        users: students,
        collegeId: session.user.collegeId,
        session: currentSession,
        settings: session.settings,
        actor: session.user,
      );
      if (!mounted) return;
      setState(() {
        _messageIsError = outcome.unresolved.isNotEmpty;
        _message = outcome.unresolved.isEmpty
            ? 'Backfilled ${outcome.created} students for $currentSession.'
            : 'Backfilled ${outcome.created}. '
                  '${outcome.unresolved.length} need a batch fix:\n'
                  '${outcome.unresolved.take(8).join('\n')}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _messageIsError = true;
        _message = AuthService.describeError(e);
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runPromotion(
    Session session,
    List<AppUser> students,
    String fromSession,
    String toSession,

    /// The `fromSession` records already on screen. Handed straight to
    /// [EnrollmentService.promoteAll] so it doesn't re-read one per student —
    /// this page is streaming exactly the list promotion needs.
    List<Enrollment> roster,
  ) async {
    final ok = await _confirm(
      title: 'Promote everyone to $toSession?',
      body:
          'Each student moves up one year from wherever their $fromSession '
          'record says they are. Anyone who would pass the end of their '
          'course is marked graduated instead, and gets no $toSession record '
          '— their room is freed too, if they had one.\n\n'
          'Rooms reset for the new session: everyone currently in a shared '
          'room is vacated and starts $toSession unallotted, ready for fresh '
          'allotment under this year\'s seating rules. A student already in a '
          'Single keeps it unchanged — earned once, kept until graduation.\n\n'
          'Nothing is deleted, and re-running is safe.',
      confirmLabel: 'Promote ${students.length}',
    );
    if (ok != true) return;

    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final results = await EnrollmentService.instance.promoteAll(
        users: students,
        collegeId: session.user.collegeId,
        fromSession: fromSession,
        toSession: toSession,
        settings: session.settings,
        actor: session.user,
        previousRoster: roster,
      );
      if (!mounted) return;

      final promoted = results
          .where((r) => r.outcome == PromotionOutcome.promoted)
          .toList();
      final graduated = results.where(
        (r) => r.outcome == PromotionOutcome.graduated,
      );
      final skipped = results.where(
        (r) => r.outcome == PromotionOutcome.skipped,
      );
      final offTrack = promoted.where((r) => r.offTrack);
      final needsRoom = promoted.where((r) => r.needsRoom).toList();
      final needsSingle = needsRoom
          .where((r) => r.requiredCapacity == 1)
          .length;
      final needsShared = needsRoom
          .where((r) => (r.requiredCapacity ?? 1) > 1)
          .length;
      final roomsKept = promoted.where((r) => r.roomKept).length;

      setState(() {
        _messageIsError = skipped.isNotEmpty;
        _message = [
          '${promoted.length} promoted, ${graduated.length} graduated.',
          if (needsRoom.isNotEmpty)
            '${needsRoom.length} need a room for $toSession '
                '($needsSingle Single, $needsShared shared) — allot them '
                'from Room Allotment.'
                '${roomsKept > 0 ? ' $roomsKept kept their existing Single.' : ''}',
          if (offTrack.isNotEmpty)
            'Worth a look — ${offTrack.length} are not where their batch '
                'suggests (repeaters usually): '
                '${offTrack.take(6).map((r) => r.user.name).join(', ')}',
          if (skipped.isNotEmpty)
            '${skipped.length} skipped: '
                '${skipped.take(6).map((r) => '${r.user.name} (${r.note})').join('; ')}',
        ].join('\n\n');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _messageIsError = true;
        _message = AuthService.describeError(e);
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool?> _confirm({
    required String title,
    required String body,
    required String confirmLabel,
  }) => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 460,
        child: Text(body, style: const TextStyle(height: 1.45)),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final session = Session.of(context);
    final collegeId = session.user.collegeId;

    if (!session.canAny([Perm.academicView, Perm.academicManage])) {
      return AppCard(
        padding: const EdgeInsets.symmetric(vertical: 54),
        child: Center(
          child: Text(
            'You don\'t have permission to view academic records.',
            style: TextStyle(color: AppColors.textMuted),
          ),
        ),
      );
    }

    final liveSession = session.settings.session.current;
    if (liveSession == null) {
      return AppCard(
        padding: const EdgeInsets.symmetric(vertical: 46),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.event_busy_rounded,
                size: 40,
                color: AppColors.textMuted,
              ),
              const SizedBox(height: 14),
              const Text(
                'No academic session set',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                'Set the current session under System Settings — everything '
                'on this page is scoped to it.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textMuted, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    // The year picker in the top bar, same lens the Dashboard and Hostels &
    // Rooms already follow. Backfill and Promotion stay pinned to the live
    // session regardless — see the long comment on [Session.viewingSession].
    final viewedSession = session.effectiveSession!;
    final isHistory = session.isViewingHistory;

    final nextSession =
        session.settings.session.next ?? nextSessionAfter(liveSession);

    return StreamBuilder<List<AppUser>>(
      stream: DataService.instance.watchUsers(collegeId),
      builder: (context, userSnap) {
        final students = (userSnap.data ?? const <AppUser>[])
            .where((u) => !u.isSuperAdmin && !u.isGraduated)
            .where((u) => (u.batch ?? '').isNotEmpty)
            .toList();

        return StreamBuilder<List<Enrollment>>(
          stream: EnrollmentService.instance.watchRoster(
            collegeId,
            viewedSession,
          ),
          builder: (context, rosterSnap) {
            if (rosterSnap.hasError) {
              return AppCard(
                child: Text(AuthService.describeError(rosterSnap.error!)),
              );
            }
            final roster = rosterSnap.data ?? const <Enrollment>[];

            return SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const HistoryBanner(),
                  if (isHistory)
                    _HistoryHeader(
                      session: viewedSession,
                      rosterCount: roster.length,
                    )
                  else
                    _Header(
                      currentSession: liveSession,
                      nextSession: nextSession,
                      studentCount: students.length,
                      rosterCount: roster.length,
                      missingCount: countMissing(
                        students.map((u) => u.uid),
                        roster.map((e) => e.uid),
                      ),
                      busy: _busy,
                      canManage: session.can(Perm.academicManage),
                      onBackfill: () =>
                          _runBackfill(session, students, liveSession),
                      onPromote: nextSession == null
                          ? null
                          : () => _runPromotion(
                              session,
                              students,
                              liveSession,
                              nextSession,
                              roster,
                            ),
                    ),
                  if (!isHistory && _message != null) ...[
                    const SizedBox(height: 14),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: _messageIsError
                            ? AppColors.warningSoft
                            : AppColors.successSoft,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        _message!,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.5,
                          color: _messageIsError
                              ? AppColors.warning
                              : AppColors.success,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  _YearBreakdown(roster: roster, session: viewedSession),
                  if (roster.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    _CourseBreakdowns(
                      roster: roster,
                      settings: session.settings,
                    ),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  final String currentSession;
  final String? nextSession;
  final int studentCount;
  final int rosterCount;

  /// How many current students have no record for this session.
  ///
  /// Counted per student rather than inferred from the two tallies. Comparing
  /// the totals looked equivalent and was not: the moment anyone graduates the
  /// counts diverge for a perfectly correct reason — graduates leave the live
  /// roster but stay in the session they really were enrolled in — and the
  /// page cried "roster incomplete" at exactly the moment promotion had just
  /// succeeded. Asking who is actually missing cannot make that mistake.
  final int missingCount;

  final bool busy;
  final bool canManage;
  final VoidCallback onBackfill;
  final VoidCallback? onPromote;

  const _Header({
    required this.currentSession,
    required this.nextSession,
    required this.studentCount,
    required this.rosterCount,
    required this.missingCount,
    required this.busy,
    required this.canManage,
    required this.onBackfill,
    required this.onPromote,
  });

  @override
  Widget build(BuildContext context) {
    final matches = missingCount == 0;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            'Academic records',
            trailing: StatusPill(
              currentSession,
              AppColors.primary,
              AppColors.primarySoft,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'A student\'s year belongs to a session, not to the student — so '
            'each year adds a record instead of overwriting last year\'s.',
            style: TextStyle(fontSize: 13, color: AppColors.textMuted),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              _Tally('Students with a batch', studentCount, AppColors.primary),
              const SizedBox(width: 28),
              _Tally(
                'Enrolled in $currentSession',
                rosterCount,
                matches ? AppColors.success : AppColors.warning,
              ),
            ],
          ),
          if (!matches) ...[
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                color: AppColors.warningSoft,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                rosterCount == 0
                    ? 'No enrollment records for $currentSession yet. Run the '
                          'backfill to create one per student from their batch.'
                    : '$missingCount current student(s) have no $currentSession '
                          'record — usually a batch that doesn\'t parse against '
                          'the session. Re-run the backfill to pick them up; '
                          'until then treat the roster as incomplete and keep '
                          'reading year off the student profile.',
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.45,
                  color: AppColors.warning,
                ),
              ),
            ),
          ],
          if (canManage) ...[
            const SizedBox(height: 18),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: busy || studentCount == 0 ? null : onBackfill,
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: Text('Backfill $currentSession'),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: busy || rosterCount == 0 ? null : onPromote,
                  icon: const Icon(Icons.arrow_upward_rounded, size: 18),
                  label: Text(
                    nextSession == null
                        ? 'Promote (no next session)'
                        : 'Promote to $nextSession',
                  ),
                ),
                if (busy) ...[
                  const SizedBox(width: 16),
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
              ],
            ),
            // Promote reads "current session" (top of this card) as the
            // session to promote FROM, and computes the target as one year
            // ahead — so it has to be clicked BEFORE System Settings is
            // switched to the new session, not after. Switching first is the
            // natural thing to try and leaves this button disabled with no
            // roster to promote from, which explains nothing on its own —
            // hence spelling it out here rather than leaving it a silent dead
            // end.
            if (!busy && rosterCount == 0 && studentCount > 0) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.warningSoft,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  'Promote is disabled because there\'s no $currentSession '
                  'roster to promote from yet. If you already switched '
                  'System Settings to $currentSession before promoting — '
                  'switch it back to the previous session, click "Promote '
                  'to $currentSession" there, and only change System '
                  'Settings to $currentSession afterwards.',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.45,
                    color: AppColors.warning,
                  ),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// Stands in for [_Header] while viewing a past session. No tallies, no
/// mismatch warning, no Backfill/Promote — those are live-session concepts
/// (they ask "does this year's roster match who's here today"), which has no
/// honest answer for a year that isn't the live one.
class _HistoryHeader extends StatelessWidget {
  final String session;
  final int rosterCount;

  const _HistoryHeader({required this.session, required this.rosterCount});

  @override
  Widget build(BuildContext context) => AppCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          'Academic records',
          trailing: StatusPill(
            session,
            AppColors.warning,
            AppColors.warningSoft,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'A read-only look at $session\'s enrollment roster — '
          '$rosterCount record${rosterCount == 1 ? '' : 's'}. Switch back to '
          'the live session from the year picker to backfill or promote.',
          style: TextStyle(fontSize: 13, color: AppColors.textMuted),
        ),
      ],
    ),
  );
}

class _YearBreakdown extends StatelessWidget {
  final List<Enrollment> roster;
  final String session;

  const _YearBreakdown({required this.roster, required this.session});

  @override
  Widget build(BuildContext context) {
    if (roster.isEmpty) {
      return AppCard(
        padding: const EdgeInsets.symmetric(vertical: 46),
        child: Center(
          child: Text(
            'Nothing enrolled in $session yet.',
            style: TextStyle(color: AppColors.textMuted),
          ),
        ),
      );
    }

    final byYear = <int, List<Enrollment>>{};
    for (final e in roster) {
      byYear.putIfAbsent(e.year, () => []).add(e);
    }
    final years = byYear.keys.toList()..sort();

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader('$session roster'),
          const SizedBox(height: 16),
          for (final year in years)
            _YearBar(
              year: year,
              count: byYear[year]!.length,
              total: roster.length,
            ),
        ],
      ),
    );
  }
}

/// One panel per course (ICD, UG, PG …) under the combined roster, each
/// counting its own students by year.
///
/// The course list comes from Settings, not from a hardcoded set, so a college
/// that adds or renames a course gets a panel for it without a code change.
/// Every year the course runs is listed even when nobody is in it — an empty
/// 3rd year is something to notice, not something to hide. A course present
/// in the roster but missing from Settings still gets a panel, after the
/// configured ones, so no student silently drops out of the counts.
class _CourseBreakdowns extends StatelessWidget {
  final List<Enrollment> roster;
  final CollegeSettings settings;

  const _CourseBreakdowns({required this.roster, required this.settings});

  static const _noCourse = 'No course';

  @override
  Widget build(BuildContext context) {
    final byCourse = <String, List<Enrollment>>{};
    for (final e in roster) {
      final course = settings.courseNameFor(e.course) ?? _noCourse;
      byCourse.putIfAbsent(course, () => []).add(e);
    }

    final configured = settings.courseNames;
    final courses = [
      ...configured,
      for (final c in byCourse.keys)
        if (!configured.contains(c)) c,
    ];

    final panels = [
      for (final course in courses)
        _CoursePanel(
          course: course,
          enrollments: byCourse[course] ?? const [],
          totalYears: course == _noCourse
              ? null
              : settings.totalYearsFor(course),
        ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 760) {
          return Column(
            children: [
              for (var i = 0; i < panels.length; i++) ...[
                if (i > 0) const SizedBox(height: 14),
                panels[i],
              ],
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < panels.length; i++) ...[
              if (i > 0) const SizedBox(width: 14),
              Expanded(child: panels[i]),
            ],
          ],
        );
      },
    );
  }
}

class _CoursePanel extends StatelessWidget {
  final String course;
  final List<Enrollment> enrollments;

  /// How many years the course runs, or null for students with no course.
  final int? totalYears;

  const _CoursePanel({
    required this.course,
    required this.enrollments,
    required this.totalYears,
  });

  @override
  Widget build(BuildContext context) {
    final byYear = <int, int>{};
    for (final e in enrollments) {
      byYear[e.year] = (byYear[e.year] ?? 0) + 1;
    }
    // The course's own years always, plus any stray year a record carries
    // beyond them, so a bad record is visible rather than uncounted.
    final years = {
      if (totalYears != null)
        for (var y = 1; y <= totalYears!; y++) y,
      ...byYear.keys,
    }.toList()..sort();

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: SectionHeader(courseLabel(course))),
              Text(
                '${enrollments.length}',
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          if (totalYears != null)
            Text(
              '$totalYears-year course',
              style: TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
          const SizedBox(height: 16),
          for (final year in years)
            _YearBar(
              year: year,
              count: byYear[year] ?? 0,
              total: enrollments.length,
            ),
        ],
      ),
    );
  }
}

/// "2nd year ▬▬▬▬░░░ 977" — shared by the combined roster and the per-course
/// panels so the two always read the same way.
class _YearBar extends StatelessWidget {
  final int year;
  final int count;
  final int total;

  const _YearBar({
    required this.year,
    required this.count,
    required this.total,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      children: [
        SizedBox(
          width: 70,
          child: Text(
            '${ordinal(year)} year',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: LinearProgressIndicator(
              value: total == 0 ? 0 : count / total,
              minHeight: 8,
              backgroundColor: AppColors.border,
            ),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 40,
          child: Text(
            '$count',
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
        ),
      ],
    ),
  );
}

class _Tally extends StatelessWidget {
  final String label;
  final int value;
  final Color color;
  const _Tally(this.label, this.value, this.color);

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: AppColors.textMuted,
        ),
      ),
      Text(
        '$value',
        style: TextStyle(
          fontSize: 26,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    ],
  );
}
