// lib/features/profile/widgets/date_picker_row.dart
import 'package:flutter/material.dart';
import '../../../theme/app_theme.dart';
import 'tokens.dart' show kRadiusPill;

/// Compact date row that opens a date picker.
class DatePickerRow extends StatelessWidget {
  const DatePickerRow({
    super.key,
    required this.label,
    required this.value,
    required this.onPick,
  });

  final String label;
  final DateTime? value;
  final ValueChanged<DateTime?> onPick;

  @override
  Widget build(BuildContext context) {
    Future<void> pick() async {
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

    return InkWell(
      onTap: pick,
      borderRadius: BorderRadius.circular(kRadiusPill),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: Colors.white70),
          filled: true,
          fillColor: const Color(0xFF141414),
          enabledBorder: OutlineInputBorder(
            borderSide: BorderSide(color: AppTheme.ffAlt.withValues(alpha: .60)),
            borderRadius: BorderRadius.circular(kRadiusPill),
          ),
          focusedBorder: OutlineInputBorder(
            borderSide: const BorderSide(color: AppTheme.ffPrimary),
            borderRadius: BorderRadius.circular(kRadiusPill),
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        ),
        child: Text(
          value == null
              ? 'Select...'
              : '${value!.year}-${value!.month.toString().padLeft(2, '0')}-${value!.day.toString().padLeft(2, '0')}',
          style: const TextStyle(color: Colors.white),
        ),
      ),
    );
  }
}
