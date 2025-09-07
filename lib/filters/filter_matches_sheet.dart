// FILE: lib/filters/filter_matches_sheet.dart
// Bottom-sheet filters — brand-matched to the profile page.
// - No deprecated Slider props (use SliderTheme wrappers)
// - No undefined helpers; all widgets are in this file
// - No leaked constants; everything is local + const-safe

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Result object returned from showModalBottomSheet(...)
class FilterMatchesResult {
  final String gender; // 'Men' | 'Women' | 'Both'
  final double maxDistanceKm; // 0..100
  final RangeValues ageRange; // e.g., 18..75
  final bool hasBioOnly;
  final Set<String> languages;
  final Set<String> interests;
  final String? knowledgeLevel;
  final bool? animalLover;
  final String? vibeType;
  final String? socialScene;
  final Set<String> starSigns;
  final String? familyPlans;
  final String? smoke;
  final String? fitness;
  final Set<String> foods;
  final Set<String> dealbreakers;

  const FilterMatchesResult({
    required this.gender,
    required this.maxDistanceKm,
    required this.ageRange,
    required this.hasBioOnly,
    required this.languages,
    required this.interests,
    required this.knowledgeLevel,
    required this.animalLover,
    required this.vibeType,
    required this.socialScene,
    required this.starSigns,
    required this.familyPlans,
    required this.smoke,
    required this.fitness,
    required this.foods,
    required this.dealbreakers,
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
  RangeValues _ages = const RangeValues(20, 30);
  bool _hasBioOnly = true;

  // Filters
  Set<String> _languages = {};
  Set<String> _interests = {};
  String? _knowledgeLevel;
  bool? _animalLover; // null=Any
  String? _vibeType;
  String? _socialScene;
  Set<String> _starSigns = {};
  String? _familyPlans;
  String? _smoke;
  String? _fitness;
  Set<String> _foods = {};
  Set<String> _dealbreakers = {};

  // Options
  static const _genderOptions = ['Men', 'Women', 'Both'];
  static const _languageOptions = [
    'English','Afrikaans','Zulu','Xhosa','Sotho','French','Spanish'
  ];
  static const _interestOptions = [
    'Music','Travel','Food','Gaming','Outdoors','Reading','Art'
  ];
  static const _knowledgeLevels = [
    'High School','Diploma','Bachelor','Master','PhD'
  ];
  static const _vibeTypes = ['Casual','Serious','Friendship'];
  static const _socialScenes = ['Introvert','Ambivert','Extrovert'];
  static const _starSignsOptions = [
    'Aries','Taurus','Gemini','Cancer','Leo','Virgo','Libra',
    'Scorpio','Sagittarius','Capricorn','Aquarius','Pisces'
  ];
  static const _familyPlansOptions = ['Want kids','Not sure','Don\'t want'];
  static const _smokeOptions = ['Smoker','Non-smoker'];
  static const _fitnessOptions = ['Gym rat','Active','Chill'];
  static const _foodOptions = ['Italian','Sushi','Burgers','BBQ','Vegan','Indian'];
  static const _dealbreakerOptions = [
    'Smoking','Drugs','No Pets','Different Values','Long Distance'
  ];

  void _reset() {
    setState(() {
      _gender = 'Both';
      _distance = 50;
      _ages = const RangeValues(20, 30);
      _hasBioOnly = true;
      _languages = {};
      _interests = {};
      _knowledgeLevel = null;
      _animalLover = null;
      _vibeType = null;
      _socialScene = null;
      _starSigns = {};
      _familyPlans = null;
      _smoke = null;
      _fitness = null;
      _foods = {};
      _dealbreakers = {};
    });
  }

  void _submit() {
    Navigator.of(context).pop(
      FilterMatchesResult(
        gender: _gender,
        maxDistanceKm: _distance,
        ageRange: _ages,
        hasBioOnly: _hasBioOnly,
        languages: _languages,
        interests: _interests,
        knowledgeLevel: _knowledgeLevel,
        animalLover: _animalLover,
        vibeType: _vibeType,
        socialScene: _socialScene,
        starSigns: _starSigns,
        familyPlans: _familyPlans,
        smoke: _smoke,
        fitness: _fitness,
        foods: _foods,
        dealbreakers: _dealbreakers,
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
                                activeColor: AppTheme.ffPrimary,
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
                    const SizedBox(height: 12),

                    // Boost Filters
                    _SectionCard(
                      outline: _outline,
                      radius: _radiusCard,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const _Heading(icon: Icons.rocket_launch_outlined, text: 'Bangher Boost Filters'),
                          const SizedBox(height: 12),
                          _ListRow(
                            label: 'Spoken Languages',
                            value: _languages.isEmpty ? 'Any' : _languages.join(', '),
                            onTap: () async {
                              final res = await showModalBottomSheet<Set<String>>(
                                context: context,
                                isScrollControlled: true,
                                backgroundColor: Colors.transparent,
                                builder: (_) => _MultiSelectSheet(
                                  title: 'Spoken Languages',
                                  options: _languageOptions,
                                  initial: _languages,
                                ),
                              );
                              if (res != null) setState(() => _languages = res);
                            },
                          ),
                          _ListRow(
                            label: 'Interests',
                            value: _interests.isEmpty ? 'Any' : _interests.join(', '),
                            onTap: () async {
                              final res = await showModalBottomSheet<Set<String>>(
                                context: context,
                                isScrollControlled: true,
                                backgroundColor: Colors.transparent,
                                builder: (_) => _MultiSelectSheet(
                                  title: 'Interests',
                                  options: _interestOptions,
                                  initial: _interests,
                                ),
                              );
                              if (res != null) setState(() => _interests = res);
                            },
                          ),
                          _ListRow(
                            label: 'Knowledge Level',
                            value: _knowledgeLevel ?? 'Any',
                            onTap: () async {
                              final res = await showModalBottomSheet<String?>(
                                context: context,
                                isScrollControlled: true,
                                backgroundColor: Colors.transparent,
                                builder: (_) => _SingleSelectSheet(
                                  title: 'Knowledge Level',
                                  options: _knowledgeLevels,
                                  initial: _knowledgeLevel,
                                ),
                              );
                              setState(() => _knowledgeLevel = res);
                            },
                          ),
                          _ListRow(
                            label: 'Animal Lover',
                            value: _animalLover == null ? 'Any' : (_animalLover! ? 'Yes' : 'No'),
                            onTap: () async {
                              final res = await showModalBottomSheet<bool?>(
                                context: context,
                                backgroundColor: Colors.transparent,
                                builder: (_) => _BoolSelectSheet(
                                  title: 'Animal Lover',
                                  initial: _animalLover,
                                ),
                              );
                              setState(() => _animalLover = res);
                            },
                          ),
                          _ListRow(
                            label: 'Vibe Type',
                            value: _vibeType ?? 'Any',
                            onTap: () async {
                              final res = await showModalBottomSheet<String?>(
                                context: context,
                                backgroundColor: Colors.transparent,
                                builder: (_) => _SingleSelectSheet(
                                  title: 'Vibe Type',
                                  options: _vibeTypes,
                                  initial: _vibeType,
                                ),
                              );
                              setState(() => _vibeType = res);
                            },
                          ),
                          _ListRow(
                            label: 'Social Scene',
                            value: _socialScene ?? 'Any',
                            onTap: () async {
                              final res = await showModalBottomSheet<String?>(
                                context: context,
                                backgroundColor: Colors.transparent,
                                builder: (_) => _SingleSelectSheet(
                                  title: 'Social Scene',
                                  options: _socialScenes,
                                  initial: _socialScene,
                                ),
                              );
                              setState(() => _socialScene = res);
                            },
                          ),
                          _ListRow(
                            label: 'Star Signs',
                            value: _starSigns.isEmpty ? 'Any' : _starSigns.join(', '),
                            onTap: () async {
                              final res = await showModalBottomSheet<Set<String>>(
                                context: context,
                                isScrollControlled: true,
                                backgroundColor: Colors.transparent,
                                builder: (_) => _MultiSelectSheet(
                                  title: 'Star Signs',
                                  options: _starSignsOptions,
                                  initial: _starSigns,
                                ),
                              );
                              if (res != null) setState(() => _starSigns = res);
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Lifestyle & Values
                    _SectionCard(
                      outline: _outline,
                      radius: _radiusCard,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const _Heading(icon: Icons.style_outlined, text: 'Lifestyle & Values'),
                          const SizedBox(height: 12),
                          _ListRow(
                            label: 'Future Family Plans',
                            value: _familyPlans ?? 'Any',
                            onTap: () async {
                              final res = await showModalBottomSheet<String?>(
                                context: context,
                                backgroundColor: Colors.transparent,
                                builder: (_) => _SingleSelectSheet(
                                  title: 'Future Family Plans',
                                  options: _familyPlansOptions,
                                  initial: _familyPlans,
                                ),
                              );
                              setState(() => _familyPlans = res);
                            },
                          ),
                          _ListRow(
                            label: 'Smoke Detector',
                            value: _smoke ?? 'Any',
                            onTap: () async {
                              final res = await showModalBottomSheet<String?>(
                                context: context,
                                backgroundColor: Colors.transparent,
                                builder: (_) => _SingleSelectSheet(
                                  title: 'Smoke Detector',
                                  options: _smokeOptions,
                                  initial: _smoke,
                                ),
                              );
                              setState(() => _smoke = res);
                            },
                          ),
                          _ListRow(
                            label: 'Fitness Vibe',
                            value: _fitness ?? 'Any',
                            onTap: () async {
                              final res = await showModalBottomSheet<String?>(
                                context: context,
                                backgroundColor: Colors.transparent,
                                builder: (_) => _SingleSelectSheet(
                                  title: 'Fitness Vibe',
                                  options: _fitnessOptions,
                                  initial: _fitness,
                                ),
                              );
                              setState(() => _fitness = res);
                            },
                          ),
                          _ListRow(
                            label: 'Favourite Foods',
                            value: _foods.isEmpty ? 'Any' : _foods.join(', '),
                            onTap: () async {
                              final res = await showModalBottomSheet<Set<String>>(
                                context: context,
                                isScrollControlled: true,
                                backgroundColor: Colors.transparent,
                                builder: (_) => _MultiSelectSheet(
                                  title: 'Favourite Foods',
                                  options: _foodOptions,
                                  initial: _foods,
                                ),
                              );
                              if (res != null) setState(() => _foods = res);
                            },
                          ),
                          _ListRow(
                            label: 'Dealbreakers',
                            value: _dealbreakers.isEmpty ? 'Any' : _dealbreakers.join(', '),
                            onTap: () async {
                              final res = await showModalBottomSheet<Set<String>>(
                                context: context,
                                isScrollControlled: true,
                                backgroundColor: Colors.transparent,
                                builder: (_) => _MultiSelectSheet(
                                  title: 'Dealbreakers',
                                  options: _dealbreakerOptions,
                                  initial: _dealbreakers,
                                ),
                              );
                              if (res != null) setState(() => _dealbreakers = res);
                            },
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

class _ListRow extends StatelessWidget {
  const _ListRow({
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: AppTheme.ffPrimaryBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.ffAlt.withValues(alpha: .55), width: 1),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500),
                ),
              ),
              Flexible(
                child: Text(
                  value,
                  textAlign: TextAlign.right,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right, color: Colors.white70, size: 18),
            ],
          ),
        ),
      ),
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

// ─────────────────────────────────────────────────────────────────────────────
// Selection sheets

class _SheetScaffold extends StatelessWidget {
  const _SheetScaffold({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF080808),
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            Flexible(child: child),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.ffPrimary,
                  foregroundColor: Colors.white,
                ),
                onPressed: () => Navigator.pop(context),
                child: const Text('Done'),
              ),
            )
          ],
        ),
      ),
    );
  }
}

class _MultiSelectSheet extends StatefulWidget {
  const _MultiSelectSheet({
    required this.title,
    required this.options,
    required this.initial,
  });
  final String title;
  final List<String> options;
  final Set<String> initial;

  @override
  State<_MultiSelectSheet> createState() => _MultiSelectSheetState();
}

class _MultiSelectSheetState extends State<_MultiSelectSheet> {
  late Set<String> _sel;
  @override
  void initState() {
    super.initState();
    _sel = {...widget.initial};
  }

  @override
  Widget build(BuildContext context) {
    return _SheetScaffold(
      title: widget.title,
      child: SingleChildScrollView(
        child: Wrap(
          spacing: 10,
          runSpacing: 10,
          children: widget.options.map((o) {
            final selected = _sel.contains(o);
            return FilterChip(
              label: Text(o),
              selected: selected,
              onSelected: (v) {
                setState(() {
                  if (v) {
                    _sel.add(o);
                  } else {
                    _sel.remove(o);
                  }
                });
                Navigator.pop(context, _sel);
              },
              selectedColor: AppTheme.ffPrimary,
              backgroundColor: const Color(0xFF1E1F24),
              labelStyle: TextStyle(color: selected ? Colors.white : Colors.white70),
            );
          }).toList(),
        ),
      ),
    );
  }
}

class _SingleSelectSheet extends StatefulWidget {
  const _SingleSelectSheet({
    required this.title,
    required this.options,
    required this.initial,
  });
  final String title;
  final List<String> options;
  final String? initial;

  @override
  State<_SingleSelectSheet> createState() => _SingleSelectSheetState();
}

class _SingleSelectSheetState extends State<_SingleSelectSheet> {
  String? _value;
  @override
  void initState() {
    super.initState();
    _value = widget.initial;
  }

  @override
  Widget build(BuildContext context) {
    return _SheetScaffold(
      title: widget.title,
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: widget.options.map((o) {
          final selected = _value == o;
          return ChoiceChip(
            label: Text(o),
            selected: selected,
            onSelected: (_) {
              setState(() => _value = o);
              Navigator.pop(context, o);
            },
            selectedColor: AppTheme.ffPrimary,
            backgroundColor: const Color(0xFF1E1F24),
            labelStyle: TextStyle(color: selected ? Colors.white : Colors.white70),
          );
        }).toList(),
      ),
    );
  }
}

class _BoolSelectSheet extends StatelessWidget {
  const _BoolSelectSheet({required this.title, required this.initial});
  final String title;
  final bool? initial; // null/any

  @override
  Widget build(BuildContext context) {
    const opts = ['Any', 'Yes', 'No'];
    return _SheetScaffold(
      title: title,
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: opts.map((o) {
          final selected =
              (initial == null && o == 'Any') || (initial == true && o == 'Yes') || (initial == false && o == 'No');
          return ChoiceChip(
            label: Text(o),
            selected: selected,
            onSelected: (_) {
              bool? res;
              if (o == 'Yes') {
                res = true;
              } else if (o == 'No') {
                res = false;
              } else {
                res = null;
              }
              Navigator.pop(context, res);
            },
            selectedColor: AppTheme.ffPrimary,
            backgroundColor: const Color(0xFF1E1F24),
            labelStyle: TextStyle(color: selected ? Colors.white : Colors.white70),
          );
        }).toList(),
      ),
    );
  }
}
