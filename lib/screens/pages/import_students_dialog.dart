import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme.dart';
import '../../models/app_role.dart';
import '../../models/app_user.dart';
import '../../models/hostel.dart';
import '../../services/auth_service.dart';
import '../../services/csv_import.dart';

/// Bulk import: paste a sheet, check the preview, run it.
///
/// Three explicit steps, and nothing is written until you've seen exactly what
/// will happen. Imports get run twice by accident constantly, so the preview
/// isn't a nicety — it's the safety mechanism.
class ImportStudentsDialog extends StatefulWidget {
  /// Passed in rather than read from the context.
  ///
  /// `showDialog` pushes a route onto the *root* Navigator, so this widget's
  /// context is a sibling of the dashboard's — not a descendant. `SessionScope`
  /// lives below that Navigator (see `auth_gate.dart`), which means
  /// `Session.of(context)` inside a dialog finds nothing and throws. The caller
  /// reads the session from the page's own context and hands us the one value
  /// we actually need.
  final String collegeId;

  final List<AppUser> existingUsers;
  final List<AppRole> roles;
  final List<Hostel> hostels;

  /// The college's trade list, passed in for the same reason as [collegeId].
  final List<String> knownTrades;

  const ImportStudentsDialog({
    super.key,
    required this.collegeId,
    required this.existingUsers,
    required this.roles,
    this.hostels = const [],
    this.knownTrades = kTrades,
  });

  @override
  State<ImportStudentsDialog> createState() => _ImportStudentsDialogState();
}

class _ImportStudentsDialogState extends State<ImportStudentsDialog> {
  final _paste = TextEditingController();

  int _step = 0; // 0 paste · 1 preview · 2 running/done
  ImportPlan? _plan;
  String? _parseError;
  String _defaultRole = '';

  bool _running = false;
  bool _stopRequested = false;
  int _done = 0;
  int _total = 0;
  String _currentLabel = '';
  ImportPhase? _phase;
  ImportOutcome? _outcome;

  /// A failure that killed the whole run, as opposed to a single bad row.
  /// Without this the dialog would sit on "0 of N" forever with no
  /// explanation, because the exception escaped _run() silently.
  String? _fatalError;

  /// Mirrors "is the paste box non-empty", so the Preview button can enable
  /// itself. Without a listener the button's onPressed is only evaluated on
  /// rebuild, and typing alone never triggers one.
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _paste.addListener(() {
      final has = _paste.text.trim().isNotEmpty;
      if (has != _hasText) setState(() => _hasText = has);
    });
    final assignable = widget.roles.where((r) => !r.isSystem).toList();
    final student = assignable.where((r) => r.name.toLowerCase() == 'student');
    _defaultRole = student.isNotEmpty
        ? student.first.name
        : (assignable.isEmpty ? '' : assignable.first.name);
  }

  @override
  void dispose() {
    _paste.dispose();
    super.dispose();
  }

  void _analyse() {
    final table = parseDelimited(_paste.text);
    if (table.isEmpty) {
      setState(
        () => _parseError =
            'Nothing to import. Paste at least a header row and one data row.',
      );
      return;
    }
    setState(() {
      _parseError = null;
      _plan = analyseImport(
        table: table,
        existingUsers: widget.existingUsers,
        roles: widget.roles,
        hostels: widget.hostels,
        defaultRoleName: _defaultRole,
        knownTrades: widget.knownTrades,
      );
      _step = 1;
    });
  }

  Future<void> _run() async {
    final plan = _plan!;
    final collegeId = widget.collegeId;

    // Move to the progress step FIRST, and put every subsequent statement
    // inside the try. Anything thrown before this point would land in a
    // Future that `onPressed` discards — an unhandled async error that shows
    // up only as an engine stack trace in the browser console, with the
    // dialog sitting there looking fine. This is how the Session lookup that
    // used to live here stayed invisible.
    setState(() {
      _step = 2;
      _running = true;
      _stopRequested = false;
      _fatalError = null;
      _done = 0;
      _total = plan.rows.where((r) => r.isValid).length;
    });

    try {
      final outcome = await runImport(
        plan: plan,
        collegeId: collegeId,
        onProgress: (phase, done, total, label) {
          if (mounted) {
            setState(() {
              _phase = phase;
              _done = done;
              _total = total;
              _currentLabel = label;
            });
          }
        },
        isCancelled: () => _stopRequested,
      );
      if (mounted) setState(() => _outcome = outcome);
    } catch (e, st) {
      debugPrint('Import failed: $e\n$st');
      if (mounted) {
        setState(() => _fatalError = AuthService.describeError(e));
      }
    } finally {
      // Must run whatever happened, or the dialog stays stuck on "Working…".
      if (mounted) setState(() => _running = false);
    }
  }

  /// AlertDialog's own horizontal inset, plus its content padding. Anything
  /// wider than the window minus this overflows instead of shrinking.
  static const double _dialogChrome = 40 * 2 + 24 * 2;

  double _contentWidth(BuildContext context) {
    final room = MediaQuery.of(context).size.width - _dialogChrome;
    // The paste box doesn't benefit from extra width; the grid does.
    return _step == 1 ? room.clamp(320.0, 1180.0) : room.clamp(320.0, 720.0);
  }

  double _contentHeight(BuildContext context) {
    final room = MediaQuery.of(context).size.height - 220;
    return _step == 1 ? room.clamp(320.0, 760.0) : room.clamp(320.0, 540.0);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(switch (_step) {
        0 => 'Import people from a spreadsheet',
        1 => 'Check before importing',
        _ => _running ? 'Importing…' : 'Import finished',
      }),
      // The preview earns more room than the other two steps: it is a
      // spreadsheet, and 720px shows about four columns of one.
      //
      // Sized against the window *minus the dialog's own inset padding* —
      // asking for more than that overflows rather than shrinking, since a
      // SizedBox is a demand, not a request.
      content: SizedBox(
        width: _contentWidth(context),
        height: _contentHeight(context),
        child: switch (_step) {
          0 => _PasteStep(
            controller: _paste,
            error: _parseError,
            roles: widget.roles.where((r) => !r.isSystem).toList(),
            defaultRole: _defaultRole,
            onDefaultRoleChanged: (v) => setState(() => _defaultRole = v),
          ),
          1 => _PreviewStep(plan: _plan!),
          _ => _RunStep(
            running: _running,
            stopRequested: _stopRequested,
            done: _done,
            total: _total,
            phase: _phase,
            label: _currentLabel,
            outcome: _outcome,
            fatalError: _fatalError,
          ),
        },
      ),
      actions: switch (_step) {
        0 => [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _hasText ? _analyse : null,
            child: const Text('Preview'),
          ),
        ],
        1 => [
          TextButton(
            onPressed: () => setState(() => _step = 0),
            child: const Text('Back'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: (_plan?.canRun ?? false) ? _run : null,
            child: Text(
              _plan == null
                  ? 'Import'
                  : (_plan!.creates + _plan!.updates == 0
                        ? 'Nothing to import'
                        : 'Import ${_plan!.creates + _plan!.updates}'),
            ),
          ),
        ],
        _ => [
          if (_running)
            TextButton(
              onPressed: _stopRequested
                  ? null
                  : () => setState(() => _stopRequested = true),
              child: Text(_stopRequested ? 'Stopping…' : 'Stop'),
            )
          else
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
        ],
      },
    );
  }
}

// ------------------------------- step 1 -------------------------------

class _PasteStep extends StatelessWidget {
  final TextEditingController controller;
  final String? error;
  final List<AppRole> roles;
  final String defaultRole;
  final ValueChanged<String> onDefaultRoleChanged;

  const _PasteStep({
    required this.controller,
    required this.error,
    required this.roles,
    required this.defaultRole,
    required this.onDefaultRoleChanged,
  });

  /// Reads a CSV/TSV from the user's computer into the paste box — the same
  /// text pasting would put there, so preview and import are unchanged. All
  /// in the browser: nothing is uploaded anywhere, so no Storage (and no
  /// Blaze plan) is involved. Excel's own .xlsx isn't read — save as CSV.
  Future<void> _pickFile(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv', 'tsv', 'txt'],
      withData: true,
    );
    final file = result?.files.single;
    if (file == null || file.bytes == null) return;
    // Excel writes a UTF-8 BOM, and sometimes stray non-UTF-8 bytes in a name;
    // neither should stop a 2,000-row import at the first character.
    var text = utf8.decode(file.bytes!, allowMalformed: true);
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    if (text.trim().isEmpty) {
      messenger.showSnackBar(SnackBar(content: Text('${file.name} is empty.')));
      return;
    }
    controller.text = text;
    final rows = '\n'.allMatches(text.trimRight()).length;
    messenger.showSnackBar(
      SnackBar(content: Text('Loaded ${file.name} — $rows data row(s).')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Choose a CSV file, or open it in Excel or Notepad, select '
          'everything, copy, and paste it below. Each row needs a name and '
          'either a registration number or an email — every other column can '
          'be left blank.',
          style: TextStyle(
            fontSize: 13,
            color: AppColors.textMuted,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 14),
        // Wrap rather than Row + Spacer: the two buttons and the role
        // dropdown need ~824px side by side and this step is 720 wide, so a
        // Row clipped the dropdown off the right edge at every window size.
        Wrap(
          spacing: 10,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              onPressed: () => _pickFile(context),
              icon: const Icon(Icons.upload_file_rounded, size: 18),
              label: const Text('Choose CSV file…'),
            ),
            OutlinedButton.icon(
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(text: templateHeaderRow()),
                );
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Header row copied — paste into Excel'),
                    ),
                  );
                }
              },
              icon: const Icon(Icons.copy_rounded, size: 17),
              label: const Text('Copy template headers'),
            ),
            OutlinedButton.icon(
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(text: templateWithExample()),
                );
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Template + example copied')),
                  );
                }
              },
              icon: const Icon(Icons.description_outlined, size: 17),
              label: const Text('With example row'),
            ),
            if (roles.isNotEmpty)
              SizedBox(
                width: 210,
                child: DropdownButtonFormField<String>(
                  initialValue: roles.any((r) => r.name == defaultRole)
                      ? defaultRole
                      : roles.first.name,
                  isDense: true,
                  decoration: const InputDecoration(
                    labelText: 'Role if column is blank',
                    isDense: true,
                  ),
                  items: roles
                      .map(
                        (r) => DropdownMenuItem(
                          value: r.name,
                          child: Text(r.name),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => onDefaultRoleChanged(v ?? ''),
                ),
              ),
          ],
        ),
        const SizedBox(height: 14),
        if (error != null) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.dangerSoft,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              error!,
              style: TextStyle(color: AppColors.danger, fontSize: 13),
            ),
          ),
          const SizedBox(height: 12),
        ],
        Expanded(
          child: TextField(
            controller: controller,
            maxLines: null,
            expands: true,
            textAlignVertical: TextAlignVertical.top,
            style: const TextStyle(fontSize: 12.5, fontFamily: 'monospace'),
            decoration: const InputDecoration(
              hintText:
                  'name,email,role,enrollmentNo,...\n'
                  'Aarav Sharma,aarav@sliet.ac.in,Student,21CS128,...',
              alignLabelWithHint: true,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Tabs or commas both work, so a direct copy out of Excel is fine.',
          style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
        ),
      ],
    );
  }
}

// ------------------------------- step 2 -------------------------------

class _PreviewStep extends StatelessWidget {
  final ImportPlan plan;
  const _PreviewStep({required this.plan});

  @override
  Widget build(BuildContext context) {
    if (plan.missingColumns.isNotEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline_rounded,
              size: 42,
              color: AppColors.danger,
            ),
            const SizedBox(height: 14),
            Text(
              'Missing required column${plan.missingColumns.length == 1 ? '' : 's'}: '
              '${plan.missingColumns.join(', ')}',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              'Go back and make sure your first pasted line is the header row.',
              style: TextStyle(color: AppColors.textMuted, fontSize: 13),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (plan.creates + plan.updates == 0) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: AppColors.dangerSoft,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              'Nothing can be imported — all ${plan.skips} row(s) were '
              'skipped, so the Import button is disabled. The reason for '
              'each row is shown in red below. The usual cause is a role '
              'name in the sheet that does not exist yet.',
              style: TextStyle(
                color: AppColors.danger,
                fontSize: 12.5,
                height: 1.4,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 14),
        ],
        // Wrap, not Row: five tallies need about 800px and the dialog is
        // narrower than that on a small window, where a Row silently clips
        // the last two counts instead of moving them to a second line.
        Wrap(
          spacing: 26,
          runSpacing: 10,
          children: [
            _Tally('Will create', plan.creates, AppColors.success),
            _Tally('Will update', plan.updates, AppColors.primary),
            _Tally('Skipped', plan.skips, AppColors.danger),
            _Tally('Rooms allotted', plan.allotments, AppColors.info),
            _Tally('Hostel only', plan.hostelOnlyAllotments, AppColors.info),
          ],
        ),
        if (plan.unknownColumns.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            'Ignored column${plan.unknownColumns.length == 1 ? '' : 's'}: '
            '${plan.unknownColumns.join(', ')}',
            style: TextStyle(
              fontSize: 12.5,
              color: AppColors.warning,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
        const SizedBox(height: 12),
        Expanded(child: _SheetGrid(plan: plan)),
      ],
    );
  }
}

/// The pasted sheet, laid out as a sheet.
///
/// A vertical list of summary tiles answered "what will happen to row 40?"
/// but not "does column K look right?", which is the question someone
/// actually opens a 2,000-row file to check. This shows the grid they pasted,
/// with the import's verdict attached to each line.
///
/// Two scroll axes, arranged so the header cannot drift out of step with the
/// body: the horizontal scroll wraps *both* the header row and the list, so
/// they move together for free and no controller has to be synchronised. The
/// vertical scroll lives inside the list, which leaves the header pinned.
class _SheetGrid extends StatefulWidget {
  final ImportPlan plan;
  const _SheetGrid({required this.plan});

  @override
  State<_SheetGrid> createState() => _SheetGridState();
}

class _SheetGridState extends State<_SheetGrid> {
  final _h = ScrollController();
  final _v = ScrollController();

  static const double _numberWidth = 46;
  static const double _statusWidth = 78;
  static const double _issueWidth = 210;
  static const double _rowHeight = 34;

  late List<String> _columns;
  late Map<String, double> _widths;

  @override
  void initState() {
    super.initState();
    _measure();
  }

  @override
  void didUpdateWidget(_SheetGrid old) {
    super.didUpdateWidget(old);
    if (old.plan != widget.plan) _measure();
  }

  /// Rough auto-fit, like a spreadsheet sizing a column to its contents.
  ///
  /// Sampled rather than exhaustive: a 2,600-row file would otherwise measure
  /// 75,000 cells to set 29 widths, and the first hundred rows already tell
  /// you whether a column holds "M" or a postal address.
  void _measure() {
    _columns = widget.plan.headers.isNotEmpty
        ? widget.plan.headers
        : kImportColumns;

    final sample = widget.plan.rows.take(100);
    _widths = {
      for (final col in _columns)
        col: () {
          var chars = col.length;
          for (final row in sample) {
            final v = row.values[col];
            if (v != null && v.length > chars) chars = v.length;
          }
          return (chars * 7.6 + 26).clamp(72.0, 260.0);
        }(),
    };
  }

  @override
  void dispose() {
    _h.dispose();
    _v.dispose();
    super.dispose();
  }

  double get _totalWidth =>
      _numberWidth +
      _statusWidth +
      _issueWidth +
      _columns.fold(0.0, (sum, c) => sum + _widths[c]!);

  @override
  Widget build(BuildContext context) {
    final rows = widget.plan.rows;

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      // Both scrollbars keep the default depth==0 predicate: each one's own
      // scrollable is its immediate descendant, and the inner list's
      // notifications bubble up to this one at depth 1, where ignoring them
      // is exactly what's wanted.
      child: Scrollbar(
        controller: _h,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: _h,
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: _totalWidth,
            child: Column(
              children: [
                _header(),
                Divider(height: 1, color: AppColors.border),
                Expanded(
                  child: Scrollbar(
                    controller: _v,
                    thumbVisibility: true,
                    child: ListView.builder(
                      controller: _v,
                      itemExtent: _rowHeight,
                      itemCount: rows.length,
                      itemBuilder: (context, i) => _row(rows[i], i),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() {
    Widget cell(String text, double width, {bool ignored = false}) => Container(
      width: width,
      height: _rowHeight,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: AppColors.border)),
      ),
      child: Text(
        text,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.2,
          // An ignored column is shown, not hidden — seeing it greyed out is
          // how you find out the app never understood that header.
          color: ignored ? AppColors.textMuted : null,
          fontStyle: ignored ? FontStyle.italic : null,
          decoration: ignored ? TextDecoration.lineThrough : null,
        ),
      ),
    );

    final ignored = widget.plan.unknownColumns.toSet();

    return ColoredBox(
      color: AppColors.canvas,
      child: Row(
        children: [
          cell('#', _numberWidth),
          cell('Status', _statusWidth),
          cell('Issue', _issueWidth),
          for (final col in _columns)
            Tooltip(
              message: ignored.contains(col)
                  ? '$col — not a column this import understands, so it is '
                        'ignored'
                  : col,
              child: cell(col, _widths[col]!, ignored: ignored.contains(col)),
            ),
        ],
      ),
    );
  }

  Widget _row(ImportRow row, int index) {
    final (label, color, bg) = switch (row.action) {
      RowAction.create => ('NEW', AppColors.success, AppColors.successSoft),
      RowAction.update => ('UPDATE', AppColors.primary, AppColors.primarySoft),
      RowAction.skip => ('SKIP', AppColors.danger, AppColors.dangerSoft),
    };

    // The tint is what keeps a row's verdict readable once it is scrolled
    // past the status column — colour survives horizontal scrolling, a pill
    // does not.
    final tint = switch (row.action) {
      RowAction.skip => AppColors.dangerSoft,
      RowAction.update => AppColors.primarySoft,
      RowAction.create => index.isEven ? AppColors.canvas : null,
    };

    Widget cell(Widget child, double width, {Color? fg}) => Container(
      width: width,
      height: _rowHeight,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: AppColors.border)),
      ),
      child: child,
    );

    Widget text(String value, double width, {Color? fg, FontWeight? weight}) =>
        cell(
          Text(
            value,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: fg, fontWeight: weight),
          ),
          width,
        );

    final issue = row.problems.isNotEmpty
        ? row.problems.join(' · ')
        : row.warnings.join(' · ');

    return ColoredBox(
      color: tint ?? Colors.transparent,
      child: Row(
        children: [
          text(
            '${row.lineNumber}',
            _numberWidth,
            fg: AppColors.textMuted,
            weight: FontWeight.w600,
          ),
          cell(StatusPill(label, color, bg), _statusWidth),
          Tooltip(
            message: issue,
            waitDuration: const Duration(milliseconds: 400),
            child: text(
              issue,
              _issueWidth,
              fg: row.problems.isNotEmpty
                  ? AppColors.danger
                  : AppColors.warning,
              weight: FontWeight.w600,
            ),
          ),
          for (final col in _columns)
            text(row.values[col] ?? '', _widths[col]!),
        ],
      ),
    );
  }
}

class _Tally extends StatelessWidget {
  final String label;
  final int value;
  final Color color;
  const _Tally(this.label, this.value, this.color);

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: AppColors.textMuted,
        ),
      ),
      Text(
        '$value',
        style: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    ],
  );
}

// ------------------------------- step 3 -------------------------------

class _RunStep extends StatelessWidget {
  final bool running;
  final bool stopRequested;
  final int done;
  final int total;
  final String label;

  /// Which part is running — each phase counts its own students, so "of N"
  /// always means students, never units of work.
  final ImportPhase? phase;
  final ImportOutcome? outcome;
  final String? fatalError;

  const _RunStep({
    required this.running,
    required this.stopRequested,
    required this.done,
    required this.total,
    required this.label,
    this.phase,
    required this.outcome,
    this.fatalError,
  });

  @override
  Widget build(BuildContext context) {
    if (fatalError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline_rounded,
              size: 42,
              color: AppColors.danger,
            ),
            const SizedBox(height: 14),
            const Text(
              'The import stopped',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 30),
              child: Text(
                fatalError!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.danger,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              done == 0
                  ? 'Nothing was written.'
                  : '$done row(s) were processed before it stopped. '
                        'Re-running is safe — existing people are updated, '
                        'not duplicated.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textMuted, fontSize: 12.5),
            ),
          ],
        ),
      );
    }

    if (running) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (phase != null) ...[
            Text(
              phase!.label,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
          ],
          Text(
            '$done of $total',
            style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800),
          ),
          Text(
            'students',
            style: TextStyle(fontSize: 12.5, color: AppColors.textMuted),
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: total == 0 ? null : done / total,
              minHeight: 8,
              backgroundColor: AppColors.border,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            label,
            style: TextStyle(color: AppColors.textMuted, fontSize: 13),
          ),
          const SizedBox(height: 22),
          Text(
            stopRequested
                ? 'Stopping after the student currently being imported…'
                : 'Please leave this window open until it finishes.',
            style: TextStyle(
              color: stopRequested ? AppColors.warning : AppColors.textMuted,
              fontSize: 12.5,
              fontWeight: stopRequested ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ],
      );
    }

    final o = outcome;
    if (o == null) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _Tally('Created', o.created, AppColors.success),
            const SizedBox(width: 26),
            _Tally('Updated', o.updated, AppColors.primary),
            const SizedBox(width: 26),
            _Tally('Rooms allotted', o.allotted, AppColors.info),
            const SizedBox(width: 26),
            _Tally('Hostel only', o.hostelOnly, AppColors.info),
            const SizedBox(width: 26),
            _Tally('Failed', o.failures.length, AppColors.danger),
          ],
        ),
        const SizedBox(height: 18),
        if (o.stoppedEarly)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 14),
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: AppColors.warningSoft,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              'Stopped early — ${o.remaining} row(s) were never attempted. '
              'Re-run the same file to pick up where this left off; rows '
              'already imported are matched by email and updated, not '
              'duplicated.',
              style: TextStyle(
                fontSize: 12.5,
                color: AppColors.warning,
                height: 1.45,
              ),
            ),
          ),
        if (o.created > 0)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: AppColors.infoSoft,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Text(
              'New students were added as records only — they have no sign-in '
              'account yet. Everything else (filters, rooms, fines, office '
              'orders) works for them as normal. To let one sign in, a Super '
              'Admin opens their record and uses "Create login account".',
              style: TextStyle(
                fontSize: 12.5,
                color: Color(0xFF075985),
                height: 1.45,
              ),
            ),
          ),
        if (o.allotmentIssues.isNotEmpty) ...[
          const SizedBox(height: 14),
          const Text(
            'Students were added, but these rooms could not be allotted:',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 90,
            child: ListView(
              children: o.allotmentIssues
                  .map(
                    (f) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        f,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: AppColors.warning,
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
        if (o.failures.isNotEmpty) ...[
          const SizedBox(height: 16),
          const Text(
            'These rows failed — fix them and paste just those rows again:',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(
              children: o.failures
                  .map(
                    (f) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        f,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: AppColors.danger,
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
      ],
    );
  }
}
