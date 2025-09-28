// -----------------------------------------------------------------------------
// file: lib/core/cache_wiper.dart
// Central cache wiper + hook registry. One API used across the app.
// - Public API: wipeAll(supa: _supa, clearWebLocalStorage: false)
// - Clears: feature hooks, Flutter image cache, DefaultCacheManager,
//           SharedPreferences, (optionally web) local/session storage,
//           Supabase Realtime channels, and app-owned dirs.
// - Safe to call multiple times.
// -----------------------------------------------------------------------------

import 'dart:async';
import 'dart:io' as io;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/painting.dart' as painting show PaintingBinding;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Web-only localStorage cleaner (no-op on non-web) via conditional import.
import 'src/web_storage_clear_stub.dart'
    if (dart.library.html) 'src/web_storage_clear_web.dart';

typedef CacheWipeHook = FutureOr<void> Function();

class CacheWiper {
  CacheWiper._();

  static final List<CacheWipeHook> _hooks = <CacheWipeHook>[];

  /// Features register a hook once to participate in global wipes.
  static void registerHook(CacheWipeHook hook) {
    if (!_hooks.contains(hook)) _hooks.add(hook);
  }

  /// Full wipe.
  /// - When logging out on web, pass `clearWebLocalStorage: true`
  ///   so any app-owned local/session storage is cleared too.
  /// - When “Reset cache” while staying logged in, pass `false`.
  static Future<void> wipeAll({
    required SupabaseClient supa,
    bool clearWebLocalStorage = false,
  }) async {
    // 1) Feature hooks
    await _runHooksSafely();

    // 2) Flutter in-memory image cache
    _clearPaintingCache();

    // 3) Disk caches (DefaultCacheManager)
    await _clearDefaultCacheManager();

    // 4) SharedPreferences
    await _clearSharedPreferences();

    // 4b) Web-only: optionally clear local/session storage
    if (clearWebLocalStorage && kIsWeb) {
      try {
        await WebStorageClear.clearAllLocalStorage();
      } catch (_) {/* ignore */}
    }

    // 5) Supabase realtime channels
    await _closeSupabaseRealtime(supa);

    // 6) App-owned cache folders (best-effort)
    await _deleteAppCacheFolders();
  }

  // ───────────────────────── Helpers ─────────────────────────

  static Future<void> _runHooksSafely() async {
    for (final h in List<CacheWipeHook>.from(_hooks)) {
      try {
        final r = h();
        if (r is Future) await r;
      } catch (_) {/* ignore */}
    }
  }

  static void _clearPaintingCache() {
    try {
      final cache = painting.PaintingBinding.instance.imageCache;
      cache.clear();
      cache.clearLiveImages();
    } catch (_) {/* ignore */}
  }

  static Future<void> _clearDefaultCacheManager() async {
    try {
      final manager = DefaultCacheManager();
      await manager.emptyCache();
      // Some stores expose an underlying store; best-effort clear as well.
      try {
        await manager.store.emptyCache();
      } catch (_) {/* ignore */}
    } catch (_) {/* ignore */}
  }

  static Future<void> _clearSharedPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
    } catch (_) {/* ignore */}
  }

  static Future<void> _closeSupabaseRealtime(SupabaseClient supa) async {
    try {
      await supa.removeAllChannels();
    } catch (_) {/* ignore */}
  }

  /// Delete app-owned cache folders. On web, skip (browser sandbox).
  static Future<void> _deleteAppCacheFolders() async {
    if (kIsWeb) return;

    Future<void> deleteIfExists(io.Directory d) async {
      try {
        if (await d.exists()) await d.delete(recursive: true);
      } catch (_) {/* ignore */}
    }

    try {
      final docs = await getApplicationDocumentsDirectory();
      // Known app-owned subfolders:
      await deleteIfExists(io.Directory(p.join(docs.path, 'peer_profiles'))); // PeerProfileCache
      await deleteIfExists(io.Directory(p.join(docs.path, 'pinned_images'))); // PinnedImageCache
    } catch (_) {/* ignore */}

    // Also nuke temp/cache/support dirs (best-effort)
    try {
      final tmp = await getTemporaryDirectory();
      await deleteIfExists(tmp);
    } catch (_) {/* ignore */}
    try {
      final cache = await getApplicationCacheDirectory();
      await deleteIfExists(cache);
    } catch (_) {/* ignore */}
    try {
      final support = await getApplicationSupportDirectory();
      await deleteIfExists(support);
    } catch (_) {/* ignore */}
  }
}
