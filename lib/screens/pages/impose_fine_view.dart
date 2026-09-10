import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/identity.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../models/app_user.dart';
import '../../models/college_settings.dart';
import '../../models/fine.dart';
import '../../services/auth_service.dart';
import '../../services/data_service.dart';
import '../../services/fine_service.dart';

/// Largest order photo accepted, in bytes. Base64 adds ~33% on top of this,
/// and a Firestore document tops out around 1 MB, so this leaves headroom
/// for the fine and order fields alongside it.
const int _maxOrderImageBytes = 700 * 1024;

const _monthNames = [
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

/// Form for issuing an office order, and optionally fining the students it
/// names.
///
/// Students are chosen from a live search rather than typed, so the order
/// always lands on real uids — one attached to a mistyped name would be
/// invisible to the student it was meant for.
///
/// One incident is one order. A fight involving five students produces a
/// single order naming all five, which is how the office issues them, and it
/// stores the scanned photo once rather than five times (it is base64 inside
/// the document).
///
/// The fine is optional. Given an amount, each named student gets their own
/// fine for it, all written in the same batch as the order
/// ([FineService.publishOfficeOrder]). Without one the order stands alone — a
/// warning, a suspension, a notice of enquiry.
class ImposeFineView extends StatefulWidget {
  final VoidCallback onBack;
  final VoidCallback onDone;

  /// Pre-selected student, when arriving from someone's fine history.
  final AppUser? student;

  const ImposeFineView({
    super.key,
    required this.onBack,
    required this.onDone,
    this.student,
  });

  @override
  State<ImposeFineView> createState() => _ImposeFineViewState();
}

class _ImposeFineViewState extends State<ImposeFineView> {
  final _formKey = GlobalKey<FormState>();
  final _reason = TextEditingController();
  final _search = TextEditingController();

  final _orderNo = TextEditingController();
  final _orderTitle = TextEditingController();
  final _orderDescription = TextEditingController();
  DateTime _orderDate = DateTime.now();
  Uint8List? _orderImageBytes;
  String? _orderImageMimeType;
  String? _orderImageName;

  /// Everyone this order is against. One incident is one order, so a fight
  /// involving five students is five entries here, not five orders.
  final List<AppUser> _students = [];

  /// What each student owes, keyed by uid.
  ///
  /// A student with no controller text is named on the order but not fined —
  /// which is a real outcome, not an omission. The ringleader and the person
  /// who happened to be standing there do not pay the same, and one of them
  /// may pay nothing.
  final Map<String, TextEditingController> _amounts = {};

  TextEditingController _amountFor(AppUser u) =>
      _amounts.putIfAbsent(u.uid, () => TextEditingController());

  /// Null until the first build reads the workspace's configured categories —
  /// Session isn't available from initState.
  String? _category;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.student != null) _students.add(widget.student!);
  }

  /// Pre-fills each student's amount when the chosen category has a default
  /// configured for the workspace.
  ///
  /// Only fills *blank* boxes — a figure already typed for one student is
  /// theirs, and picking a category should not quietly overwrite it. That is
  /// what makes the per-student amounts and the college's default amounts get
  /// along: the default is a starting point, not a rule.
  void _applyDefault(List<FineCategory> configured, String category) {
    for (final c in configured) {
      if (c.name == category && c.defaultAmount != null) {
        setState(() {
          for (final u in _students) {
            final box = _amountFor(u);
            if (box.text.trim().isEmpty) box.text = '${c.defaultAmount}';
          }
        });
        return;
      }
    }
  }

  @override
  void dispose() {
    for (final c in _amounts.values) {
      c.dispose();
    }
    _reason.dispose();
    _search.dispose();
    _orderNo.dispose();
    _orderTitle.dispose();
    _orderDescription.dispose();
    super.dispose();
  }

  static const _mimeByExt = {
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'webp': 'image/webp',
  };

  Future<void> _pickOrderImage() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jpg', 'jpeg', 'png', 'webp'],
      withData: true,
    );
    final file = result?.files.single;
    if (file == null || file.bytes == null) return;

    if (file.bytes!.lengthInBytes > _maxOrderImageBytes) {
      setState(() {
        _error =
            'That photo is too large '
            '(${(file.bytes!.lengthInBytes / 1024).round()} KB). Please '
            'keep it under ${_maxOrderImageBytes ~/ 1024} KB — a phone camera '
            'shot usually compresses well below that.';
      });
      return;
    }

    final ext = file.extension?.toLowerCase() ?? '';
    setState(() {
      _error = null;
      _orderImageBytes = file.bytes;
      _orderImageMimeType = _mimeByExt[ext] ?? 'image/jpeg';
      _orderImageName = file.name;
    });
  }

  Future<void> _pickOrderDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _orderDate,
      firstDate: DateTime(now.year - 15),
      lastDate: DateTime(now.year + 1, 12, 31),
    );
    if (picked == null) return;
    setState(() => _orderDate = picked);
  }

  /// The amount typed for one student, or null when they are not being fined.
  num? _chargeFor(AppUser u) {
    final raw = _amounts[u.uid]?.text.trim() ?? '';
    if (raw.isEmpty) return null;
    final n = num.tryParse(raw);
    return (n == null || n <= 0) ? null : n;
  }

  /// Everyone actually being fined.
  List<AppUser> get _fined =>
      _students.where((u) => _chargeFor(u) != null).toList();

  /// The order's total, so the whole bill is visible before submitting rather
  /// than being a surprise in the fines ledger.
  num get _total =>
      _students.fold<num>(0, (sum, u) => sum + (_chargeFor(u) ?? 0));

  /// Fills every blank amount with the same figure, for the common case where
  /// most of a group are fined alike. Deliberately fills rather than locks —
  /// each field stays editable afterwards.
  void _applyToAll(num value) {
    setState(() {
      for (final u in _students) {
        _amountFor(u).text = '$value';
      }
    });
  }

  /// Asks for one figure to drop into every student's box.
  Future<num?> _askSameAmount(BuildContext context) async {
    final controller = TextEditingController();
    final value = await showDialog<num>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Fine everyone the same?'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Amount for each',
            prefixText: '\u20b9 ',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final n = num.tryParse(controller.text.trim());
              Navigator.pop(c, n != null && n > 0 ? n : null);
            },
            child: const Text('Fill in'),
          ),
        ],
      ),
    );
    controller.dispose();
    return value;
  }

  Future<void> _submit() async {
    if (_students.isEmpty) {
      setState(() => _error = 'Choose at least one student for this order.');
      return;
    }
    if (!_formKey.currentState!.validate()) return;
    if (_fined.isNotEmpty && (_category ?? '').trim().isEmpty) {
      setState(() => _error = 'Pick a category for the fines.');
      return;
    }
    if (_orderImageBytes == null) {
      setState(
        () => _error = 'Add a photo of the office order before submitting',
      );
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    final session = Session.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await FineService.instance.publishOfficeOrder(
        collegeId: session.user.collegeId,
        // Each student with their own amount; a null amount means named on the
        // order but not fined.
        charges: [
          for (final u in _students) (student: u, amount: _chargeFor(u)),
        ],
        imposedBy: session.user,
        category: _fined.isEmpty ? null : (_category ?? kFineCategories.first),
        reason: _reason.text,
        orderNo: _orderNo.text,
        orderTitle: _orderTitle.text,
        orderImageBytes: _orderImageBytes!,
        orderImageMimeType: _orderImageMimeType!,
        orderDescription: _orderDescription.text,
        orderDate: _orderDate,
      );
      final n = _fined.length;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            n == 0
                ? 'Order ${_orderNo.text.trim()} issued against '
                      '${_students.length} student'
                      '${_students.length == 1 ? '' : 's'} — no fines'
                : 'Order issued — $n of ${_students.length} fined, '
                      '₹$_total total',
          ),
        ),
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
    final session = Session.of(context);
    final collegeId = session.user.collegeId;

    // Categories come from System Settings, falling back to the built-in list
    // when nobody has configured any.
    final categories = session.settings.categoryNames;
    _category ??= categories.first;
    if (!categories.contains(_category)) _category = categories.first;

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
                    tooltip: 'Back to fines',
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    // The form issues an order that may or may not carry a
                    // fine, so a fixed "Impose a fine" would be wrong half the
                    // time — it follows the switch.
                    child: Text(
                      _fined.isEmpty
                          ? 'Issue an office order'
                          : 'Issue an office order with fines',
                      style: const TextStyle(
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

            // ------------------------- who -------------------------
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _students.length > 1
                        ? 'Students (${_students.length})'
                        : 'Student',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textMuted,
                      letterSpacing: 0.4,
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Everyone chosen so far. The search below stays open rather
                  // than collapsing on the first pick, because adding the
                  // second and third student is the normal case for a group
                  // order, not an edge case.
                  for (final u in _students) ...[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: _SelectedStudent(
                            student: u,
                            onClear: _busy
                                ? null
                                : () => setState(() {
                                    _students.remove(u);
                                    _amounts.remove(u.uid)?.dispose();
                                  }),
                          ),
                        ),
                        const SizedBox(width: 10),
                        // One box per student, because on a real order they do
                        // not all pay the same. Left blank, this student is
                        // named on the order but not fined.
                        SizedBox(
                          width: 130,
                          child: TextFormField(
                            controller: _amountFor(u),
                            enabled: !_busy,
                            keyboardType: TextInputType.number,
                            onChanged: (_) => setState(() {}),
                            decoration: const InputDecoration(
                              labelText: 'Fine',
                              hintText: 'none',
                              prefixText: '\u20b9 ',
                              isDense: true,
                            ),
                            validator: (v) {
                              final raw = (v ?? '').trim();
                              if (raw.isEmpty) return null; // not fined
                              final n = num.tryParse(raw);
                              if (n == null) return 'Number';
                              if (n <= 0) return '> 0';
                              return null;
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (_students.length > 1) ...[
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Text(
                          _fined.isEmpty
                              ? 'Nobody is being fined \u2014 this will be a '
                                    'warning.'
                              : '${_fined.length} of ${_students.length} fined '
                                    '\u2014 \u20b9$_total total',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: _fined.isEmpty
                                ? AppColors.textMuted
                                : AppColors.primary,
                          ),
                        ),
                        const Spacer(),
                        // The common case is "mostly the same, with
                        // exceptions" — fill them all, then edit the outliers.
                        if (!_busy)
                          TextButton(
                            onPressed: () async {
                              final v = await _askSameAmount(context);
                              if (v != null) _applyToAll(v);
                            },
                            child: const Text('Same for all'),
                          ),
                      ],
                    ),
                  ],
                  TextField(
                    controller: _search,
                    enabled: !_busy,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: _students.isEmpty
                          ? 'Search by name, registration number or room'
                          : 'Add another student to this order',
                      prefixIcon: const Icon(Icons.search_rounded),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _StudentResults(
                    collegeId: collegeId,
                    query: _search.text,
                    // Already-added students are filtered out of the results,
                    // so the same person can't be listed twice and be fined
                    // twice for one incident.
                    excludeUids: {for (final u in _students) u.uid},
                    onPick: (u) => setState(() {
                      _students.add(u);
                      _error = null;
                      // Clearing the box readies it for the next name and
                      // collapses a long result list.
                      _search.clear();
                    }),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),

            // ------------------------- what -------------------------
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // No "does this carry a fine?" switch any more: that is
                  // decided per student by whether their amount box is filled.
                  // An order where nobody is fined is a warning, and needs no
                  // separate toggle to say so.
                  DropdownButtonFormField<String>(
                    initialValue: _category,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: 'Reason category',
                      helperText: _fined.isEmpty
                          ? 'Only needed once somebody is being fined'
                          : null,
                    ),
                    items: categories
                        .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                        .toList(),
                    onChanged: _busy
                        ? null
                        : (v) {
                            setState(() => _category = v ?? categories.first);
                            _applyDefault(
                              session.settings.fineCategories,
                              _category!,
                            );
                          },
                  ),
                  const SizedBox(height: 18),
                  TextFormField(
                    controller: _reason,
                    enabled: !_busy,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: 'Details',
                      alignLabelWithHint: true,
                      hintText:
                          'What happened, and when. The student sees '
                          'this on their fines list.',
                    ),
                    validator: (v) => (v == null || v.trim().length < 5)
                        ? 'Say what the fine is for (at least 5 characters)'
                        : null,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),

            // --------------------- office order ---------------------
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Office order',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textMuted,
                      letterSpacing: 0.4,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Every fine is issued under an order — fill in what was '
                    'printed and attach a photo of it.',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: AppColors.textMuted,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _orderNo,
                          enabled: !_busy,
                          decoration: const InputDecoration(
                            labelText: 'Office order number',
                            hintText: 'SLIET/HM/2026/17',
                          ),
                          validator: (v) => (v == null || v.trim().isEmpty)
                              ? 'Order number is required'
                              : null,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: InkWell(
                          onTap: _busy ? null : _pickOrderDate,
                          borderRadius: BorderRadius.circular(10),
                          child: InputDecorator(
                            decoration: const InputDecoration(
                              labelText: 'Order date',
                              suffixIcon: Icon(
                                Icons.calendar_today_rounded,
                                size: 17,
                              ),
                            ),
                            child: Text(
                              '${_orderDate.day} '
                              '${_monthNames[_orderDate.month - 1]} '
                              '${_orderDate.year}',
                              style: const TextStyle(fontSize: 14),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  TextFormField(
                    controller: _orderTitle,
                    enabled: !_busy,
                    decoration: const InputDecoration(
                      labelText: 'Subject',
                      hintText:
                          'e.g., Disciplinary action for curfew violation',
                    ),
                    validator: (v) => (v == null || v.trim().length < 3)
                        ? 'Subject is required (at least 3 characters)'
                        : null,
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'Photo of the order',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textMuted,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (_orderImageBytes != null)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Image.memory(
                            _orderImageBytes!,
                            height: 120,
                            width: 120,
                            fit: BoxFit.cover,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _orderImageName ?? 'Photo selected',
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                '${(_orderImageBytes!.lengthInBytes / 1024).round()} KB',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: AppColors.textMuted,
                                ),
                              ),
                              const SizedBox(height: 8),
                              OutlinedButton.icon(
                                onPressed: _busy ? null : _pickOrderImage,
                                icon: const Icon(
                                  Icons.image_outlined,
                                  size: 16,
                                ),
                                label: const Text('Choose a different photo'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    )
                  else
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _pickOrderImage,
                      icon: const Icon(Icons.add_photo_alternate_outlined),
                      label: const Text(
                        'Choose a photo (JPG/PNG, under 700 KB)',
                      ),
                    ),
                  const SizedBox(height: 18),
                  TextFormField(
                    controller: _orderDescription,
                    enabled: !_busy,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: 'Summary (optional)',
                      alignLabelWithHint: true,
                      hintText:
                          'A line or two on what the order says, so '
                          'people can find it without opening the photo.',
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
                            : Text(
                                _fined.isEmpty
                                    ? 'Issue order'
                                    : _fined.length > 1
                                    ? 'Issue order \u2014 ${_fined.length} fines'
                                    : 'Issue order \u2014 1 fine',
                              ),
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

class _SelectedStudent extends StatelessWidget {
  final AppUser student;
  final VoidCallback? onClear;

  const _SelectedStudent({required this.student, this.onClear});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: AppColors.primarySoft,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      children: [
        CircleAvatar(
          radius: 20,
          backgroundColor: AppColors.primary,
          child: Text(
            student.initials,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 14,
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                student.name,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                _subtitleFor(student),
                style: TextStyle(fontSize: 12.5, color: AppColors.textMuted),
              ),
            ],
          ),
        ),
        if (onClear != null)
          TextButton(onPressed: onClear, child: const Text('Change')),
      ],
    ),
  );
}

String _subtitleFor(AppUser u) => [
  Identity.display(u.email),
  if (u.roomLabel != null) u.roomLabel!,
  if (u.trade != null) u.trade!,
  if (u.sem != null) 'Sem ${u.sem}',
].join(' · ');

/// Live student picker. Shows nothing until at least two characters are typed
/// — a college has hundreds of residents and an unfiltered list is useless.
class _StudentResults extends StatelessWidget {
  final String collegeId;
  final String query;

  /// Students already named on this order. Excluded from results so the same
  /// person can't be added twice — which would raise two fines against them
  /// for one incident, and is rejected by the service anyway.
  final Set<String> excludeUids;

  final ValueChanged<AppUser> onPick;

  const _StudentResults({
    required this.collegeId,
    required this.query,
    this.excludeUids = const {},
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final q = query.trim().toLowerCase();
    if (q.length < 2) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Text(
          'Type at least two characters to find a student.',
          style: TextStyle(color: AppColors.textMuted, fontSize: 13),
        ),
      );
    }

    return StreamBuilder<List<AppUser>>(
      stream: DataService.instance.watchUsers(collegeId),
      builder: (context, snap) {
        if (snap.hasError) {
          return Text(AuthService.describeError(snap.error!));
        }
        if (!snap.hasData) {
          return const Padding(
            padding: EdgeInsets.all(20),
            child: Center(child: CircularProgressIndicator()),
          );
        }

        final matches = snap.data!
            .where((u) => !u.isSuperAdmin)
            .where((u) => !excludeUids.contains(u.uid))
            .where(
              (u) =>
                  u.name.toLowerCase().contains(q) ||
                  (u.enrollmentNo ?? '').toLowerCase().contains(q) ||
                  (u.roomNumber ?? '').toLowerCase().contains(q),
            )
            .take(8)
            .toList();

        if (matches.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Text(
              'Nobody matches that.',
              style: TextStyle(color: AppColors.textMuted, fontSize: 13),
            ),
          );
        }

        return Container(
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              for (var i = 0; i < matches.length; i++) ...[
                InkWell(
                  onTap: () => onPick(matches[i]),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 11,
                    ),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 16,
                          backgroundColor: AppColors.primarySoft,
                          child: Text(
                            matches[i].initials,
                            style: TextStyle(
                              color: AppColors.primary,
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                matches[i].name,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _subtitleFor(matches[i]),
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: AppColors.textMuted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (i != matches.length - 1)
                  Divider(height: 1, color: AppColors.border),
              ],
            ],
          ),
        );
      },
    );
  }
}
