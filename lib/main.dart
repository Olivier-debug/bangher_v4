// FILE: lib/main.dart — performance-tuned + compile-fixes
import 'dart:async';
import 'dart:io' show HttpClient, HttpOverrides, SecurityContext;
import 'dart:ui' as ui show PlatformDispatcher; // for global onError
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform, kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'routing/router.dart';
// ignore: unused_import
import 'core/hooks_bootstrap.dart';
// ↓↓↓ RESET MatchSeen session cache on sign-out
import 'features/matches/data/match_seen_store.dart' show MatchSeenStore;

const String _supabaseUrl = 'https://ccaxkmbpnvuuhxgtjjnv.supabase.co';
const String _supabaseAnonKey =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImNjYXhrbWJwbnZ1dWh4Z3Rqam52Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3MjU4OTgwODUsImV4cCI6MjA0MTQ3NDA4NX0.yWf3OGPwArMNh_xUppY5Wbo972L-6nNt64V5jbqLJuY';

Future<void> main() async {
  FlutterError.onError = (FlutterErrorDetails d) {
    FlutterError.dumpErrorToConsole(d);
    Zone.current.handleUncaughtError(d.exception, d.stack ?? StackTrace.current);
  };
  ui.PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Platform error: $error');
    return true;
  };

  HttpOverrides.global = _TurboHttpOverrides();

  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    GestureBinding.instance.resamplingEnabled = true;

    _tuneImageCache();

    final binding = WidgetsBinding.instance;
    binding.deferFirstFrame();

    await Supabase.initialize(
      url: _supabaseUrl,
      anonKey: _supabaseAnonKey,
      debug: false,
    );

    runApp(const _AppRoot());

    binding.addPostFrameCallback((_) => binding.allowFirstFrame());
  }, (e, st) {
    debugPrint('Uncaught in zone: $e\n$st');
  });
}

/// Re-keys ProviderScope only when the user logs out.
class _AppRoot extends StatefulWidget {
  const _AppRoot();
  @override
  State<_AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<_AppRoot> {
  Key _scopeKey = UniqueKey();
  StreamSubscription<AuthState>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = Supabase.instance.client.auth.onAuthStateChange.listen((authState) {
      if (authState.event == AuthChangeEvent.signedOut) {
        // Clear in-memory "seen" cache on logout to avoid stale state after user switch.
        MatchSeenStore.instance.resetSession();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _scopeKey = UniqueKey());
        });
      }
    });

    assert(() {
      SchedulerBinding.instance.addTimingsCallback((timings) {
        for (final t in timings) {
          if (t.totalSpan.inMilliseconds > 16) {
            debugPrint(
              '🐢 Frame: build=${t.buildDuration}, raster=${t.rasterDuration}, total=${t.totalSpan}',
            );
          }
        }
      });
      return true;
    }());
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      key: _scopeKey,
      child: const MyApp(),
    );
  }
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: 'Meetup',
      routerConfig: router,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        visualDensity: VisualDensity.compact,
        iconTheme: const IconThemeData(size: 26, color: Colors.white),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          elevation: 0,
          toolbarHeight: 64,
        ),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: Colors.black,
          selectedItemColor: Colors.white,
          unselectedItemColor: Colors.white70,
          type: BottomNavigationBarType.fixed,
          showUnselectedLabels: true,
        ),
        pageTransitionsTheme: const PageTransitionsTheme(builders: {
          TargetPlatform.android: ZoomPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: ZoomPageTransitionsBuilder(),
          TargetPlatform.linux: ZoomPageTransitionsBuilder(),
        }),
      ),
      builder: (context, child) {
        final mq = MediaQuery.of(context);
        final current = mq.textScaler.scale(14) / 14;
        final clamped = current.clamp(0.9, 1.1);
        return MediaQuery(
          data: mq.copyWith(textScaler: TextScaler.linear(clamped.toDouble())),
          child: ScrollConfiguration(
            behavior: const _AppScrollBehavior(),
            child: child ?? const SizedBox.shrink(),
          ),
        );
      },
    );
  }
}

// ============================================================================
// HTTP + Image cache tuning
// ============================================================================
class _TurboHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final c = super.createHttpClient(context);
    c.maxConnectionsPerHost = 12; // parallel image fetches
    c.connectionTimeout = const Duration(seconds: 10);
    c.idleTimeout = const Duration(seconds: 15);
    return c;
  }
}

void _tuneImageCache() {
  // PaintingBinding is available via material.dart in your setup, so no extra import is needed.
  final cache = PaintingBinding.instance.imageCache;

  int maxEntries;
  int maxBytes;

  if (kIsWeb) {
    maxEntries = 800;
    maxBytes = 256 * 1024 * 1024;
  } else {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        maxEntries = 600;
        maxBytes = 192 * 1024 * 1024;
        break;
      case TargetPlatform.iOS:
        maxEntries = 900;
        maxBytes = 256 * 1024 * 1024;
        break;
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.linux:
        maxEntries = 1500;
        maxBytes = 384 * 1024 * 1024;
        break;
      default:
        maxEntries = 700;
        maxBytes = 224 * 1024 * 1024;
    }
  }

  cache.maximumSize = maxEntries;
  cache.maximumSizeBytes = maxBytes;
}

// ============================================================================
// Polished scroll behavior (mouse, touch, trackpad; no glow).
// ============================================================================
class _AppScrollBehavior extends ScrollBehavior {
  const _AppScrollBehavior();

  @override
  Widget buildOverscrollIndicator(BuildContext context, Widget child, ScrollableDetails details) {
    return child;
  }

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());
      default:
        return const ClampingScrollPhysics(parent: AlwaysScrollableScrollPhysics());
    }
  }

  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
      };
}
