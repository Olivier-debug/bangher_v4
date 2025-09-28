// Unified profile store (snake_case only) with strict List<String> normalization.

import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/cache/peer_profile_cache.dart';
import 'edit_profile_repository.dart';

/// Public facade your screens import.
final myProfileProvider =
    StateNotifierProvider<MyProfileNotifier, AsyncValue<Map<String, dynamic>?>>(
  (ref) => MyProfileNotifier(ref),
);

class MyProfileNotifier extends StateNotifier<AsyncValue<Map<String, dynamic>?>> {
  MyProfileNotifier(this.ref) : super(const AsyncLoading()) {
    _load();
  }

  final Ref ref;
  SupabaseClient get _sb => Supabase.instance.client;

  // ---------- public API ----------
  Future<void> refresh() => _load();

  /// Optimistic local update. Callers pass *snake_case* keys.
  void updateProfile(Map<String, dynamic> patch) {
    final current = state.value ?? <String, dynamic>{};
    final merged = {...current, ...patch};
    final normalized = _normalize(merged);
    state = AsyncData(normalized);
  }

  // ---------- internal ----------
  Future<void> _load() async {
    try {
      state = const AsyncLoading();

      final uid = _sb.auth.currentUser?.id;
      if (uid == null) {
        state = const AsyncData(null);
        return;
      }

      // 1) cache first (offline-first feel)
      final cached = await PeerProfileCache.instance.read(uid);
      if (cached != null) {
        state = AsyncData(_normalize(cached));
      }

      // 2) fresh from DB (SWR)
      final dynamic result =
          await _sb.from('profiles').select().eq('user_id', uid).limit(1);

      final rows = (result as List);
      if (rows.isNotEmpty) {
        final db = Map<String, dynamic>.from(rows.first as Map);
        final normalized = _normalize(db);
        await PeerProfileCache.instance.write(uid, normalized);
        state = AsyncData(normalized);
      } else {
        final shell = <String, dynamic>{'user_id': uid};
        state = AsyncData(_normalize(shell));
      }
    } catch (e, st) {
      // Your Riverpod version doesn’t support AsyncError(previous: ...).
      // If we already have data, keep it; otherwise surface the error.
      if (!state.hasValue) {
        state = AsyncError(e, st);
      }
    }
  }

  // Ensure the shape our widgets expect: strings and List<String>, snake_case only.
  Map<String, dynamic> _normalize(Map<String, dynamic> src) {
    String? s(dynamic v) {
      final t = v?.toString();
      if (t == null) return null;
      final trimmed = t.trim();
      return trimmed.isEmpty ? null : trimmed;
    }

    List<String> listStr(dynamic v) {
      if (v is List) {
        return v
            .map((e) => e?.toString() ?? '')
            .where((t) => t.trim().isNotEmpty)
            .cast<String>()
            .toList(growable: false);
      }
      return const <String>[];
    }

    int? i(dynamic v) => switch (v) { int x => x, num x => x.toInt(), _ => null };

    final out = <String, dynamic>{};

    // strings
    for (final k in const [
      'user_id',
      'name',
      'gender',
      'current_city',
      'bio',
      'love_language',
      'communication_style',
      'education',
      'family_plans',
      'date_of_birth',
      'drinking',
      'smoking',
      'pets',
      'sexual_orientation',
      'zodiac_sign',
      'workout',
      'dietary_preference',
      'sleeping_habits',
      'social_media',
      'personality_type',
    ]) {
      out[k] = s(src[k]);
    }

    // numbers
    out['age'] = i(src['age']);
    out['height_cm'] = i(src['height_cm']);

    // arrays → List<String>
    out['profile_pictures'] = listStr(src['profile_pictures']);
    out['interests'] = listStr(src['interests']);
    out['relationship_goals'] = listStr(src['relationship_goals']);
    out['my_languages'] = listStr(src['my_languages']);

    // location
    final loc = src['location2'];
    if (loc is List && loc.length == 2) {
      final lat = (loc[0] as num?)?.toDouble();
      final lng = (loc[1] as num?)?.toDouble();
      if (lat != null && lng != null) out['location2'] = <num>[lat, lng];
    }

    // Drop nulls for cleaner state
    out.removeWhere((_, v) => v == null);
    return out;
  }
}

/// Repository used by edit page and photo outbox.
final editProfileRepositoryProvider = Provider<EditProfileRepository>((ref) {
  return EditProfileRepository(Supabase.instance.client);
});
