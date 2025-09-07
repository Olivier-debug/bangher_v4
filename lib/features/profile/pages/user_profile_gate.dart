// FILE: lib/features/profile/pages/user_profile_gate.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../theme/app_theme.dart';
import '../profile_repository.dart';          // exports myProfileProvider + UserProfile model
import 'user_profile_page.dart';
import 'create_or_complete_profile_page.dart';

class UserProfileGate extends ConsumerWidget {
  const UserProfileGate({super.key});

  static const String routeName = UserProfilePage.routeName;
  static const String routePath = UserProfilePage.routePath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncProfile = ref.watch(myProfileProvider);

    int calcAge(DateTime dob) {
      final now = DateTime.now();
      var years = now.year - dob.year;
      final hadBirthday =
          (now.month > dob.month) || (now.month == dob.month && now.day >= dob.day);
      if (!hadBirthday) years -= 1;
      return years;
    }

    bool isComplete(UserProfile p) {
      final hasName = (p.name ?? '').trim().isNotEmpty;
      final hasPhoto = (p.profilePictures).isNotEmpty;
      // prefer explicit age if present; otherwise derive from dob if available
      final int? age = p.age ?? (p.dateOfBirth != null ? calcAge(p.dateOfBirth!) : null);
      final isAdult = (age ?? 0) >= 18;
      return hasName && hasPhoto && isAdult;
    }

    return asyncProfile.when(
      loading: () => const Scaffold(
        backgroundColor: AppTheme.ffSecondaryBg,
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        backgroundColor: AppTheme.ffSecondaryBg,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Failed to load profile\n$e',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
          ),
        ),
      ),
      data: (p) {
        final complete = (p != null) && isComplete(p);

        if (!complete) {
          // Defer navigation out of build to avoid setState during build
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) {
              context.go(CreateOrCompleteProfilePage.routePath);
            }
          });
          return const Scaffold(
            backgroundColor: AppTheme.ffSecondaryBg,
            body: Center(child: CircularProgressIndicator()),
          );
        }

        // Profile is complete: show the page.
        return const UserProfilePage();
      },
    );
  }
}
