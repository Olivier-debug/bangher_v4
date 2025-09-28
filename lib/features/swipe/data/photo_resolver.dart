// ─────────────────────────────────────────────────────────────────────────────
// lib/features/swipe/data/photo_resolver.dart
// Signed/public URL resolver with storage:// support, missing-token repair,
// stable cache keys, and expiry detection.
// ─────────────────────────────────────────────────────────────────────────────

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../presentation/swipe_models.dart';

@immutable
class ResolvedPhoto {
  final String url;       // actual fetch URL (may include token)
  final String cacheKey;  // stable cache key (no querystring)
  const ResolvedPhoto(this.url, this.cacheKey);
}

class PhotoResolver {
  final SupabaseClient _supa;
  final bool _useSignedUrls;

  final Map<String, ResolvedPhoto> _resolvedByRaw = <String, ResolvedPhoto>{};
  final Map<String, String> _stableKeyByUrl = <String, String>{};

  PhotoResolver(this._supa, {bool useSignedUrls = true}) : _useSignedUrls = useSignedUrls;

  // ── helpers

  String _trimLeadingSlash(String s) => s.startsWith('/') ? s.substring(1) : s;
  bool _isHttp(String s) => s.startsWith('http://') || s.startsWith('https://');

  bool _looksLikeSupabaseUrl(String s) {
    final u = Uri.tryParse(s);
    return u != null && u.host.contains('.supabase.co') && u.path.contains('/storage/v1/object/');
  }

  bool _looksLikeSignUrl(String s) {
    final u = Uri.tryParse(s);
    return u != null && u.path.contains('/storage/v1/object/sign/');
  }

  bool _hasQueryToken(String s) {
    final u = Uri.tryParse(s);
    return u != null && u.queryParameters.containsKey('token');
  }

  /// Accepts `/storage/v1/object/<kind>/<bucket>/<path...>`
  (String, String)? _parseBucketAndPathFromUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final segs = uri.pathSegments;
    final objectIdx = segs.indexOf('object');
    if (objectIdx < 0 || objectIdx + 2 >= segs.length) return null;
    final bucket = segs[objectIdx + 2];
    final rest = segs.sublist(objectIdx + 3);
    if (bucket.isEmpty || rest.isEmpty) return null;
    final objectPath = rest.map(Uri.decodeComponent).join('/');
    return (bucket, objectPath);
  }

  /// Accepts `storage://bucket/path...` OR `storage://path...` (defaults to kProfileBucket)
  (String, String)? _parseBucketAndPathFromStorageScheme(String input) {
    const prefix = 'storage://';
    if (!input.startsWith(prefix)) return null;
    final body = input.substring(prefix.length); // may be 'bucket/path...' or 'path...'
    final s = _trimLeadingSlash(body);
    final i = s.indexOf('/');
    if (i <= 0) {
      // No bucket given → default bucket, whole thing is path
      return (kProfileBucket, s);
    }
    final head = s.substring(0, i);
    final rest = s.substring(i + 1);
    if (rest.isEmpty) return null;
    return (head, rest);
  }

  /// Signed URL typical query has `token` and `exp/expires`.
  bool isSignedAndExpired(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    if (!uri.queryParameters.containsKey('token')) return true; // will 400/403
    final expStr = uri.queryParameters['expires'] ?? uri.queryParameters['exp'];
    final exp = int.tryParse(expStr ?? '');
    if (exp == null) return false;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return now >= exp;
  }

  String _stableKeyFromUrl(String s) {
    final uri = Uri.tryParse(s);
    return uri == null ? s : uri.replace(queryParameters: const {}).toString();
  }

  Future<ResolvedPhoto> _sign(String bucket, String path, String stableKeyIfNeeded) async {
    final url = _useSignedUrls
        ? await _supa.storage.from(bucket).createSignedUrl(path, 55 * 60)
        : _supa.storage.from(bucket).getPublicUrl(path);
    final key = _useSignedUrls ? _stableKeyFromUrl(url) : (stableKeyIfNeeded.isEmpty ? _stableKeyFromUrl(url) : stableKeyIfNeeded);
    return ResolvedPhoto(url, key);
  }

  // ── public API

  Future<ResolvedPhoto> resolvePhoto(String raw) async {
    if (raw.isEmpty) return ResolvedPhoto(raw, raw);

    // memo: still valid?
    final memo = _resolvedByRaw[raw];
    if (memo != null) {
      if (!_useSignedUrls || !isSignedAndExpired(memo.url)) return memo;
    }

    // Case 1: Full HTTP(S) URL
    if (_isHttp(raw)) {
      // If it's a Supabase 'sign' URL lacking token, re-sign.
      if (_looksLikeSupabaseUrl(raw) && _looksLikeSignUrl(raw) && !_hasQueryToken(raw)) {
        final parsed = _parseBucketAndPathFromUrl(raw);
        if (parsed != null) {
          final (bucket, objectPath) = parsed;
          final rp = await _sign(bucket, objectPath, '$bucket/$objectPath');
          _resolvedByRaw[raw] = rp;
          _stableKeyByUrl[rp.url] = rp.cacheKey;
          return rp;
        }
      }
      // Use as-is; make stable cache key by dropping the query.
      final rp = ResolvedPhoto(raw, _stableKeyFromUrl(raw));
      _resolvedByRaw[raw] = rp;
      _stableKeyByUrl[rp.url] = rp.cacheKey;
      return rp;
    }

    // Case 2: storage://bucket/path  OR  storage://path  (default bucket)
    final storageParsed = _parseBucketAndPathFromStorageScheme(raw);
    if (storageParsed != null) {
      final (bucket, objectPath) = storageParsed;
      try {
        final rp = await _sign(bucket, objectPath, '$bucket/$objectPath');
        _resolvedByRaw[raw] = rp;
        _stableKeyByUrl[rp.url] = rp.cacheKey;
        return rp;
      } catch (_) {
        final fallback = ResolvedPhoto(raw, '$bucket/$objectPath');
        _resolvedByRaw[raw] = fallback;
        _stableKeyByUrl[fallback.url] = fallback.cacheKey;
        return fallback;
      }
    }

    // Case 3: plain storage path "<uid>/file" or "bucket/<path>"
    String s = _trimLeadingSlash(raw);
    String bucket = kProfileBucket;
    String path = s;

    final slash = s.indexOf('/');
    if (slash > 0) {
      final head = s.substring(0, slash);
      final rest = s.substring(slash + 1);
      if (!head.contains('.') && rest.isNotEmpty) {
        bucket = head; // treat "bucket/path"
        path = rest;
      }
    }

    final stableKey = '$bucket/$path';
    try {
      final rp = await _sign(bucket, path, stableKey);
      _resolvedByRaw[raw] = rp;
      _stableKeyByUrl[rp.url] = rp.cacheKey;
      return rp;
    } catch (_) {
      final fallback = ResolvedPhoto(raw, stableKey);
      _resolvedByRaw[raw] = fallback;
      _stableKeyByUrl[fallback.url] = fallback.cacheKey;
      return fallback;
    }
  }

  Future<ResolvedPhoto?> resolveMaybe(String? raw) async {
    if (raw == null || raw.isEmpty) return null;
    return resolvePhoto(raw);
  }

  String cacheKeyForUrl(String url) => _stableKeyByUrl[url] ?? _stableKeyFromUrl(url);

  Future<List<ResolvedPhoto>> resolveMany(List<String> raws) async {
    final out = <ResolvedPhoto>[];
    for (final r in raws) {
      if (r.isEmpty) continue;
      out.add(await resolvePhoto(r));
    }
    return out;
  }

  /// Force a fresh signed URL for this *raw* storage path or previously-signed URL.
  Future<ResolvedPhoto> refresh(String raw) async {
    _resolvedByRaw.remove(raw);

    // Refresh from HTTP Supabase URL
    if (_isHttp(raw) && _looksLikeSupabaseUrl(raw)) {
      final parsed = _parseBucketAndPathFromUrl(raw);
      if (parsed != null) {
        try {
          final (bucket, objectPath) = parsed;
          final rp = await _sign(bucket, objectPath, '$bucket/$objectPath');
          _resolvedByRaw[raw] = rp;
          _stableKeyByUrl[rp.url] = rp.cacheKey;
          return rp;
        } catch (_) {/* fall through */}
      }
    }

    // Refresh from storage:// URL
    final sp = _parseBucketAndPathFromStorageScheme(raw);
    if (sp != null) {
      final (bucket, objectPath) = sp;
      final rp = await _sign(bucket, objectPath, '$bucket/$objectPath');
      _resolvedByRaw[raw] = rp;
      _stableKeyByUrl[rp.url] = rp.cacheKey;
      return rp;
    }

    // Fallback: plain path
    return resolvePhoto(raw);
  }
}
