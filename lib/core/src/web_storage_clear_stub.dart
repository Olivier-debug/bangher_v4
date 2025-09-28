// Stub used on non-web platforms.
class WebStorageClear {
  static Future<void> clearAllLocalStorage() async {
    // no-op off web
  }
}

