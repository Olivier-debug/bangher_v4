// FILE: lib/features/matches/match_repository.dart
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

  /// Register a "like" and return a MatchResult.
  /// If it's a mutual like, ensures a match row exists and returns both user profiles.
  Future<MatchResult> likeUser({
    required String fromUserId,
    required String toUserId,
  }) async {
    // 1) Upsert like (safe if unique constraint exists on (user_id, target_user_id))
    await _sb.from('likes').upsert({
      'user_id': fromUserId,
      'target_user_id': toUserId,
      'created_at': DateTime.now().toIso8601String(),
    });

    // 2) Check reciprocity
    final reciprocal = await _sb
        .from('likes')
        .select('user_id')
        .eq('user_id', toUserId)
        .eq('target_user_id', fromUserId);

    final isMatch = reciprocal.isNotEmpty;
    if (!isMatch) {
      return MatchResult(isMatch: false);
    }

    // 3) Create or fetch existing match row (normalize ordering for uniqueness)
    final a = fromUserId.compareTo(toUserId) <= 0 ? fromUserId : toUserId;
    final b = fromUserId.compareTo(toUserId) <= 0 ? toUserId : fromUserId;

    final existing = await _sb
        .from('matches')
        .select('id')
        .eq('user1_id', a)
        .eq('user2_id', b);

    String matchId;
    if (existing.isNotEmpty) {
      matchId = (existing.first['id']).toString();
    } else {
      final inserted = await _sb.from('matches').insert({
        'user1_id': a,
        'user2_id': b,
        'created_at': DateTime.now().toIso8601String(),
      }).select('id');
      matchId = (inserted.first['id']).toString();
    }

    // 4) Fetch the two profiles (names + first picture)
    final me = await _getProfileLite(fromUserId);
    final other = await _getProfileLite(toUserId);

    return MatchResult(
      isMatch: true,
      matchId: matchId,
      me: me,
      other: other,
    );
  }

  Future<ProfileLite> _getProfileLite(String userId) async {
    final rows = await _sb
        .from('profiles')
        .select('user_id,name,profile_pictures')
        .eq('user_id', userId);

    if (rows.isEmpty) {
      return ProfileLite(id: userId, name: 'Unknown', photoUrl: null);
    }

    final r = rows.first;
    final pics = (r['profile_pictures'] as List?)?.cast<String>() ?? const <String>[];
    return ProfileLite(
      id: (r['user_id']).toString(),
      name: (r['name'] as String?)?.trim().isNotEmpty == true ? r['name'] as String : 'User',
      photoUrl: pics.isNotEmpty ? pics.first : null,
    );
  }
}

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
