import 'package:flutter/material.dart';

import '../../core/permissions.dart';
import '../../core/session.dart';
import 'admin_home.dart';
import 'student_home.dart';

/// The landing page — a router, nothing more.
///
/// Staff and residents open this to answer genuinely different questions:
/// institution-wide status versus "where do I live, what do I owe, what's for
/// dinner". Those share almost no content, so each side gets a page built for
/// it rather than one widget tree of mutually-exclusive blocks.
///
/// The test is `users.view` — the permission meaning "you look after other
/// people" — not a role name.
class OverviewPage extends StatelessWidget {
  const OverviewPage({super.key});

  @override
  Widget build(BuildContext context) {
    final session = Session.of(context);
    return session.can(Perm.usersView)
        ? const AdminHome()
        : const StudentHome();
  }
}
