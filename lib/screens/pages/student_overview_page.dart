import 'package:flutter/material.dart';

import '../../core/hostel_codes.dart';
import '../../core/permissions.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../models/app_role.dart';
import '../../models/app_user.dart';
import '../../models/college_settings.dart';
import '../../models/enrollment.dart';
import '../../models/hostel.dart';
import '../../services/auth_service.dart';
import '../../services/data_service.dart';
import '../../services/enrollment_service.dart';
import '../../services/hostel_service.dart';
import '../../utils/enrollment_helpers.dart';
import '../dashboard_shell.dart' show HistoryBanner;
import 'user_detail_view.dart';

/// A filterable directory of residents — hostel, course, trade, semester,
/// year, batch, religion, category, blood group, home state.
///
/// Reads straight off [AppUser], not off `Enrollment` (see
/// enrollment_service.dart) — this page's job is a snapshot of the whole
/// roster right now, not a session-scoped view, so it stays independent of
/// whether backfill has been run and never gates on a current session being
/// set. `year` in particular is whatever free text a sheet or a warden typed
/// ("2nd", "II", ...), not a normalised ordinal, so the filter options are
/// exactly the distinct strings actually in use rather than a clean
/// 1st/2nd/3rd/4th list. `batch` is cleaner — see
/// `batchFromRegistrationNo` — but is filtered the same way for consistency.
///
/// Tapping a row opens the same [UserDetailView] User Management uses, held
/// as state rather than pushed as a route — same reasoning as
/// `UsersPage._openUser` — so the sidebar stays visible and the page falls
/// straight back to the filtered list on the way out. This page still owns
/// none of the actual workflows: Users & Roles owns editing, Room Allotment
/// owns moving people, Academic Records owns promotion. It only answers "who,
/// filtered by these things" and hands off to those from there.
///
/// Session-scoping follows the year picker in the top bar
/// ([Session.effectiveSession]), same lens as the Dashboard and Hostels &
/// Rooms: switch to a past session and this becomes that year's roster,
/// enrollment fields and all — which is free, since read-only means there
/// was never a live/history distinction to make here in the first place.
///
/// Paginated the same way as Users / Room Allotment: rendering every match
/// at once is what makes a large roster crawl.
class StudentOverviewPage extends StatefulWidget {
  const StudentOverviewPage({super.key});

  @override
  State<StudentOverviewPage> createState() => _StudentOverviewPageState();
}

class _StudentOverviewPageState extends State<StudentOverviewPage> {
  String? _trade;
  String? _year;
  int? _sem;
  String? _hostel;
  String? _state;
  String? _batch;
  String? _religion;
  String? _course;

  /// LEET or Regular — only offered, and only meaningful, under Graduation.
  String? _entry;
  String? _category;
  String? _blood;

  static const _pageSize = 50;
  int _page = 0;

  /// Free-text search over name, registration number and email — the same
  /// fields User Management searches. Owned as a controller for the same
  /// reason as there: "Clear filters" has to be able to empty the box, not
  /// just the query behind it.
  String _query = '';
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _matchesQuery(AppUser u) {
    final q = _query.trim().toLowerCase();
    return q.isEmpty ||
        u.name.toLowerCase().contains(q) ||
        u.email.toLowerCase().contains(q) ||
        (u.enrollmentNo ?? '').toLowerCase().contains(q);
  }

  /// Set when a row is tapped. Held as state rather than pushed as a route so
  /// the sidebar stays visible — same pattern as `UsersPage._openUser`.
  AppUser? _openUser;

  /// A filter chip reads "BH-5" rather than the full "CV Raman House" — see
  /// [HostelCodes].
  String _hostelLabel(String? name) {
    if (name == null || name.trim().isEmpty) return 'Unallotted';
    return HostelCodes.of(name)!;
  }

  /// `state` is only as good as the address it was parsed from, so a blank is
  /// common and gets its own bucket — the same 'Not set' wording the fines
  /// dashboard uses — rather than being silently dropped from the roster.
  /// Religion, course, category and blood group use the same bucket for the
  /// same reason.
  static const _noState = 'Not set';

  static String _stateLabel(String? s) =>
      (s == null || s.trim().isEmpty) ? _noState : s;

  static String _religionOf(AppUser u) => religionLabel(u.religion) ?? _noState;

  static String _categoryOf(AppUser u) => categoryLabel(u.category) ?? _noState;

  static String _bloodOf(AppUser u) =>
      bloodGroupLabel(u.bloodGroup) ?? _noState;

  /// Read at the top of [build]. Course is matched through the college's
  /// course rules, so a student is grouped under the same course promotion
  /// treats them as.
  CollegeSettings _settings = const CollegeSettings();

  String _courseOf(AppUser u) => _settings.courseNameFor(u.course) ?? _noState;

  /// [standard] first, in its own order, then any other value the roster
  /// actually has, sorted, then 'Not set' last — so a sheet's one-off
  /// spelling stays findable without shuffling the familiar options.
  static List<String> _withExtras(
    List<String> standard,
    Iterable<String> found,
  ) => [
    ...standard,
    ...(({...found}..removeAll([...standard, _noState])).toList()..sort()),
    _noState,
  ];

  /// This session's enrollment per student. Empty when no session is set.
  Map<String, Enrollment> _byUid = const {};

  /// True when the page is showing one academic session rather than the
  /// standing roster.
  bool _sessionScoped = false;

  // ------------------------------------------------------------------
  // Where each displayed value comes from.
  //
  // In session mode the enrollment is authoritative, because it is the only
  // record promotion actually maintains. `AppUser.year` is free text copied
  // from the import sheet and never updated again — a student imported as
  // "1" still reads "1" four promotions later, which is what made this page
  // disagree with Academic Records. `Enrollment.year` is a real ordinal,
  // recomputed every July.
  //
  // Hostel and semester come from the enrollment too, and deliberately: for a
  // past session the room someone held *then* is the honest answer, and it is
  // exactly why the enrollment denormalises it.
  // ------------------------------------------------------------------

  String? _yearLabel(AppUser u) {
    final e = _byUid[u.uid];
    if (e != null) return ordinal(e.year);
    return _sessionScoped ? null : u.year;
  }

  int? _semOf(AppUser u) =>
      _byUid[u.uid]?.sem ?? (_sessionScoped ? null : u.sem);

  String? _hostelOf(AppUser u) =>
      _sessionScoped ? _byUid[u.uid]?.hostelName : u.hostelName;

  // Same as `_yearLabel`/`_semOf` but without the "no data for this session
  // means blank" gate — used only to build the *permanent* filter options
  // below. A resident whose batch/course puts them outside the currently
  // viewed session still has a real year and semester; they just don't have
  // one *for this session*, which is exactly the distinction `_keep` still
  // needs to keep filtering correctly.
  String? _anyYearLabel(AppUser u) {
    final e = _byUid[u.uid];
    return e != null ? ordinal(e.year) : u.year;
  }

  int? _anySemOf(AppUser u) => _byUid[u.uid]?.sem ?? u.sem;

  bool _keep(AppUser u) =>
      _matchesQuery(u) &&
      (_trade == null || u.trade == _trade) &&
      (_year == null || _yearLabel(u) == _year) &&
      (_sem == null || _semOf(u) == _sem) &&
      (_hostel == null || _hostelLabel(_hostelOf(u)) == _hostel) &&
      (_state == null || _stateLabel(u.state) == _state) &&
      (_batch == null || u.batch == _batch) &&
      (_religion == null || _religionOf(u) == _religion) &&
      (_course == null || _courseOf(u) == _course) &&
      (_entry == null || entryTypeOf(u) == _entry) &&
      (_category == null || _categoryOf(u) == _category) &&
      (_blood == null || _bloodOf(u) == _blood);

  bool get _anyFilter =>
      _query.trim().isNotEmpty ||
      _trade != null ||
      _year != null ||
      _sem != null ||
      _hostel != null ||
      _state != null ||
      _batch != null ||
      _religion != null ||
      _course != null ||
      _entry != null ||
      _category != null ||
      _blood != null;

  void _clearAll() => setState(() {
    _search.clear();
    _query = '';
    _trade = null;
    _year = null;
    _sem = null;
    _hostel = null;
    _state = null;
    _batch = null;
    _religion = null;
    _course = null;
    _entry = null;
    _category = null;
    _blood = null;
    _page = 0;
  });

  @override
  Widget build(BuildContext context) {
    final session = Session.of(context);
    final collegeId = session.user.collegeId;
    _settings = session.settings;

    if (!session.can(Perm.usersView)) {
      return AppCard(
        padding: const EdgeInsets.symmetric(vertical: 54),
        child: Center(
          child: Text(
            'You don\'t have permission to view the student directory.',
            style: TextStyle(color: AppColors.textMuted),
          ),
        ),
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

        return StreamBuilder<List<AppRole>>(
          stream: DataService.instance.watchRoles(collegeId),
          builder: (context, roleSnap) {
            // Staff who manage hostels aren't residents — excluded from the
            // directory the same way Room Allotment excludes the Super
            // Admin, so trade/year/sem columns aren't full of staff blanks.
            final staffRoleIds = (roleSnap.data ?? const <AppRole>[])
                .where((r) => Perm.managesHostels(r.permissions))
                .map((r) => r.id)
                .toSet();

            // The session drives who is listed at all. Both streams are
            // pooled and both are already open from Academic Records, so this
            // attaches listeners rather than paying for either query again.
            final currentSession = session.effectiveSession;

            return StreamBuilder<List<Enrollment>>(
              stream: currentSession == null
                  ? const Stream<List<Enrollment>>.empty()
                  : EnrollmentService.instance.watchRoster(
                      collegeId,
                      currentSession,
                    ),
              builder: (context, enrollSnap) {
                _sessionScoped = currentSession != null;
                _byUid = {
                  for (final e in enrollSnap.data ?? const <Enrollment>[])
                    e.uid: e,
                };

                return StreamBuilder<List<AppUser>>(
                  stream: DataService.instance.watchUsers(collegeId),
                  builder: (context, userSnap) {
                    if (userSnap.hasError) {
                      return AppCard(
                        child: Text(AuthService.describeError(userSnap.error!)),
                      );
                    }
                    if (!userSnap.hasData ||
                        (_sessionScoped && !enrollSnap.hasData)) {
                      return const Padding(
                        padding: EdgeInsets.all(60),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }

                    final allResidents = userSnap.data!
                        .where((u) => !u.isSuperAdmin)
                        .where((u) => !staffRoleIds.contains(u.roleId))
                        .toList();

                    final roster = allResidents
                        // In session mode the directory *is* that session's
                        // roster: someone with no enrollment for it either
                        // graduated, has not been backfilled, or was admitted
                        // later. Listing them anyway is what made a fully
                        // graduated campus still show 2,649 students.
                        .where(
                          (u) => !_sessionScoped || _byUid.containsKey(u.uid),
                        )
                        .toList();

                    final shown = roster.where(_keep).toList()
                      ..sort(
                        (a, b) => a.name.toLowerCase().compareTo(
                          b.name.toLowerCase(),
                        ),
                      );

                    // Every option is permanent: built from the full resident
                    // list (never `roster`, which a session view or a filter
                    // selection can narrow) and, where the college configures
                    // a master list, from that too — so switching sessions or
                    // picking a filter can empty the results without ever
                    // making an option disappear. A filter with nobody in it
                    // just shows no students; see the empty state below.
                    final tradeOptions = ({
                      ...session.settings.tradeCodes,
                      for (final u in allResidents)
                        if (u.trade != null) u.trade!,
                    }.toList()..sort());
                    // Built through the same accessors the filter compares
                    // against, so an option can never be offered that matches
                    // nobody *whenever they're looked up the same way* — see
                    // `_anyYearLabel`/`_anySemOf` for why options use the
                    // session-independent versions.
                    final yearOptions = ({
                      for (final u in allResidents)
                        if (_anyYearLabel(u) != null) _anyYearLabel(u)!,
                    }.toList()..sort());
                    final semOptions = ({
                      for (final u in allResidents)
                        if (_anySemOf(u) != null) _anySemOf(u)!,
                    }.toList()..sort());
                    final hostelOptions = ({
                      'Unallotted',
                      for (final h in hostels) h.label,
                      for (final u in allResidents) _hostelLabel(_hostelOf(u)),
                      // BH-10 belongs after BH-9, not between BH-1 and BH-2.
                    }.toList()..sort(Hostel.compareLabels));
                    // 'Not set' is not a place, so it sorts to the end instead of
                    // landing between Nagaland and Odisha.
                    final stateOptions =
                        ({
                          ...kIndianStates,
                          _noState,
                          for (final u in allResidents) _stateLabel(u.state),
                        }.toList()..sort((a, b) {
                          if (a == _noState) return 1;
                          if (b == _noState) return -1;
                          return a.compareTo(b);
                        }));
                    // No college-wide master list of batches exists — they're
                    // whatever admission years the roster actually has — so
                    // this is the one option list still built from real data
                    // rather than a config. Still pulled from `allResidents`,
                    // not `roster`, so it doesn't shrink with the session view.
                    // Descending: the most recent intake is what a warden is
                    // usually looking for, not the oldest one still on the books.
                    final batchOptions = ({
                      for (final u in allResidents)
                        if (u.batch != null) u.batch!,
                    }.toList()..sort((a, b) => b.compareTo(a)));
                    // The standard list first, in its own order, then anything
                    // else a sheet recorded, then 'Not set' last.
                    final religionOptions = _withExtras(
                      kReligions,
                      allResidents.map(_religionOf),
                    );
                    // Courses come from Settings' course rules (ICD, UG, PG
                    // here), so a course with nobody in it is still offered.
                    final courseOptions = _withExtras(
                      _settings.courseNames,
                      allResidents.map(_courseOf),
                    );
                    final categoryOptions = _withExtras(
                      kCategories,
                      allResidents.map(_categoryOf),
                    );
                    final bloodOptions = _withExtras(
                      kBloodGroups,
                      allResidents.map(_bloodOf),
                    );

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
                        const HistoryBanner(),
                        _Header(
                          total: roster.length,
                          shown: shown.length,
                          anyFilter: _anyFilter,
                          onClear: _clearAll,
                          session: currentSession,
                          search: _search,
                          onSearch: (v) => setState(() {
                            _query = v;
                            _page = 0;
                          }),
                        ),
                        const SizedBox(height: 14),

                        // An empty session is a real answer, not a broken page.
                        // Everyone graduating is the expected end state, and
                        // saying so beats rendering filter chips over nothing.
                        if (_sessionScoped && roster.isEmpty) ...[
                          AppCard(
                            padding: const EdgeInsets.symmetric(vertical: 46),
                            child: Center(
                              child: Column(
                                children: [
                                  Icon(
                                    Icons.school_outlined,
                                    size: 34,
                                    color: AppColors.textMuted,
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    'Nobody is enrolled in $currentSession.',
                                    style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 430,
                                    ),
                                    child: Text(
                                      'This directory follows the current '
                                      'academic session. Either everyone has '
                                      'graduated, or this session has not been '
                                      'backfilled yet — Academic Records is where '
                                      'that is done.',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: AppColors.textMuted,
                                        fontSize: 13,
                                        height: 1.5,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ] else ...[
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    _StudentList(
                                      students: pageItems,
                                      byUid: _byUid,
                                      onTap: (u) =>
                                          setState(() => _openUser = u),
                                    ),
                                    if (pageCount > 1) ...[
                                      const SizedBox(height: 14),
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          OutlinedButton(
                                            onPressed: page > 0
                                                ? () => setState(
                                                    () => _page = page - 1,
                                                  )
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
                                                ? () => setState(
                                                    () => _page = page + 1,
                                                  )
                                                : null,
                                            child: const Text('Next'),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              const SizedBox(width: 14),
                              SizedBox(
                                width: 232,
                                child: _SlicerRail(
                                  tradeOptions: tradeOptions,
                                  yearOptions: yearOptions,
                                  sems: semOptions,
                                  hostelOptions: hostelOptions,
                                  stateOptions: stateOptions,
                                  batchOptions: batchOptions,
                                  religionOptions: religionOptions,
                                  religion: _religion,
                                  onReligion: (v) => setState(() {
                                    _religion = _religion == v ? null : v;
                                    _page = 0;
                                  }),
                                  courseOptions: courseOptions,
                                  course: _course,
                                  onCourse: (v) => setState(() {
                                    _course = _course == v ? null : v;
                                    // LEET only exists within Graduation.
                                    if (!hasLateralEntry(_course)) {
                                      _entry = null;
                                    }
                                    _page = 0;
                                  }),
                                  showEntry: hasLateralEntry(_course),
                                  entry: _entry,
                                  onEntry: (v) => setState(() {
                                    _entry = _entry == v ? null : v;
                                    _page = 0;
                                  }),
                                  categoryOptions: categoryOptions,
                                  category: _category,
                                  onCategory: (v) => setState(() {
                                    _category = _category == v ? null : v;
                                    _page = 0;
                                  }),
                                  bloodOptions: bloodOptions,
                                  blood: _blood,
                                  onBlood: (v) => setState(() {
                                    _blood = _blood == v ? null : v;
                                    _page = 0;
                                  }),
                                  trade: _trade,
                                  year: _year,
                                  sem: _sem,
                                  hostel: _hostel,
                                  state: _state,
                                  batch: _batch,
                                  tradeLabelFor: session.settings.tradeLabelFor,
                                  onTrade: (v) => setState(() {
                                    _trade = _trade == v ? null : v;
                                    _page = 0;
                                  }),
                                  onYear: (v) => setState(() {
                                    _year = _year == v ? null : v;
                                    _page = 0;
                                  }),
                                  onSem: (v) => setState(() {
                                    _sem = _sem == v ? null : v;
                                    _page = 0;
                                  }),
                                  onHostel: (v) => setState(() {
                                    _hostel = _hostel == v ? null : v;
                                    _page = 0;
                                  }),
                                  onState: (v) => setState(() {
                                    _state = _state == v ? null : v;
                                    _page = 0;
                                  }),
                                  onBatch: (v) => setState(() {
                                    _batch = _batch == v ? null : v;
                                    _page = 0;
                                  }),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}

// ------------------------------- header -------------------------------

class _Header extends StatelessWidget {
  final int total;
  final int shown;
  final bool anyFilter;
  final VoidCallback onClear;

  /// Null when no academic session is set, in which case this falls back to
  /// the standing roster and says so.
  final String? session;

  final TextEditingController search;
  final ValueChanged<String> onSearch;

  const _Header({
    required this.total,
    required this.shown,
    required this.anyFilter,
    required this.onClear,
    required this.session,
    required this.search,
    required this.onSearch,
  });

  @override
  Widget build(BuildContext context) => AppCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          'Student Overview',
          trailing: session == null
              ? null
              : StatusPill(session!, AppColors.primary, AppColors.primarySoft),
        ),
        const SizedBox(height: 4),
        Text(
          session == null
              ? 'No academic session is set, so this shows the standing '
                    'roster. Year comes from the import sheet and does not '
                    'move with promotion — set a session for live years.'
              : 'Everyone enrolled in $session, by trade, year, semester, '
                    'hostel and home state. Year and room come from that '
                    'session\'s record, so they follow promotion.',
          style: TextStyle(fontSize: 13, color: AppColors.textMuted),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: search,
          onChanged: onSearch,
          decoration: const InputDecoration(
            hintText: 'Search by name, registration number or email',
            prefixIcon: Icon(Icons.search_rounded),
            isDense: true,
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Text(
              anyFilter ? '$shown of $total students' : '$total students',
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
            ),
            if (anyFilter) ...[
              const SizedBox(width: 14),
              TextButton.icon(
                onPressed: onClear,
                icon: const Icon(Icons.filter_alt_off_rounded, size: 17),
                label: const Text('Clear filters'),
              ),
            ],
          ],
        ),
      ],
    ),
  );
}

// ----------------------------- slicer rail -----------------------------

/// Click-to-filter tiles, one box per dimension — the same interaction as
/// the fines dashboard's slicer rail: tap a tile to filter by it, tap it
/// again to clear just that one. Replaces what used to be a row of six
/// dropdowns, which meant opening a menu and scanning a list to find "BH-5"
/// instead of just seeing and tapping it.
class _SlicerRail extends StatelessWidget {
  final List<String> tradeOptions;
  final List<String> yearOptions;
  final List<int> sems;
  final List<String> hostelOptions;
  final List<String> stateOptions;
  final List<String> batchOptions;
  final List<String> religionOptions;
  final List<String> courseOptions;
  final List<String> categoryOptions;
  final List<String> bloodOptions;
  final String? trade;
  final String? year;
  final int? sem;
  final String? hostel;
  final String? state;
  final String? batch;
  final String? religion;
  final String? course;
  final String? category;
  final String? blood;
  final String Function(String) tradeLabelFor;
  final ValueChanged<String> onTrade;
  final ValueChanged<String> onYear;
  final ValueChanged<int> onSem;
  final ValueChanged<String> onHostel;
  final ValueChanged<String> onState;
  final ValueChanged<String> onBatch;
  final ValueChanged<String> onReligion;
  final ValueChanged<String> onCourse;
  final bool showEntry;
  final String? entry;
  final ValueChanged<String> onEntry;
  final ValueChanged<String> onCategory;
  final ValueChanged<String> onBlood;

  const _SlicerRail({
    required this.tradeOptions,
    required this.yearOptions,
    required this.sems,
    required this.hostelOptions,
    required this.stateOptions,
    required this.batchOptions,
    required this.religionOptions,
    required this.courseOptions,
    required this.categoryOptions,
    required this.bloodOptions,
    required this.trade,
    required this.year,
    required this.sem,
    required this.hostel,
    required this.state,
    required this.batch,
    required this.religion,
    required this.course,
    required this.category,
    required this.blood,
    required this.tradeLabelFor,
    required this.onTrade,
    required this.onYear,
    required this.onSem,
    required this.onHostel,
    required this.onState,
    required this.onBatch,
    required this.onReligion,
    required this.onCourse,
    required this.showEntry,
    required this.entry,
    required this.onEntry,
    required this.onCategory,
    required this.onBlood,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SlicerBox<String>(
          title: 'Hostel',
          options: hostelOptions,
          selected: hostel,
          onTap: onHostel,
          columns: 2,
          maxHeight: 200,
        ),
        const SizedBox(height: 14),
        _SlicerBox<String>(
          title: 'Course',
          options: courseOptions,
          selected: course,
          labelFor: courseLabel,
          onTap: onCourse,
          columns: 1,
        ),
        // A sub-filter of Graduation, so it sits right under Course and only
        // appears once Graduation is picked.
        if (showEntry) ...[
          const SizedBox(height: 14),
          _SlicerBox<String>(
            title: 'Entry',
            options: const [kEntryRegular, kEntryLeet],
            selected: entry,
            onTap: onEntry,
            columns: 2,
          ),
        ],
        const SizedBox(height: 14),
        _SlicerBox<String>(
          title: 'Trade',
          options: tradeOptions,
          selected: trade,
          labelFor: tradeLabelFor,
          onTap: onTrade,
          columns: 2,
          maxHeight: 200,
        ),
        const SizedBox(height: 14),
        _SlicerBox<int>(
          title: 'Semester',
          options: sems,
          selected: sem,
          labelFor: (s) => 'Sem $s',
          onTap: onSem,
          columns: 3,
        ),
        const SizedBox(height: 14),
        _SlicerBox<String>(
          title: 'Year',
          options: yearOptions,
          selected: year,
          onTap: onYear,
          columns: 3,
        ),
        const SizedBox(height: 14),
        _SlicerBox<String>(
          title: 'Batch',
          options: batchOptions,
          selected: batch,
          onTap: onBatch,
          columns: 2,
          maxHeight: 160,
        ),
        const SizedBox(height: 14),
        _SlicerBox<String>(
          title: 'Religion',
          options: religionOptions,
          selected: religion,
          onTap: onReligion,
          columns: 2,
          maxHeight: 200,
        ),
        const SizedBox(height: 14),
        _SlicerBox<String>(
          title: 'Category',
          options: categoryOptions,
          selected: category,
          onTap: onCategory,
          columns: 2,
        ),
        const SizedBox(height: 14),
        _SlicerBox<String>(
          title: 'Blood Group',
          options: bloodOptions,
          selected: blood,
          onTap: onBlood,
          columns: 3,
          maxHeight: 200,
        ),
        const SizedBox(height: 14),
        _SlicerBox<String>(
          title: 'Home State',
          options: stateOptions,
          selected: state,
          onTap: onState,
          columns: 1,
          maxHeight: 200,
        ),
      ],
    );
  }
}

class _SlicerBox<T> extends StatelessWidget {
  final String title;
  final List<T> options;
  final T? selected;
  final ValueChanged<T> onTap;
  final int columns;
  final double? maxHeight;
  final String Function(T)? labelFor;

  const _SlicerBox({
    required this.title,
    required this.options,
    required this.selected,
    required this.onTap,
    required this.columns,
    this.maxHeight,
    this.labelFor,
  });

  @override
  Widget build(BuildContext context) {
    if (options.isEmpty) return const SizedBox.shrink();

    final grid = Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final o in options)
          _Tile(
            label: labelFor == null ? '$o' : labelFor!(o),
            selected: selected == o,
            onTap: () => onTap(o),
            width: columns == 1
                ? double.infinity
                : (200 - (columns - 1) * 6) / columns,
          ),
      ],
    );

    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          if (maxHeight == null)
            grid
          else
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight!),
              child: SingleChildScrollView(child: grid),
            ),
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final double width;

  const _Tile({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.width,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width == double.infinity ? null : width,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: width == double.infinity ? double.infinity : null,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary : AppColors.canvas,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.border,
          ),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            color: selected ? Colors.white : AppColors.textStrong,
          ),
        ),
      ),
    ),
  );
}

// -------------------------------- list ---------------------------------

class _StudentList extends StatelessWidget {
  final List<AppUser> students;

  /// This session's enrollment per student, so a row can show the year
  /// promotion actually maintains rather than the import sheet's stale
  /// free text. Empty when no session is set, in which case the row
  /// falls back to the profile fields.
  final Map<String, Enrollment> byUid;

  /// Opens the tapped student's full detail view — see [UserDetailView].
  final ValueChanged<AppUser> onTap;

  const _StudentList({
    required this.students,
    required this.byUid,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (students.isEmpty) {
      return AppCard(
        padding: const EdgeInsets.symmetric(vertical: 50),
        child: Center(
          child: Text(
            'No students match these filters.',
            style: TextStyle(color: AppColors.textMuted),
          ),
        ),
      );
    }

    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (var i = 0; i < students.length; i++) ...[
            if (i > 0) Divider(height: 1, color: AppColors.border),
            _StudentRow(
              student: students[i],
              enrollment: byUid[students[i].uid],
              onTap: () => onTap(students[i]),
            ),
          ],
        ],
      ),
    );
  }
}

class _StudentRow extends StatelessWidget {
  final AppUser student;
  final Enrollment? enrollment;
  final VoidCallback onTap;

  const _StudentRow({
    required this.student,
    this.enrollment,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final u = student;
    final e = enrollment;

    // The enrollment wins wherever it exists: it is the record promotion
    // maintains, and for a past session it is also the honest answer about
    // which room this student actually held at the time.
    final hostelName = e?.hostelName != null
        ? HostelCodes.of(e!.hostelName, id: e.hostelId)
        : u.hostelLabel;
    final roomNumber = e?.roomNumber ?? u.roomNumber;
    final hostelLabel = hostelName == null
        ? null
        : (roomNumber == null ? hostelName : '$hostelName · $roomNumber');

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          children: [
            CircleAvatar(
              radius: 19,
              backgroundColor: AppColors.primarySoft,
              child: Text(
                u.initials,
                style: TextStyle(
                  color: AppColors.primary,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
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
                    u.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (u.enrollmentNo != null) u.enrollmentNo!,
                      if (u.course != null) u.course!,
                    ].join('  ·  '),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                  ),
                ],
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(
                u.trade ?? '—',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Expanded(
              flex: 2,
              child: Builder(
                builder: (context) {
                  final year = e != null ? ordinal(e.year) : u.year;
                  final sem = e?.sem ?? u.sem;
                  final parts = [
                    if (year != null) year,
                    if (sem != null) 'Sem $sem',
                  ];
                  return Text(
                    parts.isEmpty ? '—' : parts.join(' · '),
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  );
                },
              ),
            ),
            Expanded(
              flex: 3,
              child: hostelLabel == null
                  ? StatusPill(
                      'UNALLOTTED',
                      AppColors.warning,
                      AppColors.warningSoft,
                    )
                  : Text(
                      hostelLabel,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: AppColors.textMuted,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
