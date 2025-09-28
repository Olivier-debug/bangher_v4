// FILE: lib/features/profile/profile_media_repository.dart
import 'dart:io' show File;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:image_picker/image_picker.dart';
import 'package:mime_type/mime_type.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/config/profile_schema.dart';
import '../../../core/config/storage_config.dart';
import 'profile_repository.dart';

class ProfileMediaRepository {
  ProfileMediaRepository(this._client, this._schema, this._profiles);
  final SupabaseClient _client;
  final ProfileSchema _schema;

  // Kept for DI compatibility; not used directly in this class.
  // ignore: unused_field
  final ProfileRepository _profiles;

  final _picker = ImagePicker();

  /// Adds a photo to the user's profile, returns the public (or signed) URL,
  /// or null if the user cancelled.
  Future<String?> addPhoto({
    required String userId,
    required bool toAvatarBucket,
  }) async {
    final XFile? pick = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1600,
      imageQuality: 90,
    );
    if (pick == null) return null;

    // Lowercase extension (no package:path)
    String extFrom(String filename) {
      final dot = filename.lastIndexOf('.');
      return dot >= 0 ? filename.substring(dot).toLowerCase() : '';
    }

    final ext = extFrom(pick.name); // e.g. ".jpg"
    final contentType = mime(ext.isNotEmpty ? ext.substring(1) : '') ?? 'image/jpeg';

    final filename = '${DateTime.now().millisecondsSinceEpoch}$ext';
    final bucket =
        toAvatarBucket ? StorageConfig.avatarsBucket : StorageConfig.photosBucket;
    final path = '$userId/$filename';

    final storage = _client.storage.from(bucket);

    // Figure out the correct photos column from schema, or default.
    final photosCol = (_schema.photosCol != null && _schema.photosCol!.isNotEmpty)
        ? _schema.photosCol!
        : 'profile_pictures';
    // IMPORTANT: your table has no avatar column; only set if schema provides one.
    final avatarCol = (_schema.avatarUrlCol ?? '').trim(); // may be empty

    // Start DB read in parallel with upload
    final fetchPhotosFut = _client
        .from(_schema.table)
        .select(photosCol)
        .eq(_schema.idCol, userId)
        .maybeSingle();

    // Upload (web via bytes, mobile via File)
    if (kIsWeb) {
      final bytes = await pick.readAsBytes();
      final uint8 = bytes;
      await storage.uploadBinary(
        path,
        uint8,
        fileOptions: FileOptions(
          upsert: true,
          contentType: contentType,
          cacheControl: 'public, max-age=31536000, immutable',
        ),
      );
    } else {
      final file = File(pick.path);
      await storage.upload(
        path,
        file,
        fileOptions: FileOptions(
          upsert: true,
          contentType: contentType,
          cacheControl: 'public, max-age=31536000, immutable',
        ),
      );
    }

    // If your buckets are public, this is fine. For private, use createSignedUrl.
    final uploadedUrl = storage.getPublicUrl(path);

    // Merge photos (newest first)
    final row = await fetchPhotosFut;
    final existing = _stringList(row?[photosCol]);
    final nextPhotos = <String>[uploadedUrl, ...existing];

    // Single upsert (no returning payload)
    final payload = <String, dynamic>{
      _schema.idCol: userId,
      photosCol: nextPhotos,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    if (avatarCol.isNotEmpty) {
      payload[avatarCol] = nextPhotos.first;
    }

    await _client.from(_schema.table).upsert(
      payload,
      onConflict: _schema.idCol,
    );

    return uploadedUrl;
  }

  // ---- helpers ----
  List<String> _stringList(dynamic v) {
    if (v is List) {
      return v
          .map((e) => (e ?? '').toString())
          .where((s) => s.isNotEmpty)
          .toList(growable: false);
    }
    return const <String>[];
  }
}
