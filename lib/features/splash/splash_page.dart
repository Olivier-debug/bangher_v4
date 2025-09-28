import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../onboarding/onboarding_page.dart';

class SplashPage extends StatefulWidget {
  const SplashPage({super.key});

  static const String routeName = 'Splash';
  static const String routePath = '/splash';

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // Hold the splash for exactly 3 seconds.
    _timer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      // Continue to your app's existing entry point.
      // Your redirect() will handle auth (send to Login if needed).
      context.go(OnboardingPage.routePath);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Image(
          image: AssetImage('assets/images/Untitled_design_(10).gif'),
          fit: BoxFit.contain, // centered, no scaling beyond natural size
        ),
      ),
    );
  }
}