// FILE: lib/features/matches/match_repository.dart
//
// Provides:
//   - likeUser(...)          : registers a like via `swipes`; if reciprocal (trigger made a row), returns lite profiles
//   - getOrFetchMatchId(...) : resolves the canonical match row id for a pair (sorted user1_id/user2_id)
//   - watchMyMatches(...)    : realtime stream of my matches with counterpart lite profile
//
// Schema used (this file now matches your posted schema):
//   swipes(id, created_at, swiper_id uuid, swipee_id uuid, liked bool, status text)
//   matches(id bigint, user1_id uuid, user2_id uuid, user_ids uuid[], created_at, is_deleted bool)
//   profiles(user_id uuid PK, name text, profile_pictures jsonb/text[])
//
// Notes:
// - `likeUser` relies on a DB trigger that upserts into `matches` when a reciprocal like exists.
// - If the trigger hasn't fired yet, `likeUser` will return isMatch=false; your Realtime listener will still catch it.

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final matchRepositoryProvider = Provider<MatchRepository>((ref) {
  return MatchRepository(Supabase.instance.client);
});

class MatchRepository {
  MatchRepository(this._sb);
  final SupabaseClient _sb;

  /// Register a "like" by inserting into `swipes`.
  /// If a match row already exists (or was just created by trigger), returns both lite profiles.
  Future<MatchResult> likeUser({
    required String fromUserId,
    required String toUserId,
  }) async {
    // Insert swipe (idempotent at app level; server has unique constraint)
    try {
      await _sb.from('swipes').insert({
        'swiper_id': fromUserId,
        'swipee_id': toUserId,
        'liked': true,
        'status': 'active',
        'created_at': DateTime.now().toIso8601String(),
      });
    } catch (_) {
      // Ignore unique_swipe_pair conflicts or network races.
    }

    // Check if a match exists (trigger-created) using sorted pair.
    final a = (fromUserId.compareTo(toUserId) <= 0) ? fromUserId : toUserId;
    final b = (fromUserId.compareTo(toUserId) <= 0) ? toUserId : fromUserId;

    final matchRows = await _sb
        .from('matches')
        .select('id,is_deleted')
        .eq('user1_id', a)
        .eq('user2_id', b)
        .limit(1);

    if (matchRows.isEmpty) {
      return const MatchResult(isMatch: false);
    }
    final row = matchRows.first;
    if (row['is_deleted'] == true) {
      return const MatchResult(isMatch: false);
    }

    final matchId = row['id'].toString();
    final me = await _getProfileLite(fromUserId);
    final other = await _getProfileLite(toUserId);

    return MatchResult(isMatch: true, matchId: matchId, me: me, other: other);
  }

  /// Resolve the canonical `matches.id` for two users; returns null if not present.
  Future<String?> getOrFetchMatchId(String u1, String u2) async {
    final a = (u1.compareTo(u2) <= 0) ? u1 : u2;
    final b = (u1.compareTo(u2) <= 0) ? u2 : u1;
    final rows = await _sb
        .from('matches')
        .select('id,is_deleted')
        .eq('user1_id', a)
        .eq('user2_id', b)
        .limit(1);
    if (rows.isEmpty) return null;
    if (rows.first['is_deleted'] == true) return null;
    return rows.first['id']?.toString();
  }

  /// Live stream of my matches with counterpart light profile.
  /// Uses two column filters (user1_id,user2_id) for Realtime compatibility.
  Stream<List<MatchThread>> watchMyMatches(String myId) {
    final ctl = StreamController<List<MatchThread>>();

    Future<List<MatchThread>> fetch() async {
      final ms = await _sb
          .from('matches')
          .select('id,user1_id,user2_id,created_at,is_deleted')
          .or('user1_id.eq.$myId,user2_id.eq.$myId')
          .order('created_at', ascending: false);

      if (ms.isEmpty) return const <MatchThread>[];

      // Filter out soft-deleted matches client-side if present.
      final filtered = ms.where((m) => m['is_deleted'] != true).toList();
      if (filtered.isEmpty) return const <MatchThread>[];

      final otherIds = <String>{
        for (final r in filtered)
          (r['user1_id'].toString() == myId ? r['user2_id'] : r['user1_id'])
              .toString(),
      }.toList();

      final profRows = otherIds.isEmpty
          ? <Map<String, dynamic>>[]
          : await _sb
              .from('profiles')
              .select('user_id,name,profile_pictures')
              .inFilter('user_id', otherIds);

      final byId = {for (final p in profRows) (p['user_id']).toString(): p};

      return filtered.map<MatchThread>((r) {
        final otherId = (r['user1_id'].toString() == myId)
            ? r['user2_id'].toString()
            : r['user1_id'].toString();
        final row = byId[otherId];

        final other = row == null
            ? null
            : ProfileLite(
                id: (row['user_id']).toString(),
                name: _safeName(row['name']),
                photoUrl: _firstPic(row['profile_pictures']),
              );

        final createdAt =
            DateTime.tryParse(r['created_at']?.toString() ?? '') ??
                DateTime.fromMillisecondsSinceEpoch(0);

        return MatchThread(
          matchId: r['id']?.toString(),
          meId: myId,
          other: other,
          createdAt: createdAt,
        );
      }).toList();
    }

    // Initial emit
    fetch().then(ctl.add).catchError(ctl.addError);

    // Realtime: subscribe to inserts/deletes where you appear in either column.
    final ch = _sb.channel('public:matches_$myId');

    void refreshChanges(PostgresChangePayload _) async {
      try {
        ctl.add(await fetch());
      } catch (e, st) {
        ctl.addError(e, st);
      }
    }

    ch.onPostgresChanges(
      event: PostgresChangeEvent.insert,
      schema: 'public',
      table: 'matches',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'user1_id',
        value: myId,
      ),
      callback: refreshChanges,
    );
    ch.onPostgresChanges(
      event: PostgresChangeEvent.insert,
      schema: 'public',
      table: 'matches',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'user2_id',
        value: myId,
      ),
      callback: refreshChanges,
    );
    ch.onPostgresChanges(
      event: PostgresChangeEvent.delete,
      schema: 'public',
      table: 'matches',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'user1_id',
        value: myId,
      ),
      callback: refreshChanges,
    );
    ch.onPostgresChanges(
      event: PostgresChangeEvent.delete,
      schema: 'public',
      table: 'matches',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'user2_id',
        value: myId,
      ),
      callback: refreshChanges,
    );

    // Optional: also refresh on UPDATE to catch is_deleted flips.
    ch.onPostgresChanges(
      event: PostgresChangeEvent.update,
      schema: 'public',
      table: 'matches',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'user1_id',
        value: myId,
      ),
      callback: refreshChanges,
    );
    ch.onPostgresChanges(
      event: PostgresChangeEvent.update,
      schema: 'public',
      table: 'matches',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'user2_id',
        value: myId,
      ),
      callback: refreshChanges,
    );

    ch.subscribe();

    ctl.onCancel = () async {
      try {
        await _sb.removeChannel(ch);
      } catch (_) {}
      await ctl.close();
    };

    return ctl.stream;
  }

  // --- helpers ---------------------------------------------------------------

  Future<ProfileLite> _getProfileLite(String userId) async {
    final rows = await _sb
        .from('profiles')
        .select('user_id,name,profile_pictures')
        .eq('user_id', userId)
        .limit(1);

    if (rows.isEmpty) {
      return ProfileLite(id: userId, name: 'Unknown', photoUrl: null);
    }

    final r = rows.first;
    return ProfileLite(
      id: (r['user_id']).toString(),
      name: _safeName(r['name']),
      photoUrl: _firstPic(r['profile_pictures']),
    );
  }

  String _safeName(dynamic raw) {
    final s = (raw as String?) ?? '';
    return s.trim().isEmpty ? 'User' : s;
  }

  /// Accepts `text[]` or `jsonb` (list of strings).
  String? _firstPic(dynamic raw) {
    if (raw is List && raw.isNotEmpty) {
      final first = raw.first;
      if (first is String && first.trim().isNotEmpty) return first;
    }
    return null;
  }
}

// --- models ------------------------------------------------------------------

@immutable
class ProfileLite {
  final String id;
  final String name;
  final String? photoUrl;
  const ProfileLite({required this.id, required this.name, required this.photoUrl});
}

@immutable
class MatchResult {
  final bool isMatch;
  final String? matchId;
  final ProfileLite? me;
  final ProfileLite? other;

  const MatchResult({
    required this.isMatch,
    this.matchId,
    this.me,
    this.other,
  });
}

@immutable
class MatchThread {
  final String? matchId;
  final String meId;
  final ProfileLite? other;
  final DateTime createdAt;

  const MatchThread({
    required this.matchId,
    required this.meId,
    required this.other,
    required this.createdAt,
  });
}
