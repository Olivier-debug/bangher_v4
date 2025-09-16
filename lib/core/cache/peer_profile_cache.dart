// -----------------------------------------------------------------------------
// file: lib/core/cache/peer_profile_cache.dart
// Offline cache for *public* profiles by userId (used by ViewProfilePage).
// Mobile: JSON files under <docs>/peer_profiles/<userId>.json
// Web:    shared_preferences fallback.

import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PeerProfileCache {
  PeerProfileCache._();
  static final PeerProfileCache instance = PeerProfileCache._();

  Future<Map<String, dynamic>?> read(String userId) async {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      final s = prefs.getString('peer_profile_$userId');
      if (s == null) return null;
      try { return jsonDecode(s) as Map<String, dynamic>; } catch (_) { return null; }
    }
    final f = await _file(userId);
    if (!await f.exists()) return null;
    try { return jsonDecode(await f.readAsString()) as Map<String, dynamic>; } catch (_) { return null; }
  }

  Future<void> write(String userId, Map<String, dynamic> raw) async {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('peer_profile_$userId', jsonEncode(raw));
      return;
    }
    final f = await _file(userId);
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode(raw), flush: true);
  }

  Future<io.File> _file(String userId) async {
    final dir = await getApplicationDocumentsDirectory();
    return io.File(p.join(dir.path, 'peer_profiles', '$userId.json'));
  }
}