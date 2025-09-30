import 'package:flutter/material.dart';

class GridShimmer extends StatelessWidget {
  const GridShimmer({super.key});
  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF202227),
      child: const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 1.8),
        ),
      ),
    );
  }
}
