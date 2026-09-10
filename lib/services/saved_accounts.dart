import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// One remembered sign-in, shown as a card on the login screen.
class SavedAccount {
  /// What was typed into the identifier field — email or registration number.
  final String identifier;

  /// Display name from the profile, so the card reads "Pravjeet" rather than
  /// a registration number. Falls back to the identifier when unknown.
  final String? name;

  /// Whether a password is in the keychain for this account. Kept as a flag
  /// so the login screen can render "one-click" vs "type your password"
  /// without unlocking the keychain on every build.
  final bool hasPassword;

  final DateTime lastUsed;

  const SavedAccount({
    required this.identifier,
    required this.lastUsed,
    this.name,
    this.hasPassword = false,
  });

  factory SavedAccount.fromJson(Map<String, dynamic> j) => SavedAccount(
    identifier: j['identifier'] as String,
    name: j['name'] as String?,
    hasPassword: j['hasPassword'] as bool? ?? false,
    lastUsed:
        DateTime.tryParse(j['lastUsed'] as String? ?? '') ?? DateTime.now(),
  );

  Map<String, dynamic> toJson() => {
    'identifier': identifier,
    'name': name,
    'hasPassword': hasPassword,
    'lastUsed': lastUsed.toIso8601String(),
  };

  String get display => (name != null && name!.trim().isNotEmpty)
      ? name!.trim()
      : identifier;

  String get initials {
    final source = display.trim();
    if (source.isEmpty) return '?';
    final parts = source.split(RegExp(r'[\s@._-]+')).where((p) => p.isNotEmpty);
    if (parts.isEmpty) return source[0].toUpperCase();
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts.elementAt(1)[0]).toUpperCase();
  }
}

/// Remembers who has signed in on this machine, so returning users get a
/// one-tap card instead of retyping their credentials.
///
/// Two storage tiers, deliberately:
///   * the *list* of accounts (identifier + name) — not secret, but kept in
///     secure storage anyway so there's only one thing to clear;
///   * the *password* — one entry per account under `pw:<identifier>`, which
///     the platform hands to the OS keychain: Credential Manager on Windows,
///     Keychain on macOS/iOS, EncryptedSharedPreferences on Android.
///
/// Nothing here ever writes a password to a plain file. On the web, where
/// there is no OS keychain, [passwordsSupported] is false and the screen
/// falls back to remembering the identifier only.
class SavedAccounts {
  SavedAccounts._();
  static final SavedAccounts instance = SavedAccounts._();

  static const _listKey = 'saved_accounts_v1';

  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// Browsers have no OS keychain — flutter_secure_storage falls back to
  /// plain `window.localStorage` there, which is not a safe place for a
  /// password. So on web we remember the identifier and nothing more.
  bool get passwordsSupported => !kIsWeb;

  // ------------------------------ read ------------------------------

  /// Most recently used first. Never throws — a corrupt or unreadable store
  /// degrades to "no saved accounts" rather than blocking the login screen.
  Future<List<SavedAccount>> all() async {
    try {
      final raw = await _storage.read(key: _listKey);
      if (raw == null || raw.isEmpty) return const [];
      final list = (jsonDecode(raw) as List)
          .map((e) => SavedAccount.fromJson(e as Map<String, dynamic>))
          .toList();
      list.sort((a, b) => b.lastUsed.compareTo(a.lastUsed));
      return list;
    } catch (_) {
      return const [];
    }
  }

  Future<String?> passwordFor(String identifier) async {
    try {
      return await _storage.read(key: _pwKey(identifier));
    } catch (_) {
      return null;
    }
  }

  // ------------------------------ write ------------------------------

  /// Records a successful sign-in. Pass [password] only when the user ticked
  /// "remember me" — passing null removes any previously stored password,
  /// so unticking the box on a later login actually forgets it.
  Future<void> remember({
    required String identifier,
    String? name,
    String? password,
  }) async {
    try {
      final id = identifier.trim();
      if (id.isEmpty) return;

      if (password != null && password.isNotEmpty) {
        await _storage.write(key: _pwKey(id), value: password);
      } else {
        await _storage.delete(key: _pwKey(id));
      }

      final existing = await all();
      final next = [
        SavedAccount(
          identifier: id,
          name: name,
          hasPassword: password != null && password.isNotEmpty,
          lastUsed: DateTime.now(),
        ),
        ...existing.where(
          (a) => a.identifier.toLowerCase() != id.toLowerCase(),
        ),
      ];
      // Five is plenty for a shared office machine and keeps the card list
      // from turning into a scroll.
      await _write(next.take(5).toList());
    } catch (_) {
      // Remembering is a convenience — never let it fail a sign-in.
    }
  }

  /// Drops one account and its stored password.
  Future<void> forget(String identifier) async {
    try {
      await _storage.delete(key: _pwKey(identifier));
      final rest = (await all())
          .where(
            (a) => a.identifier.toLowerCase() != identifier.toLowerCase(),
          )
          .toList();
      await _write(rest);
    } catch (_) {}
  }

  /// Drops every saved account and password on this machine.
  Future<void> forgetAll() async {
    try {
      for (final a in await all()) {
        await _storage.delete(key: _pwKey(a.identifier));
      }
      await _storage.delete(key: _listKey);
    } catch (_) {}
  }

  Future<void> _write(List<SavedAccount> accounts) => _storage.write(
    key: _listKey,
    value: jsonEncode(accounts.map((a) => a.toJson()).toList()),
  );

  static String _pwKey(String identifier) => 'pw:${identifier.toLowerCase()}';
}
