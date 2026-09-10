import 'package:flutter/material.dart';

import '../../core/permissions.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../models/enrollment.dart';
import '../../models/hostel.dart';
import '../../services/auth_service.dart';
import '../../services/enrollment_service.dart';
import '../../services/hostel_service.dart';
import '../../utils/enrollment_helpers.dart';

/// A filterable directory of the current session's students — trade, year,
/// semester, hostel.
///
/// Built on [Enrollment], not [AppUser]: year and semester belong to a
/// session (see ARCHITECTURE.md / academic_page.dart), and the enrollment
/// record already carries a clean numeric year plus a denormalised
/// trade/hostel snapshot for exactly this kind of filtering, with no joins
/// needed. Reading `AppUser.year` instead would mean filtering on free text
/// ("2nd", "II", "2" all meaning the same year) and would silently miss
/// anyone whose room changed since their profile was last saved.
///
/// Deliberately read-only: no drill-down, no editing. Users & Roles already
/// owns editing a student; Room Allotment already owns moving them. This
/// page answers one question — "who, filtered by these four things" — and
/// stops there.
class StudentOverviewPage extends StatefulWidget {
  const StudentOverviewPage({super.key});

  @override
  State<StudentOverviewPage> createState() => _StudentOverviewPageState();
}

class _StudentOverviewPageState extends State<StudentOverviewPage> {
  String? _trade;
  int? _year;
  int? _sem;
  String? _hostel;

  /// Hostel full name -> short code, same resolution fines_overview_view
  /// uses: a fine/enrollment snapshots the full name, which is unreadable as
  /// a filter chip next to nine other "… House" options.
  Map<String, String> _codes = const {};

  String _hostelLabel(String? name) {
    if (name == null || name.trim().isEmpty) return 'Unallotted';
    return _codes[name] ?? name;
  }

  bool _keep(Enrollment e) =>
      (_trade == null || e.trade == _trade) &&
      (_year == null || e.year == _year) &&
      (_sem == null || e.sem == _sem) &&
      (_hostel == null || _hostelLabel(e.hostelName) == _hostel);

  bool get _anyFilter =>
      _trade != null || _year != null || _sem != null || _hostel != null;

  void _clearAll() => setState(() {
    _trade = null;
    _year = null;
    _sem = null;
    _hostel = null;
  });

  @override
  Widget build(BuildContext context) {
    final session = Session.of(context);
    final collegeId = session.user.collegeId;

    if (!session.canAny([Perm.academicView, Perm.academicManage])) {
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

    final currentSession = session.settings.session.current;
    if (currentSession == null) {
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
                'Set the current session under System Settings — this list '
                'is scoped to it, the same as Academic Records.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textMuted, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    return StreamBuilder<List<Hostel>>(
      stream: HostelService.instance.watchHostels(collegeId),
      builder: (context, hostelSnap) {
        final hostels = hostelSnap.data ?? const <Hostel>[];
        _codes = {
          for (final h in hostels)
            if (h.code.trim().isNotEmpty) h.name: h.code,
        };

        return StreamBuilder<List<Enrollment>>(
          stream: EnrollmentService.instance.watchRoster(
            collegeId,
            currentSession,
          ),
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

            final roster = snap.data!;
            final shown = roster.where(_keep).toList()
              ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

            // Every option comes from the UNFILTERED roster — building them
            // from `shown` would make picking a filter erase the very
            // options that could get you back out of it.
            final tradeOptions =
                ({for (final e in roster) if (e.trade != null) e.trade!}.toList()
                  ..sort());
            final years = ({for (final e in roster) e.year}.toList()..sort());
            final sems =
                ({for (final e in roster) if (e.sem != null) e.sem!}.toList()
                  ..sort());
            final hostelOptions =
                ({for (final e in roster) _hostelLabel(e.hostelName)}.toList()
                  ..sort());

            return SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Header(
                    currentSession: currentSession,
                    total: roster.length,
                    shown: shown.length,
                    anyFilter: _anyFilter,
                    onClear: _clearAll,
                  ),
                  const SizedBox(height: 14),
                  _Filters(
                    tradeOptions: tradeOptions,
                    years: years,
                    sems: sems,
                    hostelOptions: hostelOptions,
                    trade: _trade,
                    year: _year,
                    sem: _sem,
                    hostel: _hostel,
                    tradeLabelFor: session.settings.tradeLabelFor,
                    onTrade: (v) => setState(() => _trade = v),
                    onYear: (v) => setState(() => _year = v),
                    onSem: (v) => setState(() => _sem = v),
                    onHostel: (v) => setState(() => _hostel = v),
                  ),
                  const SizedBox(height: 14),
                  _StudentList(students: shown),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

// ------------------------------- header -------------------------------

class _Header extends StatelessWidget {
  final String currentSession;
  final int total;
  final int shown;
  final bool anyFilter;
  final VoidCallback onClear;

  const _Header({
    required this.currentSession,
    required this.total,
    required this.shown,
    required this.anyFilter,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) => AppCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          'Student Overview',
          trailing: StatusPill(
            currentSession,
            AppColors.primary,
            AppColors.primarySoft,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Filter this session\'s roster by trade, year, semester and hostel.',
          style: TextStyle(fontSize: 13, color: AppColors.textMuted),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Text(
              anyFilter ? '$shown of $total students' : '$total students',
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
              ),
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

// ------------------------------- filters -------------------------------

class _Filters extends StatelessWidget {
  final List<String> tradeOptions;
  final List<int> years;
  final List<int> sems;
  final List<String> hostelOptions;
  final String? trade;
  final int? year;
  final int? sem;
  final String? hostel;
  final String Function(String) tradeLabelFor;
  final ValueChanged<String?> onTrade;
  final ValueChanged<int?> onYear;
  final ValueChanged<int?> onSem;
  final ValueChanged<String?> onHostel;

  const _Filters({
    required this.tradeOptions,
    required this.years,
    required this.sems,
    required this.hostelOptions,
    required this.trade,
    required this.year,
    required this.sem,
    required this.hostel,
    required this.tradeLabelFor,
    required this.onTrade,
    required this.onYear,
    required this.onSem,
    required this.onHostel,
  });

  @override
  Widget build(BuildContext context) => AppCard(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    child: Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        _Drop<String>(
          label: 'Trade',
          value: trade,
          options: tradeOptions,
          labelFor: tradeLabelFor,
          onChanged: onTrade,
          width: 220,
        ),
        _Drop<int>(
          label: 'Year',
          value: year,
          options: years,
          labelFor: (y) => '${ordinal(y)} year',
          onChanged: onYear,
          width: 140,
        ),
        _Drop<int>(
          label: 'Semester',
          value: sem,
          options: sems,
          labelFor: (s) => 'Sem $s',
          onChanged: onSem,
          width: 130,
        ),
        _Drop<String>(
          label: 'Hostel',
          value: hostel,
          options: hostelOptions,
          onChanged: onHostel,
          width: 170,
        ),
      ],
    ),
  );
}

class _Drop<T> extends StatelessWidget {
  final String label;
  final T? value;
  final List<T> options;
  final String Function(T)? labelFor;
  final ValueChanged<T?> onChanged;
  final double width;

  const _Drop({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.labelFor,
    this.width = 200,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: DropdownButtonFormField<T>(
      initialValue: options.contains(value) ? value : null,
      isExpanded: true,
      decoration: InputDecoration(labelText: label, isDense: true),
      hint: const Text('All'),
      items: [
        DropdownMenuItem<T>(value: null, child: const Text('All')),
        ...options.map(
          (o) => DropdownMenuItem(
            value: o,
            child: Text(
              labelFor == null ? '$o' : labelFor!(o),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ],
      onChanged: onChanged,
    ),
  );
}

// -------------------------------- list ---------------------------------

class _StudentList extends StatelessWidget {
  final List<Enrollment> students;
  const _StudentList({required this.students});

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
            _StudentRow(enrollment: students[i]),
          ],
        ],
      ),
    );
  }
}

class _StudentRow extends StatelessWidget {
  final Enrollment enrollment;
  const _StudentRow({required this.enrollment});

  String get _initials {
    final parts = enrollment.name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final e = enrollment;
    final hostelLabel = e.hostelName == null
        ? null
        : (e.roomNumber == null ? e.hostelName : '${e.hostelName} · ${e.roomNumber}');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        children: [
          CircleAvatar(
            radius: 19,
            backgroundColor: AppColors.primarySoft,
            child: Text(
              _initials,
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
                  e.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    if (e.enrollmentNo != null) e.enrollmentNo!,
                    if (e.course != null) e.course!,
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
              e.trade ?? '—',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              '${ordinal(e.year)} yr'
              '${e.sem == null ? '' : ' · Sem ${e.sem}'}',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            flex: 3,
            child: hostelLabel == null
                ? StatusPill('UNALLOTTED', AppColors.warning, AppColors.warningSoft)
                : Text(
                    hostelLabel,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: AppColors.textMuted),
                  ),
          ),
        ],
      ),
    );
  }
}
