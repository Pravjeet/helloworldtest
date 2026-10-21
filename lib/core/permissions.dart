/// Central permission catalogue.
///
/// A permission is a plain string `"<module>.<action>"`. A Role owns a
/// `Set<String>` of them. Everything in the UI (sidebar entries, buttons,
/// pages) asks `session.can(Perm.xxx)` instead of comparing role *names*.
/// This is what lets you invent a brand new role like "Hostel Manager"
/// without touching a single `if (role == ...)` in the codebase.
library;

class Perm {
  // Users
  static const usersView = 'users.view';
  static const usersCreate = 'users.create';
  static const usersEdit = 'users.edit';
  static const usersDelete = 'users.delete';

  // Roles & permissions
  static const rolesView = 'roles.view';
  static const rolesManage = 'roles.manage';

  // Hostels / rooms
  static const hostelsView = 'hostels.view';
  static const hostelsManage = 'hostels.manage';
  static const allotmentManage = 'allotment.manage';

  // Mess
  static const messView = 'mess.view';
  static const messManage = 'mess.manage';

  // Requests (leave / maintenance / other)
  static const requestsViewOwn = 'requests.viewOwn';
  static const requestsViewAll = 'requests.viewAll';
  static const requestsApprove = 'requests.approve';
  static const requestsCreate = 'requests.create';

  // Fines
  static const finesViewOwn = 'fines.viewOwn';
  static const finesViewAll = 'fines.viewAll';
  static const finesManage = 'fines.manage';

  // Office orders
  static const officeOrdersView = 'officeOrders.view';
  static const officeOrdersManage = 'officeOrders.manage';

  // Academic records (enrollments, promotion)
  static const academicView = 'academic.view';
  static const academicManage = 'academic.manage';

  // Mess fees (status only — the app never takes money)
  static const feesViewOwn = 'fees.viewOwn';
  static const feesViewAll = 'fees.viewAll';
  static const feesManage = 'fees.manage';

  // Notices
  static const noticesView = 'notices.view';
  static const noticesManage = 'notices.manage';

  // Student self-service
  static const selfRoom = 'self.room';

  // Settings
  static const settingsManage = 'settings.manage';

  /// Grouped for the permission-picker UI.
  static const Map<String, List<PermissionDef>> catalogue = {
    'User Management': [
      PermissionDef(usersView, 'View users', 'See the user directory'),
      PermissionDef(usersCreate, 'Create users', 'Add new accounts'),
      PermissionDef(usersEdit, 'Edit users', 'Change details and roles'),
      PermissionDef(usersDelete, 'Delete users', 'Remove accounts'),
    ],
    'Roles & Permissions': [
      PermissionDef(rolesView, 'View roles', 'See roles and their access'),
      PermissionDef(rolesManage, 'Manage roles', 'Create, edit, delete roles'),
    ],
    'Hostel & Rooms': [
      PermissionDef(hostelsView, 'View hostels', 'See blocks and rooms'),
      PermissionDef(hostelsManage, 'Manage hostels', 'Add/edit blocks, rooms'),
      PermissionDef(allotmentManage, 'Room allotment', 'Assign students'),
    ],
    'Mess': [
      PermissionDef(messView, 'View mess', 'Menu, wallet, transactions'),
      PermissionDef(messManage, 'Manage mess', 'Edit menu and wallets'),
    ],
    'Requests': [
      PermissionDef(requestsCreate, 'Raise requests', 'Submit own requests'),
      PermissionDef(requestsViewOwn, 'View own requests', 'Track own requests'),
      PermissionDef(requestsViewAll, 'View all requests', 'See everyone\'s'),
      PermissionDef(requestsApprove, 'Approve requests', 'Approve or reject'),
    ],
    'Fines': [
      PermissionDef(finesViewOwn, 'View own fines', 'See fines raised on you'),
      PermissionDef(
        finesViewAll,
        'View all fines',
        'Fines dashboard and roster',
      ),
      PermissionDef(finesManage, 'Manage fines', 'Impose, waive and mark paid'),
    ],
    'Office Orders': [
      PermissionDef(
        officeOrdersView,
        'View office orders',
        'Read issued orders',
      ),
      PermissionDef(
        officeOrdersManage,
        'Manage office orders',
        'Publish orders',
      ),
    ],
    'Academic Records': [
      PermissionDef(
        academicView,
        'View enrollments',
        'See session rosters and year-wise lists',
      ),
      PermissionDef(
        academicManage,
        'Manage academic records',
        'Backfill and run annual promotion',
      ),
    ],
    'Mess Fees': [
      PermissionDef(feesViewOwn, 'View own fee status', 'See if you have paid'),
      PermissionDef(
        feesViewAll,
        'View all fee status',
        'Month-by-month roster',
      ),
      PermissionDef(feesManage, 'Record fee status', 'Mark students paid'),
    ],
    'Notices': [
      PermissionDef(noticesView, 'View notices', 'Read announcements'),
      PermissionDef(noticesManage, 'Manage notices', 'Publish announcements'),
    ],
    'Student Self-Service': [
      PermissionDef(selfRoom, 'My room', 'View own room and roommates'),
    ],
    'System': [
      PermissionDef(settingsManage, 'System settings', 'Institution settings'),
    ],
  };

  static List<String> get all =>
      catalogue.values.expand((l) => l).map((p) => p.key).toList();

  /// True for a role whose job is hostel/room operations — Chief Warden,
  /// Warden, Caretaker, BHS in the starter templates, and anything a
  /// SuperAdmin builds later that grants the same access.
  ///
  /// Deliberately a permission check, not a role-name check — a custom role
  /// called "Block Supervisor" with [hostelsManage] gets the same treatment
  /// as one literally named "Caretaker". This is what the user-creation form
  /// asks to decide whether to show student academic fields or a "hostels
  /// managed" picker.
  static bool managesHostels(Set<String> perms) =>
      perms.contains(hostelsManage) || perms.contains(allotmentManage);

  /// True for a role that lives in the hostel rather than runs it.
  ///
  /// Staff always hold at least one permission that reaches beyond themselves:
  /// something that manages a module, reads everyone's records, or opens the
  /// user directory. A resident holds only self-service permissions — their
  /// own fines, their own requests, their own room.
  ///
  /// Tested this way round on purpose. Whitelisting "student permissions"
  /// would misfile every new self-service permission added later as staff;
  /// this errs the safe way instead, treating anything with reach as staff.
  /// It is also why the check is not [managesHostels]: a Mess Manager or an
  /// Accountant runs nothing hostel-shaped, but is emphatically not a student
  /// and should not be asked for a guardian's phone number.
  ///
  /// Drives which form the user-creation dialog shows.
  static bool isResident(Set<String> perms) => !perms.any(
    (p) =>
        p.endsWith('.manage') ||
        p.endsWith('.viewAll') ||
        p.endsWith('.create') && p != requestsCreate ||
        p == usersView ||
        p == usersEdit ||
        p == hostelsView,
  );
}

class PermissionDef {
  final String key;
  final String label;
  final String description;
  const PermissionDef(this.key, this.label, this.description);
}

/// Starter role templates offered to the SuperAdmin. These are *suggestions*
/// written into Firestore once; the admin can freely edit them afterwards.
const Map<String, List<String>> kRoleTemplates = {
  'Chief Warden': [
    Perm.usersView,
    Perm.usersCreate,
    Perm.usersEdit,
    Perm.hostelsView,
    Perm.hostelsManage,
    Perm.allotmentManage,
    Perm.messView,
    Perm.messManage,
    Perm.requestsViewAll,
    Perm.requestsApprove,
    Perm.finesViewAll,
    Perm.finesManage,
    Perm.officeOrdersView,
    Perm.officeOrdersManage,
    Perm.academicView,
    Perm.academicManage,
    Perm.feesViewAll,
    Perm.feesManage,
    Perm.noticesView,
    Perm.noticesManage,
  ],
  'Warden': [
    Perm.usersView,
    Perm.hostelsView,
    Perm.allotmentManage,
    Perm.messView,
    Perm.requestsViewAll,
    Perm.requestsApprove,
    Perm.finesViewAll,
    Perm.finesManage,
    Perm.officeOrdersView,
    Perm.feesViewAll,
    Perm.feesManage,
    Perm.noticesView,
  ],
  'Caretaker': [
    Perm.usersView,
    Perm.hostelsView,
    Perm.hostelsManage,
    Perm.messView,
    Perm.messManage,
    Perm.requestsViewAll,
    Perm.finesViewAll,
    Perm.finesManage,
    Perm.officeOrdersView,
    Perm.officeOrdersManage,
    Perm.feesViewAll,
    Perm.feesManage,
    Perm.noticesView,
  ],

  /// Reports to the Caretaker — day-to-day room/allotment work on the ground,
  /// without the user-management, mess, fees or office-order authority a
  /// Caretaker has.
  'BHS': [
    Perm.hostelsView,
    Perm.hostelsManage,
    Perm.allotmentManage,
    Perm.requestsViewAll,
    Perm.noticesView,
  ],
  'Student': [
    Perm.selfRoom,
    Perm.messView,
    Perm.noticesView,
    Perm.requestsCreate,
    Perm.requestsViewOwn,
    Perm.finesViewOwn,
    Perm.officeOrdersView,
    Perm.feesViewOwn,
  ],
};
