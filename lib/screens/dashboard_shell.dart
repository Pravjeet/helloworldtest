import 'package:flutter/material.dart';

import '../core/logo.dart';
import '../core/nav_registry.dart';
import '../core/permissions.dart';
import '../core/session.dart';
import '../core/theme.dart';
import '../models/hostel_request.dart';
import '../services/auth_service.dart';
import '../services/request_service.dart';

/// The one and only dashboard chrome: sidebar + header + content area.
///
/// Every role uses this. The sidebar contents come from [navigationFor],
/// which filters by permission — so a Student and a Super Admin get an
/// identical, consistent shell with different doors in it.
class DashboardShell extends StatefulWidget {
  const DashboardShell({super.key});

  @override
  State<DashboardShell> createState() => _DashboardShellState();
}

class _DashboardShellState extends State<DashboardShell> {
  String _selectedId = 'overview';
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final session = Session.of(context);
    final sections = navigationFor(session);
    final items = sections.expand((s) => s.items).toList();

    // Guard: if the admin revokes a permission while the user is sitting on
    // that page, fall back to the first page they can still reach.
    final current = items.any((i) => i.id == _selectedId)
        ? items.firstWhere((i) => i.id == _selectedId)
        : items.first;

    final isNarrow = MediaQuery.sizeOf(context).width < 1000;

    return Scaffold(
      backgroundColor: AppColors.canvas,
      drawer: isNarrow
          ? Drawer(
              child: _Sidebar(
                sections: sections,
                selectedId: current.id,
                expanded: true,
                onSelect: (id) {
                  setState(() => _selectedId = id);
                  Navigator.pop(context);
                },
                onToggle: null,
              ),
            )
          : null,
      body: Row(
        children: [
          if (!isNarrow)
            _Sidebar(
              sections: sections,
              selectedId: current.id,
              expanded: _expanded,
              onSelect: (id) => setState(() => _selectedId = id),
              onToggle: () => setState(() => _expanded = !_expanded),
            ),
          Expanded(
            // Wraps the top bar too, not just the page content below it — the
            // bell in _TopBar depends on this to navigate to Requests, and a
            // DashboardNav scoped to only the content area is invisible to a
            // sibling widget, which previously left the bell permanently
            // unpressable no matter who was signed in.
            child: DashboardNav(
              // Lets a page send the user somewhere else in the sidebar — a
              // "Raise a request" button on the dashboard should actually
              // open Requests, not just name it.
              goTo: (id) {
                if (items.any((i) => i.id == id)) {
                  setState(() => _selectedId = id);
                }
              },
              canReach: (id) => items.any((i) => i.id == id),
              child: Column(
                children: [
                  _TopBar(title: current.label, showMenuButton: isNarrow),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1400),
                        // KeyedSubtree forces a fresh state when the page
                        // changes, so stale form state never leaks across
                        // pages.
                        child: KeyedSubtree(
                          key: ValueKey(current.id),
                          child: Builder(builder: current.builder),
                        ),
                      ),
                    ),
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

/// Lets any page inside the shell jump to another sidebar entry.
///
/// [canReach] matters as much as [goTo]: a page should not offer a shortcut
/// to something the current user's permissions have filtered out of the
/// sidebar, or the button would silently do nothing.
class DashboardNav extends InheritedWidget {
  final void Function(String navId) goTo;
  final bool Function(String navId) canReach;

  const DashboardNav({
    super.key,
    required this.goTo,
    required this.canReach,
    required super.child,
  });

  static DashboardNav? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DashboardNav>();

  @override
  bool updateShouldNotify(DashboardNav oldWidget) => false;
}

class _Sidebar extends StatelessWidget {
  final List<NavSection> sections;
  final String selectedId;
  final bool expanded;
  final ValueChanged<String> onSelect;
  final VoidCallback? onToggle;

  const _Sidebar({
    required this.sections,
    required this.selectedId,
    required this.expanded,
    required this.onSelect,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final session = Session.of(context);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: expanded ? 262 : 80,
      color: AppColors.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 88,
            width: double.infinity,
            color: AppColors.sidebarDeep,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Row(
              children: [
                WorkspaceLogo(
                  logoBase64: session.settings.institution.logoBase64,
                  size: 40,
                ),
                if (expanded) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          session.collegeName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          session.user.displayRole,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 14),
              children: [
                for (final section in sections) ...[
                  if (expanded && section.title != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(22, 16, 16, 8),
                      child: Text(
                        section.title!.toUpperCase(),
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 10.5,
                          letterSpacing: 1.1,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  for (final item in section.items)
                    _NavTile(
                      item: item,
                      selected: item.id == selectedId,
                      expanded: expanded,
                      onTap: () => onSelect(item.id),
                    ),
                ],
              ],
            ),
          ),
          const Divider(color: Colors.white12, height: 1),
          if (onToggle != null)
            _SidebarAction(
              icon: expanded
                  ? Icons.chevron_left_rounded
                  : Icons.chevron_right_rounded,
              label: 'Collapse',
              expanded: expanded,
              onTap: onToggle!,
            ),
          _SidebarAction(
            icon: Icons.logout_rounded,
            label: 'Log out',
            expanded: expanded,
            danger: true,
            onTap: () => _confirmLogout(context),
          ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }

  Future<void> _confirmLogout(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Log out?'),
        content: const Text('You will need to sign in again to continue.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Log out'),
          ),
        ],
      ),
    );
    // AuthGate listens to authStateChanges, so signing out is enough —
    // no manual navigation, and therefore no chance of a stale route stack.
    if (ok == true) await AuthService.instance.signOut();
  }
}

class _NavTile extends StatelessWidget {
  final NavItem item;
  final bool selected;
  final bool expanded;
  final VoidCallback onTap;

  const _NavTile({
    required this.item,
    required this.selected,
    required this.expanded,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tile = Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      decoration: BoxDecoration(
        color: selected ? AppColors.primary : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: expanded ? 14 : 0,
              vertical: 12,
            ),
            child: Row(
              mainAxisAlignment: expanded
                  ? MainAxisAlignment.start
                  : MainAxisAlignment.center,
              children: [
                Icon(
                  item.icon,
                  size: 20,
                  color: selected ? Colors.white : Colors.white70,
                ),
                if (expanded) ...[
                  const SizedBox(width: 13),
                  Expanded(
                    child: Text(
                      item.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: selected ? Colors.white : Colors.white70,
                        fontSize: 14,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    return expanded ? tile : Tooltip(message: item.label, child: tile);
  }
}

class _SidebarAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool expanded;
  final bool danger;
  final VoidCallback onTap;

  const _SidebarAction({
    required this.icon,
    required this.label,
    required this.expanded,
    required this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = danger ? const Color(0xFFFCA5A5) : Colors.white70;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: expanded ? 26 : 0,
            vertical: 14,
          ),
          child: Row(
            mainAxisAlignment: expanded
                ? MainAxisAlignment.start
                : MainAxisAlignment.center,
            children: [
              Icon(icon, size: 20, color: color),
              if (expanded) ...[
                const SizedBox(width: 13),
                Text(
                  label,
                  style: TextStyle(
                    color: color,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  final String title;
  final bool showMenuButton;
  const _TopBar({required this.title, required this.showMenuButton});

  @override
  Widget build(BuildContext context) {
    final session = Session.of(context);
    final now = DateTime.now();
    final institution = session.settings.institution;

    // The page name carries the institution under it rather than a greeting.
    // On a screen someone stares at all day, "which college am I looking at"
    // is a useful fact; "Welcome back, Pravjeet" stops being one after the
    // first login.
    final subtitle = [
      session.collegeName,
      if (institution.tagline != null)
        institution.tagline!
      else
        'overall system status',
    ].join(' · ');

    return Container(
      decoration: BoxDecoration(
        color: AppColors.canvas,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 13, 24, 13),
      child: Row(
        children: [
          if (showMenuButton)
            IconButton(
              icon: const Icon(Icons.menu_rounded),
              onPressed: () => Scaffold.of(context).openDrawer(),
            ),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.4,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: AppColors.textMuted, fontSize: 12.5),
                ),
              ],
            ),
          ),
          const Spacer(),
          if (MediaQuery.sizeOf(context).width > 1150) ...[
            _Pill(
              icon: Icons.apartment_rounded,
              label: institution.shortName ?? session.collegeName,
            ),
            const SizedBox(width: 10),
          ],
          if (MediaQuery.sizeOf(context).width > 760) ...[
            _Pill(
              icon: Icons.calendar_today_rounded,
              label: '${now.day} ${_month(now.month)} ${now.year}',
              dim: 'Today',
            ),
            const SizedBox(width: 10),
          ],
          const _Bell(),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.only(left: 12),
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: AppColors.border)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: AppColors.primarySoft,
                  child: Text(
                    session.user.initials,
                    style: TextStyle(
                      color: AppColors.primary,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ),
                if (MediaQuery.sizeOf(context).width > 620) ...[
                  const SizedBox(width: 9),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        session.user.name,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          height: 1.25,
                        ),
                      ),
                      Text(
                        session.user.displayRole,
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.textMuted,
                          height: 1.25,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _month(int m) => const [
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
  ][m - 1];
}

/// A bordered chip in the top bar — institution, date.
class _Pill extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? dim;

  const _Pill({required this.icon, required this.label, this.dim});

  @override
  Widget build(BuildContext context) => Container(
    height: 34,
    padding: const EdgeInsets.symmetric(horizontal: 11),
    decoration: BoxDecoration(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: AppColors.border),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: AppColors.textMuted),
        const SizedBox(width: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
              color: AppColors.textStrong,
            ),
          ),
        ),
        if (dim != null) ...[
          const SizedBox(width: 5),
          Text(
            '· $dim',
            style: TextStyle(fontSize: 12.5, color: AppColors.textMuted),
          ),
        ],
      ],
    ),
  );
}

/// Notification bell, counting what actually needs a decision.
///
/// Wired to open requests rather than a generic "notifications" collection
/// that does not exist — a badge showing a number nobody can act on is worse
/// than no badge.
class _Bell extends StatefulWidget {
  const _Bell();

  @override
  State<_Bell> createState() => _BellState();
}

class _BellState extends State<_Bell> {
  // Cached rather than created inline in build(): this widget sits in the
  // top bar on *every* page, so it rebuilds on every single sidebar click.
  // Handing StreamBuilder a fresh `watchAll(...)` each time looks harmless
  // but isn't — a new Stream instance makes it tear down the old Firestore
  // listener and open a new one, and a new listener re-reads every document
  // in the collection for its initial snapshot. That turned ordinary
  // navigation into a full re-read of `requests` on every click.
  String? _collegeId;
  Stream<List<HostelRequest>>? _stream;

  @override
  Widget build(BuildContext context) {
    final session = Session.of(context);
    final nav = DashboardNav.maybeOf(context);

    if (!session.can(Perm.requestsViewAll)) return const SizedBox.shrink();

    if (_collegeId != session.user.collegeId) {
      _collegeId = session.user.collegeId;
      _stream = RequestService.instance.watchAll(_collegeId!);
    }

    return StreamBuilder<List<HostelRequest>>(
      stream: _stream,
      builder: (context, snap) {
        final open = (snap.data ?? const <HostelRequest>[])
            .where((r) => r.status.isOpen)
            .length;

        return InkWell(
          onTap: (nav?.canReach('requests') ?? false)
              ? () => nav!.goTo('requests')
              : null,
          borderRadius: BorderRadius.circular(8),
          child: Tooltip(
            message: open > 0
                ? '$open request(s) waiting on a decision'
                : 'Open requests',
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  height: 34,
                  width: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.card,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Icon(
                    Icons.notifications_none_rounded,
                    size: 17,
                    color: AppColors.textStrong,
                  ),
                ),
                if (open > 0)
                  Positioned(
                    top: -5,
                    right: -5,
                    child: Container(
                      constraints: const BoxConstraints(minWidth: 17),
                      height: 17,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: AppColors.danger,
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(color: AppColors.canvas, width: 2),
                      ),
                      child: Text(
                        open > 99 ? '99+' : '$open',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          height: 1,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
