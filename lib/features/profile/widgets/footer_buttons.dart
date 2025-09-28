// lib/features/profile/widgets/footer_buttons.dart
import 'package:flutter/material.dart';
import '../../../theme/app_theme.dart';
import 'tokens.dart' show kRadiusPill;

/// Back + Primary buttons row. Primary can show spinner.
class FooterButtons extends StatelessWidget {
  const FooterButtons({
    super.key,
    required this.canGoBack,
    required this.onBack,
    required this.primaryEnabled,
    required this.saving,
    required this.onPrimary,
    this.primaryLabel = 'Save & Continue',
    this.backLabel = 'Back',
  });

  final bool canGoBack;
  final VoidCallback onBack;
  final bool primaryEnabled;
  final bool saving;
  final VoidCallback onPrimary;
  final String primaryLabel;
  final String backLabel;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton(
            onPressed: canGoBack ? onBack : null,
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: BorderSide(color: AppTheme.ffAlt.withValues(alpha: .60)),
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(kRadiusPill),
              ),
              backgroundColor: Colors.transparent,
            ),
            child: Text(backLabel),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 150),
            child: primaryEnabled
                ? ElevatedButton(
                    key: const ValueKey('primary-visible'),
                    onPressed: saving ? null : onPrimary,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.ffPrimary,
                      minimumSize: const Size.fromHeight(52),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(kRadiusPill),
                      ),
                    ),
                    child: saving
                        ? const SizedBox(
                            height: 22,
                            width: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Text(
                            primaryLabel,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  )
                : const SizedBox(
                    key: ValueKey('primary-hidden'),
                    height: 52,
                  ),
          ),
        ),
      ],
    );
  }
}
