import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../core/hostel_codes.dart';
import '../core/identity.dart';
import '../core/permissions.dart';
import '../core/session.dart';
import '../core/theme.dart';
import '../models/app_role.dart';
import '../models/app_user.dart';
import '../models/college_settings.dart';
import '../models/hostel.dart';
import '../services/auth_service.dart';
import '../services/data_service.dart';
import '../services/default_hostels.dart';
import '../services/enrollment_service.dart';
import '../services/hostel_service.dart';
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
class _SessionLoader extends StatefulWidget {
  final User authUser;
  const _SessionLoader({required this.authUser});

  @override
  State<_SessionLoader> createState() => _SessionLoaderState();
}

class _SessionLoaderState extends State<_SessionLoader> {
  User get authUser => widget.authUser;

  /// The past session being viewed, or null for the live one.
  ///
  /// Held here rather than in Firestore on purpose: it is one person's lens,
  /// not workspace configuration, so it must not follow them onto another
  /// machine or drag other signed-in admins along with it. It resets to the
  /// live session on every sign-in, which is the right default — you should
  /// have to ask to be looking at the past.
  String? _viewing;

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
        if (profile.isActive && profile.isSuperAdmin) {
          DefaultHostels.instance.seedIfNeeded(profile.collegeId);
        }
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

                    // Hostel codes for every screen (see HostelCodes). Only
                    // for accounts the rules let read hostels — a student's
                    // read would be refused, and they fall back to names.
                    final canSeeHostels =
                        profile.isSuperAdmin ||
                        (role?.permissions.contains(Perm.hostelsView) ?? false);

                    return StreamBuilder<List<Hostel>>(
                      stream: canSeeHostels
                          ? HostelService.instance.watchHostels(
                              profile.collegeId,
                            )
                          : const Stream<List<Hostel>>.empty(),
                      builder: (context, hostelSnap) {
                        // Waited for once, so no screen draws a hostel's full
                        // name and then flips to its code a moment later.
                        if (canSeeHostels &&
                            !hostelSnap.hasData &&
                            !hostelSnap.hasError) {
                          return const _Loading('Loading your workspace…');
                        }
                        if (hostelSnap.hasData) {
                          HostelCodes.update(hostelSnap.data!);
                        }

                        return SessionScope(
                          session: Session(
                            user: profile,
                            role: role,
                            collegeName: nameSnap.data ?? 'Institution',
                            settings: settings,
                            // Ignored once it matches the live session again, so
                            // returning to "now" clears the lens rather than
                            // pinning it to a value that will go stale in July.
                            viewingSession: _viewing == settings.session.current
                                ? null
                                : _viewing,
                            onViewSession: (s) => setState(() => _viewing = s),
                            hostelCodes: HostelCodes.signature,
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
                                child: const _HistoryChooserGate(
                                  child: DashboardShell(),
                                ),
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

/// Offers a batch/session chooser once per sign-in, for whoever holds
/// `academic.view` or `academic.manage` and has more than one session's
/// worth of history to choose between.
///
/// This is the entry point asked for at login — the header pill (see
/// [dashboard_shell.dart]) stays available afterwards for switching again.
/// Both call the same [Session.onViewSession]; this is only where the choice
/// is first offered.
class _HistoryChooserGate extends StatefulWidget {
  final Widget child;
  const _HistoryChooserGate({required this.child});

  @override
  State<_HistoryChooserGate> createState() => _HistoryChooserGateState();
}

class _HistoryChooserGateState extends State<_HistoryChooserGate> {
  /// A field, not a static — this widget is recreated (with a fresh `false`)
  /// every time [_SessionLoader] is, which is exactly on sign-in. Flutter
  /// preserves State across the ordinary rebuilds this screen goes through
  /// as its four StreamBuilders resolve, so this stays `true` across those
  /// and the dialog is offered exactly once per session, not once per frame.
  bool _offered = false;

  @override
  Widget build(BuildContext context) {
    if (!_offered) {
      _offered = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeOffer());
    }
    return widget.child;
  }

  Future<void> _maybeOffer() async {
    if (!mounted) return;
    // Read here, before showDialog — a dialog is pushed onto the root
    // Navigator and cannot see SessionScope; see the note on [Session.of].
    final session = Session.of(context);
    final onViewSession = session.onViewSession;
    if (!session.canAny([Perm.academicView, Perm.academicManage])) return;
    final current = session.settings.session.current;
    if (current == null || onViewSession == null) return;

    final sessions = await EnrollmentService.instance.sessionsWithData(
      session.user.collegeId,
      current,
    );
    // A chooser offering one option is not a choice — nothing to ask.
    if (!mounted || sessions.length < 2) return;

    final chosen = await showDialog<String>(
      context: context,
      builder: (_) =>
          _SessionChooserDialog(sessions: sessions, current: current),
    );
    if (chosen != null && chosen != current) onViewSession(chosen);
  }
}

class _SessionChooserDialog extends StatelessWidget {
  final List<String> sessions;
  final String current;

  const _SessionChooserDialog({required this.sessions, required this.current});

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Which session?'),
    content: SizedBox(
      width: 380,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'The Dashboard and Hostels & Rooms can show any past session as '
            'it stood that year. Pick one, or stay on the current session — '
            'you can always switch later from the pill next to the bell.',
            style: TextStyle(
              fontSize: 12.5,
              height: 1.45,
              color: AppColors.textMuted,
            ),
          ),
          const SizedBox(height: 16),
          // A plain tappable row rather than RadioListTile: this dialog
          // commits on the first tap, so there is no group selection state
          // to manage — only "current" needs to read as pre-highlighted.
          for (final s in sessions)
            InkWell(
              onTap: () => Navigator.pop(context, s),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
                child: Row(
                  children: [
                    Icon(
                      s == current
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_unchecked_rounded,
                      size: 18,
                      color: s == current
                          ? AppColors.primary
                          : AppColors.textMuted,
                    ),
                    const SizedBox(width: 12),
                    Text(s, style: const TextStyle(fontSize: 13.5)),
                    if (s == current) ...[
                      const SizedBox(width: 8),
                      Text(
                        '· current',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, current),
        child: const Text('Continue with current'),
      ),
    ],
  );
}
