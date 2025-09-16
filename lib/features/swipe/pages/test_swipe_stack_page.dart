// =========================
// FIXED & ENHANCED FILE: lib/features/swipe/pages/test_swipe_stack_page.dart
// =========================
// Notes on this patch (keep these dev notes at the top):
// - **BUGFIX**: Empty state showed before the *last* card was swiped.
//   Root cause: the card was removed from the data list in onWillMoveNext.
//   **Fix**: Defer removal until `onSwipeCompleted` using `_pendingIdByIndex`.
//   Now the last-card swipe animates smoothly and then "No more matches" auto-shows.
// - **UI**: Card width ~92–94% of screen, clamped for polish; bottom bar auto-sizes.
// - **Presence**: Active / Recently active / Last seen X with chip + online dot.
// - **Perf**: Precache current/adjacent photos, snapshot for robust Undo.
// - **Connectivity**: Correct `checkConnectivity()` usage; Socket ping on native.
// - **API**: Immediate local outbox + server sync; match overlay on mutual like.
// - **Styling**: Replaced deprecated `withOpacity` with `withValues(alpha: ...)`.
// - **Exhausted detection**: Set exhausted if loaded batch size < requested, to avoid unnecessary RPC on final swipes.
// - **Dart analysis fixes**: Handled List<ConnectivityResult> for connectivity_plus; added mounted checks for BuildContext usage after async gaps.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:swipable_stack/swipable_stack.dart';

import '../../profile/pages/view_profile_page.dart';
import '../../matches/chat_list_page.dart';
import '../../swipe/data/swipe_feed_cache.dart';
import '../../../services/presence_service.dart';

const double _kDefaultAlpha = 0.12;

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

class TestSwipeStackPage extends StatefulWidget {
  const TestSwipeStackPage({super.key});

  static const String routeName = 'SwipePage';
  static const String routePath = '/swipe';

  @override
  State<TestSwipeStackPage> createState() => _TestSwipeStackPageState();
}

class _TestSwipeStackPageState extends State<TestSwipeStackPage>
    with TickerProviderStateMixin {
  // ─────────────────────────────── Constants
  static const _rpcGetMatches = 'get_potential_matches';
  static const _rpcHandleSwipe = 'handle_swipe';

  static const int _initialBatch = 20;
  static const int _topUpBatch = 20;
  static const int _topUpThreshold = 5;

  // ─────────────────────────────── Services
  final SupabaseClient _supa = Supabase.instance.client;
  final SwipableStackController _stack = SwipableStackController();

  // ─────────────────────────────── Global cache
  final SwipeFeedCache _cache = SwipeFeedCache.instance;

  // Per-USER photo index (stable across list growth)
  final Map<String, int> _photoIndexById = <String, int>{};

  // Swipe bookkeeping
  final Set<String> _inFlight = <String>{};
  final Set<String> _handled = <String>{}; // "$index|$userId"
  final List<_SwipeEvent> _history = <_SwipeEvent>[];

  // NEW: defer removal until animation completes (index → id)
  final Map<int, String> _pendingIdByIndex = <int, String>{};

  // Presence
  final Set<String> _onlineUserIds = <String>{};
  Timer? _presenceTimer;

  // UI state
  bool _fetching = false;
  bool _initializing = true;
  bool _online = true;

  // Prefs
  String _prefGender = 'F';
  int _prefAgeMin = 18;
  int _prefAgeMax = 60;
  double _prefRadiusKm = 50.0;

  // Connectivity
  StreamSubscription? _connSub;

  // bottom-bar measurement
  double? _lastCardW;
  double? _lastCardH;

  // Loader avatar (my first profile photo)
  String? _myPhoto;

  // Convenience
  List<Map<String, dynamic>> get _cards => _cache.cards;

  @override
  void initState() {
    super.initState();

    _stack.addListener(() {
      _cache.lastStackIndex = _stack.currentIndex;
      _warmTopCard();
      _updateFinishedState();
      if (mounted) setState(() {});
    });

    _bootstrap();
  }

  @override
  void deactivate() {
    super.deactivate();
    _compactSwipedExceptLast();
  }

  void _compactSwipedExceptLast() {
    if (_cache.cards.isEmpty || _cache.swipedIds.isEmpty) return;
    _cache.compactConsumed(exceptId: null);
  }

  Future<void> _bootstrap() async {
    final ok = await _ensureConnectivity();
    if (mounted) setState(() => _online = ok);
    _listenConnectivity();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startPresence();
    });

    await _loadMyPhoto();
    await _loadPreferences();

    final me = _supa.auth.currentUser?.id;
    if (me != null) {
      final key = '$me|g=$_prefGender|a=$_prefAgeMin-$_prefAgeMax|r=$_prefRadiusKm';
      _cache.resetIfKeyChanged(key);
    }

    await _flushPendingOutbox();

    if (_cards.isEmpty) {
      if (mounted) setState(() => _initializing = true);
      await _loadBatch(wanted: _initialBatch);
      if (mounted) setState(() => _initializing = false);
    } else {
      if (mounted) setState(() => _initializing = false);
      if (_cardsAfterCurrent() <= _topUpThreshold && !_cache.exhausted) {
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
      if (mounted) {
        _updateFinishedState();
        setState(() {});
      }
    }
  }

  @override
  void dispose() {
    _connSub?.cancel();
    _presenceTimer?.cancel();
    _stack.dispose();
    super.dispose();
  }

  // ───────────────────────────── Derived helpers
  bool get _hasCurrentCard {
    final i = _stack.currentIndex;
    return i >= 0 && i < _cards.length;
  }

  int _cardsAfterCurrent() {
    final i = _stack.currentIndex < 0 ? 0 : _stack.currentIndex;
    final left = _cards.length - i - 1;
    return left <= 0 ? 0 : left;
  }

  // EMPTY only when not fetching/initializing and truly empty.
  bool get _showEmpty => !_initializing && !_fetching && !_hasCurrentCard && _cards.isEmpty;

  // SKELETON during initial load or while refilling an empty stack.
  bool get _showSkeleton => (_initializing || (_fetching && _cards.isEmpty)) && _cards.isEmpty;

  // ───────────────────────────── Connectivity
  void _listenConnectivity() {
    _connSub = Connectivity().onConnectivityChanged.listen((List<ConnectivityResult> results) async {
      bool ok = !results.contains(ConnectivityResult.none);
      if (ok && !kIsWeb) {
        try {
          final socket = await Socket.connect('8.8.8.8', 53, timeout: const Duration(milliseconds: 900));
          socket.destroy();
        } catch (_) {
          ok = false;
        }
      }
      if (ok) {
        unawaited(_flushPendingOutbox());
      }
      if (mounted) setState(() => _online = ok);
    });
  }

  Future<bool> _ensureConnectivity() async {
    try {
      final List<ConnectivityResult> result = await Connectivity().checkConnectivity();
      if (result.contains(ConnectivityResult.none)) return false;
      if (!kIsWeb) {
        final socket = await Socket.connect('8.8.8.8', 53,
            timeout: const Duration(milliseconds: 900));
        socket.destroy();
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  // ───────────────────────────── Presence
  void _startPresence() {
    final me = _supa.auth.currentUser?.id;
    if (me == null) return;

    final ch = PresenceService.instance.channel();
    unawaited(ch.track({
      'user_id': me,
      'online_at': DateTime.now().toUtc().toIso8601String(),
    }));

    _presenceTimer?.cancel();
    _presenceTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      final states = ch.presenceState();
      final set = <String>{};
      for (final room in states) {
        for (final pr in room.presences) {
          final id = pr.payload['user_id']?.toString();
          if (id != null && id.isNotEmpty) set.add(id);
        }
      }
      if (!mounted) return;
      if (!setEquals(set, _onlineUserIds)) {
        _onlineUserIds
          ..clear()
          ..addAll(set);
        setState(() {});
      }
    });
  }

  // ───────────────────────────── My avatar
  Future<void> _loadMyPhoto() async {
    try {
      final me = _supa.auth.currentUser?.id;
      if (me == null) return;
      final row = await _supa
          .from('profiles')
          .select('profile_pictures, name')
          .eq('user_id', me)
          .maybeSingle();
      final pics = (row?['profile_pictures'] as List?)
              ?.map((e) => e?.toString() ?? '')
              .where((s) => s.isNotEmpty)
              .toList() ??
          const <String>[];
      if (pics.isNotEmpty && mounted) {
        final url = pics.first;
        unawaited(precacheImage(CachedNetworkImageProvider(url), context));
        setState(() => _myPhoto = url);
      }
    } catch (e) {
      debugPrint('Load my photo error: $e');
    }
  }

  // ───────────────────────────── Preferences
  Future<void> _loadPreferences() async {
    try {
      final me = _supa.auth.currentUser?.id;
      if (me == null) return;
      final row = await _supa
          .from('preferences')
          .select('interested_in_gender, age_min, age_max, distance_radius')
          .eq('user_id', me)
          .maybeSingle();
      if (row != null) {
        _prefGender = (row['interested_in_gender'] ?? _prefGender).toString();
        _prefAgeMin = (row['age_min'] ?? _prefAgeMin) as int;
        _prefAgeMax = (row['age_max'] ?? _prefAgeMax) as int;
        _prefRadiusKm = (row['distance_radius'] ?? _prefRadiusKm).toDouble();
      }
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Prefs load error: $e');
    }
  }

  // ───────────────────────────── Data Loading
  Future<int> _loadBatch({required int wanted}) async {
    if (_fetching) return 0;
    if (mounted) setState(() => _fetching = true);

    int added = 0;
    try {
      if (!_cache.preferDirect) {
        added = await _loadBatchRpc(limit: wanted);
      }
      if (added == 0) {
        _cache.preferDirect = true;
        added = await _loadBatchDirect(limit: wanted);
      }
    } finally {
      if (mounted) {
        setState(() {
          if (added < wanted) {
            _cache.exhausted = true;
          } else {
            _cache.exhausted = false;
          }
          _fetching = false;
        });
      }
      _warmTopCard();
    }
    return added;
  }

  Future<int> _loadBatchRpc({required int limit}) async {
    try {
      final me = _supa.auth.currentUser?.id;
      if (me == null) return 0;

      final res = await _supa.rpc(_rpcGetMatches, params: {
        'user_id_arg': me,
        'gender_arg': _prefGender,
        'radius_arg': _prefRadiusKm,
        'age_min_arg': _prefAgeMin,
        'age_max_arg': _prefAgeMax,
        'limit_arg': limit,
        'offset_arg': _cache.rpcOffset,
      });

      final list = (res as List?)
              ?.map((e) => Map<String, dynamic>.from(e as Map))
              .toList() ??
          <Map<String, dynamic>>[];

      final added = _mergeIncoming(list,
          idKey: 'potential_match_id',
          photosKey: 'photos',
          distanceKey: 'distance');

      _cache.rpcOffset += limit;
      return added;
    } catch (e) {
      debugPrint('RPC load error → fallback: $e');
      return 0;
    }
  }

  Future<int> _loadBatchDirect({required int limit}) async {
    try {
      final me = _supa.auth.currentUser?.id;
      if (me == null) return 0;

      final already = await _alreadySwiped(me);

      final rows = await _supa
          .from('profiles')
          .select(
            'user_id, name, profile_pictures, current_city, bio, age, is_online, last_seen',
          )
          .neq('user_id', me)
          .range(_cache.directOffset, _cache.directOffset + 60 - 1);

      _cache.directOffset += 60;

      final mapped = (rows as List)
          .cast<Map<String, dynamic>>()
          .map((row) {
            final photos = (row['profile_pictures'] is List)
                ? (row['profile_pictures'] as List)
                    .map((e) => e?.toString() ?? '')
                    .where((s) => s.isNotEmpty)
                    .toList()
                : const <String>[];
            return {
              'potential_match_id': row['user_id']?.toString(),
              'photos': photos,
              'name': (row['name'] ?? 'Someone').toString(),
              'age': (row['age'] is int)
                  ? row['age']
                  : int.tryParse('${row['age']}') ?? 0,
              'bio': (row['bio'] ?? '').toString(),
              'is_online': row['is_online'] == true,
              'last_seen': row['last_seen'],
              'distance': (row['current_city'] ?? '').toString(),
            };
          })
          .where((m) {
            final id = m['potential_match_id']?.toString();
            return id != null && !already.contains(id);
          })
          .toList(growable: false);

      return _mergeIncoming(mapped,
          idKey: 'potential_match_id',
          photosKey: 'photos',
          distanceKey: 'distance');
    } catch (e) {
      debugPrint('Direct load error: $e');
      return 0;
    }
  }

  int _mergeIncoming(
    List<Map<String, dynamic>> rows, {
    required String idKey,
    required String photosKey,
    required String distanceKey,
  }) {
    if (rows.isEmpty) return 0;

    final normalized = rows
        .map((m) {
          final photos = (m[photosKey] is List)
              ? (m[photosKey] as List)
                  .map((e) => e?.toString() ?? '')
                  .where((s) => s.isNotEmpty)
                  .toList()
              : const <String>[];
          return {...m, photosKey: photos};
        })
        .toList();

    final before = _cards.length;
    setState(() => _cache.addAll(normalized));
    final after = _cards.length;

    return (after - before).clamp(0, normalized.length);
  }

  Future<List<String>> _alreadySwiped(String me) async {
    try {
      final rows = await _supa
          .from('swipes')
          .select('swipee_id')
          .eq('swiper_id', me)
          .eq('status', 'active');
      return (rows as List)
          .map((e) => (e as Map<String, dynamic>)['swipee_id']?.toString())
          .whereType<String>()
          .toList(growable: false);
    } catch (e) {
      debugPrint('already swiped error: $e');
      return const [];
    }
  }

  // ───────────────────────────── Swipes + Undo

  // Handle swipe IMMEDIATELY (no list mutation here).
  void _processSwipe({required int index, required SwipeDirection direction}) {
    if (index < 0 || index >= _cards.length) return;
    final data = _cards[index];
    final id = data['potential_match_id']?.toString() ?? '';
    if (id.isEmpty) return;

    final key = '$index|$id';
    if (_handled.contains(key)) return;
    _handled.add(key);

    final liked = direction == SwipeDirection.right;

    // Defer list removal to onSwipeCompleted to avoid early empty-state.
    _pendingIdByIndex[index] = id;

    // Snapshot for robust Undo.
    _undoMemory.set(id, liked, data);

    // Enqueue + attempt to persist (idempotent).
    _recordSwipe(swipeeId: id, liked: liked);

    if (liked) unawaited(_checkAndShowMatch(id));

    _history
      ..clear()
      ..add(_SwipeEvent(index: index, swipeeId: id, liked: liked));

    HapticFeedback.lightImpact();

    // Top-up using the post-swipe remaining count
    final remainingAfterThis = _cards.length - (index + 1);
    if (remainingAfterThis <= _topUpThreshold && !_cache.exhausted) {
      if (remainingAfterThis == 0 && mounted) {
        setState(() => _fetching = true); // prevent blank during refill
      }
      unawaited(_loadBatch(wanted: _topUpBatch));
    }

    // Precache next card's first image
    final next = index + 1;
    if (next < _cards.length) {
      final photos = (_cards[next]['photos'] as List?)?.cast<String>() ?? const [];
      if (photos.isNotEmpty) {
        unawaited(precacheImage(CachedNetworkImageProvider(photos.first), context));
      }
    }

    if (mounted) setState(() {});
  }

  Future<void> _recordSwipe({
    required String swipeeId,
    required bool liked,
  }) async {
    if (_inFlight.contains(swipeeId)) return;

    _cache.enqueuePending(swipeeId: swipeeId, liked: liked);

    _inFlight.add(swipeeId);
    try {
      final ok = await _sendSwipeToServer(swipeeId: swipeeId, liked: liked);
      if (ok) {
        _cache.removePending(swipeeId);
        _cache.swipedIds.add(swipeeId);
      }
    } catch (e) {
      debugPrint('recordSwipe error: $e');
    } finally {
      _inFlight.remove(swipeeId);
    }
  }

  Future<bool> _sendSwipeToServer({
    required String swipeeId,
    required bool liked,
  }) async {
    try {
      try {
        await _supa.rpc(_rpcHandleSwipe, params: {
          'swiper_id_arg': _supa.auth.currentUser?.id,
          'swipee_id_arg': swipeeId,
          'liked_arg': liked,
        });
      } catch (_) {
        await _supa.from('swipes').upsert(
          {
            'swiper_id': _supa.auth.currentUser?.id,
            'swipee_id': swipeeId,
            'liked': liked,
            'status': 'active',
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          },
          onConflict: 'swiper_id,swipee_id',
        );
      }
      return true;
    } catch (e) {
      debugPrint('sendSwipeToServer error: $e');
      return false;
    }
  }

  Future<void> _flushPendingOutbox() async {
    if (_cache.pendingCount == 0) return;
    final items = _cache.snapshotPending();
    for (final p in items) {
      if (_inFlight.contains(p.swipeeId)) continue;
      _inFlight.add(p.swipeeId);
      try {
        final ok = await _sendSwipeToServer(
          swipeeId: p.swipeeId,
          liked: p.liked,
        );
        if (ok) {
          _cache.removePending(p.swipeeId);
          _cache.swipedIds.add(p.swipeeId);
        }
      } catch (e) {
        debugPrint('flush pending error: $e');
      } finally {
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
        debugPrint('rewind err: $e');
      }
    }

    _handled.remove('${last.index}|${last.swipeeId}');

    // If removal hasn't happened yet, cancel the pending removal.
    final pendingIndex = _pendingIdByIndex.entries
        .firstWhere((e) => e.value == last.swipeeId, orElse: () => const MapEntry(-1, ''))
        .key;
    if (pendingIndex != -1) {
      _pendingIdByIndex.remove(pendingIndex);
    } else {
      // Already removed → reinsert from snapshot.
      final stillInList = _containsCardId(last.swipeeId);
      if (!stillInList && _undoMemory.card != null) {
        final at = (_stack.currentIndex < 0)
            ? 0
            : _stack.currentIndex.clamp(0, _cards.length).toInt();
        _cache.reinsertAt(_undoMemory.card!, index: at);
      }
    }

    _cache.removePending(last.swipeeId);
    unawaited(
      _supa
          .from('swipes')
          .delete()
          .match({'swiper_id': me, 'swipee_id': last.swipeeId})
          .catchError((e) => debugPrint('undo delete error: $e')),
    );

    _undoMemory.clear();

    HapticFeedback.selectionClick();
    if (mounted) setState(() {});
  }

  // Optional: mutual like overlay
  Future<void> _checkAndShowMatch(String otherUserId) async {
    if (_cache.matchOverlayShownFor.contains(otherUserId)) return;

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
        final lite = _ProfileLite(
          id: id,
          name: (m['name'] as String?)?.trim().isNotEmpty == true
              ? m['name'] as String
              : 'User',
          photoUrl: pics.isNotEmpty ? pics.first : null,
        );
        if (id == me) {
          meLite = lite;
        } else if (id == otherUserId) {
          otherLite = lite;
        }
      }

      if (!mounted || meLite == null || otherLite == null) return;

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
      debugPrint('check match error: $e');
    }
  }

  // ───────────────────────────── UI helpers

  void _openViewProfile(int index) {
    if (index < 0 || index >= _cards.length) return;
    final data = _cards[index];
    final userId = data['potential_match_id']?.toString();
    if (userId == null || userId.isEmpty) return;

    final photos = (data['photos'] as List?)?.cast<String>() ?? const <String>[];
    if (photos.isNotEmpty) {
      unawaited(
        precacheImage(CachedNetworkImageProvider(photos.first), context),
      );
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

  void _precachePhotos(Iterable<String> urls) {
    for (final u in urls) {
      if (u.isEmpty) continue;
      unawaited(precacheImage(CachedNetworkImageProvider(u), context));
    }
  }

  void _warmTopCard() {
    if (_cards.isEmpty || !_hasCurrentCard) return;
    final idx = _stack.currentIndex < 0 ? 0 : _stack.currentIndex;
    if (idx < 0 || idx >= _cards.length) return;
    final photos = (_cards[idx]['photos'] as List?)?.cast<String>() ?? const [];
    _precachePhotos(photos.take(3));
  }

  void _updateFinishedState() {
    if (_fetching) return;
    if (_cards.isEmpty && !_hasCurrentCard) {
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
      return _notLoggedIn();
    }

    return Column(
      children: [
        if (!_online) const _OfflineBanner(),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: _showSkeleton
                ? _SwipeSkeleton(centerAvatarUrl: _myPhoto)
                : (_showEmpty ? _emptyState() : _buildStackAndMeasure()),
          ),
        ),
        if (!_showSkeleton && !_showEmpty) _bottomBar(),
      ],
    );
  }

  Widget _notLoggedIn() {
    return const Center(
      child: Text('Please sign in to discover profiles',
          style: TextStyle(fontSize: 16)),
    );
  }

  Widget _emptyState() {
    return _OutOfPeoplePage(
      onSeeSwiped: _openSwipedSheet,
      onAdjustFilters: _openFiltersSheet,
    );
  }

  // Measures the card and saves width/height for the bottom bar.
  Widget _buildStackAndMeasure() {
    return LayoutBuilder(
      builder: (context, box) {
        final size = box.biggest;

        final double target = size.width * 0.94;
        final double cardW = target.clamp(280.0, 520.0).toDouble();
        final double cardH = size.height;

        if ((_lastCardW == null || (_lastCardW! - cardW).abs() > 0.5) ||
            (_lastCardH == null || (_lastCardH! - cardH).abs() > 0.5)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            setState(() {
              _lastCardW = cardW;
              _lastCardH = cardH;
            });
          });
        }

        if (_cards.isEmpty) return const SizedBox.shrink();

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
                if (id != null && id.isNotEmpty) {
                  _cache.consumeById(id);
                  _updateFinishedState();
                  if (mounted) setState(() {});
                }
              },

              itemCount: _cards.length,
              builder: (context, props) {
                final i = props.index;
                if (i >= _cards.length) return const SizedBox.shrink();

                final data = _cards[i];
                final userId = data['potential_match_id']?.toString() ?? 'row-$i';

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
  Widget _card(
      int index, Map<String, dynamic> data, double cardW, double cardH) {
    final String userId = (data['potential_match_id'] ?? '').toString();
    final String name = (data['name'] ?? 'Unknown').toString();
    final int age = (data['age'] is int)
        ? data['age'] as int
        : int.tryParse('${data['age']}') ?? 0;
    final String bio = (data['bio'] ?? '').toString();
    final String distance = (data['distance'] ?? '').toString();

    final List<String> photos =
        ((data['photos'] as List?)?.map((e) => e.toString()).toList() ??
            const <String>[]);

    _photoIndexById.putIfAbsent(userId, () => 0);
    final int maxIdx = photos.isEmpty ? 0 : photos.length - 1;
    final int currentIndex = (_photoIndexById[userId] ?? 0).clamp(0, maxIdx);
    final bool hasPhotos = photos.isNotEmpty;
    final String? currentPhoto = hasPhotos ? photos[currentIndex] : null;

    final bool onlineRealtime = _onlineUserIds.contains(userId);
    final bool isOnline = onlineRealtime || (data['is_online'] == true);

    final presence = _presenceInfo(
      isOnline: isOnline,
      lastSeenRaw: data['last_seen'],
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
                  if (next != currentIndex) {
                    unawaited(precacheImage(
                        CachedNetworkImageProvider(photos[next]), context));
                  }
                  if (prev != currentIndex) {
                    unawaited(precacheImage(
                        CachedNetworkImageProvider(photos[prev]), context));
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
                                      child: CachedNetworkImage(
                                        imageUrl: currentPhoto,
                                        fit: BoxFit.cover,
                                        fadeInDuration:
                                            const Duration(milliseconds: 80),
                                        errorWidget: (_, __, ___) =>
                                            const ColoredBox(
                                          color: Colors.black26,
                                          child: Center(
                                            child: Icon(
                                              Icons.broken_image,
                                              size: 36,
                                              color: Colors.white54,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  )
                                : Transform.scale(
                                    scale: 1.06,
                                    child: CachedNetworkImage(
                                      imageUrl: currentPhoto,
                                      fit: BoxFit.cover,
                                      fadeInDuration:
                                          const Duration(milliseconds: 80),
                                      errorWidget: (_, __, ___) =>
                                          const ColoredBox(
                                        color: Colors.black26,
                                        child: Center(
                                          child: Icon(
                                            Icons.broken_image,
                                            size: 36,
                                            color: Colors.white54,
                                          ),
                                        ),
                                      ),
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
              _roundAction(
                icon: Icons.rotate_left,
                color: _history.isEmpty ? Colors.white24 : Colors.green,
                size: btn,
                scale: 1,
                onTapDown: _history.isEmpty ? null : () {},
                onTapUp: _history.isEmpty ? null : () {},
                onTap: _history.isEmpty
                    ? null
                    : () {
                        HapticFeedback.lightImpact();
                        _undoLast();
                      },
              ),
              _roundAction(
                icon: Icons.cancel,
                color: Colors.red,
                size: btn,
                scale: 1,
                onTapDown: () {},
                onTapUp: () {},
                onTap: () {
                  _stack.next(swipeDirection: SwipeDirection.left);
                },
              ),
              _roundAction(
                icon: Icons.star,
                color: Colors.blue,
                size: bigBtn,
                scale: 1,
                onTapDown: () {},
                onTapUp: () {},
                onTap: () {
                  _openViewProfile(_stack.currentIndex);
                },
              ),
              _roundAction(
                icon: Icons.favorite,
                color: Colors.pink,
                size: btn,
                scale: 1,
                onTapDown: () {},
                onTapUp: () {},
                onTap: () {
                  _stack.next(swipeDirection: SwipeDirection.right);
                },
              ),
              _roundAction(
                icon: Icons.flash_on,
                color: Colors.purple,
                size: btn,
                scale: 1,
                onTapDown: () {},
                onTapUp: () {},
                onTap: () {
                  if (!mounted) return;
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

  Widget _roundAction({
    required IconData icon,
    required Color color,
    required double scale,
    required double size,
    required VoidCallback? onTap,
    VoidCallback? onTapDown,
    VoidCallback? onTapUp,
  }) {
    const Color bg = Color(0xFF1E1F24);
    return GestureDetector(
      onTap: onTap,
      onTapDown: onTapDown == null ? null : (_) => onTapDown(),
      onTapUp: onTapUp == null ? null : (_) => onTapUp(),
      onTapCancel: onTapUp,
      child: AnimatedScale(
        scale: scale,
        duration: const Duration(milliseconds: 100),
        child: SizedBox(
          width: size,
          height: size,
          child: DecoratedBox(
            decoration: const BoxDecoration(
              color: bg,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                    blurRadius: 10, color: Colors.black38, offset: Offset(0, 4)),
              ],
            ),
            child: Center(child: Icon(icon, color: color, size: size * 0.44)),
          ),
        ),
      ),
    );
  }

  // ───────────────────────────── Empty-state actions
  Future<void> _openFiltersSheet() async {
    String g = _prefGender;
    RangeValues ages = RangeValues(_prefAgeMin.toDouble(), _prefAgeMax.toDouble());
    double radius = _prefRadiusKm;
    if (!mounted) return;
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

    setState(() {
      _prefGender = gender;
      _prefAgeMin = ageMin;
      _prefAgeMax = ageMax;
      _prefRadiusKm = radiusKm;
    });

    try {
      await _supa.from('preferences').upsert({
        'user_id': me,
        'interested_in_gender': _prefGender,
        'age_min': _prefAgeMin,
        'age_max': _prefAgeMax,
        'distance_radius': _prefRadiusKm,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'user_id');
    } catch (e) {
      debugPrint('prefs upsert failed: $e');
    }

    final key = '$me|g=$_prefGender|a=$_prefAgeMin-$_prefAgeMax|r=$_prefRadiusKm';
    _cache.resetIfKeyChanged(key);

    setState(() {
      _initializing = true;
    });
    await _loadBatch(wanted: _initialBatch);
    if (mounted) setState(() => _initializing = false);
  }

  Future<void> _openSwipedSheet() async {
    final me = _supa.auth.currentUser?.id;
    if (me == null) return;

    List<Map<String, dynamic>> items = const [];
    try {
      final swipes = await _supa
          .from('swipes')
          .select('swipee_id, liked, updated_at')
          .eq('swiper_id', me)
          .eq('status', 'active')
          .order('updated_at', ascending: false)
          .limit(50);

      final ids = (swipes as List)
          .map((e) => (e as Map<String, dynamic>)['swipee_id']?.toString())
          .whereType<String>()
          .toList();

      if (ids.isNotEmpty) {
        final profs = await _supa
            .from('profiles')
            .select('user_id,name,profile_pictures')
            .inFilter('user_id', ids);
        final map = <String, Map<String, dynamic>>{
          for (final r in (profs as List))
            (r['user_id'] as String): (r as Map<String, dynamic>)
        };

        items = (swipes as List).map<Map<String, dynamic>>((e) {
          final m = e as Map<String, dynamic>;
          final id = m['swipee_id'] as String;
          final prof = map[id];
          final pics = (prof?['profile_pictures'] as List?)
                  ?.map((e) => e?.toString() ?? '')
                  .where((s) => s.isNotEmpty)
                  .toList() ??
              const <String>[];
          return {
            'id': id,
            'name': (prof?['name'] ?? 'User').toString(),
            'photo': pics.isNotEmpty ? pics.first : null,
            'liked': (m['liked'] == true),
            'at': m['updated_at'],
          };
        }).toList(growable: false);
      }
    } catch (e) {
      debugPrint('swiped sheet load failed: $e');
    }

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
                Center(
                  child: Container(
                    width: 44,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const Text('Your recent swipes',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 12),
                if (items.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('No history yet.',
                        style: TextStyle(color: Colors.white70)),
                  )
                else ...[
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 420),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: items.length,
                      separatorBuilder: (_, __) => const Divider(height: 10),
                      itemBuilder: (_, i) {
                        final it = items[i];
                        final liked = it['liked'] == true;
                        final photo = it['photo'] as String?;
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: CircleAvatar(
                            radius: 22,
                            backgroundImage: photo == null
                                ? null
                                : CachedNetworkImageProvider(photo),
                            child: photo == null
                                ? const Icon(Icons.person)
                                : null,
                          ),
                          title: Text(it['name'] as String),
                          subtitle: Text(liked ? 'Liked' : 'Passed'),
                          trailing: Icon(
                            liked ? Icons.favorite : Icons.block,
                            color: liked ? Colors.pink : Colors.white38,
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () {
                        Navigator.of(ctx).maybePop();
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const ChatListPage()),
                        );
                      },
                      child: const Text('Open Messages / Matches'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  // ───────────────────────────── Helpers
  bool _containsCardId(String id) {
    for (final m in _cards) {
      if ((m['potential_match_id']?.toString() ?? '') == id) return true;
    }
    return false;
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
class _SwipeSkeleton extends StatefulWidget {
  const _SwipeSkeleton({required this.centerAvatarUrl});
  final String? centerAvatarUrl;

  @override
  State<_SwipeSkeleton> createState() => _SwipeSkeletonState();
}

class _SwipeSkeletonState extends State<_SwipeSkeleton>
    with TickerProviderStateMixin {
  late final AnimationController _radar =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))
        ..repeat();
  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
        ..repeat(reverse: true);

  static const Color _brandPink = Color(0xFFFF0F7B);

  @override
  void dispose() {
    _radar.dispose();
    _pulse.dispose();
    super.dispose();
  }

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
            child: FadeTransition(
              opacity: _pulse.drive(Tween(begin: .55, end: 1.0)),
              child: const _SkeletonBar(height: 12, radius: 6),
            ),
          ),
          Positioned(
            left: 18,
            right: 140,
            bottom: 58,
            child: FadeTransition(
              opacity: _pulse.drive(Tween(begin: .55, end: 1.0)),
              child: const _SkeletonBar(height: 10, radius: 6),
            ),
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
                      _RadarRing(
                          controller: _radar,
                          delay: 0.00,
                          maxRadius: 140,
                          color: _brandPink),
                      _RadarRing(
                          controller: _radar,
                          delay: 0.25,
                          maxRadius: 140,
                          color: _brandPink),
                      _RadarRing(
                          controller: _radar,
                          delay: 0.50,
                          maxRadius: 140,
                          color: _brandPink),
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
                        child: (widget.centerAvatarUrl == null ||
                                widget.centerAvatarUrl!.isEmpty)
                            ? const Icon(Icons.person,
                                color: Colors.white70, size: 44)
                            : Image(
                                image: CachedNetworkImageProvider(
                                    widget.centerAvatarUrl!),
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

class _RadarRing extends StatelessWidget {
  const _RadarRing({
    required this.controller,
    required this.delay,
    required this.maxRadius,
    required this.color,
  });
  final AnimationController controller;
  final double delay; // 0..1 phase offset
  final double maxRadius;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: controller,
        builder: (_, __) {
          final t = ((controller.value + delay) % 1.0);
          final double r = 36.0 + (maxRadius - 36.0) * Curves.easeOut.transform(t);
          return Container(
            width: r,
            height: r,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: color.withValues(alpha: _kDefaultAlpha), width: 3),
            ),
          );
        },
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
  } catch (_) {
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
                    if (!context.mounted) return;
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
                    if (!context.mounted) return;
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
    return t.isEmpty ? 'U' : t[0].toUpperCase();
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
                image: CachedNetworkImageProvider(url!),
                fit: BoxFit.cover,
                onError: (_, __) {},
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
      builder: (_, child) {
        final s = 0.9 + 0.1 * (1 + math.sin(controller.value * math.pi * 2)) / 2;
        return Transform.translate(
          offset: Offset(dx, dy),
          child: Transform.scale(scale: s, child: child),
        );
      },
    );
  }
}