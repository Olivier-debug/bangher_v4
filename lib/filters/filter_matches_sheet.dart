import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Result object returned from showModalBottomSheet(...)
class FilterMatchesResult {
  final String gender; // 'Men' | 'Women' | 'Both'
  final double maxDistanceKm; // 0..100
  final RangeValues ageRange; // e.g., 18..75
  final bool hasBioOnly;

  const FilterMatchesResult({
    required this.gender,
    required this.maxDistanceKm,
    required this.ageRange,
    required this.hasBioOnly,
  });
}

class FilterMatchesSheet extends StatefulWidget {
  const FilterMatchesSheet({super.key});
  @override
  State<FilterMatchesSheet> createState() => _FilterMatchesSheetState();
}

class _FilterMatchesSheetState extends State<FilterMatchesSheet> {
  // Tokens (aligned with profile page)
  static const double _screenHPad = 24;
  static const double _radiusCard = 12;
  static const double _radiusPill = 10;

  Color get _outline => AppTheme.ffAlt;

  // Defaults
  String _gender = 'Both';
  double _distance = 50;
  RangeValues _ages = const RangeValues(18, 60);
  bool _hasBioOnly = false;

  // Options
  static const _genderOptions = ['Women', 'Men', 'Both'];

  void _reset() {
    setState(() {
      _gender = 'Both';
      _distance = 50;
      _ages = const RangeValues(18, 60);
      _hasBioOnly = false;
    });
  }

  void _submit() {
    Navigator.of(context).pop(
      FilterMatchesResult(
        gender: _gender,
        maxDistanceKm: _distance,
        ageRange: _ages,
        hasBioOnly: _hasBioOnly,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        color: AppTheme.ffSecondaryBg,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(_screenHPad, 18, _screenHPad, 6),
              child: Row(
                children: [
                  const Text(
                    'Filter',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      letterSpacing: .2,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Reset',
                    onPressed: _reset,
                    icon: const Icon(Icons.refresh, color: Colors.white70),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, color: Colors.white70),
                  ),
                ],
              ),
            ),

            // Content
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(_screenHPad, 2, _screenHPad, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Looking For
                    _SectionCard(
                      outline: _outline,
                      radius: _radiusCard,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const _Heading(icon: Icons.search_rounded, text: 'Looking For'),
                          const SizedBox(height: 12),
                          _PillsWrapSelectable<String>(
                            options: _genderOptions,
                            isSelected: (g) => _gender == g,
                            onTap: (g) => setState(() => _gender = g),
                            radius: _radiusPill,
                            outline: _outline,
                          ),
                          const SizedBox(height: 18),
                          const _Subheading(icon: Icons.social_distance_rounded, text: 'Maximum Distance'),
                          const SizedBox(height: 8),
                          _SliderRow(
                            valueLabel: '${_distance.round()} km',
                            child: SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                activeTrackColor: AppTheme.ffPrimary,
                                inactiveTrackColor: Colors.white.withValues(alpha: .20),
                                thumbColor: AppTheme.ffPrimary,
                                overlayColor: AppTheme.ffPrimary.withValues(alpha: .08),
                              ),
                              child: Slider(
                                value: _distance,
                                onChanged: (v) => setState(() => _distance = v.roundToDouble()),
                                min: 0,
                                max: 100,
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          const _Subheading(icon: Icons.cake_outlined, text: 'Age Range'),
                          const SizedBox(height: 8),
                          _SliderRow(
                            valueLabel: '${_ages.start.round()}–${_ages.end.round()}',
                            child: SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                activeTrackColor: AppTheme.ffPrimary,
                                inactiveTrackColor: Colors.white.withValues(alpha: .20),
                                rangeThumbShape: const RoundRangeSliderThumbShape(enabledThumbRadius: 10),
                                thumbColor: AppTheme.ffPrimary,
                                overlayColor: AppTheme.ffPrimary.withValues(alpha: .08),
                              ),
                              // Using SliderTheme for RangeSlider for broad SDK support
                              child: RangeSlider(
                                values: _ages,
                                onChanged: (r) => setState(
                                  () => _ages = RangeValues(
                                    r.start.roundToDouble(),
                                    r.end.roundToDouble(),
                                  ),
                                ),
                                min: 18,
                                max: 75,
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Switch.adaptive(
                                value: _hasBioOnly,
                                onChanged: (v) => setState(() => _hasBioOnly = v),
                                activeThumbColor: const Color.fromRGBO(255, 20, 147, 1),
                              ),
                              const SizedBox(width: 8),
                              const Expanded(
                                child: Text(
                                  'Only show people with a bio',
                                  style: TextStyle(color: Colors.white70),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 18),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppTheme.ffPrimary,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: _submit,
                        child: const Text('Apply Filters'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(color: _outline.withValues(alpha: .6)),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: _reset,
                        child: const Text('Clear all'),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Visual building blocks

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.child,
    required this.outline,
    required this.radius,
  });

  final Widget child;
  final Color outline;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.ffPrimaryBg,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: outline.withValues(alpha: .50), width: 1.2),
      ),
      padding: const EdgeInsets.all(14),
      child: child,
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: AppTheme.ffPrimary, size: 18),
        const SizedBox(width: 8),
        Text(
          text,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w700,
            letterSpacing: .2,
          ),
        ),
      ],
    );
  }
}

class _Subheading extends StatelessWidget {
  const _Subheading({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: AppTheme.ffPrimary),
        const SizedBox(width: 8),
        Text(
          text,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: 14,
            letterSpacing: .2,
          ),
        ),
      ],
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({required this.child, required this.valueLabel});
  final Widget child;
  final String valueLabel;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        child,
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerRight,
          child: Text(
            valueLabel,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ),
      ],
    );
  }
}

class _PillsWrapSelectable<T> extends StatelessWidget {
  const _PillsWrapSelectable({
    required this.options,
    required this.isSelected,
    required this.onTap,
    required this.radius,
    required this.outline,
  });

  final List<T> options;
  final bool Function(T) isSelected;
  final void Function(T) onTap;
  final double radius;
  final Color outline;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: options.map((o) {
        final sel = isSelected(o);
        return InkWell(
          onTap: () => onTap(o),
          borderRadius: BorderRadius.circular(radius),
          child: Container(
            constraints: const BoxConstraints(minHeight: 34),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: sel ? AppTheme.ffPrimary : AppTheme.ffPrimaryBg,
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(
                color: sel ? AppTheme.ffPrimary : outline.withValues(alpha: .60),
                width: 1,
              ),
            ),
            child: Text('$o', style: const TextStyle(color: Colors.white, height: 1.1)),
          ),
        );
      }).toList(),
    );
  }
}















