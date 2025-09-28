import 'dart:html' as html;

class WebStorageClear {
  static Future<void> clearAllLocalStorage() async {
    try {
      // Clear *everything* in this origin’s localStorage.
      // Safe because you’re immediately re-creating prefs/session on next login.
      html.window.localStorage.clear();
      // If you keep any keys you *don’t* want to drop, remove them here instead.
    } catch (_) {
      // best-effort
    }
  }
}
