import 'package:flutter/material.dart';
import '../../../theme/app_theme.dart';
import 'signed_image.dart';

class EditStylePhotosGrid extends StatelessWidget {
  const EditStylePhotosGrid({
    super.key,
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
