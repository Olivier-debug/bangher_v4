// ─────────────────────────────────────────────────────────────────────────────
// lib/features/swipe/data/swipe_feed_cache.dart
// + Global undo store (last item only) to persist across navigation.
// ─────────────────────────────────────────────────────────────────────────────

class _PendingSwipe {
  final String swipeeId;
  final bool liked;
  const _PendingSwipe(this.swipeeId, this.liked);
}

class SwipeUndoStore {
  SwipeUndoStore._();
  static final SwipeUndoStore instance = SwipeUndoStore._();

  Map<String, dynamic>? _lastCardMap;
  int _lastIndex = 0;

  bool get has => _lastCardMap != null;

  void push({required Map<String, dynamic> cardMap, required int index}) {
    // why: persist *one* undo globally (survives route changes & trims)
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

  final List<Map<String, dynamic>> cards = <Map<String, dynamic>>[];
  final Set<String> swipedIds = <String>{};

  String? _key;
  bool exhausted = false;

  final List<_PendingSwipe> _pending = <_PendingSwipe>[];

  String? get currentKey => _key;
  bool isCurrentKey(String key) => _key == key;

  void resetIfKeyChanged(String newKey) {
    if (_key == newKey) return;
    _key = newKey;
    cards.clear();
    swipedIds.clear();
    _pending.clear();
    exhausted = false;
    // keep undo store as-is across resets
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

  void compactConsumed() {
    final seen = <String>{};
    cards.removeWhere((m) {
      final id = (m['potential_match_id'] ?? m['user_id'] ?? '').toString();
      if (id.isEmpty) return true;
      if (seen.contains(id)) return true;
      seen.add(id);
      return false;
    });
  }

  // Outbox
  void enqueuePending({required String swipeeId, required bool liked}) {
    _pending.removeWhere((p) => p.swipeeId == swipeeId);
    _pending.add(_PendingSwipe(swipeeId, liked));
  }

  void removePending(String swipeeId) {
    _pending.removeWhere((p) => p.swipeeId == swipeeId);
  }

  List<({String swipeeId, bool liked})> snapshotPending() =>
      [for (final p in _pending) (swipeeId: p.swipeeId, liked: p.liked)];

  int get pendingCount => _pending.length;
}


