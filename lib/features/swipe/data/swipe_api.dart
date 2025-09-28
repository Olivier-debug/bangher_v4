// ─────────────────────────────────────────────────────────────────────────────
// lib/features/swipe/data/swipe_api.dart
// Supabase RPC adapter with retry/backoff.
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../presentation/swipe_models.dart';

typedef _Task<T> = Future<T> Function();

@immutable
class RetryPolicyApi {
  final int maxAttempts;
  final Duration baseDelay;
  final Duration maxDelay;
  final Duration attemptTimeout;
  final double jitterFactor;
  final bool Function(Object error) shouldRetry;

  const RetryPolicyApi({
    this.maxAttempts = 4,
    this.baseDelay = const Duration(milliseconds: 250),
    this.maxDelay = const Duration(seconds: 5),
    this.attemptTimeout = const Duration(seconds: 15),
    this.jitterFactor = 0.25,
    this.shouldRetry = _defaultShouldRetry,
  });

  static bool _defaultShouldRetry(Object e) => true;
}

@immutable
class SwipeApi {
  final SupabaseClient _supa;
  final RetryPolicyApi _policy;
  final math.Random _rng = math.Random();

  SwipeApi(this._supa, {RetryPolicyApi? retryPolicy})
      : _policy = retryPolicy ?? const RetryPolicyApi();

  Future<Bootstrap> initBootstrap(String userId) async {
    return _runWithRetry(
      opName: 'init_swipe_bootstrap',
      task: () async {
        final res = await _supa.rpc('init_swipe_bootstrap', params: {'user_id_arg': userId});
        final row = _asSingleRow(res);
        return Bootstrap.fromJson(_castMap(row));
      },
    );
  }

  Future<FeedPage> getFeed({
    required String userId,
    required Map<String, dynamic> prefs,
    String? afterCursorB64,
    int limit = 20,
  }) async {
    return _runWithRetry(
      opName: 'get_feed',
      task: () async {
        final res = await _supa.rpc('get_feed', params: {
          'user_id_arg': userId,
          'prefs_arg': prefs,
          'after_arg': afterCursorB64,
          'limit_arg': limit,
        });
        final row = _asSingleRow(res);
        return FeedPage.fromJson(_castMap(row));
      },
    );
  }

  Future<SwipeResult> handleSwipeAtomic({
    required String swiperId,
    required String swipeeId,
    required bool liked,
  }) async {
    return _runWithRetry(
      opName: 'handle_swipe_atomic',
      task: () async {
        final res = await _supa.rpc('handle_swipe_atomic', params: {
          'swiper_id_arg': swiperId,
          'swipee_id_arg': swipeeId,
          'liked_arg': liked,
        });
        final row = _asSingleRowOrNull(res);
        return SwipeResult.fromJson(row == null ? null : _castMap(row));
      },
    );
  }

  Future<void> undoSwipe({
    required String swiperId,
    required String swipeeId,
  }) async {
    return _runWithRetry(
      opName: 'undo_swipe',
      task: () => _supa
          .rpc('undo_swipe', params: {
            'swiper_id_arg': swiperId,
            'swipee_id_arg': swipeeId,
          })
          .then((_) => null),
    );
  }

  Future<void> handleSwipeBatch({
    required String swiperId,
    required List<({String swipeeId, bool liked})> items,
  }) async {
    if (items.isEmpty) return;
    final payload = [
      for (final it in items) {'swipee_id': it.swipeeId, 'liked': it.liked}
    ];
    return _runWithRetry(
      opName: 'handle_swipe_batch',
      task: () => _supa
          .rpc('handle_swipe_batch', params: {
            'swiper_id_arg': swiperId,
            'items_arg': payload,
          })
          .then((_) => null),
    );
  }

  // retry core
  Future<T> _runWithRetry<T>({
    required String opName,
    required _Task<T> task,
  }) async {
    Object? lastErr;
    for (int attempt = 1; attempt <= _policy.maxAttempts; attempt++) {
      try {
        final v = await task().timeout(_policy.attemptTimeout);
        return v;
      } on Object catch (e, st) {
        lastErr = e;
        final more = attempt < _policy.maxAttempts;
        final canRetry = more && _policy.shouldRetry(e);
        if (!canRetry) Error.throwWithStackTrace(e, st);
        await Future.delayed(_nextDelay(attempt));
      }
    }
    throw lastErr ?? StateError('retry failed: $opName');
  }

  Duration _nextDelay(int attempt) {
    final baseMs = _policy.baseDelay.inMilliseconds;
    final exp = baseMs * math.pow(2, attempt - 1).toDouble();
    final capped = math.min<double>(exp, _policy.maxDelay.inMilliseconds.toDouble());
    final jitter = 1.0 + (_policy.jitterFactor * (_rng.nextDouble() * 2 - 1));
    final ms = (capped * jitter)
        .clamp(0, _policy.maxDelay.inMilliseconds.toDouble())
        .toInt();
    return Duration(milliseconds: ms);
  }

  static Map<String, dynamic> _castMap(Object obj) => (obj as Map).cast<String, dynamic>();

  static Object _asSingleRow(Object? res) {
    if (res == null) throw StateError('RPC returned null');
    if (res is List && res.isNotEmpty) return res.first;
    return res;
  }

  static Object? _asSingleRowOrNull(Object? res) {
    if (res == null) return null;
    if (res is List) return res.isEmpty ? null : res.first;
    return res;
  }
}


