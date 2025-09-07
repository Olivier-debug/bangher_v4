// FILE: lib/features/matches/pages/finding_nearby_matches_page.dart
// Purpose: Pure Flutter "Finding nearby matches" page with a very dark,
// blurred haze over the Earth background so it's barely visible.
// Also fixes lints: prefer_const_declarations, withOpacity deprecations, etc.

import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';

class FindingNearbyMatchesPage extends StatefulWidget {
  const FindingNearbyMatchesPage({
    super.key,
    this.profileImageUrl,
    this.backgroundAsset,
    this.message = 'Finding people near you ...',
  });

  /// Optional network URL for the center avatar.
  final String? profileImageUrl;

  /// Optional background asset path; if null, defaults to the Earth image.
  final String? backgroundAsset;

  /// Status message under the animation.
  final String message;

  static const String routeName = 'findingNearbyMatches';
  static const String routePath = '/findingNearbyMatches';

  @override
  State<FindingNearbyMatchesPage> createState() => _FindingNearbyMatchesPageState();
}

class _FindingNearbyMatchesPageState extends State<FindingNearbyMatchesPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Use provided asset, otherwise default to your Earth image
    final String bg = widget.backgroundAsset ??
        'assets/images/Earth Picture.png';

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Background (asset or gradient fallback)
          _SafeImageBackground(asset: bg),

          // VERY DARK haze: strong blur + dark layer + subtle brand tint
          const _HazeOverlay(
            blurSigma: 0.5,          // strong blur so the earth is soft
            darkenOpacity: 0.5,    // very dark (earth barely visible)
            brandTintOpacity: 0.18, // tiny purple hint to match brand
          ),

          // Content
          SafeArea(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Radar pulse with centered avatar
                  const SizedBox(
                    width: 300,
                    height: 300,
                    child: _RadarWithAvatar(),
                  ),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      widget.message,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        letterSpacing: .2,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Combines the animated radar + center avatar.
/// (Split so we can keep most widgets const.)
class _RadarWithAvatar extends StatefulWidget {
  const _RadarWithAvatar();

  @override
  State<_RadarWithAvatar> createState() => _RadarWithAvatarState();
}

class _RadarWithAvatarState extends State<_RadarWithAvatar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Pull the profile URL from closest FindingNearbyMatchesPage above in the tree if needed.
    final parent = context.findAncestorWidgetOfExactType<FindingNearbyMatchesPage>();

    return Stack(
      alignment: Alignment.center,
      children: [
        _RadarPulse(controller: _ctrl),
        _ProfileCircle(imageUrl: parent?.profileImageUrl),
      ],
    );
  }
}

/// Very dark, brand-tinted haze with heavy blur.
/// Uses withValues() (non-deprecated) and no external packages.
class _HazeOverlay extends StatelessWidget {
  const _HazeOverlay({
    required this.blurSigma,
    required this.darkenOpacity,
    required this.brandTintOpacity,
  });

  final double blurSigma;
  final double darkenOpacity;     // 0..1
  final double brandTintOpacity;  // 0..1

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Blur the background behind
        ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
            child: const SizedBox.shrink(),
          ),
        ),
        // Heavy darkening
        Container(color: Colors.black.withValues(alpha: darkenOpacity)),
        // Subtle brand tint on top
        Container(color: const Color(0xFF880EE7).withValues(alpha: brandTintOpacity)),
      ],
    );
  }
}

/// Animated radar-style expanding circles with soft blur.
class _RadarPulse extends StatelessWidget {
  const _RadarPulse({required this.controller});
  final Animation<double> controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        // t goes 0→1 repeatedly
        final t = Curves.easeOut.transform(controller.value);
        return Stack(
          alignment: Alignment.center,
          children: [
            for (int i = 0; i < 3; i++)
              _PulseCircle(
                // phase each ring so they don't overlap exactly
                progress: ((t + i / 3) % 1.0),
              ),
          ],
        );
      },
    );
  }
}

class _PulseCircle extends StatelessWidget {
  const _PulseCircle({required this.progress});
  final double progress; // 0..1

  @override
  Widget build(BuildContext context) {
    const double maxRadius = 130; // relative to parent 300x300

    // Ease-out radius growth and fade
    final double radius = Tween<double>(begin: 10, end: maxRadius).transform(progress);
    final double fade = (1.0 - progress).clamp(0.0, 1.0);

    return IgnorePointer(
      child: CustomPaint(
        painter: _RingPainter(
          radius: radius,
          color: Colors.white.withValues(alpha: fade * 0.25), // <- withValues
          blurSigma: 12,
          strokeWidth: 2,
        ),
        size: const Size.square(300),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.radius,
    required this.color,
    required this.blurSigma,
    required this.strokeWidth,
  });

  final double radius;
  final Color color;
  final double blurSigma;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = Offset(size.width / 2, size.height / 2);

    // Soft glow ring
    final Paint glow = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, blurSigma);

    // Crisp ring on top (preserve current alpha via .a)
    final Paint ring = Paint()
      ..color = color.withValues(alpha: color.a * 0.90)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;

    canvas.drawCircle(center, radius, glow);
    canvas.drawCircle(center, math.max(0, radius - 0.5), ring);
  }

  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) {
    return oldDelegate.radius != radius ||
        oldDelegate.color != color ||
        oldDelegate.blurSigma != blurSigma ||
        oldDelegate.strokeWidth != strokeWidth;
  }
}

class _ProfileCircle extends StatelessWidget {
  const _ProfileCircle({required this.imageUrl});
  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    const double size = 90; // const fixes "prefer_const_declarations"
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFF1F2127),
        border: Border.all(color: Colors.white.withValues(alpha: .8), width: 2),
        boxShadow: const [
          BoxShadow(blurRadius: 16, color: Colors.black54, offset: Offset(0, 6)),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: imageUrl == null || imageUrl!.isEmpty
          ? const _AvatarPlaceholder()
          : Image.network(
              imageUrl!,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const _AvatarPlaceholder(),
            ),
    );
  }
}

class _AvatarPlaceholder extends StatelessWidget {
  const _AvatarPlaceholder();
  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Color(0xFF1F2127),
      child: Center(
        child: Icon(Icons.person, size: 36, color: Colors.white70),
      ),
    );
  }
}

class _SafeImageBackground extends StatelessWidget {
  const _SafeImageBackground({required this.asset});
  final String asset;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      asset,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => const _GradientFallback(),
    );
  }
}

class _GradientFallback extends StatelessWidget {
  const _GradientFallback();
  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0E0F12), Color(0xFF171922)],
        ),
      ),
    );
  }
}
