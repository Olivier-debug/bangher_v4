// =========================
// FILE: lib/features/confessions/confessions_feature.dart
// =========================
// Confessions v3.2 — modern layout polish
// - Sleek cards, consistent radii/padding, glassy action pills
// - Compact filters with chip pickers (+ bottom-sheet language/topic picker)
// - Composer with header bar + toolbar (photo/topic/lang/anon)
// - Owner-only edit/delete, optimistic likes, comments
// - No extra packages beyond cached_network_image, image_picker, supabase_flutter.

import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // Clipboard, Haptics
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../theme/app_theme.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Tokens
const _kRadius = 14.0;
const _kPad = 14.0;
const _kPadSmall = 10.0;

const List<String> kTopics = <String>[
  'All',
  'Relationships',
  'Work',
  'School',
  'Family',
  'Money',
  'Health',
  'Spiritual',
  'Random',
];

const List<MapEntry<String, String>> kLanguages = <MapEntry<String, String>>[
  MapEntry('all', 'All'),
  MapEntry('en', 'English'),
  MapEntry('af', 'Afrikaans'),
  MapEntry('zu', 'Zulu'),
  MapEntry('xh', 'Xhosa'),
  MapEntry('st', 'Sotho'),
  MapEntry('fr', 'French'),
  MapEntry('es', 'Spanish'),
];

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
// Models
class ConfessionItem {
  final String id;
  final String authorUserId;
  final String content;
  final bool isAnonymous;
  final String? imageUrl;
  final String? imagePath;
  final DateTime createdAt;
  final int likeCount;
  final int commentCount;
  final bool likedByMe;
  final String? authorName;
  final String? authorAvatarUrl;
  final String? topic;
  final String? languageCode;

  ConfessionItem({
    required this.id,
    required this.authorUserId,
    required this.content,
    required this.isAnonymous,
    required this.imageUrl,
    required this.imagePath,
    required this.createdAt,
    required this.likeCount,
    required this.commentCount,
    required this.likedByMe,
    required this.authorName,
    required this.authorAvatarUrl,
    required this.topic,
    required this.languageCode,
  });

  ConfessionItem copyWith({
    String? content,
    bool? isAnonymous,
    String? imageUrl,
    String? imagePath,
    int? likeCount,
    int? commentCount,
    bool? likedByMe,
    String? topic,
    String? languageCode,
  }) =>
      ConfessionItem(
        id: id,
        authorUserId: authorUserId,
        content: content ?? this.content,
        isAnonymous: isAnonymous ?? this.isAnonymous,
        imageUrl: imageUrl ?? this.imageUrl,
        imagePath: imagePath ?? this.imagePath,
        createdAt: createdAt,
        likeCount: likeCount ?? this.likeCount,
        commentCount: commentCount ?? this.commentCount,
        likedByMe: likedByMe ?? this.likedByMe,
        authorName: authorName,
        authorAvatarUrl: authorAvatarUrl,
        topic: topic ?? this.topic,
        languageCode: languageCode ?? this.languageCode,
      );

  static ConfessionItem fromRow(Map<String, dynamic> r, {String? me}) {
    String? _nullIfEmpty(dynamic v) {
      if (v == null) return null;
      final s = v.toString().trim();
      return s.isEmpty ? null : s;
    }

    return ConfessionItem(
      id: r['id'].toString(),
      authorUserId: (r['author_user_id'] ?? '').toString(),
      content: (r['content'] ?? '').toString(),
      isAnonymous: r['is_anonymous'] == true,
      imageUrl: _nullIfEmpty(r['image_url']),
      imagePath: _nullIfEmpty(r['image_path']),
      createdAt: DateTime.tryParse((r['created_at'] ?? '').toString()) ?? DateTime.now().toUtc(),
      likeCount: (r['like_count'] as int?) ?? 0,
      commentCount: (r['comment_count'] as int?) ?? 0,
      likedByMe: (r['liked_by_me'] as bool?) ?? false,
      authorName: _nullIfEmpty(r['author_name'] ?? r['name']),
      authorAvatarUrl: _nullIfEmpty(r['author_avatar_url']),
      topic: _nullIfEmpty(r['topic']),
      languageCode: _nullIfEmpty(r['language_code']),
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

  CommentItem({
    required this.id,
    required this.confessionId,
    required this.authorUserId,
    required this.authorName,
    required this.authorAvatarUrl,
    required this.text,
    required this.createdAt,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Feed Page
class _ConfessionsFeedPageState extends State<ConfessionsFeedPage> with TickerProviderStateMixin {
  final SupabaseClient _supa = Supabase.instance.client;
  final ScrollController _scroll = ScrollController();

  final List<ConfessionItem> _items = <ConfessionItem>[];
  bool _loading = true;
  bool _refreshing = false;
  bool _fetchingMore = false;
  bool _end = false;

  // Filters
  String _selectedTopic = kTopics.first; // 'All'
  String _selectedLangCode = kLanguages.first.key; // 'all'
  bool _withImagesOnly = false;
  bool _anonOnly = false;

  RealtimeChannel? _ch;
  static const int _pageSize = 20;

  @override
  void initState() {
    super.initState();
    _load(initial: true);
    _listenRealtime();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _ch?.unsubscribe();
    super.dispose();
  }

  Future<void> _load({bool initial = false}) async {
    try {
      if (initial) setState(() => _loading = true);
      final me = _supa.auth.currentUser?.id;
      final rows = await _supa.rpc('confessions_feed', params: {
        'limit_arg': _pageSize,
        'offset_arg': 0,
      });
      final list = (rows as List?)?.cast<Map<String, dynamic>>() ?? const <Map<String, dynamic>>[];
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
      final list = (rows as List?)?.cast<Map<String, dynamic>>() ?? const <Map<String, dynamic>>[];
      final mapped = list.map((r) => ConfessionItem.fromRow(r, me: me)).toList();
      if (!mounted) return;
      setState(() {
        _items.addAll(mapped);
        if (mapped.length < _pageSize) _end = true;
      });
    } catch (_) {
    } finally {
      if (mounted) setState(() => _fetchingMore = false);
    }
  }

  void _onScroll() {
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 400) {
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
            final row = payload.newRecord;
            try {
              final me = _supa.auth.currentUser?.id;
              final res = await _supa.rpc('confessions_one', params: {'p_confession_id': row['id']});
              final list = (res as List?)?.cast<Map<String, dynamic>>() ?? const [];
              if (list.isEmpty) return;
              final item = ConfessionItem.fromRow(list.first, me: me);
              if (!mounted) return;
              setState(() => _items.insert(0, item));
            } catch (_) {}
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'confessions',
          callback: (payload) {
            final nr = payload.newRecord;
            final id = nr['id'].toString();
            final likeCount = (nr['like_count'] as int?) ?? 0;
            final commentCount = (nr['comment_count'] as int?) ?? 0;
            final topic = (nr['topic'] ?? '') as String?;
            final lang = (nr['language_code'] ?? '') as String?;
            final content = (nr['content'] ?? '') as String?;
            final imageUrl = (nr['image_url'] ?? '') as String?;
            final imagePath = (nr['image_path'] ?? '') as String?;
            if (!mounted) return;
            final idx = _items.indexWhere((e) => e.id == id);
            if (idx != -1) {
              setState(() {
                _items[idx] = _items[idx].copyWith(
                  likeCount: likeCount,
                  commentCount: commentCount,
                  topic: (topic == null || topic.isEmpty) ? null : topic,
                  languageCode: (lang == null || lang.isEmpty) ? null : lang,
                  content: content ?? _items[idx].content,
                  imageUrl: (imageUrl == null || imageUrl.isEmpty) ? null : imageUrl,
                  imagePath: (imagePath == null || imagePath.isEmpty) ? null : imagePath,
                );
              });
            }
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'confessions',
          callback: (payload) {
            final or = payload.oldRecord;
            final id = or['id'].toString();
            if (!mounted) return;
            setState(() => _items.removeWhere((e) => e.id == id));
          },
        )
        .subscribe();
  }

  // ───────── Composer
  Future<void> _openComposer() async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ComposerSheet(
        mode: ComposerMode.create,
        onPosted: (it) => setState(() => _items.insert(0, it)),
      ),
    );
  }

  Future<void> _openEdit(ConfessionItem item) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ComposerSheet(
        mode: ComposerMode.edit,
        original: item,
        onUpdated: (updated) {
          final idx = _items.indexWhere((e) => e.id == updated.id);
          if (idx != -1) setState(() => _items[idx] = updated);
        },
      ),
    );
  }

  Future<void> _delete(ConfessionItem item) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.ffPrimaryBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete confession?', style: TextStyle(color: Colors.white)),
        content: const Text('This cannot be undone.', style: TextStyle(color: Colors.white70)),
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

    try {
      final path = item.imagePath ?? _pathFromPublicUrl(item.imageUrl);
      if (path != null) {
        try {
          await _supa.storage.from('confessions').remove([path]);
        } catch (_) {}
      }
      await _supa.from('confessions').delete().eq('id', item.id);
      if (!mounted) return;
      setState(() => _items.removeWhere((e) => e.id == item.id));
      messenger.showSnackBar(const SnackBar(content: Text('Confession deleted')));
    } catch (e) {
      messenger.showSnackBar(const SnackBar(content: Text('Failed to delete')));
    } finally {
      navigator.maybePop();
    }
  }

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

      final rows = await _supa.rpc('toggle_confession_like', params: {'p_confession_id': item.id});
      final list = (rows as List?)?.cast<Map<String, dynamic>>() ?? const [];
      if (list.isEmpty) return optimistic;
      final liked = (list.first['liked'] as bool?) ?? optimistic.likedByMe;
      final count = (list.first['like_count'] as int?) ?? optimistic.likeCount;
      return item.copyWith(likedByMe: liked, likeCount: count);
    } catch (_) {
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

  // Filters
  List<ConfessionItem> get _visibleItems {
    return _items.where((e) {
      if (_selectedTopic != 'All' && (e.topic ?? 'All') != _selectedTopic) return false;
      if (_selectedLangCode != 'all' && (e.languageCode ?? 'all') != _selectedLangCode) return false;
      if (_withImagesOnly && e.imageUrl == null) return false;
      if (_anonOnly && !e.isAnonymous) return false;
      return true;
    }).toList();
  }

  void _clearFilters() {
    setState(() {
      _selectedTopic = kTopics.first;
      _selectedLangCode = kLanguages.first.key;
      _withImagesOnly = false;
      _anonOnly = false;
    });
  }

  Future<void> _pickLanguage() async {
    final sel = await _PickListSheet.pick<String>(
      context,
      title: 'Language',
      items: kLanguages.map((e) => MapEntry(e.key, e.value)).toList(),
      selected: _selectedLangCode,
    );
    if (sel != null) setState(() => _selectedLangCode = sel);
  }

  Future<void> _pickTopic() async {
    final sel = await _PickListSheet.pick<String>(
      context,
      title: 'Topic',
      items: kTopics.map((e) => MapEntry(e, e)).toList(),
      selected: _selectedTopic,
    );
    if (sel != null) setState(() => _selectedTopic = sel);
  }

  @override
  Widget build(BuildContext context) {
    final me = _supa.auth.currentUser?.id;

    return Scaffold(
      backgroundColor: AppTheme.ffSecondaryBg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Confessions', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh, color: Colors.white70),
          ),
        ],
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
                    // CTA
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
                        child: _HeroMessage(onConfess: _openComposer),
                      ),
                    ),
                    // Filters — compact, chip-first
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
                        child: _FiltersRow(
                          topic: _selectedTopic,
                          languageLabel: kLanguages.firstWhere((e) => e.key == _selectedLangCode).value,
                          withImages: _withImagesOnly,
                          anonOnly: _anonOnly,
                          onTapTopic: _pickTopic,
                          onTapLanguage: _pickLanguage,
                          onWithImages: (v) => setState(() => _withImagesOnly = v),
                          onAnonOnly: (v) => setState(() => _anonOnly = v),
                          onClear: _clearFilters,
                        ),
                      ),
                    ),
                    // Feed
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 92),
                      sliver: SliverList.builder(
                        itemCount: _visibleItems.length + (_fetchingMore ? 1 : 0),
                        itemBuilder: (context, i) {
                          if (i >= _visibleItems.length) {
                            return const Padding(
                              padding: EdgeInsets.symmetric(vertical: 18),
                              child: Center(child: CircularProgressIndicator()),
                            );
                          }
                          final item = _visibleItems[i];
                          final isOwner = me != null && me == item.authorUserId;
                          return _ConfessionCard(
                            item: item,
                            isOwner: isOwner,
                            onTapImage: (tag) {
                              Navigator.of(context).push(
                                PageRouteBuilder(
                                  transitionDuration: const Duration(milliseconds: 250),
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
                            onEdit: () => _openEdit(item),
                            onDelete: () => _delete(item),
                          );
                        },
                      ),
                    ),
                  ],
                ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openComposer,
        backgroundColor: AppTheme.ffPrimary,
        elevation: 0,
        icon: const Icon(Icons.add, color: Colors.white),
        label: const Text('Confess', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Composer Sheet (create/edit) — modern header + toolbar
enum ComposerMode { create, edit }

class _ComposerSheet extends StatefulWidget {
  const _ComposerSheet({
    required this.mode,
    this.original,
    this.onPosted,
    this.onUpdated,
  });

  final ComposerMode mode;
  final ConfessionItem? original;
  final void Function(ConfessionItem item)? onPosted;
  final void Function(ConfessionItem item)? onUpdated;

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
  String _lang = 'en';
  bool _removeExistingImage = false;

  @override
  void initState() {
    super.initState();
    if (widget.mode == ComposerMode.edit && widget.original != null) {
      final o = widget.original!;
      _text.text = o.content;
      _anon = o.isAnonymous;
      _topic = (o.topic == null || o.topic!.isEmpty) ? 'Random' : o.topic!;
      _lang = (o.languageCode == null || o.languageCode!.isEmpty) ? 'en' : o.languageCode!;
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    try {
      final x = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 85, maxWidth: 2000);
      if (x != null) setState(() {
        _picked = x;
        _removeExistingImage = false;
      });
    } catch (_) {}
  }

  Future<void> _chooseTopic() async {
    final sel = await _PickListSheet.pick<String>(
      context,
      title: 'Topic',
      items: kTopics.where((t) => t != 'All').map((e) => MapEntry(e, e)).toList(),
      selected: _topic,
    );
    if (sel != null) setState(() => _topic = sel);
  }

  Future<void> _chooseLanguage() async {
    final sel = await _PickListSheet.pick<String>(
      context,
      title: 'Language',
      items: kLanguages.where((e) => e.key != 'all').map((e) => MapEntry(e.key, e.value)).toList(),
      selected: _lang,
    );
    if (sel != null) setState(() => _lang = sel);
  }

  Future<void> _postOrUpdate() async {
    if (_posting) return;
    final content = _text.text.trim();
    if (content.isEmpty && _picked == null && widget.mode == ComposerMode.create) return;

    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    setState(() => _posting = true);

    try {
      if (widget.mode == ComposerMode.create) {
        String? imageUrl;
        String? imagePath;
        if (_picked != null) {
          final bytes = await _picked!.readAsBytes();
          final ext = _picked!.name.split('.').last.toLowerCase();
          final me = _supa.auth.currentUser?.id ?? 'anon';
          final path = 'u_$me/${DateTime.now().millisecondsSinceEpoch}.${ext.isEmpty ? 'jpg' : ext}';
          await _supa.storage.from('confessions').uploadBinary(
                path,
                bytes,
                fileOptions: const FileOptions(cacheControl: '3600', upsert: false, contentType: 'image/jpeg'),
              );
          imageUrl = _supa.storage.from('confessions').getPublicUrl(path);
          imagePath = path;
        }

        final row = await _supa
            .from('confessions')
            .insert({
              'content': content,
              'is_anonymous': _anon,
              if (imageUrl != null) 'image_url': imageUrl,
              if (imagePath != null) 'image_path': imagePath,
              'topic': _topic,
              'language_code': _lang,
            })
            .select()
            .single();

        final res = await _supa.rpc('confessions_one', params: {'p_confession_id': row['id']});
        final list = (res as List?)?.cast<Map<String, dynamic>>() ?? const [];
        final item = list.isNotEmpty
            ? ConfessionItem.fromRow(list.first)
            : ConfessionItem(
                id: row['id'].toString(),
                authorUserId: (row['author_user_id'] ?? '').toString(),
                content: content,
                isAnonymous: _anon,
                imageUrl: row['image_url']?.toString(),
                imagePath: row['image_path']?.toString(),
                createdAt: DateTime.tryParse((row['created_at'] ?? '').toString()) ?? DateTime.now().toUtc(),
                likeCount: 0,
                commentCount: 0,
                likedByMe: false,
                authorName: null,
                authorAvatarUrl: null,
                topic: _topic,
                languageCode: _lang,
              );

        widget.onPosted?.call(item);
        navigator.maybePop();
      } else {
        final o = widget.original!;
        String? newImageUrl = o.imageUrl;
        String? newImagePath = o.imagePath;

        if (_picked != null) {
          final bytes = await _picked!.readAsBytes();
          final ext = _picked!.name.split('.').last.toLowerCase();
          final me = _supa.auth.currentUser?.id ?? o.authorUserId;
          final path = 'u_$me/${DateTime.now().millisecondsSinceEpoch}.${ext.isEmpty ? 'jpg' : ext}';
          await _supa.storage.from('confessions').uploadBinary(
                path,
                bytes,
                fileOptions: const FileOptions(cacheControl: '3600', upsert: false, contentType: 'image/jpeg'),
              );
          newImageUrl = _supa.storage.from('confessions').getPublicUrl(path);
          newImagePath = path;

          final oldPath = o.imagePath ?? _pathFromPublicUrl(o.imageUrl);
          if (oldPath != null) {
            unawaited(_supa.storage.from('confessions').remove([oldPath]));
          }
        } else if (_removeExistingImage && (o.imageUrl != null || o.imagePath != null)) {
          final oldPath = o.imagePath ?? _pathFromPublicUrl(o.imageUrl);
          if (oldPath != null) {
            unawaited(_supa.storage.from('confessions').remove([oldPath]));
          }
          newImageUrl = null;
          newImagePath = null;
        }

        final patch = {
          'content': content,
          'is_anonymous': _anon,
          'topic': _topic,
          'language_code': _lang,
          'image_url': newImageUrl,
          'image_path': newImagePath,
        };

        await _supa.from('confessions').update(patch).eq('id', o.id);
        final res = await _supa.rpc('confessions_one', params: {'p_confession_id': o.id});
        final list = (res as List?)?.cast<Map<String, dynamic>>() ?? const [];
        final updated = list.isNotEmpty
            ? ConfessionItem.fromRow(list.first)
            : o.copyWith(
                content: content,
                isAnonymous: _anon,
                topic: _topic,
                languageCode: _lang,
                imageUrl: newImageUrl,
                imagePath: newImagePath,
              );

        widget.onUpdated?.call(updated);
        navigator.maybePop();
      }
    } catch (e) {
      messenger.showSnackBar(const SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text('Action failed. Check connection and DB/storage policy.'),
      ));
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.mode == ComposerMode.edit;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final existingImageUrl = widget.original?.imageUrl;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.ffPrimaryBg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          boxShadow: const [BoxShadow(blurRadius: 24, color: Colors.black54)],
          border: Border.all(color: Colors.white.withValues(alpha: .08), width: 1),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header bar
            Padding(
              padding: const EdgeInsets.fromLTRB(_kPad, 12, _kPad, 6),
              child: Row(
                children: [
                  Icon(isEdit ? Icons.edit : Icons.auto_awesome, color: AppTheme.ffPrimary),
                  const SizedBox(width: 8),
                  Text(
                    isEdit ? 'Edit confession' : 'New confession',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.ffPrimary,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      shape: const StadiumBorder(),
                    ),
                    onPressed: _posting ? null : _postOrUpdate,
                    child: _posting
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : Text(isEdit ? 'Save' : 'Post', style: const TextStyle(color: Colors.white)),
                  ),
                ],
              ),
            ),
            // Text area
            Padding(
              padding: const EdgeInsets.fromLTRB(_kPad, 4, _kPad, 6),
              child: TextField(
                controller: _text,
                maxLines: 7,
                minLines: 4,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: "What's on your mind?",
                  hintStyle: const TextStyle(color: Colors.white54),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: Colors.white.withValues(alpha: .18)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: AppTheme.ffPrimary),
                  ),
                  filled: true,
                  fillColor: const Color(0xFF121316),
                  contentPadding: const EdgeInsets.all(12),
                ),
                style: const TextStyle(color: Colors.white, height: 1.35),
              ),
            ),
            // Image preview
            if (isEdit && existingImageUrl != null && !_removeExistingImage && _picked == null)
              Padding(
                padding: const EdgeInsets.fromLTRB(_kPad, 2, _kPad, 6),
                child: Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: CachedNetworkImage(
                        imageUrl: existingImageUrl,
                        fit: BoxFit.cover,
                        placeholder: (_, __) => Container(height: 180, color: const Color(0xFF202227)),
                      ),
                    ),
                    Positioned(
                      right: 8,
                      top: 8,
                      child: _TinyIconButton(
                        icon: Icons.close,
                        onTap: () => setState(() => _removeExistingImage = true),
                      ),
                    ),
                  ],
                ),
              ),
            if (_picked != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(_kPad, 2, _kPad, 6),
                child: Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: FutureBuilder<Uint8List>(
                        future: _picked!.readAsBytes(),
                        builder: (context, snap) {
                          if (!snap.hasData) return Container(height: 180, color: const Color(0xFF202227));
                          return Image.memory(snap.data!, fit: BoxFit.cover, height: 200);
                        },
                      ),
                    ),
                    Positioned(
                      right: 8,
                      top: 8,
                      child: _TinyIconButton(
                        icon: Icons.close,
                        onTap: () => setState(() => _picked = null),
                      ),
                    ),
                  ],
                ),
              ),
            // Toolbar
            Padding(
              padding: const EdgeInsets.fromLTRB(_kPad, 4, _kPad, 12),
              child: Row(
                children: [
                  _ToolbarChip(icon: Icons.photo, label: 'Photo', onTap: _pickImage),
                  const SizedBox(width: 8),
                  _ToolbarChip(icon: Icons.tag, label: _topic, onTap: _chooseTopic),
                  const SizedBox(width: 8),
                  _ToolbarChip(
                    icon: Icons.language,
                    label: kLanguages.firstWhere((e) => e.key == _lang).value,
                    onTap: _chooseLanguage,
                  ),
                  const Spacer(),
                  Switch.adaptive(
                    value: _anon,
                    onChanged: (v) => setState(() => _anon = v),
                    activeColor: AppTheme.ffPrimary,
                  ),
                  const SizedBox(width: 6),
                  const Text('Anonymous', style: TextStyle(color: Colors.white70)),
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
// Card — clean header, badges, image, glassy pill actions
class _ConfessionCard extends StatelessWidget {
  const _ConfessionCard({
    required this.item,
    required this.isOwner,
    required this.onToggleLike,
    required this.onOpenComments,
    required this.onTapImage,
    required this.onEdit,
    required this.onDelete,
  });

  final ConfessionItem item;
  final bool isOwner;
  final VoidCallback onToggleLike;
  final VoidCallback onOpenComments;
  final void Function(String heroTag) onTapImage;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final heroTag = 'conf_img_${item.id}';
    final topic = item.topic;
    final langLabel = item.languageCode == null
        ? null
        : (kLanguages.firstWhere((e) => e.key == item.languageCode!, orElse: () => const MapEntry('x', '')).value);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.ffPrimaryBg,
          borderRadius: BorderRadius.circular(_kRadius),
          border: Border.all(color: Colors.white.withValues(alpha: .10), width: 1),
          boxShadow: const [BoxShadow(blurRadius: 24, color: Colors.black26)],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _CardHeader(item: item, isOwner: isOwner, onEdit: onEdit, onDelete: onDelete),
            if (topic != null || langLabel != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(_kPad, 2, _kPad, 0),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (topic != null) _MiniBadge(icon: Icons.tag, label: topic),
                    if (langLabel != null) _MiniBadge(icon: Icons.language, label: langLabel),
                  ],
                ),
              ),
            if (item.content.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(_kPad, 8, _kPad, 8),
                child: _ExpandableText(text: item.content),
              ),
            if (item.imageUrl != null)
              GestureDetector(
                onTap: () => onTapImage(heroTag),
                child: Hero(
                  tag: heroTag,
                  child: ClipRRect(
                    borderRadius: const BorderRadius.vertical(bottom: Radius.circular(_kRadius - 2)),
                    child: CachedNetworkImage(
                      imageUrl: item.imageUrl!,
                      fit: BoxFit.cover,
                      placeholder: (_, __) => Container(height: 240, color: const Color(0xFF202227)),
                      errorWidget: (_, __, ___) =>
                          Container(height: 240, color: const Color(0xFF1E1F24), child: const Center(child: Icon(Icons.broken_image, color: Colors.white38))),
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 6),
            _ActionsRow(item: item, onToggleLike: onToggleLike, onOpenComments: onOpenComments),
          ],
        ),
      ),
    );
  }
}

class _CardHeader extends StatelessWidget {
  const _CardHeader({required this.item, required this.isOwner, required this.onEdit, required this.onDelete});
  final ConfessionItem item;
  final bool isOwner;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final isAnon = item.isAnonymous;
    final name = isAnon ? 'Anonymous' : (item.authorName ?? 'Someone');
    final avatar = isAnon ? null : item.authorAvatarUrl;

    return Padding(
      padding: const EdgeInsets.fromLTRB(_kPad, _kPadSmall, _kPadSmall, 4),
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: Colors.white12,
            backgroundImage: avatar != null ? CachedNetworkImageProvider(avatar) : null,
            child: avatar == null ? const Icon(Icons.person, color: Colors.white54) : null,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(_timeAgo(item.createdAt), style: const TextStyle(color: Colors.white54, fontSize: 12)),
            ]),
          ),
          PopupMenuButton<String>(
            color: const Color(0xFF0E0F12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            icon: const Icon(Icons.more_horiz, color: Colors.white70),
            onSelected: (v) {
              final messenger = ScaffoldMessenger.of(context);
              if (v == 'copy') {
                Clipboard.setData(ClipboardData(text: item.content));
                messenger.showSnackBar(const SnackBar(content: Text('Copied')));
              } else if (v == 'share') {
                Clipboard.setData(ClipboardData(text: 'confession:${item.id}'));
                messenger.showSnackBar(const SnackBar(content: Text('Link copied')));
              } else if (v == 'report') {
                Supabase.instance.client
                    .rpc('report_confession', params: {'p_confession_id': item.id, 'p_reason': 'inappropriate'})
                    .then((_) => messenger.showSnackBar(const SnackBar(content: Text('Reported.'))))
                    .catchError((_) {});
              } else if (v == 'edit') {
                onEdit();
              } else if (v == 'delete') {
                onDelete();
              }
            },
            itemBuilder: (_) => <PopupMenuEntry<String>>[
              const PopupMenuItem<String>(value: 'copy', child: Text('Copy text')),
              const PopupMenuItem<String>(value: 'share', child: Text('Copy link')),
              const PopupMenuItem<String>(value: 'report', child: Text('Report')),
              if (isOwner) const PopupMenuDivider(),
              if (isOwner) const PopupMenuItem<String>(value: 'edit', child: Text('Edit')),
              if (isOwner)
                const PopupMenuItem<String>(
                  value: 'delete',
                  child: Text('Delete', style: TextStyle(color: Colors.red)),
                ),
            ],
          )
        ],
      ),
    );
  }
}

class _MiniBadge extends StatelessWidget {
  const _MiniBadge({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .06),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: .14), width: 1),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 12, color: Colors.white70),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ]),
    );
  }
}

class _ActionsRow extends StatelessWidget {
  const _ActionsRow({required this.item, required this.onToggleLike, required this.onOpenComments});
  final ConfessionItem item;
  final VoidCallback onToggleLike;
  final VoidCallback onOpenComments;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
      child: Row(
        children: [
          _GlassPill(
            icon: item.likedByMe ? Icons.favorite : Icons.favorite_border,
            label: item.likeCount.toString(),
            active: item.likedByMe,
            onTap: onToggleLike,
          ),
          const SizedBox(width: 8),
          _GlassPill(
            icon: Icons.mode_comment_outlined,
            label: item.commentCount.toString(),
            onTap: onOpenComments,
          ),
          const Spacer(),
          _IconGhost(
            icon: Icons.share,
            tooltip: 'Copy link',
            onTap: () {
              Clipboard.setData(ClipboardData(text: 'confession:${item.id}'));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link copied')));
            },
          ),
        ],
      ),
    );
  }
}

class _GlassPill extends StatelessWidget {
  const _GlassPill({required this.icon, required this.label, this.onTap, this.active = false});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: .06),
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Icon(icon, color: active ? Colors.pinkAccent : Colors.white, size: 18),
              const SizedBox(width: 8),
              Text(label, style: TextStyle(color: active ? Colors.pinkAccent : Colors.white)),
            ],
          ),
        ),
      ),
    );
  }
}

class _IconGhost extends StatelessWidget {
  const _IconGhost({required this.icon, required this.onTap, this.tooltip});
  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final btn = InkResponse(
      onTap: onTap,
      radius: 22,
      child: const Padding(
        padding: EdgeInsets.all(8),
        child: Icon(Icons.share, color: Colors.white70),
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip!, child: btn);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Filters row — compact chips + toggles
class _FiltersRow extends StatelessWidget {
  const _FiltersRow({
    required this.topic,
    required this.languageLabel,
    required this.withImages,
    required this.anonOnly,
    required this.onTapTopic,
    required this.onTapLanguage,
    required this.onWithImages,
    required this.onAnonOnly,
    required this.onClear,
  });

  final String topic;
  final String languageLabel;
  final bool withImages;
  final bool anonOnly;

  final VoidCallback onTapTopic;
  final VoidCallback onTapLanguage;
  final ValueChanged<bool> onWithImages;
  final ValueChanged<bool> onAnonOnly;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(_kPadSmall),
      decoration: BoxDecoration(
        color: AppTheme.ffPrimaryBg,
        borderRadius: BorderRadius.circular(_kRadius),
        border: Border.all(color: Colors.white.withValues(alpha: .08), width: 1),
      ),
      child: Row(
        children: [
          _ToolbarChip(icon: Icons.tag, label: topic, onTap: onTapTopic),
          const SizedBox(width: 8),
          _ToolbarChip(icon: Icons.language, label: languageLabel, onTap: onTapLanguage),
          const Spacer(),
          _SmallFlag(label: 'Images', value: withImages, onChanged: onWithImages),
          const SizedBox(width: 8),
          _SmallFlag(label: 'Anon', value: anonOnly, onChanged: onAnonOnly),
          const SizedBox(width: 6),
          TextButton(onPressed: onClear, child: const Text('Clear', style: TextStyle(color: Colors.white70))),
        ],
      ),
    );
  }
}

class _SmallFlag extends StatelessWidget {
  const _SmallFlag({required this.label, required this.value, required this.onChanged});
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Switch(
        value: value,
        onChanged: onChanged,
        activeColor: AppTheme.ffPrimary,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      Text(label, style: const TextStyle(color: Colors.white70)),
    ]);
  }
}

class _ToolbarChip extends StatelessWidget {
  const _ToolbarChip({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: .06),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 16, color: Colors.white70),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(color: Colors.white)),
          ]),
        ),
      ),
    );
  }
}

class _TinyIconButton extends StatelessWidget {
  const _TinyIconButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: .35),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, color: Colors.white, size: 16),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Pick list sheet (used for language/topic)
class _PickListSheet extends StatelessWidget {
  const _PickListSheet({required this.title, required this.items, required this.selected});
  final String title;
  final List<MapEntry<String, String>> items;
  final String selected;

  static Future<T?> pick<T>(
    BuildContext context, {
    required String title,
    required List<MapEntry<T, String>> items,
    required T selected,
  }) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _PickListSheet(
        title: title,
        items: items.map((e) => MapEntry(e.key.toString(), e.value)).toList(),
        selected: selected.toString(),
      ),
    ).then((val) {
      if (val == null) return null;
      final match = items.firstWhere((e) => e.key.toString() == val, orElse: () => items.first);
      return match.key;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.ffPrimaryBg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
        border: Border.all(color: Colors.white.withValues(alpha: .08), width: 1),
        boxShadow: const [BoxShadow(blurRadius: 24, color: Colors.black54)],
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(height: 4, width: 44, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close, color: Colors.white70),
                ),
              ],
            ),
            const Divider(height: 1, color: Colors.white12),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: items.length,
                itemBuilder: (_, i) {
                  final e = items[i];
                  final sel = e.key == selected;
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                    dense: true,
                    onTap: () => Navigator.pop(context, e.key),
                    leading: Icon(sel ? Icons.radio_button_checked : Icons.radio_button_off,
                        color: sel ? AppTheme.ffPrimary : Colors.white54),
                    title: Text(e.value, style: const TextStyle(color: Colors.white)),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Detail Page (hero + actions + comments)
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
      final res = await _supa.rpc('confessions_one', params: {'p_confession_id': widget.confessionId});
      final list = (res as List?)?.cast<Map<String, dynamic>>() ?? const [];
      if (!mounted) return;
      setState(() {
        _item = list.isNotEmpty ? ConfessionItem.fromRow(list.first) : null;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
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
    final item = _item;
    final me = _supa.auth.currentUser?.id;
    final isOwner = item != null && me != null && me == item.authorUserId;

    return Scaffold(
      backgroundColor: AppTheme.ffSecondaryBg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          if (!_loading && item != null)
            PopupMenuButton<String>(
              color: const Color(0xFF0E0F12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              icon: const Icon(Icons.more_horiz, color: Colors.white70),
              onSelected: (v) async {
                final messenger = ScaffoldMessenger.of(context);
                if (v == 'copy') {
                  await Clipboard.setData(ClipboardData(text: item.content));
                  messenger.showSnackBar(const SnackBar(content: Text('Copied')));
                } else if (v == 'report') {
                  try {
                    await _supa.rpc('report_confession', params: {'p_confession_id': item.id, 'p_reason': 'inappropriate'});
                    messenger.showSnackBar(const SnackBar(content: Text('Reported.')));
                  } catch (_) {}
                } else if (v == 'edit' && isOwner) {
                  // ignore: use_build_context_synchronously
                  await showModalBottomSheet(
                    context: context,
                    isScrollControlled: true,
                    useSafeArea: true,
                    backgroundColor: Colors.transparent,
                    builder: (_) => _ComposerSheet(
                      mode: ComposerMode.edit,
                      original: item,
                      onUpdated: (updated) => setState(() => _item = updated),
                    ),
                  );
                } else if (v == 'delete' && isOwner) {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      backgroundColor: AppTheme.ffPrimaryBg,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      title: const Text('Delete confession?', style: TextStyle(color: Colors.white)),
                      content: const Text('This cannot be undone.', style: TextStyle(color: Colors.white70)),
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
                  if (ok == true) {
                    try {
                      final path = item.imagePath ?? _pathFromPublicUrl(item.imageUrl);
                      if (path != null) {
                        unawaited(_supa.storage.from('confessions').remove([path]));
                      }
                      await _supa.from('confessions').delete().eq('id', item.id);
                      if (!mounted) return;
                      Navigator.of(context).maybePop();
                    } catch (_) {
                      messenger.showSnackBar(const SnackBar(content: Text('Failed to delete')));
                    }
                  }
                }
              },
              itemBuilder: (_) => <PopupMenuEntry<String>>[
                const PopupMenuItem<String>(value: 'copy', child: Text('Copy text')),
                const PopupMenuItem<String>(value: 'report', child: Text('Report')),
                if (isOwner) const PopupMenuDivider(),
                if (isOwner) const PopupMenuItem<String>(value: 'edit', child: Text('Edit')),
                if (isOwner)
                  const PopupMenuItem<String>(
                    value: 'delete',
                    child: Text('Delete', style: TextStyle(color: Colors.red)),
                  ),
              ],
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : item == null
              ? const Center(child: Text('Confession not found', style: TextStyle(color: Colors.white70)))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                  children: [
                    _CardHeader(item: item, isOwner: isOwner, onEdit: () {}, onDelete: () {}),
                    if (item.topic != null || item.languageCode != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(_kPad, 2, _kPad, 6),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            if (item.topic != null) _MiniBadge(icon: Icons.tag, label: item.topic!),
                            if (item.languageCode != null)
                              _MiniBadge(
                                icon: Icons.language,
                                label: kLanguages.firstWhere((e) => e.key == item.languageCode!, orElse: () => const MapEntry('x', '')).value,
                              ),
                          ],
                        ),
                      ),
                    if (item.content.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(_kPad, 4, _kPad, 8),
                        child: Text(item.content, style: const TextStyle(color: Colors.white, height: 1.35)),
                      ),
                    if (item.imageUrl != null) ...[
                      const SizedBox(height: 6),
                      Hero(
                        tag: widget.heroTag ?? 'conf_img_${item.id}',
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(_kRadius),
                          child: CachedNetworkImage(
                            imageUrl: item.imageUrl!,
                            fit: BoxFit.cover,
                            placeholder: (_, __) => Container(height: 260, color: const Color(0xFF202227)),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    _ActionsRow(
                      item: item,
                      onToggleLike: () async {
                        await _supa.rpc('toggle_confession_like', params: {'p_confession_id': item.id});
                        if (!mounted) return;
                        setState(() => _item = item.copyWith(
                              likedByMe: !item.likedByMe,
                              likeCount: item.likeCount + (item.likedByMe ? -1 : 1),
                            ));
                      },
                      onOpenComments: _openComments,
                    ),
                  ],
                ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Comments bottom sheet — rounded input bar
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
          .select('id, confession_id, author_user_id, text, created_at, profiles(name, avatar_url)')
          .eq('confession_id', widget.confessionId)
          .order('created_at', ascending: true);
      final list = (rows as List?)?.cast<Map<String, dynamic>>() ?? const [];
      final mapped = list.map((r) {
        final prof = (r['profiles'] as Map?) ?? const {};
        return CommentItem(
          id: r['id'].toString(),
          confessionId: r['confession_id'].toString(),
          authorUserId: r['author_user_id'].toString(),
          authorName: (prof['name'] ?? 'Someone').toString(),
          authorAvatarUrl: (prof['avatar_url'] ?? '') == '' ? null : prof['avatar_url'].toString(),
          text: (r['text'] ?? '').toString(),
          createdAt: DateTime.tryParse((r['created_at'] ?? '').toString()) ?? DateTime.now().toUtc(),
        );
      }).toList();
      if (!mounted) return;
      setState(() {
        _comments
          ..clear()
          ..addAll(mapped);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _send() async {
    if (_posting) return;
    final text = _text.text.trim();
    if (text.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _posting = true);
    try {
      final row = await _supa
          .from('confession_comments')
          .insert({'confession_id': widget.confessionId, 'text': text})
          .select('id, confession_id, author_user_id, created_at, profiles(name, avatar_url)')
          .single();
      final prof = (row['profiles'] as Map?) ?? const {};
      final me = CommentItem(
        id: row['id'].toString(),
        confessionId: row['confession_id'].toString(),
        authorUserId: row['author_user_id'].toString(),
        authorName: (prof['name'] ?? 'You').toString(),
        authorAvatarUrl: (prof['avatar_url'] ?? '') == '' ? null : prof['avatar_url'].toString(),
        text: text,
        createdAt: DateTime.tryParse((row['created_at'] ?? '').toString()) ?? DateTime.now().toUtc(),
      );
      if (!mounted) return;
      setState(() {
        _comments.add(me);
        _text.clear();
        _posting = false;
      });
      await Future.delayed(const Duration(milliseconds: 50));
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent + 80);
    } catch (_) {
      if (mounted) setState(() => _posting = false);
      messenger.showSnackBar(const SnackBar(content: Text('Failed to send comment.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.ffPrimaryBg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
          border: Border.all(color: Colors.white.withValues(alpha: .08), width: 1),
          boxShadow: const [BoxShadow(blurRadius: 20, color: Colors.black54)],
        ),
        height: MediaQuery.of(context).size.height * 0.75,
        child: Column(
          children: [
            Container(height: 4, width: 44, margin: const EdgeInsets.only(top: 10, bottom: 6), decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
            const Text('Comments', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
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
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              CircleAvatar(
                                radius: 16,
                                backgroundColor: Colors.white12,
                                backgroundImage: c.authorAvatarUrl != null ? CachedNetworkImageProvider(c.authorAvatarUrl!) : null,
                                child: c.authorAvatarUrl == null ? const Icon(Icons.person, color: Colors.white54, size: 18) : null,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(c.authorName, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13)),
                                    const SizedBox(height: 3),
                                    Text(c.text, style: const TextStyle(color: Colors.white, height: 1.35)),
                                    const SizedBox(height: 3),
                                    Text(_timeAgo(c.createdAt), style: const TextStyle(color: Colors.white54, fontSize: 11)),
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
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF121316),
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(color: Colors.white.withValues(alpha: .14), width: 1),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
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
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.ffPrimary,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      shape: const StadiumBorder(),
                    ),
                    onPressed: _posting ? null : _send,
                    child: _posting
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
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
              borderRadius: BorderRadius.circular(_kRadius),
            ),
            child: Column(
              children: [
                const SizedBox(height: 12),
                _shimmerBar(width: 160),
                const SizedBox(height: 8),
                _shimmerBar(width: double.infinity, height: 180, radius: _kRadius - 2),
                const SizedBox(height: 12),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _shimmerBar({double width = 120, double height = 12, double radius = 6}) {
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
// Text utils
class _ExpandableText extends StatefulWidget {
  const _ExpandableText({required this.text});
  final String text;

  @override
  State<_ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<_ExpandableText> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final text = widget.text.trim();
    const clamped = 5;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AnimatedSize(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          child: Text(
            text,
            maxLines: _expanded ? null : clamped,
            overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, height: 1.38),
          ),
        ),
        if (!_expanded && _needsMore(text, clamped))
          TextButton(onPressed: () => setState(() => _expanded = true), child: const Text('See more')),
      ],
    );
  }

  bool _needsMore(String text, int lines) => text.length > 240;
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
String _timeAgo(DateTime dt) {
  final now = DateTime.now().toUtc();
  final diff = now.difference(dt.toUtc());
  if (diff.inSeconds < 60) return 'just now';
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

String? _pathFromPublicUrl(String? url) {
  if (url == null || url.isEmpty) return null;
  const marker = '/storage/v1/object/public/confessions/';
  final idx = url.indexOf(marker);
  if (idx == -1) return null;
  return url.substring(idx + marker.length);
}

// ─────────────────────────────────────────────────────────────────────────────
// CTA banner
class _HeroMessage extends StatelessWidget {
  const _HeroMessage({required this.onConfess});
  final VoidCallback onConfess;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(_kPad),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_kRadius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppTheme.ffPrimary.withValues(alpha: .18),
            Colors.white.withValues(alpha: .06),
          ],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: .10), width: 1),
      ),
      child: Row(
        children: [
          const Icon(Icons.auto_awesome, color: Colors.white, size: 26),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Share a confession',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16, letterSpacing: .2)),
                SizedBox(height: 4),
                Text("Tell the community what's on your mind — anonymous or as you.",
                    style: TextStyle(color: Colors.white70, height: 1.25)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.ffPrimary,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              shape: const StadiumBorder(),
            ),
            onPressed: onConfess,
            icon: const Icon(Icons.add, size: 18, color: Colors.white),
            label: const Text('Post', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}
