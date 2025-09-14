// FILE: lib/features/chat/chat_repository.dart
// Supabase Realtime v2 helpers for chat (messages, typing, presence).

import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';

typedef MessageInsertCallback = void Function(Map<String, dynamic> newRecord);
typedef BroadcastCallback = void Function(Map<String, dynamic> payload);

class ChatRepository {
  ChatRepository({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  RealtimeChannel? _messagesChannel;
  RealtimeChannel? _presenceChannel;

  /// Listen for INSERTs into `public.messages` filtered by chat_id.
  RealtimeChannel subscribeToMessageInserts({
    required int chatId,
    required MessageInsertCallback onInsert,
  }) {
    final channel = _client.channel('chat-msgs-$chatId');

    channel
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'chat_id',
            value: chatId,
          ),
          callback: (payload) {
            onInsert(payload.newRecord);
          },
        )
        .subscribe();

    _messagesChannel = channel;
    return channel;
  }

  /// Listen to typing broadcasts on the messages channel.
  void listenTyping({required BroadcastCallback onTyping}) {
    final channel = _ensureMessagesChannel();
    channel.onBroadcast(event: 'typing', callback: (payload) {
      onTyping(payload);
    });
  }

  /// Broadcast a typing event.
  Future<void> sendTyping({
    required int chatId,
    required String userId,
    required bool isTyping,
  }) async {
    final channel = _ensureMessagesChannel();
    await channel.sendBroadcastMessage(
      event: 'typing',
      payload: {
        'chat_id': chatId,
        'user_id': userId,
        'typing': isTyping,
        'ts': DateTime.now().toIso8601String(),
      },
    );
  }

  /// Join presence for a chat; emits online users via sync/join/leave.
  RealtimeChannel joinPresence({
    required int chatId,
    required String userId,
    void Function(Set<String> onlineUserIds)? onSync,
    void Function(String userId)? onJoin,
    void Function(String userId)? onLeave,
  }) {
    final channel = _client.channel('chat-presence-$chatId');

    channel
      ..onPresenceSync((_) {
        final ids = _currentOnlineUserIds(channel);
        if (onSync != null) onSync(ids);
      })
      ..onPresenceJoin((payload) {
        for (final p in payload.newPresences) {
          final uid = p.payload['user_id']?.toString();
          if (uid != null && onJoin != null) onJoin(uid);
        }
      })
      ..onPresenceLeave((payload) {
        for (final p in payload.leftPresences) {
          final uid = p.payload['user_id']?.toString();
          if (uid != null && onLeave != null) onLeave(uid);
        }
      })
      ..subscribe((status, error) async {
        if (status == RealtimeSubscribeStatus.subscribed) {
          await channel.track({
            'user_id': userId,
            'status': 'online',
            'ts': DateTime.now().toIso8601String(),
          });
        } else if (error != null) {
          // optionally log error
        }
      });

    _presenceChannel = channel;
    return channel;
  }

  /// Current online user IDs from presence.
  Set<String> getCurrentOnlineUserIds() {
    final channel = _presenceChannel;
    if (channel == null) return <String>{};
    return _currentOnlineUserIds(channel);
  }

  /// Stream all messages for a chat (ordered ASC).
  Stream<List<Map<String, dynamic>>> streamMessages(int chatId) {
    return _client
        .from('messages')
        .stream(primaryKey: ['id'])
        .eq('chat_id', chatId)
        .order('created_at', ascending: true)
        .map((rows) => rows.map((e) => Map<String, dynamic>.from(e)).toList());
  }

  /// Insert a message row.
  Future<void> sendMessage({
    required int chatId,
    required String senderId,
    required String text,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    await _client.from('messages').insert({
      'chat_id': chatId,
      'sender_id': senderId,
      'message': trimmed,
    });
  }

  /// Cleanup.
  Future<void> dispose() async {
    await _messagesChannel?.unsubscribe();
    await _presenceChannel?.unsubscribe();
    _messagesChannel = null;
    _presenceChannel = null;
  }

  // ----------------- Helpers -----------------

  RealtimeChannel _ensureMessagesChannel() {
    final ch = _messagesChannel;
    if (ch != null) return ch;
    return _messagesChannel =
        _client.channel('chat-msgs-generic')..subscribe();
  }

  Set<String> _currentOnlineUserIds(RealtimeChannel channel) {
    final states = channel.presenceState(); // List<PresenceState>
    final ids = <String>{};
    for (final s in states) {
      for (final presence in s.presences) {
        final uid = presence.payload['user_id']?.toString();
        if (uid != null && uid.isNotEmpty) ids.add(uid);
      }
    }
    return ids;
  }
}
