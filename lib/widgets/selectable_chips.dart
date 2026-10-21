import 'package:flutter/material.dart';

import '../core/theme.dart';

/// A wrap of toggleable chips backed by a `Set<String>`.
/// Used for both hostel amenities and room features.
class SelectableChips extends StatelessWidget {
  final List<String> options;
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;
  final bool enabled;

  const SelectableChips({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: options.map((option) {
        final isOn = selected.contains(option);
        return FilterChip(
          label: Text(option),
          selected: isOn,
          onSelected: enabled
              ? (v) {
                  final next = {...selected};
                  if (v) {
                    next.add(option);
                  } else {
                    next.remove(option);
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
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
        );
      }).toList(),
    );
  }
}

/// Read-only version for display in cards.
class ReadOnlyChips extends StatelessWidget {
  final List<String> values;
  final String emptyLabel;
  final int? max;

  const ReadOnlyChips({
    super.key,
    required this.values,
    this.emptyLabel = 'None listed',
    this.max,
  });

  @override
  Widget build(BuildContext context) {
    if (values.isEmpty) {
      return Text(
        emptyLabel,
        style: TextStyle(color: AppColors.textMuted, fontSize: 12.5),
      );
    }

    final shown = max != null && values.length > max!
        ? values.take(max!).toList()
        : values;
    final hidden = values.length - shown.length;

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final v in shown)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.canvas,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.border),
            ),
            child: Text(
              v,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: AppColors.textMuted,
              ),
            ),
          ),
        if (hidden > 0)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.primarySoft,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              '+$hidden more',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: AppColors.primary,
              ),
            ),
          ),
      ],
    );
  }
}
