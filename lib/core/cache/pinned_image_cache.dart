// file: lib/core/cache/pinned_image_cache.dart
// Persistent, per-UID image pinning for fully-offline display.
// Stores images under <app-docs>/pinned_images/<uid>/ and keeps a manifest url->localPath.
// Clear on sign-out or user switch only.
//
// Deps (pubspec.yaml):
//   path_provider: ^2.1.4
//   http: ^1.2.1
//   crypto: ^3.0.3
//   path: ^1.9.0

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha1;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

// Global cache wipe coordinator (non-optional integration).
import '../cache_wiper.dart';

class PinnedImageCache {
  PinnedImageCache._();
  static final PinnedImageCache instance = PinnedImageCache._();

  Future<Directory> _baseDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'pinned_images'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<Directory> _userDir(String uid) async {
    final base = await _baseDir();
    final dir = Directory(p.join(base.path, uid));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> _manifestFile(String uid) async {
    final dir = await _userDir(uid);
    return File(p.join(dir.path, 'manifest.json'));
  }

  Future<Map<String, String>> _readManifest(String uid) async {
    final f = await _manifestFile(uid);
    if (!await f.exists()) return {};
    try {
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return j.map((k, v) => MapEntry(k, v as String));
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeManifest(String uid, Map<String, String> m) async {
    final f = await _manifestFile(uid);
    await f.writeAsString(jsonEncode(m));
  }

  String _fileNameForUrl(String url) {
    final uri = Uri.tryParse(url);
    final ext = uri == null ? '' : p.extension(uri.path);
    final hash = sha1.convert(utf8.encode(url)).toString();
    return '$hash$ext';
  }

  Future<String?> _downloadToUserDir(String url, String uid) async {
    try {
      final resp = await http.get(Uri.parse(url));
      if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) return null;
      final dir = await _userDir(uid);
      final name = _fileNameForUrl(url);
      final file = File(p.join(dir.path, name));
      await file.writeAsBytes(resp.bodyBytes, flush: true);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  /// Ensure all [urls] are downloaded and pinned for [uid].
  /// Returns a fresh url->localPath manifest subset for provided urls.
  Future<Map<String, String>> prefetchAll(
    List<String> urls, {
    required String uid,
  }) async {
    final manifest = await _readManifest(uid);
    final out = <String, String>{};

    for (final url in urls) {
      final existing = manifest[url];
      if (existing != null && await File(existing).exists()) {
        out[url] = existing;
        continue;
      }
      final path = await _downloadToUserDir(url, uid);
      if (path != null) {
        manifest[url] = path;
        out[url] = path;
      }
    }

    await _writeManifest(uid, manifest);
    return out;
  }

  /// Map known urls to local paths (no downloads). Missing entries are omitted.
  Future<Map<String, String>> localPaths(
    List<String> urls, {
    required String uid,
  }) async {
    final manifest = await _readManifest(uid);
    final out = <String, String>{};
    for (final url in urls) {
      final path = manifest[url];
      if (path != null && await File(path).exists()) out[url] = path;
    }
    return out;
  }

  /// Remove all pinned images for a specific user.
  Future<void> clearForUser(String uid) async {
    final dir = await _userDir(uid);
    if (await dir.exists()) {
      try { await dir.delete(recursive: true); } catch (_) {}
    }
  }

  /// Remove ALL pinned images for ALL users.
  Future<void> clearAll() async {
    try {
      final base = await _baseDir();
      if (await base.exists()) {
        await base.delete(recursive: true);
      }
    } catch (_) {
      // best-effort
    }
  }
}

// ──────────────────────────────────────────────────────────────
// Register with CacheWiper (runs on Settings → Reset cache).
// ──────────────────────────────────────────────────────────────

void _registerPinnedImageHook() {
  CacheWiper.registerHook(() async {
    await PinnedImageCache.instance.clearAll();
  });
}

// Ensure one-time registration and avoid unused warnings.
// ignore: unused_element
final bool _pinnedImageHookRegistered = (() {
  _registerPinnedImageHook();
  return true;
})();
