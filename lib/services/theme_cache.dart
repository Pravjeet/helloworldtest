import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/college_settings.dart';

/// Remembers the last-applied theme on this device.
///
/// The authoritative copy always lives in the signed-in workspace's Firestore
/// settings — nothing can read that before login, because which college it
/// even is isn't known yet. This is a device-local mirror of it: written every
/// time [AuthGate] loads the real settings, and read once at startup so the
/// login screen matches instead of falling back to the hardcoded default.
class ThemeCache {
  ThemeCache._();
  static final ThemeCache instance = ThemeCache._();

  static const _key = 'last_theme_v1';

  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// Never throws — a corrupt or unreadable entry degrades to the built-in
  /// default rather than blocking startup.
  Future<AppTheming> read() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null || raw.isEmpty) return const AppTheming();
      return AppTheming.fromMap(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const AppTheming();
    }
  }

  /// Caching is a convenience — never let it fail the real settings load.
  Future<void> write(AppTheming theming) async {
    try {
      await _storage.write(key: _key, value: jsonEncode(theming.toMap()));
    } catch (_) {}
  }
}
