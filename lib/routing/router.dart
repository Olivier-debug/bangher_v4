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
import '../filters/filter_matches_sheet.dart';
import '../theme/app_theme.dart'; // ← for AppTheme.ffPrimary (pink)
import 'go_router_refresh.dart';

// Reusable 4-tab nav
import '../widgets/app_bottom_nav.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final auth = Supabase.instance.client.auth;

  final refresh = GoRouterRefreshStream(auth.onAuthStateChange);
  ref.onDispose(refresh.dispose);

  String? redirect(_, GoRouterState state) {
    final session = auth.currentSession;
    final atLogin = state.matchedLocation == LoginPageWidget.routePath;
    final atSplash = state.matchedLocation == SplashPage.routePath;

    if (atSplash) return null;
    if (session == null) return atLogin ? null : LoginPageWidget.routePath;
    if (atLogin) return CreateOrCompleteProfilePage.routePath;
    return null;
  }

  return GoRouter(
    debugLogDiagnostics: kDebugMode,
    refreshListenable: refresh,
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
      GoRoute(
        path: CreateOrCompleteProfilePage.routePath,
        name: CreateOrCompleteProfilePage.routeName,
        builder: (_, __) => const CreateOrCompleteProfilePage(),
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
    redirect: redirect,
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
                label: const Text('UPGRADE',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
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
              onPressed: () => context.push(EditProfilePage.routePath),
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
