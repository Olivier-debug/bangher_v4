// lib/features/profile/edit_profile_repository.dart
import 'dart:io' show File;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mime_type/mime_type.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final editProfileRepositoryProvider = Provider<EditProfileRepository>((ref) {
  return EditProfileRepository(Supabase.instance.client);
});

/// Supabase bucket name (underscore, per your project).
const String _profileBucket = 'profile_pictures';

/// Prefer signed URLs so it works whether the bucket is public or private.
const bool _preferSignedUrls = true;

class ProfileUpdate {
  final String? name;
  final String? bio;
  final String? gender;
  final String? currentCity;
  final DateTime? dateOfBirth;
  final int? height;
  final int? weight;
  final String? jobTitle;
  final String? company;
  final String? education;
  final String? school;
  final String? loveLanguage;
  final String? familyPlans;
  final String? communicationStyle;
  final String? religion;
  final String? drinking;
  final String? smoking;
  final String? exercise;
  final List<String>? interests;         // text[]
  final List<String>? relationshipGoals; // text[]
  final List<String>? myLanguages;       // text[]
  final List<String>? profilePictures;   // text[]

  const ProfileUpdate({
    this.name,
    this.bio,
    this.gender,
    this.currentCity,
    this.dateOfBirth,
    this.height,
    this.weight,
    this.jobTitle,
    this.company,
    this.education,
    this.school,
    this.loveLanguage,
    this.familyPlans,
    this.communicationStyle,
    this.religion,
    this.drinking,
    this.smoking,
    this.exercise,
    this.interests,
    this.relationshipGoals,
    this.myLanguages,
    this.profilePictures,
  });

  Map<String, dynamic> toMap() {
    final m = <String, dynamic>{};
    void put(String k, dynamic v) {
      if (v == null) return;
      m[k] = v;
    }

    put('name', name);
    put('bio', bio);
    put('gender', gender);
    put('current_city', currentCity);
    put('date_of_birth', dateOfBirth?.toUtc().toIso8601String());
    put('height', height);
    put('weight', weight);
    put('job_title', jobTitle);
    put('company', company);
    put('education', education);
    put('school', school);
    put('love_language', loveLanguage);
    put('family_plans', familyPlans);
    put('communication_style', communicationStyle);
    put('religion', religion);
    put('drinking', drinking);
    put('smoking', smoking);
    put('exercise', exercise);
    if (interests != null) put('interests', interests);
    if (relationshipGoals != null) put('relationship_goals', relationshipGoals);
    if (myLanguages != null) put('my_languages', myLanguages);
    if (profilePictures != null) put('profile_pictures', profilePictures);
    return m;
  }

  bool get isEmpty => toMap().isEmpty;
}

class EditProfileRepository {
  EditProfileRepository(this._db);
  final SupabaseClient _db;

  Future<Map<String, dynamic>?> fetchByUserId(String userId) async {
    return await _db
        .from('profiles')
        .select('*')
        .eq('user_id', userId)
        .maybeSingle();
  }

  Future<void> createProfile({
    required String userId,
    required ProfileUpdate update,
  }) async {
    final data = update.toMap()..putIfAbsent('user_id', () => userId);
    await _db.from('profiles').insert(data);
  }

  Future<void> updateProfile({
    required String userId,
    required ProfileUpdate update,
  }) async {
    if (update.isEmpty) return;
    await _db.from('profiles').update(update.toMap()).eq('user_id', userId);
  }

  /// Uploads image bytes or file to Storage and returns a URL (signed when preferred).
  Future<String> uploadProfileImage({
    required String userId,
    required String filePath,
    List<int>? bytes,
  }) async {
    final filename = _basename(filePath);
    final ext = _extension(filename).replaceFirst('.', '').toLowerCase();
    final mime = mimeFromExtension(ext) ?? 'image/jpeg';
    final objectPath =
        'users/$userId/${DateTime.now().millisecondsSinceEpoch}-$filename';

    final storage = _db.storage.from(_profileBucket);

    // Robust cross‑platform upload:
    // - Web: must use bytes (File API not available).
    // - Mobile/desktop: prefer file path, but if bytes are provided use uploadBinary.
    if (kIsWeb) {
      if (bytes == null) {
        throw Exception('On web, provide bytes for upload.');
      }
      final asUint8 = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
      await storage.uploadBinary(
        objectPath,
        asUint8,
        fileOptions: FileOptions(contentType: mime, upsert: true),
      );
    } else {
      if (bytes != null) {
        final asUint8 = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
        await storage.uploadBinary(
          objectPath,
          asUint8,
          fileOptions: FileOptions(contentType: mime, upsert: true),
        );
      } else {
        final file = File(filePath);
        if (!await file.exists()) {
          // Explicit message helps diagnose PathNotFound on devices.
          throw Exception('File not found at path: $filePath');
        }
        await storage.upload(
          objectPath,
          file,
          fileOptions: FileOptions(contentType: mime, upsert: true),
        );
      }
    }

    // URL (signed works for both public/private buckets)
    if (_preferSignedUrls) {
      const oneWeekSeconds = 60 * 60 * 24 * 7;
      final signedUrl = await storage.createSignedUrl(objectPath, oneWeekSeconds);
      return signedUrl;
    } else {
      return storage.getPublicUrl(objectPath);
    }
  }

  Future<void> setProfilePictures({
    required String userId,
    required List<String> urls,
  }) async {
    await _db
        .from('profiles')
        .update({'profile_pictures': urls})
        .eq('user_id', userId);
  }

  Future<void> addProfilePicture({
    required String userId,
    required String url,
  }) async {
    final row = await fetchByUserId(userId);
    final current = ((row?['profile_pictures'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList();
    current.add(url);
    await setProfilePictures(userId: userId, urls: current);
  }
}

/// --- Tiny helpers (no package:path) ---
String _basename(String path) {
  final parts = path.split(RegExp(r'[\\/]'));
  return parts.isEmpty ? path : parts.last;
}

String _extension(String filename) {
  final i = filename.lastIndexOf('.');
  return i == -1 ? '' : filename.substring(i);
}
