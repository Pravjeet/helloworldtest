import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../models/mess.dart';
import '../../services/auth_service.dart';
import '../../services/mess_service.dart';

/// What the mess costs, and a rebate calculator for days you weren't here.
///
/// The maths itself lives in [MessRebate] so it can be tested without a
/// widget tree; everything here is presentation.
class MessFeesView extends StatefulWidget {
  final String collegeId;
  final MessConfig config;
  final bool canManage;

  const MessFeesView({
    super.key,
    required this.collegeId,
    required this.config,
    required this.canManage,
  });

  @override
  State<MessFeesView> createState() => _MessFeesViewState();
}

class _MessFeesViewState extends State<MessFeesView> {
  late DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  int _absent = 0;

  MessConfig get _config => widget.config;
  String get _sym => _config.currencySymbol;

  MessRebate get _rebate => MessRebate(
    monthlyCharge: _config.monthlyCharge,
    daysInMonth: _config.daysFor(_month),
    daysAbsent: _absent,
    minRebateDays: _config.minRebateDays,
  );

  @override
  Widget build(BuildContext context) {
    if (!_config.isConfigured) return _notConfigured();

    final r = _rebate;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ---------------------------- the rate ----------------------------
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionHeader(
                'Mess charges',
                trailing: widget.canManage
                    ? OutlinedButton.icon(
                        onPressed: _editConfig,
                        icon: const Icon(Icons.edit_outlined, size: 17),
                        label: const Text('Edit'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 13,
                          ),
                        ),
                      )
                    : null,
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _Stat(
                      label: 'Per month',
                      value: '$_sym${_money(_config.monthlyCharge)}',
                      caption: _config.billingDays != null
                          ? 'Billed over a fixed ${_config.billingDays} days'
                          : 'Billed over the length of each month',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _Stat(
                      label: 'Per day',
                      value: '$_sym${r.perDay.toStringAsFixed(2)}',
                      caption:
                          '$_sym${_money(_config.monthlyCharge)} ÷ '
                          '${r.daysInMonth} days',
                      highlight: true,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _Stat(
                      label: 'Per meal (approx.)',
                      value: '$_sym${(r.perDay / 3).toStringAsFixed(2)}',
                      caption: 'Day rate split across 3 main meals',
                    ),
                  ),
                ],
              ),
              if (_config.minRebateDays > 0) ...[
                const SizedBox(height: 16),
                _Note(
                  'A rebate applies only from '
                  '${_config.minRebateDays} days of absence onwards.',
                  color: AppColors.warning,
                  background: AppColors.warningSoft,
                  icon: Icons.info_outline_rounded,
                ),
              ],
              if (_config.notes != null &&
                  _config.notes!.trim().isNotEmpty) ...[
                const SizedBox(height: 14),
                Text(
                  _config.notes!,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.55,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 18),

        // --------------------------- calculator ---------------------------
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionHeader('Absence calculator'),
              const SizedBox(height: 4),
              Text(
                'Went home, or away on an internship? Work out what you '
                'should be charged for the days you were actually here.',
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.textMuted,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 20),

              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _monthPicker(r)),
                  const SizedBox(width: 16),
                  Expanded(child: _absentPicker(r)),
                ],
              ),
              const SizedBox(height: 20),
              _Breakdown(rebate: r, symbol: _sym),
            ],
          ),
        ),
      ],
    );
  }

  // ------------------------------- inputs -------------------------------

  Widget _monthPicker(MessRebate r) {
    // Six months back and six forward covers "last semester" and "next month"
    // without turning into a date-picker dialog.
    final now = DateTime.now();
    final months = List.generate(
      13,
      (i) => DateTime(now.year, now.month - 6 + i),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Label('Month'),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          initialValue: _key(_month),
          decoration: InputDecoration(
            helperText:
                '${r.daysInMonth} days'
                '${_config.billingDays != null ? ' (fixed billing period)' : ''}',
          ),
          items: months
              .map(
                (m) => DropdownMenuItem(
                  value: _key(m),
                  child: Text('${_monthName(m.month)} ${m.year}'),
                ),
              )
              .toList(),
          onChanged: (v) {
            if (v == null) return;
            final parts = v.split('-');
            setState(() {
              _month = DateTime(int.parse(parts[0]), int.parse(parts[1]));
              _absent = _absent.clamp(0, _config.daysFor(_month));
            });
          },
        ),
      ],
    );
  }

  Widget _absentPicker(MessRebate r) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Label('Days absent'),
        const SizedBox(height: 8),
        Row(
          children: [
            IconButton.outlined(
              onPressed: _absent > 0 ? () => setState(() => _absent--) : null,
              icon: const Icon(Icons.remove_rounded, size: 18),
            ),
            Expanded(
              child: Slider(
                value: r.effectiveAbsent.toDouble(),
                min: 0,
                max: r.daysInMonth.toDouble(),
                divisions: r.daysInMonth,
                label: '${r.effectiveAbsent} days',
                onChanged: (v) => setState(() => _absent = v.round()),
              ),
            ),
            IconButton.outlined(
              onPressed: _absent < r.daysInMonth
                  ? () => setState(() => _absent++)
                  : null,
              icon: const Icon(Icons.add_rounded, size: 18),
            ),
            const SizedBox(width: 10),
            Container(
              width: 58,
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.primarySoft,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '${r.effectiveAbsent}',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: AppColors.primary,
                ),
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(left: 12, top: 4),
          child: Text(
            'Present for ${r.daysPresent} of ${r.daysInMonth} days',
            style: TextStyle(fontSize: 12, color: AppColors.textMuted),
          ),
        ),
      ],
    );
  }

  // --------------------------- not configured ---------------------------

  Widget _notConfigured() {
    return AppCard(
      padding: const EdgeInsets.symmetric(vertical: 60, horizontal: 24),
      child: Center(
        child: Column(
          children: [
            Icon(Icons.payments_rounded, size: 40, color: AppColors.textMuted),
            const SizedBox(height: 14),
            const Text(
              'Mess charges haven\'t been set.',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              widget.canManage
                  ? 'Set the monthly charge and the calculator becomes '
                        'available to every resident.'
                  : 'Your mess manager hasn\'t published the charges yet.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: AppColors.textMuted,
                height: 1.5,
              ),
            ),
            if (widget.canManage) ...[
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: _editConfig,
                icon: const Icon(Icons.add_rounded, size: 17),
                label: const Text('Set mess charges'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 16,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _editConfig() async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) =>
          _ConfigDialog(collegeId: widget.collegeId, config: _config),
    );
    if (saved == true && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Mess charges updated')));
    }
  }

  // ------------------------------- helpers -------------------------------

  static String _key(DateTime d) => '${d.year}-${d.month}';

  static String _monthName(int m) => const [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ][m - 1];
}

/// Trims a trailing `.0` so ₹3500 doesn't render as ₹3500.0.
String _money(num v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);

// ------------------------------ breakdown ------------------------------

class _Breakdown extends StatelessWidget {
  final MessRebate rebate;
  final String symbol;

  const _Breakdown({required this.rebate, required this.symbol});

  @override
  Widget build(BuildContext context) {
    final r = rebate;
    final blocked = r.effectiveAbsent > 0 && !r.qualifies;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.canvas,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          _Line(
            'Full month',
            '$symbol${_money(r.monthlyCharge)}',
            caption: '${r.daysInMonth} days',
          ),
          const SizedBox(height: 10),
          _Line(
            'Per day',
            '$symbol${r.perDay.toStringAsFixed(2)}',
            caption: '$symbol${_money(r.monthlyCharge)} ÷ ${r.daysInMonth}',
          ),
          const SizedBox(height: 10),
          _Line(
            'Days absent',
            '− ${r.effectiveAbsent}',
            caption: 'Present ${r.daysPresent} days',
          ),
          const SizedBox(height: 10),
          _Line(
            'Rebate',
            '− $symbol${r.rebate.toStringAsFixed(2)}',
            caption: blocked
                ? 'Below the minimum for a rebate'
                : '${r.effectiveAbsent} × '
                      '$symbol${r.perDay.toStringAsFixed(2)}',
            valueColor: blocked ? AppColors.textMuted : AppColors.success,
          ),
          Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Divider(height: 1, color: AppColors.border),
          ),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'You should pay',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                '$symbol${r.payable.toStringAsFixed(2)}',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: AppColors.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _Note(
            'An estimate only. The actual rebate depends on your mess\'s '
            'rules and an approved leave record — check with your warden '
            'before assuming it.',
            color: AppColors.info,
            background: AppColors.infoSoft,
            icon: Icons.info_outline_rounded,
          ),
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  final String label;
  final String value;
  final String? caption;
  final Color? valueColor;

  const _Line(this.label, this.value, {this.caption, this.valueColor});

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontSize: 13.5, height: 1.3)),
            if (caption != null)
              Text(
                caption!,
                style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
              ),
          ],
        ),
      ),
      Text(
        value,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w700,
          color: valueColor ?? AppColors.textStrong,
        ),
      ),
    ],
  );
}

// ------------------------------ small bits ------------------------------

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  final String caption;
  final bool highlight;

  const _Stat({
    required this.label,
    required this.value,
    required this.caption,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: highlight ? AppColors.primarySoft : AppColors.canvas,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(
        color: highlight ? AppColors.primary : AppColors.border,
      ),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.8,
            color: AppColors.textMuted,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          value,
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w800,
            color: highlight ? AppColors.primary : AppColors.textStrong,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          caption,
          style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
        ),
      ],
    ),
  );
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w800,
      letterSpacing: 0.9,
      color: AppColors.textMuted,
    ),
  );
}

class _Note extends StatelessWidget {
  final String text;
  final Color color;
  final Color background;
  final IconData icon;

  const _Note(
    this.text, {
    required this.color,
    required this.background,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 12.5, height: 1.5, color: color),
          ),
        ),
      ],
    ),
  );
}

// ------------------------------ config editor ------------------------------

class _ConfigDialog extends StatefulWidget {
  final String collegeId;
  final MessConfig config;

  const _ConfigDialog({required this.collegeId, required this.config});

  @override
  State<_ConfigDialog> createState() => _ConfigDialogState();
}

class _ConfigDialogState extends State<_ConfigDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _charge;
  late final TextEditingController _billingDays;
  late final TextEditingController _minRebate;
  late final TextEditingController _symbol;
  late final TextEditingController _notes;

  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final c = widget.config;
    _charge = TextEditingController(
      text: c.monthlyCharge > 0 ? _money(c.monthlyCharge) : '',
    );
    _billingDays = TextEditingController(text: c.billingDays?.toString() ?? '');
    _minRebate = TextEditingController(
      text: c.minRebateDays > 0 ? c.minRebateDays.toString() : '',
    );
    _symbol = TextEditingController(text: c.currencySymbol);
    _notes = TextEditingController(text: c.notes ?? '');
  }

  @override
  void dispose() {
    _charge.dispose();
    _billingDays.dispose();
    _minRebate.dispose();
    _symbol.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await MessService.instance.saveConfig(
        widget.collegeId,
        MessConfig(
          monthlyCharge: num.parse(_charge.text.trim()),
          billingDays: int.tryParse(_billingDays.text.trim()),
          minRebateDays: int.tryParse(_minRebate.text.trim()) ?? 0,
          currencySymbol: _symbol.text.trim().isEmpty
              ? '₹'
              : _symbol.text.trim(),
          timings: widget.config.timings,
          notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
        ),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = AuthService.describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Mess charges'),
      content: SizedBox(
        width: 480,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_error != null) ...[
                  _Note(
                    _error!,
                    color: AppColors.danger,
                    background: AppColors.dangerSoft,
                    icon: Icons.error_outline_rounded,
                  ),
                  const SizedBox(height: 16),
                ],
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextFormField(
                        controller: _charge,
                        enabled: !_busy,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Charge per month',
                          hintText: '3500',
                        ),
                        validator: (v) {
                          final n = num.tryParse((v ?? '').trim());
                          if (n == null || n <= 0) {
                            return 'Enter an amount';
                          }
                          return null;
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _symbol,
                        enabled: !_busy,
                        decoration: const InputDecoration(labelText: 'Symbol'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _billingDays,
                  enabled: !_busy,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Fixed billing days (optional)',
                    helperText:
                        'Leave blank to divide by the real length of '
                        'each month',
                  ),
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _minRebate,
                  enabled: !_busy,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Minimum days for a rebate (optional)',
                    helperText: 'Blank or 0 means any absence is refundable',
                  ),
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _notes,
                  enabled: !_busy,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Notes for residents (optional)',
                    hintText: 'How to claim a rebate, what the charge covers…',
                    alignLabelWithHint: true,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: _busy
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: Colors.white,
                  ),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}
