import 'package:flutter/material.dart';
import 'grid_shimmer.dart';
import 'signed_url_cache.dart';

class SignedImage extends StatelessWidget {
  const SignedImage({
    super.key,
    required this.rawUrlOrPath,
    required this.fit,
    this.explicitLogicalWidth,
    this.explicitCacheWidth,
  });

  final String rawUrlOrPath;
  final BoxFit fit;
  final double? explicitLogicalWidth; // why: enable crisp zoom in viewers
  final int? explicitCacheWidth;      // why: control cache size on demand

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final dpr = MediaQuery.of(context).devicePixelRatio;
      final logicalW = explicitLogicalWidth ?? constraints.maxWidth;
      final cacheW =
          explicitCacheWidth ?? (logicalW.isFinite ? (logicalW * dpr).round() : null);

      return FutureBuilder<String>(
        future: SignedUrlCache.resolve(rawUrlOrPath),
        builder: (context, snap) {
          if (!snap.hasData) return const GridShimmer();
          return Image.network(
            snap.data!,
            fit: fit,
            cacheWidth: cacheW,
            filterQuality: FilterQuality.medium,
            gaplessPlayback: true,
            loadingBuilder: (context, child, progress) {
              if (progress == null) return child;
              return const GridShimmer();
            },
            errorBuilder: (_, __, ___) => const ColoredBox(
              color: Colors.black26,
              child: Center(child: Icon(Icons.broken_image, color: Colors.white70)),
            ),
          );
        },
      );
    });
  }
}
