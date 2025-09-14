// =========================
// FIXED FILE: lib/features/swipe/data/swipe_feed_cache.dart
// =========================

/// Global singleton for swipe feed state (persists across page opens).
/// - Append-only list bound to the SwipableStack lifecycle (no reordering while visible).
/// - Strong de-dupe by id against the in-memory list and local swiped set.
/// - Holds paging state, top-up exhaustion flag, and match overlay guard.
/// - Resets only when the (user+prefs) key changes.
/// - Supports compaction when the page is hidden to keep memory lean.
/// - NEW: Holds a small pending outbox of swipes for robust persistence.
class SwipeFeedCache {
  SwipeFeedCache._();
  static final SwipeFeedCache instance = SwipeFeedCache._();

  String? _key; // user+prefs key

  // Backing list as fetched from backend (append-only while the stack is visible)
  final List<Map<String, dynamic>> _cards = <Map<String, dynamic>>[];
  final Set<String> _idSet = <String>{};

  // Cards user has swiped (used for de-dupe and Undo)
  final Set<String> swipedIds = <String>{};

  // Guard match overlay (avoid re-showing for same user)
  final Set<String> matchOverlayShownFor = <String>{};

  // Paging state survives navigation
  int rpcOffset = 0;
  int directOffset = 0;
  bool preferDirect = false;
  bool exhausted = false;

  // (Optional) last known stack index if you want to restore later
  int lastStackIndex = -1;

  // Minimal pending outbox (deduped by swipeeId)
  final Map<String, _PendingSwipe> _pending = <String, _PendingSwipe>{};

  /// Raw list (mutable on purpose so the page can surgically trim when hidden).
  List<Map<String, dynamic>> get cards => _cards;

  /// Projection for UI: backing cards minus locally-swiped ids.
  List<Map<String, dynamic>> get visibleCards {
    if (_cards.isEmpty) return const <Map<String, dynamic>>[];
    if (swipedIds.isEmpty) return List<Map<String, dynamic>>.unmodifiable(_cards);
    final out = <Map<String, dynamic>>[];
    for (final m in _cards) {
      final id = m['potential_match_id']?.toString();
      if (id == null) continue;
      if (!swipedIds.contains(id)) out.add(m);
    }
    return out;
  }

  bool containsId(String id) => _idSet.contains(id);

  int addAll(List<Map<String, dynamic>> rows, {String idKey = 'potential_match_id'}) {
    if (rows.isEmpty) return 0;
    var added = 0;
    for (final m in rows) {
      final id = m[idKey]?.toString();
      if (id == null || id.isEmpty) continue;
      if (_idSet.contains(id)) continue;
      if (swipedIds.contains(id)) continue;
      _cards.add(m);
      _idSet.add(id);
      added++;
    }
    _compactIfNeeded();
    return added;
  }

  void consumeById(String id) {
    swipedIds.add(id);
  }

  void unconsumeById(String id) {
    swipedIds.remove(id);
  }

  /// Compacts by removing all consumed cards (call when page hidden).
  void compactConsumed({
    int? trimTo,
    String idKey = 'potential_match_id',
    String? exceptId,
  }) {
    if (_cards.isEmpty) return;

    final next = <Map<String, dynamic>>[];
    for (final m in _cards) {
      final id = m[idKey]?.toString();
      if (id == null) continue;
      if (exceptId != null && id == exceptId) {
        // kept only if caller wants a specific exception
        next.add(m);
        continue;
      }
      if (swipedIds.contains(id)) continue;
      next.add(m);
    }

    if (trimTo != null && trimTo > 0 && next.length > trimTo) {
      next.removeRange(0, next.length - trimTo);
    }

    _cards
      ..clear()
      ..addAll(next);

    _idSet
      ..clear()
      ..addAll(next.map((m) => m[idKey]?.toString()).whereType<String>());

    if (lastStackIndex >= _cards.length) {
      lastStackIndex = _cards.isEmpty ? -1 : (_cards.length - 1);
    }
  }

  /// Reinsert a card snapshot if it no longer exists (used by Undo after compaction).
  void removeById(String id, {String idKey = 'potential_match_id'}) {
    if (_cards.isEmpty) return;
    for (int i = 0; i < _cards.length; i++) {
      final cid = _cards[i][idKey]?.toString();
      if (cid == id) {
        _cards.removeAt(i);
        _idSet.remove(id);
        if (lastStackIndex > i) lastStackIndex -= 1;
        break;
      }
    }
  }

  void reinsertAt(Map<String, dynamic> card, {required int index, String idKey = 'potential_match_id'}) {
    final id = card[idKey]?.toString();
    if (id == null || id.isEmpty) return;
    // Remove any stray duplicate first
    removeById(id, idKey: idKey);

    final at = index.clamp(0, _cards.length);
    _cards.insert(at, card);
    _idSet.add(id);

    // If the insertion is before the lastStackIndex, shift it right to point to the same logical card
    if (lastStackIndex >= at) {
      lastStackIndex += 1;
    }
  }

  void clear() {
    _cards.clear();
    _idSet.clear();
    swipedIds.clear();
    matchOverlayShownFor.clear();
    rpcOffset = 0;
    directOffset = 0;
    preferDirect = false;
    exhausted = false;
    lastStackIndex = -1;
    _pending.clear();
  }

  void resetIfKeyChanged(String newKey) {
    if (_key == newKey) return;
    _key = newKey;
    clear();
  }

  void _compactIfNeeded({
    int softCap = 600,
    String idKey = 'potential_match_id',
  }) {
    if (_cards.length < softCap) return;

    final next = <Map<String, dynamic>>[];
    for (final m in _cards) {
      final id = m[idKey]?.toString();
      if (id == null) continue;
      if (swipedIds.contains(id)) continue;
      next.add(m);
    }

    if (next.length > softCap) {
      next.removeRange(0, next.length - softCap);
    }

    _cards
      ..clear()
      ..addAll(next);

    _idSet
      ..clear()
      ..addAll(next.map((m) => m[idKey]?.toString()).whereType<String>());
  }

  // ───── Pending outbox helpers ─────
  void enqueuePending({required String swipeeId, required bool liked}) {
    final p = _PendingSwipe(swipeeId: swipeeId, liked: liked, queuedAt: DateTime.now());
    _pending[swipeeId] = p; // dedupe by id
  }

  void removePending(String swipeeId) {
    _pending.remove(swipeeId);
  }

  // ignore: library_private_types_in_public_api
  List<_PendingSwipe> snapshotPending() => List<_PendingSwipe>.unmodifiable(_pending.values);

  int get pendingCount => _pending.length;

  @override
  String toString() {
    return 'SwipeFeedCache(cards:${_cards.length}, visible:${visibleCards.length}, '
        'swiped:${swipedIds.length}, rpcOffset:$rpcOffset, directOffset:$directOffset, '
        'preferDirect:$preferDirect, exhausted:$exhausted, lastStackIndex:$lastStackIndex, pending:${_pending.length})';
  }
}

class _PendingSwipe {
  final String swipeeId;
  final bool liked;
  final DateTime queuedAt;
  const _PendingSwipe({required this.swipeeId, required this.liked, required this.queuedAt});
}
