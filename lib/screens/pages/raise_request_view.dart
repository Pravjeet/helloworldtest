import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../core/theme.dart';
import '../../models/hostel_request.dart';
import '../../services/auth_service.dart';
import '../../services/request_service.dart';

/// The form a resident fills in to raise a request.
///
/// The fields change with the type, because a leave request and a broken tap
/// have almost nothing in common. One form that shows everything would ask a
/// student for a destination when they're reporting a fused light.
class RaiseRequestView extends StatefulWidget {
  final VoidCallback onBack;
  final VoidCallback onDone;

  const RaiseRequestView({
    super.key,
    required this.onBack,
    required this.onDone,
  });

  @override
  State<RaiseRequestView> createState() => _RaiseRequestViewState();
}

class _RaiseRequestViewState extends State<RaiseRequestView> {
  final _formKey = GlobalKey<FormState>();
  final _subject = TextEditingController();
  final _details = TextEditingController();
  final _destination = TextEditingController();

  RequestType _type = RequestType.leave;
  String _category = kComplaintCategories.first;
  DateTime? _from;
  DateTime? _to;

  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_subject, _details, _destination]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickDate({required bool isFrom}) async {
    final now = DateTime.now();
    final initial = (isFrom ? _from : _to) ?? now;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial.isBefore(now) ? now : initial,
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: now.add(const Duration(days: 365)),
    );
    if (picked == null) return;
    setState(() {
      if (isFrom) {
        _from = picked;
        // Keep the range sane rather than silently allowing to < from.
        if (_to != null && _to!.isBefore(picked)) _to = picked;
      } else {
        _to = picked;
        if (_from != null && picked.isBefore(_from!)) _from = picked;
      }
    });
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    if (_type == RequestType.leave && (_from == null || _to == null)) {
      setState(() => _error = 'Pick both a start and an end date.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    final session = Session.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await RequestService.instance.raise(
        collegeId: session.user.collegeId,
        author: session.user,
        type: _type,
        subject: _subject.text,
        details: _details.text,
        fromDate: _type == RequestType.leave ? _from : null,
        toDate: _type == RequestType.leave ? _to : null,
        destination: _type == RequestType.leave ? _destination.text : null,
        category: _type == RequestType.complaint ? _category : null,
      );
      messenger.showSnackBar(
        const SnackBar(content: Text('Request submitted')),
      );
      widget.onDone();
    } catch (e) {
      if (mounted) setState(() => _error = AuthService.describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = Session.of(context).user;

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
                    tooltip: 'Back to requests',
                  ),
                  const SizedBox(width: 4),
                  const Expanded(
                    child: Text(
                      'New request',
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
                  const Text(
                    'What kind of request?',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: RequestType.values.map((t) {
                      final selected = _type == t;
                      return ChoiceChip(
                        label: Text(t.label),
                        selected: selected,
                        onSelected: _busy
                            ? null
                            : (_) => setState(() => _type = t),
                        selectedColor: AppColors.primarySoft,
                        backgroundColor: Colors.white,
                        side: BorderSide(
                          color: selected
                              ? AppColors.primary
                              : AppColors.border,
                        ),
                        labelStyle: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: selected
                              ? AppColors.primary
                              : AppColors.textStrong,
                        ),
                      );
                    }).toList(),
                  ),

                  const SizedBox(height: 20),

                  if (_type == RequestType.complaint) ...[
                    DropdownButtonFormField<String>(
                      initialValue: _category,
                      decoration: const InputDecoration(
                        labelText: 'What is it about?',
                      ),
                      items: kComplaintCategories
                          .map(
                            (c) => DropdownMenuItem(value: c, child: Text(c)),
                          )
                          .toList(),
                      onChanged: _busy
                          ? null
                          : (v) => setState(
                              () => _category = v ?? kComplaintCategories.first,
                            ),
                    ),
                    const SizedBox(height: 16),
                  ],

                  if (_type == RequestType.leave) ...[
                    Row(
                      children: [
                        Expanded(
                          child: _DateField(
                            label: 'Leaving on',
                            value: _from,
                            enabled: !_busy,
                            onTap: () => _pickDate(isFrom: true),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _DateField(
                            label: 'Back on',
                            value: _to,
                            enabled: !_busy,
                            onTap: () => _pickDate(isFrom: false),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _destination,
                      enabled: !_busy,
                      decoration: const InputDecoration(
                        labelText: 'Where are you going?',
                        hintText: 'Home / Ludhiana',
                      ),
                      validator: (v) => (v == null || v.trim().length < 2)
                          ? 'Please say where you\'ll be'
                          : null,
                    ),
                    const SizedBox(height: 16),
                  ],

                  TextFormField(
                    controller: _subject,
                    enabled: !_busy,
                    decoration: InputDecoration(
                      labelText: 'Subject',
                      hintText: switch (_type) {
                        RequestType.leave => 'Going home for Diwali',
                        RequestType.complaint => 'Ceiling fan not working',
                        RequestType.roomChange => 'Request to move to BH-02',
                        RequestType.other => 'Short summary',
                      },
                    ),
                    validator: (v) => (v == null || v.trim().length < 3)
                        ? 'A short subject is required'
                        : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _details,
                    enabled: !_busy,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: 'Details',
                      alignLabelWithHint: true,
                      hintText: 'Anything the warden should know',
                    ),
                  ),

                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.canvas,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Text(
                      user.isAllotted
                          ? 'This will be raised as ${user.name} · '
                                '${user.roomLabel}'
                          : 'This will be raised as ${user.name}. You have no '
                                'room allotted, so the warden won\'t see a '
                                'room against it.',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ),

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
                            : const Text('Submit request'),
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

class _DateField extends StatelessWidget {
  final String label;
  final DateTime? value;
  final bool enabled;
  final VoidCallback onTap;

  const _DateField({
    required this.label,
    required this.value,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: enabled ? onTap : null,
    borderRadius: BorderRadius.circular(10),
    child: InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: const Icon(Icons.calendar_today_rounded, size: 17),
      ),
      child: Text(
        value == null
            ? 'Tap to pick'
            : '${value!.day.toString().padLeft(2, '0')}/'
                  '${value!.month.toString().padLeft(2, '0')}/'
                  '${value!.year}',
        style: TextStyle(
          fontSize: 14,
          color: value == null ? AppColors.textMuted : AppColors.textStrong,
        ),
      ),
    ),
  );
}
