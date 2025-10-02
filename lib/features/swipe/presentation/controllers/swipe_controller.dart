// ============================================================================
// file: lib/features/swipe/presentation/controllers/swipe_controller.dart
// Persistent boot + cache topId; append-only; no head mutation.
// Adds: recordSwiped() + prune() for bounded memory.
// Exposes: flushOutboxNow() so callers can flush before global wipes.
// New: non-breaking swipeCardWithResult(...) returning SwipeResult?.
// Realtime: matchStream emits a MatchEvent when a NEW match appears.
// ============================================================================

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/swipe_repository.dart' as data;
import '../../data/swipe_feed_cache.dart';
import '../../data/swipe_api.dart' as rpc;
import '../../data/photo_resolver.dart';
import '../swipe_models.dart';
import '../../../matches/match_repository.dart' show MatchRepository, MatchThread;

int _swLogSeq2 = 0;
@pragma('vm:prefer-inline')
void swLog(String msg) {
  final now = DateTime.now();
  final ts =
      '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}.${now.millisecond.toString().padLeft(3, '0')}';
  final n = (++_swLogSeq2).toString().padLeft(4, '0');
  debugPrint('[CTRL $n $ts] $msg');
}

final swipeControllerProvider =
    StateNotifierProvider<SwipeController, SwipeUiState>((ref) {
  final supa = Supabase.instance.client;
  final apiClient = rpc.SwipeApi(supa);
  final feedRepo = data.FeedRepository(swipeApi: apiClient, supa: supa);
  return SwipeController(repo: feedRepo, cache: SwipeFeedCache.instance);
});

class SwipeController extends StateNotifier<SwipeUiState> {
  final data.FeedRepository repo;
  final SwipeFeedCache cache;
  final PhotoResolver _resolver;

  String? _cursorB64Snapshot;
  Timer? _flushTimer;

  bool _initialized = false;

  // ---- Realtime matches (minimal, non-breaking) -----------------------------
  final _matchSc = StreamController<MatchEvent>.broadcast();
  Stream<MatchEvent> get matchStream => _matchSc.stream;
  StreamSubscription<List<MatchThread>>? _matchSub;
  final Set<String> _knownMatchIds = <String>{};
  late final MatchRepository _matchRepo =
      MatchRepository(Supabase.instance.client);
  // --------------------------------------------------------------------------

  SwipeController({required this.repo, required this.cache})
      : _resolver =
            PhotoResolver(Supabase.instance.client, useSignedUrls: true),
        super(const SwipeUiState()) {
    _flushTimer =
        Timer.periodic(const Duration(seconds: 30), (_) => _flushOutbox());
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    _matchSub?.cancel();
    _matchSc.close();
    super.dispose();
  }

  Future<void> bootstrapIfNeeded() async {
    if (_initialized) return;
    await bootstrapAndFirstLoad();
  }

  Future<void> bootstrapAndFirstLoad() async {
    final me = repo.supa.auth.currentUser?.id;
    if (me == null) return;
    swLog('bootstrap: start');
    state = state.copyWith(fetching: true);
    try {
      final boot = await repo.init(userId: me);
      swLog(
          'bootstrap: boot ok swiped=${boot.swipedIds.length} cursor=${boot.cursorB64?.length ?? 0}');

      cache.swipedIds
        ..clear()
        ..addAll(boot.swipedIds);
      cache.applyUnswipeOverrides();

      repo.reset();
      _cursorB64Snapshot = boot.cursorB64;

      final page = await repo.fetchFirst(
        userId: me,
        prefs: boot.prefs,
        afterCursorB64: _cursorB64Snapshot,
      );
      _cursorB64Snapshot = page.nextCursorB64;
      swLog(
          'bootstrap: firstPage items=${page.items.length} exhausted=${page.exhausted}');

      final resolvedItems = await _resolveCards(page.items);
      final resolvedMyPhoto = await _resolveMaybe(boot.myPhoto);

      state = state.copyWith(
        fetching: false,
        exhausted: page.exhausted,
        cards: resolvedItems,
        myPhoto: resolvedMyPhoto,
      );
      _initialized = true;
      swLog(
          'bootstrap: setState cards=${state.cards.length} exhausted=${state.exhausted}');

      // Start realtime matches (instant "It's a match!" without polling)
      _startMatchRealtime(myId: me);
    } catch (e) {
      swLog('bootstrap: ERROR $e');
      state = state.copyWith(fetching: false);
    }
  }

  Future<void> topUpIfNeededCorrect({
    required Map<String, dynamic> prefs,
    int limit = 20,
  }) async {
    if (state.fetching || repo.exhausted) {
      swLog(
          'topUp: skip fetching=${state.fetching} repo.exhausted=${repo.exhausted}');
      return;
    }
    swLog('topUp: start limit=$limit curCards=${state.cards.length}');
    state = state.copyWith(fetching: true);
    try {
      final collected = <SwipeCard>[];
      await repo.topUp(
        prefs: prefs,
        limit: limit,
        onItems: (items) {
          swLog('topUp: page items=${items.length}');
          if (items.isEmpty) return;
          collected.addAll(items);
        },
      );
      if (collected.isNotEmpty) {
        final resolved = await _resolveCards(collected);
        state = state.copyWith(cards: [...state.cards, ...resolved]);
        swLog('topUp: appended -> cards=${state.cards.length}');
      }
      state = state.copyWith(fetching: false, exhausted: repo.exhausted);
      swLog(
          'topUp: done exhausted=${repo.exhausted} cards=${state.cards.length}');
    } catch (e) {
      swLog('topUp: ERROR $e');
      state = state.copyWith(fetching: false);
    }
  }

  /// Back-compatible API. Use [swipeCardWithResult] if you need match info.
  Future<void> swipeCard({
    required String swipeeId,
    required bool liked,
  }) async {
    await swipeCardWithResult(swipeeId: swipeeId, liked: liked);
  }

  /// New API: returns SwipeResult from backend (createdMatch, me, other).
  Future<SwipeResult?> swipeCardWithResult({
    required String swipeeId,
    required bool liked,
  }) async {
    swLog(
        'swipeCard: id=$swipeeId liked=$liked pendingBefore=${cache.pendingCount}');
    try {
      cache.enqueuePending(swipeeId: swipeeId, liked: liked);
      cache.recordSwiped(swipeeId); // why: prune bound and dedupe
      final result = await repo.swipe(swipeeId: swipeeId, liked: liked);
      cache.removePending(swipeeId);
      cache.removeUnswipeOverride(swipeeId);
      cache.prune(maxSwiped: 6000, maxPending: 512);
      swLog('swipeCard: ok pendingAfter=${cache.pendingCount}');
      // If your repo.swipe returns null/void, callers will get null and skip overlay.
      return result;
    } catch (e) {
      cache.prune(maxSwiped: 6000, maxPending: 512);
      swLog(
          'swipeCard: queued (retry later) err=$e pendingAfter=${cache.pendingCount}');
      return null;
    }
  }

  Future<void> undo({required String swipeeId}) async {
    swLog('undo: $swipeeId');
    try {
      await repo.undo(swipeeId: swipeeId);
      cache.removePending(swipeeId);
      cache.swipedIds.remove(swipeeId);
      cache.addUnswipeOverride(swipeeId);
      swLog('undo: ok');
    } catch (e) {
      swLog('undo: ERROR $e');
    }
  }

  /// Expose manual flush to avoid losing pending items during wipes.
  Future<void> flushOutboxNow() => _flushOutbox();

  Future<void> _flushOutbox() async {
    final items = cache.snapshotPending();
    if (items.isEmpty) return;
    swLog('outbox: flush ${items.length} items');
    try {
      await repo.flushBatch(items);
      for (final p in items) {
        cache.removePending(p.swipeeId);
      }
      cache.prune(maxSwiped: 6000, maxPending: 512);
      swLog('outbox: flushed ok left=${cache.pendingCount}');
    } catch (e) {
      swLog('outbox: flush ERROR $e');
    }
  }

  math.Random seededRngForKey(String feedKey) {
    final day = DateTime.now().toUtc().toIso8601String().substring(0, 10);
    final seed = ('$feedKey|$day').codeUnits.fold<int>(
      0,
      (a, b) => (a * 31 + b) & 0x7fffffff,
    );
    return math.Random(seed);
  }

  Future<List<SwipeCard>> _resolveCards(List<SwipeCard> raw) async {
    final out = <SwipeCard>[];
    for (final c in raw) {
      final sources =
          (c.rawPhotos?.isNotEmpty ?? false) ? c.rawPhotos! : c.photos;
      if (sources.isEmpty) {
        out.add(c);
        continue;
      }
      final resolved = await _resolver.resolveMany(sources);
      out.add(c.copyWith(photos: [for (final p in resolved) p.url]));
    }
    return out;
  }

  Future<String?> _resolveMaybe(String? raw) async {
    final rp = await _resolver.resolveMaybe(raw);
    return rp?.url;
  }

  void markTopCardId(String? id) {
    cache.lastTopCardId = id;
    swLog('markTopCardId: $id');
  }

  Future<void> markExhaustedIfDepleted({required int visibleCount}) async {
    swLog(
        'markExhaustedIfDepleted: visible=$visibleCount exhaustedBefore=${state.exhausted}');
    if (visibleCount == 0) {
      state = state.copyWith(exhausted: true);
      swLog('markExhaustedIfDepleted: exhaustedNow=${state.exhausted}');
    }
  }

  // -------------------- Realtime matches wiring ------------------------------
  void _startMatchRealtime({required String myId}) {
    _matchSub?.cancel(); // avoid duplicate listeners on hot reload
    // Listen to the full list and derive NEW matches client-side.
    _matchSub = _matchRepo.watchMyMatches(myId).listen(
      (threads) {
        if (threads.isEmpty) return;
        for (final t in threads) {
          final id = t.matchId;
          if (id == null || _knownMatchIds.contains(id)) continue;
          _knownMatchIds.add(id);
          final other = t.other;
          _matchSc.add(
            MatchEvent(
              matchId: id,
              meId: myId,
              otherId: other?.id ?? '',
              otherName: other?.name ?? 'New match',
              otherPhotoUrl: other?.photoUrl,
            ),
          );
          swLog('realtime: NEW match id=$id other=${other?.id}');
        }
      },
      onError: (err, st) => swLog('realtime: match error $err'),
    );
  }
  // --------------------------------------------------------------------------
}

/// Small event surfaced to UI for overlays.
class MatchEvent {
  final String matchId;
  final String meId;
  final String otherId;
  final String otherName;
  final String? otherPhotoUrl;
  const MatchEvent({
    required this.matchId,
    required this.meId,
    required this.otherId,
    required this.otherName,
    this.otherPhotoUrl,
  });
}
