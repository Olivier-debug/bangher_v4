// =========================
// FILE: lib/features/confessions/data/confession_models.dart
// =========================

class ConfessionItem {
  final String id;
  final String authorUserId;
  final String content;
  final bool isAnonymous;
  final String? imageUrl;
  final DateTime createdAt;
  final int likeCount;
  final int commentCount;
  final bool likedByMe;
  final String? authorName;
  final String? authorAvatarUrl;
  final String topic;
  final String language;
  final bool nsfw;
  final DateTime? editedAt;

  const ConfessionItem({
    required this.id,
    required this.authorUserId,
    required this.content,
    required this.isAnonymous,
    required this.imageUrl,
    required this.createdAt,
    required this.likeCount,
    required this.commentCount,
    required this.likedByMe,
    required this.authorName,
    required this.authorAvatarUrl,
    required this.topic,
    required this.language,
    required this.nsfw,
    required this.editedAt,
  });

  ConfessionItem copyWith({
    int? likeCount,
    int? commentCount,
    bool? likedByMe,
    String? content,
    String? imageUrl,
    String? topic,
    String? language,
    bool? nsfw,
    DateTime? editedAt,
  }) {
    return ConfessionItem(
      id: id,
      authorUserId: authorUserId,
      content: content ?? this.content,
      isAnonymous: isAnonymous,
      imageUrl: imageUrl ?? this.imageUrl,
      createdAt: createdAt,
      likeCount: likeCount ?? this.likeCount,
      commentCount: commentCount ?? this.commentCount,
      likedByMe: likedByMe ?? this.likedByMe,
      authorName: authorName,
      authorAvatarUrl: authorAvatarUrl,
      topic: topic ?? this.topic,
      language: language ?? this.language,
      nsfw: nsfw ?? this.nsfw,
      editedAt: editedAt ?? this.editedAt,
    );
  }

  static ConfessionItem fromRow(Map<String, dynamic> r) {
    String s(dynamic v) => (v ?? '').toString();
    int i(dynamic v) => (v is int) ? v : (int.tryParse(s(v)) ?? 0);
    bool b(dynamic v) => v == true;

    return ConfessionItem(
      id: s(r['id']),
      authorUserId: s(r['author_user_id']),
      content: s(r['content']),
      isAnonymous: b(r['is_anonymous']),
      imageUrl: s(r['image_url']).isEmpty ? null : s(r['image_url']),
      createdAt: DateTime.tryParse(s(r['created_at']))?.toUtc() ?? DateTime.now().toUtc(),
      likeCount: i(r['like_count']),
      commentCount: i(r['comment_count']),
      likedByMe: (r['liked_by_me'] as bool?) ?? false,
      authorName: s(r['author_name']).isEmpty ? null : s(r['author_name']),
      authorAvatarUrl: s(r['author_avatar_url']).isEmpty ? null : s(r['author_avatar_url']),
      topic: s(r['topic']).isEmpty ? 'Random' : s(r['topic']),
      language: s(r['language']).isEmpty ? 'English' : s(r['language']),
      nsfw: b(r['nsfw']),
      editedAt: DateTime.tryParse(s(r['edited_at'])),
    );
  }
}

class CommentItem {
  final String id;
  final String confessionId;
  final String authorUserId;
  final String authorName;
  final String? authorAvatarUrl;
  final String text;
  final DateTime createdAt;

  const CommentItem({
    required this.id,
    required this.confessionId,
    required this.authorUserId,
    required this.authorName,
    required this.authorAvatarUrl,
    required this.text,
    required this.createdAt,
  });

  static CommentItem fromRow(Map<String, dynamic> r) {
    String s(dynamic v) => (v ?? '').toString();
    return CommentItem(
      id: s(r['id']),
      confessionId: s(r['confession_id']),
      authorUserId: s(r['author_user_id']),
      authorName: s(r['author_name']).isEmpty ? s(r['name']).isEmpty ? 'Someone' : s(r['name']) : s(r['author_name']),
      authorAvatarUrl: s(r['author_avatar_url']).isEmpty
          ? (s(r['avatar_url']).isEmpty ? null : s(r['avatar_url']))
          : s(r['author_avatar_url']),
      text: s(r['text']),
      createdAt: DateTime.tryParse(s(r['created_at']))?.toUtc() ?? DateTime.now().toUtc(),
    );
  }
}
