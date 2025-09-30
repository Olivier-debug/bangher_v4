// FILE: lib/features/profile/pages/steps/step_goals.dart
import 'package:flutter/material.dart';
import './_step_shared.dart' show StepScaffold, ChipsSelector;

class StepGoals extends StatelessWidget {
  const StepGoals({
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
    return StepScaffold(
      title: 'Relationship goals',
      children: [
        ChipsSelector(
          options: options,
          values: values,
          onChanged: onChanged,
        ),
        const SizedBox(height: 8),
        const Text(
          'Pick at least 1',
          style: TextStyle(color: Colors.white70),
        ),
      ],
    );
  }
}
