import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../models/hostel.dart';

/// Toggleable chips for picking which hostels a staff member is
/// responsible for — the Chief Warden / Warden / Caretaker / BHS equivalent
/// of a student's room allotment.
///
/// Keyed on hostel id rather than display text like [SelectableChips] is,
/// because a hostel's code/name is not guaranteed unique the way an id is.
class HostelPickerChips extends StatelessWidget {
  final List<Hostel> hostels;
  final Set<String> selectedIds;
  final ValueChanged<Set<String>> onChanged;
  final bool enabled;

  const HostelPickerChips({
    super.key,
    required this.hostels,
    required this.selectedIds,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    if (hostels.isEmpty) {
      return Text(
        'No hostels have been created yet — add one under Hostels & Rooms '
        'first.',
        style: TextStyle(color: AppColors.textMuted, fontSize: 12.5),
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: hostels.map((h) {
        final isOn = selectedIds.contains(h.id);
        return FilterChip(
          label: Text(h.code.isEmpty ? h.name : '${h.code} · ${h.name}'),
          selected: isOn,
          onSelected: enabled
              ? (v) {
                  final next = {...selectedIds};
                  if (v) {
                    next.add(h.id);
                  } else {
                    next.remove(h.id);
                  }
                  onChanged(next);
                }
              : null,
          showCheckmark: false,
          labelStyle: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: isOn ? AppColors.primary : AppColors.textMuted,
          ),
          backgroundColor: Colors.white,
          selectedColor: AppColors.primarySoft,
          side: BorderSide(color: isOn ? AppColors.primary : AppColors.border),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        );
      }).toList(),
    );
  }
}
