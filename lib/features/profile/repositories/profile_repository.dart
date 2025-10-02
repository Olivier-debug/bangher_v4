// FILE: lib/features/profile/profile_repository.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// DI: repository provider (keep this)
final profileRepositoryProvider = Provider<ProfileRepository>((ref) {
  return ProfileRepository(Supabase.instance.client);
});

class ProfileRepository {
  ProfileRepository(this.client);
  final SupabaseClient client;

  Future<Map<String, dynamic>?> fetchProfileByUserId(String userId) async {
    final res = await client
        .from('profiles')
        .select()
        .eq('user_id', userId)
        .limit(1)
        .maybeSingle();
    return res;
  }

  Future<void> upsertProfileSnakeCase(Map<String, dynamic> patch) async {
    if (!patch.containsKey('user_id')) {
      throw ArgumentError('patch must include user_id');
    }
    await client.from('profiles').upsert(patch, onConflict: 'user_id');
  }

  Future<void> setProfilePictures({
    required String userId,
    required List<String> urls,
  }) async {
    await client
        .from('profiles')
        .update({'profile_pictures': urls})
        .eq('user_id', userId);
  }
}