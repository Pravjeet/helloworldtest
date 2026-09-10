/// How a person identifies themselves at the login screen.
///
/// Firebase Auth has no "username" provider — it authenticates against an
/// email address. To let students sign in with just a registration number we
/// map that number onto a synthetic address behind the scenes:
///
///     2040353  ->  2040353@homihostel.local
///
/// The student never sees or types the domain. Staff keep real addresses and
/// are unaffected.
///
/// The trade-off, stated plainly: a synthetic address has no inbox, so
/// Firebase's password-reset email can never reach a student. Resetting a
/// student's password is therefore an admin action, not a self-service one.
/// Anyone signing in with a real email keeps working resets.
library;

/// Non-routable on purpose — nothing should ever try to deliver mail here.
const String kSyntheticEmailDomain = 'homihostel.local';

class Identity {
  /// True when the user typed something that looks like an email address
  /// rather than a registration number.
  static bool looksLikeEmail(String input) => input.contains('@');

  /// Turns whatever was typed into the address Firebase expects.
  static String toAuthEmail(String input) {
    final v = input.trim().toLowerCase();
    if (v.isEmpty) return v;
    return looksLikeEmail(v) ? v : '$v@$kSyntheticEmailDomain';
  }

  /// True if this stored address is a synthetic one we generated.
  static bool isSynthetic(String email) =>
      email.toLowerCase().endsWith('@$kSyntheticEmailDomain');

  /// What to show a user in the UI: the registration number for synthetic
  /// addresses, the address itself otherwise.
  static String display(String email) =>
      isSynthetic(email) ? email.split('@').first : email;

  /// A registration number is usable as a login id only if it survives the
  /// round trip into an email local-part.
  static bool isValidRegistrationNumber(String v) =>
      RegExp(r'^[A-Za-z0-9._-]{3,}$').hasMatch(v.trim());

  /// Starting password for a bulk-imported student.
  ///
  /// Derived from the registration number so you can sign in as any test
  /// student without keeping a list. Firebase requires 6 characters, so short
  /// numbers get padded.
  static String derivedPassword(String registrationNumber) {
    final v = registrationNumber.trim();
    return v.length >= 6 ? v : v.padRight(6, '0');
  }
}
