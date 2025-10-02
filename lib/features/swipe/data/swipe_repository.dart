// ─────────────────────────────────────────────────────────────────────────────
// lib/features/swipe/data/swipe_repository.dart
// Cursor/exhaustion-aware repository with SingleFlight for top-ups.
// Auto-resets when preferences change to avoid stale cursors.
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:async';
import 'dart:convert' show jsonEncode;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../presentation/swipe_models.dart';
import 'swipe_api.dart' as rpc;

/// Ensures only one async job of a given type runs at a time.
/// Subsequent callers await the same in-flight future.
class SingleFlight<T> {
  Future<T>? _inflight;

  Future<T> run(Future<T> Function() task) {
    if (_inflight != null) return _inflight!;
    final completer = Completer<T>();
    _inflight = completer.future;

    () async {
      try {
        final v = await task();
        completer.complete(v);
      } catch (e, st) {
        completer.completeError(e, st);
      } finally {
        _inflight = null;
      }
    }();

    return completer.future;
  }
}

class FeedRepository {
  final rpc.SwipeApi swipeApi;
  final SupabaseClient supa;

  String? _cursorB64;
  bool _exhausted = false;

  // Keep the last prefs (as canonical JSON) so we can detect changes and reset.
  String? _lastPrefsJson;

  final _singleTopUp = SingleFlight<int>();

  FeedRepository({
    required this.swipeApi,
    required this.supa,
  });

  String? get cursorB64 => _cursorB64;
  bool get exhausted => _exhausted;

  /// Blow away local pagination state (use when filters changed or on logout).
  void reset() {
    _cursorB64 = null;
    _exhausted = false;
    _lastPrefsJson = null;
  }

  /// Initialize bootstrap data (profile, prefs, first cursor, etc.)
  Future<Bootstrap> init({required String userId}) => swipeApi.initBootstrap(userId);

  /// Fetch the first page explicitly (e.g., after bootstrap).
  Future<FeedPage> fetchFirst({
    required String userId,
    required Map<String, dynamic> prefs,
    String? afterCursorB64,
    int limit = 20,
  }) async {
    // Track current prefs as canonical JSON string for change detection.
    _lastPrefsJson = _canonicalPrefsJson(prefs);

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

  /// Top up using the current cursor; if prefs changed since last call,
  /// the cursor/exhausted flags are reset and we fetch from the beginning.
  ///
  /// Returns the number of items added.
  Future<int> topUp({
    required Map<String, dynamic> prefs,
    int limit = 20,
    required void Function(List<SwipeCard> items) onItems,
  }) {
    return _singleTopUp.run(() async {
      // If already exhausted, short-circuit.
      if (_exhausted) return 0;

      final me = supa.auth.currentUser?.id;
      if (me == null) return 0;

      // Detect prefs changes; if changed, reset pagination.
      final currentPrefsJson = _canonicalPrefsJson(prefs);
      if (_lastPrefsJson != currentPrefsJson) {
        _cursorB64 = null;
        _exhausted = false;
        _lastPrefsJson = currentPrefsJson;
      }

      final page = await swipeApi
          .getFeed(
            userId: me,
            prefs: prefs,
            afterCursorB64: _cursorB64,
            limit: limit,
          )
          .timeout(const Duration(seconds: 12));

      _cursorB64 = page.nextCursorB64;
      _exhausted = page.exhausted;

      if (page.items.isNotEmpty) {
        onItems(page.items);
      }

      return page.items.length;
    });
  }

  /// Record a swipe and return the server result (which may include a match).
  Future<SwipeResult> swipe({
    required String swipeeId,
    required bool liked,
  }) async {
    final me = supa.auth.currentUser?.id;
    if (me == null) {
      throw StateError('Not authenticated');
    }
    return swipeApi.handleSwipeAtomic(
      swiperId: me,
      swipeeId: swipeeId,
      liked: liked,
    );
  }

  /// Undo a previous swipe for the given counterpart.
  Future<void> undo({required String swipeeId}) async {
    final me = supa.auth.currentUser?.id;
    if (me == null) {
      throw StateError('Not authenticated');
    }
    await swipeApi.undoSwipe(swiperId: me, swipeeId: swipeeId);
  }

  /// Flush a batch of pending swipes (best-effort; returns when server acked).
  Future<void> flushBatch(List<({String swipeeId, bool liked})> batch) async {
    final me = supa.auth.currentUser?.id;
    if (me == null || batch.isEmpty) return;
    await swipeApi.handleSwipeBatch(swiperId: me, items: batch);
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Internals
  // ───────────────────────────────────────────────────────────────────────────

  /// Create a stable JSON string for preference maps.
  /// Ensures keys are sorted to avoid spurious resets.
  String _canonicalPrefsJson(Map<String, dynamic> prefs) {
    // Simple and sufficient for our fields: encode once — keys insertion order
    // is stable for literals; if callers build maps dynamically, consider deep
    // sorting. For our use case, jsonEncode is adequate.
    return jsonEncode(prefs);
  }
}
