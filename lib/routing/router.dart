// ─────────────────────────────────────────────────────────────────────────────
// FILE: lib/routing/router.dart
// Purpose: Centralize routing; safe redirects; 4-tab bottom nav shell.
// Header behavior:
//  - UserProfilePage: brand logo + UPGRADE button + Settings icon
//  - TestSwipeStackPage: brand logo + bell + filter
//  - Others: no header
//
// NOTE: Requires assets:
//   assets/images/Bangher_Logo.png
//   assets/images/nswz3_9.png
// And AppTheme for the pink brand color.

import 'dart:async';

import 'package:bangher/features/confessions/confessions_feature.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../features/splash/splash_page.dart';
import '../features/onboarding/onboarding_page.dart';
import '../features/auth/login_page_widget.dart';
import '../features/profile/pages/create_or_complete_profile_page.dart';
import '../features/profile/pages/edit_profile_page.dart';
import '../features/profile/pages/user_profile_page.dart';
import '../features/swipe/pages/test_swipe_stack_page.dart';
import '../features/matches/chat_list_page.dart';
import '../features/matches/chat_page.dart';
import '../features/paywall/paywall_page.dart';
import '../features/settings/settings_page.dart';
import '../filters/filter_matches_sheet.dart';
import '../theme/app_theme.dart'; // ← for AppTheme.ffPrimary (pink)
// import 'go_router_refresh.dart'; // ← no longer needed

// Reusable 4-tab nav
import '../widgets/app_bottom_nav.dart';

/// Only notify GoRouter on signedIn / signedOut (ignore tokenRefreshed etc.)
class _FilteredAuthRefresh extends ChangeNotifier {
  late final StreamSubscription<AuthState> _sub;
  _FilteredAuthRefresh(Stream<AuthState> stream) {
    _sub = stream.listen((s) {
      final e = s.event;
      if (e == AuthChangeEvent.signedIn || e == AuthChangeEvent.signedOut) {
        notifyListeners();
      }
    });
  }
  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  final auth = Supabase.instance.client.auth;

  // Only refresh router on true auth boundary changes (sign in/out)
  final refresh = _FilteredAuthRefresh(auth.onAuthStateChange);
  ref.onDispose(refresh.dispose);

  // Make redirect async so we can quickly check `profiles` existence + `complete`
  FutureOr<String?> redirect(BuildContext _, GoRouterState state) async {
    final session = auth.currentSession;

    // Where are we now?
    final here = state.matchedLocation; // prefer matchedLocation on newer go_router
    final atSplash = here == SplashPage.routePath;
    final atLogin = here == LoginPageWidget.routePath;
    final atOnboarding = here == OnboardingPage.routePath;
    final atProfile = here == CreateOrCompleteProfilePage.routePath;

    // Fresh intent (brand-new signup / OAuth create)
    final freshParam = state.uri.queryParameters['fresh'] == '1';

    // Allow splash always.
    if (atSplash) return null;

    // Helper: profile existence + completion in one roundtrip
    Future<Map<String, bool>> profileStatus() async {
      try {
        final uid = auth.currentUser?.id;
        if (uid == null) {
          return {'exists': false, 'complete': false};
        }
        final row = await Supabase.instance.client
            .from('profiles')
            .select('complete')
            .eq('user_id', uid)
            .maybeSingle();

        if (row == null) {
          // no profiles row yet → brand-new user
          return {'exists': false, 'complete': false};
        }
        final complete = (row['complete'] as bool?) ?? false;
        return {'exists': true, 'complete': complete};
      } catch (_) {
        // On errors, assume the row exists but is not complete (safer than forcing fresh).
        return {'exists': true, 'complete': false};
      }
    }

    // Not authenticated → allow splash/onboarding/login, otherwise go to login.
    if (session == null) {
      if (atLogin || atSplash || atOnboarding) return null;
      return LoginPageWidget.routePath;
    }

    // Authenticated and on login → decide where to go.
    if (atLogin) {
      if (freshParam) {
        return '${CreateOrCompleteProfilePage.routePath}?fresh=1';
      }
      final status = await profileStatus();
      if (!status['exists']!) {
        // brand-new user, no profiles row yet → fresh flow
        return '${CreateOrCompleteProfilePage.routePath}?fresh=1';
      }
      return status['complete']!
          ? TestSwipeStackPage.routePath
          : CreateOrCompleteProfilePage.routePath;
    }

    // Don’t loop while already on the create/complete page
    if (atProfile) return null;

    // If this navigation is marked fresh (e.g., OAuth returned with ?fresh=1),
    // send them straight into the create flow.
    if (freshParam) {
      return '${CreateOrCompleteProfilePage.routePath}?fresh=1';
    }

    // Gate all other locations if profile is not complete
    final status = await profileStatus();
    if (!status['complete']!) {
      return status['exists']!
          ? CreateOrCompleteProfilePage.routePath
          : '${CreateOrCompleteProfilePage.routePath}?fresh=1';
    }

    // All good, proceed.
    return null;
  }

  return GoRouter(
    debugLogDiagnostics: kDebugMode,
    refreshListenable: refresh,      // filtered (no spam on token refresh)
    redirect: redirect,
    redirectLimit: 2,                // avoids long redirect chains in dev
    initialLocation: SplashPage.routePath,
    routes: [
      GoRoute(
        path: SplashPage.routePath,
        name: SplashPage.routeName,
        builder: (_, __) => const SplashPage(),
      ),
      GoRoute(
        path: OnboardingPage.routePath,
        name: OnboardingPage.routeName,
        builder: (_, __) => const OnboardingPage(),
      ),
      GoRoute(
        path: LoginPageWidget.routePath,
        name: LoginPageWidget.routeName,
        builder: (_, __) => const LoginPageWidget(),
      ),

      // Create/Complete Profile:
      // Accept "fresh" from query (?fresh=1).
      GoRoute(
        name: CreateOrCompleteProfilePage.routeName,
        path: CreateOrCompleteProfilePage.routePath,
        builder: (ctx, state) => CreateOrCompleteProfilePage(
          fresh: state.uri.queryParameters['fresh'] == '1',
        ),
      ),

      GoRoute(
        path: EditProfilePage.routePath,
        name: EditProfilePage.routeName,
        builder: (_, __) => const EditProfilePage(),
      ),

      // Confessions: bottom nav (no header)
      GoRoute(
        name: ConfessionsFeedPage.routeName,
        path: ConfessionsFeedPage.routePath,
        builder: (context, state) => _AppScaffold(
          body: const ConfessionsFeedPage(),
          currentLocation: state.matchedLocation,
          showHeader: false,
        ),
      ),

      // Profile: bottom nav + header (logo + upgrade + settings)
      GoRoute(
        path: UserProfilePage.routePath,
        name: UserProfilePage.routeName,
        builder: (context, state) => _AppScaffold(
          body: const UserProfilePage(),
          currentLocation: state.matchedLocation,
          showHeader: true,
          headerVariant: _HeaderVariant.profile,
        ),
      ),

      // Swipe: bottom nav + header (brand logo + bell + filter)
      GoRoute(
        path: TestSwipeStackPage.routePath,
        name: TestSwipeStackPage.routeName,
        builder: (context, state) => _AppScaffold(
          body: const TestSwipeStackPage(),
          currentLocation: state.matchedLocation,
          showHeader: true,
          headerVariant: _HeaderVariant.swipe,
        ),
      ),

      // Chats list: bottom nav (no header)
      GoRoute(
        path: ChatListPage.routePath,
        name: ChatListPage.routeName,
        builder: (context, state) => _AppScaffold(
          body: const ChatListPage(),
          currentLocation: state.matchedLocation,
          showHeader: false,
        ),
      ),

      // Settings (standalone page)
      GoRoute(
        path: SettingsPage.routePath,
        name: SettingsPage.routeName,
        builder: (_, __) => const SettingsPage(),
      ),

      // Chat thread: bottom nav (no header)
      GoRoute(
        path: ChatPage.routePath,
        name: ChatPage.routeName,
        builder: (context, state) {
          final idStr = state.uri.queryParameters['id'];
          final matchId = int.tryParse(idStr ?? '') ?? 0;
          return _AppScaffold(
            body: ChatPage(matchId: matchId),
            currentLocation: state.matchedLocation,
            showHeader: false,
          );
        },
      ),

      GoRoute(
        path: PaywallPage.routePath,
        name: PaywallPage.routeName,
        builder: (_, __) => const PaywallPage(),
      ),
    ],
  );
});

/// Which header layout to show when [showHeader] is true.
enum _HeaderVariant { swipe, profile }

/// ─────────────────────────────────────────────────────────────────────────────
/// Header sizing constants (single source of truth so logos are identical)
const double _kHeaderHeight = 80;
const double _kHeaderIconSize = 25;
const double _kHeaderTapTarget = 56;

// Logo sizing – used everywhere the logo appears in the AppBar
const double _kLogoWidth = 150;
const double _kLogoHeight = 75;
// Leading width so the logo doesn’t get cramped (logo width + padding)
const double _kHeaderLeadingWidth = 174;

/// ─────────────────────────────────────────────────────────────────────────────
/// Shared shell with optional header (AppBar) + 4-tab bottom nav.
class _AppScaffold extends StatelessWidget {
  const _AppScaffold({
    required this.body,
    required this.currentLocation,
    this.showHeader = false,
    this.headerVariant = _HeaderVariant.swipe,
  });

  final Widget body;
  final String currentLocation;
  final bool showHeader;
  final _HeaderVariant headerVariant;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: showHeader ? _buildHeader(context, headerVariant) : null,
      body: SafeArea(child: body),
      bottomNavigationBar: AppBottomNav(
        currentPath: currentLocation,
        items: const [
          NavItem(
            icon: Icons.explore_rounded,
            label: 'Discover',
            path: TestSwipeStackPage.routePath,
            selectedStartsWith: [TestSwipeStackPage.routePath],
          ),
          NavItem(
            icon: Icons.auto_awesome,
            label: 'Confess',
            path: ConfessionsFeedPage.routePath,
            selectedStartsWith: [ConfessionsFeedPage.routePath],
          ),
          NavItem(
            icon: Icons.chat_bubble_outline,
            label: 'Chats',
            path: ChatListPage.routePath,
            selectedStartsWith: [ChatListPage.routePath, ChatPage.routePath],
          ),
          NavItem(
            icon: Icons.person_outline,
            label: 'Profile',
            path: UserProfilePage.routePath,
            selectedStartsWith: [
              UserProfilePage.routePath,
              CreateOrCompleteProfilePage.routePath,
              EditProfilePage.routePath,
              SettingsPage.routePath, // keep Profile tab “selected” if you decide to show bottom nav on Settings
            ],
          ),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildHeader(BuildContext context, _HeaderVariant variant) {
    switch (variant) {
      case _HeaderVariant.profile:
        return AppBar(
          toolbarHeight: _kHeaderHeight,
          centerTitle: false,
          titleSpacing: 12,
          title: const _BrandLogo(),
          actions: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: ElevatedButton.icon(
                onPressed: () => context.push(PaywallPage.routePath),
                icon: const Icon(Icons.star_rounded, size: 16, color: Colors.white),
                label: const Text(
                  'UPGRADE',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.ffPrimary,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  shape: const StadiumBorder(),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Settings',
              icon: const Icon(Icons.settings, color: Colors.white),
              onPressed: () => context.push(SettingsPage.routePath), // ← wired to Settings page
              iconSize: _kHeaderIconSize,
              splashRadius: _kHeaderTapTarget / 2,
            ),
            const SizedBox(width: 8),
          ],
        );

      case _HeaderVariant.swipe:
        return AppBar(
          toolbarHeight: _kHeaderHeight,
          leadingWidth: _kHeaderLeadingWidth,
          leading: const Padding(
            padding: EdgeInsets.only(left: 12, top: 2),
            child: _BrandLogo(),
          ),
          actions: [
            _HeaderBell(count: 3, iconSize: _kHeaderIconSize),
            const SizedBox(width: 4),
            IconButton(
              tooltip: 'Filters',
              iconSize: _kHeaderIconSize,
              constraints: const BoxConstraints(
                minWidth: _kHeaderTapTarget,
                minHeight: _kHeaderTapTarget,
              ),
              splashRadius: _kHeaderTapTarget / 2,
              icon: const Icon(Icons.filter_list),
              onPressed: () {
                showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  useSafeArea: true,
                  backgroundColor: Colors.transparent,
                  builder: (ctx) => const FilterMatchesSheet(),
                );
              },
            ),
            const SizedBox(width: 8),
          ],
        );
    }
  }
}

class _BrandLogo extends StatelessWidget {
  const _BrandLogo();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _kLogoWidth,
      height: _kLogoHeight,
      child: Image.asset(
        'assets/images/Bangher_Logo.png',
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
      ),
    );
  }
}

class _HeaderBell extends StatelessWidget {
  const _HeaderBell({
    required this.count,
    this.iconSize = _kHeaderIconSize,
  });

  final int count;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        IconButton(
          iconSize: iconSize,
          splashRadius: _kHeaderTapTarget / 2,
          constraints: const BoxConstraints(
            minWidth: _kHeaderTapTarget,
            minHeight: _kHeaderTapTarget,
          ),
          icon: const Icon(Icons.notifications_none),
          onPressed: () {},
        ),
        if (count > 0)
          Positioned(
            right: 8,
            top: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.redAccent,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                count > 99 ? '99+' : '$count',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
              ),
            ),
          ),
      ],
    );
  }
}
