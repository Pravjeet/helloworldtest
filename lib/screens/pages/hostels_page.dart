import 'package:flutter/material.dart';

import '../../core/permissions.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../models/hostel.dart';
import '../../services/auth_service.dart';
import '../../services/data_service.dart';
import '../../services/enrollment_service.dart';
import '../../services/hostel_service.dart';
import '../dashboard_shell.dart' show HistoryBanner;
import '../../widgets/selectable_chips.dart';
import 'hostel_detail_view.dart';
import 'hostel_editor_dialog.dart';

/// Hostels & Rooms.
///
/// Holds the drill-down as internal state rather than pushing a route, so the
/// dashboard sidebar stays visible when you open a hostel.
class HostelsPage extends StatefulWidget {
  const HostelsPage({super.key});

  @override
  State<HostelsPage> createState() => _HostelsPageState();
}

class _HostelsPageState extends State<HostelsPage> {
  String? _openHostelId;

  /// Memoised per set of hostels — the same reason `_FeedState._countsFor`
  /// exists on the dashboard. These are aggregation queries, which always go
  /// to the server, so an un-memoised future would re-fire all fourteen on
  /// every rebuild and undo the saving it exists to make.
  ///
  /// Keyed on the hostel ids, so adding or removing a block refetches while
  /// an ordinary rebuild does not. Occupancy changes are made on Room
  /// Allotment, not here, so a snapshot taken when the page opened is the
  /// right currency for it.
  Future<({Map<String, int> heads, int occupiedBeds})>? _heads;
  String? _headsKey;

  /// [viewingSession] is null for the live count and a session string while
  /// browsing history — see [Session.viewingSession]. Folded into the key so
  /// switching the lens invalidates the cache the same way changing which
  /// hostels exist does.
  ///
  /// `occupiedBeds` travels alongside `heads` rather than being derived from
  /// the live [Hostel] documents, so the "Students" and "Occupied %" tiles
  /// can never disagree about which session they're describing.
  Future<({Map<String, int> heads, int occupiedBeds})> _headsFor(
    String collegeId,
    List<Hostel> hostels,
    String? viewingSession,
  ) {
    final ids = hostels.map((h) => h.id).toList();
    final key = '$collegeId/${ids.join(',')}/${viewingSession ?? 'live'}';
    if (_headsKey != key || _heads == null) {
      _headsKey = key;
      _heads = viewingSession == null
          ? DataService.instance
                .countStudentsByHostel(collegeId, ids)
                .then(
                  (heads) => (
                    heads: heads,
                    occupiedBeds: hostels.fold<int>(
                      0,
                      (s, h) => s + h.occupiedBeds,
                    ),
                  ),
                )
          // A past session's occupancy has to come from that session's
          // Enrollment records — the live count() above answers "who is here
          // now", which is a different question the moment history is on
          // screen.
          : EnrollmentService.instance
                .rosterOnce(collegeId, viewingSession)
                .then(
                  (roster) => (
                    heads: studentsByHostelFor(roster),
                    occupiedBeds: roster.where((e) => e.isAllotted).length,
                  ),
                );
    }
    return _heads!;
  }

  @override
  Widget build(BuildContext context) {
    final session = Session.of(context);
    final collegeId = session.user.collegeId;

    if (_openHostelId != null) {
      return HostelDetailView(
        collegeId: collegeId,
        hostelId: _openHostelId!,
        onBack: () => setState(() => _openHostelId = null),
      );
    }

    return StreamBuilder<List<Hostel>>(
      stream: HostelService.instance.watchHostels(collegeId),
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

        final hostels = snap.data!;

        // Headcounts come from the roster, and listing users needs
        // `users.view` — a role granted hostels but not users would otherwise
        // fire a query the rules reject and sit on a permanent dash. Without
        // the permission the student figures are simply not shown.
        if (!session.can(Perm.usersView)) {
          return _body(
            context,
            session: session,
            collegeId: collegeId,
            hostels: hostels,
            heads: const {},
            occupiedBeds: hostels.fold<int>(0, (s, h) => s + h.occupiedBeds),
            showCounts: false,
            countsReady: false,
          );
        }

        // Counted, not downloaded.
        //
        // This used to stream the whole roster and tally it in Dart, which
        // meant 2,649 documents to render fourteen numbers — and an older
        // comment here claimed the dashboard had already opened that query so
        // it was free. That stopped being true when the dashboard moved to
        // aggregations, and this page went on paying for it silently.
        return FutureBuilder<({Map<String, int> heads, int occupiedBeds})>(
          future: _headsFor(collegeId, hostels, session.viewingSession),
          builder: (context, headSnap) {
            return _body(
              context,
              session: session,
              collegeId: collegeId,
              hostels: hostels,
              heads: headSnap.data?.heads ?? const {},
              occupiedBeds:
                  headSnap.data?.occupiedBeds ??
                  hostels.fold<int>(0, (s, h) => s + h.occupiedBeds),
              showCounts: true,
              // Still loading, so the tiles show a dash rather than a
              // confident zero.
              countsReady: headSnap.hasData,
            );
          },
        );
      },
    );
  }

  Widget _body(
    BuildContext context, {
    required Session session,
    required String collegeId,
    required List<Hostel> hostels,
    required Map<String, int> heads,
    required int occupiedBeds,
    required bool showCounts,
    required bool countsReady,
  }) {
    final totalRooms = hostels.fold<int>(0, (s, h) => s + h.roomCount);
    final totalBeds = hostels.fold<int>(0, (s, h) => s + h.bedCount);
    final totalOccupied = occupiedBeds;
    final totalStudents = heads.values.fold<int>(0, (s, n) => s + n);

    // Hostels and rooms are the institution's buildings, not history — they
    // don't change per session, so adding/removing/editing/emptying them
    // while browsing a past year would mean *today's* buildings inheriting an
    // edit made while the screen happened to be dressed in 2025-26's numbers.
    // Every mutating control on this page is disabled for exactly that
    // reason whenever the lens is pointed at the past.
    final canMutate = session.can(Perm.hostelsManage) && !session.isViewingHistory;
    // Emptying writes students and academic records too, not just rooms —
    // so it needs more than hostels.manage to finish rather than half-run.
    final canEmpty = session.canEmptyAllRooms && !session.isViewingHistory;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const HistoryBanner(),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionHeader(
                'Hostels  (${hostels.length})',
                trailing: !session.can(Perm.hostelsManage)
                    ? null
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (hostels.isNotEmpty) ...[
                            OutlinedButton.icon(
                              onPressed: canEmpty
                                  ? () => _emptyAllRooms(collegeId)
                                  : null,
                              icon: Icon(
                                Icons.meeting_room_outlined,
                                size: 18,
                                color: canEmpty
                                    ? AppColors.danger
                                    : AppColors.textMuted,
                              ),
                              label: Text(
                                'Empty all rooms',
                                style: TextStyle(
                                  color: canEmpty
                                      ? AppColors.danger
                                      : AppColors.textMuted,
                                ),
                              ),
                              style: OutlinedButton.styleFrom(
                                side: BorderSide(
                                  color: canEmpty
                                      ? AppColors.dangerSoft
                                      : AppColors.border,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 14,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                          ],
                          ElevatedButton.icon(
                            onPressed: canMutate
                                ? () => _openEditor(collegeId, null)
                                : null,
                            icon: const Icon(Icons.add_rounded, size: 18),
                            label: const Text('Add hostel'),
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                                vertical: 14,
                              ),
                            ),
                          ),
                        ],
                      ),
              ),
              if (hostels.isNotEmpty) ...[
                const SizedBox(height: 18),
                Wrap(
                  spacing: 28,
                  runSpacing: 14,
                  children: [
                    _Metric('Hostels', '${hostels.length}'),
                    _Metric('Rooms', '$totalRooms'),
                    _Metric('Beds', '$totalBeds'),
                    _Metric(
                      'Occupied',
                      totalBeds == 0
                          ? '0%'
                          : '${(totalOccupied / totalBeds * 100).round()}%',
                    ),
                    // Counted from the roster rather than from the bed
                    // counters, so it stays honest if the two ever drift.
                    if (showCounts)
                      _Metric('Students', countsReady ? '$totalStudents' : '—'),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 18),
        if (hostels.isEmpty)
          _EmptyState(
            canManage: session.can(Perm.hostelsManage),
            onAdd: () => _openEditor(collegeId, null),
          )
        else
          // A Wrap, not a GridView with a fixed childAspectRatio: cards
          // size to their own content, so a hostel with many amenities
          // can't overflow its tile and paint over the ones beside it.
          LayoutBuilder(
            builder: (context, c) {
              const spacing = 16.0;
              final columns = c.maxWidth > 1150
                  ? 3
                  : c.maxWidth > 720
                  ? 2
                  : 1;
              final cardWidth =
                  (c.maxWidth - spacing * (columns - 1)) / columns;
              return Wrap(
                spacing: spacing,
                runSpacing: spacing,
                children: hostels
                    .map(
                      (h) => SizedBox(
                        width: cardWidth,
                        child: _HostelCard(
                          hostel: h,
                          students: heads[h.id] ?? 0,
                          // Only overridden while viewing history — live mode
                          // keeps reading straight off the hostel document, as
                          // it always has, so this never changes what today's
                          // occupancy bar means.
                          historicalOccupied: session.isViewingHistory
                              ? (heads[h.id] ?? 0)
                              : null,
                          showCounts: showCounts,
                          countsReady: countsReady,
                          canManage: canMutate,
                          onOpen: () => setState(() => _openHostelId = h.id),
                          onEdit: () => _openEditor(collegeId, h),
                          onDelete: () => _confirmDelete(collegeId, h),
                        ),
                      ),
                    )
                    .toList(),
              );
            },
          ),
      ],
    );
  }

  Future<void> _openEditor(String collegeId, Hostel? hostel) async {
    await showDialog(
      context: context,
      builder: (_) => HostelEditorDialog(collegeId: collegeId, hostel: hostel),
    );
  }

  Future<void> _emptyAllRooms(String collegeId) async {
    const phrase = 'EMPTY ROOMS';
    final controller = TextEditingController();
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setLocal) => AlertDialog(
          title: const Text('Empty all rooms?'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Every room in every hostel is emptied, and every student '
                  'loses their hostel and room. They stay on the roster and '
                  'reappear in Room Allotment awaiting a room, so nobody is '
                  'deleted — but every allotment in the college is undone, '
                  'and there is no undo.',
                  style: TextStyle(fontSize: 13, height: 1.5),
                ),
                const SizedBox(height: 16),
                Text(
                  'Type $phrase to confirm',
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: phrase,
                    isDense: true,
                  ),
                  onChanged: (_) => setLocal(() {}),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
              onPressed: controller.text.trim().toUpperCase() == phrase
                  ? () => Navigator.pop(c, true)
                  : null,
              child: const Text('Empty all'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (ok != true) return;

    try {
      final result = await HostelService.instance.emptyAllRooms(collegeId);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Cleared ${result.roomsCleared} room(s), freed '
            '${result.bedsFreed} bed(s), unallotted '
            '${result.studentsFreed} student(s)',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(AuthService.describeError(e))),
      );
    }
  }

  Future<void> _confirmDelete(String collegeId, Hostel hostel) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Delete ${hostel.label}?'),
        content: Text(
          hostel.occupiedBeds > 0
              ? 'This hostel currently has ${hostel.occupiedBeds} student(s) '
                    'allotted. Deleting it removes all ${hostel.roomCount} '
                    'rooms and their allotments. This cannot be undone.'
              : 'This removes the hostel and all ${hostel.roomCount} of its '
                    'rooms. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
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

    messenger.showSnackBar(
      const SnackBar(content: Text('Deleting hostel and rooms…')),
    );
    try {
      await HostelService.instance.deleteHostel(collegeId, hostel.id);
      messenger.showSnackBar(SnackBar(content: Text('${hostel.label} deleted')));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(AuthService.describeError(e))),
      );
    }
  }
}

class _Metric extends StatelessWidget {
  final String label;
  final String value;
  const _Metric(this.label, this.value);

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
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
        style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800),
      ),
    ],
  );
}

class _EmptyState extends StatelessWidget {
  final bool canManage;
  final VoidCallback onAdd;
  const _EmptyState({required this.canManage, required this.onAdd});

  @override
  Widget build(BuildContext context) => AppCard(
    padding: const EdgeInsets.symmetric(vertical: 60, horizontal: 28),
    child: Column(
      children: [
        Container(
          height: 64,
          width: 64,
          decoration: BoxDecoration(
            color: AppColors.primarySoft,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Icon(
            Icons.apartment_rounded,
            size: 30,
            color: AppColors.primary,
          ),
        ),
        const SizedBox(height: 20),
        const Text(
          'No hostels yet',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        // Not const: ConstrainedBox's constructor asserts on its constraints,
        // which disqualifies it from being a const constructor.
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Text(
            'Add your first hostel block. You describe the floors and rooms '
            'per floor, and every room is created for you.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 14,
              height: 1.5,
            ),
          ),
        ),
        if (canManage) ...[
          const SizedBox(height: 22),
          ElevatedButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Add hostel'),
          ),
        ],
      ],
    ),
  );
}

class _HostelCard extends StatelessWidget {
  final Hostel hostel;
  final int students;

  /// Set only while viewing history, in which case it replaces
  /// `hostel.occupiedBeds` as the source for the percentage and the bar
  /// below — a past session has no "beds occupied right now" figure, only a
  /// count of whose enrollment named this hostel that year. Null in the live
  /// case, where this card renders exactly as it always has.
  final int? historicalOccupied;

  /// False when the viewer lacks `users.view`, so the roster was never read
  /// and the student figures are hidden rather than shown as a stuck dash.
  final bool showCounts;
  final bool countsReady;
  final bool canManage;
  final VoidCallback onOpen;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _HostelCard({
    required this.hostel,
    required this.students,
    this.historicalOccupied,
    required this.showCounts,
    required this.countsReady,
    required this.canManage,
    required this.onOpen,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final occupiedForBar = historicalOccupied ?? hostel.occupiedBeds;
    final occupancyForBar = hostel.bedCount == 0
        ? 0.0
        : occupiedForBar / hostel.bedCount;
    final pct = (occupancyForBar * 100).round();

    return InkWell(
      onTap: onOpen,
      borderRadius: BorderRadius.circular(14),
      child: AppCard(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  height: 42,
                  constraints: const BoxConstraints(minWidth: 42),
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: AppColors.primarySoft,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  // Codes are free-form now ("A" or "BH-01"), so the badge
                  // grows with the text and shrinks the font rather than
                  // clipping a longer code.
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      hostel.code.isNotEmpty
                          ? hostel.code
                          : (hostel.name.trim().isEmpty
                                ? '?'
                                : hostel.name.trim()[0].toUpperCase()),
                      style: TextStyle(
                        color: AppColors.primary,
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        hostel.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      // The full name stays visible here, and only here and
                      // in the editor — it's an alias, not how staff refer to
                      // the block.
                      Text(
                        '${hostel.label == hostel.name ? '' : '${hostel.name} · '}'
                        '${hostel.gender.label} · ${hostel.floors} floor'
                        '${hostel.floors == 1 ? '' : 's'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  ),
                ),
                if (canManage)
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_horiz_rounded, size: 20),
                    onSelected: (v) => v == 'edit' ? onEdit() : onDelete(),
                    itemBuilder: (_) => [
                      PopupMenuItem(value: 'edit', child: Text('Edit details')),
                      PopupMenuItem(
                        value: 'delete',
                        child: Text(
                          'Delete hostel',
                          style: TextStyle(color: AppColors.danger),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                _MiniStat(label: 'Rooms', value: '${hostel.roomCount}'),
                _MiniStat(label: 'Beds', value: '${hostel.bedCount}'),
                _MiniStat(label: 'Free', value: '${hostel.freeBeds}'),
                if (showCounts)
                  _MiniStat(
                    label: 'Students',
                    value: countsReady ? '$students' : '—',
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Text(
                  'Occupancy',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textMuted,
                  ),
                ),
                const Spacer(),
                Text(
                  '$pct%',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: occupancyForBar,
                minHeight: 7,
                backgroundColor: AppColors.border,
                valueColor: AlwaysStoppedAnimation(
                  pct >= 90
                      ? AppColors.danger
                      : pct >= 70
                      ? AppColors.warning
                      : AppColors.success,
                ),
              ),
            ),
            const SizedBox(height: 14),
            // Not Expanded: these cards size to their content now, so the
            // column's height is unbounded and a vertical flex child would
            // fail to lay out — which silently blanks the whole list.
            ReadOnlyChips(
              values: hostel.amenities,
              max: 4,
              emptyLabel: 'No amenities listed',
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;
  const _MiniStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        Text(
          label,
          style: TextStyle(
            color: AppColors.textMuted,
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

// =====================================================================
// Create / edit dialog
// =====================================================================
