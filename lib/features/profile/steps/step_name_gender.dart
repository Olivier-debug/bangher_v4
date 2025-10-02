// lib/features/profile/steps/step_name_gender.dart

import 'package:flutter/material.dart';
import './_step_shared.dart' show StepScaffold, StepTitle; // shared layout/title
import '../widgets/input_text.dart' as w;                  // input field
import '../widgets/choice_chips.dart' as wchips;           // choice chips

class StepNameGender extends StatelessWidget {
  const StepNameGender({
    super.key,
    required this.nameController,
    required this.gender,
    required this.onGenderChanged,
    this.genderOptions = const ['Male', 'Female', 'Other'],
  });

  final TextEditingController nameController;
  final String? gender;
  final ValueChanged<String?> onGenderChanged;
  final List<String> genderOptions;

  @override
  Widget build(BuildContext context) {
    return StepScaffold(
      title: "What's your first name?",
      children: [
        w.InputText(
          label: 'First name',
          controller: nameController,
          hint: 'Enter your first name',
          maxLines: 1,
        ),
        const SizedBox(height: 16),
        const StepTitle('I am a:'),
        const SizedBox(height: 6),
        wchips.ChoiceChips(
          options: genderOptions,
          value: gender,
          onChanged: onGenderChanged,
        ),
      ],
    );
  }
}

// IMPORTANT: Ensure there are NO other widget classes in this file
// like `StepDob` etc. This file should ONLY define `StepNameGender`.
