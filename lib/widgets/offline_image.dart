// -----------------------------------------------------------------------------
// file: lib/widgets/offline_image.dart
// Local-first image widget. Uses PinnedImageCache under the hood.

import 'dart:io' as io;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../core/cache/pinned_image_cache.dart';

class OfflineImage extends StatelessWidget {
  const OfflineImage.url({
    super.key,
    required this.url,
    required this.ownerUid,
    this.fit,
    this.placeholder,
    this.error,
  });

  final String url;
  final String ownerUid; // namespace for local cache
  final BoxFit? fit;
  final Widget? placeholder;
  final Widget? error;

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
      return Image.network(url, fit: fit, errorBuilder: (_, __, ___) => error ?? const SizedBox());
    }

    return FutureBuilder<Map<String, String>>(
      future: PinnedImageCache.instance.localPaths([url], uid: ownerUid),
      builder: (context, snap) {
        final path = (snap.data ?? const {})[url];
        if (path != null && io.File(path).existsSync()) {
          return Image.file(io.File(path), fit: fit, errorBuilder: (_, __, ___) => error ?? const SizedBox());
        }
        return Image.network(url, fit: fit, errorBuilder: (_, __, ___) => error ?? const SizedBox());
      },
    );
  }
}