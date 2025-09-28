// FILE: lib/web_storage_clear_web.dart (use conditional import if you prefer)
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
  }
}
