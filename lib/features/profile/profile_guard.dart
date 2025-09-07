// FILE: lib/features/profile/profile_guard.dart
import 'dart:async';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/config/profile_schema.dart' as cfg;

/// Simple gate signal for routers.
enum ProfileStatus { unknown, incomplete, complete }

/// Exposes a ValueNotifier so GoRouter (or anything else) can listen for changes.
final profileStatusListenableProvider =
    Provider<ValueNotifier<ProfileStatus>>((ref) {
  final notifier = ValueNotifier<ProfileStatus>(ProfileStatus.unknown);
  final auth = Supabase.instance.client.auth;

  Future<void> refresh() async {
    final user = auth.currentUser;
    if (user == null) {
      notifier.value = ProfileStatus.unknown;
      return;
    }

    final s = cfg.defaultProfileSchema;

    // Build select list explicitly (no collection-if/else to keep older SDKs happy).
    final cols = <String>{};
    cols.add(s.idCol);                 // e.g. user_id
    cols.add(s.displayNameCol);        // e.g. name
    if (s.ageCol != null && s.ageCol!.isNotEmpty) {
      cols.add(s.ageCol!);             // explicit age column
    } else {
      cols.add('date_of_birth');       // fallback so we can compute age
    }
    if (s.avatarUrlCol != null && s.avatarUrlCol!.isNotEmpty) {
      cols.add(s.avatarUrlCol!);
    }
    if (s.photosCol != null && s.photosCol!.isNotEmpty) {
      cols.add(s.photosCol!);
    } else {
      cols.add('profile_pictures');
    }
    if (s.cityCol.isNotEmpty) {
      cols.add(s.cityCol);
    }
    final selectCols = cols.join(',');

    try {
      final row = await Supabase.instance.client
          .from(s.table) // usually 'profiles'
          .select(selectCols)
          .eq(s.idCol, user.id)
          .maybeSingle();

      if (row == null) {
        notifier.value = ProfileStatus.incomplete;
        return;
      }

      // ---- Map to minimal fields we need for the check ----
      final name = (row[s.displayNameCol] ?? row['name'] ?? '')
          .toString()
          .trim();

      // Age: prefer explicit age column, else compute from DOB if present.
      int age = 0;
      if (s.ageCol != null && row[s.ageCol] != null) {
        final a = row[s.ageCol];
        if (a is num) age = a.toInt();
        if (a is String) age = int.tryParse(a) ?? 0;
      } else {
        final dobRaw = row['date_of_birth'];
        DateTime? dob;
        if (dobRaw is DateTime) {
          dob = dobRaw;
        } else if (dobRaw is String && dobRaw.isNotEmpty) {
          dob = DateTime.tryParse(dobRaw);
        }
        if (dob != null) {
          final now = DateTime.now();
          age = now.year - dob.year -
              ((now.month < dob.month ||
                      (now.month == dob.month && now.day < dob.day))
                  ? 1
                  : 0);
        }
      }

      // Avatar / photos
      final avatar = (s.avatarUrlCol != null
              ? (row[s.avatarUrlCol] ?? '')
              : '')
          .toString()
          .trim();

      final photosDyn =
          (s.photosCol != null ? row[s.photosCol] : row['profile_pictures']);
      final photos = (photosDyn is List)
          ? photosDyn
              .map((e) => (e ?? '').toString())
              .where((e) => e.isNotEmpty)
              .toList()
          : const <String>[];

      final looksComplete =
          name.isNotEmpty && age >= 18 && (avatar.isNotEmpty || photos.isNotEmpty);

      notifier.value =
          looksComplete ? ProfileStatus.complete : ProfileStatus.incomplete;
    } catch (_) {
      // Be conservative on failure.
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
