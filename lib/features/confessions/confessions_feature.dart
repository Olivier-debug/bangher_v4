// =========================
// FILE: lib/features/confessions/confessions_feature.dart
// =========================
// IG+ Revamp — COMPLETE (fixed + comments + caching)
// - Commenting works (sheet with pagination, optimistic insert)
// - In‑memory feed + comments cache (TTL + capacity)
// - Safer BuildContext across awaits; _timeAgo + showSnackSafe helpers
// - Small top header for Confessions (keeps the “cool” vibe)
// - Keep class/file names; RPCs used: confessions_feed, confessions_one, toggle_confession_like

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../theme/app_theme.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Helpers (time‑ago + safe snackbar)
String _timeAgo(DateTime t) {
  final d = DateTime.now().toUtc().difference(t.toUtc());
  if (d.inSeconds < 60) return '${d.inSeconds}s';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  if (d.inDays < 7) return '${d.inDays}d';
  final w = (d.inDays / 7).floor();
  if (w < 5) return '${w}w';
  final mo = (d.inDays / 30).floor();
  if (mo < 12) return '${mo}mo';
  final y = (d.inDays / 365).floor();
  return '${y}y';
}

void showSnackSafe(BuildContext ctx, String msg) {
  ScaffoldMessenger.of(ctx)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(behavior: SnackBarBehavior.floating, content: Text(msg)),
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// Routes
class ConfessionsFeedPage extends StatefulWidget {
  const ConfessionsFeedPage({super.key});
  static const String routeName = 'ConfessionsFeed';
  static const String routePath = '/confessions';

  @override
  State<ConfessionsFeedPage> createState() => _ConfessionsFeedPageState();
}

class ConfessionDetailPage extends StatefulWidget {
  const ConfessionDetailPage({super.key, required this.confessionId, this.heroTag});
  final String confessionId;
  final String? heroTag;

  static const String routeName = 'ConfessionDetail';
  static const String routePath = '/confession';

  @override
  State<ConfessionDetailPage> createState() => _ConfessionDetailPageState();
}

// ─────────────────────────────────────────────────────────────────────────────
// Constants / Choices
const _topics = <String>['All', 'Love', 'Campus', 'Work', 'Family', 'Money', 'Friends', 'Random'];
const _languages = <String>['All', 'English', 'Afrikaans', 'Zulu', 'Xhosa', 'Sotho', 'French', 'Spanish'];
const _seedPrompts = <String>[
  "Today I realized…",
  "My hottest take is…",
  "I can't tell my friends that…",
  "I feel guilty because…",
  "If I could go back, I'd…",
  "The pettiest thing I did was…",
  "Lowkey, I love it when…",
  "I lied about… and now…",
];
const Map<String, String> _topicEmoji = {
  'Love': '❤️',
  'Campus': '🎓',
  'Work': '💼',
  'Family': '👪',
  'Money': '💸',
  'Friends': '👯',
  'Random': '✨',
};

// ─────────────────────────────────────────────────────────────────────────────
// Models
class ConfessionItem {
  final String id;
  final String authorUserId;
  final String content;
  final bool isAnonymous;
  final String? imageUrl;
  final DateTime createdAt;
  final int likeCount;
  final int commentCount;
  final bool likedByMe;
  final String? authorName;
  final String? authorAvatarUrl;
  final String topic;
  final String language;
  final bool nsfw;
  final DateTime? editedAt;

  ConfessionItem({
    required this.id,
    required this.authorUserId,
    required this.content,
    required this.isAnonymous,
    required this.imageUrl,
    required this.createdAt,
    required this.likeCount,
    required this.commentCount,
    required this.likedByMe,
    required this.authorName,
    required this.authorAvatarUrl,
    required this.topic,
    required this.language,
    required this.nsfw,
    required this.editedAt,
  });

  ConfessionItem copyWith({
    int? likeCount,
    int? commentCount,
    bool? likedByMe,
    String? content,
    String? imageUrl,
    String? topic,
    String? language,
    bool? nsfw,
    DateTime? editedAt,
  }) =>
      ConfessionItem(
        id: id,
        authorUserId: authorUserId,
        content: content ?? this.content,
        isAnonymous: isAnonymous,
        imageUrl: imageUrl ?? this.imageUrl,
        createdAt: createdAt,
        likeCount: likeCount ?? this.likeCount,
        commentCount: commentCount ?? this.commentCount,
        likedByMe: likedByMe ?? this.likedByMe,
        authorName: authorName,
        authorAvatarUrl: authorAvatarUrl,
        topic: topic ?? this.topic,
        language: language ?? this.language,
        nsfw: nsfw ?? this.nsfw,
        editedAt: editedAt ?? this.editedAt,
      );

  static ConfessionItem fromRow(Map<String, dynamic> r, {String? me}) {
    String str(dynamic v) => (v ?? '').toString();
    bool toBool(dynamic v) => v == true;
    int toInt(dynamic v) => (v as int?) ?? (int.tryParse(str(v)) ?? 0);

    return ConfessionItem(
      id: str(r['id']),
      authorUserId: str(r['author_user_id']),
      content: str(r['content']),
      isAnonymous: toBool(r['is_anonymous']),
      imageUrl: str(r['image_url']).isEmpty ? null : str(r['image_url']),
      createdAt: DateTime.tryParse(str(r['created_at']))?.toUtc() ?? DateTime.now().toUtc(),
      likeCount: toInt(r['like_count']),
      commentCount: toInt(r['comment_count']),
      likedByMe: (r['liked_by_me'] as bool?) ?? false,
      authorName: str(r['author_name']).isEmpty ? null : str(r['author_name']),
      authorAvatarUrl: str(r['author_avatar_url']).isEmpty ? null : str(r['author_avatar_url']),
      topic: str(r['topic']).isEmpty ? 'Random' : str(r['topic']),
      language: str(r['language']).isEmpty ? 'English' : str(r['language']),
      nsfw: toBool(r['nsfw']),
      editedAt: DateTime.tryParse(str(r['edited_at'])),
    );
  }
}

class CommentItem {
  final String id;
  final String confessionId;
  final String authorUserId;
  final String authorName;
  final String? authorAvatarUrl;
  final String text;
  final DateTime createdAt;

  const CommentItem({
    required this.id,
    required this.confessionId,
    required this.authorUserId,
    required this.authorName,
    required this.authorAvatarUrl,
    required this.text,
    required this.createdAt,
  });

  static CommentItem fromRow(Map<String, dynamic> r) => CommentItem(
        id: (r['id'] ?? '').toString(),
        confessionId: (r['confession_id'] ?? '').toString(),
        authorUserId: (r['author_user_id'] ?? '').toString(),
        authorName: (r['author_name'] ?? r['name'] ?? 'Someone').toString(),
        authorAvatarUrl: (r['author_avatar_url'] ?? r['avatar_url'] ?? '').toString().isEmpty
            ? null
            : (r['author_avatar_url'] ?? r['avatar_url']).toString(),
        text: (r['text'] ?? '').toString(),
        createdAt: DateTime.tryParse((r['created_at'] ?? '').toString())?.toUtc() ??
            DateTime.now().toUtc(),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Local stores
class _BookmarkStore {
  _BookmarkStore._();
  static final instance = _BookmarkStore._();
  static const _key = 'conf_bookmarks_v1';

  Set<String> _ids = <String>{};
  SharedPreferences? _prefs;
  bool _ready = false;

  Future<void> init() async {
    if (_ready) return;
    _prefs = await SharedPreferences.getInstance();
    _ids = (_prefs?.getStringList(_key)?.toSet() ?? <String>{});
    _ready = true;
  }

  bool isSaved(String id) => _ids.contains(id);
  Future<void> toggle(String id) async {
    await init();
    if (_ids.contains(id)) {
      _ids.remove(id);
    } else {
      _ids.add(id);
    }
    await _prefs?.setStringList(_key, _ids.toList());
  }
}

class _SearchStore {
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
}

// ─────────────────────────────────────────────────────────────────────────────
// In‑memory caches (tiny, TTL + cap). Avoids re‑hitting DB on fast returns.
class _FeedCache {
  static final instance = _FeedCache._();
  _FeedCache._();

  static const int cap = 45; // ~2–3 pages
  static const Duration ttl = Duration(seconds: 60);
  List<ConfessionItem> items = <ConfessionItem>[];
  bool end = false;
  DateTime at = DateTime.fromMillisecondsSinceEpoch(0);

  bool get fresh => DateTime.now().difference(at) <= ttl;

  void seed(List<ConfessionItem> firstPage, {required bool isEnd}) {
    items = List.of(firstPage);
    end = isEnd;
    at = DateTime.now();
  }

  void append(List<ConfessionItem> page, {required bool isEnd}) {
    final ids = items.map((e) => e.id).toSet();
    for (final e in page) {
      if (!ids.contains(e.id)) items.add(e);
    }
    if (items.length > cap) items = items.sublist(items.length - cap);
    end = isEnd;
    at = DateTime.now();
  }

  void upsert(ConfessionItem it) {
    final i = items.indexWhere((e) => e.id == it.id);
    if (i == -1) {
      items.insert(0, it);
      if (items.length > cap) items.removeLast();
    } else {
      items[i] = it;
    }
    at = DateTime.now();
  }

  void remove(String id) {
    items.removeWhere((e) => e.id == id);
    at = DateTime.now();
  }
}

class _CommentsCache {
  static final instance = _CommentsCache._();
  _CommentsCache._();

  static const int capPerPost = 30;
  static const Duration ttl = Duration(seconds: 60);
  final Map<String, List<CommentItem>> _byPost = <String, List<CommentItem>>{};
  final Map<String, DateTime> _stamp = <String, DateTime>{};

  List<CommentItem> get(String postId) => List.unmodifiable(_byPost[postId] ?? const <CommentItem>[]);
  bool fresh(String postId) => DateTime.now().difference(_stamp[postId] ?? DateTime(0)) <= ttl;

  void seed(String postId, List<CommentItem> xs) {
    final list = List.of(xs);
    if (list.length > capPerPost) {
      _byPost[postId] = list.sublist(0, capPerPost);
    } else {
      _byPost[postId] = list;
    }
    _stamp[postId] = DateTime.now();
  }

  void appendNewTop(String postId, CommentItem c) {
    final list = List.of(_byPost[postId] ?? const <CommentItem>[]);
    list.insert(0, c);
    if (list.length > capPerPost) list.removeLast();
    _byPost[postId] = list;
    _stamp[postId] = DateTime.now();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Feed Page
enum _Sort { latest, top, trending }

class _ConfessionsFeedPageState extends State<ConfessionsFeedPage>
    with TickerProviderStateMixin {
  final SupabaseClient _supa = Supabase.instance.client;
  final ScrollController _scroll = ScrollController();

  final List<ConfessionItem> _items = <ConfessionItem>[];
  bool _loading = true;
  bool _refreshing = false;
  bool _fetchingMore = false;
  bool _end = false;

  RealtimeChannel? _ch;
  static const int _pageSize = 20;

  String _topic = _topics.first;
  String _language = _languages.first;
  _Sort _sort = _Sort.trending;
  String _query = '';
  bool _bookmarksOnly = false;

  final _recentSearch = _SearchStore();

  @override
  void initState() {
    super.initState();
    _load(initial: true);
    _listenRealtime();
    _scroll.addListener(_onScroll);
    _BookmarkStore.instance.init();
    _recentSearch.init();
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _ch?.unsubscribe();
    super.dispose();
  }

  // Data ----------------------------------------------------------------------
  Future<void> _load({bool initial = false}) async {
    try {
      if (initial) {
        final cache = _FeedCache.instance;
        if (cache.fresh && cache.items.isNotEmpty) {
          setState(() {
            _items
              ..clear()
              ..addAll(cache.items);
            _end = cache.end;
            _loading = false;
          });
        } else {
          setState(() => _loading = true);
        }
      }

      final me = _supa.auth.currentUser?.id;
      final rows = await _supa.rpc('confessions_feed', params: {
        'limit_arg': _pageSize,
        'offset_arg': 0,
      });
      final list = (rows as List?)?.cast<Map<String, dynamic>>() ?? const [];
      final mapped = list.map((r) => ConfessionItem.fromRow(r, me: me)).toList();
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(mapped);
        _end = mapped.length < _pageSize;
        _loading = false;
      });
      _FeedCache.instance.seed(mapped, isEnd: _end);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      debugPrint('confessions load error: $e');
    }
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    await _load(initial: false);
    if (!mounted) return;
    setState(() => _refreshing = false);
  }

  Future<void> _loadMore() async {
    if (_fetchingMore || _end) return;
    setState(() => _fetchingMore = true);
    try {
      final me = _supa.auth.currentUser?.id;
      final offset = _items.length;

      // If cache is fresh and has more than offset, serve from cache only
      final cache = _FeedCache.instance;
      if (cache.fresh && cache.items.length > offset) {
        final take = cache.items.length - offset;
        final page = cache.items.sublist(offset, offset + take);
        setState(() {
          _items.addAll(page);
          _end = cache.end;
        });
        return;
      }

      final rows = await _supa.rpc('confessions_feed', params: {
        'limit_arg': _pageSize,
        'offset_arg': offset,
      });
      final list = (rows as List?)?.cast<Map<String, dynamic>>() ?? const [];
      final mapped = list.map((r) => ConfessionItem.fromRow(r, me: me)).toList();
      if (!mounted) return;
      setState(() {
        _items.addAll(mapped);
        if (mapped.length < _pageSize) _end = true;
      });
      _FeedCache.instance.append(mapped, isEnd: _end);
    } catch (e) {
      debugPrint('confessions loadMore error: $e');
    } finally {
      if (mounted) setState(() => _fetchingMore = false);
    }
  }

  void _onScroll() {
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 500) {
      _loadMore();
    }
  }

  void _listenRealtime() {
    _ch?.unsubscribe();
    _ch = _supa.channel('confessions_feed');

    _ch!
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'confessions',
          callback: (payload) async {
            try {
              final res = await _supa.rpc('confessions_one', params: {
                'p_confession_id': payload.newRecord['id'],
              });
              final list = (res as List?)?.cast<Map<String, dynamic>>() ?? const [];
              if (list.isEmpty || !mounted) return;
              final me = _supa.auth.currentUser?.id;
              final item = ConfessionItem.fromRow(list.first, me: me);
              setState(() => _items.insert(0, item));
              _FeedCache.instance.upsert(item);
            } catch (e) {
              debugPrint('hydrate insert error: $e');
            }
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'confessions',
          callback: (payload) {
            if (!mounted) return;
            final nr = payload.newRecord;
            final id = (nr['id'] ?? '').toString();
            final idx = _items.indexWhere((e) => e.id == id);
            if (idx == -1) return;
            setState(() {
              _items[idx] = _items[idx].copyWith(
                likeCount: (nr['like_count'] as int?) ?? _items[idx].likeCount,
                commentCount: (nr['comment_count'] as int?) ?? _items[idx].commentCount,
                content: (nr['content'] ?? _items[idx].content).toString(),
                imageUrl: (nr['image_url'] ?? _items[idx].imageUrl)?.toString(),
                topic: (nr['topic'] ?? _items[idx].topic).toString(),
                language: (nr['language'] ?? _items[idx].language).toString(),
                nsfw: nr['nsfw'] == true ? true : (nr['nsfw'] == false ? false : _items[idx].nsfw),
                editedAt: DateTime.tryParse((nr['edited_at'] ?? '').toString()) ?? _items[idx].editedAt,
              );
            });
            _FeedCache.instance.upsert(_items[idx]);
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'confessions',
          callback: (payload) {
            if (!mounted) return;
            final id = (payload.oldRecord['id'] ?? '').toString();
            setState(() => _items.removeWhere((e) => e.id == id));
            _FeedCache.instance.remove(id);
          },
        )
        .subscribe();
  }

  // Actions -------------------------------------------------------------------
  Future<ConfessionItem?> _toggleLike(ConfessionItem item) async {
    try {
      final prev = item;
      final optimistic = prev.copyWith(
        likedByMe: !prev.likedByMe,
        likeCount: prev.likeCount + (prev.likedByMe ? -1 : 1),
      );
      setState(() {
        final idx = _items.indexWhere((e) => e.id == prev.id);
        if (idx != -1) _items[idx] = optimistic;
      });
      _FeedCache.instance.upsert(optimistic);
      HapticFeedback.lightImpact();
      final rows = await _supa.rpc('toggle_confession_like', params: {
        'p_confession_id': item.id,
      });
      final list = (rows as List?)?.cast<Map<String, dynamic>>() ?? const [];
      if (list.isEmpty) return optimistic;
      final liked = (list.first['liked'] as bool?) ?? optimistic.likedByMe;
      final count = (list.first['like_count'] as int?) ?? optimistic.likeCount;
      final fixed = item.copyWith(likedByMe: liked, likeCount: count);
      _FeedCache.instance.upsert(fixed);
      return fixed;
    } catch (e) {
      debugPrint('toggle like error: $e');
      return null;
    }
  }

  Future<void> _openComments(String confessionId) async {
    final ctx = context;
    await showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CommentsSheet(confessionId: confessionId),
    );
  }

  Future<void> _openComposer({ConfessionItem? edit}) async {
    final ctx = context;
    await showModalBottomSheet<ConfessionItem?>(
      context: ctx,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ComposerSheet(existing: edit),
    ).then((res) {
      if (!mounted || res == null) return;
      final idx = _items.indexWhere((e) => e.id == res.id);
      setState(() {
        if (idx == -1) {
          _items.insert(0, res);
        } else {
          _items[idx] = res;
        }
      });
      _FeedCache.instance.upsert(res);
    });
  }

  Future<void> _deletePost(ConfessionItem item) async {
    final ctx = context;
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.ffPrimaryBg,
        title: const Text('Delete confession?', style: TextStyle(color: Colors.white)),
        content: const Text('This action cannot be undone.', style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final idx = _items.indexWhere((e) => e.id == item.id);
    if (idx == -1) return;
    final removed = _items.removeAt(idx);
    setState(() {});
    try {
      await _supa.from('confessions').delete().eq('id', item.id);
    } catch (e) {
      if (!mounted) return;
      setState(() => _items.insert(idx, removed));
      showSnackSafe(ctx, 'Failed to delete.');
    }
  }

  // Helpers -------------------------------------------------------------------
  double _hotScore(ConfessionItem e) {
    final ageHours = math.max(1, DateTime.now().toUtc().difference(e.createdAt).inMinutes / 60);
    final score = (e.likeCount + 1) / math.pow(ageHours, 1.4);
    return score.toDouble();
  }

  Iterable<ConfessionItem> get _visible {
    Iterable<ConfessionItem> xs = _items;
    if (_bookmarksOnly) xs = xs.where((e) => _BookmarkStore.instance.isSaved(e.id));
    if (_topic != 'All') xs = xs.where((e) => e.topic.toLowerCase() == _topic.toLowerCase());
    if (_language != 'All') xs = xs.where((e) => e.language.toLowerCase() == _language.toLowerCase());
    if (_query.trim().isNotEmpty) {
      final q = _query.trim().toLowerCase();
      xs = xs.where((e) => e.content.toLowerCase().contains(q) || e.topic.toLowerCase().contains(q) || (e.authorName ?? '').toLowerCase().contains(q));
    }
    if (_sort == _Sort.latest) {
      xs = xs.toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    } else if (_sort == _Sort.top) {
      xs = xs.toList()..sort((a, b) => b.likeCount.compareTo(a.likeCount));
    } else {
      xs = xs.toList()..sort((a, b) => _hotScore(b).compareTo(_hotScore(a)));
    }
    return xs;
  }

  Future<void> _onSearchSubmitted(String v) async {
    setState(() => _query = v);
    await _recentSearch.push(v);
  }

  Future<void> _openSearchSheet() async {
    final ctx = context;
    final recents = await _recentSearch.all();
    if (!mounted) return;
    await showModalBottomSheet<String>(
      context: ctx,
      backgroundColor: Colors.transparent,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => _RecentSearchSheet(
        recents: recents,
        onRemove: (t) => _recentSearch.remove(t),
      ),
    ).then((picked) {
      if (picked == null) return;
      _onSearchSubmitted(picked);
    });
  }

  Map<String, int> get _topicCounts {
    final Map<String, int> c = {for (final t in _topics) t: 0};
    for (final e in _items) {
      c[e.topic] = (c[e.topic] ?? 0) + 1;
    }
    c.remove('All');
    return c;
  }

  // Build ---------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final items = _visible.toList(growable: false);

    return Scaffold(
      backgroundColor: AppTheme.ffSecondaryBg,
      appBar: _FeedAppBar(
        query: _query,
        onQuery: (v) => setState(() => _query = v),
        onClear: () => setState(() => _query = ''),
        onSubmitted: _onSearchSubmitted,
        onOpenSearch: _openSearchSheet,
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _refresh,
          color: AppTheme.ffPrimary,
          child: _loading
              ? const _FeedSkeleton()
              : StretchingOverscrollIndicator(
                  axisDirection: AxisDirection.down,
                  child: CustomScrollView(
                    controller: _scroll,
                    slivers: [
                      const SliverToBoxAdapter(child: _ConfessionsHeader()),
                      SliverToBoxAdapter(
                        child: Column(
                          children: [
                            _FiltersRow(
                              topic: _topic,
                              language: _language,
                              sort: _sort,
                              bookmarksOnly: _bookmarksOnly,
                              onTopic: (v) => setState(() => _topic = v),
                              onLanguage: (v) => setState(() => _language = v),
                              onSort: (v) => setState(() => _sort = v),
                              onToggleBookmarksOnly: () => setState(() => _bookmarksOnly = !_bookmarksOnly),
                              onConfess: () => _openComposer(),
                            ),
                            _HighlightsRow(
                              activeTopic: _topic,
                              counts: _topicCounts,
                              onPick: (t) => setState(() => _topic = t),
                            ),
                            _TrendingBar(counts: _topicCounts),
                          ],
                        ),
                      ),
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 92),
                        sliver: SliverList.builder(
                          itemCount: items.length + (_fetchingMore ? 1 : 0),
                          itemBuilder: (context, i) {
                            if (i >= items.length) {
                              return const Padding(
                                padding: EdgeInsets.symmetric(vertical: 18),
                                child: Center(child: CircularProgressIndicator()),
                              );
                            }
                            final item = items[i];
                            final me = _supa.auth.currentUser?.id;
                            final canEditDelete = me != null && me == item.authorUserId;

                            return _ConfessionCard(
                              item: item,
                              canEditDelete: canEditDelete,
                              onTapImage: (tag) {
                                Navigator.of(context).push(
                                  PageRouteBuilder(
                                    transitionDuration: const Duration(milliseconds: 260),
                                    reverseTransitionDuration: const Duration(milliseconds: 200),
                                    pageBuilder: (_, __, ___) => ConfessionDetailPage(
                                      confessionId: item.id,
                                      heroTag: tag,
                                    ),
                                    transitionsBuilder: (_, anim, __, child) => FadeTransition(opacity: anim, child: child),
                                  ),
                                );
                              },
                              onToggleLike: () async {
                                final updated = await _toggleLike(item);
                                if (!mounted) return;
                                if (updated != null) {
                                  setState(() {
                                    final idx = _items.indexWhere((e) => e.id == item.id);
                                    if (idx != -1) _items[idx] = updated;
                                  });
                                }
                              },
                              onOpenComments: () => _openComments(item.id),
                              onEdit: () => _openComposer(edit: item),
                              onDelete: () => _deletePost(item),
                              onBookmark: () async {
                                await _BookmarkStore.instance.toggle(item.id);
                                if (!mounted) return;
                                setState(() {});
                              },
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ),
      floatingActionButton: _ComposeFab(onPressed: () => _openComposer()),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// App Bar + Filters + Header
class _FeedAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _FeedAppBar({
    required this.query,
    required this.onQuery,
    required this.onClear,
    required this.onSubmitted,
    required this.onOpenSearch,
  });

  final String query;
  final ValueChanged<String> onQuery;
  final VoidCallback onClear;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onOpenSearch;

  @override
  Size get preferredSize => const Size.fromHeight(72);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      backgroundColor: AppTheme.ffSecondaryBg,
      elevation: 0,
      titleSpacing: 0,
      title: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF121316),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: AppTheme.ffAlt.withValues(alpha: .35),
              width: 1,
            ),
          ),
          child: Row(
            children: [
              const SizedBox(width: 10),
              const Icon(Icons.search, color: Colors.white70, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  // NOTE: ephemeral controller so the text reflects state.query.
                  controller: TextEditingController(text: query)
                    ..selection = TextSelection.collapsed(offset: query.length),
                  onChanged: onQuery,
                  onSubmitted: onSubmitted,
                  onTap: onOpenSearch,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    hintText: 'Search confessions…',
                    hintStyle: TextStyle(color: Colors.white54),
                    border: InputBorder.none,
                  ),
                ),
              ),
              if (query.isNotEmpty)
                IconButton(
                  tooltip: 'Clear',
                  onPressed: onClear,
                  icon: const Icon(Icons.close, color: Colors.white54, size: 18),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Small branded header (keeps “cool” vibe)
class _ConfessionsHeader extends StatelessWidget {
  const _ConfessionsHeader();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
      child: Row(
        children: [
          SizedBox(
            height: 38,
            child: Image.asset(
              'assets/images/Bangher_Logo.png',
              fit: BoxFit.contain,
              filterQuality: FilterQuality.high,
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: 'Notifications',
            icon: const Icon(Icons.notifications_none, color: Colors.white),
            onPressed: () {},
          ),
          const SizedBox(width: 4),
          TextButton.icon(
            onPressed: () => ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('Tip: use the Confess button below'))),
            icon: const Icon(Icons.auto_awesome, color: Colors.white),
            label: const Text('Tips', style: TextStyle(color: Colors.white)),
            style: TextButton.styleFrom(
              backgroundColor: Colors.white.withValues(alpha: .06),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Filters row + trending + highlights
class _FiltersRow extends StatelessWidget {
  const _FiltersRow({
    required this.topic,
    required this.language,
    required this.sort,
    required this.bookmarksOnly,
    required this.onTopic,
    required this.onLanguage,
    required this.onSort,
    required this.onToggleBookmarksOnly,
    required this.onConfess,
  });

  final String topic;
  final String language;
  final _Sort sort;
  final bool bookmarksOnly;
  final ValueChanged<String> onTopic;
  final ValueChanged<String> onLanguage;
  final ValueChanged<_Sort> onSort;
  final VoidCallback onToggleBookmarksOnly;
  final VoidCallback onConfess;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          height: 44,
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            scrollDirection: Axis.horizontal,
            itemBuilder: (_, i) {
              final t = _topics[i];
              final sel = t == topic;
              return ChoiceChip(
                label: Text(t),
                selected: sel,
                onSelected: (_) => onTopic(t),
                labelStyle: TextStyle(color: sel ? Colors.white : Colors.white70),
                selectedColor: AppTheme.ffPrimary.withValues(alpha: .55),
                backgroundColor: const Color(0xFF141414),
                side: BorderSide(color: AppTheme.ffAlt.withValues(alpha: .55)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              );
            },
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemCount: _topics.length,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _DropdownPill<String>(
                value: language,
                items: _languages,
                onChanged: (v) => onLanguage(v ?? 'All'),
                icon: Icons.language,
              ),
              _DropdownPill<_Sort>(
                value: sort,
                items: const [_Sort.trending, _Sort.latest, _Sort.top],
                display: (s) => s == _Sort.latest ? 'Latest' : s == _Sort.top ? 'Top' : 'Trending',
                onChanged: (v) => onSort(v ?? _Sort.trending),
                icon: Icons.auto_graph,
              ),
              FilterChip(
                label: const Text('Bookmarks'),
                selected: bookmarksOnly,
                onSelected: (_) => onToggleBookmarksOnly(),
                selectedColor: AppTheme.ffPrimary.withValues(alpha: .35),
                backgroundColor: const Color(0xFF141414),
                labelStyle: TextStyle(color: bookmarksOnly ? Colors.white : Colors.white70),
                side: BorderSide(color: AppTheme.ffAlt.withValues(alpha: .55)),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: onConfess,
                icon: const Icon(Icons.add, size: 18, color: Colors.white),
                label: const Text('Confess',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  backgroundColor: AppTheme.ffPrimary.withValues(alpha: .25),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TrendingBar extends StatelessWidget {
  const _TrendingBar({required this.counts});
  final Map<String, int> counts;

  @override
  Widget build(BuildContext context) {
    if (counts.isEmpty) return const SizedBox.shrink();
    final top = counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final show = top.take(4).where((e) => e.value > 0).toList();
    if (show.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF0F1013),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.ffAlt.withValues(alpha: .35)),
        ),
        child: Row(
          children: [
            const Icon(Icons.local_fire_department, color: Colors.orangeAccent, size: 18),
            const SizedBox(width: 8),
            const Text('Trending:', style: TextStyle(color: Colors.white70)),
            const SizedBox(width: 8),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final e in show)
                      Container(
                        margin: const EdgeInsets.only(right: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: AppTheme.ffPrimary.withValues(alpha: .18),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppTheme.ffAlt.withValues(alpha: .35)),
                        ),
                        child: Text('${e.key} • ${e.value}',
                            style: const TextStyle(color: Colors.white, fontSize: 12)),
                      ),
                  ],
                ),
              ),
            )
          ],
        ),
      ),
    );
  }
}

class _HighlightsRow extends StatelessWidget {
  const _HighlightsRow({required this.activeTopic, required this.counts, required this.onPick});
  final String activeTopic;
  final Map<String, int> counts;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final topics = _topics.where((t) => t != 'All').toList();
    return SizedBox(
      height: 86,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
        scrollDirection: Axis.horizontal,
        itemCount: topics.length,
        itemBuilder: (_, i) {
          final t = topics[i];
          final c = counts[t] ?? 0;
          final active = activeTopic == t || c > 0;
          final emoji = _topicEmoji[t] ?? '✨';
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: InkWell(
              onTap: () => onPick(t),
              borderRadius: BorderRadius.circular(999),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: active
                          ? const LinearGradient(
                              colors: [Colors.pinkAccent, Colors.orangeAccent],
                            )
                          : null,
                      border: active ? null : Border.all(color: Colors.white24),
                    ),
                    child: CircleAvatar(
                      radius: 26,
                      backgroundColor: const Color(0xFF15161A),
                      child: Text(emoji, style: const TextStyle(fontSize: 22)),
                    ),
                  ),
                  const SizedBox(height: 6),
                  SizedBox(
                    width: 64,
                    child: Text(
                      c > 0 ? '$t · $c' : t,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _DropdownPill<T> extends StatelessWidget {
  const _DropdownPill({
    required this.value,
    required this.items,
    required this.onChanged,
    required this.icon,
    this.display,
  });

  final T value;
  final List<T> items;
  final ValueChanged<T?> onChanged;
  final IconData icon;
  final String Function(T value)? display;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF121316),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.ffAlt.withValues(alpha: .35)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          icon: const Icon(Icons.expand_more, color: Colors.white70, size: 18),
          dropdownColor: const Color(0xFF0E0F11),
          onChanged: onChanged,
          items: items
              .map((e) => DropdownMenuItem<T>(
                    value: e,
                    child: Row(
                      children: [
                        Icon(icon, color: Colors.white54, size: 16),
                        const SizedBox(width: 8),
                        Text(
                          display != null ? display!(e) : e.toString(),
                          style: const TextStyle(color: Colors.white),
                        ),
                      ],
                    ),
                  ))
              .toList(),
        ),
      ),
    );
  }
}

class _ComposeFab extends StatelessWidget {
  const _ComposeFab({required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton.extended(
      onPressed: onPressed,
      backgroundColor: AppTheme.ffPrimary,
      icon: const Icon(Icons.edit, color: Colors.white),
      label: const Text('New',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    );
  }
}

class _FeedSkeleton extends StatelessWidget {
  const _FeedSkeleton();

  @override
  Widget build(BuildContext context) {
    Widget bar({double h = 14, double w = 120}) => Container(
          height: h,
          width: w,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: .06),
            borderRadius: BorderRadius.circular(8),
          ),
        );
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemBuilder: (_, __) => Container(
        decoration: BoxDecoration(
          color: AppTheme.ffPrimaryBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppTheme.ffAlt.withValues(alpha: .30), width: 1),
        ),
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              bar(h: 36, w: 36),
              const SizedBox(width: 10),
              bar(w: 160),
              const Spacer(),
              bar(w: 40),
            ]),
            const SizedBox(height: 10),
            bar(w: double.infinity),
            const SizedBox(height: 6),
            bar(w: double.infinity),
            const SizedBox(height: 6),
            bar(w: 180),
            const SizedBox(height: 8),
            Container(
              height: 160,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .04),
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ],
        ),
      ),
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemCount: 4,
    );
  }
}
// ─────────────────────────────────────────────────────────────────────────────
// Composer (create/edit)
class _ComposerSheet extends StatefulWidget {
  const _ComposerSheet({this.existing});
  final ConfessionItem? existing;

  @override
  State<_ComposerSheet> createState() => _ComposerSheetState();
}

class _ComposerSheetState extends State<_ComposerSheet> {
  final SupabaseClient _supa = Supabase.instance.client;
  final _text = TextEditingController();
  final _picker = ImagePicker();

  XFile? _picked;
  bool _anon = false;
  bool _posting = false;
  String _topic = 'Random';
  String _language = 'English';
  bool _nsfw = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _text.text = e.content;
      _topic = e.topic;
      _language = e.language;
      _nsfw = e.nsfw;
      _anon = e.isAnonymous;
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    try {
      final x = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
        maxWidth: 2000,
      );
      if (x != null) {
        setState(() => _picked = x);
      }
    } catch (e) {
      debugPrint('pick image error: $e');
    }
  }

  void _seedPrompt() {
    final seed = (_seedPrompts..shuffle()).first;
    final t = _text.text;
    if (t.trim().isEmpty) {
      _text.text = '$seed\n';
    } else {
      _text.text = '$t\n$seed\n';
    }
    _text.selection = TextSelection.collapsed(offset: _text.text.length);
    setState(() {});
  }

  Future<void> _submit() async {
    if (_posting) return;
    final content = _text.text.trim();
    if (content.isEmpty && _picked == null && widget.existing?.imageUrl == null) return;

    setState(() => _posting = true);
    final ctx = context;

    try {
      String? imageUrl = widget.existing?.imageUrl;

      if (_picked != null) {
        final bytes = await _picked!.readAsBytes();
        final ext = _picked!.name.split('.').last.toLowerCase();
        final me = _supa.auth.currentUser?.id ?? 'anon';
        final path =
            'u_$me/${DateTime.now().millisecondsSinceEpoch}.${ext.isEmpty ? 'jpg' : ext}';
        await _supa.storage.from('confessions').uploadBinary(
              path,
              bytes,
              fileOptions: const FileOptions(
                cacheControl: '3600',
                upsert: false,
                contentType: 'image/jpeg',
              ),
            );
        imageUrl = _supa.storage.from('confessions').getPublicUrl(path);
      }

      ConfessionItem result;

      if (widget.existing == null) {
        final row = await _supa
            .from('confessions')
            .insert({
              'content': content,
              'is_anonymous': _anon,
              'topic': _topic,
              'language': _language,
              'nsfw': _nsfw,
              if (imageUrl != null) 'image_url': imageUrl,
            })
            .select()
            .single();

        final res =
            await _supa.rpc('confessions_one', params: {'p_confession_id': row['id']});
        final list = (res as List?)?.cast<Map<String, dynamic>>() ?? const [];
        result = list.isNotEmpty
            ? ConfessionItem.fromRow(list.first)
            : ConfessionItem.fromRow(row);
      } else {
        final patch = <String, dynamic>{
          'content': content,
          'topic': _topic,
          'language': _language,
          'nsfw': _nsfw,
          'is_anonymous': _anon,
        };

        final removeExistingImage =
            _picked == null && widget.existing?.imageUrl != null && imageUrl == null;
        if (removeExistingImage) {
          patch['image_url'] = null;
        } else if (imageUrl != null) {
          patch['image_url'] = imageUrl;
        }

        final row = await _supa
            .from('confessions')
            .update(patch)
            .eq('id', widget.existing!.id)
            .select()
            .single();

        final res =
            await _supa.rpc('confessions_one', params: {'p_confession_id': row['id']});
        final list = (res as List?)?.cast<Map<String, dynamic>>() ?? const [];
        result = list.isNotEmpty
            ? ConfessionItem.fromRow(list.first)
            : ConfessionItem.fromRow(row);
      }

      _FeedCache.instance.upsert(result);
      if (!mounted) return;
      Navigator.of(ctx).pop<ConfessionItem>(result);
    } catch (e) {
      if (!mounted) return;
      showSnackSafe(ctx, "Couldn’t submit. Check your connection and try again.");
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    final isEdit = widget.existing != null;

    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: Container(
        decoration: const BoxDecoration(
          color: AppTheme.ffPrimaryBg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
          boxShadow: [BoxShadow(blurRadius: 20, color: Colors.black54)],
        ),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 4,
              width: 40,
              margin: const EdgeInsets.only(bottom: 10),
              decoration:
                  BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
            ),
            Row(
              children: [
                const Icon(Icons.auto_awesome, color: AppTheme.ffPrimary),
                const SizedBox(width: 8),
                Text(
                  isEdit ? 'Edit confession' : 'New confession',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                Row(
                  children: [
                    const Icon(Icons.person_outline, color: Colors.white54, size: 16),
                    const SizedBox(width: 6),
                    Switch(
                      value: _anon,
                      onChanged: (v) => setState(() => _anon = v),
                      thumbIcon: WidgetStateProperty.resolveWith(
                        (_) => Icon(_anon ? Icons.visibility_off : Icons.person),
                      ),
                      thumbColor: WidgetStateProperty.all(Colors.white),
                      trackColor: WidgetStateProperty.resolveWith(
                        (states) => states.contains(WidgetState.selected)
                            ? AppTheme.ffPrimary
                            : Colors.white24,
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _text,
              maxLines: 6,
              minLines: 3,
              textInputAction: TextInputAction.newline,
              decoration: const InputDecoration(
                hintText: "What's on your mind?",
                hintStyle: TextStyle(color: Colors.white54),
                border: InputBorder.none,
              ),
              style: const TextStyle(color: Colors.white),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _SmallDropdown<String>(
                    value: _topic,
                    items: _topics.where((t) => t != 'All').toList(),
                    icon: Icons.label_outline,
                    onChanged: (v) => setState(() => _topic = v ?? _topic),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _SmallDropdown<String>(
                    value: _language,
                    items: _languages.where((t) => t != 'All').toList(),
                    icon: Icons.language,
                    onChanged: (v) => setState(() => _language = v ?? _language),
                  ),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message: 'Mark as sensitive (NSFW)',
                  child: FilterChip(
                    label: const Text('NSFW'),
                    selected: _nsfw,
                    onSelected: (v) => setState(() => _nsfw = v),
                    selectedColor: Colors.red.withValues(alpha: .35),
                    backgroundColor: const Color(0xFF141414),
                    labelStyle: TextStyle(color: _nsfw ? Colors.white : Colors.white70),
                    side: BorderSide(color: Colors.red.withValues(alpha: .35)),
                  ),
                ),
              ],
            ),
            if (_picked != null || widget.existing?.imageUrl != null) ...[
              const SizedBox(height: 12),
              Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: _picked != null
                        ? FutureBuilder<Uint8List>(
                            future: _picked!.readAsBytes(),
                            builder: (context, snap) => SizedBox(
                              height: 180,
                              width: double.infinity,
                              child: snap.hasData
                                  ? Image.memory(snap.data!, fit: BoxFit.cover)
                                  : Container(color: const Color(0xFF202227)),
                            ),
                          )
                        : CachedNetworkImage(
                            imageUrl: widget.existing!.imageUrl!,
                            height: 180,
                            width: double.infinity,
                            fit: BoxFit.cover,
                            placeholder: (_, __) =>
                                Container(color: const Color(0xFF202227)),
                          ),
                  ),
                  Positioned(
                    right: 8,
                    top: 8,
                    child: Material(
                      color: Colors.black.withValues(alpha: .35),
                      borderRadius: BorderRadius.circular(10),
                      child: IconButton(
                        tooltip: 'Remove image',
                        icon: const Icon(Icons.close, color: Colors.white),
                        onPressed: () => setState(() {
                          _picked = null;
                          if (widget.existing != null) {
                            // clear preview only; actual removal handled in submit patch
                          }
                        }),
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                TextButton.icon(
                  onPressed: _seedPrompt,
                  icon: const Icon(Icons.auto_awesome, color: Colors.white),
                  label: const Text('Prompt', style: TextStyle(color: Colors.white)),
                ),
                const SizedBox(width: 4),
                TextButton.icon(
                  onPressed: _pickImage,
                  icon: const Icon(Icons.photo, color: Colors.white),
                  label: const Text('Photo', style: TextStyle(color: Colors.white)),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: _posting ? null : _submit,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.ffPrimary,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  icon: _posting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child:
                              CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : Icon(isEdit ? Icons.check : Icons.send,
                          size: 18, color: Colors.white),
                  label: Text(
                    isEdit ? 'Save' : 'Post',
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SmallDropdown<T> extends StatelessWidget {
  const _SmallDropdown({
    required this.value,
    required this.items,
    required this.icon,
    required this.onChanged,
  });

  final T value;
  final List<T> items;
  final IconData icon;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF121316),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.ffAlt.withValues(alpha: .35)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          icon: const Icon(Icons.expand_more, color: Colors.white70, size: 18),
          dropdownColor: const Color(0xFF0E0F11),
          onChanged: onChanged,
          items: items
              .map(
                (e) => DropdownMenuItem<T>(
                  value: e,
                  child: Row(
                    children: [
                      Icon(icon, color: Colors.white54, size: 16),
                      const SizedBox(width: 6),
                      Text(e.toString(), style: const TextStyle(color: Colors.white)),
                    ],
                  ),
                ),
              )
              .toList(),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Card + heart animation
class _ConfessionCard extends StatefulWidget {
  const _ConfessionCard({
    required this.item,
    required this.canEditDelete,
    required this.onToggleLike,
    required this.onOpenComments,
    required this.onTapImage,
    required this.onEdit,
    required this.onDelete,
    required this.onBookmark,
  });

  final ConfessionItem item;
  final bool canEditDelete;
  final VoidCallback onToggleLike;
  final VoidCallback onOpenComments;
  final void Function(String heroTag) onTapImage;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final Future<void> Function() onBookmark;

  @override
  State<_ConfessionCard> createState() => _ConfessionCardState();
}

class _ConfessionCardState extends State<_ConfessionCard>
    with SingleTickerProviderStateMixin {
  bool _hideNSFW = true;

  late final AnimationController _heartCtrl;
  late final Animation<double> _heartScale;
  late final Animation<double> _heartFade;

  @override
  void initState() {
    super.initState();
    _hideNSFW = widget.item.nsfw;
    _heartCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    );
    _heartScale = Tween<double>(begin: 0.6, end: 1.8)
        .chain(CurveTween(curve: Curves.easeOutBack))
        .animate(_heartCtrl);
    _heartFade = Tween<double>(begin: 0.9, end: 0.0)
        .chain(CurveTween(curve: Curves.easeOut))
        .animate(_heartCtrl);
  }

  @override
  void didUpdateWidget(covariant _ConfessionCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.nsfw != widget.item.nsfw) {
      _hideNSFW = widget.item.nsfw;
    }
  }

  @override
  void dispose() {
    _heartCtrl.dispose();
    super.dispose();
  }

  void _burstHeart() {
    _heartCtrl.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final it = widget.item;
    final saved = _BookmarkStore.instance.isSaved(it.id);

    final isAnon = it.isAnonymous;
    final name = isAnon ? 'Anonymous' : (it.authorName ?? 'Someone');
    final avatar = isAnon ? null : it.authorAvatarUrl;

    final tag = 'conf_img_${it.id}';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.ffPrimaryBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppTheme.ffAlt.withValues(alpha: .30), width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // header
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 4),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: Colors.white10,
                    backgroundImage:
                        avatar != null ? CachedNetworkImageProvider(avatar) : null,
                    child: avatar == null
                        ? const Icon(Icons.person, color: Colors.white54)
                        : null,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            _TopicChip(text: it.topic),
                            const SizedBox(width: 6),
                            _LangChip(text: it.language),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Text(
                              _timeAgo(it.createdAt),
                              style: const TextStyle(
                                  color: Colors.white54, fontSize: 12),
                            ),
                            if (it.editedAt != null) ...[
                              const SizedBox(width: 6),
                              const Text('·', style: TextStyle(color: Colors.white38)),
                              const SizedBox(width: 6),
                              const Text('edited',
                                  style:
                                      TextStyle(color: Colors.white54, fontSize: 12)),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'More',
                    icon: const Icon(Icons.more_horiz, color: Colors.white70),
                    color: const Color(0xFF0E0F11),
                    onSelected: (v) async {
                      if (v == 'copy') {
                        await Clipboard.setData(ClipboardData(text: it.content));
                        if (!mounted) return;
                        showSnackSafe(context, 'Copied to clipboard');
                      } else if (v == 'edit') {
                        widget.onEdit();
                      } else if (v == 'delete') {
                        widget.onDelete();
                      } else if (v == 'report') {
                        try {
                          await Supabase.instance.client
                              .rpc('report_confession', params: {
                            'p_confession_id': it.id,
                            'p_reason': 'inappropriate',
                          });
                          if (!mounted) return;
                          showSnackSafe(context, 'Reported.');
                        } catch (_) {}
                      }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'copy', child: Text('Copy text')),
                      if (widget.canEditDelete)
                        const PopupMenuItem(value: 'edit', child: Text('Edit')),
                      if (widget.canEditDelete)
                        const PopupMenuItem(
                          value: 'delete',
                          child:
                              Text('Delete', style: TextStyle(color: Colors.redAccent)),
                        ),
                      const PopupMenuItem(value: 'report', child: Text('Report')),
                    ],
                  ),
                ],
              ),
            ),

            if (it.content.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 2, 14, 10),
                child: Text(
                  it.content,
                  style: const TextStyle(color: Colors.white, height: 1.35),
                ),
              ),

            if (it.imageUrl != null)
              GestureDetector(
                onDoubleTap: () {
                  widget.onToggleLike();
                  _burstHeart();
                  HapticFeedback.lightImpact();
                },
                onTap: () {
                  if (_hideNSFW) {
                    setState(() => _hideNSFW = false);
                    return;
                  }
                  widget.onTapImage(tag);
                },
                child: Hero(
                  tag: tag,
                  child: ClipRRect(
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(0),
                      bottom: Radius.circular(14),
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        CachedNetworkImage(
                          imageUrl: it.imageUrl!,
                          fit: BoxFit.cover,
                          width: double.infinity,
                          placeholder: (_, __) =>
                              Container(height: 220, color: const Color(0xFF202227)),
                          errorWidget: (_, __, ___) => Container(
                            height: 220,
                            color: const Color(0xFF1E1F24),
                            child: const Center(
                              child: Icon(Icons.broken_image, color: Colors.white38),
                            ),
                          ),
                        ),
                        // Heart burst overlay
                        IgnorePointer(
                          child: FadeTransition(
                            opacity: _heartFade,
                            child: ScaleTransition(
                              scale: _heartScale,
                              child: Icon(
                                Icons.favorite,
                                size: 96,
                                color: it.likedByMe
                                    ? Colors.pinkAccent.withValues(alpha: .95)
                                    : Colors.white.withValues(alpha: .85),
                              ),
                            ),
                          ),
                        ),
                        if (_hideNSFW)
                          Positioned.fill(
                            child: ClipRect(
                              child: BackdropFilter(
                                filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                                child: Container(
                                  color: Colors.black.withValues(alpha: .40),
                                  alignment: Alignment.center,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: Colors.red.withValues(alpha: .65),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: const Text(
                                      'NSFW — tap to reveal',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),

            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 0, 6, 10),
              child: Row(
                children: [
                  _PillButton(
                    icon: it.likedByMe ? Icons.favorite : Icons.favorite_border,
                    color: it.likedByMe ? Colors.pinkAccent : Colors.white,
                    label: it.likeCount.toString(),
                    onTap: () {
                      widget.onToggleLike();
                      HapticFeedback.lightImpact();
                      _burstHeart();
                    },
                  ),
                  const SizedBox(width: 6),
                  _PillButton(
                    icon: Icons.mode_comment_outlined,
                    color: Colors.white,
                    label: it.commentCount.toString(),
                    onTap: widget.onOpenComments,
                  ),
                  const SizedBox(width: 6),
                  _PillButton(
                    icon: saved ? Icons.bookmark : Icons.bookmark_border,
                    color: saved ? AppTheme.ffPrimary : Colors.white,
                    label: 'Save',
                    onTap: () async {
                      await widget.onBookmark();
                      if (mounted) setState(() {});
                    },
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Share link',
                    icon: const Icon(Icons.share, color: Colors.white70),
                    onPressed: () async {
                      final url =
                          'https://yourapp.example/confession/${it.id}'; // replace with real deep link
                      await Clipboard.setData(ClipboardData(text: url));
                      if (!mounted) return;
                      showSnackSafe(context, 'Link copied');
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopicChip extends StatelessWidget {
  const _TopicChip({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppTheme.ffPrimary.withValues(alpha: .18),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.ffAlt.withValues(alpha: .35), width: 1),
      ),
      child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 11, height: 1)),
    );
  }
}

class _LangChip extends StatelessWidget {
  const _LangChip({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF141414),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.ffAlt.withValues(alpha: .35), width: 1),
      ),
      child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 11, height: 1)),
    );
  }
}

class _PillButton extends StatelessWidget {
  const _PillButton({
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white10,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            children: [
              Icon(icon, color: color, size: 18),
              const SizedBox(width: 6),
              Text(label, style: const TextStyle(color: Colors.white)),
            ],
          ),
        ),
      ),
    );
  }
}
// ─────────────────────────────────────────────────────────────────────────────
// Comments bottom sheet (paginated + optimistic insert + cache)
class _CommentsSheet extends StatefulWidget {
  const _CommentsSheet({required this.confessionId});
  final String confessionId;

  @override
  State<_CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends State<_CommentsSheet> {
  final SupabaseClient _supa = Supabase.instance.client;
  final _scroll = ScrollController();
  final _input = TextEditingController();

  static const int _pageSize = 20;
  final List<CommentItem> _items = <CommentItem>[];

  bool _loading = true;
  bool _posting = false;
  bool _fetchingMore = false;
  bool _end = false;

  @override
  void initState() {
    super.initState();
    // Seed from cache if fresh
    final cache = _CommentsCache.instance;
    if (cache.fresh(widget.confessionId)) {
      _items.addAll(cache.get(widget.confessionId));
      _loading = false;
    }
    _load(initial: true);
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _input.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 300) {
      _loadMore();
    }
  }

  Future<void> _load({bool initial = false}) async {
    if (initial) setState(() => _loading = true);
    try {
      final rows = await _supa
          .from('confession_comments')
          .select(
              '''
              id, confession_id, author_user_id, text, created_at,
              profiles:confession_comments_author_user_id_fkey(name, profile_pictures)
              ''')
          .eq('confession_id', widget.confessionId)
          .order('created_at', ascending: false)
          .range(0, _pageSize - 1);

      final list = (rows as List?)?.cast<Map<String, dynamic>>() ?? const [];
      final mapped = list.map(_mapCommentRow).toList();

      if (!mounted) return;
      setState(() {
        if (_items.isEmpty) {
          _items.addAll(mapped);
        } else {
          // Replace initial window to avoid dupes
          _items
            ..clear()
            ..addAll(mapped);
        }
        _end = mapped.length < _pageSize;
        _loading = false;
      });
      _CommentsCache.instance.seed(widget.confessionId, _items);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      debugPrint('comments load error: $e');
    }
  }

  Future<void> _loadMore() async {
    if (_fetchingMore || _end) return;
    setState(() => _fetchingMore = true);
    try {
      final offset = _items.length;
      final rows = await _supa
          .from('confession_comments')
          .select(
              '''
              id, confession_id, author_user_id, text, created_at,
              profiles:confession_comments_author_user_id_fkey(name, profile_pictures)
              ''')
          .eq('confession_id', widget.confessionId)
          .order('created_at', ascending: false)
          .range(offset, offset + _pageSize - 1);

      final list = (rows as List?)?.cast<Map<String, dynamic>>() ?? const [];
      final mapped = list.map(_mapCommentRow).toList();

      if (!mounted) return;
      setState(() {
        _items.addAll(mapped);
        if (mapped.length < _pageSize) _end = true;
      });

      // Refresh cache head only (we keep latest first)
      if (_items.isNotEmpty) {
        _CommentsCache.instance.seed(widget.confessionId, _items.take(_CommentsCache.capPerPost).toList());
      }
    } catch (e) {
      debugPrint('comments loadMore error: $e');
    } finally {
      if (mounted) setState(() => _fetchingMore = false);
    }
  }

  Map<String, dynamic> _flattenProfile(Map<String, dynamic> row) {
    final prof = (row['profiles'] as Map?) ?? const {};
    final pics = (prof['profile_pictures'] as List?) ?? const [];
    final avatar = pics.isNotEmpty ? pics.first?.toString() : null;
    return {
      ...row,
      'author_name': (prof['name'] ?? 'Someone').toString(),
      'author_avatar_url': avatar,
    };
  }

  CommentItem _mapCommentRow(Map<String, dynamic> r) =>
      CommentItem.fromRow(_flattenProfile(r));

  Future<void> _post() async {
    if (_posting) return;
    final text = _input.text.trim();
    if (text.isEmpty) return;

    final ctx = context;
    setState(() => _posting = true);

    // optimistic
    final uid = _supa.auth.currentUser?.id ?? 'me';
    final temp = CommentItem(
      id: 'temp-${DateTime.now().microsecondsSinceEpoch}',
      confessionId: widget.confessionId,
      authorUserId: uid,
      authorName: 'You',
      authorAvatarUrl: null,
      text: text,
      createdAt: DateTime.now().toUtc(),
    );
    setState(() {
      _items.insert(0, temp);
      _input.clear();
    });
    _CommentsCache.instance.appendNewTop(widget.confessionId, temp);

    try {
      final row = await _supa
          .from('confession_comments')
          .insert({
            'confession_id': widget.confessionId,
            'author_user_id': uid, // RLS CHECK
            'text': text,
          })
          .select(
              '''
              id, confession_id, author_user_id, text, created_at,
              profiles:confession_comments_author_user_id_fkey(name, profile_pictures)
              ''')
          .single();

      final real = _mapCommentRow((row as Map).cast<String, dynamic>());
      if (!mounted) return;
      setState(() {
        final idx = _items.indexWhere((c) => c.id == temp.id);
        if (idx != -1) {
          _items[idx] = real;
        } else {
          _items.insert(0, real);
        }
      });
      _CommentsCache.instance.appendNewTop(widget.confessionId, real);
    } catch (e) {
      if (!mounted) return;
      // rollback optimistic
      setState(() {
        _items.removeWhere((c) => c.id == temp.id);
      });
      showSnackSafe(ctx, 'Failed to comment.');
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final kb = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: kb),
      child: Container(
        decoration: const BoxDecoration(
          color: AppTheme.ffPrimaryBg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        height: MediaQuery.of(context).size.height * .88,
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(height: 4, width: 40, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 10),
            Row(
              children: [
                const SizedBox(width: 12),
                const Text('Comments', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white70),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const Divider(height: 1, color: Colors.white12),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                      itemCount: _items.length + (_fetchingMore ? 1 : 0),
                      itemBuilder: (_, i) {
                        if (i >= _items.length) {
                          return const Padding(
                            padding: EdgeInsets.symmetric(vertical: 18),
                            child: Center(child: CircularProgressIndicator()),
                          );
                        }
                        final c = _items[i];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              CircleAvatar(
                                radius: 16,
                                backgroundColor: Colors.white10,
                                backgroundImage: (c.authorAvatarUrl ?? '').isNotEmpty
                                    ? CachedNetworkImageProvider(c.authorAvatarUrl!)
                                    : null,
                                child: (c.authorAvatarUrl ?? '').isEmpty
                                    ? const Icon(Icons.person, color: Colors.white54, size: 18)
                                    : null,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Flexible(
                                          child: Text(
                                            c.authorName,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                                color: Colors.white, fontWeight: FontWeight.w600),
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        Text(_timeAgo(c.createdAt),
                                            style: const TextStyle(color: Colors.white54, fontSize: 12)),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Text(c.text, style: const TextStyle(color: Colors.white)),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
            const Divider(height: 1, color: Colors.white12),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _post(),
                      decoration: InputDecoration(
                        hintText: 'Add a comment…',
                        hintStyle: const TextStyle(color: Colors.white54),
                        filled: true,
                        fillColor: const Color(0xFF121316),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: AppTheme.ffAlt.withValues(alpha: .35)),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: AppTheme.ffAlt.withValues(alpha: .35)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: AppTheme.ffPrimary.withValues(alpha: .55)),
                        ),
                      ),
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _posting ? null : _post,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.ffPrimary,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: _posting
                        ? const SizedBox(
                            width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.send, color: Colors.white, size: 18),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Detail page (full-view, reuses card layout pieces)
class _ConfessionDetailPageState extends State<ConfessionDetailPage> {
  final SupabaseClient _supa = Supabase.instance.client;
  ConfessionItem? _item;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _hydrate();
  }

  Future<void> _hydrate() async {
    setState(() => _loading = true);
    try {
      final res = await _supa.rpc('confessions_one', params: {
        'p_confession_id': widget.confessionId,
      });
      final list = (res as List?)?.cast<Map<String, dynamic>>() ?? const [];
      final me = _supa.auth.currentUser?.id;
      final it = list.isNotEmpty ? ConfessionItem.fromRow(list.first, me: me) : null;
      if (!mounted) return;
      setState(() {
        _item = it;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      debugPrint('detail hydrate error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final it = _item;

    return Scaffold(
      backgroundColor: AppTheme.ffSecondaryBg,
      appBar: AppBar(
        backgroundColor: AppTheme.ffSecondaryBg,
        title: const Text('Confession', style: TextStyle(color: Colors.white)),
      ),
      body: _loading || it == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
              children: [
                if (it.imageUrl != null)
                  Hero(
                    tag: widget.heroTag ?? 'conf_img_${it.id}',
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: CachedNetworkImage(
                        imageUrl: it.imageUrl!,
                        fit: BoxFit.cover,
                        placeholder: (_, __) =>
                            Container(height: 240, color: const Color(0xFF202227)),
                        errorWidget: (_, __, ___) => Container(
                          height: 240,
                          color: const Color(0xFF1E1F24),
                          child: const Center(
                              child: Icon(Icons.broken_image, color: Colors.white38)),
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    _TopicChip(text: it.topic),
                    const SizedBox(width: 8),
                    _LangChip(text: it.language),
                    const Spacer(),
                    Text(_timeAgo(it.createdAt),
                        style: const TextStyle(color: Colors.white54)),
                  ],
                ),
                const SizedBox(height: 10),
                if (it.content.isNotEmpty)
                  Text(it.content,
                      style: const TextStyle(color: Colors.white, height: 1.35)),
                const SizedBox(height: 12),
                Row(
                  children: [
                    _PillButton(
                      icon: it.likedByMe ? Icons.favorite : Icons.favorite_border,
                      color: it.likedByMe ? Colors.pinkAccent : Colors.white,
                      label: it.likeCount.toString(),
                      onTap: () async {
                        final feed = _FeedCache.instance.items;
                        final existing = feed.firstWhere(
                          (e) => e.id == it.id,
                          orElse: () => it,
                        );
                        final updated = await Supabase.instance.client
                            .rpc('toggle_confession_like', params: {'p_confession_id': it.id});
                        if (!mounted) return;
                        final list =
                            (updated as List?)?.cast<Map<String, dynamic>>() ?? const [];
                        if (list.isNotEmpty) {
                          final liked = (list.first['liked'] as bool?) ?? it.likedByMe;
                          final count =
                              (list.first['like_count'] as int?) ?? it.likeCount;
                          final fixed = it.copyWith(likedByMe: liked, likeCount: count);
                          setState(() => _item = fixed);
                          _FeedCache.instance.upsert(
                              existing.copyWith(likedByMe: liked, likeCount: count));
                        }
                      },
                    ),
                    const SizedBox(width: 6),
                    _PillButton(
                      icon: Icons.mode_comment_outlined,
                      color: Colors.white,
                      label: it.commentCount.toString(),
                      onTap: () => showModalBottomSheet(
                        context: context,
                        isScrollControlled: true,
                        useSafeArea: true,
                        backgroundColor: Colors.transparent,
                        builder: (_) =>
                            _CommentsSheet(confessionId: widget.confessionId),
                      ),
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Recent search picker sheet
class _RecentSearchSheet extends StatelessWidget {
  const _RecentSearchSheet({required this.recents, required this.onRemove});
  final List<String> recents;
  final Future<void> Function(String) onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.ffPrimaryBg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      height: MediaQuery.of(context).size.height * .6,
      child: Column(
        children: [
          Container(height: 4, width: 40, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 10),
          const Text('Recent searches', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          Expanded(
            child: recents.isEmpty
                ? const Center(child: Text('No recent searches', style: TextStyle(color: Colors.white54)))
                : ListView.separated(
                    itemBuilder: (_, i) {
                      final q = recents[i];
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                        leading: const Icon(Icons.history, color: Colors.white54),
                        title: Text(q, style: const TextStyle(color: Colors.white)),
                        trailing: IconButton(
                          tooltip: 'Remove',
                          icon: const Icon(Icons.close, color: Colors.white54),
                          onPressed: () async => onRemove(q),
                        ),
                        onTap: () => Navigator.of(context).pop<String>(q),
                      );
                    },
                    separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white12),
                    itemCount: recents.length,
                  ),
          ),
        ],
      ),
    );
  }
}
