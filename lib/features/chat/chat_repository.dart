// FILE: lib/features/chat/chat_repository.dart
// Supabase Realtime v2 helpers for chat (messages, typing, presence).

import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/cache_wiper.dart';

typedef MessageInsertCallback = void Function(Map<String, dynamic> newRecord);
typedef BroadcastCallback = void Function(Map<String, dynamic> payload);

class ChatRepository {
  ChatRepository({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  RealtimeChannel? _messagesChannel;
  RealtimeChannel? _presenceChannel;
  String? _messagesChannelName;

  /// Listen for INSERTs into `public.messages` filtered by chat_id.
  RealtimeChannel subscribeToMessageInserts({
    required int chatId,
    required MessageInsertCallback onInsert,
  }) {
    final name = 'chat-msgs-$chatId';
    final channel = _client.channel(name);

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
            onInsert(Map<String, dynamic>.from(payload.newRecord));
          },
        )
        .subscribe();

    if (_messagesChannel != null && _messagesChannel != channel) {
      unawaited(_messagesChannel!.unsubscribe());
    }
    _messagesChannel = channel;
    _messagesChannelName = name;
    return channel;
  }

  /// Listen to typing broadcasts on the messages channel.
  void listenTyping({required BroadcastCallback onTyping}) {
    final channel = _ensureMessagesChannel();
    channel.onBroadcast(event: 'typing', callback: (payload) {
      onTyping(Map<String, dynamic>.from(payload));
    });
  }

  /// Broadcast a typing event (public API).
  Future<void> sendTyping({
    required int chatId,
    required String userId,
    required bool isTyping,
  }) async {
    final channel = await _ensureMessagesChannelFor(chatId);
    await channel.sendBroadcastMessage(
      event: 'typing',
      payload: <String, dynamic>{
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
          try {
            await channel.track({
              'user_id': userId,
              'status': 'online',
              'ts': DateTime.now().toIso8601String(),
            });
          } catch (_) {}
        } else if (error != null) {
          // optionally log
        }
      });

    if (_presenceChannel != null && _presenceChannel != channel) {
      unawaited(_presenceChannel!.unsubscribe());
    }
    _presenceChannel = channel;
    return channel;
  }

  /// Current online user IDs from presence.
  Set<String> getCurrentOnlineUserIds() {
    final ch = _presenceChannel;
    if (ch == null) return <String>{};
    return _currentOnlineUserIds(ch);
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
    try {
      await _messagesChannel?.unsubscribe();
    } catch (_) {}
    try {
      await _presenceChannel?.unsubscribe();
    } catch (_) {}
    _messagesChannel = null;
    _presenceChannel = null;
    _messagesChannelName = null;
  }

  // ----------------- Helpers -----------------

  RealtimeChannel _ensureMessagesChannel() {
    final ch = _messagesChannel;
    if (ch != null) return ch;
    final fallback = _client.channel('chat-msgs-generic')..subscribe();
    _messagesChannel = fallback;
    _messagesChannelName = 'chat-msgs-generic';
    return fallback;
  }

  Future<RealtimeChannel> _ensureMessagesChannelFor(int chatId) async {
    final desiredName = 'chat-msgs-$chatId';
    if (_messagesChannel != null && _messagesChannelName == desiredName) {
      return _messagesChannel!;
    }
    try {
      await _messagesChannel?.unsubscribe();
    } catch (_) {}
    final channel = _client.channel(desiredName)..subscribe();
    _messagesChannel = channel;
    _messagesChannelName = desiredName;
    return channel;
  }

  /// Presence parsing compatible with both SDK shapes.
  Set<String> _currentOnlineUserIds(RealtimeChannel channel) {
    final ids = <String>{};
    final dynamic state = channel.presenceState();

    if (state is Map) {
      for (final entry in state.entries) {
        final value = entry.value;
        if (value is List) {
          for (final pres in value) {
            final uid = (pres as dynamic).payload?['user_id']?.toString();
            if (uid != null && uid.isNotEmpty) ids.add(uid);
          }
        }
      }
      return ids;
    }

    if (state is List) {
      for (final s in state) {
        try {
          final presences = (s as dynamic).presences as List?;
          if (presences == null) continue;
          for (final p in presences) {
            final uid = (p as dynamic).payload?['user_id']?.toString();
            if (uid != null && uid.isNotEmpty) ids.add(uid);
          }
        } catch (_) {}
      }
    }
    return ids;
    }
}

// ──────────────────────────────────────────────────────────────
// Concrete singleton + CacheWiper hook (non-optional).
// ──────────────────────────────────────────────────────────────

final ChatRepository chatRepositorySingleton = ChatRepository();

void _registerChatRepoHook() {
  CacheWiper.registerHook(() async {
    try {
      await chatRepositorySingleton.dispose();
    } catch (_) {}
  });
}

// Ensure one-time registration.
// ignore: unused_element
final bool _chatRepoHookRegistered = (() {
  _registerChatRepoHook();
  return true;
})();
