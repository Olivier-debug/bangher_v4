// ─────────────────────────────────────────────────────────────────────────────
// lib/features/swipe/data/swipe_feed_cache.dart
// + Global undo store (last item only) to persist across navigation.
// + Unswipe overrides to survive bootstrap resets.
// + Track lastTopCardId for position persistence.
// + Pruning & compaction to keep memory light.
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:collection';

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

  void addUnswipeOverride(String id) => _unswipedOverrides.add(id);
  void removeUnswipeOverride(String id) => _unswipedOverrides.remove(id);

  void resetIfKeyChanged(String newKey) {
    if (_key == newKey) return;
    _key = newKey;
    cards.clear();
    swipedIds.clear();
    _pending.clear();
    exhausted = false;
    // keep undo store, unswipe overrides, and lastTopCardId across resets
  }

  void applyUnswipeOverrides() {
    if (_unswipedOverrides.isEmpty) return;
    for (final id in _unswipedOverrides) {
      swipedIds.remove(id);
    }
    // Keep overrides so they survive the next bootstrap too
  }

  /// Record a swipe locally for pruning/compaction decisions.
  void recordSwiped(String id) {
    if (id.isEmpty) return;
    if (swipedIds.contains(id)) swipedIds.remove(id);
    swipedIds.add(id);
  }

  void addAll(List<Map<String, dynamic>> incoming) {
    for (final m in incoming) {
      final id = (m['potential_match_id'] ?? m['user_id'] ?? '').toString();
      if (id.isEmpty) continue;
      if (swipedIds.contains(id)) continue;
      if (!cards.any((e) => (e['potential_match_id'] ?? e['user_id']).toString() == id)) {
        cards.add(m);
      }
    }
  }

  void consumeById(String id) {
    cards.removeWhere((m) => (m['potential_match_id'] ?? m['user_id'] ?? '').toString() == id);
  }

  void reinsertAt(Map<String, dynamic> card, {required int index}) {
    final id = (card['potential_match_id'] ?? card['user_id'] ?? '').toString();
    cards.removeWhere((m) => (m['potential_match_id'] ?? m['user_id'] ?? '').toString() == id);
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
      final id = (cards[i]['potential_match_id'] ?? cards[i]['user_id'] ?? '').toString();
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
      final id = (m['potential_match_id'] ?? m['user_id'] ?? '').toString();
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
}
