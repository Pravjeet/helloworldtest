import 'package:flutter/material.dart';

import '../core/identity.dart';
import '../core/logo.dart';
import '../core/theme.dart';
import '../services/auth_service.dart';
import '../services/saved_accounts.dart';
import 'register_college_screen.dart';

/// Single sign-in form for *everyone* — super admin, warden, student.
/// There is deliberately no role picker: the role comes from the database,
/// never from something the user can choose at the login screen.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _identifier = TextEditingController();
  final _password = TextEditingController();

  bool _obscure = true;
  bool _busy = false;
  String? _error;

  /// Accounts remembered on this machine. Null while still loading, so the
  /// form doesn't flash the "no saved accounts" layout for a frame.
  List<SavedAccount>? _saved;

  /// Ticked = store the password in the OS keychain on a successful sign-in.
  bool _remember = false;

  /// The card currently signing in, so only that one shows a spinner.
  String? _signingInAs;

  /// Set once the user chooses "use another account", which hides the cards
  /// for the rest of this visit to the screen.
  bool _showForm = false;

  @override
  void initState() {
    super.initState();
    _loadSaved();
  }

  @override
  void dispose() {
    _identifier.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _loadSaved() async {
    final accounts = await SavedAccounts.instance.all();
    if (!mounted) return;
    setState(() {
      _saved = accounts;
      _showForm = accounts.isEmpty;
    });
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    await _signIn(_identifier.text, _password.text);
  }

  /// The one place a sign-in actually happens, so remembering the account
  /// can't be forgotten on one of the paths into it.
  Future<void> _signIn(String identifier, String password) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AuthService.instance.signIn(
        identifier: identifier,
        password: password,
        // The same tick that remembers the password keeps the session alive
        // past closing the browser. Both are the one question a person is
        // actually answering — "is this machine mine?" — and splitting them
        // into two checkboxes would only invite ticking one and not the other.
        staySignedIn: _remember,
      );

      // Fire-and-forget: the profile name makes the card readable, but a
      // failure to read it must not hold up the sign-in.
      await SavedAccounts.instance.remember(
        identifier: identifier.trim(),
        name: AuthService.instance.currentUser?.displayName,
        password: (_remember && SavedAccounts.instance.passwordsSupported)
            ? password
            : null,
      );
      // No navigation here — AuthGate reacts to the auth state change.
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = AuthService.describeError(e);
          // A stored password that no longer works is worse than none: drop
          // it so the next tap asks for a fresh one instead of failing again.
          if (_signingInAs != null) {
            SavedAccounts.instance.remember(identifier: identifier);
            _showForm = true;
            _identifier.text = identifier;
          }
        });
        _loadSaved();
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _signingInAs = null;
        });
      }
    }
  }

  /// Tapping a saved card: sign straight in when the password is in the
  /// keychain, otherwise drop into the form with the identifier filled.
  Future<void> _useAccount(SavedAccount account) async {
    if (!account.hasPassword) {
      setState(() {
        _showForm = true;
        _identifier.text = account.identifier;
        _password.clear();
        _remember = true;
      });
      return;
    }

    setState(() => _signingInAs = account.identifier);
    final password = await SavedAccounts.instance.passwordFor(
      account.identifier,
    );
    if (!mounted) return;
    if (password == null) {
      setState(() {
        _signingInAs = null;
        _showForm = true;
        _identifier.text = account.identifier;
      });
      return;
    }
    _remember = true;
    await _signIn(account.identifier, password);
  }

  Future<void> _forget(SavedAccount account) async {
    await SavedAccounts.instance.forget(account.identifier);
    await _loadSaved();
    if (mounted && (_saved?.isEmpty ?? true)) {
      setState(() => _showForm = true);
    }
  }

  Future<void> _resetPassword() async {
    final id = _identifier.text.trim();
    if (id.isEmpty) {
      setState(
        () => _error = 'Enter your email or registration number above first.',
      );
      return;
    }
    try {
      await AuthService.instance.sendPasswordReset(id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Password reset link sent to $id')),
      );
    } catch (e) {
      if (mounted) setState(() => _error = AuthService.describeError(e));
    }
  }

  /// One tappable card per remembered sign-in.
  List<Widget> _savedCards() => [
    for (final account in _saved ?? const <SavedAccount>[])
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: _AccountCard(
          account: account,
          busy: _busy,
          signingIn: _signingInAs == account.identifier,
          onTap: () => _useAccount(account),
          onForget: () => _forget(account),
        ),
      ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 430),
            child: AppCard(
              padding: const EdgeInsets.all(36),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(child: HomiLogo(size: 62)),
                    const SizedBox(height: 22),
                    const Text(
                      'Homi Hostel',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 25,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _showForm
                          ? 'Sign in to your hostel workspace'
                          : 'Pick up where you left off',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 30),

                    if (_error != null) ...[
                      ErrorBanner(_error!),
                      const SizedBox(height: 18),
                    ],

                    if (!_showForm) ...[
                      ..._savedCards(),
                      const SizedBox(height: 4),
                      OutlinedButton.icon(
                        onPressed: _busy
                            ? null
                            : () => setState(() {
                                _showForm = true;
                                _identifier.clear();
                                _password.clear();
                              }),
                        icon: const Icon(
                          Icons.person_add_alt_rounded,
                          size: 18,
                        ),
                        label: const Text('Use another account'),
                      ),
                    ] else ...[
                      TextFormField(
                        controller: _identifier,
                        enabled: !_busy,
                        autofillHints: const [AutofillHints.username],
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: 'Email or registration number',
                          helperText: 'Students: just your registration number',
                          prefixIcon: Icon(Icons.person_outline_rounded),
                        ),
                        validator: (v) {
                          final s = v?.trim() ?? '';
                          if (s.isEmpty) {
                            return 'Enter your email or registration number';
                          }
                          if (Identity.looksLikeEmail(s)) {
                            if (!RegExp(
                              r'^[^@\s]+@[^@\s]+\.[^@\s]+$',
                            ).hasMatch(s)) {
                              return 'That email address doesn\'t look valid';
                            }
                          } else if (!Identity.isValidRegistrationNumber(s)) {
                            return 'Registration numbers use letters, digits, '
                                '. _ or - only';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _password,
                        enabled: !_busy,
                        obscureText: _obscure,
                        autofillHints: const [AutofillHints.password],
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => _busy ? null : _submit(),
                        decoration: InputDecoration(
                          labelText: 'Password',
                          prefixIcon: const Icon(Icons.lock_outline_rounded),
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscure
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                            ),
                            onPressed: () =>
                                setState(() => _obscure = !_obscure),
                          ),
                        ),
                        validator: (v) => (v == null || v.isEmpty)
                            ? 'Password is required'
                            : null,
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: SavedAccounts.instance.passwordsSupported
                                ? CheckboxListTile(
                                    value: _remember,
                                    onChanged: _busy
                                        ? null
                                        : (v) => setState(
                                            () => _remember = v ?? false,
                                          ),
                                    title: const Text(
                                      'Keep me signed in on this PC',
                                      style: TextStyle(fontSize: 13),
                                    ),
                                    subtitle: Text(
                                      'Stays signed in after you close the '
                                      'browser. Leave off on shared machines.',
                                      style: TextStyle(
                                        fontSize: 11.5,
                                        color: AppColors.textMuted,
                                      ),
                                    ),
                                    controlAffinity:
                                        ListTileControlAffinity.leading,
                                    contentPadding: EdgeInsets.zero,
                                    dense: true,
                                  )
                                : const SizedBox.shrink(),
                          ),
                          TextButton(
                            onPressed: _busy ? null : _resetPassword,
                            child: const Text('Forgot password?'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      ElevatedButton(
                        onPressed: _busy ? null : _submit,
                        child: _busy
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.4,
                                  color: Colors.white,
                                ),
                              )
                            : const Text('Sign in'),
                      ),
                      if ((_saved?.isNotEmpty ?? false)) ...[
                        const SizedBox(height: 8),
                        TextButton.icon(
                          onPressed: _busy
                              ? null
                              : () => setState(() {
                                  _showForm = false;
                                  _error = null;
                                }),
                          icon: const Icon(Icons.arrow_back_rounded, size: 17),
                          label: const Text('Back to saved accounts'),
                        ),
                      ],
                    ],
                    const SizedBox(height: 18),
                    Wrap(
                      alignment: WrapAlignment.center,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          'Setting up a new institution?',
                          style: TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 13.5,
                          ),
                        ),
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        const RegisterCollegeScreen(),
                                  ),
                                ),
                          child: const Text('Register'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A remembered sign-in, rendered like the account pickers people already
/// know from Google and Windows: avatar, name, and a hint of what tapping
/// will do.
class _AccountCard extends StatelessWidget {
  final SavedAccount account;
  final bool busy;
  final bool signingIn;
  final VoidCallback onTap;
  final VoidCallback onForget;

  const _AccountCard({
    required this.account,
    required this.busy,
    required this.signingIn,
    required this.onTap,
    required this.onForget,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: busy ? null : onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: AppColors.primarySoft,
              child: signingIn
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2.2),
                    )
                  : Text(
                      account.initials,
                      style: TextStyle(
                        color: AppColors.primary,
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    account.display,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    signingIn
                        ? 'Signing in…'
                        : account.hasPassword
                        ? 'Tap to sign in'
                        : 'Tap to enter your password',
                    style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                  ),
                ],
              ),
            ),
            if (!busy)
              IconButton(
                onPressed: onForget,
                icon: const Icon(Icons.close_rounded, size: 18),
                tooltip: 'Forget this account',
                color: AppColors.textMuted,
              ),
          ],
        ),
      ),
    );
  }
}

class ErrorBanner extends StatelessWidget {
  final String message;
  const ErrorBanner(this.message, {super.key});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    decoration: BoxDecoration(
      color: AppColors.dangerSoft,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.error_outline_rounded, color: AppColors.danger, size: 19),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            message,
            style: TextStyle(
              color: AppColors.danger,
              fontSize: 13,
              height: 1.35,
            ),
          ),
        ),
      ],
    ),
  );
}
