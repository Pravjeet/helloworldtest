import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../services/auth_service.dart';
import 'login_screen.dart';

/// One-time provisioning of an institution and its Super Admin.
/// After this succeeds, AuthGate takes over automatically (the new admin is
/// already signed in), so there is no navigation code on success.
class RegisterCollegeScreen extends StatefulWidget {
  const RegisterCollegeScreen({super.key});

  @override
  State<RegisterCollegeScreen> createState() => _RegisterCollegeScreenState();
}

class _RegisterCollegeScreenState extends State<RegisterCollegeScreen> {
  final _formKey = GlobalKey<FormState>();
  final _institution = TextEditingController();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  bool _obscure = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_institution, _name, _email, _password, _confirm]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AuthService.instance.registerCollege(
        institutionName: _institution.text,
        adminName: _name.text,
        email: _email.text,
        password: _password.text,
      );
    } catch (e) {
      if (mounted) {
        setState(() => _error = AuthService.describeError(e));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: AppColors.textStrong,
        title: const Text('Register your institution'),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: AppCard(
              padding: const EdgeInsets.all(34),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Create your workspace',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'This creates the institution and makes you its Super '
                      'Admin. You can add wardens, managers and students '
                      'afterwards from the dashboard.',
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 13.5,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 26),

                    if (_error != null) ...[
                      ErrorBanner(_error!),
                      const SizedBox(height: 18),
                    ],

                    _Field(
                      controller: _institution,
                      label: 'Institution name',
                      icon: Icons.apartment_rounded,
                      enabled: !_busy,
                      validator: (v) => (v == null || v.trim().length < 3)
                          ? 'Enter the full name of your college'
                          : null,
                    ),
                    _Field(
                      controller: _name,
                      label: 'Your full name',
                      icon: Icons.person_outline_rounded,
                      enabled: !_busy,
                      validator: (v) => (v == null || v.trim().length < 2)
                          ? 'Your name is required'
                          : null,
                    ),
                    _Field(
                      controller: _email,
                      label: 'Work email',
                      icon: Icons.mail_outline_rounded,
                      enabled: !_busy,
                      keyboardType: TextInputType.emailAddress,
                      validator: (v) {
                        final s = v?.trim() ?? '';
                        if (s.isEmpty) return 'Email is required';
                        if (!RegExp(
                          r'^[^@\s]+@[^@\s]+\.[^@\s]+$',
                        ).hasMatch(s)) {
                          return 'Enter a valid email address';
                        }
                        return null;
                      },
                    ),
                    _Field(
                      controller: _password,
                      label: 'Password',
                      icon: Icons.lock_outline_rounded,
                      enabled: !_busy,
                      obscure: _obscure,
                      suffix: IconButton(
                        icon: Icon(
                          _obscure
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                        ),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                      validator: (v) => (v == null || v.length < 6)
                          ? 'Use at least 6 characters'
                          : null,
                    ),
                    _Field(
                      controller: _confirm,
                      label: 'Confirm password',
                      icon: Icons.lock_outline_rounded,
                      enabled: !_busy,
                      obscure: _obscure,
                      validator: (v) =>
                          v != _password.text ? 'Passwords don\'t match' : null,
                    ),
                    const SizedBox(height: 10),
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
                          : const Text('Create workspace'),
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

class _Field extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final IconData icon;
  final bool enabled;
  final bool obscure;
  final Widget? suffix;
  final TextInputType? keyboardType;
  final String? Function(String?) validator;

  const _Field({
    required this.controller,
    required this.label,
    required this.icon,
    required this.enabled,
    required this.validator,
    this.obscure = false,
    this.suffix,
    this.keyboardType,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextFormField(
      controller: controller,
      enabled: enabled,
      obscureText: obscure,
      keyboardType: keyboardType,
      validator: validator,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
        suffixIcon: suffix,
      ),
    ),
  );
}
