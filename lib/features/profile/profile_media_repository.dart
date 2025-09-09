// FILE: lib/features/profile/profile_media_repository.dart
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
  Future<String?> addPhoto({
    required String userId,
    required bool toAvatarBucket,
  }) async {
    final XFile? pick = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1600,
      imageQuality: 92,
    );
    if (pick == null) return null;

    // Get a lowercase extension without using `package:path`
    String extFrom(String filename) {
      final dot = filename.lastIndexOf('.');
      return dot >= 0 ? filename.substring(dot).toLowerCase() : '';
    }

    final ext = extFrom(pick.name);
    final filename = '${DateTime.now().millisecondsSinceEpoch}$ext';
    final bucket = toAvatarBucket ? StorageConfig.avatarsBucket : StorageConfig.photosBucket;
    final path = '$userId/$filename';

    final bytes = await pick.readAsBytes();
    final contentType = mime(ext.replaceFirst('.', '')) ?? 'image/jpeg';

    // Upload to storage
    await _client.storage
        .from(bucket)
        .uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(
            upsert: true,
            contentType: contentType,
            cacheControl: '3600',
          ),
        );

    final publicUrl = _client.storage.from(bucket).getPublicUrl(path);

    // Fetch existing photos and update profile record
    final row = await _client
        .from(_schema.table)
        .select('photos, avatar_url')
        .eq(_schema.idCol, userId)
        .maybeSingle();

    final List<String> photos =
        (row?['photos'] as List?)?.map((e) => e.toString()).toList() ?? <String>[];

    // Add newest first; first photo doubles as avatar
    photos.insert(0, publicUrl);

    await _client
        .from(_schema.table)
        .upsert(
          {
            _schema.idCol: userId,
            'photos': photos,
            'avatar_url': photos.first,
            'updated_at': DateTime.now().toIso8601String(),
          },
          onConflict: _schema.idCol,
        )
        .select(); // ensure errors bubble up

    return publicUrl;
  }
}
