import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../core/theme.dart';
import '../../models/notice.dart';
import '../../services/auth_service.dart';
import '../../services/notice_service.dart';

/// Form for staff to post a notice.
class PostNoticeView extends StatefulWidget {
  final VoidCallback onBack;
  final VoidCallback onDone;

  const PostNoticeView({super.key, required this.onBack, required this.onDone});

  @override
  State<PostNoticeView> createState() => _PostNoticeViewState();
}

class _PostNoticeViewState extends State<PostNoticeView> {
  final _formKey = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _content = TextEditingController();

  String _category = kNoticeCategories.first;
  DateTime? _expiryDate;

  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _content.dispose();
    super.dispose();
  }

  Future<void> _pickExpiryDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: now.add(const Duration(days: 7)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (picked == null) return;
    setState(() => _expiryDate = picked);
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    final session = Session.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await NoticeService.instance.post(
        collegeId: session.user.collegeId,
        author: session.user,
        title: _title.text,
        content: _content.text,
        category: _category,
        expiryDate: _expiryDate,
      );
      messenger.showSnackBar(const SnackBar(content: Text('Notice posted')));
      widget.onDone();
    } catch (e) {
      if (mounted) setState(() => _error = AuthService.describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppCard(
              child: Row(
                children: [
                  IconButton(
                    onPressed: _busy ? null : widget.onBack,
                    icon: const Icon(Icons.arrow_back_rounded),
                    tooltip: 'Back to notices',
                  ),
                  const SizedBox(width: 4),
                  const Expanded(
                    child: Text(
                      'Post a notice',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            if (_error != null) ...[
              AppCard(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Icon(
                      Icons.error_outline_rounded,
                      color: AppColors.danger,
                      size: 19,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _error!,
                        style: TextStyle(color: AppColors.danger, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
            ],
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextFormField(
                    controller: _title,
                    enabled: !_busy,
                    decoration: const InputDecoration(
                      labelText: 'Title',
                      hintText: 'e.g., Campus closed for Diwali',
                    ),
                    validator: (v) => (v == null || v.trim().length < 3)
                        ? 'Title is required (at least 3 characters)'
                        : null,
                  ),
                  const SizedBox(height: 18),
                  DropdownButtonFormField<String>(
                    initialValue: _category,
                    decoration: const InputDecoration(labelText: 'Category'),
                    items: kNoticeCategories
                        .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                        .toList(),
                    onChanged: _busy
                        ? null
                        : (v) => setState(
                            () => _category = v ?? kNoticeCategories.first,
                          ),
                  ),
                  const SizedBox(height: 18),
                  TextFormField(
                    controller: _content,
                    enabled: !_busy,
                    maxLines: 6,
                    decoration: const InputDecoration(
                      labelText: 'Message',
                      alignLabelWithHint: true,
                      hintText:
                          'Full details of the notice. Students will see '
                          'this in the notices section.',
                    ),
                    validator: (v) => (v == null || v.trim().length < 10)
                        ? 'Message is required (at least 10 characters)'
                        : null,
                  ),
                  const SizedBox(height: 18),
                  InkWell(
                    onTap: _busy ? null : _pickExpiryDate,
                    borderRadius: BorderRadius.circular(10),
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        labelText: 'Expires (optional)',
                        helperText: 'Leave empty to keep it active permanently',
                        suffixIcon: Icon(
                          Icons.calendar_today_rounded,
                          size: 17,
                        ),
                      ),
                      child: Text(
                        _expiryDate == null
                            ? 'Tap to set expiry date'
                            : '${_expiryDate!.day} ${months[_expiryDate!.month - 1]} '
                                  '${_expiryDate!.year}',
                        style: TextStyle(
                          fontSize: 14,
                          color: _expiryDate == null
                              ? AppColors.textMuted
                              : AppColors.textStrong,
                        ),
                      ),
                    ),
                  ),
                  if (_expiryDate != null) ...[
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: _busy
                          ? null
                          : () => setState(() => _expiryDate = null),
                      icon: const Icon(Icons.close_rounded, size: 16),
                      label: const Text('Clear expiry'),
                    ),
                  ],
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: _busy ? null : widget.onBack,
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: _busy ? null : _submit,
                        child: _busy
                            ? const SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.2,
                                  color: Colors.white,
                                ),
                              )
                            : const Text('Post notice'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
