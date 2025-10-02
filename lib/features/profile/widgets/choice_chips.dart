// lib/features/profile/widgets/choice_chips.dart
import 'package:flutter/material.dart';
import '../../../theme/app_theme.dart';
import 'tokens.dart' show kRadiusPill;

/// Single-select chips (ChoiceChip).
class ChoiceChips extends StatelessWidget {
  const ChoiceChips({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
  });

  final List<String> options;
  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 10,
      children: options.map((opt) {
        final selected = value == opt;
        return ChoiceChip(
          label: Text(opt),
          selected: selected,
          onSelected: (_) => onChanged(selected ? null : opt),
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
