// ─────────────────────────────────────────────────────────────────────────────
// lib/features/swipe/presentation/controllers/swipe_controller.dart
// + Reinsert API for Undo that survives trimming & navigation.
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:async';
import 'dart:math' as math;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../data/swipe_repository.dart' as data;
import '../../data/swipe_feed_cache.dart';
import '../../data/swipe_api.dart' as rpc; // kept for parity; safe if unused
import '../../data/photo_resolver.dart';
import '../swipe_models.dart';

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

  SwipeController({required this.repo, required this.cache})
      : _resolver = PhotoResolver(Supabase.instance.client, useSignedUrls: true),
        super(const SwipeUiState()) {
    // why: ensure pending swipes are flushed regularly without blocking UI
    _flushTimer = Timer.periodic(const Duration(seconds: 30), (_) => _flushOutbox());
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    super.dispose();
  }

  Future<void> bootstrapAndFirstLoad() async {
    final me = repo.supa.auth.currentUser?.id;
    if (me == null) return;
    state = state.copyWith(fetching: true);
    try {
      final boot = await repo.init(userId: me);

      cache.swipedIds
        ..clear()
        ..addAll(boot.swipedIds);

      repo.reset();
      _cursorB64Snapshot = boot.cursorB64;

      final page = await repo.fetchFirst(
        userId: me,
        prefs: boot.prefs,
        afterCursorB64: _cursorB64Snapshot,
      );
      _cursorB64Snapshot = page.nextCursorB64;

      final resolvedItems = await _resolveCards(page.items);
      final resolvedMyPhoto = await _resolveMaybe(boot.myPhoto);

      state = state.copyWith(
        fetching: false,
        exhausted: page.exhausted,
        cards: resolvedItems,
        myPhoto: resolvedMyPhoto,
      );
    } catch (_) {
      state = state.copyWith(fetching: false);
    }
  }

  Future<void> topUpIfNeededCorrect({
    required Map<String, dynamic> prefs,
    int limit = 20,
  }) async {
    if (state.fetching || repo.exhausted) return;
    state = state.copyWith(fetching: true);
    try {
      final collected = <SwipeCard>[];
      await repo.topUp(
        prefs: prefs,
        limit: limit,
        onItems: (items) {
          if (items.isEmpty) return;
          collected.addAll(items);
        },
      );
      if (collected.isNotEmpty) {
        final resolved = await _resolveCards(collected);
        state = state.copyWith(cards: [...state.cards, ...resolved]);
      }
      state = state.copyWith(fetching: false, exhausted: repo.exhausted);
    } catch (_) {
      state = state.copyWith(fetching: false);
    }
  }

  Future<void> topUpIfNeeded({
    required Map<String, dynamic> prefs,
    int limit = 20,
  }) =>
      topUpIfNeededCorrect(prefs: prefs, limit: limit);

  Future<void> swipeCard({
    required String swipeeId,
    required bool liked,
  }) async {
    try {
      cache.enqueuePending(swipeeId: swipeeId, liked: liked);
      await repo.swipe(swipeeId: swipeeId, liked: liked);
      cache.removePending(swipeeId);
    } catch (_) {
      // why: keep in pending for periodic flush retries
    }
  }

  Future<void> undo({required String swipeeId}) async {
    try {
      await repo.undo(swipeeId: swipeeId);
      cache.removePending(swipeeId);
      cache.swipedIds.remove(swipeeId);
    } catch (_) {}
  }

  Future<void> _flushOutbox() async {
    final items = cache.snapshotPending();
    if (items.isEmpty) return;
    final batch = <({String swipeeId, bool liked})>[
      for (final p in items) (swipeeId: p.swipeeId, liked: p.liked)
    ];
    try {
      await repo.flushBatch(batch);
      for (final p in items) {
        cache.removePending(p.swipeeId);
      }
    } catch (_) {}
  }

  void trimFront({required int count}) {
    if (count <= 0 || state.cards.isEmpty) return;
    final int n = count.clamp(0, state.cards.length).toInt();
    final remaining = state.cards.sublist(n);
    state = state.copyWith(cards: remaining);
  }

  // why: reinsert a card for Undo after we trimmed or navigated away.
  void reinsertForUndo(SwipeCard card, {required int index}) {
    final next = [...state.cards];
    final existing = next.indexWhere((c) => c.id == card.id);
    if (existing >= 0) next.removeAt(existing);
    final safeIndex = index.clamp(0, next.length);
    next.insert(safeIndex, card);
    cache.swipedIds.remove(card.id);
    state = state.copyWith(cards: next);
  }

  math.Random seededRngForKey(String feedKey) {
    final day = DateTime.now().toUtc().toIso8601String().substring(0, 10);
    final seed = ('$feedKey|$day').codeUnits.fold<int>(
      0,
      (a, b) => (a * 31 + b) & 0x7fffffff,
    );
    return math.Random(seed);
  }

  // photo resolution helpers
  Future<List<SwipeCard>> _resolveCards(List<SwipeCard> raw) async {
    final out = <SwipeCard>[];
    for (final c in raw) {
      final sources = (c.rawPhotos?.isNotEmpty ?? false) ? c.rawPhotos! : c.photos;
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

  Future<void> refreshPhoto({required String cardId, required int photoIndex}) async {
    final i = state.cards.indexWhere((c) => c.id == cardId);
    if (i < 0) return;
    final card = state.cards[i];
    final raws = (card.rawPhotos?.isNotEmpty ?? false) ? card.rawPhotos! : card.photos;
    if (photoIndex < 0 || photoIndex >= raws.length) return;

    try {
      final fresh = await _resolver.refresh(raws[photoIndex]);
      final newPhotos = List<String>.from(card.photos);
      newPhotos[photoIndex] = fresh.url;

      final updated = card.copyWith(photos: newPhotos);
      final next = [...state.cards];
      next[i] = updated;
      state = state.copyWith(cards: next);
    } catch (_) {
      // swallow
    }
  }
}
