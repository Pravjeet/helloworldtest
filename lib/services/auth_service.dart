import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

import '../core/hostel_codes.dart';
import '../core/identity.dart';
import '../core/permissions.dart';
import '../models/app_role.dart';
import '../models/app_user.dart';
import '../utils/web_update.dart';
import 'office_order_service.dart';
import 'photo_service.dart';
import 'stream_cache.dart';

/// All authentication + provisioning logic. Widgets never touch
/// FirebaseAuth/Firestore directly.
class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Stream<User?> get authStateChanges => _auth.authStateChanges();
  User? get currentUser => _auth.currentUser;

  // ---------------------------------------------------------------------
  // Registration: creates the college workspace + its SuperAdmin.
  // ---------------------------------------------------------------------
  Future<void> registerCollege({
    required String institutionName,
    required String adminName,
    required String email,
    required String password,
  }) async {
    // Registration signs the new owner in, so it needs the same safe default
    // as [signIn] — without this it would inherit Firebase's web default of
    // LOCAL and quietly outlive the browser on a machine nobody chose that
    // for. There is no tick box on the registration form; a workspace owner
    // can opt in next time they sign in.
    if (kIsWeb) {
      await _auth.setPersistence(Persistence.SESSION);
    }

    final cred = await _auth.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    final user = cred.user;
    if (user == null) {
      throw AuthFailure('Account could not be created. Please try again.');
    }

    await user.updateDisplayName(adminName.trim());

    final slug = institutionName
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    final collegeId =
        '${slug.isEmpty ? 'college' : slug}-'
        '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';

    final batch = _db.batch();
    final collegeRef = _db.collection('colleges').doc(collegeId);

    batch.set(collegeRef, {
      'name': institutionName.trim(),
      'ownerUid': user.uid,
      'createdAt': FieldValue.serverTimestamp(),
    });

    // The one system role. It implicitly holds every permission; we still
    // write them out so the Roles screen can display it honestly.
    batch.set(collegeRef.collection('roles').doc('super-admin'), {
      'name': 'Super Admin',
      'description': 'Full access to everything. Cannot be edited or deleted.',
      'permissions': Perm.all,
      'isSystem': true,
      'createdAt': FieldValue.serverTimestamp(),
    });

    // Starter roles so the admin isn't staring at an empty screen.
    kRoleTemplates.forEach((name, perms) {
      final id = name.toLowerCase().replaceAll(' ', '-');
      batch.set(collegeRef.collection('roles').doc(id), {
        'name': name,
        'description': 'Starter template — edit the permissions to taste.',
        'permissions': perms,
        'isSystem': false,
        'createdAt': FieldValue.serverTimestamp(),
      });
    });

    batch.set(_db.collection('users').doc(user.uid), {
      'uid': user.uid,
      'name': adminName.trim(),
      'email': email.trim(),
      'collegeId': collegeId,
      'roleId': 'super-admin',
      'roleName': 'Super Admin',
      'isSuperAdmin': true,
      'isActive': true,
      'createdAt': FieldValue.serverTimestamp(),
    });

    await batch.commit();
  }

  // ---------------------------------------------------------------------
  // Login
  // ---------------------------------------------------------------------
  /// [identifier] may be a real email address or a registration number —
  /// see [Identity]. The number is mapped to a synthetic address before it
  /// reaches Firebase.
  /// [staySignedIn] chooses how long the credential outlives this tab, and is
  /// the whole of the "keep me signed in" decision.
  ///
  /// The default is deliberately the *safe* one. Firebase's web default is
  /// LOCAL — the session survives closing the browser entirely — which on the
  /// shared office machines this runs on hands the next person a live warden
  /// session. SESSION scopes the credential to the tab: close it and the next
  /// visit starts at the login screen, while an accidental F5 mid-task still
  /// keeps you signed in.
  ///
  /// Opting in is therefore per-person and per-machine, which is the only way
  /// it can be correct — the office desk and someone's own laptop want
  /// opposite answers, and the app cannot tell which it is running on.
  ///
  /// Web-only in FlutterFire; it throws on Windows and Android, where the OS
  /// account model already isolates users.
  Future<void> signIn({
    required String identifier,
    required String password,
    bool staySignedIn = false,
  }) async {
    if (kIsWeb) {
      await _auth.setPersistence(
        staySignedIn ? Persistence.LOCAL : Persistence.SESSION,
      );
    }
    await _auth.signInWithEmailAndPassword(
      email: Identity.toAuthEmail(identifier),
      password: password,
    );
    // A login screen left open across a deploy would otherwise sign the user
    // into last week's app. The session survives the reload either way.
    if (kIsWeb) await reloadIfNewVersion();
  }

  /// Signs out and drops every cached query.
  ///
  /// Order matters: the caches are closed *before* Firebase Auth drops the
  /// credential. A listener still attached when the token goes away fires a
  /// permission-denied error, which surfaces as a red error card flashing over
  /// the login screen on the way out.
  Future<void> signOut() async {
    await StreamCaches.disposeAll();
    HostelCodes.update(const []);
    PhotoService.instance.clearCache();
    OfficeOrderService.instance.clearCache();
    await _auth.signOut();
  }

  /// Only meaningful for real addresses. A synthetic one has no inbox, so we
  /// refuse rather than silently pretending to send.
  Future<void> sendPasswordReset(String identifier) async {
    final email = Identity.toAuthEmail(identifier);
    if (Identity.isSynthetic(email)) {
      throw AuthFailure(
        'Accounts that sign in with a registration number have no email '
        'inbox, so a reset link can\'t be sent. Ask your hostel administrator '
        'to set a new password for you.',
      );
    }
    await _auth.sendPasswordResetEmail(email: email);
  }

  // ---------------------------------------------------------------------
  // Changing your own sign-in email.
  //
  // The client SDK can only ever touch the *currently signed-in* account —
  // there's no "change someone else's email" call, by design. That's fine
  // here: this is a self-service action, not an admin one.
  //
  // Firebase requires a recent sign-in for a security-sensitive change like
  // this, so we reauthenticate with the current password first rather than
  // surface a confusing "requires-recent-login" error. And rather than
  // swapping the address outright, `verifyBeforeUpdateEmail` sends a
  // confirmation link to the *new* address — the Auth email only actually
  // changes once that link is clicked, which is what stops someone from
  // locking the real owner out by mistyping an address they don't control.
  // ---------------------------------------------------------------------

  /// Sends a confirmation link to [newEmail]. The signed-in account's email
  /// does not change until that link is clicked.
  Future<void> changeOwnEmail({
    required String currentPassword,
    required String newEmail,
  }) async {
    final user = _auth.currentUser;
    final currentEmail = user?.email;
    if (user == null || currentEmail == null) {
      throw AuthFailure('You need to be signed in to do that.');
    }

    try {
      await user.reauthenticateWithCredential(
        EmailAuthProvider.credential(
          email: currentEmail,
          password: currentPassword,
        ),
      );
      await user.verifyBeforeUpdateEmail(newEmail.trim());
    } on FirebaseAuthException catch (e) {
      throw AuthFailure(_friendly(e));
    }
  }

  /// Changes the signed-in user's own password.
  ///
  /// This is what lets a student move off the registration-number-derived
  /// starter password without needing an email inbox — [sendPasswordReset]
  /// can't reach a synthetic address, but this doesn't go through email at
  /// all. Requires the current password to reauthenticate first, same as
  /// [changeOwnEmail].
  Future<void> changeOwnPassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final user = _auth.currentUser;
    final currentEmail = user?.email;
    if (user == null || currentEmail == null) {
      throw AuthFailure('You need to be signed in to do that.');
    }

    try {
      await user.reauthenticateWithCredential(
        EmailAuthProvider.credential(
          email: currentEmail,
          password: currentPassword,
        ),
      );
      await user.updatePassword(newPassword);
    } on FirebaseAuthException catch (e) {
      throw AuthFailure(_friendly(e));
    }
  }

  // ---------------------------------------------------------------------
  // Session loading
  // ---------------------------------------------------------------------

  // These three sit in nested StreamBuilders at the root of AuthGate, so they
  // are re-evaluated on every rebuild of the entire app. Single documents each,
  // but the most frequently re-created streams in the codebase — and the pool
  // is what stops each rebuild from re-reading them. See [CachedStream].

  final CachedStreamPool<AppUser?> _profilePool = CachedStreamPool();
  final CachedStreamPool<AppRole?> _rolePool = CachedStreamPool();
  final CachedStreamPool<String> _collegeNamePool = CachedStreamPool();

  /// Live view of the signed-in user's profile document.
  ///
  /// Also called with other people's uids from the user detail page, hence
  /// keying by uid rather than holding a single stream.
  Stream<AppUser?> watchProfile(String uid) => _profilePool.stream(
    uid,
    () => _db
        .collection('users')
        .doc(uid)
        .snapshots()
        .map((d) => d.exists ? AppUser.fromMap(d.id, d.data()!) : null),
  );

  /// Live view of a role document, so a permission change applied by the
  /// admin reaches the affected user's sidebar without them re-logging in.
  Stream<AppRole?> watchRole(String collegeId, String roleId) =>
      _rolePool.stream(
        '$collegeId/$roleId',
        () => _db
            .collection('colleges')
            .doc(collegeId)
            .collection('roles')
            .doc(roleId)
            .snapshots()
            .map((d) => d.exists ? AppRole.fromMap(d.id, d.data()!) : null),
      );

  Future<String> collegeName(String collegeId) async {
    final doc = await _db.collection('colleges').doc(collegeId).get();
    return doc.data()?['name'] as String? ?? 'Institution';
  }

  /// Live college name, so renaming the institution in System Settings shows
  /// up in the sidebar immediately rather than after a re-login.
  Stream<String> watchCollegeName(String collegeId) => _collegeNamePool.stream(
    collegeId,
    () => _db
        .collection('colleges')
        .doc(collegeId)
        .snapshots()
        .map((d) => d.data()?['name'] as String? ?? 'Institution'),
  );

  // ---------------------------------------------------------------------
  // Creating a sub-user without kicking the admin out of their own session.
  //
  // `createUserWithEmailAndPassword` signs the *new* user in on the default
  // FirebaseAuth instance — which would log the admin out. Spinning up a
  // secondary FirebaseApp gives us an isolated auth instance to do the
  // creation in, then we throw it away.
  //
  // NOTE: this is the right pragmatic call while you have no backend. The
  // production-grade answer is a Cloud Function using the Admin SDK; move to
  // that when you can, because it also lets you delete Auth accounts.
  // ---------------------------------------------------------------------
  /// Spins up an isolated FirebaseApp for provisioning accounts.
  ///
  /// Creating one of these is expensive — on web it bootstraps a whole JS SDK
  /// app. A bulk import should open **one** and pass it to every
  /// [createSubUser] call, then [closeProvisioningApp] at the end. Doing it
  /// per row is what made a 30-row import take minutes.
  ///
  /// Named with a counter as well as the time: on web the clock only has
  /// millisecond resolution, so two apps opened together — one per lane when
  /// sign-in accounts are removed in parallel — would otherwise get the same
  /// name, and Firebase refuses a duplicate.
  Future<FirebaseApp> openProvisioningApp() => Firebase.initializeApp(
    name:
        'user-provisioning-${DateTime.now().microsecondsSinceEpoch}'
        '-${_provisioningSeq++}',
    options: Firebase.app().options,
  );

  static int _provisioningSeq = 0;

  Future<void> closeProvisioningApp(FirebaseApp app) async {
    try {
      await FirebaseAuth.instanceFor(app: app).signOut();
    } catch (_) {
      // Nothing signed in; nothing to do.
    }
    await app.delete();
  }

  // ---------------------------------------------------------------------
  // Deleting an Auth account from a browser
  //
  // Firebase's client SDK can only delete the user who is *currently signed
  // in* — there is no "delete that other account" call, by design. The
  // Admin SDK has one, but it needs a trusted environment: a Cloud Function
  // (Blaze plan) or a machine holding a service-account key.
  //
  // The trick that works on the free plan: sign in AS the account on an
  // isolated FirebaseApp, then call delete() on it. That is legitimate here
  // only because student passwords are *derived* from the registration
  // number, so the app can reconstruct them without storing anything.
  //
  // Which is also the honest limitation: the moment a student changes their
  // password we can no longer do this, and staff with real passwords were
  // never deletable this way. Those cases fall back to
  // `tools/delete-students.js`, which uses the Admin SDK properly.
  // ---------------------------------------------------------------------

  /// Attempts to remove a Firebase Auth account.
  ///
  /// [candidatePasswords] are tried in order — normally just the one derived
  /// from the registration number. Never logs or stores them.
  Future<AuthDeleteResult> deleteAuthAccount({
    required String email,
    required List<String> candidatePasswords,
    FirebaseApp? app,
  }) async {
    if (candidatePasswords.isEmpty) {
      return AuthDeleteResult.noCredential;
    }

    final owned = app == null;
    FirebaseApp? temp = app;
    try {
      temp ??= await openProvisioningApp();
      final auth = FirebaseAuth.instanceFor(app: temp);

      for (final password in candidatePasswords) {
        try {
          final cred = await auth.signInWithEmailAndPassword(
            email: email.trim(),
            password: password,
          );
          await cred.user!.delete();
          return AuthDeleteResult.deleted;
        } on FirebaseAuthException catch (e) {
          switch (e.code) {
            case 'user-not-found':
              // Already gone — the outcome the caller wanted either way.
              return AuthDeleteResult.alreadyGone;
            case 'wrong-password':
            case 'invalid-credential':
              continue; // try the next candidate
            case 'too-many-requests':
              return AuthDeleteResult.throttled;
            case 'requires-recent-login':
              // Cannot happen on a session we just created, but if Firebase
              // ever decides otherwise, say so rather than lying.
              return AuthDeleteResult.failed;
            default:
              return AuthDeleteResult.failed;
          }
        }
      }
      return AuthDeleteResult.wrongPassword;
    } catch (_) {
      return AuthDeleteResult.failed;
    } finally {
      try {
        await FirebaseAuth.instanceFor(app: temp!).signOut();
      } catch (_) {
        // Deleting the user already ended the session.
      }
      if (owned) await temp?.delete();
    }
  }

  Future<AppUser> createSubUser({
    required String name,
    required String email,
    required String password,
    required String collegeId,
    required String roleId,
    required String roleName,
    String? phone,
    String? gender,
    String? enrollmentNo,

    /// Extra profile fields written in the *same* document write, so a bulk
    /// import doesn't need a second round trip per student.
    Map<String, dynamic>? extra,

    /// Reuse an app from [openProvisioningApp]. When supplied it is NOT
    /// deleted here — the caller owns its lifetime.
    FirebaseApp? app,
  }) async {
    final owned = app == null;
    FirebaseApp? temp = app;
    try {
      temp ??= await openProvisioningApp();
      final cred = await FirebaseAuth.instanceFor(
        app: temp,
      ).createUserWithEmailAndPassword(email: email.trim(), password: password);
      final uid = cred.user!.uid;

      // Deliberately NOT calling updateDisplayName: it is a whole extra network
      // round trip per account, and nothing in this app ever reads
      // User.displayName — every screen renders from the Firestore profile
      // below. On a 30-row import that alone was 30 wasted round trips.

      final profile = AppUser(
        uid: uid,
        name: name.trim(),
        email: email.trim(),
        collegeId: collegeId,
        roleId: roleId,
        roleName: roleName,
        phone: phone,
        gender: gender,
        enrollmentNo: enrollmentNo,
      );

      await _db.collection('users').doc(uid).set({
        ...profile.toMap(),
        ...?extra,
        'createdAt': FieldValue.serverTimestamp(),
      });

      // No signOut here when the caller owns the app. The next
      // createUserWithEmailAndPassword replaces the session on this isolated
      // instance anyway, and the Firestore write above went through the
      // *default* app (the admin's credentials), so who is signed in on the
      // provisioning instance never affects permissions.
      // closeProvisioningApp() signs out once at the end of the run.
      if (owned) await FirebaseAuth.instanceFor(app: temp).signOut();
      return profile;
    } on FirebaseAuthException catch (e) {
      throw AuthFailure(_friendly(e));
    } finally {
      // Only tear down an app we created ourselves.
      if (owned) await temp?.delete();
    }
  }

  /// Maps Firebase's error codes to something a human can act on.
  static String _friendly(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-email':
        return 'That email address doesn\'t look valid.';
      case 'user-disabled':
        return 'This account has been disabled.';
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
        return 'Incorrect email or password.';
      case 'email-already-in-use':
        return 'An account already exists with that email.';
      case 'weak-password':
        return 'Password is too weak — use at least 6 characters.';
      case 'too-many-requests':
        return 'Too many attempts. Please wait a moment and try again.';
      case 'network-request-failed':
        return 'No internet connection.';
      default:
        return e.message ?? 'Something went wrong. Please try again.';
    }
  }

  static String describeError(Object e) {
    if (e is FirebaseAuthException) return _friendly(e);
    if (e is AuthFailure) return e.message;
    if (e is FirebaseException) {
      return e.code == 'permission-denied'
          ? 'You don\'t have permission to do that.'
          : (e.message ?? 'Database error.');
    }
    return 'Something went wrong. Please try again.';
  }
}

/// What happened when we tried to remove a Firebase Auth account.
enum AuthDeleteResult {
  deleted,

  /// No account existed — the desired end state anyway.
  alreadyGone,

  /// The account exists but its password is no longer the derived one, so a
  /// browser cannot sign in as it. Needs the Admin SDK script.
  wrongPassword,

  /// Nothing to try — a staff member with a real password, for instance.
  noCredential,

  /// Firebase rate-limited the sign-in attempts.
  throttled,

  failed,
}

extension AuthDeleteResultX on AuthDeleteResult {
  bool get isGone =>
      this == AuthDeleteResult.deleted || this == AuthDeleteResult.alreadyGone;

  String get explanation => switch (this) {
    AuthDeleteResult.deleted => 'sign-in account removed',
    AuthDeleteResult.alreadyGone => 'no sign-in account existed',
    // Not a definite "kept": with Firebase's email enumeration protection on
    // (the default for new projects), signing in to an account that no
    // longer exists fails exactly like a wrong password does.
    AuthDeleteResult.wrongPassword =>
      'could not sign in as this account — its password was changed, or it '
          'was already removed. If re-adding this person says "email already '
          'in use", run: node delete-students.js --orphans --commit',
    AuthDeleteResult.noCredential =>
      'sign-in account KEPT — no derivable password. '
          'Run: node delete-students.js --orphans --commit',
    AuthDeleteResult.throttled =>
      'sign-in account KEPT — Firebase throttled the request. Try again in a '
          'minute, or run: node delete-students.js --orphans --commit',
    AuthDeleteResult.failed =>
      'sign-in account KEPT — removal failed. '
          'Run: node delete-students.js --orphans --commit',
  };
}

class AuthFailure implements Exception {
  final String message;
  AuthFailure(this.message);
  @override
  String toString() => message;
}
