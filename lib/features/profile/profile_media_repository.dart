// FILE: lib/features/profile/profile_media_repository.dart
import 'dart:io' show File;
import 'package:image_picker/image_picker.dart';
import 'package:mime_type/mime_type.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/config/storage_config.dart';
import '../../core/config/profile_schema.dart';
import 'profile_repository.dart';

class ProfileMediaRepository {
  ProfileMediaRepository(this._client, this._schema, this._profiles);
  final SupabaseClient _client;
  final ProfileSchema _schema;

  // Kept for DI compatibility; not used directly in this class.
  // ignore: unused_field
  final ProfileRepository _profiles;

  final _picker = ImagePicker();

  /// Adds a photo to the user's profile, returns the public URL (or null if cancelled).
  /// Mobile-optimized:
  /// - Streams file from disk (no big in-memory byte buffers).
  /// - Upload + DB read in parallel.
  /// - One upsert, no returned rows.
  Future<String?> addPhoto({
    required String userId,
    required bool toAvatarBucket,
  }) async {
    final XFile? pick = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1600,   // keep uploads light on mobile networks
      imageQuality: 90, // good balance of size vs. quality
    );
    if (pick == null) return null;

    // Lowercase extension (avoid package:path to keep deps slim)
    String extFrom(String filename) {
      final dot = filename.lastIndexOf('.');
      return dot >= 0 ? filename.substring(dot).toLowerCase() : '';
    }

    final ext = extFrom(pick.name);
    final filename = '${DateTime.now().millisecondsSinceEpoch}$ext';
    final bucket = toAvatarBucket ? StorageConfig.avatarsBucket : StorageConfig.photosBucket;
    final path = '$userId/$filename';

    // Public URL (assumes public bucket)
    final publicUrl = _client.storage.from(bucket).getPublicUrl(path);

    // Start DB fetch immediately (parallel with upload)
    final fetchPhotosFut = _client
        .from(_schema.table)
        .select('photos')
        .eq(_schema.idCol, userId)
        .maybeSingle();

    // Upload straight from disk to keep memory low
    final file = File(pick.path);
    final detectedType = mime(ext.replaceFirst('.', '')) ?? 'image/jpeg';

    final uploadFut = _client.storage.from(bucket).upload(
          path,
          file,
          fileOptions: FileOptions(
            upsert: true,
            contentType: detectedType,
            // unique filenames → safe long caching on CDN
            cacheControl: 'public, max-age=31536000, immutable',
          ),
        );

    // Await both in parallel (minimal total wall time)
    final row = await fetchPhotosFut;
    await uploadFut;

    // Merge photos (newest first)
    final List<String> photos = (row?['photos'] as List?)
            ?.map((e) => (e ?? '').toString())
            .where((s) => s.isNotEmpty)
            .toList() ??
        <String>[];
    photos.insert(0, publicUrl);

    // Single upsert (no returning payload to avoid extra bytes)
    await _client.from(_schema.table).upsert(
      {
        _schema.idCol: userId,
        'photos': photos,
        'avatar_url': photos.first, // newest acts as avatar
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      onConflict: _schema.idCol,
    );

    return publicUrl;
  }
}
