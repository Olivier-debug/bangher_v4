// FILE: lib/main.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'routing/router.dart';
// If you want to start/stop a global presence service on auth changes,
// uncomment the next line and the two calls inside the listener below.
// import 'services/presence_service.dart';

const String _supabaseUrl = 'https://ccaxkmbpnvuuhxgtjjnv.supabase.co';
const String _supabaseAnonKey =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImNjYXhrbWJwbnZ1dWh4Z3Rqam52Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3MjU4OTgwODUsImV4cCI6MjA0MTQ3NDA4NX0.yWf3OGPwArMNh_xUppY5Wbo972L-6nNt64V5jbqLJuY';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: _supabaseUrl,
    anonKey: _supabaseAnonKey,
    debug: false,
    // If supported by your version, you can also pass options like:
    // realtimeClientOptions: const RealtimeClientOptions(heartbeatIntervalMs: 30000),
    // authOptions: const GoTrueClientOptions(flowType: AuthFlowType.pkce), // only if available
  );

  // Optional: react to auth state changes at app level (safe to keep).
  Supabase.instance.client.auth.onAuthStateChange.listen((data) {
    final event = data.event;
    if (event == AuthChangeEvent.signedIn) {
      // PresenceService.instance.start();
    } else if (event == AuthChangeEvent.signedOut) {
      // PresenceService.instance.stop();
    }
  });

  runApp(const ProviderScope(child: MyApp()));
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
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          elevation: 0,
          centerTitle: false,
          titleTextStyle: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w400,
            color: Colors.white,
            letterSpacing: 0.2,
          ),
          toolbarHeight: 64,
        ),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: Colors.black,
          selectedItemColor: Colors.white,
          unselectedItemColor: Colors.white70,
          type: BottomNavigationBarType.fixed,
          showUnselectedLabels: true,
        ),
        iconTheme: const IconThemeData(size: 26, color: Colors.white),
      ),
    );
  }
}
