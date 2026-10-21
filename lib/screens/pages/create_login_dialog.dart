import 'package:flutter/material.dart';

import '../../core/identity.dart';
import '../../core/theme.dart';
import '../../models/app_user.dart';
import '../../services/auth_service.dart';
import '../../services/login_account_service.dart';

/// Asks a Super Admin for a password, then gives a record-only student a
/// sign-in account (see [LoginAccountService]). Pops with the new uid.
///
/// The password starts as the one derived from the registration number — the
/// same one the importer used to give everyone. It can be changed, but keeping
/// it means the app can still remove this login by itself if the student is
/// ever deleted, which a hand-typed password rules out.
class CreateLoginDialog extends StatefulWidget {
  final AppUser student;
  final AppUser actor;

  const CreateLoginDialog({
    super.key,
    required this.student,
    required this.actor,
  });

  @override
  State<CreateLoginDialog> createState() => _CreateLoginDialogState();
}

class _CreateLoginDialogState extends State<CreateLoginDialog> {
  late final TextEditingController _password;
  bool _obscure = false;
  bool _busy = false;
  String? _error;

  bool get _resuming => widget.student.pendingLoginUid != null;

  String get _derived {
    final reg = (widget.student.enrollmentNo ?? '').trim();
    if (reg.isNotEmpty) return Identity.derivedPassword(reg);
    return Identity.derivedPassword(Identity.display(widget.student.email));
  }

  @override
  void initState() {
    super.initState();
    _password = TextEditingController(text: _derived);
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final password = _password.text;
    if (!_resuming && password.length < 6) {
      setState(() => _error = 'The password needs at least 6 characters.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final uid = await LoginAccountService.instance.createLogin(
        student: widget.student,
        password: password,
        actor: widget.actor,
      );
      if (mounted) Navigator.pop(context, uid);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e is AuthFailure ? e.message : AuthService.describeError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.student;
    return AlertDialog(
      title: Text(
        _resuming ? 'Finish creating login' : 'Create login for ${s.name}',
      ),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'They will sign in with ${Identity.display(s.email)}.',
              style: const TextStyle(fontSize: 13.5, height: 1.5),
            ),
            const SizedBox(height: 14),
            if (_resuming)
              Text(
                'The sign-in account was already made on an earlier try. '
                'This finishes moving their fines, office orders, room and '
                'academic records onto it.',
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.45,
                  color: AppColors.textMuted,
                ),
              )
            else ...[
              TextField(
                controller: _password,
                obscureText: _obscure,
                enabled: !_busy,
                decoration: InputDecoration(
                  labelText: 'Password',
                  isDense: true,
                  suffixIcon: IconButton(
                    onPressed: () => setState(() => _obscure = !_obscure),
                    icon: Icon(
                      _obscure
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                      size: 19,
                    ),
                  ),
                ),
                onSubmitted: (_) => _busy ? null : _submit(),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.infoSoft,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(
                  'Pre-filled with their registration number. Keep it and the '
                  'app can remove this login by itself if they are ever '
                  'deleted; with a different password that takes '
                  'tools/delete-students.js.\n\nTheir fines, office orders, '
                  'room, fee records, academic records and photo stay '
                  'attached — the record is moved onto the new account.',
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.45,
                    color: AppColors.info,
                  ),
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.45,
                  color: AppColors.danger,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_resuming ? 'Finish' : 'Create login'),
        ),
      ],
    );
  }
}
