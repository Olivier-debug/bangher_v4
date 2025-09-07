// =========================
// FILE: lib/features/confessions/confessions_feature.dart
// =========================
// Confessions v2 — Engaging feed with media, hero transitions, reactions, comments.
// - Realtime v2 (onPostgresChanges)
// - Image attach & upload to Supabase Storage (bucket: 'confessions')
// - Optimistic posting/liking
// - Pull-to-refresh + infinite scroll
// - Hero image to detail page, comments sheet with composer
// - Anonymous posts; comments always show user
// - Minimal dependencies: cached_network_image, image_picker, supabase_flutter
// - No extra theming assumptions beyond AppTheme

import 'dart:async';



import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
  const ConfessionDetailPage({super.key, required this.confessionId, this.heroTag});
  final String confessionId;
  final String? heroTag; // image hero tag

  static const String routeName = 'ConfessionDetail';
  static const String routePath = '/confession';

  @override
  State<ConfessionDetailPage> createState() => _ConfessionDetailPageState();
}

// ─────────────────────────────────────────────────────────────────────────────
// Models (lightweight; maps to SQL schema you created earlier)
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
  });

  ConfessionItem copyWith({
    int? likeCount,
    int? commentCount,
    bool? likedByMe,
  }) => ConfessionItem(
        id: id,
        authorUserId: authorUserId,
        content: content,
        isAnonymous: isAnonymous,
        imageUrl: imageUrl,
        createdAt: createdAt,
        likeCount: likeCount ?? this.likeCount,
        commentCount: commentCount ?? this.commentCount,
        likedByMe: likedByMe ?? this.likedByMe,
        authorName: authorName,
        authorAvatarUrl: authorAvatarUrl,
      );

  static ConfessionItem fromRow(Map<String, dynamic> r, {String? me}) {
    return ConfessionItem(
      id: r['id'].toString(),
      authorUserId: (r['author_user_id'] ?? '').toString(),
      content: (r['content'] ?? '').toString(),
      isAnonymous: r['is_anonymous'] == true,
      imageUrl: (r['image_url'] ?? '') == '' ? null : r['image_url'].toString(),
      createdAt: DateTime.tryParse((r['created_at'] ?? '').toString()) ?? DateTime.now().toUtc(),
      likeCount: (r['like_count'] as int?) ?? 0,
      commentCount: (r['comment_count'] as int?) ?? 0,
      likedByMe: (r['liked_by_me'] as bool?) ?? false,
      authorName: (r['author_name'] ?? r['name'] ?? '') == '' ? null : (r['author_name'] ?? r['name']).toString(),
      authorAvatarUrl: (r['author_avatar_url'] ?? '') == '' ? null : r['author_avatar_url'].toString(),
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

  static CommentItem fromRow(Map<String, dynamic> r) => CommentItem(
        id: r['id'].toString(),
        confessionId: r['confession_id'].toString(),
        authorUserId: r['author_user_id'].toString(),
        authorName: (r['author_name'] ?? r['name'] ?? 'Someone').toString(),
        authorAvatarUrl: (r['author_avatar_url'] ?? '') == '' ? null : r['author_avatar_url'].toString(),
        text: (r['text'] ?? '').toString(),
        createdAt: DateTime.tryParse((r['created_at'] ?? '').toString()) ?? DateTime.now().toUtc(),
      );
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
      // Server-side query: join profiles for author name/avatar and whether I liked
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
      final list = (rows as List?)?.cast<Map<String, dynamic>>() ?? const <Map<String, dynamic>>[];
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
            // hydrate additional fields via a small select (keeps code simple)
            try {
              final me = _supa.auth.currentUser?.id;
              final res = await _supa.rpc('confessions_one', params: {
                'p_confession_id': row['id'],
              });
              final list = (res as List?)?.cast<Map<String, dynamic>>() ?? const [];
              if (list.isEmpty) return;
              final item = ConfessionItem.fromRow(list.first, me: me);
              if (!mounted) return;
              setState(() {
                _items.insert(0, item);
              });
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
            final nr = payload.newRecord;
            final id = nr['id'].toString();
            final likeCount = (nr['like_count'] as int?) ?? 0;
            final commentCount = (nr['comment_count'] as int?) ?? 0;
            if (!mounted) return;
            final idx = _items.indexWhere((e) => e.id == id);
            if (idx != -1) {
              setState(() {
                _items[idx] = _items[idx].copyWith(likeCount: likeCount, commentCount: commentCount);
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
      builder: (_) => _ComposerSheet(onPosted: _onPosted),
    );
  }

  void _onPosted(ConfessionItem item) {
    setState(() => _items.insert(0, item));
    // no need to scroll; but we could animate to top if desired
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.ffSecondaryBg,
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _refresh,
          color: AppTheme.ffPrimary,
          child: _loading
              ? const _FeedSkeleton()
              : CustomScrollView(
                  controller: _scroll,
                  slivers: [
                    // Friendly CTA banner
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                        child: _HeroMessage(onConfess: _openComposer),
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 92),
                      sliver: SliverList.builder(
                        itemCount: _items.length + (_fetchingMore ? 1 : 0),
                        itemBuilder: (context, i) {
                          if (i >= _items.length) {
                            return const Padding(
                              padding: EdgeInsets.symmetric(vertical: 18),
                              child: Center(child: CircularProgressIndicator()),
                            );
                          }
                          final item = _items[i];
                          return _ConfessionCard(
                            item: item,
                            onTapImage: (tag) {
                              Navigator.of(context).push(
                                PageRouteBuilder(
                                  transitionDuration: const Duration(milliseconds: 250),
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
                            onOpenComments: () {
                              _openComments(item.id);
                            },
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
        icon: const Icon(Icons.add, color: Colors.white),
        label: const Text('Confess', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
      ),
    );
  }

  Future<ConfessionItem?> _toggleLike(ConfessionItem item) async {
    try {
      // optimistic
      final prev = item;
      final optimistic = prev.copyWith(
        likedByMe: !prev.likedByMe,
        likeCount: prev.likeCount + (prev.likedByMe ? -1 : 1),
      );
      setState(() {
        final idx = _items.indexWhere((e) => e.id == prev.id);
        if (idx != -1) _items[idx] = optimistic;
      });

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
}

// ─────────────────────────────────────────────────────────────────────────────
// Composer Sheet (image attach + anonymous toggle)
class _ComposerSheet extends StatefulWidget {
  const _ComposerSheet({required this.onPosted});
  final void Function(ConfessionItem item) onPosted;

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

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    try {
      final x = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 85, maxWidth: 2000);
      if (x != null) setState(() => _picked = x);
    } catch (e) {
      debugPrint('pick image error: $e');
    }
  }

  Future<void> _post() async {
    if (_posting) return;
    final content = _text.text.trim();
    if (content.isEmpty && _picked == null) return;

    setState(() => _posting = true);

    try {
      String? imageUrl;
      if (_picked != null) {
        final bytes = await _picked!.readAsBytes();
        final ext = _picked!.name.split('.').last.toLowerCase();
        final me = _supa.auth.currentUser?.id ?? 'anon';
        final path = 'u_$me/${DateTime.now().millisecondsSinceEpoch}.${ext.isEmpty ? 'jpg' : ext}';
        await _supa.storage.from('confessions').uploadBinary(path, bytes,
            fileOptions: const FileOptions(cacheControl: '3600', upsert: false, contentType: 'image/jpeg'));
        imageUrl = _supa.storage.from('confessions').getPublicUrl(path);
      }

      final row = await _supa
          .from('confessions')
          .insert({
            'content': content,
            'is_anonymous': _anon,
            if (imageUrl != null) 'image_url': imageUrl,
          })
          .select()
          .single();

      // Hydrate with feed view (counts, liked_by_me, author fields)
      final res = await _supa.rpc('confessions_one', params: {
        'p_confession_id': row['id'],
      });
      final list = (res as List?)?.cast<Map<String, dynamic>>() ?? const [];
      final item = list.isNotEmpty ? ConfessionItem.fromRow(list.first) : ConfessionItem(
        id: row['id'].toString(),
        authorUserId: (row['author_user_id'] ?? '').toString(),
        content: content,
        isAnonymous: _anon,
        imageUrl: imageUrl,
        createdAt: DateTime.tryParse((row['created_at'] ?? '').toString()) ?? DateTime.now().toUtc(),
        likeCount: 0,
        commentCount: 0,
        likedByMe: false,
        authorName: null,
        authorAvatarUrl: null,
      );

      if (!mounted) return;
      widget.onPosted(item);
      Navigator.of(context).maybePop();
    } catch (e) {
      debugPrint('post confession error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            'Posting failed. Check your connection and that the confessions bucket & DB functions exist.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
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
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.auto_awesome, color: AppTheme.ffPrimary),
                const SizedBox(width: 8),
                const Text('New confession', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                const Spacer(),
                Switch(
                  value: _anon,
                  onChanged: (v) => setState(() => _anon = v),
                  thumbIcon: WidgetStateProperty.resolveWith((states) => Icon(_anon ? Icons.visibility_off : Icons.person)),
                  thumbColor: WidgetStateProperty.all(Colors.white),
                  trackColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.selected) ? AppTheme.ffPrimary : Colors.white24),
                ),
                const SizedBox(width: 6),
                const Text('Anonymous', style: TextStyle(color: Colors.white70)),
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
            if (_picked != null) ...[
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: FutureBuilder<Uint8List>(
                  future: _picked!.readAsBytes(),
                  builder: (context, snap) {
                    if (!snap.hasData) {
                      return Container(height: 180, color: Colors.black12);
                    }
                    return Image.memory(
                      snap.data!,
                      fit: BoxFit.cover,
                      height: 180,
                    );
                  },
                ),
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
                ElevatedButton(
                  onPressed: _posting ? null : _post,
                  style: ElevatedButton.styleFrom(backgroundColor: AppTheme.ffPrimary),
                  child: _posting
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Post', style: TextStyle(color: Colors.white)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Card
class _ConfessionCard extends StatelessWidget {
  const _ConfessionCard({
    required this.item,
    required this.onToggleLike,
    required this.onOpenComments,
    required this.onTapImage,
  });

  final ConfessionItem item;
  final VoidCallback onToggleLike;
  final VoidCallback onOpenComments;
  final void Function(String heroTag) onTapImage;

  @override
  Widget build(BuildContext context) {
    const tag = 'public_profile_photo_{widget.userId}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.ffPrimaryBg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppTheme.ffAlt.withValues(alpha: .35), width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _CardHeader(item: item),
            if (item.content.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
                child: _ExpandableText(text: item.content),
              ),
            if (item.imageUrl != null)
              GestureDetector(
                onTap: () => onTapImage(tag),
                child: Hero(
                  tag: tag,
                  child: ClipRRect(
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(0), bottom: Radius.circular(12)),
                    child: CachedNetworkImage(
                      imageUrl: item.imageUrl!,
                      fit: BoxFit.cover,
                      placeholder: (_, __) => Container(height: 220, color: Colors.black12),
                      errorWidget: (_, __, ___) => Container(
                        height: 220,
                        color: Colors.black26,
                        child: const Center(child: Icon(Icons.broken_image, color: Colors.white38)),
                      ),
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
  const _CardHeader({required this.item});
  final ConfessionItem item;

  @override
  Widget build(BuildContext context) {
    final isAnon = item.isAnonymous;
    final name = isAnon ? 'Anonymous' : (item.authorName ?? 'Someone');
    final avatar = isAnon ? null : item.authorAvatarUrl;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(_timeAgo(item.createdAt), style: const TextStyle(color: Colors.white54, fontSize: 12)),
              ],
            ),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_horiz, color: Colors.white70),
            onSelected: (v) async {
              if (v == 'report') {
                // best-effort report; ignore errors
                try {
                  await Supabase.instance.client.rpc('report_confession', params: {
                    'p_confession_id': item.id,
                    'p_reason': 'inappropriate',
                  });
                  // ignore: use_build_context_synchronously
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Reported.')));
                } catch (_) {}
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem<String>(value: 'report', child: Text('Report')),
            ],
          )
        ],
      ),
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
      padding: const EdgeInsets.fromLTRB(6, 0, 6, 10),
      child: Row(
        children: [
          _PillButton(
            icon: item.likedByMe ? Icons.favorite : Icons.favorite_border,
            color: item.likedByMe ? Colors.pinkAccent : Colors.white,
            label: item.likeCount.toString(),
            onTap: onToggleLike,
          ),
          const SizedBox(width: 6),
          _PillButton(
            icon: Icons.mode_comment_outlined,
            color: Colors.white,
            label: item.commentCount.toString(),
            onTap: onOpenComments,
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.share, color: Colors.white70),
            onPressed: () {},
          )
        ],
      ),
    );
  }
}

class _PillButton extends StatelessWidget {
  const _PillButton({required this.icon, required this.color, required this.label, required this.onTap});
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
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
// Feed CTA banner
class _HeroMessage extends StatelessWidget {
  const _HeroMessage({required this.onConfess});
  final VoidCallback onConfess;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppTheme.ffPrimary.withValues(alpha: .18),
            Colors.white.withValues(alpha: .06),
          ],
        ),
        border: Border.all(color: AppTheme.ffAlt.withValues(alpha: .35), width: 1),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Icon(Icons.auto_awesome, color: Colors.white, size: 28),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Share a confession',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16, letterSpacing: .2),
                ),
                SizedBox(height: 4),
                Text(
                  "Tell the community what's on your mind — anonymous or as you.",
                  style: TextStyle(color: Colors.white70, height: 1.25),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          ElevatedButton.icon(
            onPressed: onConfess,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.ffPrimary,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              shape: const StadiumBorder(),
            ),
            icon: const Icon(Icons.add, size: 18, color: Colors.white),
            label: const Text('Post', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Detail Page (with hero image + comments thread)
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
    return Scaffold(
      backgroundColor: AppTheme.ffSecondaryBg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : item == null
              ? const Center(child: Text('Confession not found', style: TextStyle(color: Colors.white70)))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                  children: [
                    _CardHeader(item: item),
                    if (item.content.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
                        child: Text(item.content, style: const TextStyle(color: Colors.white, height: 1.35)),
                      ),
                    if (item.imageUrl != null) ...[
                      const SizedBox(height: 6),
                      Hero(
                        tag: widget.heroTag ?? 'conf_img_${item.id}',
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: CachedNetworkImage(
                            imageUrl: item.imageUrl!,
                            fit: BoxFit.cover,
                            placeholder: (_, __) => Container(height: 260, color: Colors.black12),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    _ActionsRow(item: item, onToggleLike: () async {
                      // optimistic like inside detail
                      await Supabase.instance.client.rpc('toggle_confession_like', params: {
                        'p_confession_id': item.id,
                      });
                      if (!mounted) return;
                      setState(() {
                        // fallback: refetch; cheaper: just flip
                        _item = item.copyWith(
                          likedByMe: !item.likedByMe,
                          likeCount: item.likeCount + (item.likedByMe ? -1 : 1),
                        );
                      });
                    }, onOpenComments: _openComments),
                  ],
                ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
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
          .select('id, confession_id, author_user_id, text, created_at, profiles(name, profile_pictures)')
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
    } catch (e) {
      if (!mounted) return;
      setState(() => _posting = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to send comment.')));
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
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
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
              color: AppTheme.ffPrimaryBg,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              children: [
                const SizedBox(height: 12),
                _shimmerBar(width: 160),
                const SizedBox(height: 8),
                _shimmerBar(width: double.infinity, height: 160, radius: 12),
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
            colors: [Color(0x22FFFFFF), Color(0x11FFFFFF), Color(0x22FFFFFF)],
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
    const clamped = 4;
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
            style: const TextStyle(color: Colors.white, height: 1.35),
          ),
        ),
        if (!_expanded && _needsMore(text, clamped))
          TextButton(
            onPressed: () => setState(() => _expanded = true),
            child: const Text('See more'),
          )
      ],
    );
  }

  bool _needsMore(String text, int lines) {
    // heuristic: more than 220 chars likely overflow 4 lines on mobile
    return text.length > 220;
  }
}

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

