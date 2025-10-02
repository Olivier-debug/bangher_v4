// -----------------------------------------------------------------------------
// PeerAvatar
// - Circular avatar that resolves & refreshes a user's image via Resolver.
// -----------------------------------------------------------------------------

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../core/images/peer_avatar_resolver.dart';

class PeerAvatar extends StatefulWidget {
  const PeerAvatar({
    super.key,
    required this.userId,
    this.online = false,
    this.size = 36,
    this.border,
  });

  final String userId;
  final bool online;
  final double size;
  final BoxBorder? border;

  @override
  State<PeerAvatar> createState() => _PeerAvatarState();
}

class _PeerAvatarState extends State<PeerAvatar> {
  String? _url;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant PeerAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.userId != widget.userId) {
      _resolve();
    }
  }

  void _resolve() {
    if (widget.userId.isEmpty) {
      setState(() => _url = null);
      return;
    }
    PeerAvatarResolver.instance.getAvatarUrl(widget.userId).then((u) {
      if (!mounted) return;
      setState(() => _url = u);
    });
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.size;

    return SizedBox(
      width: d,
      height: d,
      child: Stack(
        children: [
          Container(
            width: d,
            height: d,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: widget.border,
            ),
            child: ClipOval(
              child: (_url == null || _url!.isEmpty)
                  ? const ColoredBox(color: Color(0xFF1E1F24))
                  : CachedNetworkImage(
                      imageUrl: _url!,
                      fit: BoxFit.cover,
                      fadeInDuration: const Duration(milliseconds: 120),
                      errorWidget: (_, __, ___) => const ColoredBox(color: Color(0xFF1E1F24)),
                    ),
            ),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: (d * 0.25).clamp(10, 16),
              height: (d * 0.25).clamp(10, 16),
              decoration: BoxDecoration(
                color: widget.online ? const Color(0xFF2ECC71) : const Color(0xFF50535B),
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFF14151A), width: 2),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
