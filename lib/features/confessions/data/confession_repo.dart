// =========================
// FILE: lib/features/confessions/data/confession_repo.dart
// =========================

import 'dart:typed_data';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'confession_models.dart';

class ConfessionRepository {
  ConfessionRepository({SupabaseClient? client}) : _supa = client ?? Supabase.instance.client;
  final SupabaseClient _supa;

  // --- Feed ------------------------------------------------------------------
  Future<List<ConfessionItem>> fetchFeed({required int limit, required int offset}) async {
    // Prefer your RPC if available; otherwise do a view/select.
    final rows = await _supa.rpc('confessions_feed', params: {
      'limit_arg': limit,
      'offset_arg': offset,
    });

    final list = (rows as List?)?.cast<Map<String, dynamic>>() ?? const [];
    return list.map((r) => ConfessionItem.fromRow(r)).toList();
  }

  Future<ConfessionItem?> fetchOne(String id) async {
    final rows = await _supa.rpc('confessions_one', params: {
      'p_confession_id': id,
    });
    final list = (rows as List?)?.cast<Map<String, dynamic>>() ?? const [];
    if (list.isEmpty) return null;
    return ConfessionItem.fromRow(list.first);
  }

  // --- Likes -----------------------------------------------------------------
  Future<ConfessionItem?> toggleLike(String confessionId) async {
    final rows = await _supa.rpc('toggle_confession_like', params: {
      'p_confession_id': confessionId,
    });
    final list = (rows as List?)?.cast<Map<String, dynamic>>() ?? const [];
    if (list.isEmpty) return null;

    // We only get liked + like_count back usually; the rest should be merged by caller.
    final liked = (list.first['liked'] as bool?) ?? false;
    final count = (list.first['like_count'] as int?) ?? 0;
    // Return a tiny object for merging upstream.
    return ConfessionItem(
      id: confessionId,
      authorUserId: '',
      content: '',
      isAnonymous: false,
      imageUrl: null,
      createdAt: DateTime.now().toUtc(),
      likeCount: count,
      commentCount: 0,
      likedByMe: liked,
      authorName: null,
      authorAvatarUrl: null,
      topic: 'Random',
      language: 'English',
      nsfw: false,
      editedAt: null,
    );
  }

  // --- Comments --------------------------------------------------------------
  Future<List<CommentItem>> fetchComments({
    required String confessionId,
    required int limit,
    required int offset,
  }) async {
    final rows = await _supa
        .from('confession_comments')
        .select(
          '''
          id, confession_id, author_user_id, text, created_at,
          profiles:confession_comments_author_user_id_fkey(name, profile_pictures)
          ''',
        )
        .eq('confession_id', confessionId)
        .order('created_at', ascending: false)
        .range(offset, offset + limit - 1);

    final list = (rows as List?)?.cast<Map<String, dynamic>>() ?? const [];
    Map<String, dynamic> flatten(Map<String, dynamic> r) {
      final prof = (r['profiles'] as Map?) ?? const {};
      final pics = (prof['profile_pictures'] as List?) ?? const [];
      final avatar = pics.isNotEmpty ? pics.first?.toString() : null;
      return {
        ...r,
        'author_name': (prof['name'] ?? 'Someone').toString(),
        'author_avatar_url': avatar,
      };
    }

    return list.map((r) => CommentItem.fromRow(flatten(r))).toList();
  }

  Future<CommentItem> postComment({
    required String confessionId,
    required String text,
  }) async {
    final row = await _supa
        .from('confession_comments')
        .insert({
          'confession_id': confessionId,
          'text': text,
        })
        .select(
          '''
          id, confession_id, author_user_id, text, created_at,
          profiles:confession_comments_author_user_id_fkey(name, profile_pictures)
          ''',
        )
        .single();

    Map<String, dynamic> flatten(Map<String, dynamic> r) {
      final prof = (r['profiles'] as Map?) ?? const {};
      final pics = (prof['profile_pictures'] as List?) ?? const [];
      final avatar = pics.isNotEmpty ? pics.first?.toString() : null;
      return {
        ...r,
        'author_name': (prof['name'] ?? 'Someone').toString(),
        'author_avatar_url': avatar,
      };
    }

    return CommentItem.fromRow(flatten((row as Map).cast<String, dynamic>()));
  }

  // --- Compose (create/edit/delete) ------------------------------------------
  Future<ConfessionItem> insertConfession({
    required String content,
    required String topic,
    required String language,
    required bool nsfw,
    required bool isAnonymous,
    String? imageUrl,
  }) async {
    final row = await _supa
        .from('confessions')
        .insert({
          'content': content,
          'topic': topic,
          'language': language,
          'nsfw': nsfw,
          'is_anonymous': isAnonymous,
          if (imageUrl != null) 'image_url': imageUrl,
        })
        .select()
        .single();

    final res = await _supa.rpc('confessions_one', params: {'p_confession_id': row['id']});
    final list = (res as List?)?.cast<Map<String, dynamic>>() ?? const [];
    return list.isNotEmpty ? ConfessionItem.fromRow(list.first) : ConfessionItem.fromRow(row);
  }

  Future<ConfessionItem> updateConfession({
    required String confessionId,
    required String content,
    required String topic,
    required String language,
    required bool nsfw,
    required bool isAnonymous,
    String? imageUrl, // pass null to remove image
    bool removeImage = false,
  }) async {
    final patch = <String, dynamic>{
      'content': content,
      'topic': topic,
      'language': language,
      'nsfw': nsfw,
      'is_anonymous': isAnonymous,
    };
    if (removeImage) {
      patch['image_url'] = null;
    } else if (imageUrl != null) {
      patch['image_url'] = imageUrl;
    }

    final row = await _supa
        .from('confessions')
        .update(patch)
        .eq('id', confessionId)
        .select()
        .single();

    final res = await _supa.rpc('confessions_one', params: {'p_confession_id': row['id']});
    final list = (res as List?)?.cast<Map<String, dynamic>>() ?? const [];
    return list.isNotEmpty ? ConfessionItem.fromRow(list.first) : ConfessionItem.fromRow(row);
  }

  Future<void> deleteConfession(String confessionId) async {
    await _supa.from('confessions').delete().eq('id', confessionId);
  }

  // --- Image upload (optional helper) ----------------------------------------
  Future<String> uploadImageToPublicBucket({
    required String bucket, // e.g. 'confessions'
    required String fileName, // e.g. 'u_<uid>/ts.jpg'
    required Uint8List bytes,
    String contentType = 'image/jpeg',
  }) async {
    await _supa.storage.from(bucket).uploadBinary(
          fileName,
          bytes,
          fileOptions: FileOptions(
            cacheControl: '3600',
            upsert: false,
            contentType: contentType,
          ),
        );
    return _supa.storage.from(bucket).getPublicUrl(fileName);
  }
}
