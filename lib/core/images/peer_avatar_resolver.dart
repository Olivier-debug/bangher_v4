// -----------------------------------------------------------------------------
// PeerAvatarResolver
// - Resolves a user's avatar URL for web/mobile.
// - Converts storage://bucket/path and plain "bucket/path" to HTTPS signed URLs.
// - Refreshes expired Supabase signed URLs and persists to PeerProfileCache.
// - Uses stable storage identity (bucket + objectPath) when available.
// -----------------------------------------------------------------------------

import 'package:supabase_flutter/supabase_flutter.dart';
import '../cache/peer_profile_cache.dart';

class PeerAvatarResolver {
  PeerAvatarResolver._();
  static final PeerAvatarResolver instance = PeerAvatarResolver._();

  /// Returns a best-effort HTTPS URL for the user's avatar.
  /// Persists the normalized URL + stable storage identity back to cache.
  Future<String?> getAvatarUrl(
    String userId, {
    Duration signedUrlTtl = const Duration(hours: 2),
  }) async {
    if (userId.isEmpty) return null;

    final supa = Supabase.instance.client;
    final meId = supa.auth.currentUser?.id;

    // 0) read cache in the new typed form (keeps old raw methods working too)
    final rec = await PeerProfileCache.instance.readRecord(userId);

    // Prefer stable storage identity when available
    if (rec?.avatarBucket != null && rec!.avatarBucket!.isNotEmpty &&
        rec.avatarObjectPath != null && rec.avatarObjectPath!.isNotEmpty) {
      final fresh = await _createSignedUrl(rec.avatarBucket!, rec.avatarObjectPath!, signedUrlTtl);
      if (fresh != null && fresh.isNotEmpty) {
        await _writePicsMerge(rec, primary: fresh);
        return fresh;
      }
    }

    // otherwise, try the first cached picture (signed or storage path)
    final cachedFirst = (rec?.profilePictures.isNotEmpty ?? false) ? rec!.profilePictures.first : null;
    if (cachedFirst != null && cachedFirst.isNotEmpty) {
      // A) if it's a valid http url and not near expiry, use it
      if (_isHttp(cachedFirst) && !_isExpiringSoon(cachedFirst)) {
        return cachedFirst;
      }

      // B) if it's a signed url near expiry OR a storage-ish reference → re-sign it
      final parsedFromSigned = _parseBucketAndPathFromSigned(cachedFirst);
      if (parsedFromSigned != null) {
        // store stable identity for future runs
        await PeerProfileCache.instance.setAvatarObject(
          userId: userId,
          bucket: parsedFromSigned.$1,
          objectPath: parsedFromSigned.$2,
        );
        final fresh = await _createSignedUrl(parsedFromSigned.$1, parsedFromSigned.$2, signedUrlTtl);
        if (fresh != null) {
          await _writePicsMerge(rec, primary: fresh);
          return fresh;
        }
      }

      final storagePseudo = _parseStoragePseudo(cachedFirst) ?? _guessBucketAndPath(cachedFirst);
      if (storagePseudo != null) {
        await PeerProfileCache.instance.setAvatarObject(
          userId: userId,
          bucket: storagePseudo.$1,
          objectPath: storagePseudo.$2,
        );
        final fresh = await _createSignedUrl(storagePseudo.$1, storagePseudo.$2, signedUrlTtl);
        if (fresh != null) {
          await _writePicsMerge(rec, primary: fresh);
          return fresh;
        }
      }

      // If it's http but already expiring or broken, we will try DB fetch next.
    }

    // 1) DB fetch → detect & store stable identity if possible
    final prof = await supa
        .from('profiles')
        .select('name, profile_pictures, last_seen')
        .eq('user_id', userId)
        .maybeSingle();

    if (prof != null) {
      final pics = (prof['profile_pictures'] as List?)?.map((e) => '$e').toList() ?? const <String>[];
      final first = pics.isNotEmpty ? pics.first : '';

      // First try storage reference from DB
      final storeRef = _parseStoragePseudo(first) ?? _guessBucketAndPath(first);
      if (storeRef != null) {
        await PeerProfileCache.instance.setAvatarObject(
          userId: userId,
          bucket: storeRef.$1,
          objectPath: storeRef.$2,
        );
        final fresh = await _createSignedUrl(storeRef.$1, storeRef.$2, signedUrlTtl);
        if (fresh != null) {
          await PeerProfileCache.instance.write(userId, {
            'user_id': userId,
            'name': (prof['name'] ?? 'Member').toString(),
            'profile_pictures': [fresh, ...pics.skip(1).map((e) => e)],
            'last_seen': prof['last_seen']?.toString(),
            'avatar_bucket': storeRef.$1,
            'avatar_object_path': storeRef.$2,
          });
          return fresh;
        }
      }

      // Otherwise if DB already stores a signed/public URL, use it (and cache)
      if (first.isNotEmpty && _isHttp(first)) {
        await PeerProfileCache.instance.write(userId, {
          'user_id': userId,
          'name': (prof['name'] ?? 'Member').toString(),
          'profile_pictures': pics,
          'last_seen': prof['last_seen']?.toString(),
        });
        return first;
      }
    }

    // 2) Last resort for current user: try auth metadata (google/apple/etc.)
    if (meId != null && meId == userId) {
      final meta = supa.auth.currentUser?.userMetadata ?? {};
      final mAvatar = (meta['avatar_url'] ?? meta['picture'] ?? '').toString();
      if (mAvatar.isNotEmpty && _isHttp(mAvatar)) {
        // cache it for next time (no stable storage identity though)
        await PeerProfileCache.instance.write(userId, {
          'user_id': userId,
          'name': (prof?['name'] ?? 'Member').toString(),
          'profile_pictures': [mAvatar],
          'last_seen': prof?['last_seen']?.toString(),
        });
        return mAvatar;
      }
    }

    return null; // truly no avatar
  }

  // ───────────────────────── helpers ─────────────────────────

  bool _isHttp(String url) {
    final u = Uri.tryParse(url);
    return u != null && (u.scheme == 'http' || u.scheme == 'https');
  }

  bool _isExpiringSoon(String url, {Duration window = const Duration(minutes: 5)}) {
    final u = Uri.tryParse(url);
    if (u == null) return false;
    final expStr = u.queryParameters['expires'] ?? u.queryParameters['exp'];
    final exp = int.tryParse(expStr ?? '');
    if (exp == null) return false;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return nowSec >= (exp - window.inSeconds);
  }

  /// Accepts `storage://bucket/path/to/file.jpg`
  (String, String)? _parseStoragePseudo(String url) {
    final u = Uri.tryParse(url);
    if (u == null) return null;
    if (u.scheme != 'storage') return null;
    final bucket = u.host;
    final path = u.path.startsWith('/') ? u.path.substring(1) : u.path;
    if (bucket.isEmpty || path.isEmpty) return null;
    return (bucket, path);
  }

  /// Accepts plain `bucket/path/to/file.jpg`
  (String, String)? _guessBucketAndPath(String s) {
    if (s.contains('://')) return null; // already a URL
    final parts = s.split('/');
    if (parts.length < 2) return null;
    return (parts.first, parts.skip(1).join('/'));
  }

  /// Extracts (bucket, path) from a Supabase **signed** URL if possible.
  (String, String)? _parseBucketAndPathFromSigned(String url) {
    final u = Uri.tryParse(url);
    if (u == null) return null;
    // typical path: /storage/v1/object/sign/<bucket>/<path..> or /object/sign/...
    final segs = u.path.split('/').where((s) => s.isNotEmpty).toList();
    final idx = segs.indexOf('sign');
    if (idx != -1 && idx + 2 <= segs.length - 1) {
      final bucket = segs[idx + 1];
      final path = segs.sublist(idx + 2).join('/');
      if (bucket.isNotEmpty && path.isNotEmpty) return (bucket, path);
    }
    return null;
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

  Future<void> _writePicsMerge(PeerProfileRecord? rec, {required String primary}) async {
    if (rec == null) return;
    final next = <String>[primary, ...rec.profilePictures.where((e) => e != primary)];
    await PeerProfileCache.instance.write(rec.userId, {
      'user_id': rec.userId,
      'name': rec.name,
      'profile_pictures': next,
      'last_seen': rec.lastSeenIso,
      'avatar_bucket': rec.avatarBucket,
      'avatar_object_path': rec.avatarObjectPath,
    });
  }
}
