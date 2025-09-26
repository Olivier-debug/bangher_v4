// ─────────────────────────────────────────────────────────────────────────────
// lib/features/swipe/data/photo_resolver.dart
// Signed/public URL resolver with stable cache keys & expiry detection.
// ─────────────────────────────────────────────────────────────────────────────

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../presentation/swipe_models.dart';

@immutable
class ResolvedPhoto {
  final String url;      // final URL to load (signed or public)
  final String cacheKey; // stable key without volatile query params
  const ResolvedPhoto(this.url, this.cacheKey);
}

class PhotoResolver {
  final SupabaseClient _supa;
  final bool _useSignedUrls;
  final Map<String, ResolvedPhoto> _resolvedByRaw = <String, ResolvedPhoto>{};
  final Map<String, String> _stableKeyByUrl = <String, String>{};

  PhotoResolver(this._supa, {bool useSignedUrls = true}) : _useSignedUrls = useSignedUrls;

  String _trimLeadingSlash(String s) => s.startsWith('/') ? s.substring(1) : s;

  /// Heuristic for Supabase signed URL expiry (`?token=...&expiresAt=` or `...&exp=unix`).
  bool isSignedAndExpired(String url) {
    if (!url.contains('?')) return false;
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    // Supabase uses either `expiresAt` (ms) or `exp` (s) depending on version.
    final expQuery = uri.queryParameters['exp'];
    final expiresAtMsQuery = uri.queryParameters['expiresAt'];
    final nowS = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    if (expQuery != null) {
      final expS = int.tryParse(expQuery);
      if (expS != null) return nowS >= expS;
    }
    if (expiresAtMsQuery != null) {
      final expMs = int.tryParse(expiresAtMsQuery);
      if (expMs != null) return DateTime.now().millisecondsSinceEpoch >= expMs;
    }
    return false;
  }

  /// Main resolver. Accepts:
  /// - Full URL: kept as-is; cacheKey = url without query.
  /// - "<bucket>/<path>": creates public or signed URL as configured.
  Future<ResolvedPhoto> resolvePhoto(String raw) async {
    if (raw.isEmpty) return ResolvedPhoto(raw, raw);

    final memo = _resolvedByRaw[raw];
    if (memo != null) {
      // Avoid re-signing unless required.
      if (!_useSignedUrls || !isSignedAndExpired(memo.url)) return memo;
    }

    String s = _trimLeadingSlash(raw);
    String bucket = kProfileBucket;
    String path = s;

    // Full URL? Use verbatim; stable cache key is URL without query.
    if (s.startsWith('http://') || s.startsWith('https://')) {
      final uri = Uri.tryParse(s);
      final key = (uri != null) ? uri.replace(queryParameters: const {}).toString() : s;
      final rp = ResolvedPhoto(s, key);
      _resolvedByRaw[raw] = rp;
      _stableKeyByUrl[rp.url] = rp.cacheKey;
      return rp;
    }

    // Parse "<bucket>/<path>" form
    final firstSlash = s.indexOf('/');
    if (firstSlash > 0) {
      final head = s.substring(0, firstSlash);
      final rest = s.substring(firstSlash + 1);
      if (!head.contains('.') && rest.isNotEmpty) {
        bucket = head;
        path = rest;
      }
    }

    final stableKey = '$bucket/$path';
    try {
      final url = _useSignedUrls
          ? await _supa.storage.from(bucket).createSignedUrl(path, 55 * 60) // 55m to be cache-safe
          : _supa.storage.from(bucket).getPublicUrl(path);
      final rp = ResolvedPhoto(url, stableKey);
      _resolvedByRaw[raw] = rp;
      _stableKeyByUrl[rp.url] = rp.cacheKey;
      return rp;
    } catch (_) {
      // Fallback: return raw path as URL (useful for debug) with stable key.
      final rp = ResolvedPhoto(raw, stableKey);
      _resolvedByRaw[raw] = rp;
      _stableKeyByUrl[rp.url] = rp.cacheKey;
      return rp;
    }
  }

  Future<ResolvedPhoto?> resolveMaybe(String? raw) async {
    if (raw == null || raw.isEmpty) return null;
    return resolvePhoto(raw);
  }

  /// Retrieve a previously computed stable cache key for a URL.
  String cacheKeyForUrl(String url) => _stableKeyByUrl[url] ?? url;

  Future<List<ResolvedPhoto>> resolveMany(List<String> raws) async {
    final out = <ResolvedPhoto>[];
    for (final r in raws) {
      if (r.isEmpty) continue;
      out.add(await resolvePhoto(r));
    }
    return out;
  }

  /// Force a fresh signed URL for this *raw* storage path (bypass memo).
  Future<ResolvedPhoto> refresh(String raw) async {
    _resolvedByRaw.remove(raw);
    return resolvePhoto(raw);
  }
}


