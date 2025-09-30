// FILE: lib/features/swipe/data/photo_resolver.dart
// Hardened resolver + variant helpers: re-sign expired sign-URLs,
// robust stable keys, tolerant parsing, and variant-aware cache keys.

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../presentation/swipe_models.dart';

@immutable
class ResolvedPhoto {
  /// Actual fetch URL (may include signed query params).
  final String url;
  /// Stable base cache key (bucket/path or URL w/o query).
  final String cacheKey;
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
    return u != null && (u.queryParameters.containsKey('token') || u.queryParameters.containsKey('t'));
  }

  /// `/storage/v1/object/<kind>/<bucket>/<path...>`, kind ∈ {public, sign, authenticated}
  (String bucket, String objectPath)? _parseBucketAndPathFromUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final segs = uri.pathSegments;
    final objectIdx = segs.indexOf('object');
    if (objectIdx < 0) return null;
    final next = objectIdx + 1;
    if (next >= segs.length) return null;

    String bucket;
    List<String> rest;
    if (next < segs.length && (segs[next] == 'public' || segs[next] == 'sign' || segs[next] == 'authenticated')) {
      final bIdx = next + 1;
      if (bIdx >= segs.length) return null;
      bucket = segs[bIdx];
      rest = segs.sublist(bIdx + 1);
    } else {
      bucket = segs[next];
      rest = segs.sublist(next + 1);
    }

    if (bucket.isEmpty || rest.isEmpty) return null;
    final objectPath = rest.map(Uri.decodeComponent).join('/');
    return (bucket, objectPath);
  }

  /// `storage://bucket/path...` OR `storage://path...` (defaults to kProfileBucket)
  (String bucket, String objectPath)? _parseBucketAndPathFromStorageScheme(String input) {
    const prefix = 'storage://';
    if (!input.startsWith(prefix)) return null;
    final body = input.substring(prefix.length);
    final s = _trimLeadingSlash(body);
    final i = s.indexOf('/');
    if (i <= 0) {
      return (kProfileBucket, s);
    }
    final head = s.substring(0, i);
    final rest = s.substring(i + 1);
    if (rest.isEmpty) return null;
    return (head, rest);
  }

  /// Signed URL typical query has `token` and `expires` (unix seconds).
  bool isSignedAndExpired(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    // If no token, consider it effectively unusable/expired.
    if (!(uri.queryParameters.containsKey('token') || uri.queryParameters.containsKey('t'))) return true;
    // Supabase uses `expires` or sometimes `exp`.
    final expStr = uri.queryParameters['expires'] ?? uri.queryParameters['exp'];
    final exp = int.tryParse(expStr ?? '');
    if (exp == null) return false;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return now >= exp;
  }

  /// Prefer bucket/path for Supabase storage URLs; otherwise drop querystring.
  String _stableKeyFromUrl(String s) {
    if (_looksLikeSupabaseUrl(s)) {
      final parsed = _parseBucketAndPathFromUrl(s);
      if (parsed != null) {
        final (b, p) = parsed;
        return '$b/$p';
      }
    }
    final uri = Uri.tryParse(s);
    return uri == null ? s : uri.replace(queryParameters: const {}).toString();
  }

  Future<ResolvedPhoto> _sign(String bucket, String path, String stableKeyIfNeeded) async {
    final normalizedPath = _trimLeadingSlash(path);
    final url = _useSignedUrls
        ? await _supa.storage.from(bucket).createSignedUrl(normalizedPath, 55 * 60)
        : _supa.storage.from(bucket).getPublicUrl(normalizedPath);
    final key = _useSignedUrls ? '$bucket/$normalizedPath' : (stableKeyIfNeeded.isEmpty ? '$bucket/$normalizedPath' : stableKeyIfNeeded);
    return ResolvedPhoto(url, key);
  }

  void _memo(String raw, ResolvedPhoto rp) {
    _resolvedByRaw[raw] = rp;
    _stableKeyByUrl[rp.url] = rp.cacheKey;
  }

  // ── public API

  Future<ResolvedPhoto> resolvePhoto(String raw) async {
    if (raw.isEmpty) return ResolvedPhoto(raw, raw);

    // memo: still valid?
    final memo = _resolvedByRaw[raw];
    if (memo != null) {
      if (!_useSignedUrls || !isSignedAndExpired(memo.url)) {
        return memo;
      }
    }

    // Case 1: Full HTTP(S) URL
    if (_isHttp(raw)) {
      // Supabase sign URLs → re-sign if missing token OR expired.
      if (_looksLikeSupabaseUrl(raw) && _looksLikeSignUrl(raw)) {
        final needsResign = !_hasQueryToken(raw) || isSignedAndExpired(raw);
        if (needsResign) {
          final parsed = _parseBucketAndPathFromUrl(raw);
          if (parsed != null) {
            final (bucket, objectPath) = parsed;
            final rp = await _sign(bucket, objectPath, '$bucket/$objectPath');
            _memo(raw, rp);
            return rp;
          }
        }
      }
      final rp = ResolvedPhoto(raw, _stableKeyFromUrl(raw));
      _memo(raw, rp);
      return rp;
    }

    // Case 2: storage://bucket/path  OR  storage://path  (default bucket)
    final storageParsed = _parseBucketAndPathFromStorageScheme(raw);
    if (storageParsed != null) {
      final (bucket, objectPath) = storageParsed;
      try {
        final rp = await _sign(bucket, objectPath, '$bucket/$objectPath');
        _memo(raw, rp);
        return rp;
      } catch (_) {
        final fallback = ResolvedPhoto(raw, '$bucket/$objectPath');
        _memo(raw, fallback);
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
      _memo(raw, rp);
      return rp;
    } catch (_) {
      final fallback = ResolvedPhoto(raw, stableKey);
      _memo(raw, fallback);
      return fallback;
    }
  }

  Future<ResolvedPhoto?> resolveMaybe(String? raw) async {
    if (raw == null || raw.isEmpty) return null;
    return resolvePhoto(raw);
  }

  /// Base cache key from a resolved fetch URL.
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
          _memo(raw, rp);
          return rp;
        } catch (_) {/* fall through */}
      }
    }

    // Refresh from storage:// URL
    final sp = _parseBucketAndPathFromStorageScheme(raw);
    if (sp != null) {
      final (bucket, objectPath) = sp;
      final rp = await _sign(bucket, objectPath, '$bucket/$objectPath');
      _memo(raw, rp);
      return rp;
    }

    // Fallback: plain path
    return resolvePhoto(raw);
  }

  // ───────────────────────────────────────────────────────────────────────────
  // NEW: Variant helpers
  // Use these to build exact-size URLs and variant-aware cache keys.
  // ───────────────────────────────────────────────────────────────────────────

  /// Preferred compressed format per platform.
  /// Keep it simple: WEBP everywhere (broad support). If you want AVIF on Android:
  /// change to: if (defaultTargetPlatform == TargetPlatform.android) 'avif' else 'webp'
  String preferredFormat() {
    return 'webp';
  }

  /// Build a transformed Supabase image URL (fit=cover) from a resolved URL.
  /// Pass *pixel* width/height (layout * devicePixelRatio).
  String buildTransformedUrl({
    required String resolvedUrl,
    required int widthPx,
    required int heightPx,
    required double dpr,
    int quality = 78,
    String? format,
    String fit = 'cover',
  }) {
    final fmt = (format ?? preferredFormat()).toLowerCase();
    // Append/merge query safely
    final hasQuery = resolvedUrl.contains('?');
    final sep = hasQuery ? '&' : '?';
    return '$resolvedUrl'
        '${sep}format=$fmt'
        '&quality=$quality'
        '&width=$widthPx'
        '&height=$heightPx'
        '&dpr=${dpr.toStringAsFixed(2)}'
        '&fit=$fit';
  }

  /// Tiny LQIP (blurred). Keep width small for instant paint.
  String buildLqipUrl({
    required String resolvedUrl,
    int tinyWidth = 64,
    int quality = 35,
    int blur = 25,
    String fit = 'cover',
  }) {
    final hasQuery = resolvedUrl.contains('?');
    final sep = hasQuery ? '&' : '?';
    return '$resolvedUrl'
        '${sep}format=webp'
        '&quality=$quality'
        '&width=$tinyWidth'
        '&blur=$blur'
        '&fit=$fit';
  }

  /// Variant-aware cache key: suffix the base with size/dpr/format.
  String cacheKeyWithVariant({
    required String urlOrStable,
    required int widthPx,
    required int heightPx,
    required double dpr,
    required String format,
  }) {
    final base = cacheKeyForUrl(urlOrStable);
    return '$base#w${widthPx}h${heightPx}d${dpr.toStringAsFixed(2)}f${format.toLowerCase()}';
  }
}
