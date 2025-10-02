import 'package:flutter/material.dart';
import '../../../../theme/app_theme.dart';
import './_step_shared.dart' show StepScaffold, StepTitle;
import '../../profile/widgets/signed_image.dart';

class StepPhotosPrefs extends StatelessWidget {
  const StepPhotosPrefs({
    super.key,
    required this.pictures,
    required this.onAdd,
    required this.onTapImage,
    required this.ageRange,
    required this.onAgeRangeChanged,
    required this.maxDistanceKm,
    required this.onDistanceChanged,
  });

  final List<String> pictures;
  final VoidCallback onAdd;
  final ValueChanged<int> onTapImage;

  final RangeValues ageRange;
  final ValueChanged<RangeValues> onAgeRangeChanged;

  final int maxDistanceKm;
  final ValueChanged<double> onDistanceChanged;

  @override
  Widget build(BuildContext context) {
    return StepScaffold(
      title: 'Photos & preferences',
      children: [
        const StepTitle('Add your photos'),
        _EditStylePhotosGrid(
          pictures: pictures,
          onAdd: onAdd,
          onTapImage: onTapImage,
        ),
        const SizedBox(height: 12),
        const Text(
          'Tip: Add 3–6 clear photos for the best results.',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
        const SizedBox(height: 16),
        const StepTitle('Preferences'),
        const SizedBox(height: 8),
        Text(
          'Age range: ${ageRange.start.round()} - ${ageRange.end.round()}',
          style: const TextStyle(color: Colors.white),
        ),
        RangeSlider(
          values: ageRange,
          min: 18,
          max: 100,
          divisions: 82,
          labels: RangeLabels(
            '${ageRange.start.round()}',
            '${ageRange.end.round()}',
          ),
          activeColor: AppTheme.ffPrimary,
          onChanged: onAgeRangeChanged,
        ),
        const SizedBox(height: 8),
        Text(
          'Max distance: $maxDistanceKm km',
          style: const TextStyle(color: Colors.white),
        ),
        Slider(
          value: maxDistanceKm.toDouble(),
          min: 5,
          max: 200,
          divisions: 39,
          activeColor: AppTheme.ffPrimary,
          label: '$maxDistanceKm km',
          onChanged: onDistanceChanged,
        ),
      ],
    );
  }
}

class _EditStylePhotosGrid extends StatelessWidget {
  const _EditStylePhotosGrid({
    required this.pictures,
    required this.onAdd,
    required this.onTapImage,
  });

  final List<String> pictures;
  final VoidCallback onAdd;
  final ValueChanged<int> onTapImage;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final cols = width < 480 ? 2 : 3;

    final cells = <Widget>[
      for (int i = 0; i < pictures.length; i++)
        InkWell(
          onTap: () => onTapImage(i),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SignedImage(rawUrlOrPath: pictures[i], fit: BoxFit.cover),
          ),
        ),
      if (pictures.length < 6)
        InkWell(
          onTap: onAdd,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xFF141414),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.ffAlt.withValues(alpha: .60)),
            ),
            child: const Center(
              child: Icon(Icons.add_a_photo_outlined, color: Colors.white70),
            ),
          ),
        ),
    ];

    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: cols,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      children: cells,
    );
  }
}
