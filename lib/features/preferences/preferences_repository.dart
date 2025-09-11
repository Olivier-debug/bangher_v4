// FILE: lib/features/preferences/preferences_repository.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final preferencesRepositoryProvider = Provider<PreferencesRepository>((ref) {
  return PreferencesRepository(Supabase.instance.client);
});

class UserPreferences {
  final String gender;       // e.g., 'F' | 'M' | 'A'
  final int ageMin;
  final int ageMax;
  final double radiusKm;

  const UserPreferences({
    required this.gender,
    required this.ageMin,
    required this.ageMax,
    required this.radiusKm,
  });

  factory UserPreferences.fromMap(Map<String, dynamic> m) => UserPreferences(
        gender: (m['interested_in_gender'] ?? 'F') as String,
        ageMin: (m['age_min'] ?? 18) as int,
        ageMax: (m['age_max'] ?? 60) as int,
        radiusKm: ((m['distance_radius'] ?? 50) as num).toDouble(),
      );

  Map<String, dynamic> toMap(String userId) => {
        'user_id': userId,
        'interested_in_gender': gender,
        'age_min': ageMin,
        'age_max': ageMax,
        'distance_radius': radiusKm,
      };
}

class PreferencesRepository {
  PreferencesRepository(this._db);
  final SupabaseClient _db;

  Future<UserPreferences?> fetch(String userId) async {
    final row = await _db
        .from('preferences')
        .select('interested_in_gender, age_min, age_max, distance_radius')
        .eq('user_id', userId)
        .maybeSingle();
    if (row == null) return null;
    return UserPreferences.fromMap(row);
  }

  Future<void> upsert(String userId, UserPreferences prefs) async {
    await _db.from('preferences').upsert(
          prefs.toMap(userId),
          onConflict: 'user_id',
        );
  }
}
