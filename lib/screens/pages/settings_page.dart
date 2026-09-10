import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/logo.dart';
import '../../core/permissions.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../models/college_settings.dart';
import '../../services/auth_service.dart';
import '../../services/data_service.dart';
import '../../services/fine_service.dart';
import '../../services/hostel_service.dart';
import '../../services/request_service.dart';
import '../../services/settings_service.dart';
import 'reset_student_data_dialog.dart';

/// Largest logo photo accepted, in bytes. Base64 adds ~33% on top, and this
/// document also carries the rest of the institution profile plus theming —
/// a much tighter budget than an office order gets its own document for.
const int _maxLogoBytes = 250 * 1024;

const Map<String, String> _logoMimeByExt = {
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'webp': 'image/webp',
};

/// Workspace configuration.
///
/// Five sections, each saving independently. Independent saves matter here:
/// these are unrelated concerns, and a single "Save everything" button means
/// changing the accent colour re-writes the fine categories someone else was
/// editing in another tab.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final session = Session.of(context);
    final collegeId = session.user.collegeId;

    if (!session.can(Perm.settingsManage)) {
      return AppCard(
        padding: const EdgeInsets.symmetric(vertical: 54),
        child: Center(
          child: Text(
            'You don\'t have permission to change system settings.',
            style: TextStyle(color: AppColors.textMuted),
          ),
        ),
      );
    }

    return StreamBuilder<CollegeSettings>(
      stream: SettingsService.instance.watch(collegeId),
      builder: (context, snap) {
        if (snap.hasError) {
          return AppCard(child: Text(AuthService.describeError(snap.error!)));
        }
        if (!snap.hasData) {
          return const Padding(
            padding: EdgeInsets.all(60),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final s = snap.data!;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SectionHeader('System Settings'),
                  const SizedBox(height: 4),
                  Text(
                    s.updatedByName == null
                        ? 'Configuration for this workspace.'
                        : 'Configuration for this workspace. '
                              'Last changed by ${s.updatedByName}.',
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            _InstitutionSection(
              collegeId: collegeId,
              collegeName: session.collegeName,
              value: s.institution,
            ),
            const SizedBox(height: 18),
            _ThemeSection(
              collegeId: collegeId,
              value: s.theming,
              logoBase64: s.institution.logoBase64,
            ),
            const SizedBox(height: 18),
            _SessionSection(collegeId: collegeId, value: s.session),
            const SizedBox(height: 18),
            _FineCategoriesSection(
              collegeId: collegeId,
              value: s.fineCategories,
            ),
            const SizedBox(height: 18),
            _TradesSection(collegeId: collegeId, value: s.trades),
            const SizedBox(height: 18),
            _DangerZone(collegeId: collegeId),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------- shared

class _Section extends StatelessWidget {
  final String title;
  final String blurb;
  final Widget child;
  final VoidCallback? onSave;
  final bool busy;
  final String? error;

  const _Section({
    required this.title,
    required this.blurb,
    required this.child,
    this.onSave,
    this.busy = false,
    this.error,
  });

  @override
  Widget build(BuildContext context) => AppCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 3),
        Text(
          blurb,
          style: TextStyle(fontSize: 12.5, color: AppColors.textMuted),
        ),
        const SizedBox(height: 18),
        child,
        if (error != null) ...[
          const SizedBox(height: 12),
          Text(
            error!,
            style: TextStyle(color: AppColors.danger, fontSize: 12.5),
          ),
        ],
        if (onSave != null) ...[
          const SizedBox(height: 18),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: busy ? null : onSave,
              child: busy
                  ? const SizedBox(
                      height: 17,
                      width: 17,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('Save'),
            ),
          ),
        ],
      ],
    ),
  );
}

class _Field extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String? hint;
  final bool enabled;
  final int lines;

  const _Field(
    this.controller,
    this.label, {
    this.hint,
    this.enabled = true,
    this.lines = 1,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: TextField(
      controller: controller,
      enabled: enabled,
      maxLines: lines,
      decoration: InputDecoration(labelText: label, hintText: hint),
    ),
  );
}

/// Wraps a save call with the busy/error handling every section repeats.
mixin _Saving<T extends StatefulWidget> on State<T> {
  bool busy = false;
  String? error;

  Future<void> save(Future<void> Function() run, String done) async {
    setState(() {
      busy = true;
      error = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      await run();
      messenger.showSnackBar(SnackBar(content: Text(done)));
    } catch (e) {
      if (mounted) setState(() => error = AuthService.describeError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
}

// ----------------------------------------------------------- institution

class _InstitutionSection extends StatefulWidget {
  final String collegeId;
  final String collegeName;
  final InstitutionProfile value;

  const _InstitutionSection({
    required this.collegeId,
    required this.collegeName,
    required this.value,
  });

  @override
  State<_InstitutionSection> createState() => _InstitutionSectionState();
}

class _InstitutionSectionState extends State<_InstitutionSection>
    with _Saving {
  late final Map<String, TextEditingController> _c;

  Uint8List? _logoBytes;
  String? _logoMimeType;

  /// Tracks whether the logo was touched this session, and how — untouched
  /// means "keep whatever's already saved" rather than re-sending the same
  /// bytes on every unrelated field edit.
  bool _logoRemoved = false;

  @override
  void initState() {
    super.initState();
    final v = widget.value;
    _c = {
      'name': TextEditingController(text: widget.collegeName),
      'shortName': TextEditingController(text: v.shortName ?? ''),
      'tagline': TextEditingController(text: v.tagline ?? ''),
      'address': TextEditingController(text: v.address ?? ''),
      'contactEmail': TextEditingController(text: v.contactEmail ?? ''),
      'contactPhone': TextEditingController(text: v.contactPhone ?? ''),
      'website': TextEditingController(text: v.website ?? ''),
    };
    if (v.hasLogo) {
      try {
        _logoBytes = base64Decode(v.logoBase64!);
        _logoMimeType = v.logoMimeType;
      } catch (_) {
        // Corrupt stored value — treat as no logo rather than crash the page.
      }
    }
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  String? _val(String k) {
    final t = _c[k]!.text.trim();
    return t.isEmpty ? null : t;
  }

  Future<void> _pickLogo() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jpg', 'jpeg', 'png', 'webp'],
      withData: true,
    );
    final file = result?.files.single;
    if (file == null || file.bytes == null) return;

    if (file.bytes!.lengthInBytes > _maxLogoBytes) {
      setState(() => error =
          'That image is too large (${(file.bytes!.lengthInBytes / 1024).round()} '
          'KB). Please keep it under ${_maxLogoBytes ~/ 1024} KB.');
      return;
    }

    final ext = file.extension?.toLowerCase() ?? '';
    setState(() {
      error = null;
      _logoBytes = file.bytes;
      _logoMimeType = _logoMimeByExt[ext] ?? 'image/jpeg';
      _logoRemoved = false;
    });
  }

  void _removeLogo() => setState(() {
    _logoBytes = null;
    _logoMimeType = null;
    _logoRemoved = true;
  });

  @override
  Widget build(BuildContext context) {
    final name = Session.of(context).user.name;
    return _Section(
      title: 'Institution profile',
      blurb: 'Shown in the sidebar, on the login screen and on reports.',
      busy: busy,
      error: error,
      onSave: () => save(() async {
        // The display name lives on the college document, because that is
        // what every user's session reads at login — not in settings.
        final typed = _c['name']!.text.trim();
        if (typed.isNotEmpty && typed != widget.collegeName) {
          await SettingsService.instance.renameCollege(widget.collegeId, typed);
        }
        await SettingsService.instance.saveInstitution(
          widget.collegeId,
          InstitutionProfile(
            shortName: _val('shortName'),
            tagline: _val('tagline'),
            address: _val('address'),
            contactEmail: _val('contactEmail'),
            contactPhone: _val('contactPhone'),
            website: _val('website'),
            logoBase64: _logoRemoved || _logoBytes == null
                ? null
                : base64Encode(_logoBytes!),
            logoMimeType: _logoRemoved ? null : _logoMimeType,
          ),
          byName: name,
        );
      }, 'Institution profile saved'),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: _logoBytes == null
                    ? Container(
                        height: 64,
                        width: 64,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: AppColors.canvas,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(
                          Icons.image_outlined,
                          color: AppColors.textMuted,
                        ),
                      )
                    : Image.memory(
                        _logoBytes!,
                        height: 64,
                        width: 64,
                        fit: BoxFit.cover,
                      ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'College logo',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textMuted,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Replaces the default mark in the sidebar. JPG/PNG/WebP, '
                      'under ${_maxLogoBytes ~/ 1024} KB.',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: AppColors.textMuted,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        OutlinedButton.icon(
                          onPressed: busy ? null : _pickLogo,
                          icon: const Icon(
                            Icons.upload_rounded,
                            size: 16,
                          ),
                          label: Text(
                            _logoBytes == null ? 'Upload logo' : 'Change logo',
                          ),
                        ),
                        if (_logoBytes != null) ...[
                          const SizedBox(width: 10),
                          TextButton(
                            onPressed: busy ? null : _removeLogo,
                            child: const Text('Remove'),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                flex: 2,
                child: _Field(
                  _c['name']!,
                  'Institution name',
                  hint: 'Sant Longowal Institute of Engineering & Technology',
                  enabled: !busy,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _Field(
                  _c['shortName']!,
                  'Short name',
                  hint: 'SLIET',
                  enabled: !busy,
                ),
              ),
            ],
          ),
          _Field(
            _c['tagline']!,
            'Tagline',
            hint: 'Hostel Management System',
            enabled: !busy,
          ),
          _Field(_c['address']!, 'Address', enabled: !busy, lines: 2),
          Row(
            children: [
              Expanded(
                child: _Field(
                  _c['contactEmail']!,
                  'Contact email',
                  enabled: !busy,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _Field(
                  _c['contactPhone']!,
                  'Contact phone',
                  enabled: !busy,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _Field(
                  _c['website']!,
                  'Website',
                  hint: 'https://sliet.ac.in',
                  enabled: !busy,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ----------------------------------------------------------------- theme

class _ThemeSection extends StatefulWidget {
  final String collegeId;
  final AppTheming value;
  final String? logoBase64;

  const _ThemeSection({
    required this.collegeId,
    required this.value,
    this.logoBase64,
  });

  @override
  State<_ThemeSection> createState() => _ThemeSectionState();
}

class _ThemeSectionState extends State<_ThemeSection> with _Saving {
  late String _preset = widget.value.presetId;
  late AppBrightness _brightness = widget.value.brightness;

  @override
  Widget build(BuildContext context) {
    final name = Session.of(context).user.name;
    final chosen = kThemePresets.firstWhere(
      (p) => p.id == _preset,
      orElse: () => kThemePresets.first,
    );

    return _Section(
      title: 'Appearance',
      blurb: 'Light or dark, and the accent colour used across the app.',
      busy: busy,
      error: error,
      onSave: () => save(
        () => SettingsService.instance.saveTheming(
          widget.collegeId,
          AppTheming(presetId: _preset, brightness: _brightness),
          byName: name,
        ),
        'Appearance saved',
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'MODE',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: AppColors.textMuted,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final b in AppBrightness.values)
                _ModeChip(
                  mode: b,
                  selected: b == _brightness,
                  accent: chosen.color,
                  onTap: busy ? null : () => setState(() => _brightness = b),
                ),
            ],
          ),
          const SizedBox(height: 22),
          Text(
            'ACCENT',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: AppColors.textMuted,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final p in kThemePresets)
                _Swatch(
                  preset: p,
                  selected: p.id == _preset,
                  onTap: busy ? null : () => setState(() => _preset = p.id),
                ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              WorkspaceLogo(
                logoBase64: widget.logoBase64,
                size: 54,
                background: chosen.color,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Preview — ${chosen.label}',
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: chosen.color,
                          ),
                          onPressed: () {},
                          child: const Text('Primary'),
                        ),
                        const SizedBox(width: 10),
                        OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: chosen.color,
                            side: BorderSide(
                              color: chosen.color.withValues(alpha: 0.4),
                            ),
                          ),
                          onPressed: () {},
                          child: const Text('Secondary'),
                        ),
                        const SizedBox(width: 10),
                        Container(
                          height: 26,
                          width: 90,
                          decoration: BoxDecoration(
                            color: chosen.color.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.infoSoft,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Text(
              'Applies across every screen the moment you save — sidebar, '
              'cards, charts, text and borders all follow. "Match device" '
              'tracks your system light/dark setting.',
              style: TextStyle(
                fontSize: 12,
                color: AppColors.info,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  final AppBrightness mode;
  final bool selected;
  final Color accent;
  final VoidCallback? onTap;

  const _ModeChip({
    required this.mode,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(10),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: selected ? accent.withValues(alpha: 0.10) : AppColors.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: selected ? accent : AppColors.border,
          width: selected ? 1.8 : 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            mode.icon,
            size: 18,
            color: selected ? accent : AppColors.textMuted,
          ),
          const SizedBox(width: 9),
          Text(
            mode.label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: selected ? accent : AppColors.textStrong,
            ),
          ),
        ],
      ),
    ),
  );
}

class _Swatch extends StatelessWidget {
  final ThemePreset preset;
  final bool selected;
  final VoidCallback? onTap;

  const _Swatch({
    required this.preset,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(10),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: selected ? preset.color.withValues(alpha: 0.10) : Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: selected ? preset.color : AppColors.border,
          width: selected ? 1.8 : 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            height: 20,
            width: 20,
            decoration: BoxDecoration(
              color: preset.color,
              borderRadius: BorderRadius.circular(6),
            ),
            child: selected
                ? const Icon(Icons.check_rounded, size: 14, color: Colors.white)
                : null,
          ),
          const SizedBox(width: 9),
          Text(
            preset.label,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    ),
  );
}

// --------------------------------------------------------------- session

class _SessionSection extends StatefulWidget {
  final String collegeId;
  final AcademicSession value;

  const _SessionSection({required this.collegeId, required this.value});

  @override
  State<_SessionSection> createState() => _SessionSectionState();
}

class _SessionSectionState extends State<_SessionSection> with _Saving {
  late final _current = TextEditingController(text: widget.value.current ?? '');
  late bool _odd = widget.value.oddSemester;

  @override
  void dispose() {
    _current.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final name = Session.of(context).user.name;
    final sems = (_odd ? const [1, 3, 5, 7] : const [2, 4, 6, 8]).join(', ');

    return _Section(
      title: 'Academic session',
      blurb: 'Which session and half of the year the institution is in.',
      busy: busy,
      error: error,
      onSave: () => save(
        () => SettingsService.instance.saveSession(
          widget.collegeId,
          AcademicSession(
            current: _current.text.trim().isEmpty
                ? null
                : _current.text.trim(),
            oddSemester: _odd,
          ),
          byName: name,
        ),
        'Academic session saved',
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 220,
                child: _Field(
                  _current,
                  'Current session',
                  hint: '2026-27',
                  enabled: !busy,
                ),
              ),
              const SizedBox(width: 16),
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true, label: Text('Odd semester')),
                    ButtonSegment(value: false, label: Text('Even semester')),
                  ],
                  selected: {_odd},
                  showSelectedIcon: false,
                  onSelectionChanged: busy
                      ? null
                      : (s) => setState(() => _odd = s.first),
                ),
              ),
            ],
          ),
          Text(
            'Semesters currently running: $sems',
            style: TextStyle(fontSize: 12.5, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

// -------------------------------------------------------- fine categories

class _FineCategoriesSection extends StatefulWidget {
  final String collegeId;
  final List<FineCategory> value;

  const _FineCategoriesSection({
    required this.collegeId,
    required this.value,
  });

  @override
  State<_FineCategoriesSection> createState() =>
      _FineCategoriesSectionState();
}

class _FineCategoriesSectionState extends State<_FineCategoriesSection>
    with _Saving {
  late final List<FineCategory> _rows =
      widget.value.isEmpty ? FineCategory.defaults : List.of(widget.value);

  @override
  Widget build(BuildContext context) {
    final name = Session.of(context).user.name;

    return _Section(
      title: 'Fine categories',
      blurb: 'The reasons offered when imposing a fine, and what each '
          'usually costs.',
      busy: busy,
      error: error,
      onSave: () => save(() {
        final clean = _rows
            .where((r) => r.name.trim().isNotEmpty)
            .map((r) => FineCategory(
                  name: r.name.trim(),
                  defaultAmount: r.defaultAmount,
                ))
            .toList();
        if (clean.isEmpty) {
          throw Exception('Keep at least one category.');
        }
        return SettingsService.instance.saveFineCategories(
          widget.collegeId,
          clean,
          byName: name,
        );
      }, 'Fine categories saved'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < _rows.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextFormField(
                      key: ValueKey('cat-$i'),
                      initialValue: _rows[i].name,
                      enabled: !busy,
                      decoration: const InputDecoration(
                        labelText: 'Reason',
                        isDense: true,
                      ),
                      onChanged: (v) => _rows[i] = FineCategory(
                        name: v,
                        defaultAmount: _rows[i].defaultAmount,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      key: ValueKey('amt-$i'),
                      initialValue: _rows[i].defaultAmount?.toString() ?? '',
                      enabled: !busy,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Default amount',
                        prefixText: '₹ ',
                        isDense: true,
                      ),
                      onChanged: (v) => _rows[i] = FineCategory(
                        name: _rows[i].name,
                        defaultAmount: num.tryParse(v.trim()),
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: busy || _rows.length == 1
                        ? null
                        : () => setState(() => _rows.removeAt(i)),
                    icon: const Icon(Icons.close_rounded, size: 18),
                    tooltip: 'Remove',
                  ),
                ],
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: busy
                  ? null
                  : () => setState(
                      () => _rows.add(const FineCategory(name: '')),
                    ),
              icon: const Icon(Icons.add_rounded, size: 17),
              label: const Text('Add category'),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Renaming a category does not change fines already imposed under '
            'the old name — those keep what they were issued with, which is '
            'what a record is for.',
            style: TextStyle(fontSize: 12, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- trades

class _TradesSection extends StatefulWidget {
  final String collegeId;
  final List<Trade> value;

  const _TradesSection({required this.collegeId, required this.value});

  @override
  State<_TradesSection> createState() => _TradesSectionState();
}

class _TradesSectionState extends State<_TradesSection> with _Saving {
  late final List<Trade> _rows = widget.value.isEmpty
      ? Trade.defaults
      : List.of(widget.value);

  @override
  Widget build(BuildContext context) {
    final name = Session.of(context).user.name;

    return _Section(
      title: 'Trades & branches',
      blurb: 'The programmes students can be recorded under. Offered '
          'everywhere a trade is picked, and used to group the fines '
          'dashboard.',
      busy: busy,
      error: error,
      onSave: () => save(() {
        final clean = <Trade>[];
        final seen = <String>{};
        for (final r in _rows) {
          final code = r.code.trim();
          if (code.isEmpty) continue;
          // Codes are the stored value on every student and fine, so a
          // duplicate would make two rows fight over the same records.
          if (!seen.add(code.toUpperCase())) {
            throw Exception('"$code" is listed twice — codes must be unique.');
          }
          clean.add(Trade(code: code, name: r.name?.trim()));
        }
        if (clean.isEmpty) {
          throw Exception('Keep at least one trade.');
        }
        return SettingsService.instance.saveTrades(
          widget.collegeId,
          clean,
          byName: name,
        );
      }, 'Trades saved'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < _rows.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  SizedBox(
                    width: 130,
                    child: TextFormField(
                      key: ValueKey('trade-code-$i'),
                      initialValue: _rows[i].code,
                      enabled: !busy,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(
                        labelText: 'Code',
                        hintText: 'GCS',
                        isDense: true,
                      ),
                      onChanged: (v) => _rows[i] = Trade(
                        code: v,
                        name: _rows[i].name,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      key: ValueKey('trade-name-$i'),
                      initialValue: _rows[i].name ?? '',
                      enabled: !busy,
                      decoration: const InputDecoration(
                        labelText: 'Name (optional)',
                        hintText: 'Computer Science & Engineering',
                        isDense: true,
                      ),
                      onChanged: (v) => _rows[i] = Trade(
                        code: _rows[i].code,
                        name: v,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: busy || _rows.length == 1
                        ? null
                        : () => setState(() => _rows.removeAt(i)),
                    icon: const Icon(Icons.close_rounded, size: 18),
                    tooltip: 'Remove',
                  ),
                ],
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: busy
                  ? null
                  : () => setState(() => _rows.add(const Trade(code: ''))),
              icon: const Icon(Icons.add_rounded, size: 17),
              label: const Text('Add trade'),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'The code is what gets stored on a student and snapshotted onto '
            'their fines, so changing one does not rewrite existing records — '
            'they keep the code they were saved with. Renaming is always '
            'safe; re-coding is not.',
            style: TextStyle(fontSize: 12, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------ danger zone

class _DangerZone extends StatefulWidget {
  final String collegeId;
  const _DangerZone({required this.collegeId});

  @override
  State<_DangerZone> createState() => _DangerZoneState();
}

class _DangerZoneState extends State<_DangerZone> {
  bool _busy = false;

  Future<void> _confirm({
    required String title,
    required String body,
    required String phrase,
    required Future<String> Function() run,
  }) async {
    final controller = TextEditingController();
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setLocal) => AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(body, style: const TextStyle(fontSize: 13, height: 1.5)),
                const SizedBox(height: 16),
                Text(
                  'Type $phrase to confirm',
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: InputDecoration(hintText: phrase, isDense: true),
                  onChanged: (_) => setLocal(() {}),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
              onPressed:
                  controller.text.trim().toUpperCase() == phrase
                  ? () => Navigator.pop(c, true)
                  : null,
              child: const Text('Do it'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (ok != true) return;

    setState(() => _busy = true);
    try {
      final result = await run();
      messenger.showSnackBar(SnackBar(content: Text(result)));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(AuthService.describeError(e))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Counts non-admin accounts before opening the reset dialog, so its
  /// confirmation states the real number rather than asking you to approve
  /// "everyone".
  Future<void> _resetAll(Session session) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);

    int count;
    try {
      final all = await DataService.instance.watchUsers(widget.collegeId).first;
      count = all.where((u) => !u.isSuperAdmin).length;
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(AuthService.describeError(e))),
      );
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }

    if (!mounted) return;
    await showDialog<bool>(
      context: context,
      // A half-finished sweep is worse than either finishing or stopping
      // deliberately, and Stop is right there.
      barrierDismissible: false,
      builder: (_) => ResetStudentDataDialog(
        collegeId: widget.collegeId,
        actor: session.user,
        studentCount: count,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = Session.of(context);

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded,
                  size: 19, color: AppColors.danger),
              const SizedBox(width: 8),
              Text(
                'Danger zone',
                style: TextStyle(
                  fontSize: 15.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.danger,
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            'Bulk resets for clearing test data. None of these can be undone '
            'from inside the app.',
            style: TextStyle(fontSize: 12.5, color: AppColors.textMuted),
          ),
          const SizedBox(height: 18),

          // The master reset, set apart from the rows below it. Those are
          // single-collection cleanups you reach for when one thing has gone
          // stale; this is the one that clears an intake end-to-end, and
          // burying it in the list is how you end up running four of the
          // others and still finding fee records left over.
          Container(
            padding: const EdgeInsets.all(15),
            decoration: BoxDecoration(
              color: AppColors.dangerSoft,
              borderRadius: BorderRadius.circular(11),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Delete ALL student data',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: AppColors.danger,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'One button for a clean slate: every profile, mess fee '
                        'record, fine, request and room assignment. Hostels, '
                        'rooms, college details, roles and Super Admins are '
                        'kept.',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: AppColors.danger,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                FilledButton(
                  onPressed: _busy ? null : () => _resetAll(session),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.danger,
                  ),
                  child: const Text('Delete all'),
                ),
              ],
            ),
          ),
          Divider(height: 26, color: AppColors.border),
          _DangerRow(
            label: 'Delete every fine',
            detail: 'Removes all fines, paid and unpaid. Students and rooms '
                'are untouched.',
            busy: _busy,
            onTap: () => _confirm(
              title: 'Delete every fine?',
              body: 'Every fine in this workspace will be removed — including '
                  'ones already marked paid. Student accounts, rooms and '
                  'office orders are not affected.',
              phrase: 'DELETE FINES',
              run: () async {
                final n = await FineService.instance.deleteAll(
                  widget.collegeId,
                );
                return 'Deleted $n fine(s)';
              },
            ),
          ),
          Divider(height: 26, color: AppColors.border),
          _DangerRow(
            label: 'Delete orphaned fines',
            detail: 'Removes fines belonging to students who no longer '
                'exist. Current students\' fines are untouched.',
            busy: _busy,
            onTap: () => _confirm(
              title: 'Delete orphaned fines?',
              body: 'Fines whose student no longer has an account — paid or '
                  'unpaid — will be removed. Fines from anyone still in the '
                  'system are not touched.',
              phrase: 'DELETE ORPHAN FINES',
              run: () async {
                final all = await DataService.instance
                    .watchUsers(widget.collegeId)
                    .first;
                final liveUids = all.map((u) => u.uid).toSet();
                final n = await FineService.instance.deleteOrphaned(
                  widget.collegeId,
                  liveUids,
                );
                return 'Deleted $n orphaned fine(s)';
              },
            ),
          ),
          Divider(height: 26, color: AppColors.border),
          _DangerRow(
            label: 'Delete every non-admin account',
            detail: 'Removes all student and staff profiles, freeing their '
                'rooms. Super Admins and you are kept.',
            busy: _busy,
            onTap: () => _confirm(
              title: 'Delete every non-admin account?',
              body: 'Every profile in this workspace except Super Admins and '
                  'your own will be deleted, and any rooms they hold freed.\n\n'
                  'Their sign-in accounts are NOT removed — the app cannot do '
                  'that. Re-importing the same registration numbers in-app '
                  'will fail with "email already in use". For a complete wipe '
                  'run tools/delete-students.js instead.',
              phrase: 'DELETE ACCOUNTS',
              run: () async {
                final all = await DataService.instance
                    .watchUsers(widget.collegeId)
                    .first;
                final targets = all
                    .where((u) => !u.isSuperAdmin)
                    .where((u) => u.uid != session.user.uid)
                    .toList();
                final outcome = await DataService.instance.deleteUserProfiles(
                  collegeId: widget.collegeId,
                  users: targets,
                );
                return 'Deleted ${outcome.deleted} profile(s), '
                    'freed ${outcome.vacated} bed(s), '
                    'removed ${outcome.finesDeleted} fine(s), '
                    '${outcome.requestsDeleted} request(s)';
              },
            ),
          ),
          Divider(height: 26, color: AppColors.border),
          _DangerRow(
            label: 'Delete orphaned requests',
            detail: 'Removes requests raised by people who no longer exist. '
                'Current students\' requests are untouched.',
            busy: _busy,
            onTap: () => _confirm(
              title: 'Delete orphaned requests?',
              body: 'Leave applications, complaints and room-change requests '
                  'whose author no longer has an account will be removed. '
                  'Requests from anyone still in the system — pending or '
                  'already decided — are not touched.',
              phrase: 'DELETE ORPHANS',
              run: () async {
                final all = await DataService.instance
                    .watchUsers(widget.collegeId)
                    .first;
                final liveUids = all.map((u) => u.uid).toSet();
                final n = await RequestService.instance.deleteOrphaned(
                  widget.collegeId,
                  liveUids,
                );
                return 'Deleted $n orphaned request(s)';
              },
            ),
          ),
          Divider(height: 26, color: AppColors.border),
          _DangerRow(
            label: 'Empty all rooms',
            detail: 'Clears every room\'s occupants and resets occupancy to '
                'zero. Use if deleted students are still shown occupying a '
                'room.',
            busy: _busy,
            onTap: () => _confirm(
              title: 'Empty all rooms?',
              body: 'Every room in every hostel will be marked unoccupied, '
                  'and each hostel\'s occupied-bed count reset to zero. Do '
                  'this only when nobody actually holds a room — it does not '
                  'check who still needs one.',
              phrase: 'EMPTY ROOMS',
              run: () async {
                final result = await HostelService.instance.emptyAllRooms(
                  widget.collegeId,
                );
                return 'Cleared ${result.roomsCleared} room(s), freed '
                    '${result.bedsFreed} bed(s)';
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _DangerRow extends StatelessWidget {
  final String label;
  final String detail;
  final bool busy;
  final VoidCallback onTap;

  const _DangerRow({
    required this.label,
    required this.detail,
    required this.busy,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              detail,
              style: TextStyle(
                fontSize: 12.5,
                color: AppColors.textMuted,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
      const SizedBox(width: 16),
      OutlinedButton(
        onPressed: busy ? null : onTap,
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.danger,
          side: BorderSide(color: AppColors.dangerSoft),
        ),
        child: const Text('Run'),
      ),
    ],
  );
}
