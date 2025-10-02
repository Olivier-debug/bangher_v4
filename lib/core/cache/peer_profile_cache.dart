// -----------------------------------------------------------------------------
// file: lib/core/cache/peer_profile_cache.dart
// Stores *stable* identity for peer avatars (bucket + objectPath) and profile.
// Keeps old API working, but adds model helpers and avatar object support.
// -----------------------------------------------------------------------------

import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../cache_wiper.dart';

class PeerProfileRecord {
  final String userId;
  final String name;
  final List<String> profilePictures; // raw list from DB (may be http/signed)
  final String? avatarBucket;         // stable storage identity (NEW)
  final String? avatarObjectPath;     // stable storage identity (NEW)
  final String? lastSeenIso;

  const PeerProfileRecord({
    required this.userId,
    required this.name,
    required this.profilePictures,
    this.avatarBucket,
    this.avatarObjectPath,
    this.lastSeenIso,
  });

  Map<String, dynamic> toMap() => {
        'user_id': userId,
        'name': name,
        'profile_pictures': profilePictures,
        'avatar_bucket': avatarBucket,
        'avatar_object_path': avatarObjectPath,
        'last_seen': lastSeenIso,
      };

  static PeerProfileRecord? fromMap(Map<String, dynamic>? m) {
    if (m == null) return null;
    return PeerProfileRecord(
      userId: (m['user_id'] ?? '').toString(),
      name: (m['name'] ?? 'Member').toString(),
      profilePictures: (m['profile_pictures'] as List?)?.map((e) => '$e').toList() ?? const <String>[],
      avatarBucket: m['avatar_bucket']?.toString(),
      avatarObjectPath: m['avatar_object_path']?.toString(),
      lastSeenIso: m['last_seen']?.toString(),
    );
  }

  PeerProfileRecord copyWith({
    String? name,
    List<String>? profilePictures,
    String? avatarBucket,
    String? avatarObjectPath,
    String? lastSeenIso,
  }) {
    return PeerProfileRecord(
      userId: userId,
      name: name ?? this.name,
      profilePictures: profilePictures ?? this.profilePictures,
      avatarBucket: avatarBucket ?? this.avatarBucket,
      avatarObjectPath: avatarObjectPath ?? this.avatarObjectPath,
      lastSeenIso: lastSeenIso ?? this.lastSeenIso,
    );
  }
}

class PeerProfileCache {
  PeerProfileCache._();
  static final PeerProfileCache instance = PeerProfileCache._();

  static const String _spPrefix = 'peer_profile_';
  static const String _folder = 'peer_profiles';

  // --------- Public API ---------

  Future<PeerProfileRecord?> readRecord(String userId) async {
    final raw = await read(userId);
    return PeerProfileRecord.fromMap(raw);
  }

  Future<void> writeRecord(PeerProfileRecord rec) => write(rec.userId, rec.toMap());

  /// Set a stable avatar identity (bucket+path) for this userId.
  Future<void> setAvatarObject({
    required String userId,
    required String bucket,
    required String objectPath,
  }) async {
    final existing = await readRecord(userId);
    final next = (existing ??
            PeerProfileRecord(userId: userId, name: 'Member', profilePictures: const <String>[]))
        .copyWith(avatarBucket: bucket, avatarObjectPath: objectPath);
    await writeRecord(next);
  }

  /// Old methods (kept for compatibility) – store arbitrary JSON.
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
    } catch (_) {/* best-effort */}
  }

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
    } catch (_) {/* best-effort */}
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

// Ensure one-time registration.
// ignore: unused_element
final bool _peerProfileCacheHookRegistered = (() {
  _registerPeerProfileCacheHook();
  return true;
})();
