// FILE: lib/routing/go_router_refresh.dart
import 'dart:async';
import 'package:flutter/foundation.dart';

/// Minimal ChangeNotifier that re-notifies GoRouter when the auth stream emits.
class GoRouterRefreshStream extends ChangeNotifier {
  GoRouterRefreshStream(Stream<dynamic> stream) {
    _sub = stream.asBroadcastStream().listen((_) => notifyListeners());
  }
  late final StreamSubscription<dynamic> _sub;

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}
