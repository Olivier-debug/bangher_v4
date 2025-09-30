// ─────────────────────────────────────────────────────────────────────────────
// lib/features/swipe/data/swipe_repository.dart
// Cursor/exhaustion aware repository with SingleFlight for top-up.
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../presentation/swipe_models.dart';
import 'swipe_api.dart' as rpc;

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

class FeedRepository {
  final rpc.SwipeApi swipeApi;
  final SupabaseClient supa;

  String? _cursorB64;
  bool _exhausted = false;
  final _single = SingleFlight<int>();

  FeedRepository({required this.swipeApi, required this.supa});

  String? get cursorB64 => _cursorB64;
  bool get exhausted => _exhausted;

  void reset() {
    _cursorB64 = null;
    _exhausted = false;
  }

  Future<Bootstrap> init({required String userId}) => swipeApi.initBootstrap(userId);

  Future<FeedPage> fetchFirst({
    required String userId,
    required Map<String, dynamic> prefs,
    String? afterCursorB64,
    int limit = 20,
  }) async {
    final first = await swipeApi.getFeed(
      userId: userId,
      prefs: prefs,
      afterCursorB64: afterCursorB64,
      limit: limit,
    );
    _cursorB64 = first.nextCursorB64;
    _exhausted = first.exhausted;
    return first;
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
      final page = await swipeApi
          .getFeed(
            userId: me,
            prefs: prefs,
            afterCursorB64: _cursorB64,
            limit: limit,
          )
          .timeout(const Duration(seconds: 10));
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
    return swipeApi.handleSwipeAtomic(swiperId: me, swipeeId: swipeeId, liked: liked);
  }

  Future<void> undo({required String swipeeId}) async {
    final me = supa.auth.currentUser?.id;
    if (me == null) throw StateError('Not authenticated');
    await swipeApi.undoSwipe(swiperId: me, swipeeId: swipeeId);
  }

  Future<void> flushBatch(List<({String swipeeId, bool liked})> batch) async {
    final me = supa.auth.currentUser?.id;
    if (me == null || batch.isEmpty) return;
    await swipeApi.handleSwipeBatch(swiperId: me, items: batch);
  }
}
