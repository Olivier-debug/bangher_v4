// lib/features/swipe/pages/test_swipe_stack_page.dart
// =========================
// FIXED FILE: test_swipe_stack_page.dart
// =========================

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

// removed: import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:swipable_stack/swipable_stack.dart';

import '../../profile/pages/view_profile_page.dart';
import '../../matches/chat_list_page.dart';
import '../../swipe/data/swipe_feed_cache.dart';
import '../../../services/presence_service.dart';

const double _kDefaultAlpha = 0.12;
const bool kUseSignedUrls = true;
const String kProfileBucket = 'profile_pictures';
const Color _brandPink = Color(0xFFFF0F7B);

// 1×1 transparent PNG bytes; keep as `final` (constructor not const).
final Uint8List transparentPixel = Uint8List.fromList(<int>[
  137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,0,0,0,1,0,0,0,1,8,6,0,0,0,31,21,196,137,
  0,0,0,1,115,82,71,66,0,174,206,28,233,0,0,0,10,73,68,65,84,8,153,99,0,1,0,0,5,0,1,13,
  10,44,170,0,0,0,0,73,69,78,68,174,66,96,130
]);

// Custom cache manager with longer TTL for profiles
final customCacheManager = CacheManager(
  Config(
    'profileCacheKey',
    stalePeriod: const Duration(days: 7),
    maxNrOfCacheObjects: 500,
  ),
);

/// Single-level undo memory that survives page/tab switches.
class _UndoMemory {
  String? id;
  bool liked = false;
  DateTime? at;
  Map<String, dynamic>? card;

  bool get has => id != null;
  void set(String id, bool liked, Map<String, dynamic> snapshot) {
    this.id = id;
    this.liked = liked;
    at = DateTime.now();
    card = Map<String, dynamic>.from(snapshot);
  }

  void clear() {
    id = null;
    at = null;
    card = null;
  }
}

final _UndoMemory _undoMemory = _UndoMemory();

@immutable
class SwipeCard {
  final String id;
  final String name;
  final int? age;
  final String? bio;
  final List<String> photos;
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
    required this.isOnline,
    this.lastSeen,
    this.distance,
    required this.interests,
  });

  factory SwipeCard.fromJson(Map<String, dynamic> m) {
    List<String> listOfString(dynamic v) =>
        (v as List? ?? const []).map((e) => e?.toString() ?? '').where((e) => e.isNotEmpty).toList();

    DateTime? toDt(dynamic v) {
      final s = v?.toString();
      if (s == null || s.isEmpty) return null;
      return DateTime.tryParse(s);
    }

    return SwipeCard(
      id: (m['potential_match_id'] ?? m['user_id'] ?? '').toString(),
      name: (m['name'] ?? 'User').toString(),
      age: m['age'] is int ? m['age'] as int : int.tryParse(m['age'].toString()),
      bio: (m['bio']?.toString().isNotEmpty ?? false) ? m['bio'].toString() : null,
      photos: listOfString(m['photos'] ?? m['profile_pictures']),
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
        'is_online': isOnline,
        'last_seen': lastSeen?.toIso8601String(),
        'distance': distance,
        'interests': interests,
      };

  SwipeCard copyWith({List<String>? photos}) => SwipeCard(
        id: id,
        name: name,
        age: age,
        bio: bio,
        photos: photos ?? this.photos,
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
class FeedCursor {
  final bool isOnline;
  final DateTime? lastSeen;
  final String userId;
  const FeedCursor({required this.isOnline, this.lastSeen, required this.userId});
}

class CursorCodec {
  static String? encode(FeedCursor? c) {
    if (c == null) return null;
    final m = {
      'is_online': c.isOnline,
      'last_seen': c.lastSeen?.toIso8601String() ?? '',
      'user_id': c.userId,
    };
    final raw = jsonEncode(m);
    return base64Encode(utf8.encode(raw));
  }

  static FeedCursor? decode(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      final raw = utf8.decode(base64Decode(s));
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final lsStr = m['last_seen'] as String?;
      final ls = (lsStr == null || lsStr.isEmpty) ? null : DateTime.tryParse(lsStr);
      return FeedCursor(
        isOnline: m['is_online'] == true,
        lastSeen: ls,
        userId: (m['user_id'] ?? '').toString(),
      );
    } catch (_) {
      return null;
    }
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
    if (s.contains('timeout') ||
        s.contains('network') ||
        s.contains('connection') ||
        s.contains('failed host lookup') ||
        s.contains('temporarily unavailable') ||
        s.contains('503') ||
        s.contains('502') ||
        s.contains('gateway')) {
      return true;
    }
    return false;
  }
}

class _RetryRunner {
  final math.Random _rng = math.Random();
  Future<T> run<T>({
    required Future<T> Function() task,
    required RetryPolicy policy,
    String? opName,
  }) async {
    Object? lastErr;
    for (int attempt = 1; attempt <= policy.maxAttempts; attempt++) {
      try {
        final v = await task().timeout(policy.attemptTimeout);
        if (attempt > 1 && kDebugMode) debugPrint('[$opName] ok on attempt $attempt');
        return v;
      } catch (e, st) {
        lastErr = e;
        final canRetry = attempt < policy.maxAttempts && policy.shouldRetry(e);
        if (kDebugMode) debugPrint('[$opName] attempt $attempt failed: $e');
        if (!canRetry) {
          Error.throwWithStackTrace(e, st);
        }
        final baseMs = policy.baseDelay.inMilliseconds;
        final exp = baseMs * math.pow(2, attempt - 1).toDouble();
        final capped = math.min(exp, policy.maxDelay.inMilliseconds.toDouble());
        final jitter = 1.0 + (policy.jitterFactor * (_rng.nextDouble() * 2 - 1));
        final delayMs = (capped * jitter).clamp(0, policy.maxDelay.inMilliseconds.toDouble()).toInt();
        await Future.delayed(Duration(milliseconds: delayMs));
      }
    }
    throw lastErr ?? StateError('retry failed: $opName');
  }
}

class SwipeApi {
  final SupabaseClient _supa;
  final RetryPolicy _policy;
  final _RetryRunner _runner = _RetryRunner();
  SwipeApi(this._supa, {RetryPolicy? retryPolicy})
      : _policy = retryPolicy ?? const RetryPolicy();

  Future<Bootstrap> initBootstrap(String userId) async {
    return _runner.run(
      opName: 'init_bootstrap',
      policy: _policy,
      task: () async {
        final res = await _supa.rpc('init_swipe_bootstrap', params: {'user_id_arg': userId});
        final dynamic row = (res is List && res.isNotEmpty) ? res.first : res;
        return Bootstrap.fromJson((row as Map).cast<String, dynamic>());
      },
    );
  }

  Future<FeedPage> getFeed({
    required String userId,
    required Map<String, dynamic> prefs,
    String? afterCursorB64,
    int limit = 20,
  }) async {
    return _runner.run(
      opName: 'get_feed',
      policy: _policy,
      task: () async {
        final res = await _supa.rpc('get_feed', params: {
          'user_id_arg': userId,
          'prefs_arg': prefs,
          'after_arg': afterCursorB64,
          'limit_arg': limit,
        });
        final dynamic row = (res is List && res.isNotEmpty) ? res.first : res;
        return FeedPage.fromJson((row as Map).cast<String, dynamic>());
      },
    );
  }

  Future<SwipeResult> handleSwipeAtomic({
    required String swiperId,
    required String swipeeId,
    required bool liked,
  }) async {
    return _runner.run(
      opName: 'handle_swipe_atomic',
      policy: _policy,
      task: () async {
        final res = await _supa.rpc('handle_swipe_atomic', params: {
          'swiper_id_arg': swiperId,
          'swipee_id_arg': swipeeId,
          'liked_arg': liked,
        });
        final dynamic row = (res is List && res.isNotEmpty) ? res.first : res;
        return SwipeResult.fromJson((row as Map?)?.cast<String, dynamic>());
      },
    );
  }

  Future<void> undoSwipe({required String swiperId, required String swipeeId}) async {
    return _runner.run(
      opName: 'undo_swipe',
      policy: _policy,
      task: () => _supa.rpc('undo_swipe', params: {
        'swiper_id_arg': swiperId,
        'swipee_id_arg': swipeeId,
      }),
    );
  }

  Future<void> handleSwipeBatch({
    required String swiperId,
    required List<({String swipeeId, bool liked})> items,
  }) async {
    final payload = [
      for (final it in items) {'swipee_id': it.swipeeId, 'liked': it.liked}
    ];
    return _runner.run(
      opName: 'handle_swipe_batch',
      policy: _policy,
      task: () => _supa.rpc('handle_swipe_batch', params: {
        'swiper_id_arg': swiperId,
        'items_arg': payload,
      }),
    );
  }
}

class SingleFlight<T> {
  Future<T>? _inflight;
  Future<T> run(Future<T> Function() task) {
    if (_inflight != null) return _inflight!;
    final c = Completer<T>();
    _inflight = c.future;
    () async {
      try {
        final v = await task();
        c.complete(v);
      } catch (e, st) {
        c.completeError(e, st);
      } finally {
        _inflight = null;
      }
    }();
    return c.future;
  }
}

/// Repository keeps cursor/exhaustion and provides ergonomic calls.
class FeedRepository {
  final SwipeApi api;
  final SupabaseClient supa;
  String? _cursorB64;
  bool _exhausted = false;
  final _single = SingleFlight<int>();

  FeedRepository({required this.api, required this.supa});

  String? get cursorB64 => _cursorB64;
  bool get exhausted => _exhausted;

  void reset() {
    _cursorB64 = null;
    _exhausted = false;
  }

  Future<({Bootstrap boot, FeedPage first})> init({required Map<String, dynamic> fallbackPrefs}) async {
    final me = supa.auth.currentUser?.id;
    if (me == null) throw StateError('Not authenticated');

    final boot = await api.initBootstrap(me);
    final prefs = <String, dynamic>{
      'interested_in_gender': (boot.prefs['interested_in_gender']?.toString() == 'A')
          ? null
          : (boot.prefs['interested_in_gender'] ?? 'A'),
      'age_min': boot.prefs['age_min'] ?? fallbackPrefs['age_min'] ?? 18,
      'age_max': boot.prefs['age_max'] ?? fallbackPrefs['age_max'] ?? 80,
      'radius_km': (boot.prefs['distance_radius'] ?? fallbackPrefs['radius_km'] ?? 50),
    };

    final first = await api.getFeed(userId: me, prefs: prefs, afterCursorB64: boot.cursorB64, limit: 20);
    _cursorB64 = first.nextCursorB64;
    _exhausted = first.exhausted;
    return (boot: boot, first: first);
  }

  Future<int> topUp({
    required Map<String, dynamic> prefs,
    int limit = 20,
    required void Function(List<SwipeCard> items) onItems,
  }) {
    return _single.run(() async {
      if (_exhausted) return 0;
      final me = supa.auth.currentUser?.id;
      if (me == null) return 0;
      final page = await api.getFeed(
        userId: me,
        prefs: prefs,
        afterCursorB64: _cursorB64,
        limit: limit,
      );
      _cursorB64 = page.nextCursorB64;
      _exhausted = page.exhausted;
      onItems(page.items);
      return page.items.length;
    });
  }

  Future<SwipeResult> swipe({
    required String swipeeId,
    required bool liked,
  }) async {
    final me = supa.auth.currentUser?.id;
    if (me == null) throw StateError('Not authenticated');
    return api.handleSwipeAtomic(swiperId: me, swipeeId: swipeeId, liked: liked);
  }

  Future<void> undo({required String swipeeId}) async {
    final me = supa.auth.currentUser?.id;
    if (me == null) throw StateError('Not authenticated');
    await api.undoSwipe(swiperId: me, swipeeId: swipeeId);
  }

  Future<void> flushBatch(List<({String swipeeId, bool liked})> batch) async {
    final me = supa.auth.currentUser?.id;
    if (me == null || batch.isEmpty) return;
    await api.handleSwipeBatch(swiperId: me, items: batch);
  }
}

class TestSwipeStackPage extends ConsumerStatefulWidget {
  const TestSwipeStackPage({super.key});

  static const String routeName = 'SwipePage';
  static const String routePath = '/swipe';

  @override
  ConsumerState<TestSwipeStackPage> createState() => _TestSwipeStackPageState();
}

// Riverpod providers for reactive state (decoupled from widget)
final fetchingProvider = StateProvider<bool>((ref) => false);
final initializingProvider = StateProvider<bool>((ref) => true);
final onlineProvider = StateProvider<bool>((ref) => true);
final prefGenderProvider = StateProvider<String>((ref) => 'A');
final prefAgeMinProvider = StateProvider<int>((ref) => 18);
final prefAgeMaxProvider = StateProvider<int>((ref) => 60);
final prefRadiusKmProvider = StateProvider<double>((ref) => 50.0);

class _TestSwipeStackPageState extends ConsumerState<TestSwipeStackPage>
    with TickerProviderStateMixin {
  final SupabaseClient _supa = Supabase.instance.client;

  late final SwipeApi _api = SwipeApi(
    _supa,
    retryPolicy: const RetryPolicy(
      maxAttempts: 6,
      baseDelay: Duration(milliseconds: 200),
      maxDelay: Duration(seconds: 3),
      attemptTimeout: Duration(seconds: 8),
      jitterFactor: 0.30,
    ),
  );
  late final FeedRepository _repo = FeedRepository(api: _api, supa: _supa);

  // ─────────────────────────────── Constants
  static const int _initialBatch = 20;
  static const int _topUpBatch = 20;
  static const int _topUpThreshold = 5;

  // ─────────────────────────────── Services
  final SwipableStackController _stack = SwipableStackController();

  // ─────────────────────────────── Global cache
  final SwipeFeedCache _cache = SwipeFeedCache.instance;

  // Per-USER photo index (stable across list growth)
  final Map<String, int> _photoIndexById = <String, int>{};

  // Swipe bookkeeping
  final Set<String> _inFlight = <String>{};
  final Set<String> _handled = <String>{};
  final List<_SwipeEvent> _history = <_SwipeEvent>[];

  // NEW: defer removal until animation completes (index → id)
  final Map<int, String> _pendingIdByIndex = <int, String>{};

  // Presence
  final Set<String> _onlineUserIds = <String>{};

  // UI state (now in Riverpod)
  bool _wasOnline = true;

  // Connectivity
  StreamSubscription? _connSub;

  // bottom-bar measurement
  double? _lastCardW;
  double? _lastCardH;

  // Loader avatar (my first profile photo)
  String? _myPhoto;

  // Convenience
  List<SwipeCard> _cardsView = const [];

  void _refreshCardsView() {
    _cardsView = _cache.cards.map(SwipeCard.fromJson).toList(growable: false);
  }

  int _lastIndexNotified = -999;

  bool get _hasCurrentCard {
    final i = _stack.currentIndex;
    final has = i >= 0 && i < _cache.cards.length;
    return has;
  }

  int _cardsAfterCurrent() {
    final i = _stack.currentIndex < 0 ? 0 : _stack.currentIndex;
    final left = _cache.cards.length - i - 1;
    return left <= 0 ? 0 : left;
  }

  @override
  void initState() {
    super.initState();

    _stack.addListener(() {
      final i = _stack.currentIndex;
      if (i != _lastIndexNotified) {
        _lastIndexNotified = i;
        _cache.lastStackIndex = i;
        _warmTopCard();
        _updateFinishedState();
        setState(() {});
      }
    });

    _bootstrap();
  }

  @override
  void dispose() {
    _connSub?.cancel();
    _unbindPresence();
    _stack.dispose();
    super.dispose();
  }

  // =========================
  // ROBUST URL RESOLVER
  // =========================

  final Map<String, String> _photoCache = <String, String>{};

  bool _isHttpUrl(String s) => s.startsWith('http://') || s.startsWith('https://');

  String _trimLeadingSlash(String s) => s.startsWith('/') ? s.substring(1) : s;

  /// Returns a usable URL for any of these forms:
  ///  - full https URL (returned as-is)
  ///  - "bucket/path/to.jpg"  -> uses that bucket
  ///  - "path/to.jpg"         -> uses kProfileBucket
  Future<String> _resolvePhotoUrl(String raw) async {
    if (raw.isEmpty) return raw;
    if (_photoCache.containsKey(raw)) return _photoCache[raw]!;

    // Case 1: already a full URL (maybe already public/signed)
    if (_isHttpUrl(raw)) {
      _photoCache[raw] = raw;
      return raw;
    }

    // Normalize
    String s = _trimLeadingSlash(raw);

    // Case 2: looks like "bucket/path..."
    String bucket = kProfileBucket;
    String path = s;
    final firstSlash = s.indexOf('/');
    if (firstSlash > 0) {
      final possibleBucket = s.substring(0, firstSlash);
      final rest = s.substring(firstSlash + 1);
      // Heuristic: treat as bucket/path if bucket doesn't look like a file (has no dot) and rest is non-empty
      if (!possibleBucket.contains('.') && rest.isNotEmpty) {
        bucket = possibleBucket;
        path = rest;
      }
    }

    // Make URL (public or signed)
    try {
      String url;
      if (kUseSignedUrls) {
        // 55 minutes to comfortably cover a session
        url = await _supa.storage.from(bucket).createSignedUrl(path, 55 * 60);
      } else {
        url = _supa.storage.from(bucket).getPublicUrl(path);
      }
      _photoCache[raw] = url;
      if (kDebugMode) debugPrint('[photo] $raw → $bucket/$path → $url');
      return url;
    } catch (e) {
      if (kDebugMode) debugPrint('[photo] failed for $raw: $e');
      // Last resort: return as-is (lets CachedNetworkImage at least try)
      _photoCache[raw] = raw;
      return raw;
    }
  }

  Future<List<SwipeCard>> _resolvePhotosForCards(List<SwipeCard> inCards) async {
    final out = <SwipeCard>[];
    for (final c in inCards) {
      if (c.photos.isEmpty) { out.add(c); continue; }
      final resolved = <String>[];
      for (final p in c.photos) {
        if (p.isEmpty) continue;
        resolved.add(await _resolvePhotoUrl(p));
      }
      out.add(c.copyWith(photos: resolved));
    }
    return out;
  }

  Future<String?> _resolveMaybeUrl(String? u) async {
    if (u == null || u.isEmpty) return u;
    return _resolvePhotoUrl(u);
  }

  // ───────────────────────────── Bootstrap
  Future<void> _bootstrap() async {
    final ok = await _ensureConnectivity();
    ref.read(onlineProvider.notifier).state = ok;
    _wasOnline = ok;
    _listenConnectivity();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startPresence();
    });

    await _flushPendingOutbox();

    // Compute cache key early
    final me = _supa.auth.currentUser?.id;
    final key = (me == null)
        ? null
        : '$me|g=${ref.read(prefGenderProvider)}|a=${ref.read(prefAgeMinProvider)}-${ref.read(prefAgeMaxProvider)}|r=${ref.read(prefRadiusKmProvider)}';

    // If we have valid, keyed cards -> use them immediately and bail out
    if (key != null && _cache.isCurrentKey(key) && _cache.visibleCards.isNotEmpty) {
      _refreshCardsView();
      ref.read(initializingProvider.notifier).state = false;
      _warmTopCard();
      return;
    }

    // Otherwise do a real bootstrap (hydrate prefs + server cursor)
    final meId = _supa.auth.currentUser?.id;
    if (meId != null) {
      try {
        final boot = await _api.initBootstrap(meId);

        // Hydrate local prefs from server so UI + key match
        ref.read(prefGenderProvider.notifier).state = (boot.prefs['interested_in_gender']?.toString().isNotEmpty == true)
            ? boot.prefs['interested_in_gender'].toString()
            : 'A';
        ref.read(prefAgeMinProvider.notifier).state = (boot.prefs['age_min'] ?? ref.read(prefAgeMinProvider)) as int;
        ref.read(prefAgeMaxProvider.notifier).state = (boot.prefs['age_max'] ?? ref.read(prefAgeMaxProvider)) as int;
        ref.read(prefRadiusKmProvider.notifier).state = ((boot.prefs['distance_radius'] ?? ref.read(prefRadiusKmProvider)) as num).toDouble();

        _myPhoto = await _resolveMaybeUrl(boot.myPhoto);

        final newKey = '$meId|g=${ref.read(prefGenderProvider)}|a=${ref.read(prefAgeMinProvider)}-${ref.read(prefAgeMaxProvider)}|r=${ref.read(prefRadiusKmProvider)}';
        _cache.resetIfKeyChanged(newKey);

        _repo
          ..reset()
          .._cursorB64 = boot.cursorB64
          .._exhausted = false;

        _cache.swipedIds
          ..clear()
          ..addAll(boot.swipedIds);
      } catch (e) {
        if (kDebugMode) debugPrint('bootstrap load err: $e');
      }
    }

    await _flushPendingOutbox();

    if (_cache.cards.isEmpty) {
      ref.read(initializingProvider.notifier).state = true;
      await _loadBatch(wanted: _initialBatch);
      ref.read(initializingProvider.notifier).state = false;
    } else {
      ref.read(initializingProvider.notifier).state = false;
      _refreshCardsView();
      final afterCurrent = _cardsAfterCurrent();
      if (afterCurrent <= _topUpThreshold && !_cache.exhausted) {
        unawaited(_loadBatch(wanted: _topUpBatch));
      }
      _warmTopCard();
    }

    if (_undoMemory.has) {
      _history
        ..clear()
        ..add(_SwipeEvent(
          index: (_stack.currentIndex < 0) ? 0 : _stack.currentIndex,
          swipeeId: _undoMemory.id!,
          liked: _undoMemory.liked,
        ));
      _updateFinishedState();
      setState(() {});
    }
  }

  // ───────────────────────────── Connectivity
  void _listenConnectivity() {
    _connSub?.cancel();
    _connSub = Connectivity().onConnectivityChanged.listen(
      (dynamic event) async {
        final bool ok = (event is List<ConnectivityResult>)
            ? event.any((r) => r != ConnectivityResult.none)
            : (event is ConnectivityResult)
                ? event != ConnectivityResult.none
                : false;

        if (ok && !_wasOnline) {
          unawaited(_flushPendingOutbox());
        }
        _wasOnline = ok;
        ref.read(onlineProvider.notifier).state = ok;
      },
    );
  }

  Future<bool> _ensureConnectivity() async {
    try {
      final dynamic res = await Connectivity().checkConnectivity();
      if (res is List<ConnectivityResult>) {
        return res.any((r) => r != ConnectivityResult.none);
      } else if (res is ConnectivityResult) {
        return res != ConnectivityResult.none;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  // ───────────────────────────── Presence
  dynamic _presenceChannel;
  StreamSubscription? _presenceSub;

  void _startPresence() {
    final me = _supa.auth.currentUser?.id;
    if (me == null) return;

    try {
      final ch = PresenceService.instance.channel(); // custom type
      _presenceChannel = ch;

      try {
        final track = (ch as dynamic).track;
        if (track is Function) {
          unawaited(track({
            'user_id': me,
            'online_at': DateTime.now().toUtc().toIso8601String(),
          }));
        }
      } catch (_) {}

      Stream? stream;

      final svc = PresenceService.instance;
      final svcOnlineIdsStream = (svc as dynamic).onlineUserIdsStream;
      final svcPresenceStream  = (svc as dynamic).presenceStream;

      if (svcOnlineIdsStream is Stream) {
        stream = svcOnlineIdsStream;
      } else if (svcPresenceStream is Stream) {
        stream = svcPresenceStream;
      } else {
        final chOnlineIdsStream = (ch as dynamic).onlineUserIdsStream;
        final chPresenceStream  = (ch as dynamic).presenceStream;
        if (chOnlineIdsStream is Stream) {
          stream = chOnlineIdsStream;
        } else if (chPresenceStream is Stream) {
          stream = chPresenceStream;
        }
      }

      if (stream != null) {
        _presenceSub = stream.listen((dynamic payload) {
          final ids = <String>{};

          if (payload is Set) {
            for (final v in payload) {
              final s = v?.toString();
              if (s != null && s.isNotEmpty) ids.add(s);
            }
          } else if (payload is Iterable) {
            for (final v in payload) {
              final s = v?.toString();
              if (s != null && s.isNotEmpty) ids.add(s);
            }
          } else if (payload is Map) {
            for (final value in payload.values) {
              if (value is Iterable) {
                for (final pr in value) {
                  try {
                    final id = (pr as dynamic).payload?['user_id']?.toString();
                    if (id != null && id.isNotEmpty) ids.add(id);
                  } catch (_) {}
                }
              }
            }
          } else {
            try {
              final ps = (payload as dynamic).presences;
              if (ps is Iterable) {
                for (final pr in ps) {
                  final id = (pr as dynamic).payload?['user_id']?.toString();
                  if (id != null && id.isNotEmpty) ids.add(id);
                }
              }
            } catch (_) {}
          }

          if (!setEquals(_onlineUserIds, ids)) {
            _onlineUserIds
              ..clear()
              ..addAll(ids);
            setState(() {});
          }
        });
      }

      try {
        final subscribe = (ch as dynamic).subscribe;
        if (subscribe is Function) unawaited(subscribe());
      } catch (_) {}

      try {
        final nowIds = (PresenceService.instance as dynamic).currentOnlineUserIds;
        if (nowIds is Iterable) {
          final ids = nowIds.map((e) => e.toString()).where((s) => s.isNotEmpty).toSet();
          if (!setEquals(_onlineUserIds, ids)) {
            _onlineUserIds..clear()..addAll(ids);
            setState(() {});
          }
        }
      } catch (_) {}
    } catch (_) {
      // Ignore: presence is non-critical.
    }
  }

  void _unbindPresence() {
    try {
      _presenceSub?.cancel();
      _presenceSub = null;

      final ch = _presenceChannel;
      if (ch != null) {
        final unsubscribe = (ch as dynamic).unsubscribe;
        if (unsubscribe is Function) unsubscribe();
      }
    } catch (_) {}
    _presenceChannel = null;
  }

  // ───────────────────────────── Data Loading
  Future<int> _loadBatch({required int wanted}) async {
    if (ref.read(fetchingProvider)) return 0;
    ref.read(fetchingProvider.notifier).state = true;

    int added = 0;
    try {
      final prefs = <String, dynamic>{
        'interested_in_gender': ref.read(prefGenderProvider) == 'A' ? null : ref.read(prefGenderProvider),
        'age_min': ref.read(prefAgeMinProvider),
        'age_max': ref.read(prefAgeMaxProvider),
        'radius_km': ref.read(prefRadiusKmProvider),
      };

      List<SwipeCard> received = const [];
      final numAdded = await _repo.topUp(
        prefs: prefs,
        limit: wanted,
        onItems: (items) => received = items,
      );

      // Resolve photo URLs, then cache
      final resolved = await _resolvePhotosForCards(received);
      _cache.addAll(resolved.map((c) => c.toCacheMap()).toList());

      added = numAdded;
      } finally {
        _refreshCardsView();
        _cache.exhausted = added == 0 && _cache.cards.isEmpty;
        ref.read(fetchingProvider.notifier).state = false;
      if (mounted) _warmTopCard(); // ✅ avoid using context after async gaps
    }
    return added;
  }

  // ───────────────────────────── Swipes + Undo
  void _processSwipe({required int index, required SwipeDirection direction}) {
    if (index < 0 || index >= _cache.cards.length) return;

    final data = _cardsView[index];
    final id = data.id;
    if (id.isEmpty) return;

    if (_handled.contains(id)) return;
    _handled.add(id);

    final liked = direction == SwipeDirection.right;

    _pendingIdByIndex[index] = id;

    _undoMemory.set(id, liked, data.toCacheMap());

    _recordSwipe(swipeeId: id, liked: liked);

    if (liked) unawaited(_checkAndShowMatch(id));

    _history
      ..clear()
      ..add(_SwipeEvent(index: index, swipeeId: id, liked: liked));

    HapticFeedback.lightImpact();

    final remainingAfterThis = _cache.cards.length - (index + 1);
    if (remainingAfterThis <= _topUpThreshold && !_cache.exhausted) {
      unawaited(_loadBatch(wanted: _topUpBatch));
    }

    final next = index + 1;
    if (next < _cache.cards.length) {
      final photos = _cardsView[next].photos;
      if (photos.isNotEmpty) {
        unawaited(precacheImage(CachedNetworkImageProvider(photos.first, cacheManager: customCacheManager), context));
      }
    }

    setState(() {});
  }

  Future<void> _recordSwipe({
    required String swipeeId,
    required bool liked,
  }) async {
    if (_inFlight.contains(swipeeId)) return;

    _cache.enqueuePending(swipeeId: swipeeId, liked: liked);

    _inFlight.add(swipeeId);
    try {
      final result = await _repo.swipe(swipeeId: swipeeId, liked: liked);
      _cache.removePending(swipeeId);
      _cache.swipedIds.add(swipeeId);
      if (!mounted) return; // guard UI after await
      if (liked && result.createdMatch && result.me != null && result.other != null) {
        await _MatchOverlay.show(
          context,
          me: _ProfileLite(
            id: result.me!.id,
            name: result.me!.name,
            photoUrl: await _resolveMaybeUrl(result.me!.photoUrl),
          ),
          other: _ProfileLite(
            id: result.other!.id,
            name: result.other!.name,
            photoUrl: await _resolveMaybeUrl(result.other!.photoUrl),
          ),
          onMessage: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ChatListPage()),
            );
          },
          onDismiss: () {},
        );
      }
    } catch (e) {
      if (kDebugMode) debugPrint('recordSwipe error: $e');
    } finally {
      _inFlight.remove(swipeeId);
    }
  }

  Future<void> _flushPendingOutbox() async {
    if (_cache.pendingCount == 0) return;
    final items = _cache.snapshotPending();
    final batch = <({String swipeeId, bool liked})>[
      for (final p in items) (swipeeId: p.swipeeId, liked: p.liked),
    ];
    try {
      await _repo.flushBatch(batch);
      for (final p in items) {
        _cache.removePending(p.swipeeId);
        _cache.swipedIds.add(p.swipeeId);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('flush pending error: $e');
    } finally {
      for (final p in items) {
        _inFlight.remove(p.swipeeId);
      }
    }
  }

  Future<void> _undoLast() async {
    if (_history.isEmpty) return;
    final last = _history.removeLast();
    final me = _supa.auth.currentUser?.id;
    if (me == null) return;

    if (_stack.canRewind) {
      try {
        _stack.rewind();
      } catch (e) {
        if (kDebugMode) debugPrint('rewind err: $e');
      }
    }

    _handled.remove(last.swipeeId);

    final pendingIndex = _pendingIdByIndex.entries
        .firstWhere((e) => e.value == last.swipeeId, orElse: () => const MapEntry(-1, ''))
        .key;
    if (pendingIndex != -1) {
      _pendingIdByIndex.remove(pendingIndex);
    } else {
      final stillInList = _containsCardId(last.swipeeId);
      if (!stillInList && _undoMemory.card != null) {
        final at = (_stack.currentIndex < 0)
            ? 0
            : _stack.currentIndex.clamp(0, _cache.cards.length).toInt();
        _cache.reinsertAt(_undoMemory.card!, index: at);
        _refreshCardsView();
      }
    }

    _cache.removePending(last.swipeeId);
    _cache.swipedIds.remove(last.swipeeId);
    unawaited(
      _repo.undo(swipeeId: last.swipeeId).catchError((e) {
        if (kDebugMode) debugPrint('undo error: $e');
      }),
    );

    _undoMemory.clear();

    HapticFeedback.selectionClick();
    setState(() {});
  }

  // Optional: mutual like overlay
  Future<void> _checkAndShowMatch(String otherUserId) async {
    if (_cache.matchOverlayShownFor.contains(otherUserId) ) return;

    final me = _supa.auth.currentUser?.id;
    if (me == null) return;

    try {
      final recip = await _supa
          .from('swipes')
          .select('liked')
          .eq('swiper_id', otherUserId)
          .eq('swipee_id', me)
          .eq('liked', true)
          .eq('status', 'active')
          .maybeSingle();

      if (recip == null) return;

      final a = me.compareTo(otherUserId) <= 0 ? me : otherUserId;
      final b = me.compareTo(otherUserId) <= 0 ? otherUserId : me;

      final existing = await _supa
          .from('matches')
          .select('id')
          .eq('user1_id', a)
          .eq('user2_id', b);

      if (existing.isEmpty) {
        await _supa
            .from('matches')
            .insert({
              'user1_id': a,
              'user2_id': b,
              'created_at': DateTime.now().toUtc().toIso8601String(),
            })
            .select('id');
      }

      final profs = await _supa
          .from('profiles')
          .select('user_id,name,profile_pictures')
          .inFilter('user_id', [me, otherUserId]);

      _ProfileLite? meLite;
      _ProfileLite? otherLite;

      for (final r in (profs as List)) {
        final m = r as Map<String, dynamic>;
        final id = m['user_id']?.toString() ?? '';
        final pics = (m['profile_pictures'] as List?)
                ?.map((e) => e?.toString() ?? '')
                .where((s) => s.isNotEmpty)
                .toList() ??
            const <String>[];

        String? first = pics.isNotEmpty ? pics.first : null;
        if (first != null) first = await _resolvePhotoUrl(first);

        final lite = _ProfileLite(
          id: id,
          name: (m['name'] as String?)?.trim().isNotEmpty == true
              ? m['name'] as String
              : 'User',
          photoUrl: first,
        );
        if (id == me) {
          meLite = lite;
        } else if (id == otherUserId) {
          otherLite = lite;
        }
      }

      if (!mounted) return; // guard after awaits
      if (meLite == null || otherLite == null) return;

      _cache.matchOverlayShownFor.add(otherUserId);

      await _MatchOverlay.show(
        context,
        me: meLite,
        other: otherLite,
        onMessage: () {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const ChatListPage()),
          );
        },
        onDismiss: () {},
      );
    } catch (e) {
      if (kDebugMode) debugPrint('check match error: $e');
    }
  }

  // ───────────────────────────── UI helpers

  void _openViewProfile(int index) {
    if (index < 0 || index >= _cache.cards.length) return;

    final data = _cardsView[index];
    final userId = data.id;
    if (userId.isEmpty) return;

    final photos = data.photos;
    if (photos.isNotEmpty) {
      unawaited(precacheImage(CachedNetworkImageProvider(photos.first, cacheManager: customCacheManager), context));
    }

    Navigator.of(context).push(PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 220),
      reverseTransitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (_, __, ___) => ViewProfilePage(userId: userId),
      transitionsBuilder: (_, anim, __, child) {
        final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.98, end: 1).animate(curved),
            child: child,
          ),
        );
      },
    ));
  }

  void _precachePhotos(Iterable<String> urls, {int? targetW, int? targetH}) {
    for (final u in urls) {
      if (u.isEmpty) continue;
      final ImageProvider<Object> provider =
          (targetW != null && targetH != null)
              ? ResizeImage(NetworkImage(u), width: targetW, height: targetH)
              : (NetworkImage(u) as ImageProvider<Object>);
      unawaited(precacheImage(provider, context).catchError((_) {}));
    }
  }

  void _warmTopCard() {
    if (_cache.cards.isEmpty || !_hasCurrentCard) return;

    final idx = _stack.currentIndex < 0 ? 0 : _stack.currentIndex;
    if (idx < 0 || idx >= _cache.cards.length) return;

    final photos = _cardsView[idx].photos;

    final dpr = MediaQuery.of(context).devicePixelRatio;
    final w = ((_lastCardW ?? MediaQuery.of(context).size.width) * dpr).round();
    final h = ((_lastCardH ?? 500) * dpr).round();

    _precachePhotos(photos.take(3), targetW: w, targetH: h);
  }

  void _updateFinishedState() {
    if (ref.read(fetchingProvider)) return;
    if (_stack.currentIndex >= _cache.cards.length) {
      _cache.exhausted = true;
    }
  }

  // Swipe overlay label
  Widget _swipeLabel(String text, Color color) {
    return Transform.rotate(
      angle: -math.pi / 14,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color, width: 3),
        ),
        child: Text(
          text,
          style: TextStyle(
            letterSpacing: 2,
            fontWeight: FontWeight.w800,
            fontSize: 20,
            color: color,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final me = _supa.auth.currentUser;
    if (me == null) {
      return const _NotLoggedIn();
    }

    final fetching = ref.watch(fetchingProvider);
    final initializing = ref.watch(initializingProvider);
    final online = ref.watch(onlineProvider);

    final cards = _cardsView; // snapshot once
    final bool empty = _stack.currentIndex >= cards.length;

    final bool showSkeleton = (initializing || fetching) && empty;
    final bool showEmpty    = !showSkeleton && empty;

    return Column(
      children: [
        if (!online) const _OfflineBanner(),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: showSkeleton
                ? _SwipeSkeleton(centerAvatarUrl: _myPhoto)
                : (showEmpty ? _emptyState() : _buildStackAndMeasure(cards)),
          ),
        ),
        if (!showSkeleton && !showEmpty) _bottomBar(),
      ],
    );
  }

  Widget _emptyState() {
    return _OutOfPeoplePage(
      onSeeSwiped: _openSwipedSheet,
      onAdjustFilters: _openFiltersSheet,
    );
  }

  Widget _buildStackAndMeasure(List<SwipeCard> cards) {
    return LayoutBuilder(
      builder: (context, box) {
        final size = box.biggest;

        double target = size.width * 0.94;
        double cardW = target.clamp(280.0, 520.0).toDouble();
        if (size.width > 800) {
          cardW = size.width * 0.6; // Adaptive for tablets/larger screens
        }
        final double cardH = size.height;

        if ((_lastCardW == null || (_lastCardW! - cardW).abs() > 0.5) ||
            (_lastCardH == null || (_lastCardH! - cardH).abs() > 0.5)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            setState(() {
              _lastCardW = cardW;
              _lastCardH = cardH;
            });
          });
        }

        return Center(
          child: SizedBox(
            width: cardW,
            height: cardH,
            child: SwipableStack(
              controller: _stack,
              detectableSwipeDirections: const {
                SwipeDirection.left,
                SwipeDirection.right,
                SwipeDirection.up,
              },
              stackClipBehaviour: Clip.none,
              horizontalSwipeThreshold: 0.25,
              verticalSwipeThreshold: 0.28,
              overlayBuilder: (context, props) {
                final dir = props.direction;
                final p = props.swipeProgress; // 0..1
                final double o = p.isNaN ? 0.0 : p.clamp(0.0, 1.0).toDouble();
                return Stack(children: [
                  if (dir == SwipeDirection.right && o > 0)
                    Positioned(
                      top: 24,
                      left: 18,
                      child: Opacity(
                        opacity: o,
                        child: _swipeLabel('LIKE', Colors.greenAccent),
                      ),
                    ),
                  if (dir == SwipeDirection.left && o > 0)
                    Positioned(
                      top: 24,
                      right: 18,
                      child: Opacity(
                        opacity: o,
                        child: _swipeLabel('NOPE', Colors.redAccent),
                      ),
                    ),
                  if (dir == SwipeDirection.up && o > 0)
                    Positioned(
                      bottom: 100,
                      left: 18,
                      child: Opacity(
                        opacity: o,
                        child: _swipeLabel('VIEW', Colors.lightBlueAccent),
                      ),
                    ),
                ]);
              },

              // Register + queue; do not mutate the list here.
              onWillMoveNext: (index, direction) {
                if (direction == SwipeDirection.up) {
                  _openViewProfile(index);
                  HapticFeedback.selectionClick();
                  return false; // open profile instead of like
                }
                _processSwipe(index: index, direction: direction);
                return true;
              },

              // Now the animation is done → mutate list safely.
              onSwipeCompleted: (index, direction) {
                final id = _pendingIdByIndex.remove(index);
                if (id == null || id.isEmpty) return;

                if (_cache.cards.any((m) => m['potential_match_id'] == id || m['user_id'] == id)) {
                  _cache.consumeById(id);
                  _photoIndexById.remove(id);
                  _refreshCardsView();
                }

                final noneLeft = _cache.cards.isEmpty;
                if (noneLeft && !ref.read(fetchingProvider)) {
                  _cache.exhausted = true;
                }
                setState(() {});
              },

              itemCount: cards.length,
              builder: (context, props) {
                final i = props.index;
                if (i >= cards.length) return const SizedBox.shrink();

                final data = cards[i];
                final userId = data.id;

                return KeyedSubtree(
                  key: ValueKey(userId),
                  child: _card(i, data, cardW, cardH),
                );
              },
            ),
          ),
        );
      },
    );
  }

  // Card with left/right photo tap, dots top, gradient info bottom
  Widget _card(int index, SwipeCard data, double cardW, double cardH) {
    final String userId = data.id;
    final String name = data.name;
    final int age = data.age ?? 0;
    final String bio = data.bio ?? '';
    final String distance = data.distance ?? '';

    final List<String> photos = data.photos;

    _photoIndexById.putIfAbsent(userId, () => 0);
    final int maxIdx = photos.isEmpty ? 0 : photos.length - 1;
    final int currentIndex = (_photoIndexById[userId] ?? 0).clamp(0, maxIdx);
    final bool hasPhotos = photos.isNotEmpty;
    final String? currentPhoto = hasPhotos ? photos[currentIndex] : null;

    final bool onlineRealtime = _onlineUserIds.contains(userId);
    final bool isOnline = onlineRealtime || data.isOnline;

    final presence = _presenceInfo(
      isOnline: isOnline,
      lastSeenRaw: data.lastSeen,
    );

    final bool isTopCard = index == _stack.currentIndex;

    return Align(
      alignment: Alignment.topCenter,
      child: Container(
        width: cardW,
        height: cardH,
        margin: const EdgeInsets.only(top: 0),
        decoration: const BoxDecoration(
          boxShadow: [
            BoxShadow(
              blurRadius: 22,
              color: Colors.black45,
              offset: Offset(0, 14),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: SizedBox(
            width: cardW,
            height: cardH,
            child: LayoutBuilder(
              builder: (context, c) {
                final cw = c.maxWidth;

                if (photos.length > 1) {
                  final next = math.min(currentIndex + 1, maxIdx);
                  final prev = math.max(currentIndex - 1, 0);
                  if (next != currentIndex && photos[next].isNotEmpty) {
                    unawaited(precacheImage(
                        CachedNetworkImageProvider(photos[next], cacheManager: customCacheManager), context));
                  }
                  if (prev != currentIndex && photos[prev].isNotEmpty) {
                    unawaited(precacheImage(
                        CachedNetworkImageProvider(photos[prev], cacheManager: customCacheManager), context));
                  }
                }

                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (details) {
                    if (photos.length < 2) return;
                    final isRight = details.localPosition.dx > cw / 2;
                    setState(() {
                      final n = currentIndex + (isRight ? 1 : -1);
                      final clamped = n.clamp(0, maxIdx).toInt();
                      _photoIndexById[userId] = clamped;
                    });
                  },
                  onLongPress: () => _openViewProfile(index),
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: currentPhoto == null
                            ? const ColoredBox(color: Colors.black26)
                            : (isTopCard
                                ? Hero(
                                    tag: 'public_profile_photo_$userId',
                                    child: Transform.scale(
                                      scale: 1.06,
                                      child: FadeInImage(
                                        placeholder: MemoryImage(transparentPixel),
                                        image: CachedNetworkImageProvider(
                                          currentPhoto,
                                          cacheManager: customCacheManager,
                                        ),
                                        fit: BoxFit.cover,
                                        width: cardW,
                                        height: cardH,
                                      ),
                                    ),
                                  )
                                : Transform.scale(
                                    scale: 1.06,
                                    child: FadeInImage(
                                      placeholder: MemoryImage(transparentPixel),
                                      image: CachedNetworkImageProvider(
                                        currentPhoto,
                                        cacheManager: customCacheManager,
                                      ),
                                      fit: BoxFit.cover,
                                      width: cardW,
                                      height: cardH,
                                    ),
                                  )),
                      ),

                      if (photos.length > 1)
                        Positioned(
                          top: 14,
                          left: 0,
                          right: 0,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: List.generate(
                              photos.length,
                              (dot) => Container(
                                margin: const EdgeInsets.symmetric(horizontal: 3),
                                width: 9,
                                height: 9,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: dot == currentIndex
                                      ? Colors.pink
                                      : Colors.grey.withValues(alpha: _kDefaultAlpha),
                                ),
                              ),
                            ),
                          ),
                        ),

                      if (presence.bucket == _PresenceBucket.active)
                        Positioned(
                          top: 14,
                          left: 14,
                          child: Container(
                            width: 12,
                            height: 12,
                            decoration: const BoxDecoration(
                              color: Color(0xFF00E676),
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: Color(0x8000E676),
                                  blurRadius: 8,
                                ),
                              ],
                            ),
                          ),
                        ),

                      Positioned(
                        top: 12,
                        left: 34,
                        child: _StatusChip(
                          text: presence.label,
                          color: presence.color,
                        ),
                      ),

                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: InkWell(
                          onTap: () => _openViewProfile(index),
                          child: Container(
                            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                            decoration: const BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.bottomCenter,
                                end: Alignment.topCenter,
                                colors: [
                                  Color.fromARGB(230, 0, 0, 0),
                                  Color.fromARGB(150, 0, 0, 0),
                                  Color.fromARGB(60, 0, 0, 0),
                                ],
                                stops: [0.0, 0.5, 1.0],
                              ),
                              borderRadius: BorderRadius.vertical(
                                top: Radius.circular(12),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  age > 0 ? '$name, $age' : name,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 22,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Row(
                                  children: [
                                    if (distance.isNotEmpty) ...[
                                      const Icon(Icons.place_outlined,
                                          size: 16, color: Colors.white70),
                                      const SizedBox(width: 6),
                                      Flexible(
                                        child: Text(
                                          distance,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: Colors.white70,
                                            fontSize: 14,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                if (bio.isNotEmpty) ...[
                                  const SizedBox(height: 10),
                                  Text(
                                    bio,
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  // Bottom bar sized to card width.
  Widget _bottomBar() {
    final cardW = (_lastCardW ?? MediaQuery.of(context).size.width * 0.94);

    final double btn = cardW < 320 ? 52 : (cardW < 360 ? 58 : 62);
    final double bigBtn = btn + 10;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        12,
        8,
        12,
        12 + MediaQuery.of(context).padding.bottom * .6,
      ),
      child: Align(
        alignment: Alignment.center,
        child: SizedBox(
          width: math.max(cardW - 8, 220),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _RoundAction(
                icon: Icons.rotate_left,
                color: _history.isEmpty ? Colors.white24 : Colors.green,
                size: btn,
                onTap: _history.isEmpty
                    ? null
                    : () {
                        HapticFeedback.lightImpact();
                        _undoLast();
                      },
              ),
              _RoundAction(
                icon: Icons.cancel,
                color: Colors.red,
                size: btn,
                onTap: () {
                  _stack.next(swipeDirection: SwipeDirection.left);
                },
              ),
              _RoundAction(
                icon: Icons.star,
                color: Colors.blue,
                size: bigBtn,
                onTap: () {
                  _openViewProfile(_stack.currentIndex);
                },
              ),
              _RoundAction(
                icon: Icons.favorite,
                color: Colors.pink,
                size: btn,
                onTap: () {
                  _stack.next(swipeDirection: SwipeDirection.right);
                },
              ),
              _RoundAction(
                icon: Icons.flash_on,
                color: Colors.purple,
                size: btn,
                onTap: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Boost sent ✨')),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ───────────────────────────── Empty-state actions
  Future<void> _openFiltersSheet() async {
    String g = ref.read(prefGenderProvider);
    RangeValues ages = RangeValues(ref.read(prefAgeMinProvider).toDouble(), ref.read(prefAgeMaxProvider).toDouble());
    double radius = ref.read(prefRadiusKmProvider);
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF16181C),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: 16 + MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: StatefulBuilder(builder: (ctx, setM) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 44,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const Text('Adjust Filters',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Text('Interested in', style: TextStyle(fontSize: 14)),
                    const Spacer(),
                    SegmentedButton<String>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: 'F', label: Text('Women')),
                        ButtonSegment(value: 'M', label: Text('Men')),
                        ButtonSegment(value: 'A', label: Text('All')),
                      ],
                      selected: <String>{g},
                      onSelectionChanged: (s) => setM(() => g = s.first),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Text('Age range', style: TextStyle(fontSize: 14)),
                    const Spacer(),
                    Text('${ages.start.round()}–${ages.end.round()}'),
                  ],
                ),
                RangeSlider(
                  values: ages,
                  min: 18,
                  max: 80,
                  divisions: 62,
                  labels: RangeLabels(
                    ages.start.round().toString(),
                    ages.end.round().toString(),
                  ),
                  onChanged: (v) => setM(() => ages = v),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Text('Distance radius', style: TextStyle(fontSize: 14)),
                    const Spacer(),
                    Text('${radius.round()} km'),
                  ],
                ),
                Slider(
                  value: radius,
                  min: 5,
                  max: 200,
                  divisions: 39,
                  onChanged: (v) => setM(() => radius = v),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () async {
                      Navigator.of(ctx).maybePop();
                      await _applyFilters(
                        gender: g,
                        ageMin: ages.start.round(),
                        ageMax: ages.end.round(),
                        radiusKm: radius,
                      );
                    },
                    child: const Text('Apply Filters'),
                  ),
                ),
                const SizedBox(height: 6),
              ],
            );
          }),
        );
      },
    );
  }

  Future<void> _applyFilters({
    required String gender,
    required int ageMin,
    required int ageMax,
    required double radiusKm,
  }) async {
    final me = _supa.auth.currentUser?.id;
    if (me == null) return;

    ref.read(prefGenderProvider.notifier).state = gender;
    ref.read(prefAgeMinProvider.notifier).state = ageMin;
    ref.read(prefAgeMaxProvider.notifier).state = ageMax;
    ref.read(prefRadiusKmProvider.notifier).state = radiusKm;

    try {
      await _supa.from('preferences').upsert(
        {
          'user_id': me,
          // NULL for "All" so backend returns everyone
          'interested_in_gender': (ref.read(prefGenderProvider) == 'A') ? null : ref.read(prefGenderProvider),
          'age_min': ref.read(prefAgeMinProvider),
          'age_max': ref.read(prefAgeMaxProvider),
          'distance_radius': ref.read(prefRadiusKmProvider).round(),
        },
        onConflict: 'user_id',
      );
    } catch (e) {
      if (kDebugMode) debugPrint('prefs upsert failed: $e');
    }

    final key = '$me|g=${ref.read(prefGenderProvider)}|a=${ref.read(prefAgeMinProvider)}-${ref.read(prefAgeMaxProvider)}|r=${ref.read(prefRadiusKmProvider)}';
    _cache.resetIfKeyChanged(key);
    _repo.reset();
    _cache.exhausted = false;

    ref.read(initializingProvider.notifier).state = true;
    await _loadBatch(wanted: _initialBatch);
    ref.read(initializingProvider.notifier).state = false;
  }

  Future<void> _openSwipedSheet() async {
    final me = _supa.auth.currentUser?.id;
    if (me == null) return;

    try {
      // ... fetch, map, resolve photos ...
    } catch (e) {
      if (kDebugMode) debugPrint('swiped sheet load failed: $e');
    }

    if (!mounted) return; // guard State.context use after awaits
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF16181C),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // … list UI …
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () async {
                      await Navigator.of(ctx).maybePop();
                      if (!mounted) return; // guard State.context (we use Navigator.of(context) next)
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const ChatListPage()),
                      );
                    },
                    child: const Text('Open Messages / Matches'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ───────────────────────────── Helpers
  bool _containsCardId(String id) {
    for (final m in _cardsView) {
      if (m.id == id) return true;
    }
    return false;
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.icon,
    required this.color,
    required this.size,
    this.onTap,
  });

  final IconData icon;
  final Color color;
  final double size;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    const Color bg = Color(0xFF1E1F24);
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: size,
        height: size,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            color: bg,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(blurRadius: 10, color: Colors.black38, offset: Offset(0, 4)),
            ],
          ),
          child: Center(child: Icon(icon, color: color, size: size * 0.44)),
        ),
      ),
    );
  }
}

// ───────────────────────────── Helper Widgets
class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.withValues(alpha: _kDefaultAlpha),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.red.withValues(alpha: _kDefaultAlpha)),
      ),
      child: const Row(
        children: [
          Icon(Icons.wifi_off_rounded, color: Colors.redAccent),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              "You're offline. Swipes will queue when you're back online.",
              style: TextStyle(color: Colors.white70),
            ),
          ),
        ],
      ),
    );
  }
}

class _NotLoggedIn extends StatelessWidget {
  const _NotLoggedIn();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text('Please sign in to discover profiles',
          style: TextStyle(fontSize: 16)),
    );
  }
}

// ───────────────────────────── Empty CTA Page
class _OutOfPeoplePage extends StatelessWidget {
  const _OutOfPeoplePage({required this.onSeeSwiped, required this.onAdjustFilters});
  final VoidCallback onSeeSwiped;
  final VoidCallback onAdjustFilters;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(18.0),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF6759FF), Color(0xFFFF0F7B)],
                  ),
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: const [
                    BoxShadow(color: Colors.black45, blurRadius: 22, offset: Offset(0, 12)),
                  ],
                ),
                child: const Icon(Icons.verified_rounded, size: 64, color: Colors.white),
              ),
              const SizedBox(height: 16),
              const Text("No more matches",
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 22)),
              const SizedBox(height: 6),
              const Text(
                'No more profiles right now. Explore your history or tweak your filters.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: const Icon(Icons.history),
                  onPressed: onSeeSwiped,
                  label: const Text('See swiped users'),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.tune),
                  onPressed: onAdjustFilters,
                  label: const Text('Adjust filters'),
                ),
              ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }
}

// ───────────────────────────── Loading Skeleton
class _SwipeSkeleton extends StatelessWidget {
  const _SwipeSkeleton({required this.centerAvatarUrl});
  final String? centerAvatarUrl;

  @override
  Widget build(BuildContext context) {
    final outline = Theme.of(context).dividerColor.withValues(alpha: _kDefaultAlpha);
    return RepaintBoundary(
      child: Stack(
        children: [
          Align(
            alignment: Alignment.topCenter,
            child: Container(
              width: double.infinity,
              height: double.infinity,
              decoration: BoxDecoration(
                color: const Color(0xFF16181C),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: outline),
                boxShadow: const [
                  BoxShadow(
                      color: Colors.black54,
                      blurRadius: 16,
                      offset: Offset(0, 10)),
                ],
              ),
            ),
          ),
          Positioned(
            left: 18,
            right: 90,
            bottom: 80,
            child: const _SkeletonBar(height: 12, radius: 6),
          ),
          Positioned(
            left: 18,
            right: 140,
            bottom: 58,
            child: const _SkeletonBar(height: 10, radius: 6),
          ),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 160,
                  height: 160,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Container(
                        width: 100,
                        height: 100,
                        decoration: BoxDecoration(
                          color: const Color(0xFF202227),
                          shape: BoxShape.circle,
                          border: Border.all(color: outline),
                          boxShadow: const [
                            BoxShadow(
                                color: Colors.black45,
                                blurRadius: 12,
                                offset: Offset(0, 6))
                          ],
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: (centerAvatarUrl == null ||
                                centerAvatarUrl!.isEmpty)
                            ? const Icon(Icons.person,
                                color: Colors.white70, size: 44)
                            : FadeInImage(
                                placeholder: MemoryImage(transparentPixel),
                                image: CachedNetworkImageProvider(
                                  centerAvatarUrl!,
                                  cacheManager: customCacheManager,
                                ),
                                fit: BoxFit.cover,
                                filterQuality: FilterQuality.medium,
                              ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.radar_rounded,
                        size: 18, color: _brandPink),
                    const SizedBox(width: 6),
                    Text(
                      'Finding matches near you…',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: _kDefaultAlpha),
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        letterSpacing: .2,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SkeletonBar extends StatelessWidget {
  const _SkeletonBar({required this.height, this.radius = 12});
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: height,
      decoration: BoxDecoration(
        color: const Color(0xFF202227),
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

// ───────────────────────────── Presence helpers
enum _PresenceBucket { active, recent, offline }

class _PresenceInfo {
  final _PresenceBucket bucket;
  final String label;
  final Color color;
  const _PresenceInfo(this.bucket, this.label, this.color);
}

_PresenceInfo _presenceInfo({required bool isOnline, required dynamic lastSeenRaw}) {
  if (isOnline) {
    return const _PresenceInfo(
      _PresenceBucket.active,
      'Active now',
      Color(0xFF00E676),
    );
  }

  final lastSeen = _toDateTimeOrNull(lastSeenRaw);
  if (lastSeen == null) {
    return const _PresenceInfo(
      _PresenceBucket.offline,
      'Offline',
      Colors.white24,
    );
  }

  final now = DateTime.now().toUtc();
  final dt = lastSeen.isUtc ? lastSeen : lastSeen.toUtc();
  final diff = now.difference(dt);
  final minutes = diff.inMinutes;
  final hours = diff.inHours;
  final days = diff.inDays;

  if (minutes <= 10) {
    return const _PresenceInfo(
      _PresenceBucket.recent,
      'Recently active',
      Color(0xFFFFC107),
    );
  }

  String fmtAgo() {
    if (minutes < 60) return 'Last seen ${minutes}m';
    if (hours < 24) return 'Last seen ${hours}h';
    return 'Last seen ${days}d';
  }

  return _PresenceInfo(_PresenceBucket.offline, fmtAgo(), Colors.white24);
}

DateTime? _toDateTimeOrNull(dynamic v) {
  try {
    if (v == null) return null;
    if (v is DateTime) return v;
    final s = v.toString();
    if (s.isEmpty) return null;
    return DateTime.tryParse(s);
  } catch (e) {
    return null;
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────────── Models
class _SwipeEvent {
  final int index; // stack index at time of swipe
  final String swipeeId;
  final bool liked;
  const _SwipeEvent({
    required this.index,
    required this.swipeeId,
    required this.liked,
  });
}

@immutable
class _ProfileLite {
  final String id;
  final String name;
  final String? photoUrl;
  const _ProfileLite({required this.id, required this.name, required this.photoUrl});
}

// ───────────────────────────── Match Overlay (self-contained)
class _MatchOverlay extends StatefulWidget {
  const _MatchOverlay({
    required this.me,
    required this.other,
    this.onMessage,
    this.onDismiss,
  });

  final _ProfileLite me;
  final _ProfileLite other;
  final VoidCallback? onMessage;
  final VoidCallback? onDismiss;

  static Future<void> show(
    BuildContext context, {
    required _ProfileLite me,
    required _ProfileLite other,
    VoidCallback? onMessage,
    VoidCallback? onDismiss,
  }) async {
    await showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'match',
      barrierColor: Colors.black.withValues(alpha: _kDefaultAlpha),
      pageBuilder: (_, __, ___) => Center(
        child: _MatchOverlay(me: me, other: other, onMessage: onMessage, onDismiss: onDismiss),
      ),
      transitionBuilder: (ctx, anim, __, child) {
        final scale = Tween<double>(begin: 0.95, end: 1.0)
            .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutBack));
        final fade = Tween<double>(begin: 0.0, end: 1.0)
            .animate(CurvedAnimation(parent: anim, curve: Curves.easeOut));
        return Opacity(
          opacity: fade.value,
          child: Transform.scale(scale: scale.value, child: child),
        );
      },
      transitionDuration: const Duration(milliseconds: 280),
    );
  }

  @override
  State<_MatchOverlay> createState() => _MatchOverlayState();
}

class _MatchOverlayState extends State<_MatchOverlay>
    with TickerProviderStateMixin {
  late final AnimationController _pulse1;
  late final AnimationController _pulse2;
  late final AnimationController _pulse3;

  @override
  void initState() {
    super.initState();
    _pulse1 = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))
      ..repeat(reverse: true);
    _pulse2 = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))
      ..repeat(reverse: true);
    _pulse3 = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse1.dispose();
    _pulse2.dispose();
    _pulse3.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const outline = Color(0xFF3C4046);
    const primaryBg = Color(0xFF16181C);
    const primary = Color(0xFFFF0F7B);

    return Material(
      color: Colors.transparent,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 18),
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
        decoration: BoxDecoration(
          color: primaryBg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: outline),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: _kDefaultAlpha),
              blurRadius: 24,
              offset: const Offset(0, 16),
            ),
          ],
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 300,
                height: 380,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    _PulsingHeart(controller: _pulse1, size: 60, dx: -120, dy: -140, color: primary),
                    _PulsingHeart(controller: _pulse2, size: 40, dx:  120, dy: -120, color: primary),
                    _PulsingHeart(controller: _pulse3, size: 50, dx: -100, dy:  140, color: primary),

                    Align(
                      alignment: const Alignment(1, -0.4),
                      child: Transform.rotate(
                        angle: 10 * (math.pi / 180),
                        child: _PicCard(
                          url: widget.me.photoUrl,
                          fallbackLetter: _firstLetter(widget.me.name),
                        ),
                      ),
                    ),
                    Align(
                      alignment: const Alignment(-1, 0.6),
                      child: Transform.rotate(
                        angle: -10 * (math.pi / 180),
                        child: _PicCard(
                          url: widget.other.photoUrl,
                          fallbackLetter: _firstLetter(widget.other.name),
                        ),
                      ),
                    ),
                    Align(
                      alignment: Alignment.center,
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: primaryBg,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: _kDefaultAlpha),
                              blurRadius: 10,
                            ),
                          ],
                          border: Border.all(color: outline),
                        ),
                        child: const Icon(Icons.favorite, size: 22, color: primary),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text(
                "It's a match, ${widget.me.name}!",
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  letterSpacing: .2,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                "Now’s your chance — say hi to ${widget.other.name}.",
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: primary,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () {
                    Navigator.of(context).maybePop();
                    widget.onMessage?.call();
                  },
                  child: const Text('Say Hello', style: TextStyle(color: Colors.white, fontSize: 16)),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: outline),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () {
                    Navigator.of(context).maybePop();
                    widget.onDismiss?.call();
                  },
                  child: const Text('Keep swiping', style: TextStyle(fontSize: 16)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _firstLetter(String s) {
    final t = s.trim();
    final letter = t.isEmpty ? 'U' : t[0].toUpperCase();
    return letter;
  }
}

class _PicCard extends StatelessWidget {
  const _PicCard({required this.url, required this.fallbackLetter});
  final String? url;
  final String fallbackLetter;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 172,
      height: 248,
      decoration: BoxDecoration(
        color: const Color(0xFF1A1C21),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF3C4046)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: _kDefaultAlpha),
            blurRadius: 12,
            offset: const Offset(0, 8),
          ),
        ],
        image: url == null
            ? null
            : DecorationImage(
                image: CachedNetworkImageProvider(url!, cacheManager: customCacheManager),
                fit: BoxFit.cover,
                onError: (Object _, StackTrace? __) {},
              ),
      ),
      child: url == null
          ? Center(
              child: Text(
                fallbackLetter,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 56,
                  fontWeight: FontWeight.w700,
                ),
              ),
            )
          : null,
    );
  }
}

class _PulsingHeart extends StatelessWidget {
  const _PulsingHeart({
    required this.controller,
    required this.size,
    required this.dx,
    required this.dy,
    required this.color,
  });
  final AnimationController controller;
  final double size;
  final double dx;
  final double dy;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: const Color(0xFF1A1C21),
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0xFF3C4046)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: _kDefaultAlpha),
              blurRadius: 10,
            ),
          ],
        ),
        child: Icon(Icons.favorite, color: color, size: size * 0.6),
      ),
      builder: (BuildContext context, Widget? child) {
        final s = 0.9 + 0.1 * (1 + math.sin(controller.value * math.pi * 2)) / 2;
        return Transform.translate(
          offset: Offset(dx, dy),
          child: Transform.scale(scale: s, child: child),
        );
      },
    );
  }
}

// Note: For Material 3, add to your app's ThemeData in main.dart:
// ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue));
