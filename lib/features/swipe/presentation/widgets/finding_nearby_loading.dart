// ─────────────────────────────────────────────────────────────────────────────
// lib/features/swipe/presentation/widgets/finding_nearby_loading.dart
// Lightweight “Finding people near you …” loader (no provider writes).
// ─────────────────────────────────────────────────────────────────────────────

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

class FindingNearbyLoading extends StatefulWidget {
  const FindingNearbyLoading({
    super.key,
    this.avatarUrl,
  });

  final String? avatarUrl;

  @override
  State<FindingNearbyLoading> createState() => _FindingNearbyLoadingState();
}

class _FindingNearbyLoadingState extends State<FindingNearbyLoading>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))
        ..repeat(reverse: true);
  late final Animation<double> _pulse =
      Tween<double>(begin: 0.88, end: 1.06).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF0F0F14), Color(0xFF191C21)],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
        ),
        const ColoredBox(color: Color(0xCB880EE7)),
        Center(
          child: ScaleTransition(
            scale: _pulse,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 160,
                  height: 160,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      AnimatedBuilder(
                        animation: _c,
                        builder: (_, __) {
                          final t = (_c.value - 0.5).abs() * 2;
                          return Container(
                            width: 140,
                            height: 140,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: RadialGradient(
                                colors: [
                                  const Color(0xFFFF0F7B).withValues(alpha: .10 + .10 * (1 - t)),
                                  Colors.transparent,
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                      Container(
                        width: 100,
                        height: 100,
                        decoration: BoxDecoration(
                          color: const Color(0xFF202227),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white.withValues(alpha: .25)),
                          boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 12, offset: Offset(0, 6))],
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: (widget.avatarUrl == null || widget.avatarUrl!.isEmpty)
                            ? const Icon(Icons.person, color: Colors.white70, size: 44)
                            : Image(image: CachedNetworkImageProvider(widget.avatarUrl!), fit: BoxFit.cover),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.radar_rounded, size: 18, color: Color(0xFFFF0F7B)),
                    const SizedBox(width: 6),
                    Text(
                      'Finding people near you…',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: .9),
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        letterSpacing: .2,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
