// FILE: lib/features/confessions/ui/comments_sheet.dart
// =========================

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../theme/app_theme.dart' as theme; // path: lib/theme/app_theme.dart
import '../data/confession_models.dart';
import '../data/confession_repo.dart';

// Small helpers
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

/// Comments bottom sheet with pagination + optimistic insert
class CommentsSheet extends StatefulWidget {
  const CommentsSheet({super.key, required this.confessionId});
  final String confessionId;

  @override
  State<CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends State<CommentsSheet> {
  final _repo = ConfessionRepository();
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
      final list = await _repo.fetchComments(
        confessionId: widget.confessionId,
        limit: _pageSize,
        offset: 0,
      );
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(list);
        _end = list.length < _pageSize;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack(context, 'Failed to load comments');
    }
  }

  Future<void> _loadMore() async {
    if (_fetchingMore || _end) return;
    setState(() => _fetchingMore = true);
    try {
      final offset = _items.length;
      final list = await _repo.fetchComments(
        confessionId: widget.confessionId,
        limit: _pageSize,
        offset: offset,
      );
      if (!mounted) return;
      setState(() {
        _items.addAll(list);
        if (list.length < _pageSize) _end = true;
      });
    } catch (e) {
      // ignore but stop spinner
    } finally {
      if (mounted) setState(() => _fetchingMore = false);
    }
  }

  Future<void> _post() async {
    if (_posting) return;
    final text = _input.text.trim();
    if (text.isEmpty) return;

    setState(() => _posting = true);

    // optimistic
    final uid = Supabase.instance.client.auth.currentUser?.id ?? 'me';
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

    try {
      final real = await _repo.postComment(confessionId: widget.confessionId, text: text);
      if (!mounted) return;
      setState(() {
        final idx = _items.indexWhere((c) => c.id == temp.id);
        if (idx != -1) {
          _items[idx] = real;
        } else {
          _items.insert(0, real);
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _items.removeWhere((c) => c.id == temp.id));
      _snack(context, 'Failed to comment.');
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
          color: theme.AppTheme.ffPrimaryBg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        height: MediaQuery.of(context).size.height * .88,
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              height: 4,
              width: 40,
              decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
            ),
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
                      itemBuilder: (ctx, i) {
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
                                              color: Colors.white,
                                              fontWeight: FontWeight.w600,
                                            ),
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
                              IconButton(
                                tooltip: 'Copy',
                                icon: const Icon(Icons.copy, color: Colors.white38, size: 18),
                                onPressed: () async {
                                  await Clipboard.setData(ClipboardData(text: c.text));
                                  if (!ctx.mounted) return; // guard the same BuildContext used below
                                  _snack(ctx, 'Copied');
                                },
                              )
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
                          borderSide: BorderSide(color: theme.AppTheme.ffAlt.withValues(alpha: .35)),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: theme.AppTheme.ffAlt.withValues(alpha: .35)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: theme.AppTheme.ffPrimary.withValues(alpha: .55)),
                        ),
                      ),
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _posting ? null : _post,
                    style: FilledButton.styleFrom(
                      backgroundColor: theme.AppTheme.ffPrimary,
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
