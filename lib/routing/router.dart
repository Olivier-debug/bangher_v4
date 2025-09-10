// ─────────────────────────────────────────────────────────────────────────────
// FILE: lib/routing/router.dart (fresh, clean, validated)
// Purpose: Centralize routing; safe redirects; 4-tab bottom nav shell.
// Header behavior:
//  - UserProfilePage: brand logo + UPGRADE button + Settings icon
//  - TestSwipeStackPage: brand logo + bell + filter
//  - Others: no header
//
// External requirements:
//   assets/images/Bangher_Logo.png
//   assets/images/nswz3_9.png
//   AppTheme.ffPrimary (pink brand color)
// ─────────────────────────────────────────────────────────────────────────────

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
import '../theme/app_theme.dart';

// Reusable 4-tab nav
import '../widgets/app_bottom_nav.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Navigator key for top-level pages (e.g., Settings/Paywall shown above tabs)
final GlobalKey<NavigatorState> _rootNavigatorKey = GlobalKey<NavigatorState>();

// ─────────────────────────────────────────────────────────────────────────────
// Query param keys / values
const String _kFreshParam = 'fresh';
const String _kFreshValue = '1';
const String _kIdParam = 'id';

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

// ─────────────────────────────────────────────────────────────────────────────
// Small, short-lived cache to make tab switches & redirects feel instant.
const Duration _kProfileStatusTtl = Duration(seconds: 3);

class _ProfileStatusEntry {
  final bool exists;
  final bool complete;
  final DateTime at;
  const _ProfileStatusEntry({
    required this.exists,
    required this.complete,
    required this.at,
  });
}

class _ProfileStatus {
  final bool exists;
  final bool complete;
  const _ProfileStatus({required this.exists, required this.complete});
  static const none = _ProfileStatus(exists: false, complete: false);
}

final Map<String, _ProfileStatusEntry> _profileStatusCache = <String, _ProfileStatusEntry>{};
final Map<String, Future<_ProfileStatus>> _inflight = <String, Future<_ProfileStatus>>{};

/// Public helper so other pages can nudge the router cache.
void invalidateProfileStatusCache() {
  _profileStatusCache.clear();
  _inflight.clear();
}

Future<_ProfileStatus> _fetchProfileStatus(String uid) async {
  final now = DateTime.now();
  try {
    final row = await Supabase.instance.client
        .from('profiles')
        .select('complete')
        .eq('user_id', uid)
        .maybeSingle();

    if (row == null) {
      _profileStatusCache[uid] =
          _ProfileStatusEntry(exists: false, complete: false, at: now);
      return _ProfileStatus.none;
    }

    final complete = (row['complete'] as bool?) ?? false;
    _profileStatusCache[uid] =
        _ProfileStatusEntry(exists: true, complete: complete, at: now);
    return _ProfileStatus(exists: true, complete: complete);
  } catch (_) {
    _profileStatusCache[uid] =
        _ProfileStatusEntry(exists: true, complete: false, at: now);
    return const _ProfileStatus(exists: true, complete: false);
  }
}

void _prewarmProfileStatus(GoTrueClient auth) {
  final uid = auth.currentUser?.id;
  if (uid == null) return;
  final hit = _profileStatusCache[uid];
  final fresh = hit != null && DateTime.now().difference(hit.at) <= _kProfileStatusTtl;
  if (fresh) return;
  _inflight[uid] ??= _fetchProfileStatus(uid);
}

// ─────────────────────────────────────────────────────────────────────────────
// Router provider (fresh build)
final Provider<GoRouter> routerProvider = Provider<GoRouter>((ref) {
  final GoTrueClient auth = Supabase.instance.client.auth;

  // Only refresh router on true auth boundary changes (sign in/out)
  final refresh = _FilteredAuthRefresh(auth.onAuthStateChange);
  ref.onDispose(refresh.dispose);

  // Prewarm when we already have a session, and on sign-in/token refresh
  if (auth.currentSession != null) {
    _prewarmProfileStatus(auth);
  }
  final sub = auth.onAuthStateChange.listen((s) {
    final e = s.event;
    if (e == AuthChangeEvent.signedIn || e == AuthChangeEvent.tokenRefreshed) {
      _prewarmProfileStatus(auth);
    }
  });
  ref.onDispose(sub.cancel);

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
    final freshParam = state.uri.queryParameters[_kFreshParam] == _kFreshValue;

    // Allow splash always.
    if (atSplash) return null;

    // Helper: profile existence + completion with a tiny TTL cache + in-flight dedupe
    Future<_ProfileStatus> profileStatusCached() async {
      final uid = auth.currentUser?.id;
      if (uid == null) return _ProfileStatus.none;

      final now = DateTime.now();
      final hit = _profileStatusCache[uid];
      if (hit != null && now.difference(hit.at) <= _kProfileStatusTtl) {
        return _ProfileStatus(exists: hit.exists, complete: hit.complete);
      }

      final pending = _inflight[uid];
      if (pending != null) return pending;

      final future = _fetchProfileStatus(uid);
      _inflight[uid] = future;
      try {
        return await future;
      } finally {
        _inflight.remove(uid);
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
        return '${CreateOrCompleteProfilePage.routePath}?$_kFreshParam=$_kFreshValue';
      }
      final status = await profileStatusCached();
      if (!status.exists) {
        return '${CreateOrCompleteProfilePage.routePath}?$_kFreshParam=$_kFreshValue';
      }
      return status.complete
          ? TestSwipeStackPage.routePath
          : CreateOrCompleteProfilePage.routePath;
    }

    // Don’t loop while already on the create/complete page
    if (atProfile) return null;

    // If this navigation is marked fresh (e.g., OAuth returned with ?fresh=1),
    if (freshParam) {
      return '${CreateOrCompleteProfilePage.routePath}?$_kFreshParam=$_kFreshValue';
    }

    // Gate all other locations if profile is not complete
    final status = await profileStatusCached();
    if (!status.complete) {
      return status.exists
          ? CreateOrCompleteProfilePage.routePath
          : '${CreateOrCompleteProfilePage.routePath}?$_kFreshParam=$_kFreshValue';
    }

    // All good, proceed.
    return null;
  }

  return GoRouter(
    debugLogDiagnostics: kDebugMode,
    navigatorKey: _rootNavigatorKey,
    refreshListenable: refresh, // filtered (no spam on token refresh)
    redirect: redirect,
    redirectLimit: 2, // avoids long redirect chains in dev
    initialLocation: SplashPage.routePath,
    routes: <RouteBase>[
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

      // Standalone pages (no bottom nav)
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

      // Tabs (with bottom nav) — each wrapped in _AppScaffold
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
      GoRoute(
        name: ConfessionsFeedPage.routeName,
        path: ConfessionsFeedPage.routePath,
        builder: (context, state) => _AppScaffold(
          body: const ConfessionsFeedPage(),
          currentLocation: state.matchedLocation,
          showHeader: false,
        ),
      ),
      GoRoute(
        path: ChatListPage.routePath,
        name: ChatListPage.routeName,
        builder: (context, state) => _AppScaffold(
          body: const ChatListPage(),
          currentLocation: state.matchedLocation,
          showHeader: false,
        ),
      ),
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

// Reusable constraints for header icon buttons
const BoxConstraints _kHeaderBtnConstraints = BoxConstraints(
  minWidth: _kHeaderTapTarget,
  minHeight: _kHeaderTapTarget,
);

// Single shared style instance for the UPGRADE button to avoid rebuild allocs
final ButtonStyle _kUpgradeBtnStyle = ElevatedButton.styleFrom(
  backgroundColor: AppTheme.ffPrimary,
  elevation: 0,
  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
  shape: const StadiumBorder(),
);

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
              SettingsPage.routePath, // keep Profile tab “selected” when viewing Settings
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
                style: _kUpgradeBtnStyle, // reused style instance
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
