import 'package:flutter/material.dart';
import '../../../theme/app_theme.dart';

class GateScaffold extends StatelessWidget {
  const GateScaffold({
    super.key,
    required this.title,
    this.subtitle,
    required this.child,
  });

  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.ffSecondaryBg,
      appBar: AppBar(
        backgroundColor: AppTheme.ffPrimaryBg,
        title: const Text('Profile'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppTheme.ffPrimaryBg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.ffAlt),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        subtitle!,
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ],
                    const SizedBox(height: 14),
                    child,
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
