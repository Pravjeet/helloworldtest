import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../models/hostel.dart';
import '../../services/auth_service.dart';
import '../../services/hostel_service.dart';
import '../../widgets/selectable_chips.dart';

/// Create or edit a hostel.
///
/// On create it also collects the room-generation plan (floors x rooms per
/// floor, plus optional extra seater types) and writes every room. On edit
/// that section is hidden, because the rooms already exist — use "Add floor"
/// or the room editor to change them.
class HostelEditorDialog extends StatefulWidget {
  final String collegeId;

  /// Null when creating. When editing, the room generator is hidden — rooms
  /// already exist and are managed from the hostel's own page.
  final Hostel? hostel;

  const HostelEditorDialog({super.key, required this.collegeId, this.hostel});

  @override
  State<HostelEditorDialog> createState() => HostelEditorDialogState();
}

class HostelEditorDialogState extends State<HostelEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _code;
  late final TextEditingController _address;

  final _floors = TextEditingController(text: '4');

  /// True while every floor is built the same way — the usual case, and what
  /// keeps a 10-floor hostel a two-field form. Turning it off seeds every
  /// floor from the shared layout, so customising one floor never means
  /// retyping the other nine.
  bool _sameEveryFloor = true;

  /// The layout applied to every floor while [_sameEveryFloor] is on.
  final List<_GroupDraft> _sharedGroups = [
    _GroupDraft(capacity: 2, rooms: '25'),
  ];

  /// Per-floor layouts, index 0 == floor 1. Only read when [_sameEveryFloor]
  /// is off, and kept the same length as the floor count by
  /// [_syncFloorGroups].
  final List<List<_GroupDraft>> _floorGroups = [];

  late HostelGender _gender;
  late Set<String> _amenities;
  Set<String> _roomFeatures = {'Ceiling Fan', 'Study Table'};

  bool _busy = false;
  String? _error;

  /// When editing, the room-plan fields are hidden behind this — set once
  /// the admin explicitly opts into replacing the existing room layout.
  bool _regenerateRooms = false;

  bool get _isEditing => widget.hostel != null;

  /// Whether the room-plan fields below should currently be shown and
  /// included in [_save].
  bool get _showRoomPlan => !_isEditing || _regenerateRooms;

  @override
  void initState() {
    super.initState();
    final h = widget.hostel;
    _name = TextEditingController(text: h?.name ?? '');
    _code = TextEditingController(text: h?.code ?? '');
    _address = TextEditingController(text: h?.address ?? '');
    _gender = h?.gender ?? HostelGender.boys;
    _amenities = {...?h?.amenities};
  }

  @override
  void dispose() {
    for (final c in [_name, _code, _address, _floors]) {
      c.dispose();
    }
    for (final g in _sharedGroups) {
      g.dispose();
    }
    for (final floor in _floorGroups) {
      for (final g in floor) {
        g.dispose();
      }
    }
    super.dispose();
  }

  int get _floorCount => (int.tryParse(_floors.text) ?? 0).clamp(0, 20);

  /// Grows or trims [_floorGroups] to match the floor count. New floors are
  /// copied from the shared layout rather than starting empty — an added
  /// floor is nearly always "another one like the others".
  void _syncFloorGroups() {
    final n = _floorCount;
    while (_floorGroups.length < n) {
      _floorGroups.add([for (final g in _sharedGroups) g.copy()]);
    }
    while (_floorGroups.length > n) {
      for (final g in _floorGroups.removeLast()) {
        g.dispose();
      }
    }
  }

  /// Adds a room type to [target], defaulting to a capacity not already used
  /// there — a second row duplicating the first is never what's wanted.
  void _addGroup(List<_GroupDraft> target) => setState(() {
    final used = target.map((g) => g.capacity).toSet();
    final next = [1, 2, 3, 4, 5, 6].firstWhere(
      (c) => !used.contains(c),
      orElse: () => 1,
    );
    target.add(_GroupDraft(capacity: next, rooms: '25'));
  });

  void _removeGroup(List<_GroupDraft> target, int index) => setState(() {
    target.removeAt(index).dispose();
  });

  /// Pushes one floor's layout onto every other floor — for the building
  /// where the ground floor is the odd one out and floors 2–10 all match it
  /// after a tweak.
  void _copyFloorToAll(int source) => setState(() {
    final master = _floorGroups[source];
    for (var i = 0; i < _floorGroups.length; i++) {
      if (i == source) continue;
      for (final g in _floorGroups[i]) {
        g.dispose();
      }
      _floorGroups[i] = [for (final g in master) g.copy()];
    }
  });

  List<RoomGroup> _toGroups(List<_GroupDraft> drafts, List<String> features) => [
    for (final d in drafts)
      RoomGroup(
        capacity: d.capacity,
        rooms: int.tryParse(d.rooms.text) ?? 0,
        features: features,
      ),
  ];

  RoomPlan get _plan {
    final features = _roomFeatures.toList();
    if (_sameEveryFloor) {
      return RoomPlan.uniform(
        floors: _floorCount,
        groups: _toGroups(_sharedGroups, features),
      );
    }
    return RoomPlan(
      floorPlans: [
        for (var i = 0; i < _floorCount; i++)
          FloorPlan(
            groups: i < _floorGroups.length
                ? _toGroups(_floorGroups[i], features)
                : const [],
          ),
      ],
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    final plan = _plan;
    if (_showRoomPlan && plan.totalRooms > 2000) {
      setState(
        () => _error =
            'That would create ${plan.totalRooms} rooms. Cap it at 2000 — '
            'split very large blocks into separate hostels instead.',
      );
      return;
    }
    if (_showRoomPlan && plan.exceedsFloorLimit) {
      setState(
        () => _error =
            'A floor can hold at most $kMaxRoomsPerFloor rooms, because room '
            'numbers are floor-prefixed — a 100th room on floor 3 would be '
            'numbered 400 and collide with floor 4. Split that floor in two.',
      );
      return;
    }
    if (_showRoomPlan && plan.totalRooms == 0) {
      setState(
        () => _error = 'Add at least one room type with a room count above 0.',
      );
      return;
    }

    final messenger = ScaffoldMessenger.of(context);

    if (_regenerateRooms) {
      final confirmed = await _confirmRegenerate(context, plan);
      if (confirmed != true || !mounted) return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      if (_isEditing) {
        await HostelService.instance.updateHostel(
          widget.collegeId,
          widget.hostel!.copyWith(
            name: _name.text.trim(),
            code: _code.text.trim().toUpperCase(),
            gender: _gender,
            amenities: _amenities.toList(),
            address: _address.text.trim(),
          ),
        );
        if (_regenerateRooms) {
          await HostelService.instance.regenerateRooms(
            collegeId: widget.collegeId,
            hostelId: widget.hostel!.id,
            plan: plan,
          );
        }
      } else {
        await HostelService.instance.createHostel(
          collegeId: widget.collegeId,
          hostel: Hostel(
            id: '',
            name: _name.text.trim(),
            code: _code.text.trim().toUpperCase(),
            gender: _gender,
            floors: plan.floors,
            amenities: _amenities.toList(),
            address: _address.text.trim(),
          ),
          plan: plan,
        );
      }
      if (mounted) Navigator.pop(context);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            _regenerateRooms
                ? 'Hostel updated and rooms regenerated '
                      '(${plan.totalRooms} rooms)'
                : _isEditing
                ? 'Hostel updated'
                : 'Created ${_name.text.trim()} with ${plan.totalRooms} rooms',
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _error = AuthService.describeError(e));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool?> _confirmRegenerate(BuildContext context, RoomPlan plan) {
    return showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Replace all rooms?'),
        content: Text(
          'Every existing room in ${widget.hostel!.name} will be deleted '
          'and replaced with ${plan.totalRooms} new rooms (${plan.rangeSummary}). '
          'This cannot be undone. Rooms that currently have a student in '
          'them will block this instead of being deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Replace rooms'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;

    return AlertDialog(
      title: Text(_isEditing ? 'Edit ${widget.hostel!.name}' : 'Add a hostel'),
      content: SizedBox(
        width: 600,
        height: 600,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_error != null) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.dangerSoft,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: AppColors.danger,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextFormField(
                        controller: _name,
                        enabled: !_busy,
                        decoration: const InputDecoration(
                          labelText: 'Hostel name',
                          hintText: 'e.g. Aryabhatta Hostel / Block A',
                        ),
                        validator: (v) => (v == null || v.trim().length < 2)
                            ? 'Name is required'
                            : null,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _code,
                        enabled: !_busy,
                        textCapitalization: TextCapitalization.characters,
                        maxLength: 12,
                        decoration: const InputDecoration(
                          labelText: 'Code',
                          hintText: 'BH-01',
                          helperText: 'Used by the CSV importer to match rows',
                          counterText: '',
                        ),
                        validator: (v) {
                          final s = v?.trim() ?? '';
                          if (s.isEmpty) return 'Required';
                          if (s.length > 12) return 'Keep it under 12 chars';
                          return null;
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),

                DropdownButtonFormField<HostelGender>(
                  initialValue: _gender,
                  decoration: const InputDecoration(labelText: 'Accommodates'),
                  items: HostelGender.values
                      .map(
                        (g) => DropdownMenuItem(
                          value: g,
                          child: Text(g.label),
                        ),
                      )
                      .toList(),
                  onChanged: _busy
                      ? null
                      : (v) => setState(
                          () => _gender = v ?? HostelGender.coed,
                        ),
                ),
                const SizedBox(height: 14),

                TextFormField(
                  controller: _address,
                  enabled: !_busy,
                  decoration: const InputDecoration(
                    labelText: 'Location / address (optional)',
                  ),
                ),
                const SizedBox(height: 22),

                const Text(
                  'Things provided in this hostel',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                SelectableChips(
                  options: kHostelAmenities,
                  selected: _amenities,
                  enabled: !_busy,
                  onChanged: (v) => setState(() => _amenities = v),
                ),

                const SizedBox(height: 24),
                const Divider(),
                const SizedBox(height: 14),
                const Text(
                  'Rooms',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),

                if (_isEditing && !_regenerateRooms) ...[
                  Text(
                    'Rooms already exist for this hostel — use "Add room", '
                    '"Add floor" or tap a room to edit it individually. If '
                    'the whole layout was wrong from the start, you can '
                    'replace every room here instead of deleting the hostel.',
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 12.5,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () => setState(() => _regenerateRooms = true),
                    icon: const Icon(Icons.restart_alt_rounded, size: 17),
                    label: const Text('Regenerate rooms…'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.danger,
                      side: BorderSide(color: AppColors.danger),
                    ),
                  ),
                ],

                if (_showRoomPlan) ...[
                  if (_isEditing) ...[
                    const SizedBox(height: 4),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.dangerSoft,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.warning_amber_rounded,
                            size: 18,
                            color: AppColors.danger,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'This deletes every existing room in this '
                              'hostel and creates new ones from the layout '
                              'below. Blocked if any room currently has a '
                              'student in it.',
                              style: TextStyle(
                                color: AppColors.danger,
                                fontSize: 12.5,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: _busy
                            ? null
                            : () => setState(() => _regenerateRooms = false),
                        child: const Text('Cancel — keep existing rooms'),
                      ),
                    ),
                  ] else
                    Text(
                      'Describe the layout and every room is created for '
                      'you. You can add, edit or remove individual rooms '
                      'afterwards.',
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12.5,
                        height: 1.4,
                      ),
                    ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: 160,
                    child: TextFormField(
                      controller: _floors,
                      enabled: !_busy,
                      keyboardType: TextInputType.number,
                      onChanged: (_) => setState(_syncFloorGroups),
                      decoration: const InputDecoration(labelText: 'Floors'),
                      validator: (v) {
                        final n = int.tryParse(v ?? '');
                        if (n == null || n < 1) return 'Min 1';
                        if (n > 20) return 'Max 20';
                        return null;
                      },
                    ),
                  ),
                  const SizedBox(height: 14),

                  SwitchListTile(
                    value: _sameEveryFloor,
                    onChanged: _busy
                        ? null
                        : (v) => setState(() {
                            _sameEveryFloor = v;
                            if (!v) _syncFloorGroups();
                          }),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text(
                      'Every floor is laid out the same',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      _sameEveryFloor
                          ? 'Set the mix once and it applies to all '
                                '$_floorCount floors.'
                          : 'Each floor is set separately below. They all '
                                'started from the shared layout.',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),

                  if (_sameEveryFloor)
                    _CompositionEditor(
                      title: 'Rooms on each floor',
                      groups: _sharedGroups,
                      enabled: !_busy,
                      onChanged: () => setState(() {}),
                      onAdd: () => _addGroup(_sharedGroups),
                      onRemove: (i) => _removeGroup(_sharedGroups, i),
                    )
                  else
                    for (var f = 0; f < _floorGroups.length; f++) ...[
                      if (f > 0) const SizedBox(height: 12),
                      _CompositionEditor(
                        title: 'Floor ${f + 1}',
                        groups: _floorGroups[f],
                        enabled: !_busy,
                        onChanged: () => setState(() {}),
                        onAdd: () => _addGroup(_floorGroups[f]),
                        onRemove: (i) => _removeGroup(_floorGroups[f], i),
                        onCopyToAll: _floorGroups.length > 1
                            ? () => _copyFloorToAll(f)
                            : null,
                      ),
                    ],

                  const SizedBox(height: 18),
                  const Text(
                    'Default room features',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SelectableChips(
                    options: kRoomFeatures,
                    selected: _roomFeatures,
                    enabled: !_busy,
                    onChanged: (v) => setState(() => _roomFeatures = v),
                  ),
                  const SizedBox(height: 18),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.primarySoft,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Will create ${plan.totalRooms} rooms · '
                          '${plan.totalBeds} beds',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 13.5,
                            color: AppColors.primary,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          plan.rangeSummary,
                          style: TextStyle(
                            fontSize: 12.5,
                            color: AppColors.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
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
              : Text(_isEditing ? 'Save changes' : 'Create hostel'),
        ),
      ],
    );
  }
}

/// Editing state for one room type within a floor: how many rooms, and of
/// what capacity.
class _GroupDraft {
  final TextEditingController rooms;
  int capacity;

  _GroupDraft({required String rooms, required this.capacity})
    : rooms = TextEditingController(text: rooms);

  /// A detached duplicate — needed because each floor owns its own
  /// controllers, so seeding a floor from another must not share them.
  _GroupDraft copy() => _GroupDraft(rooms: rooms.text, capacity: capacity);

  void dispose() => rooms.dispose();
}

/// The room mix for one floor (or for every floor at once) — a list of
/// "N rooms of capacity C" rows, with a live total underneath.
class _CompositionEditor extends StatelessWidget {
  final String title;
  final List<_GroupDraft> groups;
  final bool enabled;
  final VoidCallback onChanged;
  final VoidCallback onAdd;
  final void Function(int index) onRemove;

  /// Shown only in per-floor mode, and only when there's more than one floor
  /// to copy onto.
  final VoidCallback? onCopyToAll;

  const _CompositionEditor({
    required this.title,
    required this.groups,
    required this.enabled,
    required this.onChanged,
    required this.onAdd,
    required this.onRemove,
    this.onCopyToAll,
  });

  int get _rooms => groups.fold(
    0,
    (acc, g) => acc + (int.tryParse(g.rooms.text) ?? 0),
  );

  int get _beds => groups.fold(
    0,
    (acc, g) => acc + (int.tryParse(g.rooms.text) ?? 0) * g.capacity,
  );

  @override
  Widget build(BuildContext context) {
    final over = _rooms > kMaxRoomsPerFloor;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        border: Border.all(color: over ? AppColors.danger : AppColors.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (onCopyToAll != null)
                TextButton.icon(
                  onPressed: enabled ? onCopyToAll : null,
                  icon: const Icon(Icons.copy_all_rounded, size: 15),
                  label: const Text('Copy to all floors'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    textStyle: const TextStyle(fontSize: 11.5),
                  ),
                ),
            ],
          ),
          for (var i = 0; i < groups.length; i++)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: TextFormField(
                      controller: groups[i].rooms,
                      enabled: enabled,
                      keyboardType: TextInputType.number,
                      onChanged: (_) => onChanged(),
                      decoration: const InputDecoration(
                        labelText: 'Rooms',
                        isDense: true,
                      ),
                      validator: (v) {
                        final n = int.tryParse(v ?? '');
                        if (n == null || n < 0) return 'Min 0';
                        if (n > kMaxRoomsPerFloor) return 'Max 99';
                        return null;
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 3,
                    child: DropdownButtonFormField<int>(
                      initialValue: groups[i].capacity,
                      decoration: const InputDecoration(
                        labelText: 'Type',
                        isDense: true,
                      ),
                      items: const [1, 2, 3, 4, 5, 6]
                          .map(
                            (n) => DropdownMenuItem(
                              value: n,
                              child: Text(n == 1 ? 'Single' : '$n seater'),
                            ),
                          )
                          .toList(),
                      onChanged: enabled
                          ? (v) {
                              groups[i].capacity = v ?? groups[i].capacity;
                              onChanged();
                            }
                          : null,
                    ),
                  ),
                  IconButton(
                    onPressed: (enabled && groups.length > 1)
                        ? () => onRemove(i)
                        : null,
                    icon: const Icon(Icons.close_rounded, size: 18),
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Remove this room type',
                  ),
                ],
              ),
            ),
          const SizedBox(height: 6),
          Row(
            children: [
              TextButton.icon(
                onPressed: (enabled && groups.length < 6) ? onAdd : null,
                icon: const Icon(Icons.add_rounded, size: 16),
                label: const Text('Add room type'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(fontSize: 12),
                ),
              ),
              const Spacer(),
              Text(
                over
                    ? '$_rooms rooms — over the $kMaxRoomsPerFloor limit'
                    : '$_rooms rooms · $_beds beds',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: over ? AppColors.danger : AppColors.textMuted,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
