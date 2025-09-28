// -----------------------------------------------------------------------------
// file: lib/core/cache/peer_profile_cache.dart
// Offline cache for *public* profiles by userId (used by ViewProfilePage).
// Mobile: JSON files under `<docs>/peer_profiles/<userId>.json`
// Web:    shared_preferences fallback.
// -----------------------------------------------------------------------------

import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Global cache wipe coordinator (non-optional integration).
import '../cache_wiper.dart';

class PeerProfileCache {
  PeerProfileCache._();
  static final PeerProfileCache instance = PeerProfileCache._();

  static const String _spPrefix = 'peer_profile_';
  static const String _folder = 'peer_profiles';

  /// Read cached profile by [userId].
  Future<Map<String, dynamic>?> read(String userId) async {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      final s = prefs.getString('$_spPrefix$userId');
      if (s == null) return null;
      try {
        return jsonDecode(s) as Map<String, dynamic>;
      } catch (_) {
        return null;
      }
    }
    final f = await _file(userId);
    if (!await f.exists()) return null;
    try {
      return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Write cached profile for [userId].
  Future<void> write(String userId, Map<String, dynamic> raw) async {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_spPrefix$userId', jsonEncode(raw));
      return;
    }
    final f = await _file(userId);
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode(raw), flush: true);
  }

  /// Delete cached profile for [userId].
  Future<void> delete(String userId) async {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('$_spPrefix$userId');
      return;
    }
    final f = await _file(userId);
    try {
      if (await f.exists()) {
        await f.delete();
      }
    } catch (_) {
      /* best-effort */
    }
  }

  /// Clear ALL peer profile cache on this device.
  /// - Web: removes all SharedPreferences keys with 'peer_profile_' prefix.
  /// - Mobile: deletes the '`<docs>`/peer_profiles' directory tree.
  Future<void> clearAll() async {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys();
      for (final k in keys) {
        if (k.startsWith(_spPrefix)) {
          await prefs.remove(k);
        }
      }
      return;
    }
    try {
      final dir = await _dir();
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {
      /* best-effort */
    }
  }

  // ---------- FS helpers (mobile) ----------

  Future<io.File> _file(String userId) async {
    final dir = await _dir();
    return io.File(p.join(dir.path, '$userId.json'));
  }

  Future<io.Directory> _dir() async {
    final base = await getApplicationDocumentsDirectory();
    return io.Directory(p.join(base.path, _folder));
  }
}

// ──────────────────────────────────────────────────────────────
void _registerPeerProfileCacheHook() {
  CacheWiper.registerHook(() async {
    await PeerProfileCache.instance.clearAll();
  });
}

// Ensure one-time registration and avoid unused warnings.
// ignore: unused_element
final bool _peerProfileCacheHookRegistered = (() {
  _registerPeerProfileCacheHook();
  return true;
})();
