// =========================
// FILE: lib/features/confessions/confessions_feature.dart
// =========================
// Confessions v4 (2025 revamp, FIXED) — modern micro‑interactions, trending sort,
// recent-search memory, double‑tap like, hold‑to‑reveal NSFW, topic trends,
// improved composer prompts, and swipe‑ish gestures — keeping all class/file
// names the same for drop‑in replacement.
//
// Lint fixes:
// - no_leading_underscores_for_local_identifiers (renamed helper locals)
// - curly_braces_in_flow_control_structures (while {...})
// - prefer_interpolation_to_compose_strings ("$p\n")
// - await_only_futures/use_of_void_result (onToggleLike now Future<void> Function())
// - use_build_context_synchronously (use context.mounted in async UI points)
// - unnecessary_to_list_in_spreads (removed .toList() with spread)
//
// Deps unchanged.

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
// Routes
class ConfessionsFeedPage extends StatefulWidget {
  const ConfessionsFeedPage({super.key});
  static const String routeName = 'ConfessionsFeed';
  static const String routePath = '/confessions';

  @override
  State<ConfessionsFeedPage> createState() => _ConfessionsFeedPageState();
}

class ConfessionDetailPage extends StatefulWidget {
  const ConfessionDetailPage({
    super.key,
    required this.confessionId,
    this.heroTag,
  });
  final String confessionId;
  final String? heroTag;

  static const String routeName = 'ConfessionDetail';
  static const String routePath = '/confession';

  @override
  State<ConfessionDetailPage> createState() => _ConfessionDetailPageState();
}

// ─────────────────────────────────────────────────────────────────────────────
// Constants / Choices
const _topics = <String>[
  'All',
  'Love',
  'Campus',
  'Work',
  'Family',
  'Money',
  'Friends',
  'Random',
];

const _languages = <String>[
  'All',
  'English',
  'Afrikaans',
  'Zulu',
  'Xhosa',
  'Sotho',
  'French',
  'Spanish',
];

// Composer seed prompts (client-only)
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
// Local bookmarks (client-only)
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

// Recent search memory (client-only)
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

  // UI state
  String _topic = _topics.first; // 'All'
  String _language = _languages.first; // 'All'
  _Sort _sort = _Sort.trending; // default to trendy feed
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
      if (initial) setState(() => _loading = true);
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
      final rows = await _supa.rpc('confessions_feed', params: {
        'limit_arg': _pageSize,
        'offset_arg': _items.length,
      });
      final list = (rows as List?)?.cast<Map<String, dynamic>>() ?? const [];
      final mapped = list.map((r) => ConfessionItem.fromRow(r, me: me)).toList();
      if (!mounted) return;
      setState(() {
        _items.addAll(mapped);
        if (mapped.length < _pageSize) _end = true;
      });
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

      HapticFeedback.lightImpact();

      final rows = await _supa.rpc('toggle_confession_like', params: {
        'p_confession_id': item.id,
      });
      final list = (rows as List?)?.cast<Map<String, dynamic>>() ?? const [];
      if (list.isEmpty) return optimistic;
      final liked = (list.first['liked'] as bool?) ?? optimistic.likedByMe;
      final count = (list.first['like_count'] as int?) ?? optimistic.likeCount;
      return item.copyWith(likedByMe: liked, likeCount: count);
    } catch (e) {
      debugPrint('toggle like error: $e');
      return null;
    }
  }

  Future<void> _openComments(String confessionId) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CommentsSheet(confessionId: confessionId),
    );
  }

  Future<void> _openComposer({ConfessionItem? edit}) async {
    await showModalBottomSheet<ConfessionItem?>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ComposerSheet(
        existing: edit,
      ),
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
    });
  }

  Future<void> _deletePost(ConfessionItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.ffPrimaryBg,
        title: const Text('Delete confession?', style: TextStyle(color: Colors.white)),
        content: const Text(
          'This action cannot be undone.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
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
      if (!context.mounted) return;
      setState(() => _items.insert(idx, removed));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to delete.')),
      );
    }
  }

  // UI helpers ----------------------------------------------------------------
  double _hotScore(ConfessionItem e) {
    final ageHours = math.max(1, DateTime.now().toUtc().difference(e.createdAt).inMinutes / 60);
    final score = (e.likeCount + 1) / math.pow(ageHours, 1.4);
    return score.toDouble();
  }

  Iterable<ConfessionItem> get _visible {
    Iterable<ConfessionItem> xs = _items;

    if (_bookmarksOnly) {
      xs = xs.where((e) => _BookmarkStore.instance.isSaved(e.id));
    }
    if (_topic != 'All') {
      xs = xs.where((e) => e.topic.toLowerCase() == _topic.toLowerCase());
    }
    if (_language != 'All') {
      xs = xs.where((e) => e.language.toLowerCase() == _language.toLowerCase());
    }
    if (_query.trim().isNotEmpty) {
      final q = _query.trim().toLowerCase();
      xs = xs.where((e) =>
          e.content.toLowerCase().contains(q) ||
          e.topic.toLowerCase().contains(q) ||
          (e.authorName ?? '').toLowerCase().contains(q));
    }

    if (_sort == _Sort.latest) {
      xs = xs.toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    } else if (_sort == _Sort.top) {
      xs = xs.toList()
        ..sort((a, b) => (b.likeCount).compareTo(a.likeCount));
    } else {
      xs = xs.toList()
        ..sort((a, b) => _hotScore(b).compareTo(_hotScore(a)));
    }
    return xs;
  }

  Future<void> _onSearchSubmitted(String v) async {
    setState(() => _query = v);
    await _recentSearch.push(v);
  }

  Future<void> _openSearchSheet() async {
    final recents = await _recentSearch.all();
    if (!mounted) return;
    await showModalBottomSheet<String>(
      context: context,
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
              : CustomScrollView(
                  controller: _scroll,
                  slivers: [
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
                                  transitionsBuilder: (_, anim, __, child) =>
                                      FadeTransition(opacity: anim, child: child),
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
      floatingActionButton: _ComposeFab(onPressed: () => _openComposer()),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// App Bar + Filters
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
            border: Border.all(color: AppTheme.ffAlt.withValues(alpha: .35), width: 1),
          ),
          child: Row(
            children: [
              const SizedBox(width: 10),
              const Icon(Icons.search, color: Colors.white70, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
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
        // Topics row
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
        // Language / Sort + inline CTA
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: Row(
            children: [
              _DropdownPill<String>(
                value: language,
                items: _languages,
                onChanged: (v) => onLanguage(v ?? 'All'),
                icon: Icons.language,
              ),
              const SizedBox(width: 8),
              _DropdownPill<_Sort>(
                value: sort,
                items: const [_Sort.trending, _Sort.latest, _Sort.top],
                display: (s) => s == _Sort.latest
                    ? 'Latest'
                    : s == _Sort.top
                        ? 'Top'
                        : 'Trending',
                onChanged: (v) => onSort(v ?? _Sort.trending),
                icon: Icons.auto_graph,
              ),
              const SizedBox(width: 8),
              FilterChip(
                label: const Text('Bookmarks'),
                selected: bookmarksOnly,
                onSelected: (_) => onToggleBookmarksOnly(),
                selectedColor: AppTheme.ffPrimary.withValues(alpha: .35),
                backgroundColor: const Color(0xFF141414),
                labelStyle: TextStyle(color: bookmarksOnly ? Colors.white : Colors.white70),
                side: BorderSide(color: AppTheme.ffAlt.withValues(alpha: .55)),
              ),
              const Spacer(),
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
    final top = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
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
                    for (final e in show) ...[
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
                    ]
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
      label: const Text('New', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
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

  String? _suggestion; // seed prompt

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
    } else {
      _suggestion = (_seedPrompts.toList()..shuffle()).first;
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
      if (x != null) setState(() => _picked = x);
    } catch (e) {
      debugPrint('pick image error: $e');
    }
  }

  Future<void> _submit() async {
    if (_posting) return;
    final content = _text.text.trim();
    if (content.isEmpty && _picked == null && widget.existing?.imageUrl == null) return;

    setState(() => _posting = true);

    try {
      String? imageUrl = widget.existing?.imageUrl;

      if (_picked != null) {
        final bytes = await _picked!.readAsBytes();
        final ext = _picked!.name.split('.').last.toLowerCase();
        final me = _supa.auth.currentUser?.id ?? 'anon';
        final path = 'u_$me/${DateTime.now().millisecondsSinceEpoch}.${ext.isEmpty ? 'jpg' : ext}';
        await _supa.storage.from('confessions').uploadBinary(
              path,
              bytes,
              fileOptions:
                  const FileOptions(cacheControl: '3600', upsert: false, contentType: 'image/jpeg'),
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

        final res = await _supa.rpc('confessions_one', params: {
          'p_confession_id': row['id'],
        });
        final list = (res as List?)?.cast<Map<String, dynamic>>() ?? const [];
        result = list.isNotEmpty ? ConfessionItem.fromRow(list.first) : ConfessionItem.fromRow(row);
      } else {
        final patch = <String, dynamic>{
          'content': content,
          'topic': _topic,
          'language': _language,
          'nsfw': _nsfw,
          'is_anonymous': _anon,
        };

        final bool removeExistingImage =
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

        final res = await _supa.rpc('confessions_one', params: {
          'p_confession_id': row['id'],
        });
        final list = (res as List?)?.cast<Map<String, dynamic>>() ?? const [];
        result = list.isNotEmpty ? ConfessionItem.fromRow(list.first) : ConfessionItem.fromRow(row);
      }

      if (!context.mounted) return;
      Navigator.of(context).pop<ConfessionItem>(result);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text('Couldn’t submit. Check your connection and try again.'),
        ),
      );
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
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Row(
              children: [
                const Icon(Icons.auto_awesome, color: AppTheme.ffPrimary),
                const SizedBox(width: 8),
                Text(isEdit ? 'Edit confession' : 'New confession',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                const Spacer(),
                Row(
                  children: [
                    const Icon(Icons.person_outline, color: Colors.white54, size: 16),
                    const SizedBox(width: 6),
                    Switch(
                      value: _anon,
                      onChanged: (v) => setState(() => _anon = v),
                      thumbIcon: WidgetStateProperty.resolveWith((_) =>
                          Icon(_anon ? Icons.visibility_off : Icons.person)),
                      thumbColor: WidgetStateProperty.all(Colors.white),
                      trackColor: WidgetStateProperty.resolveWith(
                        (states) =>
                            states.contains(WidgetState.selected) ? AppTheme.ffPrimary : Colors.white24,
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 10),

            if (_suggestion != null && _text.text.trim().isEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final p in _seedPrompts)
                      ActionChip(
                        label: Text(p, style: const TextStyle(color: Colors.white70)),
                        backgroundColor: const Color(0xFF1A1B1F),
                        onPressed: () {
                          setState(() {
                            _text.text = "$p\n";
                            _text.selection = TextSelection.collapsed(offset: _text.text.length);
                          });
                        },
                      ),
                  ],
                ),
              ),

            const SizedBox(height: 8),
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
                            placeholder: (_, __) => Container(color: const Color(0xFF202227)),
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
                          _picked = null; // removal intent
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
                  onPressed: _pickImage,
                  icon: const Icon(Icons.photo, color: Colors.white),
                  label: const Text('Add Photo', style: TextStyle(color: Colors.white)),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: _posting ? null : _submit,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.ffPrimary,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  icon: _posting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : Icon(isEdit ? Icons.check : Icons.send, size: 18, color: Colors.white),
                  label: Text(isEdit ? 'Save' : 'Post',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
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
// Card + Detail + Comments + Skeleton
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
  final Future<void> Function() onToggleLike; // changed to Future for awaits
  final VoidCallback onOpenComments;
  final void Function(String heroTag) onTapImage;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final Future<void> Function() onBookmark;

  @override
  State<_ConfessionCard> createState() => _ConfessionCardState();
}

class _ConfessionCardState extends State<_ConfessionCard> with SingleTickerProviderStateMixin {
  bool _hideNSFW = true;
  late final AnimationController _likeCtl;
  late final Animation<double> _likeScale;
  bool _pressing = false;

  @override
  void initState() {
    super.initState();
    _hideNSFW = widget.item.nsfw;
    _likeCtl = AnimationController(vsync: this, duration: const Duration(milliseconds: 380));
    _likeScale = Tween<double>(begin: .6, end: 1.0).chain(CurveTween(curve: Curves.easeOutBack)).animate(_likeCtl);
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
    _likeCtl.dispose();
    super.dispose();
  }

  Future<void> _onDoubleTapLike() async {
    if (widget.item.likedByMe) {
      _likeCtl.forward(from: 0);
      return;
    }
    _likeCtl.forward(from: 0);
    await widget.onToggleLike();
  }

  Future<void> _onSwipeBookmark(DragEndDetails d) async {
    final vx = d.primaryVelocity ?? 0;
    if (vx.abs() < 400) return;
    await widget.onBookmark();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Saved to bookmarks'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final it = widget.item;
    final saved = _BookmarkStore.instance.isSaved(it.id);

    final isAnon = it.isAnonymous;
    final name = isAnon ? 'Anonymous' : (it.authorName ?? 'Someone');
    final avatar = isAnon ? null : it.authorAvatarUrl;

    final tag = 'conf_img_${it.id}';

    return GestureDetector(
      onHorizontalDragEnd: _onSwipeBookmark,
      onTapDown: (_) => setState(() => _pressing = true),
      onTapCancel: () => setState(() => _pressing = false),
      onTapUp: (_) => setState(() => _pressing = false),
      onDoubleTap: _onDoubleTapLike,
      behavior: HitTestBehavior.opaque,
      child: AnimatedScale(
        duration: const Duration(milliseconds: 120),
        scale: _pressing ? .99 : 1,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Container(
            decoration: BoxDecoration(
              color: AppTheme.ffPrimaryBg,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppTheme.ffAlt.withValues(alpha: .30), width: 1),
            ),
            child: Stack(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 8, 4),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 18,
                            backgroundColor: Colors.white10,
                            backgroundImage: avatar != null ? CachedNetworkImageProvider(avatar) : null,
                            child: avatar == null ? const Icon(Icons.person, color: Colors.white54) : null,
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
                                        style:
                                            const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
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
                                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                                    ),
                                    if (it.editedAt != null) ...[
                                      const SizedBox(width: 6),
                                      const Text('·', style: TextStyle(color: Colors.white38)),
                                      const SizedBox(width: 6),
                                      const Text('edited',
                                          style: TextStyle(color: Colors.white54, fontSize: 12)),
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
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context)
                                    .showSnackBar(const SnackBar(content: Text('Copied to clipboard')));
                              } else if (v == 'edit') {
                                widget.onEdit();
                              } else if (v == 'delete') {
                                widget.onDelete();
                              } else if (v == 'report') {
                                try {
                                  await Supabase.instance.client.rpc('report_confession', params: {
                                    'p_confession_id': it.id,
                                    'p_reason': 'inappropriate',
                                  });
                                  if (!context.mounted) return;
                                  ScaffoldMessenger.of(context)
                                      .showSnackBar(const SnackBar(content: Text('Reported.')));
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
                                    child: Text('Delete', style: TextStyle(color: Colors.redAccent))),
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
                        onTap: () {
                          if (_hideNSFW) {
                            setState(() => _hideNSFW = false);
                            HapticFeedback.selectionClick();
                            return;
                          }
                          widget.onTapImage(tag);
                        },
                        onLongPress: () => setState(() => _hideNSFW = false),
                        child: Hero(
                          tag: tag,
                          child: ClipRRect(
                            borderRadius:
                                const BorderRadius.vertical(top: Radius.circular(0), bottom: Radius.circular(14)),
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                CachedNetworkImage(
                                  imageUrl: it.imageUrl!,
                                  fit: BoxFit.cover,
                                  width: double.infinity,
                                  placeholder: (_, __) => Container(height: 220, color: const Color(0xFF202227)),
                                  errorWidget: (_, __, ___) => Container(
                                    height: 220,
                                    color: const Color(0xFF1E1F24),
                                    child: const Center(
                                      child: Icon(Icons.broken_image, color: Colors.white38),
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
                                            padding:
                                                const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                            decoration: BoxDecoration(
                                              color: Colors.red.withValues(alpha: .65),
                                              borderRadius: BorderRadius.circular(8),
                                            ),
                                            child: const Text(
                                              'NSFW — tap to reveal',
                                              style: TextStyle(
                                                  color: Colors.white, fontWeight: FontWeight.w700),
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
                            onTap: () { widget.onToggleLike(); },
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
                              final url = 'https://yourapp.example/confession/${it.id}';
                              await Clipboard.setData(ClipboardData(text: url));
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context)
                                  .showSnackBar(const SnackBar(content: Text('Link copied')));
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                // Heart burst overlay on double-tap
                Positioned.fill(
                  child: IgnorePointer(
                    child: AnimatedBuilder(
                      animation: _likeCtl,
                      builder: (_, __) {
                        final t = _likeCtl.value;
                        final opacity = t < .1
                            ? t * 10
                            : t > .8
                                ? (1 - t) / .2
                                : 1.0;
                        return Opacity(
                          opacity: opacity.clamp(0, 1).toDouble(),
                          child: Center(
                            child: Transform.scale(
                              scale: _likeScale.value,
                              child: const Icon(Icons.favorite, size: 96, color: Colors.pinkAccent),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
// =========================
// FILE: lib/features/confessions/confessions_feature.dart
// =========================
// (Full) — Part 2/2

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

// Detail Page
class _ConfessionDetailPageState extends State<ConfessionDetailPage> {
  final SupabaseClient _supa = Supabase.instance.client;
  ConfessionItem? _item;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await _supa.rpc('confessions_one', params: {
        'p_confession_id': widget.confessionId,
      });
      final list = (res as List?)?.cast<Map<String, dynamic>>() ?? const [];
      if (!mounted) return;
      setState(() {
        _item = list.isNotEmpty ? ConfessionItem.fromRow(list.first) : null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _toggleLike() async {
    final it = _item;
    if (it == null) return;
    setState(() {
      _item = it.copyWith(
        likedByMe: !it.likedByMe,
        likeCount: it.likeCount + (it.likedByMe ? -1 : 1),
      );
    });
    try {
      await _supa.rpc('toggle_confession_like', params: {
        'p_confession_id': it.id,
      });
    } catch (_) {}
  }

  void _openComments() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CommentsSheet(confessionId: widget.confessionId),
    );
  }

  @override
  Widget build(BuildContext context) {
    final it = _item;
    return Scaffold(
      backgroundColor: AppTheme.ffSecondaryBg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          if (it != null)
            IconButton(
              tooltip: 'Share link',
              icon: const Icon(Icons.share, color: Colors.white70),
              onPressed: () async {
                final url = 'https://yourapp.example/confession/${it.id}';
                await Clipboard.setData(ClipboardData(text: url));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('Link copied')));
              },
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : it == null
              ? const Center(
                  child: Text('Confession not found', style: TextStyle(color: Colors.white70)))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 18,
                          backgroundColor: Colors.white10,
                          backgroundImage: it.isAnonymous || it.authorAvatarUrl == null
                              ? null
                              : CachedNetworkImageProvider(it.authorAvatarUrl!),
                          child: (it.isAnonymous || it.authorAvatarUrl == null)
                              ? const Icon(Icons.person, color: Colors.white54)
                              : null,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                Flexible(
                                  child: Text(
                                    it.isAnonymous ? 'Anonymous' : (it.authorName ?? 'Someone'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        color: Colors.white, fontWeight: FontWeight.w700),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                _TopicChip(text: it.topic),
                                const SizedBox(width: 6),
                                _LangChip(text: it.language),
                              ]),
                              const SizedBox(height: 2),
                              Text(_timeAgo(it.createdAt),
                                  style: const TextStyle(color: Colors.white54, fontSize: 12)),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (it.content.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(it.content, style: const TextStyle(color: Colors.white, height: 1.35)),
                    ],
                    if (it.imageUrl != null) ...[
                      const SizedBox(height: 10),
                      Hero(
                        tag: widget.heroTag ?? 'conf_img_${it.id}',
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: CachedNetworkImage(
                            imageUrl: it.imageUrl!,
                            fit: BoxFit.cover,
                            placeholder: (_, __) =>
                                Container(height: 260, color: const Color(0xFF202227)),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        _PillButton(
                          icon: it.likedByMe ? Icons.favorite : Icons.favorite_border,
                          color: it.likedByMe ? Colors.pinkAccent : Colors.white,
                          label: it.likeCount.toString(),
                          onTap: _toggleLike,
                        ),
                        const SizedBox(width: 6),
                        _PillButton(
                          icon: Icons.mode_comment_outlined,
                          color: Colors.white,
                          label: it.commentCount.toString(),
                          onTap: _openComments,
                        ),
                      ],
                    ),
                  ],
                ),
    );
  }
}

// Comments bottom sheet
class _CommentsSheet extends StatefulWidget {
  const _CommentsSheet({required this.confessionId});
  final String confessionId;

  @override
  State<_CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends State<_CommentsSheet> {
  final SupabaseClient _supa = Supabase.instance.client;
  final TextEditingController _text = TextEditingController();
  final ScrollController _scroll = ScrollController();

  final List<CommentItem> _comments = <CommentItem>[];
  bool _loading = true;
  bool _posting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final rows = await _supa
          .from('confession_comments')
          .select(
              'id, confession_id, author_user_id, text, created_at, profiles(name, avatar_url, author_avatar_url)')
          .eq('confession_id', widget.confessionId)
          .order('created_at', ascending: true);
      final list = (rows as List?)?.cast<Map<String, dynamic>>() ?? const [];
      final mapped = list
          .map((r) => CommentItem.fromRow({
                ...r,
                'author_name': (r['profiles'] as Map?)?['name'],
                'author_avatar_url': (r['profiles'] as Map?)?['avatar_url'] ??
                    (r['profiles'] as Map?)?['author_avatar_url'],
              }))
          .toList();
      if (!mounted) return;
      setState(() {
        _comments
          ..clear()
          ..addAll(mapped);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      debugPrint('load comments error: $e');
    }
  }

  Future<void> _send() async {
    if (_posting) return;
    final text = _text.text.trim();
    if (text.isEmpty) return;
    setState(() => _posting = true);
    try {
      final row = await _supa
          .from('confession_comments')
          .insert({'confession_id': widget.confessionId, 'text': text})
          .select('id, confession_id, author_user_id, created_at, profiles(name, avatar_url)')
          .single();
      final me = CommentItem.fromRow({
        ...row,
        'author_name': (row['profiles'] as Map?)?['name'] ?? 'You',
        'author_avatar_url': (row['profiles'] as Map?)?['avatar_url'],
        'text': text,
      });
      if (!mounted) return;
      setState(() {
        _comments.add(me);
        _text.clear();
        _posting = false;
      });
      await Future.delayed(const Duration(milliseconds: 40));
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent + 80);
      }
    } catch (e) {
      if (!context.mounted) return;
      setState(() => _posting = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Failed to send comment.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: AppTheme.ffPrimaryBg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
          boxShadow: [BoxShadow(blurRadius: 20, color: Colors.black54)],
        ),
        height: MediaQuery.of(context).size.height * 0.75,
        child: Column(
          children: [
            Container(
              height: 4,
              width: 40,
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
            ),
            const Text('Comments',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            const Divider(height: 1, color: Colors.white12),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                      itemCount: _comments.length,
                      itemBuilder: (_, i) {
                        final c = _comments[i];
                        return GestureDetector(
                          onLongPress: () async {
                            await Clipboard.setData(ClipboardData(text: c.text));
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context)
                                .showSnackBar(const SnackBar(content: Text('Comment copied')));
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                CircleAvatar(
                                  radius: 16,
                                  backgroundColor: Colors.white12,
                                  backgroundImage: c.authorAvatarUrl != null
                                      ? CachedNetworkImageProvider(c.authorAvatarUrl!)
                                      : null,
                                  child: c.authorAvatarUrl == null
                                      ? const Icon(Icons.person, color: Colors.white54, size: 18)
                                      : null,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(c.authorName,
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.w700,
                                              fontSize: 13)),
                                      const SizedBox(height: 3),
                                      Text(c.text,
                                          style:
                                              const TextStyle(color: Colors.white, height: 1.35)),
                                      const SizedBox(height: 3),
                                      Text(_timeAgo(c.createdAt),
                                          style: const TextStyle(
                                              color: Colors.white54, fontSize: 11)),
                                    ],
                                  ),
                                ),
                              ],
                            ),
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
                      controller: _text,
                      minLines: 1,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        hintText: 'Write a comment…',
                        hintStyle: TextStyle(color: Colors.white54),
                        border: InputBorder.none,
                      ),
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                  IconButton(
                    icon: _posting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.send, color: AppTheme.ffPrimary),
                    onPressed: _posting ? null : _send,
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

// Recent Search bottom sheet
class _RecentSearchSheet extends StatelessWidget {
  const _RecentSearchSheet({required this.recents, required this.onRemove});
  final List<String> recents;
  final Future<void> Function(String) onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.ffPrimaryBg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.history, color: Colors.white70),
                const SizedBox(width: 8),
                const Text('Recent searches',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white54),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (recents.isEmpty)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text('No recent searches yet', style: TextStyle(color: Colors.white54)),
              )
            else
              ...recents.map((q) => _RecentRow(q: q, onRemove: onRemove)),
          ],
        ),
      ),
    );
  }
}

class _RecentRow extends StatelessWidget {
  const _RecentRow({required this.q, required this.onRemove});
  final String q;
  final Future<void> Function(String) onRemove;
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => Navigator.of(context).pop<String>(q),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            const Icon(Icons.search, color: Colors.white38, size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text(q, style: const TextStyle(color: Colors.white))),
            IconButton(
              tooltip: 'Remove',
              icon: const Icon(Icons.close, color: Colors.white38, size: 18),
              onPressed: () async {
                await onRemove(q);
                if (!context.mounted) return;
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('Removed from recent')));
              },
            ),
          ],
        ),
      ),
    );
  }
}

// Skeleton loader
class _FeedSkeleton extends StatelessWidget {
  const _FeedSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 80),
      itemCount: 6,
      itemBuilder: (_, i) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF16181C),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                const SizedBox(height: 12),
                _bar(width: 160),
                const SizedBox(height: 8),
                _bar(width: double.infinity, height: 160, radius: 12),
                const SizedBox(height: 12),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _bar({double width = 120, double height = 12, double radius = 6}) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 14),
        width: width,
        height: height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          gradient: const LinearGradient(
            colors: [Color(0xFF202227), Color(0xFF1B1D21), Color(0xFF202227)],
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Utilities
String _timeAgo(DateTime dt) {
  final now = DateTime.now().toUtc();
  final diff = now.difference(dt.toUtc());

  if (diff.inSeconds < 5) return 'just now';
  if (diff.inSeconds < 60) return '${diff.inSeconds}s';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m';
  if (diff.inHours < 24) return '${diff.inHours}h';
  if (diff.inDays < 7) return '${diff.inDays}d';

  final weeks = (diff.inDays / 7).floor();
  if (weeks < 5) return '${weeks}w';

  final months = (diff.inDays / 30).floor();
  if (months < 12) return '${months}mo';

  final years = (diff.inDays / 365).floor();
  return '${years}y';
}