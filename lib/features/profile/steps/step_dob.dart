// lib/features/profile/steps/step_dob.dart
import 'package:flutter/material.dart';
import '../../../../theme/app_theme.dart';
import './_step_shared.dart' show StepScaffold, stepDecoration;

class StepDob extends StatelessWidget {
  const StepDob({
    super.key,
    required this.value,
    required this.onPick,
  });

  final DateTime? value;
  final ValueChanged<DateTime?> onPick;

  @override
  Widget build(BuildContext context) {
    Future<void> pickDate() async {
      final now = DateTime.now();
      final first = DateTime(now.year - 80, 1, 1);
      final last = DateTime(now.year - 18, now.month, now.day);
      final initial = value ?? DateTime(now.year - 25, 1, 1);

      final picked = await showDatePicker(
        context: context,
        firstDate: first,
        lastDate: last,
        initialDate: initial,
        helpText: 'Select your date of birth',
        builder: (context, child) => Theme(
          data: Theme.of(context).copyWith(
            colorScheme: Theme.of(context).colorScheme.copyWith(
                  primary: AppTheme.ffPrimary,
                  onPrimary: Colors.white,
                  surface: const Color(0xFF000000),
                  onSurface: Colors.white,
                ),
            textButtonTheme: TextButtonThemeData(
              style: TextButton.styleFrom(foregroundColor: AppTheme.ffPrimary),
            ), dialogTheme: DialogThemeData(backgroundColor: const Color(0xFF000000)),
          ),
          child: child!,
        ),
      );
      onPick(picked);
    }

    final label = value == null
        ? 'Select...'
        : '${value!.year}-${value!.month.toString().padLeft(2, '0')}-${value!.day.toString().padLeft(2, '0')}';

    return StepScaffold(
      title: "When's your birthday?",
      children: [
        InkWell(
          onTap: pickDate,
          borderRadius: BorderRadius.circular(10),
          child: InputDecorator(
            decoration: stepDecoration('Date of birth'),
            child: Text(label, style: const TextStyle(color: Colors.white)),
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'You must be at least 18 years old.',
          style: TextStyle(color: Colors.white70),
        ),
      ],
    );
  }
}
