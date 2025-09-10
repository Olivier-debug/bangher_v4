// lib/features/swipe/data/swipe_feed_cache.dart

/// Global singleton for swipe feed state (persists across page opens).
/// - Append-only list bound to the SwipableStack lifecycle.
/// - De-dupes strongly by id against the in-memory list and local swiped set.
/// - Holds paging state, top-up exhaustion flag, and match overlay guard.
/// - Resets only when the (user+prefs) key changes.
class SwipeFeedCache {
  SwipeFeedCache._();
  static final SwipeFeedCache instance = SwipeFeedCache._();

  String? _key; // user+prefs key

  // Append-only backing list as fetched from backend
  final List<Map<String, dynamic>> _cards = <Map<String, dynamic>>[];
  final Set<String> _idSet = <String>{};

  // Cards user has swiped (used for visible projection, de-dupe, and undo)
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

  /// Raw list (for debugging/advanced use). Do not mutate from outside.
  List<Map<String, dynamic>> get cards => _cards;

  /// Projection for UI: backing cards minus locally-swiped ids.
  List<Map<String, dynamic>> get visibleCards {
    if (_cards.isEmpty) return const <Map<String, dynamic>>[];
    if (swipedIds.isEmpty) {
      // Return an unmodifiable view to discourage external mutations.
      return List<Map<String, dynamic>>.unmodifiable(_cards);
    }
    final out = <Map<String, dynamic>>[];
    for (final m in _cards) {
      final id = m['potential_match_id']?.toString();
      if (id == null) continue;
      if (!swipedIds.contains(id)) out.add(m);
    }
    return out;
  }

  /// True if we've already appended an id.
  bool containsId(String id) => _idSet.contains(id);

  /// Add a batch (already normalized) with strong de-dupe.
  /// Returns number of items actually appended.
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

  /// Mark an id as consumed (removes from visible projection immediately).
  /// We don't delete from [_cards] while the stack is visible to avoid index drift.
  void consumeById(String id) {
    swipedIds.add(id);
  }

  /// Undo a consume (used by single-level undo).
  void unconsumeById(String id) {
    swipedIds.remove(id);
  }

  /// Remove all consumed cards from the backing list.
  /// Call only when the swipe page is NOT visible (e.g., tab hidden or app paused).
  /// Optionally keep only the newest [trimTo] remaining to cap memory.
  void compactConsumed({int? trimTo, String idKey = 'potential_match_id'}) {
    if (_cards.isEmpty) return;

    final next = <Map<String, dynamic>>[];
    for (final m in _cards) {
      final id = m[idKey]?.toString();
      if (id == null) continue;
      if (swipedIds.contains(id)) continue;
      next.add(m);
    }

    if (trimTo != null && trimTo > 0 && next.length > trimTo) {
      // Keep tail only
      next.removeRange(0, next.length - trimTo);
    }

    _cards
      ..clear()
      ..addAll(next);

    _idSet
      ..clear()
      ..addAll(next.map((m) => m[idKey]?.toString()).whereType<String>());

    // Adjust lastStackIndex if it was pointing past end
    if (lastStackIndex >= _cards.length) {
      lastStackIndex = _cards.isEmpty ? -1 : (_cards.length - 1);
    }
  }

  /// Clear everything (e.g., when prefs change or sign-out).
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
  }

  /// Reset if user/prefs key changed.
  void resetIfKeyChanged(String newKey) {
    if (_key == newKey) return;
    _key = newKey;
    clear();
  }

  /// Soft compaction when the buffer grows large (keeps memory tidy).
  void _compactIfNeeded({int softCap = 600, String idKey = 'potential_match_id'}) {
    if (_cards.length < softCap) return;

    final next = <Map<String, dynamic>>[];
    for (final m in _cards) {
      final id = m[idKey]?.toString();
      if (id == null) continue;
      if (swipedIds.contains(id)) continue;
      next.add(m);
    }

    // Bound memory to `softCap` newest items
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

  @override
  String toString() {
    return 'SwipeFeedCache(cards:${_cards.length}, visible:${visibleCards.length}, '
        'swiped:${swipedIds.length}, rpcOffset:$rpcOffset, directOffset:$directOffset, '
        'preferDirect:$preferDirect, exhausted:$exhausted, lastStackIndex:$lastStackIndex)';
  }
}
