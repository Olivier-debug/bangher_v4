// FILE: lib/features/matches/widgets/match_overlay.dart
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../../theme/app_theme.dart';
import '../../matches/match_repository.dart';

class MatchOverlay extends StatefulWidget {
  const MatchOverlay({
    super.key,
    required this.me,
    required this.other,
    this.onMessage,
    this.onDismiss,
  });

  final ProfileLite me;
  final ProfileLite other;
  final VoidCallback? onMessage;
  final VoidCallback? onDismiss;

  static Future<void> show(
    BuildContext context, {
    required ProfileLite me,
    required ProfileLite other,
    VoidCallback? onMessage,
    VoidCallback? onDismiss,
  }) async {
    await showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'match',
      barrierColor: Colors.black.withValues(alpha: 0.75),
      pageBuilder: (_, __, ___) => Center(
        child: MatchOverlay(me: me, other: other, onMessage: onMessage, onDismiss: onDismiss),
      ),
      transitionBuilder: (ctx, anim, __, child) {
        final scale = Tween<double>(begin: 0.95, end: 1.0).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutBack));
        final fade  = Tween<double>(begin: 0.0, end: 1.0).animate(CurvedAnimation(parent: anim, curve: Curves.easeOut));
        return Opacity(
          opacity: fade.value,
          child: Transform.scale(scale: scale.value, child: child),
        );
      },
      transitionDuration: const Duration(milliseconds: 280),
    );
  }

  @override
  State<MatchOverlay> createState() => _MatchOverlayState();
}

class _MatchOverlayState extends State<MatchOverlay> with TickerProviderStateMixin {
  late final AnimationController _pulse1;
  late final AnimationController _pulse2;
  late final AnimationController _pulse3;

  @override
  void initState() {
    super.initState();
    _pulse1 = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat(reverse: true);
    _pulse2 = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat(reverse: true);
    _pulse3 = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse1.dispose();
    _pulse2.dispose();
    _pulse3.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final primaryBg = AppTheme.ffPrimaryBg;
    final outline   = AppTheme.ffAlt;
    final primary   = AppTheme.ffPrimary;

    return Material(
      color: Colors.transparent,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 18),
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
        decoration: BoxDecoration(
          color: primaryBg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: outline),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 24, offset: const Offset(0, 16)),
          ],
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Stacked, slightly rotated profile images
              SizedBox(
                width: 300,
                height: 380,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    _PulsingHeart(controller: _pulse1, size: 60, dx: -120, dy: -140, color: primary),
                    _PulsingHeart(controller: _pulse2, size: 40, dx: 120, dy: -120, color: primary),
                    _PulsingHeart(controller: _pulse3, size: 50, dx: -100, dy: 140, color: primary),

                    Align(
                      alignment: const Alignment(1, -0.4),
                      child: Transform.rotate(
                        angle: 10 * (math.pi / 180),
                        child: _PicCard(url: widget.me.photoUrl, fallbackLetter: _firstLetter(widget.me.name)),
                      ),
                    ),
                    Align(
                      alignment: const Alignment(-1, 0.6),
                      child: Transform.rotate(
                        angle: -10 * (math.pi / 180),
                        child: _PicCard(url: widget.other.photoUrl, fallbackLetter: _firstLetter(widget.other.name)),
                      ),
                    ),

                    // Center mini heart token
                    Align(
                      alignment: Alignment.center,
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: primaryBg,
                          shape: BoxShape.circle,
                          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .25), blurRadius: 10)],
                          border: Border.all(color: outline),
                        ),
                        child: Icon(Icons.favorite, size: 22, color: primary),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text(
                "It's a match, ${widget.me.name}!",
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  letterSpacing: .2,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                "Now’s your chance — say hi to ${widget.other.name}.",
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 18),

              // Buttons
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: primary,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () {
                    Navigator.of(context).maybePop();
                    widget.onMessage?.call();
                  },
                  child: const Text('Say Hello', style: TextStyle(color: Colors.white, fontSize: 16)),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: outline),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () {
                    Navigator.of(context).maybePop();
                    widget.onDismiss?.call();
                  },
                  child: const Text('Keep swiping', style: TextStyle(fontSize: 16)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _firstLetter(String s) {
    final t = s.trim();
    return t.isEmpty ? 'U' : t.characters.first.toUpperCase();
  }
}

class _PicCard extends StatelessWidget {
  const _PicCard({required this.url, required this.fallbackLetter});
  final String? url;
  final String fallbackLetter;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 172,
      height: 248,
      decoration: BoxDecoration(
        color: AppTheme.ffPrimaryBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.ffAlt),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .25), blurRadius: 12, offset: const Offset(0, 8))],
        image: url == null
            ? null
            : DecorationImage(
                image: NetworkImage(url!),
                fit: BoxFit.cover,
                onError: (_, __) {},
              ),
      ),
      child: url == null
          ? Center(
              child: Text(
                fallbackLetter,
                style: const TextStyle(color: Colors.white70, fontSize: 56, fontWeight: FontWeight.w700),
              ),
            )
          : null,
    );
  }
}

class _PulsingHeart extends StatelessWidget {
  const _PulsingHeart({
    required this.controller,
    required this.size,
    required this.dx,
    required this.dy,
    required this.color,
  });

  final AnimationController controller;
  final double size;
  final double dx;
  final double dy;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: AppTheme.ffPrimaryBg,
          shape: BoxShape.circle,
          border: Border.all(color: AppTheme.ffAlt),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .25), blurRadius: 10)],
        ),
        child: Icon(Icons.favorite, color: color, size: size * 0.6),
      ),
      builder: (_, child) {
        final s = 0.9 + 0.1 * (1 + math.sin(controller.value * math.pi * 2)) / 2;
        return Transform.translate(
          offset: Offset(dx, dy),
          child: Transform.scale(scale: s, child: child),
        );
      },
    );
  }
}
