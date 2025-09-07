// FILE: lib/features/onboarding/onboarding_page.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../auth/login_page_widget.dart'; // ⬅️ use the new login page

class OnboardingPage extends StatelessWidget {
  static const routePath = '/';
  static const routeName = 'onboarding';
  const OnboardingPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Spacer(),
              Text('Bangher', style: t.displayMedium),
              const SizedBox(height: 12),
              Text('Meet remarkable people. Elegantly.', style: t.titleMedium),
              const Spacer(),
              FilledButton.tonal(
                // ⬇️ route to the new Login page
                onPressed: () => context.goNamed(LoginPageWidget.routeName),
                // (or: context.go(LoginPageWidget.routePath))
                child: const Text('Get started'),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}
