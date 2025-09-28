// =========================
// FILE: lib/features/confessions/ui/confessions_feed_page.dart
// =========================

import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../theme/app_theme.dart';
import '../data/confession_models.dart';
import '../data/confession_repo.dart';
import '../data/confession_cache.dart';


/// Tiny helpers ---------------------------------------------------------------
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

void _snack(BuildContext ctx, String msg) {
  ScaffoldMessenger.of(ctx)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(behavior: SnackBarBehavior.floating, content: Text(msg)));
}

/// Public route ---------------------------------------------------------------
class ConfessionsFeedPage extends StatefulWidget {
  const ConfessionsFeedPage({super.key});

  static const String routeName = 'ConfessionsFeed';
  static const String routePath = '/confessions';

  @override
  State<ConfessionsFeedPage> createState() => _ConfessionsFeedPageState();
}

/// Choices (keep in sync with backend expectations) ---------------------------
const _topics = <String>['All', 'Love', 'Campus', 'Work', 'Family', 'Money', 'Friends', 'Random'];
const _languages = <String>['All', 'English', 'Afrikaans', 'Zulu', 'Xhosa', 'Sotho', 'French', 'Spanish'];

enum _Sort { latest, top, trending }

class _ConfessionsFeedPageState extends State<ConfessionsFeedPage> with TickerProviderStateMixin {
  final _repo = ConfessionRepository();
  final _scroll = ScrollController();

  final List<ConfessionItem> _items = <ConfessionItem>[];
  bool _loading = true;
  bool _refreshing = false;
  bool _fetchingMore = false;
  bool _end = false;

  static const int _pageSize = 20;

  String _topic = _topics.first;
  String _language = _languages.first;
  _Sort _sort = _Sort.trending;
  String _query = '';
  bool _bookmarksOnly = false;

  @override
  void initState() {
    super.initState();
    _load(initial: true);
    _scroll.addListener(_onScroll);
    // best-effort warmups (async, no await)
    BookmarkStore.instance.init();
    RecentSearchStore.instance.init();
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  // Data ----------------------------------------------------------------------
  Future<void> _load({bool initial = false}) async {
    try {
      if (initial) {
        final cache = FeedCache.instance;
        if (cache.isFresh && cache.items.isNotEmpty) {
          setState(() {
            _items
              ..clear()
              ..addAll(cache.items);
            _end = cache.isEnd;
            _loading = false;
          });
          return;
        }
        setState(() => _loading = true);
      }

      final list = await _repo.fetchFeed(limit: _pageSize, offset: 0);
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(list);
        _end = list.length < _pageSize;
        _loading = false;
      });
      FeedCache.instance.seed(list, end: _end);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack(context, 'Failed to load feed.');
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
      final offset = _items.length;

      // If cache is still fresh and has more than offset, serve from cache
      final cache = FeedCache.instance;
      if (cache.isFresh && cache.items.length > offset) {
        final page = cache.items.sublist(offset);
        setState(() {
          _items.addAll(page);
          _end = cache.isEnd;
        });
        return;
      }

      final page = await _repo.fetchFeed(limit: _pageSize, offset: offset);
      if (!mounted) return;
      setState(() {
        _items.addAll(page);
        if (page.length < _pageSize) _end = true;
      });
      FeedCache.instance.append(page, end: _end);
    } catch (_) {
      // soft-fail for pagination
    } finally {
      if (mounted) setState(() => _fetchingMore = false);
    }
  }

  void _onScroll() {
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 500) {
      _loadMore();
    }
  }

  // Derived view --------------------------------------------------------------
  double _hotScore(ConfessionItem e) {
    final ageHours = math.max(1, DateTime.now().toUtc().difference(e.createdAt).inMinutes / 60);
    return (e.likeCount + 1) / math.pow(ageHours, 1.4);
  }

  Future<void> _onSearchSubmitted(String v) async {
    setState(() => _query = v);
    await RecentSearchStore.instance.push(v);
  }

  Map<String, int> get _topicCounts {
    final Map<String, int> c = {for (final t in _topics) t: 0};
    for (final e in _items) {
      c[e.topic] = (c[e.topic] ?? 0) + 1;
    }
    c.remove('All');
    return c;
  }

  /// Synchronous filter only (no async/bookmarks here).
  List<ConfessionItem> get _visibleSyncOnly {
    Iterable<ConfessionItem> xs = _items;

    if (_topic != 'All') xs = xs.where((e) => e.topic.toLowerCase() == _topic.toLowerCase());
    if (_language != 'All') xs = xs.where((e) => e.language.toLowerCase() == _language.toLowerCase());
    if (_query.trim().isNotEmpty) {
      final q = _query.trim().toLowerCase();
      xs = xs.where((e) =>
          e.content.toLowerCase().contains(q) ||
          e.topic.toLowerCase().contains(q) ||
          (e.authorName ?? '').toLowerCase().contains(q));
    }
    if (_sort == _Sort.latest) {
      xs = xs.toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    } else if (_sort == _Sort.top) {
      xs = xs.toList()..sort((a, b) => b.likeCount.compareTo(a.likeCount));
    } else {
      xs = xs.toList()..sort((a, b) => _hotScore(b).compareTo(_hotScore(a)));
    }
    return xs.toList(growable: false);
  }

  // Actions -------------------------------------------------------------------
  Future<void> _toggleLike(ConfessionItem item) async {
    final idx = _items.indexWhere((e) => e.id == item.id);
    if (idx == -1) return;

    final prev = _items[idx];
    final optimistic = prev.copyWith(
      likedByMe: !prev.likedByMe,
      likeCount: prev.likeCount + (prev.likedByMe ? -1 : 1),
    );
    setState(() => _items[idx] = optimistic);
    FeedCache.instance.upsert(optimistic);
    HapticFeedback.lightImpact();

    try {
      final fixed = await _repo.toggleLike(item.id);
      if (!mounted || fixed == null) return;
      final j = _items.indexWhere((e) => e.id == item.id);
      if (j != -1) {
        setState(() => _items[j] = _items[j].copyWith(
              likedByMe: fixed.likedByMe,
              likeCount: fixed.likeCount,
            ));
        FeedCache.instance.upsert(_items[j]);
      }
    } catch (_) {
      // soft-fail; realtime sync can correct later if wired
    }
  }

  Future<void> _openSearchSheet() async {
    final recents = await RecentSearchStore.instance.all();
    if (!mounted) return;
    await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => _RecentSearchSheet(
        recents: recents,
        onRemove: (q) => RecentSearchStore.instance.remove(q),
      ),
    ).then((picked) {
      if (picked == null) return;
      _onSearchSubmitted(picked);
    });
  }

  // Build ---------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    // 1) Apply the synchronous filters
    final syncVisible = _visibleSyncOnly;

    // 2) If bookmarksOnly is on, we filter again using the async store.
    final Widget listArea = _bookmarksOnly
        ? FutureBuilder<Set<String>>(
            future: BookmarkStore.instance.all(),
            builder: (context, snap) {
              final keep = snap.data;
              final filtered = keep == null ? <ConfessionItem>[] : syncVisible.where((e) => keep.contains(e.id)).toList();
              final items = keep == null ? <ConfessionItem>[] : filtered;
              return _FeedListView(
                items: items,
                fetchingMore: _fetchingMore,
                onToggleLike: _toggleLike,
              );
            },
          )
        : _FeedListView(
            items: syncVisible,
            fetchingMore: _fetchingMore,
            onToggleLike: _toggleLike,
          );

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
                              onConfess: () => _snack(context, 'Composer sheet coming next file ✨'),
                            ),
                            _TrendingBar(counts: _topicCounts),
                          ],
                        ),
                      ),
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 92),
                        sliver: SliverToBoxAdapter(child: listArea),
                      ),
                    ],
                  ),
                ),
        ),
      ),
      floatingActionButton: _ComposeFab(
        onPressed: () => _snack(context, 'Composer sheet coming next file ✨'),
      ),
    );
  }
}

class _FeedListView extends StatelessWidget {
  const _FeedListView({
    required this.items,
    required this.fetchingMore,
    required this.onToggleLike,
  });

  final List<ConfessionItem> items;
  final bool fetchingMore;
  final void Function(ConfessionItem) onToggleLike;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: Text('No confessions yet.', style: TextStyle(color: Colors.white54))),
      );
    }
    return ListView.builder(
      physics: const NeverScrollableScrollPhysics(),
      shrinkWrap: true,
      itemCount: items.length + (fetchingMore ? 1 : 0),
      itemBuilder: (context, i) {
        if (i >= items.length) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 18),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final item = items[i];
        return _ConfessionCard(
          item: item,
          onToggleLike: () => onToggleLike(item),
          onOpenComments: () => _snack(context, 'Comments sheet coming next file 💬'),
          onBookmark: () async {
            await BookmarkStore.instance.toggle(item.id);
          },
        );
      },
    );
  }
}

/// UI bits (AppBar / Header / Filters / Skeleton / Card) ----------------------

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
            onPressed: () => _snack(context, 'Notifications coming later 🔔'),
          ),
          const SizedBox(width: 4),
          TextButton.icon(
            onPressed: () => _snack(context, 'Tip: use the Confess button below'),
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
            const Icon(Icons.local_fire_department),
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

class _ConfessionCard extends StatefulWidget {
  const _ConfessionCard({
    required this.item,
    required this.onToggleLike,
    required this.onOpenComments,
    required this.onBookmark,
  });

  final ConfessionItem item;
  final VoidCallback onToggleLike;
  final VoidCallback onOpenComments;
  final Future<void> Function() onBookmark;

  @override
  State<_ConfessionCard> createState() => _ConfessionCardState();
}

class _ConfessionCardState extends State<_ConfessionCard> with SingleTickerProviderStateMixin {
  late final AnimationController _heartCtrl;
  late final Animation<double> _heartScale;
  late final Animation<double> _heartFade;

  @override
  void initState() {
    super.initState();
    _heartCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 650));
    _heartScale = Tween<double>(begin: 0.6, end: 1.8)
        .chain(CurveTween(curve: Curves.easeOutBack))
        .animate(_heartCtrl);
    _heartFade = Tween<double>(begin: 0.9, end: 0.0)
        .chain(CurveTween(curve: Curves.easeOut))
        .animate(_heartCtrl);
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
                    backgroundImage: (it.authorAvatarUrl ?? '').isNotEmpty
                        ? CachedNetworkImageProvider(it.authorAvatarUrl!)
                        : null,
                    child: (it.authorAvatarUrl ?? '').isEmpty
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
                                it.isAnonymous ? 'Anonymous' : (it.authorName ?? 'Someone'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            _Chip(text: it.topic, filled: true),
                            const SizedBox(width: 6),
                            _Chip(text: it.language),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(_timeAgo(it.createdAt),
                            style: const TextStyle(color: Colors.white54, fontSize: 12)),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'More',
                    icon: const Icon(Icons.more_horiz, color: Colors.white70),
                    onPressed: () => _snack(context, 'Menu coming in detail page'),
                  ),
                ],
              ),
            ),

            if (it.content.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 2, 14, 10),
                child: Text(it.content, style: const TextStyle(color: Colors.white, height: 1.35)),
              ),

            if (it.imageUrl != null)
              GestureDetector(
                onDoubleTap: () {
                  widget.onToggleLike();
                  _burstHeart();
                  HapticFeedback.lightImpact();
                },
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(bottom: Radius.circular(14)),
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
                          child: const Center(child: Icon(Icons.broken_image, color: Colors.white38)),
                        ),
                      ),
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
                    ],
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
                  const Spacer(),
                  FutureBuilder<bool>(
                    future: BookmarkStore.instance.isSaved(it.id),
                    builder: (context, snap) {
                      final saved = snap.data ?? false;
                      return _PillButton(
                        icon: saved ? Icons.bookmark : Icons.bookmark_border,
                        color: saved ? AppTheme.ffPrimary : Colors.white,
                        label: 'Save',
                        onTap: () async {
                          await widget.onBookmark();
                          if (mounted) setState(() {});
                        },
                      );
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

class _Chip extends StatelessWidget {
  const _Chip({required this.text, this.filled = false});
  final String text;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: filled ? AppTheme.ffPrimary.withValues(alpha: .18) : const Color(0xFF141414),
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

/// Recent search picker sheet --------------------------------------------------
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
