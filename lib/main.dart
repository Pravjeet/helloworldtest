import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'core/theme.dart';
import 'firebase_options.dart';
import 'models/college_settings.dart' show AppBrightnessX;
import 'screens/auth_gate.dart';
import 'services/theme_cache.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Guard the init so a misconfigured firebase_options file produces a
  // readable screen instead of a blank one.
  Object? startupError;
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (e) {
    startupError = e;
  }

  // Apply the workspace's last-known theme before the first frame, so the
  // login screen matches instead of showing the hardcoded default. AuthGate
  // re-applies the authoritative copy from Firestore the moment it loads
  // (see PaletteScope in auth_gate.dart) and refreshes this cache for next
  // time.
  final cachedTheme = await ThemeCache.instance.read();
  AppColors.apply(
    accent: cachedTheme.seed,
    dark: cachedTheme.brightness.isDark(
      WidgetsBinding.instance.platformDispatcher.platformBrightness,
    ),
  );

  runApp(HostelApp(startupError: startupError));
}

class HostelApp extends StatelessWidget {
  final Object? startupError;
  const HostelApp({super.key, this.startupError});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Homi Hostel',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: startupError == null
          ? const AuthGate()
          : _StartupError(error: startupError!),
    );
  }
}

class _StartupError extends StatelessWidget {
  final Object error;
  const _StartupError({required this.error});

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppColors.canvas,
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: AppCard(
          padding: const EdgeInsets.all(30),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off_rounded,
                size: 44,
                color: AppColors.danger,
              ),
              const SizedBox(height: 16),
              const Text(
                'Could not connect to Firebase',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              Text(
                '$error',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
