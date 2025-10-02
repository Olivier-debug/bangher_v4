// lib/features/profile/application/photo_batch_flow.dart
//
// Batch picker → (per-item) crop → upload to Supabase Storage.
// Returns storage paths; signing is handled by SignedUrlCache/SignedImage downstream.

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../profile/repositories/edit_profile_repository.dart';
import '../../profile/widgets/signed_url_cache.dart'; // import the actual cache
import '../../../widgets/photo_cropper_dialog.dart';

class BatchUploadResult {
  BatchUploadResult({
    required this.storagePaths,
    this.signedUrls,
  });

  /// Storage paths or public URLs returned by the repo (e.g. `profile_pictures/<uid>/file.jpg`
  /// or `storage://bucket/path` or a public http(s) URL).
  final List<String> storagePaths;

  /// Optional: resolved signed URLs (1:1 with storagePaths) when
  /// [pickCropAndUploadPhotos] is called with `returnSignedUrls: true`.
  final List<String>? signedUrls;
}

/// Launches a multi-image picker, then for each selected image opens the cropper
/// dialog and uploads the cropped bytes. Returns the uploaded storage paths.
/// If [returnSignedUrls] is true, it also returns pre-resolved signed URLs
/// by using the shared SignedUrlCache (no repository dependency).
Future<BatchUploadResult?> pickCropAndUploadPhotos(
  BuildContext context, {
  required String userId,
  int maxCount = 6,
  bool returnSignedUrls = false,
}) async {
  final picker = ImagePicker();

  // 1) Pick multiple images (quietly allow user to select more but only process up to maxCount)
  final picked = await picker.pickMultiImage(
    imageQuality: 96,
    maxWidth: 2048,
    maxHeight: 2048,
  );

  if (picked.isEmpty) return null;
  final files = picked.take(maxCount).toList();

  // Early bail if the calling widget went away
  if (!context.mounted) return null;

  final repo = EditProfileRepository(Supabase.instance.client);
  final uploadedPaths = <String>[];

  // 2) For each picked image: crop → upload
  for (int i = 0; i < files.length; i++) {
    final x = files[i];

    final originalBytes = await x.readAsBytes();
    if (!context.mounted) return null;

    final croppedBytes = await showProfilePhotoCropper(
      context,
      sourceBytes: originalBytes,
    );

    // User skipped this item
    if (croppedBytes == null) continue;
    if (!context.mounted) return null;

    final safeName = _sanitizeName(x.name, index: i);

    // Upload via repository (returns storage path or public URL)
    final urlOrPath = await repo.uploadProfileImage(
      userId: userId,
      filePath: safeName,
      bytes: croppedBytes,
    );

    uploadedPaths.add(urlOrPath);
  }

  if (uploadedPaths.isEmpty) return null;

  // 3) Optionally pre-resolve signed URLs using the shared cache
  List<String>? signed;
  if (returnSignedUrls) {
    signed = [];
    for (final p in uploadedPaths) {
      final s = await SignedUrlCache.resolve(p);
      signed.add(s);
    }
  }

  return BatchUploadResult(storagePaths: uploadedPaths, signedUrls: signed);
}

String _sanitizeName(String raw, {required int index}) {
  var name = raw.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
  if (name.length > 64) {
    name = name.substring(name.length - 64);
  }
  final ts = DateTime.now().millisecondsSinceEpoch;
  // Ensure uniqueness and keep extension if present
  final dot = name.lastIndexOf('.');
  if (dot > 0 && dot < name.length - 1) {
    final base = name.substring(0, dot);
    final ext = name.substring(dot); // includes the dot
    return 'p_${ts}_$index$base$ext';
  }
  return 'p_${ts}_$index$name';
}
