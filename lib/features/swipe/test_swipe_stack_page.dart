// =========================
// FIXED FILE: lib/features/swipe/pages/test_swipe_stack_page.dart
// =========================
// Notes on this patch (keep these dev notes at the top):
// - Append-only session buffer in SwipeFeedCache (global) -> no removals,
//   no filtering, no reordering while the stack is mounted (prevents “skips”).
// - Initial load = 20 cards. Auto top-up by +20 when <= 5 remain (seamless).
// - Refetch only when preferences change: cache keyed by (user+prefs).
// - Undo persists across tab switches via _UndoMemory; reliable: rewinds,
//   removes DB row, clears local guards & swiped set.
// - On tab switch (page deactivate): compact cache by dropping already-swiped
//   cards (to keep memory lean) EXCEPT the most recent swiped card so undo works.
// - Strong de-dupe on merge against cache.ids + cache.swipedIds.
// - Per-user photo index keyed by userId to avoid “photo jumping”.
// - Presence, match overlay, and image pre-warm preserved.
// - NEW: Swipes are registered immediately in onWillMoveNext (no animation delay).

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

// Public profile page (for expanded view)
import '../../profile/pages/view_profile_page.dart';
// Chat list destination
import '../../matches/chat_list_page.dart';

// Global cache singleton (persists across pages)
import '../../swipe/data/swipe_feed_cache.dart';

/// Single-level undo memory that survives page/tab switches.
/// We keep the id + liked + when. (We don't need the full card because we
/// keep the last card in the cache during compaction.)
class _UndoMemory {
  String? id;
  bool liked = false;
  DateTime? at;

  bool get has => id != null;
  void set(String id, bool liked) {
    this.id = id;
    this.liked = liked;
    at = DateTime.now();
  }

  void clear() {
    id = null;
    at = null;
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
  static const _presenceChannel = 'Online';

  // Batch + top-up policy
  static const int _initialBatch = 20;
  static const int _topUpBatch = 20;
  static const int _topUpThreshold = 5; // when <= 5 remain, fetch more

  // ─────────────────────────────── Services
  final SupabaseClient _supa = Supabase.instance.client;
  final SwipableStackController _stack = SwipableStackController();

  // ─────────────────────────────── Global cache
  final SwipeFeedCache _cache = SwipeFeedCache.instance;

  // Per-USER photo index (stable across list growth)
  final Map<String, int> _photoIndexById = <String, int>{};

  // Swipe bookkeeping (page-local guards)
  final Set<String> _inFlight = <String>{};
  final Set<String> _handled = <String>{}; // "$index|$userId"
  final List<_SwipeEvent> _history = <_SwipeEvent>[];

  // Presence
  RealtimeChannel? _presence;
  final Set<String> _onlineUserIds = <String>{};

  // UI state
  bool _fetching = false;    // network guard
  bool _initializing = true; // first load gating the skeleton
  bool _online = true;

  // Prefs (minimal)
  String _prefGender = 'F';
  int _prefAgeMin = 18;
  int _prefAgeMax = 60;
  double _prefRadiusKm = 50.0;

  // Connectivity
  StreamSubscription<List<ConnectivityResult>>? _connSub;

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

    // Track current index to persist it (optional restore later)
    _stack.addListener(() {
      _cache.lastStackIndex = _stack.currentIndex;
    });

    _bootstrap();
  }

  // Compact swiped profiles on tab switch (but KEEP the last swiped for undo).
  @override
  void deactivate() {
    super.deactivate();
    _compactSwipedExceptLast();
  }

  void _compactSwipedExceptLast() {
    if (_cache.cards.isEmpty || _cache.swipedIds.isEmpty) return;
    final except = _undoMemory.id;
    _cache.cards.removeWhere((m) {
      final id = m['potential_match_id']?.toString();
      if (id == null) return false;
      if (id == except) return false; // keep last swiped for undo
      return _cache.swipedIds.contains(id);
    });
    // _cache._idSet remains populated to keep strong de-dupe.
  }

  Future<void> _bootstrap() async {
    final ok = await _ensureConnectivity();
    if (mounted) setState(() => _online = ok);
    _listenConnectivity();
    await _startPresence();
    await _loadMyPhoto();

    // Load prefs and set cache key; only reset cache when prefs changed.
    await _loadPreferences();
    final me = _supa.auth.currentUser?.id;
    if (me != null) {
      final key = '$me|g=$_prefGender|a=$_prefAgeMin-$_prefAgeMax|r=$_prefRadiusKm';
      _cache.resetIfKeyChanged(key);
    }

    // If cache already has data, use it; else fetch initial 20.
    if (_cards.isEmpty) {
      setState(() => _initializing = true);
      await _loadBatch(wanted: _initialBatch);
      if (mounted) setState(() => _initializing = false);
    } else {
      setState(() => _initializing = false);
      if (_cardsLeft() <= _topUpThreshold && !_cache.exhausted) {
        unawaited(_loadBatch(wanted: _topUpBatch));
      }
      _warmTopCard();
    }

    // Restore Undo button enablement across tab switches
    if (_undoMemory.has) {
      _history
        ..clear()
        ..add(_SwipeEvent(
          index: (_stack.currentIndex < 0) ? 0 : _stack.currentIndex,
          swipeeId: _undoMemory.id!,
          liked: _undoMemory.liked,
        ));
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _connSub?.cancel();
    _presence?.unsubscribe();
    _stack.dispose();
    super.dispose();
  }

  // ───────────────────────────── Derived helpers
  int _cardsLeft() {
    final consumed = _stack.currentIndex + 1; // -1 => 0
    final left = _cards.length - consumed;
    return left <= 0 ? 0 : left;
  }

  bool get _showSkeleton => _initializing && _cards.isEmpty;
  bool get _showEmpty => !_initializing && _cache.exhausted && _cardsLeft() == 0;

  // ───────────────────────────── Connectivity
  void _listenConnectivity() {
    _connSub = Connectivity().onConnectivityChanged.listen((_) async {
      final ok = await _ensureConnectivity();
      if (mounted) setState(() => _online = ok);
    });
  }

  Future<bool> _ensureConnectivity() async {
    try {
      final result = await Connectivity().checkConnectivity();
      if (result.contains(ConnectivityResult.none)) return false;
      if (!kIsWeb) {
        final sw = Stopwatch()..start();
        final socket = await Socket.connect('8.8.8.8', 53,
            timeout: const Duration(milliseconds: 900));
        socket.destroy();
        if (sw.elapsedMilliseconds >= 3000) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  // ───────────────────────────── Presence (v2 API)
  Future<void> _startPresence() async {
    final me = _supa.auth.currentUser?.id;
    if (me == null) return;

    await _presence?.unsubscribe();
    final ch = _supa.channel(_presenceChannel,
        opts: const RealtimeChannelConfig(self: true));

    ch
        .onPresenceSync((_) {
          final states = ch.presenceState();
          _onlineUserIds
            ..clear()
            ..addAll(states
                .expand((s) => s.presences)
                .map((p) => p.payload['user_id']?.toString())
                .whereType<String>());
          if (mounted) setState(() {});
        })
        .onPresenceJoin((payload) {
          for (final p in payload.newPresences) {
            final id = p.payload['user_id']?.toString();
            if (id != null) _onlineUserIds.add(id);
          }
          if (mounted) setState(() {});
        })
        .onPresenceLeave((payload) {
          for (final p in payload.leftPresences) {
            final id = p.payload['user_id']?.toString();
            if (id != null) _onlineUserIds.remove(id);
          }
          if (mounted) setState(() {});
        })
        .subscribe((status, error) async {
          if (status == RealtimeSubscribeStatus.subscribed) {
            await ch.track({
              'user_id': me,
              'online_at': DateTime.now().toUtc().toIso8601String(),
            });
          }
        });

    _presence = ch;
  }

  // ───────────────────────────── My avatar (for skeleton center)
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

  // ───────────────────────────── Data Loading (RPC → direct fallback)
  Future<int> _loadBatch({required int wanted}) async {
    if (_fetching) return 0;
    setState(() => _fetching = true);

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
          if (added > 0) {
            _cache.exhausted = false;
          } else if (_cardsLeft() == 0) {
            _cache.exhausted = true;
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

      _cache.rpcOffset += limit; // always advance to avoid re-fetching same rows
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

    // Normalize + collect, then pass through cache.addAll for strong de-dupe.
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

  // NEW: Handle swipe IMMEDIATELY (called from onWillMoveNext)
  void _processSwipe({required int index, required SwipeDirection direction}) {
    if (index < 0 || index >= _cards.length) return;
    final data = _cards[index];
    final id = data['potential_match_id']?.toString() ?? '';
    if (id.isEmpty) return;

    final key = '$index|$id';
    if (_handled.contains(key)) return;
    _handled.add(key);

    final liked = direction == SwipeDirection.right;

    // Persist (idempotent + race-safe)
    unawaited(_recordSwipe(swipeeId: id, liked: liked));

    // Optional: match overlay
    if (liked) unawaited(_checkAndShowMatch(id));

    // Single-level undo (page-local + cross-tab memory)
    _history
      ..clear()
      ..add(_SwipeEvent(index: index, swipeeId: id, liked: liked));
    _undoMemory.set(id, liked);

    HapticFeedback.lightImpact();

    // Top-up using the *post-swipe* remaining count (index + 1 consumed)
    final remainingAfterThis = _cards.length - (index + 1);
    if (remainingAfterThis <= _topUpThreshold && !_cache.exhausted) {
      unawaited(_loadBatch(wanted: _topUpBatch));
    }

    // Precache next card's first image
    final next = index + 1;
    if (next < _cards.length) {
      final photos =
          (_cards[next]['photos'] as List?)?.cast<String>() ?? const [];
      if (photos.isNotEmpty) {
        unawaited(
            precacheImage(CachedNetworkImageProvider(photos.first), context));
      }
    }

    // Refresh bottom bar undo state now (no wait for animation)
    if (mounted) setState(() {});
  }

  Future<void> _recordSwipe({
    required String swipeeId,
    required bool liked,
  }) async {
    if (_inFlight.contains(swipeeId)) return;
    _inFlight.add(swipeeId);
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
      _cache.swipedIds.add(swipeeId); // de-dupe future merges
    } catch (e) {
      debugPrint('recordSwipe error: $e');
    } finally {
      _inFlight.remove(swipeeId);
    }
  }

  Future<void> _undoLast() async {
    if (_history.isEmpty) return;
    final last = _history.removeLast();
    final me = _supa.auth.currentUser?.id;
    if (me == null) return;

    // Rewind (the card is still present; we don't remove while mounted).
    if (_stack.canRewind) {
      try {
        _stack.rewind();
      } catch (e) {
        debugPrint('rewind err: $e');
      }
    }

    // Allow re-swipe for that index+id
    _handled.remove('${last.index}|${last.swipeeId}');
    // Let future merges include this id (if server sends it again)
    _cache.swipedIds.remove(last.swipeeId);

    // Delete the swipe row (best-effort)
    unawaited(
      _supa
          .from('swipes')
          .delete()
          .match({'swiper_id': me, 'swipee_id': last.swipeeId})
          .catchError((e) => debugPrint('undo delete error: $e')),
    );

    // Clear global undo memory
    _undoMemory.clear();

    HapticFeedback.selectionClick();
    setState(() {});
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

    final photos =
        (data['photos'] as List?)?.cast<String>() ?? const <String>[];
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
    if (_cards.isEmpty) return;
    final idx = (_stack.currentIndex < 0) ? 0 : _stack.currentIndex;
    if (idx < 0 || idx >= _cards.length) return;
    final photos =
        (_cards[idx]['photos'] as List?)?.cast<String>() ?? const [];
    _precachePhotos(photos.take(3));
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
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.verified_rounded, size: 64, color: Color(0xFF6759FF)),
          SizedBox(height: 10),
          Text("You're all caught up",
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 20)),
          SizedBox(height: 6),
          Text('Check back later for more profiles.',
              style: TextStyle(color: Colors.white70)),
        ],
      ),
    );
  }

  // Measures the card and saves width/height for the bottom bar.
  Widget _buildStackAndMeasure() {
    return LayoutBuilder(
      builder: (context, box) {
        final size = box.biggest;

        final double hMargin = 4.0;
        final double maxW = size.width - hMargin * 2;
        final double maxH = size.height;

        final double cardW = maxW;
        final double cardH = maxH;

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

        return Stack(
          children: [
            SwipableStack(
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
                final double o =
                    p.isNaN ? 0.0 : p.clamp(0.0, 1.0).toDouble();
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

              // NEW: Register the swipe immediately here (no 1-card/animation delay).
              onWillMoveNext: (index, direction) {
                if (direction == SwipeDirection.up) {
                  _openViewProfile(index);
                  HapticFeedback.selectionClick();
                  return false; // intercept: open full profile instead of like
                }

                // Left / Right → process immediately
                _processSwipe(index: index, direction: direction);
                return true;
              },

              // Kept for safety; we already handled the swipe in onWillMoveNext.
              onSwipeCompleted: (index, direction) {
                // no-op (prefetch/top-up already done in _processSwipe)
              },

              itemCount: _cards.length,
              builder: (context, props) {
                final i = props.index;
                if (i >= _cards.length) return const SizedBox.shrink();

                final data = _cards[i];
                final userId = data['potential_match_id']?.toString() ?? 'row-$i';

                // Stable identity → no photo jumping
                return KeyedSubtree(
                  key: ValueKey(userId),
                  child: _card(i, data, cardW, cardH),
                );
              },
            ),
          ],
        );
      },
    );
  }

  // Card with left/right photo tap, dots top, gradient info bottom
  Widget _card(int index, Map<String, dynamic> data, double cardW, double cardH) {
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

    final bool isOnline =
        _onlineUserIds.contains(userId) || (data['is_online'] == true);

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
                      final next = currentIndex + (isRight ? 1 : -1);
                      final clamped = next.clamp(0, maxIdx).toInt();
                      _photoIndexById[userId] = clamped;
                    });
                  },
                  onLongPress: () => _openViewProfile(index), // open this card
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: currentPhoto == null
                            ? const ColoredBox(color: Colors.black26)
                            : (isTopCard
                                ? Hero(
                                    tag: 'public_profile_photo_0',
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
                                margin:
                                    const EdgeInsets.symmetric(horizontal: 3),
                                width: 9,
                                height: 9,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: dot == currentIndex
                                      ? Colors.pink
                                      : Colors.grey.withValues(alpha: 0.5),
                                ),
                              ),
                            ),
                          ),
                        ),

                      // Presence dot
                      if (isOnline)
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
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: InkWell(
                          onTap: () => _openViewProfile(index), // tap name
                          child: Container(
                            padding:
                                const EdgeInsets.fromLTRB(14, 12, 14, 14),
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
                                if (distance.isNotEmpty) ...[
                                  const SizedBox(height: 6),
                                  Text(
                                    distance,
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 16,
                                    ),
                                  ),
                                ],
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

  // Width ties to cardW - 10. Buttons lowered (no overlap) + safe-area padding.
  Widget _bottomBar() {
    final cardW = (_lastCardW ?? MediaQuery.of(context).size.width - 24);

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
          width: (cardW - 8).clamp(220, double.infinity),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _roundAction(
                icon: Icons.rotate_left, // single-level undo
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
        color: Colors.red.withValues(alpha: .15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.red.withValues(alpha: .3)),
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

// ───────────────────────────── Loading Skeleton (with avatar + pink radar)
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
    final outline = Theme.of(context).dividerColor.withValues(alpha: 0.20);
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
                        color: Colors.white.withValues(alpha: 0.95),
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
          final double r =
              36.0 + (maxRadius - 36.0) * Curves.easeOut.transform(t);
          final double a = (0.35 + 0.35 * (1.0 - t)).clamp(0.0, 0.70);
          return Container(
            width: r,
            height: r,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: color.withValues(alpha: a), width: 3),
            ),
          );
        },
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
  const _ProfileLite(
      {required this.id, required this.name, required this.photoUrl});
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
      barrierColor: Colors.black.withValues(alpha: 0.75),
      pageBuilder: (_, __, ___) => Center(
        child: _MatchOverlay(
            me: me, other: other, onMessage: onMessage, onDismiss: onDismiss),
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
    _pulse1 = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1200))
      ..repeat(reverse: true);
    _pulse2 = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1400))
      ..repeat(reverse: true);
    _pulse3 = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1600))
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
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 24,
                offset: Offset(0, 16)),
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
                    _PulsingHeart(
                        controller: _pulse1,
                        size: 60,
                        dx: -120,
                        dy: -140,
                        color: primary),
                    _PulsingHeart(
                        controller: _pulse2,
                        size: 40,
                        dx: 120,
                        dy: -120,
                        color: primary),
                    _PulsingHeart(
                        controller: _pulse3,
                        size: 50,
                        dx: -100,
                        dy: 140,
                        color: primary),
                    Align(
                      alignment: const Alignment(1, -0.4),
                      child: Transform.rotate(
                        angle: 10 * (math.pi / 180),
                        child: _PicCard(
                            url: widget.me.photoUrl,
                            fallbackLetter: _firstLetter(widget.me.name)),
                      ),
                    ),
                    Align(
                      alignment: const Alignment(-1, 0.6),
                      child: Transform.rotate(
                        angle: -10 * (math.pi / 180),
                        child: _PicCard(
                            url: widget.other.photoUrl,
                            fallbackLetter: _firstLetter(widget.other.name)),
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
                                color: Colors.black.withValues(alpha: .25),
                                blurRadius: 10)
                          ],
                          border: Border.all(color: outline),
                        ),
                        child:
                            const Icon(Icons.favorite, size: 22, color: primary),
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
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () {
                    Navigator.of(context).maybePop();
                    widget.onMessage?.call();
                  },
                  child: const Text('Say Hello',
                      style: TextStyle(color: Colors.white, fontSize: 16)),
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
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () {
                    Navigator.of(context).maybePop();
                    widget.onDismiss?.call();
                  },
                  child: const Text('Keep swiping',
                      style: TextStyle(fontSize: 16)),
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
              color: Colors.black.withValues(alpha: .25),
              blurRadius: 12,
              offset: Offset(0, 8))
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
                    fontWeight: FontWeight.w700),
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
                color: Colors.black.withValues(alpha: .25), blurRadius: 10)
          ],
        ),
        child: Icon(Icons.favorite, color: color, size: size * 0.6),
      ),
      builder: (_, child) {
        final s = 0.9 +
            0.1 * (1 + math.sin(controller.value * math.pi * 2)) / 2;
        return Transform.translate(
          offset: Offset(dx, dy),
          child: Transform.scale(scale: s, child: child),
        );
      },
    );
  }
}
