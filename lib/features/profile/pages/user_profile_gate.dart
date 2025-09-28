import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Very small redirector used after save.
/// You can also just call context.go('/userProfile') directly.
class UserProfileGate extends StatelessWidget {
  const UserProfileGate({super.key});

  static const String routePath = '/userProfile';

  @override
  Widget build(BuildContext context) {
    // Push replacement so back button returns to previous screen.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      context.go(routePath);
    });
    return const Scaffold(
      backgroundColor: Colors.black,
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
