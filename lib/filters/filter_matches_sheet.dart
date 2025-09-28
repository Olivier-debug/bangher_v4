// ============================================================================
// lib/filters/filter_matches_sheet.dart
// Discovery / Filters screen styled like EditProfilePage.
// Writes to public.preferences where columns exist in your schema.
// Persists two local-only smart-expansion toggles in SharedPreferences.
// ============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../theme/app_theme.dart'; // same theme used by EditProfilePage

class FilterMatchesSheet extends ConsumerStatefulWidget {
  const FilterMatchesSheet({super.key});

  @override
  ConsumerState<FilterMatchesSheet> createState() => _FilterMatchesSheetState();
}

class _FilterMatchesSheetState extends ConsumerState<FilterMatchesSheet> {
  // ── Local-only expansion toggles
  static const _kExpandDistanceKey = 'prefs_expand_distance_when_out_v1';
  static const _kExpandAgeKey = 'prefs_expand_age_when_out_v1';

  // Form state
  final _city = TextEditingController();
  final _jobTitle = TextEditingController();
  final _company = TextEditingController();
  final _education = TextEditingController();
  final _familyPlans = TextEditingController();
  final _loveLanguage = TextEditingController();

  // Ranges / choices
  String? _gender; // 'M' | 'F' | 'O'
  int _ageMin = 18;
  int _ageMax = 60;
  int _distance = 50;

  // Optional/advanced filters (nullable = don't constrain)
  final Set<String> _languages = {};
  final Set<String> _relationshipTypes = {};
  String? _pets;
  String? _drinking;
  String? _smoking;
  String? _workout;
  String? _dietary;
  int? _height;
  int? _weight;
  String? _excerciseSchemaSafe; // schema has "excercise"

  bool _expandDistance = false;
  bool _expandAge = false;

  bool _loading = true;
  bool _saving = false;

  // Options (reusing what you already show on EditProfilePage)
  static const languageOptions = [
    'English','Afrikaans','Zulu','Xhosa','Sotho',
    'French','Spanish','German','Italian','Portuguese',
  ];
  static const relationshipOptions = [
    'Long-term','Short-term','Open to explore','Marriage','Friendship',
  ];
  static const petsOptions = ['No pets','Cat person','Dog person','All the pets'];
  static const drinkingOptions = ['Never','On special occasions','Socially','Often'];
  static const smokingOptions = ['Never','Occasionally','Smoker when drinking','Regularly'];
  static const workoutOptions = ['Never','Sometimes','Often'];
  static const dietaryOptions = ['Omnivore','Vegetarian','Vegan','Pescatarian','Halal','Kosher'];

  @override
  void initState() {
    super.initState();
    _hydrate();
  }

  @override
  void dispose() {
    _city.dispose();
    _jobTitle.dispose();
    _company.dispose();
    _education.dispose();
    _familyPlans.dispose();
    _loveLanguage.dispose();
    super.dispose();
  }

  Future<void> _hydrate() async {
    final me = Supabase.instance.client.auth.currentUser;
    if (me == null) {
      setState(() => _loading = false);
      return;
    }

    // Local toggles
    final prefs = await SharedPreferences.getInstance();
    _expandDistance = prefs.getBool(_kExpandDistanceKey) ?? false;
    _expandAge = prefs.getBool(_kExpandAgeKey) ?? false;

    try {
      // NOTE: remove type args from select() to support your SDK version.
      final data = await Supabase.instance.client
          .from('preferences')
          .select()
          .eq('user_id', me.id)
          .maybeSingle();

      final Map<String, dynamic>? row =
          data is Map<String, dynamic> ? data : null;

      if (row != null) {
        String? s(dynamic v) =>
            (v?.toString().trim().isEmpty ?? true) ? null : v.toString().trim();
        List<String> listStr(dynamic v) => v is List
            ? v
                .map((e) => e?.toString() ?? '')
                .where((t) => t.trim().isNotEmpty)
                .cast<String>()
                .toList()
            : <String>[];

        _gender = s(row['interested_in_gender']); // M/F/O
        _ageMin = (row['age_min'] as num?)?.toInt() ?? _ageMin;
        _ageMax = (row['age_max'] as num?)?.toInt() ?? _ageMax;
        _distance = (row['distance_radius'] as num?)?.toInt() ?? _distance;

        _city.text = s(row['city']) ?? '';
        _jobTitle.text = s(row['job_title']) ?? '';
        _company.text = s(row['company']) ?? '';
        _education.text = s(row['education']) ?? '';
        _familyPlans.text = s(row['family_plans']) ?? '';
        _loveLanguage.text = s(row['love_language']) ?? '';

        _languages
          ..clear()
          ..addAll(listStr(row['match_languages']));

        _relationshipTypes
          ..clear()
          ..addAll(listStr(row['relationship_type']));

        _pets = s(row['pets']);
        _drinking = s(row['drinking']);
        _smoking = s(row['smoking']);
        _excerciseSchemaSafe = s(row['excercise']); // keep schema name
        _workout = _excerciseSchemaSafe;            // UX label shows "Workout"
        _dietary = s(row['diet_preference']) ?? s(row['dietary_preference']); // support either
        _height = (row['height'] as num?)?.toInt();
        _weight = (row['weight'] as num?)?.toInt();
      }
    } catch (_) {
      // fail-soft
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    final me = Supabase.instance.client.auth.currentUser;
    if (me == null) return;

    setState(() => _saving = true);
    try {
      final patch = <String, dynamic>{
        'user_id': me.id,
        'interested_in_gender': _gender,
        'age_min': _ageMin,
        'age_max': _ageMax,
        'distance_radius': _distance,
        'match_languages': _languages.isEmpty ? null : _languages.toList(),
        'relationship_type': _relationshipTypes.isEmpty ? null : _relationshipTypes.toList(),
        'city': _city.text.trim().isEmpty ? null : _city.text.trim(),
        'job_title': _jobTitle.text.trim().isEmpty ? null : _jobTitle.text.trim(),
        'company': _company.text.trim().isEmpty ? null : _company.text.trim(),
        'education': _education.text.trim().isEmpty ? null : _education.text.trim(),
        'family_plans': _familyPlans.text.trim().isEmpty ? null : _familyPlans.text.trim(),
        'love_language': _loveLanguage.text.trim().isEmpty ? null : _loveLanguage.text.trim(),
        'pets': _pets,
        'drinking': _drinking,
        'smoking': _smoking,
        // Keep the schema column name "excercise"
        'excercise': _workout,
        //'diet_preference': _dietary, // if you use dietary_preference instead, change here
        'height': _height,
        'weight': _weight,
      };

      await Supabase.instance.client
          .from('preferences')
          .upsert(patch, onConflict: 'user_id');

      // Persist local-only toggles
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kExpandDistanceKey, _expandDistance);
      await prefs.setBool(_kExpandAgeKey, _expandAge);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Filters updated')),
      );
      Navigator.of(context).maybePop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save: $e'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ── UI helpers styled like EditProfilePage ─────────────────────────────────

  Color get _outline => AppTheme.ffAlt;
  static const _radiusCard = 12.0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.ffSecondaryBg,
      appBar: AppBar(
        backgroundColor: AppTheme.ffPrimaryBg,
        title: const Text('Discovery Settings'),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(10, 16, 10, 24),
                children: [
                  _Card(
                    radius: _radiusCard,
                    outline: _outline,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const _Heading(icon: Icons.place_outlined, text: 'Location'),
                        const SizedBox(height: 12),
                        _LabeledText('City', _city),
                        const SizedBox(height: 6),
                        const Text(
                          'Change locations to find matches anywhere.',
                          style: TextStyle(color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Distance
                  _Card(
                    radius: _radiusCard,
                    outline: _outline,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const _Heading(icon: Icons.social_distance, text: 'Maximum distance'),
                            const Spacer(),
                            Text(
                              '$_distance km',
                              style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                        Slider(
                          value: _distance.toDouble(),
                          min: 1,
                          max: 1000,
                          divisions: 99,
                          label: '$_distance',
                          onChanged: (v) => setState(() => _distance = v.round()),
                          activeColor: AppTheme.ffPrimary,
                          thumbColor: AppTheme.ffPrimary,
                        ),
                        const SizedBox(height: 8),
                        _SwitchTile(
                          text: 'Show people further away if I run out of profiles to see',
                          value: _expandDistance,
                          onChanged: (v) => setState(() => _expandDistance = v),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Interested in
                  _Card(
                    radius: _radiusCard,
                    outline: _outline,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const _Heading(icon: Icons.transgender_outlined, text: 'Interested in'),
                        const SizedBox(height: 12),
                        _Dropdown<String>(
                          label: 'Gender',
                          value: _genderLabel(_gender),
                          items: const ['Women', 'Men', 'Other', 'All'],
                          onChanged: (val) => setState(() => _gender = _genderDb(val)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Age range
                  _Card(
                    radius: _radiusCard,
                    outline: _outline,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const _Heading(icon: Icons.cake_outlined, text: 'Age range'),
                            const Spacer(),
                            Text(
                              '$_ageMin – $_ageMax',
                              style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                        RangeSlider(
                          values: RangeValues(_ageMin.toDouble(), _ageMax.toDouble()),
                          min: 18,
                          max: 87,
                          divisions: 69,
                          activeColor: AppTheme.ffPrimary,
                          onChanged: (r) => setState(() {
                            _ageMin = r.start.round();
                            _ageMax = r.end.round();
                          }),
                        ),
                        const SizedBox(height: 8),
                        _SwitchTile(
                          text:
                              'Show people slightly out of my preferred range if I run out of profiles to see',
                          value: _expandAge,
                          onChanged: (v) => setState(() => _expandAge = v),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Languages
                  _Card(
                    radius: _radiusCard,
                    outline: _outline,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const _Heading(icon: Icons.translate_outlined, text: 'Languages'),
                        const SizedBox(height: 10),
                        _ChipsSelector(
                          options: languageOptions,
                          values: _languages,
                          onChanged: (next) => setState(() {
                            _languages
                              ..clear()
                              ..addAll(next);
                          }),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Relationship type
                  _Card(
                    radius: _radiusCard,
                    outline: _outline,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const _Heading(icon: Icons.flag_outlined, text: 'Looking for'),
                        const SizedBox(height: 10),
                        _ChipsSelector(
                          options: relationshipOptions,
                          values: _relationshipTypes,
                          onChanged: (next) => setState(() {
                            _relationshipTypes
                              ..clear()
                              ..addAll(next);
                          }),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Lifestyle filters (nullable -> don't constrain)
                  _Card(
                    radius: _radiusCard,
                    outline: _outline,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const _Heading(icon: Icons.style_outlined, text: 'Lifestyle'),
                        const SizedBox(height: 10),
                        _Dropdown<String>(
                          label: 'Pets (optional)',
                          value: _pets,
                          items: const ['Any', ...petsOptions],
                          onChanged: (v) => setState(() => _pets = _nullIfAny(v)),
                        ),
                        const SizedBox(height: 10),
                        _Dropdown<String>(
                          label: 'Drinking (optional)',
                          value: _drinking,
                          items: const ['Any', ...drinkingOptions],
                          onChanged: (v) => setState(() => _drinking = _nullIfAny(v)),
                        ),
                        const SizedBox(height: 10),
                        _Dropdown<String>(
                          label: 'Smoking (optional)',
                          value: _smoking,
                          items: const ['Any', ...smokingOptions],
                          onChanged: (v) => setState(() => _smoking = _nullIfAny(v)),
                        ),
                        const SizedBox(height: 10),
                        _Dropdown<String>(
                          label: 'Workout (optional)',
                          value: _workout,
                          items: const ['Any', ...workoutOptions],
                          onChanged: (v) => setState(() => _workout = _nullIfAny(v)),
                        ),
                        const SizedBox(height: 10),
                        _Dropdown<String>(
                          label: 'Dietary preference (optional)',
                          value: _dietary,
                          items: const ['Any', ...dietaryOptions],
                          onChanged: (v) => setState(() => _dietary = _nullIfAny(v)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // About / work (optional)
                  _Card(
                    radius: _radiusCard,
                    outline: _outline,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const _Heading(icon: Icons.work_outline, text: 'About & work (optional)'),
                        const SizedBox(height: 10),
                        _LabeledText('Job title', _jobTitle),
                        const SizedBox(height: 10),
                        _LabeledText('Company', _company),
                        const SizedBox(height: 10),
                        _LabeledText('Education', _education),
                        const SizedBox(height: 10),
                        _LabeledText('Family plans', _familyPlans),
                        const SizedBox(height: 10),
                        _LabeledText('Love style (love language)', _loveLanguage),
                        const SizedBox(height: 10),
                        _NumberRow(
                          label: 'Height (cm)',
                          value: _height,
                          min: 120,
                          max: 250,
                          onChanged: (v) => setState(() => _height = v),
                        ),
                        const SizedBox(height: 10),
                        _NumberRow(
                          label: 'Weight (kg)',
                          value: _weight,
                          min: 30,
                          max: 200,
                          onChanged: (v) => setState(() => _weight = v),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  ElevatedButton(
                    onPressed: _saving ? null : _save,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.ffPrimary,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: _saving
                        ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Apply filters', style: TextStyle(color: Colors.white, fontSize: 16)),
                  ),
                ],
              ),
      ),
    );
  }

  // Map DB gender ↔︎ label
  String? _genderLabel(String? db) {
    switch ((db ?? '').toUpperCase()) {
      case 'F':
        return 'Women';
      case 'M':
        return 'Men';
      case 'O':
        return 'Other';
      default:
        return 'All';
    }
  }

  String? _genderDb(String? label) {
    switch (label) {
      case 'Women':
        return 'F';
      case 'Men':
        return 'M';
      case 'Other':
        return 'O';
      case 'All':
      default:
        return null; // null = any
    }
  }

  String? _nullIfAny(String? v) => (v == null || v == 'Any') ? null : v;
}

// ──────────────────────────────────────────────────────────────
// Reusable widgets (styled after EditProfilePage bits)
// ──────────────────────────────────────────────────────────────

class _Card extends StatelessWidget {
  const _Card({required this.child, required this.radius, required this.outline});
  final Widget child;
  final double radius;
  final Color outline;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color.fromARGB(255, 0, 0, 0),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: outline.withValues(alpha: .50), width: 1.2),
      ),
      child: Padding(padding: const EdgeInsets.all(14), child: child),
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

class _LabeledText extends StatelessWidget {
  const _LabeledText(this.label, this.controller);
  final String label;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      maxLines: 1,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white70),
        filled: true,
        fillColor: const Color(0xFF141414),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: AppTheme.ffAlt.withValues(alpha: .60)),
          borderRadius: BorderRadius.circular(10),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: AppTheme.ffPrimary),
          borderRadius: BorderRadius.circular(10),
        ),
      ),
    );
  }
}

class _Dropdown<T> extends StatelessWidget {
  const _Dropdown({required this.label, required this.value, required this.items, required this.onChanged});
  final String label;
  final T? value;
  final List<T> items;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    final T? safeValue = (value != null && items.contains(value)) ? value : null;
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white70),
        filled: true,
        fillColor: const Color(0xFF141414),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: AppTheme.ffAlt.withValues(alpha: .60)),
          borderRadius: BorderRadius.circular(10),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: AppTheme.ffPrimary),
          borderRadius: BorderRadius.circular(10),
        ),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: safeValue,
          isExpanded: true,
          dropdownColor: const Color(0xFF000000),
          items: items
              .map((e) => DropdownMenuItem<T>(
                    value: e,
                    child: Text(e.toString(), style: const TextStyle(color: Colors.white)),
                  ))
              .toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _ChipsSelector extends StatelessWidget {
  const _ChipsSelector({required this.options, required this.values, required this.onChanged});
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
          selectedColor: AppTheme.ffPrimary.withValues(alpha: .55),
          backgroundColor: const Color(0xFF141414),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          side: BorderSide(color: AppTheme.ffAlt.withValues(alpha: .60)),
        );
      }).toList(),
    );
  }
}

class _SwitchTile extends StatelessWidget {
  const _SwitchTile({required this.text, required this.value, required this.onChanged});
  final String text;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(text, style: const TextStyle(color: Colors.white70))),
        Switch(
          value: value,
          onChanged: onChanged,
          // Use Widgets-layer properties (non-deprecated).
          thumbColor: const WidgetStatePropertyAll<Color>(Colors.white),
          trackColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) return AppTheme.ffPrimary;
            return Colors.white24;
          }),
        ),
      ],
    );
  }
}

class _NumberRow extends StatelessWidget {
  const _NumberRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final int? value;
  final int min;
  final int max;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white70),
        filled: true,
        fillColor: const Color(0xFF141414),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: AppTheme.ffAlt.withValues(alpha: .60)),
          borderRadius: BorderRadius.circular(10),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: AppTheme.ffPrimary),
          borderRadius: BorderRadius.circular(10),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: (value ?? min) > min ? () => onChanged((value ?? min) - 1) : null,
            icon: const Icon(Icons.remove, color: Colors.white70),
          ),
          Expanded(
            child: Center(
              child: Text(value?.toString() ?? '—',
                  style: const TextStyle(color: Colors.white, fontSize: 16)),
            ),
          ),
          IconButton(
            onPressed: (value ?? min) < max ? () => onChanged((value ?? min) + 1) : null,
            icon: const Icon(Icons.add, color: Colors.white70),
          ),
        ],
      ),
    );
  }
}
