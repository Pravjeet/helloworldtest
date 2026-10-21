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

  /// The building, floor by floor. Each floor holds one or more groups of
  /// identical rooms, so "floor 1 has eight 3-seaters and four singles" is
  /// expressible — which the old floors × rooms-per-floor × capacity form
  /// could not say at all.
  final List<_FloorDraft> _floorDrafts = [
    _FloorDraft.uniform(rooms: 25, capacity: 2),
  ];

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
    for (final c in [_name, _code, _address]) {
      c.dispose();
    }
    for (final f in _floorDrafts) {
      f.dispose();
    }
    super.dispose();
  }

  RoomPlan get _plan {
    final features = _roomFeatures.toList();
    return RoomPlan(
      floorPlans: [
        for (final f in _floorDrafts)
          FloorPlan(
            groups: [
              for (final g in f.groups)
                if (g.count > 0)
                  RoomGroup(
                    capacity: g.capacity,
                    count: g.count,
                    features: features,
                  ),
            ],
          ),
      ],
    );
  }

  void _addFloor() => setState(() {
    // A new floor copies the one below it: buildings repeat, and retyping the
    // same eight-and-four mix per floor is the tedium this form exists to
    // remove.
    final last = _floorDrafts.isEmpty ? null : _floorDrafts.last;
    _floorDrafts.add(
      last == null
          ? _FloorDraft.uniform(rooms: 25, capacity: 2)
          : _FloorDraft.from(last),
    );
  });

  void _removeFloor(int i) => setState(() => _floorDrafts.removeAt(i));

  /// Applies floor 1's mix to every other floor, for the common building
  /// where each storey is identical.
  void _copyFirstFloorToAll() => setState(() {
    if (_floorDrafts.isEmpty) return;
    final first = _floorDrafts.first;
    for (var i = 1; i < _floorDrafts.length; i++) {
      _floorDrafts[i] = _FloorDraft.from(first);
    }
  });

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
                      style: TextStyle(color: AppColors.danger, fontSize: 13),
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
                        (g) => DropdownMenuItem(value: g, child: Text(g.label)),
                      )
                      .toList(),
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _gender = v ?? HostelGender.coed),
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
                  Row(
                    children: [
                      Text(
                        'Floors (${_floorDrafts.length})',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      if (_floorDrafts.length > 1)
                        TextButton(
                          onPressed: _busy ? null : _copyFirstFloorToAll,
                          child: const Text('Make all floors like floor 1'),
                        ),
                      const SizedBox(width: 4),
                      TextButton.icon(
                        onPressed: (_busy || _floorDrafts.length >= 20)
                            ? null
                            : _addFloor,
                        icon: const Icon(Icons.add_rounded, size: 17),
                        label: const Text('Add floor'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Each floor can mix seater types \u2014 eight 3-seaters and '
                    'four singles on the same floor is fine.',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: AppColors.textMuted,
                    ),
                  ),
                  const SizedBox(height: 10),
                  for (var i = 0; i < _floorDrafts.length; i++) ...[
                    _FloorRow(
                      floor: i + 1,
                      draft: _floorDrafts[i],
                      enabled: !_busy,
                      canRemove: _floorDrafts.length > 1,
                      onChanged: () => setState(() {}),
                      onRemove: () => _removeFloor(i),
                    ),
                    const SizedBox(height: 10),
                  ],

                  const SizedBox(height: 18),
                  const Text(
                    'Default room features',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
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

/// Editing state for one extra room type: how many rooms, and what capacity.
/// Rooms per floor is shared with the main type above, so this row is just
/// two fields.
/// One floor being edited: a list of {count, capacity} rows.
class _FloorDraft {
  final List<_GroupDraft> groups;

  _FloorDraft(this.groups);

  factory _FloorDraft.uniform({required int rooms, required int capacity}) =>
      _FloorDraft([_GroupDraft(rooms: rooms, capacity: capacity)]);

  /// A copy, so editing the new floor never writes through to the one it was
  /// modelled on.
  factory _FloorDraft.from(_FloorDraft other) => _FloorDraft([
    for (final g in other.groups)
      _GroupDraft(rooms: g.count, capacity: g.capacity),
  ]);

  int get roomCount => groups.fold(0, (a, g) => a + g.count);
  int get bedCount => groups.fold(0, (a, g) => a + g.count * g.capacity);

  void dispose() {
    for (final g in groups) {
      g.dispose();
    }
  }
}

class _GroupDraft {
  final TextEditingController rooms;
  int capacity;

  _GroupDraft({required int rooms, required this.capacity})
    : rooms = TextEditingController(text: '$rooms');

  int get count => int.tryParse(rooms.text.trim()) ?? 0;

  void dispose() => rooms.dispose();
}

/// One floor's row in the editor: its seater groups, and what it adds up to.
class _FloorRow extends StatelessWidget {
  final int floor;
  final _FloorDraft draft;
  final bool enabled;
  final bool canRemove;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  const _FloorRow({
    required this.floor,
    required this.draft,
    required this.enabled,
    required this.canRemove,
    required this.onChanged,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Floor $floor',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '${draft.roomCount} rooms \u00b7 ${draft.bedCount} beds',
                style: TextStyle(fontSize: 12, color: AppColors.textMuted),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: !enabled || draft.groups.length >= 5
                    ? null
                    : () {
                        // Default the new group to a size not already on this
                        // floor, so it is a genuine addition rather than a
                        // duplicate row.
                        final used = draft.groups
                            .map((g) => g.capacity)
                            .toSet();
                        final next = [
                          1,
                          2,
                          3,
                          4,
                          5,
                          6,
                        ].firstWhere((c) => !used.contains(c), orElse: () => 1);
                        draft.groups.add(_GroupDraft(rooms: 0, capacity: next));
                        onChanged();
                      },
                icon: const Icon(Icons.add_rounded, size: 15),
                label: const Text('Seater type'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
              ),
              IconButton(
                onPressed: !enabled || !canRemove ? null : onRemove,
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
                tooltip: 'Remove floor $floor',
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          for (var i = 0; i < draft.groups.length; i++) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                SizedBox(
                  width: 110,
                  child: TextFormField(
                    controller: draft.groups[i].rooms,
                    enabled: enabled,
                    keyboardType: TextInputType.number,
                    onChanged: (_) => onChanged(),
                    decoration: const InputDecoration(
                      labelText: 'Rooms',
                      isDense: true,
                    ),
                    validator: (v) {
                      final n = int.tryParse(v?.trim() ?? '');
                      if (n == null || n < 0) return 'Number';
                      if (n > 99) return 'Max 99';
                      return null;
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: draft.groups[i].capacity,
                    decoration: const InputDecoration(
                      labelText: 'Seater type',
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
                    onChanged: !enabled
                        ? null
                        : (v) {
                            draft.groups[i].capacity = v ?? 2;
                            onChanged();
                          },
                  ),
                ),
                IconButton(
                  onPressed: !enabled || draft.groups.length <= 1
                      ? null
                      : () {
                          draft.groups.removeAt(i).dispose();
                          onChanged();
                        },
                  icon: const Icon(Icons.close_rounded, size: 17),
                  tooltip: 'Remove this seater type',
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
