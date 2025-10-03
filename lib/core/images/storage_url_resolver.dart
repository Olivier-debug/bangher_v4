// FILE: lib/core/images/storage_url_resolver.dart
// A tiny, centralized helper for turning storage refs into usable HTTP URLs
// and for building stable cache keys + image transform variants.

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:supabase_flutter/supabase_flutter.dart';

typedef BucketPath = ({String bucket, String objectPath});

class StorageUrlResolver {
  /// Returns true if [url] looks like a Supabase *signed* URL.
  static bool isSupabaseSignedUrl(String url) {
    final u = Uri.tryParse(url);
    return u != null && u.path.contains('/storage/v1/object/sign/');
  }

  /// Extracts (bucket, objectPath) from a Supabase *signed* URL.
  /// Returns null if [url] isn't a recognized signed URL form.
  static BucketPath? parseBucketAndPathFromSignedUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final segs = uri.pathSegments;
    final signIdx = segs.indexOf('sign');
    if (signIdx < 0 || signIdx + 1 >= segs.length) return null;
    final bucket = segs[signIdx + 1];
    final rest = segs.sublist(signIdx + 2);
    if (bucket.isEmpty || rest.isEmpty) return null;
    final objectPath = rest.map(Uri.decodeComponent).join('/');
    return (bucket: bucket, objectPath: objectPath);
  }

  /// Normalizes common storage reference formats into (bucket, objectPath).
  /// Accepts:
  ///   - 'storage://bucket/path/to/file.jpg'
  ///   - 'bucket/path/to/file.jpg'
  ///   - Already-HTTP(s) URL → returns null (means: nothing to normalize)
  static BucketPath? parseStorageRef(String input) {
    final s = input.trim();
    if (s.isEmpty) return null;
    if (s.startsWith('http://') || s.startsWith('https://')) return null;

    if (s.startsWith('storage://')) {
      final rest = s.substring('storage://'.length);
      final slash = rest.indexOf('/');
      if (slash > 0) {
        return (bucket: rest.substring(0, slash), objectPath: rest.substring(slash + 1));
      }
      return (bucket: rest, objectPath: '');
    }

    if (s.contains('/')) {
      final parts = s.split('/');
      if (parts.isNotEmpty) {
        return (bucket: parts.first, objectPath: parts.skip(1).join('/'));
      }
    }

    // If no slash is present, assume default bucket and the whole string as objectPath
    return (bucket: 'profile_pictures', objectPath: s);
  }

  /// Produces a *stable* cache key from URL by dropping query params on native.
  /// On web, use the full URL so the browser cache can differentiate variants.
  static String stableCacheKey(String url) {
    final u = Uri.tryParse(url);
    if (u == null) return url;
    if (kIsWeb) return url;
    return url.split('?').first;
  }

  /// Ensures [raw] becomes a resolvable, fetchable HTTP URL.
  /// - If [raw] is already http(s), return it.
  /// - If it's a signed URL, return it (optionally add a web cache-bust).
  /// - If it's a storage ref, try signed first (55m TTL), else fall back to public.
  static Future<String> resolve({
    required SupabaseClient supa,
    required String raw,
    Duration ttl = const Duration(minutes: 55),
    bool preferPublic = false,
    bool addCacheBustOnWeb = true,
  }) async {
    final s = raw.trim();
    if (s.isEmpty) return '';

    if (s.startsWith('http://') || s.startsWith('https://')) {
      return _maybeBust(s, addCacheBustOnWeb);
    }

    // Signed URL input (rare case: persisted from elsewhere)
    final signedParsed = parseBucketAndPathFromSignedUrl(s);
    if (signedParsed != null) {
      return _maybeBust(s, addCacheBustOnWeb);
    }

    // Storage ref
    final ref = parseStorageRef(s);
    if (ref == null) return '';

    try {
      if (preferPublic) {
        final pub = supa.storage.from(ref.bucket).getPublicUrl(ref.objectPath);
        return _maybeBust(pub, addCacheBustOnWeb);
      }

      final signed = await supa.storage.from(ref.bucket).createSignedUrl(ref.objectPath, ttl.inSeconds);
      return _maybeBust(signed, addCacheBustOnWeb);
    } catch (_) {
      // Fallback to public url if signing fails.
      final pub = supa.storage.from(ref.bucket).getPublicUrl(ref.objectPath);
      return _maybeBust(pub, addCacheBustOnWeb);
    }
  }

  /// Builds a transformed variant URL for Supabase image transformation.
  /// If [url] isn't a Supabase storage *signed* URL, returns it unchanged.
  static String addTransformsVariant({
    required String url,
    required int widthPx,
    required int heightPx,
    required double dpr,
    String format = 'webp',
    int quality = 78,
    String fit = 'cover',
  }) {
    if (!isSupabaseSignedUrl(url)) return url;
    final sep = url.contains('?') ? '&' : '?';
    return '$url'
        '${sep}format=$format'
        '&quality=$quality'
        '&width=$widthPx'
        '&height=$heightPx'
        '&dpr=${dpr.toStringAsFixed(2)}'
        '&fit=$fit';
  }

  /// Low-quality placeholder transform for fast-first paint.
  static String addTransformsLqip({
    required String url,
    String format = 'webp',
    int quality = 35,
    int widthPx = 64,
    int blur = 25,
    String fit = 'cover',
  }) {
    if (!isSupabaseSignedUrl(url)) return url;
    final sep = url.contains('?') ? '&' : '?';
    return '$url${sep}format=$format&quality=$quality&width=$widthPx&blur=$blur&fit=$fit';
  }

  static String _maybeBust(String url, bool add) {
    if (!add || !kIsWeb) return url;
    final sep = url.contains('?') ? '&' : '?';
    return '$url${sep}cb=${DateTime.now().millisecondsSinceEpoch}';
  }
}

// Convenience top-level forwards if you prefer functions over the class API.
bool isSupabaseSignedUrl(String url) => StorageUrlResolver.isSupabaseSignedUrl(url);
BucketPath? parseBucketAndPathFromSignedUrl(String url) => StorageUrlResolver.parseBucketAndPathFromSignedUrl(url);
BucketPath? parseStorageRef(String input) => StorageUrlResolver.parseStorageRef(input);
String stableCacheKey(String url) => StorageUrlResolver.stableCacheKey(url);
Future<String> resolveStorageUrl({
  required SupabaseClient supa,
  required String raw,
  Duration ttl = const Duration(minutes: 55),
  bool preferPublic = false,
  bool addCacheBustOnWeb = true,
}) =>
    StorageUrlResolver.resolve(
      supa: supa,
      raw: raw,
      ttl: ttl,
      preferPublic: preferPublic,
      addCacheBustOnWeb: addCacheBustOnWeb,
    );
String addVariantTransform({
  required String url,
  required int widthPx,
  required int heightPx,
  required double dpr,
  String format = 'webp',
  int quality = 78,
  String fit = 'cover',
}) =>
    StorageUrlResolver.addTransformsVariant(
      url: url,
      widthPx: widthPx,
      heightPx: heightPx,
      dpr: dpr,
      format: format,
      quality: quality,
      fit: fit,
    );
String addLqipTransform({
  required String url,
  String format = 'webp',
  int quality = 35,
  int widthPx = 64,
  int blur = 25,
  String fit = 'cover',
}) =>
    StorageUrlResolver.addTransformsLqip(
      url: url,
      format: format,
      quality: quality,
      widthPx: widthPx,
      blur: blur,
      fit: fit,
    );


