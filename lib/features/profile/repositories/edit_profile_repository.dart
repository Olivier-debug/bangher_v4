// Supabase storage + DB helpers used by EditProfilePage and the photo outbox.
// No dart:io, no extra helper files — uses uploadBinary everywhere.

import 'dart:typed_data';
import 'package:supabase_flutter/supabase_flutter.dart';

class EditProfileRepository {
  EditProfileRepository(this._sb);
  final SupabaseClient _sb;

  /// Upload a profile image and return a storage path your UI can sign later:
  /// `storage://profile_pictures/<userId>/<filename>`
  ///
  /// Always pass [bytes]. We intentionally avoid dart:io to keep this file
  /// web-safe and avoid extra helper files.
  Future<String> uploadProfileImage({
    required String userId,
    required String filePath, // original filename for naming only
    required Uint8List bytes,
  }) async {
    const bucket = 'profile_pictures';
    final safeName = _safeName(filePath);
    final storagePath = '$userId/$safeName';

    await _sb.storage.from(bucket).uploadBinary(
          storagePath,
          bytes,
          fileOptions: const FileOptions(upsert: true),
    );

    return 'storage://$bucket/$storagePath';
  }

  Future<void> setProfilePictures({
    required String userId,
    required List<String> urls,
  }) async {
    await _sb.from('profiles').update({'profile_pictures': urls}).eq('user_id', userId);
  }

  // Keep only a clean file name, prefix with timestamp, and sanitize.
  static String _safeName(String originalPath) {
    final base = _basename(originalPath);
    final ts = DateTime.now().millisecondsSinceEpoch;
    return '${ts}_${base.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), "_")}';
  }

  // Simple basename without extra packages.
  static String _basename(String p) {
    final slash = p.lastIndexOf('/');
    final back = p.lastIndexOf('\\');
    final i = slash > back ? slash : back;
    return i >= 0 ? p.substring(i + 1) : p;
  }
}
