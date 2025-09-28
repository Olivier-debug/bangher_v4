// =========================
// FILE: lib/features/confessions/data/confession_cache.dart
// =========================

import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';

// Hook to central cache wiper
import '../../../core/cache_wiper.dart';

import 'confession_models.dart';

/// In-memory feed cache (small, TTL)
class FeedCache {
  FeedCache._();
  static final instance = FeedCache._();

  static const int cap = 45;
  static const Duration ttl = Duration(seconds: 60);

  List<ConfessionItem> items = <ConfessionItem>[];
  bool isEnd = false;
  DateTime _at = DateTime.fromMillisecondsSinceEpoch(0);

  bool get isFresh => DateTime.now().difference(_at) <= ttl;

  void seed(List<ConfessionItem> firstPage, {required bool end}) {
    items = List.of(firstPage);
    isEnd = end;
    _at = DateTime.now();
  }

  void append(List<ConfessionItem> page, {required bool end}) {
    final ids = items.map((e) => e.id).toSet();
    for (final e in page) {
      if (!ids.contains(e.id)) items.add(e);
    }
    if (items.length > cap) items = items.sublist(items.length - cap);
    isEnd = end;
    _at = DateTime.now();
  }

  void upsert(ConfessionItem it) {
    final i = items.indexWhere((e) => e.id == it.id);
    if (i == -1) {
      items.insert(0, it);
      if (items.length > cap) items.removeLast();
    } else {
      items[i] = it;
    }
    _at = DateTime.now();
  }

  void remove(String id) {
    items.removeWhere((e) => e.id == id);
    _at = DateTime.now();
  }

  /// Clear in-memory state (why: used by global cache wipe).
  void clearAll() {
    items = <ConfessionItem>[];
    isEnd = false;
    _at = DateTime.fromMillisecondsSinceEpoch(0);
  }
}

/// Per-device bookmarks (local only)
class BookmarkStore {
  BookmarkStore._();
  static final instance = BookmarkStore._();

  static const _k = 'conf_bookmarks_v1';
  SharedPreferences? _prefs;
  Set<String> _ids = <String>{};
  bool _ready = false;

  Future<void> init() async {
    if (_ready) return;
    _prefs = await SharedPreferences.getInstance();
    _ids = (_prefs?.getStringList(_k)?.toSet() ?? <String>{});
    _ready = true;
  }

  Future<Set<String>> all() async {
    await init();
    return _ids;
  }

  Future<bool> isSaved(String id) async {
    await init();
    return _ids.contains(id);
  }

  Future<void> toggle(String id) async {
    await init();
    if (_ids.contains(id)) {
      _ids.remove(id);
    } else {
      _ids.add(id);
    }
    await _prefs?.setStringList(_k, _ids.toList());
  }

  /// Clear saved bookmarks from memory and disk (why: global wipe).
  Future<void> clearAll() async {
    await init();
    _ids.clear();
    await _prefs?.remove(_k);
  }
}

/// Recent search terms
class RecentSearchStore {
  RecentSearchStore._();
  static final instance = RecentSearchStore._();

  static const _k = 'conf_recent_searches_v1';
  static const _max = 8;

  SharedPreferences? _prefs;
  bool _ready = false;

  Future<void> init() async {
    if (_ready) return;
    _prefs = await SharedPreferences.getInstance();
    _ready = true;
  }

  Future<List<String>> all() async {
    await init();
    return (_prefs?.getStringList(_k) ?? const <String>[]);
  }

  Future<void> push(String q) async {
    await init();
    final list = (_prefs?.getStringList(_k) ?? <String>[]);
    final cleaned = q.trim();
    if (cleaned.isEmpty) return;
    list.removeWhere((e) => e.toLowerCase() == cleaned.toLowerCase());
    list.insert(0, cleaned);
    while (list.length > _max) {
      list.removeLast();
    }
    await _prefs?.setStringList(_k, list);
  }

  Future<void> remove(String q) async {
    await init();
    final list = (_prefs?.getStringList(_k) ?? <String>[]);
    list.removeWhere((e) => e.toLowerCase() == q.toLowerCase());
    await _prefs?.setStringList(_k, list);
  }

  /// Clear from disk (why: global wipe).
  Future<void> clearAll() async {
    await init();
    await _prefs?.remove(_k);
  }
}

// ──────────────────────────────────────────────────────────────
// Global clear facade + CacheWiper hook (runs on Settings → Reset).
// ──────────────────────────────────────────────────────────────

Future<void> clearConfessionCaches() async {
  try {
    FeedCache.instance.clearAll();
  } catch (_) {}

  try {
    await BookmarkStore.instance.clearAll();
  } catch (_) {}

  try {
    await RecentSearchStore.instance.clearAll();
  } catch (_) {}
}

void _registerConfessionsHook() {
  CacheWiper.registerHook(() async {
    await clearConfessionCaches();
  });
}

// Ensure one-time registration and avoid unused warnings.
// ignore: unused_element
final bool _confessionsHookRegistered = (() {
  _registerConfessionsHook();
  return true;  
})();
