// ─────────────────────────────────────────────────────────────────────────────
// file: lib/features/swipe/data/swipe_feed_cache.dart
// + Global undo store (last item only) to persist across navigation.
// + Unswipe overrides to survive bootstrap resets.
// + Track lastTopCardId for position persistence.
// + Pruning & compaction to keep memory light.
// + Explicit cache-wiper hook init; controllable wipeAll keepPending flag.
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:collection';
import '../../../core/cache_wiper.dart';

@pragma('vm:prefer-inline')
String _idFromMap(Map<String, dynamic> m) =>
    (m['potential_match_id'] ?? m['user_id'] ?? '').toString();

// ─────────────────────────────────────────────────────────────────────────────

class _PendingSwipe {
  final String swipeeId;
  final bool liked;
  final int ts; // epoch millis (for recency)
  const _PendingSwipe(this.swipeeId, this.liked, this.ts);
}

class SwipeUndoStore {
  SwipeUndoStore._();
  static final SwipeUndoStore instance = SwipeUndoStore._();

  Map<String, dynamic>? _lastCardMap;
  int _lastIndex = 0;

  bool get has => _lastCardMap != null;

  void push({required Map<String, dynamic> cardMap, required int index}) {
    _lastCardMap = Map<String, dynamic>.from(cardMap);
    _lastIndex = index;
  }

  ({Map<String, dynamic> cardMap, int index})? take() {
    if (_lastCardMap == null) return null;
    final out = (cardMap: _lastCardMap!, index: _lastIndex);
    _lastCardMap = null;
    return out;
  }
}

class SwipeFeedCache {
  SwipeFeedCache._();
  static final SwipeFeedCache instance = SwipeFeedCache._();

  /// In-order for O(1) oldest removal during pruning.
  final LinkedHashSet<String> swipedIds = LinkedHashSet<String>();

  /// Raw card maps used by bootstrap snapshots (not the live UI state).
  final List<Map<String, dynamic>> cards = <Map<String, dynamic>>[];

  /// Any id added here is *removed* from swipedIds on every bootstrap/reset.
  final Set<String> _unswipedOverrides = <String>{};

  String? _key;
  bool exhausted = false;

  /// Deduped pending outbox keyed by swipee id (newest wins).
  final Map<String, _PendingSwipe> _pending = <String, _PendingSwipe>{};

  /// Persist-by-ID across widget lifecycles for re-anchoring.
  String? lastTopCardId;

  String? get currentKey => _key;
  bool isCurrentKey(String key) => _key == key;

  void addUnswipeOverride(String id) {
    _unswipedOverrides.add(id);
  }

  void removeUnswipeOverride(String id) {
    _unswipedOverrides.remove(id);
  }

  void resetIfKeyChanged(String newKey) {
    if (_key == newKey) return;
    _key = newKey;
    cards.clear();
    swipedIds.clear();
    _pending.clear();
    exhausted = false;
    // keep undo store, unswipe overrides, and lastTopCardId
  }

  void applyUnswipeOverrides() {
    if (_unswipedOverrides.isEmpty) return;
    for (final id in _unswipedOverrides) {
      swipedIds.remove(id);
    }
  }

  /// Record a swipe locally for pruning/compaction decisions.
  void recordSwiped(String id) {
    if (id.isEmpty) return;
    swipedIds.remove(id);
    swipedIds.add(id);
    // existed is intentionally unused; O(1) move-to-recent behavior preserved.
  }

  void addAll(List<Map<String, dynamic>> incoming) {
    for (final m in incoming) {
      final id = _idFromMap(m);
      if (id.isEmpty) continue;
      if (swipedIds.contains(id)) continue;
      final exists = cards.any((e) => _idFromMap(e) == id);
      if (exists) continue;
      cards.add(m);
    }
  }

  void consumeById(String id) {
    cards.removeWhere((m) => _idFromMap(m) == id);
  }

  void reinsertAt(Map<String, dynamic> card, {required int index}) {
    final id = _idFromMap(card);
    cards.removeWhere((m) => _idFromMap(m) == id);
    if (index < 0) {
      cards.insert(0, card);
    } else if (index >= cards.length) {
      cards.add(card);
    } else {
      cards.insert(index, card);
    }
  }

  /// Deduplicate by id, keeping the last occurrence.
  void compactConsumed() {
    final seen = <String>{};
    for (int i = cards.length - 1; i >= 0; i--) {
      final id = _idFromMap(cards[i]);
      if (id.isEmpty || seen.contains(id)) {
        cards.removeAt(i);
      } else {
        seen.add(id);
      }
    }
  }

  // ───────────────────────── Outbox (deduped, prunable)

  void enqueuePending({required String swipeeId, required bool liked}) {
    _pending[swipeeId] = _PendingSwipe(
      swipeeId,
      liked,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  void removePending(String swipeeId) {
    _pending.remove(swipeeId);
  }

  List<({String swipeeId, bool liked})> snapshotPending() =>
      [for (final p in _pending.values) (swipeeId: p.swipeeId, liked: p.liked)];

  int get pendingCount => _pending.length;

  // ───────────────────────── Pruning & Compaction

  /// Hard caps to guarantee memory stays bounded.
  /// - Keep the most recent [maxSwiped] swiped IDs.
  /// - Keep at most [maxPending] pending records (newest wins).
  void prune({int maxSwiped = 6000, int maxPending = 512}) {
    while (swipedIds.length > maxSwiped) {
      final oldest = swipedIds.first;
      swipedIds.remove(oldest);
    }

    if (_pending.length > maxPending) {
      final entries = _pending.values.toList()
        ..sort((a, b) => a.ts.compareTo(b.ts)); // oldest first
      final toDrop = entries.take(_pending.length - maxPending);
      for (final p in toDrop) {
        _pending.remove(p.swipeeId);
      }
    }
  }

  /// Strip heavy fields from already-swiped cards that are not near the deck.
  /// Keep "full" data for ids in [keepFullIds] (e.g., top, last N for undo, next M).
  void compactSwipedCardsInCache({required Set<String> keepFullIds}) {
    if (cards.isEmpty || swipedIds.isEmpty) return;

    const heavyPhotoKeys = ['photos', 'profile_pictures', 'raw_photos'];
    const interestKey = 'interests';
    const bioKey = 'bio';

    for (int i = 0; i < cards.length; i++) {
      final m = cards[i];
      final id = _idFromMap(m);
      if (id.isEmpty) continue;

      final swiped = swipedIds.contains(id);
      final keep = keepFullIds.contains(id);
      if (!swiped || keep) continue;

      bool changed = false;

      for (final k in heavyPhotoKeys) {
        final v = m[k];
        if (v is List && v.isNotEmpty) {
          m[k] = const <dynamic>[];
          changed = true;
        }
      }

      final bio = m[bioKey]?.toString();
      if (bio != null && bio.isNotEmpty) {
        m[bioKey] = bio.length > 64 ? '${bio.substring(0, 64)}…' : bio;
        changed = true;
      }

      final ints = m[interestKey];
      if (ints is List && ints.isNotEmpty) {
        m[interestKey] = const <dynamic>[];
        changed = true;
      }

      if (changed) {
        cards[i] = Map<String, dynamic>.from(m);
      }
    }
  }

  // ───────────────────────── Wiper
  /// Hard wipe of in-memory swipe state. Defaults preserve overrides & position.
  /// Why: allows global cache reset without losing user’s unswipe intent/position.
  void wipeAll({
    bool keepUnswipeOverrides = true,
    bool keepLastTopCardId = true,
    bool keepPending = false, // avoid losing queued swipes if desired
  }) {
    cards.clear();
    swipedIds.clear();
    if (!keepPending) _pending.clear();
    exhausted = false;
    _key = null; // force rebootstrap

    if (!keepUnswipeOverrides) _unswipedOverrides.clear();
    if (!keepLastTopCardId) lastTopCardId = null;
  }

  // ───────────────────────── Debug dump

  /// Structured summary for diagnostics. Call in controllers as needed.
  String dumpState({int max = 30, bool verbose = false}) {
    final idsInCards = <String>[
      for (final m in cards.take(max)) _idFromMap(m),
      if (cards.length > max) '…(+${cards.length - max})',
    ];
    final swiped = <String>[
      for (final id in swipedIds.take(max)) id,
      if (swipedIds.length > max) '…(+${swipedIds.length - max})',
    ];
    final pend = <String>[
      for (final p in _pending.values.take(max)) '${p.swipeeId}:${p.liked ? "L" : "N"}',
      if (_pending.length > max) '…(+${_pending.length - max})',
    ];
    final ovr = <String>[
      for (final id in _unswipedOverrides.take(max)) id,
      if (_unswipedOverrides.length > max) '…(+${_unswipedOverrides.length - max})',
    ];

    final b = StringBuffer()
      ..writeln('SwipeFeedCache{ key=${_key ?? "-"}, exhausted=$exhausted, '
          'cards=${cards.length}, swiped=${swipedIds.length}, pending=${_pending.length}, '
          'overrides=${_unswipedOverrides.length}, top="${lastTopCardId ?? "-"}" }')
      ..writeln('  cards[0..]: ${idsInCards.join(", ")}')
      ..writeln('  swiped(oldest→newest): ${swiped.join(", ")}')
      ..writeln('  pending: ${pend.join(", ")}')
      ..writeln('  overrides: ${ovr.join(", ")}');

    if (verbose) {
      for (int i = 0; i < cards.length && i < max; i++) {
        b.writeln('    #$i id=${_idFromMap(cards[i])} keys=${cards[i].keys.join("|")}');
      }
    }
    return b.toString();
  }
}

// ───────────────────────── Hook registration
/// Explicit, idempotent registration with the global CacheWiper.
/// Call once during app startup (e.g., in main()).
void initSwipeCacheWiperHook() {
  CacheWiper.registerHook(() async {
    // Keep overrides & position; drop pending by default.
    SwipeFeedCache.instance.wipeAll(
      keepUnswipeOverrides: true,
      keepLastTopCardId: true,
      keepPending: false,
    );
  });
}
