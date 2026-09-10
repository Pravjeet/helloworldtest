import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../core/identity.dart';
import '../core/session.dart';
import '../core/theme.dart';
import '../models/app_role.dart';
import '../models/app_user.dart';
import '../models/college_settings.dart';
import '../services/auth_service.dart';
import '../services/data_service.dart';
import '../services/settings_service.dart';
import '../services/theme_cache.dart';
import 'dashboard_shell.dart';
import 'login_screen.dart';

/// The real front door.
///
/// Your previous "auth gate" was a menu screen — it never checked whether
/// somebody was already signed in, so a restart dumped a logged-in user back
/// at the login form. This one listens to [authStateChanges], which means:
/// sessions persist across restarts, and `signOut()` anywhere in the app
/// automatically returns to the login screen with no navigation code.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: AuthService.instance.authStateChanges,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const _Loading('Checking your session…');
        }
        final user = snapshot.data;
        if (user == null) return const LoginScreen();
        return _SessionLoader(authUser: user);
      },
    );
  }
}

/// Loads profile → role → college name, then hands a [Session] to the shell.
class _SessionLoader extends StatelessWidget {
  final User authUser;
  const _SessionLoader({required this.authUser});

  /// Catches up the Firestore profile after a sign-in email change.
  ///
  /// `verifyBeforeUpdateEmail` only takes effect once the confirmation link
  /// is clicked, at which point the *next* sign-in carries the new address on
  /// [authUser] while the Firestore profile still has the old one. This
  /// reconciles them rather than leaving the profile permanently stale.
  void _syncEmail(AppUser profile) {
    final authEmail = authUser.email;
    if (authEmail == null || authEmail.isEmpty) return;
    if (authEmail == profile.email) return;
    if (Identity.isSynthetic(profile.email)) return;
    DataService.instance.updateUser(profile.uid, {'email': authEmail});
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AppUser?>(
      stream: AuthService.instance.watchProfile(authUser.uid),
      builder: (context, profileSnap) {
        if (profileSnap.hasError) {
          return _Failure(
            message: AuthService.describeError(profileSnap.error!),
          );
        }
        if (!profileSnap.hasData &&
            profileSnap.connectionState == ConnectionState.waiting) {
          return const _Loading('Loading your workspace…');
        }

        final profile = profileSnap.data;
        if (profile == null) {
          return const _Failure(
            message:
                'Your account exists but has no profile in this workspace. '
                'Ask your administrator to add you again.',
          );
        }
        _syncEmail(profile);
        if (!profile.isActive) {
          return const _Failure(
            message:
                'Your account has been deactivated. '
                'Please contact your hostel administrator.',
          );
        }

        // No role assigned yet — nothing to load, show the holding screen.
        if (profile.roleId == null) {
          return _NoAccess(name: profile.name);
        }

        return StreamBuilder<AppRole?>(
          stream: AuthService.instance.watchRole(
            profile.collegeId,
            profile.roleId!,
          ),
          builder: (context, roleSnap) {
            if (roleSnap.connectionState == ConnectionState.waiting) {
              return const _Loading('Loading your workspace…');
            }
            final role = roleSnap.data;
            if (!profile.isSuperAdmin &&
                (role == null || role.permissions.isEmpty)) {
              return _NoAccess(name: profile.name);
            }

            return StreamBuilder<String>(
              stream: AuthService.instance.watchCollegeName(profile.collegeId),
              builder: (context, nameSnap) {
                return StreamBuilder<CollegeSettings>(
                  stream: SettingsService.instance.watch(profile.collegeId),
                  builder: (context, settingsSnap) {
                    final settings =
                        settingsSnap.data ?? const CollegeSettings();
                    // Mirrors this workspace's real theme locally, so next
                    // time the app opens — including the login screen, before
                    // anyone has signed in — it starts on this instead of the
                    // hardcoded default. See ThemeCache and the apply() call
                    // in main().
                    if (settingsSnap.hasData) {
                      ThemeCache.instance.write(settings.theming);
                    }
                    final dark = settings.theming.brightness.isDark(
                      MediaQuery.platformBrightnessOf(context),
                    );

                    return SessionScope(
                      session: Session(
                        user: profile,
                        role: role,
                        collegeName: nameSnap.data ?? 'Institution',
                        settings: settings,
                      ),
                      // Applied here rather than at MaterialApp, because the
                      // palette lives in the workspace's settings and there is
                      // no workspace until someone has signed in.
                      //
                      // PaletteScope must wrap the Theme: it rewrites the
                      // AppColors tokens that buildAppTheme then reads.
                      child: PaletteScope(
                        accent: settings.theming.seed,
                        dark: dark,
                        child: Builder(
                          builder: (context) => Theme(
                            data: buildAppTheme(
                              seed: settings.theming.seed,
                              dark: dark,
                            ),
                            child: const DashboardShell(),
                          ),
                        ),
                      ),
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

class _Loading extends StatelessWidget {
  final String message;
  const _Loading(this.message);

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppColors.canvas,
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            height: 34,
            width: 34,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          const SizedBox(height: 18),
          Text(
            message,
            style: TextStyle(color: AppColors.textMuted, fontSize: 14),
          ),
        ],
      ),
    ),
  );
}

class _Failure extends StatelessWidget {
  final String message;
  const _Failure({required this.message});

  @override
  Widget build(BuildContext context) => _Centered(
    icon: Icons.error_outline_rounded,
    iconColor: AppColors.danger,
    title: 'We couldn\'t open your workspace',
    body: message,
    actionLabel: 'Back to sign in',
    onAction: AuthService.instance.signOut,
  );
}

class _NoAccess extends StatelessWidget {
  final String name;
  const _NoAccess({required this.name});

  @override
  Widget build(BuildContext context) => _Centered(
    icon: Icons.hourglass_top_rounded,
    iconColor: AppColors.warning,
    title: 'Hi $name — you\'re almost set up',
    body:
        'Your account is active but no role has been assigned to it yet, so '
        'there\'s nothing to show. Your administrator needs to give you a '
        'role. This screen will update by itself the moment they do.',
    actionLabel: 'Sign out',
    onAction: AuthService.instance.signOut,
  );
}

class _Centered extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String body;
  final String actionLabel;
  final VoidCallback onAction;

  const _Centered({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.body,
    required this.actionLabel,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppColors.canvas,
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: AppCard(
          padding: const EdgeInsets.all(34),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 48, color: iconColor),
              const SizedBox(height: 18),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                body,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 14,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 24),
              OutlinedButton(onPressed: onAction, child: Text(actionLabel)),
            ],
          ),
        ),
      ),
    ),
  );
}
