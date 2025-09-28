// FILE: lib/features/profile/preferences_store.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

class MyPreferencesState {
  final String gender; // 'M','F','A' etc. (A = All)
  final int ageMin;
  final int ageMax;
  final int maxDistanceKm;

  const MyPreferencesState({
    this.gender = 'A',
    this.ageMin = 18,
    this.ageMax = 99,
    this.maxDistanceKm = 100,
  });

  MyPreferencesState copyWith({
    String? gender,
    int? ageMin,
    int? ageMax,
    int? maxDistanceKm,
  }) {
    return MyPreferencesState(
      gender: gender ?? this.gender,
      ageMin: ageMin ?? this.ageMin,
      ageMax: ageMax ?? this.ageMax,
      maxDistanceKm: maxDistanceKm ?? this.maxDistanceKm,
    );
  }

  bool get isAnyFilterActive =>
      gender != 'A' || ageMin != 18 || ageMax != 99 || maxDistanceKm != 100;
}

/// UI-only store (no network). Useful for ephemeral filter state.
/// If you already use a DB-backed preferences provider for persistence,
/// keep this for on-screen filters, or remove it to avoid duplication.
class MyPreferencesStore extends AutoDisposeNotifier<MyPreferencesState> {
  @override
  MyPreferencesState build() => const MyPreferencesState();

  void setGender(String g) {
    // accept only expected values to keep UI consistent
    final up = (g.trim().toUpperCase());
    final allowed = {'M', 'F', 'A'};
    state = state.copyWith(gender: allowed.contains(up) ? up : state.gender);
  }

  void setAgeRange(int min, int max) {
    // clamp and ensure min <= max and >= 18
    int lo = min.clamp(18, 100);
    int hi = max.clamp(18, 100);
    if (lo > hi) {
      final t = lo;
      lo = hi;
      hi = t;
    }
    state = state.copyWith(ageMin: lo, ageMax: hi);
  }

  void setDistance(int km) {
    // simple sanity clamp
    final v = km.clamp(1, 500);
    state = state.copyWith(maxDistanceKm: v);
  }

  void reset() => state = const MyPreferencesState();
}

/// Renamed to avoid confusion with the DB-backed `myPreferencesProvider`.
final myPreferencesUiStoreProvider =
    AutoDisposeNotifierProvider<MyPreferencesStore, MyPreferencesState>(
  MyPreferencesStore.new,
);
