// FILE: lib/features/preferences/preferences_repository.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final preferencesRepositoryProvider = Provider<PreferencesRepository>((ref) {
  return PreferencesRepository(Supabase.instance.client);
});

/// UI-facing preferences model
/// gender: 'M' | 'F' | 'A' (A = All)
class UserPreferences {
  final String gender; // UI values: 'M','F','A'
  final int ageMin;
  final int ageMax;
  final int distanceKm;

  const UserPreferences({
    required this.gender,
    required this.ageMin,
    required this.ageMax,
    required this.distanceKm,
  });

  /// Map DB value -> UI value
  /// DB uses: 'M' | 'F' | 'O' (O = both)
  static String _dbToUiGender(String? g) {
    final u = (g ?? '').trim().toUpperCase();
    if (u == 'M' || u == 'F') return u;
    return 'A'; // all/both
    }

  /// Map UI value -> DB value
  /// UI 'A' becomes DB 'O'
  static String _uiToDbGender(String g) {
    final u = g.trim().toUpperCase();
    if (u == 'M' || u == 'F') return u;
    return 'O';
  }

  factory UserPreferences.fromMap(Map<String, dynamic> m) => UserPreferences(
        gender: _dbToUiGender(m['interested_in_gender'] as String?),
        ageMin: (m['age_min'] as int?) ?? 18,
        ageMax: (m['age_max'] as int?) ?? 60,
        distanceKm: (m['distance_radius'] as int?) ?? 50,
      );

  /// Serialize to DB map (with DB gender)
  Map<String, dynamic> toDbMap(String userId) => {
        'user_id': userId,
        'interested_in_gender': _uiToDbGender(gender),
        'age_min': ageMin,
        'age_max': ageMax,
        'distance_radius': distanceKm,
      };

  UserPreferences copyWith({
    String? gender,
    int? ageMin,
    int? ageMax,
    int? distanceKm,
  }) {
    return UserPreferences(
      gender: gender ?? this.gender,
      ageMin: ageMin ?? this.ageMin,
      ageMax: ageMax ?? this.ageMax,
      distanceKm: distanceKm ?? this.distanceKm,
    );
  }
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
          prefs.toDbMap(userId),
          onConflict: 'user_id',
        );
  }

  /// Optional helper for small patches without reading first.
  Future<void> update(String userId, UserPreferences prefs) async {
    await _db
        .from('preferences')
        .update(prefs.toDbMap(userId))
        .eq('user_id', userId);
  }
}
