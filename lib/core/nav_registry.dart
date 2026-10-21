import 'package:flutter/material.dart';

import '../screens/pages/academic_page.dart';
import '../screens/pages/allotment_page.dart';
import '../screens/pages/audit_page.dart';
import '../screens/pages/fees_page.dart';
import '../screens/pages/fines_page.dart';
import '../screens/pages/hostels_page.dart';
import '../screens/pages/maintenance_page.dart';
import '../screens/pages/mess_page.dart';
import '../screens/pages/my_room_page.dart';
import '../screens/pages/office_orders_page.dart';
import '../screens/pages/overview_page.dart';
import '../screens/pages/profile_page.dart';
import '../screens/pages/requests_page.dart';
import '../screens/pages/notices_page.dart';
import '../screens/pages/roles_page.dart';
import '../screens/pages/settings_page.dart';
import '../screens/pages/student_overview_page.dart';
import '../screens/pages/users_page.dart';
import 'permissions.dart';
import 'session.dart';

/// One entry in the sidebar.
class NavItem {
  final String id;
  final String label;
  final IconData icon;

  /// Shown only if the session holds at least one of these. Empty = always.
  final List<String> requires;

  /// Hidden if the session holds any of these, even when [requires] matched.
  ///
  /// For self-service entries that make no sense to the people who manage the
  /// thing. "My Room" is the case that forced this: `Session.can` short-
  /// circuits to true for a Super Admin, so a `requires: [selfRoom]` entry
  /// showed the workspace owner a room they will never be allotted. Anyone
  /// holding `allotment.manage` sees Room Allotment instead, which is the
  /// staff-facing version of the same information.
  final List<String> excludes;

  final WidgetBuilder builder;

  const NavItem({
    required this.id,
    required this.label,
    required this.icon,
    this.requires = const [],
    this.excludes = const [],
    required this.builder,
  });
}

class NavSection {
  final String? title;
  final List<NavItem> items;
  const NavSection({this.title, required this.items});
}

/// THE single source of truth for navigation.
///
/// Every role — SuperAdmin, Warden, Student — renders from this same list.
/// The only difference between what two users see is which entries survive
/// the permission filter. Add a feature once, and it appears for exactly the
/// roles that were granted it.
const List<NavSection> _allSections = [
  NavSection(
    items: [
      NavItem(
        id: 'overview',
        label: 'Dashboard',
        icon: Icons.dashboard_rounded,
        builder: _overview,
      ),
    ],
  ),
  NavSection(
    title: 'People',
    items: [
      NavItem(
        id: 'users',
        label: 'User Management',
        icon: Icons.group_rounded,
        requires: [Perm.usersView],
        builder: _users,
      ),
      NavItem(
        id: 'academic',
        label: 'Academic Records',
        icon: Icons.event_available_rounded,
        requires: [Perm.academicView, Perm.academicManage],
        builder: _academic,
      ),
      NavItem(
        id: 'student-overview',
        label: 'Student Overview',
        icon: Icons.school_rounded,
        requires: [Perm.usersView],
        builder: _studentOverview,
      ),
      NavItem(
        id: 'roles',
        label: 'Roles & Permissions',
        icon: Icons.verified_user_rounded,
        requires: [Perm.rolesView],
        builder: _roles,
      ),
    ],
  ),
  NavSection(
    title: 'Hostel',
    items: [
      NavItem(
        id: 'hostels',
        label: 'Hostels & Rooms',
        icon: Icons.apartment_rounded,
        requires: [Perm.hostelsView],
        builder: _hostels,
      ),
      NavItem(
        id: 'maintenance',
        label: 'Under Maintenance',
        icon: Icons.handyman_rounded,
        requires: [Perm.hostelsView],
        builder: _maintenance,
      ),
      NavItem(
        id: 'allotment',
        label: 'Room Allotment',
        icon: Icons.bed_rounded,
        requires: [Perm.allotmentManage],
        builder: _allotment,
      ),
      NavItem(
        id: 'my-room',
        label: 'My Room',
        icon: Icons.meeting_room_rounded,
        requires: [Perm.selfRoom],
        excludes: [Perm.allotmentManage],
        builder: _myRoom,
      ),
    ],
  ),
  NavSection(
    title: 'Operations',
    items: [
      NavItem(
        id: 'mess',
        label: 'Mess',
        icon: Icons.restaurant_rounded,
        requires: [Perm.messView],
        builder: _mess,
      ),
      NavItem(
        id: 'requests',
        label: 'Requests',
        icon: Icons.assignment_turned_in_rounded,
        requires: [
          Perm.requestsViewAll,
          Perm.requestsViewOwn,
          Perm.requestsCreate,
        ],
        builder: _requests,
      ),
      NavItem(
        id: 'notices',
        label: 'Notices',
        icon: Icons.campaign_rounded,
        requires: [Perm.noticesView],
        builder: _notices,
      ),
      NavItem(
        id: 'fines',
        label: 'Fines',
        icon: Icons.gavel_rounded,
        requires: [Perm.finesViewAll, Perm.finesViewOwn],
        builder: _fines,
      ),
      NavItem(
        id: 'fees',
        label: 'Mess Fees',
        icon: Icons.receipt_long_rounded,
        requires: [Perm.feesViewAll, Perm.feesViewOwn],
        builder: _fees,
      ),
      NavItem(
        id: 'office-orders',
        label: 'Office Orders',
        icon: Icons.description_rounded,
        requires: [Perm.officeOrdersView],
        builder: _officeOrders,
      ),
    ],
  ),
  NavSection(
    title: 'Account',
    items: [
      NavItem(
        id: 'profile',
        label: 'My Profile',
        icon: Icons.person_rounded,
        builder: _profile,
      ),
      NavItem(
        id: 'settings',
        label: 'System Settings',
        icon: Icons.settings_rounded,
        requires: [Perm.settingsManage],
        builder: _settings,
      ),
      NavItem(
        id: 'audit',
        label: 'Activity Log',
        icon: Icons.history_rounded,
        requires: [Perm.settingsManage],
        builder: _audit,
      ),
    ],
  ),
];

/// Filters the master list down to what this session may see.
List<NavSection> navigationFor(Session session) {
  final result = <NavSection>[];
  for (final section in _allSections) {
    final visible = section.items
        .where((i) => i.requires.isEmpty || session.canAny(i.requires))
        .where((i) => i.excludes.isEmpty || !session.canAny(i.excludes))
        .toList();
    if (visible.isNotEmpty) {
      result.add(NavSection(title: section.title, items: visible));
    }
  }
  return result;
}

// Page builders. These are top-level functions rather than `Page.new` tear-offs
// because a WidgetBuilder takes a BuildContext, and because only top-level
// function references are const — which `_allSections` requires.
Widget _overview(BuildContext c) => const OverviewPage();
Widget _users(BuildContext c) => const UsersPage();
Widget _academic(BuildContext c) => const AcademicPage();

Widget _studentOverview(BuildContext c) => const StudentOverviewPage();
Widget _roles(BuildContext c) => const RolesPage();
Widget _myRoom(BuildContext c) => const MyRoomPage();
Widget _profile(BuildContext c) => const ProfilePage();

// Placeholder builders for modules you haven't built yet. Replacing one is a
// one-line change here — the sidebar, routing and gating already work.
Widget _hostels(BuildContext c) => const HostelsPage();
Widget _maintenance(BuildContext c) => const MaintenanceRoomsPage();
Widget _allotment(BuildContext c) => const AllotmentPage();

Widget _mess(BuildContext c) => const MessPage();
Widget _requests(BuildContext c) => const RequestsPage();
Widget _notices(BuildContext c) => const NoticesPage();
Widget _fines(BuildContext c) => const FinesPage();
Widget _fees(BuildContext c) => const FeesPage();
Widget _officeOrders(BuildContext c) => const OfficeOrdersPage();
Widget _settings(BuildContext c) => const SettingsPage();
Widget _audit(BuildContext c) => const AuditPage();
