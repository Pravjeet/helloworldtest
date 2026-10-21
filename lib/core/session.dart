import 'package:flutter/widgets.dart';

import '../models/app_role.dart';
import '../models/app_user.dart';
import '../models/college_settings.dart';
import 'permissions.dart';

/// Everything the UI needs to know about "who is looking at this screen".
///
/// Exposed through an [InheritedWidget] so any widget can call
/// `Session.of(context).can(Perm.usersEdit)` without prop-drilling and
/// without pulling in a state-management package.
@immutable
class Session {
  final AppUser user;
  final AppRole? role;
  final String collegeName;

  /// Workspace configuration. Defaults so any screen can read it without a
  /// null check, and so a workspace that has never opened System Settings
  /// behaves exactly like one that has.
  final CollegeSettings settings;

  /// A past session this person is *looking at*, or null for the live one.
  ///
  /// Deliberately not the same thing as `settings.session.current`. That value
  /// is the workspace's real position in time — it is what Backfill and
  /// Promotion operate on, and it is shared by everyone signed in. This one is
  /// a private lens: it changes what you see and nothing else.
  ///
  /// Driving history browsing through System Settings instead would have wired
  /// it to the most destructive button in the app — someone reading last
  /// year's roster would have had a Promote button aimed at last year, ready
  /// to re-run a promotion that already happened. It would also have dragged
  /// every other signed-in admin back in time with them.
  final String? viewingSession;

  /// Switches the lens. Null returns to the live session.
  final void Function(String?)? onViewSession;

  /// [HostelCodes.signature] at the time this session was built. Carried only
  /// so [SessionScope] can rebuild every screen when a hostel's code changes.
  final String hostelCodes;

  const Session({
    required this.user,
    this.role,
    required this.collegeName,
    this.settings = const CollegeSettings(),
    this.viewingSession,
    this.onViewSession,
    this.hostelCodes = '',
  });

  /// The session every read-only screen should render.
  ///
  /// Write paths must keep using `settings.session.current` — allotting a bed
  /// or running a promotion always belongs to the live year, whatever the
  /// reader happens to be looking at.
  String? get effectiveSession => viewingSession ?? settings.session.current;

  /// True when looking at a session that is not the live one, which is the
  /// cue for read-only banners and for hiding actions that would write.
  bool get isViewingHistory =>
      viewingSession != null && viewingSession != settings.session.current;

  /// SuperAdmin short-circuits every check — they own the workspace.
  bool can(String permission) =>
      user.isSuperAdmin || (role?.permissions.contains(permission) ?? false);

  bool canAny(List<String> permissions) => permissions.any(can);

  /// Whether "Empty all rooms" can finish once started. It writes rooms
  /// (hostels.manage), every allotted student (users.edit or
  /// allotment.manage, after listing them with users.view) and the live
  /// session's enrollments (academic.manage, or allotment.manage limited to
  /// room fields). Checked up front, because a role missing the last of
  /// those used to empty every room and student and then be refused the
  /// enrollments — half-done, every time.
  bool get canEmptyAllRooms =>
      can(Perm.hostelsManage) &&
      can(Perm.usersView) &&
      (can(Perm.usersEdit) || can(Perm.allotmentManage)) &&
      (can(Perm.academicManage) || can(Perm.allotmentManage));

  /// A user with no role assigned yet gets a friendly holding screen instead
  /// of an empty dashboard.
  bool get hasNoAccess =>
      !user.isSuperAdmin && (role == null || role!.permissions.isEmpty);

  /// The session for this part of the tree.
  ///
  /// Throws if there is no [SessionScope] above [context]. The usual cause is
  /// calling this from inside a `showDialog` builder: a dialog is pushed onto
  /// the root Navigator, so its context is a *sibling* of the dashboard rather
  /// than a descendant, and SessionScope sits below that Navigator. Read the
  /// session in the page that opens the dialog and pass what you need in.
  static Session of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<SessionScope>();
    if (scope == null) {
      throw FlutterError(
        'Session.of() found no SessionScope above this widget.\n'
        'If this is inside a showDialog/showModalBottomSheet builder, that is '
        'expected — the dialog is a separate route and cannot see the '
        'dashboard\'s SessionScope. Read Session.of(context) in the calling '
        'page and pass the value into the dialog as a constructor argument.',
      );
    }
    return scope.session;
  }
}

class SessionScope extends InheritedWidget {
  final Session session;

  const SessionScope({super.key, required this.session, required super.child});

  @override
  bool updateShouldNotify(SessionScope oldWidget) =>
      oldWidget.session.user.uid != session.user.uid ||
      oldWidget.session.role?.permissions != session.role?.permissions ||
      oldWidget.session.user.name != session.user.name ||
      oldWidget.session.collegeName != session.collegeName ||
      oldWidget.session.settings.updatedAt != session.settings.updatedAt ||
      // Switching the lens has to rebuild everything that reads it, which is
      // most of the app — the whole point is that the dashboard, hostels and
      // rooms all move together.
      oldWidget.session.viewingSession != session.viewingSession ||
      oldWidget.session.hostelCodes != session.hostelCodes;
}

/// Convenience for reading permissions inline in build methods.
extension SessionContext on BuildContext {
  Session get session => Session.of(this);
  bool can(String permission) => Session.of(this).can(permission);
}
