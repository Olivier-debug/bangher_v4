import 'package:flutter/material.dart';
import '../../../../theme/app_theme.dart';

const double kStepRadius = 10;

// ---------- Common decoration ----------
InputDecoration stepDecoration(String label, {String? hint}) => InputDecoration(
  labelText: label,
  hintText: hint,
  labelStyle: const TextStyle(color: Colors.white70),
  hintStyle: const TextStyle(color: Colors.white54),
  filled: true,
  fillColor: const Color(0xFF141414),
  enabledBorder: OutlineInputBorder(
    borderSide: BorderSide(color: AppTheme.ffAlt.withValues(alpha: .60)),
    borderRadius: BorderRadius.circular(kStepRadius),
  ),
  focusedBorder: OutlineInputBorder(
    borderSide: const BorderSide(color: AppTheme.ffPrimary),
    borderRadius: BorderRadius.circular(kStepRadius),
  ),
  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
);

// ---------- Layout scaffold for a step ----------
class StepScaffold extends StatelessWidget {
  const StepScaffold({super.key, required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
        child: ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          children: [ StepTitle(title), ...children ],
        ),
      );
}

// ---------- Title ----------
class StepTitle extends StatelessWidget {
  const StepTitle(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(
          text,
          style: const TextStyle(
            color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
        ),
      );
}

// ---------- Text input ----------
class InputText extends StatelessWidget {
  const InputText({
    super.key,
    required this.label,
    required this.controller,
    this.hint,
    this.maxLines = 1,
    this.isRequired = false,
    this.readOnly = false,
  });

  final String label;
  final String? hint;
  final TextEditingController controller;
  final int maxLines;
  final bool isRequired;
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
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
      decoration: stepDecoration(label, hint: hint),
      validator: isRequired
          ? (v) => (v == null || v.trim().isEmpty) ? '$label is required' : null
          : null,
    );
  }
}

// ---------- Single-choice chips ----------
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
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kStepRadius)),
          side: BorderSide(color: AppTheme.ffAlt.withValues(alpha: .60)),
        );
      }).toList(),
    );
  }
}

// ---------- Multi-select chips ----------
class ChipsSelector extends StatelessWidget {
  const ChipsSelector({
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
    return Wrap(
      spacing: 8,
      runSpacing: 10,
      children: options.map((opt) {
        final selected = values.contains(opt);
        return FilterChip(
          label: Text(opt),
          selected: selected,
          onSelected: (isSel) {
            final next = {...values};
            isSel ? next.add(opt) : next.remove(opt);
            onChanged(next);
          },
          labelStyle: TextStyle(color: selected ? Colors.white : Colors.white70),
          selectedColor: AppTheme.ffPrimary.withValues(alpha: 0.6),
          backgroundColor: const Color(0xFF141414),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kStepRadius)),
          side: BorderSide(color: AppTheme.ffAlt.withValues(alpha: .60)),
        );
      }).toList(),
    );
  }
}

// ---------- Checkbox group ----------
class CheckboxGroup extends StatelessWidget {
  const CheckboxGroup({
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
    return Wrap(
      spacing: 12,
      runSpacing: 6,
      children: options.map((opt) {
        final sel = values.contains(opt);
        return InkWell(
          onTap: () {
            final next = {...values};
            sel ? next.remove(opt) : next.add(opt);
            onChanged(next);
          },
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Checkbox(
              value: sel,
              onChanged: (_) {
                final next = {...values};
                sel ? next.remove(opt) : next.add(opt);
                onChanged(next);
              },
              activeColor: AppTheme.ffPrimary,
            ),
            Flexible(
              child: Text(
                opt,
                style: const TextStyle(color: Colors.white70),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ]),
        );
      }).toList(),
    );
  }
}
