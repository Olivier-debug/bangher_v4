// ─────────────────────────────────────────────────────────────────────────────
// lib/features/swipe/presentation/swipe_models.dart
// Core models + constants used across swipe feature.
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:async' show TimeoutException;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color;
import 'package:supabase_flutter/supabase_flutter.dart';

const double kDefaultAlpha = 0.12;
const String kProfileBucket = 'profile_pictures';
const Color kBrandPink = Color(0xFFFF0F7B);

final Uint8List transparentPixel = Uint8List.fromList(<int>[
  137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,0,0,0,1,0,0,0,1,8,6,0,0,0,31,21,196,137,
  0,0,0,1,115,82,71,66,0,174,206,28,233,0,0,0,10,73,68,65,84,8,153,99,0,1,0,0,5,0,1,13,
  10,44,170,0,0,0,0,73,69,78,68,174,66,96,130
]);

@immutable
class SwipeCard {
  final String id;
  final String name;
  final int? age;
  final String? bio;

  /// Resolved URLs (signed or public) used by the UI.
  final List<String> photos;

  /// Original DB values (e.g., "profile_pictures/users/.../file.png").
  /// Kept so we can re-sign a single photo when its token expires.
  final List<String>? rawPhotos;

  final bool isOnline;
  final DateTime? lastSeen;
  final String? distance;
  final List<String> interests;

  const SwipeCard({
    required this.id,
    required this.name,
    this.age,
    this.bio,
    required this.photos,
    this.rawPhotos,
    required this.isOnline,
    this.lastSeen,
    this.distance,
    required this.interests,
  });

  factory SwipeCard.fromJson(Map<String, dynamic> m) {
    List<String> listOfString(dynamic v) =>
        (v as List? ?? const [])
            .map((e) => e?.toString() ?? '')
            .where((e) => e.isNotEmpty)
            .toList();
    DateTime? toDt(dynamic v) {
      final s = v?.toString();
      if (s == null || s.isEmpty) return null;
      return DateTime.tryParse(s);
    }

    final raws = listOfString(m['photos'] ?? m['profile_pictures']);

    return SwipeCard(
      id: (m['potential_match_id'] ?? m['user_id'] ?? '').toString(),
      name: (m['name'] ?? 'User').toString(),
      age: m['age'] as int? ?? int.tryParse(m['age']?.toString() ?? ''),
      bio: (m['bio']?.toString().isNotEmpty ?? false) ? m['bio'].toString() : null,
      photos: raws,                 // start with raws; controller will resolve
      rawPhotos: raws,              // keep originals for future refresh
      isOnline: m['is_online'] == true,
      lastSeen: toDt(m['last_seen']),
      distance: (m['distance']?.toString().isNotEmpty ?? false) ? m['distance'].toString() : null,
      interests: listOfString(m['interests']),
    );
  }

  Map<String, dynamic> toCacheMap() => {
        'potential_match_id': id,
        'name': name,
        'age': age,
        'bio': bio,
        'photos': photos,
        'raw_photos': rawPhotos,
        'is_online': isOnline,
        'last_seen': lastSeen?.toIso8601String(),
        'distance': distance,
        'interests': interests,
      };

  SwipeCard copyWith({
    List<String>? photos,
    List<String>? rawPhotos,
  }) =>
      SwipeCard(
        id: id,
        name: name,
        age: age,
        bio: bio,
        photos: photos ?? this.photos,
        rawPhotos: rawPhotos ?? this.rawPhotos,
        isOnline: isOnline,
        lastSeen: lastSeen,
        distance: distance,
        interests: interests,
      );
}

@immutable
class MatchLite {
  final String id;
  final String name;
  final String? photoUrl;
  const MatchLite({required this.id, required this.name, this.photoUrl});

  factory MatchLite.fromJson(Map<String, dynamic> m) {
    final pics = (m['profile_pictures'] as List? ?? const [])
        .map((e) => e?.toString() ?? '')
        .where((e) => e.isNotEmpty)
        .toList();
    return MatchLite(
      id: (m['user_id'] ?? '').toString(),
      name: (m['name']?.toString().isNotEmpty ?? false) ? m['name'].toString() : 'User',
      photoUrl: pics.isNotEmpty ? pics.first : null,
    );
  }
}

@immutable
class Bootstrap {
  final String? myPhoto;
  final List<String>? myPhotos;
  final List<num>? myLoc2;
  final Map<String, dynamic> prefs;
  final List<String> swipedIds;
  final String? cursorB64;
  const Bootstrap({
    this.myPhoto,
    this.myPhotos,
    this.myLoc2,
    required this.prefs,
    required this.swipedIds,
    this.cursorB64,
  });

  factory Bootstrap.fromJson(Map<String, dynamic> m) {
    final prof = (m['profile'] as Map?) ?? {};
    final pics = (prof['profile_pictures'] as List? ?? const [])
        .map((e) => e?.toString() ?? '')
        .where((e) => e.isNotEmpty)
        .toList();
    return Bootstrap(
      myPhoto: pics.isNotEmpty ? pics.first : null,
      myPhotos: pics,
      myLoc2: (prof['location2'] as List?)?.cast<num>(),
      prefs: (m['prefs'] as Map?)?.cast<String, dynamic>() ?? const {},
      swipedIds: ((m['swiped_ids'] as List?) ?? const []).map((e) => e.toString()).toList(),
      cursorB64: (m['cursor'] as String?),
    );
  }
}

@immutable
class FeedPage {
  final List<SwipeCard> items;
  final bool exhausted;
  final String? nextCursorB64;
  const FeedPage({required this.items, required this.exhausted, this.nextCursorB64});

  factory FeedPage.fromJson(Map<String, dynamic> m) {
    final items = ((m['items'] as List?) ?? const [])
        .map((e) => SwipeCard.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
    return FeedPage(
      items: items,
      exhausted: m['exhausted'] == true,
      nextCursorB64: m['next_cursor'] as String?,
    );
  }
}

@immutable
class SwipeResult {
  final bool createdMatch;
  final MatchLite? me;
  final MatchLite? other;
  const SwipeResult({required this.createdMatch, this.me, this.other});

  factory SwipeResult.fromJson(Map<String, dynamic>? m) {
    if (m == null) return const SwipeResult(createdMatch: false);
    return SwipeResult(
      createdMatch: m['created_match'] == true,
      me: (m['me'] is Map) ? MatchLite.fromJson((m['me'] as Map).cast<String, dynamic>()) : null,
      other: (m['other'] is Map) ? MatchLite.fromJson((m['other'] as Map).cast<String, dynamic>()) : null,
    );
  }
}

typedef RetryPredicate = bool Function(Object error);

@immutable
class RetryPolicy {
  final int maxAttempts;
  final Duration baseDelay;
  final Duration maxDelay;
  final Duration attemptTimeout;
  final double jitterFactor;
  final RetryPredicate shouldRetry;
  const RetryPolicy({
    this.maxAttempts = 5,
    this.baseDelay = const Duration(milliseconds: 250),
    this.maxDelay = const Duration(seconds: 4),
    this.attemptTimeout = const Duration(seconds: 8),
    this.jitterFactor = 0.25,
    this.shouldRetry = RetryPolicy.defaultPredicate,
  }) : assert(jitterFactor >= 0 && jitterFactor <= 1);

  static bool defaultPredicate(Object e) {
    if (e is TimeoutException) return true;
    if (e is PostgrestException) {
      final msg = e.message.toLowerCase();
      if (msg.contains('timeout') || msg.contains('connection') || msg.contains('terminating connection')) return true;
      if (msg.contains('permission denied') || msg.contains('violates') || msg.contains('invalid')) return false;
      return true;
    }
    final s = e.toString().toLowerCase();
    if (s.contains('timeout') || s.contains('network') || s.contains('connection') ||
        s.contains('failed host lookup') || s.contains('temporarily unavailable') ||
        s.contains('503') || s.contains('502') || s.contains('gateway')) {
      return true;
    }
    return false;
  }
}

@immutable
class SwipeUiState {
  final bool fetching;
  final bool exhausted;
  final List<SwipeCard> cards;
  final String? myPhoto;

  const SwipeUiState({
    this.fetching = false,
    this.exhausted = false,
    this.cards = const [],
    this.myPhoto,
  });

  SwipeUiState copyWith({
    bool? fetching,
    bool? exhausted,
    List<SwipeCard>? cards,
    String? myPhoto,
  }) =>
      SwipeUiState(
        fetching: fetching ?? this.fetching,
        exhausted: exhausted ?? this.exhausted,
        cards: cards ?? this.cards,
        myPhoto: myPhoto ?? this.myPhoto,
      );
}
