// -----------------------------------------------------------------------------
// file: lib/features/profile/services/profile_guard.dart
// Simple profile completion gate + avatar prewarm when complete.
// -----------------------------------------------------------------------------

import 'dart:async'; // scheduleMicrotask, unawaited
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/config/profile_schema.dart' as cfg;
import '../../../core/images/peer_avatar_resolver.dart'; // <— prewarm avatar

/// Simple gate signal for routers.
enum ProfileStatus { unknown, incomplete, complete }

/// Exposes a ValueNotifier so GoRouter (or anything else) can listen for changes.
///
/// IMPORTANT: Mirrors the old flow:
/// - If `profiles.complete == true`  -> ProfileStatus.complete
/// - Else (false/null/missing/error) -> ProfileStatus.incomplete
final profileStatusListenableProvider =
    Provider<ValueNotifier<ProfileStatus>>((ref) {
  final notifier = ValueNotifier<ProfileStatus>(ProfileStatus.unknown);
  final auth = Supabase.instance.client.auth;

  Future<void> prewarmAvatar(String? userId) async {
    if (userId == null || userId.isEmpty) return;
    // Seed/refresh the user's avatar URL into PeerProfileCache in the background.
    unawaited(PeerAvatarResolver.instance.getAvatarUrl(userId));
  }

  Future<void> refresh() async {
    final user = auth.currentUser;
    if (user == null) {
      notifier.value = ProfileStatus.unknown;
      return;
    }

    // Prefer the explicit boolean column `complete` on profiles.
    try {
      final row = await Supabase.instance.client
          .from('profiles')
          .select('complete')
          .eq('user_id', user.id)
          .maybeSingle();

      final bool isComplete = (row?['complete'] as bool?) ?? false;

      if (row != null && row.containsKey('complete')) {
        notifier.value =
            isComplete ? ProfileStatus.complete : ProfileStatus.incomplete;

        if (isComplete) {
          // Prewarm only when we become/are complete.
          prewarmAvatar(user.id);
        }
        return;
      }
      // If row exists but doesn't contain 'complete', fall through to heuristic.
      // If row is null, also fall through.
    } catch (_) {
      // Ignore and fall through to heuristic to be robust.
    }

    // ---- Fallback heuristic (only used if `complete` is missing or query failed) ----
    try {
      final s = cfg.defaultProfileSchema;

      // Minimal select to determine “looks complete”
      final cols = <String>{
        s.idCol,                 // e.g. user_id
        s.displayNameCol,        // e.g. name
        'date_of_birth',
        'profile_pictures',
      };
      final selectCols = cols.join(',');

      final row = await Supabase.instance.client
          .from(s.table) // usually 'profiles'
          .select(selectCols)
          .eq(s.idCol, user.id)
          .maybeSingle();

      if (row == null) {
        notifier.value = ProfileStatus.incomplete;
        return;
      }

      final name =
          (row[s.displayNameCol] ?? row['name'] ?? '').toString().trim();

      // Compute age from DOB if present
      int age = 0;
      final dobRaw = row['date_of_birth'];
      DateTime? dob;
      if (dobRaw is DateTime) {
        dob = dobRaw;
      } else if (dobRaw is String && dobRaw.isNotEmpty) {
        dob = DateTime.tryParse(dobRaw);
      }
      if (dob != null) {
        final now = DateTime.now();
        age = now.year -
            dob.year -
            ((now.month < dob.month ||
                    (now.month == dob.month && now.day < dob.day))
                ? 1
                : 0);
      }

      // Photos
      final photosDyn = row['profile_pictures'];
      final photos = (photosDyn is List)
          ? photosDyn
              .map((e) => (e ?? '').toString())
              .where((e) => e.isNotEmpty)
              .toList()
          : const <String>[];

      final looksComplete = name.isNotEmpty && age >= 18 && photos.isNotEmpty;

      notifier.value =
          looksComplete ? ProfileStatus.complete : ProfileStatus.incomplete;

      if (looksComplete) {
        prewarmAvatar(user.id);
      }
    } catch (_) {
      // Be conservative on failure: incomplete -> route to Create/Complete.
      notifier.value = ProfileStatus.incomplete;
    }
  }

  // React to auth changes and do an initial check.
  final sub = auth.onAuthStateChange.listen((_) => refresh());
  scheduleMicrotask(refresh);

  ref.onDispose(() async {
    await sub.cancel();
    notifier.dispose();
  });

  return notifier;
});

/// Simple convenience provider for the current status value.
final profileStatusProvider = Provider<ProfileStatus>((ref) {
  return ref.watch(profileStatusListenableProvider).value;
});
