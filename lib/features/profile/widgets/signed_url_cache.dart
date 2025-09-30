import 'package:supabase_flutter/supabase_flutter.dart';

class SignedUrlCache {
  static const Duration _ttl = Duration(minutes: 30);
  static final Map<String, _Entry> _map = {};

  static Future<String> resolve(String urlOrPath) async {
    if (urlOrPath.startsWith('http')) return urlOrPath;

    final now = DateTime.now();
    final hit = _map[urlOrPath];
    if (hit != null && now.isBefore(hit.expires)) return hit.url;

    final cleaned = urlOrPath.replaceFirst(RegExp(r'^storage://'), '');
    final slash = cleaned.indexOf('/');
    if (slash <= 0) {
      throw StateError('Invalid storage path: $urlOrPath');
    }
    final bucket = cleaned.substring(0, slash);
    final path = cleaned.substring(slash + 1);

    final signed = await Supabase.instance.client.storage
        .from(bucket)
        .createSignedUrl(path, _ttl.inSeconds);

    _map[urlOrPath] = _Entry(
      signed,
      now.add(_ttl - const Duration(minutes: 2)),
    );
    return signed;
  }

  static void clear() => _map.clear();
}

class _Entry {
  _Entry(this.url, this.expires);
  final String url;
  final DateTime expires;
}
