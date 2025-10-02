// FILE: lib/features/profile/data/preferences_store.dart
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
    final up = g.trim().toUpperCase();
    const allowed = {'M', 'F', 'A'};
    state = state.copyWith(gender: allowed.contains(up) ? up : state.gender);
  }

  void setAgeRange(int min, int max) {
    // clamp and ensure min <= max and >= 18
    final lo = min.clamp(18, 100);
    final hi = max.clamp(18, 100);
    int a = lo.toInt();
    int b = hi.toInt();
    if (a > b) {
      final t = a;
      a = b;
      b = t;
    }
    state = state.copyWith(ageMin: a, ageMax: b);
  }

  void setDistance(int km) {
    // simple sanity clamp; ensure int
    final vNum = km.clamp(1, 500);
    final v = vNum.toInt();
    state = state.copyWith(maxDistanceKm: v);
  }

  void reset() => state = const MyPreferencesState();
}

/// Renamed to avoid confusion with the DB-backed `myPreferencesProvider`.
final myPreferencesUiStoreProvider =
    AutoDisposeNotifierProvider<MyPreferencesStore, MyPreferencesState>(
  MyPreferencesStore.new,
);
