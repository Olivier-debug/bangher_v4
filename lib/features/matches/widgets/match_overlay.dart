// ignore_for_file: library_private_types_in_public_api

import 'dart:math' as math;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// Tiny lightweight profile used by the overlay.
class ProfileLite {
  const ProfileLite({
    required this.id,
    required this.name,
    this.photoUrl,
    this.subtitle, // e.g. "23 • 3km away"
    this.bio,
  });

  final String id;
  final String name;
  final String? photoUrl;
  final String? subtitle;
  final String? bio;
}

/// Fancy "It's a match!" overlay with full-bleed photo, bio and confetti.
/// API stays the same as your current code uses.
class MatchOverlay {
  static Future<void> show(
    BuildContext context, {
    required ProfileLite me,
    required ProfileLite other,
    required VoidCallback onMessage,
    required VoidCallback onDismiss,
  }) async {
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      transitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (context, _, __) {
        return _MatchDialog(
          me: me,
          other: other,
          onMessage: onMessage,
          onDismiss: onDismiss,
        );
      },
      transitionBuilder: (context, anim, _, child) {
        final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
        return Opacity(
          opacity: curved.value,
          child: Transform.scale(
            scale: 0.98 + curved.value * 0.02,
            child: child,
          ),
        );
      },
    );
  }
}

class _MatchDialog extends StatefulWidget {
  const _MatchDialog({
    required this.me,
    required this.other,
    required this.onMessage,
    required this.onDismiss,
  });

  final ProfileLite me;
  final ProfileLite other;
  final VoidCallback onMessage;
  final VoidCallback onDismiss;

  @override
  State<_MatchDialog> createState() => _MatchDialogState();
}

class _MatchDialogState extends State<_MatchDialog>
    with SingleTickerProviderStateMixin {
  late final AnimationController _confettiCtrl;

  @override
  void initState() {
    super.initState();
    _confettiCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..forward();
  }

  @override
  void dispose() {
    _confettiCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final other = widget.other;
    final size = MediaQuery.of(context).size;

    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          // Dim background
          Positioned.fill(
            child: Container(color: Colors.black.withOpacity(0.60)),
          ),

          // Full-bleed OTHER user's photo behind the card
          Positioned.fill(
            child: _HeroImage(url: other.photoUrl),
          ),

          // Soft vignette
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      Colors.black.withOpacity(0.75),
                      Colors.black.withOpacity(0.25),
                      Colors.transparent,
                    ],
                    stops: const [0, .35, 1],
                  ),
                ),
              ),
            ),
          ),

          // Confetti sprinkles
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _ConfettiPainter(animation: _confettiCtrl),
              ),
            ),
          ),

          // Foreground card
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                bottom: math.max(16, MediaQuery.of(context).padding.bottom + 12),
              ),
              child: _GlassCard(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: math.min(520, size.width - 32),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Avatars row
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _TinyAvatar(url: widget.me.photoUrl),
                            const SizedBox(width: 10),
                            const Icon(Icons.favorite, color: Color(0xFFFF0F7B)),
                            const SizedBox(width: 10),
                            _TinyAvatar(url: other.photoUrl),
                          ],
                        ),
                        const SizedBox(height: 14),
                        // Headline
                        Text(
                          "It's a match!",
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 6),
                        // Name + optional subtitle
                        Text(
                          other.subtitle == null
                              ? other.name
                              : '${other.name} • ${other.subtitle}',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 16,
                            color: Colors.white.withOpacity(0.95),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if ((other.bio ?? '').trim().isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Text(
                            (other.bio ?? '').trim(),
                            textAlign: TextAlign.center,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.white.withOpacity(0.85),
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),

                        // Buttons
                        Row(
                          children: [
                            Expanded(
                              child: _PrimaryBtn(
                                label: 'Say Hello',
                                onTap: () {
                                  Navigator.of(context).maybePop();
                                  widget.onMessage();
                                },
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        _GhostBtn(
                          label: 'Keep swiping',
                          onTap: () {
                            Navigator.of(context).maybePop();
                            widget.onDismiss();
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Close tap area (top-right)
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            right: 8,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ),
        ],
      ),
    );
  }
}

/// -------------------- visuals --------------------

class _HeroImage extends StatelessWidget {
  const _HeroImage({this.url});
  final String? url;

  @override
  Widget build(BuildContext context) {
    if (url == null || url!.isEmpty) {
      return Container(color: Colors.black);
    }
    return CachedNetworkImage(
      imageUrl: url!,
      fit: BoxFit.cover,
      placeholder: (_, __) => const SizedBox.expand(),
      errorWidget: (_, __, ___) => Container(color: Colors.black),
    );
  }
}

class _TinyAvatar extends StatelessWidget {
  const _TinyAvatar({this.url});
  final String? url;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white.withOpacity(0.35), width: 2),
        boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 12)],
      ),
      clipBehavior: Clip.antiAlias,
      child: url == null || url!.isEmpty
          ? Container(color: Colors.white10)
          : CachedNetworkImage(
              imageUrl: url!,
              fit: BoxFit.cover,
            ),
    );
  }
}

class _GlassCard extends StatelessWidget {
  const _GlassCard({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF121217).withOpacity(0.82),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withOpacity(0.16)),
        boxShadow: const [
          BoxShadow(blurRadius: 40, color: Colors.black54, offset: Offset(0, 16)),
        ],
      ),
      child: child,
    );
  }
}

class _PrimaryBtn extends StatelessWidget {
  const _PrimaryBtn({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          padding: EdgeInsets.zero,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          backgroundColor: Colors.transparent,
        ),
        onPressed: onTap,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: const LinearGradient(
              colors: [Color(0xFF6759FF), Color(0xFFFF0F7B)],
            ),
          ),
          child: Center(
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 16,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GhostBtn extends StatelessWidget {
  const _GhostBtn({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        side: BorderSide(color: Colors.white.withOpacity(0.65)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      onPressed: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
    );
  }
}

/// Simple confetti painter (no packages).
class _ConfettiPainter extends CustomPainter {
  _ConfettiPainter({required this.animation}) : super(repaint: animation);

  final Animation<double> animation;
  final math.Random _rng = math.Random();

  @override
  void paint(Canvas canvas, Size size) {
    final t = animation.value;
    final count = 80;
    final colors = <Color>[
      const Color(0xFFFF0F7B),
      const Color(0xFF6759FF),
      const Color(0xFFFFD166),
      const Color(0xFF26C6DA),
      const Color(0xFF66BB6A),
    ];

    for (var i = 0; i < count; i++) {
      final p = (i / count + t) % 1.0;
      final x = size.width * (i / count);
      final y = size.height * (p * p); // ease-in fall
      final s = 2.0 + 3.0 * ((_rng.nextInt(100 + i) % 100) / 100.0);
      final paint = Paint()
        ..color = colors[i % colors.length].withOpacity(1.0 - p * 0.9);
      canvas.drawCircle(Offset(x, y), s, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
