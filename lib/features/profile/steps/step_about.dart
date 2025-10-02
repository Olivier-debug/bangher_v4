// lib/features/profile/steps/step_about.dart

import 'package:flutter/material.dart';

// Only bring StepScaffold from the shared step utilities.
import './_step_shared.dart' show StepScaffold;

// Prefix the widgets version to disambiguate InputText.
import '../widgets/input_text.dart' as w;

class StepAbout extends StatelessWidget {
  const StepAbout({
    super.key,
    required this.bioController,
    required this.loveLanguageController,
  });

  final TextEditingController bioController;
  final TextEditingController loveLanguageController;

  @override
  Widget build(BuildContext context) {
    return StepScaffold(
      title: 'About you',
      children: [
        w.InputText(
          label: 'Short bio',
          controller: bioController,
          hint: 'Tell people a little about you',
          maxLines: 4,
        ),
        const SizedBox(height: 12),
        w.InputText(
          label: 'Love language',
          controller: loveLanguageController,
          hint: 'e.g. Quality Time',
        ),
      ],
    );
  }
}
