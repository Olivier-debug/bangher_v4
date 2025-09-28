// lib/features/profile/widgets/input_text.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../theme/app_theme.dart';
import 'tokens.dart'; // provides kRadiusPill

class InputText extends StatelessWidget {
  const InputText({
    super.key,
    required this.label,
    required this.controller,
    this.hint,
    this.maxLines = 1,
    this.required = false,
    this.readOnly = false,
  });

  final String label;
  final String? hint;
  final TextEditingController controller;
  final int maxLines;
  final bool required;
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    // Prevent focus entirely when read-only, so the keyboard never shows.
    final focusNode = readOnly
        ? FocusNode(skipTraversal: true, canRequestFocus: false)
        : null;

    return TextFormField(
      controller: controller,
      maxLines: maxLines,
      style: const TextStyle(color: Colors.white),
      textInputAction: maxLines == 1 ? TextInputAction.next : TextInputAction.newline,
      readOnly: readOnly,
      showCursor: !readOnly,
      enableInteractiveSelection: !readOnly,
      focusNode: focusNode,
      onTap: readOnly
          ? () {
              // Hide keyboard & clear focus when this read-only field is tapped.
              FocusScope.of(context).unfocus();
              SystemChannels.textInput.invokeMethod('TextInput.hide');
            }
          : null,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: const TextStyle(color: Colors.white70),
        hintStyle: const TextStyle(color: Colors.white54),
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
      validator: required
          ? (v) => (v == null || v.trim().isEmpty) ? '$label is required' : null
          : null,
    );
  }
}
