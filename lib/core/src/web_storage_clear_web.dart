// Web-only implementation using package:web (no dart:html).
import 'package:web/web.dart' as web;

class WebStorageClear {
  static Future<void> clearAllLocalStorage() async {
    try {
      web.window.localStorage.clear();
    } catch (_) {}

    try {
      web.window.sessionStorage.clear();
    } catch (_) {}

    // If you also use Cache API / IndexedDB, clear them here via JS interop.
  }
}
