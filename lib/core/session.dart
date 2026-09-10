import 'package:flutter/widgets.dart';

import '../models/app_role.dart';
import '../models/app_user.dart';
import '../models/college_settings.dart';

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

  const Session({
    required this.user,
    this.role,
    required this.collegeName,
    this.settings = const CollegeSettings(),
  });

  /// SuperAdmin short-circuits every check — they own the workspace.
  bool can(String permission) =>
      user.isSuperAdmin || (role?.permissions.contains(permission) ?? false);

  bool canAny(List<String> permissions) => permissions.any(can);

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
    final scope = context
        .dependOnInheritedWidgetOfExactType<SessionScope>();
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

  const SessionScope({
    super.key,
    required this.session,
    required super.child,
  });

  @override
  bool updateShouldNotify(SessionScope oldWidget) =>
      oldWidget.session.user.uid != session.user.uid ||
      oldWidget.session.role?.permissions != session.role?.permissions ||
      oldWidget.session.user.name != session.user.name ||
      oldWidget.session.collegeName != session.collegeName ||
      oldWidget.session.settings.updatedAt != session.settings.updatedAt;
}

/// Convenience for reading permissions inline in build methods.
extension SessionContext on BuildContext {
  Session get session => Session.of(this);
  bool can(String permission) => Session.of(this).can(permission);
}
