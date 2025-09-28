// FILE: lib/features/profile/pages/steps/step_interests.dart
import 'package:flutter/material.dart';
import './_step_shared.dart' show StepScaffold, ChipsSelector;

class StepInterests extends StatelessWidget {
  const StepInterests({
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
      title: 'Pick your interests',
      children: [
        ChipsSelector(
          options: options,
          values: values,
          onChanged: onChanged,
        ),
        const SizedBox(height: 10),
        const Text('Pick at least 3', style: TextStyle(color: Colors.white70)),
      ],
    );
  }
}
