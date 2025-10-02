// -----------------------------------------------------------------------------
// PeerAvatarResolver
// - Resolves a user's avatar URL for web/mobile.
// - Converts storage://bucket/path and plain "bucket/path" to HTTPS signed URLs.
// - Refreshes expired Supabase signed URLs and persists to PeerProfileCache.
// -----------------------------------------------------------------------------

import 'package:supabase_flutter/supabase_flutter.dart';
import '../cache/peer_profile_cache.dart';

class PeerAvatarResolver {
  PeerAvatarResolver._();
  static final PeerAvatarResolver instance = PeerAvatarResolver._();

  /// Returns a best-effort HTTPS URL for the user's avatar.
  /// Persists the normalized URL back to cache so it survives app restarts.
  Future<String?> getAvatarUrl(
    String userId, {
    Duration signedUrlTtl = const Duration(hours: 2),
  }) async {
    if (userId.isEmpty) return null;

    // 1) Cache-first
    final cached = await PeerProfileCache.instance.read(userId);
    List<dynamic> cachedPics = const [];
    String? cachedFirst;
    if (cached != null) {
      cachedPics = (cached['profile_pictures'] as List?) ?? const [];
      if (cachedPics.isNotEmpty) cachedFirst = cachedPics.first?.toString();
    }

    Future<void> writePics(List<String> pics) async {
      final snap = <String, dynamic>{
        if (cached != null) ...cached,
        'user_id': userId,
        'profile_pictures': pics,
      };
      await PeerProfileCache.instance.write(userId, snap);
    }

    // Core normalization: turn any form into an HTTPS URL
    Future<String?> normalize(String? urlOrRef) async {
      if (urlOrRef == null || urlOrRef.isEmpty) return null;

      // Case A: Supabase signed HTTPS URL already
      if (_isSupabaseSignedUrl(urlOrRef)) {
        // Optionally refresh, but usually you can use as-is.
        return urlOrRef;
      }

      // Case B: explicit storage://bucket/path
      final storageParsed = _parseStoragePseudo(urlOrRef);
      if (storageParsed != null) {
        final fresh = await _createSignedUrl(storageParsed.$1, storageParsed.$2, signedUrlTtl);
        if (fresh != null) {
          final next = cachedPics.isEmpty
              ? <String>[fresh]
              : <String>[fresh, ...cachedPics.skip(1).map((e) => '$e')];
          await writePics(next);
          return fresh;
        }
        return null;
      }

      // Case C: raw "bucket/path"
      final guess = _guessBucketAndPath(urlOrRef);
      if (guess != null) {
        final fresh = await _createSignedUrl(guess.$1, guess.$2, signedUrlTtl);
        if (fresh != null) {
          final next = cachedPics.isEmpty
              ? <String>[fresh]
              : <String>[fresh, ...cachedPics.skip(1).map((e) => '$e')];
          await writePics(next);
          return fresh;
        }
        return null;
      }

      // Case D: http(s) public url → pass through
      final u = Uri.tryParse(urlOrRef);
      if (u != null && (u.scheme == 'http' || u.scheme == 'https')) {
        return urlOrRef;
      }

      // Unknown form
      return null;
    }

    // Try cached first
    if (cachedFirst != null && cachedFirst.isNotEmpty) {
      final normalized = await normalize(cachedFirst);
      if (normalized != null && normalized.isNotEmpty) return normalized;
    }

    // 2) Cache miss → fetch latest profile
    final supa = Supabase.instance.client;
    final prof = await supa
        .from('profiles')
        .select('name, profile_pictures, last_seen')
        .eq('user_id', userId)
        .maybeSingle();

    if (prof == null) return null;

    final serverPics = (prof['profile_pictures'] as List?) ?? const [];
    final first = serverPics.isNotEmpty ? (serverPics.first?.toString() ?? '') : '';
    final normalized = await normalize(first);

    // Persist normalized snapshot for future runs
    await PeerProfileCache.instance.write(userId, {
      'user_id': userId,
      'name': (prof['name'] ?? 'Member').toString(),
      'profile_pictures': [
        if ((normalized ?? first).isNotEmpty) (normalized ?? first),
        ...serverPics.skip(1).map((e) => '$e'),
      ],
      'last_seen': prof['last_seen']?.toString(),
    });

    return normalized?.isNotEmpty == true ? normalized : (first.isNotEmpty ? first : null);
  }

  // ───────────────────────── helpers ─────────────────────────

  bool _isSupabaseSignedUrl(String url) {
    final u = Uri.tryParse(url);
    return u != null && u.scheme.startsWith('http') && u.path.contains('/storage/v1/object/sign/');
  }

  /// Accepts `storage://bucket/path/to/file.jpg`
  (String, String)? _parseStoragePseudo(String url) {
    final u = Uri.tryParse(url);
    if (u == null) return null;
    if (u.scheme != 'storage') return null;
    final bucket = u.host; // e.g. profile_pictures
    final path = u.path.startsWith('/') ? u.path.substring(1) : u.path;
    if (bucket.isEmpty || path.isEmpty) return null;
    return (bucket, path);
  }

  /// Accepts plain `bucket/path/to/file.jpg`
  (String, String)? _guessBucketAndPath(String s) {
    if (s.contains('://')) return null; // already has scheme; handled above
    final parts = s.split('/');
    if (parts.length < 2) return null;
    return (parts.first, parts.skip(1).join('/'));
  }

  Future<String?> _createSignedUrl(String bucket, String objectPath, Duration ttl) async {
    try {
      final supa = Supabase.instance.client;
      final seconds = ttl.inSeconds.clamp(60, 60 * 60 * 24);
      var url = await supa.storage.from(bucket).createSignedUrl(objectPath, seconds);
      // Cache-buster for web to avoid stale service worker entries
      final sep = url.contains('?') ? '&' : '?';
      url = '$url${sep}cb=${DateTime.now().millisecondsSinceEpoch}';
      return url;
    } catch (_) {
      return null;
    }
  }
}
