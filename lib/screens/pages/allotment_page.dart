import 'package:flutter/material.dart';

import '../../core/permissions.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../models/app_user.dart';
import '../../models/college_settings.dart';
import '../../models/enrollment.dart';
import '../../models/hostel.dart';
import '../../services/allotment_service.dart';
import '../../services/auth_service.dart';
import '../../services/data_service.dart';
import '../../services/enrollment_service.dart';
import '../../services/hostel_service.dart';
import '../../utils/enrollment_helpers.dart';
import 'allot_room_view.dart';
import 'auto_allot_dialog.dart';
import 'user_detail_view.dart';

/// Room Allotment: who has a bed, who doesn't, and the actions to fix that.
class AllotmentPage extends StatefulWidget {
  const AllotmentPage({super.key});

  @override
  State<AllotmentPage> createState() => _AllotmentPageState();
}

class _AllotmentPageState extends State<AllotmentPage> {
  String _query = '';
  final _searchCtl = TextEditingController();
  _Filter _filter = _Filter.pending;

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  /// Course as Settings spells it ("UG"), or null for every course.
  String? _course;

  /// Academic year (1, 2, …), or null for every year.
  int? _year;

  /// LEET or Regular — a sub-filter of Graduation, null for everyone.
  String? _entry;

  /// Branches (trade codes, e.g. "GCS"), any number at once; empty means
  /// every branch. A student matches if they're in any of them.
  final Set<String> _trades = {};

  /// A student's year in the live session.
  ///
  /// The enrollment is authoritative — it is the record promotion maintains.
  /// `AppUser.year` is free text copied from the import sheet and never
  /// updated, so it is only a fallback for students not yet backfilled;
  /// otherwise a student imported as "1" would sit under 1st year forever.
  /// Same rule as Student Overview.
  static int? _yearOf(AppUser u, Map<String, Enrollment> byUid) =>
      byUid[u.uid]?.year ?? int.tryParse(u.year?.trim() ?? '');

  /// Same reasoning as the Users page: with a large roster, rendering every
  /// match at once is what makes this screen crawl. Reset to 0 whenever the
  /// search or filter changes.
  static const _pageSize = 50;
  int _page = 0;

  /// Set when a person is opened from the worklist. Held as state rather than
  /// pushed as a route so the dashboard sidebar stays visible.
  AppUser? _openUser;

  /// Set while the room picker is showing in place of the worklist.
  AppUser? _allotUser;
  bool _allotIsMove = false;

  @override
  Widget build(BuildContext context) {
    final session = Session.of(context);
    final collegeId = session.user.collegeId;
    final canAllot = session.can(Perm.allotmentManage);

    if (_allotUser != null) {
      return AllotRoomView(
        student: _allotUser!,
        isMove: _allotIsMove,
        onBack: _closeAllot,
        onDone: _closeAllot,
      );
    }

    if (_openUser != null) {
      return UserDetailView(
        uid: _openUser!.uid,
        initial: _openUser!,
        onBack: () => setState(() => _openUser = null),
      );
    }

    return StreamBuilder<List<Hostel>>(
      stream: HostelService.instance.watchHostels(collegeId),
      builder: (context, hostelSnap) {
        final hostels = hostelSnap.data ?? const <Hostel>[];

        // Allotting is a write path, so years come from the live session —
        // never the session someone is browsing in the top bar. The roster
        // stream is pooled with Academic Records, so this costs no extra
        // query when that page has been opened.
        final liveSession = session.settings.session.current;
        return StreamBuilder<List<Enrollment>>(
          stream: liveSession == null
              ? const Stream<List<Enrollment>>.empty()
              : EnrollmentService.instance.watchRoster(collegeId, liveSession),
          builder: (context, enrollSnap) {
            final byUid = {
              for (final e in enrollSnap.data ?? const <Enrollment>[]) e.uid: e,
            };

            return StreamBuilder<List<AppUser>>(
              stream: DataService.instance.watchUsers(collegeId),
              builder: (context, userSnap) {
                if (userSnap.hasError) {
                  return AppCard(
                    child: Text(AuthService.describeError(userSnap.error!)),
                  );
                }
                if (!userSnap.hasData) {
                  return const Padding(
                    padding: EdgeInsets.all(60),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }

                // The Super Admin is staff, not a resident — exclude from the
                // allotment worklist so it isn't cluttered.
                //
                // Graduates go too, and for a sharper reason: promotion vacates
                // their room, so `isAllotted` turns false and they would fall
                // straight into the "pending" queue as students awaiting a bed.
                // After a few years of promotions that queue is mostly people who
                // left, which is worse than useless — it hides the ones who are
                // actually waiting.
                final people = userSnap.data!
                    .where((u) => !u.isSuperAdmin && !u.isGraduated)
                    .toList();
                final allotted = people.where((u) => u.isAllotted).toList();
                final pending = people.where((u) => !u.isAllotted).toList();

                final totalBeds = hostels.fold<int>(
                  0,
                  (s, h) => s + h.bedCount,
                );
                final freeBeds = hostels.fold<int>(0, (s, h) => s + h.freeBeds);

                final source = switch (_filter) {
                  _Filter.pending => pending,
                  _Filter.allotted => allotted,
                  _Filter.all => people,
                };
                final q = _query.trim().toLowerCase();
                bool matchesQuery(AppUser u) =>
                    q.isEmpty ||
                    u.name.toLowerCase().contains(q) ||
                    u.email.toLowerCase().contains(q) ||
                    (u.enrollmentNo ?? '').toLowerCase().contains(q) ||
                    (u.roomNumber ?? '').toLowerCase().contains(q);

                final settings = session.settings;
                String? courseOf(AppUser u) => settings.courseNameFor(u.course);
                int? yearOf(AppUser u) => _yearOf(u, byUid);
                bool courseOk(AppUser u) =>
                    _course == null || courseOf(u) == _course;
                bool yearOk(AppUser u) => _year == null || yearOf(u) == _year;
                bool entryOk(AppUser u) =>
                    _entry == null || entryTypeOf(u) == _entry;
                bool tradeOk(AppUser u) =>
                    _trades.isEmpty || _trades.contains(u.trade);

                final searched = source.where(matchesQuery).toList();
                final shown = searched
                    .where(
                      (u) =>
                          courseOk(u) && yearOk(u) && entryOk(u) && tradeOk(u),
                    )
                    .toList();

                // Branch: counted under every other filter, so "GCS (27)"
                // is what picking it would show. Every configured branch is
                // offered (plus any a sheet invented), the ones with anybody
                // in them first — 35 branches with "(0)" on most would bury
                // the few that matter under a course and year.
                final tradeCounts = <String, int>{};
                for (final u in searched.where(
                  (u) => courseOk(u) && yearOk(u) && entryOk(u),
                )) {
                  final t = u.trade;
                  if (t != null && t.isNotEmpty) {
                    tradeCounts[t] = (tradeCounts[t] ?? 0) + 1;
                  }
                }
                final allTrades = {
                  ...settings.tradeCodes,
                  for (final u in people)
                    if (u.trade != null && u.trade!.isNotEmpty) u.trade!,
                  ..._trades,
                }.toList()..sort();
                final tradeOptions = [
                  ...allTrades.where((t) => (tradeCounts[t] ?? 0) > 0),
                  ...allTrades.where((t) => (tradeCounts[t] ?? 0) == 0),
                ];

                // LEET / Regular, counted under the course and year picked.
                final showEntry = hasLateralEntry(_course);
                final entryCounts = <String, int>{};
                if (showEntry) {
                  for (final u in searched.where(
                    (u) => courseOk(u) && yearOk(u) && tradeOk(u),
                  )) {
                    final t = entryTypeOf(u);
                    if (t != null) entryCounts[t] = (entryCounts[t] ?? 0) + 1;
                  }
                }

                // Each chip counts what you'd get by tapping it, given the other
                // filter — so "2nd year (40)" means 40 under the course picked.
                final configuredCourses = settings.courseNames;
                final courseOptions = [
                  ...configuredCourses,
                  ...({
                    for (final u in people)
                      if (courseOf(u) != null &&
                          !configuredCourses.contains(courseOf(u)))
                        courseOf(u)!,
                  }.toList()..sort()),
                ];
                final courseCounts = <String, int>{};
                for (final u in searched.where(
                  (u) => yearOk(u) && entryOk(u) && tradeOk(u),
                )) {
                  final c = courseOf(u);
                  if (c != null) courseCounts[c] = (courseCounts[c] ?? 0) + 1;
                }

                // The years the picked course runs (or the longest course, with
                // none picked), plus any stray year a record actually carries.
                final maxYears = _course != null
                    ? settings.totalYearsFor(_course)
                    : configuredCourses.fold<int>(
                        0,
                        (m, c) => settings.totalYearsFor(c) > m
                            ? settings.totalYearsFor(c)
                            : m,
                      );
                final yearCounts = <int, int>{};
                for (final u in searched.where(
                  (u) => courseOk(u) && entryOk(u) && tradeOk(u),
                )) {
                  final y = yearOf(u);
                  if (y != null) yearCounts[y] = (yearCounts[y] ?? 0) + 1;
                }
                final yearOptions = {
                  for (var y = 1; y <= maxYears; y++) y,
                  ...yearCounts.keys,
                }.toList()..sort();

                // Auto-allot works on exactly the group the Pending tab shows
                // under these filters — whichever status tab is open — and
                // only once a course or year narrows it, so one click can't
                // sweep the whole institute into a single hostel.
                final autoCandidates = pending
                    .where(
                      (u) =>
                          matchesQuery(u) &&
                          courseOk(u) &&
                          yearOk(u) &&
                          entryOk(u) &&
                          tradeOk(u),
                    )
                    .toList();
                // The roster carries each student's seating-policy room type
                // and live year. Planning before it arrives — or after it was
                // refused — would quietly drop the policy and put a PG student
                // in a 3-Seater, so the button waits and says why.
                final rosterError = enrollSnap.hasError
                    ? AuthService.describeError(enrollSnap.error!)
                    : null;
                final rosterReady =
                    liveSession == null ||
                    (enrollSnap.hasData && rosterError == null);
                final autoReady =
                    (_course != null ||
                        _year != null ||
                        _entry != null ||
                        _trades.isNotEmpty) &&
                    autoCandidates.isNotEmpty &&
                    rosterReady;
                final scopeLabel = [
                  if (_course != null) courseLabel(_course!),
                  if (_year != null) '${ordinal(_year!)} year',
                  if (_entry != null) _entry!,
                  if (_trades.isNotEmpty) (_trades.toList()..sort()).join(', '),
                  if (q.isNotEmpty) 'matching "$q"',
                ].join(' · ');

                final pageCount = shown.isEmpty
                    ? 1
                    : (shown.length / _pageSize).ceil();
                final page = _page.clamp(0, pageCount - 1);
                final pageStart = page * _pageSize;
                final pageItems = shown
                    .skip(pageStart)
                    .take(_pageSize)
                    .toList();

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SectionHeader('Room allotment'),
                          const SizedBox(height: 16),
                          Wrap(
                            spacing: 30,
                            runSpacing: 14,
                            children: [
                              _Metric(
                                'Awaiting a room',
                                '${pending.length}',
                                pending.isEmpty
                                    ? AppColors.success
                                    : AppColors.warning,
                              ),
                              _Metric(
                                'Allotted',
                                '${allotted.length}',
                                AppColors.primary,
                              ),
                              _Metric(
                                'Free beds',
                                '$freeBeds',
                                freeBeds == 0
                                    ? AppColors.danger
                                    : AppColors.success,
                              ),
                              _Metric(
                                'Total beds',
                                '$totalBeds',
                                AppColors.textStrong,
                              ),
                            ],
                          ),
                          if (hostels.isEmpty) ...[
                            const SizedBox(height: 16),
                            Text(
                              'No hostels exist yet — create one under '
                              '"Hostels & Rooms" before allotting.',
                              style: TextStyle(
                                color: AppColors.warning,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ] else if (pending.isNotEmpty && freeBeds == 0) ...[
                            const SizedBox(height: 16),
                            Text(
                              'Every bed is taken but people are still waiting. '
                              'Add rooms or a floor to make space.',
                              style: TextStyle(
                                color: AppColors.danger,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                          const SizedBox(height: 18),
                          // Side by side when there's room; stacked on a
                          // phone, where "Pending (530)" alone makes the
                          // segmented button wider than the card and squeezed
                          // the search box to nothing.
                          LayoutBuilder(
                            builder: (context, box) {
                              final search = TextField(
                                // Owned by the page, so the typed text
                                // survives the switch between the two
                                // layouts below, which remounts the field.
                                controller: _searchCtl,
                                onChanged: (v) => setState(() {
                                  _query = v;
                                  _page = 0;
                                }),
                                decoration: const InputDecoration(
                                  hintText:
                                      'Search name, email, enrollment or room',
                                  prefixIcon: Icon(Icons.search_rounded),
                                  isDense: true,
                                ),
                              );
                              final narrow = box.maxWidth < 600;
                              final status = SegmentedButton<_Filter>(
                                expandedInsets: narrow ? EdgeInsets.zero : null,
                                segments: [
                                  ButtonSegment(
                                    value: _Filter.pending,
                                    label: Text('Pending (${pending.length})'),
                                  ),
                                  ButtonSegment(
                                    value: _Filter.allotted,
                                    label: Text(
                                      'Allotted (${allotted.length})',
                                    ),
                                  ),
                                  const ButtonSegment(
                                    value: _Filter.all,
                                    label: Text('All'),
                                  ),
                                ],
                                selected: {_filter},
                                showSelectedIcon: false,
                                onSelectionChanged: (s) => setState(() {
                                  _filter = s.first;
                                  _page = 0;
                                }),
                              );
                              if (narrow) {
                                return Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    search,
                                    const SizedBox(height: 10),
                                    status,
                                  ],
                                );
                              }
                              return Row(
                                children: [
                                  Expanded(child: search),
                                  const SizedBox(width: 14),
                                  status,
                                ],
                              );
                            },
                          ),
                          const SizedBox(height: 14),
                          _ChipFilter<String>(
                            label: 'Course',
                            options: courseOptions,
                            selected: _course,
                            labelFor: (c) =>
                                '${courseLabel(c)} '
                                '(${courseCounts[c] ?? 0})',
                            onChanged: (c) => setState(() {
                              _course = c;
                              // LEET only exists within Graduation.
                              if (!hasLateralEntry(c)) _entry = null;
                              // A 4th-year pick means nothing once PG is chosen.
                              if (c != null &&
                                  _year != null &&
                                  _year! > settings.totalYearsFor(c)) {
                                _year = null;
                              }
                              _page = 0;
                            }),
                          ),
                          const SizedBox(height: 10),
                          _ChipFilter<int>(
                            label: 'Year',
                            options: yearOptions,
                            selected: _year,
                            labelFor: (y) =>
                                '${ordinal(y)} year (${yearCounts[y] ?? 0})',
                            onChanged: (y) => setState(() {
                              _year = y;
                              _page = 0;
                            }),
                          ),
                          // A sub-filter of Graduation: shown once it's picked.
                          if (showEntry) ...[
                            const SizedBox(height: 10),
                            _ChipFilter<String>(
                              label: 'Entry',
                              options: const [kEntryRegular, kEntryLeet],
                              selected: _entry,
                              labelFor: (e) => '$e (${entryCounts[e] ?? 0})',
                              onChanged: (e) => setState(() {
                                _entry = e;
                                _page = 0;
                              }),
                            ),
                          ],
                          const SizedBox(height: 10),
                          _BranchFilter(
                            options: tradeOptions,
                            selected: _trades,
                            labelFor: (t) =>
                                '${settings.tradeLabelFor(t)} '
                                '(${tradeCounts[t] ?? 0})',
                            onToggle: (t) => setState(() {
                              if (!_trades.remove(t)) _trades.add(t);
                              _page = 0;
                            }),
                            onClear: () => setState(() {
                              _trades.clear();
                              _page = 0;
                            }),
                          ),
                          if (canAllot && hostels.isNotEmpty) ...[
                            const SizedBox(height: 14),
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    rosterError != null
                                        ? 'Can\'t auto-allot: academic '
                                              'records didn\'t load '
                                              '($rosterError).'
                                        : !rosterReady
                                        ? 'Loading academic records…'
                                        : autoReady
                                        ? '${autoCandidates.length} waiting in '
                                              '$scopeLabel — fill a hostel\'s '
                                              'rooms in order, in one click.'
                                        : _course == null && _year == null
                                        ? 'Pick a course and/or year to '
                                              'auto-allot that whole group '
                                              'into a hostel, room by room.'
                                        : 'Nobody in $scopeLabel is waiting '
                                              'for a room.',
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      color: AppColors.textMuted,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                FilledButton.icon(
                                  onPressed: autoReady
                                      ? () => _openAutoAllot(
                                          settings,
                                          session.user,
                                          hostels,
                                          autoCandidates,
                                          byUid,
                                          scopeLabel,
                                        )
                                      : null,
                                  icon: const Icon(
                                    Icons.bolt_rounded,
                                    size: 18,
                                  ),
                                  label: Text(
                                    autoReady
                                        ? 'Auto-allot '
                                              '(${autoCandidates.length})'
                                        : 'Auto-allot',
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    if (shown.isEmpty)
                      AppCard(
                        padding: const EdgeInsets.symmetric(vertical: 54),
                        child: Center(
                          child: Text(
                            _course != null ||
                                    _year != null ||
                                    _entry != null ||
                                    _trades.isNotEmpty
                                ? 'Nobody matches these filters.'
                                : _filter == _Filter.pending
                                ? 'Everyone has a room. Nice.'
                                : 'Nobody matches that search.',
                            style: TextStyle(color: AppColors.textMuted),
                          ),
                        ),
                      )
                    else ...[
                      AppCard(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Column(
                          children: [
                            for (var i = 0; i < pageItems.length; i++) ...[
                              _PersonRow(
                                person: pageItems[i],
                                canAllot: canAllot,
                                showMerit: _meritApplies(
                                  settings,
                                  pageItems[i],
                                  yearOf(pageItems[i]),
                                ),
                                onMerit: (v) =>
                                    _setMerit(session.user, pageItems[i], v),
                                onOpen: () => _openDetail(pageItems[i]),
                                onAllot: () =>
                                    _openAllot(pageItems[i], move: false),
                                onMove: () =>
                                    _openAllot(pageItems[i], move: true),
                                onVacate: () => _vacate(pageItems[i]),
                              ),
                              if (i != pageItems.length - 1)
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
                      if (pageCount > 1) ...[
                        const SizedBox(height: 14),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            OutlinedButton(
                              onPressed: page > 0
                                  ? () => setState(() => _page = page - 1)
                                  : null,
                              child: const Text('Previous'),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              child: Text(
                                'Page ${page + 1} of $pageCount  '
                                '(${pageStart + 1}–'
                                '${pageStart + pageItems.length} of '
                                '${shown.length})',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.textMuted,
                                ),
                              ),
                            ),
                            OutlinedButton(
                              onPressed: page < pageCount - 1
                                  ? () => setState(() => _page = page + 1)
                                  : null,
                              child: const Text('Next'),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  void _openDetail(AppUser u) => setState(() => _openUser = u);

  /// Whether merit decides this student's room type this year — the years
  /// of a "merit single" course between the always-shared start and the
  /// all-singles final year. For UG that is exactly 3rd year. Read off the
  /// course rule rather than hard-coded, so it follows Settings.
  static bool _meritApplies(CollegeSettings settings, AppUser u, int? year) {
    final rule = settings.courseRuleFor(u.course);
    if (rule == null || rule.seating != CourseSeating.meritSingle) {
      return false;
    }
    return year != null && year > 2 && year < rule.totalYears;
  }

  Future<void> _setMerit(AppUser actor, AppUser student, bool merit) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await AllotmentService.instance.setMerit(
        collegeId: student.collegeId,
        student: student,
        merit: merit,
        actor: actor,
      );
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            merit
                ? '${student.name} marked merit — entitled to a Single.'
                : '${student.name} marked non-merit — entitled to a shared '
                      'room.',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(AuthService.describeError(e))),
      );
    }
  }

  /// Everything the dialog needs is handed over here: it opens above
  /// SessionScope, where `Session.of` throws.
  Future<void> _openAutoAllot(
    CollegeSettings settings,
    AppUser actor,
    List<Hostel> hostels,
    List<AppUser> students,
    Map<String, Enrollment> byUid,
    String scopeLabel,
  ) async {
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AutoAllotDialog(
        collegeId: actor.collegeId,
        actor: actor,
        hostels: hostels,
        students: students,
        // Live from Settings + year + merit — the same answer the single
        // picker and Hostels & Rooms get — not the copy frozen on the
        // enrollment when backfill wrote it.
        requiredCapacityByUid: {
          for (final u in students)
            u.uid: entitledRoomCapacity(
              settings: settings,
              course: u.course,
              year: _yearOf(u, byUid),
              singleRoomEligible: u.singleRoomEligible,
            ),
        },
        scopeLabel: scopeLabel,
      ),
    );
  }

  void _openAllot(AppUser u, {required bool move}) => setState(() {
    _allotUser = u;
    _allotIsMove = move;
  });

  void _closeAllot() => setState(() {
    _allotUser = null;
    _allotIsMove = false;
  });

  Future<void> _vacate(AppUser u) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Vacate ${u.roomLabel}?'),
        content: Text('${u.name} will be removed and the bed freed up.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Vacate'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      await AllotmentService.instance.vacate(
        collegeId: u.collegeId,
        student: u,
      );
      messenger.showSnackBar(const SnackBar(content: Text('Room vacated')));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            e is AllotmentFailure ? e.message : AuthService.describeError(e),
          ),
        ),
      );
    }
  }
}

enum _Filter { pending, allotted, all }

/// "Branch  [GCS, GME +1 ▾]  ✕" — tick any number of branches.
///
/// A menu of checkboxes rather than chips: a college has dozens of branches,
/// and a wall of chips would push the worklist off the screen. The menu stays
/// open while ticking, so picking four branches is four taps, and each line
/// shows the live count. The picks also show as removable chips beside it, so
/// what's applied is visible without reopening the menu.
class _BranchFilter extends StatelessWidget {
  final List<String> options;
  final Set<String> selected;
  final String Function(String) labelFor;
  final ValueChanged<String> onToggle;
  final VoidCallback onClear;

  const _BranchFilter({
    required this.options,
    required this.selected,
    required this.labelFor,
    required this.onToggle,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final picked = selected.toList()..sort();
    final summary = picked.isEmpty
        ? 'All branches'
        : picked.length <= 2
        ? picked.join(', ')
        : '${picked.take(2).join(', ')} +${picked.length - 2}';

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 9),
          child: SizedBox(
            width: 58,
            child: Text(
              'Branch',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: AppColors.textMuted,
              ),
            ),
          ),
        ),
        Expanded(
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              MenuAnchor(
                style: const MenuStyle(
                  maximumSize: WidgetStatePropertyAll(Size(420, 420)),
                ),
                menuChildren: [
                  for (final t in options)
                    CheckboxMenuButton(
                      value: selected.contains(t),
                      // Stay open: several branches are usually picked in one
                      // go, and closing after each tick would mean reopening.
                      closeOnActivate: false,
                      onChanged: (_) => onToggle(t),
                      child: Text(labelFor(t)),
                    ),
                ],
                builder: (context, menu, _) => OutlinedButton.icon(
                  onPressed: () => menu.isOpen ? menu.close() : menu.open(),
                  icon: const Icon(Icons.arrow_drop_down_rounded),
                  label: Text(summary),
                ),
              ),
              for (final t in picked)
                InputChip(
                  label: Text(t),
                  tooltip: labelFor(t),
                  onDeleted: () => onToggle(t),
                  visualDensity: VisualDensity.compact,
                ),
              if (picked.length > 1)
                TextButton(onPressed: onClear, child: const Text('Clear')),
            ],
          ),
        ),
      ],
    );
  }
}

/// "Non-merit | Merit" for one student. Merit means a Single this year under
/// the seating policy; non-merit, a shared room. Read-only without
/// allotment.manage.
class _MeritToggle extends StatelessWidget {
  final bool merit;
  final ValueChanged<bool>? onChanged;

  const _MeritToggle({required this.merit, required this.onChanged});

  /// One chip that names the current state and flips on tap — not a
  /// two-segment button, which needs ~155px and at phone width squeezed
  /// "Merit" to nothing inside the row's name column.
  @override
  Widget build(BuildContext context) => FilterChip(
    selected: merit,
    showCheckmark: false,
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    avatar: Icon(
      merit ? Icons.star_rounded : Icons.star_border_rounded,
      size: 15,
    ),
    label: Text(
      merit ? 'Merit' : 'Non-merit',
      style: const TextStyle(fontSize: 11.5),
    ),
    tooltip: merit
        ? 'Merit — entitled to a Single. Tap to mark non-merit.'
        : 'Non-merit — entitled to a shared room. Tap to mark merit.',
    onSelected: onChanged == null ? null : (v) => onChanged!(v),
  );
}

/// "Course  [All] [UG — Graduation (316)] [ICD — Diploma (197)] …"
///
/// Tapping the selected chip again, or "All", clears it.
class _ChipFilter<T> extends StatelessWidget {
  final String label;
  final List<T> options;
  final T? selected;
  final String Function(T) labelFor;
  final ValueChanged<T?> onChanged;

  const _ChipFilter({
    required this.label,
    required this.options,
    required this.selected,
    required this.labelFor,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 7),
        child: SizedBox(
          width: 58,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: AppColors.textMuted,
            ),
          ),
        ),
      ),
      Expanded(
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              label: const Text('All'),
              selected: selected == null,
              showCheckmark: false,
              onSelected: (_) => onChanged(null),
            ),
            for (final o in options)
              ChoiceChip(
                label: Text(labelFor(o)),
                selected: selected == o,
                showCheckmark: false,
                onSelected: (_) => onChanged(selected == o ? null : o),
              ),
          ],
        ),
      ),
    ],
  );
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

class _PersonRow extends StatelessWidget {
  final AppUser person;
  final bool canAllot;

  /// Shown only where merit decides the room type (UG 3rd year).
  final bool showMerit;
  final ValueChanged<bool> onMerit;
  final VoidCallback onOpen;
  final VoidCallback onAllot;
  final VoidCallback onMove;
  final VoidCallback onVacate;

  const _PersonRow({
    required this.person,
    required this.canAllot,
    required this.showMerit,
    required this.onMerit,
    required this.onOpen,
    required this.onAllot,
    required this.onMove,
    required this.onVacate,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        child: Row(
          children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: AppColors.primarySoft,
              child: Text(
                person.initials,
                style: TextStyle(
                  color: AppColors.primary,
                  fontWeight: FontWeight.w700,
                  fontSize: 13.5,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    person.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14.5,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      person.displayRole,
                      if (person.enrollmentNo != null) person.enrollmentNo!,
                      if (person.gender != null) person.gender!,
                    ].join(' · '),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 12.5,
                    ),
                  ),
                  if (showMerit) ...[
                    const SizedBox(height: 6),
                    _MeritToggle(
                      merit: person.singleRoomEligible,
                      onChanged: canAllot ? onMerit : null,
                    ),
                  ],
                ],
              ),
            ),
            Expanded(
              flex: 2,
              child: Align(
                alignment: Alignment.centerLeft,
                child: person.isAllotted
                    ? StatusPill(
                        person.roomLabel!.toUpperCase(),
                        AppColors.success,
                        AppColors.successSoft,
                      )
                    : StatusPill(
                        'NO ROOM',
                        AppColors.warning,
                        AppColors.warningSoft,
                      ),
              ),
            ),
            if (canAllot)
              person.isAllotted
                  ? PopupMenuButton<String>(
                      icon: const Icon(Icons.more_horiz_rounded, size: 20),
                      onSelected: (v) => v == 'move' ? onMove() : onVacate(),
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'move',
                          child: Text('Change room'),
                        ),
                        PopupMenuItem(
                          value: 'vacate',
                          child: Text(
                            'Vacate',
                            style: TextStyle(color: AppColors.danger),
                          ),
                        ),
                      ],
                    )
                  : FilledButton(
                      onPressed: onAllot,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                      ),
                      child: const Text('Allot'),
                    )
            else
              const SizedBox(width: 48),
          ],
        ),
      ),
    );
  }
}
