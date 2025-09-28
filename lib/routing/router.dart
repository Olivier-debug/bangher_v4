// FILE: lib/routing/router.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../features/splash/splash_page.dart';
import '../features/onboarding/onboarding_page.dart';
import '../features/auth/login_page_widget.dart';
import '../features/profile/pages/create_or_complete_profile_page.dart';
import '../features/profile/pages/edit_profile_page.dart';
import '../features/profile/pages/user_profile_page.dart';
import '../features/swipe/pages/swipe_stack_page.dart';
import '../features/matches/chat_list_page.dart';
import '../features/matches/chat_page.dart';
import '../features/paywall/paywall_page.dart';
import '../features/settings/settings_page.dart';
import '../filters/filter_matches_sheet.dart';
import '../theme/app_theme.dart';
import '../widgets/app_bottom_nav.dart';
import '../features/profile/profile_guard.dart';

// Confessions UI
import '../features/confessions/ui/confessions_feed_page.dart';
import '../features/confessions/ui/confession_detail_page.dart';
import '../features/confessions/ui/composer_sheet.dart';

final GlobalKey<NavigatorState> _rootNavigatorKey = GlobalKey<NavigatorState>();

const String _kFreshParam = 'fresh';
const String _kFreshValue = '1';
const String _kIdParam = 'id';

// Confessions query/segments
const String _kConfessionIdParam = 'cid';
const String _kConfDetailSegment = 'detail';
const String _kConfComposeSegment = 'compose';

final Provider<GoRouter> routerProvider = Provider<GoRouter>((ref) {
  final auth = Supabase.instance.client.auth;
  final profileGateListenable = ref.read(profileStatusListenableProvider);

  FutureOr<String?> redirect(BuildContext _, GoRouterState state) async {
    final here = state.matchedLocation;
    final atSplash = here == SplashPage.routePath;
    final atLogin = here == LoginPageWidget.routePath;
    final atOnboarding = here == OnboardingPage.routePath;
    final atCreateComplete = here == CreateOrCompleteProfilePage.routePath;

    if (atSplash) return null;

    final session = auth.currentSession;

    if (session == null) {
      if (atLogin || atOnboarding || atSplash) return null;
      return LoginPageWidget.routePath;
    }

    if (atCreateComplete) return null;

    if (atLogin) {
      final st = profileGateListenable.value;
      if (st == ProfileStatus.complete) return TestSwipeStackPage.routePath;
      if (st == ProfileStatus.incomplete) {
        return CreateOrCompleteProfilePage.routePath;
      }
      return null;
    }

    final st = profileGateListenable.value;
    if (st == ProfileStatus.incomplete) {
      return CreateOrCompleteProfilePage.routePath;
    }
    return null;
  }

  return GoRouter(
    debugLogDiagnostics: kDebugMode,
    navigatorKey: _rootNavigatorKey,
    refreshListenable: profileGateListenable,
    redirect: redirect,
    redirectLimit: 2,
    initialLocation: SplashPage.routePath,
    routes: <RouteBase>[
      // ───────── Boot / Auth ─────────
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

      // ───────── Standalone (no bottom nav) ─────────
      GoRoute(
        path: CreateOrCompleteProfilePage.routePath,
        name: CreateOrCompleteProfilePage.routeName,
        parentNavigatorKey: _rootNavigatorKey,
        builder: (ctx, state) => CreateOrCompleteProfilePage(
          fresh: state.uri.queryParameters[_kFreshParam] == _kFreshValue,
        ),
      ),
      GoRoute(
        path: EditProfilePage.routePath,
        name: EditProfilePage.routeName,
        parentNavigatorKey: _rootNavigatorKey,
        builder: (_, __) => const EditProfilePage(),
      ),
      GoRoute(
        path: SettingsPage.routePath,
        name: SettingsPage.routeName,
        parentNavigatorKey: _rootNavigatorKey,
        builder: (_, __) => const SettingsPage(),
      ),
      GoRoute(
        path: PaywallPage.routePath,
        name: PaywallPage.routeName,
        parentNavigatorKey: _rootNavigatorKey,
        builder: (_, __) => const PaywallPage(),
      ),

      // ───────── Tabs (bottom nav) ─────────
      GoRoute(
        path: TestSwipeStackPage.routePath,
        name: TestSwipeStackPage.routeName,
        pageBuilder: (context, state) => NoTransitionPage(
          child: _AppScaffold(
            body: const TestSwipeStackPage(),
            currentLocation: state.matchedLocation,
            showHeader: true,
            headerVariant: _HeaderVariant.swipe,
          ),
        ),
      ),
      GoRoute(
        name: ConfessionsFeedPage.routeName,
        path: ConfessionsFeedPage.routePath,
        pageBuilder: (context, state) => NoTransitionPage(
          child: _AppScaffold(
            body: const ConfessionsFeedPage(),
            currentLocation: state.matchedLocation,
            showHeader: false,
          ),
        ),
        routes: [
          // /confess/detail?cid=123
          GoRoute(
            path: _kConfDetailSegment,
            name: ConfessionDetailPage.routeName,
            parentNavigatorKey: _rootNavigatorKey, // push over tab scaffold
            builder: (context, state) {
              // Detail page expects a String id → pass as String
              final cid = state.uri.queryParameters[_kConfessionIdParam] ?? '';
              return ConfessionDetailPage(confessionId: cid);
            },
          ),
          // /confess/compose (fullscreen page/sheet)
          GoRoute(
            path: _kConfComposeSegment,
            name: 'confession_compose',
            parentNavigatorKey: _rootNavigatorKey,
            pageBuilder: (context, state) => CustomTransitionPage(
              key: state.pageKey,
              fullscreenDialog: true,
              transitionsBuilder: (context, animation, secondaryAnimation, child) {
                return SlideTransition(
                  position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
                      .chain(CurveTween(curve: Curves.easeOutCubic))
                      .animate(animation),
                  child: child,
                );
              },
              child: const ComposerSheet(),
            ),
          ),
        ],
      ),
      GoRoute(
        path: ChatListPage.routePath,
        name: ChatListPage.routeName,
        pageBuilder: (context, state) => NoTransitionPage(
          child: _AppScaffold(
            body: const ChatListPage(),
            currentLocation: state.matchedLocation,
            showHeader: false,
          ),
        ),
      ),
      GoRoute(
        path: UserProfilePage.routePath,
        name: UserProfilePage.routeName,
        pageBuilder: (context, state) => NoTransitionPage(
          child: _AppScaffold(
            body: const UserProfilePage(),
            currentLocation: state.matchedLocation,
            showHeader: true,
            headerVariant: _HeaderVariant.profile,
          ),
        ),
      ),

      // ───────── Chat detail (normal push) ─────────
      GoRoute(
        path: ChatPage.routePath,
        name: ChatPage.routeName,
        builder: (context, state) {
          final idStr = state.uri.queryParameters[_kIdParam];
          final matchId = int.tryParse(idStr ?? '') ?? 0;
          return _AppScaffold(
            body: ChatPage(matchId: matchId),
            currentLocation: state.matchedLocation,
            showHeader: false,
          );
        },
      ),
    ],
  );
});

enum _HeaderVariant { swipe, profile }

const double _kHeaderHeight = 80;
const double _kHeaderIconSize = 25;
const double _kHeaderTapTarget = 56;

const double _kLogoWidth = 150;
const double _kLogoHeight = 75;
const double _kHeaderLeadingWidth = 174;

const BoxConstraints _kHeaderBtnConstraints = BoxConstraints(
  minWidth: _kHeaderTapTarget,
  minHeight: _kHeaderTapTarget,
);

final ButtonStyle _kUpgradeBtnStyle = ElevatedButton.styleFrom(
  backgroundColor: AppTheme.ffPrimary,
  elevation: 0,
  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
  shape: const StadiumBorder(),
);

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

  static DateTime? _lastBack;

  @override
  Widget build(BuildContext context) {
    final router = GoRouter.of(context);

    return PopScope(
      canPop: router.canPop(),
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;

        if (router.canPop()) {
          router.pop();
          return;
        }

        final onHomeTab = currentLocation.startsWith(TestSwipeStackPage.routePath);
        if (!onHomeTab) {
          if (context.mounted) context.go(TestSwipeStackPage.routePath);
          return;
        }

        final platform = Theme.of(context).platform;
        if (platform == TargetPlatform.android) {
          final now = DateTime.now();
          if (_lastBack == null || now.difference(_lastBack!) > const Duration(seconds: 2)) {
            _lastBack = now;
            if (context.mounted) {
              ScaffoldMessenger.of(context)
                ..hideCurrentSnackBar()
                ..showSnackBar(
                  const SnackBar(
                    content: Text('Press back again to exit'),
                    duration: Duration(seconds: 2),
                  ),
                );
            }
            return;
          }
          await SystemNavigator.pop();
        }
      },
      child: Scaffold(
        appBar: showHeader ? _buildHeader(context, headerVariant) : null,
        body: SafeArea(child: body),
        bottomNavigationBar: AppBottomNav(
          currentPath: currentLocation,
          // NOTE: this list is intentionally NOT const (contains runtime strings).
          items: [
            const NavItem(
              icon: Icons.explore_rounded,
              label: 'Discover',
              path: TestSwipeStackPage.routePath,
              selectedStartsWith: [TestSwipeStackPage.routePath],
            ),
            NavItem(
              icon: Icons.auto_awesome,
              label: 'Confess',
              path: ConfessionsFeedPage.routePath,
              selectedStartsWith: [
                ConfessionsFeedPage.routePath,
                '${ConfessionsFeedPage.routePath}/$_kConfDetailSegment',
                '${ConfessionsFeedPage.routePath}/$_kConfComposeSegment',
              ],
            ),
            const NavItem(
              icon: Icons.chat_bubble_outline,
              label: 'Chats',
              path: ChatListPage.routePath,
              selectedStartsWith: [ChatListPage.routePath, ChatPage.routePath],
            ),
            const NavItem(
              icon: Icons.person_outline,
              label: 'Profile',
              path: UserProfilePage.routePath,
              selectedStartsWith: [
                UserProfilePage.routePath,
                CreateOrCompleteProfilePage.routePath,
                EditProfilePage.routePath,
                SettingsPage.routePath,
              ],
            ),
          ],
        ),
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
          actions: <Widget>[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: ElevatedButton.icon(
                onPressed: () => context.push(PaywallPage.routePath),
                icon: const Icon(Icons.star_rounded, size: 16, color: Colors.white),
                label: const Text(
                  'UPGRADE',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                ),
                style: _kUpgradeBtnStyle,
              ),
            ),
            IconButton(
              tooltip: 'Settings',
              icon: const Icon(Icons.settings, color: Colors.white),
              onPressed: () => context.push(SettingsPage.routePath),
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
          actions: <Widget>[
            const _HeaderBell(count: 3, iconSize: _kHeaderIconSize),
            const SizedBox(width: 4),
            IconButton(
              tooltip: 'Filters',
              iconSize: _kHeaderIconSize,
              constraints: _kHeaderBtnConstraints,
              splashRadius: _kHeaderTapTarget / 2,
              icon: const Icon(Icons.filter_list),
              onPressed: () {
                showModalBottomSheet<void>(
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

  int _cacheWidthForDpr(BuildContext context) {
    final dpr = MediaQuery.of(context).devicePixelRatio;
    return (dpr * _kLogoWidth).ceil();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _kLogoWidth,
      height: _kLogoHeight,
      child: Image.asset(
        'assets/images/Bangher_Logo.png',
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
        cacheWidth: _cacheWidthForDpr(context),
        excludeFromSemantics: true,
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
    final label = count > 99 ? '99+' : '$count';
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        IconButton(
          iconSize: iconSize,
          splashRadius: _kHeaderTapTarget / 2,
          constraints: _kHeaderBtnConstraints,
          icon: const Icon(Icons.notifications_none),
          onPressed: () {},
        ),
        if (count > 0)
          Positioned(
            right: 8,
            top: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: const BoxDecoration(
                color: Colors.redAccent,
                borderRadius: BorderRadius.all(Radius.circular(10)),
              ),
              child: Text(
                label,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
              ),
            ),
          ),
      ],
    );
  }
}
