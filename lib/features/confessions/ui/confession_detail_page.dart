// =========================
// FILE: lib/features/confessions/ui/confession_detail_page.dart
// =========================

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../theme/app_theme.dart' as theme;
import '../data/confession_models.dart';
import '../data/confession_repo.dart';
import 'comments_sheet.dart';

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

class ConfessionDetailPage extends StatefulWidget {
  const ConfessionDetailPage({super.key, required this.confessionId, this.heroTag});
  final String confessionId;
  final String? heroTag;

  static const String routeName = 'ConfessionDetail';
  static const String routePath = '/confession';

  @override
  State<ConfessionDetailPage> createState() => _ConfessionDetailPageState();
}

class _ConfessionDetailPageState extends State<ConfessionDetailPage> {
  final _repo = ConfessionRepository();
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
      final it = await _repo.fetchOne(widget.confessionId);
      if (!mounted) return;
      setState(() {
        _item = it;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final it = _item;

    return Scaffold(
      backgroundColor: theme.AppTheme.ffSecondaryBg,
      appBar: AppBar(
        backgroundColor: theme.AppTheme.ffSecondaryBg,
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
                        placeholder: (_, __) => Container(height: 240, color: const Color(0xFF202227)),
                        errorWidget: (_, __, ___) => Container(
                          height: 240,
                          color: const Color(0xFF1E1F24),
                          child: const Center(child: Icon(Icons.broken_image, color: Colors.white38)),
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
                    Text(_timeAgo(it.createdAt), style: const TextStyle(color: Colors.white54)),
                  ],
                ),
                const SizedBox(height: 10),
                if (it.content.isNotEmpty)
                  Text(it.content, style: const TextStyle(color: Colors.white, height: 1.35)),
                const SizedBox(height: 12),
                Row(
                  children: [
                    _PillButton(
                      icon: it.likedByMe ? Icons.favorite : Icons.favorite_border,
                      color: it.likedByMe ? Colors.pinkAccent : Colors.white,
                      label: it.likeCount.toString(),
                      onTap: () async {
                        // optimistic UI
                        setState(() {
                          _item = it.copyWith(
                            likedByMe: !it.likedByMe,
                            likeCount: it.likeCount + (it.likedByMe ? -1 : 1),
                          );
                        });
                        try {
                          final tiny = await _repo.toggleLike(it.id);
                          if (!mounted || tiny == null) return;
                          setState(() {
                            _item = _item!.copyWith(
                              likedByMe: tiny.likedByMe,
                              likeCount: tiny.likeCount,
                            );
                          });
                        } catch (_) {
                          // ignore; stays optimistic
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
                        builder: (_) => CommentsSheet(confessionId: widget.confessionId),
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Share link',
                      icon: const Icon(Icons.share, color: Colors.white70),
                      onPressed: () async {
                        final url = 'https://yourapp.example/confession/${it.id}'; // replace with your deep link
                        await Supabase.instance.client.functions.invoke('share_copy', body: {'url': url});
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link copied')));
                      },
                    ),
                  ],
                ),
              ],
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
        color: theme.AppTheme.ffPrimary.withOpacity(.18),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.AppTheme.ffAlt.withOpacity(.35), width: 1),
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
        border: Border.all(color: theme.AppTheme.ffAlt.withOpacity(.35), width: 1),
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
