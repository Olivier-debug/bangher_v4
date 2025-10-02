// lib/features/profile/widgets/chips_selector.dart
import 'package:flutter/material.dart';
import '../../../theme/app_theme.dart';
import 'tokens.dart' show kRadiusPill;

/// Multi-select chips (FilterChip).
class ChipsSelector extends StatelessWidget {
  const ChipsSelector({
    super.key,
    required this.options,
    required this.values,
    required this.onChanged,
  });

  final List<String> options;
  final Set<String> values;
  final ValueChanged<Set<String>> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 10,
      children: options.map((opt) {
        final selected = values.contains(opt);
        return FilterChip(
          label: Text(opt),
          selected: selected,
          onSelected: (isSel) {
            final next = {...values};
            isSel ? next.add(opt) : next.remove(opt);
            onChanged(next);
          },
          labelStyle: TextStyle(color: selected ? Colors.white : Colors.white70),
          selectedColor: AppTheme.ffPrimary.withValues(alpha: 0.6),
          backgroundColor: const Color(0xFF141414),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(kRadiusPill),
          ),
          side: BorderSide(color: AppTheme.ffAlt.withValues(alpha: .60)),
        );
      }).toList(),
    );
  }
}
