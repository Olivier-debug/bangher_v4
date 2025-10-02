// FILE: lib/features/profile/pages/steps/step_interested_in.dart
import 'package:flutter/material.dart';
import './_step_shared.dart' show StepScaffold, ChoiceChips;

class StepInterestedIn extends StatelessWidget {
  const StepInterestedIn({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String? value;
  final List<String> options;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return StepScaffold(
      title: 'I am interested in:',
      children: [
        ChoiceChips(
          options: options,
          value: value,
          onChanged: onChanged,
        ),
      ],
    );
  }
}
