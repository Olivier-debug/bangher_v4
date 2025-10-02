// FILE: lib/features/matches/data/match_seen_store.dart
// RPC-first seen tracking with tiny retry and a compile-time flag to disable SELECT fallback.

import 'dart:async';
import 'dart:math' as math;
import 'package:supabase_flutter/supabase_flutter.dart';

class MatchSeenConfig {
  // Compile-time flags (set via --dart-define)
  static const bool rpcOnly = bool.fromEnvironment('SEEN_RPC_ONLY', defaultValue: false);
  static const int rpcRetry = int.fromEnvironment('SEEN_RPC_RETRY', defaultValue: 2);
  static const int backoffMs = int.fromEnvironment('SEEN_RPC_BACKOFF_MS', defaultValue: 180);
}

class MatchSeenStore {
  MatchSeenStore._();
  static final MatchSeenStore instance = MatchSeenStore._();

  final Set<String> _seenMatchIds = <String>{};
  final math.Random _rng = math.Random();

  Future<T> _retry<T>(
    Future<T> Function() task, {
    int? attempts,
    Duration? baseDelay,
  }) async {
    final tries = (attempts ?? MatchSeenConfig.rpcRetry).clamp(1, 5);
    final delay = baseDelay ?? Duration(milliseconds: MatchSeenConfig.backoffMs);
    Object? lastErr;
    for (int i = 0; i < tries; i++) {
      try {
        return await task();
      } catch (e) {
        lastErr = e;
        if (i == tries - 1) break;
        // FIX: Duration cannot be multiplied by double → compute ms manually.
        final jitter = 1.0 + (_rng.nextDouble() * 0.4 - 0.2); // ±20%
        final ms = (delay.inMilliseconds * jitter).round().clamp(1, 5000);
        await Future.delayed(Duration(milliseconds: ms));
      }
    }
    // ignore: only_throw_errors
    throw lastErr ?? StateError('retry failed');
  }

  Future<bool> isSeen(String matchId, {String? meId}) async {
    if (matchId.isEmpty) return false;
    if (_seenMatchIds.contains(matchId)) return true;

    final client = Supabase.instance.client;
    final uid = meId ?? client.auth.currentUser?.id;
    if (uid == null) return false;

    final intId = int.tryParse(matchId);
    if (intId == null) return false;

    // RPC-first path
    try {
      final bool seen = await _retry<bool>(() async {
        final res = await client.rpc('is_match_seen', params: {'match_id_arg': intId});
        return (res as bool?) ?? false;
      });
      if (seen) _seenMatchIds.add(matchId);
      return seen;
    } catch (_) {
      if (MatchSeenConfig.rpcOnly) return false;
    }

    // Fallback SELECT path (disabled when rpcOnly == true)
    try {
      final row = await client
          .from('matches')
          .select('user1_id,user2_id,seen1,seen2')
          .eq('id', intId)
          .maybeSingle();

      if (row == null) return false;

      final String? u1 = row['user1_id'] as String?;
      final String? u2 = row['user2_id'] as String?;
      final bool s1 = (row['seen1'] as bool?) ?? false;
      final bool s2 = (row['seen2'] as bool?) ?? false;

      final bool seenForMe = (uid == u1 && s1) || (uid == u2 && s2);
      if (seenForMe) _seenMatchIds.add(matchId);
      return seenForMe;
    } catch (_) {
      return false;
    }
  }

  Future<void> markSeen(String matchId, {String? meId}) async {
    if (matchId.isEmpty) return;

    final client = Supabase.instance.client;
    final intId = int.tryParse(matchId);
    if (intId == null) return;

    // Preferred: single-update RPC with retry
    try {
      await _retry(() => client.rpc('mark_match_seen', params: {'match_id_arg': intId}));
      _seenMatchIds.add(matchId);
      return;
    } catch (_) {
      // Fall through if RPC not available
    }

    // Fallback: two guarded updates (PostgREST cannot express CASE in payload)
    final uid = meId ?? client.auth.currentUser?.id;
    if (uid == null) return;

    try {
      await client
          .from('matches')
          .update({'seen1': true})
          .match({'id': intId, 'user1_id': uid, 'seen1': false});
    } catch (_) {/* ignore */}
    try {
      await client
          .from('matches')
          .update({'seen2': true})
          .match({'id': intId, 'user2_id': uid, 'seen2': false});
    } catch (_) {/* ignore */}

    _seenMatchIds.add(matchId);
  }

  void resetSession() => _seenMatchIds.clear();
}

/*
Build flags examples:

# Force RPC-only (no SELECT fallback) with slightly longer backoff and 3 retries
flutter run \
  --dart-define=SEEN_RPC_ONLY=true \
  --dart-define=SEEN_RPC_RETRY=3 \
  --dart-define=SEEN_RPC_BACKOFF_MS=220
*/

