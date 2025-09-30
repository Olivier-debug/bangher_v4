// FILE: lib/ui/shimmer.dart
// Public shimmer utilities (extracted). No behavior change.

import 'package:flutter/material.dart';

class Shimmer extends StatefulWidget {
  const Shimmer({super.key, required this.child});
  final Widget child;

  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))
        ..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const Color base = Color(0xFF2A2C31);
    const Color highlight = Color(0xFF3A3D44);

    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) {
        final t = _ctrl.value;
        return ShaderMask(
          shaderCallback: (rect) {
            final dx = rect.width;
            final double x = (2 * dx) * t - dx;
            return const LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [base, highlight, base],
              stops: [0.35, 0.50, 0.65],
            ).createShader(Rect.fromLTWH(x, 0, dx, rect.height));
          },
          blendMode: BlendMode.srcATop,
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

class ShimmerLine extends StatelessWidget {
  const ShimmerLine({super.key, required this.height, this.widthFactor});
  final double height;
  final double? widthFactor;

  @override
  Widget build(BuildContext context) {
    Widget box = ShimmerBox(height: height, radius: 6);
    if (widthFactor != null) {
      box = FractionallySizedBox(widthFactor: widthFactor, child: box);
    }
    return box;
  }
}

class ShimmerBox extends StatelessWidget {
  const ShimmerBox({super.key, this.height, this.radius = 8});
  final double? height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Shimmer(
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: const Color(0xFF2A2C31),
          borderRadius: BorderRadius.circular(radius),
        ),
      ),
    );
  }
}
